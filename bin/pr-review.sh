#!/bin/bash
# pr-review.sh — Posts a review with inline comments to a GitHub PR via gh api.
#
# Usage:
#   pr-review.sh <pr_number> <comments_json> <event> <markdown_body>
#
# event: APPROVE | REQUEST_CHANGES | COMMENT
# comments_json: path to JSON file with [{path, line, severity, body, agent}, ...]
# markdown_body: path to the review markdown (used to extract summary)

set -e

PR_NUM="$1"
COMMENTS_JSON="$2"
EVENT="$3"
MD_BODY="$4"

if [ -z "$PR_NUM" ] || [ -z "$COMMENTS_JSON" ] || [ -z "$EVENT" ] || [ -z "$MD_BODY" ]; then
    echo "Usage: pr-review.sh <pr_number> <comments_json> <event> <markdown_body>" >&2
    exit 1
fi

if [ ! -f "$COMMENTS_JSON" ]; then
    echo "ERROR: comments file not found: $COMMENTS_JSON" >&2
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh CLI not found in PATH" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq not found in PATH" >&2
    exit 1
fi

# Resolve repo + head SHA
REPO_INFO=$(gh pr view "$PR_NUM" --json headRepository,headRepositoryOwner,headRefOid,number)
OWNER=$(echo "$REPO_INFO" | jq -r '.headRepositoryOwner.login')
REPO=$(echo "$REPO_INFO" | jq -r '.headRepository.name')
HEAD_SHA=$(echo "$REPO_INFO" | jq -r '.headRefOid')

# Body summary: extract sections from the review markdown
BODY=$(awk '
  /^## Resumo/{flag=1; print; next}
  /^## Veredicto sugerido/{flag=1; print; next}
  /^## Comentarios inline/{flag=0}
  flag {print}
' "$MD_BODY")

# Build comments payload — convert to GitHub API shape
# GitHub expects: {path, body, line, side: "RIGHT"}  (or position for legacy)
PAYLOAD_FILE=$(mktemp -t pr-review-payload-XXXXXX.json)
trap 'rm -f "$PAYLOAD_FILE"' EXIT

jq --arg event "$EVENT" \
   --arg sha "$HEAD_SHA" \
   --arg body "$BODY" \
   '{
     commit_id: $sha,
     event: $event,
     body: $body,
     comments: [.[] | {
       path: .path,
       line: .line,
       side: "RIGHT",
       body: ("**[" + (.severity // "minor") + (if .agent then " · " + .agent else "" end) + "]** " + .body)
     }]
   }' "$COMMENTS_JSON" > "$PAYLOAD_FILE"

TOTAL=$(jq '.comments | length' "$PAYLOAD_FILE")
echo "Posting review with $TOTAL inline comments (event=$EVENT, sha=$HEAD_SHA)..." >&2

# Try posting
RESPONSE_FILE=$(mktemp -t pr-review-response-XXXXXX.json)
HTTP_STATUS=$(gh api \
  --method POST \
  -H "Accept: application/vnd.github+json" \
  "/repos/${OWNER}/${REPO}/pulls/${PR_NUM}/reviews" \
  --input "$PAYLOAD_FILE" \
  > "$RESPONSE_FILE" 2>&1 && echo OK || echo FAIL)

if [ "$HTTP_STATUS" = "FAIL" ]; then
    echo "ERROR posting review:" >&2
    cat "$RESPONSE_FILE" >&2
    rm -f "$RESPONSE_FILE"
    exit 1
fi

REVIEW_ID=$(jq -r '.id // empty' "$RESPONSE_FILE")
REVIEW_URL=$(jq -r '.html_url // empty' "$RESPONSE_FILE")

echo "OK: review_id=$REVIEW_ID"
echo "URL: $REVIEW_URL"
echo "$REVIEW_ID"

rm -f "$RESPONSE_FILE"
