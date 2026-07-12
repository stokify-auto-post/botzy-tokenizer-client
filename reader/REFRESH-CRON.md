# Cache Refresher Cron

The `refresh_state.sh` script writes a daily state snapshot to `reader/out/<date>.json` via `jsonl_reader.py --date <today> --write`. This cache is consumed by botzy_coder/signal_line.py and the statusline widget.

## Setup

Add this line to your user crontab:

```
*/5 * * * * /opt/tokenizer-client/reader/refresh_state.sh >/dev/null 2>&1
```

This runs the refresher every 5 minutes. On the distributable client, the local bridge already computes state via browser-widget polls, so the cron is mainly for server or headless installs where no widget is active.

## Notes

- Script is fail-silent; cron mail is suppressed.
- Runs in UTC (uses `date -u`).
- Logs are not written; errors are swallowed.
