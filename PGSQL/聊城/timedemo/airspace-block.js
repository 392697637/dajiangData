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
  };
}

function blockColor(state) {
  const colors = {
    CONTROL: Cesium.Color.fromCssColorString("rgba(24, 169, 255, 0.58)"),
    MONITOR: Cesium.Color.fromCssColorString("rgba(155, 125, 255, 0.56)"),
    REPORT: Cesium.Color.fromCssColorString("rgba(255, 86, 168, 0.56)"),
  };
  return colors[state] || Cesium.Color.YELLOW.withAlpha(0.5);
}

window.AirspaceBlockPage = {
  viewer: null,
  source: null,
  blocks: [],
  entities: new Map(),
  popupAnchor: null,
  popupListener: null,
  pageNo: 1,
  pageSize: 6,

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
    if (this.viewer && this.popupListener) {
      this.viewer.scene.postRender.removeEventListener(this.popupListener);
    }
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
    const totalPages = Math.max(1, Math.ceil(blocks.length / this.pageSize));
    if (this.pageNo > totalPages) this.pageNo = totalPages;
    const start = (this.pageNo - 1) * this.pageSize;
    const pageBlocks = blocks.slice(start, start + this.pageSize);
    this.els.count.textContent = `${blocks.length} 个区块`;
    this.els.list.innerHTML = pageBlocks.map((block) => `
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
    this.renderPager(blocks.length, totalPages);
    this.draw(blocks);
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
    const popupHeight = 172;
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
    this.els.popupTitle.textContent = "空域区块详情";
    this.els.popupContent.innerHTML = `
      <div class="popup-block">
        <strong>${block.airspace_name}</strong>
        <p>空域编号：${block.airspace_code}</p>
        <p>空域类型：${AIRSPACE_TYPES[block.airspace_type]}</p>
        <p>默认状态：${AIRSPACE_STATES[block.airspace_state]}</p>
        <p>关联计划：${block.plans.length} 条</p>
      </div>`;
    this.popupAnchor = AirspaceMap.center(block, 120);
    this.els.popup.hidden = false;
    this.updatePopupPosition();
  },
};

