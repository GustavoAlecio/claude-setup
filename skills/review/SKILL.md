---
name: review
model: opus
description: Fluxo Review etapa 1 — gera revisao detalhada de um PR aberto, usando agentes especializados por stack e foco. Comentarios inline propostos para validacao do usuario.
---

## 1. Detectar projeto
```bash
PROJECT_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
source ~/.claude/bin/get-project.sh
PROJECT_NAME=$(get-project-name)
REVIEWS_DIR="$HOME/.claude/workflow/$PROJECT_NAME/reviews"
mkdir -p "$REVIEWS_DIR"
```

Confirme que `gh` esta autenticado:
```bash
gh auth status
```
Se nao estiver, peca: "Execute `gh auth login` antes de continuar."

## 2. Determinar PR alvo

Se o usuario passou um numero de PR como argumento, use esse numero diretamente.

Se nao passou, liste PRs abertos:
```bash
gh pr list --json number,title,author,headRefName,updatedAt --limit 30 \
  --jq '.[] | "#\(.number) — \(.title) (@\(.author.login), \(.headRefName))"'
```

Apresente a lista numerada e pergunte qual PR revisar. Aguarde a resposta.

Guarde como `PR_NUM`.

## 3. Coletar contexto do PR
```bash
gh pr view "$PR_NUM" --json number,title,body,baseRefName,headRefName,author,files \
  > "$REVIEWS_DIR/PR-${PR_NUM}.meta.json"

gh pr diff "$PR_NUM" > "$REVIEWS_DIR/PR-${PR_NUM}.diff"
```

Leia ambos os arquivos. Liste os arquivos modificados:
```bash
jq -r '.files[].path' "$REVIEWS_DIR/PR-${PR_NUM}.meta.json"
```

## 4. Detectar stacks afetadas

Classifique cada arquivo modificado em uma ou mais stacks pelas regras abaixo. Um arquivo pode pertencer a mais de uma stack (ex: `.dart` em flutter package → `flutter` E `dart`).

| Padrao | Stack |
|--------|-------|
| `*.dart` em arvore com `pubspec.yaml` que depende de `flutter` | `flutter` |
| `*.dart` (todos) | `dart` |
| `*.ts` ou `*.js` em arvore com `package.json` contendo `@nestjs/*` | `nestjs` |
| `android/**`, `*.kt`, `*.java` (fora de teste flutter) | `android` |
| `ios/**`, `*.swift`, `*.m`, `*.mm`, `*.h` (fora de flutter pods) | `ios` |
| `*.tf`, `cloudbuild*.yaml`, `app.yaml`, `.gcloudignore`, arquivos referenciando `gcloud`/`firebase` | `gcp` |

Se nenhum padrao bater para um arquivo (ex: docs, config), ignore-o do review tecnico.

Stacks unicas detectadas → `DETECTED_STACKS`.

## 5. Verificar agentes disponiveis — GATE

Para cada stack detectada, verifique se existem os 5 agentes de foco:

```bash
FOCUSES=(correctness architecture performance security testing)
MISSING=()
for stack in "${DETECTED_STACKS[@]}"; do
  for focus in "${FOCUSES[@]}"; do
    test -f ~/.claude/agents/${stack}-${focus}.md || MISSING+=("${stack}-${focus}")
  done
done
```

**Se `MISSING` estiver vazio:** prossiga.

**Se faltar algum agente:** PAUSE o fluxo e avise:

> "Detectei a(s) stack(s) `<lista>` neste PR, mas faltam os seguintes agentes:
> - `<stack>-<focus>`
> - ...
>
> Quero criar esses agentes com voce antes de continuar a revisao. Para cada agente faltante, preciso entender:
> 1. Quais sao os principais riscos/padroes desse foco nessa stack neste seu contexto?
> 2. Existem regras especificas (lint, convencoes, anti-patterns) que devem ser sempre flagged?
>
> Posso comecar pelo `<primeiro-da-lista>`?"

Aguarde a definicao do usuario. Crie cada agente em `~/.claude/agents/<nome>.md` antes de prosseguir. So volte ao passo 6 quando todos os agentes existirem.

## 6. Executar revisao com agentes

Para cada combinacao `(stack, focus)` em `DETECTED_STACKS x FOCUSES`:

1. Filtre os arquivos modificados que pertencem a essa stack
2. Lance o agente `<stack>-<focus>` em paralelo (mesma message com varios `Agent` calls quando possivel)
3. Passe ao agente:
   - Lista de arquivos relevantes (paths absolutos)
   - Caminho do diff: `$REVIEWS_DIR/PR-${PR_NUM}.diff`
   - Instrucao: "Leia o diff e os arquivos. Retorne JSON array de comentarios inline. Schema: `[{path, line, severity, body}]`. severity ∈ critical|major|minor|nit. Sem prosa fora do JSON.

     **IMPORTANTE sobre `line`:** o numero deve ser a linha **no arquivo NEW (pos-imagem)**, nao o offset dentro do diff. Para encontrar a linha correta:
     - Procure o hunk header `@@ -a,b +c,d @@` que contem o trecho que voce quer comentar.
     - A primeira linha de conteudo apos esse header corresponde a linha `c` do arquivo NEW.
     - Cada linha que comeca com `+` ou ` ` (espaco/contexto) avanca o contador da linha NEW; linhas que comecam com `-` nao avancam.
     - Use exatamente esse numero (`c + offset`) no campo `line`.
     - Para arquivos novos (`@@ -0,0 +1,N @@`), a linha NEW vai de 1 ate N.
     - Nunca use a posicao da linha dentro do arquivo .diff inteiro — o GitHub rejeita."

Colete todas as respostas. Cada agente retorna um array (vazio se nada a flagged).

## 7. Consolidar review draft

Crie `$REVIEWS_DIR/PR-${PR_NUM}.md` com este formato:

```markdown
---
pr: <PR_NUM>
title: <titulo do PR>
author: <author>
branch: <head> -> <base>
stacks: <stacks detectadas>
status: draft
generated_at: <ISO timestamp>
---

# Review PR #<PR_NUM> — <titulo>

## Resumo
- **Arquivos analisados:** N
- **Stacks:** <lista>
- **Agentes executados:** <count>
- **Achados:** X critical, Y major, Z minor, W nit

## Comentarios inline

### `<path/do/arquivo>`

#### Linha <N> — <severity> [<stack>-<focus>]
<body do comentario>

#### Linha <M> — <severity> [<stack>-<focus>]
<body>

### `<outro/arquivo>`
...

## Veredicto sugerido
<APPROVE | COMMENT | REQUEST_CHANGES> — <justificativa em 1 linha>

Regra:
- Se ha qualquer `critical` ou >= 3 `major` → REQUEST_CHANGES
- Se ha `major` (1-2) ou apenas `minor`/`nit` → COMMENT
- Se nao ha achados → APPROVE
```

Tambem salve o JSON consolidado para o `/post-review`:

```bash
# $REVIEWS_DIR/PR-${PR_NUM}.comments.json
[
  {"path": "...", "line": N, "severity": "...", "body": "...", "agent": "stack-focus"},
  ...
]
```

## 8. Apresentar para o usuario

Mostre um resumo conciso:
- Total de comentarios por severidade
- Veredicto sugerido
- Caminho do arquivo: `$REVIEWS_DIR/PR-${PR_NUM}.md`

Finalize: "Review draft gerado. Revise/edite `PR-<num>.md` se quiser ajustar. Quando estiver pronto: `/approve-review <PR_NUM>`."
