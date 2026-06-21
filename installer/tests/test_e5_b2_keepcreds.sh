#!/usr/bin/env bash
# B2: an uninstall whose server-wipe does NOT confirm (non-200/401) must KEEP
# creds.json + a wipe_pending marker (so a later re-run can still wipe), and remove
# everything else. A confirmed wipe (200) then removes creds too.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INST="$(cd "$HERE/.." && pwd)"
SBX="$(mktemp -d /tmp/sbx_b2.XXXXXX)"
NAME="test_e5_b2_keepcreds"
PORT=18097

cleanup() { [ -n "${STUB_PID:-}" ] && kill "$STUB_PID" 2>/dev/null; rm -rf "$SBX"; }
trap cleanup EXIT
fail() { echo "[FAIL] $NAME: $1"; [ -n "${OUT:-}" ] && echo "$OUT" | sed 's/^/    /'; exit 1; }

# config: server_base -> local stub; HOME -> sandbox
mkcfg() {  # $1 = port
  CFG="$SBX/cfg.yaml"
  sed -e 's#^server_base:.*#server_base:    "http://127.0.0.1:'"$1"'"#' \
      -e "s#\${HOME}#$SBX#g" "$INST/installer_config.yaml" > "$CFG"
}

INSTALL_ROOT="$SBX/.botzy-tokenizer"
CREDS="$INSTALL_ROOT/creds.json"
seed_install() {
  rm -rf "$INSTALL_ROOT"
  mkdir -p "$INSTALL_ROOT/reader" "$INSTALL_ROOT/widget" "$INSTALL_ROOT/logs"
  printf '{"registry_id":"%s","install_token":"tok-xyz","transit_key":"k"}' \
    "0123456789abcdef0123456789abcdef" > "$CREDS"
  echo "x" > "$INSTALL_ROOT/reader/local_bridge.py"
}

# ── 1. wipe FAILS (500 stub) -> creds + marker kept, rest gone ───────────────
python3 "$HERE/_stub_http.py" "$PORT" 500 >"$SBX/stub.out" 2>&1 &
STUB_PID=$!
for i in $(seq 1 20); do grep -q STUB_READY "$SBX/stub.out" 2>/dev/null && break; sleep 0.2; done
mkcfg "$PORT"; seed_install
OUT="$(HOME="$SBX" BOTZY_CONFIG="$CFG" bash "$INST/uninstall.sh" 2>&1)"; RC=$?
[ "$RC" -eq 0 ]                                  || fail "uninstall exit $RC != 0 (failed wipe must not abort)"
[ -f "$CREDS" ]                                  || fail "creds.json DELETED on failed wipe (B2 regression!)"
[ -f "$INSTALL_ROOT/wipe_pending" ]              || fail "wipe_pending marker not written"
[ ! -d "$INSTALL_ROOT/reader" ]                  || fail "reader/ not removed on failed wipe"
[ ! -d "$INSTALL_ROOT/widget" ]                  || fail "widget/ not removed on failed wipe"
echo "$OUT" | grep -qi "still exists"            || fail "missing honest 'data still exists' message"
kill "$STUB_PID" 2>/dev/null; STUB_PID=""

# ── 2. re-run with a CONFIRMING wipe (200 stub) -> creds removed ─────────────
python3 "$HERE/_stub_http.py" "$PORT" 200 >"$SBX/stub2.out" 2>&1 &
STUB_PID=$!
for i in $(seq 1 20); do grep -q STUB_READY "$SBX/stub2.out" 2>/dev/null && break; sleep 0.2; done
OUT="$(HOME="$SBX" BOTZY_CONFIG="$CFG" bash "$INST/uninstall.sh" 2>&1)"; RC=$?
[ "$RC" -eq 0 ]                                  || fail "re-run uninstall exit $RC != 0"
[ ! -f "$CREDS" ]                                || fail "creds.json kept after a CONFIRMED (200) wipe"
[ ! -d "$INSTALL_ROOT" ]                         || fail "install root not removed after confirmed wipe"

echo "[PASS] $NAME (fail->keep creds+marker; 200->remove creds)"
exit 0
