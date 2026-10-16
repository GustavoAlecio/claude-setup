---
id: 0025
title: Modo de permissão por sessão com padrão "aceitar edições" e bypass só com confirmação
status: accepted
date: 2026-10-07
affects: ["engine/sessions.mjs", "engine/engine.mjs", "app/lib/engine/engine_config.dart", "app/lib/data/orgs.dart", "app/lib/data/sessions_repository.dart", "app/lib/core/widgets/permission_mode.dart", "app/lib/features/settings/**"]
supersedes: ["0019"]
superseded_by: []
tags: [engine, flutter, security]
---

# 0025 — Modo de permissão por sessão com padrão "aceitar edições" e bypass só com confirmação

## Contexto
A ADR 0019 resolveu o modo por sessão e deixou bypass como padrão global, porque o dono do app trabalha assim no CLI. A revisão de produto e UX de 2026-10-07 mostrou o problema disso. Kickoff, paleta e o review aberto pela inbox (até em repo não cadastrado) nasciam em bypass sem que a pessoa tivesse escolhido. Um usuário médio roda agentes que editam arquivos e executam comandos sem nenhuma confirmação.

## Decisão
- **Engine (mantido da 0019):**
  - sempre passa `allowDangerouslySkipPermissions: true`; o modo efetivo vem só de `permissionMode`;
  - sem modo no corpo → `default`, e nunca lê o modo da config;
  - o modo fica gravado na sessão e troca ao vivo por `POST /api/sessions/:id/permission-mode` (recusa → 409, nada gravado);
  - trocar o modo não resolve cards pendentes.
- **App:**
  - resolve o modo sessão > org > global (`effectivePermissionMode`/`launchOrg`);
  - **o global ausente ou inválido passa a ser `acceptEdits`**: edições passam sem pergunta, comandos pedem card;
  - o modo é obrigatório na criação de sessão, e o selo "bypass" aparece no cabeçalho da sessão;
  - **escolher bypass pede confirmação** (`confirmBypass`) em todos os seletores: global, org, paleta, kickoff e cabeçalho da sessão. Quem já está em bypass não é perguntado de novo.
- **`AskUserQuestion`:** continua no `canUseTool` em qualquer modo.

## Alternativas consideradas
- **Manter bypass e só exibir aviso.** O aviso não impede o primeiro uso sem confirmação.
- **Padrão `default`.** Pede card até para editar e trava o fluxo comum.
- **Gravar o bypass na config de quem já usava o padrão.** Esconde a mudança: a escolha precisa ser explícita.

## Consequências
- Quem dependia do padrão (config sem `permissionMode`) passa a ver cards de comando. Para voltar, basta escolher bypass em Configurações, e ele fica gravado.
- As demais consequências da 0019 continuam: checagens de segurança do CLI, regras `deny` e hooks valem em bypass, e mudar o global não altera sessões existentes.

## Relacionados
- [[0019-modo-de-permissao-por-sessao]]
- [[0014-sessao-de-org]]
