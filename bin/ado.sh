#!/bin/bash
# ado.sh — acesso ao Azure DevOps Boards via PAT + REST (sem MCP, headless-safe).
#
# PAT: lido de AZURE_DEVOPS_EXT_PAT (env) ou, senão, do ~/.claude.json
#      (busca recursiva pela chave AZURE_DEVOPS_EXT_PAT). Nunca é impresso.
#
# Config: exporte ADO_ORG e ADO_PROJECT no ambiente
#           sobrescreva com ADO_ORG / ADO_PROJECT no ambiente.
#
# Comandos:
#   get <id>                 -> JSON compacto do work item (title, type, state, desc, ac, repro, tags, assignee)
#   raw <id>                 -> JSON cru da API (todos os fields)
#   comment <id> <texto>     -> adiciona comentario (aceita HTML)
#   my-items                 -> work items atribuidos a mim, ativos
#   wiql '<query>'           -> roda WIQL e retorna ids+title+type+state

set -euo pipefail

ORG="${ADO_ORG:?export ADO_ORG}"
PROJECT="${ADO_PROJECT:?export ADO_PROJECT}"
API="api-version=7.1"
BASE="https://dev.azure.com/$ORG"

get_pat() {
  # ordem: env -> arquivo dedicado (chmod 600) -> fallback legado ~/.claude.json
  if [ -n "${AZURE_DEVOPS_EXT_PAT:-}" ]; then printf '%s' "$AZURE_DEVOPS_EXT_PAT"; return; fi
  if [ -f "$HOME/.claude/.ado_pat" ]; then
    tr -d '[:space:]' < "$HOME/.claude/.ado_pat"; return
  fi
  local p; p="$(jq -r '..|.AZURE_DEVOPS_EXT_PAT? // empty' "$HOME/.claude.json" 2>/dev/null | head -1)"
  if [ -z "$p" ]; then echo "ERRO: PAT nao encontrado (env, ~/.claude/.ado_pat, nem ~/.claude.json)" >&2; exit 1; fi
  printf '%s' "$p"
}

# curl autenticado; -u ":PAT" via arquivo netrc-like em memoria nao dá, então usa -u
adoc() {
  local url="$1"; shift
  curl -sS -u ":$(get_pat)" "$@" "$url"
}

# strip HTML basico pra leitura
html2txt() { sed -e 's/<[^>]*>//g' -e 's/&nbsp;/ /g' -e 's/&amp;/\&/g' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g'; }

urlenc() { jq -rn --arg s "$1" '$s|@uri'; }

cmd="${1:-}"; shift || true

case "$cmd" in
  get)
    id="$1"
    proj="$(urlenc "$PROJECT")"
    adoc "$BASE/$proj/_apis/wit/workitems/$id?\$expand=fields&$API" | jq '
      .fields as $f | {
        id: .id,
        title: $f["System.Title"],
        type: $f["System.WorkItemType"],
        state: $f["System.State"],
        assignee: ($f["System.AssignedTo"].displayName // null),
        tags: ($f["System.Tags"] // ""),
        description: ($f["System.Description"] // ""),
        acceptance: ($f["Microsoft.VSTS.Common.AcceptanceCriteria"] // ""),
        repro: ($f["Microsoft.VSTS.TCM.ReproSteps"] // "")
      }'
    ;;

  raw)
    id="$1"; proj="$(urlenc "$PROJECT")"
    adoc "$BASE/$proj/_apis/wit/workitems/$id?\$expand=fields&$API"
    ;;

  desc)
    # texto plano legivel da descricao + repro (pra alimentar /fix e /specify)
    id="$1"; proj="$(urlenc "$PROJECT")"
    adoc "$BASE/$proj/_apis/wit/workitems/$id?\$expand=fields&$API" | jq -r '
      .fields as $f |
      "# " + ($f["System.Title"]//"") + "\n\n" +
      "Tipo: " + ($f["System.WorkItemType"]//"") + " | Estado: " + ($f["System.State"]//"") + "\n\n" +
      "## Descricao\n" + ($f["System.Description"]//"(vazio)") + "\n\n" +
      "## Repro\n" + ($f["Microsoft.VSTS.TCM.ReproSteps"]//"(vazio)") + "\n\n" +
      "## Criterios de aceite\n" + ($f["Microsoft.VSTS.Common.AcceptanceCriteria"]//"(vazio)")
    ' | html2txt
    ;;

  comment)
    id="$1"; text="$2"; proj="$(urlenc "$PROJECT")"
    adoc "$BASE/$proj/_apis/wit/workItems/$id/comments?api-version=7.1-preview.4" \
      -X POST -H "Content-Type: application/json" \
      -d "$(jq -n --arg t "$text" '{text:$t}')" | jq '{id, url: (.url//null)}'
    ;;

  my-items)
    proj="$(urlenc "$PROJECT")"
    q='SELECT [System.Id] FROM WorkItems WHERE [System.AssignedTo] = @Me AND [System.State] <> "Done" AND [System.State] <> "Closed" ORDER BY [System.ChangedDate] DESC'
    ids="$(adoc "$BASE/$proj/_apis/wit/wiql?$API" -X POST -H "Content-Type: application/json" \
      -d "$(jq -n --arg q "$q" '{query:$q}')" | jq -r '[.workItems[]?.id]|@csv')"
    [ -z "$ids" ] && { echo '[]'; exit 0; }
    adoc "$BASE/_apis/wit/workitems?ids=$ids&fields=System.Id,System.Title,System.WorkItemType,System.State&$API" \
      | jq '[.value[] | {id:.id, title:.fields["System.Title"], type:.fields["System.WorkItemType"], state:.fields["System.State"]}]'
    ;;

  wiql)
    proj="$(urlenc "$PROJECT")"; q="$1"
    ids="$(adoc "$BASE/$proj/_apis/wit/wiql?$API" -X POST -H "Content-Type: application/json" \
      -d "$(jq -n --arg q "$q" '{query:$q}')" | jq -r '[.workItems[]?.id]|@csv')"
    [ -z "$ids" ] && { echo '[]'; exit 0; }
    adoc "$BASE/_apis/wit/workitems?ids=$ids&fields=System.Id,System.Title,System.WorkItemType,System.State&$API" \
      | jq '[.value[] | {id:.id, title:.fields["System.Title"], type:.fields["System.WorkItemType"], state:.fields["System.State"]}]'
    ;;

  *)
    echo "usage: ado.sh {get|raw|desc|comment|my-items|wiql} ..." >&2; exit 1 ;;
esac
