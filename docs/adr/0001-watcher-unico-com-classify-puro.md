---
id: 0001
title: Fonte reativa do app com um único watcher e classificação pura
status: accepted
date: 2026-10-01
affects: ["app/lib/data/file_flow_repository.dart", "app/lib/data/workflow_parser.dart"]
supersedes: []
superseded_by: []
tags: [flutter, io, realtime]
---

# 0001 — Fonte reativa do app com um único watcher e classificação pura

## Contexto
O app precisa refletir em ≤ 1 s mudanças em `~/.claude/workflow/` (current.json trocado via `os.replace`, linhas anexadas em `events.jsonl`). FSEvents entrega rajadas, eventos de `.current.json.lock` a cada leitura e caminhos `/private/var/...` para diretórios temporários.

## Decisão
Um único `Directory.watch(recursive: true)` sobre a raiz canônica (`resolveSymbolicLinksSync`) alimenta um snapshot `List<Project>`. Cada evento passa por `classify(root, path, destination)` — função pura que ignora segmentos iniciados por `.`, `*.tmp` e `*.lock`, usando o `destination` em moves — e por debounce de 300 ms. Só o projeto afetado é relido; reloads do mesmo projeto são serializados num `Future` encadeado. `watchProject`/`watchRun` derivam do snapshot.

## Alternativas consideradas
- **Um watcher por projeto/run** — N assinaturas FSEvents e estado duplicado.
- **Polling por mtime** — latência e CPU constantes no limite de 1 s.
- **package:watcher / rxdart** — dependência nova sobre o mesmo FSEvents.
- **Filtrar pelo path de origem do move** — perde o `current.tmp → current.json`.

## Consequências
- `classify` é testável com caminhos literais, sem disco.
- `.dashboard.json` (na raiz, com ponto) não dispara reload — limitação conhecida, follow-up.

## Relacionados
- [[0002-parser-puro-separado-do-io]]
