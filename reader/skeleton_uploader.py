#!/usr/bin/env python3
"""
skeleton_uploader.py — opt-in, enroll-gated upload of the project SKELETON.

Sends ONLY file paths/sizes/kinds — never file contents, never secrets, never
env values. Enforced upstream by skeleton_reader.read_skeleton(), which never
opens file contents and drops secret-ish paths entirely. This module only
seals that already-clean shape and ships it.

It mirrors usage_uploader.py exactly: the SAME creds.json load (registry_id +
install_token + transit_key from enroll), the SAME Fernet seal(), the SAME
{registry_id, payload} envelope + Bearer header, and the SAME honest-failure
posture — on any network error / non-200 we return {ok:False, reason} and
NEVER raise uncaught, NEVER pretend success. The only difference is the target
path: POST {server_base}/v1/skeleton instead of the usage endpoint.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

# reuse usage_uploader's proven plumbing verbatim (soft-dep, config, creds,
# seal, _post) rather than re-inventing it.
try:
    from usage_uploader import (HAVE_CRYPTO, load_config, load_creds,
                                creds_path, seal, _post, log)
except Exception:                                # pragma: no cover - env dependent
    sys.path.insert(0, str(HERE))
    from usage_uploader import (HAVE_CRYPTO, load_config, load_creds,  # type: ignore
                                creds_path, seal, _post, log)

# local import of the reader half.
try:
    from skeleton_reader import read_skeleton
except Exception:                                # pragma: no cover
    sys.path.insert(0, str(HERE))
    from skeleton_reader import read_skeleton    # type: ignore


def skeleton_url(cfg, server_base=None):
    """Target URL. server_base falls back to the SAME installer_config.yaml key
    usage_uploader uses (server_base). Path is /v1/skeleton (override via the
    optional skeleton_path key if present — no new REQUIRED key invented)."""
    base = (server_base or cfg.get("server_base") or "").rstrip("/")
    if not base:
        return None
    path = cfg.get("skeleton_path") or "/v1/skeleton"
    if not path.startswith("/"):
        path = "/" + path
    return base + path


def upload_skeleton(project_root, server_base=None, *, poster=_post, cfg=None):
    """Read the skeleton, seal it, POST it. Enroll-gated (needs creds.json).

    Returns {ok, reason, ...}. Never raises for an expected condition (no
    crypto, no creds, no url, network/http error) — logs honestly and returns
    ok=False with a reason. `poster` is injectable so tests need no network."""
    if not HAVE_CRYPTO:
        log("skeleton skip: 'cryptography' not installed — cannot Fernet-seal.")
        return {"ok": False, "reason": "no-cryptography"}

    cfg = load_config(HERE) if cfg is None else cfg

    creds = load_creds(creds_path(cfg, HERE))
    if not creds:                                # GATE: enrolled?
        return {"ok": False, "reason": "no-creds (not enrolled) — not uploading"}

    url = skeleton_url(cfg, server_base)
    if not url:
        log("skeleton skip: no server_base in installer_config.yaml")
        return {"ok": False, "reason": "no-server-base"}

    try:
        payload = read_skeleton(project_root)
    except Exception as e:
        log(f"skeleton skip: could not read skeleton: {e}")
        return {"ok": False, "reason": f"read-error: {e}"}

    try:
        sealed = seal(payload, creds["transit_key"])
    except Exception as e:
        log(f"skeleton skip: could not seal payload: {e}")
        return {"ok": False, "reason": f"seal-error: {e}"}

    ok, status, body = poster(url, creds["registry_id"], creds["install_token"],
                              sealed)
    if ok:
        log(f"OK — uploaded skeleton ({payload['total_files']} files, "
            f"{payload['redacted_count']} redacted) to {url}")
        return {"ok": True, "reason": "ok", "status": status,
                "total_files": payload["total_files"],
                "redacted_count": payload["redacted_count"]}
    snippet = (body or "").replace("\n", " ")[:200]
    log(f"skeleton FAILED (status {status}) — nothing pretended. server: {snippet}")
    return {"ok": False, "reason": f"http-{status}", "status": status}


# ── offline self-test — stubs the POST, no real network call ───────────────────
def _selftest():
    import tempfile

    if not HAVE_CRYPTO:
        print("SKIP skeleton_uploader: cryptography not installed")
        return  # not a failure; the module is honest about the missing dep

    from cryptography.fernet import Fernet

    with tempfile.TemporaryDirectory(prefix="skelup_") as tmp:
        os.makedirs(os.path.join(tmp, "src"))
        secret_text = "STUB_SECRET_zzz_98765"
        with open(os.path.join(tmp, "src", "main.py"), "w") as fh:
            fh.write("x = 1  # stub_source_marker_abc\n")
        with open(os.path.join(tmp, ".env"), "w") as fh:
            fh.write("TOKEN=" + secret_text + "\n")
        with open(os.path.join(tmp, "id_rsa"), "w") as fh:
            fh.write(secret_text + "\n")

        # fake enrolled creds + a captured-payload stub poster.
        tk = Fernet.generate_key().decode()
        fake_creds = {"registry_id": "a" * 32, "install_token": "tok",
                      "transit_key": tk}
        captured = {}

        def stub_creds(_path):
            return fake_creds

        def stub_post(url, rid, tok_, sealed):
            captured["url"] = url
            captured["decrypted"] = Fernet(tk.encode()).decrypt(
                sealed.encode()).decode()
            return (True, 200, "ok")

        # monkeypatch creds loader in THIS module's own globals (running as
        # __main__, so patch globals() directly — not a re-import copy).
        g = globals()
        orig = g["load_creds"]
        g["load_creds"] = stub_creds
        try:
            res = upload_skeleton(tmp, server_base="https://stub.example",
                                  poster=stub_post,
                                  cfg={"server_base": "https://stub.example"})
        finally:
            g["load_creds"] = orig

        assert res["ok"] is True, res
        assert captured["url"] == "https://stub.example/v1/skeleton", captured
        blob = captured["decrypted"]
        assert secret_text not in blob, "secret content in payload!"
        assert "stub_source_marker_abc" not in blob, "source content in payload!"
        assert ".env" not in blob, "secret PATH in payload!"
        assert "id_rsa" not in blob, "secret PATH in payload!"
        assert "src/main.py" in blob, blob
    print("OK skeleton_uploader")


if __name__ == "__main__":
    try:
        _selftest()
    except AssertionError as e:
        print("FAIL skeleton_uploader:", e)
        sys.exit(1)
    sys.exit(0)
