---
name: ado-get
model: sonnet
description: Mostra um resumo de um work item do Azure DevOps a partir do ID. Usa o MCP azure-devops.
---

Resumo rapido de um work item.

## Defaults

- **Org:** `<your-org>`
- **Project:** `<your-project>`

Se o usuario passar `--org=...` ou `--project=...` nos args, sobrescreva. Se passar so um numero, e o ID.

## Passos

1. **Validar entrada.** Se nao houver ID nos args, pergunte e pare.
2. **Buscar o work item** via tool do MCP `azure-devops` (work item get / wit_get_work_item ou equivalente disponivel na sessao). Inclua os campos: title, state, assignedTo, workItemType, tags, iterationPath, areaPath, description, acceptanceCriteria, reproSteps (quando aplicavel).
3. **Buscar comentários recentes** (ate os 5 mais novos) via tool de comments do MCP.
4. **Apresentar** no chat com este formato:

```
#<id> [<type>] <title>
Estado: <state> · Iteration: <iterationPath> · Assignee: <assignedTo or "—">
Tags: <tags or "—">

<description em texto plano, max 30 linhas; resumir se maior>

Criterios de aceite (se houver):
<acceptanceCriteria>

Comentários recentes:
- <autor, data relativa>: <primeira linha>
- ...
```

5. **Pare.** Nao tome ação nenhuma. Espere o usuario decidir o próximo passo (`/ado-refine`, `/ado-comment`, etc).

## Notas

- HTML em descricao do ADO: converta para texto plano legivel (remova tags, preserve quebras).
- Se o item nao existir ou o PAT nao tiver permissao, mostre o erro do MCP cru e sugira checar PAT/scope.
