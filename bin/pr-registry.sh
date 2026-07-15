#!/bin/bash
# pr-registry.sh — mantem o indice de PRs em voo (spine ADO<->GitHub).
#
# Store: ~/.claude/workflow/<PROJECT_NAME>/prs.json
# Fonte durável do vínculo é o rodapé "ADO: #<id>" no corpo do PR;
# este arquivo é apenas o índice rápido para o /pr-status.
#
# Comandos:
#   register <pr_number> <ado_id> <branch> <target> <title> <url>
#   set-stage <pr_number> <stage>          # atualiza stage + last_check
#   touch <pr_number>                       # so atualiza last_check
#   get <pr_number>                         # imprime o objeto do PR
#   list                                    # imprime prs.json inteiro
#   remove <pr_number>                      # remove (merge/close)
#
# ado_id pode ser "" (PR sem card vinculado).
# stages: awaiting_review | changes_requested | resolving | approved | merge_ready | merged | closed

set -euo pipefail

source "$HOME/.claude/bin/get-project.sh"

PROJECT_NAME="$(get-project-name)"
STORE_DIR="$HOME/.claude/workflow/$PROJECT_NAME"
STORE="$STORE_DIR/prs.json"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

ensure_store() {
  mkdir -p "$STORE_DIR"
  if [ ! -f "$STORE" ]; then
    printf '{"project":"%s","prs":[]}\n' "$PROJECT_NAME" > "$STORE"
  fi
}

# escreve atomicamente o resultado de um filtro jq aplicado ao store
apply() {
  local filter="$1"; shift
  local tmp; tmp="$(mktemp)"
  jq "$@" "$filter" "$STORE" > "$tmp"
  mv "$tmp" "$STORE"
}

cmd="${1:-}"; shift || true

case "$cmd" in
  register)
    pr="$1"; ado="${2:-}"; branch="$3"; target="$4"; title="$5"; url="$6"
    ensure_store
    apply '
      (.prs |= map(select(.pr_number != ($pr|tonumber)))) |
      .prs += [{
        pr_number: ($pr|tonumber),
        ado_id: (if $ado == "" then null else ($ado|tonumber) end),
        branch: $branch, target: $target, title: $title, url: $url,
        stage: "awaiting_review",
        opened_at: $ts, last_check: null
      }]
    ' \
      --arg pr "$pr" --arg ado "$ado" --arg branch "$branch" \
      --arg target "$target" --arg title "$title" --arg url "$url" --arg ts "$(now)"
    echo "registered PR #$pr (ado=${ado:-none}) in $STORE"
    ;;

  set-stage)
    pr="$1"; stage="$2"
    ensure_store
    apply '
      .prs |= map(if .pr_number == ($pr|tonumber)
                  then .stage = $stage | .last_check = $ts else . end)
    ' --arg pr "$pr" --arg stage "$stage" --arg ts "$(now)"
    echo "PR #$pr -> $stage"
    ;;

  touch)
    pr="$1"
    ensure_store
    apply '.prs |= map(if .pr_number == ($pr|tonumber) then .last_check = $ts else . end)' \
      --arg pr "$pr" --arg ts "$(now)"
    ;;

  get)
    ensure_store
    jq --arg pr "$1" '.prs[] | select(.pr_number == ($pr|tonumber))' "$STORE"
    ;;

  list)
    ensure_store
    cat "$STORE"
    ;;

  remove)
    pr="$1"
    ensure_store
    apply '.prs |= map(select(.pr_number != ($pr|tonumber)))' --arg pr "$pr"
    echo "removed PR #$pr"
    ;;

  path)
    echo "$STORE"
    ;;

  *)
    echo "usage: pr-registry.sh {register|set-stage|touch|get|list|remove|path} ..." >&2
    exit 1
    ;;
esac
