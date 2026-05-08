---
name: approve-review
description: Fluxo Review etapa 2 — gate local. Marca um review draft como aprovado e pronto para publicar via /post-review. NAO aprova o PR no GitHub.
---

## 1. Detectar projeto e PR
```bash
PROJECT_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
PROJECT_NAME=$(basename "$PROJECT_PATH")
REVIEWS_DIR="$HOME/.claude/workflow/$PROJECT_NAME/reviews"
```

Se o usuario passou um numero de PR como argumento, use-o como `PR_NUM`.

Se nao passou, liste reviews drafts disponiveis:
```bash
ls "$REVIEWS_DIR"/PR-*.md 2>/dev/null
```
Pergunte qual aprovar, ou se ha apenas um, use-o.

## 2. Validar review

Leia `$REVIEWS_DIR/PR-${PR_NUM}.md`. Verifique:

1. Frontmatter existe e tem `status: draft`. Se ja for `approved`, avise: "Este review ja foi aprovado. Para republicar, use `/post-review <PR_NUM>`."
2. Existe `$REVIEWS_DIR/PR-${PR_NUM}.comments.json` com comentarios validos.
3. O JSON tem schema correto: cada item com `path`, `line`, `body`, `severity`.

Se algo estiver errado, liste o problema e pare.

## 3. Sincronizar edicoes manuais (opcional)

Se o usuario editou o `PR-${PR_NUM}.md` (adicionou/removeu/alterou comentarios), o `comments.json` pode estar desatualizado.

Pergunte: "O `PR-${PR_NUM}.md` pode ter sido editado manualmente. Quer que eu re-sincronize o `comments.json` a partir do markdown? (recomendado se voce editou)"

Se sim:
1. Parse o markdown extraindo cada bloco `### \`<path>\`` → `#### Linha N — <sev> [<agent>]` → corpo
2. Re-gere o `PR-${PR_NUM}.comments.json` a partir disso
3. Confirme: "Re-sincronizado: N comentarios."

Se nao, mantenha o `.comments.json` original.

## 4. Marcar como aprovado

Atualize o frontmatter de `PR-${PR_NUM}.md`:
- `status: approved`
- Adicione `approved_at: <ISO timestamp>`

## 5. Finalizar

Apresente:
- Total de comentarios que serao publicados
- Veredicto que sera enviado (do campo "Veredicto sugerido" do markdown)
- Caminho do arquivo

Mensagem final: "Review aprovado localmente. Para publicar no PR: `/post-review <PR_NUM>`."
