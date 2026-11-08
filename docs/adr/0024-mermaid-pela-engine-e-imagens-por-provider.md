---
id: 0024
title: Mermaid renderizado pela engine com o Chrome local e imagens anexadas por provider
status: accepted
date: 2026-10-06
affects: ["engine/mermaid.mjs", "engine/engine.mjs", "engine/sessions.mjs", "engine/package.json", "engine/.puppeteerrc.cjs", "app/lib/core/widgets/mermaid_block.dart", "app/lib/core/widgets/markdown_view.dart", "app/lib/core/platform/clipboard_image.dart", "app/macos/Runner/AppDelegate.swift", "app/lib/features/sessions/session_view.dart"]
supersedes: []
superseded_by: []
tags: [engine, flutter, markdown]
---

# 0024 — Mermaid renderizado pela engine com o Chrome local e imagens anexadas por provider

## Contexto
- **Mermaid.** Os agentes escrevem diagramas em blocos ```` ```mermaid ````, e o renderer próprio do app (ADR 0015) só mostrava o código. O mermaid precisa de um DOM.
- **Imagens.** A mensagem precisa levar imagens. O Claude Agent SDK aceita blocos de imagem. Já o stream-json do `agy` recusa qualquer bloco que não seja texto ("only text"), mas a tool `view_file` dele lê imagens de arquivo.

## Decisão
- **Mermaid.**
  - `POST /api/mermaid {code, theme}` devolve um PNG em 2x. O `@mermaid-js/mermaid-cli` roda num Chrome já instalado (`CHROME_PATH` ou `/Applications`). O Chromium do puppeteer não é baixado (`.puppeteerrc.cjs`).
  - Um único Chrome headless serve um render por vez e fecha depois de 5 min parado.
  - Cache em disco pela hash de estilo, tema e texto. Paletas do app no tema `base`, mais CSS do gantt.
  - Sintaxe inválida é 422 com a mensagem do mermaid; sem Chrome, 501.
  - No app, o `MermaidBlock` mostra a imagem com alternância para o código e cai no código quando não há engine, durante o render ou em erro.
- **Imagens.**
  - O composer anexa por ⌘V, via canal `claude_flow/clipboard` no `AppDelegate`, porque o `Clipboard` do Flutter só lê texto. Também anexa pelo seletor do `file_selector`.
  - Limites: até 6 imagens de até 5 MB, em PNG, JPEG, GIF ou WebP, validados no app e na engine.
  - A engine guarda os anexos em `<sessionsDir>/attachments/<sessão>/` e os serve para o histórico. O evento `user_text` leva os nomes.
  - O Claude recebe blocos de imagem. O `agy` recebe os caminhos no texto e os abre com `view_file`, que o gate libera como leitura (ADR 0023).

## Alternativas consideradas
- **mermaid.ink e similares.** Mandam o conteúdo para fora da máquina.
- **WebView no app ou renderer mermaid em Dart.** Exigem dependência nova no app ou reimplementar o mermaid.
- **Chromium do puppeteer.** São ~170 MB para algo que o Chrome instalado já faz.
- **Arrastar e soltar imagem.** Precisa de handler nativo de drop. Fica para depois.

## Consequências
- Máquina sem Chrome, Edge, Brave ou Chromium mostra o mermaid como código.
- O primeiro diagrama após o Chrome fechar leva ~1–5 s. Os seguintes, centenas de ms; os repetidos vêm do cache.
- Anexos somem junto com a sessão.

## Relacionados
- [[0015-markdown-parser-e-renderer-proprio]]
- [[0023-provider-antigravity-com-gate-por-hook-e-home-sombra]]
