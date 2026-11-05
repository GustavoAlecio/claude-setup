---
id: 0011
title: Path de projeto com a mesma precedência e desempate por profundidade no app e no engine
status: superseded
date: 2026-10-01
affects: ["app/lib/data/orgs.dart", "app/lib/data/project_scan.dart", "engine/cwd.mjs"]
supersedes: []
superseded_by: ["0018"]
tags: [flutter, engine, config]
---

# 0011 — Path de projeto com a mesma precedência e desempate por profundidade no app e no engine

## Contexto
O path decide a org do projeto e o `cwd` das sessões. Raízes reais têm cópias de repositórios em pastas de documentação (`<raiz>/r10-arq-docs/repos/r10-hub`), o que fazia a varredura achar vários candidatos, deixar projetos da raiz em "Sem org" no app e o engine escolher a cópia pela ordem do `readdir`.

## Decisão
Precedência: entrada registrada em `projects[].path` > `project_path` do `current.json` > `cwds` > varredura das raízes até profundidade 3. Na varredura vence o candidato mais raso relativo à raiz; empate no nível mais raso significa sem path (no engine, `cwd` nulo e sessão recusada). `resolvePath` (Dart) e `resolveCwd` (engine) seguem a mesma regra, com lista de pastas ignoradas comparada por teste.

## Alternativas consideradas
- **Exigir candidato único** — a regra da spec original; quebra no layout real.
- **Primeiro candidato do DFS** — depende da ordem do sistema de arquivos.

## Consequências
- Ambiguidade real se resolve na tela com "Adicionar projeto", que faz merge com uma entrada sem path.
