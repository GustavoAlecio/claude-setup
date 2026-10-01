---
id: 0018
title: Path de projeto só na raiz de um repo, com a mesma precedência e desempate por profundidade no app e no engine
status: accepted
date: 2026-10-01
affects: ["app/lib/data/orgs.dart", "app/lib/data/project_scan.dart", "engine/cwd.mjs"]
supersedes: ["0011"]
superseded_by: []
tags: [flutter, engine, config]
---

# 0018 — Path de projeto só na raiz de um repo, com a mesma precedência e desempate por profundidade no app e no engine

## Contexto
A 0011 aceitava como candidata da varredura qualquer pasta com o nome do projeto e só desempatava por profundidade. Um projeto sem repo próprio resolveu para uma subpasta de mesmo nome dentro de outro repo (cópia de contrato em pasta de docs), e a sessão rodou nesse outro repo. Com as sessões em `bypassPermissions` por padrão, rodar no diretório errado deixa de ser só incômodo.

## Decisão
Continua valendo da 0011: precedência `projects[].path` > `project_path` do `current.json` > `cwds` > varredura das raízes até profundidade 3; vence o candidato mais raso relativo à raiz; empate no nível mais raso significa sem path; `resolvePath` (Dart) e `resolveCwd` (engine) seguem a mesma regra, com a lista de pastas ignoradas comparada por teste.

Muda a candidatura na varredura (`scanRoots` no app, `scan` no engine):
- Um candidato vale se contém `.git` (diretório, arquivo ou symlink, sem seguir o link: cobre worktree e submódulo) ou se nenhum ancestral entre a raiz da busca (inclusive) e ele contém `.git`.
- "Dentro de repo" é marcado durante a descida pela listagem que já é feita; o `.git` do candidato só é checado (`FileSystemEntity.type`/`lstat`) quando há ancestral com `.git`. Nenhum processo `git` por pasta.
- Candidato recusado não interrompe a descida. No app, um ancestral só bloqueia o mesmo nome abaixo dele se foi aceito, como o engine, que para de descer só num candidato aceito.
- Um teste do app roda o `resolveCwd` do engine na mesma árvore temporária e compara os resultados.

## Alternativas consideradas
- **`git rev-parse --show-toplevel` por candidato** — um processo por pasta varrida, e ainda precisa da regra para pastas fora de git.
- **Exigir `.git` em todo candidato** — perde pastas de workflow sem repo (raiz da org sem git), que a regra (b) mantém.
- **Manter a 0011 e confiar no desempate** — a cópia aninhada vence sempre que o projeto não tem repo próprio na raiz.

## Consequências
- Um projeto cuja única pasta de mesmo nome está dentro de outro repo fica sem path: ⌘K, Kickoff e Nova conversa mostram a mensagem "sem pasta" existente e não criam sessão.
- App e engine varrem raízes diferentes (orgs no app, `CLAUDE_WEB_SCAN_ROOTS` no engine), então o mesmo nome pode resolver diferente. O app sempre manda `cwd` e barra `path == null`, então o resultado do engine não é alcançável pelo app.

## Relacionados
- [[0011-resolucao-de-path-de-projeto]]
- [[0014-sessao-de-org]]
