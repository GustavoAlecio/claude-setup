---
name: adr
description: Gerencia Architecture Decision Records do repo em docs/adr/ — new, supersede, deprecate, list, show, reindex, propose (a partir de decisões do ciclo). ADRs são imutáveis; mudança de decisão = supersede.
---

Uso: `/adr <subcomando> [args]`. Sem subcomando → `list`.

```bash
REPO=$(git rev-parse --show-toplevel)
ADR_DIR="$REPO/docs/adr"
source ~/.claude/bin/get-project.sh
WF_DIR="$HOME/.claude/workflow/$(get-project-name)"
SUBMODULE=$(git -C "$ADR_DIR" rev-parse --show-superproject-working-tree 2>/dev/null)
```

**Submódulo:** `SUBMODULE` não vazio significa que `docs/adr` é um submódulo (ADR vive em outro repo). Aí `new`, `supersede` e `reindex` **recusam** com uma linha explicando; `propose` não escreve ADR: grava as candidatas em `$WF_DIR/adr-candidates.md` (o `/pr-open --from-complete` anexa esse arquivo ao PR).

## Formato

`docs/adr/NNNN-<slug>.md`:

```markdown
---
id: NNNN
title: <decisão em uma frase>
status: proposed | accepted | deprecated | superseded
date: YYYY-MM-DD
affects: ["lib/features/**/bloc/**"]
supersedes: []
superseded_by: []
tags: []
---

# NNNN — <título>

## Contexto
<forças em jogo; o que tornou a decisão necessária>

## Decisão
<o que foi decidido, no imperativo>

## Alternativas consideradas
- **<alternativa>** — <por que não>

## Consequências
- <o que fica mais fácil / mais difícil; o que os gates passam a cobrar>

## Relacionados
- [[NNNN-outro-adr]]
```

`affects` é o que liga o ADR ao fluxo: o `/plan`, o G1 e o dev-implementer só leem ADRs `accepted` cujos globs casam com os arquivos tocados. ADR sem `affects` não é encontrado por ninguém — sempre preencha.

## Subcomandos

- **new `<título>`** — `python3 ~/.claude/bin/adr-index.py next-id "$REPO"` para o id. Pergunte contexto, decisão, alternativas e `affects` (proponha os globs a partir do código). Status `proposed`. Reindex.
- **accept `<id>`** — `proposed` → `accepted`. Reindex.
- **supersede `<id>` `<novo título>`** — cria o novo ADR com `supersedes: [<id>]`; no antigo, só troca `status: superseded` e `superseded_by`. Não edite o corpo do antigo. Reindex.
- **deprecate `<id>`** — `status: deprecated` + uma linha em Consequências com o motivo. Reindex.
- **list** — mostre o `INDEX.md` (reindex antes se estiver desatualizado).
- **show `<id>`** — conteúdo + ADRs ligados por wikilink/supersedes.
- **reindex** — `python3 ~/.claude/bin/adr-index.py reindex "$REPO"`.
- **propose** — usado pelo `/complete`: recebe decisões candidatas (do `tot-plan` e dos `decisions` do dev-implementer), descarta as triviais ou já cobertas por ADR existente, e cria as restantes como `proposed`. Mostre a lista e peça OK antes de gravar. Em submódulo, grave a lista em `$WF_DIR/adr-candidates.md` em vez de criar ADRs.

## Regras

- Nunca edite Decisão/Contexto de ADR `accepted`. Mudou → supersede.
- Bootstrap num repo sem `docs/adr/`: crie a pasta e o `INDEX.md` vazio via reindex; não invente ADRs retroativos sem o usuário apontar as decisões.
