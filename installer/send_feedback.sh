#!/usr/bin/env bash
# Botzy Tokenizer — feedback channel. One string arg = your note.
#   bash send_feedback.sh "your note here"
# Token-counts-only channel: the note is the only freeform field sent. No user
# paths, env, or registry_id beyond what the server already knows. If the endpoint
# isn't live yet (404) the note is queued locally; B3: every run DRAINS that queue
# first (re-POSTs each pending note, drops it on 2xx, keeps it on failure), so the
# "sent on a future run" promise is real, not a write-only log.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${BOTZY_CONFIG:-$SCRIPT_DIR/installer_config.yaml}"

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

NOTE="${1:-}"
[ -n "$NOTE" ]            || { say "usage: bash send_feedback.sh \"<note>\""; exit 2; }
[ "${#NOTE}" -le 4000 ]  || { say "✗ note too long (${#NOTE} chars, max 4000)."; exit 2; }

SERVER_BASE="$(cfg server_base)"
FEEDBACK_PATH="$(cfg feedback_path)"
CREDS_PATH="$(cfg creds_path)"
INSTALL_ROOT="$(dirname "$CREDS_PATH")"
FEEDBACK_URL="${SERVER_BASE}${FEEDBACK_PATH}"
PENDING_LOG="$INSTALL_ROOT/feedback_pending.log"
HAVE_JQ=0; command -v jq >/dev/null && HAVE_JQ=1

# os + client_ver (no paths/secrets)
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
grep -qiE "microsoft|wsl" /proc/version 2>/dev/null && OS="wsl"
CLIENT_VER="$(grep -E '"version"' "$REPO_ROOT/widget/manifest.json" 2>/dev/null | head -1 \
             | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
[ -n "$CLIENT_VER" ] || CLIENT_VER="unknown"
UTC_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# optional bearer token (server may accept with or without)
AUTH=()
if [ -f "$CREDS_PATH" ]; then
  if [ "$HAVE_JQ" = 1 ]; then TOK="$(jq -r '.install_token // empty' "$CREDS_PATH")"
  else TOK="$(python3 -c 'import json;print(json.load(open("'"$CREDS_PATH"'")).get("install_token",""))' 2>/dev/null || echo '')"; fi
  [ -n "$TOK" ] && AUTH=(-H "Authorization: Bearer ${TOK}")
fi

# build body via python (safe JSON escaping of the note)
BODY="$(NOTE="$NOTE" CLIENT_VER="$CLIENT_VER" OS="$OS" UTC_TS="$UTC_TS" python3 -c '
import json,os
print(json.dumps({"note":os.environ["NOTE"],"client_ver":os.environ["CLIENT_VER"],
                  "os":os.environ["OS"],"ts":os.environ["UTC_TS"]}))')"

queue() {
  mkdir -p "$INSTALL_ROOT"
  printf '%s\n' "$BODY" >> "$PENDING_LOG"
  say "  note queued locally at $PENDING_LOG"
}

# B3: replay any queued notes BEFORE sending the new one. POST each pending line;
# drop it on 2xx, keep it on any failure. Atomically rewrite the queue with only
# the still-unsent lines (never lose a note, never claim a phantom send).
drain_pending() {
  [ -f "$PENDING_LOG" ] || return 0
  local keep code sent=0 kept=0
  keep="$(mktemp)"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    code="$(curl -sS --max-time 15 -X POST "${AUTH[@]}" \
              -H "Content-Type: application/json" -d "$line" \
              -o /dev/null -w '%{http_code}' "$FEEDBACK_URL" || echo "000")"
    case "$code" in
      200|202) sent=$((sent+1)) ;;
      *)       printf '%s\n' "$line" >> "$keep"; kept=$((kept+1)) ;;
    esac
  done < "$PENDING_LOG"
  if [ "$kept" -gt 0 ]; then mv "$keep" "$PENDING_LOG"; else rm -f "$keep" "$PENDING_LOG"; fi
  if [ "$sent" -gt 0 ]; then
    say "  replayed $sent queued note(s)$([ "$kept" -gt 0 ] && printf '; %s still pending' "$kept")"
  fi
}

drain_pending     # B3: flush the backlog first (honest "sent on a future run")

TMP_RESP="$(mktemp)"
HTTP="$(curl -sS --max-time 15 -X POST "${AUTH[@]}" \
          -H "Content-Type: application/json" -d "$BODY" \
          -o "$TMP_RESP" -w '%{http_code}' "$FEEDBACK_URL" || echo "000")"
case "$HTTP" in
  200|202)
    ACK=""
    if [ "$HAVE_JQ" = 1 ]; then ACK="$(jq -r '.ack_id // .id // empty' "$TMP_RESP" 2>/dev/null || true)"; fi
    say "thanks, note received.${ACK:+ ack: $ACK}" ;;
  404)
    say "feedback endpoint not live yet (404)."; queue
    say "it will be re-sent automatically next time you run send_feedback (the queue is drained on each run)." ;;
  429)
    say "rate limited (429) — try again later."; queue ;;
  000)
    say "could not reach $FEEDBACK_URL (network/timeout)."; queue ;;
  *)
    say "feedback POST returned HTTP $HTTP."; queue ;;
esac
rm -f "$TMP_RESP"
exit 0
