const PLAN_TYPES = { CONTROL: "管制空域", MONITOR: "监视空域", REPORT: "报告空域" };
const PLAN_STATES = { CONTROL: "管制状态", MONITOR: "监控状态", REPORT: "报警状态" };
const PLAN_STATUS = { ACTIVE: "当前生效", APPLIED: "已申请", DISABLED: "不可用", NOT_APPLIED: "未申请" };

function planEls() {
  return {
    date: document.querySelector("#useDate"),
    type: document.querySelector("#airspaceType"),
    code: document.querySelector("#airspaceCode"),
    name: document.querySelector("#airspaceName"),
    state: document.querySelector("#airspaceState"),
    list: document.querySelector("#blockList"),
    pager: document.querySelector("#blockPager"),
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
    modal: document.querySelector("#planFormModal"),
    formTitle: document.querySelector("#planFormTitle"),
    formClose: document.querySelector("#planFormClose"),
    formCancel: document.querySelector("#planFormCancel"),
    formSave: document.querySelector("#planFormSave"),
    formBlock: document.querySelector("#formPlanBlock"),
    formDate: document.querySelector("#formPlanDate"),
    formStart: document.querySelector("#formPlanStart"),
    formEnd: document.querySelector("#formPlanEnd"),
    formMinHeight: document.querySelector("#formPlanMinHeight"),
    formMaxHeight: document.querySelector("#formPlanMaxHeight"),
    formBufferHeight: document.querySelector("#formPlanBufferHeight"),
    formStatus: document.querySelector("#formPlanStatus"),
    formRemark: document.querySelector("#formPlanRemark"),
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
  const colors = {
    ACTIVE: Cesium.Color.RED.withAlpha(0.55),
    APPLIED: Cesium.Color.GOLD.withAlpha(0.45),
    DISABLED: Cesium.Color.MEDIUMPURPLE.withAlpha(0.45),
    NOT_APPLIED: Cesium.Color.GRAY.withAlpha(0.28),
    CONTROL: Cesium.Color.fromCssColorString("rgba(24, 169, 255, 0.58)"),
    MONITOR: Cesium.Color.fromCssColorString("rgba(155, 125, 255, 0.56)"),
    REPORT: Cesium.Color.fromCssColorString("rgba(255, 86, 168, 0.56)"),
  };
  return colors[status] || Cesium.Color.YELLOW.withAlpha(0.5);
}

function planHeightRange(block, isActiveSegment) {
  const usablePlans = block.plans.filter((plan) => plan.plan_status === "1");
  const activePlan = usablePlans.find((plan) =>
    plan.time_plan.some((segment) => isActiveSegment(segment)),
  );
  if (!activePlan) return null;
  const minHeight = Number(activePlan.min_height || 0);
  const maxHeight = Number(activePlan.max_height || 0);
  const bufferHeight = Number(activePlan.buffer_height || 0);
  return {
    minHeight,
    maxHeight,
    bufferHeight,
    fenceHeight: Math.max(maxHeight + bufferHeight, minHeight + 30),
  };
}

window.AirspacePlanPage = {
  viewer: null,
  source: null,
  blocks: [],
  entities: new Map(),
  entityStates: new Map(),
  currentBlocks: [],
  seconds: 0,
  timer: null,
  playing: false,
  pageNo: 1,
  pageSize: 6,
  editingPlan: null,

  init(blockData, planData) {
    const planMap = new Map(
      planData.data.plans.map((item) => [String(item.block_id), item.plans || []]),
    );
    this.blocks = blockData.data.map((block) => ({
      ...block,
      plans: planMap.get(String(block.block_id)) || [],
    }));
    this.els = planEls();
    this.els.date.value = planToday();
    this.seconds = planNowSecond();
    this.els.slider.value = this.seconds;
    this.els.popup.hidden = true;
    this.els.popupTitle.textContent = "用空计划详情";
    this.els.popup.style.left = "10px";
    this.els.popup.style.top = "10px";
    this.els.popup.style.right = "auto";
    this.els.popup.style.bottom = "auto";
    this.els.popup.style.removeProperty("--arrow-left");
    this.viewer = AirspaceMap.createViewer();
    this.bindForm();
    this.bindMap();
    this.render();
    this.startPlay();
  },

  bindForm() {
    this.els.formClose.onclick = () => this.closePlanForm();
    this.els.formCancel.onclick = () => this.closePlanForm();
    this.els.formSave.onclick = () => this.savePlanForm();
  },

  destroy() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    this.playing = false;
    AirspaceMap.destroyViewer(this.viewer);
    this.viewer = null;
    this.source = null;
    this.entities.clear();
    this.entityStates.clear();
    this.currentBlocks = [];
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
    const totalPages = Math.max(1, Math.ceil(blocks.length / this.pageSize));
    if (this.pageNo > totalPages) this.pageNo = totalPages;
    const start = (this.pageNo - 1) * this.pageSize;
    const pageBlocks = blocks.slice(start, start + this.pageSize);
    this.els.count.textContent = `${blocks.length} 个区块`;
    this.els.time.textContent = planTimeText(this.seconds);
    this.els.clock.textContent = planTimeText(this.seconds);
    this.els.dateText.textContent = this.els.date.value;
    const active = blocks.filter((b) => this.status(b) === "ACTIVE").length;
    const applied = blocks.filter((b) => this.status(b) === "APPLIED").length;
    const none = blocks.filter((b) => this.status(b) === "NOT_APPLIED").length;
    this.els.note.textContent = `当前 ${planTimeText(this.seconds)}：${active} 个生效，${applied} 个已申请未生效，${none} 个当天未申请。`;
    this.els.list.innerHTML = pageBlocks.map((block) => {
      const state = block.airspace_state;
      return `<div class="block-row" data-id="${block.block_id}"><i class="status-dot ${state.toLowerCase()}"></i><div><div class="block-title">${block.airspace_code} · ${block.airspace_name}</div><div class="block-meta">${PLAN_TYPES[block.airspace_type]} · ${block.plans.length} 条当天计划</div></div><div class="block-row-actions"><span class="status-label ${state.toLowerCase()}">${PLAN_STATES[state]}</span><button class="secondary" data-action="add-plan" data-id="${block.block_id}" type="button">新增</button></div></div>`;
    }).join("");
    this.els.list.querySelectorAll("[data-id]").forEach((row) => row.addEventListener("click", () => this.showBlock(row.dataset.id)));
    this.bindPlanRowActions();
    this.renderPager(blocks.length, totalPages);
    this.renderTimeline(blocks);
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
      this.renderListOnly();
    });
    this.els.pager.querySelector("[data-page-action='next']").addEventListener("click", () => {
      if (this.pageNo >= totalPages) return;
      this.pageNo += 1;
      this.renderListOnly();
    });
  },

  renderListOnly() {
    const blocks = this.filtered();
    const totalPages = Math.max(1, Math.ceil(blocks.length / this.pageSize));
    if (this.pageNo > totalPages) this.pageNo = totalPages;
    const start = (this.pageNo - 1) * this.pageSize;
    const pageBlocks = blocks.slice(start, start + this.pageSize);
    this.els.list.innerHTML = pageBlocks.map((block) => {
      const state = block.airspace_state;
      return `<div class="block-row" data-id="${block.block_id}"><i class="status-dot ${state.toLowerCase()}"></i><div><div class="block-title">${block.airspace_code} · ${block.airspace_name}</div><div class="block-meta">${PLAN_TYPES[block.airspace_type]} · ${block.plans.length} 条当天计划</div></div><div class="block-row-actions"><span class="status-label ${state.toLowerCase()}">${PLAN_STATES[state]}</span><button class="secondary" data-action="add-plan" data-id="${block.block_id}" type="button">新增</button></div></div>`;
    }).join("");
    this.els.list.querySelectorAll("[data-id]").forEach((row) => row.addEventListener("click", () => this.showBlock(row.dataset.id)));
    this.bindPlanRowActions();
    this.renderPager(blocks.length, totalPages);
  },

  openPlanForm(blockId, editFirst = false) {
    const block = blockId
      ? this.blocks.find((item) => String(item.block_id) === String(blockId))
      : this.filtered()[0] || this.blocks[0];
    if (!block) return;
    const plan = editFirst
      ? block.plans.find((item) => item.use_date === this.els.date.value) || null
      : null;
    this.editingPlan = plan ? { blockId: block.block_id, planId: plan.plan_id } : null;
    this.els.formTitle.textContent = plan ? "编辑用空计划" : "新增用空计划";
    this.els.formBlock.innerHTML = this.blocks
      .map((item) => `<option value="${item.block_id}">${item.airspace_code} · ${item.airspace_name}</option>`)
      .join("");
    this.els.formBlock.value = String(block.block_id);
    this.els.formDate.value = plan?.use_date || this.els.date.value;
    this.els.formStart.value = plan?.time_plan?.[0]?.start_time || "09:00:00";
    this.els.formEnd.value = plan?.time_plan?.[0]?.end_time || "10:00:00";
    this.els.formMinHeight.value = plan?.min_height ?? 0;
    this.els.formMaxHeight.value = plan?.max_height ?? 120;
    this.els.formBufferHeight.value = plan?.buffer_height ?? 10;
    this.els.formStatus.value = plan?.plan_status || "1";
    this.els.formRemark.value = plan?.remark || "";
    this.els.modal.hidden = false;
  },

  openPlanFormById(blockId, planId) {
    const block = this.blocks.find((item) => String(item.block_id) === String(blockId));
    if (!block) return;
    const plan = block.plans.find((item) => String(item.plan_id) === String(planId));
    if (!plan) return;
    this.editingPlan = { blockId: block.block_id, planId: plan.plan_id };
    this.els.formTitle.textContent = "编辑用空计划";
    this.els.formBlock.innerHTML = this.blocks
      .map((item) => `<option value="${item.block_id}">${item.airspace_code} · ${item.airspace_name}</option>`)
      .join("");
    this.els.formBlock.value = String(block.block_id);
    this.els.formDate.value = plan.use_date;
    this.els.formStart.value = plan.time_plan?.[0]?.start_time || "09:00:00";
    this.els.formEnd.value = plan.time_plan?.[0]?.end_time || "10:00:00";
    this.els.formMinHeight.value = plan.min_height ?? 0;
    this.els.formMaxHeight.value = plan.max_height ?? 120;
    this.els.formBufferHeight.value = plan.buffer_height ?? 10;
    this.els.formStatus.value = plan.plan_status || "1";
    this.els.formRemark.value = plan.remark || "";
    this.els.modal.hidden = false;
  },

  closePlanForm() {
    this.editingPlan = null;
    this.els.modal.hidden = true;
  },

  savePlanForm() {
    const block = this.blocks.find((item) => String(item.block_id) === String(this.els.formBlock.value));
    if (!block) return;
    let plan = null;
    if (this.editingPlan) {
      const oldBlock = this.blocks.find((item) => String(item.block_id) === String(this.editingPlan.blockId));
      plan = oldBlock?.plans.find((item) => String(item.plan_id) === String(this.editingPlan.planId));
      if (oldBlock && oldBlock !== block && plan) {
        oldBlock.plans = oldBlock.plans.filter((item) => String(item.plan_id) !== String(plan.plan_id));
        block.plans.push(plan);
      }
    }
    if (!plan) {
      plan = {
        plan_id: this.nextPlanId(),
        plan_outid: `PLAN-DEMO-${Date.now()}`,
      };
      block.plans.push(plan);
    }
    plan.use_date = this.els.formDate.value;
    plan.time_plan = [{
      start_time: this.els.formStart.value,
      end_time: this.els.formEnd.value,
    }];
    plan.min_height = Number(this.els.formMinHeight.value || 0);
    plan.max_height = Number(this.els.formMaxHeight.value || 0);
    plan.buffer_height = Number(this.els.formBufferHeight.value || 0);
    plan.plan_status = this.els.formStatus.value;
    plan.remark = this.els.formRemark.value.trim();
    this.closePlanForm();
    this.pageNo = 1;
    this.render();
  },

  nextPlanId() {
    return this.blocks.reduce(
      (max, block) => Math.max(max, ...block.plans.map((plan) => Number(plan.plan_id) || 0)),
      0,
    ) + 1;
  },

  deletePlan(blockId) {
    const block = this.blocks.find((item) => String(item.block_id) === String(blockId));
    if (!block) return;
    const plan = block.plans.find((item) => item.use_date === this.els.date.value);
    if (!plan) return;
    block.plans = block.plans.filter((item) => String(item.plan_id) !== String(plan.plan_id));
    this.render();
  },

  deletePlanById(blockId, planId) {
    const block = this.blocks.find((item) => String(item.block_id) === String(blockId));
    if (!block) return;
    block.plans = block.plans.filter((item) => String(item.plan_id) !== String(planId));
    this.els.popup.hidden = true;
    this.render();
  },

  bindPlanRowActions() {
    this.els.list.querySelectorAll("[data-action='add-plan']").forEach((button) => {
      button.addEventListener("click", (event) => {
        event.stopPropagation();
        this.openPlanForm(button.dataset.id);
      });
    });
  },

  draw(blocks) {
    this.currentBlocks = blocks;
    const featureCollection = { type: "FeatureCollection", features: blocks.map((block) => ({ type: "Feature", properties: { blockId: block.block_id, code: block.airspace_code, status: block.airspace_state }, geometry: block.geom.geometry })) };
    Cesium.GeoJsonDataSource.load(featureCollection, { stroke: Cesium.Color.WHITE, fill: Cesium.Color.YELLOW.withAlpha(0.5), strokeWidth: 4 }).then((source) => {
      if (this.source) this.viewer.dataSources.remove(this.source, true);
      this.source = source;
      this.entities.clear();
      this.entityStates.clear();
      this.viewer.dataSources.add(source);
      source.entities.values.forEach((entity) => {
        const id = String(entity.properties.blockId.getValue());
        const code = entity.properties.code.getValue();
        const status = entity.properties.status.getValue();
        const block = blocks.find((item) => String(item.block_id) === id);
        entity.polygon.material = planColor(status);
        entity.polygon.outline = true;
        entity.polygon.outlineColor = Cesium.Color.WHITE;
        entity.label = new Cesium.LabelGraphics({ text: code, font: "14px Microsoft YaHei", fillColor: Cesium.Color.WHITE, outlineColor: Cesium.Color.BLACK, outlineWidth: 3, style: Cesium.LabelStyle.FILL_AND_OUTLINE, disableDepthTestDistance: Number.POSITIVE_INFINITY });
        this.entities.set(id, entity);
      });
      this.updatePlaybackState();
      if (source.entities.values.length) this.viewer.zoomTo(source);
    });
  },

  updatePlaybackState() {
    const blocks = this.currentBlocks.length ? this.currentBlocks : this.filtered();
    const active = blocks.filter((b) => this.status(b) === "ACTIVE").length;
    const applied = blocks.filter((b) => this.status(b) === "APPLIED").length;
    const none = blocks.filter((b) => this.status(b) === "NOT_APPLIED").length;
    this.els.time.textContent = planTimeText(this.seconds);
    this.els.clock.textContent = planTimeText(this.seconds);
    this.els.dateText.textContent = this.els.date.value;
    this.els.note.textContent = `当前 ${planTimeText(this.seconds)}：${active} 个生效，${applied} 个已申请未生效，${none} 个当天未申请。`;
    blocks.forEach((block) => {
      const entity = this.entities.get(String(block.block_id));
      if (!entity) return;
      const heightRange = planHeightRange(block, (segment) => this.activeSegment(segment));
      const stateKey = heightRange
        ? `solid:${heightRange.minHeight}:${heightRange.fenceHeight}`
        : "flat";
      if (this.entityStates.get(String(block.block_id)) === stateKey) return;
      this.entityStates.set(String(block.block_id), stateKey);
      entity.show = true;
      if (heightRange) {
        entity.position = AirspaceMap.center(block, heightRange.fenceHeight + 80);
        entity.polygon.height = heightRange.minHeight;
        entity.polygon.extrudedHeight = heightRange.fenceHeight;
        entity.polygon.perPositionHeight = false;
      } else {
        entity.position = AirspaceMap.center(block, 80);
        entity.polygon.height = undefined;
        entity.polygon.extrudedHeight = undefined;
        entity.polygon.perPositionHeight = false;
      }
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
      return `<div class="popup-block"><strong>${block.airspace_name}</strong><p>空域编号：${block.airspace_code}</p><p>高度层：${plan.min_height}-${plan.max_height}m</p><p>可用时段：${time}</p><p>状态：${plan.plan_status === "1" ? "可用" : "不可用"}</p><p>缓冲高度：${plan.buffer_height}m</p><p>管控高度：${fenceHeight}m</p><div class="popup-actions"><button class="secondary" data-popup-action="edit-plan" data-block-id="${block.block_id}" data-plan-id="${plan.plan_id}" type="button">编辑</button><button class="secondary" data-popup-action="delete-plan" data-block-id="${block.block_id}" data-plan-id="${plan.plan_id}" type="button">删除</button></div></div>`;
    }).join("") : `<div class="popup-block"><strong>${block.airspace_name}</strong><p>空域编号：${block.airspace_code}</p><p>用空日期：${this.els.date.value}</p><p>当天未申请飞行计划</p></div>`;
    this.els.popupTitle.textContent = "用空计划详情";
    this.els.popupContent.innerHTML = planHtml;
    this.els.popupContent.querySelectorAll("[data-popup-action='edit-plan']").forEach((button) => {
      button.addEventListener("click", () => this.openPlanFormById(button.dataset.blockId, button.dataset.planId));
    });
    this.els.popupContent.querySelectorAll("[data-popup-action='delete-plan']").forEach((button) => {
      button.addEventListener("click", () => this.deletePlanById(button.dataset.blockId, button.dataset.planId));
    });
    this.els.popup.hidden = false;
  },

  setSeconds(value) {
    this.seconds = Math.max(0, Math.min(86399, Number(value)));
    this.els.slider.value = this.seconds;
    this.updatePlaybackState();
  },

  startPlay() {
    this.playing = true;
    this.els.play.textContent = "暂停";
    if (this.timer) clearInterval(this.timer);
    this.timer = setInterval(() => this.setSeconds(this.seconds + 1 >= 86400 ? 0 : this.seconds + 1), 1000);
  },

  togglePlay() {
    this.playing = !this.playing;
    this.els.play.textContent = this.playing ? "暂停" : "播放";
    if (this.timer) clearInterval(this.timer);
    if (this.playing) this.timer = setInterval(() => this.setSeconds(this.seconds + 1 >= 86400 ? 0 : this.seconds + 1), 1000);
  },
};

