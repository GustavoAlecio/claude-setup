---
id: 0013
title: Tela Sobre gerada do inventário em disco, com parsers que nunca lançam e claudeHome único
status: accepted
date: 2026-10-01
affects: ["app/lib/data/inventory_parser.dart", "app/lib/data/file_inventory_repository.dart", "app/lib/core/claude_home.dart", "app/lib/features/about/**", "engine/data.mjs"]
supersedes: []
superseded_by: []
tags: [flutter, io, engine]
---

# 0013 — Tela Sobre gerada do inventário em disco, com parsers que nunca lançam e claudeHome único

## Contexto
A tela "Sobre o app" precisa continuar verdadeira quando skills, agentes ou workflows mudam. Os arquivos reais têm frontmatter heterogêneo (blocos `>-`, aspas com `:`, chaves extras) e o `meta` dos workflows é literal JS. O app resolvia `~/.claude` de três jeitos diferentes.

## Decisão
O conteúdo vem de `~/.claude` e do repo do projeto, lido por `FileInventoryRepository`. O código só fixa a ordem das etapas e os vínculos etapa → skill/workflow/agente.
Os parsers ficam puros em `inventory_parser.dart`: um subconjunto de YAML e um mini-parser de literal JS. Eles nunca lançam exceção; entrada ruim vira um item com `error`.
`core/claude_home.dart` é o único lugar que resolve a raiz (`CLAUDE_HOME`, senão o pai de `WORKFLOW_ROOT`, senão `$HOME/.claude`), para inventário, repositório de fluxo e engine.
O `parseFrontmatter` do engine aceita o mesmo subconjunto, para o ⌘K e o Inventário concordarem.

## Alternativas consideradas
- **Página estática** — desatualiza na primeira skill nova.
- **Dependência de YAML/JS parser** — a rule do app proíbe dependência nova sem decisão, e o subconjunto real é pequeno.
- **Importar o workflow em JS** — o script referencia `args`, que não existe fora do runtime.

## Consequências
- Formato fora do subconjunto aparece como "não foi possível ler", sem derrubar a tela.
- A leitura é feita sob demanda ("Recarregar"); não há watcher de `~/.claude`.

## Relacionados
- [[0002-parser-puro-separado-do-io]]
