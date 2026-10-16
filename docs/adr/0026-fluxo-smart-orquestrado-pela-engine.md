---
id: 0026
title: Fluxo Smart orquestrado pela engine, com escada de modelos por provider
status: proposed
date: 2026-10-07
affects: ["engine/**", "workflows/*.js", "skills/implement/SKILL.md", "skills/verify/SKILL.md", "skills/plan/SKILL.md", "tests/harness.mjs", "app/lib/features/runs/**"]
supersedes: []
superseded_by: []
tags: [engine, agents, workflow]
---

# 0026 — Fluxo Smart orquestrado pela engine, com escada de modelos por provider

## Contexto
`smart-implement`, `smart-verify` e `tot-plan` rodam no Workflow tool do Claude Code. As skills `/implement`, `/verify` e `/plan` chamam esse tool. Por isso, toda skill roda em Anthropic (ADR 0023), e uma org em Antigravity só tem conversa livre.

Os scripts usam pouca API: `agent(prompt, {model, agentType, schema, effort, label, phase})`, `parallel`, `phase`, `log` e `args`. O `tests/harness.mjs` já carrega cada workflow como função comum, com `agent` injetado, e o `tests/ladder.test.mjs` cobre a escada inteira assim. A orquestração não depende do Claude Code, só a execução de cada `agent()`.

## Decisão (proposta)
- **Runner na engine.** `engine/workflows.mjs` executa os mesmos `workflows/*.js` pelo mesmo mecanismo do harness. O `agent()` vira uma sessão filha da engine no provider da org, com `canUseTool`, modo de permissão e registro no `run_dir` iguais aos de hoje. As filhas aparecem no app sob a sessão que disparou o run.
- **Escada por provider.** Os tiers `haiku → sonnet → opus → fable` continuam nos scripts. A engine traduz o tier para o modelo do provider. A tabela fica em `orgs[].agent.ladder`, com um padrão por provider; no Antigravity, por exemplo, do Flash ao Claude Opus. O tier de cada papel continua no script.
- **Papéis.** `agentType` carrega `agents/<nome>.md` como system prompt nos dois providers. No Antigravity, o adapter recebe esse texto como primeira mensagem, porque o `agy` não tem system prompt.
- **Saída estruturada.** No Claude, `outputFormat` com o `schema`. No `agy`, o prompt pede JSON e a engine valida contra o `schema`, com uma tentativa de reparo. JSON inválido vira `null`, como no Workflow tool, e o script já trata `null`.
- **Entrada.** `POST /api/workflows/run {name, args, org}` devolve o id do run, e o progresso sai pelo SSE da sessão. As skills passam a chamar esse endpoint por `bin/wf-run.py` em qualquer provider, para existir um caminho só.
- **Rollout.**
  1. Runner só com Claude, com paridade contra o Workflow tool na suíte da escada.
  2. Mapeamento Antigravity.
  3. Troca das skills. Até o passo 3, o Workflow tool segue funcionando.

## Alternativas consideradas
- **Manter o Workflow tool.** O Fluxo fica preso ao Claude Code, e as orgs em Antigravity não têm Fluxo.
- **LangGraph.** Traz checkpointing e grafo explícito, mas troca a escada já testada por um framework Python novo. Também foi descartado na comparação de 2026-10-07.
- **Orquestrar em Python no `bin/`.** Duplica o que a engine já sabe fazer: sessões, gate, SSE, tokens e custo.

## Consequências
- A engine vira orquestradora de runs longos. Um run precisa sobreviver a um restart da engine, retomando do `events.jsonl` do `run_dir` como o `wf-report.py` já faz para o relatório.
- O custo por run passa a ser soma exata das filhas, o que alimenta o orçamento por ciclo.
- A qualidade dos gates depende do modelo do provider. O padrão sugerido mantém G1 e o diagnóstico ToT no tier `opus` mapeado para Claude Opus via Antigravity.
- No `agy`, as regras do projeto só valem com `AGENTS.md` (ADR 0023). O runner pode injetar `.claude/rules` no prompt do papel para não depender disso.
- O Workflow tool deixa de ser dependência. Mudanças nos scripts passam a ser testadas na suíte da engine.

## Relacionados
- [[0008-testes-fora-do-g0-incluem-engine]]
- [[0021-gates-como-pergunta-e-fluxo-com-sessao]]
- [[0023-provider-antigravity-com-gate-por-hook-e-home-sombra]]
