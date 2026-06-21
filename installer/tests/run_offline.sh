#!/usr/bin/env bash
# Runs all OFFLINE tests (no live server). The live smoke (test_live_smoke.sh) is
# run separately because it touches the real server.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS=(test_setup_dryrun.sh test_idempotency.sh test_backup_invariant.sh
       test_uninstall_idempotent.sh test_feedback_404_queues.sh
       test_e5_b1_stopreader.sh test_e5_b2_keepcreds.sh test_e5_b3_drain.sh)
PYTESTS=(test_usage_upload.py            # E1: reader -> POST /v1/usage round-trip + gates
         test_e2_advice_in_state.py      # E2: reader LOCAL advice -> /v1/state
         test_e4_delivery.py             # E4: server-advice pull (own id, moat, graceful)
         test_e5_m10_empty_token.py)     # m10: empty .bridge_token re-mint
JSTESTS=(test_e5_m5_401.js)             # M5: 401 token_rejected != offline (widget)
pass=0; fail=0
echo "=== Botzy Tokenizer — offline tests ==="
for t in "${TESTS[@]}"; do
  if bash "$HERE/$t"; then pass=$((pass+1)); else fail=$((fail+1)); fi
done
for t in "${PYTESTS[@]}"; do
  if python3 "$HERE/$t"; then pass=$((pass+1)); else fail=$((fail+1)); fi
done
for t in "${JSTESTS[@]}"; do
  if command -v node >/dev/null 2>&1; then
    if node "$HERE/$t"; then pass=$((pass+1)); else fail=$((fail+1)); fi
  else echo "(skip $t — node not found)"; fi
done
total=$(( ${#TESTS[@]} + ${#PYTESTS[@]} + ${#JSTESTS[@]} ))
echo "------------------------------------------------"
echo "offline: $pass passed, $fail failed (of $total)"
[ "$fail" -eq 0 ]
