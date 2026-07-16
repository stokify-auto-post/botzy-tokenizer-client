#!/usr/bin/env python3
"""
skeleton_reader.py — client-side reader of a project's SHAPE (skeleton) only.

WHAT LEAVES THE MACHINE (and nothing else, ever):
  for each file — its relative path, extension, size in bytes, and a coarse
  'kind' guess (source/config/doc/data/binary) derived PURELY from the
  extension. Never the file's bytes, never its contents, never secrets, never
  env values. This mirrors the server-side content_reader.read_structure()
  shape (path/extension/size/kind) but is the CLIENT half of the promise
  "Allow access — reads your skeleton, read-only, no code files touched".

HOW THAT PROMISE IS ENFORCED IN CODE (not just in this comment):
  this module NEVER calls open() in 'r'/'rb' on a catalogued file and NEVER
  calls .read() on any project file. It learns the tree with os.walk / os.stat
  (directory listing + metadata) ONLY. The single, deliberate exception is the
  repo's own .gitignore — an ignore-RULES metadata file, not a code file and
  never transmitted — read solely to know what to skip.

HARD SECRET GUARD:
  files matching secret-ish patterns (.env*, *.pem, *.key, id_rsa*,
  *credentials*, *secret*) are dropped ENTIRELY — their path never even
  appears in the output. A redacted_count is returned so nothing is silently
  invisible.
"""
from __future__ import annotations

import fnmatch
import os
from datetime import datetime, timezone


# ── secret-ish names: path is excluded ENTIRELY (not just its content) ─────────
_SECRET_GLOBS = (".env", ".env.*", "*.pem", "*.key", "id_rsa*",
                 "*credentials*", "*secret*")

# ── directories/patterns always skipped even without a .gitignore ──────────────
_DEFAULT_IGNORE_DIRS = {".git", "node_modules", "__pycache__", "venv", ".venv",
                        "env", ".mypy_cache", ".pytest_cache", ".next", "dist",
                        "build", ".idea", ".vscode", "target", ".gradle"}

_SOURCE_EXT = {".py", ".js", ".ts", ".jsx", ".tsx", ".go", ".rs", ".java", ".c",
               ".h", ".cpp", ".cc", ".hpp", ".rb", ".php", ".sh", ".bash",
               ".css", ".scss", ".sass", ".less", ".html", ".htm", ".vue",
               ".svelte", ".swift", ".kt", ".kts", ".sql", ".lua", ".pl", ".r",
               ".m", ".mm", ".scala", ".clj", ".ex", ".exs", ".dart", ".ps1"}
_CONFIG_EXT = {".yaml", ".yml", ".json", ".toml", ".ini", ".cfg", ".conf",
               ".lock", ".xml", ".properties", ".editorconfig", ".gradle",
               ".tf", ".tfvars", ".dockerfile"}
_DOC_EXT = {".md", ".rst", ".txt", ".pdf", ".docx", ".adoc", ".rtf", ".org"}
_DATA_EXT = {".csv", ".tsv", ".parquet", ".db", ".sqlite", ".sqlite3", ".jsonl",
             ".ndjson", ".avro", ".arrow"}


def _kind_for(ext):
    e = ext.lower()
    if e in _SOURCE_EXT:
        return "source"
    if e in _CONFIG_EXT:
        return "config"
    if e in _DOC_EXT:
        return "doc"
    if e in _DATA_EXT:
        return "data"
    return "binary"


def _is_secret(name):
    low = name.lower()
    for g in _SECRET_GLOBS:
        if fnmatch.fnmatch(low, g):
            return True
    return False


# ── minimal .gitignore parser — the ONLY file whose bytes we read, and it is an
#    ignore-RULES metadata file (never a code file, never transmitted). ─────────
def _load_gitignore(root):
    rules = []
    gi = os.path.join(root, ".gitignore")
    if not os.path.isfile(gi):
        return rules
    try:
        with open(gi) as fh:                 # metadata only — see module docstring
            for line in fh:
                s = line.strip()
                if not s or s.startswith("#") or s.startswith("!"):
                    continue
                rules.append(s.rstrip("/"))
    except OSError:
        pass
    return rules


def _ignored(rel, rules):
    """True if rel path (posix, no leading slash) matches a gitignore rule."""
    parts = rel.split("/")
    base = parts[-1]
    for r in rules:
        pat = r.lstrip("/")
        if fnmatch.fnmatch(rel, pat) or fnmatch.fnmatch(base, pat):
            return True
        # directory-anchored rule matching any ancestor segment
        if "/" not in pat and pat in parts[:-1]:
            return True
    return False


def read_skeleton(project_root):
    """Return the SHAPE of project_root — paths/exts/sizes/kinds only.

    Never opens or reads the contents of any catalogued file; uses os.walk +
    os.stat exclusively. Secret-ish files are excluded entirely and counted in
    redacted_count."""
    root = os.path.abspath(project_root)
    rules = _load_gitignore(root)
    files = []
    total_size = 0
    redacted = 0

    for dirpath, dirnames, filenames in os.walk(root):
        # prune ignored/default dirs in place (do not descend)
        rel_dir = os.path.relpath(dirpath, root)
        rel_dir = "" if rel_dir == "." else rel_dir.replace(os.sep, "/")
        kept = []
        for d in dirnames:
            if d in _DEFAULT_IGNORE_DIRS:
                continue
            rd = (rel_dir + "/" + d) if rel_dir else d
            if rules and _ignored(rd, rules):
                continue
            kept.append(d)
        dirnames[:] = kept

        for fn in filenames:
            rel = (rel_dir + "/" + fn) if rel_dir else fn
            if _is_secret(fn):
                redacted += 1
                continue                     # path excluded ENTIRELY
            if rules and _ignored(rel, rules):
                continue
            full = os.path.join(dirpath, fn)
            try:
                size = os.stat(full).st_size  # metadata only — never read()
            except OSError:
                continue
            ext = os.path.splitext(fn)[1]
            files.append({"path": rel, "ext": ext, "size": size,
                          "kind": _kind_for(ext)})
            total_size += size

    files.sort(key=lambda f: f["path"])
    return {"root_name": os.path.basename(root.rstrip(os.sep)) or root,
            "files": files,
            "total_files": len(files),
            "total_size": total_size,
            "redacted_count": redacted,
            "generated_ts": datetime.now(timezone.utc).strftime(
                "%Y-%m-%dT%H:%M:%SZ")}


# ── standalone self-test against a /tmp fixture tree ───────────────────────────
def _selftest():
    import json
    import tempfile

    with tempfile.TemporaryDirectory(prefix="skel_") as tmp:
        os.makedirs(os.path.join(tmp, "src"))
        srcfile = os.path.join(tmp, "src", "app.py")
        secret_text = "SUPER_SECRET_TOKEN_do_not_leak_42"
        with open(os.path.join(tmp, "src", "app.py"), "w") as fh:
            fh.write("print('hello world unique_source_marker_xyz')\n")
        with open(os.path.join(tmp, "README.md"), "w") as fh:
            fh.write("# fixture\n")
        with open(os.path.join(tmp, "config.yaml"), "w") as fh:
            fh.write("k: v\n")
        # secret files that MUST be redacted
        with open(os.path.join(tmp, ".env"), "w") as fh:
            fh.write("API_KEY=" + secret_text + "\n")
        with open(os.path.join(tmp, "secret.key"), "w") as fh:
            fh.write(secret_text + "\n")

        res = read_skeleton(tmp)
        dumped = json.dumps(res)

        paths = [f["path"] for f in res["files"]]
        assert ".env" not in paths, paths
        assert "secret.key" not in paths, paths
        assert res["redacted_count"] >= 2, res["redacted_count"]
        assert res["total_files"] == len(paths), res
        # non-redacted files present
        assert "src/app.py" in paths and "README.md" in paths, paths
        # NO file content ever appears in output
        assert secret_text not in dumped, "secret content leaked!"
        assert "unique_source_marker_xyz" not in dumped, "source content leaked!"
        assert "print(" not in dumped, "source content leaked!"
        # kinds sane
        kinds = {f["path"]: f["kind"] for f in res["files"]}
        assert kinds["src/app.py"] == "source", kinds
        assert kinds["config.yaml"] == "config", kinds
        assert kinds["README.md"] == "doc", kinds
        _ = srcfile  # keep ref
    print("OK skeleton_reader")


if __name__ == "__main__":
    import sys
    try:
        _selftest()
    except AssertionError as e:
        print("FAIL skeleton_reader:", e)
        sys.exit(1)
    sys.exit(0)
