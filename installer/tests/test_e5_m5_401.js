// test_e5_m5_401.js — M5: the widget must distinguish a 401 "token rejected"
// (bridge ALIVE but our token stale/wrong) from a network-unreachable "offline".
//
// Loads the REAL widget/background.js in a sandbox with stubbed chrome + fetch,
// captures its onMessage listener, and drives bridgeGetState end-to-end:
//   • bridge returns 401 (and re-pair fails)  -> reason "token_rejected"  (NOT offline)
//   • bridge unreachable (fetch throws)        -> reason "unreachable"     (offline)
//
// Run: node test_e5_m5_401.js   (exit 0 = pass)
const fs = require("fs");
const vm = require("vm");
const path = require("path");

const BG = path.join(__dirname, "..", "..", "widget", "background.js");
let pass = 0, fail = 0;
function check(name, cond, extra) {
  if (cond) { pass++; console.log("PASS " + name); }
  else { fail++; console.log("FAIL " + name + "  " + (extra || "")); }
}

// Run background.js fresh with a given fetch stub + initial storage; return the
// captured onMessage listener and a live storage object.
function loadBackground(fetchStub, initialStorage) {
  const storage = Object.assign({}, initialStorage);
  let listener = null;
  const local = {
    get(key, cb) {
      const out = {};
      if (typeof key === "string") out[key] = storage[key];
      else if (Array.isArray(key)) key.forEach((k) => (out[k] = storage[k]));
      else Object.assign(out, storage);
      if (cb) cb(out);
      return Promise.resolve(out);
    },
    set(obj, cb) { Object.assign(storage, obj); if (cb) cb(); return Promise.resolve(); },
    remove(key, cb) { delete storage[key]; if (cb) cb(); return Promise.resolve(); }
  };
  const chrome = {
    runtime: {
      lastError: null,
      onInstalled: { addListener() {} },
      onMessage: { addListener(fn) { listener = fn; } }
    },
    storage: { local }
  };
  const sandbox = { chrome, fetch: fetchStub, crypto, setTimeout, clearTimeout, console,
                    AbortController, Promise, JSON, parseInt };
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(BG, "utf8"), sandbox, { filename: "background.js" });
  return { listener, storage };
}

function ask(listener, msg) {
  return new Promise((resolve) => {
    listener(msg, {}, resolve);   // sendResponse = resolve
  });
}

async function main() {
  const MSG = { type: "bridge:getState", port: 8765, path: "/v1/state", pairPath: "/v1/pair" };

  // CASE 1 — bridge ALIVE but rejecting: /v1/state -> 401, /v1/pair -> 403 (no re-pair).
  // We HELD a stale token, so the code clears it, tries one re-pair (fails), and the
  // final 401 must surface as token_rejected.
  {
    const fetchStub = async (url) => {
      if (url.indexOf("/v1/pair") !== -1) return { ok: false, status: 403, json: async () => ({}) };
      return { ok: false, status: 401, json: async () => ({}) };
    };
    const { listener } = loadBackground(fetchStub, { botzy_bridge_token: "stale-token" });
    const resp = await ask(listener, MSG);
    check("401 + re-pair fail -> reason 'token_rejected' (NOT offline)",
          resp && resp.ok === false && resp.reason === "token_rejected" && resp.status === 401,
          JSON.stringify(resp));
  }

  // CASE 2 — bridge UNREACHABLE: fetch throws (network/abort). Must be "unreachable",
  // never "token_rejected".
  {
    const fetchStub = async () => { throw new Error("ECONNREFUSED"); };
    const { listener } = loadBackground(fetchStub, { botzy_bridge_token: "some-token" });
    const resp = await ask(listener, MSG);
    check("network down -> reason 'unreachable' (offline), not token_rejected",
          resp && resp.ok === false && resp.reason === "unreachable",
          JSON.stringify(resp));
  }

  console.log("\n" + pass + " passed, " + fail + " failed");
  process.exit(fail ? 1 : 0);
}

main();
