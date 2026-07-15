---
name: ado-refine
model: opus
description: Pega um work item do Azure DevOps pelo ID, entende a regra de negocio, e gera detalhamento tecnico fundamentado no codigo do projeto. Opcionalmente posta o detalhamento como comentario no card.
---

Skill que orquestra: buscar work item do Azure DevOps → entender contexto → gerar detalhamento tecnico (mesma logica do `/refine`) → opcionalmente comentar de volta no card.

## Defaults

- **Org:** `<your-org>`
- **Project:** `<your-project>`

Sobrescritos por `--org=...` / `--project=...` nos args. Primeiro argumento numerico = ID do work item.

## 1. Pre-condicoes

- Argumento obrigatorio: ID numerico do work item.
- Acesso ao ADO via `~/.claude/bin/ado.sh` (PAT + REST, headless-safe; PAT lido de `~/.claude.json`). **Nao** dependemos do MCP `azure-devops` (auth interativa quebra).

## 2. Detectar projeto local

```bash
PROJECT_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
PROJECT_NAME=$(basename "$PROJECT_PATH")
DETAILS_DIR="$HOME/.claude/workflow/$PROJECT_NAME/details"
mkdir -p "$DETAILS_DIR"
```

## 3. Puxar o work item

```bash
~/.claude/bin/ado.sh get <id>     # title, type, state, assignee, tags
~/.claude/bin/ado.sh desc <id>    # descricao + repro + criterios em texto plano (HTML ja limpo)
```

Para org/project alternativos (outra org/projeto), exporte `ADO_ORG` / `ADO_PROJECT` antes de chamar. Se precisar de campos que o helper nao expoe (parent links, areaPath, iterationPath), use `ado.sh raw <id>` e leia o JSON cru.

## 4. Reconhecimento do codebase local

Antes de detalhar tecnicamente, fundamente no codigo real:

1. Leia `CLAUDE.md` do projeto e `DESIGN.md` se existirem.
2. A partir do titulo + descricao do work item, identifique diretorios/arquivos mais provaveis de serem tocados. Liste e leia os relevantes.
3. Procure componentes/servicos reutilizaveis com `grep` antes de propor coisa nova.
4. Se a tarefa toca contratos (APIs, models, BLoC events/states), leia os atuais.

Se a busca for ampla (>3 queries), use o agent `Explore`.

## 5. Casar regra de negocio com codigo

- Reformule o problema do work item com suas palavras.
- Liste regras de negocio explicitas e implicitas.
- Liste cenarios provavelmente nao mencionados (estados vazios, erro, concorrencia, offline).
- Aponte conflitos com regras de negocio ja codificadas.

Se algo critico estiver ambiguo, **pergunte ao usuario antes de seguir**.

## 6. Gerar o detalhamento

Crie `$DETAILS_DIR/<slug>.md` onde:

```bash
SLUG="$(date +%Y%m%d-%H%M)-ado<id>-<titulo-em-kebab-case>"
```

### Estrutura do documento

```markdown
# ADO #<id> — <titulo>

> Gerado por /ado-refine em <data>.
> Origem: <url do work item no Azure DevOps>
> Tipo: <type> · Estado: <state> · Assignee: <assignedTo>

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
3. **Pergunte:** "Quer que eu poste esse detalhamento como comentario no work item #<id>?"
   - Se sim → `~/.claude/bin/ado.sh comment <id> "<html>"`. Poste um resumo (nao o markdown inteiro) com link/path para o doc completo, ou o markdown convertido pra HTML se o usuario pedir o conteudo completo. O endpoint aceita HTML (use `<b>`, `<br>`, `<code>`).
   - Se nao → encerre.

Nao mude estado do work item (assignee, state, iteration) — isso e responsabilidade de outras skills (`/ado-close`).

## 8. Iteracao

Se o usuario pedir ajustes apos a revisao, edite o arquivo no lugar — nao gere novo slug. Se atualizar o comentario no card depois, o `ado.sh` sempre adiciona um novo comentario (nao edita); avise o usuario disso.
