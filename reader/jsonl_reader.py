"""
jsonl_reader.py — token-count log-reader over ~/.claude/projects/**/*.jsonl (READ-ONLY).

Usage:
    python3 jsonl_reader.py [--date YYYY-MM-DD] [--write] [--selftest]

Walks every *.jsonl under ~/.claude/projects (read-only, never modifies), and from each
line extracts ONLY:
    {ts, session_id, model, input_tokens, output_tokens, cache_read, cache_creation}
plus the numeric web_search_requests count (server_tool_use — a counter, not content).
Every other field — message content above all — is never read into the pipeline.

Output: ONE JSON object on stdout —
    schema_version, date, generated_at, scanned {jsonl_files, usage_lines, deduped, sessions},
    per_model [{model, family, calls, in_tok, out_tok, cache_r, cache_w, cost_inr}],
    total_cost_inr, saved {inr, pct}, missed_by_model [...], advice [...]

advice[] is an OPEN schema ({kind, message, model?, inr?}) — cache, model-misuse,
web-search-on-opus today; deliberately extensible (timing, spikes). NOTE: item key is
`kind`, never `code` — `code` is moat-forbidden.

MOAT BOUNDARY (absolute): the emitted summary carries ONLY distilled aggregates +
advice. moat_check() recursively rejects any content/key/identifier-shaped field
(prompt, response, content, text, messages, code, file, api_key, session ids, ts, ...).
build_summary() refuses to return a dirty object. --selftest proves the negative path:
a planted content-bearing object MUST be rejected.

ts/session_id exist in-memory only for date-filtering and a distinct-session COUNT;
they never reach the emitted object. Dedup key (requestId, message.id) is in-memory
only too (streamed responses repeat usage across lines).

Rates from usage_rates.yaml alongside this file (R13: nothing hardcoded — public
Anthropic pricing; edit there, never in code).
"""
import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import yaml

BASE = Path(__file__).resolve().parent           # the reader/ dir
RATES = BASE / "usage_rates.yaml"                 # public pricing, ships beside this file
PROJECTS = Path.home() / ".claude" / "projects"
OUT_DIR = BASE / "out"

SCHEMA_VERSION = 1

# ── MOAT CHECK ──────────────────────────────────────────────────────────────
ALLOWED_TOP = {"schema_version", "date", "generated_at", "scanned", "per_model",
               "total_cost_inr", "saved", "missed_by_model", "advice", "signal_hint"}
# exact-match key names that must never appear anywhere in the emitted object
FORBIDDEN_KEYS = {"prompt", "prompts", "response", "responses", "content", "contents",
                  "messages", "body", "text", "raw", "code", "file", "files", "path",
                  "paths", "api_key", "apikey", "key", "keys", "secret", "secrets",
                  "authorization", "bearer", "headers", "token", "tokens",
                  "session_id", "sessionid", "session_ids", "registry_id",
                  "id", "ts", "uuid", "requestid", "request_id", "cwd", "gitbranch"}
MAX_STR = 300        # no string field may be prompt-sized
MAX_LIST = 100       # no list may approach per-call granularity


def moat_check(obj, path="$"):
    """Raise AssertionError if any raw/prompt/key/identifier-shaped field is present."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            assert k.lower() not in FORBIDDEN_KEYS, \
                f"MOAT VIOLATION: forbidden key {k!r} at {path}"
            moat_check(v, f"{path}.{k}")
        if path == "$":
            extra = set(obj) - ALLOWED_TOP
            assert not extra, f"MOAT VIOLATION: unexpected top-level keys {extra}"
    elif isinstance(obj, list):
        assert len(obj) <= MAX_LIST, \
            f"MOAT VIOLATION: list len {len(obj)} at {path} (per-call granularity?)"
        for i, v in enumerate(obj):
            moat_check(v, f"{path}[{i}]")
    elif isinstance(obj, str):
        assert len(obj) <= MAX_STR, f"MOAT VIOLATION: string len {len(obj)} at {path} (raw content?)"
    else:
        assert obj is None or isinstance(obj, (int, float, bool)), \
            f"MOAT VIOLATION: unexpected type {type(obj).__name__} at {path}"
    return True


# ── rates (same helpers as usage_report.py) ────────────────────────────────
def load_rates() -> dict:
    with open(RATES) as fh:
        return yaml.safe_load(fh) or {}


def fam_rate(rates: dict, family: str, bucket: str) -> float:
    fams = rates.get("families") or {}
    fr = fams.get(family) or fams.get("unknown") or {}
    return float(fr.get(bucket) or 0.0)


def family_of(model: str) -> str:
    m = (model or "").lower()
    for fam in ("opus", "sonnet", "haiku"):
        if fam in m:
            return fam
    return "unknown"


def cost_inr(rates: dict, fam: str, in_t: int, out_t: int, cr: int, cw: int) -> float:
    usd = (in_t / 1e6 * fam_rate(rates, fam, "input")
           + out_t / 1e6 * fam_rate(rates, fam, "output")
           + cr / 1e6 * fam_rate(rates, fam, "cache_read")
           + cw / 1e6 * fam_rate(rates, fam, "cache_write"))
    return usd * float(rates.get("usd_inr") or 0.0)


# ── extraction (token counts ONLY — content is never read) ──────────────────
def extract_line(line: str):
    """Return the 7-field token record for one JSONL line, or None.

    Reads ONLY: timestamp, sessionId, message.model, the 4 usage token counters,
    web_search count, and (in-memory dedup only) requestId + message.id.
    """
    try:
        o = json.loads(line)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None
    if not isinstance(o, dict):
        return None
    msg = o.get("message")
    if not isinstance(msg, dict):
        return None
    usage = msg.get("usage")
    if not isinstance(usage, dict):
        return None
    in_t = int(usage.get("input_tokens") or 0)
    out_t = int(usage.get("output_tokens") or 0)
    cr = int(usage.get("cache_read_input_tokens") or 0)
    cw = int(usage.get("cache_creation_input_tokens") or 0)
    if in_t == out_t == cr == cw == 0:
        return None                                    # synthetic / empty entry
    stu = usage.get("server_tool_use")
    ws = int(stu.get("web_search_requests") or 0) if isinstance(stu, dict) else 0
    return {
        "ts": str(o.get("timestamp") or ""),
        "session_id": str(o.get("sessionId") or ""),
        "model": str(msg.get("model") or "unknown"),
        "input_tokens": in_t,
        "output_tokens": out_t,
        "cache_read": cr,
        "cache_creation": cw,
        "_web_search": ws,                             # numeric counter only
        "_dedup": (str(o.get("requestId") or ""), str(msg.get("id") or "")),
    }


def read_projects(date: str):
    """Walk PROJECTS read-only; yield deduped token records for `date` (UTC)."""
    files = sorted(PROJECTS.glob("**/*.jsonl")) if PROJECTS.is_dir() else []
    seen, records, lines_with_usage = set(), [], 0
    for fp in files:
        try:
            fh = open(fp, "r", encoding="utf-8", errors="replace")
        except OSError:
            continue
        with fh:
            for line in fh:
                rec = extract_line(line)
                if rec is None:
                    continue
                lines_with_usage += 1
                if not rec["ts"].startswith(date):
                    continue
                dk = rec["_dedup"]
                if dk != ("", "") and dk in seen:      # streamed dup of same request
                    continue
                seen.add(dk)
                records.append(rec)
    return files, lines_with_usage, records


# ── advice (OPEN schema: {kind, message, severity, model?, inr?}) ───────────
def build_advice(rates, per_model, missed_rows, web_search_by_model):
    th = rates.get("advice_thresholds") or {}
    missed_inr_min = float(th.get("missed_inr_min", 0.01))
    opus_share_min = float(th.get("opus_share", 0.8))
    opus_cost_min = float(th.get("opus_cost_min", 1.0))

    advice = []
    for row in missed_rows:
        if row["missed_inr"] >= missed_inr_min:
            advice.append({"kind": "cache_uncached_input", "model": row["model"],
                           "inr": row["missed_inr"], "severity": row["missed_inr"],
                           "message": f"{row['model']}: {row['in_tok']} uncached input tokens — "
                                      f"₹{row['missed_inr']} were cacheable"})
    # model-misuse: opus carrying the bulk of cost — flag the haiku/sonnet delta
    total = sum(r["cost_inr"] for r in per_model) or 0.0
    opus_cost = sum(r["cost_inr"] for r in per_model if r["family"] == "opus")
    if total > 0 and opus_cost / total > opus_share_min and opus_cost > opus_cost_min:
        advice.append({"kind": "model_mix_opus_heavy", "inr": round(opus_cost, 3),
                       "severity": round(opus_cost / total, 3),
                       "message": f"opus is {opus_cost / total * 100:.0f}% of the day's cost "
                                  f"(₹{opus_cost:.2f}) — route bulk/simple calls to haiku or sonnet"})
    for model, ws in web_search_by_model.items():
        if ws > 0 and family_of(model) == "opus":
            advice.append({"kind": "web_search_on_opus", "model": model, "severity": ws,
                           "message": f"{model} made {ws} web-search call(s) — search inflates "
                                      f"opus input tokens; consider a cheaper model for search turns"})
    return advice


# ── signal_hint: worst light for the widget (green/yellow/red), no re-derive ─
def compute_signal_hint(advice, per_model, yellow_min_inr=50.0):
    if any(a["kind"] == "model_mix_opus_heavy" for a in advice):
        return "red"
    total_severity = sum(float(a.get("severity") or a.get("inr") or 0) for a in advice)
    if total_severity >= yellow_min_inr:
        return "yellow"
    return "green"


# ── summary ─────────────────────────────────────────────────────────────────
def build_summary(date: str) -> dict:
    rates = load_rates()
    usd_inr = float(rates.get("usd_inr") or 0.0)
    files, usage_lines, records = read_projects(date)

    agg, web_search_by_model, sessions = {}, {}, set()
    for r in records:
        sessions.add(r["session_id"])
        a = agg.setdefault(r["model"], {"calls": 0, "in": 0, "out": 0, "cr": 0, "cw": 0})
        a["calls"] += 1
        a["in"] += r["input_tokens"]
        a["out"] += r["output_tokens"]
        a["cr"] += r["cache_read"]
        a["cw"] += r["cache_creation"]
        web_search_by_model[r["model"]] = web_search_by_model.get(r["model"], 0) + r["_web_search"]

    per_model, saved_inr, total = [], 0.0, 0.0
    missed_rows = []
    for model, a in sorted(agg.items(), key=lambda kv: -kv[1]["in"]):
        fam = family_of(model)
        c = round(cost_inr(rates, fam, a["in"], a["out"], a["cr"], a["cw"]), 3)
        total += c
        per_model.append({"model": model, "family": fam, "calls": a["calls"],
                          "in_tok": a["in"], "out_tok": a["out"],
                          "cache_r": a["cr"], "cache_w": a["cw"], "cost_inr": c})
        rate_delta = fam_rate(rates, fam, "input") - fam_rate(rates, fam, "cache_read")
        saved_inr += a["cr"] / 1e6 * rate_delta * usd_inr
        if a["in"] > 0:
            missed = round(a["in"] / 1e6 * rate_delta * usd_inr, 4)
            missed_rows.append({"model": model, "family": fam, "why": "uncached-input",
                                "calls": a["calls"], "in_tok": a["in"], "missed_inr": missed})
    missed_rows = sorted(missed_rows, key=lambda r: -r["missed_inr"])[:MAX_LIST]

    without_cache = total + saved_inr
    summary = {
        "schema_version": SCHEMA_VERSION,
        "date": date,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "scanned": {"jsonl_files": len(files), "usage_lines": usage_lines,
                    "deduped_calls": len(records), "sessions": len(sessions)},
        "per_model": per_model[:MAX_LIST],
        "total_cost_inr": round(total, 3),
        "saved": {"inr": round(saved_inr, 3),
                  "pct": round(saved_inr / without_cache * 100, 1) if without_cache > 0 else 0.0},
        "missed_by_model": missed_rows,
        "advice": build_advice(rates, per_model, missed_rows, web_search_by_model)[:MAX_LIST],
    }
    th = rates.get("advice_thresholds") or {}
    yellow_min_inr = float(th.get("yellow_min_inr", 50))
    summary["signal_hint"] = compute_signal_hint(summary["advice"], per_model, yellow_min_inr)
    moat_check(summary)          # refuse to return a dirty object
    return summary


# ── negative self-test: a content-bearing object MUST be rejected ───────────
def selftest() -> int:
    clean = {"schema_version": 1, "date": "2026-01-01", "generated_at": "x",
             "scanned": {"jsonl_files": 0, "usage_lines": 0, "deduped_calls": 0, "sessions": 0},
             "per_model": [], "total_cost_inr": 0.0,
             "saved": {"inr": 0.0, "pct": 0.0}, "missed_by_model": [], "advice": [],
             "signal_hint": "green"}
    moat_check(clean)
    print("PASS clean summary accepted")
    planted = [
        ("content key", {**clean, "advice": [{"kind": "x", "content": "user prompt leaked"}]}),
        ("prompt key", {**clean, "advice": [{"kind": "x", "prompt": "secret prompt"}]}),
        ("api_key key", {**clean, "saved": {"inr": 0, "pct": 0, "api_key": "sk-ant-xxx"}}),
        ("messages key", {**clean, "per_model": [{"model": "m", "messages": ["hi"]}]}),
        ("session_id key", {**clean, "per_model": [{"model": "m", "session_id": "abc"}]}),
        ("prompt-sized string", {**clean, "advice": [{"kind": "x", "message": "A" * 301}]}),
        ("unexpected top-level", {**clean, "transcript": []}),
    ]
    failures = 0
    for name, obj in planted:
        try:
            moat_check(obj)
            print(f"FAIL {name}: dirty object was ACCEPTED")
            failures += 1
        except AssertionError as e:
            print(f"PASS rejected {name}: {e}")
    return failures


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--date", default=datetime.now(timezone.utc).strftime("%Y-%m-%d"))
    ap.add_argument("--write", action="store_true", help=f"also write to {OUT_DIR}/<date>.json")
    ap.add_argument("--selftest", action="store_true", help="run moat negative tests and exit")
    args = ap.parse_args()
    if args.selftest:
        sys.exit(selftest())
    summary = build_summary(args.date)
    out = json.dumps(summary, indent=2)
    print(out)
    if args.write:
        OUT_DIR.mkdir(exist_ok=True)
        (OUT_DIR / f"{args.date}.json").write_text(out + "\n")


if __name__ == "__main__":
    main()
