---
id: 0028
title: Sessões do terminal no app e pergunta à parte, por fork do transcript
status: accepted
date: 2026-10-16
affects: ["engine/terminal.mjs", "engine/agy.mjs", "app/lib/engine/engine_config.dart", "app/lib/core/widgets/permission_mode.dart", "engine/sessions.mjs", "engine/engine.mjs", "engine/index.mjs", "bin/to-app.py", "skills/app/SKILL.md", "app/lib/app/terminal_handoff.dart", "app/lib/features/sessions/sessions_page.dart", "app/lib/data/sessions_repository.dart", "app/lib/data/session_reducer.dart", "app/lib/engine/engine_supervisor.dart"]
supersedes: []
superseded_by: []
tags: [engine, flutter, sessions, skills]
---

# 0028 — Sessões do terminal no app e pergunta à parte, por fork do transcript

## Contexto
O uso real é conversar no terminal (dúvidas, planejamento) e só às vezes partir para a execução. O app só enxergava as sessões que o próprio engine criava, então o contexto ficava sempre no terminal e o app era pouco usado.

O Claude Code grava cada conversa em `~/.claude/projects/<cwd>/<sdkSessionId>.jsonl`. Enquanto o processo vive, ele também grava `~/.claude/sessions/<pid>.json` com `sessionId` e `status`. Os dois formatos são internos do CLI. As linhas `user`/`assistant` do transcript têm o mesmo formato das mensagens do SDK.

## Decisão
- **Listar.** `GET /api/terminal-sessions?cwd=` devolve as últimas 20 sessões do projeto e das subpastas dele, decidindo pelo `cwd` gravado no transcript, porque o nome do diretório é ambíguo. Ficam de fora as sessões que o engine já tem e as de `entrypoint: sdk-*`, que são programas e não conversas.
- **Importar.** `POST /api/sessions/import` converte o transcript nos eventos do engine (só a linha principal, as últimas 600, com `tool_result` cortado). A sessão nasce `detached`, com a nota `imported`. Importar de novo devolve a mesma sessão e traz os turnos mais novos que o último importado, pelo timestamp, enquanto o app não tiver conversado nela.
- **Retomar.** No `attach` com resume, se o transcript está vivo num terminal, o engine passa `forkSession: true`, o app segue num ramo novo e o reducer mostra a nota. Se não está, retoma no próprio transcript, e um `claude --resume` depois enxerga o que foi feito no app. A decisão é tomada no Retomar, não no import.
- **`/app` no terminal.** `bin/to-app.py` acha o engine por `engine.json` (porta e pid, gravado no boot e apagado na saída) e abre o app se estiver fechado. Depois manda `POST /api/ui/open-terminal`. O engine só repassa pelo stream global; quem importa e navega é o app (`TerminalHandoffListener`), com projeto, modo e conta pelas regras dele.
- **Pergunta à parte.** `POST /api/sessions/:id/aside` cria uma sessão que parte de um fork do transcript de `:id` (`forkFrom` no primeiro attach, `asideOf` no summary), em `plan`. Ela vê tudo o que a original fez, e nada do que se pergunta entra no contexto do pipeline. Só para Anthropic: o `agy` não tem fork de conversa. `plan` vale por sessão e nunca vem da config (`kConfigPermissionModes`, `PermissionMode.parseConfig`): como padrão de org, ele deixaria o pipeline sem conseguir editar. No `agy`, `plan` recusa tudo o que não é leitura.
- **Env por shell detached.** O `zsh -ilc` que captura o ambiente roda com `ProcessStartMode.detachedWithStdio` (`setsid`). Um zsh interativo toma o terminal de quem lançou o app (`flutter run`, uma sessão do Claude Code), e quem estava lá fica suspenso com SIGTTIN.

## Alternativas consideradas
- **Modo leitura enquanto o terminal estiver aberto.** Seguro, mas trava o uso até o terminal fechar. O fork resolve a concorrência sem bloquear.
- **Retomar sempre no mesmo transcript.** Dois processos gravando no mesmo `.jsonl`, e o terminal não veria os turnos do app no contexto em memória.
- **A skill importar direto no engine.** Duplicaria em Python as regras de org, modo e conta, que hoje só o app conhece (ADR 0014).

## Consequências
- O formato do transcript e o `sessions/<pid>.json` podem mudar entre versões do CLI. A leitura ignora o que não reconhece, e a lista fica vazia em vez de quebrar.
- Depois de conversar num ramo do app, um novo `/app` cria outra sessão para o mesmo transcript do terminal, que é o outro ramo.
- O `open -b` prefere a cópia do LaunchServices (`/Applications`). O script ativa a instância já aberta pelo caminho dela, para não abrir uma segunda.

## Relacionados
- [[0014-sessao-de-org]]
- [[0021-gates-como-pergunta-e-fluxo-com-sessao]]
- [[0022-identidade-de-ciclo-progressiva-e-sessao-pelo-ambiente]]
