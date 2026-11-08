---
name: pr-open
model: opus
description: Abre um PR no GitHub a partir da branch atual, grava a spine card<->GitHub (referência ao card no corpo — AB#<id> no Azure DevOps, chave no Jira/Linear — + indice prs.json) e comenta de volta no card.
---

Materializa o vínculo card↔PR no momento em que o PR nasce. Isso é o que permite o `/pr-status` acompanhar tudo depois sem poll manual.

## 1. Pré-condições

```bash
source ~/.claude/bin/get-project.sh
PROJECT_PATH=$(git rev-parse --show-toplevel)
PROJECT_NAME="$(get-project-name)"
WF_DIR="$HOME/.claude/workflow/$PROJECT_NAME"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
```

- Se `BRANCH` for `main` ou casar `^release/`, **pare**: "Você está na branch base (`$BRANCH`). Faça checkout da branch de trabalho antes de abrir PR."
- Garanta que não há mudanças não commitadas: `git status --porcelain`. Se houver, **pare** e avise — não commite por conta própria.
- Garanta que a branch está pushada: `git push -u origin "$BRANCH"` (ok rodar; é ação de rotina).

## 2. Resolver o card

Ordem de resolução:
1. Primeiro argumento que não é flag → `REF=$(python3 ~/.claude/bin/tracker.py ref "<arg>" "$PROJECT_PATH")`. Saída 2 → **pare** repassando o stderr (org sem tracker ou ID que não é desse tracker).
2. Senão, o `tracker` do `$WF_DIR/current.json`, se for um card (`kind` `ado`, `jira` ou `linear`, com `id`).
3. Senão, sem card — PR sem vínculo. Avise: "Abrindo PR sem card vinculado. Passe `/pr-open <id>` se quiser vincular." (`tracker.kind` `manual` também cai aqui, sem o aviso.)

Daqui em diante, `<KIND>`, `<ID>` e `<CARD_URL>` são os campos do card (`url` pode ser `null`).

## 3. Resolver a base

- Default: se existir uma branch `release/*` ativa (veja os últimos PRs com `gh pr list --limit 5 --json baseRefName`), use a mais recente como base; senão a branch padrão do remoto.
- Apresente a base escolhida e **confirme com o usuário** antes de criar (a base errada é custosa de corrigir).

## 4. Montar título e corpo

- **Título:** conventional commit refletindo a mudança (`feat(scope): ...`, `fix(scope): ...`). Derive dos commits da branch (`git log origin/<base>..HEAD --oneline`). Não invente escopo — use o do código tocado. Com card Jira ou Linear, termine o título com ` [<ID>]`: as integrações de GitHub dos dois vinculam o PR pela chave no título.
- **Corpo:** com card, a **primeira linha** é a referência que dispara o auto-vínculo do tracker:

  | kind | Primeira linha |
  |---|---|
  | `ado` | `[AB#<ID>](<CARD_URL>)` — a syntax `AB#<id>` liga o PR ao work item pela integração Azure Boards↔GitHub |
  | `jira` | `[<ID>](<CARD_URL>)` |
  | `linear` | `[<ID>](<CARD_URL>)` (sem URL: só `<ID>`) |

  Depois: resumo do que muda + seção de teste. Com `--from-complete`, se `$WF_DIR/adr-candidates.md` existir, anexe o conteúdo numa seção `## ADRs propostas` do corpo. A referência no corpo é a fonte durável da spine — o `prs.json` é só índice.

## 5. Criar o PR

Escreva o corpo com **Write** em `$WF_DIR/.pr-body.md` (nunca interpole o texto em shell) e rode:

```bash
gh pr create --base "<BASE>" --head "$BRANCH" --title "<TITULO>" --body-file "$WF_DIR/.pr-body.md"
```

Capture o número e a URL do PR do output (`gh pr view --json number,url`).

## 6. Gravar no índice

```bash
~/.claude/bin/pr-registry.sh register "<PR_NUMBER>" "$BRANCH" "<BASE>" "<TITULO>" "<PR_URL>" "<KIND>" "<ID>" "<CARD_URL>"
```

Sem card, omita os três últimos argumentos.

## 7. Comentar de volta no card (só com card)

O vínculo em si é automático pela referência no corpo/título. Não refaça o link.

Opcional (default: fazer) — sinal explícito no card com o texto curto `PR aberto: <PR_URL> (base: <BASE>). Aguardando review.`:
- ADO: `~/.claude/bin/ado.sh comment <ID> "<texto>"`.
- Jira: escreva o texto com **Write** em `$WF_DIR/.card-comment.md` e rode `~/.claude/bin/jira.py comment <ID> "$WF_DIR/.card-comment.md"`.
- Linear: comentário via MCP `linear`.

Se falhar, não trave — o auto-vínculo já cobre a rastreabilidade.

Não mude estado/assignee do card — no ADO isso é do `/ado-close`; no Jira/Linear, decisão do usuário.

## 8. Finalizar

Resumo em 3 linhas: número do PR + URL, base, e se o card foi anotado. Sugira: "Acompanhe com `/pr-status`."

**Chamado pelo `/complete`** (argumento `--from-complete`): a **última linha** do resultado é só a URL do PR, sem texto, formatação ou pontuação depois. O `/complete` grava a URL no relatório. Este skill nunca grava no relatório: avulso, não grava relatório.
