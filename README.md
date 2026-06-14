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

---

## Uninstall

One line, backups kept: `bash installer/uninstall.sh` (or `.\installer\uninstall.ps1` on Windows).

## Feedback

`bash installer/send_feedback.sh "your note"` — every note is read.

## License

MIT — see [`LICENSE`](LICENSE).

## Repo

https://github.com/stokify-auto-post/botzy-tokenizer-client
