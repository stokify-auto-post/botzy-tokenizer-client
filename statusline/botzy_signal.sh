#!/usr/bin/env bash
# Botzy cost-signal fragment — meant to be APPENDED to an existing Claude Code statusline.
# Data source: reader/jsonl_reader.py build_summary() for today, called directly (no HTTP bridge).
# Fields read: signal_hint (green/yellow/red), total_cost_inr, advice[].message.
# Fail-silent: any missing dep / reader error / timeout -> neutral "⚪ botzy off", exit 0.
# Never reads stdin, never writes stderr, always exits 0 — safe to pipe/append blindly.
# Self-caches the rendered fragment (cache_ttl_s) so the expensive reader walk
# runs at most once per TTL window; every other render is an instant file read.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/botzy_signal_config.yaml"
READER="$SCRIPT_DIR/../reader/jsonl_reader.py"
CACHE="${TMPDIR:-/tmp}/botzy_signal_$(id -u).cache"

RESET=$'\033[0m'; DIM=$'\033[2m'

# cfg <key> -> flat scalar value from the yaml (quotes stripped).
cfg() {
  local line val
  line=$(grep -E "^$1:" "$CONFIG" 2>/dev/null | head -1)
  val="${line#*: }"
  val="${val%%#*}"                     # drop trailing inline comment
  val="$(printf '%s' "$val" | sed -e 's/[[:space:]]*$//')"  # trim trailing space
  val="${val%\"}"; val="${val#\"}"
  printf '%s' "$val"
}

# write_cache <fragment> -> atomic write (temp file + mv), best-effort/fail-silent.
write_cache() {
  local tmp="${CACHE}.tmp.$$"
  printf '%s' "$1" > "$tmp" 2>/dev/null || return 0
  mv -f "$tmp" "$CACHE" 2>/dev/null
}

cat_cache() {
  local content
  content=$(<"$CACHE") 2>/dev/null
  printf '%s' "$content"
}

# off: fail-silent path. Prefer a still-present stale cache over flapping to
# the neutral fragment; only compute+write 'off' when no prior cache exists.
off() {
  if [ -s "$CACHE" ]; then
    cat_cache
    exit 0
  fi
  local sym col out
  sym=$(cfg symbol_off); col=$(printf '%b' "$(cfg color_off)")
  out=$(printf '%s%s %s%s' "$col" "${sym:-⚪}" "$(cfg off_text)" "$RESET")
  printf '%s' "$out"
  write_cache "$out"
  exit 0
}

if [ ! -f "$CONFIG" ]; then
  [ -s "$CACHE" ] && { cat_cache; exit 0; }
  printf '⚪ botzy off'; exit 0
fi

# Fast path: fresh cache -> instant read, no reader call at all.
TTL=$(cfg cache_ttl_s); TTL=${TTL:-30}
if [ -s "$CACHE" ]; then
  MTIME=$(date -r "$CACHE" +%s 2>/dev/null)
  NOW=$(date +%s 2>/dev/null)
  if [ -n "$MTIME" ] && [ -n "$NOW" ] && [ $((NOW - MTIME)) -lt "$TTL" ]; then
    cat_cache
    exit 0
  fi
fi

[ -f "$READER" ] || off
command -v python3 >/dev/null 2>&1 || off
command -v jq      >/dev/null 2>&1 || off
command -v timeout >/dev/null 2>&1 || off

TIMEOUT_MS=$(cfg reader_timeout_ms); TIMEOUT_MS=${TIMEOUT_MS:-2000}
TIMEOUT_S=$(awk -v ms="$TIMEOUT_MS" 'BEGIN{printf "%.3f", ms/1000}')

RAW=$(timeout "$TIMEOUT_S" python3 "$READER" --date "$(date -u +%F)" 2>/dev/null)
[ $? -eq 0 ] && [ -n "$RAW" ] || off

IFS=$'\t' read -r SIGNAL COST MSG < <(
  printf '%s' "$RAW" | jq -r '
    [ (.signal_hint // "off"),
      ((.total_cost_inr // 0) | tostring),
      (((.advice // []) | sort_by(-(.severity // 0)) | .[0].message) // "")
    ] | @tsv' 2>/dev/null
)
[ -n "$SIGNAL" ] || off

case "$SIGNAL" in
  red)    SYM=$(cfg symbol_red);    COL=$(printf '%b' "$(cfg color_red)") ;;
  yellow) SYM=$(cfg symbol_yellow); COL=$(printf '%b' "$(cfg color_yellow)") ;;
  green)  SYM=$(cfg symbol_green);  COL=$(printf '%b' "$(cfg color_green)") ;;
  *)      off ;;
esac

PREFIX=$(cfg currency_prefix); SEP=$(cfg separator)
MAXLEN=$(cfg advice_max_len); MAXLEN=${MAXLEN:-40}
COST_H=$(awk -v c="$COST" 'BEGIN{printf "%.1f", c+0}')

if [ -n "$MSG" ] && [ "${#MSG}" -gt "$MAXLEN" ]; then
  MSG="${MSG:0:$MAXLEN}…"
fi

OUT=$(printf '%s%s %s%s%s' "$COL" "$SYM" "$PREFIX" "$COST_H" "$RESET")
[ -n "$MSG" ] && OUT="${OUT}${SEP}${DIM}${MSG}${RESET}"

write_cache "$OUT"
printf '%s' "$OUT"
exit 0
