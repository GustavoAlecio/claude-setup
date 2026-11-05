---
id: 0014
title: Sessão de org com rótulo opaco no engine e pertença resolvida no app
status: accepted
date: 2026-10-01
affects: ["engine/engine.mjs", "engine/sessions.mjs", "app/lib/data/orgs.dart", "app/lib/features/shell/**", "app/lib/app/router.dart", "app/lib/features/launcher/command_palette.dart"]
supersedes: []
superseded_by: []
tags: [engine, flutter, routing]
---

# 0014 — Sessão de org com rótulo opaco no engine e pertença resolvida no app

## Contexto
Atividades que atravessam vários repos de uma org precisam de uma sessão que enxergue todas as raízes. Orgs são renomeadas e removidas pela tela, e o engine não conhece o `.dashboard.json` do app.

## Decisão
- **Engine:** aceita `{org, cwd, additionalDirectories}`, com paths absolutos e existentes. Trata `org` como rótulo opaco, guarda os diretórios no snapshot e os reaplica no resume. Sobe para a versão 0.2.0.
- **Pertença no app (`sessionOrg` em `orgs.dart`):** a sessão pertence à org de nome igual ao rótulo, se ela existir. Senão, à org que contém o `cwd` (segue renames). Senão, a "Sem org", onde fica alcançável só para leitura.
- **Rotas:** `/o/<org>/…` vivem no mesmo shell, com um `ShellScope` sealed escolhido pelo primeiro segmento, sem `redirect` (ADR 0003).
- **Paleta:** a org vem de uma única função, `paletteOrg`, que alimenta o ⌘⇧K e o menu. Skills do pipeline ficam fora do modo org.

## Alternativas consideradas
- **Engine lendo a config de orgs** — acopla o engine ao app e à tela de Configurações.
- **Sessão de org como projeto sintético** — colide com nomes de projeto e com as regras de "Sem org".
- **Migrar o rótulo das sessões no rename** — exige endpoint novo; resolver pelo `cwd` cobre o caso.

## Consequências
- CLAUDE.md e as settings vêm só da primeira raiz.
- Ciclo Smart Flow multi-repo continua fora; o modo org é para conversa, análise e skills fora do pipeline.

## Relacionados
- [[0007-engine-node-processo-filho]]
- [[0011-resolucao-de-path-de-projeto]]
