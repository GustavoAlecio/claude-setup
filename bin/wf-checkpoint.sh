#!/bin/bash
# Checkpoints the working tree as a git tree object without touching HEAD, refs or the real index.
#
# Usage:
#   wf-checkpoint.sh create  <repo>           -> prints tree sha
#   wf-checkpoint.sh changed <repo> <tree>    -> paths changed since tree (incl. untracked)
#   wf-checkpoint.sh numstat <repo> <tree>    -> added<TAB>deleted<TAB>path per file since tree (incl. untracked)
#   wf-checkpoint.sh diff    <repo> <tree>    -> unified diff since tree (incl. untracked)
#   wf-checkpoint.sh restore <repo> <tree>    -> reverts ONLY paths changed since tree
set -euo pipefail

CMD="${1:?cmd}"
REPO="${2:?repo}"
TREE="${3:-}"
# `@<file>` reads the sha from a file gate_g0.py wrote, so no LLM ever retypes a hash.
if [ "${TREE#@}" != "$TREE" ]; then TREE="$(tr -d '[:space:]' < "${TREE#@}" 2>/dev/null || true)"; fi
cd "$REPO"

snapshot() {
    local tmp real
    tmp="$(mktemp -u)"
    real="$(git rev-parse --git-path index)"
    [ -f "$real" ] && cp "$real" "$tmp"
    GIT_INDEX_FILE="$tmp" git add -A >/dev/null 2>&1
    GIT_INDEX_FILE="$tmp" git write-tree
    rm -f "$tmp"
}

require_tree() {
    [ -n "$TREE" ] || { echo "missing tree sha" >&2; exit 2; }
    [ "$(git cat-file -t "$TREE" 2>/dev/null)" = "tree" ] || { echo "not a tree: $TREE" >&2; exit 2; }
}

case "$CMD" in
    create)  snapshot ;;
    changed) require_tree; git diff --name-only --no-renames "$TREE" "$(snapshot)" ;;
    numstat) require_tree; git diff --numstat --no-renames "$TREE" "$(snapshot)" ;;
    diff)    require_tree; git diff --no-renames "$TREE" "$(snapshot)" ;;
    restore)
        require_tree
        CUR="$(snapshot)"
        n=0
        while IFS=$'\t' read -r status path; do
            [ -z "$path" ] && continue
            if [ "$status" = "A" ]; then
                rm -f -- "$path"
            else
                git restore --source="$TREE" --worktree -- "$path"
            fi
            n=$((n + 1))
        done < <(git diff --name-status --no-renames "$TREE" "$CUR")
        echo "restored $n path(s) to $TREE"
        ;;
    *) echo "usage: wf-checkpoint.sh create|changed|numstat|diff|restore <repo> [tree]" >&2; exit 2 ;;
esac
