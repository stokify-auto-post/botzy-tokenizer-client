#!/usr/bin/env bash
# B1: uninstall must STOP a reader bound to this install (even one the pid-file
# doesn't know about, matched by its local_bridge.py path) and WAIT for it to exit
# BEFORE deleting — never orphan a port-bound reader, never abort the delete.
# Linux stand-in for the Windows file-lock case (identity-based stop is shared code).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INST="$(cd "$HERE/.." && pwd)"
SBX="$(mktemp -d /tmp/sbx_b1.XXXXXX)"
NAME="test_e5_b1_stopreader"

cleanup() { [ -n "${READER_PID:-}" ] && kill "$READER_PID" 2>/dev/null; rm -rf "$SBX"; }
trap cleanup EXIT
fail() { echo "[FAIL] $NAME: $1"; [ -n "${OUT:-}" ] && echo "$OUT" | sed 's/^/    /'; exit 1; }

# config: no server reachable (creds absent -> wipe skipped, WIPE_OK=1 -> full delete)
CFG="$SBX/cfg.yaml"
sed -e "s#\${HOME}#$SBX#g" "$INST/installer_config.yaml" > "$CFG"

INSTALL_ROOT="$SBX/.botzy-tokenizer"
READER_DIR="$INSTALL_ROOT/reader"
mkdir -p "$READER_DIR" "$INSTALL_ROOT/logs"
# a fake reader that just sleeps (stands in for the bound local_bridge.py)
cat > "$READER_DIR/local_bridge.py" <<'PY'
import time
while True:
    time.sleep(1)
PY

# launch it WITHOUT recording reader.pid -> proves identity-based match (not pid-file)
python3 "$READER_DIR/local_bridge.py" >/dev/null 2>&1 &
READER_PID=$!
sleep 0.5
kill -0 "$READER_PID" 2>/dev/null || fail "fake reader did not start"

OUT="$(HOME="$SBX" BOTZY_CONFIG="$CFG" bash "$INST/uninstall.sh" 2>&1)"; RC=$?
[ "$RC" -eq 0 ]                          || fail "uninstall exit $RC != 0"
# reader must be stopped (pid no longer alive)
sleep 0.3
if kill -0 "$READER_PID" 2>/dev/null; then fail "reader still running after uninstall (orphaned)"; fi
READER_PID=""
[ ! -d "$INSTALL_ROOT" ]                 || fail "install root not removed after stopping reader"
echo "$OUT" | grep -qi "removed"         || fail "no removal confirmation in output"

echo "[PASS] $NAME (identity-matched reader stopped, then dir removed)"
exit 0
