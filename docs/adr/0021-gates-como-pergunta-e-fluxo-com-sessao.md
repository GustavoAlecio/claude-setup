---
id: 0021
title: Gates do Fluxo como AskUserQuestion decididos por wf-report.py, respondidos no Fluxo com a sessão embutida
status: accepted
date: 2026-10-02
affects: ["bin/wf-report.py", "skills/*/SKILL.md", "engine/sessions.mjs", "app/lib/features/flow/**", "app/lib/features/sessions/session_view.dart", "app/lib/data/flow_aggregates.dart", "app/lib/data/session_reducer.dart"]
supersedes: []
superseded_by: []
tags: [workflow, skills, flutter, engine]
---

# 0021 — Gates do Fluxo como AskUserQuestion decididos por wf-report.py, respondidos no Fluxo com a sessão embutida

## Contexto
O usuário quer intervir só nos pontos que importam e responder sem sair do Fluxo. Antes, com piloto off, as skills paravam com texto de fim de turno, e o app não enxergava essas paradas. As perguntas existentes só apareciam na aba Sessões.

## Decisão
- **Quando parar:** `wf-report.py gate <spec|plan|tasks|pr>` decide de forma determinística (piloto off → sempre; piloto on → `gates.json`, padrão spec e pr). As skills nunca leem o `gates.json`.
- **Como parar:** todo gate é `AskUserQuestion` com Aprovar, Ajustar e Rejeitar. Paradas de risco (bloqueante do challenger, backtrack/blocked, branch existente, base `release/*`, reset, push) são incondicionais.
- **Ligação sessão → relatório:** o engine injeta `CLAUDE_FLOW_SESSION_ID` e as skills gravam o `session_id` da etapa.
- **Fluxo:** a tela fica dividida, com a linha do tempo à esquerda e a sessão da etapa embutida à direita (`SessionPanel`). A seleção vai por etapa (`?stage=`), e o card "Aguardando você" fica no topo do painel.
- **Regras puras:** "viva" e "interrompida" ficam em `isLive` e `showsInterrupted`.

## Alternativas consideradas
- **Mecanismo de aprovação novo no engine** — duplicaria o que o `AskUserQuestion` e o `canUseTool` já entregam.
- **Skills lendo `gates.json` direto** — decisão não determinística e difícil de testar.
- **Selecionar por sessão na URL** — várias etapas compartilham a mesma sessão, e o destaque ficaria errado.

## Consequências
- Com piloto off, cada etapa para em card, inclusive specify, que encadeia o challenge sem perguntar.
- O status "interrompida" é derivado do stream da sessão, o que abre uma conexão SSE por sessão `idle` listada. Trazer o campo do engine fica para depois.

## Relacionados
- [[0019-modo-de-permissao-por-sessao]]
- [[0020-relatorio-de-ciclo-por-contrato]]
