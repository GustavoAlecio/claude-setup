---
id: 0020
title: Relatório de ciclo por contrato, escrito só pelo wf-report.py e lido pelo app
status: accepted
date: 2026-10-02
affects: ["bin/wf-report.py", "bin/current_json.py", "bin/archive-cycle.sh", "skills/*/SKILL.md", "app/lib/data/report_parser.dart", "app/lib/data/flow_aggregates.dart", "app/lib/features/flow/**"]
supersedes: []
superseded_by: []
tags: [workflow, flutter, skills]
---

# 0020 — Relatório de ciclo por contrato, escrito só pelo wf-report.py e lido pelo app

## Contexto
O resultado de cada etapa do Fluxo Smart existia só nos transcripts das sessões e em arquivos dispersos (`current.json`, `result.json`). O usuário quer acompanhar o ciclo no app como acompanhou no terminal: resumo por etapa, decisões (inclusive erros), achados do challenger, tasks e verify. Também quer intervir pouco.

## Decisão
- **Contrato:** `$WF_DIR/report.json` versionado (`version: 1`), com no máximo uma entrada por etapa (enum fixo), escrito só por `bin/wf-report.py`.
- **Escrita:** atômica com lock (`update_json`). A identidade do ciclo (`start_date` + `feature`) arquiva o relatório anterior quando diverge. Subcomandos idempotentes. Textos só via arquivo, nunca interpolados em shell.
- **Origem dos dados:** dados determinísticos (decisões dos agentes, escaladas, backtracks e blockers, `challenge`) vêm do `import-run` sobre `result.json`. Decisões livres do orquestrador são best-effort.
- **Quem escreve:** as skills do pipeline chamam o script. Workflows nunca chamam.
- **App:** lê o relatório com teto de 2 MB e parse puro. Mostra linha do tempo, painéis e fallback quando não há relatório. O relatório do histórico fica em Métricas.

## Alternativas consideradas
- **App montando o relatório só a partir dos arquivos existentes** — perde a narrativa e as decisões do orquestrador.
- **Skills escrevendo JSON diretamente** — sem atomicidade, identidade de ciclo nem dedup, e com risco de interpolação em shell.

## Consequências
- Ciclos antigos ficam sem relatório (fallback).
- A completude das decisões livres depende do modelo; as determinísticas não.
- Gates no Fluxo (3g.2) e fechamento com PR (3g.3) se apoiam neste contrato.

## Relacionados
- [[0004-fixtures-geradas-pelo-persist]]
- [[0013-inventario-lido-do-disco]]
