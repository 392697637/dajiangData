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

  center(block, height = 0) {
    const ring = block.geom.geometry.coordinates[0];
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
    return Cesium.Cartesian3.fromDegreesArray(block.geom.geometry.coordinates[0].flatMap((p) => [p[0], p[1]]));
  },

  flyToBlock(viewer, block) {
    const sphere = Cesium.BoundingSphere.fromPoints(this.boundary(block));
    viewer.camera.flyToBoundingSphere(sphere, {
      duration: 0.8,
      offset: new Cesium.HeadingPitchRange(0, Cesium.Math.toRadians(-80), Math.max(sphere.radius * 3.5, 5000)),
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
      date: document.querySelector("#useDate"),
      slider: document.querySelector("#timeSlider"),
      back: document.querySelector("#backBtn"),
      forward: document.querySelector("#forwardBtn"),
      play: document.querySelector("#playBtn"),
    };
    const response = await fetch("time.json", { cache: "no-store" });
    if (!response.ok) throw new Error("time.json 请求失败");
    this.data = await response.json();
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
    this.els.date.addEventListener("change", () => this.current?.render());
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
    this.els.popup.hidden = true;
    if (page === "block") {
      this.els.filterTitle.textContent = "空域区块";
      this.els.resultTitle.textContent = "空域区块列表";
      this.current = window.AirspaceBlockPage;
    } else {
      this.els.filterTitle.textContent = "用空计划";
      this.els.resultTitle.textContent = "当天空域区块";
      this.current = window.AirspacePlanPage;
    }
    this.current.init(this.data);
  },
};

App.init().catch((error) => {
  document.querySelector("#blockList").innerHTML = `<p>模拟后端数据加载失败：${error.message}<br>请通过本地 HTTP 服务打开此页面。</p>`;
});

