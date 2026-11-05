---
name: pr-open
model: opus
description: Abre um PR no GitHub a partir da branch atual, grava a spine ADO<->GitHub (link nativo AB#<id> no corpo + indice prs.json) e comenta de volta no work item do Azure DevOps.
---

Materializa o vínculo card↔PR no momento em que o PR nasce. Isso é o que permite o `/pr-status` acompanhar tudo depois sem poll manual.

## Defaults ADO
- **Org:** `<your-org>` · **Project:** `<your-project>`
- Sobrescritos por `--org=` / `--project=`.

## 1. Pré-condições

```bash
source ~/.claude/bin/get-project.sh
PROJECT_NAME="$(get-project-name)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
```

- Se `BRANCH` for `main` ou casar `^release/`, **pare**: "Você está na branch base (`$BRANCH`). Faça checkout da branch de trabalho antes de abrir PR."
- Garanta que não há mudanças não commitadas: `git status --porcelain`. Se houver, **pare** e avise — não commite por conta própria.
- Garanta que a branch está pushada: `git push -u origin "$BRANCH"` (ok rodar; é ação de rotina).

## 2. Resolver o work item (ado_id)

Ordem de resolução:
1. Primeiro argumento numérico → `ADO_ID`.
2. Senão, leia `~/.claude/workflow/$PROJECT_NAME/current.json` e use `.ado_id` se presente.
3. Senão, `ADO_ID` fica vazio — PR sem vínculo. Avise: "Abrindo PR sem card ADO vinculado. Passe `/pr-open <id>` se quiser vincular."

## 3. Resolver a base

- Default: se existir uma branch `release/*` ativa (veja os últimos PRs com `gh pr list --limit 5 --json baseRefName`), use a mais recente como base; senão `main`.
- Apresente a base escolhida e **confirme com o usuário** antes de criar (a base errada é custosa de corrigir).

## 4. Montar título e corpo

- **Título:** conventional commit refletindo a mudança (`feat(scope): ...`, `fix(scope): ...`). Derive dos commits da branch (`git log origin/<base>..HEAD --oneline`). Não invente escopo — use o do código tocado.
- **Corpo:** quando houver `ADO_ID`, a **primeira linha** deve ser o link nativo Azure Boards (dispara o auto-vínculo PR↔work item da integração ADO↔GitHub):

  ```
  [AB#<ADO_ID>](https://dev.azure.com/<your-org>/<your-project>/_workitems/edit/<ADO_ID>)
  ```

  Depois: resumo do que muda + seção de teste. A syntax `AB#<id>` é a fonte durável da spine — o `prs.json` é só índice.

## 5. Criar o PR

```bash
gh pr create --base "<BASE>" --head "$BRANCH" --title "<TITULO>" --body-file <(printf '%s\n' "<CORPO>")
```

Capture o número e a URL do PR do output (`gh pr view --json number,url`).

## 6. Gravar no índice

```bash
~/.claude/bin/pr-registry.sh register "<PR_NUMBER>" "<ADO_ID>" "$BRANCH" "<BASE>" "<TITULO>" "<PR_URL>"
```

## 7. Comentar de volta no card (só se houver ADO_ID)

O vínculo em si é automático: a syntax `AB#<id>` no corpo faz a integração Azure Boards↔GitHub linkar o PR ao work item sem ação manual. Não refaça o link.

Opcional (default: fazer) — sinal explícito via MCP `azure-devops`: `wit_add_work_item_comment` no work item `<ADO_ID>` com texto curto `PR aberto: <PR_URL> (base: <BASE>). Aguardando review.` Se o MCP falhar, não trave — o auto-vínculo já cobre a rastreabilidade.

Não mude estado/assignee do card — isso é do `/ado-close`.

## 8. Finalizar

Resumo em 3 linhas: número do PR + URL, base, e se o card foi anotado. Sugira: "Acompanhe com `/pr-status`."

**Chamado pelo `/complete`** (argumento `--from-complete`): a **última linha** do resultado é só a URL do PR, sem texto, formatação ou pontuação depois. O `/complete` grava a URL no relatório. Este skill nunca grava no relatório: avulso, não grava relatório.
