---
name: kickoff
model: opus
description: Entrada do pipeline — com ID de card, detecta o tracker pela raiz do repo (ADO ou Linear), puxa o card/issue e faz triage bug/feature/auditoria; sem ID (ou com --manual), entra no modo manual a partir de uma descricao livre, sem tracker. Semeia a spine no current.json e encadeia refine->specify (feature), aponta /fix (bug/chore), ou refine-only/abort (card nao-implementavel neste repo).
---

Ponto de entrada único do ciclo. A partir do ID do card (ou de uma descrição livre, no modo manual), decide o tracker, decide a rota e já carrega o contexto — você não redigita nada.

## 0. Resolver modo, tracker e config do repo

```bash
source ~/.claude/bin/get-project.sh
PROJECT_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
PROJECT_NAME="$(get-project-name)"
WF_DIR="$HOME/.claude/workflow/$PROJECT_NAME"
```

### Parsing do argumento

1. Remova primeiro as flags conhecidas: `--ado`, `--az`, `--linear`, `--l`, `--org=…`, `--project=…`, `--manual`, `--bug`, `--feature`. Na forma multilinha (ver "Modo manual"), flags só são lidas da **primeira linha**; o corpo nunca é parseado.
2. Combinações inválidas — **pare com erro**, sem criar nada:
   - `--manual` junto com `--ado`/`--az`/`--linear`/`--l`/`--org=`/`--project=` → "modo manual não tem tracker; remova as flags de tracker".
   - `--bug` junto com `--feature` → "escolha um tipo só".
3. Decida o modo:
   - Sem `--manual` e sobra **exatamente um** token que casa com `^\d+$` ou `^[A-Z][A-Z0-9]*-\d+$` → **modo ID** (resto deste passo e passos 1-7). Se veio `--bug`/`--feature`, avise "flag de tipo ignorada com ID" e siga a triage do tracker.
   - Sem argumento nenhum (nem flag, nem texto) → pergunte a descrição do trabalho (1 pergunta) e siga no **modo manual**.
   - Qualquer outro caso (`--manual`, texto livre, mais de um token, token que não é ID) → **modo manual**. Sem `--manual` explícito, anuncie "sem ID de card → modo manual". `--manual` sem descrição → pergunte a descrição (1 pergunta).

No modo manual, **pule o resto deste passo e o passo 1** e vá para a seção "Modo manual".

### Tracker (modo ID)

O tracker é propriedade do **repositório**, não da invocação. Resolva por `$PROJECT_PATH`:

| Raiz | Tracker | Refine | Base de branch | Nome de branch | Exige RFC |
|---|---|---|---|---|---|
| `<ado-root>/**` | **ADO** — org `<your-org>`, project `<your-project>` | `/ado-refine` | última `release/*` no remoto, senão `main` | `<tipo>/<versao>/<id>-<slug>` | não |
| `<linear-root>/**` | **Linear** | `/linear-refine` | `main` | `<tipo>/<key-minusculo>-<slug>` | sim (features) |
| qualquer outra | — | — | — | — | — |

Repo Linear sem team key conhecido: pergunte o team key antes de seguir.

Fora das duas raízes conhecidas, **pare** e pergunte qual tracker usar — não chute. (Trabalho sem card nesses repos é o modo manual.)

### Override explícito

- `--ado` / `--az` → força ADO. Aceita `--org=` / `--project=`.
- `--linear` / `--l` → força Linear.

**Se o flag contradiz o path, pare e confirme** ("`--az` num repo da raiz Linear — o card #X é mesmo do ADO?"). Semear a spine do tracker errado só aparece lá no `/pr-open`, e aí já custou.

### Forma do ID

- Numérico puro (`12345`) → ID do ADO.
- Key (`ENG-101`) → issue do Linear; o prefixo já identifica o team.
- Numérico com `--l` → prefixe com o team key do repo (`101` com team key `ENG` → `ENG-101`).

Anuncie o resultado em uma linha antes de seguir: "Repo `<nome>` → tracker **<ADO|Linear>**, refine `/<skill>`, base `<base>`."

## 1. Pré-condições do tracker

**ADO:** acesso via `~/.claude/bin/ado.sh` (PAT + REST, headless-safe; PAT lido de `~/.claude.json`). **Não** dependemos do MCP `azure-devops` (auth interativa quebra).

**Linear:** acesso via MCP `linear`. Se as únicas ferramentas `mcp__linear__*` disponíveis forem `authenticate` / `complete_authentication`, o server **não está logado** — pare e peça ao usuário para rodar `/mcp` e autenticar.

## 2. Checar fluxo em andamento

Leia `$WF_DIR/current.json` (se existir). Se `status` não for terminal (`verified`/ausente), ele conta como de **outro** card quando:
- o tracker é diferente do novo kickoff (inclusive `manual` × ADO/Linear), ou
- não tem chave de tracker (`tracker`, `ado_id`, `linear_key` ausentes), ou
- tem `ado_id`/`linear_key` diferente do novo ID.

Nesse caso, **pare** e pergunte: "Já há um fluxo ativo em **PROJECT_NAME** (card X, status Y). Continuar (`/status`) ou resetar pra começar o <novo>?" — não clobber sem OK.

No modo manual, a regra de mesma descrição está em "Modo manual" (M3).

## 3. Puxar o card

**Rota ADO:**
```bash
~/.claude/bin/ado.sh get <id>     # metadados (title, type, state, assignee, tags)
~/.claude/bin/ado.sh desc <id>    # descricao + repro + criterios em texto plano
```

**Rota Linear:** busque a issue pela key via MCP `linear` — título, descrição, estado, labels, assignee, projeto/cycle, links, comentários relevantes.

## 4. Triage bug/feature

**ADO** — classifique pelo `type`, case-insensitive por substring (os tipos reais variam: `Bug`, `Bug USs`, etc.):
- contém `bug` → **bug**
- resto (`User Story`, `Feature`, `Task`, `Product Backlog Item`, ...) → **feature**

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

Se **nenhum** sinal → prossiga normal (4b → 6). Se **houver** sinal, **pare e ofereça 3 rotas** (mesmo com auto on — esta decisão não é automatizável):

1. **refine-only** — invoque o refine do tracker (`/ado-refine` ou `/linear-refine`) para investigar o card no codebase (o que existe, onde vive, gaps) e postar os achados. **Sem** seed/branch/specify. É a rota certa pra auditoria.
2. **Feature completa** — segue 4b → 6 (o usuário assume que há escopo implementável aqui).
3. **Abortar** — card não é pra este fluxo/repo; encerra limpo (nada criado) e o usuário redireciona.

Execute conforme a escolha. Rota 1: invoque o refine e encerre. Rota 3: pare aqui.

## 4b. Preparar branch de trabalho (rota BUG e FEATURE completa)

> Pule este passo nas rotas refine-only e abortar (não há código a mudar ainda).

Nunca começar o card na branch de outro trabalho. Prepare o isolamento:

```bash
# 1) mudanças pendentes? stasha (avisa o usuário do stash)
[ -n "$(git status --porcelain)" ] && git stash push -u -m "kickoff-<id>-wip"
```

**Base e nome da branch seguem a tabela do passo 0.**

Rota ADO (base = última `release/*`, senão `main`):
```bash
BASE=$(git ls-remote --heads origin 'release/*' | awk '{print $2}' | sed 's|refs/heads/||' | sort -V | tail -1)
BASE=${BASE:-main}
git fetch origin "$BASE" --quiet
# prefixo: bug→fix, feature→feat ; versao extraída da base (release/3.11.0 → 3.11.0)
SLUG=$(~/.claude/bin/to-slug.sh "<título curto do card>")
git checkout -b "<prefixo>/<versao>/<id>-$SLUG" "origin/$BASE"
```

Rota Linear (base = `main`):
```bash
BASE=main
git fetch origin "$BASE" --quiet
SLUG=$(~/.claude/bin/to-slug.sh "<título curto da issue>")
git checkout -b "<prefixo>/<key-minusculo>-$SLUG" "origin/$BASE"   # ex: feat/eng-101-refresh-token
```

**Confirme a base com o usuário** antes do checkout na rota ADO (release errada é custosa). Se houve stash, lembre o usuário ao final que há um `stash` pendente da branch anterior.

## 5. Rota BUG

Não semeia `current.json` (não polui o estado do Flow Smart). Apresente:

- Resumo do bug (root cause provável se os repro steps derem pista), em 2-3 linhas.
- Instrução: "Bug — pulando refino. Rodando `/fix` com esse contexto." E **invoque `/fix`** passando o contexto do card como bug report.
- Lembrete de vínculo do PR:
  - ADO: "Ao abrir o PR, rode `/pr-open <id>` (ou inclua `AB#<id>` no corpo) — o card não está no current.json nesta rota."
  - Linear: "Ao abrir o PR, inclua a key `<KEY>` no título ou o link da issue no corpo — `/pr-open` ainda não vincula Linear automaticamente."

Encerre após o `/fix` assumir.

## 6. Rota FEATURE

### 6a. Semear a spine no current.json

Rota ADO:
```bash
python3 -c "
import sys; sys.path.insert(0, '$HOME/.claude/bin')
from current_json import update_current_json
seed = {'tracker': 'ado', 'ado_id': <ADO_ID>, 'work_item_type': 'feature', 'status': 'triaged'}
def m(d):
    d.update(seed); d.setdefault('status', 'triaged'); return d
update_current_json('$WF_DIR', m, default=seed)
"
```

Rota Linear:
```bash
python3 -c "
import sys; sys.path.insert(0, '$HOME/.claude/bin')
from current_json import update_current_json
seed = {'tracker': 'linear', 'linear_key': '<KEY>', 'linear_url': '<URL>', 'work_item_type': 'feature', 'status': 'triaged'}
def m(d):
    d.update(seed); d.setdefault('status', 'triaged'); return d
update_current_json('$WF_DIR', m, default=seed)
"
```

### 6b. Refinar

**Invoque o refine do tracker** — `/ado-refine <id>` ou `/linear-refine <KEY>`. Gera o detalhamento técnico em `$WF_DIR/details/<slug>.md` e (com seu OK) comenta no card. Aguarde ele concluir.

### 6c. Especificar

**Invoque `/specify`** usando como descrição de entrada: o card (título + descrição + critérios de aceite) **+ o doc de refino recém-gerado** (`$WF_DIR/details/<slug>.md`). Na rota Linear, inclua também a **RFC** lida no refine — ela é o input principal da spec. Diga ao `/specify` explicitamente para se basear nesse material em vez de pedir a descrição ao usuário.

A partir daí o Flow Smart segue seu curso normal (specify → challenge-spec → plan → tasks → implement → verify → complete), com os gates conforme `auto_mode.flag`. Implement e verify rodam como workflows com escada de modelos; `blocked`/`backtrack` sempre param para decisão humana.

Vínculo do PR no fim do ciclo:
- ADO: `ado_id` já está no `current.json`, então `/pr-open` vincula o PR sozinho.
- Linear: `/pr-open` **ainda não lê `linear_key`** — ele abrirá o PR sem vínculo. Inclua a key no título do PR ou o link da issue no corpo.

## Modo manual

Trabalho sem card: ideia, ajuste pessoal, repo fora das raízes com tracker. Entra no mesmo pipeline a partir de uma descrição livre.

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

- Sem tracker: pule a tabela de raízes, as pré-condições de ADO/Linear (passo 1) e a exigência de RFC — em qualquer raiz, inclusive fora das conhecidas.
- Fora de repositório git (`git rev-parse --show-toplevel` falha) → **pare**: "modo manual precisa de um repositório git".

Grave a descrição com a ferramenta **Write** em `$WF_DIR/manual-description.md` (crie `$WF_DIR` com `mkdir -p "$WF_DIR"` se faltar). Um kickoff novo sobrescreve o arquivo. Daqui em diante, **nenhum texto do usuário entra em shell**: nem em `python3 -c`, nem em `to-slug.sh`, nem em mensagem de stash/commit. Quem precisa da descrição lê o arquivo.

### M3. Fluxo em andamento

Aplique o passo 2. Um fluxo não terminal sem chave de tracker, ou de tracker ADO/Linear, conta como outro card. Com `tracker: manual`, compare a descrição:

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
if not active:
    print('NO_ACTIVE_FLOW')
elif cur.get('tracker') == 'manual' and (cur.get('manual_description') or '').strip() == desc.strip():
    print('SAME_MANUAL_FLOW', cur.get('status'))
else:
    print('OTHER_FLOW', cur.get('tracker') or '-', cur.get('ado_id') or cur.get('linear_key') or '-', cur.get('status'))
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
- Raiz conhecida → a base do tracker da raiz (tabela do passo 0): ADO = última `release/*` no remoto, senão `main` (confirme com o usuário só se for `release/*`); Linear = `main`.
- Fora das raízes:

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
- `BRANCH_EXISTS` → **pergunte**: reusar (`git checkout "$BRANCH"`) ou criar com sufixo `-2` (`BRANCH="$BRANCH-2"`).
- Senão: `git checkout -b "$BRANCH" "$START"`.

Se houve stash, lembre ao final que há um stash `kickoff-manual-<slug>-wip` pendente.

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
seed = {'tracker': 'manual', 'manual_description': desc, 'work_item_type': 'feature', 'status': 'triaged'}
def m(d):
    for k in ('ado_id', 'linear_key', 'linear_url'):
        d.pop(k, None)
    d.update(seed)
    return d
update_current_json(wf, m, default=seed)
PY
```

Depois **invoque `/specify`** com a descrição (conteúdo de `$WF_DIR/manual-description.md`) como entrada, dizendo explicitamente para se basear nela em vez de pedir a descrição ao usuário. O Flow Smart segue como na rota FEATURE. No fim do ciclo, `/pr-open` abre o PR sem vínculo de tracker.

## 7. Não fazer

- Não mudar estado/assignee do card (ADO: isso é do `/ado-close`; Linear: é decisão do usuário).
- Não abrir PR aqui — isso é do `/pr-open`, no fim do ciclo.
- Não assumir tracker por hábito. Repo manda; flag só com confirmação quando contradiz.
- Não interpolar a descrição do modo manual em shell nem reescrevê-la.
