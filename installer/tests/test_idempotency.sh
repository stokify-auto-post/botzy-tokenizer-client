#!/usr/bin/env bash
# Idempotency: a pre-existing creds.json makes setup abort at STEP 2 with
# "already installed", exit 0, and NO mutation (creds content unchanged).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INST="$(cd "$HERE/.." && pwd)"
SBX="$(mktemp -d /tmp/sbx_idem.XXXXXX)"
NAME="test_idempotency"

mkdir -p "$SBX/.botzy-tokenizer"
echo '{"registry_id":"PREEXISTING-ID","install_token":"x"}' > "$SBX/.botzy-tokenizer/creds.json"
BEFORE="$(cat "$SBX/.botzy-tokenizer/creds.json")"

OUT="$(HOME="$SBX" BOTZY_NO_SERVICE=1 BOTZY_NO_BROWSER=1 bash "$INST/setup.sh" 2>&1)"; RC=$?
AFTER="$(cat "$SBX/.botzy-tokenizer/creds.json")"

fail() { echo "[FAIL] $NAME: $1"; echo "$OUT" | sed 's/^/    /'; rm -rf "$SBX"; exit 1; }
[ "$RC" -eq 0 ]                           || fail "exit code $RC != 0"
echo "$OUT" | grep -q "already installed" || fail "missing 'already installed' message"
[ "$BEFORE" = "$AFTER" ]                  || fail "creds.json was mutated"
# no reader/widget copied (aborted before STEP 4)
[ ! -e "$SBX/.botzy-tokenizer/reader" ]   || fail "reader copied despite idempotent abort"

echo "[PASS] $NAME (exit 0, no mutation, aborted at STEP 2)"
rm -rf "$SBX"; exit 0
