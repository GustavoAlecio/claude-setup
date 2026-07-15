#!/bin/bash
# pr-inspect.sh — snapshot compacto do estado de review de um PR.
#
# Usage: pr-inspect.sh <pr_number>
# Saida (stdout): JSON { reviewDecision, mergeable, checks, unresolved:[{path,line,author,body}] }
#
# checks: SUCCESS | PENDING | FAILURE | null  (rollup dos status checks do ultimo commit)

set -euo pipefail

PR="${1:?usage: pr-inspect.sh <pr_number>}"

if ! command -v gh >/dev/null 2>&1; then echo '{"error":"gh not found"}'; exit 1; fi

read -r OWNER REPO < <(gh repo view --json owner,name -q '.owner.login + " " + .name')

gh api graphql -f query='
query($owner:String!,$repo:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$pr){
      reviewDecision
      mergeable
      commits(last:1){ nodes{ commit{ statusCheckRollup{ state } } } }
      reviewThreads(first:100){
        nodes{
          isResolved
          comments(first:1){ nodes{ author{login} body path line } }
        }
      }
    }
  }
}' -F owner="$OWNER" -F repo="$REPO" -F pr="$PR" | jq '
  .data.repository.pullRequest as $pr |
  {
    reviewDecision: $pr.reviewDecision,
    mergeable: $pr.mergeable,
    checks: ($pr.commits.nodes[0].commit.statusCheckRollup.state // null),
    unresolved: [
      $pr.reviewThreads.nodes[]
      | select(.isResolved == false)
      | .comments.nodes[0]
      | select(. != null)
      | { path: .path, line: .line, author: .author.login, body: .body }
    ]
  }
'
