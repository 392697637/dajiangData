const AIRSPACE_TYPES = { CONTROL: "管制空域", MONITOR: "监视空域", REPORT: "报告空域" };
const AIRSPACE_STATES = { CONTROL: "管制状态", MONITOR: "监控状态", REPORT: "报警状态" };

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
    modal: document.querySelector("#blockFormModal"),
    formTitle: document.querySelector("#blockFormTitle"),
    formClose: document.querySelector("#blockFormClose"),
    formCancel: document.querySelector("#blockFormCancel"),
    formSave: document.querySelector("#blockFormSave"),
    formCode: document.querySelector("#formAirspaceCode"),
    formName: document.querySelector("#formAirspaceName"),
    formType: document.querySelector("#formAirspaceType"),
    formState: document.querySelector("#formAirspaceState"),
    formUnitName: document.querySelector("#formUnitName"),
    formUnitId: document.querySelector("#formUnitId"),
    formArea: document.querySelector("#formAirspaceArea"),
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

  init(data) {
    this.blocks = data.data;
    this.els = blockEls();
    this.els.popup.hidden = true;
    this.els.popupTitle.textContent = "空域区块详情";
    this.viewer = AirspaceMap.createViewer();
    this.bind();
    this.bindForm();
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
      const block = this.filtered().find((item) => String(item.block_id) === id);
      if (block) this.showPopup(block, event.position);
    };
    this.viewer.screenSpaceEventHandler.setInputAction(this.clickHandler, Cesium.ScreenSpaceEventType.LEFT_CLICK);
    this.popupListener = () => this.updatePopupPosition();
    this.viewer.scene.postRender.addEventListener(this.popupListener);
  },

  bindForm() {
    this.els.add.onclick = () => this.openForm();
    this.els.formClose.onclick = () => this.closeForm();
    this.els.formCancel.onclick = () => this.closeForm();
    this.els.formSave.onclick = () => this.saveForm();
    this.els.draw.onclick = () => this.startDraw();
    this.els.clearDraw.onclick = () => this.clearDraft();
  },

  filtered() {
    const els = this.els;
    const code = els.code.value.trim().toLowerCase();
    const name = els.name.value.trim().toLowerCase();
    return this.blocks.filter((block) =>
      (!code || block.airspace_code.toLowerCase().includes(code)) &&
      (!name || block.airspace_name.toLowerCase().includes(name)) &&
      (!els.type.value || block.airspace_type === els.type.value) &&
      (!els.state.value || block.airspace_state === els.state.value)
    );
  },

  render() {
    const blocks = this.filtered();
    this.renderList();
    this.draw(blocks);
  },

  openForm(id) {
    const block = id
      ? this.blocks.find((item) => String(item.block_id) === String(id))
      : null;
    this.editingId = block ? block.block_id : null;
    this.els.formTitle.textContent = block ? "编辑空域区块" : "新增空域区块";
    this.els.formCode.value = block?.airspace_code || "";
    this.els.formName.value = block?.airspace_name || "";
    this.els.formType.value = block?.airspace_type || "CONTROL";
    this.els.formState.value = block?.airspace_state || "CONTROL";
    this.els.formUnitName.value = block?.unit_name || "";
    this.els.formUnitId.value = block?.unit_id || "";
    this.els.formArea.value = block?.airspace_area || "";
    this.draftGeom = block ? structuredClone(block.geom) : null;
    this.showDraft();
    this.setDrawTip(block ? "可重新绘制，也可直接保存原面" : "点击绘制面后，左键取点，右键结束");
    this.els.modal.hidden = false;
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
      const block = this.blocks.find((item) => item.block_id === this.editingId);
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

  applyForm(block) {
    block.airspace_code = this.els.formCode.value.trim();
    block.airspace_name = this.els.formName.value.trim();
    block.airspace_type = this.els.formType.value;
    block.airspace_state = this.els.formState.value;
    block.unit_name = this.els.formUnitName.value.trim();
    block.unit_id = this.els.formUnitId.value.trim();
    block.airspace_area = Number(this.els.formArea.value || 0);
    if (this.draftGeom) block.geom = structuredClone(this.draftGeom);
  },

  startDraw() {
    this.stopDraw();
    this.clearDraft();
    this.draftPositions = [];
    this.setDrawTip("正在绘制：左键取点，右键结束");
    this.drawHandler = new Cesium.ScreenSpaceEventHandler(this.viewer.scene.canvas);
    this.drawHandler.setInputAction((event) => {
      const coordinate = this.pickLonLat(event.position);
      if (!coordinate) return;
      this.draftPositions.push(coordinate);
      this.showDraft();
      this.setDrawTip(`已取 ${this.draftPositions.length} 个点，至少 3 个点后右键结束`);
    }, Cesium.ScreenSpaceEventType.LEFT_CLICK);
    this.drawHandler.setInputAction(() => this.finishDraw(), Cesium.ScreenSpaceEventType.RIGHT_CLICK);
    this.drawHandler.setInputAction(() => this.finishDraw(), Cesium.ScreenSpaceEventType.LEFT_DOUBLE_CLICK);
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
    this.setDrawTip("已清空绘制，可重新绘制");
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
    const ring = this.draftGeom?.geometry?.coordinates?.[0] || this.draftPositions;
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
    const maxId = this.blocks.reduce((max, item) => Math.max(max, Number(item.block_id)), 0);
    const id = maxId + 1;
    const offset = (id % 8) * 0.015;
    return {
      block_id: id,
      outid: `AS-DEMO-${String(id).padStart(3, "0")}`,
      unit_id: "",
      unit_name: "",
      airspace_code: "",
      airspace_name: "",
      airspace_type: "CONTROL",
      airspace_state: "CONTROL",
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
    this.blocks = this.blocks.filter((item) => String(item.block_id) !== String(id));
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
    const totalPages = Math.max(1, Math.ceil(blocks.length / this.pageSize));
    if (this.pageNo > totalPages) this.pageNo = totalPages;
    const start = (this.pageNo - 1) * this.pageSize;
    const pageBlocks = blocks.slice(start, start + this.pageSize);
    this.els.count.textContent = `${blocks.length} 个区块`;
    this.els.list.innerHTML = pageBlocks.map((block) => `
      <div class="block-row" data-id="${block.block_id}">
        <i class="status-dot control"></i>
        <div>
          <div class="block-title">${block.airspace_code} · ${block.airspace_name}</div>
          <div class="block-meta">${block.unit_name || "未设置单位"} · ${block.airspace_area} 平方公里</div>
        </div>
        <div class="block-row-actions">
          <button class="secondary" data-action="edit" data-id="${block.block_id}" type="button">编辑</button>
          <button class="secondary" data-action="delete" data-id="${block.block_id}" type="button">删除</button>
        </div>
      </div>`).join("");
    this.els.list.querySelectorAll("[data-id]").forEach((row) => {
      if (row.dataset.action) return;
      row.addEventListener("click", () => this.flyTo(row.dataset.id));
    });
    this.els.list.querySelectorAll("[data-action='edit']").forEach((button) => {
      button.addEventListener("click", (event) => {
        event.stopPropagation();
        this.openForm(button.dataset.id);
      });
    });
    this.els.list.querySelectorAll("[data-action='delete']").forEach((button) => {
      button.addEventListener("click", (event) => {
        event.stopPropagation();
        this.deleteBlock(button.dataset.id);
      });
    });
    this.renderPager(blocks.length, totalPages);
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
      features: blocks.map((block) => ({
        type: "Feature",
        properties: { blockId: block.block_id, code: block.airspace_code, state: block.airspace_state },
        geometry: block.geom.geometry,
      })),
    };
    Cesium.GeoJsonDataSource.load(featureCollection, { stroke: Cesium.Color.WHITE, fill: Cesium.Color.YELLOW.withAlpha(0.5), strokeWidth: 4 }).then((source) => {
      if (this.source) this.viewer.dataSources.remove(this.source, true);
      this.source = source;
      this.entities.clear();
      this.viewer.dataSources.add(source);
      source.entities.values.forEach((entity) => {
        const id = String(entity.properties.blockId.getValue());
        const code = entity.properties.code.getValue();
        const state = entity.properties.state.getValue();
        const block = blocks.find((item) => String(item.block_id) === id);
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
      if (source.entities.values.length) this.viewer.zoomTo(source);
    });
  },

  flyTo(id) {
    const block = this.filtered().find((item) => String(item.block_id) === String(id));
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
    const pointCount = geometry?.coordinates?.[0]?.length || 0;
    this.els.popupTitle.textContent = "空域区块详情";
    this.els.popupContent.innerHTML = `
      <div class="popup-block">
        <strong>${block.airspace_name}</strong>
        <p>区块ID：${block.block_id}</p>
        <p>第三方ID：${block.outid}</p>
        <p>空域编号：${block.airspace_code}</p>
        <p>空域名称：${block.airspace_name}</p>
        <p>所属单位：${block.unit_name}</p>
        <p>单位ID：${block.unit_id}</p>
        <p>面积：${block.airspace_area} 平方公里</p>
        <p>空间类型：${geometry?.type || "-"}</p>
        <p>坐标点数：${pointCount}</p>
      </div>`;
    this.popupAnchor = AirspaceMap.center(block, 120);
    this.els.popup.hidden = false;
    this.updatePopupPosition();
  },
};

