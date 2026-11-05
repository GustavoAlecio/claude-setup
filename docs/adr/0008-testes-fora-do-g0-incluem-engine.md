---
id: 0008
title: Testes de workflow, scripts e engine fora do G0
status: accepted
date: 2026-10-01
affects: ["tests/**", "workflows/**", "bin/**", "engine/**"]
supersedes: [0006]
superseded_by: []
tags: [pipeline, testing, engine]
---

# 0008 — Testes de workflow, scripts e engine fora do G0

## Contexto
A ADR 0006 estabelecia que testes de workflow (`.mjs`/`.sh`) ficam fora do campo `tests` porque `gate_g0.py` agrupa por `pubspec.yaml` e rodaria testes falsos. Agora, o engine Node (`engine/**`) também precisa ter seus testes executados fora do G0, pois é um subprojeto com próprio `package.json` e suite de testes em Node.

## Decisão
Testes de `.mjs`, `.sh` e engine Node (`engine/test/*.test.mjs`) não entram no campo `tests` das tasks. A execução é:

1. `bash tests/run.sh` — roda testes de workflow e scripts.
2. `bash tests/run.sh` também roda testes do engine via `node --test '../engine/test/*.test.mjs'` (glob para suportar múltiplos arquivos).

Se `engine/node_modules` não existir, `tests/run.sh` falha com mensagem `rode: cd engine && npm ci`.

A verificação é citada na descrição da task e executada pelo dev-implementer e no G2. O G0 cobre apenas analyze/format de Dart.

## Alternativas consideradas
- **Mapear .mjs/.sh/engine no campo tests** — G0-TEST-FAIL falso; `gate_g0.py` espera `pubspec.yaml`.
- **Stack profile "node" para a raiz** — duplicaria gates num repo de stack principal (Flutter/Dart).
- **`npm ci` automático em `run.sh`** — rede dentro do runner.

## Consequências
- Tasks de workflow, scripts e engine dependem do dev rodar `bash tests/run.sh`; o G0 não cobre estas suites.
- Os gates G0, G1 e G2 se coordenam: `flutter analyze` + `flutter format --dry-run` são automáticos no G0; `bash tests/run.sh` é manual no dev e no G2.
- O engine tem seu próprio `package.json` e `package-lock.json` gerados por `npm install`.

## Relacionados
- [[0006-testes-de-workflow-fora-do-g0]] (supersedida por esta decisão)
- [[0007-engine-node-processo-filho]]
