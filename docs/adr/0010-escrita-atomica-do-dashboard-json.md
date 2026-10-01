---
id: 0010
title: Escrita do .dashboard.json por mutação pura sobre o mapa cru, atômica e serializada
status: accepted
date: 2026-10-01
affects: ["app/lib/data/config_mutations.dart", "app/lib/data/dashboard_config_repository.dart", "app/lib/data/flow_repository.dart", "app/lib/features/settings/**"]
supersedes: []
superseded_by: []
tags: [flutter, io, config]
---

# 0010 — Escrita do .dashboard.json por mutação pura sobre o mapa cru, atômica e serializada

## Contexto
O `.dashboard.json` é lido e escrito também pelo engine e pelas skills, com chaves que o app não conhece (`cwds`, `engineDir`, `nodePath`, `paletteSkills`). A tela grava em rajadas (trocar org, ocultar, renomear).

## Decisão
Toda escrita passa por `FlowRepository.updateConfig(ConfigMutation)`. `FileDashboardConfigRepository` é o único writer: relê o disco, aplica a mutação pura (de `config_mutations.dart`) ao `Map` cru preservando chaves e ordem, não grava se nada mudou e grava `.dashboard.json.tmp` + rename, com escritas numa cadeia de `Future`. Mutações derivam o estado do mapa relido, nunca do snapshot da UI. `ConfigWriteException` e `applyConfigMutation` ficam no módulo puro.

## Alternativas consideradas
- **Round-trip tipado via `toJson`** — perde chaves desconhecidas.
- **Lock de arquivo** — engine e web não o respeitam.
- **Widget gravando direto e esperando o watcher** — lost update entre cliques.

## Consequências
- Widgets não importam o módulo com `dart:io`.
- O writer não atômico de `web/server/cwd.mjs` continua sendo risco conhecido.

## Relacionados
- [[0009-watcher-unico-com-config-reativa]]
