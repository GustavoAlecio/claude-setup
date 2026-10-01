---
id: 0002
title: Parser puro separado do IO e modelos escritos à mão
status: proposed
date: 2026-10-01
affects: ["app/lib/data/workflow_parser.dart", "app/lib/data/models.dart"]
supersedes: []
superseded_by: []
tags: [flutter, parsing]
---

# 0002 — Parser puro separado do IO e modelos escritos à mão

## Contexto
Os arquivos lidos (current.json, result.json, events.jsonl) têm schema externo, parcial e com formato legado convivendo com o novo. Runs de verify repetem `attempt` entre rounds.

## Decisão
`workflow_parser.dart` concentra funções puras (`stageOf`, `parseCycle`, `parseResultRun`, `parseEventsRun`, `decodeJsonl`, `classify`, `formatStartedAt(utc, now)`) que mapeiam direto para os modelos existentes. Modelos ganham campos nullable, `Attempt.ordinal` (1..N na task, chave de "repetido/igual à") e `Attempt.label` (`#n` ou `r<round> #<m>`), e `Run.gates`. Sem freezed/json_serializable.

## Alternativas consideradas
- **Parse dentro do repositório** — força disco em todo teste.
- **freezed/json_serializable** — codegen não paga para schema externo e parcial.
- **DTO + mapper** — duplica modelos para um único consumidor.

## Consequências
- Todas as regras de negócio viram testes unitários de string/map.
- O relógio só entra como parâmetro de `formatStartedAt`.

## Relacionados
- [[0001-watcher-unico-com-classify-puro]]
