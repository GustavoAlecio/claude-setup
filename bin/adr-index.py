#!/usr/bin/env python3
"""
ADR index and relevance lookup.

  adr-index.py reindex <repo> [--dir docs/adr]           -> rewrites <dir>/INDEX.md
  adr-index.py match   <repo> [--dir docs/adr] FILE...    -> accepted ADR paths whose `affects` globs hit FILE
  adr-index.py next-id <repo> [--dir docs/adr]

Frontmatter keys: id, title, status (proposed|accepted|deprecated|superseded), date,
affects (glob list), supersedes, superseded_by, tags.
"""
import argparse
import json
import re
import sys
from pathlib import Path


def parse_front(text):
    m = re.match(r"^---\n(.*?)\n---", text, re.S)
    if not m:
        return {}
    meta = {}
    for line in m.group(1).splitlines():
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        v = v.strip()
        if v.startswith("["):
            try:
                v = json.loads(v)
            except json.JSONDecodeError:
                v = [x.strip().strip("'\"") for x in v.strip("[]").split(",") if x.strip()]
        else:
            v = v.strip("'\"")
        meta[k.strip()] = v
    return meta


def glob_re(pattern):
    out, i = "", 0
    while i < len(pattern):
        c = pattern[i]
        if pattern.startswith("**/", i):
            out += "(?:.*/)?"
            i += 3
        elif pattern.startswith("**", i):
            out += ".*"
            i += 2
        elif c == "*":
            out += "[^/]*"
            i += 1
        elif c == "?":
            out += "[^/]"
            i += 1
        else:
            out += re.escape(c)
            i += 1
    return re.compile("^" + out + "$")


def load(repo, d):
    adrs = []
    for p in sorted((Path(repo) / d).glob("[0-9]*.md")):
        meta = parse_front(p.read_text())
        meta["_path"] = str(p.relative_to(repo))
        adrs.append(meta)
    return adrs


def as_list(v):
    return v if isinstance(v, list) else ([v] if v else [])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["reindex", "match", "next-id"])
    ap.add_argument("repo")
    ap.add_argument("files", nargs="*")
    ap.add_argument("--dir", default="docs/adr")
    a = ap.parse_args()
    adrs = load(a.repo, a.dir)

    if a.cmd == "next-id":
        ids = [int(x["id"]) for x in adrs if str(x.get("id", "")).isdigit()]
        print(f"{(max(ids) + 1) if ids else 1:04d}")
    elif a.cmd == "reindex":
        rows = ["# ADR Index", "", "> Gerado por `adr-index.py reindex`. Não editar à mão.", "",
                "| ID | Título | Status | Affects | Supersedes | Superseded by |", "|---|---|---|---|---|---|"]
        for x in adrs:
            name = Path(x["_path"]).name
            rows.append(f"| [[{name[:-3]}\\|{x.get('id', '?')}]] | {x.get('title', '')} | {x.get('status', '')} | "
                        f"{'<br>'.join(f'`{g}`' for g in as_list(x.get('affects')))} | "
                        f"{', '.join(as_list(x.get('supersedes')))} | {', '.join(as_list(x.get('superseded_by')))} |")
        out = Path(a.repo) / a.dir / "INDEX.md"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text("\n".join(rows) + "\n")
        print(f"{len(adrs)} ADR(s) -> {out}")
    else:
        files = a.files or [l.strip() for l in sys.stdin if l.strip()]
        for x in adrs:
            if x.get("status") != "accepted":
                continue
            pats = [glob_re(g) for g in as_list(x.get("affects"))]
            if any(p.match(f) for p in pats for f in files):
                print(x["_path"])


if __name__ == "__main__":
    main()
