---
id: 0027
title: Conta Anthropic por org com CLAUDE_CONFIG_DIR sombra
status: proposed
date: 2026-10-07
affects: ["engine/accounts.mjs", "engine/sessions.mjs", "engine/engine.mjs", "app/lib/engine/engine_config.dart", "app/lib/features/settings/org_form.dart"]
supersedes: []
superseded_by: []
tags: [engine, security, agents]
---

# 0027 — Conta Anthropic por org com CLAUDE_CONFIG_DIR sombra

## Contexto
Toda sessão `anthropic` usa a conta do usuário, a do `~/.claude` (ADR 0023). Uma consultoria com assinatura de cliente (ex.: otg) e a própria (ABM) não consegue separar uso, cota nem faturamento por org.

O Claude Agent SDK roda o Claude Code, que lê config e credencial do diretório em `CLAUDE_CONFIG_DIR`. Skills, agentes, workflows e `bin/` também vivem nesse diretório, e o Fluxo depende deles.

## Decisão (proposta)
- **Config.** `orgs[].agent.account` passa a valer também para `provider: "anthropic"`. Ausente mantém a conta do usuário.
- **Diretório sombra.** Cada conta ganha `~/.claude-flow/accounts/anthropic/<conta>/`. Ele tem symlinks para cada entrada de `~/.claude`, exceto a credencial e o estado de sessão. O mesmo mecanismo da HOME sombra do Antigravity sincroniza os links a cada spawn, para skills e agentes novos aparecerem sem reinstalar.
- **Engine.** A sessão passa `env.CLAUDE_CONFIG_DIR` no `query()` da conta. Sem conta, nada muda.
- **Login.** Igual ao Antigravity: o app mostra o comando (`CLAUDE_CONFIG_DIR=… claude /login`) para o usuário rodar no terminal. A engine diz se a conta tem credencial e qual e-mail, pelo `accountInfo` do probe.
- **Spike antes de aceitar.** No macOS, a credencial fica no Keychain. É preciso confirmar se a versão instalada separa a entrada do Keychain por `CLAUDE_CONFIG_DIR`. Se não separar, a conta precisa de API key (`ANTHROPIC_API_KEY` por processo, guardada no Keychain pelo app) em vez de assinatura.

## Alternativas consideradas
- **`CLAUDE_CONFIG_DIR` vazio por conta.** Perde skills, agentes e workflows: o Fluxo para.
- **Só API key por org.** Simples e isolado, mas cobra por uso e não aproveita a assinatura do cliente.
- **Trocar o login global ao trocar de org.** Mistura sessões vivas de orgs diferentes e é frágil.

## Consequências
- Custo e cota passam a ser por org, e o orçamento por ciclo fica comparável entre clientes.
- A sombra precisa acompanhar mudanças de layout do `~/.claude` entre versões do Claude Code. O que não for linkado some para a conta.
- O seletor de modelos e o checklist de prontidão passam a consultar a conta da org, não a do usuário.
- Combina com a ADR 0026: as sessões filhas de um run herdam a conta da org.

## Relacionados
- [[0017-github-por-org-com-token-por-processo]]
- [[0023-provider-antigravity-com-gate-por-hook-e-home-sombra]]
- [[0026-fluxo-smart-orquestrado-pela-engine]]
