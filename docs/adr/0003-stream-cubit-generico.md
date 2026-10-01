---
id: 0003
title: Estado de UI com StreamCubit genérico e router que não lê o repositório
status: proposed
date: 2026-10-01
affects: ["app/lib/core/bloc/**", "app/lib/app/**", "app/lib/features/**"]
supersedes: []
superseded_by: []
tags: [flutter, state]
---

# 0003 — Estado de UI com StreamCubit genérico e router que não lê o repositório

## Contexto
O `FlowRepository` passou de síncrono para streams. O router lia `projects().first` na construção, o que quebra com fonte assíncrona ou raiz vazia.

## Decisão
`StreamCubit<T> extends Cubit<AsyncSnapshot<T>>`, instanciado para projetos (acima do `MaterialApp.router`), projeto e run. Loading renderiza vazio, sem spinner animado. A rota `/` é um landing que navega para o projeto mais recente ou mostra estado vazio; o router não lê o repositório. `repositoryFromEnvironment()` (REPO/WORKFLOW_ROOT) atende `main.dart` e `test_driver/app.dart`.

## Alternativas consideradas
- **Três Cubits sob medida com estado sealed** — cerimônia para loading/data/null.
- **StreamBuilder direto nas telas** — fere "um Cubit por stream".
- **redirect + refreshListenable no GoRouter** — acopla router ao repositório.

## Consequências
- Telas sem stream não ganham BLoC.
- Modelos sem `==` reconstroem a tela do projeto a cada reload (risco aceito).
