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
    spikeThresholdTokens: CFG.spikeThresholdTokens,
    // CONTEXT-METER: which plan's context-window ceiling to measure against.
    // Overridable in Settings; auto-calibrated by a detected compaction. R13.
    contextPlan: (CFG.contextMeter && CFG.contextMeter.defaultPlan) || "200k"
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
    bridgeDtach: [],     // [{name, alive, attached}] — HONEST dtach names, no mask
    bridgeAdvice: [],    // E2: reader's LOCAL advice — [{kind, message, model?, inr?}],
                         // outcome MESSAGES only, shown in TIPS when connected + has logs
    bridgeServerAdvice: [], // E4: SERVER/ENGINE advice — [{kind, message, model?}],
                         // pulled by the reader from its own registry-tagged file,
                         // shown as a SEPARATE labelled layer above the local advice
    // ---- CONTEXT-METER (dual-signal) — numbers/booleans only, no content -------
    ctxPlan: null,            // resolved plan key ("200k" | "1m")
    ctxCeiling: null,         // resolved context-window ceiling (tokens)
    ctxPct: null,             // totalEstTokens / ceiling (0..1+); null until ceiling known
    ctxNudged: false,         // 70% approach-nudge already fired (reset by a compaction)
    ctxNudgeMsg: null,
    ctxCompactions: 0,        // compaction events detected (count only)
    ctxCompactionPresent: false, // marker currently in DOM (edge-trigger guard)
    ctxCalibrated: false,     // ceiling confirmed/snapped by a detected compaction
    // ---- SIGNAL LIGHT + PROACTIVE NUDGE — numbers/booleans only ----------------
    recentSpike: false,       // true for CFG.blinkMs after a spike fires (drives red)
    signalLevel: "green",     // "green" | "yellow" | "red" — recomputed every render
    opusNudgeFired: false     // edge-trigger guard so the nudge blinks/beeps once
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
    // drives the signal light red for a bit — cleared the same way as the blink
    state.recentSpike = true;
    setTimeout(() => { state.recentSpike = false; }, CFG.blinkMs);
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

    // SIGNAL LIGHT (tri-color R/Y/G) — sits above the tabs so it's visible the
    // instant the panel opens, whichever tab was last active. Colors/labels are
    // ALL config-driven (R13); set as inline style so it renders correctly even
    // without a matching panel.css rule (this widget's CSS ships separately).
    const sigRow = document.createElement("div");
    sigRow.id = "botzy-signal";
    sigRow.className = "botzy-row";
    const sigDot = document.createElement("span");
    sigDot.id = "botzy-signal-dot";
    sigDot.style.display = "inline-block";
    sigDot.style.width = "10px";
    sigDot.style.height = "10px";
    sigDot.style.borderRadius = "50%";
    sigDot.style.marginRight = "6px";
    const sigLabel = document.createElement("span");
    sigLabel.className = "botzy-val";
    const sigWrap = document.createElement("span");
    sigWrap.appendChild(sigDot);
    sigWrap.appendChild(document.createTextNode("status"));
    sigRow.appendChild(sigWrap);
    sigRow.appendChild(sigLabel);
    panel.appendChild(sigRow);
    ui.signalDot = sigDot;
    ui.signalLabel = sigLabel;

    // PROACTIVE NUDGE + TEASER + CTA — one box, one nudge at a time (see
    // renderNudge). Hidden by default; shown only on a real signal in state.
    const nudgeBox = document.createElement("div");
    nudgeBox.id = "botzy-nudge";
    nudgeBox.style.display = "none";
    const nudgeText = document.createElement("div");
    nudgeText.className = "botzy-hint";
    const nudgeCta = document.createElement("button");
    nudgeCta.id = "botzy-nudge-cta";
    nudgeCta.addEventListener("click", () => {
      const tok = ui.bridgeTokenInput;
      if (tok) { tok.scrollIntoView({ block: "center" }); tok.focus(); }
    });
    nudgeBox.appendChild(nudgeText);
    nudgeBox.appendChild(nudgeCta);
    panel.appendChild(nudgeBox);
    ui.nudgeBox = nudgeBox;
    ui.nudgeText = nudgeText;
    ui.nudgeCta = nudgeCta;

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
    // CONTEXT-METER (dual-signal): fill % of the context window + nudge note
    row(ov, "Context window", "ctxWindow");
    row(ov, "Context note", "ctxNote");
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

    // TIPS — LIVE advice from the reader's own logs (E2) sits ABOVE the static
    // tips. Heading is honest about provenance ("from your local logs"); the
    // body is filled by renderAdvice() and gated on the bridge being connected.
    const tipsBody = tabBodies["TIPS"].body;
    const adviceHead = document.createElement("div");
    adviceHead.className = "botzy-advice-head";
    adviceHead.textContent = "Your advice";
    tipsBody.appendChild(adviceHead);
    const adviceBox = document.createElement("div");
    adviceBox.id = "botzy-advice";
    adviceBox.className = "botzy-advice";
    tipsBody.appendChild(adviceBox);
    ui.adviceBox = adviceBox;
    const tipsHead = document.createElement("div");
    tipsHead.className = "botzy-advice-head";
    tipsHead.textContent = "General tips";
    tipsBody.appendChild(tipsHead);
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
    ui.bridgeTokenInput = tokInput; // nudge CTA scrolls/focuses here on "Connect"
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
    // CONTEXT-METER (dual-signal): "NN% of 200k · calibrated" + nudge/compaction note
    if (ui.ctxWindow) {
      if (state.ctxCeiling && state.ctxPct != null) {
        const pct = Math.round(state.ctxPct * 100);
        const ceilK = state.ctxCeiling >= 1000000
          ? (state.ctxCeiling / 1000000) + "M"
          : Math.round(state.ctxCeiling / 1000) + "k";
        ui.ctxWindow.textContent = pct + "% of " + ceilK +
          (state.ctxCalibrated ? " · calibrated" : "");
        ui.ctxWindow.classList.toggle("botzy-warn",
          pct >= Math.round(((CFG.contextMeter && CFG.contextMeter.nudgePct) || 0.70) * 100));
      } else {
        ui.ctxWindow.textContent = "—";
      }
    }
    if (ui.ctxNote) {
      const note = state.ctxNudged ? (state.ctxNudgeMsg || "approaching the safe point")
        : (state.ctxCompactions > 0 ? ("compactions: " + state.ctxCompactions) : "ok");
      ui.ctxNote.textContent = note;
      ui.ctxNote.classList.toggle("botzy-warn", !!state.ctxNudged);
    }
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
    renderAdvice();
    renderSignal();
    renderNudge();

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

  // Advice render — TWO clearly-labelled layers, bridge-gated, OUTCOME-only lines:
  //   • SERVER / ENGINE layer (E4): the engine's analysis pulled from your own
  //     registry-tagged file (enrollment-gated; may exist before any local log).
  //   • LOCAL layer (E2): the reader's advice from your own Claude Code logs (B3
  //     gate: only when paired + connected + logs present).
  // No bridge => basic-monitoring hint. DOM built with textContent only (advice
  // text is an already-distilled outcome message — never content, never a formula).
  function renderAdvice() {
    const box = ui.adviceBox;
    if (!box) return;
    while (box.firstChild) box.removeChild(box.firstChild);
    function hint(text) {
      const p = document.createElement("div");
      p.className = "botzy-hint";
      p.textContent = text;
      box.appendChild(p);
    }
    function sublabel(text) {
      const d = document.createElement("div");
      d.className = "botzy-advice-sublabel";
      d.textContent = text;
      box.appendChild(d);
    }
    function rows(list) {
      for (const a of list) {
        const p = document.createElement("div");
        p.className = "botzy-advice-row";
        p.textContent = "• " + a.message;
        box.appendChild(p);
      }
    }
    if (!state.bridgePaired || state.bridgeNote) {
      // not connected -> basic monitoring only; don't pretend we have advice
      hint((CFG.nudge && CFG.nudge.disconnectedHint) || "connect the local reader to see advice from your own logs");
      return;
    }
    // SERVER / ENGINE layer first (the unlock the bridge buys), if the engine has
    // written advice for this install. Silent when there is none (no fake content).
    if (state.bridgeServerAdvice.length) {
      sublabel("From the engine (server analysis):");
      rows(state.bridgeServerAdvice);
    }
    // LOCAL layer (from this machine's logs).
    sublabel("From your local logs:");
    if (state.bridgeHasData === false) {
      hint("no advice yet — appears as you use Claude Code");
    } else if (!state.bridgeAdvice.length) {
      hint("no advice for today — nothing stands out in your local logs");
    } else {
      rows(state.bridgeAdvice);
    }
  }

  // renderSignal — paints the tri-color dot + one-line label from
  // state.signalLevel (computed in render() via computeSignalLevel()). Colors
  // and labels come straight from CFG.signal (R13) — inline style, not a CSS
  // class, so it renders correctly regardless of which stylesheet ships.
  function renderSignal() {
    if (!ui.signalDot) return;
    const sg = CFG.signal || {};
    const level = computeSignalLevel();
    state.signalLevel = level;
    const color = (sg.colors && sg.colors[level]) || "#9a9ab8";
    const label = (sg.labels && sg.labels[level]) || level;
    ui.signalDot.style.background = color;
    ui.signalDot.className = "botzy-signal-" + level; // hook for a future CSS rule
    if (ui.signalLabel) ui.signalLabel.textContent = label;
    document.documentElement.setAttribute("data-botzy-signal", level); // proof hook
  }

  // renderNudge — ONE proactive box, non-spammy (edge-triggered blink/beep, not
  // per-render). Priority: connected + opus-waste/spike advice > disconnected.
  // The teaser line is deliberately short — never the advisor's full logic.
  function renderNudge() {
    if (!ui.nudgeBox) return;
    const nd = CFG.nudge || {};
    if (nd.enabled === false) { ui.nudgeBox.style.display = "none"; return; }
    const connected = state.bridgePaired && !state.bridgeNote;
    const opusWaste = connected && hasOpusWasteAdvice();
    const spikeNow = connected && state.recentSpike;
    if (opusWaste || spikeNow) {
      if (!state.opusNudgeFired) {
        state.opusNudgeFired = true;
        if (settings.blinkOn && mascot) {
          mascot.classList.add("botzy-spike");
          setTimeout(() => mascot.classList.remove("botzy-spike"), CFG.blinkMs);
        }
        if (settings.soundOn) beep();
      }
      const opusPct = (typeof state.opusPct === "number") ? state.opusPct : 0;
      const headline = spikeNow ? (nd.spikeCopy || "")
        : (nd.opusCopy || "").replace("{opusPct}", String(opusPct));
      ui.nudgeText.textContent = headline + " " + (nd.teaserCopy || "");
      ui.nudgeCta.textContent = nd.ctaUpgradeLabel || "Upgrade";
      ui.nudgeBox.style.display = "";
    } else if (!connected) {
      state.opusNudgeFired = false;
      ui.nudgeText.textContent = nd.disconnectedHint || "connect the local reader to see advice from your own logs";
      ui.nudgeCta.textContent = nd.ctaConnectLabel || "Connect to bridge";
      ui.nudgeBox.style.display = "";
    } else {
      state.opusNudgeFired = false;
      ui.nudgeBox.style.display = "none";
    }
  }

  // ============================================================================
  // CONTEXT-METER (dual-signal) — how full is the current context WINDOW.
  //   Signal-1: DOM-estimate% (state.totalEstTokens / ceiling) -> 70% nudge.
  //   Signal-2: compaction-detect (app's own marker) -> confirm-full + calibrate.
  // MOAT: length-only estimate (chars/4, already computed); compaction detection
  // matches a known marker phrase on a UI node — message content is never read here.
  // ============================================================================
  function resolveCeiling() {
    const cm = CFG.contextMeter || {};
    const plan = settings.contextPlan || cm.defaultPlan;
    const ceil = (cm.plans && cm.plans[plan] != null) ? cm.plans[plan] : null;
    state.ctxPlan = plan;
    state.ctxCeiling = ceil;
    return ceil;
  }

  // present? — true only when the app's OWN compaction marker is in the DOM.
  function detectCompaction() {
    const cm = CFG.contextMeter || {};
    const pats = (cm.compactionTextPatterns || []).map((p) => p.toLowerCase());
    for (const sel of (cm.compactionSelectors || [])) {
      let els;
      try { els = document.querySelectorAll(sel); } catch (e) { continue; }
      for (const el of els) {
        if (el.closest("#botzy-panel")) continue;       // never our own panel
        // MOAT: we read the marker node's text ONLY to confirm the marker phrase;
        // we keep a boolean, never the text, and never scan message bodies.
        const t = (el.textContent || "").toLowerCase();
        for (const p of pats) { if (t.indexOf(p) !== -1) return true; }
      }
    }
    return false;
  }

  // On a detected compaction, snap the ceiling to the nearest known tier from the
  // estimate-at-compaction (~190k->200k, ~950k->1M), within tolerance. R13 tiers.
  function calibrateContextCeiling() {
    const cm = CFG.contextMeter || {};
    const tiers = cm.calibrationTiers || [];
    const tol = (cm.toleranceFrac != null) ? cm.toleranceFrac : 0.10;
    const est = state.totalEstTokens;
    let best = null;
    for (const tier of tiers) {
      if (Math.abs(est - tier) <= tier * tol) {
        if (best === null || Math.abs(est - tier) < Math.abs(est - best)) best = tier;
      }
    }
    if (best === null) return false;
    state.ctxCeiling = best;
    state.ctxCalibrated = true;
    const plans = cm.plans || {};
    for (const k of Object.keys(plans)) {
      if (plans[k] === best) { state.ctxPlan = k; settings.contextPlan = k; saveSettings(); break; }
    }
    return true;
  }

  function fireContextNudge() {
    const cm = CFG.contextMeter || {};
    const pct = Math.round((state.ctxPct || 0) * 100);
    if (settings.blinkOn && mascot) {
      mascot.classList.add("botzy-spike");
      setTimeout(() => mascot.classList.remove("botzy-spike"), CFG.blinkMs);
    }
    if (settings.soundOn) beep();
    state.ctxNudgeMsg = (cm.nudgeCopy || "")
      .replace("{pct}", String(pct))
      .replace("{ceiling}", String(settings.contextPlan || state.ctxPlan || ""));
    // numeric/boolean test+proof hooks (count + pct only; never content)
    document.documentElement.setAttribute("data-botzy-ctx-nudge", String(pct));
  }

  function computeContextMeter() {
    const cm = CFG.contextMeter || {};
    if (cm.enabled === false) return;
    resolveCeiling();
    // Signal-2: compaction (edge-triggered so a persistent marker counts once).
    const present = detectCompaction();
    if (present && !state.ctxCompactionPresent) {
      state.ctxCompactions += 1;
      calibrateContextCeiling();   // confirm-full -> snap ceiling to nearest tier
      state.ctxNudged = false;     // window has room again after a compaction
    }
    state.ctxCompactionPresent = present;
    // Signal-1: DOM-estimate% of the ceiling -> 70% approach-nudge (once until reset).
    if (state.ctxCeiling) {
      state.ctxPct = state.totalEstTokens / state.ctxCeiling;
      if (state.ctxPct >= (cm.nudgePct != null ? cm.nudgePct : 0.70) && !state.ctxNudged) {
        state.ctxNudged = true;
        fireContextNudge();
      }
    }
    // expose the live fill % for the proof hook (rounded; number only)
    if (state.ctxPct != null) {
      document.documentElement.setAttribute("data-botzy-ctx-pct",
        String(Math.round(state.ctxPct * 100)));
    }
  }

  // ============================================================================
  // SIGNAL LIGHT (tri-color R/Y/G) — one glance health read, from EXISTING state
  // only (usage %, contextMeter, advice). Thresholds/colors/labels all in config.
  // ============================================================================
  function computeSignalLevel() {
    const sg = CFG.signal || {};
    if (sg.enabled === false) return "green";
    const hard = (sg.hardBreachPct != null) ? sg.hardBreachPct : 100;
    const soft = (sg.breachPct != null) ? sg.breachPct : 90;
    const pcts = [state.sessionPct, state.weeklyPct, state.sonnetPct, state.opusPct]
      .filter((v) => typeof v === "number");
    const hardBreach = pcts.some((v) => v >= hard);
    const softBreach = pcts.some((v) => v >= soft);
    const opusWaste = hasOpusWasteAdvice();
    if (state.recentSpike || opusWaste || hardBreach) return "red";
    const ctxWarm = state.ctxPct != null &&
      state.ctxPct >= ((CFG.contextMeter && CFG.contextMeter.nudgePct) || 0.70);
    if (ctxWarm || softBreach) return "yellow";
    return "green";
  }

  // true when the reader's advice (local or server layer) is tagged as Opus-waste,
  // or (fallback, no tagged advice yet) the weekly Opus utilization itself is high.
  function hasOpusWasteAdvice() {
    const nd = CFG.nudge || {};
    const kinds = nd.opusAdviceKinds || [];
    const tagged = state.bridgeAdvice.concat(state.bridgeServerAdvice)
      .some((a) => kinds.indexOf(a.kind) !== -1);
    if (tagged) return true;
    const thresh = (nd.opusPctThreshold != null) ? nd.opusPctThreshold : 30;
    return typeof state.opusPct === "number" && state.opusPct >= thresh;
  }

  function refresh() {
    scanModel();
    trackMessages();
    computeContextMeter();   // dual-signal context-window meter (length-only, MOAT-safe)
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
          if (chrome.runtime.lastError) { state.bridgeNote = "bridge unavailable"; state.bridgeHasData = null; state.bridgeAdvice = []; state.bridgeServerAdvice = []; render(); return; }
          if (!resp || !resp.ok) {
            if (resp && resp.reason === "unpaired") { state.bridgePaired = false; state.bridgeNote = "bridge not paired"; }
            // M5: a live-but-rejecting bridge (401) is NOT "offline" — the reader is
            // up; our token is stale/wrong. Tell the user to re-pair, not to restart.
            else if (resp && resp.reason === "token_rejected") { state.bridgePaired = true; state.bridgeNote = "bridge paired but token rejected — re-pair (reload the page) or paste a fresh token"; }
            else { state.bridgePaired = true; state.bridgeNote = "bridge offline"; }
            state.bridgeDtach = []; state.bridgeHasData = null; state.bridgeAdvice = []; state.bridgeServerAdvice = [];
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
          // E2: LOCAL outcome-only advice messages (defensive re-sanitise on the page side)
          state.bridgeAdvice = Array.isArray(st.advice) ? st.advice.map((a) => ({
            kind: String((a && a.kind) || "tip"),
            message: String((a && a.message) || ""),
            model: (a && typeof a.model === "string") ? a.model : null,
            inr: (a && typeof a.inr === "number") ? a.inr : null
          })).filter((a) => a.message) : [];
          // E4: SERVER/ENGINE outcome-only advice (defensive re-sanitise on the page side too)
          state.bridgeServerAdvice = Array.isArray(st.server_advice) ? st.server_advice.map((a) => ({
            kind: String((a && a.kind) || "engine"),
            message: String((a && a.message) || ""),
            model: (a && typeof a.model === "string") ? a.model : null
          })).filter((a) => a.message) : [];
          render();
        });
    } catch (e) { state.bridgeNote = "bridge unavailable"; state.bridgeAdvice = []; state.bridgeServerAdvice = []; renderBridge(); renderAdvice(); }
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
