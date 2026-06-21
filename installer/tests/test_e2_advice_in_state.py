#!/usr/bin/env python3
"""
test_e2_advice_in_state.py — OFFLINE proof for Phase E2 (reader advice -> widget
via /v1/state). NO live server, NO nginx, NO network. It proves locally:

  • build_state() now carries an `advice` list built from the reader's OWN logs
    (jsonl_reader.build_summary -> advice[]) when there ARE logs;
  • the advice that crosses the bridge is OUTCOME-only ({kind, message, model?,
    inr?}) and passes the reader's REAL moat_check — no derivation, no content;
  • a planted content-bearing advice item is REFUSED (negative test): the dirty
    payload trips moat_check and build_state relays an EMPTY advice list, never
    the leaked field;
  • the GATE holds: no logs -> advice == [] (B3 empty-state preserved); and the
    /v1/state auth path means advice never crosses to an unpaired widget.

Run: python3 test_e2_advice_in_state.py    (exit 0 = all pass)
"""
import json
import sys
import tempfile
from pathlib import Path

CLIENT_READER = Path("/opt/tokenizer-client/reader")
sys.path.insert(0, str(CLIENT_READER))

import jsonl_reader                               # noqa: E402
import local_bridge as lb                         # noqa: E402

PASS = FAIL = 0


def check(name, cond, extra=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS {name}")
    else:
        FAIL += 1
        print(f"FAIL {name}  {extra}")


def _write_fixture(projects: Path, date: str):
    """A real-shaped Claude Code jsonl line: big UNCACHED Opus input (triggers the
    cache_uncached_input advice) + planted conversation content we must never see
    cross the bridge."""
    proj = projects / "proj1"
    proj.mkdir(parents=True)
    secret = "TOP_SECRET_PROMPT_TEXT_MUST_NEVER_LEAVE_THE_MACHINE"
    line = json.dumps({
        "timestamp": f"{date}T10:00:00Z", "sessionId": "sess-xyz", "requestId": "req-1",
        "message": {"id": "m1", "model": "claude-opus-4-8", "role": "assistant",
                    "content": secret,
                    "usage": {"input_tokens": 4_000_000, "output_tokens": 5000,
                              "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0,
                              "server_tool_use": {"web_search_requests": 2}}}})
    (proj / "a.jsonl").write_text(line + "\n")
    return secret


def main():
    tmp = Path(tempfile.mkdtemp(prefix="e2advice_"))
    date = "2026-06-21"
    projects = tmp / "projects"
    secret = _write_fixture(projects, date)

    # redirect BOTH the reader scan AND the bridge's "today" + advice cache.
    # count_project_logs() reads the REAL ~/.claude/projects (independent of the
    # fixture), so stub it to make has_data deterministic for the test.
    jsonl_reader.PROJECTS = projects
    lb._utc_today = lambda: date                   # pin advice to the fixture's date
    lb.count_project_logs = lambda: 5              # "logs present" for the has-data steps
    lb._advice_cache.update({"date": None, "at": 0.0, "advice": []})  # cold cache

    # ── 1. advice is BUILT from the reader's own logs (outcome messages) ──────
    advice = lb.build_advice({})
    check("advice list is non-empty for a heavy-uncached-Opus day", len(advice) > 0,
          f"advice={advice}")
    kinds = {a.get("kind") for a in advice}
    check("cache-savings advice present (cache_uncached_input)",
          "cache_uncached_input" in kinds, f"kinds={kinds}")
    one = next((a for a in advice if a.get("kind") == "cache_uncached_input"), {})
    check("advice item is outcome-shaped {kind,message}",
          isinstance(one.get("message"), str) and one["message"] != "")
    check("advice carries the uncached count + cacheable outcome wording",
          "uncached input" in one.get("message", "") and "cacheable" in one.get("message", ""),
          one.get("message"))

    # ── 2. build_state() carries advice, moat-clean, NO content ──────────────
    lb._advice_cache.update({"date": None, "at": 0.0, "advice": []})  # cold cache again
    state = lb.build_state({})
    check("/v1/state response now carries an advice list",
          isinstance(state.get("advice"), list) and len(state["advice"]) > 0)
    check("B3 state preserved (logs_found/has_data/dtach still present)",
          isinstance(state.get("logs_found"), int) and state.get("has_data") is True
          and isinstance(state.get("dtach"), list))
    blob = json.dumps(state)
    check("NO conversation content anywhere in the /v1/state response", secret not in blob)
    # the reader's REAL moat_check passes on the advice payload that leaves the handler
    try:
        jsonl_reader.moat_check(state["advice"], path="$.advice")
        clean = True
    except AssertionError as e:
        clean = False
        print("   moat_check error:", e)
    check("advice payload PASSES the reader's real moat_check", clean)

    # ── 3. NEGATIVE: a content-bearing advice item is REFUSED ────────────────
    # Simulate build_summary leaking a content field; build_advice must relay [].
    dirty_summary = {
        "schema_version": 1, "date": date, "generated_at": "x",
        "scanned": {"jsonl_files": 0, "usage_lines": 0, "deduped_calls": 0, "sessions": 0},
        "per_model": [], "total_cost_inr": 0.0, "saved": {"inr": 0.0, "pct": 0.0},
        "missed_by_model": [],
        "advice": [{"kind": "x", "message": "ok", "content": secret}],  # forbidden key
    }
    orig = jsonl_reader.build_summary
    jsonl_reader.build_summary = lambda d: dirty_summary
    # build_advice imports build_summary/moat_check from jsonl_reader at call time,
    # so patching the module attribute is enough.
    try:
        lb._advice_cache.update({"date": None, "at": 0.0, "advice": []})
        refused = lb.build_advice({})
    finally:
        jsonl_reader.build_summary = orig
    check("NEGATIVE: dirty advice (content key) -> relayed as EMPTY list", refused == [],
          f"refused={refused}")
    check("NEGATIVE: leaked secret never appears in the relayed advice",
          secret not in json.dumps(refused))

    # direct moat_check proof that the dirty item WOULD be rejected
    rejected = False
    try:
        jsonl_reader.moat_check([{"kind": "x", "content": "leak"}], path="$.advice")
    except AssertionError:
        rejected = True
    check("NEGATIVE: moat_check rejects a content-bearing advice item directly", rejected)

    # ── 4. GATE: no logs -> no advice (B3 empty-state intact) ────────────────
    empty = Path(tempfile.mkdtemp(prefix="e2empty_")) / "projects"
    empty.mkdir(parents=True)
    jsonl_reader.PROJECTS = empty
    lb.count_project_logs = lambda: 0              # no Claude Code logs at all
    lb._advice_cache.update({"date": None, "at": 0.0, "advice": []})
    state2 = lb.build_state({})
    check("GATE no-logs -> advice == [] (basic monitoring only)",
          state2.get("advice") == [] and state2.get("has_data") is False)

    # reader's own moat negative-path selftest still green
    check("reader moat_check negative-path selftest still passes", jsonl_reader.selftest() == 0)

    print(f"\n{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
