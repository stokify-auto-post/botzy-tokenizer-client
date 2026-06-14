#!/usr/bin/env bash
# LIVE smoke (the ONE test that touches the real server). Sandbox HOME under
# /tmp. Runs setup end-to-end EXCEPT service registration + browser step, then
# uninstall (which wipes server-side). Asserts: enroll 201, creds 0600,
# /health 200, wipe 200/401, sandbox left clean. Cleans up even on failure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INST="$(cd "$HERE/.." && pwd)"
SBX="$(mktemp -d /tmp/sbx_live.$$.XXXXXX)"
NAME="test_live_smoke"

# real config but with HOME redirected into the sandbox (so we never touch the
# real ~/.botzy-tokenizer). server_base/paths stay = live server.
CFG="$SBX/cfg.yaml"
sed "s#\${HOME}#$SBX#g" "$INST/installer_config.yaml" > "$CFG"

cleanup() {
  # always attempt server-side wipe + local cleanup, even on early failure
  HOME="$SBX" BOTZY_CONFIG="$CFG" bash "$INST/uninstall.sh" >"$SBX/uninstall.out" 2>&1 || true
  rm -rf "$SBX"
}
fail() { echo "[FAIL] $NAME: $1"; echo "--setup--"; sed 's/^/    /' "$SBX/setup.out" 2>/dev/null; \
         echo "--uninstall--"; sed 's/^/    /' "$SBX/uninstall.out" 2>/dev/null; cleanup; exit 1; }

# ---- INSTALL (live enroll) ----
HOME="$SBX" BOTZY_CONFIG="$CFG" BOTZY_NO_SERVICE=1 BOTZY_NO_BROWSER=1 \
  bash "$INST/setup.sh" >"$SBX/setup.out" 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "setup exit $RC (expected 0)"
grep -q "enrolled (201)" "$SBX/setup.out" || fail "no 201 enroll in output"
grep -q "reader healthy"  "$SBX/setup.out" || fail "/health did not pass"

CREDS="$SBX/.botzy-tokenizer/creds.json"
[ -f "$CREDS" ] || fail "creds.json missing"
PERM="$(stat -c '%a' "$CREDS" 2>/dev/null || stat -f '%Lp' "$CREDS")"
[ "$PERM" = "600" ] || fail "creds.json perms $PERM != 600"
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if d.get("registry_id") else 1)' "$CREDS" \
  || fail "creds.json has no registry_id"

# independent /health probe
PORT="$(grep -E '^[[:space:]]*bridge_port' "$CFG" | sed -E 's/[^0-9]//g')"
curl -sS --max-time 5 "http://127.0.0.1:${PORT}/health" | grep -q '"ok"[[:space:]]*:[[:space:]]*true' \
  || fail "independent /health probe failed on port $PORT"

# ---- UNINSTALL (live wipe) ----
HOME="$SBX" BOTZY_CONFIG="$CFG" bash "$INST/uninstall.sh" >"$SBX/uninstall.out" 2>&1; RU=$?
[ "$RU" -eq 0 ] || fail "uninstall exit $RU"
grep -qE "wiped \(200\)|already gone \(401\)" "$SBX/uninstall.out" || fail "wipe did not return 200/401"
[ ! -e "$SBX/.botzy-tokenizer" ] || fail "install root not removed after uninstall"

echo "[PASS] $NAME (enroll 201, creds 0600, /health 200, wipe ok, sandbox clean)"
rm -rf "$SBX"   # cleanup already happened logically; remove sandbox
exit 0
