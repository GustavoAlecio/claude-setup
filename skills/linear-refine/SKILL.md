---
name: linear-refine
model: opus
description: Pega uma issue do Linear pela key (ex. LC-101), entende a regra de negocio, le a RFC linkada e gera detalhamento tecnico fundamentado no codigo do projeto. Opcionalmente posta o detalhamento como comentario na issue.
---

Skill que orquestra: buscar issue do Linear → ler a RFC linkada → entender contexto → gerar detalhamento tecnico (mesma logica do `/refine`) → opcionalmente comentar de volta na issue.

Equivalente Linear do `/ado-refine`, para orgs cujo `tracker` é Linear.

## 1. Pre-condicoes

- Argumento obrigatorio: key da issue (`LC-101`) ou so o numero (`101`) — nesse caso prefixe com o team key do repo (ver tabela no `/kickoff`).
- Acesso via MCP `linear`. **Se as unicas ferramentas `mcp__linear__*` disponiveis forem `authenticate` / `complete_authentication`, o server nao esta logado**: pare e peca ao usuario para rodar `/mcp` e autenticar. Nao tente contornar.

## 2. Detectar projeto local

```bash
PROJECT_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
source ~/.claude/bin/get-project.sh
PROJECT_NAME=$(get-project-name)
DETAILS_DIR="$HOME/.claude/workflow/$PROJECT_NAME/details"
mkdir -p "$DETAILS_DIR"
```

## 3. Puxar a issue

Via MCP `linear`, busque a issue pela key. Capture: titulo, descricao, estado, labels, assignee, projeto/cycle, links e comentarios relevantes.

## 3a. Ler a RFC linkada

Issues de feature costumam apontar para uma RFC — no campo/link `RFC`, nas referencias, ou citada na descricao (`RFC-00XX`).

- Repos com submodule `docs/`: a RFC vive em `docs/produtos/<produto>/rfcs/`. Se `docs/` estiver vazio, rode `git submodule update --init --recursive` antes.
- **A RFC e o input principal do detalhamento** — pesa mais que a descricao da issue. Leia inteira.
- Se a issue exige RFC (ver tabela do `/kickoff`) e nao tem nenhuma linkada, avise o usuario e pergunte se segue mesmo assim ou se e caso de `/rfc-new` antes.
- Bug/chore nao precisa de RFC — siga direto.

## 4. Reconhecimento do codebase local

Antes de detalhar tecnicamente, fundamente no codigo real:

1. Leia o `CLAUDE.md` da raiz e o do app afetado (`apps/<app>/CLAUDE.md`), mais a guideline correspondente em `docs/guidelines/`. **Mapa da org:** se existir `.map/index.md` no repo ou numa pasta acima (nunca procure abaixo), leia o índice e as notas/gerados relevantes antes de grep/`Explore`. Nota marcada STALE não é confiável: confira as âncoras. O mapa descreve `origin/development`; confira o diff da branch por cima.
2. Leia a ADR relacionada se a issue toca um entry point documentado em `docs/produtos/<produto>/adrs/`.
3. A partir do titulo + descricao + RFC, identifique diretorios/arquivos mais provaveis de serem tocados. Liste e leia os relevantes.
4. Procure componentes/servicos reutilizaveis com `grep` antes de propor coisa nova.
5. Se a tarefa toca contratos (rotas, Prisma schema, tipos em `packages/shared`), leia os atuais.

Se a busca for ampla (>3 queries), use o agent `Explore`.

## 5. Casar regra de negocio com codigo

- Reformule o problema da issue com suas palavras.
- Liste regras de negocio explicitas e implicitas.
- Liste cenarios provavelmente nao mencionados (estados vazios, erro, concorrencia, offline).
- Aponte conflitos com regras de negocio ja codificadas, e divergencias entre a RFC e o codigo atual.

Se algo critico estiver ambiguo, **pergunte ao usuario antes de seguir**.

## 6. Gerar o detalhamento

Crie `$DETAILS_DIR/<slug>.md` onde:

```bash
SLUG="$(date +%Y%m%d-%H%M)-<issue-key-minusculo>-<titulo-em-kebab-case>"
```

### Estrutura do documento

```markdown
# <KEY> — <titulo>

> Gerado por /linear-refine em <data>.
> Origem: <url da issue no Linear>
> Estado: <state> · Labels: <labels> · Assignee: <assignee>
> RFC: <caminho/link da RFC, ou "n/a">

## Contexto
- **O que foi pedido na issue:** <resumo da descricao>
- **O que a RFC define:** <decisoes que a RFC ja fechou>
- **Problema de negocio:** <por que isso importa>
- **Estado atual do codigo:** <o que ja existe, com paths>

## Regras de negocio
- Lista objetiva

## Escopo tecnico
### O que muda
- `path/arquivo.ts` — descricao

### O que e criado
- Novos arquivos/classes/funcoes

### O que e reaproveitado
- Componentes existentes

## Contratos e interfaces
- Rotas, Prisma schema, `packages/shared`, tipos consumidos por web/mobile; compatibilidade.
- Sinalize cross-cutting: mudanca de schema que afeta o web, rota consumida pelo mobile (nao tem codegen — vira issue de follow-up).

## Fluxos e estados
- Happy path + estados relevantes (loading, error, empty).

## Edge cases tecnicos
- So os que se aplicam (concorrencia, rede, permissoes, perf, offline).

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
   - Se sim → crie o comentario via MCP `linear`. Poste um resumo em markdown (nao o doc inteiro) com o caminho do doc completo. So poste o conteudo integral se o usuario pedir.
   - Se nao → encerre.

Nao mude estado, assignee nem estimativa da issue — isso e decisao do usuario.

## 8. Iteracao

Se o usuario pedir ajustes apos a revisao, edite o arquivo no lugar — nao gere novo slug. Comentario ja postado nao e editado; um novo comentario e adicionado. Avise o usuario disso.
