// =============================================================================
// BOTZY TOKENIZER — config.js  (R13: ALL knobs live HERE, none in logic files)
//
// Loaded BEFORE content.js (manifest content_scripts js order) — defines the
// global BOTZY_CONFIG. Runtime-tunable values (sound/blink/refresh/threshold)
// are overridden by the user's saved settings in chrome.storage.local via the
// panel's Settings; everything else (selectors, patterns, rates, tips) is
// edited HERE when claude.ai's UI drifts — never in content.js.
// =============================================================================
const BOTZY_CONFIG = {
  version: "0.3.1",

  // ---- usage API (PRIMARY source, v0.2.0) -----------------------------------
  // Same-origin, read-only, ZERO cost: the exact endpoint the browser hits when
  // Settings -> Usage is opened. credentials:'include' reuses the user's own
  // first-party login cookies (the widget never sees/stores them). org_id is
  // resolved DYNAMICALLY per user (never hardcoded) and cached in storage.
  // MOAT: parser reads ONLY *.utilization (number %) and *.resets_at (ISO ts).
  api: {
    organizationsUrl: "https://claude.ai/api/organizations",
    usagePathTemplate: "https://claude.ai/api/organizations/{org_id}/usage",
    pollSec: 300,              // auto-poll cadence (also fires once on load)
    timeoutMs: 8000            // per-request abort timeout
  },

  // Exact field map for GET /usage (confirmed 2026-06-08). Each metric:
  // { pct: <path to utilization number>, reset: <path to resets_at ISO> }.
  // utilization or resets_at may be null (no active limit) => render "—" / hide,
  // never crash. Schema drift = edit THESE paths (R13), not content.js; the
  // recursive fallback in extractUsage() is a safety net, this map is primary.
  usageJsonPaths: {
    session: { pct: "five_hour.utilization",        reset: "five_hour.resets_at" },
    weekly:  { pct: "seven_day.utilization",        reset: "seven_day.resets_at" },
    sonnet:  { pct: "seven_day_sonnet.utilization", reset: "seven_day_sonnet.resets_at" },
    opus:    { pct: "seven_day_opus.utilization",   reset: "seven_day_opus.resets_at" }
  },

  // ---- estimation / polling -------------------------------------------------
  refreshSec: 5,               // usage re-scan interval (settings-overridable)
  charsPerToken: 4,            // tokens ~= textContent.length / charsPerToken
  spikeThresholdTokens: 2000,  // per-message estimate above this trips the alert
  maxLogRows: 200,             // CHAT LOG cap — memory only, never persisted
  displayLogRows: 50,          // rows actually rendered in the CHAT LOG tab
  modelNameMaxLen: 40,         // longer text = not a model label; stay "unknown"
  debounceMs: 250,             // MutationObserver re-scan debounce
  blinkMs: 4000,               // mascot blink duration on spike

  // ---- alerts (settings-overridable defaults) --------------------------------
  soundOn: true,
  blinkOn: true,
  beep: { freqHz: 880, durationMs: 150, volume: 0.2 },

  // ---- DOM selectors — claude.ai UI drift => edit HERE, never content.js -----
  selectors: {
    // usage-bearing elements; ONLY these are text-scanned for percentages
    // (MOAT: conversation messages are explicitly excluded in scanUsage).
    // Usage lives in the Settings -> Usage MODAL ([role=dialog]) — not on the
    // chat page. The user opens the modal once; the widget scrapes it while
    // open and caches the values with an "as of" time.
    usage: [
      '[role="dialog"]',
      '[data-testid*="usage"]',
      '[class*="usage"]',
      '[aria-label*="usage" i]'
    ],
    // model label candidates (first short match wins; none => "model unknown")
    model: [
      '[data-testid="model-selector"]',
      'button[data-testid*="model"]'
    ],
    userMessage: '[data-testid="user-message"]',
    assistantMessage: '[data-testid="assistant-message"], .font-claude-message'
  },

  // ---- usage text patterns (capture group 1 = percent / reset time) ----------
  // Real modal (2026-06-07): "Plan usage limits"; rows = label + "NN% used" +
  // "Resets in N hr N min". Labels: "Current session" / "All models" /
  // "Sonnet only". Window {0,80} keeps each match tied to ITS label.
  patterns: {
    sessionPct: /current\s*session[^%]{0,80}?(\d{1,3})\s*%\s*used/i,
    weeklyPct: /all\s*models[^%]{0,80}?(\d{1,3})\s*%\s*used/i,
    weeklySonnetPct: /sonnet\s*only[^%]{0,80}?(\d{1,3})\s*%\s*used/i,
    sessionReset: /current\s*session[\s\S]{0,60}?resets\s*in\s*((?:\d+\s*(?:hours?|hrs?|minutes?|mins?|seconds?|secs?|days?|[hmsd])\s*)+)/i,
    weeklyReset: /all\s*models[\s\S]{0,60}?resets\s*in\s*((?:\d+\s*(?:hours?|hrs?|minutes?|mins?|seconds?|secs?|days?|[hmsd])\s*)+)/i
  },

  // ---- hint shown until usage has been read once (endpoint or modal) ---------
  hintOpenUsage: "fetching usage…",

  // ---- display-only rate table (USD per MTok; informational). NEVER applied
  //      to an unknown model — honesty rule: no silent default rate. ----------
  ratesUsdPerMTok: {
    opus: { input: 5.0, output: 25.0 },
    sonnet: { input: 3.0, output: 15.0 },
    haiku: { input: 1.0, output: 5.0 }
  },

  // ---- TIPS tab content -------------------------------------------------------
  tips: [
    "Usage % auto-refreshes from your own claude.ai session every few minutes — no need to open Settings.",
    "'as of HH:MM:SS' shows when the numbers were last fetched; it advances on its own.",
    "Reading usage costs nothing — it's the same data Settings → Usage shows, no model call.",
    "Spike alert fires when ONE message's estimate exceeds the threshold (see Settings).",
    "Estimates are length-based (chars / 4) — directional, not billing-grade.",
    "'model unknown' means the page doesn't expose it — no rate is silently assumed.",
    "Long conversations re-send history every turn — fresh chats cut usage.",
    "Rates table is display-only and editable in config.js (R13)."
  ],

  // ---- Gate 1/2 localhost bridge (reader <-> widget) — R13 ---------------------
  // 127.0.0.1-ONLY, GET-only, token+origin gated, numbers/state only. The
  // content-script NEVER fetches this directly — it asks background.js (the
  // service worker) so the request Origin is chrome-extension://<id>, never
  // claude.ai. Host is pinned to loopback in background.js (a safety invariant,
  // not a tunable); only port/path/cadence are config here.
  bridge: {
    host: "127.0.0.1",   // informational; background.js pins loopback in code
    port: 8765,          // must match reader/bridge_local_config.yaml
    path: "/v1/state",   // GET-only state endpoint
    pairPath: "/v1/pair",// GET-only AUTO-PAIR: fetched ONCE when no token is stored,
                         // returns {token}; reader closes the window after first use
    pollSec: 300         // reuse the usage-endpoint cadence (api.pollSec); +on-load
  },

  // ---- test hook: auto-open panel (set true only by the test harness) ---------
  debugAutoOpen: false
};
