#!/usr/bin/env python3
"""
Aggregates escalation outcomes across runs and suggests tier0 overrides.

  routing-stats.py [--project NAME] [--write]

Reads result.json from active runs (~/.claude/workflow/*/runs/*) and archived ones
(~/.claude/projects/*/history/*/runs/*). With --write, stores suggestions in
~/.claude/projects/<project>/routing.json, which /tasks consults.
"""
import argparse
import json
from collections import defaultdict
from pathlib import Path

HOME = Path.home() / ".claude"
LADDER = ["haiku", "sonnet", "opus", "fable"]
MIN_SAMPLES = 5


def results(project):
    globs = [f"workflow/{project or '*'}/runs/*/result.json", f"projects/{project or '*'}/history/*/runs/*/result.json"]
    for g in globs:
        for p in HOME.glob(g):
            try:
                yield json.loads(p.read_text())
            except (json.JSONDecodeError, OSError):
                continue


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project")
    ap.add_argument("--write", action="store_true")
    a = ap.parse_args()

    stats = defaultdict(lambda: {"n": 0, "first_tier_pass": 0, "attempts": 0, "escalated": 0, "blocked": 0, "final": defaultdict(int)})
    for r in results(a.project):
        for t in r.get("tasks", []):
            if t.get("status") not in ("done", "blocked"):
                continue
            key = (t.get("complexity", "?"), "high" if t.get("risk") == "high" else "low")
            s = stats[key]
            s["n"] += 1
            s["attempts"] += t.get("attempts", 0)
            esc = len(t.get("escalations", []))
            s["escalated"] += 1 if esc else 0
            s["first_tier_pass"] += 1 if t.get("status") == "done" and not esc else 0
            s["blocked"] += 1 if t.get("status") == "blocked" else 0
            s["final"][t.get("tier", "?")] += 1

    if not stats:
        print("sem dados de runs ainda")
        return

    print("| complexidade | risco | n | passou no tier0 | escalou | bloqueou | tentativas/task | tier final |")
    print("|---|---|---|---|---|---|---|---|")
    suggestions = {}
    for (cx, risk), s in sorted(stats.items()):
        rate = s["first_tier_pass"] / s["n"]
        print(f"| {cx} | {risk} | {s['n']} | {rate:.0%} | {s['escalated']} | {s['blocked']} | "
              f"{s['attempts'] / s['n']:.1f} | {dict(s['final'])} |")
        if s["n"] >= MIN_SAMPLES and rate < 0.5:
            dominant = max(s["final"], key=s["final"].get)
            if dominant in LADDER:
                suggestions[f"{cx}:{risk}"] = {"tier0": dominant, "reason": f"tier0 passou em {rate:.0%} de {s['n']} tasks"}

    if suggestions:
        print("\nSugestões de tier0:", json.dumps(suggestions, ensure_ascii=False, indent=2))
    if a.write and a.project:
        out = HOME / "projects" / a.project / "routing.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps({"overrides": suggestions}, indent=2, ensure_ascii=False))
        print(f"gravado em {out}")


if __name__ == "__main__":
    main()
