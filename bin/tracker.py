#!/usr/bin/env python3
"""
Tracker de cards da org de um repositorio, lido de `orgs[].tracker` no ~/.claude/workflow/.dashboard.json.

A org de um path segue a regra do app (`launchOrg` em orgs.dart): `projects[]` com o mesmo path e `org`, senao a
primeira org cuja raiz contem o path.

Uso:
  tracker.py resolve [path]      {"org": <nome|null>, "tracker": <config|null>}
  tracker.py ref <id> [path]     {"kind", "id", "url"} do card; exit 2 se o ID nao serve para o tracker
  tracker.py env [path]          exports para o ado.sh (ADO_ORG/ADO_PROJECT); vazio para outros trackers

`path` padrao: raiz git do cwd, senao o cwd.

Config por tipo:
  ado     {"kind": "ado", "org": "...", "project": "...", "base": "release"}
  jira    {"kind": "jira", "site": "x.atlassian.net", "project": "LC", "email": "...", "base": "release"}
  linear  {"kind": "linear", "team": "LC", "workspace": "..."}
`base: "release"` = branch a partir da ultima release/* do remoto; ausente = branch padrao do remoto.
"""

import json
import os
import re
import shlex
import subprocess
import sys
from urllib.parse import quote

KINDS = ("ado", "jira", "linear")
NUMERIC = re.compile(r"^\d+$")
KEYED = re.compile(r"^[A-Z][A-Z0-9]*-\d+$")


def config_path():
    home = os.environ.get("CLAUDE_HOME") or os.path.expanduser("~/.claude")
    return os.path.join(home, "workflow", ".dashboard.json")


def load_config():
    try:
        with open(config_path(), encoding="utf-8") as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def default_path():
    try:
        out = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True)
        return out.stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return os.getcwd()


def canonical(path):
    return os.path.realpath(os.path.expanduser(path)).rstrip("/") or "/"


def contains(root, path):
    return path == root or path.startswith(root.rstrip("/") + "/")


def org_of(path, config):
    orgs = [o for o in config.get("orgs") or [] if isinstance(o, dict) and o.get("name")]
    names = {o["name"] for o in orgs}
    here = canonical(path)
    for p in config.get("projects") or []:
        if isinstance(p, dict) and p.get("path") and canonical(p["path"]) == here and p.get("org") in names:
            return p["org"]
    for o in orgs:
        for root in o.get("roots") or []:
            if isinstance(root, str) and root and contains(canonical(root), here):
                return o["name"]
    return None


def tracker_of(org, config):
    for o in config.get("orgs") or []:
        if isinstance(o, dict) and o.get("name") == org:
            t = o.get("tracker")
            return t if isinstance(t, dict) and t.get("kind") in KINDS else None
    return None


def resolve(path):
    config = load_config()
    org = org_of(path, config)
    return {"org": org, "tracker": tracker_of(org, config) if org else None}


def normalize_id(raw, tracker):
    """`#123` → `123`, `lc-101` → `LC-101`; numerico vira `<project|team>-<n>` em Jira/Linear quando ha prefixo."""
    card = raw.strip().lstrip("#").upper()
    if tracker["kind"] == "ado":
        return card if NUMERIC.match(card) else None
    if KEYED.match(card):
        return card
    prefix = tracker.get("project") if tracker["kind"] == "jira" else tracker.get("team")
    return f"{prefix.upper()}-{card}" if NUMERIC.match(card) and prefix else None


def card_url(card, tracker):
    kind = tracker["kind"]
    if kind == "ado" and tracker.get("org") and tracker.get("project"):
        return f"https://dev.azure.com/{quote(tracker['org'])}/{quote(tracker['project'])}/_workitems/edit/{card}"
    if kind == "jira" and tracker.get("site"):
        return f"https://{tracker['site']}/browse/{card}"
    if kind == "linear" and tracker.get("workspace"):
        return f"https://linear.app/{tracker['workspace']}/issue/{card}"
    return None


def main(argv):
    if not argv:
        print(__doc__.strip(), file=sys.stderr)
        return 1
    cmd, rest = argv[0], argv[1:]
    if cmd == "resolve":
        print(json.dumps(resolve(rest[0] if rest else default_path()), ensure_ascii=False))
        return 0
    if cmd == "ref":
        if not rest:
            print("uso: tracker.py ref <id> [path]", file=sys.stderr)
            return 1
        resolved = resolve(rest[1] if len(rest) > 1 else default_path())
        tracker = resolved["tracker"]
        if tracker is None:
            print(f"sem tracker configurado para a org {resolved['org'] or '(nenhuma)'}", file=sys.stderr)
            return 2
        card = normalize_id(rest[0], tracker)
        if card is None:
            print(f"ID {rest[0]!r} nao e um card de {tracker['kind']}", file=sys.stderr)
            return 2
        print(json.dumps({"kind": tracker["kind"], "id": card, "url": card_url(card, tracker)}, ensure_ascii=False))
        return 0
    if cmd == "env":
        tracker = resolve(rest[0] if rest else default_path())["tracker"]
        if tracker and tracker["kind"] == "ado":
            for var, key in (("ADO_ORG", "org"), ("ADO_PROJECT", "project")):
                if tracker.get(key):
                    print(f"export {var}={shlex.quote(tracker[key])}")
        return 0
    print(f"comando desconhecido: {cmd}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
