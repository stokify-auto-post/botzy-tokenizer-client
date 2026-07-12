#!/bin/bash
# refresh_state.sh: background refresher for cost-state cache (daily snapshot).
# writes reader/out/<date>.json via jsonl_reader.py. Runs from cron every 5min,
# fails silent (always exit 0). Consumed by botzy_coder/signal_line.py + statusline.

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# fail-silent guards
if ! command -v python3 &>/dev/null; then
  exit 0
fi

cd "$SCRIPT_DIR" || exit 0

python3 jsonl_reader.py --date "$(date -u +%F)" --write 2>/dev/null

exit 0
