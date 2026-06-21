# 🪙 **Tokenizer** — cut Claude token costs up to 70%, first GO

**Research-grade AI cost-intelligence** that keeps your workflow from ever stalling.

**Built from months of ground-level research, where Claude token spend hits hardest** — catching cost leaks, model mismatches, and token spikes the day they happen.

Two tools, one install. **Tokenizer** watches your real usage and cuts your token bill. **Builder** reviews your code's design and flaws at senior-architect level. Both run on **Claude's most capable models**, built by our Research Analysts the way big-tech ships.

**Install (one line):**
`git clone https://github.com/stokify-auto-post/botzy-tokenizer-client.git && cd botzy-tokenizer-client && bash installer/setup.sh`
— then load `widget/` unpacked (2 clicks). Full guide: [`installer/INSTALL.md`](installer/INSTALL.md).

- 🔒 **No conversation content, no API key, no account** — reads only token counts, all on your machine.
- 📊 **Live usage %** — session, weekly, Sonnet & Opus limits, derived while you keep working.
- 🔔 **Spike alerts** — get pinged the moment a single message blows past your token threshold.
- 🧠 **Day-1 cost fixes a fresh Claude never gives you** — the hard-won right-usage tricks that take months to discover, applied from your very first session.
- 💸 **Local & server spend breakdown** — per-model token cost + where cost-cutting steps would have saved you money.

---

## The two tools

### 🪙 Tokenizer — cut your token costs
Tracks your real Claude usage and shows where money burns — cost leaks, selective model usage, spikes, peak-rate windows. Then it sends you sharper, personalized fixes as your usage reveals them. Built on months of ground-level research into real token-spend patterns, so you skip the slow, expensive discovery phase.

### 🏛️ Builder — your senior architect on call
A senior-architect-grade review of your code's design and flaws — the kind of audit a principal engineer would do. It catches architecture mistakes, wiring gaps, and IP-risky calls your own Claude can miss, before they cost you.

You opt in; the analysis runs server-side; you get back specific, prioritized fixes — with a backup in hand and one-command rollback. Your repo is never touched without your say.

**Free, after you connect the bridge** (no payment — through the Builder gate):
- 🎯 Where *your* spend actually leaks — per-key diagnosis, not generic tips
- 🔔 Spike & peak-window alerts — the moment a 2× burn starts, well before the wall
- 🧠 Right-usage fixes from your own logs — applied as your usage reveals them
- 💸 Per-model spend insight tuned to *your* workflow — where each model's cost is saveable for you
- 📈 Research-grade token-saver analysis + pre-built formulas that stop you before the wall, not after

*Without the bridge, the widget alone gives live usage %, a spike ping, and a rough token tally — basic monitoring. The real engine — the analysis, the formulas, the per-key cuts — unlocks the moment you connect.*

---

## How it works

Two small pieces, both on your machine:

**The widget (`widget/`)** — a browser extension for `claude.ai`. It reads the
same usage percentages the Settings → Usage panel shows (a same-origin,
read-only request that reuses *your own* login — the widget never sees or stores
your cookies), and it estimates each message's size from its on-screen length
(`tokens ≈ characters ÷ 4`, public-knowledge math). It shows live %s, a per-model
rate table, a running token tally, and a spike alert. **Conversation text is
explicitly excluded from every scan.**

**The log-reader (`reader/`)** — an optional Python script that walks
`~/.claude/projects/**/*.jsonl` **read-only** and reports your per-model token
spend for the day, plus simple, practical advice (e.g. *"these input tokens were
saveable"*). It extracts **only token counts** — model name, the four usage
counters, and a numeric web-search count. Everything else, conversation content
above all, is never read into the pipeline. A built-in guard (`--selftest`)
refuses to emit any object that looks like it carries content, keys, or IDs.

The two connect, if you want, over a **loopback-only (`127.0.0.1`) bridge** —
GET-only, token-gated, numbers/state only. Nothing leaves your machine.

## Privacy & safety

- **No conversation content** is ever read, stored, logged, or transmitted.
- **No API key, no login, no account.** The widget rides your existing browser session.
- **Read-only.** The log-reader never modifies your `.jsonl` logs.
- **Local-first.** The widget talks only to `claude.ai` (your session) and, optionally, `127.0.0.1`.
- **Minimal permissions** — storage + the two hosts above. No telemetry, no analytics, no tabs.

## Honest about the numbers

Token estimates in the widget are **length-based (chars ÷ 4) — directional, not
billing-grade.** The log-reader uses the *actual* usage counters from your logs
for its cost breakdown, priced from an **editable public rate table**
(`reader/usage_rates.yaml`) — accurate to whatever rates you keep current.

## What this repo is — and isn't

This is the **client**: the widget, the local reader, and the install scaffold —
everything that runs on **your machine**, open for you to read end to end. The
deeper cost-intelligence behind both tools lives as a service that **delivers
sharper, personalized fixes to you exactly when you need them** — when a spike
hits, when you're stuck, when a cheaper path opens up. The heavy analysis stays
server-side so your machine stays light, and **sends you sharper fixes as your
usage reveals them**; this repo ships the client itself — **no keys, no account
data**.

---

*Reading your usage costs nothing — it's the same data Settings → Usage already
shows, with no model call. This just makes it visible.*

---

## Installer (`installer/`) — shipped

A self-contained, user-level installer. **No sudo. Backup before every change.
Idempotent re-run safe.** Two paths, same scripts:

- **Path A — Claude-driven (recommended):** the user asks their Claude to read
  `installer/INSTALL.md` and run `setup.sh`. INSTALL.md opens with a verbatim
  **"Note to Claude"** trust contract (what it does / does not do /
  reversibility / server side) — the spine of the whole install.
- **Path B — manual:** `bash setup.sh` (Linux/Mac/WSL2) or `.\setup.ps1`
  (Windows native).

### Pieces

| file | role |
|------|------|
| `INSTALL.md` | Path A + Path B + the "Note to Claude" contract + 2-click widget step |
| `installer_config.yaml` | **single source of truth** (R13) — endpoints/paths/port; scripts bake in nothing |
| `setup.sh` / `setup.ps1` | 9-step install: pre-flight → idempotency → dirs → copy reader+widget → self-enroll → auto-start → `/health` smoke → browser nudge → done |
| `uninstall.sh` / `uninstall.ps1` | stop+remove service → server-side wipe (`/v1/wipe/self`) → local cleanup (**backups kept**) |
| `send_feedback.sh` / `send_feedback.ps1` | one-arg note channel; queues locally on 404 until the server endpoint is live |
| `tests/` | 5 offline tests + 1 live smoke + a 404 HTTP stub |

### Config (R13 — nothing hardcoded)

All scripts read `installer/installer_config.yaml`. **`bridge_port: 8765` is
pinned** — it must match the widget, which uses 8765 in `manifest.json`
(host_permissions), `config.js`, and `background.js`. Tests can point at a stub
config via `BOTZY_CONFIG`.

### Auto-start (user-level, no sudo)

- Linux / WSL2 → `~/.config/systemd/user/botzy-tokenizer-reader.service`
  (`systemctl --user enable --now`; WSL2 prints the `loginctl enable-linger`
  hint).
- Mac → `~/Library/LaunchAgents/co.botzify.tokenizer.reader.plist`
  (`launchctl bootstrap gui/$(id -u)`).
- Windows → Task Scheduler task `BotzyTokenizerReader` (At-LogOn, RunLevel
  Limited).

`reader/local_bridge.py` includes an unauthenticated **`/health`** liveness probe
(`{"ok":true}`) so the installer can confirm the reader started without the
bridge token.

### Tests — 6/6 pass

`bash installer/tests/run_offline.sh` runs the 5 offline tests
(dryrun · idempotency · backup-invariant · uninstall-idempotent ·
feedback-404-queues). `test_live_smoke.sh` is the **one** live test: a sandboxed
end-to-end enroll → `/health` → wipe against the enrollment server
(enroll 201, creds 0600, /health 200, wipe ok, sandbox clean).

### Changelog

- **2026-06-20 — Native-Windows auto-start, auto-pair & empty-state fixes**
  (all found via a real native-Windows reboot/reinstall test: Python 3.14, no
  WSL, no `~/.claude` logs). Each fix is widget- or installer-side, no admin:
  - **Admin-less auto-start.** `Register-ScheduledTask` needs admin on
    locked-down boxes (`0x80070005`) and hid its own failure behind a false
    `[ok]`. Replaced with a per-user **Startup-folder launcher**
    (`BotzyTokenizerReader.vbs`, `WScript.Shell.Run(cmd,0,False)` = hidden, no
    console). An earlier `HKCU\…\Run` attempt was dropped: its multi-quoted
    command line fired unreliably at logon (worked manually, not on reboot).
    Every `[ok]` is now gated on a verified result; failures print `[x]` + the
    real reason + a manual fallback.
  - **Requirements manual.** `INSTALL.md` gained a top "Requirements" section
    (Windows 10+, Python 3.9+, git, Chrome) with direct links + a self-check,
    and a sharpened "Note to Claude" (auto-start is best-effort; exact `pythonw`
    manual-launch fallback). The OS/Python/git/Chrome environment is the user's
    to provide; the installer fixes only its own setup.
  - **Token auto-pair.** The widget's `/v1/state` was 401-ing because the
    per-install bridge token never reached it (silent auto-start never shows the
    printed token). Added a loopback-only `GET /v1/pair` (custom-header gated so
    a web page can't reach it cross-origin; one-time window that closes after the
    first pair) and widget auto-fetch — **no manual paste**. Token stays unique,
    only delivery is automated; the paste box remains as a fallback.
  - **Empty-state honesty.** With the bridge healthy but no Claude Code logs yet,
    the panel showed a bare `0`/`—` that read as "broken". `/v1/state` now
    reports `logs_found`/`has_data` (a count, never content); the widget shows
    "connected · no Claude Code logs yet" and `—` + a hint instead of a scary 0.
  - **Stale-token self-recovery.** On reinstall the reader remints its token
    while the widget still holds the old one (a reload doesn't clear
    `chrome.storage`, and only the widget can — the installer can't touch the
    browser sandbox). The widget now detects a `401` while holding a token,
    clears it, re-pairs once against the restarted reader, and retries — so a
    reinstall recovers to "connected" on its own.
  - Verified on Linux (reader curl matrix + JS `node --check`) and confirmed on
    a real native-Windows reboot/reinstall run.

- **2026-06-15 — Windows installer fixes** (found via a real native-Windows
  newcomer test: clean machine, Python 3.14 + git 2.54, no WSL):
  - `setup.ps1` pre-flight Python check **rewritten PS-native** — the old inline
    `python -c "...(3,9)..."` one-liners broke the PowerShell 5.1 *parser* (the
    whole script failed to load). Now parses `python --version` in PowerShell, no
    embedded Python. Both inline-interpreter blocks removed.
  - `INSTALL.md` Path B (Windows): added the `Set-ExecutionPolicy Bypass -Scope
    Process -Force` step in the correct order (`Bypass` positional first — the
    `-Bypass` named form errors on PS 5.1), a copy-pasteable clone→`setup.ps1`
    quick-start, and a prereqs box (Python 3.9+ + git; no Node.js).
  - Verified on Linux via PowerShell structural lint (no inline interpreter
    strings, balanced `(){}`, all `try` blocks have `catch`); native-Windows
    re-test still recommended.

---

## Uninstall

One line, backups kept: `bash installer/uninstall.sh` (or `.\installer\uninstall.ps1` on Windows).

## Feedback

`bash installer/send_feedback.sh "your note"` — every note is read.

## License

MIT — see [`LICENSE`](LICENSE).

## Repo

https://github.com/stokify-auto-post/botzy-tokenizer-client
