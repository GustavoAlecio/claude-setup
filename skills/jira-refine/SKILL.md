---
name: jira-refine
model: opus
description: Pega uma issue do Jira pela key (ex. LC-101), entende a regra de negocio, e gera detalhamento tecnico fundamentado no codigo do projeto. Opcionalmente posta o detalhamento como comentario na issue.
---

Skill que orquestra: buscar issue do Jira → entender contexto → gerar detalhamento tecnico (mesma logica do `/refine`) → opcionalmente comentar de volta no card.

## Defaults

- **Site / Projeto / Email:** os do tracker da org do repo (`orgs[].tracker` com `kind: jira` no `.dashboard.json`, configurado no app). O `jira.py` já os lê sozinho.

Primeiro argumento = key da issue. Um número puro ganha a chave do projeto: `python3 ~/.claude/bin/tracker.py ref <arg>` normaliza.

## 1. Pre-condicoes

- Argumento obrigatorio: key da issue.
- Acesso ao Jira via `~/.claude/bin/jira.py` (API token + REST v3, headless-safe; token em `~/.claude/.jira_token` ou `JIRA_API_TOKEN`). **Nao** dependemos do MCP do Atlassian (auth interativa quebra em sessao headless).

## 2. Detectar projeto local

```bash
PROJECT_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
source ~/.claude/bin/get-project.sh
PROJECT_NAME=$(get-project-name)
DETAILS_DIR="$HOME/.claude/workflow/$PROJECT_NAME/details"
mkdir -p "$DETAILS_DIR"
```

## 3. Puxar a issue

```bash
~/.claude/bin/jira.py get <KEY>     # title, type, state, assignee, labels, priority, parent, url
~/.claude/bin/jira.py desc <KEY>    # descricao em texto plano
```

Criterios de aceite costumam estar na descricao; se o projeto usar campo customizado, peca ao usuario o nome do campo. Issue com `parent` (epic/story): leia o pai com `jira.py desc <parent>` para contexto.

## 4. Reconhecimento do codebase local

Antes de detalhar tecnicamente, fundamente no codigo real:

1. Leia `CLAUDE.md` do projeto e `DESIGN.md` se existirem.
2. A partir do titulo + descricao da issue, identifique diretorios/arquivos mais provaveis de serem tocados. Liste e leia os relevantes.
3. Procure componentes/servicos reutilizaveis com `grep` antes de propor coisa nova.
4. Se a tarefa toca contratos (APIs, models, BLoC events/states), leia os atuais.

Se a busca for ampla (>3 queries), use o agent `Explore`.

## 5. Casar regra de negocio com codigo

- Reformule o problema da issue com suas palavras.
- Liste regras de negocio explicitas e implicitas.
- Liste cenarios provavelmente nao mencionados (estados vazios, erro, concorrencia, offline).
- Aponte conflitos com regras de negocio ja codificadas.

Se algo critico estiver ambiguo, **pergunte ao usuario antes de seguir**.

## 6. Gerar o detalhamento

Crie `$DETAILS_DIR/<slug>.md` onde:

```bash
SLUG="$(date +%Y%m%d-%H%M)-<key-minusculo>-<titulo-em-kebab-case>"
```

### Estrutura do documento

```markdown
# <KEY> — <titulo>

> Gerado por /jira-refine em <data>.
> Origem: <url da issue>
> Tipo: <type> · Estado: <state> · Assignee: <assignee>

## Contexto
- **O que foi pedido no card:** <resumo da descricao>
- **Problema de negocio:** <por que isso importa>
- **Estado atual do codigo:** <o que ja existe, com paths>

## Regras de negocio
- Lista objetiva

## Escopo tecnico
### O que muda
- `path/arquivo.dart` — descricao

### O que e criado
- Novos arquivos/classes/funcoes

### O que e reaproveitado
- Componentes existentes

## Contratos e interfaces
- Models, APIs, eventos, schemas afetados; compatibilidade.

## Fluxos e estados
- Happy path + estados relevantes (loading, error, empty).

## Edge cases tecnicos
- So os que se aplicam (concorrencia, rede, null safety, permissoes, perf, offline).

## Riscos e trade-offs

## Fora de escopo

## Perguntas em aberto
```

Adapte secoes ao escopo. Tarefa pequena dispensa secoes irrelevantes.

## 7. Apresentar e perguntar sobre o comentario

Apos gerar o arquivo:

1. Imprima o caminho absoluto do arquivo.
2. Resuma em 3-5 bullets os pontos criticos (decisoes, riscos, perguntas em aberto).
3. **Pergunte:** "Quer que eu poste esse detalhamento como comentario na issue <KEY>?"
   - Se sim → escreva o comentario com **Write** em `$DETAILS_DIR/.comment.md` (texto plano; paragrafos separados por linha em branco) e rode `~/.claude/bin/jira.py comment <KEY> "$DETAILS_DIR/.comment.md"`. Poste um resumo (nao o markdown inteiro) com o path do doc completo, salvo se o usuario pedir o conteudo completo.
   - Se nao → encerre.

Nao mude estado da issue (assignee, status, sprint) — isso e decisao do usuario.

## 8. Iteracao

Se o usuario pedir ajustes apos a revisao, edite o arquivo no lugar — nao gere novo slug. Se atualizar o comentario na issue depois, o `jira.py` sempre adiciona um novo comentario (nao edita); avise o usuario disso.
