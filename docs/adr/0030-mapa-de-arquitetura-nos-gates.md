---
id: 0030
title: Mapa de arquitetura nos gates plan e pr, o do plano do autor e o construído do diff
status: accepted
date: 2026-11-24
affects: ["bin/wf-report.py", "agents/gate-critic.md", "skills/plan/SKILL.md", "skills/complete/SKILL.md"]
supersedes: []
superseded_by: []
tags: [workflow, skills]
---

# 0030 — Mapa de arquitetura nos gates plan e pr, o do plano do autor e o construído do diff

## Contexto
O gate como resumo de decisão (0029) mostra riscos e perguntas, mas não onde o código muda. Quem aprova o plano não vê as peças e quem aprova o PR não vê o que saiu do plano. Um mapa escrito por agente nos dois gates teria o mesmo defeito nos dois: descreveria a intenção, não o resultado.

## Decisão
Emenda o 0029 sem substituí-lo; `brief`, `show`, `answer` e a regra de parada ficam como estavam.
- **Mapa do plano:** o autor do plano rascunha `map` (nós com estado `new|changed|existing` e globs `paths`, arestas, abordagens) a partir do `plan.md`; o `gate-critic` corta e grava na chave `map` do brief do gate `plan`. Só esse gate aceita `map`; qualquer outro recusa.
- **Mapa construído:** no gate `pr` o mapa não vem do arquivo. `wf-report.py brief pr` o calcula do `git diff` entre `exec.base_checkpoint` e a `--tree`, casando cada arquivo com o primeiro nó cujo glob bate, e marca cada peça `planned`, `untouched`, `touched`, `existing` ou `unplanned`. `built-map` imprime o mesmo resultado sem gravar.
- **Pontos do mapa:** peças `unplanned` ou `untouched` viram candidatas `M-<n>` do gate `pr`, cortáveis pelo crítico, que não confere a âncora delas no diff.
- **Degradação:** sem mapa no plano, o bloco é gravado sem mapa e sem aviso. Sem lista de arquivos ou sem git, o bloco é gravado sem mapa e o stderr avisa `mapa construído indisponível`. Nos dois casos o gate segue, e o reenvio do mesmo arquivo com a mesma `base` e `tree` mantém o mapa do bloco anterior, ou a falta dele. Recusa de campo do `map` no gate `plan` (`wf-report: map`) pede novo envio e, na terceira, `--drop-map`.

## Alternativas consideradas
- **Mapa do `pr` escrito pelo crítico** — descreveria o que ele acha que foi construído, sem como conferir; o diff é a fonte.
- **Mapa fora do `report.json`, em arquivo próprio** — o app e o `show` precisariam de um segundo ponto de leitura para o mesmo gate.
- **Recusar o gate sem mapa** — um plano de arquivo único ou um ambiente sem git pararia o ciclo por um recurso auxiliar.

## Consequências
- O mapa do `pr` depende de `--repo` ou do `project_path` do `current.json`, e do `git` no PATH.
- Arquivo fora de todos os globs do plano aparece como `unplanned`; o `ignore` do plano é o único modo de silenciá-lo.
- Os grupos `unplanned` ocupam as vagas que o plano deixa até 8 peças, com pelo menos uma: o mapa construído chega a 9 peças quando o plano usa as 8.
- O `gate-critic` precisa do `install.sh` para ler as regras novas.

## Relacionados
- [[0029-gate-como-resumo-de-decisao]]
