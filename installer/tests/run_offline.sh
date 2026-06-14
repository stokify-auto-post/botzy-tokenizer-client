#!/usr/bin/env bash
# Runs all OFFLINE installer tests (no live server). The live smoke
# (test_live_smoke.sh) is run separately because it touches the real server.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS=(test_setup_dryrun.sh test_idempotency.sh test_backup_invariant.sh
       test_uninstall_idempotent.sh test_feedback_404_queues.sh)
pass=0; fail=0
echo "=== Botzy Tokenizer — offline installer tests ==="
for t in "${TESTS[@]}"; do
  if bash "$HERE/$t"; then pass=$((pass+1)); else fail=$((fail+1)); fi
done
echo "------------------------------------------------"
echo "offline: $pass passed, $fail failed (of ${#TESTS[@]})"
[ "$fail" -eq 0 ]
