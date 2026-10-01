---
id: 0015
title: Parser markdown do pacote markdown com renderer próprio, sem flutter_markdown nem url_launcher
status: accepted
date: 2026-10-01
affects: ["app/lib/core/widgets/markdown_view.dart", "app/pubspec.yaml"]
supersedes: []
superseded_by: []
tags: [flutter, dependencies]
---

# 0015 — Parser markdown do pacote markdown com renderer próprio, sem flutter_markdown nem url_launcher

## Contexto
As abas de artefatos e reviews precisam renderizar markdown GFM (tabelas, checkbox, URL nua, código) de forma selecionável. O `InlineMarkdown` cobre só parágrafos, `- `, negrito e código.

## Decisão
- Dependência nova: `markdown` (dart-lang), só o parser. `Document(extensionSet: ExtensionSet.gitHubFlavored, encodeHtml: false)`.
- Renderer próprio em `MarkdownView`: converte o AST em widgets dentro de um `SelectionArea`, com cores de `context.colors`. HTML e nós desconhecidos viram texto literal; imagem vira o alt.
- `MarkdownView` não decide o destino dos links: cada toque chama `onLink(Uri)` e quem chama aplica a política de schemes.
- Sem `flutter_markdown` e sem `url_launcher`: abrir links é responsabilidade do repositório de docs.

## Alternativas consideradas
- **flutter_markdown** — descontinuado, estilo próprio difícil de alinhar ao tema e abre links por conta própria.
- **url_launcher** — traz plugin nativo para algo que `open` do macOS resolve (ADR 0005, sem sandbox).

## Consequências
- Elementos novos de markdown exigem código no renderer; fica limitado ao que a spec lista.
- Diagramas mermaid aparecem como bloco de código com rótulo.

## Relacionados
- [[0005-app-macos-sem-sandbox]]
- [[0013-inventario-lido-do-disco]]
