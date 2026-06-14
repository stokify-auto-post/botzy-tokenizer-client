#!/usr/bin/env bash
# Uninstall idempotency: running uninstall.sh twice in a clean sandbox exits 0
# both times (second run finds nothing to do and stays clean).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INST="$(cd "$HERE/.." && pwd)"
SBX="$(mktemp -d /tmp/sbx_uninst.XXXXXX)"
NAME="test_uninstall_idempotent"

# offline config (no creds -> no wipe network call at all)
CFG="$SBX/cfg.yaml"
sed "s#\${HOME}#$SBX#g" "$INST/installer_config.yaml" > "$CFG"

OUT1="$(HOME="$SBX" BOTZY_CONFIG="$CFG" bash "$INST/uninstall.sh" 2>&1)"; RC1=$?
OUT2="$(HOME="$SBX" BOTZY_CONFIG="$CFG" bash "$INST/uninstall.sh" 2>&1)"; RC2=$?

fail() { echo "[FAIL] $NAME: $1"; echo "--run1--"; echo "$OUT1" | sed 's/^/    /'; echo "--run2--"; echo "$OUT2" | sed 's/^/    /'; rm -rf "$SBX"; exit 1; }
[ "$RC1" -eq 0 ] || fail "first run exit $RC1 != 0"
[ "$RC2" -eq 0 ] || fail "second run exit $RC2 != 0"
echo "$OUT2" | grep -q "Uninstalled" || fail "second run missing 'Uninstalled'"

echo "[PASS] $NAME (both runs exit 0)"
rm -rf "$SBX"; exit 0
