---
id: 0022
title: Identidade de ciclo progressiva e sessão pelo ambiente no wf-report.py
status: accepted
date: 2026-10-02
affects: ["bin/wf-report.py", "skills/kickoff/SKILL.md", "app/lib/data/workflow_parser.dart"]
supersedes: []
superseded_by: []
tags: [workflow, skills, flutter]
---

# 0022 — Identidade de ciclo progressiva e sessão pelo ambiente no wf-report.py

## Contexto
Na primeira run real pelo app (card 7579), todas as etapas ficaram sem `session_id` e a etapa kickoff sumiu. O modelo reescreveu os comandos das skills e descartou o `${CLAUDE_FLOW_SESSION_ID:+--session ...}`. O `stage-start kickoff` rodou antes de o `current.json` ter `feature`/`start_date`; quando a identidade apareceu, a ADR 0020 mandava arquivar, e o relatório virou `report.unknown.json`.

## Decisão
- **Sessão:** o `wf-report.py` lê `CLAUDE_FLOW_SESSION_ID` do ambiente quando `--session` não vem, no `stage-start` e em toda etapa nova criada por outro subcomando. `--session` explícito prevalece.
- **Identidade progressiva** (refina o item de identidade da 0020): o relatório é adotado quando cada campo do seu `cycle` é nulo ou igual ao do ciclo atual; o `cycle` passa a ser o do `current.json`. Campo com valor no relatório e nulo ou diferente no atual continua sendo conflito e arquiva.
- **Kickoff:** os seeds removem `feature`, `start_date`, `end_date` e `phases` antes do update, para não herdar a identidade de um ciclo anterior ainda não arquivado.
- **App:** a etapa do projeto é a maior entre o `status` e a etapa `running` do relatório, só quando o `cycle` do relatório é compatível pela mesma regra.

## Alternativas consideradas
- **Confiar no texto da skill** (manter só o `--session` no comando) — falhou em 100% das etapas da run 7579.
- **Relaxar a identidade sempre** (nunca arquivar) — misturaria ciclos diferentes num relatório.

## Consequências
- Etapas registradas fora do app (terminal) continuam sem sessão, como antes.
- A 0020 segue valendo; este registro só refina quando a identidade diverge.

## Relacionados
- [[0020-relatorio-de-ciclo-por-contrato]]
- [[0021-gates-como-pergunta-e-fluxo-com-sessao]]
