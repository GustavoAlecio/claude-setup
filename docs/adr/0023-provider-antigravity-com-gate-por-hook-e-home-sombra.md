---
id: 0023
title: Provider Antigravity por org, com o agy em headless, gate por hook PreToolUse e HOME sombra por conta
status: accepted
date: 2026-10-06
affects: ["engine/agy.mjs", "engine/accounts.mjs", "engine/sessions.mjs", "engine/engine.mjs", "engine/agy-gate.mjs", "app/lib/engine/engine_config.dart", "app/lib/data/config_mutations.dart", "app/lib/data/orgs.dart", "app/lib/data/sessions_repository.dart", "app/lib/features/settings/**"]
supersedes: []
superseded_by: []
tags: [engine, flutter, security, agents]
---

# 0023 — Provider Antigravity por org, com o agy em headless, gate por hook PreToolUse e HOME sombra por conta

## Contexto
O Antigravity dá acesso a Gemini, Claude e GPT-OSS pela mesma assinatura, e cada org (otg, likin.do…) quer a sua. O engine só fala com o Claude Agent SDK, cujo `canUseTool` alimenta as aprovações e as perguntas do app (ADR 0019, 0021).

Spike com o `agy` 1.3.0:
- **Headless.** `--input-format/--output-format stream-json` mantém uma conversa por processo. `--conversation <id>` retoma em processo novo, inclusive trocando de modelo.
- **Permissões.** Em headless, os modos do `agy` negam escrita e comando sem perguntar e encerram o turno. Um `allow` de hook não sobrepõe essa negação.
- **Hook.** Com `--dangerously-skip-permissions`, o hook `PreToolUse` vira o único gate. Ele recebe os args completos, inclusive `ask_question`, e pode bloquear esperando. Um `deny` com `reason` volta ao modelo e o turno segue. Timeout, exit≠0, JSON inválido e `{}` negam (fail-closed). O ambiente do processo chega ao hook.
- **Conta.** O login vive no Keychain (`svce=gemini`). Com outro `HOME`, o `agy` não enxerga o Keychain e guarda o token em arquivo dentro desse HOME, sem tocar no padrão. Os comandos do agente herdam esse HOME.

## Decisão
- **Config.** `orgs[].agent = {provider: "anthropic" | "antigravity", account?, model?}`. Ausente equivale a `anthropic` com a conta do usuário. O app resolve o agente pela pertença da sessão. Comando `/skill` sempre usa `anthropic`: as skills vivem em `~/.claude` e o Fluxo Smart depende do Workflow tool do Claude Code. O agente da org vale para prompt livre. O engine recebe `provider`, `account` e `model` explícitos na criação e continua sem ler a config (ADR 0014).
- **Adapter.** `engine/agy.mjs` expõe a mesma interface do `query()` do SDK: iterável de mensagens SDK, `interrupt()` e `setPermissionMode()`, com `canUseTool`, `resume` e `model` nas opções. A `Session` só escolhe o `query` pelo provider. Eventos do `agy` viram mensagens SDK:
  - `init` vira `system/init`;
  - tool `ACTIVE` vira `tool_use`, e `DONE`/`ERROR` viram `tool_result`;
  - `text_delta` vira `stream_event`, e o texto acumulado vira `assistant`;
  - `result` vira `result`, com custo 0.
- **Gate.** O `agy` roda sempre em bypass. O hook global da conta (`<HOME sombra>/.gemini/config/hooks.json`, matcher `*`) chama `engine/agy-gate.mjs`, que faz long-poll em `POST /internal/agy-gate` com o id da sessão e um segredo por processo (env).
  - O adapter aplica o modo da sessão. Leitura passa em todo modo. `acceptEdits`/`auto` liberam escrita. `bypassPermissions` libera tudo. O resto vai ao `canUseTool`, igual ao Claude.
  - `ask_question` vira `AskUserQuestion`, e a resposta volta como `deny` com o texto da escolha.
  - Trocar o modo ao vivo é só estado do engine.
- **HOME sombra.** Cada conta vive em `~/.claude-flow/accounts/antigravity/<conta>/`.
  - Tem symlinks para cada entrada do HOME real, exceto `.gemini`, e um `Library` próprio com symlinks exceto `Keychains`.
  - A conta `default` linka também `Keychains` e usa o login da IDE.
  - O engine sincroniza os links a cada spawn. O `gh` funciona pelo `GH_TOKEN` que o engine já injeta (ADR 0017).
- **Login.** Exige TTY, então o app mostra o comando de login da conta, que o usuário roda no terminal. O engine informa se a conta tem token.

## Alternativas consideradas
- **SDK Python `google-antigravity`.** Tem aprovação real, mas é Research Preview, só funciona com cobrança por uso (sem a assinatura) e exigiria um sidecar Python.
- **Modos de permissão do próprio `agy`.** São estáticos na largada e a negação encerra o turno.
- **`permissionOverrides`/`allow` do hook sem bypass.** Não liberam em headless (testado).
- **Hook no `.agents/` do workspace.** Polui os repos e vale para qualquer cliente.
- **Hook no `~/.gemini` real.** Pegaria a IDE. Na sombra, só o engine o carrega.
- **`ANTIGRAVITY_APP_DATA_DIR`/`JETSKI_APP_DATA_DIR`.** Não isolam a conta: o Keychain vence.

## Consequências
- Sessões Antigravity não interrompem no meio do turno. `interrupt` encerra o processo e a próxima mensagem retoma com `--conversation`.
- Arquivos criados no topo do HOME por ferramentas do agente ficam na sombra. O Keychain fica fora do alcance das contas não-default.
- O `agy` lê o `AGENTS.md`, não o `CLAUDE.md`. As regras dos projetos só valem nessas sessões se o repo tiver `AGENTS.md`.
- Conta Anthropic por org (`CLAUDE_CONFIG_DIR`) fica para um ADR próprio. Nesta, `anthropic` usa a conta do usuário.
- Levar o Fluxo Smart a outros providers exige tirar a orquestração do Workflow tool. Fica para ADR próprio.

## Relacionados
- [[0007-engine-node-processo-filho]]
- [[0014-sessao-de-org]]
- [[0017-github-por-org-com-token-por-processo]]
- [[0019-modo-de-permissao-por-sessao]]
- [[0021-gates-como-pergunta-e-fluxo-com-sessao]]
