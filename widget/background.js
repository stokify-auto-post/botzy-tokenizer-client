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
  const out = { usage: { five_hour_pct: null, seven_day_pct: null, resets_at: null },
                logs_found: null, has_data: null, dtach: [] };
  if (j && typeof j.usage === "object" && j.usage) {
    const u = j.usage;
    out.usage.five_hour_pct = (typeof u.five_hour_pct === "number") ? u.five_hour_pct : null;
    out.usage.seven_day_pct = (typeof u.seven_day_pct === "number") ? u.seven_day_pct : null;
    out.usage.resets_at = (typeof u.resets_at === "string") ? u.resets_at : null;
  }
  // empty-state signal (numbers/bool only): "bridge alive, no logs yet" vs offline
  if (j && typeof j.logs_found === "number") out.logs_found = j.logs_found;
  if (j && typeof j.has_data === "boolean") out.has_data = j.has_data;
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

// One authed GET /v1/state. Returns {ok,state} on 200, {ok:false,reason,status}
// otherwise (status carried so the caller can detect a 401 = stale token).
async function bridgeFetchState(port, path, token) {
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
    if (res.ok) return { ok: true, state: sanitiseState(await res.json()) };
    return { ok: false, reason: "status_" + res.status, status: res.status };
  } catch (e) {
    clearTimeout(timer);
    return { ok: false, reason: "unreachable" };
  }
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
  const hadToken = !!token;                                    // distinguishes stale vs never-paired
  if (!token) token = await bridgeAutoPair(port, pairPath);   // fresh-install: deliver the token
  if (!token) return { ok: false, reason: "unpaired" };       // auto-pair failed -> manual paste fallback

  let result = await bridgeFetchState(port, path, token);

  // STALE-TOKEN RECOVERY: a 401 while we HELD a stored token means the reader
  // reminted its token (reinstall/restart) and ours is stale — a reload doesn't
  // clear chrome.storage, and only the widget can fix it. Clear the stale token,
  // re-pair ONCE (the reader reopened its one-time window on restart), retry. A
  // single attempt per stale 401: if re-pair or the retry fails we surface the
  // honest result (offline) — no /v1/pair spin, manual-paste box stays as backup.
  if (result.status === 401 && hadToken) {
    try { await chrome.storage.local.remove("botzy_bridge_token"); } catch (e) {}
    const fresh = await bridgeAutoPair(port, pairPath);
    result = fresh ? await bridgeFetchState(port, path, fresh)
                   : { ok: false, reason: "unreachable" };    // window closed / reader gone
  }
  return result;
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg || msg.type !== "bridge:getState") return false;
  bridgeGetState(msg).then(sendResponse);
  return true; // keep the message channel open for the async response
});
