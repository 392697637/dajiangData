const AIRSPACE_TYPES = { CONTROL: "管制空域", MONITOR: "监视空域", REPORT: "报告空域" };
const AIRSPACE_STATES = { CONTROL: "管制状态", MONITOR: "监控状态", REPORT: "报警状态" };

const DEFAULT_PROJECT_ID = "d10326d5a9894cd6b8b5bd365a103394";

function blockId(block) {
  return String(block.id ?? block.block_id);
}

function blockFeature(block) {
  return {
    type: "Feature",
    properties: { blockId: blockId(block), code: block.airspace_code, enabled: block.use_enabled },
    geometry: AirspaceMap.displayGeometry(block),
  };
}

function blockTypeText(type) {
  return ({ POINT: "点", LINE: "线", POLYGON: "面" })[type] || type || "-";
}

function blockEnabledText(enabled) {
  return enabled ? "启用" : "停用";
}

function blockEls() {
  return {
    type: document.querySelector("#airspaceType"),
    code: document.querySelector("#airspaceCode"),
    name: document.querySelector("#airspaceName"),
    state: document.querySelector("#airspaceState"),
    list: document.querySelector("#blockList"),
    pager: document.querySelector("#blockPager"),
    count: document.querySelector("#resultCount"),
    popup: document.querySelector(".plan-popup"),
    popupTitle: document.querySelector("#popupTitle"),
    popupContent: document.querySelector("#popupContent"),
    popupClose: document.querySelector("#popupClose"),
    add: document.querySelector("#addBlockBtn"),
    sidebarAdd: document.querySelector("#sidebarAddBlockBtn"),
    modal: document.querySelector("#blockFormModal"),
    formTitle: document.querySelector("#blockFormTitle"),
    formClose: document.querySelector("#blockFormClose"),
    formCancel: document.querySelector("#blockFormCancel"),
    formDelete: document.querySelector("#blockFormDelete"),
    formSave: document.querySelector("#blockFormSave"),
    formCode: document.querySelector("#formAirspaceCode"),
    formName: document.querySelector("#formAirspaceName"),
    formHeight: document.querySelector("#formAirspaceHeight"),
    formType: document.querySelector("#formAirspaceType"),
    shapePoint: document.querySelector("#shapePoint"),
    shapePolygon: document.querySelector("#shapePolygon"),
    formState: document.querySelector("#formAirspaceState"),
    stateEnable: document.querySelector("#formStateEnable"),
    stateDisable: document.querySelector("#formStateDisable"),
    formUnitName: document.querySelector("#formUnitName"),
    formUnitId: document.querySelector("#formUnitId"),
    formArea: document.querySelector("#formAirspaceArea"),
    formPerimeter: document.querySelector("#formAirspacePerimeter"),
    formCoords: document.querySelector("#formAirspaceCoords"),
    formPolygon: document.querySelector("#formAirspacePolygon"),
    draw: document.querySelector("#blockDrawBtn"),
    clearDraw: document.querySelector("#blockClearDrawBtn"),
    drawTip: document.querySelector("#blockDrawTip"),
  };
}

function blockColor(state) {
  return Cesium.Color.fromCssColorString("rgba(24, 169, 255, 0.58)");
}

window.AirspaceBlockPage = {
  viewer: null,
  source: null,
  blocks: [],
  airspaces: [],
  entities: new Map(),
  popupAnchor: null,
  popupListener: null,
  drawHandler: null,
  draftEntity: null,
  draftPositions: [],
  draftGeom: null,
  pageNo: 1,
  pageSize: 6,
  editingId: null,
  selectedId: null,

  init(data, airspaceData) {
    this.blocks = data.data;
    this.airspaces = airspaceData?.data || [];
    this.els = blockEls();
    this.els.popup.hidden = true;
    this.els.popupTitle.textContent = "空域区块详情";
    this.viewer = AirspaceMap.createViewer();
    this.bind();
    this.bindForm();
    this.bindList();
    this.render();
  },

  destroy() {
    if (this.viewer && this.popupListener) {
      this.viewer.scene.postRender.removeEventListener(this.popupListener);
    }
    this.stopDraw();
    this.clearDraft();
    AirspaceMap.destroyViewer(this.viewer);
    this.viewer = null;
    this.source = null;
    this.entities.clear();
    this.popupAnchor = null;
    this.popupListener = null;
  },

  bind() {
    this.clickHandler = (event) => {
      const picked = this.viewer.scene.pick(event.position);
      if (!Cesium.defined(picked) || !picked.id?.properties?.blockId) return;
      const id = String(picked.id.properties.blockId.getValue());
      const block = this.filtered().find((item) => blockId(item) === id);
      if (block) {
        this.selectBlock(id);
        this.showPopup(block, event.position);
      }
    };
    this.viewer.screenSpaceEventHandler.setInputAction(this.clickHandler, Cesium.ScreenSpaceEventType.LEFT_CLICK);
    this.popupListener = () => this.updatePopupPosition();
    this.viewer.scene.postRender.addEventListener(this.popupListener);
  },

  bindForm() {
    this.els.add.onclick = () => this.openForm();
    this.els.sidebarAdd.onclick = () => this.openForm();
    this.els.formClose.onclick = () => this.closeForm();
    this.els.formCancel.onclick = () => this.closeForm();
    this.els.formSave.onclick = () => this.saveForm();
    this.els.formDelete.onclick = () => {
      if (!this.editingId) return;
      this.deleteBlock(this.editingId);
      this.closeForm();
    };
    this.els.draw.onclick = () => this.startDraw();
    this.els.clearDraw.onclick = () => this.clearDraft();
    this.els.shapePoint.onchange = () => this.setShapeType("POINT");
    this.els.shapePolygon.onchange = () => this.setShapeType("POLYGON");
    this.els.stateEnable.onclick = () => this.setEnabled(true);
    this.els.stateDisable.onclick = () => this.setEnabled(false);
    this.els.formUnitName.oninput = () => {
      if (this.draftGeom?.geometry?.type === "Point") this.showDraft();
    };
  },

  bindList() {
    this.els.list.onclick = (event) => {
      const row = event.target.closest(".block-grid-row");
      if (!row || !this.els.list.contains(row)) return;
      this.selectBlock(row.dataset.id);
      this.flyTo(row.dataset.id);
      this.openForm(row.dataset.id);
    };
  },

  filtered() {
    const els = this.els;
    const code = els.code.value.trim().toLowerCase();
    const name = els.name.value.trim().toLowerCase();
    return this.blocks.filter((block) =>
      (!code || block.airspace_code.toLowerCase().includes(code)) &&
      (!name || block.airspace_name.toLowerCase().includes(name)) &&
      (!els.type.value || block.airspace_type === els.type.value) &&
      (!els.state.value || String(block.use_enabled) === els.state.value)
    );
  },

  render() {
    const blocks = this.filtered();
    this.renderList();
    this.draw(blocks);
  },

  openForm(id) {
    const block = id
      ? this.blocks.find((item) => blockId(item) === String(id))
      : null;
    this.editingId = block ? blockId(block) : null;
    if (block) this.selectBlock(this.editingId);
    this.els.formDelete.hidden = !block;
    this.els.formTitle.textContent = "空域信息";
    this.els.formCode.value = block?.airspace_code || "";
    this.els.formName.value = block?.airspace_name || "";
    this.els.formHeight.value = block?.airspace_height ?? 120;
    this.setShapeType(block?.airspace_type === "POLYGON" ? "POLYGON" : "POINT");
    this.setEnabled(block?.use_enabled ?? true);
    this.els.formUnitName.value = block?.airspace_radius || 5000;
    this.els.formUnitId.value = block?.project_id || DEFAULT_PROJECT_ID;
    this.els.formArea.value = block?.airspace_area || "";
    this.els.formArea.textContent = block?.airspace_area || "0";
    this.els.formPerimeter.value = block?.airspace_perimeter || "";
    this.els.formPerimeter.textContent = block?.airspace_perimeter || "0";
    this.els.formCoords.value = this.coordText(block);
    this.els.formPolygon.value = block?.airspace_type === "POLYGON" ? this.polygonText(block) : "";
    this.draftGeom = block ? structuredClone(block.geom) : null;
    this.setDrawTip(block ? "可重新绘制，也可直接保存原面" : "点击绘制面后，左键取点，右键结束");
    this.els.modal.hidden = false;
    this.els.modal.removeAttribute("hidden");
    this.showDraft();
  },

  closeForm() {
    this.editingId = null;
    this.els.modal.hidden = true;
    this.stopDraw();
    this.clearDraft();
  },

  saveForm() {
    const code = this.els.formCode.value.trim();
    const name = this.els.formName.value.trim();
    if (!code || !name) return;
    if (this.editingId) {
      const block = this.blocks.find((item) => blockId(item) === this.editingId);
      if (block) this.applyForm(block);
    } else {
      const block = this.createBlock();
      this.applyForm(block);
      this.blocks.unshift(block);
      this.pageNo = 1;
    }
    this.closeForm();
    this.render();
  },

  selectBlock(id) {
    this.selectedId = id ? String(id) : null;
    this.updateListSelection();
    this.updateHighlight();
  },

  updateListSelection() {
    if (!this.els?.list) return;
    this.els.list.querySelectorAll(".block-grid-row").forEach((row) => {
      row.classList.toggle("selected", row.dataset.id === this.selectedId);
    });
  },

  updateHighlight() {
    this.entities.forEach((entity, id) => {
      if (!entity.polygon) return;
      const selected = id === this.selectedId;
      const block = this.blocks.find((item) => blockId(item) === id);
      const state = block?.use_enabled ? "CONTROL" : "DISABLED";
      entity.polygon.material = selected
        ? Cesium.Color.fromCssColorString("rgba(255, 205, 56, 0.68)")
        : blockColor(state);
      entity.polygon.outline = true;
      entity.polygon.outlineColor = selected ? Cesium.Color.YELLOW : Cesium.Color.WHITE;
      entity.polygon.outlineWidth = selected ? 4 : 1;
      if (entity.label) {
        entity.label.fillColor = selected ? Cesium.Color.YELLOW : Cesium.Color.WHITE;
      }
    });
  },

  applyForm(block) {
    block.airspace_code = this.els.formCode.value.trim();
    block.airspace_name = this.els.formName.value.trim();
    block.airspace_height = Number(this.els.formHeight.value || 0);
    block.airspace_type = this.els.formType.value;
    block.use_enabled = this.els.formState.value === "true";
    block.airspace_radius = Number(this.els.formUnitName.value || 0);
    block.project_id = this.els.formUnitId.value.trim() || DEFAULT_PROJECT_ID;
    block.airspace_area = Number(this.els.formArea.value || this.els.formArea.textContent || 0);
    block.airspace_perimeter = Number(this.els.formPerimeter.value || this.els.formPerimeter.textContent || 0);
    if (this.draftGeom) block.geom = structuredClone(this.draftGeom);
  },

  setShapeType(type) {
    const previousType = this.els.formType.value;
    this.els.formType.value = type;
    this.els.shapePoint.checked = type === "POINT";
    this.els.shapePolygon.checked = type === "POLYGON";
    this.els.modal?.classList.toggle("is-polygon", type === "POLYGON");
    if (previousType && previousType !== type) this.clearDraft();
    if (type === "POINT") {
      this.els.formPolygon.value = "";
      if (!Number(this.els.formUnitName.value)) this.els.formUnitName.value = 5000;
    } else {
      this.els.formCoords.value = "";
    }
    this.setDrawTip("点击绘制面后，左键取点，右键结束");
  },

  setEnabled(enabled) {
    this.els.formState.value = String(enabled);
    this.els.stateEnable.classList.toggle("active", enabled);
    this.els.stateDisable.classList.toggle("active", !enabled);
  },

  coordText(block) {
    const coordinates = block?.geom?.geometry?.coordinates;
    if (!coordinates) return "";
    if (block.geom.geometry.type === "Point") return coordinates.slice(0, 2).join(",");
    const first = coordinates?.[0]?.[0];
    return Array.isArray(first) ? first.slice(0, 2).join(",") : "";
  },

  polygonText(block) {
    const ring = block?.geom?.geometry?.coordinates?.[0];
    if (!Array.isArray(ring)) return "";
    return ring.map((point) => point.slice(0, 2).join(",")).join("\n");
  },

  startDraw() {
    this.stopDraw();
    this.clearDraft();
    this.draftPositions = [];
    const shapeType = this.els.formType.value;
    this.setDrawTip(shapeType === "POINT" ? "正在绘制：左键点击地图生成圆形" : "正在绘制：左键取点，右键结束");
    this.drawHandler = new Cesium.ScreenSpaceEventHandler(this.viewer.scene.canvas);
    this.drawHandler.setInputAction((event) => {
      const coordinate = this.pickLonLat(event.position);
      if (!coordinate) return;
      if (shapeType === "POINT") {
        this.draftGeom = {
          type: "Feature",
          properties: {},
          geometry: {
            type: "Point",
            coordinates: [coordinate[0], coordinate[1], 0],
          },
        };
        this.els.formCoords.value = coordinate.join(",");
        if (!Number(this.els.formUnitName.value)) this.els.formUnitName.value = 5000;
        this.stopDraw();
        this.showDraft();
        this.setDrawTip("圆形已生成，可调整半径后保存");
        return;
      }
      this.draftPositions.push(coordinate);
      this.showDraft();
      this.setDrawTip(`已取 ${this.draftPositions.length} 个点，至少 3 个点后右键结束`);
    }, Cesium.ScreenSpaceEventType.LEFT_CLICK);
    if (shapeType === "POLYGON") {
      this.drawHandler.setInputAction(() => this.finishDraw(), Cesium.ScreenSpaceEventType.RIGHT_CLICK);
      this.drawHandler.setInputAction(() => this.finishDraw(), Cesium.ScreenSpaceEventType.LEFT_DOUBLE_CLICK);
    }
  },

  stopDraw() {
    if (this.drawHandler) {
      this.drawHandler.destroy();
      this.drawHandler = null;
    }
  },

  finishDraw() {
    if (this.draftPositions.length < 3) {
      this.setDrawTip("至少需要 3 个点才能生成面");
      return;
    }
    const ring = [...this.draftPositions];
    const first = ring[0];
    const last = ring[ring.length - 1];
    if (first[0] !== last[0] || first[1] !== last[1]) ring.push([...first]);
    this.draftGeom = {
      type: "Feature",
      properties: {},
      geometry: {
        type: "Polygon",
        coordinates: [ring],
      },
    };
    this.stopDraw();
    this.showDraft();
    this.setDrawTip(`绘制完成：${ring.length - 1} 个点，保存后生效`);
  },

  clearDraft() {
    this.stopDraw();
    this.draftPositions = [];
    this.draftGeom = null;
    if (this.draftEntity && this.viewer && !this.viewer.isDestroyed()) {
      this.viewer.entities.remove(this.draftEntity);
      this.draftEntity = null;
    }
    this.setDrawTip("点击绘制面后，左键取点，右键结束");
  },

  setDrawTip(text) {
    if (this.els?.drawTip) this.els.drawTip.textContent = text;
  },

  pickLonLat(position) {
    const cartesian = this.viewer.camera.pickEllipsoid(position, this.viewer.scene.globe.ellipsoid);
    if (!cartesian) return null;
    const cartographic = Cesium.Cartographic.fromCartesian(cartesian);
    return [
      Number(Cesium.Math.toDegrees(cartographic.longitude).toFixed(6)),
      Number(Cesium.Math.toDegrees(cartographic.latitude).toFixed(6)),
    ];
  },

  showDraft() {
    if (this.draftEntity) {
      this.viewer.entities.remove(this.draftEntity);
      this.draftEntity = null;
    }
    const geometry = this.draftGeom?.geometry;
    if (geometry?.type === "Point") {
      const [lon, lat, z = 0] = geometry.coordinates;
      const radius = Number(this.els?.formUnitName?.value || 0);
      const circle = AirspaceMap.displayGeometry({
        geom: this.draftGeom,
        airspace_radius: radius,
      });
      const circlePositions = circle?.coordinates?.[0]
        ? Cesium.Cartesian3.fromDegreesArray(circle.coordinates[0].flatMap((p) => [p[0], p[1]]))
        : null;
      this.draftEntity = this.viewer.entities.add({
        polygon: circlePositions ? {
          hierarchy: new Cesium.PolygonHierarchy(circlePositions),
          material: Cesium.Color.fromCssColorString("rgba(255, 205, 56, 0.24)"),
          outline: true,
          outlineColor: Cesium.Color.YELLOW,
        } : undefined,
        point: {
          pixelSize: 9,
          color: Cesium.Color.YELLOW,
          outlineColor: Cesium.Color.WHITE,
          outlineWidth: 2,
        },
        position: Cesium.Cartesian3.fromDegrees(lon, lat, z),
      });
      return;
    }
    const ring = geometry?.coordinates?.[0] || this.draftPositions;
    if (!ring || ring.length === 0) return;
    const positions = Cesium.Cartesian3.fromDegreesArray(ring.flatMap((p) => [p[0], p[1]]));
    const polygon = ring.length >= 3
      ? {
          hierarchy: new Cesium.PolygonHierarchy(positions),
          material: Cesium.Color.fromCssColorString("rgba(24, 169, 255, 0.34)"),
          outline: true,
          outlineColor: Cesium.Color.YELLOW,
        }
      : undefined;
    const polylinePositions = ring.length > 1 ? positions : undefined;
    this.draftEntity = this.viewer.entities.add({
      polygon,
      polyline: polylinePositions ? {
        positions: polylinePositions,
        width: 3,
        material: Cesium.Color.YELLOW,
        clampToGround: true,
      } : undefined,
      point: ring.length === 1 ? {
        pixelSize: 9,
        color: Cesium.Color.YELLOW,
        outlineColor: Cesium.Color.WHITE,
        outlineWidth: 2,
      } : undefined,
      position: ring.length === 1 ? positions[0] : undefined,
    });
  },

  createBlock() {
    const maxId = this.blocks.reduce((max, item) => {
      const value = String(item.id ?? item.block_id ?? "").match(/\d+$/)?.[0];
      return Math.max(max, Number(value) || 0);
    }, 0);
    const id = maxId + 1;
    const offset = (id % 8) * 0.015;
    return {
      id: `AIRSPACE-${String(id).padStart(2, "0")}`,
      project_id: DEFAULT_PROJECT_ID,
      airspace_code: "",
      airspace_name: "",
      airspace_height: 200,
      airspace_type: "POINT",
      airspace_radius: 5000,
      use_enabled: true,
      airspace_area: 0,
      geom: {
        type: "Feature",
        properties: {},
        geometry: {
          type: "Polygon",
          coordinates: [[
            [115.95 + offset, 36.45 + offset],
            [116.00 + offset, 36.45 + offset],
            [116.00 + offset, 36.49 + offset],
            [115.95 + offset, 36.49 + offset],
            [115.95 + offset, 36.45 + offset],
          ]],
        },
      },
    };
  },

  deleteBlock(id) {
    this.blocks = this.blocks.filter((item) => blockId(item) !== String(id));
    if (this.selectedId === String(id)) this.selectedId = null;
    this.popupAnchor = null;
    this.els.popup.hidden = true;
    const entity = this.entities.get(String(id));
    if (entity && this.source) {
      this.source.entities.remove(entity);
      this.entities.delete(String(id));
    }
    this.renderList();
  },

  renderList() {
    const blocks = this.filtered();
    this.els.count.textContent = `${blocks.length} 个区块`;
    this.els.list.innerHTML = `
      <div class="block-grid" role="table">
        <div class="block-grid-head" role="row">
          <strong>空域编号</strong>
          <strong>空域名称</strong>
          <strong>启用状态</strong>
        </div>
        ${blocks.map((block) => `
          <div class="block-grid-row ${this.selectedId === blockId(block) ? "selected" : ""}" data-id="${blockId(block)}" role="row">
            <span>${String(block.airspace_code || blockId(block)).match(/\d+$/)?.[0] ? 100 + Number(String(block.airspace_code || blockId(block)).match(/\d+$/)[0]) : block.airspace_code}</span>
            <span>${block.airspace_name}</span>
            <span class="${block.use_enabled ? "enabled" : "disabled"}">${block.use_enabled ? "启用" : "停用"}</span>
          </div>
        `).join("")}
      </div>`;
    this.els.pager.innerHTML = "";
  },

  renderPager(total, totalPages) {
    this.els.pager.innerHTML = `
      <button class="secondary" data-page-action="prev" ${this.pageNo <= 1 ? "disabled" : ""}>上一页</button>
      <span>${this.pageNo}/${totalPages} 页 · 共 ${total} 条</span>
      <button class="secondary" data-page-action="next" ${this.pageNo >= totalPages ? "disabled" : ""}>下一页</button>
    `;
    this.els.pager.querySelector("[data-page-action='prev']").addEventListener("click", () => {
      if (this.pageNo <= 1) return;
      this.pageNo -= 1;
      this.render();
    });
    this.els.pager.querySelector("[data-page-action='next']").addEventListener("click", () => {
      if (this.pageNo >= totalPages) return;
      this.pageNo += 1;
      this.render();
    });
  },

  draw(blocks) {
    const featureCollection = {
      type: "FeatureCollection",
      features: [
        ...AirspaceMap.airspaceFeatures(this.airspaces),
        ...blocks.map(blockFeature).filter((feature) => feature.geometry),
      ],
    };
    Cesium.GeoJsonDataSource.load(featureCollection, { stroke: Cesium.Color.WHITE, fill: Cesium.Color.YELLOW.withAlpha(0.5), strokeWidth: 4 }).then((source) => {
      if (this.source) this.viewer.dataSources.remove(this.source, true);
      this.source = source;
      this.entities.clear();
      this.viewer.dataSources.add(source);
      AirspaceMap.styleMainAirspaces(source);
      source.entities.values.forEach((entity) => {
        if (entity.properties?.kind?.getValue() === "main_airspace") return;
        const id = String(entity.properties.blockId.getValue());
        const code = entity.properties.code.getValue();
        const state = entity.properties.enabled.getValue() ? "CONTROL" : "DISABLED";
        const block = blocks.find((item) => blockId(item) === id);
        entity.position = AirspaceMap.center(block, 80);
        entity.polygon.material = blockColor(state);
        entity.polygon.outline = true;
        entity.polygon.outlineColor = Cesium.Color.WHITE;
        entity.label = new Cesium.LabelGraphics({
          text: code,
          font: "14px Microsoft YaHei",
          fillColor: Cesium.Color.WHITE,
          outlineColor: Cesium.Color.BLACK,
          outlineWidth: 3,
          style: Cesium.LabelStyle.FILL_AND_OUTLINE,
          disableDepthTestDistance: Number.POSITIVE_INFINITY,
        });
        this.entities.set(id, entity);
      });
      this.updateHighlight();
      if (source.entities.values.length) this.viewer.zoomTo(source);
    });
  },

  flyTo(id) {
    const block = this.filtered().find((item) => blockId(item) === String(id));
    if (!block) return;
    AirspaceMap.flyToBlock(this.viewer, block);
    this.popupAnchor = null;
    this.els.popup.hidden = true;
  },

  positionPopup(screenPosition) {
    const stage = document.querySelector(".stage");
    const rect = stage.getBoundingClientRect();
    const popupWidth = 250;
    const popupHeight = 330;
    let left = screenPosition.x - popupWidth / 2;
    let top = screenPosition.y - popupHeight - 18;
    if (left < 10) left = 10;
    if (left + popupWidth > rect.width - 10) left = rect.width - popupWidth - 10;
    if (top < 10) top = screenPosition.y + 18;
    if (top + popupHeight > rect.height - 10) top = rect.height - popupHeight - 10;
    if (top < 10) top = 10;
    this.els.popup.style.left = `${left}px`;
    this.els.popup.style.top = `${top}px`;
    this.els.popup.style.setProperty("--arrow-left", `${screenPosition.x - left}px`);
    this.els.popup.style.right = "auto";
    this.els.popup.style.bottom = "auto";
  },

  updatePopupPosition() {
    if (!this.popupAnchor || this.els.popup.hidden || !this.viewer) return;
    const screenPosition = Cesium.SceneTransforms.wgs84ToWindowCoordinates(
      this.viewer.scene,
      this.popupAnchor,
    );
    if (!screenPosition) {
      this.els.popup.hidden = true;
      return;
    }
    this.positionPopup(screenPosition);
  },

  showPopup(block) {
    const geometry = block.geom?.geometry;
    const pointCount = AirspaceMap.ring(block).length;
    this.els.popupTitle.textContent = "空域区块详情";
    this.els.popupContent.innerHTML = `
      <div class="popup-block">
        <strong>${block.airspace_name}</strong>
        <p>区块ID：${blockId(block)}</p>
        <p>项目ID：${block.project_id || "-"}</p>
        <p>空域编号：${block.airspace_code}</p>
        <p>空域名称：${block.airspace_name}</p>
        <p>空域类型：${blockTypeText(block.airspace_type)}</p>
        <p>空域高度：${block.airspace_height || 0} 米</p>
        <p>缓冲半径：${block.airspace_radius || 0} 米</p>
        <p>面积：${Number(block.airspace_area || 0).toFixed(2)} 平方千米</p>
        <p>周长：${Number(block.airspace_perimeter || 0).toFixed(2)} 千米</p>
        <p>启用状态：${blockEnabledText(block.use_enabled)}</p>
        <p>空间类型：${geometry?.type || "-"}</p>
        <p>坐标点数：${pointCount}</p>
      </div>`;
    this.popupAnchor = AirspaceMap.center(block, 120);
    this.els.popup.hidden = false;
    this.updatePopupPosition();
  },
};

