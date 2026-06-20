// =============================================================================
// BOTZY TOKENIZER — background.js (MV3 service worker)
//
// TWO jobs, both minimal:
//  1) First-run: mint the per-install secret token into chrome.storage.local
//     (extension storage — NEVER page localStorage). Idle today; reserved.
//  2) Gate 1 localhost bridge PROXY: on "bridge:getState" it performs the ONLY
//     loopback fetch in the whole extension. The host is PINNED to 127.0.0.1
//     in code (never taken from config/page) so this worker can never be
//     tricked into talking to a remote host. Because the fetch originates from
//     the service worker, its Origin is chrome-extension://<id> — which is what
//     the reader's bridge allowlists; a content-script fetch (Origin
//     claude.ai) is deliberately rejected 403 by the bridge.
//
// MOAT: only numbers/state cross this worker. The response is sanitised to the
// expected numeric shape before it is handed back; no content is ever stored,
// logged, or echoed. No telemetry, no analytics, no tabs, no remote host.
// =============================================================================
chrome.runtime.onInstalled.addListener(() => {
  chrome.storage.local.get("botzy_install_token", (res) => {
    if (res && res.botzy_install_token) return; // never regenerate
    const bytes = new Uint8Array(32);
    crypto.getRandomValues(bytes);
    let token = "";
    for (const b of bytes) token += b.toString(16).padStart(2, "0");
    chrome.storage.local.set({ botzy_install_token: token });
  });
});

// numbers/state ONLY — strip the bridge response down to the expected shape so
// nothing unexpected (content, prompts, file bodies) can ride back to the page.
function sanitiseState(j) {
  const out = { usage: { five_hour_pct: null, seven_day_pct: null, resets_at: null }, dtach: [] };
  if (j && typeof j.usage === "object" && j.usage) {
    const u = j.usage;
    out.usage.five_hour_pct = (typeof u.five_hour_pct === "number") ? u.five_hour_pct : null;
    out.usage.seven_day_pct = (typeof u.seven_day_pct === "number") ? u.seven_day_pct : null;
    out.usage.resets_at = (typeof u.resets_at === "string") ? u.resets_at : null;
  }
  if (Array.isArray(j && j.dtach)) {
    out.dtach = j.dtach.slice(0, 50).map((d) => ({
      name: (d && typeof d.name === "string") ? d.name.slice(0, 80) : "",
      alive: !!(d && d.alive),
      attached: !!(d && d.attached)
    }));
  }
  return out;
}

// AUTO-PAIR: when no bridge token is stored yet, fetch it ONCE from the reader's
// loopback /v1/pair and persist it — so the user never hand-copies/pastes it. The
// custom X-Botzy-Pair header is what only THIS service worker can send to loopback
// (host_permission = no CORS preflight); a web page's cross-origin attempt would
// be preflighted and blocked. The reader closes the window after the first success.
async function bridgeAutoPair(port, pairPath) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 8000);
  try {
    const res = await fetch(`http://127.0.0.1:${port}${pairPath}`, {
      method: "GET",
      headers: { "X-Botzy-Pair": "1" },
      credentials: "omit",
      signal: ctrl.signal
    });
    clearTimeout(timer);
    if (!res.ok) return null;
    const j = await res.json();
    const token = (j && typeof j.token === "string" && j.token) ? j.token : null;
    if (!token) return null;
    await chrome.storage.local.set({ botzy_bridge_token: token });
    return token;
  } catch (e) { clearTimeout(timer); return null; }
}

async function bridgeGetState(msg) {
  // HOST PINNED to loopback in code — port/path only come from config.
  const port = parseInt(msg && msg.port, 10) || 8765;
  const path = (msg && typeof msg.path === "string" && msg.path[0] === "/") ? msg.path : "/v1/state";
  const pairPath = (msg && typeof msg.pairPath === "string" && msg.pairPath[0] === "/") ? msg.pairPath : "/v1/pair";
  let store;
  try { store = await chrome.storage.local.get("botzy_bridge_token"); }
  catch (e) { return { ok: false, reason: "storage" }; }
  let token = store && store.botzy_bridge_token;
  if (!token) token = await bridgeAutoPair(port, pairPath);   // deliver the token automatically
  if (!token) return { ok: false, reason: "unpaired" };       // auto-pair failed -> manual paste fallback
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 8000);
  try {
    const res = await fetch(`http://127.0.0.1:${port}${path}`, {
      method: "GET",
      headers: { "Authorization": `Bearer ${token}` },
      credentials: "omit",
      signal: ctrl.signal
    });
    clearTimeout(timer);
    if (!res.ok) return { ok: false, reason: "status_" + res.status };
    const json = await res.json();
    return { ok: true, state: sanitiseState(json) };
  } catch (e) {
    clearTimeout(timer);
    return { ok: false, reason: "unreachable" };
  }
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg || msg.type !== "bridge:getState") return false;
  bridgeGetState(msg).then(sendResponse);
  return true; // keep the message channel open for the async response
});
