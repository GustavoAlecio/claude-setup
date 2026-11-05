---
id: 0019
title: Modo de permissão por sessão, resolvido no app, com bypass sempre habilitável no engine
status: accepted
date: 2026-10-02
affects: ["engine/sessions.mjs", "engine/engine.mjs", "app/lib/data/orgs.dart", "app/lib/data/sessions_repository.dart", "app/lib/core/widgets/permission_mode.dart", "app/lib/features/settings/**"]
supersedes: []
superseded_by: []
tags: [engine, flutter, security]
---

# 0019 — Modo de permissão por sessão, resolvido no app, com bypass sempre habilitável no engine

## Contexto
O usuário trabalha no CLI em bypass. No app, toda chamada de ferramenta pedia card porque o engine fixava `permissionMode: "default"`. O SDK só aceita trocar para `bypassPermissions` com a sessão rodando se ela nasceu com `allowDangerouslySkipPermissions`.

## Decisão
- **Engine:**
  - sempre passa `allowDangerouslySkipPermissions: true`; o modo efetivo vem só de `permissionMode`;
  - sem modo no corpo → `default`, e nunca lê o modo da config;
  - o modo fica gravado na sessão (summary, snapshot e resume) e troca ao vivo por `POST /api/sessions/:id/permission-mode` (`setPermissionMode`; recusa → 409, nada gravado);
  - trocar o modo não resolve cards pendentes.
- **App:**
  - resolve o modo sessão > org > global (`effectivePermissionMode`/`launchOrg`), com o global padrão `bypassPermissions`;
  - o modo é obrigatório na criação de sessão;
  - mostra o selo "bypass" no cabeçalho da sessão.
- **`AskUserQuestion`:** continua no `canUseTool` em qualquer modo, porque o CLI trata `requiresUserInteraction` antes do allow do modo.

## Alternativas consideradas
- **Flag só quando o modo inicial é bypass** — impede a troca ao vivo de `default` para bypass.
- **Engine lendo o modo da config** — contraria a ADR 0014.
- **Hook `PreToolUse` para perguntas** — desnecessário no CLI atual e sujeito a timeout.

## Consequências
- Em bypass, as checagens de segurança do CLI (remoção perigosa, leitura fora da pasta), as regras `deny` e os hooks do usuário continuam pedindo card ou negando, como no terminal.
- Mudar o global ou o da org não altera sessões existentes.
- O engine escuta em 127.0.0.1 sem autenticação; o bypass amplia o impacto disso (fora do escopo).

## Relacionados
- [[0014-sessao-de-org]]
- [[0017-github-por-org-com-token-por-processo]]
