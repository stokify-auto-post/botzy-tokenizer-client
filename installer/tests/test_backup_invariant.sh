#!/usr/bin/env bash
# Backup invariant: when setup writes over a pre-existing target, a .bak_<ts>
# sibling MUST exist. We pre-seed the reader/ install target, run setup offline
# (server unreachable -> enroll fails AFTER the STEP 4 backup), then assert the
# backup was taken. Runs fully in a sandbox HOME under /tmp.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INST="$(cd "$HERE/.." && pwd)"
SBX="$(mktemp -d /tmp/sbx_backup.XXXXXX)"
NAME="test_backup_invariant"

# offline config: point server at a refused port so enroll is a clean failure
CFG="$SBX/cfg.yaml"
sed 's#^server_base:.*#server_base:    "http://127.0.0.1:1"#' "$INST/installer_config.yaml" \
  | sed "s#\${HOME}#$SBX#g" > "$CFG"

# pre-seed an existing reader install target so STEP 4 must back it up
mkdir -p "$SBX/.botzy-tokenizer/reader"
echo "OLD-READER-MARKER" > "$SBX/.botzy-tokenizer/reader/local_bridge.py"

OUT="$(HOME="$SBX" BOTZY_CONFIG="$CFG" BOTZY_NO_SERVICE=1 BOTZY_NO_BROWSER=1 \
       bash "$INST/setup.sh" 2>&1)"; RC=$?

fail() { echo "[FAIL] $NAME: $1"; echo "$OUT" | sed 's/^/    /'; rm -rf "$SBX"; exit 1; }
# setup is EXPECTED to fail at enroll (offline) — that's fine; we test the backup.
BAK="$(find "$SBX/.botzy-tokenizer" -maxdepth 1 -name 'reader.bak_*' -type d 2>/dev/null | head -1)"
[ -n "$BAK" ]                                   || fail "no reader.bak_* created for pre-existing target"
grep -q "OLD-READER-MARKER" "$BAK/local_bridge.py" || fail "backup does not preserve original content"
echo "$OUT" | grep -q "✓ backup:"               || fail "no backup proof line printed"

echo "[PASS] $NAME (pre-existing reader backed up to $(basename "$BAK"); RC=$RC as expected offline)"
rm -rf "$SBX"; exit 0
