---
id: 0005
title: App macOS sem App Sandbox
status: accepted
date: 2026-10-01
affects: ["app/macos/Runner/*.entitlements"]
supersedes: []
superseded_by: []
tags: [macos, security]
---

# 0005 — App macOS sem App Sandbox

## Contexto
O app lê `~/.claude/workflow`, `~/.claude/stacks` e roda `git -C` em repos arbitrários do usuário. É ferramenta local, sem distribuição pela App Store.

## Decisão
Remover `com.apple.security.app-sandbox` de `DebugProfile.entitlements` e `Release.entitlements`, sem adicionar outras chaves ao Release.

## Alternativas consideradas
- **temporary-exception.files.home-relative-path** — não libera `Process.run` nem os repos dos projetos.
- **Security-scoped bookmarks com seletor de pasta** — atrito e estado persistente para cada repo.

## Consequências
- O app não pode ir para a App Store sem rever esta decisão.
- Assinatura/notarização ficam fora de escopo enquanto for uso local.
