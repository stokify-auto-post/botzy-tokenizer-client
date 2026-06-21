#!/usr/bin/env python3
"""
test_e5_m10_empty_token.py — m10: an empty/blank .bridge_token must be RE-MINTED.

Before the fix, ensure_token() minted only when the file was ABSENT; an existing
empty/truncated file yielded token="" and every request 401'd forever. Proves the
fix: an empty (and whitespace-only) token file is treated like absent and re-minted
to a fresh 64-hex token; a valid token file is left untouched.

Run: python3 test_e5_m10_empty_token.py   (exit 0 = pass)
"""
import re
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path("/opt/tokenizer-client/reader")))
import local_bridge as lb   # noqa: E402

PASS = FAIL = 0


def check(name, cond, extra=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS {name}")
    else:
        FAIL += 1
        print(f"FAIL {name}  {extra}")


def main():
    tmp = Path(tempfile.mkdtemp(prefix="e5m10_"))
    HEX64 = re.compile(r"^[0-9a-f]{64}$")

    # 1. truly empty file -> re-mint
    tf = tmp / ".bridge_token"
    tf.write_text("")
    tok = lb.ensure_token(str(tf))
    check("empty token file -> re-minted to 64-hex", bool(HEX64.match(tok)), repr(tok))
    check("re-minted token persisted to the file", tf.read_text().strip() == tok)

    # 2. whitespace-only file -> re-mint
    tf2 = tmp / ".bridge_token_ws"
    tf2.write_text("   \n\t ")
    tok2 = lb.ensure_token(str(tf2))
    check("whitespace-only token file -> re-minted", bool(HEX64.match(tok2)))

    # 3. valid existing token -> left untouched
    tf3 = tmp / ".bridge_token_ok"
    tf3.write_text("a" * 64 + "\n")
    tok3 = lb.ensure_token(str(tf3))
    check("valid token file -> returned unchanged (no re-mint)", tok3 == "a" * 64)

    # 4. absent file -> mint (unchanged behaviour)
    tf4 = tmp / ".bridge_token_absent"
    tok4 = lb.ensure_token(str(tf4))
    check("absent token file -> minted", bool(HEX64.match(tok4)) and tf4.exists())

    print(f"\n{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
