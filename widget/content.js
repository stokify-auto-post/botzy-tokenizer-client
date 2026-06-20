// =============================================================================
// BOTZY TOKENIZER — content.js (runs ONLY on claude.ai — see manifest matches)
//
// MOAT (hard rule, enforced in code):
//   * reads ONLY usage numbers + message text LENGTHS.
//   * message text: .textContent.length is read; the string is never stored,
//     logged, rendered, or transmitted — only the resulting number survives.
//   * usage text: scanned ONLY inside config-selected usage elements, never
//     inside conversation messages (explicit closest() exclusion).
//   * NETWORK: only same-origin reads of the user's OWN claude.ai usage
//     endpoint (apiGet — credentials reuse the user's first-party cookies).
//     The 127.0.0.1 localhost bridge (Gate 1/2) is reached ONLY via the
//     background service worker (chrome.runtime.sendMessage) — content.js
//     NEVER fetches loopback directly, so the bridge sees Origin=
//     chrome-extension://<id>, never claude.ai. Numbers/state only cross it.
//
// R13: no inline values — every knob comes from BOTZY_CONFIG (config.js) or
// the user's saved settings (chrome.storage.local).
// =============================================================================
(() => {
  "use strict";

  const CFG = (typeof BOTZY_CONFIG !== "undefined") ? BOTZY_CONFIG : null;
  if (!CFG) return; // config.js missing — do nothing, never guess

  // ------------------------------------------------------------ settings layer
  const settings = {
    soundOn: CFG.soundOn,
    blinkOn: CFG.blinkOn,
    refreshSec: CFG.refreshSec,
    spikeThresholdTokens: CFG.spikeThresholdTokens
  };

  function loadSettings(then) {
    try {
      chrome.storage.local.get("botzy_settings", (res) => {
        if (res && res.botzy_settings) Object.assign(settings, res.botzy_settings);
        then();
      });
    } catch (e) { then(); } // extension storage unavailable — config defaults
  }

  function saveSettings() {
    try { chrome.storage.local.set({ botzy_settings: Object.assign({}, settings) }); } catch (e) {}
  }

  // -------------------------------------------------------------------- state
  const state = {
    sessionPct: null,   // five_hour.utilization (%)  — null => "—"
    weeklyPct: null,    // seven_day.utilization (all models)
    sonnetPct: null,    // seven_day_sonnet.utilization
    opusPct: null,      // seven_day_opus.utilization (row hidden when null)
    sessionReset: null, // friendly "in Xh Ym" from *.resets_at (ISO -> delta)
    weeklyReset: null,
    sonnetReset: null,
    opusReset: null,
    usageAsOf: null,    // HH:MM:SS of the last SUCCESSFUL usage read (sticky)
    usageNote: null,    // quiet status line on failure ("… — showing last known")
    usageSource: null,  // "endpoint" | "modal" — provenance of current numbers
    lastPollOk: false,  // gates the modal fallback (only when endpoint not OK)
    model: null,        // null => "model unknown" — NEVER a silent default
    totalEstTokens: 0,
    lastEstTokens: null,
    spikeCount: 0,
    log: [],            // rows: {t:"HH:MM:SS", role, tokens, spike} — numbers only
    // ---- Gate 1/2 localhost bridge (numbers/state only, via service worker) ---
    bridgePaired: false, // a bridge token has been pasted into settings
    bridgeNote: null,    // quiet status ("bridge not paired" / "bridge offline")
    bridgeHasData: null, // null=unknown, true=logs present, false=connected but no logs yet
    bridgeDtach: []      // [{name, alive, attached}] — HONEST dtach names, no mask
  };

  let orgId = null;     // resolved dynamically (per user), cached in storage

  // ---------------------------------------------------------- token estimation
  // MOAT: only the LENGTH of textContent is read; the string is not retained.
  function estimateTokens(el) {
    return Math.round((el.textContent || "").length / CFG.charsPerToken);
  }

  // ---------------------------------------------------------------- usage scan
  function scanUsage() {
    let txt = "";
    const msgSel = CFG.selectors.userMessage + "," + CFG.selectors.assistantMessage;
    for (const sel of CFG.selectors.usage) {
      let els;
      try { els = document.querySelectorAll(sel); } catch (e) { continue; }
      for (const el of els) {
        if (el.closest(msgSel)) continue; // MOAT: never text-scan inside messages
        if (el.closest("#botzy-panel")) continue; // never scan our own panel
        txt += " " + (el.textContent || "");
      }
    }
    const s = txt.match(CFG.patterns.sessionPct);
    const w = txt.match(CFG.patterns.weeklyPct);
    const so = txt.match(CFG.patterns.weeklySonnetPct);
    const sr = txt.match(CFG.patterns.sessionReset);
    const wr = txt.match(CFG.patterns.weeklyReset);
    // STICKY (Option A): usage lives in the Settings → Usage modal — when the
    // modal is closed the scan finds nothing; KEEP the last-seen values and
    // stamp when they were captured. Never null-out on a miss.
    if (s || w || so) { state.usageAsOf = nowHMS(); state.usageSource = "modal"; }
    if (s) state.sessionPct = parseInt(s[1], 10);
    if (w) state.weeklyPct = parseInt(w[1], 10);
    if (so) state.sonnetPct = parseInt(so[1], 10);
    if (sr) state.sessionReset = sr[1].trim();
    if (wr) state.weeklyReset = wr[1].trim();
    // txt goes out of scope here — usage text is not retained either
  }

  function scanModel() {
    for (const sel of CFG.selectors.model) {
      let el;
      try { el = document.querySelector(sel); } catch (e) { continue; }
      if (el) {
        const name = (el.textContent || "").trim();
        if (name && name.length <= CFG.modelNameMaxLen) { state.model = name; return; }
      }
    }
    state.model = null; // honest: unknown — no default rate ever applied
  }

  // ============================================================================
  // USAGE ENDPOINT (PRIMARY, v0.2.0) — same-origin, read-only, zero cost.
  // ONLY fields read: *.utilization (number %) and *.resets_at (ISO ts). The
  // JSON body is never stored or retransmitted (out of scope after extract).
  // ============================================================================
  function storageGet(key) {
    return new Promise((resolve) => {
      try { chrome.storage.local.get(key, (r) => resolve(r ? r[key] : null)); }
      catch (e) { resolve(null); }
    });
  }
  function storageSet(key, val) {
    try { chrome.storage.local.set({ [key]: val }); } catch (e) {}
  }

  // same-origin GET with credentials + abort timeout; numbers come back, no throw
  async function apiGet(url) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), CFG.api.timeoutMs);
    try {
      const res = await fetch(url, {
        method: "GET",
        credentials: "include",       // user's own first-party login cookies
        headers: { "Accept": "application/json" },
        signal: ctrl.signal
      });
      clearTimeout(timer);
      if (!res.ok) return { ok: false, status: res.status };
      return { ok: true, json: await res.json() };
    } catch (e) {
      clearTimeout(timer);
      return { ok: false, status: 0 }; // network/abort — treated as graceful fail
    }
  }

  function getPath(obj, path) {
    return path.split(".").reduce((o, k) => (o == null ? undefined : o[k]), obj);
  }

  // ISO8601 -> "in Xh Ym" (or "in Ym" / "now"); null/invalid -> null (renders —)
  function fmtReset(iso) {
    if (!iso) return null;
    const t = Date.parse(iso);
    if (isNaN(t)) return null;
    let mins = Math.round((t - Date.now()) / 60000);
    if (mins <= 0) return "now";
    const d = Math.floor(mins / 1440); mins -= d * 1440;
    const h = Math.floor(mins / 60); const m = mins % 60;
    return "in " + (d ? d + "d " : "") + (h ? h + "h " : "") + m + "m";
  }

  // map JSON -> state via config paths (primary) with a recursive net (fallback)
  const SLOTS = [
    ["session", "sessionPct", "sessionReset"],
    ["weekly", "weeklyPct", "weeklyReset"],
    ["sonnet", "sonnetPct", "sonnetReset"],
    ["opus", "opusPct", "opusReset"]
  ];

  function extractUsage(json) {
    if (!json || typeof json !== "object") return false;
    const map = CFG.usageJsonPaths;
    // is this actually a usage payload? (at least one configured root present)
    const known = SLOTS.some(([k]) => map[k] && map[k].pct.split(".")[0] in json);
    if (!known) return recursiveExtract(json); // shape drifted — try the net
    for (const [k, pctKey, resetKey] of SLOTS) {
      const c = map[k]; if (!c) continue;
      const pct = getPath(json, c.pct);
      state[pctKey] = (typeof pct === "number") ? pct : null; // null => no limit
      state[resetKey] = fmtReset(getPath(json, c.reset));
    }
    return true;
  }

  // safety net if claude.ai renames keys: find {utilization, resets_at?} objects
  function recursiveExtract(json) {
    const found = [];
    (function walk(o, depth) {
      if (!o || typeof o !== "object" || depth > 4) return;
      if (typeof o.utilization === "number") found.push(o);
      for (const v of Object.values(o)) if (v && typeof v === "object") walk(v, depth + 1);
    })(json, 0);
    if (!found.length) return false;
    // best-effort: first three numeric-utilization objects -> session/weekly/sonnet
    const order = ["sessionPct", "weeklyPct", "sonnetPct"];
    const resets = ["sessionReset", "weeklyReset", "sonnetReset"];
    for (let i = 0; i < order.length && i < found.length; i++) {
      state[order[i]] = found[i].utilization;
      state[resets[i]] = fmtReset(found[i].resets_at);
    }
    return true;
  }

  async function resolveOrgId() {
    if (orgId) return orgId;
    const cached = await storageGet("botzy_org_id");
    if (cached) { orgId = cached; return orgId; }
    const r = await apiGet(CFG.api.organizationsUrl);
    if (r.ok && Array.isArray(r.json) && r.json.length) {
      const id = r.json[0].uuid || r.json[0].id; // dynamic — never hardcoded
      if (id) { orgId = id; storageSet("botzy_org_id", id); return id; }
    }
    return null;
  }

  function failPoll(note) {
    // graceful: keep last-known values + usageAsOf; just annotate, never blank
    state.lastPollOk = false;
    state.usageNote = note + " — showing last known";
    render();
  }

  async function pollUsage() {
    const id = await resolveOrgId();
    if (!id) { failPoll("org id unavailable"); return; }
    const url = CFG.api.usagePathTemplate.replace("{org_id}", encodeURIComponent(id));
    const r = await apiGet(url);
    if (!r.ok) {
      if (r.status === 404) { orgId = null; storageSet("botzy_org_id", ""); } // re-resolve next tick
      failPoll(r.status === 401 || r.status === 403 ? "not authorized" : "endpoint unreachable");
      return;
    }
    if (!extractUsage(r.json)) { failPoll("usage shape changed"); return; }
    state.usageAsOf = nowHMS();
    state.usageNote = null;
    state.usageSource = "endpoint";
    state.lastPollOk = true;
    render();
  }

  // ----------------------------------------------------- message tracking/log
  const tracked = new Map(); // message element -> its log row (live while streaming)

  function nowHMS() {
    const d = new Date();
    return [d.getHours(), d.getMinutes(), d.getSeconds()]
      .map((n) => String(n).padStart(2, "0")).join(":");
  }

  function trackMessages() {
    const sel = CFG.selectors.userMessage + "," + CFG.selectors.assistantMessage;
    let els;
    try { els = document.querySelectorAll(sel); } catch (e) { return; }
    for (const el of els) {
      const tokens = estimateTokens(el); // number only — see MOAT header
      let row = tracked.get(el);
      if (!row) {
        let role = "assistant";
        try { if (el.matches(CFG.selectors.userMessage)) role = "user"; } catch (e) {}
        row = { t: nowHMS(), role: role, tokens: tokens, spike: false };
        tracked.set(el, row);
        state.log.push(row);
        if (state.log.length > CFG.maxLogRows) state.log.shift();
      } else {
        row.tokens = tokens; // streaming message still growing — keep current
      }
      state.lastEstTokens = row.tokens;
      if (!row.spike && row.tokens > settings.spikeThresholdTokens) {
        row.spike = true;
        state.spikeCount += 1;
        fireSpike();
      }
    }
    state.totalEstTokens = state.log.reduce((a, r) => a + r.tokens, 0);
  }

  // -------------------------------------------------------------- spike alert
  function fireSpike() {
    if (settings.blinkOn && mascot) {
      mascot.classList.add("botzy-spike");
      setTimeout(() => mascot.classList.remove("botzy-spike"), CFG.blinkMs);
    }
    if (settings.soundOn) beep();
    // numeric test/proof hook — count only
    document.documentElement.setAttribute("data-botzy-spike", String(state.spikeCount));
  }

  function beep() {
    try {
      const Ctx = window.AudioContext || window.webkitAudioContext;
      const ctx = new Ctx();
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.frequency.value = CFG.beep.freqHz;
      gain.gain.value = CFG.beep.volume;
      osc.connect(gain);
      gain.connect(ctx.destination);
      osc.start();
      setTimeout(() => { try { osc.stop(); ctx.close(); } catch (e) {} }, CFG.beep.durationMs);
    } catch (e) { /* audio blocked (autoplay policy / headless) — non-fatal */ }
  }

  // ----------------------------------------------------------------------- UI
  let mascot = null, panel = null, proofEl = null;
  const tabBodies = {};
  const ui = {}; // live display nodes

  function row(parent, label, valueId) {
    const r = document.createElement("div");
    r.className = "botzy-row";
    const l = document.createElement("span");
    l.textContent = label;
    const v = document.createElement("span");
    v.className = "botzy-val";
    v.textContent = "—";
    r.appendChild(l); r.appendChild(v);
    parent.appendChild(r);
    ui[valueId] = v;
  }

  function settingRow(parent, label, input) {
    const lab = document.createElement("label");
    const span = document.createElement("span");
    span.textContent = label;
    lab.appendChild(span); lab.appendChild(input);
    parent.appendChild(lab);
  }

  function checkbox(checked, onChange) {
    const i = document.createElement("input");
    i.type = "checkbox"; i.checked = checked;
    i.addEventListener("change", () => onChange(i.checked));
    return i;
  }

  function numbox(value, min, onChange) {
    const i = document.createElement("input");
    i.type = "number"; i.min = String(min); i.value = String(value);
    i.addEventListener("change", () => {
      const n = parseInt(i.value, 10);
      if (!isNaN(n) && n >= min) onChange(n);
    });
    return i;
  }

  function showTab(name) {
    for (const k of Object.keys(tabBodies)) {
      tabBodies[k].body.classList.toggle("botzy-active", k === name);
      tabBodies[k].btn.classList.toggle("botzy-active", k === name);
    }
  }

  function buildUI() {
    // floating mascot
    mascot = document.createElement("button");
    mascot.id = "botzy-mascot";
    mascot.title = "Botzy Tokenizer";
    const img = document.createElement("img");
    try { img.src = chrome.runtime.getURL("icons/mascot.png"); } catch (e) {}
    img.alt = "Botzy";
    mascot.appendChild(img);
    mascot.addEventListener("click", () => panel.classList.toggle("botzy-open"));

    // panel
    panel = document.createElement("div");
    panel.id = "botzy-panel";

    const head = document.createElement("div");
    head.className = "botzy-head";
    head.textContent = "BOTZY TOKENIZER";
    panel.appendChild(head);

    const tabbar = document.createElement("div");
    tabbar.className = "botzy-tabs";
    panel.appendChild(tabbar);
    for (const name of ["OVERVIEW", "CHAT LOG", "TIPS"]) {
      const btn = document.createElement("button");
      btn.className = "botzy-tab";
      btn.textContent = name;
      btn.addEventListener("click", () => showTab(name));
      tabbar.appendChild(btn);
      const body = document.createElement("div");
      body.className = "botzy-tabbody";
      panel.appendChild(body);
      tabBodies[name] = { btn: btn, body: body };
    }

    // OVERVIEW
    const ov = tabBodies["OVERVIEW"].body;
    row(ov, "Session (5h)", "sessionPct");
    row(ov, "Weekly (all models)", "weeklyPct");
    row(ov, "Weekly (Sonnet)", "sonnetPct");
    row(ov, "Weekly (Opus)", "opusPct");
    ui.opusPct.parentElement.id = "botzy-opus-row"; // hidden when opus is null
    row(ov, "Usage data", "asOf");
    row(ov, "Model", "model");
    row(ov, "Total est. tokens", "total");
    row(ov, "Last msg est.", "last");
    // empty-state hint: explains the "—" so it never reads as a broken 0
    const emptyHint = document.createElement("div");
    emptyHint.id = "botzy-empty-hint";
    emptyHint.className = "botzy-hint";
    emptyHint.style.display = "none";
    ov.appendChild(emptyHint);
    ui.emptyHint = emptyHint;
    row(ov, "Spikes", "spikes");
    // Gate 1/2 bridge: status line + HONEST dtach session list (real names)
    row(ov, "Bridge", "bridge");
    const dtachBox = document.createElement("div");
    dtachBox.id = "botzy-dtach";
    dtachBox.className = "botzy-dtach";
    ov.appendChild(dtachBox);
    ui.dtachBox = dtachBox;

    // CHAT LOG (numbers only: time / role / est tokens)
    const logTable = document.createElement("table");
    logTable.className = "botzy-log";
    const thead = document.createElement("tr");
    for (const h of ["time", "role", "est tok"]) {
      const th = document.createElement("th");
      th.textContent = h;
      thead.appendChild(th);
    }
    logTable.appendChild(thead);
    tabBodies["CHAT LOG"].body.appendChild(logTable);
    ui.logTable = logTable;
    ui.logHead = thead;

    // TIPS (static, from config) + display-only rates
    const tipsBody = tabBodies["TIPS"].body;
    for (const t of CFG.tips) {
      const p = document.createElement("p");
      p.textContent = "• " + t;
      tipsBody.appendChild(p);
    }
    const ratesP = document.createElement("p");
    ratesP.className = "botzy-warn";
    ratesP.textContent = "Display rates (USD/MTok in/out): " +
      Object.keys(CFG.ratesUsdPerMTok).map((f) =>
        f + " " + CFG.ratesUsdPerMTok[f].input + "/" + CFG.ratesUsdPerMTok[f].output).join(" · ");
    tipsBody.appendChild(ratesP);

    // Settings (pinned below tabs)
    const st = document.createElement("div");
    st.className = "botzy-settings";
    const stHead = document.createElement("div");
    stHead.textContent = "Settings";
    stHead.style.fontWeight = "700";
    st.appendChild(stHead);
    settingRow(st, "Spike sound", checkbox(settings.soundOn, (v) => { settings.soundOn = v; saveSettings(); }));
    settingRow(st, "Spike blink", checkbox(settings.blinkOn, (v) => { settings.blinkOn = v; saveSettings(); }));
    settingRow(st, "Refresh (s)", numbox(settings.refreshSec, 1, (v) => { settings.refreshSec = v; saveSettings(); startInterval(); }));
    settingRow(st, "Spike threshold (tok)", numbox(settings.spikeThresholdTokens, 100, (v) => { settings.spikeThresholdTokens = v; saveSettings(); }));
    // Gate 1/2 bridge token. Normally AUTO-PAIRED: background.js fetches it once
    // from the reader's loopback /v1/pair and stores it here — no paste needed.
    // This box is the FALLBACK: if auto-pair fails, paste the token the installer
    // printed. Stored on its OWN key (never inside botzy_settings).
    const tokInput = document.createElement("input");
    tokInput.type = "password";
    tokInput.placeholder = "auto-paired — paste only if needed";
    storageGet("botzy_bridge_token").then((t) => {
      if (t) { tokInput.value = t; state.bridgePaired = true; renderBridge(); }
    });
    tokInput.addEventListener("change", () => {
      const v = tokInput.value.trim();
      storageSet("botzy_bridge_token", v);
      state.bridgePaired = !!v;
      state.bridgeNote = v ? null : "bridge not paired";
      pollBridge();
    });
    settingRow(st, "Bridge token", tokInput);
    panel.appendChild(st);

    // hidden numeric proof hook (numbers only — used by automated tests)
    proofEl = document.createElement("div");
    proofEl.id = "botzy-proof";
    panel.appendChild(proofEl);

    document.body.appendChild(mascot);
    document.body.appendChild(panel);
    showTab("OVERVIEW");
    if (CFG.debugAutoOpen) panel.classList.add("botzy-open");
  }

  // ------------------------------------------------------------------ render
  function fmtPct(v, reset) {
    if (v === null) return "—";
    return v + "%" + (reset ? " · resets " + reset : "");
  }

  function render() {
    ui.sessionPct.textContent = fmtPct(state.sessionPct, state.sessionReset);
    ui.weeklyPct.textContent = fmtPct(state.weeklyPct, state.weeklyReset);
    ui.sonnetPct.textContent = fmtPct(state.sonnetPct, state.sonnetReset);
    ui.opusPct.textContent = fmtPct(state.opusPct, state.opusReset);
    // Opus row only shown when an Opus weekly limit is actually present
    const opusRow = document.getElementById("botzy-opus-row");
    if (opusRow) opusRow.style.display = (state.opusPct === null ? "none" : "");
    // "as of HH:MM:SS" + quiet note; hint only before the first read lands
    let asOf = state.usageAsOf ? "as of " + state.usageAsOf : CFG.hintOpenUsage;
    if (state.usageNote) asOf += " (" + state.usageNote + ")";
    ui.asOf.textContent = asOf;
    ui.asOf.classList.toggle("botzy-warn", !state.usageAsOf || !!state.usageNote);
    ui.model.textContent = state.model || "model unknown";
    ui.model.classList.toggle("botzy-warn", !state.model);
    // empty-state: show "—" (not a scary 0) until the page has tracked a message
    const noEst = state.totalEstTokens === 0;
    ui.total.textContent = noEst ? "—" : String(state.totalEstTokens);
    ui.last.textContent = state.lastEstTokens === null ? "—" : String(state.lastEstTokens);
    ui.spikes.textContent = String(state.spikeCount);
    if (ui.emptyHint) {
      if (noEst) {
        ui.emptyHint.textContent = (state.bridgeHasData === false)
          ? "bridge connected · no Claude Code logs yet — counts appear once you use Claude Code"
          : "no messages estimated on this page yet — counts appear as you chat";
        ui.emptyHint.style.display = "";
      } else {
        ui.emptyHint.style.display = "none";
      }
    }
    renderBridge();

    // rebuild log table (last displayLogRows rows, newest first)
    while (ui.logTable.rows.length > 1) ui.logTable.deleteRow(1);
    const rows = state.log.slice(-CFG.displayLogRows).reverse();
    for (const r of rows) {
      const tr = ui.logTable.insertRow();
      if (r.spike) tr.className = "botzy-spikerow";
      for (const cell of [r.t, r.role, String(r.tokens)]) {
        const td = tr.insertCell();
        td.textContent = cell;
      }
    }

    // numbers-only JSON for automated proof
    proofEl.textContent = JSON.stringify({
      sessionPct: state.sessionPct,
      weeklyPct: state.weeklyPct,
      sonnetPct: state.sonnetPct,
      opusPct: state.opusPct,
      usageAsOf: state.usageAsOf,
      usageSource: state.usageSource,
      usageNote: state.usageNote,
      model: state.model || "model unknown",
      totalEstTokens: state.totalEstTokens,
      lastEstTokens: state.lastEstTokens,
      spikeCount: state.spikeCount
    });
  }

  // Gate 1/2 bridge render: status + HONEST dtach list (real names, NO masking,
  // never "danger"/"Autonomous"). DOM built with textContent/createElement only.
  function renderBridge() {
    if (!ui.bridge) return;
    if (!state.bridgePaired) {
      ui.bridge.textContent = "bridge not paired";
      ui.bridge.classList.add("botzy-warn");
    } else if (state.bridgeNote) {
      ui.bridge.textContent = state.bridgeNote;
      ui.bridge.classList.add("botzy-warn");
    } else if (state.bridgeDtach.length) {
      ui.bridge.textContent = state.bridgeDtach.length + " session(s)";
      ui.bridge.classList.remove("botzy-warn");
    } else if (state.bridgeHasData === false) {
      // reachable + authed, but no ~/.claude/projects logs yet — healthy, not an error
      ui.bridge.textContent = "connected · no Claude Code logs yet";
      ui.bridge.classList.remove("botzy-warn");
    } else {
      ui.bridge.textContent = "connected";
      ui.bridge.classList.remove("botzy-warn");
    }
    const box = ui.dtachBox;
    if (!box) return;
    while (box.firstChild) box.removeChild(box.firstChild);
    for (const d of state.bridgeDtach) {
      const line = document.createElement("div");
      line.className = "botzy-dtach-row";
      const label = document.createElement("span");
      label.textContent = "Resume session: " + d.name +
        (d.attached ? " (attached)" : " (detached)");
      line.appendChild(label);
      box.appendChild(line);
    }
  }

  function refresh() {
    scanModel();
    trackMessages();
    // Endpoint is the source of truth. Modal DOM-scrape is a FALLBACK, used only
    // while the endpoint hasn't succeeded (before first poll, or after a fail).
    if (!state.lastPollOk) scanUsage();
    render();
  }

  // ------------------------------------------------------------------- timers
  let intervalId = null;
  function startInterval() {
    if (intervalId !== null) clearInterval(intervalId);
    intervalId = setInterval(refresh, settings.refreshSec * 1000);
  }

  let pollId = null;
  function startPolling() {
    if (pollId !== null) clearInterval(pollId);
    pollUsage(); // once immediately on load
    pollId = setInterval(pollUsage, CFG.api.pollSec * 1000);
  }

  // Gate 1/2 bridge poll — asks the SERVICE WORKER to read the loopback bridge
  // (content.js never fetches 127.0.0.1 itself). Graceful: no token -> "not
  // paired"; bridge down -> "offline"; never throws, never blanks the panel.
  let bridgeId = null;
  function pollBridge() {
    try {
      chrome.runtime.sendMessage(
        { type: "bridge:getState", port: CFG.bridge.port, path: CFG.bridge.path, pairPath: CFG.bridge.pairPath },
        (resp) => {
          if (chrome.runtime.lastError) { state.bridgeNote = "bridge unavailable"; state.bridgeHasData = null; render(); return; }
          if (!resp || !resp.ok) {
            if (resp && resp.reason === "unpaired") { state.bridgePaired = false; state.bridgeNote = "bridge not paired"; }
            else { state.bridgePaired = true; state.bridgeNote = "bridge offline"; }
            state.bridgeDtach = []; state.bridgeHasData = null;
            render(); return;
          }
          state.bridgePaired = true;
          state.bridgeNote = null;
          const st = resp.state || {};
          // empty-state: reachable but no Claude Code logs yet vs has data
          state.bridgeHasData = (typeof st.has_data === "boolean") ? st.has_data : null;
          state.bridgeDtach = Array.isArray(st.dtach) ? st.dtach.map((d) => ({
            name: String((d && d.name) || ""),
            alive: !!(d && d.alive),
            attached: !!(d && d.attached)
          })) : [];
          render();
        });
    } catch (e) { state.bridgeNote = "bridge unavailable"; renderBridge(); }
  }
  function startBridgePolling() {
    if (bridgeId !== null) clearInterval(bridgeId);
    pollBridge(); // once immediately
    bridgeId = setInterval(pollBridge, (CFG.bridge.pollSec || 300) * 1000);
  }

  let debounceId = null;
  function onMutation() {
    if (debounceId !== null) return;
    debounceId = setTimeout(() => { debounceId = null; refresh(); }, CFG.debounceMs);
  }

  // --------------------------------------------------------------------- init
  function init() {
    buildUI();
    loadSettings(() => {
      refresh();
      startInterval();
      startPolling();        // auto-poll the usage endpoint (primary source)
      startBridgePolling();  // auto-poll the localhost bridge via the worker
      const mo = new MutationObserver(onMutation);
      mo.observe(document.body, { childList: true, subtree: true, characterData: true });
    });
  }

  if (document.body) init();
  else document.addEventListener("DOMContentLoaded", init);
})();
