---
id: 0029
title: Gate do Fluxo como resumo de decisão, com a regra de parada no wf-report.py e sem o piloto
status: accepted
date: 2026-11-23
affects: ["bin/wf-report.py", "agents/gate-critic.md", "skills/*/SKILL.md", "docs/smart-flow.md", "tests/bin.test.sh"]
supersedes: [0021]
superseded_by: []
tags: [workflow, skills]
---

# 0029 — Gate do Fluxo como resumo de decisão, com a regra de parada no wf-report.py e sem o piloto

## Contexto
O 0021 fez cada gate parar com Aprovar, Ajustar e Rejeitar sobre o documento inteiro, e deixou o piloto decidir quando parar. Aprovar um documento longo não é uma decisão; o que o usuário quer é responder só o que está em aberto. E o piloto, sendo um interruptor global, não deveria afrouxar gates que dependem do conteúdo do ciclo.

## Decisão
Continuam valendo do 0021:
- **Como parar:** o gate é `AskUserQuestion`; as paradas de risco (bloqueante do challenger, backtrack/blocked, branch existente, base `release/*`, reset, push) seguem incondicionais e fora da tabela.
- **Ligação sessão → relatório:** o engine injeta `CLAUDE_FLOW_SESSION_ID` e as skills gravam o `session_id` da etapa.
- **Fluxo dividido:** linha do tempo à esquerda, sessão da etapa à direita, seleção por etapa (`?stage=`).
- **Regras puras:** "viva" e "interrompida" ficam em `isLive` e `showsInterrupted`.

Muda:
- **Resumo de decisão:** o gate registra no `report.json` o bloco `stages[owner].gate` (resumo, riscos, perguntas com opções, `omitted`), escrito pelo `gate-critic` e validado por `wf-report.py brief`. `answer`, `show` e `reopen pr` completam o ciclo; `reopen pr` transforma respostas diferentes de `ok` em tasks `P<round>.<n>`.
- **Regra de parada sem o piloto:** `wf-report.py gate` não lê mais o `auto_mode.flag`. `spec` e `pr` sempre perguntam, mais o que o `gates.json` listar; `plan` e `tasks` só perguntam com pergunta em aberto. Gate sem bloco, de outro ciclo ou em estado inesperado pergunta.
- **Guard de escrita:** `brief`, `answer`, `gate`, `show` e `reopen` nunca arquivam o `report.json`. Relatório de outro ciclo conta como bloco ausente e o `InputError` sai (exit 2) antes de qualquer `os.replace`, então o arquivo mantém os bytes.
- **Funções puras no script:** `validate_brief`, `apply_brief`, `apply_answer`, `decide`, `render` e `pr_change_tasks` vivem no próprio `wf-report.py` e são cobertas por `tests/bin.test.sh`, sem módulo novo.
- **`stage-start` preserva `revising`:** na etapa dona remove o `gate`, exceto quando está `revising`, para a rodada pendente do `pr` sobreviver à reentrada; o `brief` seguinte grava a rodada 2 e move a anterior para `history`.
- **`reopen pr`:** gera a task pelo caminho determinístico (risco high, tier0 opus, `affects` no path da âncora), idempotente por id, sem tocar o relatório.

## Alternativas consideradas
- **Manter o piloto decidindo** — plan e tasks continuariam parando para aprovar documento, e `gates.json` seguiria acoplado a um interruptor global.
- **Módulo Python separado para a máquina de estados** — mais um arquivo para instalar e testar sem ganho, já que o script é o único chamador.
- **Skills lendo o `report.json`** — decisão não determinística e difícil de testar (mesma razão do 0021).

## Consequências
- Piloto off: plan e tasks sem pergunta em aberto passam sozinhos. Piloto on com `{"required":["plan"]}` não remove mais `spec` e `pr`.
- `gate` sem `--workflow-dir` sai com 2; as quatro skills mudaram junto.
- O texto do diálogo de piloto no app fica desatualizado até a fase 3.
- O `gate-critic` só passa a existir depois do `install.sh` (agentes por arquivo).

## Relacionados
- [[0021-gates-como-pergunta-e-fluxo-com-sessao]]
- [[0004-fixtures-geradas-pelo-persist]]
- [[0020-relatorio-de-ciclo-por-contrato]]
