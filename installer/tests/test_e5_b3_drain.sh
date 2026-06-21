#!/usr/bin/env bash
# B3: send_feedback must DRAIN feedback_pending.log on each run (re-POST queued
# notes, drop on 2xx, keep on failure) — not silently accumulate a write-only log.
# Seed 2 pending notes, run against a 200 stub, assert the queue is drained.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INST="$(cd "$HERE/.." && pwd)"
SBX="$(mktemp -d /tmp/sbx_b3.XXXXXX)"
NAME="test_e5_b3_drain"
PORT=18096

cleanup() { [ -n "${STUB_PID:-}" ] && kill "$STUB_PID" 2>/dev/null; rm -rf "$SBX"; }
trap cleanup EXIT
fail() { echo "[FAIL] $NAME: $1"; [ -n "${OUT:-}" ] && echo "$OUT" | sed 's/^/    /'; exit 1; }

# 200 stub (endpoint live)
python3 "$HERE/_stub_http.py" "$PORT" 200 >"$SBX/stub.out" 2>&1 &
STUB_PID=$!
for i in $(seq 1 20); do grep -q STUB_READY "$SBX/stub.out" 2>/dev/null && break; sleep 0.2; done

CFG="$SBX/cfg.yaml"
sed -e 's#^server_base:.*#server_base:    "http://127.0.0.1:'"$PORT"'"#' \
    -e "s#\${HOME}#$SBX#g" "$INST/installer_config.yaml" > "$CFG"

INSTALL_ROOT="$SBX/.botzy-tokenizer"
PENDING="$INSTALL_ROOT/feedback_pending.log"
mkdir -p "$INSTALL_ROOT"
# pre-seed two queued notes (as send_feedback would have, JSON bodies)
printf '%s\n' '{"note":"queued one","client_ver":"0.3.1","os":"linux","ts":"t1"}' >  "$PENDING"
printf '%s\n' '{"note":"queued two","client_ver":"0.3.1","os":"linux","ts":"t2"}' >> "$PENDING"

OUT="$(HOME="$SBX" BOTZY_CONFIG="$CFG" bash "$INST/send_feedback.sh" "brand new note" 2>&1)"; RC=$?
[ "$RC" -eq 0 ]                              || fail "exit $RC != 0"
echo "$OUT" | grep -qi "replayed 2"          || fail "did not report replaying 2 queued notes"
echo "$OUT" | grep -qi "note received"       || fail "new note not sent"
# queue fully drained on 2xx -> the pending file is removed (or empty)
if [ -f "$PENDING" ]; then
  [ ! -s "$PENDING" ]                        || fail "pending log NOT drained: $(cat "$PENDING")"
fi

echo "[PASS] $NAME (2 queued notes drained on 200; new note sent)"
exit 0
