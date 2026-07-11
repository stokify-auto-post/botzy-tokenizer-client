# statusline/botzy_signal.sh — install

A single-line, ANSI-colored fragment showing Botzy's cost signal (dot + `₹cost` +
optional top advice). Reads `reader/jsonl_reader.py`'s summary directly (no
bridge, no auth). Fail-silent: prints `⚪ botzy off` and exits 0 on any error,
missing dep, or timeout — never breaks the parent statusline.

Does **not** show session%/weekly% context-meter numbers — those only come from
the browser widget's claude.ai page-scraping and aren't available to a local
reader call.

## Requirements

`bash`, `jq`, `python3`, `timeout` (coreutils) — all commonly present. Missing
any one of these silently degrades to `⚪ botzy off`.

## Config

Thresholds/colors/copy live in `statusline/botzy_signal_config.yaml`
(R13 — edit the yaml, not the script). Notably `reader_timeout_ms` (default
250) is the hard budget for the reader CLI call; raise it if your `reader/out/`
log volume is large enough that the live scan misses that window (you'll see
`⚪ botzy off` constantly if so — check with
`time python3 reader/jsonl_reader.py --date $(date -u +%F) >/dev/null`).

## Fresh install (no existing statusline)

1. Set `~/.claude/statusline.sh`:
   ```bash
   #!/usr/bin/env bash
   cat  # pass Claude Code's stdin JSON through untouched, or build your own line
   printf '  '
   /opt/tokenizer-client/statusline/botzy_signal.sh
   ```
2. `chmod +x ~/.claude/statusline.sh`
3. In `~/.claude/settings.json`:
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "~/.claude/statusline.sh",
       "padding": 0
     }
   }
   ```

## Existing customized statusline (e.g. the context-meter script)

Your script already does `input=$(cat)` and ends with one `printf` building the
line. Append the fragment's stdout to that same `printf`, e.g. in
`~/.claude/statusline.sh`:

```bash
# ... existing context-meter logic building $MODEL/$COL/$BAR/etc ...

BOTZY=$(/opt/tokenizer-client/statusline/botzy_signal.sh)

printf '%s  %s[%s]%s %s%2d%%%s  %s%s/%s%s%s  %s' \
  "$MODEL" "$COL" "$BAR" "$RESET" "$COL" "$PCT" "$RESET" \
  "$DIM" "$USED_H" "$TOTAL_H" "$RESET" "$NUDGE" \
  "$BOTZY"
```

`botzy_signal.sh` never reads stdin and never touches `$input`, so it's safe to
call anywhere in an existing script without interfering with its JSON parsing.
It writes nothing to stderr and always exits 0.

`settings.json` `statusLine` block shape (unchanged, just points at your script):

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 0
  }
}
```

## Manual check

```bash
./statusline/botzy_signal.sh
```
Should print inline (no trailing newline) in well under 300ms, or fall back to
`⚪ botzy off`.
