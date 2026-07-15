---
name: kickoff
model: opus
description: Entrada do pipeline — pega o work item do Azure DevOps, faz triage bug/feature/auditoria, captura ado_id no current.json e encadeia refine->specify (feature), aponta /fix (bug), ou refine-only/abort (card nao-implementavel neste repo).
---

Ponto de entrada único do ciclo. A partir do ID do card, decide a rota e já carrega o contexto — você não redigita nada.

## Defaults ADO
- **Org:** `<your-org>` · **Project:** `<your-project>`
- Sobrescritos por `--org=` / `--project=`. Primeiro argumento numérico = ID do work item.

## 1. Pré-condições

- Argumento obrigatório: ID numérico do work item. Sem ele, **pare** e peça.
- Acesso ao ADO é via `~/.claude/bin/ado.sh` (PAT + REST, headless-safe). O PAT vem de `~/.claude.json`. **Não** dependemos do MCP `azure-devops` (auth interativa quebra).

```bash
source ~/.claude/bin/get-project.sh
PROJECT_NAME="$(get-project-name)"
WF_DIR="$HOME/.claude/workflow/$PROJECT_NAME"
```

## 2. Checar fluxo em andamento

Leia `$WF_DIR/current.json` (se existir). Se `status` não for terminal (`verified`/ausente) e for de **outro** card (`ado_id` diferente), **pare** e pergunte: "Já há um fluxo ativo em **PROJECT_NAME** (card #X, status Y). Continuar (`/status`) ou resetar pra começar o #<novo>?" — não clobber sem OK.

## 3. Puxar o work item

```bash
~/.claude/bin/ado.sh get <id>     # metadados (title, type, state, assignee, tags)
~/.claude/bin/ado.sh desc <id>    # descricao + repro + criterios em texto plano
```

## 4. Triage bug/feature

Classifique pelo `type` **case-insensitive por substring** (os tipos reais variam: `Bug`, `Bug USs`, etc.):
- contém `bug` → **bug**
- resto (`User Story`, `Feature`, `Task`, `Product Backlog Item`, ...) → **feature**

Apresente: "Card #<id> — «<título>» (tipo `<type>`) classificado como **<bug|feature>**."

Gate: se `~/.claude/workflow/auto_mode.flag` **não** existe, confirme a classificação com o usuário (1 pergunta). Se existe (auto on), prossiga.

## 4a. Checagem de implementabilidade (só rota FEATURE)

Bug sempre segue pra `/fix`. **Feature exige um segundo julgamento pelo CONTEÚDO** (não pelo tipo): nem toda User Story é uma feature mobile implementável em PR. Antes de seguir, avalie se o card é **não-implementável neste repo**. Sinais:

- Auditoria / investigação / levantamento ("levantar", "documentar gaps", "mapear")
- Cross-platform ou explicitamente backend / server-side ("vale pros dois OSes", "enforcement no backend", infra, API)
- Entregável é relatório/decisão, não uma mudança de código mobile bem-definida

Se **nenhum** sinal → prossiga normal (4b → 6). Se **houver** sinal, **pare e ofereça 3 rotas** (mesmo com auto on — esta decisão não é automatizável):

1. **`/ado-refine`-only** — investiga o card no codebase mobile (o que existe, onde vive, gaps do lado client), posta os achados no card. **Sem** seed/branch/specify. É a rota certa pra auditoria.
2. **Feature completa** — segue 4b → 6 (o usuário assume que há escopo mobile implementável).
3. **Abortar** — card não é pra este fluxo/repo; encerra limpo (nada criado) e o usuário redireciona.

Execute conforme a escolha. Rota 1: invoque `/ado-refine <id>` e encerre. Rota 3: pare aqui.

## 4b. Preparar branch de trabalho (rota BUG e FEATURE completa)

> Pule este passo nas rotas `/ado-refine`-only e abortar (não há código a mudar ainda).

Nunca começar o card na branch de outro trabalho. Prepare o isolamento:

```bash
# 1) mudanças pendentes? stasha (avisa o usuário do stash)
[ -n "$(git status --porcelain)" ] && git stash push -u -m "kickoff-<id>-wip"
# 2) base: última release/* no remoto, senão main
BASE=$(git ls-remote --heads origin 'release/*' | awk '{print $2}' | sed 's|refs/heads/||' | sort -V | tail -1)
BASE=${BASE:-main}
git fetch origin "$BASE" --quiet
# 3) nome da branch: <prefixo>/<versao-da-base>/<id>-<slug>
#    prefixo: bug→fix, feature→feat ; versao extraída da base (release/3.11.0/main → 3.11.0)
SLUG=$(~/.claude/bin/to-slug.sh "<título curto do card>")
git checkout -b "<prefixo>/<versao>/<id>-$SLUG" "origin/$BASE"
```

**Confirme a base com o usuário** antes do checkout (release errada é custosa). Se houve stash, lembre o usuário ao final que há um `stash` pendente da branch anterior.

## 5. Rota BUG

Não semeia `current.json` (não polui o estado do Flow Smart). Apresente:

- Resumo do bug (root cause provável se os reproSteps derem pista), em 2-3 linhas.
- Instrução: "Bug — pulando refino. Rodando `/fix` com esse contexto." E **invoque `/fix`** passando o contexto do card como bug report.
- Lembrete: "Ao abrir o PR, rode `/pr-open <id>` (ou inclua `AB#<id>` no corpo) — o card não está no current.json nesta rota."

Encerre após o `/fix` assumir.

## 6. Rota FEATURE

### 6a. Semear a spine no current.json

```bash
python3 -c "
import sys; sys.path.insert(0, '$HOME/.claude/bin')
from current_json import update_current_json
def m(d):
    d['ado_id'] = <ADO_ID>
    d['work_item_type'] = 'feature'
    d.setdefault('status', 'triaged')
    return d
update_current_json('$WF_DIR', m, default={'ado_id': <ADO_ID>, 'work_item_type': 'feature', 'status': 'triaged'})
"
```

### 6b. Refinar

**Invoque `/ado-refine <id>`** — gera o detalhamento técnico em `$WF_DIR/details/<slug>.md` e (com seu OK) comenta no card. Aguarde ele concluir.

### 6c. Especificar

**Invoque `/specify`** usando como descrição de entrada: o work item (título + descrição + critérios de aceite) **+ o doc de refino recém-gerado** (`$WF_DIR/details/<slug>.md`). Diga ao `/specify` explicitamente para se basear nesse detalhamento em vez de pedir a descrição ao usuário.

A partir daí o Flow Smart segue seu curso normal (specify → plan → tasks → implement → verify), com os gates conforme `auto_mode.flag`. O `ado_id` já está no `current.json`, então `/pr-open` no fim vincula o PR sozinho.

## 7. Não fazer

- Não mudar estado/assignee do card (isso é do `/ado-close`).
- Não abrir PR aqui — isso é do `/pr-open`, no fim do ciclo.
