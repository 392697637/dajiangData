const PLAN_TYPES = { CONTROL: "管制空域", MONITOR: "监视空域", REPORT: "报告空域" };
const PLAN_STATES = { CONTROL: "管控", MONITOR: "监视", REPORT: "报告" };
const PLAN_STATUS = { ACTIVE: "当前生效", APPLIED: "已申请", DISABLED: "不可用", NOT_APPLIED: "未申请" };

function planEls() {
  return {
    date: document.querySelector("#useDate"),
    type: document.querySelector("#airspaceType"),
    code: document.querySelector("#airspaceCode"),
    name: document.querySelector("#airspaceName"),
    state: document.querySelector("#airspaceState"),
    list: document.querySelector("#blockList"),
    count: document.querySelector("#resultCount"),
    slider: document.querySelector("#timeSlider"),
    time: document.querySelector("#timelineTime"),
    clock: document.querySelector("#clockText"),
    dateText: document.querySelector("#dateText"),
    note: document.querySelector("#timelineNote"),
    segments: document.querySelector("#timelineSegments"),
    play: document.querySelector("#playBtn"),
    popup: document.querySelector(".plan-popup"),
    popupTitle: document.querySelector("#popupTitle"),
    popupContent: document.querySelector("#popupContent"),
  };
}

function planSeconds(value) {
  const parts = value.split(":").map(Number);
  return parts[0] * 3600 + parts[1] * 60 + (parts[2] || 0);
}
function planTimeText(total) {
  const seconds = ((total % 86400) + 86400) % 86400;
  return `${String(Math.floor(seconds / 3600)).padStart(2, "0")}:${String(Math.floor((seconds % 3600) / 60)).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
}
function planToday() {
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`;
}
function planNowSecond() {
  const now = new Date();
  return now.getHours() * 3600 + now.getMinutes() * 60 + now.getSeconds();
}
function planColor(status) {
  const colors = { ACTIVE: Cesium.Color.RED.withAlpha(0.55), APPLIED: Cesium.Color.GOLD.withAlpha(0.45), DISABLED: Cesium.Color.MEDIUMPURPLE.withAlpha(0.45), NOT_APPLIED: Cesium.Color.GRAY.withAlpha(0.28) };
  return colors[status] || Cesium.Color.YELLOW.withAlpha(0.5);
}

window.AirspacePlanPage = {
  viewer: null,
  source: null,
  blocks: [],
  entities: new Map(),
  seconds: 0,
  timer: null,
  playing: false,

  init(data) {
    this.blocks = data.data.blocks;
    this.els = planEls();
    this.els.date.value = planToday();
    this.seconds = planNowSecond();
    this.els.slider.value = this.seconds;
    this.els.popup.hidden = true;
    this.els.popupTitle.textContent = "用空计划详情";
    this.viewer = AirspaceMap.createViewer();
    this.bindMap();
    this.render();
  },

  destroy() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    this.playing = false;
    AirspaceMap.destroyViewer(this.viewer);
    this.viewer = null;
    this.source = null;
    this.entities.clear();
  },

  activeSegment(segment) {
    const start = planSeconds(segment.start_time);
    const end = planSeconds(segment.end_time);
    if (start === end) return true;
    return end > start ? this.seconds >= start && this.seconds < end : this.seconds >= start || this.seconds < end;
  },

  status(block) {
    if (!block.plans.length) return "NOT_APPLIED";
    let enabled = false;
    for (const plan of block.plans) {
      if (plan.plan_status !== "1") continue;
      enabled = true;
      if (plan.time_plan.some((segment) => this.activeSegment(segment))) return "ACTIVE";
    }
    return enabled ? "APPLIED" : "DISABLED";
  },

  filtered() {
    const els = this.els;
    const code = els.code.value.trim().toLowerCase();
    const name = els.name.value.trim().toLowerCase();
    return this.blocks.map((block) => ({ ...block, plans: block.plans.filter((plan) => plan.use_date === els.date.value) })).filter((block) =>
      (!code || block.airspace_code.toLowerCase().includes(code)) &&
      (!name || block.airspace_name.toLowerCase().includes(name)) &&
      (!els.type.value || block.airspace_type === els.type.value) &&
      (!els.state.value || block.airspace_state === els.state.value)
    );
  },

  render() {
    const blocks = this.filtered();
    this.els.count.textContent = `${blocks.length} 个区块`;
    this.els.time.textContent = planTimeText(this.seconds);
    this.els.clock.textContent = planTimeText(this.seconds);
    this.els.dateText.textContent = this.els.date.value;
    const active = blocks.filter((b) => this.status(b) === "ACTIVE").length;
    const applied = blocks.filter((b) => this.status(b) === "APPLIED").length;
    const none = blocks.filter((b) => this.status(b) === "NOT_APPLIED").length;
    this.els.note.textContent = `当前 ${planTimeText(this.seconds)}：${active} 个生效，${applied} 个已申请未生效，${none} 个当天未申请。`;
    this.els.list.innerHTML = blocks.map((block) => {
      const status = this.status(block);
      return `<div class="block-row" data-id="${block.block_id}"><i class="status-dot ${status.toLowerCase()}"></i><div><div class="block-title">${block.airspace_code} · ${block.airspace_name}</div><div class="block-meta">${PLAN_TYPES[block.airspace_type]} · ${block.plans.length} 条当天计划</div></div><span class="status-label ${status.toLowerCase()}">${PLAN_STATUS[status]}</span></div>`;
    }).join("");
    this.els.list.querySelectorAll("[data-id]").forEach((row) => row.addEventListener("click", () => this.showBlock(row.dataset.id)));
    this.renderTimeline(blocks);
    this.draw(blocks);
  },

  draw(blocks) {
    const featureCollection = { type: "FeatureCollection", features: blocks.map((block) => ({ type: "Feature", properties: { blockId: block.block_id, code: block.airspace_code, status: this.status(block) }, geometry: block.geom.geometry })) };
    Cesium.GeoJsonDataSource.load(featureCollection, { stroke: Cesium.Color.WHITE, fill: Cesium.Color.YELLOW.withAlpha(0.5), strokeWidth: 4 }).then((source) => {
      if (this.source) this.viewer.dataSources.remove(this.source, true);
      this.source = source;
      this.entities.clear();
      this.viewer.dataSources.add(source);
      source.entities.values.forEach((entity) => {
        const id = String(entity.properties.blockId.getValue());
        const code = entity.properties.code.getValue();
        const status = entity.properties.status.getValue();
        const block = blocks.find((item) => String(item.block_id) === id);
        entity.position = AirspaceMap.center(block);
        entity.polygon.material = planColor(status);
        entity.polygon.outline = true;
        entity.polygon.outlineColor = Cesium.Color.WHITE;
        entity.label = new Cesium.LabelGraphics({ text: code, font: "14px Microsoft YaHei", fillColor: Cesium.Color.WHITE, outlineColor: Cesium.Color.BLACK, outlineWidth: 3, style: Cesium.LabelStyle.FILL_AND_OUTLINE, disableDepthTestDistance: Number.POSITIVE_INFINITY });
        this.entities.set(id, entity);
      });
      if (source.entities.values.length) this.viewer.zoomTo(source);
    });
  },

  renderTimeline(blocks) {
    const segments = [];
    blocks.forEach((block) => block.plans.filter((p) => p.plan_status === "1").forEach((plan) => plan.time_plan.forEach((segment) => {
      const start = planSeconds(segment.start_time);
      const end = planSeconds(segment.end_time);
      if (end > start) segments.push({ start, end }); else { segments.push({ start, end: 86400 }); segments.push({ start: 0, end }); }
    })));
    this.els.segments.innerHTML = segments.map((s) => `<i class="segment" style="left:${s.start / 864}%;width:${(s.end - s.start) / 864}%"></i>`).join("");
  },

  bindMap() {
    this.viewer.screenSpaceEventHandler.setInputAction((event) => {
      const picked = this.viewer.scene.pick(event.position);
      if (!Cesium.defined(picked) || !picked.id?.properties?.blockId) return;
      this.showBlock(picked.id.properties.blockId.getValue());
    }, Cesium.ScreenSpaceEventType.LEFT_CLICK);
  },

  flyTo(block) {
    AirspaceMap.flyToBlock(this.viewer, block);
  },

  showBlock(id) {
    const block = this.filtered().find((item) => String(item.block_id) === String(id));
    if (!block) return;
    this.flyTo(block);
    const planHtml = block.plans.length ? block.plans.map((plan) => {
      const time = plan.time_plan.map((s) => `${s.start_time} - ${s.end_time}`).join("，");
      const fenceHeight = Number(plan.max_height || 0) + Number(plan.buffer_height || 0);
      return `<div class="popup-block"><strong>${block.airspace_name}</strong><p>空域编号：${block.airspace_code}</p><p>高度层：${plan.min_height}-${plan.max_height}m</p><p>可用时段：${time}</p><p>状态：${plan.plan_status === "1" ? "可用" : "不可用"}</p><p>缓冲高度：${plan.buffer_height}m</p><p>管控高度：${fenceHeight}m</p></div>`;
    }).join("") : `<div class="popup-block"><strong>${block.airspace_name}</strong><p>空域编号：${block.airspace_code}</p><p>用空日期：${this.els.date.value}</p><p>当天未申请飞行计划</p></div>`;
    this.els.popupTitle.textContent = "用空计划详情";
    this.els.popupContent.innerHTML = planHtml;
    this.els.popup.hidden = false;
  },

  setSeconds(value) {
    this.seconds = Math.max(0, Math.min(86399, Number(value)));
    this.els.slider.value = this.seconds;
    this.render();
  },

  togglePlay() {
    this.playing = !this.playing;
    this.els.play.textContent = this.playing ? "暂停" : "播放";
    if (this.timer) clearInterval(this.timer);
    if (this.playing) this.timer = setInterval(() => this.setSeconds(this.seconds + 1 >= 86400 ? 0 : this.seconds + 1), 1000);
  },
};

