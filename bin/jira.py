#!/usr/bin/env python3
"""
jira.py — acesso ao Jira Cloud via API token + REST v3 (sem MCP, headless-safe).

Site e email: JIRA_SITE / JIRA_EMAIL do ambiente; sem eles, `orgs[].tracker` (kind jira) da org do repo.
Token: JIRA_API_TOKEN do ambiente, senao ~/.claude/.jira_token (chmod 600). Nunca e impresso.

Comandos:
  get <KEY>              JSON compacto (key, title, type, state, assignee, labels, priority, parent, url)
  desc <KEY>             titulo, tipo, estado e descricao em texto plano (pra alimentar /fix e /specify)
  comment <KEY> <file>   comenta o conteudo do arquivo (texto plano; `-` le do stdin)
"""

import base64
import json
import os
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tracker import default_path, resolve  # noqa: E402


def die(msg):
    print(f"ERRO: {msg}", file=sys.stderr)
    sys.exit(1)


def settings():
    tracker = resolve(default_path())["tracker"] or {}
    if tracker.get("kind") != "jira":
        tracker = {}
    site = os.environ.get("JIRA_SITE") or tracker.get("site")
    email = os.environ.get("JIRA_EMAIL") or tracker.get("email")
    if not site or not email:
        die("sem site/email do Jira: configure o tracker da org no app ou exporte JIRA_SITE e JIRA_EMAIL")
    token = os.environ.get("JIRA_API_TOKEN")
    if not token:
        try:
            with open(os.path.expanduser("~/.claude/.jira_token"), encoding="utf-8") as f:
                token = f.read().strip()
        except FileNotFoundError:
            die("token nao encontrado (JIRA_API_TOKEN nem ~/.claude/.jira_token)")
    return site, base64.b64encode(f"{email}:{token}".encode()).decode()


def call(method, path, body=None):
    site, auth = settings()
    req = urllib.request.Request(
        f"https://{site}/rest/api/3/{path}",
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": f"Basic {auth}", "Accept": "application/json", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            return site, json.load(res)
    except urllib.error.HTTPError as e:
        die(f"Jira {e.code}: {e.read().decode(errors='replace')[:500]}")


def adf_text(node):
    """Texto plano de um documento ADF: paragrafos em linhas, itens de lista com `- `, codigo entre crases."""
    if not isinstance(node, dict):
        return ""
    kind = node.get("type")
    if kind == "text":
        return node.get("text", "")
    if kind == "hardBreak":
        return "\n"
    if kind in ("mention", "emoji"):
        return node.get("attrs", {}).get("text", "")
    if kind == "inlineCard":
        return node.get("attrs", {}).get("url", "")
    inner = "".join(adf_text(c) for c in node.get("content", []))
    if kind == "listItem":
        return "- " + inner.strip() + "\n"
    if kind == "codeBlock":
        return f"```\n{inner}\n```\n\n"
    if kind == "heading":
        return "#" * node.get("attrs", {}).get("level", 2) + " " + inner + "\n\n"
    if kind in ("paragraph", "blockquote"):
        return inner + "\n\n"
    if kind in ("bulletList", "orderedList"):
        return inner + "\n"
    return inner


def issue(key):
    fields = "summary,issuetype,status,assignee,labels,priority,parent,description"
    site, data = call("GET", f"issue/{key}?fields={fields}")
    f = data.get("fields", {})
    return {
        "key": data.get("key"),
        "title": f.get("summary"),
        "type": (f.get("issuetype") or {}).get("name"),
        "state": (f.get("status") or {}).get("name"),
        "assignee": (f.get("assignee") or {}).get("displayName"),
        "labels": f.get("labels") or [],
        "priority": (f.get("priority") or {}).get("name"),
        "parent": (f.get("parent") or {}).get("key"),
        "url": f"https://{site}/browse/{data.get('key')}",
        "description": adf_text(f.get("description")).strip(),
    }


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 1
    cmd, key = argv[0], argv[1].upper()
    if cmd == "get":
        data = issue(key)
        data.pop("description")
        print(json.dumps(data, ensure_ascii=False, indent=2))
    elif cmd == "desc":
        d = issue(key)
        print(f"# {d['title']}\n\nTipo: {d['type']} | Estado: {d['state']}\n\n## Descricao\n{d['description'] or '(vazio)'}")
    elif cmd == "comment":
        if len(argv) < 3:
            die("uso: jira.py comment <KEY> <arquivo|->")
        text = sys.stdin.read() if argv[2] == "-" else open(argv[2], encoding="utf-8").read()
        paragraphs = [p for p in text.strip().split("\n\n") if p.strip()]
        body = {
            "body": {
                "type": "doc",
                "version": 1,
                "content": [{"type": "paragraph", "content": [{"type": "text", "text": p}]} for p in paragraphs],
            }
        }
        _, data = call("POST", f"issue/{key}/comment", body)
        print(json.dumps({"id": data.get("id")}))
    else:
        die(f"comando desconhecido: {cmd}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
