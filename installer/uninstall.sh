#!/usr/bin/env bash
# Botzy Tokenizer — uninstaller (Linux / Mac / WSL2).
# Stops + removes the user-level service, wipes server-side data, removes local
# files. Backups (.bak_*) are preserved (moved aside, path printed). Idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${BOTZY_CONFIG:-$SCRIPT_DIR/installer_config.yaml}"
TS="$(date +%s)"

say() { printf '%s\n' "$*"; }
cfg() {
  local key="$1" line val
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*:" "$CONFIG_FILE" | head -1 || true)"
  [ -n "$line" ] || { printf '✗ config key %s not found\n' "$key" >&2; exit 1; }
  val="${line#*:}"
  val="$(printf '%s' "$val" | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//; s/^"//; s/"$//')"
  val="${val//\$\{HOME\}/$HOME}"
  printf '%s' "$val"
}

SERVER_BASE="$(cfg server_base)"
WIPE_PATH="$(cfg wipe_path)"
CREDS_PATH="$(cfg creds_path)"
INSTALL_ROOT="$(dirname "$CREDS_PATH")"
WIPE_URL="${SERVER_BASE}${WIPE_PATH}"
HAVE_JQ=0; command -v jq >/dev/null && HAVE_JQ=1

say "Botzy Tokenizer uninstaller"
say "  install root: $INSTALL_ROOT"

# -------------------------------------------------- 1. stop + remove service
OS="linux"; case "$(uname -s)" in Darwin) OS="mac" ;; esac
case "$OS" in
  linux|mac)
    UNIT="$HOME/.config/systemd/user/botzy-tokenizer-reader.service"
    if [ "$OS" = "mac" ]; then UNIT="$HOME/Library/LaunchAgents/co.botzify.tokenizer.reader.plist"; fi
    if [ -f "$UNIT" ]; then
      cp -a "$UNIT" "${UNIT}.bak_${TS}" && say "  ✓ backup: ${UNIT}.bak_${TS}"
      if [ "$OS" = "mac" ]; then
        launchctl bootout "gui/$(id -u)" "$UNIT" 2>/dev/null || true
      else
        if command -v systemctl >/dev/null; then
          systemctl --user disable --now botzy-tokenizer-reader.service 2>/dev/null || true
          rm -f "$UNIT"; systemctl --user daemon-reload 2>/dev/null || true
        fi
      fi
      rm -f "$UNIT"
      say "  ✓ service removed"
    else
      say "  (no service file — already removed)"
    fi ;;
esac

# kill a no-service launched reader, if any
if [ -f "$INSTALL_ROOT/reader.pid" ]; then
  kill "$(cat "$INSTALL_ROOT/reader.pid")" 2>/dev/null || true
  say "  ✓ stopped reader pid $(cat "$INSTALL_ROOT/reader.pid")"
fi

# -------------------------------------------------- 2. server-side wipe
if [ -f "$CREDS_PATH" ]; then
  if [ "$HAVE_JQ" = 1 ]; then
    REG_ID="$(jq -r '.registry_id // empty' "$CREDS_PATH")"
    TOKEN="$(jq -r '.install_token // empty' "$CREDS_PATH")"
  else
    REG_ID="$(python3 -c 'import json;print(json.load(open("'"$CREDS_PATH"'")).get("registry_id",""))' 2>/dev/null || echo '')"
    TOKEN="$(python3 -c 'import json;print(json.load(open("'"$CREDS_PATH"'")).get("install_token",""))' 2>/dev/null || echo '')"
  fi
  HTTP="$(curl -sS --max-time 15 -X POST \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"registry_id\":\"${REG_ID}\"}" \
            -o /dev/null -w '%{http_code}' "$WIPE_URL" || echo "000")"
  case "$HTTP" in
    200) say "  ✓ server-side data wiped (200)" ;;
    401) say "  ✓ server-side data already gone (401)" ;;
    *)   say "  ! wipe returned HTTP $HTTP — continuing local cleanup; re-run later if needed." ;;
  esac
else
  say "  (no creds.json — nothing to wipe server-side)"
fi

# -------------------------------------------------- 3. local cleanup (keep .bak_*)
if [ -d "$INSTALL_ROOT" ]; then
  BACKUPS_DIR="${INSTALL_ROOT}-backups"
  shopt -s nullglob dotglob
  baks=("$INSTALL_ROOT"/*.bak_* "$INSTALL_ROOT"/**/*.bak_*)
  shopt -u nullglob dotglob
  if [ "${#baks[@]}" -gt 0 ]; then
    mkdir -p "$BACKUPS_DIR"
    for b in "${baks[@]}"; do [ -e "$b" ] && mv "$b" "$BACKUPS_DIR/" 2>/dev/null || true; done
    say "  ✓ backups preserved at: $BACKUPS_DIR"
  fi
  rm -rf "$INSTALL_ROOT"
  say "  ✓ removed $INSTALL_ROOT"
else
  say "  (install root already gone)"
fi

say ""
say "Uninstalled. Widget removal: chrome://extensions → remove \"Botzy Tokenizer\"."
[ -d "${INSTALL_ROOT}-backups" ] && say "Backups kept at: ${INSTALL_ROOT}-backups"
exit 0
