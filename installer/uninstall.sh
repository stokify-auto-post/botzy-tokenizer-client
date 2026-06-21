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

# B1: also stop ANY reader bound to this install that the pid-file doesn't know
# about — after a reboot the live reader was relaunched (systemd/.vbs) under a NEW
# pid, so the recorded pid is stale. Match it by its script path and WAIT for it to
# exit (release the port + any open log handle) BEFORE we delete the dir, so we
# never orphan a port-bound reader or abort the delete on a held file.
READER_SCRIPT="$INSTALL_ROOT/reader/local_bridge.py"
if command -v pkill >/dev/null 2>&1; then
  pkill -f "$READER_SCRIPT" 2>/dev/null || true
fi
for _i in 1 2 3 4 5 6 7 8 9 10; do
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -f "$READER_SCRIPT" >/dev/null 2>&1 || break
  else
    break
  fi
  sleep 0.5
done
if command -v pgrep >/dev/null 2>&1 && pgrep -f "$READER_SCRIPT" >/dev/null 2>&1; then
  say "  ! a reader process is still running ($READER_SCRIPT) — continuing; close it if cleanup is incomplete."
else
  say "  ✓ no reader process bound to this install"
fi

# -------------------------------------------------- 2. server-side wipe
# WIPE_OK gates whether it is SAFE to delete creds.json: only a confirmed 200/401
# (data gone) clears it. No creds at all => nothing to wipe => safe to remove.
WIPE_OK=1
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
    *)   # B2: the wipe did NOT confirm (network down / 5xx / timeout). Do NOT delete
         # creds.json — it holds the ONLY token that can authorise the wipe. Keeping
         # it (below) makes "re-run later" actually possible.
         WIPE_OK=0
         say "  ! wipe NOT confirmed (HTTP $HTTP) — your server-side data still exists." ;;
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
  if [ -f "$CREDS_PATH" ] && [ "$WIPE_OK" != 1 ]; then
    # B2: KEEP creds.json + a wipe_pending marker so a later online re-run can still
    # wipe the server-side row (the wipe needs that token). Remove everything else.
    CREDS_BASE="$(basename "$CREDS_PATH")"
    date -u +"wipe_pending %Y-%m-%dT%H:%M:%SZ — server-side data NOT wiped; re-run 'bash uninstall.sh' when back online to remove it." \
      > "$INSTALL_ROOT/wipe_pending" 2>/dev/null || true
    for entry in "$INSTALL_ROOT"/* "$INSTALL_ROOT"/.[!.]*; do
      [ -e "$entry" ] || continue
      base="$(basename "$entry")"
      case "$base" in "$CREDS_BASE"|wipe_pending) continue ;; esac
      rm -rf "$entry" 2>/dev/null || say "  ! could not remove $entry (close any reader holding it, then re-run)."
    done
    say "  ! KEPT $CREDS_BASE + wipe_pending marker (server wipe unconfirmed)."
    say "    your server-side data still exists — re-run 'bash uninstall.sh' when ONLINE to wipe it."
  else
    # tolerant delete: report what couldn't be removed instead of aborting mid-delete.
    if rm -rf "$INSTALL_ROOT" 2>/dev/null && [ ! -d "$INSTALL_ROOT" ]; then
      say "  ✓ removed $INSTALL_ROOT"
    else
      say "  ! some files under $INSTALL_ROOT could not be removed (a reader handle may"
      say "    still be open). Close any running reader and re-run, or delete it manually."
    fi
  fi
else
  say "  (install root already gone)"
fi

say ""
say "Uninstalled. Widget removal: chrome://extensions → remove \"Botzy Tokenizer\"."
[ -d "${INSTALL_ROOT}-backups" ] && say "Backups kept at: ${INSTALL_ROOT}-backups"
exit 0
