#!/usr/bin/env bash
# Feedback 404 -> queue: point feedback_path at a local stub that returns 404,
# assert send_feedback exits 0 and the note lands in feedback_pending.log.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INST="$(cd "$HERE/.." && pwd)"
SBX="$(mktemp -d /tmp/sbx_fb404.XXXXXX)"
NAME="test_feedback_404_queues"
PORT=18099

cleanup() { [ -n "${STUB_PID:-}" ] && kill "$STUB_PID" 2>/dev/null; rm -rf "$SBX"; }
trap cleanup EXIT

# start a 404 stub
python3 "$HERE/_stub_http.py" "$PORT" 404 >"$SBX/stub.out" 2>&1 &
STUB_PID=$!
for i in $(seq 1 20); do grep -q "STUB_READY" "$SBX/stub.out" 2>/dev/null && break; sleep 0.2; done

# config: feedback at the 404 stub; HOME redirected to sandbox
CFG="$SBX/cfg.yaml"
sed -e 's#^server_base:.*#server_base:    "http://127.0.0.1:'"$PORT"'"#' \
    -e "s#\${HOME}#$SBX#g" "$INST/installer_config.yaml" > "$CFG"
mkdir -p "$SBX/.botzy-tokenizer"

OUT="$(HOME="$SBX" BOTZY_CONFIG="$CFG" bash "$INST/send_feedback.sh" "test note from CI" 2>&1)"; RC=$?
PENDING="$SBX/.botzy-tokenizer/feedback_pending.log"

fail() { echo "[FAIL] $NAME: $1"; echo "$OUT" | sed 's/^/    /'; exit 1; }
[ "$RC" -eq 0 ]                              || fail "exit $RC != 0"
echo "$OUT" | grep -qi "not live yet"        || fail "missing 404 message"
[ -f "$PENDING" ]                            || fail "feedback_pending.log not created"
grep -q "test note from CI" "$PENDING"       || fail "note not queued in pending log"

echo "[PASS] $NAME (404 -> queued, exit 0)"
exit 0
