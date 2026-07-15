---
name: ado-close
model: sonnet
description: Fecha (move para estado final) um work item do Azure DevOps. Pede confirmacao antes. Usa o MCP azure-devops.
---

Move um work item para estado final (Done / Closed / Resolved, dependendo do tipo).

## Defaults

- **Org:** `<your-org>`
- **Project:** `<your-project>`

Argumentos: primeiro numerico = ID. `--state=<estado>` opcional. `--comment="..."` opcional (deixa coment no card antes de fechar).

## Passos

1. **Validar entrada.** Sem ID → pergunte e pare.

2. **Buscar o work item** para entender tipo (Bug / User Story / Task / etc) e estado atual via MCP.

3. **Decidir estado destino:**
   - Se `--state=` foi passado, use.
   - Senao, baseado no tipo: Bug → `Resolved`, Task/User Story → `Closed` ou `Done` (dependendo do template do projeto).
   - Se nao tiver certeza do estado valido, **liste os estados validos** consultando o MCP (work item type states) e pergunte.

4. **Confirmar antes de aplicar** (gate humano obrigatorio — esta acao e visivel para o time):
   - Mostre: `Vai mover #<id> ("<titulo>") de <estado-atual> para <estado-destino>.`
   - Se houver `--comment`, mostre o comentario.
   - Pergunte: "Confirmar? (s/N)".

5. **Executar:**
   - Se `--comment`, postar coment primeiro via MCP add-comment.
   - Atualizar `System.State` via MCP update work item.

6. **Confirmar sucesso** com a URL do work item.

## Notas

- Nunca feche em massa. Esta skill opera em um item por vez.
- Se o item ja estiver no estado destino, avise e nao faca nada.
- Erros do MCP (estado invalido no fluxo, regra de campo obrigatorio) — mostre cru e sugira fix.
