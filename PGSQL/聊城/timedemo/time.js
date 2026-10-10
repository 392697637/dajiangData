window.CESIUM_DISABLE_DEFAULT_LAYERS = true;
window.CESIUM_BASE_URL = "https://cdn.jsdelivr.net/npm/cesium@1.92/Build/Cesium/";

window.AirspaceMap = {
  tiandituToken: "cf128e0b51efeb7df5f1720de282678e",

  resetContainer() {
    document.querySelector("#cesiumContainer")?.remove();
    document.querySelector(".stage").insertAdjacentHTML("afterbegin", '<div id="cesiumContainer"></div>');
  },

  createViewer() {
    const viewer = new Cesium.Viewer("cesiumContainer", {
      animation: false,
      timeline: false,
      baseLayerPicker: false,
      geocoder: false,
      homeButton: false,
      sceneModePicker: false,
      navigationHelpButton: false,
      fullscreenButton: false,
      infoBox: false,
      selectionIndicator: false,
      imageryProvider: false,
      terrainProvider: new Cesium.EllipsoidTerrainProvider(),
    });
    viewer.imageryLayers.removeAll();
    const subdomains = ["0", "1", "2", "3", "4", "5", "6", "7"];
    viewer.imageryLayers.addImageryProvider(new Cesium.WebMapTileServiceImageryProvider({
      url: "https://t{s}.tianditu.gov.cn/img_w/wmts?service=WMTS&request=GetTile&version=1.0.0&layer=img&style=default&format=tiles&TileMatrixSet=w&tk=" + this.tiandituToken,
      layer: "img",
      style: "default",
      format: "image/png",
      tileMatrixSetID: "w",
      subdomains,
      maximumLevel: 18,
    }));
    viewer.imageryLayers.addImageryProvider(new Cesium.WebMapTileServiceImageryProvider({
      url: "https://t{s}.tianditu.gov.cn/cia_w/wmts?service=WMTS&request=GetTile&version=1.0.0&layer=cia&style=default&format=tiles&TileMatrixSet=w&tk=" + this.tiandituToken,
      layer: "cia",
      style: "default",
      format: "image/png",
      tileMatrixSetID: "w",
      subdomains,
      maximumLevel: 18,
    }));
    viewer.scene.globe.show = true;
    viewer.scene.globe.enableLighting = true;
    viewer.camera.setView({
      destination: Cesium.Cartesian3.fromDegrees(115.985, 36.455, 85000),
      orientation: { heading: 0, pitch: Cesium.Math.toRadians(-90), roll: 0 },
    });
    return viewer;
  },

  destroyViewer(viewer) {
    if (viewer && !viewer.isDestroyed()) viewer.destroy();
  },

  displayGeometry(block) {
    const geometry = block.final_geom?.geometry || block.geom?.geometry || block.geometry;
    if (!geometry) return null;
    if (geometry.type === "Point") {
      const [lon, lat] = geometry.coordinates;
      const radius = Number(block.airspace_radius || 0);
      const points = [];
      const latRadius = radius / 111320;
      const lonRadius = radius / (111320 * Math.cos(Cesium.Math.toRadians(lat)));
      for (let i = 0; i <= 64; i += 1) {
        const angle = (Math.PI * 2 * i) / 64;
        points.push([lon + Math.cos(angle) * lonRadius, lat + Math.sin(angle) * latRadius, geometry.coordinates[2] || 0]);
      }
      return { type: "Polygon", coordinates: [points] };
    }
    if (geometry.type === "LineString") {
      return { type: "LineString", coordinates: geometry.coordinates };
    }
    return geometry;
  },

  ring(block) {
    const geometry = this.displayGeometry(block);
    if (!geometry) return [];
    if (geometry.type === "Polygon") return geometry.coordinates[0] || [];
    if (geometry.type === "MultiPolygon") return geometry.coordinates[0]?.[0] || [];
    if (geometry.type === "LineString") return geometry.coordinates || [];
    if (geometry.type === "Point") return [geometry.coordinates];
    return [];
  },

  center(block, height = 0) {
    const ring = this.ring(block);
    if (!ring.length) return Cesium.Cartesian3.fromDegrees(115.985, 36.455, height);
    const bounds = ring.reduce((acc, p) => ({
      west: Math.min(acc.west, p[0]),
      east: Math.max(acc.east, p[0]),
      south: Math.min(acc.south, p[1]),
      north: Math.max(acc.north, p[1]),
    }), { west: Infinity, east: -Infinity, south: Infinity, north: -Infinity });
    return Cesium.Cartesian3.fromDegrees(
      (bounds.west + bounds.east) / 2,
      (bounds.south + bounds.north) / 2,
      height,
    );
  },

  boundary(block) {
    return Cesium.Cartesian3.fromDegreesArray(this.ring(block).flatMap((p) => [p[0], p[1]]));
  },

  flyToBlock(viewer, block) {
    const sphere = Cesium.BoundingSphere.fromPoints(this.boundary(block));
    viewer.camera.flyToBoundingSphere(sphere, {
      duration: 0.8,
      offset: new Cesium.HeadingPitchRange(0, Cesium.Math.toRadians(-80), Math.max(sphere.radius * 3.5, 5000)),
    });
  },

  airspaceFeatures(airspaces) {
    return (airspaces || []).map((airspace) => ({
      type: "Feature",
      properties: {
        id: airspace.id,
        code: airspace.airspace_code,
        name: airspace.airspace_name,
        kind: "main_airspace",
      },
      geometry: this.displayGeometry(airspace),
    })).filter((feature) => feature.geometry);
  },

  styleMainAirspaces(source) {
    source.entities.values.forEach((entity) => {
      if (entity.properties?.kind?.getValue() !== "main_airspace") return;
      if (entity.polygon) {
        entity.polygon.material = Cesium.Color.fromCssColorString("rgba(30, 214, 255, 0.12)");
        entity.polygon.outline = true;
        entity.polygon.outlineColor = Cesium.Color.CYAN;
      }
      if (entity.polyline) {
        entity.polyline.material = Cesium.Color.CYAN;
        entity.polyline.width = 3;
      }
    });
  },
};
const App = {
  data: null,
  current: null,
  page: "plan",
  els: {},

  async init() {
    this.els = {
      filterTitle: document.querySelector("#filterTitle"),
      resultTitle: document.querySelector("#resultTitle"),
      popup: document.querySelector(".plan-popup"),
      popupClose: document.querySelector("#popupClose"),
      type: document.querySelector("#airspaceType"),
      code: document.querySelector("#airspaceCode"),
      name: document.querySelector("#airspaceName"),
      state: document.querySelector("#airspaceState"),
      search: document.querySelector("#searchBtn"),
      reset: document.querySelector("#resetBtn"),
      setFlyTime: document.querySelector("#setFlyTimeBtn"),
      publish: document.querySelector("#publishPlanBtn"),
      date: document.querySelector("#useDate"),
      slider: document.querySelector("#timeSlider"),
      back: document.querySelector("#backBtn"),
      forward: document.querySelector("#forwardBtn"),
      play: document.querySelector("#playBtn"),
    };
    const [airspaceResponse, blockResponse, planResponse] = await Promise.all([
      fetch("airspace.json", { cache: "no-store" }),
      fetch("airspace-block.json", { cache: "no-store" }),
      fetch("airspace-plan.json", { cache: "no-store" }),
    ]);
    if (!airspaceResponse.ok) throw new Error("airspace.json 请求失败");
    if (!blockResponse.ok) throw new Error("airspace-block.json 请求失败");
    if (!planResponse.ok) throw new Error("airspace-plan.json 请求失败");
    this.data = {
      airspace: await airspaceResponse.json(),
      block: await blockResponse.json(),
      plan: await planResponse.json(),
    };
    this.bind();
    this.switchTo("plan");
  },

  bind() {
    document.querySelectorAll("[data-page-link]").forEach((link) => {
      link.addEventListener("click", (event) => {
        event.preventDefault();
        this.switchTo(link.dataset.pageLink);
      });
    });
    this.els.search.addEventListener("click", () => {
      if (typeof this.current?.pageNo === "number") this.current.pageNo = 1;
      this.current?.render();
    });
    this.els.reset.addEventListener("click", () => {
      this.els.type.value = "";
      this.els.code.value = "";
      this.els.name.value = "";
      this.els.state.value = "";
      if (typeof this.current?.pageNo === "number") this.current.pageNo = 1;
      this.current?.render();
    });
    this.els.setFlyTime.addEventListener("click", () => this.current?.openPlanForm?.());
    this.els.publish.addEventListener("click", () => this.current?.openPlanForm?.());
    this.els.date.addEventListener("change", () => {
      if (typeof this.current?.pageNo === "number") this.current.pageNo = 1;
      this.current?.render();
    });
    this.els.slider.addEventListener("input", (event) => this.current?.setSeconds?.(event.target.value));
    this.els.back.addEventListener("click", () => this.current?.setSeconds?.((this.current.seconds || 0) - 3600));
    this.els.forward.addEventListener("click", () => this.current?.setSeconds?.((this.current.seconds || 0) + 3600));
    this.els.play.addEventListener("click", () => this.current?.togglePlay?.());
    this.els.popupClose.addEventListener("click", () => {
      this.els.popup.hidden = true;
    });
  },

  switchTo(page) {
    if (this.current?.destroy) this.current.destroy();
    AirspaceMap.resetContainer();
    this.page = page;
    document.body.dataset.page = page;
    document.querySelectorAll("[data-page-link]").forEach((link) => {
      link.classList.toggle("active", link.dataset.pageLink === page);
    });
    const topPage = page === "plan" ? "flight" : page === "block" ? "airspace" : "system";
    document.querySelectorAll("[data-top-nav]").forEach((link) => {
      link.classList.toggle("active", link.dataset.topNav === topPage);
    });
    this.els.popup.hidden = true;
    if (page === "block") {
      this.els.filterTitle.textContent = "空域区块";
      this.els.resultTitle.textContent = "空域区块列表";
      this.els.search.textContent = "查询";
      this.els.reset.textContent = "重置";
      this.current = window.AirspaceBlockPage;
      this.current.init(this.data.block, this.data.airspace);
      return;
    } else {
      this.els.filterTitle.textContent = "用空计划";
      this.els.resultTitle.textContent = "";
      this.els.search.textContent = "查询";
      this.els.reset.textContent = "重置";
      this.current = window.AirspacePlanPage;
    }
    this.current.init(this.data.block, this.data.plan, this.data.airspace);
  },
};

App.init().catch((error) => {
  document.querySelector("#blockList").innerHTML = `<p>模拟后端数据加载失败：${error.message}<br>请通过本地 HTTP 服务打开此页面。</p>`;
});

