---
id: 0016
title: GitHub consultado pelo engine com cache, fallback e checkout validado pelo remote
status: accepted
date: 2026-10-01
affects: ["engine/github.mjs", "engine/engine.mjs", "app/lib/data/github_parser.dart", "app/lib/data/http_github_repository.dart", "app/lib/features/prs/**", "app/lib/features/inbox/**"]
supersedes: []
superseded_by: []
tags: [engine, github, flutter]
---

# 0016 — GitHub consultado pelo engine com cache, fallback e checkout validado pelo remote

## Contexto
As abas PRs e Para revisar precisam do estado vivo do GitHub. O app Flutter só usa `dart:io` em repositórios específicos e não herda o PATH nem a autenticação do shell. O engine herda os dois. Um projeto pode ter PRs em vários repos, e a busca de checkout por nome de pasta acha clones de outra org com o mesmo nome.

## Decisão
O `gh` roda só no engine (`engine/github.mjs`):
- `gh api graphql` por PR e `gh search prs --review-requested=@me`;
- cache de 60 s por instância, que guarda também as falhas e compartilha a promise entre requisições concorrentes;
- mensagens de erro fixas;
- se o GitHub falhar, volta para o `prs.json` com `live: false`.

O `cwd` de cada PR e de cada item sai do repo do PR e só é devolvido quando `remote.origin.url` do checkout aponta para o mesmo `owner/repo`. O app usa a pasta de um projeto registrado só quando ela é exatamente esse `cwd` validado. O app fala com o engine por HTTP e trata todo erro como `GitHubException`, com timeout de 30 s.

## Alternativas consideradas
- **`gh` chamado pelo app** — exigiria replicar a resolução de PATH/ambiente do `EngineSupervisor` e abriria IO em mais lugares.
- **Confiar no checkout pelo nome** — `/review` e `/pr-status` não usam `--repo` e rodariam no repo errado sem avisar.
- **Uma query GraphQL agregada** — fica para quando o número de PRs pesar.

## Consequências
- O resultado depende da conta ativa do `gh`. Repos que ela não enxerga aparecem como "cache" com a mensagem de falta de acesso.
- Pasta registrada fora das raízes de varredura não é usada até o engine receber essas pastas (`projectsHint`).

## Relacionados
- [[0007-engine-node-processo-filho]]
- [[0011-resolucao-de-path-de-projeto]]
