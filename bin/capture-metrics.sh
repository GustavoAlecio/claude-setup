#!/bin/bash
# capture-metrics.sh — Captura timing de inicio/fim de um step do Fluxo Smart
#
# Token accounting is handled exclusively by track-tokens.py (Stop hook).
# This script only records phase timing and status transitions.
#
# Usage:
#   capture-metrics.sh start <step_name> <project_name> <project_path>
#   capture-metrics.sh end <step_name> <project_name> <project_path>

set -e

MODE="$1"
STEP_NAME="$2"
PROJECT_NAME="$3"
PROJECT_PATH="$4"

WORKFLOW_DIR="$HOME/.claude/workflow/$PROJECT_NAME"
TMP_FILE="/tmp/claude_metrics_${PROJECT_NAME}_${STEP_NAME}.json"

if [ "$MODE" = "start" ]; then
    TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    echo "{\"timestamp\": \"$TIMESTAMP\"}" > "$TMP_FILE"
    echo "$TIMESTAMP"

elif [ "$MODE" = "end" ]; then
    END_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    if [ ! -f "$TMP_FILE" ]; then
        echo "ERROR: No start metrics found at $TMP_FILE" >&2
        echo "{\"error\": \"no_start_metrics\"}"
        exit 1
    fi

    python3 - "$TMP_FILE" "$END_TS" "$STEP_NAME" "$WORKFLOW_DIR" << 'PYEOF'
import json, sys
sys.path.insert(0, str(__import__("pathlib").Path.home() / ".claude" / "bin"))
from current_json import update_current_json

tmp_file = sys.argv[1]
end_ts = sys.argv[2]
step_name = sys.argv[3]
workflow_dir = sys.argv[4]

with open(tmp_file) as f:
    start_data = json.load(f)

start_ts = start_data["timestamp"]

status_map = {
    "specify": "specifying",
    "plan": "planning",
    "tasks": "tasking",
    "implement": "implementing",
    "verify": "verifying"
}

def modifier(current):
    current.setdefault("phases", {})[step_name] = {
        "start": start_ts,
        "end": end_ts
    }

    if step_name in status_map:
        current["status"] = status_map[step_name]

    if step_name == "verify":
        current["end_date"] = end_ts
        current["status"] = "verified"

    return current

update_current_json(workflow_dir, modifier, default={"phases": {}})

print(json.dumps({"start": start_ts, "end": end_ts}, indent=2))
PYEOF

    rm -f "$TMP_FILE"

else
    echo "Usage: capture-metrics.sh <start|end> <step_name> <project_name> <project_path>" >&2
    exit 1
fi
