/* Derive stage badges without treating a compiler sub-step as overall progress. */
function workflowStepStates(run, messages = []) {
  const result = Array(5).fill("pending");
  if (!run) return result;
  const action = run.action || run.Action;
  const status = String(run.status || run.Status || "").toLowerCase();
  const active = Boolean(run.active) || status === "running";
  const scope =
    {
      full: [0, 1, 2, 3, 4],
      build: [0, 1, 3],
      clone: [0],
      update: [0],
      dependencies: [1],
      check: [2],
      package: [4],
    }[action] || [];
  if (!scope.length) return result;
  for (let i = 0; i < 5; i++) if (!scope.includes(i)) result[i] = "skipped";
  const lines = messages.map((row) =>
    typeof row === "string" ? row : String(row.Message || ""),
  );
  let current = null;
  for (const line of lines) {
    const marker = line.match(
      /\[studio-stage:(\d):(running|completed|failed)\]/,
    );
    if (marker) {
      current = Number(marker[1]) - 1;
      if (scope.includes(current)) result[current] = marker[2];
      continue;
    }
    // Older engines have no stage events; use only explicit phase output.
    let inferred =
      /Installing universal Qt|Dependency handling|Build tools ready|Discovering available Qt/.test(
        line,
      )
        ? 1
        : /CHECK:|Project setup checks passed|Diagnosis found/.test(line)
          ? 2
          : /Building and installing the project|Preparing isolated .* source|Skip clean step|Configuring CMake/.test(
                line,
              )
            ? 3
            : /Creating.*DMG|Creating disk image|Running macdeployqt|Staging.*bundle|installer package/.test(
                  line,
                )
              ? 4
              : null;
    if (
      inferred !== null &&
      scope.includes(inferred) &&
      (current === null || inferred > current)
    )
      current = inferred;
  }
  if (
    Number.isInteger(run.workflowStage) &&
    scope.includes(run.workflowStage - 1)
  )
    current = run.workflowStage - 1;
  if (["succeeded", "success", "completed"].includes(status))
    scope.forEach((i) => (result[i] = "completed"));
  else if (status === "dry-run") scope.forEach((i) => (result[i] = "preview"));
  else {
    if (current === null && scope.length === 1) current = scope[0];
    if (current === null && active) current = scope[0];
    if (current !== null) {
      scope
        .filter((i) => i < current)
        .forEach((i) => (result[i] = "completed"));
      if (active) result[current] = run.paused ? "paused" : "running";
      else if (["failed", "error"].includes(status)) result[current] = "failed";
      else if (["interrupted", "cancelled", "canceled"].includes(status))
        result[current] = "interrupted";
    }
  }
  return result;
}

const actionData = [
  ["Clone", "clone", "Clone this project’s pinned repositories.", "Prepare"],
  [
    "Update",
    "update",
    "Update clean checkouts to their pinned refs.",
    "Prepare",
  ],
  [
    "Dependencies",
    "dependencies",
    "Install and verify shared libraries in the dependency stage.",
    "Prepare",
  ],
  [
    "Check",
    "check",
    "Check tools, paths, repositories and libraries.",
    "Prepare",
  ],
  [
    "Build project",
    "build",
    "Build the selected application only.",
    "Build & package",
  ],
  [
    "Package",
    "package",
    "Create a DMG from a completed build.",
    "Build & package",
  ],
  [
    "Build installer",
    "full",
    "Clone or update this project’s repositories, build dependencies, check setup, build the project, then create and verify its DMG.",
    "Complete workflow",
    true,
  ],
];
if (localStorage.getItem("interfaceVersion") !== "11") {
  localStorage.setItem("workspaceView", "build");
  localStorage.setItem("buildSection", "workflow");
  localStorage.setItem("interfaceVersion", "11");
}
let managedProfile = "";
let pendingProfile = "";
let currentView = "build";
let buildSection = localStorage.getItem("buildSection") || "workflow";
let formSaving = false;
let state = {},
  selectedRun = "",
  selectedRecord = null,
  lastStatusKey = "",
  folderDirty = false,
  installerItems = [],
  dependencyState = { items: [], cacheFolders: [] },
  dependencyLoaded = false,
  dependencyLoading = false;
const $ = (s) => document.querySelector(s);
const esc = (s) =>
  String(s ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;",
      })[c],
  );
let refreshInFlight = false;
let pollTimer;
const tooltip = $("#appTooltip");
let tooltipTarget = null;
function placeTooltip(el) {
  const r = el.getBoundingClientRect(),
    b = tooltip.getBoundingClientRect();
  let left = Math.max(
      8,
      Math.min(innerWidth - b.width - 8, r.left + (r.width - b.width) / 2),
    ),
    top = r.bottom + 8;
  if (top + b.height > innerHeight - 8) top = Math.max(8, r.top - b.height - 8);
  tooltip.style.left = `${left}px`;
  tooltip.style.top = `${top}px`;
}
function showTooltip(el) {
  if (!el?.dataset.tip) return;
  tooltipTarget = el;
  tooltip.textContent = el.dataset.tip;
  tooltip.hidden = false;
  requestAnimationFrame(() => placeTooltip(el));
}
function hideTooltip() {
  tooltip.hidden = true;
  tooltipTarget = null;
}
document.addEventListener("pointerover", (e) => {
  const el = e.target.closest?.("[data-tip],[title]");
  if (el?.title && !el.dataset.tip) el.dataset.tip = el.title;
  if (el && el !== tooltipTarget) showTooltip(el);
});
document.addEventListener("pointerout", (e) => {
  if (tooltipTarget && !tooltipTarget.contains(e.relatedTarget)) hideTooltip();
});
document.addEventListener("focusin", (e) => {
  const el = e.target.closest?.("[data-tip],[title]");
  if (el?.title && !el.dataset.tip) el.dataset.tip = el.title;
  if (el) showTooltip(el);
});
document.addEventListener("focusout", (e) => {
  if (tooltipTarget && !tooltipTarget.contains(e.relatedTarget)) hideTooltip();
});
window.addEventListener(
  "scroll",
  () => tooltipTarget && placeTooltip(tooltipTarget),
  true,
);
window.addEventListener(
  "resize",
  () => tooltipTarget && placeTooltip(tooltipTarget),
);
const groupIcons = {
  Prepare:
    '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="m8 12 2.5 2.5L16.5 9"/></svg>',
  "Build & package":
    '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3v2m0 14v2M3 12h2m14 0h2M5.6 5.6 7 7m10 10 1.4 1.4M18.4 5.6 17 7M7 17l-1.4 1.4"/><circle cx="12" cy="12" r="5"/></svg>',
  Release:
    '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 8h16v12H4zM3 8l2-4h14l2 4M12 11v6m-3-3 3 3 3-3"/></svg>',
  "Complete workflow":
    '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 12h16M13 5l7 7-7 7"/><circle cx="5" cy="12" r="2"/></svg>',
};
function actionGroupMarkup(group) {
  return `<section class="action-group ${group === "Complete workflow" ? "complete-workflow" : ""}"><div class="action-group-title"><span class="group-icon">${groupIcons[group]}</span>${group}</div><div class="action-stack">${actionData
    .filter((a) => a[3] === group)
    .map(
      (a) =>
        `<div class="action ${a[4] ? "primary-action" : ""}"><button class="btn ${a[4] ? "primary" : ""}" data-conflict data-tip="${esc(a[2])}" title="${esc(a[2])}" onclick="runAction('${a[1]}')">${esc(a[0])}</button></div>`,
    )
    .join("")}</div></section>`;
}
$("#prepareActions").innerHTML = actionGroupMarkup("Prepare");
$("#actions").innerHTML = ["Build & package"].map(actionGroupMarkup).join("");
const listPages = {};
function fittedPageSize(name) {
  const ids = {
    plugins: "repositoryManagerList",
    dependencies: "dependencyList",
    runs: "runs",
    installers: "installers",
  };
  const container = document.getElementById(ids[name]);
  if (!container || !container.getClientRects().length)
    return listPages[name]?.size || 6;
  const first = container.firstElementChild;
  const height =
    first && !first.classList.contains("empty")
      ? first.getBoundingClientRect().height
      : { plugins: 46, dependencies: 55, runs: 60, installers: 70 }[name];
  const available = innerHeight - container.getBoundingClientRect().top - 54;
  return Math.max(
    1,
    Math.min(30, Math.floor(available / Math.max(height, 30))),
  );
}
function pageRows(name, rows, query = "") {
  let page = listPages[name];
  if (!page || page.query !== query)
    page = listPages[name] = { index: 0, query, size: fittedPageSize(name) };
  const size = fittedPageSize(name);
  if (page.size !== size) {
    page.index = Math.floor((page.index * page.size) / size);
    page.size = size;
  }
  page.index = Math.min(
    page.index,
    Math.max(0, Math.ceil(rows.length / size) - 1),
  );
  const start = page.index * size;
  const pager = $(`#${name}Pager`);
  if (pager)
    pager.innerHTML =
      rows.length > size
        ? `<span>${start + 1}–${Math.min(start + size, rows.length)} of ${rows.length}</span><div><button class="btn icon-action" aria-label="Previous ${name}" onclick="changePage('${name}',-1)" ${page.index === 0 ? "disabled" : ""}>‹</button><button class="btn icon-action" aria-label="Next ${name}" onclick="changePage('${name}',1)" ${start + size >= rows.length ? "disabled" : ""}>›</button></div>`
        : rows.length
          ? `<span>${rows.length} ${name === "plugins" ? "repositories" : name}</span>`
          : "";
  return rows.slice(start, start + size);
}
let fitFrame = 0;
function fitVisibleLists() {
  cancelAnimationFrame(fitFrame);
  fitFrame = requestAnimationFrame(() => {
    if (currentView === "installers") drawInstallerList();
    else if (currentView === "activity") drawRuns();
    else if (buildSection === "project") drawRepositoryManager();
  });
}
window.addEventListener("resize", fitVisibleLists);
new ResizeObserver(fitVisibleLists).observe(
  document.querySelector(".workspace-scroll"),
);
function changePage(name, offset) {
  listPages[name].index += offset;
  ({
    plugins: drawRepositoryManager,
    dependencies: renderDependencies,
    runs: drawRuns,
    installers: drawInstallerList,
  })[name]();
}
function truth(x) {
  return x === true || ["true", "yes", "1"].includes(String(x).toLowerCase());
}
function dateLabel(value) {
  if (typeof value === "number") {
    const date = new Date((value - 25569) * 86400000);
    return Number.isNaN(date.valueOf())
      ? String(value)
      : date.toLocaleString([], {
          dateStyle: "medium",
          timeStyle: "short",
        });
  }
  const text = String(value || "");
  const date = new Date(text);
  return text && !Number.isNaN(date.valueOf())
    ? date.toLocaleString([], { dateStyle: "medium", timeStyle: "short" })
    : text;
}
function compactPath(value) {
  const path = String(value || "");
  const parts = path.split("/").filter(Boolean);
  return path.length > 58
    ? "…/" + parts.slice(-3).join("/") || path.slice(-58)
    : path || "Not set";
}
function folderField(name) {
  return document.getElementById(name === "Out path" ? "pathOut" : "pathIn");
}
function drawFolderSettings() {
  for (const name of ["Out path", "In path"]) {
    const field = folderField(name);
    if (field && !folderDirty) {
      field.value = state.settings?.[name] || "";
      field.title = state.settings?.[name] || name;
    }
  }
  $("#saveFolders").disabled = Boolean(state.live?.active) || !folderDirty;
}
function renderInstallers(items, settings) {
  installerItems = items || [];
  const out = settings?.["Out path"] || "";
  $("#pathSummary").textContent = `DMGs from ${compactPath(out)}`;
  $("#pathSummary").title = out;
  drawInstallerList();
}
function drawInstallerList() {
  const query = ($("#installerSearch")?.value || "").trim().toLowerCase(),
    sort = $("#installerSort")?.value || "newest",
    items = installerItems.filter((item) =>
      `${item.project} ${item.name} ${item.version}`
        .toLowerCase()
        .includes(query),
    );
  items.sort((a, b) =>
    sort === "largest"
      ? parseFloat(b.size || 0) - parseFloat(a.size || 0)
      : sort === "oldest"
        ? Date.parse(a.modified) - Date.parse(b.modified)
        : Date.parse(b.modified) - Date.parse(a.modified),
  );
  if (!items.length) $("#installersPager").innerHTML = "";
  $("#installerCount").textContent = query
    ? `${items.length} of ${installerItems.length}`
    : `${items.length} available`;
  const container = $("#installers"),
    signature = JSON.stringify({
      query,
      sort,
      items,
      page: listPages.installers?.index || 0,
      size: fittedPageSize("installers"),
    });
  if (container.dataset.signature === signature) return;
  container.dataset.signature = signature;
  container.innerHTML = items.length
    ? pageRows("installers", items, query + sort)
        .map(
          (i) =>
            `<div class="run"><span class="run-name" title="${esc(i.project)} · ${esc(i.version || "Installer")}">${esc(i.project)} · ${esc(i.version || "Installer")}</span><span><a class="btn" href="/download?id=${encodeURIComponent(i.id)}" title="Download ${esc(i.name)}">Download</a> <button class="btn" data-conflict title="Copy this DMG to the configured In path" onclick="copyInstaller('${esc(i.id)}')">Copy</button> <button class="btn danger" data-conflict title="Delete this installer file" onclick="deleteInstaller('${esc(i.id)}')">Delete</button></span><span class="run-date" title="${esc(i.name)}">${esc(i.name)} · ${esc(i.size)} · ${esc(dateLabel(i.modified))}</span><span></span></div>`,
        )
        .join("")
    : installerItems.length
      ? '<div class="empty">No installers match your search. Clear the search to see all files.</div>'
      : '<div class="empty">No installers found in the configured Out path. Choose a different folder above, or create an installer.</div>';
}
async function refreshInstallers() {
  try {
    const data = await api("/api/installers");
    renderInstallers(data.installers || [], data.settings);
  } catch (e) {
    $("#installers").innerHTML =
      `<div class="empty">Could not load installers · ${esc(e.message)}</div>`;
  }
}
async function copyInstaller(id) {
  try {
    const data = await api("/api/copy-installer", {
      method: "POST",
      body: JSON.stringify({ id }),
    });
    message("Installer copied to the In path", "success", data.destination);
  } catch (e) {
    message(e.message, "error");
  }
}
async function saveFolderSettings() {
  try {
    const values = {
      "Out path": folderField("Out path").value,
      "In path": folderField("In path").value,
    };
    state.settings = await api("/api/settings", {
      method: "POST",
      body: JSON.stringify({ values }),
    }).then((x) => x.settings);
    folderDirty = false;
    drawFolderSettings();
    message(
      "Installer folders saved",
      "success",
      "New DMGs will use these Out and In paths",
    );
    await refreshInstallers();
  } catch (e) {
    message(e.message, "error");
  }
}
async function runAction(action) {
  try {
    await api("/api/run", {
      method: "POST",
      body: JSON.stringify({
        profile: action === "all" ? "all" : selectedProfile(),
        action,
        mode: $("#mode").value,
        dry: $("#dry").checked,
        reuse: $("#reuse").checked,
        jobs: buildJobs(),
      }),
    });
    message(
      `${actionData.find((x) => x[1] === action)[0]} is running`,
      "running",
      "Live output is appearing in this activity",
    );
    $("#stop").disabled = false;
    showView("build");
    await refresh();
  } catch (e) {
    message(e.message, "error");
  }
}
async function stopRun() {
  try {
    await api("/api/stop", { method: "POST", body: "{}" });
    message("Stopping after the current process is interrupted", "warning");
  } catch (e) {
    message(e.message, "error");
  }
}
async function togglePause() {
  try {
    const paused = Boolean(state.live?.paused);
    await api(paused ? "/api/resume" : "/api/pause", {
      method: "POST",
      body: "{}",
    });
    message(
      paused ? "Build resumed" : "Build paused",
      paused ? "running" : "warning",
      paused ? "The build is continuing." : "Resume when you are ready.",
    );
    await refresh();
  } catch (e) {
    message(e.message, "error");
  }
}
$("#prepareActions").innerHTML = actionGroupMarkup("Prepare");
$("#actions").innerHTML = ["Build & package"].map(actionGroupMarkup).join("");
let pendingRequests = 0;
let loadingTimer;
let workspaceReady = false;
let lastRefreshError = "";
function beginLoading() {
  pendingRequests++;
  if (pendingRequests === 1)
    loadingTimer = setTimeout(
      () => document.body.classList.add("fetching"),
      180,
    );
}
function endLoading() {
  pendingRequests = Math.max(0, pendingRequests - 1);
  if (!pendingRequests) {
    clearTimeout(loadingTimer);
    document.body.classList.remove("fetching");
  }
}
async function api(url, options = {}) {
  const visible = !workspaceReady || !url.startsWith("/api/state");
  if (visible) beginLoading();
  try {
    const response = await fetch(url, {
      headers: { "Content-Type": "application/json" },
      ...options,
    });
    const data = await response.json();
    if (!response.ok) throw Error(data.error || "Request failed");
    return data;
  } catch (error) {
    error.dataRequest = true;
    throw error;
  } finally {
    if (visible) endLoading();
  }
}
function message(text, tone = "ready", sub = "") {
  $("#headerStatus").textContent = text;
  $("#headerStatus").dataset.tone = tone;
  const box = $("#status");
  box.className = `status glass ${tone}`;
  $("#statusText").textContent = text;
  $("#statusSub").textContent = sub;
  void box.offsetWidth;
  box.classList.add("status-pop");
  if (["success", "error", "warning"].includes(tone)) showToast(text, tone);
}
const recentToasts = new Map();
function showToast(text, tone) {
  const key = `${tone}:${text}`;
  if (Date.now() - (recentToasts.get(key) || 0) < 15000) return;
  recentToasts.set(key, Date.now());
  if (recentToasts.size > 50)
    recentToasts.delete(recentToasts.keys().next().value);
  let region = $("#toasts");
  if (!region) {
    region = document.createElement("div");
    region.id = "toasts";
    region.setAttribute("aria-live", "polite");
    document.body.append(region);
  }
  const toast = document.createElement("div");
  toast.className = `toast ${tone}`;
  const label = document.createElement("span");
  label.textContent = text;
  const close = document.createElement("button");
  close.textContent = "×";
  close.setAttribute("aria-label", "Dismiss notification");
  close.onclick = () => toast.remove();
  toast.append(label, close);
  region.append(toast);
  while (region.children.length > 3) region.firstChild.remove();
  setTimeout(
    () => {
      if (!toast.matches(":hover") && !toast.contains(document.activeElement))
        toast.remove();
    },
    tone === "error" ? 12000 : 6500,
  );
}
function setBusy(busy) {
  const selectors =
    "#createInstallerBtn,#addMenu button,.workflow-panel button,.workflow-panel input,.workflow-panel select,.workflow-panel textarea,#managerPanel button,#managerPanel input,#managerPanel select,#managerPanel textarea,.dependency-panel button,.dependency-panel input,.dependency-panel select,.dependency-panel textarea,.installers .folder-settings button,.installers .folder-settings input,.installers .folder-settings select,.installers-list button,.top-actions button,.modal button,.modal input,.modal select,.modal textarea";
  document.querySelectorAll(selectors).forEach((el) => {
    if (el.id === "dialogSubmit" && formSaving) {
      el.disabled = true;
      return;
    }
    if (dialogKind === "preferences" && el.closest("#dialog")) {
      el.disabled = el.dataset.idleDisabled === "true";
      return;
    }
    if (["stop", "pauseBuild", "saveFolders"].includes(el.id)) return;
    if (el.dataset.idleDisabled === undefined)
      el.dataset.idleDisabled = String(el.disabled);
    el.disabled =
      el.dataset.idleDisabled === "true" ||
      (busy && !el.hasAttribute("data-safe-while-busy"));
  });
  document.querySelectorAll("a.btn").forEach((el) => {
    if (el.dataset.idleTabindex === undefined)
      el.dataset.idleTabindex = el.getAttribute("tabindex") || "";
    el.setAttribute("aria-disabled", String(busy));
    el.tabIndex = busy
      ? -1
      : el.dataset.idleTabindex === ""
        ? 0
        : Number(el.dataset.idleTabindex);
  });
  document
    .querySelectorAll(".action")
    .forEach((el) => el.classList.toggle("busy", busy));
  $("#saveFolders").disabled = busy || !folderDirty;
  $("#pauseBuild").hidden = !busy;
  $("#pauseBuild").disabled = !busy || Boolean(state.live?.external);
  $("#pauseBuild").textContent = state.live?.paused ? "▶" : "Ⅱ";
  $("#pauseBuild").title = state.live?.paused ? "Resume build" : "Pause build";
  $("#pauseBuild").setAttribute(
    "aria-label",
    state.live?.paused ? "Resume build" : "Pause build",
  );
  $("#stop").disabled = !busy || Boolean(state.live?.external);
}
function formatElapsed(total) {
  const s = Math.max(0, Math.floor(total));
  return s >= 3600
    ? `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`
    : s >= 60
      ? `${Math.floor(s / 60)}m ${s % 60}s`
      : `${s}s`;
}
function drawProgress(live) {
  const panel = $("#buildProgress");
  if (!live) {
    panel.hidden = true;
    return;
  }
  const lines = (live.output || [])
    .map((x) => String(x).trim())
    .filter(Boolean);
  if (!lines.length && !live.active) {
    panel.hidden = true;
    return;
  }
  panel.hidden = false;
  panel.className = `progress-panel glass ${live.active ? (live.paused ? "paused" : "running") : live.status === "failed" ? "error" : live.status === "succeeded" ? "success" : ""}`;
  $("#progressTitle").textContent =
    `${live.profile || "Project"} · ${live.action || "Build"} ${live.active ? (live.paused ? "paused" : "in progress") : live.status === "failed" ? "failed" : "finished"}`;
  const elapsed = live.started
    ? Math.max(
        0,
        Math.floor((Date.now() - new Date(live.started).getTime()) / 1000),
      )
    : 0;
  $("#progressElapsed").textContent = `Elapsed · ${formatElapsed(elapsed)}`;
  const statuses = workflowStepStates(live, lines);
  const phase = statuses.findIndex((status) =>
    ["running", "paused"].includes(status),
  );
  const names = [
    "Preparing repositories",
    "Installing dependencies",
    "Checking setup",
    "Building project",
    "Creating installer",
  ];
  $("#progressEta").textContent = live.active
    ? live.paused
      ? "Paused — resume when ready"
      : names[phase] || "Working on this operation"
    : live.status === "failed"
      ? "Stopped on an error"
      : "Operation finished";
  $("#progressEta").title =
    "Shows the current workflow stage. Compiler task counts are not an overall percentage.";
  $("#progressPercent").textContent = live.active
    ? live.paused
      ? "Paused"
      : "In progress"
    : live.status === "failed"
      ? "Failed"
      : "Finished";
  panel.setAttribute("aria-busy", String(Boolean(live.active && !live.paused)));
  panel.querySelector(".progress-bar").style.width = "100%";
  panel.classList.remove("indeterminate");
  panel.classList.toggle(
    "activity-motion",
    Boolean(live.active && !live.paused),
  );
  const meaningful = [...lines]
    .reverse()
    .find((line) => !line.startsWith("[studio-stage:"));
  $("#progressStage").textContent = meaningful || "Preparing…";
  $("#progressLog").textContent = lines.slice(-5).join("\n");
}
function tag(status) {
  status = String(status || "").toLowerCase();
  return ["succeeded", "success", "completed"].includes(status)
    ? "success"
    : ["failed", "failure"].includes(status)
      ? "error"
      : status === "running"
        ? "running"
        : status === "needs-attention"
          ? "warning"
          : "warning";
}
function drawRuns() {
  const runs = state.runs || [];
  $("#runCount").textContent = `${runs.length} saved runs`;
  if (!runs.length) {
    $("#runsPager").innerHTML = "";
    $("#runs").innerHTML =
      '<div class="empty">No activity yet. Run a setup check to start.</div>';
    return;
  }
  const runSignature = JSON.stringify([
    runs,
    selectedRun,
    listPages.runs?.index || 0,
    fittedPageSize("runs"),
  ]);
  if ($("#runs").dataset.signature === runSignature) return;
  $("#runs").dataset.signature = runSignature;
  $("#runs").innerHTML = pageRows("runs", [...runs].reverse())
    .map((r) => {
      const id = String(r["Run ID"]);
      return `<div class="run ${id === selectedRun ? "selected" : ""}" onclick="selectRun('${esc(id)}')"><span class="run-name">${esc(r["Profile ID"])} · ${esc(r.Action)}</span><span class="badge ${tag(r.Status)}">${esc(String(r.Status || "").replaceAll("-", " "))}</span><span class="run-date">${esc(dateLabel(r["Started UTC"]))}</span><span></span></div>`;
    })
    .join("");
}
async function selectRun(id) {
  selectedRun = id;
  selectedRecord = (state.runs || []).find((r) => r["Run ID"] === id);
  drawRuns();
  if (state.logRunId !== id) {
    $("#detail").dataset.signature = "";
    $("#detail").innerHTML = '<div class="empty">Loading logs…</div>';
    try {
      const data = await api(`/api/run-logs?id=${encodeURIComponent(id)}`);
      if (selectedRun !== id) return;
      state.logs = data.logs;
      state.logRunId = id;
      state.logRevision = data.logRevision || "";
    } catch (error) {
      if (selectedRun === id) message(error.message, "error");
      return;
    }
  }
  drawDetail();
}
const logSelections = new Map();
let shownLogIndexes = [];
function selectedLogLines() {
  if (!logSelections.has(selectedRun))
    logSelections.set(selectedRun, new Set());
  return logSelections.get(selectedRun);
}
const logAnchors = new Map();
function updateLogSelection() {
  const selected = selectedLogLines();
  document.querySelectorAll(".log[data-log-index]").forEach((row) => {
    const checked = selected.has(Number(row.dataset.logIndex));
    row.classList.toggle("selected", checked);
    row.setAttribute("aria-selected", String(checked));
    row.querySelector("input").checked = checked;
  });
  const button = $("#copySelectedLogs");
  if (button) {
    button.disabled = !selected.size;
    button.textContent = `Copy selected (${selected.size})`;
  }
}
function selectLogRow(event, index) {
  if (event.type === "keydown" && ![" ", "Enter"].includes(event.key)) return;
  // A text drag remains available for copying part of a message.
  if (
    !event.shiftKey &&
    event.target.type !== "checkbox" &&
    window.getSelection()?.toString()
  )
    return;
  event.preventDefault();
  const selected = selectedLogLines();
  const checked = !selected.has(index);
  const anchor = logAnchors.get(selectedRun);
  if (event.shiftKey && shownLogIndexes.includes(anchor)) {
    const start = shownLogIndexes.indexOf(anchor),
      end = shownLogIndexes.indexOf(index);
    shownLogIndexes
      .slice(Math.min(start, end), Math.max(start, end) + 1)
      .forEach((i) => (checked ? selected.add(i) : selected.delete(i)));
  } else {
    checked ? selected.add(index) : selected.delete(index);
    logAnchors.set(selectedRun, index);
  }
  updateLogSelection();
  // Native checkbox activation is reverted after click cancellation.
  queueMicrotask(updateLogSelection);
}
function selectShownLogs() {
  shownLogIndexes.forEach((index) => selectedLogLines().add(index));
  updateLogSelection();
}
function clearLogSelection() {
  selectedLogLines().clear();
  logAnchors.delete(selectedRun);
  updateLogSelection();
}
async function copySelectedLogs() {
  const all = (state.logs || []).filter(
    (row) => String(row["Run ID"]) === String(selectedRun),
  );
  const selected = selectedLogLines();
  const text = all
    .filter((row, index) => selected.has(index))
    .map(
      (row) =>
        `[${row.Level || "INFO"}] ${row.Stage || ""}: ${row.Message || ""}`,
    )
    .join("\n");
  if (!text) return message("Select log lines first.", "warning");
  try {
    await navigator.clipboard.writeText(text);
    message("Selected log lines copied", "success");
  } catch (error) {
    message(error.message, "error");
  }
}
async function copyLogTextSelection() {
  const text = window.getSelection()?.toString();
  if (!text) return message("Highlight some log text first.", "warning");
  try {
    await navigator.clipboard.writeText(text);
    message("Highlighted text copied", "success");
  } catch (error) {
    message(error.message, "error");
  }
}
function drawDetail() {
  if (!selectedRecord) {
    $("#detail").innerHTML =
      '<div class="empty">Select an activity to view its status and detailed messages.</div>';
    return;
  }
  const detail = $("#detail");
  const previousScroll = detail.querySelector(".log-viewport")?.scrollTop || 0;
  const r = selectedRecord,
    all = (state.logs || []).filter(
      (x) => String(x["Run ID"] || "") === String(selectedRun),
    ),
    level = $("#logLevel")?.value || "ALL",
    logs =
      level === "ALL"
        ? all
        : all.filter((x) => String(x.Level || "INFO").toUpperCase() === level),
    emptyMessage = all.length
      ? "No messages match this filter."
      : "No log messages were recorded for this run.";
  const detailSignature = JSON.stringify([
    r,
    level,
    all.length,
    all[0],
    all.at(-1),
  ]);
  if (detail.dataset.signature === detailSignature) return;
  const restoreScroll =
    detail.dataset.run === String(selectedRun) &&
    detail.dataset.level === level;
  detail.dataset.signature = detailSignature;
  detail.dataset.run = String(selectedRun);
  detail.dataset.level = level;
  const logIndexes = new Map(all.map((row, index) => [row, index]));
  shownLogIndexes = logs.map((row) => logIndexes.get(row));
  const selected = selectedLogLines();
  $("#detail").innerHTML =
    `<div class="detail-title">${esc(r["Profile ID"])} · ${esc(r.Action)}</div><div class="detail-meta">${esc(String(r.Status || "").replaceAll("-", " "))}　·　Started ${esc(dateLabel(r["Started UTC"]))}<br>Run ID ${esc(r["Run ID"])}</div><div class="summary">${esc(r.Summary || "No summary recorded.")}</div><div class="log-tools"><label class="small" for="logLevel">Show</label><select id="logLevel" aria-label="Filter log severity" onchange="drawDetail()"><option value="ALL" ${level === "ALL" ? "selected" : ""}>All messages (${all.length})</option><option value="ERROR" ${level === "ERROR" ? "selected" : ""}>Errors</option><option value="WARNING" ${level === "WARNING" ? "selected" : ""}>Warnings</option><option value="INFO" ${level === "INFO" ? "selected" : ""}>Info</option></select><button class="btn" onclick="selectShownLogs()">Select shown</button><button class="btn" onclick="clearLogSelection()">Deselect</button><button id="copySelectedLogs" class="btn" onclick="copySelectedLogs()" ${selected.size ? "" : "disabled"}>Copy selected (${selected.size})</button><details class="log-more"><summary class="btn" title="Copy highlighted text, download the complete log, or delete history">More</summary><div class="log-more-actions"><button class="btn" onclick="copyLogTextSelection()">Copy highlight</button><button class="btn" onclick="copyVisibleLogs()">Copy shown</button><a class="btn" href="/run-output?id=${encodeURIComponent(r["Run ID"])}" download title="Download the complete output, including lines outside the compact view">Full log</a><button class="btn danger" onclick="deleteSelected('logs')">Delete all logs</button><button class="btn danger" onclick="deleteSelected('run')">Delete run</button></div></details></div><div class="log-viewport" role="listbox" aria-label="Log messages — click a row or Shift-click a range" aria-multiselectable="true">${logs.length ? logs.map((x) => `<div class="log ${esc(String(x.Level || "INFO").toUpperCase())} ${selected.has(logIndexes.get(x)) ? "selected" : ""}" data-log-index="${logIndexes.get(x)}" role="option" tabindex="0" aria-selected="${selected.has(logIndexes.get(x))}" onmousedown="if(event.shiftKey) event.preventDefault()" onclick="selectLogRow(event,${logIndexes.get(x)})" onkeydown="selectLogRow(event,${logIndexes.get(x)})" title="Click to select; Shift-click to select a range. Drag text to highlight a message."><input type="checkbox" aria-label="Select log line ${logIndexes.get(x) + 1}" ${selected.has(logIndexes.get(x)) ? "checked" : ""} tabindex="-1"><span class="log-level">${esc(String(x.Level || "INFO").toUpperCase())}</span><span class="log-stage">${esc(x.Stage || "run")}</span><span class="log-message">${esc(x.Message)}</span></div>`).join("") : `<div class="empty">${emptyMessage}</div>`}</div>`;
  if (restoreScroll)
    detail.querySelector(".log-viewport").scrollTop = previousScroll;
}
function selectedProfile() {
  return (
    $("#project")?.value ||
    localStorage.getItem("preferredProfile") ||
    state.projects?.[0]?.["Profile ID"] ||
    ""
  );
}
function projectOptionLabel(project, duplicateNames) {
  const id = project["Profile ID"];
  const names = {
    "cytosplore-viewer-2026": "Viewer 2026",
    "cytosplore-viewer-master": "Viewer Master",
    "cytosplore-patchseq-100": "Patchseq 1.0",
    "cytosplore-patchseq-master": "Patchseq Master",
    "cytosplore-viewer-500": "Viewer 5.0",
    "manivault-151": "ManiVault 1.5.1",
    "manivault-master": "ManiVault Master",
  };
  return (
    names[id] ||
    `${project["Display name"] || id}${duplicateNames.has(project["Display name"]) ? ` · ${project["App version"]}` : ""}`
  );
}
function updatePlanMode() {
  $("#createInstallerBtn").textContent = $("#dry").checked
    ? "Preview plan"
    : "Create installer";
  document.body.classList.toggle("plan-mode", $("#dry").checked);
}
function openCreateInstaller() {
  const project =
    (state.projects || []).find((p) => p["Profile ID"] === selectedProfile()) ||
    state.projects?.[0];
  if (!project) return message("Add a project first.", "warning");
  dialog(
    $("#dry").checked ? "Preview build plan" : "Create installer",
    [
      {
        name: "Profile ID",
        label: "Project",
        options: (state.projects || []).map((p) => [
          projectOptionLabel(p, new Set()),
          p["Profile ID"],
        ]),
        value: project["Profile ID"],
      },
      {
        name: "App version",
        label: "Release version",
        hidden: $("#dry").checked,
        value: project["App version"],
        required: true,
      },
      {
        name: "action",
        label: "Create from",
        options: [
          ["Build project and package", "full"],
          ["Use existing build", "package"],
        ],
        value: "full",
      },
      {
        notice: $("#dry").checked
          ? "Uses saved project settings. No downloads, compilation or DMG creation; a preview run is saved."
          : "Creates a macOS DMG in your output folder.",
      },
    ],
    "create-installer",
  );
  $("#dialogSubmit").textContent = $("#dry").checked
    ? "Preview plan"
    : "Create installer";
  $("#form")
    .querySelector('[name="Profile ID"]')
    .addEventListener("change", (event) => {
      const selected = state.projects.find(
        (p) => p["Profile ID"] === event.target.value,
      );
      if (selected)
        $("#form").querySelector('[name="App version"]').value =
          selected["App version"];
    });
}
function updateProject() {
  const id = selectedProfile(),
    project = (state.projects || []).find((x) => x["Profile ID"] === id);
  if (!project) {
    $("#projectMeta").textContent =
      "Choose a project to see its build details.";
    return;
  }
  localStorage.setItem("preferredProfile", id);
  managedProfile = id;
  if (currentView === "build")
    $("#workspaceScope").textContent = project["Display name"] || id;
  if (currentView === "build" && buildSection === "project") {
    drawProjectManager();
    drawRepositoryManager();
  }
  const repos = (state.repositories || []).filter(
    (x) => x["Profile ID"] === id && truth(x.Enabled),
  );
  const arch = String(project.Architectures || "Not set")
      .split(";")
      .map((x) => ({ arm64: "Apple silicon", x86_64: "Intel" })[x] || x)
      .join(" + "),
    version = project["App version"]
      ? `v${project["App version"]}`
      : "Version not set",
    core = project["Core ref"] || "Not set",
    minimum = project["Minimum macOS"]
      ? `macOS ${project["Minimum macOS"]}+`
      : "macOS not set";
  $("#project").title =
    `${project["Display name"] || id} · ${id} · ${version} · Core ${core} · ${arch} · ${minimum}`;
  $("#projectMeta").innerHTML =
    `<span>${esc(version)} · ${esc(arch)} · ${esc(minimum)}</span>`;
  const missing = project["Missing dependencies"] || [];
  const building = state.live?.active && state.live.profile === id;
  $("#buildSummary").innerHTML =
    `<div class="build-intro"><span class="eyebrow">Your next release</span><h2>${esc(project["Display name"])}</h2><div class="build-chips"><span>${esc(version)}</span><span>${esc(arch)}</span><span>${esc(minimum)}</span></div></div><div class="build-health"><span class="health-symbol" aria-hidden="true">${building ? "↻" : missing.length ? "!" : "✓"}</span><button class="build-readiness ${missing.length ? "missing" : "ready"}" onclick="showProjectRequirements()" title="Review the selected project's dependency requirements">${building ? "Build in progress" : missing.length ? `${missing.length} need attention` : "Ready to build"}</button><span class="small">${repos.length} repositories · ${missing.length ? "Setup required" : "Dependencies installed"}</span></div>`;
  drawWorkflowSteps(id);
  const recent = (state.runs || [])
    .filter((run) => run["Profile ID"] === id)
    .slice(-3)
    .reverse();
  $("#recentBuilds").innerHTML = recent.length
    ? recent
        .map(
          (run) =>
            `<button class="recent-run" onclick="showView('activity');selectRun('${esc(run["Run ID"])}')"><span>${esc(run.Action)}</span><small>${esc(dateLabel(run["Started UTC"]))}</small><span class="badge ${tag(run.Status)}">${esc(run.Status)}</span></button>`,
        )
        .join("")
    : '<div class="empty">No builds yet.</div>';
}

function drawWorkflowSteps(profile) {
  const live = state.live?.profile === profile ? state.live : null;
  const run =
    live ||
    [...(state.runs || [])]
      .reverse()
      .find((row) => row["Profile ID"] === profile);
  const runId = run?.run_id || run?.["Run ID"];
  const logs =
    live?.output || (state.logs || []).filter((row) => row["Run ID"] === runId);
  const statuses = workflowStepStates(run, logs);
  const labels = ["Repositories", "Dependencies", "Check", "Build", "Package"];
  const words = {
    pending: "Pending",
    skipped: "Not part of this run",
    preview: "Preview only",
    completed: "Completed",
    running: "Running",
    failed: "Failed",
    interrupted: "Stopped",
    paused: "Paused",
  };
  const markup = statuses
    .map(
      (status, index) =>
        `<div class="workflow-step ${status}" ${status === "running" ? 'aria-current="step"' : ""} title="${labels[index]}: ${words[status]}"><b class="step-number">${status === "completed" ? "✓" : status === "failed" ? "!" : index + 1}</b><span>${labels[index]}<small>${words[status]}</small></span></div>`,
    )
    .join("");
  const container = $("#workflowSteps");
  if (container.dataset.signature !== markup) {
    container.innerHTML = markup;
    container.dataset.signature = markup;
  }
}

function showProjectRequirements() {
  const project = (state.projects || []).find(
    (p) => p["Profile ID"] === managedProfile,
  );
  if (!project) return;
  dialog(
    "Project dependencies",
    [
      {
        notice: project["Missing dependencies"]?.length
          ? "Missing or mismatched dependencies"
          : "All required dependencies are installed.",
      },
    ],
    "requirements",
  );
  $("#dialogSubmit").hidden = true;
  $("#form").innerHTML +=
    `<div class="field wide requirement-list">${(project["Missing dependencies"] || []).map((item) => `<div><strong>${esc(item.name)}</strong><span>${esc(item.version)} · ${esc(item.reason)}</span></div>`).join("")}<button type="button" class="btn" onclick="closeDialog();showView('dependencies')">Open Dependencies</button></div>`;
}
function drawProjectManager() {
  const profiles = state.projects || [],
    project =
      profiles.find((p) => p["Profile ID"] === managedProfile) || profiles[0];
  $("#projectManagerCount").textContent = "";
  if (!project) {
    $("#projectManagerList").innerHTML =
      '<div class="manager-empty">Add a project profile to start managing builds.</div>';
    return;
  }
  const arch = String(project.Architectures || "—")
    .split(";")
    .map(
      (x) =>
        ({ arm64: "Apple silicon", x86_64: "Intel" })[x.trim()] || x.trim(),
    )
    .join(" + ");
  const projectContainer = $("#projectManagerList"),
    projectSignature = JSON.stringify([project, profiles.length]);
  if (projectContainer.dataset.signature === projectSignature) return;
  projectContainer.dataset.signature = projectSignature;
  projectContainer.innerHTML = `<article class="project-card"><div><h2>${esc(project["Display name"])}</h2><span class="small">${esc(arch)} · macOS ${esc(project["Minimum macOS"])}+</span></div><button class="version-button" data-conflict onclick="editProjectVersion()" title="Change app version">v${esc(project["App version"])}</button><div class="row-actions"><button class="readiness-badge ${project["Dependency status"] === "ready" ? "ready" : "missing"}" onclick="showProjectRequirements()" title="Project dependency requirements">${project["Dependency status"] === "ready" ? "Ready" : `${project["Missing dependencies"]?.length || 0} missing`}</button><button class="btn" data-conflict onclick="editProjectSettings()">Settings</button><button class="btn danger" data-conflict onclick="removeProjectProfile('${esc(project["Profile ID"])}')" ${profiles.length <= 1 ? "disabled" : ""}>Remove</button></div></article>`;
}
function drawRepositoryManager() {
  const profile = managedProfile,
    project = (state.projects || []).find((p) => p["Profile ID"] === profile),
    all = (state.repositories || [])
      .filter((r) => r["Profile ID"] === profile)
      .sort((a, b) => Number(a.Order || 0) - Number(b.Order || 0)),
    query = ($("#pluginSearch")?.value || "").trim().toLowerCase(),
    filter = $("#pluginFilter")?.value || "all";
  const rows = all.filter(
      (r) =>
        (filter === "all" || r.Group === filter) &&
        (!query ||
          `${r.Repository} ${r.Ref} ${r.Group}`.toLowerCase().includes(query)),
    ),
    plugInCount = all.filter((r) => r.Group !== "core").length;
  $("#repositoryManagerCount").textContent =
    `${plugInCount} plug-in${plugInCount === 1 ? "" : "s"} · ${all.filter((r) => r.Group === "core").length} core`;
  if (!project) {
    $("#repositoryManagerList").innerHTML =
      '<div class="manager-empty">Choose or add a project profile first.</div>';
    return;
  }
  if (!rows.length) {
    $("#pluginsPager").innerHTML = "";
    $("#repositoryManagerList").innerHTML =
      `<div class="manager-empty">${all.length ? "No repository pins match your search." : "No plug-ins or data plug-ins yet. Add one to this project."}</div>`;
    return;
  }
  const container = $("#repositoryManagerList"),
    signature = JSON.stringify({
      profile,
      query,
      filter,
      rows,
      page: listPages.plugins?.index || 0,
      size: fittedPageSize("plugins"),
    });
  if (container.dataset.signature === signature) return;
  container.dataset.signature = signature;
  container.innerHTML = pageRows("plugins", rows, profile + query + filter)
    .map((row) => {
      const core = row.Group === "core",
        type = core
          ? "Core"
          : row.Group === "data_plugin"
            ? "Data plug-in"
            : "Plug-in",
        args = `'${esc(profile)}','${esc(row.Order)}','${esc(row.Repository)}'`;
      return `<article class="manager-repository"><div class="repo-main"><strong title="${esc(type)} · ${esc(row.Repository)}">${esc(row.Repository)}</strong></div><div class="manager-repo-actions"><button class="version-button repo-version" type="button" data-conflict title="Change ${esc(row.Repository)} branch, tag or commit: ${esc(row.Ref)}" onclick="editRepositoryRef(${args})">${esc(row.Ref || "Set version")}</button>${core ? '<span class="manager-pill">Core</span>' : `<button class="btn danger icon-action" data-conflict aria-label="Remove ${esc(row.Repository)}" title="Remove from this project; local files are kept" onclick="removeProjectRepository('${esc(profile)}','${esc(row.Order)}','${esc(row.Repository)}')">×</button>`}</div></article>`;
    })
    .join("");
}
function editRepositoryRef(profile, order, repository) {
  const row = (state.repositories || []).find(
    (r) =>
      r["Profile ID"] === profile &&
      String(r.Order) === String(order) &&
      r.Repository === repository,
  );
  if (!row) return message("Repository pin is no longer available", "warning");
  dialog(
    "Change pinned version",
    [
      { name: "Profile ID", value: profile, hidden: true },
      { name: "Order", value: order, hidden: true },
      {
        name: "Repository",
        label: "Repository",
        value: repository,
        readonly: true,
      },
      {
        name: "Clone URL",
        label: "GitHub source",
        value: row["Clone URL"] || "",
        wide: true,
      },
      {
        name: "Ref",
        label: "Branch, tag, or commit",
        value: row.Ref || "",
        required: true,
        refs: true,
      },
    ],
    "repository-edit",
  );
}
async function fetchGitHubRefChoices() {
  const form = $("#form"),
    url = form
      .querySelector('[name="Source URL"],[name="Clone URL"]')
      ?.value?.trim(),
    input = form.querySelector("#refInput"),
    list = $("#githubRefOptions"),
    status = $("#githubRefStatus");
  status.hidden = false;
  if (!url) {
    status.textContent = "Add a GitHub source URL first.";
    return;
  }
  status.textContent = "Loading branches and tags from GitHub…";
  try {
    const refs = await api(`/api/github-refs?url=${encodeURIComponent(url)}`);
    list.innerHTML = [
      ...(input?.dataset.release === "true" ? [] : refs.branches || []).map(
        (x) =>
          `<option value="${esc(x.name)}" label="Branch · ${esc(x.name)}"></option>`,
      ),
      ...(refs.tags || []).map(
        (x) =>
          `<option value="${esc(input?.dataset.release === "true" ? x.name.replace(/^v(?=\d)/, "") : x.name)}" label="Tag · ${esc(x.name)}"></option>`,
      ),
    ].join("");
    status.textContent = `${refs.branches.length} branches and ${refs.tags.length} tags loaded. Select a suggestion or enter any ref.`;
    input?.focus();
  } catch (error) {
    status.textContent = `Could not fetch refs: ${error.message}`;
  }
}

async function confirmedDelete(kind, values, label) {
  const payload = { kind, values };
  const plan = await api("/api/deletion-plan", {
    method: "POST",
    body: JSON.stringify(payload),
  });
  const messageText = `Permanently delete ${label}?\n\n${plan.files.length ? "Files/folders:\n" + plan.files.join("\n") : "No local files were found."}${plan.affectedProjects.length ? "\n\nAffected projects: " + plan.affectedProjects.join(", ") : ""}${plan.protected.length ? "\n\nShared/external paths are protected and will be kept:\n" + plan.protected.join("\n") : ""}\n\nThis cannot be undone.`;
  if (!confirm(messageText)) return false;
  message(`Deleting ${label}…`, "running");
  await api("/api/remove", {
    method: "POST",
    body: JSON.stringify({ ...payload, deleteFiles: true, confirmed: true }),
  });
  await Promise.all([refreshDependencies(), refreshInstallers(), refresh()]);
  message(`${label} deleted`, "success");
  return true;
}
async function deleteInstaller(id) {
  try {
    await confirmedDelete("installer", { id }, "installer");
  } catch (error) {
    message(error.message, "error");
  }
}
async function removeProjectProfile(profile) {
  try {
    await confirmedDelete("project", { "Profile ID": profile }, "project");
  } catch (error) {
    message(error.message, "error");
  }
}
async function removeProjectRepository(profile, order, repository) {
  try {
    await confirmedDelete(
      "repository",
      { "Profile ID": profile, Order: order, Repository: repository },
      repository,
    );
  } catch (error) {
    message(error.message, "error");
  }
}
function renderDependencies() {
  const all = dependencyState.items || [],
    query = ($("#dependencySearch")?.value || "").trim().toLowerCase(),
    filter = $("#dependencyFilter")?.value || "all";
  const items = all.filter(
    (item) =>
      (filter === "all" ||
        (filter === "recipe"
          ? item.kind === "recipe"
          : item.kind === filter)) &&
      (!query ||
        `${item.name} ${item.version} ${item.detail} ${item.linkage} ${item.sourceUrl || ""}`
          .toLowerCase()
          .includes(query)),
  );
  const ready = all.filter((item) => item.installed).length;
  $("#dependencyCount").textContent = `${ready}/${all.length} ready`;
  $("#dependencySummary").textContent = all.length
    ? `${all.length} tracked · ${ready} ready · ${(dependencyState.cacheFolders || []).length} cached versions`
    : "No dependency scripts or libraries found.";
  if (!items.length) {
    $("#dependencyList").dataset.signature = "";
    $("#dependencyList").innerHTML =
      `<div class="dependency-empty">${all.length ? "No dependencies match this search." : "Add a build library or cached source to see it here."}</div>`;
    return;
  }
  const container = $("#dependencyList");
  const signature = JSON.stringify([items, query, filter]);
  if (container.dataset.signature === signature) return;
  container.dataset.signature = signature;
  container.scrollTop = 0;
  container.innerHTML = items
    .map((item, index) => {
      const original = all.indexOf(item),
        kind =
          item.kind === "pin"
            ? "Source"
            : item.kind === "script"
              ? "Build script"
              : "Build library",
        action =
          item.kind === "script"
            ? "Register script"
            : item.kind === "pin"
              ? "Change version"
              : "Edit recipe",
        stateText = item.installed
          ? "Ready"
          : item.kind === "script"
            ? "Needs setup"
            : item.enabled
              ? "Missing"
              : "Paused";
      const blockers = item.requiredBy || [];
      return `<article class="dependency-row" style="--row-index:${index}"><div><div class="dependency-main"><span class="dependency-name">${esc(item.name)}</span><span class="dependency-state ${item.installed ? "ready" : ""}">${item.installed ? "Installed" : "Not installed"}</span></div><div class="dependency-details"><button data-conflict onclick="editDependencyVersion(${original})" title="Change version">${esc(item.version || "Set version")}</button><span class="type-label">${esc(kind)}</span><span class="usage-count" title="${esc((item.projects || []).map((p) => `${p.name}: ${p.version}`).join(" · ") || "No projects require this dependency")}">${(item.projects || []).length} projects</span></div></div><div class="dependency-actions"><button class="btn ${item.installed ? "danger" : "primary"}" data-conflict onclick="dependencyAction(${original},'${item.installed ? "uninstall" : "install"}')" ${item.installed && blockers.length ? `disabled title="Required by ${esc(blockers.join(", "))}"` : ""}>${item.installed ? "Uninstall" : "Install"}</button><button class="btn icon-action" data-conflict onclick="manageDependency(${original})" aria-label="Settings for ${esc(item.name)}" title="Settings">⚙</button><button class="btn danger icon-action" data-conflict onclick="removeLibrary(${original})" aria-label="Remove ${esc(item.name)} from catalog" title="Remove registration">×</button></div></article>`;
    })
    .join("");
}

async function refreshDependencies() {
  if (dependencyLoading) return;
  dependencyLoading = true;
  $("#dependencySummary").textContent = "Checking local dependency versions…";
  try {
    dependencyState = await api("/api/dependencies");
    dependencyLoaded = true;
    renderDependencies();
  } catch (error) {
    $("#dependencyCount").textContent = "Unavailable";
    $("#dependencySummary").textContent =
      `Could not load dependencies: ${error.message}`;
    $("#dependencyList").innerHTML =
      '<div class="dependency-empty">Check that the installer dashboard is running, then refresh.</div>';
    message("Dependency inventory could not be loaded", "error", error.message);
  } finally {
    dependencyLoading = false;
  }
}
function newPinnedDependency(name = "", existing = null, versionOnly = false) {
  const caches = dependencyState.cacheFolders || [],
    suggested = existing?.sourceUrl || "",
    cacheFolder = existing?.source || "";
  dialog(
    existing ? "Add or upgrade cached source" : "Add dependency source",
    [
      {
        section: "Add a reusable source version",
        help: "Register a version, then use Install in Dependencies.",
      },
      {
        name: "Name",
        label: "Dependency name",
        value: name || existing?.name || "",
        hidden: Boolean(existing),
        required: true,
      },
      {
        name: "Version",
        label: "Branch, tag, or commit",
        value: existing?.version || "",
        required: true,
        refs: true,
      },
      {
        name: "Source URL",
        label: "GitHub repository",
        value: suggested,
        wide: true,
        required: !existing?.source,
      },
      {
        name: "Source folder",
        label: "Cache folder (optional)",
        value: cacheFolder,
      },
      {
        name: "Integration",
        label: "CMake integration",
        options: ["CPM", "FetchContent"],
        value: existing?.linkage === "FetchContent" ? "FetchContent" : "CPM",
      },
      {
        name: "CMake source variable",
        label: "Optional CMake variable",
        value: existing?.cmake_variable || "",
      },
    ],
    "dependency-pin",
  );
  appendUsageFields(existing, versionOnly);
}

function newDependency(seed = {}) {
  const name = seed.Name || "",
    version = seed["Version / commit"] || "",
    source = seed["Source URL"] || "",
    script = seed["Build Script"] || "GENERIC";
  dialog(
    "Add a build library",
    [
      {
        section: "Register a reusable library",
        help: "New recipes get a reusable build script. Existing dependency shell scripts are listed automatically.",
      },
      {
        name: "Name",
        label: "Library name",
        value: name,
        required: true,
      },
      {
        name: "Version / commit",
        label: "Version, branch, or commit",
        value: version,
        required: true,
        refs: true,
      },
      {
        name: "Source URL",
        label: "GitHub repository",
        value: source,
        wide: true,
        required: script === "GENERIC",
      },
      {
        name: "Linkage",
        label: "Library type",
        options: ["static", "shared", "both", "header-only"],
        value: seed.Linkage || "static",
      },
      {
        name: "Build Script",
        label: "Build script",
        value: script,
        readonly: true,
      },
      {
        name: "Enabled",
        label: "Use in project builds",
        checkbox: true,
        value: true,
      },
      {
        name: "Artifacts JSON",
        label: "Expected build outputs",
        value: "[]",
        multiline: true,
        wide: true,
      },
      {
        name: "Runtime Files JSON",
        label: "Files copied into the app",
        value: "[]",
        multiline: true,
        wide: true,
      },
      {
        name: "Requires JSON",
        label: "Prerequisite library names",
        value: "[]",
        multiline: true,
        wide: true,
      },
      {
        name: "Recipe JSON",
        label: "Optional advanced build recipe",
        value: "{}",
        multiline: true,
        wide: true,
      },
    ],
    "dependency",
  );
  appendUsageFields(null);
}
async function dependencyAction(index, operation) {
  const item = dependencyState.items[index];
  if (
    operation === "uninstall" &&
    !confirm(
      `Uninstall ${item.name}? ${(item.projects || []).length} project(s) will show it as missing. Files move to local recovery storage; the catalog entry stays.`,
    )
  )
    return;
  try {
    await api("/api/run", {
      method: "POST",
      body: JSON.stringify({
        action: `${operation}-dependency`,
        profile: "workspace",
        name: item.name,
        kind: item.kind,
        jobs: buildJobs(),
      }),
    });
    message(
      `${operation === "install" ? "Installing" : "Uninstalling"} ${item.name}`,
      "running",
    );
    showView("activity");
    dependencyLoaded = false;
    await refresh();
  } catch (error) {
    message(error.message, "error");
  }
}
function appendUsageFields(item, versionOnly = false) {
  const fields = [...schema, ...projectUsageFields(item, versionOnly)];
  dialog($("#dialogTitle").textContent, fields, dialogKind);
}
function projectUsageFields(item, versionOnly = false) {
  const projects = item?.projects || [];
  const fields = [];
  if (projects.length)
    fields.push({
      notice: `Used by ${projects.length} project${projects.length === 1 ? "" : "s"}: ${projects.map((p) => p.name).join(", ")}`,
    });
  if (item)
    fields.push({
      name: "Update projects",
      label: "When the version changes",
      options: [
        ["Update affected project requirements", "true"],
        ["Keep current project requirements", "false"],
      ],
      value: "true",
    });
  if (!versionOnly)
    fields.push({
      name: "Projects",
      label: "Used by projects",
      multi: true,
      options: (
        dependencyState.projects ||
        (state.projects || []).map((p) => ({
          id: p["Profile ID"],
          name: p["Display name"],
        }))
      ).map((p) => [p.name, p.id]),
      value: projects.map((p) => p.id),
    });
  return fields;
}
function editDependencyVersion(index) {
  const item = dependencyState.items[index];
  if (item.kind === "pin") {
    newPinnedDependency(item.name, item, true);
    return;
  }
  dialog(
    `${item.name} version`,
    [
      { name: "Name", value: item.name, hidden: true },
      {
        name: "Version / commit",
        label: [
          "openmp",
          "lz4",
          "flann",
          "cups",
          "qads",
          "fmt",
          "glfw",
          "libpng",
          "imagemagick",
        ].includes(item.name)
          ? "Release version"
          : item.name === "hdf5-zlib"
            ? "Library versions"
            : "Version, tag or commit",
        value: item.version,
        required: true,
        refs: ![
          "openmp",
          "lz4",
          "flann",
          "cups",
          "qads",
          "fmt",
          "glfw",
          "libpng",
          "imagemagick",
          "hdf5-zlib",
        ].includes(item.name),
      },
      {
        name: "Source URL",
        label: "Source URL",
        value: item.sourceUrl || "",
        hidden: true,
      },
      ...projectUsageFields(item, true),
    ],
    "dependency-version",
  );
}
async function removeLibrary(index) {
  const item = dependencyState.items[index];
  try {
    await confirmedDelete(
      item.kind === "pin" ? "dependency-pin" : "dependency",
      { Name: item.name },
      item.name,
    );
  } catch (error) {
    message(error.message, "error");
  }
}
function manageDependency(index) {
  const item = (dependencyState.items || [])[index];
  if (!item) return;
  if (item.kind === "pin") {
    newPinnedDependency(item.name, item);
    return;
  }
  if (item.kind === "script") {
    newDependency({
      Name: item.name,
      "Version / commit": item.version === "Unpinned" ? "" : item.version,
      "Source URL": item.sourceUrl || "",
      "Build Script": item.detail,
      Linkage: "shared",
    });
    return;
  }
  dialog(
    `Edit ${item.name}`,
    [
      {
        section: "Version and build recipe",
        help: "Choose a GitHub tag or branch, or type a commit. Other cached versions are kept.",
      },
      {
        name: "Name",
        label: "Dependency name",
        value: item.name,
        readonly: true,
      },
      {
        name: "Version / commit",
        label: "Pinned version or commit",
        value: item.version,
        required: true,
        refs: ![
          "openmp",
          "lz4",
          "flann",
          "cups",
          "qads",
          "fmt",
          "glfw",
          "libpng",
          "imagemagick",
          "hdf5-zlib",
        ].includes(item.name),
      },
      {
        name: "Source URL",
        label: "GitHub source",
        value: item.sourceUrl || "",
        wide: true,
      },
      {
        name: "Enabled",
        label: "Build this library",
        checkbox: true,
        value: item.enabled,
      },
      {
        name: "Linkage",
        label: "Library type",
        options: ["static", "shared", "both", "header-only"],
        value: item.linkage || "shared",
      },
      {
        name: "Build Script",
        label: "Build script",
        value: item.detail || "GENERIC",
        readonly: true,
      },
      {
        name: "Artifacts JSON",
        label: "Expected build outputs",
        value: JSON.stringify(item.artifacts || []),
        multiline: true,
        wide: true,
      },
      {
        name: "Runtime Files JSON",
        label: "Files copied into the app",
        value: JSON.stringify(item.runtimeArtifacts || []),
        multiline: true,
        wide: true,
      },
      {
        name: "Requires JSON",
        label: "Prerequisite libraries",
        value: JSON.stringify(item.requires || []),
        multiline: true,
        wide: true,
      },
      {
        name: "Recipe JSON",
        label: "Build recipe",
        value: JSON.stringify(item.recipe || {}, null, 2),
        multiline: true,
        wide: true,
      },
    ],
    "dependency-recipe",
  );
  appendUsageFields(item);
}

async function refresh() {
  if (refreshInFlight) return;
  refreshInFlight = true;

  try {
    const previous = state;
    const incoming = await api(
      `/api/state?run=${encodeURIComponent(selectedRun || "")}&logs=${currentView === "activity" ? "1" : "0"}&logRevision=${encodeURIComponent(state.logRevision || "")}`,
    );
    state = {
      ...incoming,
      logs: incoming.logs ?? previous.logs ?? [],
      logRunId: incoming.logRunId ?? previous.logRunId,
      logRevision: incoming.logRevision ?? previous.logRevision,
    };
    const old = selectedRun;
    const select = $("#project"),
      cur =
        pendingProfile ||
        select.value ||
        localStorage.getItem("preferredProfile"),
      projects = state.projects || [],
      names = new Set(
        projects
          .filter(
            (p) =>
              projects.filter(
                (q) =>
                  (q["Display name"] || q["Profile ID"]) ===
                  (p["Display name"] || p["Profile ID"]),
              ).length > 1,
          )
          .map((p) => p["Display name"] || p["Profile ID"]),
      );
    const projectOptions = projects
      .map(
        (p) =>
          `<option value="${esc(p["Profile ID"])}" title="${esc(p["Profile ID"])}">${esc(projectOptionLabel(p, names))}</option>`,
      )
      .join("");
    if (select.dataset.signature !== projectOptions) {
      select.innerHTML = projectOptions;
      select.dataset.signature = projectOptions;
    }
    if (cur && [...select.options].some((o) => o.value === cur))
      select.value = cur;
    if (select.value === pendingProfile) pendingProfile = "";
    updateProject();
    if (!dependencyLoaded && currentView === "dependencies")
      refreshDependencies();
    if (typeof drawFolderSettings === "function") drawFolderSettings();
    if (currentView === "activity") drawRuns();
    if (
      currentView === "activity" &&
      old &&
      (state.runs || []).some((r) => r["Run ID"] === old)
    )
      selectRun(old);
    else if (currentView === "activity" && state.runs?.length)
      selectRun(state.runs[state.runs.length - 1]["Run ID"]);
    lastRefreshError = "";
    workspaceReady = true;
    document.body.classList.remove("page-loading", "load-failed");
    // Installer inventory is refreshed separately, not on every state poll.
    const active = Boolean(state.live?.active);
    $("#activityIndicator").hidden = !active;
    document.querySelector(".history").classList.toggle("has-current", active);
    drawProgress(active ? state.live : null);
    setBusy(active);
    if (active)
      message(
        state.live.paused
          ? "Build is paused"
          : `${state.live.action} is running`,
        state.live.paused ? "warning" : "running",
        state.live.output?.slice(-1)[0] ||
          "Live output is appearing in Activity",
      );
    else if (state.live) {
      const key = `${state.live.run_id}:${state.live.status}`;
      if (key !== lastStatusKey) {
        lastStatusKey = key;
        dependencyLoaded = false;
        refreshDependencies();
        const tone =
          state.live.status === "failed"
            ? "error"
            : state.live.status === "needs-attention"
              ? "warning"
              : "success";
        message(
          state.live.status === "failed"
            ? "The latest operation failed"
            : state.live.status === "needs-attention"
              ? "Setup needs attention"
              : "The latest operation completed",
          tone,
          state.live.output?.slice(-1)[0] ||
            "Select an activity for the full diagnostic record",
        );
      }
    }
  } catch (e) {
    const description = e.dataRequest
      ? `Workspace could not refresh · ${e.message}`
      : "The interface could not update. Reload this page to get the latest version.";
    if (lastRefreshError !== description) {
      message(description, "error");
      lastRefreshError = description;
    }
    document.body.classList.add("load-failed");
  } finally {
    refreshInFlight = false;
    document.body.classList.remove("page-loading");
    scheduleWorkspacePoll();
  }
}
async function copyRun() {
  if (!selectedRecord) {
    message("Choose an activity to copy its debugging details.", "warning");
    return;
  }
  const r = selectedRecord,
    logs = (state.logs || []).filter((x) => x["Run ID"] === selectedRun);
  const text = [
    "MANIVAULT INSTALLER RUN DETAILS",
    `Project: ${r["Profile ID"]}`,
    `Action: ${r.Action}`,
    `Status: ${r.Status}`,
    `Run ID: ${selectedRun}`,
    `Summary: ${r.Summary || ""}`,
    "",
    "ACTIVITY · FULL LOG",
    ...logs.map((x) => `[${x.Level}] [${x.Stage}] ${x.Message}`),
  ].join("\n");
  try {
    await navigator.clipboard.writeText(text);
    message("Full run and log copied to the clipboard.", "success");
  } catch {
    message(
      "Clipboard access was unavailable. Select and copy the activity details.",
      "warning",
    );
  }
}
async function copyVisibleLogs() {
  if (!selectedRecord) return message("Choose an activity first.", "warning");
  const entries = [...document.querySelectorAll("#detail .log")].map(
    (el) => el.innerText,
  );
  try {
    await navigator.clipboard.writeText(entries.join("\n"));
    message(`${entries.length} visible log entries copied.`, "success");
  } catch {
    message("Clipboard access was unavailable.", "warning");
  }
}
async function deleteSelected(kind) {
  if (!selectedRun || !selectedRecord) return;
  const verb = kind === "run" ? "run and its logs" : "all logs for this run";
  if (!confirm(`Delete ${verb}? This cannot be undone.`)) return;
  try {
    await api("/api/remove", {
      method: "POST",
      body: JSON.stringify({ kind, values: { "Run ID": selectedRun } }),
    });
    logSelections.delete(selectedRun);
    logAnchors.delete(selectedRun);
    selectedRun = null;
    selectedRecord = null;
    await refresh();
    message(
      kind === "run" ? "Run and logs deleted." : "Run logs deleted.",
      "success",
    );
  } catch (e) {
    message(e.message, "error");
  }
}
function showBuildSection(section) {
  buildSection = section;
  localStorage.setItem("buildSection", section);
  showView("build");
}
function showView(view) {
  hideTooltip();
  if (view === "projects") {
    view = "build";
    buildSection = "project";
    localStorage.setItem("buildSection", buildSection);
  }
  if (view !== "activity" && $("#detail").querySelector(".log-viewport")) {
    $("#detail").innerHTML = "";
    $("#detail").dataset.signature = "";
  }
  currentView = view;
  const context = {
    build: [
      "Build workflow",
      (state.projects || []).find(
        (p) => p["Profile ID"] === selectedProfile(),
      )?.["Display name"] || "Selected project",
    ],
    dependencies: ["Dependencies", "Shared across all projects"],
    installers: ["Installers", "Workspace output"],
    activity: ["Activity", "All projects and workspace operations"],
  }[view];
  document.body.dataset.view = view;
  $("#buildSections").hidden = view !== "build";
  $("#addMenu").hidden = !["build", "dependencies"].includes(view);
  $("#addMenu")
    .querySelectorAll("[data-add-scope]")
    .forEach((el) => (el.hidden = el.dataset.addScope !== view));
  const livePanel = $("#livePanel");
  if (livePanel)
    (view === "build" && buildSection === "workflow"
      ? $("#buildLive")
      : $("#activityLiveSlot")
    ).append(livePanel);
  $("#workspaceTitle").textContent = context[0];
  $("#workspaceScope").textContent = context[1];
  document
    .querySelectorAll(".workspace-view")
    .forEach(
      (el) =>
        (el.hidden =
          view === "build"
            ? el.id !==
              (buildSection === "project" ? "view-projects" : "view-build")
            : el.id !== `view-${view}`),
    );
  document.querySelectorAll(".tab[data-view]").forEach((el) => {
    el.classList.toggle("active", el.dataset.view === view);
    el.setAttribute(
      "aria-current",
      el.dataset.view === view ? "page" : "false",
    );
  });
  document
    .querySelectorAll("[data-build-section]")
    .forEach((el) =>
      el.classList.toggle("active", el.dataset.buildSection === buildSection),
    );
  document.querySelector(".workspace-scroll").scrollTop = 0;
  document.querySelector(".app-layout").scrollTop = 0;
  document.body.dataset.buildSection = buildSection;
  fitVisibleLists();
  localStorage.setItem("workspaceView", view);
  if (view === "dependencies" && !dependencyLoaded) refreshDependencies();
  if (view === "activity") {
    drawRuns();
    if (state.runs?.length)
      selectRun(selectedRun || state.runs.at(-1)["Run ID"]);
  }
  if (view === "build") updateProject();
}
let themeTransitionTimer;
function setTheme(value) {
  document.body.classList.add("theme-changing");
  clearTimeout(themeTransitionTimer);
  themeTransitionTimer = setTimeout(
    () => document.body.classList.remove("theme-changing"),
    450,
  );
  localStorage.setItem("uiTheme", value);
  applyUiPreferences();
}
document.addEventListener("pointerdown", (event) => {
  const button = event.target.closest(
    "button.btn.primary,button.tab,button.section-tab",
  );
  if (
    !button ||
    button.disabled ||
    document.body.classList.contains("reduce-motion") ||
    matchMedia("(prefers-reduced-motion: reduce)").matches
  )
    return;
  const bounds = button.getBoundingClientRect();
  const wave = document.createElement("i");
  wave.className = "press-wave";
  wave.setAttribute("aria-hidden", "true");
  const size = Math.max(bounds.width, bounds.height) * 2;
  wave.style.width = wave.style.height = `${size}px`;
  wave.style.left = `${event.clientX - bounds.left - size / 2}px`;
  wave.style.top = `${event.clientY - bounds.top - size / 2}px`;
  button.append(wave);
  setTimeout(() => wave.remove(), 500);
});

let knownInstances = [];
let instanceDiscoveryAvailable = true;
async function refreshInstances() {
  try {
    const response = await fetch("/api/instances");
    if (response.status === 404) {
      instanceDiscoveryAvailable = false;
      const health = await fetch("/api/health").then((response) =>
        response.json(),
      );
      knownInstances = [
        {
          pid: health.pid,
          port: health.port,
          current: true,
          responding: true,
          canStop: false,
          terminalCommand: `kill ${health.pid}`,
        },
      ];
    } else {
      if (!response.ok) throw Error("Instance discovery unavailable");
      knownInstances = (await response.json()).instances || [];
      instanceDiscoveryAvailable = true;
    }
    $("#instanceCount").textContent = String(knownInstances.length);
    $("#instanceButton").title =
      `${knownInstances.length} ${instanceDiscoveryAvailable ? "app instance(s) running" : "connected instance; restart app to discover other copies"}. View ports and stop options.`;
  } catch (error) {
    $("#instanceCount").textContent = "?";
  }
}
async function openInstances() {
  await refreshInstances();
  dialog("App instances", [], "instances");
  $("#dialogSubmit").hidden = true;
  $("#form").innerHTML =
    `<div class="field wide instance-help">${instanceDiscoveryAvailable ? "Servers running for your user account on this Mac." : "Restart the app after the current build finishes to enable discovery and stop controls."} The last instance is stopped from Terminal.</div><div class="field wide instance-list">${knownInstances.map((item) => `<article class="instance-card"><div><strong>Port ${item.port}${item.current ? " · This window" : ""}</strong><span class="small">PID ${item.pid} · ${item.busy ? "Build running" : item.responding ? "Responding" : "Not responding"}</span><span class="small instance-path" title="${esc(item.workspace || "")}">${esc(item.workspace?.split("/").at(-1) || "Current workspace")}</span></div><div class="row-actions"><button type="button" class="btn" data-safe-while-busy onclick="copyInstanceCommand(${item.pid})" title="Copy a terminal command to stop this process">Terminal command</button><button type="button" class="btn danger" data-safe-while-busy ${item.canStop ? "" : "disabled"} onclick="stopInstance(${item.pid})" title="${item.busy ? "Finish or stop the running build first" : !item.canStop ? "The last instance is protected; use Terminal" : "Stop this app server"}">Stop</button></div></article>`).join("")}</div>`;
}
async function copyInstanceCommand(pid) {
  await navigator.clipboard.writeText(`kill ${pid}`);
  message("Terminal command copied", "success");
}
async function stopInstance(pid) {
  const target = knownInstances.find((item) => item.pid === pid);
  if (
    !target?.canStop ||
    !confirm(`Stop the app instance on port ${target.port} (PID ${pid})?`)
  )
    return;
  const remaining = knownInstances.find(
    (item) => item.pid !== pid && item.responding,
  );
  try {
    await api("/api/instances/stop", {
      method: "POST",
      body: JSON.stringify({ pid, confirmed: true }),
    });
    if (target.current && remaining) {
      location.assign(`http://127.0.0.1:${remaining.port}/`);
      return;
    }
    await openInstances();
    message("App instance stopped", "success");
  } catch (error) {
    if (target.current && remaining) {
      try {
        await fetch("/api/health", { signal: AbortSignal.timeout(1500) });
      } catch {
        location.assign(`http://127.0.0.1:${remaining.port}/`);
        return;
      }
    }
    message(error.message, "error");
  }
}
let schema = [],
  dialogKind = "";
function dialog(title, fields, kind = "") {
  $("#dialogError").hidden = true;
  $("#addMenu").open = false;
  $("#dialogSubmit").hidden = false;
  if ($("#dialog").open) $("#dialog").close();
  $("#dialogTitle").textContent = title;
  schema = fields;
  const releaseOnly = [
    "openmp",
    "lz4",
    "flann",
    "cups",
    "qads",
    "fmt",
    "glfw",
    "libpng",
    "imagemagick",
  ].includes(fields.find((field) => field.name === "Name")?.value);
  dialogKind =
    kind ||
    (title.startsWith("Create")
      ? "project"
      : title.startsWith("Add a pinned")
        ? "repository"
        : "dependency");
  $("#dialogSubmit").textContent =
    {
      preferences: "Save preferences",
      project: "Create profile",
      "project-edit": "Save settings",
      "create-installer": "Create installer",
      repository: "Add repository",
      "repository-edit": "Save version",
      dependency: "Add build library",
      "dependency-pin": "Save version",
      "dependency-recipe": "Save changes",
      "dependency-version": "Save version",
    }[dialogKind] || "Save";
  $("#form").innerHTML = fields
    .map((f) => {
      if (f.hidden)
        return `<input type="hidden" name="${esc(f.name)}" value="${esc(f.value || "")}">`;
      if (f.section) return "";
      if (f.notice)
        return `<div class="impact-note wide">${esc(f.notice)}</div>`;
      if (f.multi)
        return `<details class="field wide"><summary>${esc(f.label)}</summary><div class="project-checks">${f.options.map((option) => `<label class="check"><input type="checkbox" data-multiple name="${esc(f.name)}" value="${esc(option[1])}" ${(f.value || []).includes(option[1]) ? "checked" : ""}>${esc(option[0])}</label>`).join("")}</div></details>`;
      if (f.checkbox)
        return `<div class="field wide"><label class="check"><input type="checkbox" name="${esc(f.name)}" ${f.value ? "checked" : ""}> ${esc(f.label)}</label></div>`;
      const listField = f.multiline && f.name !== "Recipe JSON";
      let fieldValue = f.value || "";
      if (listField) {
        try {
          fieldValue = JSON.parse(fieldValue).join("\n");
        } catch {}
      }
      const input = f.multiline
        ? `<textarea name="${esc(f.name)}" rows="4" ${f.required ? "required" : ""} placeholder="${listField ? "One item per line" : ""}">${esc(fieldValue)}</textarea>`
        : f.refs
          ? `<div class="ref-picker"><input id="refInput" data-release="${releaseOnly}" name="${esc(f.name)}" list="githubRefOptions" value="${esc(f.value || "")}" ${f.required ? "required" : ""}><button type="button" class="btn" onclick="fetchGitHubRefChoices()">Fetch GitHub refs</button><datalist id="githubRefOptions"></datalist><small id="githubRefStatus" class="small wide" hidden>Fetch available branches and tags or type a commit.</small></div>`
          : f.options
            ? `<select name="${esc(f.name)}">${f.options
                .map((o) => {
                  const value = Array.isArray(o) ? o[1] : o,
                    label = Array.isArray(o) ? o[0] : o;
                  return `<option value="${esc(value)}" ${String(value) === String(f.value) ? "selected" : ""}>${esc(label)}</option>`;
                })
                .join("")}</select>`
            : f.path
              ? `<div class="path-field"><input id="path-${esc(f.name)}" name="${esc(f.name)}" value="${esc(f.value || "")}" ${f.required ? "required" : ""}><button type="button" class="btn" onclick="browsePath('${esc(f.name)}')" title="Choose this folder in Finder">Choose…</button><button type="button" class="btn" onclick="openPath('${esc(f.name)}')" title="Open this folder in Finder">Show in Finder</button></div>`
              : `<input name="${esc(f.name)}" value="${esc(f.value || "")}" ${f.required ? "required" : ""} ${f.readonly ? "readonly" : ""}>`;
      const fieldId = f.refs
        ? "refInput"
        : f.path
          ? `path-${f.name}`
          : `field-${f.name.replace(/[^a-z0-9]/gi, "-")}`;
      const accessibleInput =
        f.refs || f.path
          ? input
          : input.replace(
              /^(<input|<select|<textarea)/,
              `$1 id="${esc(fieldId)}"`,
            );
      const field = `<div class="field ${f.wide ? "wide" : ""}"><label for="${esc(fieldId)}">${esc(f.label)}</label>${accessibleInput}</div>`;
      return (dialogKind === "project-edit" &&
        ![
          "Display name",
          "App version",
          "Architectures",
          "Build type",
        ].includes(f.name)) ||
        f.multiline ||
        ([
          "Source folder",
          "Integration",
          "CMake source variable",
          "Build Script",
        ].includes(f.name) &&
          !f.hidden)
        ? `<details class="field wide"><summary>${esc(f.label)}</summary>${field}</details>`
        : field;
    })
    .join("");
  const sourceInput = $("#form").querySelector('[name="Source URL"]');
  const nameInput = $("#form").querySelector('[name="Name"]');
  if (sourceInput && nameInput && !nameInput.value) {
    nameInput.addEventListener("input", () => (nameInput.dataset.manual = "1"));
    sourceInput.addEventListener("input", () => {
      const match = sourceInput.value
        .trim()
        .match(/github\.com[/:][^/]+\/([^/#?]+)/);
      if (match && !nameInput.dataset.manual)
        nameInput.value = match[1].replace(/\.git$/, "");
    });
  }
  $("#dialog").showModal();
}
function applyUiPreferences() {
  const theme = localStorage.getItem("uiTheme") || "system",
    resolved =
      theme === "system"
        ? matchMedia("(prefers-color-scheme: dark)").matches
          ? "dark"
          : "light"
        : theme,
    dark = ["dark", "ocean", "graphite", "midnight", "aurora"].includes(
      resolved,
    );
  document.body.dataset.theme = resolved;
  if ($("#themePicker")) $("#themePicker").value = theme;
  document.body.classList.toggle("dark-theme", resolved === "dark");
  document.body.classList.toggle("ocean-theme", resolved === "ocean");
  document.body.classList.toggle("graphite-theme", resolved === "graphite");
  document.body.classList.toggle("sand-theme", resolved === "sand");
  document.body.classList.toggle("forest-theme", resolved === "forest");
  document.body.classList.toggle("sunset-theme", resolved === "sunset");
  document.body.classList.toggle(
    "compact-ui",
    (localStorage.getItem("uiDensity") || "comfortable") === "compact",
  );
  document.body.classList.toggle(
    "reduce-motion",
    (localStorage.getItem("uiMotion") || "standard") === "reduced",
  );
  document.body.classList.toggle(
    "expressive-motion",
    localStorage.getItem("uiMotion") === "expressive",
  );
  document.body.classList.toggle(
    "large-text",
    localStorage.getItem("uiTextSize") === "large",
  );
  document.body.classList.toggle(
    "solid-surfaces",
    localStorage.getItem("uiSurface") === "solid",
  );
}
function openPreferences() {
  dialog(
    "Appearance settings",
    [
      {
        section: "Appearance",
        help: "Appearance and animation preferences are remembered on this browser.",
      },
      {
        name: "density",
        label: "Layout density",
        options: [
          ["Comfortable", "comfortable"],
          ["Compact", "compact"],
        ],
        value: localStorage.getItem("uiDensity") || "comfortable",
      },
      {
        name: "motion",
        label: "Animations",
        options: [
          ["Expressive motion", "expressive"],
          ["Standard motion", "standard"],
          ["Reduced motion", "reduced"],
        ],
        value: localStorage.getItem("uiMotion") || "standard",
      },
      {
        name: "textSize",
        label: "Text size",
        options: [
          ["Standard", "standard"],
          ["Larger", "large"],
        ],
        value: localStorage.getItem("uiTextSize") || "standard",
      },
      {
        name: "surface",
        label: "Surface style",
        options: [
          ["Soft depth", "soft"],
          ["Solid — less transparency", "solid"],
        ],
        value: localStorage.getItem("uiSurface") || "soft",
      },
    ],
    "preferences",
  );
  document
    .querySelectorAll(
      "#dialog button,#dialog input,#dialog select,#dialog textarea",
    )
    .forEach((el) => {
      el.disabled = el.dataset.idleDisabled === "true";
    });
  setBusy(Boolean(state.live?.active));
}
async function browsePath(name) {
  try {
    const data = await api("/api/browse-folder", {
      method: "POST",
      body: JSON.stringify({ name }),
    });
    const field = folderField(name);
    if (field) {
      field.value = data.path;
      field.dispatchEvent(new Event("input", { bubbles: true }));
    }
  } catch (e) {
    if (!/cancel/i.test(e.message)) message(e.message, "error");
  }
}
async function openPath(name) {
  try {
    const field = folderField(name);
    const data = await api("/api/open-folder", {
      method: "POST",
      body: JSON.stringify({ name, path: field?.value || "" }),
    });
    message("Folder opened in Finder", "success", data.path);
  } catch (e) {
    message(e.message, "error");
  }
}
document.addEventListener("input", (event) => {
  if (event.target.classList.contains("folder-path")) {
    folderDirty = true;
    $("#saveFolders").disabled = Boolean(state.live?.active);
  }
});
function closeDialog() {
  if (formSaving) return;
  $("#dialog").close();
}
function projectTemplateOptions() {
  return (state.projects || []).map((p) => {
    const names = new Set(
      (state.projects || []).map((q) => q["Display name"] || q["Profile ID"]),
    );
    return [projectOptionLabel(p, names), p["Profile ID"]];
  });
}
function newRepository() {
  const p = (state.projects || []).find(
      (x) => x["Profile ID"] === managedProfile,
    ),
    base = String(
      p?.["Repository base URL"] || "https://github.com/ManiVaultStudio",
    ).replace(/\/$/, "");
  dialog(
    "Add a repository",
    [
      {
        section: "Add a repository to this project",
        help: "Pin a branch, tag, or commit. You can fetch current refs from GitHub.",
      },
      {
        name: "Profile ID",
        label: "Project",
        options: (state.projects || []).map((p) => [
          projectOptionLabel(p, new Set()),
          p["Profile ID"],
        ]),
        value: managedProfile,
      },
      {
        name: "Group",
        label: "Repository type",
        options: [
          ["Plug-in", "plugin"],
          ["Data plug-in", "data_plugin"],
        ],
        value: "plugin",
      },
      { name: "Repository", label: "Repository name", required: true },
      {
        name: "Clone URL",
        label: "GitHub source",
        value: base + "/",
        wide: true,
      },
      {
        name: "Ref",
        label: "Branch, tag, or commit",
        value: p?.["Core ref"] || "main",
        required: true,
        refs: true,
      },
    ],
    "repository",
  );
  const repo = $("#form").querySelector('[name="Repository"]'),
    url = $("#form").querySelector('[name="Clone URL"]');
  repo.addEventListener("input", () => {
    if (!url.dataset.touched)
      url.value = base + "/" + repo.value.trim() + ".git";
  });
  url.addEventListener("input", () => {
    url.dataset.touched = "1";
    const match = url.value.trim().match(/github\.com[/:][^/]+\/([^/#?]+)/);
    if (match) repo.value = match[1].replace(/\.git$/, "");
  });
}

function newProject() {
  const templates = state.projects || [],
    defaultTemplate =
      templates.find((p) => p["Profile ID"] === managedProfile) || templates[0];
  dialog(
    "Add a project profile",
    [
      {
        section: "Start from a working project",
        help: "Settings, repository pins, and installer materials are copied from the selected profile. You only need to set the project name, ID, and version.",
      },
      {
        name: "Display name",
        label: "Project name",
        value: "",
        required: true,
      },
      {
        name: "Profile ID",
        label: "Short project ID",
        value: "",
        required: true,
      },
      {
        name: "App version",
        label: "Version",
        value: defaultTemplate?.["App version"] || "1.0.0",
        required: true,
      },
      {
        name: "Template profile",
        label: "Copy settings from",
        options: projectTemplateOptions(),
        value: defaultTemplate?.["Profile ID"] || "",
      },
    ],
    "project",
  );
  const form = $("#form"),
    name = form.querySelector('[name="Display name"]'),
    id = form.querySelector('[name="Profile ID"]'),
    version = form.querySelector('[name="App version"]'),
    template = form.querySelector('[name="Template profile"]');
  let manuallyEdited = false;
  id.addEventListener("input", () => {
    manuallyEdited = true;
  });
  name.addEventListener("input", () => {
    if (!manuallyEdited)
      id.value = name.value
        .toLowerCase()
        .normalize("NFKD")
        .replace(/[^a-z0-9]+/g, "-")
        .replace(/^-|-$/g, "");
  });
  template.addEventListener("change", () => {
    const project = templates.find((p) => p["Profile ID"] === template.value);
    if (project) version.value = project["App version"] || "1.0.0";
  });
}
function editProjectVersion() {
  const project = (state.projects || []).find(
    (p) => p["Profile ID"] === managedProfile,
  );
  if (!project) return;
  dialog(
    "App version",
    [
      { name: "Profile ID", value: project["Profile ID"], hidden: true },
      {
        name: "App version",
        label: "Version",
        value: project["App version"],
        required: true,
      },
    ],
    "project-edit",
  );
}
function editProjectSettings() {
  const p = (state.projects || []).find(
    (item) => item["Profile ID"] === managedProfile,
  );
  if (!p) return message("Choose a project profile first.", "warning");
  dialog(
    `Edit ${p["Display name"]} settings`,
    [
      {
        section: "Project configuration",
        help: "These settings apply to the selected profile only. Repository pins and installer materials are managed in their own tabs.",
      },
      {
        name: "Profile ID",
        label: "Project ID",
        value: p["Profile ID"],
        hidden: true,
      },
      {
        name: "Display name",
        label: "Project name",
        value: p["Display name"],
      },
      { name: "App version", label: "Version", value: p["App version"] },
      {
        name: "Architectures",
        label: "Architectures (semicolon separated)",
        value: p.Architectures,
      },
      {
        name: "Minimum macOS",
        label: "Minimum macOS version",
        value: p["Minimum macOS"],
      },
      {
        name: "Minimum core version",
        label: "Minimum core version",
        value: p["Minimum core version"],
      },
      {
        name: "Core source directory",
        label: "Core source folder (optional)",
        value: p["Core source directory"] || "",
        path: true,
        wide: true,
      },
      {
        name: "Build type",
        label: "Build type",
        options: ["Release", "RelWithDebInfo", "Debug"],
        value: p["Build type"],
      },
      {
        name: "Repository base URL",
        label: "Repository base URL",
        value: p["Repository base URL"],
        wide: true,
      },
      {
        name: "Dependency mode",
        label: "Dependency handling",
        options: [
          ["Build missing only", "if-missing"],
          ["Rebuild all", "always"],
          ["Skip builds", "skip"],
        ],
        value: p["Dependency mode"],
      },
      {
        name: "Customization folder",
        label: "Project installer customization",
        options: [
          ["Enabled", "true"],
          ["Disabled", "false"],
        ],
        value: String(p["Customization folder"]),
      },
      { name: "Qt version", label: "Qt version", value: p["Qt version"] },
      {
        name: "Qt directory",
        label: "Qt installation folder",
        value: p["Qt directory"],
        wide: true,
      },
      {
        name: "Vulkan SDK version",
        label: "Vulkan SDK version",
        value: p["Vulkan SDK version"],
      },
      {
        name: "Vulkan SDK directory",
        label: "Vulkan SDK folder",
        value: p["Vulkan SDK directory"],
        wide: true,
      },
    ],
    "project-edit",
  );
}
async function saveEntry(event) {
  event.preventDefault();
  if (formSaving || !$("#form").reportValidity()) return;
  const values = Object.fromEntries(new FormData($("#form")).entries());
  schema
    .filter((field) => field.multiline && field.name !== "Recipe JSON")
    .forEach((field) => {
      values[field.name] = JSON.stringify(
        String(values[field.name] || "")
          .split("\n")
          .map((line) => line.trim())
          .filter(Boolean),
      );
    });
  schema
    .filter((field) => field.multi)
    .forEach((field) => {
      values[field.name] = JSON.stringify(
        new FormData($("#form")).getAll(field.name),
      );
    });
  $("#form")
    .querySelectorAll('input[type="checkbox"]:not([data-multiple])')
    .forEach(
      (input) => (values[input.name] = input.checked ? "true" : "false"),
    );
  if (dialogKind === "preferences") {
    localStorage.setItem("uiDensity", values.density || "comfortable");
    localStorage.setItem("uiMotion", values.motion || "standard");
    localStorage.setItem("uiTextSize", values.textSize || "standard");
    localStorage.setItem("uiSurface", values.surface || "soft");
    applyUiPreferences();
    closeDialog();
    message(
      "Preferences saved",
      "success",
      "Your appearance settings are saved on this browser.",
    );
    return;
  }
  const newSource =
    dialogKind === "dependency-pin" &&
    !schema.find((field) => field.name === "Name")?.hidden;
  const newEntry =
    ["project", "repository", "dependency"].includes(dialogKind) || newSource;
  if (
    newEntry &&
    !confirm(
      `Add this ${dialogKind === "repository" ? "plug-in" : dialogKind === "project" ? "project" : "dependency"} to this computer? ${dialogKind === "project" || dialogKind === "repository" ? "Its repositories will be cloned." : "It will be downloaded and installed."}`,
    )
  )
    return;
  formSaving = true;
  $("#dialogSubmit").disabled = true;
  try {
    if (dialogKind === "create-installer") {
      await api("/api/create-installer", {
        method: "POST",
        body: JSON.stringify({
          profile: values["Profile ID"],
          version: values["App version"],
          action: values.action,
          mode: $("#mode").value,
          reuse: $("#reuse").checked,
          dry: $("#dry").checked,
          jobs: buildJobs(),
        }),
      });
      pendingProfile = values["Profile ID"];
      formSaving = false;
      closeDialog();
      buildSection = "workflow";
      showView("build");
      await refresh();
      message(
        $("#dry").checked ? "Previewing build plan" : "Creating installer",
        "running",
      );
      return;
    }
    if (dialogKind === "repository-edit") {
      await api("/api/repository/update", {
        method: "POST",
        body: JSON.stringify({ values }),
      });
      formSaving = false;
      closeDialog();
      await refresh();
      message(
        "Pinned repository version updated",
        "success",
        `${values.Repository} now uses ${values.Ref}.`,
      );
      return;
    }
    if (dialogKind === "project-edit") {
      await api("/api/project/update", {
        method: "POST",
        body: JSON.stringify({ values }),
      });
      formSaving = false;
      closeDialog();
      await refresh();
      message(
        "Project settings saved",
        "success",
        "Only the selected profile was updated.",
      );
      return;
    }
    if (
      dialogKind === "dependency-pin" ||
      dialogKind === "dependency-recipe" ||
      dialogKind === "dependency-version"
    ) {
      await api("/api/dependencies", {
        method: "POST",
        body: JSON.stringify({
          mode: dialogKind === "dependency-pin" ? "pin" : "recipe",
          values,
        }),
      });
      formSaving = false;
      closeDialog();
      message(
        "Dependency settings saved",
        "success",
        "Previous version folders remain available in the shared cache.",
      );
      await refreshDependencies();
      await refresh();
      if (newSource) {
        await api("/api/run", {
          method: "POST",
          body: JSON.stringify({
            action: "install-dependency",
            kind: "pin",
            name: values.Name,
            jobs: buildJobs(),
          }),
        });
        showView("activity");
        await refresh();
      }
      return;
    }
    const route = dialogKind === "settings" ? "/api/settings" : "/api/add";
    await api(route, {
      method: "POST",
      body: JSON.stringify({ kind: dialogKind, values }),
    });
    formSaving = false;
    closeDialog();
    if (dialogKind === "project") {
      pendingProfile = values["Profile ID"];
      showView("projects");
    }
    if (dialogKind === "repository") {
      pendingProfile = values["Profile ID"];
      showView("projects");
    }
    if (dialogKind === "dependency") showView("dependencies");
    const savedMessage =
      {
        settings: "Installer paths saved.",
        project:
          "Project profile created with copied settings and installer materials.",
        repository: "Repository added to the selected project.",
        dependency: "Build library added to the shared recipes.",
      }[dialogKind] || "Saved to the project database.";
    message(savedMessage, "success");
    if (dialogKind === "dependency") await refreshDependencies();
    await refresh();
    if (["project", "repository", "dependency"].includes(dialogKind)) {
      await api("/api/run", {
        method: "POST",
        body: JSON.stringify(
          dialogKind === "dependency"
            ? {
                action: "install-dependency",
                kind: "recipe",
                name: values.Name,
                jobs: buildJobs(),
              }
            : {
                action: "clone",
                profile: values["Profile ID"],
                jobs: buildJobs(),
              },
        ),
      });
      showView(dialogKind === "dependency" ? "activity" : "build");
      await refresh();
    }
  } catch (e) {
    $("#dialogError").textContent = e.message;
    $("#dialogError").hidden = false;
    message(e.message, "error");
  } finally {
    formSaving = false;
    $("#dialogSubmit").disabled = false;
  }
}
showView(
  ["build", "projects", "dependencies", "installers", "activity"].includes(
    localStorage.getItem("workspaceView"),
  )
    ? localStorage.getItem("workspaceView")
    : "build",
);
refresh();
refreshInstallers();
refreshInstances();
setInterval(() => {
  if (!document.hidden) refreshInstances();
}, 30000);
function scheduleWorkspacePoll() {
  clearTimeout(pollTimer);
  pollTimer = setTimeout(
    pollWorkspace,
    document.hidden ? 30000 : state.live?.active ? 2000 : 10000,
  );
}
async function pollWorkspace() {
  if (document.hidden) scheduleWorkspacePoll();
  else await refresh();
}
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) {
    clearTimeout(pollTimer);
    refresh();
  }
});
function buildJobs() {
  const saved = Number(localStorage.getItem("buildJobs") || 0);
  return [0, 1, 2, 4, 8].includes(saved) ? saved : 0;
}
$("#buildJobs").value = String(buildJobs());
const savedMode = localStorage.getItem("dependencyMode");
$("#mode").value = ["if-missing", "always", "skip"].includes(savedMode)
  ? savedMode
  : "if-missing";
$("#reuse").checked = localStorage.getItem("reuseBuild") !== "false";
$("#mode").addEventListener("change", () =>
  localStorage.setItem("dependencyMode", $("#mode").value),
);
$("#reuse").addEventListener("change", () =>
  localStorage.setItem("reuseBuild", String($("#reuse").checked)),
);
applyUiPreferences();
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
  if ((localStorage.getItem("uiTheme") || "system") === "system")
    applyUiPreferences();
});

document.addEventListener("click", hideTooltip);
