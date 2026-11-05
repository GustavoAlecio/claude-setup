---
id: 0009
title: Watcher único com classificação pura, incluindo a config do dashboard
status: accepted
date: 2026-10-01
affects: ["app/lib/data/file_flow_repository.dart", "app/lib/data/workflow_parser.dart", "app/lib/data/orgs.dart"]
supersedes: ["0001"]
superseded_by: []
tags: [flutter, io, realtime]
---

# 0009 — Watcher único com classificação pura, incluindo a config do dashboard

## Contexto
O 0001 deixou o `.dashboard.json` fora do watcher. Com orgs, projetos registrados e `lastOrg` gravados pela tela, a config muda a cada ⌘N, ocultar ou criar org, e precisa refletir no app sem reler git e stack de todos os projetos a cada escrita.

## Decisão
Mantém o `Directory.watch` único e o `classify` puro do 0001, que passa a devolver `ConfigScope` para `.dashboard.json`. Um `diffConfig` puro decide entre reemitir (só `lastOrg`/`orgs`/`hidden`), refazer a varredura de paths (mudou o conjunto de raízes) ou recarregar (`projects`/`cwds`). Recargas da raiz e mudanças de config rodam numa única cadeia serializada, para um scan lento não sobrescrever uma config mais nova. Após `updateConfig` com sucesso o repositório emite a config gravada; o eco do FSEvents é no-op por comparar o conteúdo lido com o já aplicado.

## Alternativas consideradas
- **Segundo watcher só para o arquivo** — duas fontes de evento para o mesmo snapshot.
- **RootScope sempre** — reload completo a cada clique.
- **Contador de geração descartando resultado obsoleto** — não cobre config e índice de varredura juntos.

## Consequências
- A UI não depende do eco do FSEvents para refletir a própria escrita.
- Projetos anotados saem antes da config no rescan, no mesmo bloco síncrono.

## Relacionados
- [[0001-watcher-unico-com-classify-puro]]
- [[0010-escrita-atomica-do-dashboard-json]]
