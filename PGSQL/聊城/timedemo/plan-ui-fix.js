(function () {
  const zh = (value) => value.replace(/\\u([0-9a-fA-F]{4})/g, (_, code) => String.fromCharCode(parseInt(code, 16)));
  const setText = (selector, value) => {
    const node = document.querySelector(selector);
    if (node) node.textContent = zh(value);
  };
  const blockKey = (block) => String(block.id ?? block.block_id);
  const planKey = (plan) => String(plan.id ?? plan.plan_id);
  const usable = (value) => value === false || value === "false" || value === 0 || value === "0" || value === "1";
  const planPageSize = 10;
  const taskPageSize = 6;
  const airspacePageSize = 9;

  function setLabelText(label, value) {
    if (!label) return;
    const firstText = [...label.childNodes].find((node) => node.nodeType === Node.TEXT_NODE);
    if (firstText) firstText.nodeValue = zh(value);
    else label.prepend(document.createTextNode(zh(value)));
  }

  function planTimes(block) {
    const segments = (block.plans || [])
      .filter((plan) => usable(plan.plan_status))
      .flatMap((plan) => plan.timeSegments || []);
    if (!segments.length) return "--";
    return segments.map((segment) => `<i>${segment.startTime.slice(0, 5)}-${segment.endTime.slice(0, 5)}</i>`).join("");
  }

  function sidePagerHtml(type, current, total) {
    return `
      <div class="side-pager" data-side-pager="${type}">
        <button class="secondary" type="button" data-side-page="prev" ${current <= 1 ? "disabled" : ""}>${zh("\\u4e0a\\u4e00\\u9875")}</button>
        <span>${current}/${total}</span>
        <button class="secondary" type="button" data-side-page="next" ${current >= total ? "disabled" : ""}>${zh("\\u4e0b\\u4e00\\u9875")}</button>
      </div>`;
  }

  function bindSidePager(page, type, total) {
    const root = document.querySelector(`[data-side-pager="${type}"]`);
    if (!root) return;
    const rerender = () => {
      if (type === "plans") page.renderList(page.currentBlocks?.length ? page.currentBlocks : page.filtered());
      else page.renderSidePanels();
    };
    root.querySelector("[data-side-page='prev']")?.addEventListener("click", () => {
      page.sidePager[type] = Math.max(1, (page.sidePager[type] || 1) - 1);
      rerender();
    });
    root.querySelector("[data-side-page='next']")?.addEventListener("click", () => {
      page.sidePager[type] = Math.min(total, (page.sidePager[type] || 1) + 1);
      rerender();
    });
  }

  function applyStaticCopy() {
    document.title = zh("\\u7a7a\\u57df\\u7528\\u7a7a\\u8ba1\\u5212 Demo");
    setText(".brand h1", "\\u804a\\u57ce\\u5e02\\u4f4e\\u7a7a\\u7efc\\u5408\\u611f\\u77e5\\u670d\\u52a1\\u5e73\\u53f0");
    setText('[data-top-nav="overview"]', "\\u7ec4\\u7ec7\\u6743\\u9650");
    setText('[data-top-nav="airspace"]', "\\u8d44\\u4ea7\\u7ba1\\u7406");
    setText('[data-top-nav="flight"]', "\\u884c\\u4e1a\\u5e94\\u7528");
    setText('[data-top-nav="warning"]', "\\u57fa\\u7840\\u914d\\u7f6e");
    setText('[data-top-nav="task"]', "\\u5ba1\\u6279\\u4e2d\\u5fc3");
    setText('[data-top-nav="system"]', "\\u7a7a\\u57df\\u7ba1\\u7406");
    setText(".nav-section strong", "\\u7a7a\\u57df\\u8bbe\\u7f6e");
    setText('[data-page-link="block"]', "\\u7a7a\\u57df\\u533a\\u5757");
    setText('[data-page-link="plan"]', "\\u7528\\u7a7a\\u8ba1\\u5212");
    setText('.nav-section a[href="#warning"]', "\\u7a7a\\u57df\\u9884\\u8b66\\u8bb0\\u5f55");
    setText("#filterTitle", "\\u7528\\u7a7a\\u8ba1\\u5212");
    setLabelText(document.querySelector("label.page-plan-only"), "\\u7528\\u7a7a\\u8ba1\\u5212\\u65e5\\u671f");
    setText("#searchBtn", "\\u67e5\\u8be2");
    setText("#resetBtn", "\\u91cd\\u7f6e");
    setText("#setFlyTimeBtn", "\\u8bbe\\u7f6e\\u53ef\\u98de\\u65f6\\u95f4");
    setText("#publishPlanBtn", "\\u53d1\\u5e03\\u7528\\u7a7a\\u8ba1\\u5212");
    setText(".plan-right-panel .plan-side-card:nth-child(1) h2", "\\u5f53\\u65e5\\u98de\\u884c\\u4efb\\u52a1");
    setText(".plan-right-panel .plan-side-card:nth-child(2) h2", "\\u5f53\\u65e5\\u4efb\\u52a1\\u6d89\\u53ca\\u7a7a\\u57df");
    setText(".plan-right-panel .plan-side-card:nth-child(3) h2", "\\u5f53\\u65e5\\u4efb\\u52a1\\u5206\\u6790");
    document.querySelectorAll("[data-top-nav]").forEach((link) => {
      link.classList.toggle("active", link.dataset.topNav === "system");
    });
    const legend = document.querySelector(".legend");
    if (legend) legend.style.display = "none";
  }

  function patchPlanPage() {
    const page = window.AirspacePlanPage;
    if (!page || page.__uiFixed) return;
    page.__uiFixed = true;
    page.sidePager = { plans: 1, tasks: 1, airspaces: 1 };

    page.init = ((original) => function (...args) {
      original.apply(this, args);
      applyStaticCopy();
      if (this.els?.popupTitle) this.els.popupTitle.textContent = zh("\\u7528\\u7a7a\\u8ba1\\u5212\\u8be6\\u60c5");
    })(page.init);

    page.render = ((original) => function (...args) {
      this.sidePager.plans = Math.max(1, this.sidePager.plans || 1);
      original.apply(this, args);
    })(page.render);

    page.renderList = function (blocks) {
      const pageCount = Math.max(1, Math.ceil(blocks.length / planPageSize));
      this.sidePager.plans = Math.min(this.sidePager.plans || 1, pageCount);
      const start = (this.sidePager.plans - 1) * planPageSize;
      const pageBlocks = blocks.slice(start, start + planPageSize);
      this.els.count.textContent = zh(`${blocks.length} \\u4e2a\\u7a7a\\u57df`);
      this.els.list.innerHTML = `
        <div class="plan-grid" role="table">
          <div class="plan-grid-head" role="row">
            <label class="plan-check"><input type="checkbox" id="planCheckAll" /></label>
            <strong>${zh("\\u7a7a\\u57df\\u7f16\\u53f7")}</strong>
            <strong>${zh("\\u7a7a\\u57df\\u540d\\u79f0")}</strong>
            <strong>${zh("\\u53ef\\u98de\\u65f6\\u6bb5")}</strong>
          </div>
          ${pageBlocks.map((block) => `
            <div class="plan-grid-row ${this.status(block).toLowerCase()}" data-id="${blockKey(block)}" role="row">
              <label class="plan-check"><input type="checkbox" data-plan-check="${blockKey(block)}" /></label>
              <span>${String(block.airspace_code || block.id).match(/\d+$/)?.[0] ? 100 + Number(String(block.airspace_code || block.id).match(/\d+$/)[0]) : block.airspace_code}</span>
              <span>${block.airspace_name}</span>
              <span class="plan-time-cell">${planTimes(block)}</span>
            </div>`).join("")}
          ${sidePagerHtml("plans", this.sidePager.plans, pageCount)}
        </div>`;
      this.els.list.querySelectorAll(".plan-grid-row").forEach((row) => {
        row.addEventListener("click", (event) => {
          if (!event.target.matches("input")) this.showBlock(row.dataset.id);
        });
      });
      this.els.list.querySelector("#planCheckAll")?.addEventListener("change", (event) => {
        this.els.list.querySelectorAll("[data-plan-check]").forEach((input) => { input.checked = event.target.checked; });
      });
      bindSidePager(this, "plans", pageCount);
      this.els.pager.innerHTML = "";
    };

    page.renderSidePanels = function () {
      const tasks = [
        ["\\u5c0f\\u6e44\\u6cb3A1\\u6bb5\\u65e5\\u5e38\\u5de1\\u68c0", "\\u5e73\\u53f0\\u98de\\u884c", "\\u516c\\u5b89\\u5c40", "\\u6b63\\u5e38", "ok", "8:30-9:00; 14:00-14:30"],
        ["\\u5c0f\\u6e44\\u6cb3A1\\u6bb5\\u65e5\\u5e38\\u5de1\\u68c0", "\\u81ea\\u52a8\\u98de\\u884c", "\\u73af\\u4fdd\\u5c40", "\\u65e5\\u5e38\\u5de1\\u68c0", "data", "8:30-9:00"],
        ["\\u5c0f\\u6e44\\u6cb3A1\\u6bb5\\u65e5\\u5e38\\u5de1\\u68c0", "\\u81ea\\u52a8\\u98de\\u884c", "\\u73af\\u4fdd\\u5c40", "\\u6570\\u636e\\u91c7\\u96c6", "data", "8:30-9:00"],
        ["\\u5c0f\\u6e44\\u6cb3A1\\u6bb5\\u65e5\\u5e38\\u5de1\\u68c0", "\\u5e73\\u53f0\\u98de\\u884c", "\\u73af\\u4fdd\\u5c40", "\\u53d6\\u6d88", "bad", "8:30-9:00"],
        ["\\u5c0f\\u6e44\\u6cb3A1\\u6bb5\\u65e5\\u5e38\\u5de1\\u68c0", "\\u81ea\\u52a8\\u98de\\u884c", "\\u73af\\u4fdd\\u5c40", "\\u65e5\\u5e38\\u5de1\\u68c0", "data", "8:30-9:00"],
        ["\\u5c0f\\u6e44\\u6cb3A1\\u6bb5\\u65e5\\u5e38\\u5de1\\u68c0", "\\u5e73\\u53f0\\u98de\\u884c", "\\u73af\\u4fdd\\u5c40", "\\u6570\\u636e\\u91c7\\u96c6", "data", "8:30-9:00"],
        ["\\u5c0f\\u6e44\\u6cb3A1\\u6bb5\\u65e5\\u5e38\\u5de1\\u68c0", "\\u81ea\\u52a8\\u98de\\u884c", "\\u516c\\u5b89\\u5c40", "\\u6b63\\u5e38", "ok", "9:30-10:00"],
        ["\\u5c0f\\u6e44\\u6cb3A1\\u6bb5\\u65e5\\u5e38\\u5de1\\u68c0", "\\u5e73\\u53f0\\u98de\\u884c", "\\u73af\\u4fdd\\u5c40", "\\u6570\\u636e\\u91c7\\u96c6", "data", "10:30-11:00"],
      ];
      const airspaces = Array.from({ length: 15 }, (_, index) => [101 + index, "\\u8fd9\\u91cc\\u662f\\u7a7a\\u57df\\u540d\\u79f0"]);
      const taskPageCount = Math.max(1, Math.ceil(tasks.length / taskPageSize));
      const airspacePageCount = Math.max(1, Math.ceil(airspaces.length / airspacePageSize));
      this.sidePager.tasks = Math.min(this.sidePager.tasks || 1, taskPageCount);
      this.sidePager.airspaces = Math.min(this.sidePager.airspaces || 1, airspacePageCount);
      const taskStart = (this.sidePager.tasks - 1) * taskPageSize;
      const airspaceStart = (this.sidePager.airspaces - 1) * airspacePageSize;

      this.els.flightTasks.innerHTML = tasks.slice(taskStart, taskStart + taskPageSize).map(([name, mode, dept, status, statusClass, time]) => `
        <div class="flight-task"><div><strong>${zh(name)}</strong><span>${zh(mode)}</span></div><p><em class="tag env">${zh(dept)}</em><em class="tag ${statusClass}">${zh(status)}</em><time>${time}</time></p></div>`).join("");
      this.els.flightTasks.insertAdjacentHTML("beforeend", sidePagerHtml("tasks", this.sidePager.tasks, taskPageCount));
      this.els.involvedAirspaces.innerHTML = `
        <div class="involved-head"><strong>${zh("\\u7a7a\\u57df\\u7f16\\u53f7")}</strong><strong>${zh("\\u7a7a\\u57df\\u540d\\u79f0")}</strong></div>
        ${airspaces.slice(airspaceStart, airspaceStart + airspacePageSize).map(([code, name]) => `<div class="involved-row"><span>${code}</span><span>${zh(name)}</span></div>`).join("")}
        ${sidePagerHtml("airspaces", this.sidePager.airspaces, airspacePageCount)}`;
      bindSidePager(this, "tasks", taskPageCount);
      bindSidePager(this, "airspaces", airspacePageCount);
      this.renderTaskAnalysis();
    };

    page.renderTaskAnalysis = function () {
      this.els.taskAnalysis.innerHTML = `
        <div><span>${zh("\\u5f53\\u65e5\\u8ba1\\u5212\\u4efb\\u52a1")}</span><strong>10</strong></div>
        <div><span>${zh("\\u53ef\\u98de\\u4efb\\u52a1")}</span><strong>7</strong></div>
        <div class="cancel"><span>${zh("\\u53d6\\u6d88\\u4efb\\u52a1")}</span><strong>3</strong></div>
        <div class="rate"><span>${zh("\\u53ef\\u653e\\u98de\\u7387")}</span><strong>70%</strong></div>`;
    };

    page.showBlock = function (id) {
      const block = this.filtered().find((item) => blockKey(item) === String(id));
      if (!block) return;
      AirspaceMap.flyToBlock(this.viewer, block);
      const html = block.plans.length ? block.plans.map((plan) => {
        const time = plan.timeSegments.map((segment) => `${segment.startTime} - ${segment.endTime}`).join("; ");
        return `<div class="popup-block"><strong>${block.airspace_name}</strong><p>${zh("\\u7a7a\\u57df\\u7f16\\u53f7")}：${block.airspace_code}</p><p>${zh("\\u4f7f\\u7528\\u65e5\\u671f")}：${plan.use_date}</p><p>${zh("\\u7528\\u7a7a\\u65f6\\u6bb5")}：${time}</p><p>${zh("\\u8ba1\\u5212\\u72b6\\u6001")}：${usable(plan.plan_status) ? zh("\\u53ef\\u7528") : zh("\\u4e0d\\u53ef\\u7528")}</p><p>${zh("\\u4fee\\u6539\\u4eba")}：${plan.update_user || "-"}</p><p>${zh("\\u5907\\u6ce8")}：${plan.remark || "-"}</p><div class="popup-actions"><button class="secondary" data-popup-action="edit-plan" data-block-id="${blockKey(block)}" data-plan-id="${planKey(plan)}" type="button">${zh("\\u7f16\\u8f91")}</button><button class="secondary" data-popup-action="delete-plan" data-block-id="${blockKey(block)}" data-plan-id="${planKey(plan)}" type="button">${zh("\\u5220\\u9664")}</button></div></div>`;
      }).join("") : `<div class="popup-block"><strong>${block.airspace_name}</strong><p>${zh("\\u7a7a\\u57df\\u7f16\\u53f7")}：${block.airspace_code}</p><p>${zh("\\u4f7f\\u7528\\u65e5\\u671f")}：${this.els.date.value}</p><p>${zh("\\u5f53\\u5929\\u65e0\\u7528\\u7a7a\\u8ba1\\u5212")}</p></div>`;
      this.els.popupTitle.textContent = zh("\\u7528\\u7a7a\\u8ba1\\u5212\\u8be6\\u60c5");
      this.els.popupContent.innerHTML = html;
      this.els.popupContent.querySelectorAll("[data-popup-action='edit-plan']").forEach((button) => button.addEventListener("click", () => this.openPlanFormById(button.dataset.blockId, button.dataset.planId)));
      this.els.popupContent.querySelectorAll("[data-popup-action='delete-plan']").forEach((button) => button.addEventListener("click", () => this.deletePlanById(button.dataset.blockId, button.dataset.planId)));
      this.els.popup.hidden = false;
    };
  }

  applyStaticCopy();
  patchPlanPage();
  document.addEventListener("DOMContentLoaded", applyStaticCopy);
})();
