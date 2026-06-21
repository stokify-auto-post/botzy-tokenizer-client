#!/usr/bin/env bash
# Botzy Tokenizer — installer (Linux / Mac / WSL2).
# User-level only. No sudo. Backup before every change. Idempotent re-run safe.
#
# Env flags (for tests / advanced use):
#   BOTZY_DRYRUN=1      pre-flight + plan only; touches no disk, no network; exit 0
#   BOTZY_NO_SERVICE=1  skip auto-start service registration (reader still launched)
#   BOTZY_NO_BROWSER=1  skip the chrome://extensions open + clipboard step
set -euo pipefail

# ---------------------------------------------------------------- locate self
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${BOTZY_CONFIG:-$SCRIPT_DIR/installer_config.yaml}"
TS="$(date +%s)"
N=9                                   # total steps (for "STEP n/N" lines)
CREATED_CREDS=""                      # set to creds path once WE create it this run

DRYRUN="${BOTZY_DRYRUN:-0}"
NO_SERVICE="${BOTZY_NO_SERVICE:-0}"
NO_BROWSER="${BOTZY_NO_BROWSER:-0}"

# ----------------------------------------------------------------- utilities
say()  { printf '%s\n' "$*"; }
step() { printf '\nSTEP %s/%s: %s\n' "$1" "$N" "$2"; }
die()  { printf '\n✗ %s\n' "$*" >&2; exit "${2:-1}"; }

# read a flat key from installer_config.yaml; strips trailing #comment + quotes;
# expands ${HOME}. No external YAML parser needed (R13 single source of truth).
cfg() {
  local key="$1" line val
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*:" "$CONFIG_FILE" | head -1 || true)"
  [ -n "$line" ] || die "config key '$key' not found in $CONFIG_FILE"
  val="${line#*:}"
  val="$(printf '%s' "$val" | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//; s/^"//; s/"$//')"
  val="${val//\$\{HOME\}/$HOME}"
  printf '%s' "$val"
}

# backup a path (file or dir) to <path>.bak_<ts> if it exists; print proof line.
backup_if_exists() {
  local p="$1"
  if [ -e "$p" ]; then
    if [ "$DRYRUN" = "1" ]; then say "  (dryrun) would back up: $p -> ${p}.bak_${TS}"; return 0; fi
    cp -a "$p" "${p}.bak_${TS}"
    say "  ✓ backup: ${p}.bak_${TS}"
  fi
}

# ERR trap: name the failing step, remove ONLY creds we created this run.
on_err() {
  local code=$?
  printf '\n✗ setup failed (exit %s) at: %s\n' "$code" "${CURRENT_STEP:-<unknown>}" >&2
  if [ -n "$CREATED_CREDS" ] && [ -f "$CREATED_CREDS" ]; then
    rm -f "$CREATED_CREDS"
    printf '  rolled back: removed creds.json created this run (%s)\n' "$CREATED_CREDS" >&2
  fi
  exit "$code"
}
trap on_err ERR
CURRENT_STEP=""

# ============================================================ load config (R13)
SERVER_BASE="$(cfg server_base)"
ENROLL_PATH="$(cfg enroll_path)"
BRIDGE_PORT="$(cfg bridge_port)"
LOG_DIR="$(cfg reader_log_dir)"
CREDS_PATH="$(cfg creds_path)"
INSTALL_ROOT="$(dirname "$CREDS_PATH")"
ENROLL_URL="${SERVER_BASE}${ENROLL_PATH}"
CLIENT_VER="$(grep -E '"version"' "$REPO_ROOT/widget/manifest.json" | head -1 \
             | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
[ -n "$CLIENT_VER" ] || CLIENT_VER="unknown"

say "Botzy Tokenizer installer  (client_ver=$CLIENT_VER, port=$BRIDGE_PORT)"
[ "$DRYRUN" = "1" ] && say ">>> DRYRUN: no disk or network changes will be made."

# ===================================================== STEP 1 — pre-flight
CURRENT_STEP="pre-flight"; step 1 "pre-flight checks"
[ "${EUID:-$(id -u)}" -ne 0 ] || die "user-level install only — do NOT run as root/sudo."

# OS detect: linux | mac | wsl2  (refuse wsl1)
OS=""
case "$(uname -s)" in
  Darwin) OS="mac" ;;
  Linux)
    if grep -qiE "microsoft|wsl" /proc/version 2>/dev/null; then
      if grep -qiE "wsl2|microsoft-standard-wsl2" /proc/version 2>/dev/null \
         || uname -r | grep -qi "WSL2"; then OS="wsl2"
      else die "WSL1 not supported; please upgrade to WSL2 — wsl --set-version Ubuntu 2"; fi
    else OS="linux"; fi ;;
  *) die "unsupported OS: $(uname -s)" ;;
esac
say "  os: $OS"

# bash 4+
[ "${BASH_VERSINFO:-0}" -ge 4 ] || die "bash 4+ required (have ${BASH_VERSION:-?})."
# required tools
command -v curl >/dev/null    || die "curl is required."
command -v python3 >/dev/null || die "python3 is required."
PYV="$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')"
python3 -c 'import sys;sys.exit(0 if sys.version_info[:2]>=(3,9) else 1)' \
  || die "python3 >= 3.9 required (have $PYV)."
HAVE_JQ=0; command -v jq >/dev/null && HAVE_JQ=1
# E1/E4 (soft): the opt-in daily usage UPLOAD (Fernet) needs `cryptography`, and
# config + URL resolution needs `PyYAML`. Non-fatal — the bridge + basic monitoring
# work without them — but we now actively try to provide them (best-effort pip),
# so the upload/delivery layer isn't silently disabled on a clean machine.
UPLOAD_DEPS_OK=1
python3 -c 'import yaml, cryptography' 2>/dev/null || UPLOAD_DEPS_OK=0
if [ "$UPLOAD_DEPS_OK" = 0 ] && [ "$DRYRUN" != "1" ]; then
  say "  installing upload deps (cryptography, PyYAML) — best effort, user-level…"
  python3 -m pip install --user --quiet cryptography pyyaml >/dev/null 2>&1 || true
  python3 -c 'import yaml, cryptography' 2>/dev/null && UPLOAD_DEPS_OK=1
fi
if [ "$UPLOAD_DEPS_OK" = 1 ]; then
  say "  deps: cryptography ✓  PyYAML ✓  (daily upload enabled)"
else
  say "  note: 'cryptography'/'PyYAML' missing and auto-install failed — daily usage"
  say "        upload/delivery stays OFF until: pip install --user cryptography pyyaml."
  say "        Bridge + widget + live monitoring are unaffected."
fi
say "  tools: curl ✓  python3 ✓ ($PYV)  jq $([ $HAVE_JQ = 1 ] && echo ✓ || echo '— (python fallback)')"

# ===================================================== STEP 2 — idempotency
CURRENT_STEP="idempotency"; step 2 "idempotency guard"
if [ -f "$CREDS_PATH" ]; then
  say "  already installed (creds.json present at $CREDS_PATH)."
  say "  to reinstall: run uninstall.sh first. Nothing changed."
  exit 0
fi
say "  no prior install detected — proceeding."

# ===================================================== STEP 3 — install dirs
CURRENT_STEP="install-dirs"; step 3 "create install dirs (0700)"
if [ "$DRYRUN" = "1" ]; then
  say "  (dryrun) would create: $INSTALL_ROOT , $LOG_DIR (mode 0700)"
else
  mkdir -p "$LOG_DIR"
  chmod 700 "$INSTALL_ROOT" "$LOG_DIR"
  say "  ✓ $INSTALL_ROOT (0700)"
fi

# ===================================================== STEP 4 — copy payload
CURRENT_STEP="copy-payload"; step 4 "copy reader/ + widget/ into install root"
READER_DST="$INSTALL_ROOT/reader"; WIDGET_DST="$INSTALL_ROOT/widget"
if [ "$DRYRUN" = "1" ]; then
  say "  (dryrun) would copy $REPO_ROOT/reader -> $READER_DST"
  say "  (dryrun) would copy $REPO_ROOT/widget -> $WIDGET_DST"
else
  backup_if_exists "$READER_DST"; backup_if_exists "$WIDGET_DST"
  rm -rf "$READER_DST" "$WIDGET_DST"
  cp -a "$REPO_ROOT/reader" "$READER_DST"
  cp -a "$REPO_ROOT/widget" "$WIDGET_DST"
  # E1: the reader's daily-upload loop reads installer_config.yaml at runtime
  # (R13 — usage URL + paths live there, never hardcoded). Copy it next to reader/
  # so the installed reader (arbitrary cwd) can find it. Single source of truth.
  cp "$CONFIG_FILE" "$INSTALL_ROOT/installer_config.yaml"
  say "  ✓ reader -> $READER_DST"
  say "  ✓ widget -> $WIDGET_DST"
  say "  ✓ installer_config.yaml -> $INSTALL_ROOT/installer_config.yaml"
fi
WIDGET_PATH="$WIDGET_DST"

# ===================================================== STEP 5 — self-enroll
CURRENT_STEP="self-enroll"; step 5 "self-enroll with the server"
if [ "$DRYRUN" = "1" ]; then
  say "  (dryrun) would POST $ENROLL_URL  body={\"client_ver\":\"$CLIENT_VER\",\"invite_code\":null}"
else
  TMP_RESP="$(mktemp)"
  HTTP="$(curl -sS --max-time 15 -X POST \
            -H "Content-Type: application/json" \
            -d "{\"client_ver\":\"$CLIENT_VER\",\"invite_code\":null}" \
            -o "$TMP_RESP" -w '%{http_code}' "$ENROLL_URL" || echo "000")"
  case "$HTTP" in
    201)
      # validate JSON + has registry_id, then persist as creds.json (0600)
      if [ "$HAVE_JQ" = 1 ]; then
        jq -e '.registry_id' "$TMP_RESP" >/dev/null \
          || { cp "$TMP_RESP" "$LOG_DIR/enroll_err.log"; rm -f "$TMP_RESP"; die "enroll 201 but no registry_id; see $LOG_DIR/enroll_err.log"; }
      else
        python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if d.get("registry_id") else 1)' "$TMP_RESP" \
          || { cp "$TMP_RESP" "$LOG_DIR/enroll_err.log"; rm -f "$TMP_RESP"; die "enroll 201 but no registry_id; see $LOG_DIR/enroll_err.log"; }
      fi
      umask 077
      cp "$TMP_RESP" "$CREDS_PATH"; chmod 600 "$CREDS_PATH"
      CREATED_CREDS="$CREDS_PATH"
      rm -f "$TMP_RESP"
      say "  ✓ enrolled (201) — creds.json written 0600"
      ;;
    429) rm -f "$TMP_RESP"; die "rate limit (429) — try again later." ;;
    503) rm -f "$TMP_RESP"; die "self-enroll disabled server-side (503) — contact ops." ;;
    000) rm -f "$TMP_RESP"; die "could not reach $ENROLL_URL (network/timeout)." ;;
    *)   cp "$TMP_RESP" "$LOG_DIR/enroll_err.log"; rm -f "$TMP_RESP"
         die "enroll failed (HTTP $HTTP) — full response at $LOG_DIR/enroll_err.log" ;;
  esac
fi

# read back registry_id for the end banner
REG_ID="unknown"
if [ -f "$CREDS_PATH" ]; then
  if [ "$HAVE_JQ" = 1 ]; then REG_ID="$(jq -r '.registry_id // "unknown"' "$CREDS_PATH")"
  else REG_ID="$(python3 -c 'import json;print(json.load(open("'"$CREDS_PATH"'")).get("registry_id","unknown"))' 2>/dev/null || echo unknown)"; fi
fi
REG_SHORT="${REG_ID:0:8}…"

# ===================================================== STEP 6 — auto-start
CURRENT_STEP="auto-start"; step 6 "register auto-start service (user-level, no sudo)"
READER_EXEC="$READER_DST/local_bridge.py"
if [ "$NO_SERVICE" = "1" ]; then
  say "  BOTZY_NO_SERVICE=1 — skipping service registration."
  if [ "$DRYRUN" != "1" ]; then
    # still launch the reader so the smoke test (/health) can pass
    nohup python3 "$READER_EXEC" >"$LOG_DIR/reader.out" 2>&1 &
    echo $! > "$INSTALL_ROOT/reader.pid"
    say "  reader launched (pid $(cat "$INSTALL_ROOT/reader.pid")), no service."
  fi
elif [ "$DRYRUN" = "1" ]; then
  say "  (dryrun) would register $OS auto-start for: python3 $READER_EXEC"
else
  case "$OS" in
    linux|wsl2)
      UNIT_DIR="$HOME/.config/systemd/user"
      UNIT="$UNIT_DIR/botzy-tokenizer-reader.service"
      mkdir -p "$UNIT_DIR"
      backup_if_exists "$UNIT"
      cat > "$UNIT" <<UNIT_EOF
[Unit]
Description=Botzy Tokenizer local reader (127.0.0.1 bridge)
After=default.target

[Service]
Type=simple
ExecStart=/usr/bin/env python3 %h/.botzy-tokenizer/reader/local_bridge.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT_EOF
      say "  ✓ unit: $UNIT"
      if command -v systemctl >/dev/null; then
        systemctl --user daemon-reload
        systemctl --user enable --now botzy-tokenizer-reader.service
        say "  ✓ enabled + started (systemctl --user)"
      else
        say "  ! systemctl --user unavailable; start manually: python3 $READER_EXEC"
      fi
      if [ "$OS" = "wsl2" ]; then
        say "  WSL2: to keep the reader alive across 'wsl --shutdown', run once:"
        say "        loginctl enable-linger $USER"
      fi
      ;;
    mac)
      LA_DIR="$HOME/Library/LaunchAgents"
      PLIST="$LA_DIR/co.botzify.tokenizer.reader.plist"
      mkdir -p "$LA_DIR"
      backup_if_exists "$PLIST"
      cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>co.botzify.tokenizer.reader</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/env</string><string>python3</string>
    <string>$READER_EXEC</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG_DIR/reader.out</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/reader.err</string>
</dict></plist>
PLIST_EOF
      say "  ✓ plist: $PLIST"
      launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$PLIST"
      say "  ✓ bootstrapped (launchctl)"
      ;;
  esac
fi

# ===================================================== STEP 7 — smoke /health
CURRENT_STEP="smoke"; step 7 "smoke test: reader /health"
if [ "$DRYRUN" = "1" ]; then
  say "  (dryrun) would GET http://127.0.0.1:$BRIDGE_PORT/health (expect {\"ok\":true})"
else
  OK=0
  for i in $(seq 1 10); do
    BODY="$(curl -sS --max-time 3 "http://127.0.0.1:$BRIDGE_PORT/health" 2>/dev/null || true)"
    if printf '%s' "$BODY" | grep -q '"ok"[[:space:]]*:[[:space:]]*true'; then OK=1; break; fi
    sleep 1
  done
  [ "$OK" = 1 ] || die "reader did not answer /health on 127.0.0.1:$BRIDGE_PORT — see $LOG_DIR/reader.out"
  say "  ✓ reader healthy on 127.0.0.1:$BRIDGE_PORT"
fi

# ===================================================== STEP 8 — browser nudge
CURRENT_STEP="browser"; step 8 "open chrome://extensions + copy widget path"
if [ "$NO_BROWSER" = "1" ]; then
  say "  BOTZY_NO_BROWSER=1 — skipping browser open + clipboard."
elif [ "$DRYRUN" = "1" ]; then
  say "  (dryrun) would open chrome://extensions and copy: $WIDGET_PATH"
else
  CLIP_PATH="$WIDGET_PATH"
  case "$OS" in
    linux)
      command -v xdg-open >/dev/null && xdg-open "chrome://extensions" >/dev/null 2>&1 || say "  (open chrome://extensions manually)"
      if command -v xclip >/dev/null; then printf '%s' "$CLIP_PATH" | xclip -selection clipboard && say "  ✓ widget path copied to clipboard"
      else say "  (xclip not found — copy this path manually: $CLIP_PATH)"; fi ;;
    mac)
      open "chrome://extensions" >/dev/null 2>&1 || say "  (open chrome://extensions manually)"
      printf '%s' "$CLIP_PATH" | pbcopy && say "  ✓ widget path copied to clipboard" ;;
    wsl2)
      # convert to a Windows path so it pastes in Windows-side Chrome/Edge
      command -v wslpath >/dev/null && CLIP_PATH="$(wslpath -w "$WIDGET_PATH" 2>/dev/null || echo "$WIDGET_PATH")"
      cmd.exe /c start chrome://extensions >/dev/null 2>&1 || say "  (open chrome://extensions in Windows Chrome/Edge)"
      printf '%s' "$CLIP_PATH" | clip.exe && say "  ✓ widget path copied to Windows clipboard" ;;
  esac
  cat <<BANNER

  ┌──────────────────────────────────────────────────────────┐
  │  WIDGET — 2 CLICKS LEFT                                   │
  │                                                          │
  │  1.  Toggle  "Developer mode"  ON  (top-right)           │
  │  2.  Click   "Load unpacked"  →  Ctrl+V  →  Enter        │
  │                                                          │
  │  (folder path is already in your clipboard)              │
  └──────────────────────────────────────────────────────────┘
   path: $CLIP_PATH
BANNER
fi

# ===================================================== STEP 9 — done
CURRENT_STEP="done"; step 9 "done"
if [ "$DRYRUN" = "1" ]; then
  say "  ✓ DRYRUN complete — no changes made. exit 0."
  exit 0
fi
# print bridge token (optional reader pairing) if minted
BRIDGE_TOKEN_FILE="$READER_DST/.bridge_token"
cat <<DONE

──────────────────────────────────────────────────────────────
 ✓ Botzy Tokenizer installed.
   registry_id : ${REG_SHORT}
   creds       : $CREDS_PATH (0600)
   reader      : $READER_EXEC
   uninstall   : bash $SCRIPT_DIR/uninstall.sh
   feedback    : bash $SCRIPT_DIR/send_feedback.sh "<note>"
DONE
if [ -f "$BRIDGE_TOKEN_FILE" ]; then
  say "   optional    : pair the reader — paste this token into the widget"
  say "                 (Settings → Bridge token):"
  say "                 $(cat "$BRIDGE_TOKEN_FILE")"
fi
say "──────────────────────────────────────────────────────────────"
exit 0
