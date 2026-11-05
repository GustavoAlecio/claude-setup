---
id: 0006
title: Testes de workflow e scripts fora do G0
status: superseded
date: 2026-10-01
affects: ["tests/**", "workflows/**", "bin/**"]
supersedes: []
superseded_by: [0008]
tags: [pipeline, testing]
---

# 0006 — Testes de workflow e scripts fora do G0

## Contexto
O `gate_g0.py` agrupa testes pelo `pubspec.yaml` mais próximo e roda `flutter test`. Arquivos `.mjs`/`.sh` na raiz dariam falha falsa e queimariam a escada.

## Decisão
`tests/*.mjs` e `tests/*.sh` não entram no campo `tests` das tasks. A verificação é `bash tests/run.sh`, citada na descrição da task e executada pelo dev-implementer e no G2.

## Alternativas consideradas
- **Mapear .mjs/.sh no campo tests** — G0-TEST-FAIL falso.
- **Stack profile "node" para a raiz** — duplicaria gates num repo de uma stack principal.

## Consequências
- Tasks de workflow/script dependem do dev rodar `tests/run.sh`; o G0 só cobre analyze/format de Dart.
