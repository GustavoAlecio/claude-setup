---
name: post-review
description: Fluxo Review etapa 3 — publica o review aprovado no PR do GitHub com comentarios inline e veredicto (approve/comment/request_changes) condicional aos achados.
---

## 1. Detectar projeto e PR
```bash
PROJECT_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
PROJECT_NAME=$(basename "$PROJECT_PATH")
REVIEWS_DIR="$HOME/.claude/workflow/$PROJECT_NAME/reviews"
```

Se o usuario passou um numero, use como `PR_NUM`. Se nao, liste reviews aprovados:
```bash
for f in "$REVIEWS_DIR"/PR-*.md; do
  grep -l "^status: approved" "$f" 2>/dev/null
done
```
Pergunte qual publicar.

## 2. Validar review aprovado

Leia `$REVIEWS_DIR/PR-${PR_NUM}.md`. Confirme `status: approved` no frontmatter. Se nao, avise: "Este review nao foi aprovado. Execute `/approve-review <PR_NUM>` primeiro."

Leia `$REVIEWS_DIR/PR-${PR_NUM}.comments.json`. Confirme que existe e tem itens validos.

## 3. Decidir veredicto (condicional)

Conte severidades no `comments.json`:
```bash
critical=$(jq '[.[] | select(.severity=="critical")] | length' "$REVIEWS_DIR/PR-${PR_NUM}.comments.json")
major=$(jq    '[.[] | select(.severity=="major")] | length' "$REVIEWS_DIR/PR-${PR_NUM}.comments.json")
minor=$(jq    '[.[] | select(.severity=="minor")] | length' "$REVIEWS_DIR/PR-${PR_NUM}.comments.json")
nit=$(jq      '[.[] | select(.severity=="nit")] | length' "$REVIEWS_DIR/PR-${PR_NUM}.comments.json")
total=$((critical + major + minor + nit))
```

Regra de decisao:
- `critical >= 1` OU `major >= 3` → `REQUEST_CHANGES`
- `major >= 1` OU `minor >= 1` → `COMMENT`
- `total == 0` → `APPROVE`
- Apenas `nit` → `COMMENT`

Mostre a contagem e o veredicto escolhido. Pergunte: "Veredicto: `<verdict>`. Confirma publicacao? (sim/nao)" — espere confirmacao.

## 4. Publicar review

Use o helper `pr-review.sh`:
```bash
bash ~/.claude/bin/pr-review.sh "$PR_NUM" "$REVIEWS_DIR/PR-${PR_NUM}.comments.json" "<VERDICT>" "$REVIEWS_DIR/PR-${PR_NUM}.md"
```

O helper:
1. Le o `comments.json`
2. Le o body do review do markdown (secao "## Resumo" + "## Veredicto sugerido" como summary)
3. Faz `gh pr view --json baseRefOid,headRefOid,number,headRepository` para obter o commit SHA do head
4. Monta payload JSON da API GitHub Reviews (event + body + comments[] com path/line/body/side)
5. POST `repos/:owner/:repo/pulls/:pr/reviews`

Se algum comentario falhar (ex: linha fora do diff), o helper reporta quais nao foram publicados — voce decide se publica os restantes ou aborta.

## 5. Atualizar status local

Apos publicacao com sucesso, atualize o frontmatter de `PR-${PR_NUM}.md`:
- `status: published`
- `published_at: <ISO timestamp>`
- `verdict: <VERDICT>`
- `review_id: <id retornado pela API>`

## 6. Finalizar

Apresente:
- URL do review: `gh pr view <PR_NUM> --json url --jq .url`
- Veredicto publicado
- Total de comentarios inline publicados (vs falhas)

Mensagem: "Review #<PR_NUM> publicado como `<VERDICT>` com N comentarios inline."
