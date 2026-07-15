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

# Remap comment lines against the actual PR diff. Agents sometimes return
# diff-file offsets instead of post-image (NEW) line numbers — the GitHub API
# rejects those. We parse the diff, validate each comment's line, and remap
# when possible. Requires python3.
DIFF_FILE="${REVIEWS_DIR:-$(dirname "$MD_BODY")}/PR-${PR_NUM}.diff"
if [ ! -f "$DIFF_FILE" ]; then
    # Try fetching it fresh if missing.
    DIFF_FILE=$(mktemp -t pr-review-diff-XXXXXX.diff)
    gh pr diff "$PR_NUM" > "$DIFF_FILE" 2>/dev/null || true
fi

REMAPPED_JSON=$(mktemp -t pr-review-remapped-XXXXXX.json)
if command -v python3 >/dev/null 2>&1 && [ -s "$DIFF_FILE" ]; then
    python3 - "$DIFF_FILE" "$COMMENTS_JSON" "$REMAPPED_JSON" <<'PYEOF'
import json, re, sys
diff_path, comments_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(diff_path) as f:
    lines = f.read().splitlines()
file_info = {}
cur_path = None
cur_new = None
in_hunk = False
for idx, line in enumerate(lines, start=1):
    if line.startswith("diff --git"):
        m = re.match(r"diff --git a/(.+) b/(.+)", line)
        cur_path = m.group(2) if m else None
        in_hunk = False
        if cur_path and cur_path not in file_info:
            file_info[cur_path] = {"new_lines": set(), "diff_to_new": {}}
    elif line.startswith("@@"):
        m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@", line)
        if m and cur_path:
            cur_new = int(m.group(1))
            in_hunk = True
    elif in_hunk and cur_path:
        if line.startswith("+") and not line.startswith("+++"):
            file_info[cur_path]["new_lines"].add(cur_new)
            file_info[cur_path]["diff_to_new"][idx] = cur_new
            cur_new += 1
        elif line.startswith(" "):
            file_info[cur_path]["diff_to_new"][idx] = cur_new
            cur_new += 1
        elif line.startswith("-"):
            pass
        else:
            in_hunk = False
with open(comments_path) as f:
    comments = json.load(f)
kept, dropped, remapped_count, approx = [], [], 0, 0
for c in comments:
    path, line = c.get("path"), c.get("line")
    info = file_info.get(path)
    if not info:
        dropped.append((path, line, "path not in diff"))
        continue
    if line in info["new_lines"]:
        kept.append(c)
        continue
    if line in info["diff_to_new"]:
        nc = dict(c); nc["line"] = info["diff_to_new"][line]
        kept.append(nc); remapped_count += 1; continue
    if info["new_lines"]:
        closest = min(info["new_lines"], key=lambda v: abs(v - line))
        nc = dict(c); nc["line"] = closest
        nc["body"] = c["body"] + f"\n\n_(linha aproximada — original {line} fora do diff)_"
        kept.append(nc); approx += 1
    else:
        dropped.append((path, line, "no added lines for path"))
with open(out_path, "w") as f:
    json.dump(kept, f, ensure_ascii=False)
sys.stderr.write(f"Line remap: kept={len(kept)} remapped_exact={remapped_count} remapped_approx={approx} dropped={len(dropped)}\n")
for d in dropped:
    sys.stderr.write(f"  DROP: path={d[0]} line={d[1]} reason={d[2]}\n")
PYEOF
    if [ -s "$REMAPPED_JSON" ]; then
        COMMENTS_JSON="$REMAPPED_JSON"
    fi
fi

# Build comments payload — convert to GitHub API shape
# GitHub expects: {path, body, line, side: "RIGHT"}  (or position for legacy)
PAYLOAD_FILE=$(mktemp -t pr-review-payload-XXXXXX.json)
trap 'rm -f "$PAYLOAD_FILE" "$REMAPPED_JSON"' EXIT

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
