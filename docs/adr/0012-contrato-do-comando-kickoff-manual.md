---
id: 0012
title: Kickoff manual com flags na primeira linha e descrição verbatim, sem shell
status: accepted
date: 2026-10-01
affects: ["app/lib/data/kickoff.dart", "app/lib/features/launcher/**", "skills/kickoff/SKILL.md"]
supersedes: []
superseded_by: []
tags: [flutter, skills, engine]
---

# 0012 — Kickoff manual com flags na primeira linha e descrição verbatim, sem shell

## Contexto
O formulário do app inicia `/kickoff` sem ID pelo engine, que entrega o comando como mensagem de usuário sem parsing. A descrição é texto livre multilinha com aspas, crases e `$(...)`, e a skill grava estado com snippets de shell/Python.

## Decisão
O app monta `/kickoff --manual [--bug|--feature]`, uma linha em branco e a descrição verbatim (`kickoffCommand` em `kickoff.dart`). A skill lê as flags só da primeira linha e trata o resto como texto literal. Ela grava a descrição com a ferramenta Write em `$WF_DIR/manual-description.md`, e os snippets Python leem esse arquivo (heredoc com delimitador entre aspas e argv). Nenhum texto do usuário é interpolado em shell.

## Alternativas consideradas
- **Descrição entre aspas com escape** — o engine não des-escapa; as barras chegariam à spec e ao slug.
- **Endpoint dedicado no engine** — muda o contrato do engine (ADR 0007) para um caso que o comando já cobre.

## Consequências
- No terminal, a forma `--manual "<texto>"` de uma linha continua aceita.
- O formato depende do modelo respeitar o "verbatim"; o QA manual do ciclo cobre isso.

## Relacionados
- [[0007-engine-node-processo-filho]]
