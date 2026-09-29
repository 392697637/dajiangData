const AIRSPACE_TYPES = { CONTROL: "管制空域", MONITOR: "监视空域", REPORT: "报告空域" };
const AIRSPACE_STATES = { CONTROL: "管控", MONITOR: "监视", REPORT: "报告" };

function blockEls() {
  return {
    type: document.querySelector("#airspaceType"),
    code: document.querySelector("#airspaceCode"),
    name: document.querySelector("#airspaceName"),
    state: document.querySelector("#airspaceState"),
    list: document.querySelector("#blockList"),
    count: document.querySelector("#resultCount"),
    popup: document.querySelector(".plan-popup"),
    popupTitle: document.querySelector("#popupTitle"),
    popupContent: document.querySelector("#popupContent"),
    popupClose: document.querySelector("#popupClose"),
  };
}

function blockColor(state) {
  const colors = {
    CONTROL: Cesium.Color.RED.withAlpha(0.56),
    MONITOR: Cesium.Color.CYAN.withAlpha(0.46),
    REPORT: Cesium.Color.LIME.withAlpha(0.42),
  };
  return colors[state] || Cesium.Color.YELLOW.withAlpha(0.5);
}

window.AirspaceBlockPage = {
  viewer: null,
  source: null,
  blocks: [],
  entities: new Map(),

  init(data) {
    this.blocks = data.data.blocks;
    this.els = blockEls();
    this.els.popup.hidden = true;
    this.els.popupTitle.textContent = "空域区块详情";
    this.viewer = AirspaceMap.createViewer();
    this.bind();
    this.render();
  },

  destroy() {
    AirspaceMap.destroyViewer(this.viewer);
    this.viewer = null;
    this.source = null;
    this.entities.clear();
  },

  bind() {
    this.clickHandler = (event) => {
      const picked = this.viewer.scene.pick(event.position);
      if (!Cesium.defined(picked) || !picked.id?.properties?.blockId) return;
      const id = String(picked.id.properties.blockId.getValue());
      const block = this.filtered().find((item) => String(item.block_id) === id);
      if (block) this.showPopup(block);
    };
    this.viewer.screenSpaceEventHandler.setInputAction(this.clickHandler, Cesium.ScreenSpaceEventType.LEFT_CLICK);
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
    this.els.count.textContent = `${blocks.length} 个区块`;
    this.els.list.innerHTML = blocks.map((block) => `
      <div class="block-row" data-id="${block.block_id}">
        <i class="status-dot ${block.airspace_state.toLowerCase()}"></i>
        <div>
          <div class="block-title">${block.airspace_code} · ${block.airspace_name}</div>
          <div class="block-meta">${AIRSPACE_TYPES[block.airspace_type]} · ${AIRSPACE_STATES[block.airspace_state]}</div>
        </div>
        <span class="status-label ${block.airspace_state.toLowerCase()}">${AIRSPACE_STATES[block.airspace_state]}</span>
      </div>`).join("");
    this.els.list.querySelectorAll("[data-id]").forEach((row) => {
      row.addEventListener("click", () => this.flyTo(row.dataset.id));
    });
    this.draw(blocks);
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
        entity.position = AirspaceMap.center(block);
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
    this.els.popup.hidden = true;
  },

  showPopup(block) {
    this.els.popupTitle.textContent = "空域区块详情";
    this.els.popupContent.innerHTML = `
      <div class="popup-block">
        <strong>${block.airspace_name}</strong>
        <p>空域编号：${block.airspace_code}</p>
        <p>空域类型：${AIRSPACE_TYPES[block.airspace_type]}</p>
        <p>默认状态：${AIRSPACE_STATES[block.airspace_state]}</p>
        <p>关联计划：${block.plans.length} 条</p>
      </div>`;
    this.els.popup.hidden = false;
  },
};

