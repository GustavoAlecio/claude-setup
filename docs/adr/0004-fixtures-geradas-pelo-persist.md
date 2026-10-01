---
id: 0004
title: Fixtures geradas pelo persist real com checagem de drift
status: proposed
date: 2026-10-01
affects: ["app/test/fixtures/**", "tests/run.sh"]
supersedes: []
superseded_by: []
tags: [testing]
---

# 0004 — Fixtures geradas pelo persist real com checagem de drift

## Contexto
O repo é público e os dados reais de `~/.claude/workflow` são privados. O formato de `result.json` vem do `wf-event.py persist` e pode mudar.

## Decisão
`app/test/fixtures/gen.sh` roda `bin/wf-event.py persist` (com HOME shim) sobre JSON sintéticos e commita a árvore gerada. `gen.sh --check` regenera num tmp e falha com diff; roda dentro de `tests/run.sh`.

## Alternativas consideradas
- **JSON escrito à mão** — diverge do persist sem ninguém perceber.
- **Rodar os workflows reais com agentes roteirizados** — acopla fixtures à sequência de `agent()`.

## Consequências
- Mudança no persist quebra o `tests/run.sh` até as fixtures serem regeneradas.
