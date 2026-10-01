---
id: 0007
title: Engine Node como processo filho com encerramento por stdin-EOF
status: accepted
date: 2026-10-01
affects: ["engine/**", "app/lib/engine/**"]
supersedes: []
superseded_by: []
tags: [node, engine, process-management]
---

# 0007 — Engine Node como processo filho com encerramento por stdin-EOF

## Contexto
O app Flutter precisa executar um engine headless em Node.js (`engine/index.mjs`) que gerencia sessões de workflow. O engine deve rodar como processo filho do app, com ciclo de vida controlado via signals e stdin. Hot restart do app, kill -9 do processo, e desativação de engine são cenários que exigem garantias.

## Decisão
O engine é um processo filho iniciado pelo `EngineSupervisor` em Dart via `Process.start`. O encerramento tem duas vias:

1. **stdin-EOF (primária):** observado apenas se fd 0 for FIFO ou socket. O EOF dispara `stop()` em todas as sessões, espera até 1,5 s pelos `consume()` em curso, `flushAll()` e `exit(0)`, com hard-exit em 1,8 s.
2. **onExitRequested (secundária):** quando o app recebe sinal de saída (Cmd-Q no macOS), dispara SIGTERM (3 s de tolerância) e SIGKILL se necessário.

O engine anterior (processo órfão) é detectado via `engine.pid`, confirmado por `ps -o command= -p <pid>` contendo `--sessions-dir`, e recebe SIGTERM com espera de até 2,5 s antes do `loadAll`. O arquivo `engine.pid` é atualizado ao boot bem-sucedido.

Logs do engine são capturados em `~/.claude/workflow/.dashboard/engine.log` com marcas `spawn` e `ready`. Se `ENGINE_READY` não chegar em 5 s desde `Process.start`, o engine é marcado como parado com as últimas 20 linhas de stderr.

## Alternativas consideradas
- **Launchd agent (macOS)** — persiste após app fechar; fora do escopo.
- **Engine embutido no `.app` (macOS)** — complexidade de bundle; fora do escopo.
- **Só `onExitRequested`** — não cobre kill -9 nem hot restart do app; órf ão fica rodando.
- **Observar EOF com qualquer fd** — `/dev/null` causaria saída imediata em critério 1 (dev rodando sem TTY).
- **SIGTERM cego sem checagem de pid** — reaproveitaria pid de outro processo não relacionado.
- **`flock` para serializar acesso** — não existe nativo no Node; duplicaria dependências.

## Consequências
- O app precisa capturar sinais de saída via `AppLifecycleListener.onExitRequested`.
- O supervisor expõe `Stream<Uri?>` do endpoint do engine, permitindo que o app reconheça quando está parado.
- Testes do engine rodamvia `bash tests/run.sh` (fora do G0), confirmando ciclo de vida, flush e orphan handling.
- Há overhead de captura de ambiente por `zsh -ilc` com timeout e fallback, necessário para respeitar toolchains (nvm, rbenv).

## Relacionados
- [[0008-testes-fora-do-g0-incluem-engine]]
