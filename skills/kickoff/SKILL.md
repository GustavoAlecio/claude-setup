---
name: kickoff
model: opus
description: Entrada do pipeline — com ID de card, usa o tracker configurado na org do repo (Azure DevOps, Jira ou Linear), puxa o card e faz triage bug/feature/auditoria; sem ID (ou com --manual), entra no modo manual a partir de uma descricao livre, sem tracker. Semeia a spine no current.json e encadeia refine->specify (feature), aponta /fix (bug/chore), ou refine-only/abort (card nao-implementavel neste repo).
---

Ponto de entrada único do ciclo. A partir do ID do card (ou de uma descrição livre, no modo manual), resolve o tracker, decide a rota e já carrega o contexto — você não redigita nada.

## 0. Resolver modo, tracker e config do repo

```bash
source ~/.claude/bin/get-project.sh
PROJECT_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
PROJECT_NAME="$(get-project-name)"
WF_DIR="$HOME/.claude/workflow/$PROJECT_NAME"
```

### Parsing do argumento

1. Remova primeiro as flags conhecidas: `--org=…`, `--project=…`, `--manual`, `--bug`, `--feature`. Na forma multilinha (ver "Modo manual"), flags só são lidas da **primeira linha**; o corpo nunca é parseado.
2. Combinações inválidas — **pare com erro**, sem criar nada:
   - `--manual` junto com `--org=`/`--project=` → "modo manual não tem tracker; remova as flags de tracker".
   - `--bug` junto com `--feature` → "escolha um tipo só".
3. Decida o modo:
   - Sem `--manual` e sobra **exatamente um** token que casa com `^#?\d+$` ou `^[A-Za-z][A-Za-z0-9]*-\d+$` → **modo ID** (resto deste passo e passos 1-7). Se veio `--bug`/`--feature`, avise "flag de tipo ignorada com ID" e siga a triage do tracker.
   - Sem argumento nenhum (nem flag, nem texto) → pergunte a descrição do trabalho (1 pergunta) e siga no **modo manual**.
   - Qualquer outro caso (`--manual`, texto livre, mais de um token, token que não é ID) → **modo manual**. Sem `--manual` explícito, anuncie "sem ID de card → modo manual". `--manual` sem descrição → pergunte a descrição (1 pergunta).

No modo manual, **pule o resto deste passo e o passo 1** e vá para a seção "Modo manual".

### Tracker (modo ID)

O tracker é propriedade da **org**, não da invocação nem da forma do ID (uma key `LC-101` tanto pode ser Jira quanto Linear). Ele vive em `orgs[].tracker` do `~/.claude/workflow/.dashboard.json`, editado no app em Configurações → org → Tracker. Resolva e normalize o ID:

```bash
python3 ~/.claude/bin/tracker.py resolve "$PROJECT_PATH"            # {"org", "tracker"}
REF=$(python3 ~/.claude/bin/tracker.py ref "<ID>" "$PROJECT_PATH")  # {"kind", "id", "url"}
```

- `tracker` `null` → **pare**: "a org `<org>` não tem tracker configurado: configure em Configurações → org → Tracker, ou rode `/kickoff --manual`". Com `org` `null`: "este repo não está em nenhuma org do app". Não chute o tracker.
- `ref` sai com código 2 → **pare** repassando o stderr (ex.: "ID 'LC-101' nao e um card de ado"). Ele já normaliza: `#123` → `123`, `lc-101` → `LC-101`, e um número em Jira/Linear ganha a chave do projeto/team (`101` → `LC-101`).

Daqui em diante, `<ID>` é o `id` do `REF` e `<KIND>` o `kind`.

| kind | Buscar o card | Refine | Exige RFC |
|---|---|---|---|
| `ado` | `~/.claude/bin/ado.sh` | `/ado-refine <ID>` | não |
| `jira` | `~/.claude/bin/jira.py` | `/jira-refine <ID>` | não |
| `linear` | MCP `linear` | `/linear-refine <ID>` | sim (features) |

Base e nome da branch vêm do `base` do tracker, não do kind:

| `base` | Base de branch | Nome de branch |
|---|---|---|
| `release` | última `release/*` no remoto, senão `main` | `<prefixo>/<versao>/<id>-<slug>` |
| ausente | branch padrão do remoto | `<prefixo>/<id-minusculo>-<slug>` |

### Override explícito

`--org=` / `--project=` sobrescrevem os campos de mesmo nome do tracker resolvido só nesta invocação (ex.: outro projeto ADO da mesma org). No ADO, exporte `ADO_ORG`/`ADO_PROJECT` antes de chamar o `ado.sh`; no Jira, `--project=` muda só o prefixo de um ID numérico (rode o `ref` de novo com a key completa).

Anuncie o resultado em uma linha antes de seguir: "Org `<org>` → **<kind>**, card `<ID>`, refine `/<skill>`, base `<base>`."

## 1. Pré-condições do tracker

**ADO:** acesso via `~/.claude/bin/ado.sh` (PAT + REST, headless-safe; PAT em `~/.claude/.ado_pat`, `AZURE_DEVOPS_EXT_PAT` ou `~/.claude.json`; org/projeto do tracker da org). **Não** dependemos do MCP `azure-devops` (auth interativa quebra).

**Jira:** acesso via `~/.claude/bin/jira.py` (API token + REST v3, headless-safe; token em `~/.claude/.jira_token` ou `JIRA_API_TOKEN`; site e email do tracker da org). Não dependemos do MCP do Atlassian pelo mesmo motivo do ADO. Se faltar token, **pare** e diga onde criá-lo (id.atlassian.com → Security → API tokens) e onde gravá-lo.

**Linear:** acesso via MCP `linear`. Se as únicas ferramentas `mcp__linear__*` disponíveis forem `authenticate` / `complete_authentication`, o server **não está logado** — pare e peça ao usuário para rodar `/mcp` e autenticar.

## 2. Checar fluxo em andamento

Leia `$WF_DIR/current.json` (se existir). Se `status` não for terminal (`verified`/ausente), ele conta como de **outro** card quando:
- não tem `tracker`, ou
- `tracker.kind` é diferente do `<KIND>` (inclusive `manual` × card), ou
- `tracker.id` é diferente do `<ID>`.

Nesse caso, **pare** com um `AskUserQuestion` (parada incondicional): "Já há um fluxo ativo em **PROJECT_NAME** (card X, status Y). Continuar (`/status`) ou resetar pra começar o <novo>?" — não clobber sem OK.

Resetar (só depois do OK do usuário): rode `python3 ~/.claude/bin/wf-report.py reset --workflow-dir "$WF_DIR" || true` antes de qualquer alteração no `current.json`.

No modo manual, a regra de mesma descrição está em "Modo manual" (M3).

## 3. Puxar o card

**ADO:**
```bash
~/.claude/bin/ado.sh get <ID>     # metadados (title, type, state, assignee, tags)
~/.claude/bin/ado.sh desc <ID>    # descricao + repro + criterios em texto plano
```

**Jira:**
```bash
~/.claude/bin/jira.py get <ID>    # metadados (title, type, state, assignee, labels, priority, parent, url)
~/.claude/bin/jira.py desc <ID>   # descricao em texto plano
```

**Linear:** busque a issue pela key via MCP `linear` — título, descrição, estado, labels, assignee, projeto/cycle, links, comentários relevantes. Se o `REF` veio com `url` `null` (tracker sem `workspace`), guarde a URL da issue que o MCP devolve como `CARD_URL`.

## 4. Triage bug/feature

**ADO e Jira** — classifique pelo `type`, case-insensitive por substring (os tipos reais variam: `Bug`, `Bug USs`, etc.):
- contém `bug` → **bug**
- resto (`User Story`, `Story`, `Feature`, `Task`, `Product Backlog Item`, `Epic`, ...) → **feature**
- Jira: um `Task` de pura manutenção (dependência, config, CI), pela descrição, é **chore** (vai pro `/fix`).

**Linear** — classifique pelo **conteúdo primeiro**; a label é desempate, não fonte:

1. Descrição em formato de defeito (repro, esperado vs. obtido, "parou de funcionar") → **bug**
2. Proposta com RFC linkada e/ou critérios de aceite de comportamento novo → **feature**
3. Manutenção sem escopo de produto (dependência, config, CI) → **chore** (vai pro `/fix`)
4. Só quando o conteúdo for genuinamente ambíguo, use a label `bug`/`feature`/`chore` como desempate.

**Não confie nas labels.** Workspaces costumam carregar taxonomia de auditoria e severidade que não mapeia para bug/feature: uma issue com `bug` + severidade alta pode ser feature com RFC aprovada, e uma com label de plataforma pode ser 100% de outra camada.

Labels de plataforma (`mobile`, `api`, `web`) também erram — **confirme o escopo lendo a descrição**, não a label, antes de decidir qual app vai ser tocado.

Ao apresentar a classificação, **diga quando ela contraria a label** e por quê. É informação que o usuário usa pra corrigir o card.

Apresente: "Card <id> — «<título>» (<tipo>) classificado como **<bug|feature>**."

Gate: se `~/.claude/workflow/auto_mode.flag` **não** existe, confirme a classificação com o usuário (1 pergunta). Se existe (auto on), prossiga.

## 4a. Checagem de implementabilidade (só rota FEATURE)

Bug sempre segue pra `/fix`. **Feature exige um segundo julgamento pelo CONTEÚDO** (não pelo tipo): nem todo card é uma feature implementável em PR **neste repo**. Antes de seguir, avalie os sinais:

- Auditoria / investigação / levantamento ("levantar", "documentar gaps", "mapear")
- Entregável é relatório/decisão, não uma mudança de código bem-definida
- Escopo fora do repo atual:
  - repo de app único (ex. um app mobile) — card cross-platform ou explicitamente backend/server-side ("vale pros dois OSes", "enforcement no backend", infra, API)
  - monorepo — card que cai fora de `apps/*` e `packages/*`, ou que é puramente de infra/ops sem mudança de código

Se **nenhum** sinal → prossiga normal (4b → 6). Se **houver** sinal, **pare com um `AskUserQuestion` de 3 rotas** (parada incondicional, mesmo com auto on — esta decisão não é automatizável):

1. **refine-only** — invoque o refine do tracker (tabela do passo 0) para investigar o card no codebase (o que existe, onde vive, gaps) e postar os achados. **Sem** seed/branch/specify. É a rota certa pra auditoria.
2. **Feature completa** — segue 4b → 6 (o usuário assume que há escopo implementável aqui).
3. **Abortar** — card não é pra este fluxo/repo; encerra limpo (nada criado) e o usuário redireciona.

Execute conforme a escolha. Rota 1: invoque o refine e encerre. Rota 3: pare aqui.

## 4b. Preparar branch de trabalho (rota BUG e FEATURE completa)

> Pule este passo nas rotas refine-only e abortar (não há código a mudar ainda).

Nunca começar o card na branch de outro trabalho. Prepare o isolamento:

```bash
# 1) mudanças pendentes? stasha (só anuncie o stash, sem pedir confirmação)
[ -n "$(git status --porcelain)" ] && git stash push -u -m "kickoff-<id>-wip"
```

**Base e nome da branch seguem o `base` do tracker (passo 0).** Prefixo: bug/chore → `fix`, feature → `feat`.

`base: "release"` (base = `release/X.Y.Z` ou `release/X.Y.Z/main` da maior versão, via `release-base.sh`; senão `main`):
```bash
# helper: 1a linha = base, 2a = versão X.Y.Z; exit 3 = só sufixos não-main (stdout = candidatas); exit 1 = sem release
RB=$(git ls-remote --heads origin 'release/*' | awk '{print $2}' | sed 's|refs/heads/||' | ~/.claude/bin/release-base.sh) && rc=0 || rc=$?
case "$rc" in
  0) BASE=$(sed -n 1p <<<"$RB"); VERSAO=$(sed -n 2p <<<"$RB") ;;
  3) ;;   # AskUserQuestion com as candidatas em $RB; BASE = escolha, VERSAO = X.Y.Z do nome da branch
  *) BASE=main ;;
esac
git fetch origin "$BASE" --quiet
# versão X.Y.Z é sempre a do nome da base (release/3.11.0/main → 3.11.0); com BASE=main, nome sem versão
SLUG=$(~/.claude/bin/to-slug.sh "<título curto do card>")
git checkout -b "<prefixo>/<versao>/<id>-$SLUG" "origin/$BASE"
```

Sem `base` (branch padrão do remoto):
```bash
BASE=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
[ -z "$BASE" ] && BASE=$(git ls-remote --symref origin HEAD 2>/dev/null | awk '/^ref:/ {sub("refs/heads/", "", $2); print $2}')
BASE=${BASE:-main}
git fetch origin "$BASE" --quiet
SLUG=$(~/.claude/bin/to-slug.sh "<título curto do card>")
git checkout -b "<prefixo>/<id-minusculo>-$SLUG" "origin/$BASE"   # ex: feat/lc-101-refresh-token
```

Se a base for `release/*`, faça um `AskUserQuestion` para confirmar a base antes do checkout (parada incondicional; release errada é custosa). Com a branch padrão e no `checkout -b` de branch nova, apenas anuncie, sem gate. Se houve stash, anuncie que há um `stash` pendente da branch anterior.

## 5. Rota BUG

Não semeia `current.json` (não polui o estado do Flow Smart). Apresente:

- Resumo do bug (root cause provável se os repro steps derem pista), em 2-3 linhas.
- Instrução: "Bug — pulando refino. Rodando `/fix` com esse contexto." E **invoque `/fix`** passando o contexto do card como bug report.
- Lembrete de vínculo do PR: "Ao abrir o PR, rode `/pr-open <ID>` — o card não está no current.json nesta rota."

Encerre após o `/fix` assumir.

## 6. Rota FEATURE

### 6a. Semear a spine no current.json

`tracker` é o `REF` do passo 0 (`{"kind", "id", "url"}`); no Linear sem `url`, passe o `CARD_URL` do passo 3 como terceiro argumento.

```bash
python3 - "$WF_DIR" "$REF" "${CARD_URL:-}" <<'PY'
import json, os, sys
sys.path.insert(0, os.path.expanduser('~/.claude/bin'))
from current_json import update_current_json
ref = json.loads(sys.argv[2])
if sys.argv[3]:
    ref['url'] = sys.argv[3]
seed = {'tracker': ref, 'work_item_type': 'feature', 'status': 'triaged'}
def m(d):
    for k in ('feature', 'start_date', 'end_date', 'phases', 'manual_description'):
        d.pop(k, None)
    d.update(seed); d.setdefault('status', 'triaged'); return d
update_current_json(sys.argv[1], m, default=seed)
PY
```

Relatório: início da etapa, só depois do seed.

```bash
python3 ~/.claude/bin/wf-report.py stage-start kickoff --workflow-dir "$WF_DIR" ${CLAUDE_FLOW_SESSION_ID:+--session "$CLAUDE_FLOW_SESSION_ID"} || true
```

### 6b. Refinar

**Invoque o refine do tracker** (tabela do passo 0) com o `<ID>`. Gera o detalhamento técnico em `$WF_DIR/details/<slug>.md` e (com seu OK) comenta no card. Aguarde ele concluir.

### 6c. Especificar

Relatório: fim da etapa. Escreva com **Write** um resumo de 3 a 10 linhas em `$WF_DIR/.stage-summary.md` (nunca interpole texto em shell) e rode:

```bash
python3 ~/.claude/bin/wf-report.py stage-end kickoff --workflow-dir "$WF_DIR" --summary-file "$WF_DIR/.stage-summary.md" || true
```

**Invoque `/specify`** usando como descrição de entrada: o card (título + descrição + critérios de aceite) **+ o doc de refino recém-gerado** (`$WF_DIR/details/<slug>.md`). Na rota Linear, inclua também a **RFC** lida no refine — ela é o input principal da spec. Diga ao `/specify` explicitamente para se basear nesse material em vez de pedir a descrição ao usuário.

A partir daí o Flow Smart segue seu curso normal (specify → challenge-spec → plan → tasks → implement → verify → complete), com os gates conforme `auto_mode.flag`. Implement e verify rodam como workflows com escada de modelos; `blocked`/`backtrack` sempre param para decisão humana.

Vínculo do PR no fim do ciclo: o `tracker` já está no `current.json`, então `/pr-open` vincula o PR sozinho.

## Modo manual

Trabalho sem card: ideia, ajuste pessoal, org sem tracker. Entra no mesmo pipeline a partir de uma descrição livre.

### M1. Forma do comando

Forma canônica (é o que o app manda):

```
/kickoff --manual [--bug|--feature]

<descrição verbatim, várias linhas>
```

- Primeira linha: só o comando e as flags.
- Depois, uma linha em branco e a descrição **verbatim** — sem aspas, sem escape. Tudo que vem depois da primeira quebra de linha é a descrição literal (descarte só a linha em branco separadora). Aspas, crases, `\`, `$(…)` dentro dela são texto, nunca comando.
- No terminal, a forma de uma linha `/kickoff --manual "<texto>"` também vale: tire **só** as aspas externas.
- Texto livre sem `--manual` (passo 0) é a descrição inteira, como veio.

O engine não faz parsing do comando: ele chega como mensagem de usuário. Não reescreva, resuma nem "corrija" a descrição — ela é gravada exatamente como recebida.

### M2. Pré-condições

- Sem tracker: pule a resolução de tracker do passo 0, as pré-condições do passo 1 e a exigência de RFC — em qualquer org, com ou sem tracker, e fora delas.
- Fora de repositório git (`git rev-parse --show-toplevel` falha) → **pare**: "modo manual precisa de um repositório git".

Grave a descrição com a ferramenta **Write** em `$WF_DIR/manual-description.md` (crie `$WF_DIR` com `mkdir -p "$WF_DIR"` se faltar). Um kickoff novo sobrescreve o arquivo. Daqui em diante, **nenhum texto do usuário entra em shell**: nem em `python3 -c`, nem em `to-slug.sh`, nem em mensagem de stash/commit. Quem precisa da descrição lê o arquivo.

### M3. Fluxo em andamento

Aplique o passo 2. Um fluxo não terminal sem `tracker`, ou com um card, conta como outro card. Com `tracker.kind` `manual`, compare a descrição:

```bash
python3 - "$WF_DIR" <<'PY'
import json, os, sys
wf = sys.argv[1]
desc = open(os.path.join(wf, 'manual-description.md'), encoding='utf-8').read()
try:
    cur = json.load(open(os.path.join(wf, 'current.json'), encoding='utf-8'))
except FileNotFoundError:
    cur = {}
active = cur.get('status') not in (None, 'verified')
tracker = cur.get('tracker') if isinstance(cur.get('tracker'), dict) else {}
if not active:
    print('NO_ACTIVE_FLOW')
elif tracker.get('kind') == 'manual' and (cur.get('manual_description') or '').strip() == desc.strip():
    print('SAME_MANUAL_FLOW', cur.get('status'))
else:
    print('OTHER_FLOW', tracker.get('kind') or '-', tracker.get('id') or '-', cur.get('status'))
PY
```

- `SAME_MANUAL_FLOW` → é o mesmo trabalho: ofereça `/status` e **não** re-semeie nem crie branch.
- `OTHER_FLOW` → pare e pergunte como no passo 2.
- `NO_ACTIVE_FLOW` → siga.

### M4. Triage pelo texto

- Defeito (repro, esperado × obtido, "parou de funcionar") → **bug**
- Manutenção sem escopo de produto (dependência, config, CI) → **chore**
- O resto → **feature**

`--bug`/`--feature` forçam o tipo (sem julgamento). Apresente: "Modo manual — «<título curto>» classificado como **<bug|chore|feature>**." Gate de confirmação igual ao passo 4 (`auto_mode.flag`). A checagem 4a **não** se aplica.

### M5. Branch

Derive um **título curto** da descrição contendo só letras, dígitos, espaços e hífens (sem aspas, crase nem `$`) e passe-o entre aspas simples para o `to-slug.sh`. Nome: `fix/<slug>` (bug/chore) ou `feat/<slug>` (feature).

```bash
SLUG=$(~/.claude/bin/to-slug.sh '<título curto>')
BRANCH="<feat|fix>/$SLUG"
[ -n "$(git status --porcelain)" ] && git stash push -u -m "kickoff-manual-$SLUG-wip"
```

Base:
- Org com tracker de `base: "release"` (`tracker.py resolve`) → a última `release/*` no remoto, senão `main`, como no passo 4b (confirme com `AskUserQuestion` só se for `release/*`).
- Senão, a branch padrão do remoto:

```bash
BASE=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
[ -z "$BASE" ] && BASE=$(git ls-remote --symref origin HEAD 2>/dev/null | awk '/^ref:/ {sub("refs/heads/", "", $2); print $2}')
BASE=${BASE:-main}
```

Checkout:

```bash
if git remote get-url origin >/dev/null 2>&1; then
  git fetch origin "$BASE" --quiet
  START="origin/$BASE"
else
  START=$(git rev-parse --verify --quiet refs/heads/main >/dev/null && echo main || echo HEAD)
fi
git show-ref --verify --quiet "refs/heads/$BRANCH" && echo BRANCH_EXISTS
```

- Sem remoto `origin`: base `main` local (ou o HEAD atual), sem fetch — avise "sem `origin`: branch criada a partir de `<START>` local".
- `BRANCH_EXISTS` → **`AskUserQuestion`** (parada incondicional): reusar (`git checkout "$BRANCH"`) ou criar com sufixo `-2` (`BRANCH="$BRANCH-2"`).
- Senão: `git checkout -b "$BRANCH" "$START"`.

Stash e `checkout -b` de branch nova são só anunciados. Se houve stash, anuncie que há um stash `kickoff-manual-<slug>-wip` pendente.

### M6. Rotas

Antes de invocar `/fix` ou `/specify`, imprima: "modo manual: `/pr-open` não vincula tracker".

**Bug/chore** → sem seed. **Invoque `/fix`** passando a descrição (conteúdo de `$WF_DIR/manual-description.md`) como bug report. Encerre após o `/fix` assumir.

**Feature** → semeie a spine lendo a descrição do arquivo, sem refine:

```bash
python3 - "$WF_DIR" <<'PY'
import os, sys
wf = sys.argv[1]
sys.path.insert(0, os.path.expanduser('~/.claude/bin'))
from current_json import update_current_json
desc = open(os.path.join(wf, 'manual-description.md'), encoding='utf-8').read()
seed = {'tracker': {'kind': 'manual'}, 'manual_description': desc, 'work_item_type': 'feature', 'status': 'triaged'}
def m(d):
    for k in ('feature', 'start_date', 'end_date', 'phases'):
        d.pop(k, None)
    d.update(seed)
    return d
update_current_json(wf, m, default=seed)
PY
```

Relatório: início da etapa, só depois do seed.

```bash
python3 ~/.claude/bin/wf-report.py stage-start kickoff --workflow-dir "$WF_DIR" ${CLAUDE_FLOW_SESSION_ID:+--session "$CLAUDE_FLOW_SESSION_ID"} || true
```

Relatório: fim da etapa. Escreva com **Write** um resumo de 3 a 10 linhas em `$WF_DIR/.stage-summary.md` (nunca interpole texto em shell) e rode:

```bash
python3 ~/.claude/bin/wf-report.py stage-end kickoff --workflow-dir "$WF_DIR" --summary-file "$WF_DIR/.stage-summary.md" || true
```

Depois **invoque `/specify`** com a descrição (conteúdo de `$WF_DIR/manual-description.md`) como entrada, dizendo explicitamente para se basear nela em vez de pedir a descrição ao usuário. O Flow Smart segue como na rota FEATURE. No fim do ciclo, `/pr-open` abre o PR sem vínculo de tracker.

## 7. Não fazer

- Não mudar estado/assignee do card (ADO: isso é do `/ado-close`; Jira/Linear: é decisão do usuário).
- Não abrir PR aqui — isso é do `/pr-open`, no fim do ciclo.
- Não assumir tracker por hábito nem pela forma do ID. A org manda; sem tracker configurado, pare.
- Não interpolar a descrição do modo manual em shell nem reescrevê-la.
