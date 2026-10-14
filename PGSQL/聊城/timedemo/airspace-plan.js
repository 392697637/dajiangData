const PLAN_STATUS = { ACTIVE: "生效中", APPLIED: "有计划", DISABLED: "不可用", NOT_APPLIED: "无计划" };

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
    timeline: document.querySelector("#planTimelineWidget"),
    play: document.querySelector("#playBtn"),
    back: document.querySelector("#backBtn"),
    forward: document.querySelector("#forwardBtn"),
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
    formStatus: document.querySelector("#formPlanStatus"),
    formRemark: document.querySelector("#formPlanRemark"),
    flightTasks: document.querySelector("#flightTaskList"),
    involvedAirspaces: document.querySelector("#involvedAirspaceList"),
    taskAnalysis: document.querySelector("#taskAnalysis"),
  };
}

function planBlockId(block) {
  return String(block.id ?? block.block_id);
}

function planId(plan) {
  return String(plan.id ?? plan.plan_id);
}

function parsePlanStatus(value) {
  return value === false || value === "false" || value === 0 || value === "0" || value === "1";
}

function normalizeSegments(value) {
  const raw = typeof value === "string" ? JSON.parse(value || "[]") : value || [];
  return raw.map((item) => ({
    startTime: item.startTime || item.start_time || "00:00:00",
    endTime: item.endTime || item.end_time || "00:00:00",
  }));
}

function normalizePlan(plan) {
  return {
    ...plan,
    id: plan.id ?? plan.plan_id,
    block_id: String(plan.block_id),
    timeSegments: normalizeSegments(plan.time_plan),
  };
}

function secondsOf(value) {
  const parts = String(value || "00:00:00").split(":").map(Number);
  return (parts[0] || 0) * 3600 + (parts[1] || 0) * 60 + (parts[2] || 0);
}

function timeText(total) {
  const seconds = ((Number(total) % 86400) + 86400) % 86400;
  return `${String(Math.floor(seconds / 3600)).padStart(2, "0")}:${String(Math.floor((seconds % 3600) / 60)).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
}

function todayText() {
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`;
}

function nowSeconds() {
  const now = new Date();
  return now.getHours() * 3600 + now.getMinutes() * 60 + now.getSeconds();
}

function activeSegment(segment, seconds) {
  const start = secondsOf(segment.startTime);
  const end = secondsOf(segment.endTime);
  if (start === end) return true;
  return end > start ? seconds >= start && seconds < end : seconds >= start || seconds < end;
}

function planColor(status) {
  const colors = {
    ACTIVE: Cesium.Color.RED.withAlpha(0.55),
    APPLIED: Cesium.Color.GOLD.withAlpha(0.45),
    DISABLED: Cesium.Color.MEDIUMPURPLE.withAlpha(0.45),
    NOT_APPLIED: Cesium.Color.GRAY.withAlpha(0.28),
  };
  return colors[status] || Cesium.Color.YELLOW.withAlpha(0.5);
}

function planTableCode(block) {
  const tail = String(block.airspace_code || planBlockId(block)).match(/\d+$/)?.[0];
  return tail ? String(100 + Number(tail)) : (block.airspace_code || planBlockId(block));
}

function planTimeCell(block) {
  const segments = block.plans
    .filter((plan) => parsePlanStatus(plan.plan_status))
    .flatMap((plan) => plan.timeSegments);
  if (!segments.length) return "--";
  return segments.map((segment) => `<i>${segment.startTime.slice(0, 5)}-${segment.endTime.slice(0, 5)}</i>`).join("");
}

function planTimeText(block) {
  const segments = block.plans
    .filter((plan) => parsePlanStatus(plan.plan_status))
    .flatMap((plan) => plan.timeSegments);
  if (!segments.length) return "--";
  return segments.map((segment) => `${segment.startTime.slice(0, 5)}-${segment.endTime.slice(0, 5)}`).join(" ");
}

function statusBadge(status) {
  return ({ ACTIVE: "正常", APPLIED: "日常巡检", DISABLED: "取消", NOT_APPLIED: "暂无" })[status] || "正常";
}

function taskAnalysisHtml() {
  return `
    <div><span>当日计划任务</span><strong>10</strong></div>
    <div><span>可飞任务</span><strong>7</strong></div>
    <div class="cancel"><span>取消任务</span><strong>3</strong></div>
    <div class="rate"><span>可放飞率</span><strong>70%</strong></div>
  `;
}

window.AirspacePlanPage = {
  viewer: null,
  source: null,
  blocks: [],
  airspaces: [],
  entities: new Map(),
  currentBlocks: [],
  seconds: 0,
  timer: null,
  playing: false,
  editingPlan: null,

  init(blockData, planData, airspaceData) {
    this.airspaces = airspaceData?.data || [];
    const plans = Array.isArray(planData.data) ? planData.data : (planData.data?.plans || []);
    const flatPlans = plans.flatMap((item) => item.plans ? item.plans.map((plan) => ({ ...plan, block_id: item.block_id })) : [item]);
    const planMap = new Map();
    flatPlans.map(normalizePlan).forEach((plan) => {
      if (!planMap.has(plan.block_id)) planMap.set(plan.block_id, []);
      planMap.get(plan.block_id).push(plan);
    });
    this.blocks = blockData.data.map((block) => ({
      ...block,
      plans: planMap.get(planBlockId(block)) || [],
    }));
    this.els = planEls();
    this.els.date.value = todayText();
    this.seconds = nowSeconds();
    this.els.slider.value = this.seconds;
    this.updateTimelineMarker();
    this.els.popup.hidden = true;
    this.els.popupTitle.textContent = "用空计划详情";
    this.viewer = AirspaceMap.createViewer();
    this.bindForm();
    this.bindTimeline();
    this.bindMap();
    this.render();
    this.startPlay();
  },

  bindForm() {
    this.els.formClose.onclick = () => this.closePlanForm();
    this.els.formCancel.onclick = () => this.closePlanForm();
    this.els.formSave.onclick = () => this.savePlanForm();
  },

  bindTimeline() {
    if (this.els.slider) this.els.slider.oninput = (event) => this.setSeconds(event.target.value);
    if (this.els.back) this.els.back.onclick = () => this.setSeconds((this.seconds || 0) - 3600);
    if (this.els.forward) this.els.forward.onclick = () => this.setSeconds((this.seconds || 0) + 3600);
    if (this.els.play) this.els.play.onclick = () => this.togglePlay();
    this.timelineResizeHandler = () => this.updateTimelineMarker();
    window.addEventListener("resize", this.timelineResizeHandler);
  },

  destroy() {
    if (this.timer) clearInterval(this.timer);
    if (this.timelineResizeHandler) window.removeEventListener("resize", this.timelineResizeHandler);
    this.timer = null;
    this.playing = false;
    AirspaceMap.destroyViewer(this.viewer);
    this.viewer = null;
    this.source = null;
    this.entities.clear();
    this.currentBlocks = [];
  },

  status(block) {
    if (!block.plans.length) return "NOT_APPLIED";
    const usablePlans = block.plans.filter((plan) => parsePlanStatus(plan.plan_status));
    if (!usablePlans.length) return "DISABLED";
    return usablePlans.some((plan) => plan.timeSegments.some((segment) => activeSegment(segment, this.seconds)))
      ? "ACTIVE"
      : "APPLIED";
  },

  filtered() {
    const code = this.els.code.value.trim().toLowerCase();
    const name = this.els.name.value.trim().toLowerCase();
    return this.blocks
      .map((block) => ({ ...block, plans: block.plans.filter((plan) => plan.use_date === this.els.date.value) }))
      .filter((block) =>
        (!code || block.airspace_code.toLowerCase().includes(code)) &&
        (!name || block.airspace_name.toLowerCase().includes(name)) &&
        (!this.els.type.value || block.airspace_type === this.els.type.value) &&
        (!this.els.state.value || String(block.use_enabled) === this.els.state.value)
      );
  },

  render() {
    const blocks = this.filtered();
    this.currentBlocks = blocks;
    this.renderList(blocks);
    this.renderTimeline(blocks);
    this.renderSidePanels(blocks);
    this.draw(blocks);
    this.updatePlaybackState();
    this.renderTaskAnalysis();
  },

  renderList(blocks) {
    this.els.count.textContent = `${blocks.length} 个空域`;
    this.els.list.innerHTML = `
      <div class="plan-grid" role="table">
        <div class="plan-grid-head" role="row">
          <label class="plan-check"><input type="checkbox" id="planCheckAll" /></label>
          <strong>空域编号</strong>
          <strong>空域名称</strong>
          <strong>可飞时段</strong>
        </div>
        ${blocks.map((block) => `
          <div class="plan-grid-row ${this.status(block).toLowerCase()}" data-id="${planBlockId(block)}" role="row">
            <label class="plan-check"><input type="checkbox" data-plan-check="${planBlockId(block)}" /></label>
            <span>${planTableCode(block)}</span>
            <span>${block.airspace_name}</span>
            <span class="plan-time-cell">${planTimeCell(block)}</span>
          </div>
        `).join("")}
      </div>
    `;
    this.els.list.querySelectorAll(".plan-grid-row").forEach((row) => {
      row.addEventListener("click", (event) => {
        if (event.target.matches("input")) return;
        this.showBlock(row.dataset.id);
      });
    });
    this.els.list.querySelector("#planCheckAll")?.addEventListener("change", (event) => {
      this.els.list.querySelectorAll("[data-plan-check]").forEach((input) => {
        input.checked = event.target.checked;
      });
    });
    this.els.pager.innerHTML = "";
  },

  renderSidePanels(blocks) {
    if (!this.els.flightTasks || !this.els.involvedAirspaces || !this.els.taskAnalysis) return;
    const tasks = [
      { name: "小潘河A1段日常巡检", mode: "平台飞行", dept: "公安局", status: "正常", statusClass: "ok", time: "8:30-9:00; 14:00-14:30" },
      { name: "小潘河A1段日常巡检", mode: "自动飞行", dept: "环保局", status: "日常巡检", statusClass: "data", time: "8:30-9:00" },
      { name: "小潘河A1段日常巡检", mode: "自动飞行", dept: "环保局", status: "数据采集", statusClass: "data", time: "8:30-9:00" },
      { name: "小潘河A1段日常巡检", mode: "平台飞行", dept: "环保局", status: "取消", statusClass: "bad", time: "8:30-9:00" },
      { name: "小潘河A1段日常巡检", mode: "自动飞行", dept: "环保局", status: "日常巡检", statusClass: "data", time: "8:30-9:00" },
      { name: "小潘河A1段日常巡检", mode: "平台飞行", dept: "环保局", status: "数据采集", statusClass: "data", time: "8:30-9:00" },
    ];
    this.els.flightTasks.innerHTML = tasks.map((task) => {
      return `
        <div class="flight-task">
          <div>
            <strong>${task.name}</strong>
            <span>${task.mode}</span>
          </div>
          <p>
            <em class="tag env">${task.dept}</em>
            <em class="tag ${task.statusClass}">${task.status}</em>
            <time>${task.time}</time>
          </p>
        </div>
      `;
    }).join("");

    this.els.involvedAirspaces.innerHTML = `
      <div class="involved-head"><strong>空域编号</strong><strong>空域名称</strong></div>
      ${Array.from({ length: 9 }, (_, index) => `
        <div class="involved-row">
          <span>${101 + index}</span>
          <span>${index % 3 === 0 ? "这里是空域名称空域" : "这里是空域名称"}</span>
        </div>
      `).join("")}
    `;
    this.renderTaskAnalysis();
  },

  renderTaskAnalysis() {
    if (!this.els?.taskAnalysis) return;
    this.els.taskAnalysis.innerHTML = taskAnalysisHtml();
  },

  openPlanForm(blockId) {
    const block = blockId
      ? this.blocks.find((item) => planBlockId(item) === String(blockId))
      : this.filtered()[0] || this.blocks[0];
    if (!block) return;
    this.editingPlan = null;
    this.els.formTitle.textContent = "新增用空计划";
    this.els.formBlock.innerHTML = this.blocks.map((item) => `<option value="${planBlockId(item)}">${item.airspace_code} · ${item.airspace_name}</option>`).join("");
    this.els.formBlock.value = planBlockId(block);
    this.els.formDate.value = this.els.date.value;
    this.els.formStart.value = "09:00:00";
    this.els.formEnd.value = "10:00:00";
    this.els.formStatus.value = "false";
    this.els.formRemark.value = "";
    this.els.modal.hidden = false;
  },

  openPlanFormById(blockId, id) {
    const block = this.blocks.find((item) => planBlockId(item) === String(blockId));
    const plan = block?.plans.find((item) => planId(item) === String(id));
    if (!block || !plan) return;
    this.editingPlan = { blockId: planBlockId(block), planId: planId(plan) };
    this.els.formTitle.textContent = "编辑用空计划";
    this.els.formBlock.innerHTML = this.blocks.map((item) => `<option value="${planBlockId(item)}">${item.airspace_code} · ${item.airspace_name}</option>`).join("");
    this.els.formBlock.value = planBlockId(block);
    this.els.formDate.value = plan.use_date;
    this.els.formStart.value = plan.timeSegments[0]?.startTime || "09:00:00";
    this.els.formEnd.value = plan.timeSegments[0]?.endTime || "10:00:00";
    this.els.formStatus.value = String(plan.plan_status);
    this.els.formRemark.value = plan.remark || "";
    this.els.modal.hidden = false;
  },

  closePlanForm() {
    this.editingPlan = null;
    this.els.modal.hidden = true;
  },

  savePlanForm() {
    const block = this.blocks.find((item) => planBlockId(item) === String(this.els.formBlock.value));
    if (!block) return;
    let plan = null;
    if (this.editingPlan) {
      const oldBlock = this.blocks.find((item) => planBlockId(item) === String(this.editingPlan.blockId));
      plan = oldBlock?.plans.find((item) => planId(item) === String(this.editingPlan.planId));
      if (oldBlock && oldBlock !== block && plan) {
        oldBlock.plans = oldBlock.plans.filter((item) => planId(item) !== planId(plan));
        block.plans.push(plan);
      }
    }
    if (!plan) {
      plan = { id: this.nextPlanId(), block_id: planBlockId(block), create_user: "system" };
      block.plans.push(plan);
    }
    plan.block_id = planBlockId(block);
    plan.use_date = this.els.formDate.value;
    plan.timeSegments = [{ startTime: this.els.formStart.value, endTime: this.els.formEnd.value }];
    plan.time_plan = JSON.stringify(plan.timeSegments);
    plan.plan_status = this.els.formStatus.value;
    plan.remark = this.els.formRemark.value.trim();
    plan.update_user = "demo";
    plan.update_time = new Date().toISOString();
    this.closePlanForm();
    this.render();
  },

  nextPlanId() {
    return this.blocks.reduce((max, block) => Math.max(max, ...block.plans.map((plan) => Number(plan.id) || 0)), 0) + 1;
  },

  deletePlanById(blockId, id) {
    const block = this.blocks.find((item) => planBlockId(item) === String(blockId));
    if (!block) return;
    block.plans = block.plans.filter((item) => planId(item) !== String(id));
    this.els.popup.hidden = true;
    this.render();
  },

  draw(blocks) {
    const featureCollection = {
      type: "FeatureCollection",
      features: [
        ...AirspaceMap.airspaceFeatures(this.airspaces),
        ...blocks.map((block) => ({
          type: "Feature",
          properties: { blockId: planBlockId(block), code: block.airspace_code, status: this.status(block) },
          geometry: AirspaceMap.displayGeometry(block),
        })).filter((feature) => feature.geometry),
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
        const block = blocks.find((item) => planBlockId(item) === id);
        const status = this.status(block);
        entity.polygon.material = planColor(status);
        entity.polygon.outline = true;
        entity.polygon.outlineColor = Cesium.Color.WHITE;
        entity.position = AirspaceMap.center(block, 80);
        entity.label = new Cesium.LabelGraphics({ text: block.airspace_code, font: "14px Microsoft YaHei", fillColor: Cesium.Color.WHITE, outlineColor: Cesium.Color.BLACK, outlineWidth: 3, style: Cesium.LabelStyle.FILL_AND_OUTLINE, disableDepthTestDistance: Number.POSITIVE_INFINITY });
        this.entities.set(id, entity);
      });
      if (source.entities.values.length) AirspaceMap.flyToBlocksTopDown(this.viewer, [...this.airspaces, ...blocks]);
    });
  },

  updatePlaybackState() {
    const blocks = this.currentBlocks.length ? this.currentBlocks : this.filtered();
    const active = blocks.filter((block) => this.status(block) === "ACTIVE").length;
    const applied = blocks.filter((block) => this.status(block) === "APPLIED").length;
    const none = blocks.filter((block) => this.status(block) === "NOT_APPLIED").length;
    this.els.time.textContent = timeText(this.seconds);
    this.els.clock.textContent = timeText(this.seconds);
    this.els.dateText.textContent = this.els.date.value;
    this.els.note.textContent = `当前 ${timeText(this.seconds)}：${active} 个生效，${applied} 个有计划未生效，${none} 个当天无计划。`;
    blocks.forEach((block) => {
      const entity = this.entities.get(planBlockId(block));
      if (!entity) return;
      entity.polygon.material = planColor(this.status(block));
      const activePlan = block.plans.find((plan) => parsePlanStatus(plan.plan_status) && plan.timeSegments.some((segment) => activeSegment(segment, this.seconds)));
      if (activePlan) {
        entity.polygon.height = 0;
        entity.polygon.extrudedHeight = Number(block.airspace_height ?? 200);
        entity.position = AirspaceMap.center(block, Number(block.airspace_height ?? 200) + 80);
      } else {
        entity.polygon.height = undefined;
        entity.polygon.extrudedHeight = undefined;
        entity.position = AirspaceMap.center(block, 80);
      }
    });
  },

  renderTimeline(blocks) {
    const segments = [];
    blocks.forEach((block) => block.plans.filter((plan) => parsePlanStatus(plan.plan_status)).forEach((plan) => plan.timeSegments.forEach((segment) => {
      const start = secondsOf(segment.startTime);
      const end = secondsOf(segment.endTime);
      if (end > start) segments.push({ start, end }); else { segments.push({ start, end: 86400 }); segments.push({ start: 0, end }); }
    })));
    this.els.segments.innerHTML = segments.map((segment) => `<i class="segment" style="left:${segment.start / 864}%;width:${(segment.end - segment.start) / 864}%"></i>`).join("");
  },

  bindMap() {
    this.viewer.screenSpaceEventHandler.setInputAction((event) => {
      const picked = this.viewer.scene.pick(event.position);
      if (!Cesium.defined(picked) || !picked.id?.properties?.blockId) return;
      this.showBlock(picked.id.properties.blockId.getValue());
    }, Cesium.ScreenSpaceEventType.LEFT_CLICK);
  },

  showBlock(id) {
    const block = this.filtered().find((item) => planBlockId(item) === String(id));
    if (!block) return;
    AirspaceMap.flyToBlock(this.viewer, block);
    const planHtml = block.plans.length ? block.plans.map((plan) => {
      const time = plan.timeSegments.map((segment) => `${segment.startTime} - ${segment.endTime}`).join("，");
      return `<div class="popup-block"><strong>${block.airspace_name}</strong><p>空域编号：${block.airspace_code}</p><p>使用日期：${plan.use_date}</p><p>用空时段：${time}</p><p>计划状态：${parsePlanStatus(plan.plan_status) ? "可用" : "不可用"}</p><p>修改人：${plan.update_user || "-"}</p><p>备注：${plan.remark || "-"}</p><div class="popup-actions"><button class="secondary" data-popup-action="edit-plan" data-block-id="${planBlockId(block)}" data-plan-id="${planId(plan)}" type="button">编辑</button><button class="secondary" data-popup-action="delete-plan" data-block-id="${planBlockId(block)}" data-plan-id="${planId(plan)}" type="button">删除</button></div></div>`;
    }).join("") : `<div class="popup-block"><strong>${block.airspace_name}</strong><p>空域编号：${block.airspace_code}</p><p>使用日期：${this.els.date.value}</p><p>当天无用空计划</p></div>`;
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
    const progress = this.seconds / 86399;
    this.els.timeline?.style.setProperty("--timeline-progress", progress);
    this.updateTimelineMarker();
    this.updatePlaybackState();
  },

  updateTimelineMarker() {
    const timeline = this.els?.timeline;
    if (!timeline) return;
    const side = parseFloat(getComputedStyle(timeline).getPropertyValue("--timeline-side")) || 96;
    const progress = this.seconds / 86399;
    const marker = ((side + progress * Math.max(0, timeline.clientWidth - side * 2)) / timeline.clientWidth) * 100;
    timeline.style.setProperty("--timeline-marker", `${marker}%`);
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
