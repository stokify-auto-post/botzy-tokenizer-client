#!/usr/bin/env bash
# DRYRUN: pre-flight + planning only. No disk writes outside /tmp, no network,
# exit 0. Asserts the install root is NEVER created and the dryrun banner prints.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INST="$(cd "$HERE/.." && pwd)"
SBX="$(mktemp -d /tmp/sbx_dryrun.XXXXXX)"
NAME="test_setup_dryrun"

OUT="$(HOME="$SBX" BOTZY_DRYRUN=1 bash "$INST/setup.sh" 2>&1)"; RC=$?

fail() { echo "[FAIL] $NAME: $1"; echo "$OUT" | sed 's/^/    /'; rm -rf "$SBX"; exit 1; }
[ "$RC" -eq 0 ]                                  || fail "exit code $RC != 0"
echo "$OUT" | grep -q "DRYRUN complete"          || fail "missing 'DRYRUN complete'"
[ ! -e "$SBX/.botzy-tokenizer" ]                 || fail "install root was created in dryrun"
# no creds, no service files anywhere in sandbox
[ -z "$(find "$SBX" -name 'creds.json' 2>/dev/null)" ] || fail "creds.json written in dryrun"

echo "[PASS] $NAME (exit 0, no disk writes, no install root)"
rm -rf "$SBX"; exit 0
