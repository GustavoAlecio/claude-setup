---
name: pr-status
model: opus
description: Digest das suas PRs em voo — le o indice prs.json, consulta review/CI/comentarios via gh, atualiza os stages e mostra o proximo passo por PR. Oferece resolver comentarios (com gate antes do push).
---

Mata o "conferir PR diariamente". Lê o índice, cruza com o GitHub, e diz exatamente o que precisa de você.

## 1. Projeto e índice

```bash
source ~/.claude/bin/get-project.sh
PROJECT_NAME="$(get-project-name)"
~/.claude/bin/pr-registry.sh list
```

## 2. Bootstrap se vazio

Se `prs.json` não tem PRs (índice novo), ofereça popular a partir das suas PRs abertas:

```bash
gh pr list --state open --author @me --json number,title,baseRefName,headRefName,url
```

Para cada uma, extraia o `ADO_ID` do corpo do PR com a convenção nativa Azure Boards:

```bash
gh pr view <n> --json body -q .body | grep -oiE 'AB#[0-9]+' | grep -oE '[0-9]+' | head -1
```

Registre com `pr-registry.sh register`. Avise quais PRs entraram vinculadas e quais ficaram sem card (`AB#` ausente — normal em PRs antigas).

## 3. Inspecionar cada PR

Para cada PR do índice:

```bash
# se o PR sumiu (merged/closed), remova do indice e registre no digest
STATE=$(gh pr view <pr> --json state -q .state 2>/dev/null || echo GONE)
```

- `MERGED` → `pr-registry.sh remove <pr>`, marque no digest como concluída.
- `CLOSED` → idem, marque como fechada sem merge.
- Aberta → `~/.claude/bin/pr-inspect.sh <pr>` e derive o stage:

| Condição (do pr-inspect) | stage | Próximo passo |
|---|---|---|
| `reviewDecision=CHANGES_REQUESTED` ou `unresolved>0` | `changes_requested` | **você**: resolver comentários |
| `reviewDecision=APPROVED` + `checks=SUCCESS` + `mergeable=MERGEABLE` | `merge_ready` | **você**: mergear |
| `reviewDecision=APPROVED` (checks pendente/falho) | `approved` | aguardar CI |
| `checks=FAILURE` | (mantém) | **você**: CI vermelho |
| resto (`REVIEW_REQUIRED`) | `awaiting_review` | aguardar review |

Atualize o índice: `pr-registry.sh set-stage <pr> <stage>`.

## 4. Digest

Ordene por urgência (o que precisa de você primeiro). Formato:

---
**PRs em voo — PROJECT_NAME**

🔴 **#<n>** <título> — `changes_requested` · ADO #<id>
  2 comentários não resolvidos · CI: ✓ · base: `release/3.11.0/main`
  → resolver comentários

🟡 **#<n>** <título> — `awaiting_review` · ADO #<id>
  aguardando review · CI: ✓

🟢 **#<n>** <título> — `merge_ready` · ADO #<id>
  aprovada, CI verde → **pronta pra merge**

_(concluídas nesta rodada: #<n> merged)_
---

Use ✓/✗/⏳ para checks (SUCCESS/FAILURE/PENDING). Se `ado_id` for null, mostre "sem card".

## 5. Resolver comentários (gate)

Se houver PRs em `changes_requested`, pergunte: "Quer que eu resolva os comentários da PR #<n>?"

Se sim, **para essa PR**:
1. `git fetch && git checkout <branch da PR do índice>`.
2. Liste os `unresolved` do `pr-inspect` (path/line/author/body). Para cada um, entenda o pedido lendo o código real no `path:line`.
3. Aplique as correções com a menor superfície possível. Rode testes relevantes do pacote afetado (`make test PKG=<pkg>`).
4. **Pare e mostre o diff. Não commite nem faça push sem OK explícito do usuário** — regra de compliance.
5. Após aprovação: commit (conventional) + push. Ao responder na thread, use `mcp azure-devops`/`gh` só se o usuário pedir; por padrão o push já dispara a notificação nativa GitHub→Slack.

Nunca resolva a thread no GitHub por conta própria — quem resolve é o revisor.

## 6. Merge

Nunca mergeie automaticamente. Para PRs em `merge_ready`, apenas sinalize. Se o usuário pedir explicitamente o merge, confirme base e método antes.
