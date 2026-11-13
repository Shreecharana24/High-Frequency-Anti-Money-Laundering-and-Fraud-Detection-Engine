const state = {
  token: sessionStorage.getItem("aml_access_token"),
  officer: null,
  page: "overview",
  generationJobId: null,
  generationTimer: null,
  alertOffset: 0,
  transactionOffset: 0,
};

const pageTitles = {
  overview: "Overview",
  alerts: "Alert queue",
  transactions: "Transactions",
  rules: "Detection rules",
  officers: "Officer access",
};

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  })[character]);
}

function initials(name) {
  return String(name || "Officer")
    .trim()
    .split(/\s+/)
    .slice(0, 2)
    .map((part) => part[0] || "")
    .join("")
    .toUpperCase();
}

function formatDate(value) {
  if (!value) return "—";
  const date = new Date(value);
  return Number.isNaN(date.getTime())
    ? "—"
    : new Intl.DateTimeFormat(undefined, {
        dateStyle: "medium",
        timeStyle: "short",
      }).format(date);
}

function formatAmount(amount, currency = "USD") {
  const value = Number(amount);
  if (!Number.isFinite(value)) return "—";
  return new Intl.NumberFormat(undefined, {
    style: "currency",
    currency: currency || "USD",
    maximumFractionDigits: 2,
  }).format(value);
}

function badge(value) {
  const normalized = String(value || "UNKNOWN").toLowerCase();
  return `<span class="badge badge-${escapeHtml(normalized)}">${escapeHtml(value || "UNKNOWN")}</span>`;
}

function toast(message, isError = false) {
  const item = document.createElement("div");
  item.className = `toast${isError ? " error" : ""}`;
  item.textContent = message;
  $("#toast-root").append(item);
  window.setTimeout(() => item.remove(), 4200);
}

function showLogin(message = "") {
  window.clearTimeout(state.generationTimer);
  state.generationJobId = null;
  state.token = null;
  state.officer = null;
  sessionStorage.removeItem("aml_access_token");
  $("#app-view").hidden = true;
  $("#login-view").hidden = false;
  $("#login-error").textContent = message;
  $("#login-error").hidden = !message;
}

async function api(path, options = {}) {
  const headers = new Headers(options.headers || {});
  if (state.token) headers.set("Authorization", `Bearer ${state.token}`);
  if (options.body && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }
  const response = await fetch(path, { ...options, headers });
  if (response.status === 401 && path !== "/api/v1/auth/login") {
    showLogin("Your session expired. Sign in again.");
    throw new Error("Session expired");
  }
  if (response.status === 204) return null;
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    const detail = Array.isArray(body.detail)
      ? body.detail.map((entry) => entry.msg).join(", ")
      : body.detail;
    throw new Error(detail || `Request failed (${response.status})`);
  }
  return body;
}

function setOfficer(officer) {
  state.officer = officer;
  const name = officer.officer_name || "Compliance officer";
  const role = officer.clearance_level || "OFFICER";
  $("#profile-name").textContent = name;
  $("#profile-role").textContent = role.replace("_", " ");
  $("#profile-avatar").textContent = initials(name);
  $("#topbar-avatar").textContent = initials(name);
  $$("[data-min-role]").forEach((item) => {
    item.hidden = !hasMinimumRole(item.dataset.minRole);
  });
  $("#app-view").hidden = false;
  $("#login-view").hidden = true;
}

function hasMinimumRole(required) {
  const rank = { LEVEL_1: 1, LEVEL_2: 2, ADMIN: 3 };
  return (rank[state.officer?.clearance_level] || 0) >= (rank[required] || 99);
}

function roleIs(...roles) {
  return roles.includes(state.officer?.clearance_level);
}

function navigate(page) {
  if (!pageTitles[page]) return;
  if (
    (page === "transactions" && !hasMinimumRole("LEVEL_2")) ||
    (page === "officers" && !roleIs("ADMIN"))
  ) {
    toast("Your clearance does not allow access to that page.", true);
    return;
  }
  state.page = page;
  $("#page-title").textContent = pageTitles[page];
  $$(".nav-link").forEach((item) => item.classList.toggle("active", item.dataset.page === page));
  renderPage();
}

function statCard(label, value, icon, footnote) {
  return `<article class="stat-card">
    <div class="stat-top"><span>${escapeHtml(label)}</span><span class="stat-icon">${icon}</span></div>
    <div class="stat-value">${escapeHtml(value)}</div>
    <div class="stat-foot">${escapeHtml(footnote)}</div>
  </article>`;
}

function alertTable(items, compact = false) {
  if (!items.length) return `<div class="empty-state">No alerts match this view.</div>`;
  const rows = items.map((item) => `
    <tr>
      <td><button class="table-link" data-alert-id="${Number(item.alert_id)}">#${Number(item.alert_id)} · ${escapeHtml(item.title)}</button><span class="table-secondary">${escapeHtml(item.rule_code)}</span></td>
      <td>${badge(item.severity)}</td>
      <td>${badge(item.alert_status)}</td>
      ${compact ? "" : `<td>${escapeHtml(item.assigned_officer_name || "Unassigned")}</td>`}
      <td>${formatDate(item.detected_at)}</td>
      ${compact ? "" : `<td><button class="text-button" data-alert-id="${Number(item.alert_id)}">Review →</button></td>`}
    </tr>`).join("");
  return `<div class="table-wrap"><table class="data-table">
    <thead><tr><th>Alert</th><th>Severity</th><th>Status</th>${compact ? "" : "<th>Assigned to</th>"}<th>Detected</th>${compact ? "" : "<th></th>"}</tr></thead>
    <tbody>${rows}</tbody>
  </table></div>`;
}

async function renderOverview() {
  const content = $("#page-content");
  content.innerHTML = `<div class="loading-state">Loading your operations overview…</div>`;
  try {
    const [metrics, alertResult] = await Promise.all([
      api("/api/v1/metrics"),
      api("/api/v1/alerts?limit=8"),
    ]);
    const alerts = alertResult.items || [];
    const total = Number(metrics.total_alerts || 0);
    const active = Number(metrics.active_alerts || 0);
    const critical = alerts.filter((item) => item.severity === "CRITICAL").length;
    const reported = Number(metrics.reported_alerts || 0);
    const severityCounts = ["CRITICAL", "HIGH", "MEDIUM", "LOW"].map((severity) =>
      alerts.filter((item) => item.severity === severity).length
    );
    const maxSeverity = Math.max(1, ...severityCounts);
    const severityRows = ["CRITICAL", "HIGH", "MEDIUM", "LOW"].map((severity, index) => {
      const tone = severity.toLowerCase();
      const count = severityCounts[index];
      return `<div class="severity-row"><span>${severity}</span><div class="severity-track"><div class="severity-fill ${tone}" style="width:${Math.round((count / maxSeverity) * 100)}%"></div></div><span class="severity-count">${count}</span></div>`;
    }).join("");
    content.innerHTML = `
      <div class="page-heading">
        <div><p class="eyebrow">COMPLIANCE OPERATIONS</p><h1>Good ${greeting()}, ${escapeHtml(state.officer.officer_name.split(" ")[0])}</h1><p>Here’s the latest view of your alert and investigation workload.</p></div>
        <div class="heading-actions"><span class="role-chip">${escapeHtml(state.officer.clearance_level.replace("_", " "))}</span></div>
      </div>
      <div class="stats-grid">
        ${statCard("Alerts in view", total.toLocaleString(), "◎", roleIs("LEVEL_1") ? "Assigned to you" : "Across the operations queue")}
        ${statCard("Active investigations", active.toLocaleString(), "◷", "Open, investigating, or escalated")}
        ${statCard("Critical · recent", critical.toLocaleString(), "!", "In the latest alerts")}
        ${statCard("Reported", reported.toLocaleString(), "↗", "Alerts reported to regulators")}
      </div>
      <div class="content-grid">
        <section class="panel">
          <div class="panel-header"><div><h2>Recent alerts</h2><p>Latest detection activity</p></div><button class="text-button" data-go="alerts">View alert queue →</button></div>
          ${alertTable(alerts, true)}
        </section>
        <div class="side-stack">
          <section class="panel signal-card"><div class="signal-top"><span>Queue status</span><span class="soft-chip">LIVE</span></div><div class="signal-number">${active.toLocaleString()}</div><div class="signal-sub">Alerts need active attention in your current view.</div></section>
          <section class="panel"><div class="panel-header"><div><h2>Recent severity</h2><p>Latest ${alerts.length} alerts</p></div></div><div class="severity-list">${severityRows}</div></section>
        </div>
      </div>`;
    $("#nav-alert-count").textContent = active ? String(active) : "";
    bindAlertButtons(content);
  } catch (error) {
    content.innerHTML = `<div class="panel empty-state">${escapeHtml(error.message)}</div>`;
  }
}

function greeting() {
  const hour = new Date().getHours();
  return hour < 12 ? "morning" : hour < 18 ? "afternoon" : "evening";
}

async function renderAlerts() {
  const content = $("#page-content");
  content.innerHTML = `
    <div class="page-heading"><div><p class="eyebrow">INVESTIGATION WORKSPACE</p><h1>Alert queue</h1><p>Review alerts, supporting evidence, and investigation history.</p></div><span class="role-chip">${escapeHtml(state.officer.clearance_level.replace("_", " "))}</span></div>
    <form id="alert-filter-form" class="toolbar">
      <div class="filter-row">
        <select id="filter-status" class="filter-select" aria-label="Filter by status"><option value="">All statuses</option>${["OPEN", "INVESTIGATING", "ESCALATED", "CLEARED", "REPORTED"].map((v) => `<option>${v}</option>`).join("")}</select>
        <select id="filter-severity" class="filter-select" aria-label="Filter by severity"><option value="">All severities</option>${["CRITICAL", "HIGH", "MEDIUM", "LOW"].map((v) => `<option>${v}</option>`).join("")}</select>
        <button class="button button-secondary" type="submit">Apply filters</button>
      </div>
      <span class="muted">Select an alert to open its case file.</span>
    </form>
    <section class="panel table-panel"><div id="alerts-table-content" class="loading-state">Loading alerts…</div><div id="alerts-pagination" class="pagination"></div></section>`;
  $("#alert-filter-form").addEventListener("submit", (event) => {
    event.preventDefault();
    state.alertOffset = 0;
    loadAlerts();
  });
  await loadAlerts();
}

async function loadAlerts() {
  const status = $("#filter-status")?.value || "";
  const severity = $("#filter-severity")?.value || "";
  const query = new URLSearchParams({ limit: "100", offset: String(state.alertOffset) });
  if (status) query.set("status", status);
  if (severity) query.set("severity", severity);
  const target = $("#alerts-table-content");
  if (!target) return;
  target.innerHTML = `<div class="loading-state">Loading alerts…</div>`;
  try {
    const result = await api(`/api/v1/alerts?${query}`);
    target.innerHTML = alertTable(result.items || []);
    const total = Number(result.total || 0);
    const count = (result.items || []).length;
    const start = count ? state.alertOffset + 1 : 0;
    const end = state.alertOffset + count;
    $("#alerts-pagination").innerHTML = `<span>Showing ${start.toLocaleString()}–${end.toLocaleString()} of ${total.toLocaleString()} alerts</span><span><button class="text-button" data-alert-page="-1" ${state.alertOffset === 0 ? "disabled" : ""}>← Previous</button><button class="text-button" data-alert-page="1" ${end >= total ? "disabled" : ""}>Next →</button></span>`;
    $$("[data-alert-page]", $("#alerts-pagination")).forEach((button) => button.addEventListener("click", () => {
      state.alertOffset = Math.max(0, state.alertOffset + Number(button.dataset.alertPage) * 100);
      loadAlerts();
    }));
    bindAlertButtons(target);
  } catch (error) {
    target.innerHTML = `<div class="empty-state">${escapeHtml(error.message)}</div>`;
  }
}

function transactionTable(items) {
  if (!items.length) return `<div class="empty-state">No transactions found.</div>`;
  return `<div class="table-wrap"><table class="data-table">
    <thead><tr><th>Transaction</th><th>Sender</th><th>Receiver</th><th>Amount</th><th>Type</th><th>Status</th><th>Created</th></tr></thead>
    <tbody>${items.map((item) => `<tr>
      <td><strong>#${Number(item.transaction_id)}</strong></td>
      <td>${escapeHtml(item.sender_name)}<span class="table-secondary">Account ${Number(item.sender_account_id)}</span></td>
      <td>${escapeHtml(item.receiver_name)}<span class="table-secondary">Account ${Number(item.receiver_account_id)}</span></td>
      <td><strong>${formatAmount(item.amount, item.currency)}</strong></td>
      <td>${escapeHtml(String(item.transaction_type || "").replaceAll("_", " "))}</td>
      <td>${badge(item.status)}</td>
      <td>${formatDate(item.created_at)}</td>
    </tr>`).join("")}</tbody>
  </table></div>`;
}

async function renderTransactions() {
  const content = $("#page-content");
  content.innerHTML = `
    <div class="page-heading"><div><p class="eyebrow">TRANSACTION ACTIVITY</p><h1>Transactions</h1><p>Review bank activity or request a synthetic batch for detection testing.</p></div><span class="role-chip">${escapeHtml(state.officer.clearance_level.replace("_", " "))}</span></div>
    <div class="toolbar"><div class="filter-row"><select id="transaction-filter" class="filter-select" aria-label="Filter transactions by status"><option value="">All statuses</option>${["PENDING", "COMPLETED", "FAILED", "BLOCKED"].map((v) => `<option>${v}</option>`).join("")}</select><button id="refresh-transactions" class="button button-secondary" type="button">Refresh list</button></div><button id="generate-transactions" class="button button-primary" type="button">＋ Generate 1,000 transactions</button></div>
    <div id="generation-status"></div>
    <section class="panel table-panel"><div id="transaction-table-content" class="loading-state">Loading transactions…</div><div id="transaction-pagination" class="pagination"></div></section>`;
  $("#transaction-filter").addEventListener("change", () => {
    state.transactionOffset = 0;
    loadTransactions();
  });
  $("#refresh-transactions").addEventListener("click", loadTransactions);
  $("#generate-transactions").addEventListener("click", startGeneration);
  await Promise.all([loadTransactions(), loadLatestGeneration()]);
}

async function loadTransactions() {
  const target = $("#transaction-table-content");
  if (!target) return;
  const query = new URLSearchParams({ limit: "100", offset: String(state.transactionOffset) });
  const status = $("#transaction-filter")?.value;
  if (status) query.set("status", status);
  target.innerHTML = `<div class="loading-state">Loading transactions…</div>`;
  try {
    const result = await api(`/api/v1/transactions?${query}`);
    target.innerHTML = transactionTable(result.items || []);
    const total = Number(result.total || 0);
    const count = (result.items || []).length;
    const start = count ? state.transactionOffset + 1 : 0;
    const end = state.transactionOffset + count;
    $("#transaction-pagination").innerHTML = `<span>Showing ${start.toLocaleString()}–${end.toLocaleString()} of ${total.toLocaleString()} transactions</span><span><button class="text-button" data-transaction-page="-1" ${state.transactionOffset === 0 ? "disabled" : ""}>← Previous</button><button class="text-button" data-transaction-page="1" ${end >= total ? "disabled" : ""}>Next →</button></span>`;
    $$("[data-transaction-page]", $("#transaction-pagination")).forEach((button) => button.addEventListener("click", () => {
      state.transactionOffset = Math.max(0, state.transactionOffset + Number(button.dataset.transactionPage) * 100);
      loadTransactions();
    }));
  } catch (error) {
    target.innerHTML = `<div class="empty-state">${escapeHtml(error.message)}</div>`;
  }
}

function generationCard(job) {
  if (!job) return "";
  const progress = Math.min(100, Math.round((Number(job.generated_count || 0) / 1000) * 100));
  const active = ["QUEUED", "RUNNING"].includes(job.status);
  const message = job.status === "FAILED"
    ? job.error_message || "Generation failed."
    : active
      ? `${Number(job.generated_count || 0).toLocaleString()} of 1,000 rows generated`
      : `${Number(job.generated_count || 0).toLocaleString()} transactions generated`;
  return `<section class="job-card">
    <div class="job-indicator">${active ? "◷" : job.status === "FAILED" ? "!" : "✓"}</div>
    <div class="job-copy"><strong>Generation job #${Number(job.job_id)} · ${escapeHtml(job.status)}</strong><small>${escapeHtml(message)}${job.finished_at ? ` · ${formatDate(job.finished_at)}` : ""}</small></div>
    <div class="progress-track" aria-label="${progress}% complete"><div class="progress-fill" style="width:${progress}%"></div></div>
  </section>`;
}

function showGenerationJob(job) {
  const target = $("#generation-status");
  if (!target) return;
  target.innerHTML = generationCard(job);
  const button = $("#generate-transactions");
  if (button) button.disabled = ["QUEUED", "RUNNING"].includes(job?.status);
}

async function loadLatestGeneration() {
  try {
    const job = await api("/api/v1/transactions/generation/latest");
    showGenerationJob(job);
    if (job && ["QUEUED", "RUNNING"].includes(job.status)) {
      pollGeneration(job.job_id);
    }
  } catch (error) {
    toast(error.message, true);
  }
}

async function startGeneration() {
  const button = $("#generate-transactions");
  if (button) button.disabled = true;
  try {
    const job = await api("/api/v1/transactions/generate", { method: "POST" });
    showGenerationJob(job);
    toast("Your 1,000-transaction batch has been queued.");
    pollGeneration(job.job_id);
  } catch (error) {
    if (button) button.disabled = false;
    toast(error.message, true);
  }
}

function pollGeneration(jobId) {
  if (state.generationJobId === Number(jobId)) return;
  state.generationJobId = Number(jobId);
  window.clearTimeout(state.generationTimer);
  const poll = async () => {
    try {
      const job = await api(`/api/v1/transactions/generation/${state.generationJobId}`);
      if (state.page === "transactions") showGenerationJob(job);
      if (["QUEUED", "RUNNING"].includes(job.status)) {
        state.generationTimer = window.setTimeout(poll, 1700);
        return;
      }
      state.generationJobId = null;
      if (job.status === "COMPLETED") {
        toast("1,000 transactions generated successfully.");
        if (state.page === "transactions") loadTransactions();
      } else {
        toast(job.error_message || `Generation stopped after ${job.generated_count} rows.`, true);
      }
      if (state.page === "overview") renderOverview();
    } catch (error) {
      state.generationJobId = null;
      toast(error.message, true);
    }
  };
  poll();
}

async function renderRules() {
  const content = $("#page-content");
  content.innerHTML = `<div class="loading-state">Loading detection rules…</div>`;
  try {
    const rules = await api("/api/v1/rules");
    content.innerHTML = `
      <div class="page-heading"><div><p class="eyebrow">DETECTION CONFIGURATION</p><h1>Detection rules</h1><p>Rules currently enabled in the monitoring pipeline.</p></div><span class="soft-chip">VIEW ONLY</span></div>
      <section class="panel table-panel"><div class="table-wrap"><table class="data-table">
        <thead><tr><th>Rule</th><th>Description</th><th>Base score</th><th>Engine</th></tr></thead>
        <tbody>${rules.map((rule) => `<tr><td><strong>${escapeHtml(rule.rule_code)}</strong></td><td>${escapeHtml(rule.description)}</td><td>${Number(rule.base_penalty_score)}</td><td>${badge("ACTIVE")}</td></tr>`).join("")}</tbody>
      </table></div></section>`;
  } catch (error) {
    content.innerHTML = `<div class="panel empty-state">${escapeHtml(error.message)}</div>`;
  }
}

async function renderOfficers() {
  const content = $("#page-content");
  content.innerHTML = `
    <div class="page-heading"><div><p class="eyebrow">ACCESS ADMINISTRATION</p><h1>Officer access</h1><p>Create staff accounts and manage clearance. Registration is restricted to Admin.</p></div><span class="role-chip">ADMIN ONLY</span></div>
    <section class="panel" style="padding:18px;margin-bottom:15px">
      <div class="panel-header" style="padding:0 0 15px;border:0"><div><h2>Register an officer</h2><p>Create a compliance profile and login account.</p></div></div>
      <form id="create-officer-form" class="form-grid">
        <div class="form-field"><label class="field-label" for="new-officer-name">Full name</label><input class="field-input" id="new-officer-name" name="officer_name" required maxlength="100"></div>
        <div class="form-field"><label class="field-label" for="new-officer-badge">Badge number</label><input class="field-input" id="new-officer-badge" name="badge_number" required maxlength="30"></div>
        <div class="form-field"><label class="field-label" for="new-officer-email">Work email</label><input class="field-input" id="new-officer-email" name="email" type="email" required maxlength="254"></div>
        <div class="form-field"><label class="field-label" for="new-officer-role">Clearance level</label><select class="field-select" id="new-officer-role" name="clearance_level"><option value="LEVEL_1">Level 1 · Analyst</option><option value="LEVEL_2">Level 2 · Senior analyst</option><option value="ADMIN">Admin</option></select></div>
        <div class="form-field"><label class="field-label" for="new-officer-password">Temporary password · 12+ characters</label><input class="field-input" id="new-officer-password" name="password" type="password" required minlength="12" maxlength="256" autocomplete="new-password"></div>
        <div class="form-field" style="align-self:end"><button class="button button-primary" type="submit">Create officer account</button></div>
      </form>
    </section>
    <section class="panel table-panel"><div class="panel-header"><div><h2>Compliance officers</h2><p>Assign access only to authorized bank staff.</p></div></div><div id="officers-table-content" class="loading-state">Loading officer accounts…</div></section>`;
  $("#create-officer-form").addEventListener("submit", createOfficer);
  await loadOfficers();
}

async function loadOfficers() {
  const target = $("#officers-table-content");
  if (!target) return;
  try {
    const officers = await api("/api/v1/officers");
    target.innerHTML = `<div class="table-wrap"><table class="data-table">
      <thead><tr><th>Officer</th><th>Badge</th><th>Login</th><th>Clearance</th><th>State</th><th>Actions</th></tr></thead>
      <tbody>${officers.map((officer) => {
        const accountExists = Boolean(officer.email);
        const active = officer.is_active === true || officer.is_active === 1;
        return `<tr data-officer-row="${Number(officer.officer_id)}" data-active="${active}">
          <td><strong>${escapeHtml(officer.officer_name)}</strong><span class="table-secondary">ID ${Number(officer.officer_id)}</span></td>
          <td>${escapeHtml(officer.badge_number)}</td>
          <td>${accountExists ? escapeHtml(officer.email) : `<button class="text-button" data-create-account="${Number(officer.officer_id)}">Create login</button>`}</td>
          <td><select class="filter-select" data-officer-role="${Number(officer.officer_id)}">${["LEVEL_1", "LEVEL_2", "ADMIN"].map((role) => `<option value="${role}" ${officer.clearance_level === role ? "selected" : ""}>${role.replace("_", " ")}</option>`).join("")}</select></td>
          <td>${accountExists ? badge(active ? "ACTIVE" : "DISABLED") : `<span class="muted">No login</span>`}</td>
          <td><div class="filter-row"><button class="button button-secondary" data-save-officer="${Number(officer.officer_id)}">Save role</button>${accountExists ? `<button class="button ${active ? "button-danger" : "button-primary"}" data-toggle-officer="${Number(officer.officer_id)}" data-next-active="${!active}">${active ? "Deactivate" : "Activate"}</button>` : ""}</div></td>
        </tr>`;
      }).join("")}</tbody>
    </table></div>`;
    $$("[data-create-account]", target).forEach((button) => button.addEventListener("click", () => openAccountDialog(button.dataset.createAccount)));
    $$("[data-save-officer]", target).forEach((button) => button.addEventListener("click", () => saveOfficerRole(button.dataset.saveOfficer)));
    $$("[data-toggle-officer]", target).forEach((button) => button.addEventListener("click", () => toggleOfficer(button.dataset.toggleOfficer, button.dataset.nextActive === "true")));
  } catch (error) {
    target.innerHTML = `<div class="empty-state">${escapeHtml(error.message)}</div>`;
  }
}

async function createOfficer(event) {
  event.preventDefault();
  const form = event.currentTarget;
  const payload = Object.fromEntries(new FormData(form).entries());
  try {
    await api("/api/v1/officers", { method: "POST", body: JSON.stringify(payload) });
    form.reset();
    toast("Officer account created.");
    await loadOfficers();
  } catch (error) {
    toast(error.message, true);
  }
}

async function saveOfficerRole(officerId) {
  const select = $(`[data-officer-role="${officerId}"]`);
  try {
    await api(`/api/v1/officers/${officerId}`, {
      method: "PATCH",
      body: JSON.stringify({ clearance_level: select.value }),
    });
    toast("Officer clearance updated.");
  } catch (error) {
    toast(error.message, true);
    loadOfficers();
  }
}

async function toggleOfficer(officerId, isActive) {
  try {
    await api(`/api/v1/officers/${officerId}`, {
      method: "PATCH",
      body: JSON.stringify({ is_active: isActive }),
    });
    toast(isActive ? "Officer account activated." : "Officer account deactivated.");
    await loadOfficers();
  } catch (error) {
    toast(error.message, true);
  }
}

function openAccountDialog(officerId) {
  $("#dialog-root").innerHTML = `
    <div class="dialog-backdrop" data-close-dialog>
      <section class="dialog" role="dialog" aria-modal="true" aria-labelledby="account-dialog-title">
        <div class="dialog-header"><div><h2 id="account-dialog-title">Create officer login</h2><p>Set credentials for existing officer #${Number(officerId)}.</p></div><button class="dialog-close" type="button" data-close-dialog aria-label="Close">×</button></div>
        <div class="dialog-body"><form id="officer-account-form" class="form-grid">
          <div class="form-field full"><label class="field-label" for="account-email">Work email</label><input class="field-input" id="account-email" name="email" type="email" required maxlength="254"></div>
          <div class="form-field full"><label class="field-label" for="account-password">Temporary password · 12+ characters</label><input class="field-input" id="account-password" name="password" type="password" required minlength="12" maxlength="256" autocomplete="new-password"></div>
          <div class="form-field full form-actions"><button class="button button-secondary" type="button" data-close-dialog>Cancel</button><button class="button button-primary" type="submit">Create login</button></div>
        </form></div>
      </section>
    </div>`;
  bindDialogClose();
  $("#officer-account-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const payload = Object.fromEntries(new FormData(event.currentTarget).entries());
    try {
      await api(`/api/v1/officers/${officerId}/account`, { method: "POST", body: JSON.stringify(payload) });
      $("#dialog-root").innerHTML = "";
      toast("Login account created.");
      await loadOfficers();
    } catch (error) {
      toast(error.message, true);
    }
  });
}

async function openAlert(alertId) {
  try {
    const alert = await api(`/api/v1/alerts/${alertId}`);
    const currentStatus = alert.alert_status;
    const statuses = state.officer.clearance_level === "LEVEL_1"
      ? ["INVESTIGATING"]
      : ({
          OPEN: ["OPEN", "INVESTIGATING", "ESCALATED", "CLEARED"],
          INVESTIGATING: ["INVESTIGATING", "ESCALATED", "CLEARED"],
          ESCALATED: ["ESCALATED", "REPORTED", "CLEARED"],
          CLEARED: ["CLEARED", "OPEN"],
          REPORTED: ["REPORTED"],
        }[currentStatus] || [currentStatus]);
    let officers = [];
    if (hasMinimumRole("LEVEL_2")) {
      try { officers = await api("/api/v1/officers/assignable"); } catch (error) { toast(error.message, true); }
    }
    const evidence = (alert.evidence || []).map((item) => `
      <div class="evidence-item"><strong>${escapeHtml(item.evidence_type)} · ${formatDate(item.created_at)}</strong><pre>${escapeHtml(JSON.stringify(item.evidence_data, null, 2))}</pre></div>`).join("") || `<div class="muted">No evidence attached.</div>`;
    const history = (alert.review_history || []).map((item) => `
      <div class="history-item"><strong>${escapeHtml(item.action_type.replaceAll("_", " "))}</strong><p>${escapeHtml(item.note || `${item.previous_status || "—"} → ${item.new_status || "—"}`)}</p><small>Officer #${Number(item.officer_id)} · ${formatDate(item.created_at)}</small></div>`).join("") || `<div class="muted">No review history yet.</div>`;
    const canResolve = state.officer.clearance_level !== "LEVEL_1";
    $("#dialog-root").innerHTML = `
      <div class="dialog-backdrop" data-close-dialog>
        <section class="dialog" role="dialog" aria-modal="true" aria-labelledby="alert-dialog-title">
          <div class="dialog-header"><div><p class="eyebrow">${escapeHtml(alert.rule_code)} · ${escapeHtml(alert.severity)}</p><h2 id="alert-dialog-title">${escapeHtml(alert.title)}</h2><p>Alert #${Number(alert.alert_id)} · Detected ${formatDate(alert.detected_at)}</p></div><button class="dialog-close" type="button" data-close-dialog aria-label="Close">×</button></div>
          <div class="dialog-body">
            <p class="muted">${escapeHtml(alert.summary)}</p>
            <div class="detail-grid">
              <div class="detail-item"><small>Status</small><strong>${badge(alert.alert_status)}</strong></div>
              <div class="detail-item"><small>Risk score</small><strong>${Number(alert.risk_score)}</strong></div>
              <div class="detail-item"><small>Assigned officer</small><strong>${escapeHtml(alert.assigned_officer_name || "Unassigned")}</strong></div>
              <div class="detail-item"><small>Account</small><strong>${alert.account_id ? `#${Number(alert.account_id)}` : "—"}</strong></div>
            </div>
            <div class="section-label">Supporting evidence</div>${evidence}
            <div class="section-label">Review history</div>${history}
            <div class="section-label">Investigation actions</div>
            <form id="alert-update-form" class="form-grid">
              <div class="form-field"><label class="field-label" for="alert-status">Status</label><select class="field-select" id="alert-status" name="status"><option value="">No change</option>${statuses.map((status) => `<option value="${status}" ${status === currentStatus ? "disabled" : ""}>${status.replaceAll("_", " ")}</option>`).join("")}</select></div>
              ${canResolve ? `<div class="form-field"><label class="field-label" for="alert-assignee">Assign to officer</label><select class="field-select" id="alert-assignee" name="assigned_officer_id"><option value="">No change</option>${officers.map((officer) => `<option value="${Number(officer.officer_id)}">${escapeHtml(officer.officer_name)} · ${escapeHtml(officer.clearance_level)}</option>`).join("")}</select></div><div class="form-field full"><label class="field-label" for="resolution-notes">Resolution notes</label><textarea class="field-textarea" id="resolution-notes" name="resolution_notes" maxlength="4000" placeholder="Optional context for this action"></textarea></div>` : ""}
              <div class="form-field full form-actions"><button class="button button-primary" type="submit">Save changes</button></div>
            </form>
            <form id="alert-note-form" class="form-grid" style="margin-top:16px">
              <div class="form-field full"><label class="field-label" for="review-note">Add a review note</label><textarea class="field-textarea" id="review-note" name="note" required maxlength="4000" placeholder="Record your investigation notes…"></textarea></div>
              <div class="form-field full form-actions"><button class="button button-secondary" type="submit">Add note</button></div>
            </form>
          </div>
        </section>
      </div>`;
    bindDialogClose();
    $("#alert-update-form").addEventListener("submit", async (event) => {
      event.preventDefault();
      const form = new FormData(event.currentTarget);
      const payload = {};
      if (form.get("status")) payload.status = form.get("status");
      if (form.get("assigned_officer_id")) payload.assigned_officer_id = Number(form.get("assigned_officer_id"));
      if (canResolve && form.get("resolution_notes")) payload.resolution_notes = form.get("resolution_notes");
      if (!payload.status && payload.assigned_officer_id === undefined) {
        toast("Choose a status or assignee change first.", true);
        return;
      }
      try {
        await api(`/api/v1/alerts/${alertId}`, { method: "PATCH", body: JSON.stringify(payload) });
        $("#dialog-root").innerHTML = "";
        toast("Alert updated.");
        renderPage();
      } catch (error) {
        toast(error.message, true);
      }
    });
    $("#alert-note-form").addEventListener("submit", async (event) => {
      event.preventDefault();
      const note = new FormData(event.currentTarget).get("note");
      try {
        await api(`/api/v1/alerts/${alertId}/notes`, { method: "POST", body: JSON.stringify({ note }) });
        toast("Review note added.");
        openAlert(alertId);
        renderPage();
      } catch (error) {
        toast(error.message, true);
      }
    });
  } catch (error) {
    toast(error.message, true);
  }
}

function bindAlertButtons(root) {
  $$("[data-alert-id]", root).forEach((button) => {
    button.addEventListener("click", () => openAlert(Number(button.dataset.alertId)));
  });
  $$("[data-go]", root).forEach((button) => button.addEventListener("click", () => navigate(button.dataset.go)));
}

function bindDialogClose() {
  $$("[data-close-dialog]").forEach((element) => {
    element.addEventListener("click", (event) => {
      if (event.target === element) $("#dialog-root").innerHTML = "";
      else if (element.matches("button")) $("#dialog-root").innerHTML = "";
    });
  });
}

async function renderPage() {
  if (state.page === "overview") return renderOverview();
  if (state.page === "alerts") return renderAlerts();
  if (state.page === "transactions") return renderTransactions();
  if (state.page === "rules") return renderRules();
  if (state.page === "officers") return renderOfficers();
}

$("#login-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const submit = event.currentTarget.querySelector("button[type=submit]");
  const error = $("#login-error");
  error.hidden = true;
  submit.disabled = true;
  try {
    const payload = Object.fromEntries(new FormData(event.currentTarget).entries());
    const session = await api("/api/v1/auth/login", {
      method: "POST",
      body: JSON.stringify(payload),
    });
    state.token = session.access_token;
    sessionStorage.setItem("aml_access_token", state.token);
    const officer = await api("/api/v1/auth/me");
    setOfficer(officer);
    navigate("overview");
  } catch (loginError) {
    error.textContent = loginError.message || "Unable to sign in.";
    error.hidden = false;
  } finally {
    submit.disabled = false;
  }
});

async function logout() {
  try {
    await api("/api/v1/auth/logout", { method: "POST" });
    showLogin();
  } catch (error) {
    toast(`Sign-out could not reach the server: ${error.message}`, true);
    showLogin();
  }
}

$("#logout-button").addEventListener("click", logout);
$("#topbar-logout").addEventListener("click", logout);

$("#main-nav").addEventListener("click", (event) => {
  const button = event.target.closest("[data-page]");
  if (button) navigate(button.dataset.page);
});

async function initialize() {
  if (!state.token) {
    showLogin();
    return;
  }
  try {
    const officer = await api("/api/v1/auth/me");
    setOfficer(officer);
    navigate("overview");
  } catch (error) {
    showLogin(error.message || "Please sign in to continue.");
  }
}

initialize();
