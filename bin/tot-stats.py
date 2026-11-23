#!/usr/bin/env python3
"""
Aggregates tot-plan.json across cycles to judge whether the ToT judges earn their cost.

  tot-stats.py [--project NAME] [--list]

Reads active (~/.claude/workflow/*/tot-plan.json) and archived
(~/.claude/projects/*/history/*/tot-plan.json) runs. Runs written before judge
auditing existed only carry winner/totals and feed the outcome section alone.
"""
import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path
from statistics import mean, median

HOME = Path.home() / ".claude"
ANGLES = ("reuse-first", "risk-first", "testability-first")


def angle_of(name):
    hits = [a for a in ANGLES if a in name]
    return hits[0] if len(hits) == 1 else name


def norm_totals(totals):
    """Legacy runs keyed totals by whatever label each judge wrote, splitting one plan's score across keys."""
    out = defaultdict(int)
    for k, v in (totals or {}).items():
        out[angle_of(k)] += v
    return dict(out), len(out) < len(totals or {})


def runs(project):
    globs = [f"workflow/{project or '*'}/tot-plan.json", f"projects/{project or '*'}/history/*/tot-plan.json"]
    for g in globs:
        for p in sorted(HOME.glob(g)):
            try:
                d = json.loads(p.read_text())
            except (json.JSONDecodeError, OSError):
                continue
            # Some early runs stored the raw Workflow envelope instead of its return value.
            if isinstance(d.get("result"), dict):
                d = d["result"]
            if d.get("winner"):
                yield p, d


def label(p):
    parts = p.relative_to(HOME).parts
    return f"{parts[1]}/{parts[3]}" if parts[0] == "projects" else f"{parts[1]} (ativo)"


def pct(a, b):
    return f"{a * 100 // b}%" if b else "n/d"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project")
    ap.add_argument("--list", action="store_true", help="uma linha por run")
    a = ap.parse_args()

    all_runs = list(runs(a.project))
    if not all_runs:
        print("Nenhum tot-plan.json encontrado.")
        return

    wins = Counter()
    margins = []
    tie_breaks = Counter()
    audited = []
    split = misjudged = 0
    for p, d in all_runs:
        totals, was_split = norm_totals(d.get("totals"))
        winner = angle_of(d["winner"])
        wins[winner] += 1
        if was_split:
            split += 1
            if totals and max(totals, key=totals.get) != winner:
                misjudged += 1
        ranked = sorted(totals.values(), reverse=True)
        if len(ranked) >= 2:
            margins.append(ranked[0] - ranked[1])
        if d.get("tie_break"):
            tie_breaks[d["tie_break"]] += 1
        if d.get("judges"):
            audited.append((p, d))

    n = len(all_runs)
    print(f"## Resultado ({n} runs)")
    print("vitórias: " + " · ".join(f"{k} {v} ({pct(v, n)})" for k, v in wins.most_common()))
    if margins:
        close = sum(1 for m in margins if m <= 2)
        print(f"margem 1º→2º: mediana {median(margins)} · ≤2 pontos em {pct(close, len(margins))} · empates {sum(1 for m in margins if m == 0)}")
    if split:
        print(f"placar fragmentado (formato antigo, juízes rotularam diferente): {split} runs · vencedor errado após somar certo: {misjudged}")
    if tie_breaks:
        print("desempates: " + ", ".join(f"{k} {v}" for k, v in tie_breaks.items()))

    if a.list:
        print()
        for p, d in all_runs:
            t, _ = norm_totals(d.get("totals"))
            print(f"- {label(p)}: {angle_of(d['winner'])} {json.dumps(t, ensure_ascii=False)}{' [auditado]' if d.get('judges') else ''}")

    print(f"\n## Juízes ({len(audited)} runs auditados de {n})")
    if not audited:
        print("Sem runs no formato novo ainda — rode /plan com ToT para gerar auditoria.")
        return

    per = defaultdict(lambda: {"runs": 0, "claims": [], "refuted": 0, "zero": 0, "picked_final": 0, "invalid": 0, "partial": 0})
    same, spreads, degraded = [], [], 0
    sug = app = 0
    for _, d in audited:
        degraded += bool(d.get("degraded"))
        ag = d.get("agreement") or {}
        if ag.get("same_winner") is not None:
            same.append(ag["same_winner"])
        spreads += [v for v in (ag.get("total_spread") or {}).values() if v is not None]
        for j in d["judges"]:
            s = per[j["persona"]]
            s["runs"] += 1
            c = j.get("verified_claims") or []
            s["claims"].append(len(c))
            s["refuted"] += sum(1 for x in c if not x.get("holds"))
            s["zero"] += not c
            s["picked_final"] += j.get("winner_angle") == d["winner"]
            s["invalid"] += j.get("invalid_scores", 0)
            s["partial"] += not j.get("scored_all", True)
        ga = d.get("grafts_applied") or []
        sug += len(ga)
        app += sum(1 for g in ga if g.get("applied"))

    for persona, s in per.items():
        tc = sum(s["claims"])
        print(f"- {persona}: {s['runs']} runs · {mean(s['claims']):.1f} verificações/run · refutadas {pct(s['refuted'], tc)} · "
              f"sem verificar {s['zero']} · escolha = vencedor final {pct(s['picked_final'], s['runs'])}"
              + (f" · notas inválidas {s['invalid']} · notas incompletas {s['partial']}" if s["invalid"] or s["partial"] else ""))
    if same:
        print(f"concordância no vencedor: {pct(sum(same), len(same))} · diferença média de nota {mean(spreads):.1f}" if spreads else "")
    print(f"enxertos: {app}/{sug} aplicados ({pct(app, sug)}) · runs degraded: {degraded}")

    print("\n## Sinais")
    flags = []
    if n >= 5 and wins.most_common(1)[0][1] / n >= 0.7:
        flags.append(f"'{wins.most_common(1)[0][0]}' vence {pct(wins.most_common(1)[0][1], n)}: os outros ângulos podem não estar gerando alternativas reais")
    if margins and median(margins) <= 2:
        flags.append("margem mediana ≤2: juízes pouco discriminam entre os planos")
    for persona, s in per.items():
        if s["zero"] / s["runs"] >= 0.5:
            flags.append(f"{persona}: metade+ dos runs sem verificação no código — está julgando texto")
        tc = sum(s["claims"])
        if tc >= 10 and s["refuted"] == 0:
            flags.append(f"{persona}: nenhuma afirmação refutada em {tc} — verificação pode ser decorativa")
    if len(same) >= 5 and all(same) and spreads and mean(spreads) <= 1.5:
        flags.append("juízes sempre concordam com diferença de nota pequena: o segundo juiz parece redundante")
    if sug >= 5 and app / sug < 0.2:
        flags.append("menos de 20% dos enxertos são aplicados: sugestões viram ruído")
    print("\n".join(f"- {f}" for f in flags) if flags else "- nenhum sinal de alerta (amostra pode ser pequena)")


if __name__ == "__main__":
    main()
