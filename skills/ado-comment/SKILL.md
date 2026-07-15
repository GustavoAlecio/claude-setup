---
name: ado-comment
model: sonnet
description: Posta um comentario em um work item do Azure DevOps. Usa o MCP azure-devops.
---

Atalho para comentar em um work item sem abrir o navegador.

## Defaults

- **Org:** `<your-org>`
- **Project:** `<your-project>`

Sobrescritos por `--org=...` / `--project=...`. Primeiro argumento numerico = ID. Resto = texto do comentario.

## Passos

1. **Validar entrada.**
   - Se faltar ID, pergunte e pare.
   - Se faltar texto do comentario, pergunte e pare. Aceite tambem texto multi-linha em bloco se o usuario indicar com `<<EOF ... EOF` ou stdin.
2. **Confirmar antes de postar** (gate humano):
   - Imprima: `Vai comentar no #<id> ("<titulo curto do work item>"):` seguido do texto formatado.
   - Pergunte: "Confirmar publicacao? (s/N)".
   - Para fazer isso, primeiro busque o titulo do work item via MCP para dar contexto na confirmacao.
3. **Postar** via tool de add-comment do MCP `azure-devops`.
4. **Confirmar sucesso** com o ID do comentario criado (se retornado) e a URL do work item.

## Notas

- Texto em markdown e aceito; o MCP converte para HTML automaticamente. Se a renderizacao no card ficar quebrada, oriente o usuario a passar HTML simples.
- Erros do MCP (PAT sem scope, item inexistente) devem ser mostrados crus + sugestao de fix.
