#!/bin/bash
# Archives a completed cycle from ~/.claude/workflow/[project]/ to ~/.claude/projects/[project]/history/
# Usage: archive-cycle.sh [status] [optional: project-name] [optional: feature-name]

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/to-slug.sh"
source "$SCRIPT_DIR/get-project.sh"

PROJECTS_DIR="$HOME/.claude/projects"
STATUS="${1:-completed}"
PROJECT_NAME="${2:-$(get-project-name)}"
WORKFLOW_DIR="$HOME/.claude/workflow/$PROJECT_NAME"

if [ ! -d "$WORKFLOW_DIR" ]; then
    echo "Error: No workflow found for project '$PROJECT_NAME'"
    exit 1
fi

FEATURE_NAME="${3:-$(python3 -c "import json,sys; d=json.load(open('$WORKFLOW_DIR/current.json')); print(d.get('feature',''))" 2>/dev/null)}"

if [ -z "$FEATURE_NAME" ]; then
    echo "Error: Could not determine feature name"
    exit 1
fi

FEATURE_SLUG=$(to-slug "$FEATURE_NAME")
DATE=$(date +%Y-%m-%d)
HISTORY_DIR="$PROJECTS_DIR/$PROJECT_NAME/history"
CYCLE_DIR="$HISTORY_DIR/${DATE}_${FEATURE_SLUG}"

mkdir -p "$CYCLE_DIR"

for f in spec.md plan.md tasks.md tot-plan.json report.json; do
    if [ -f "$WORKFLOW_DIR/$f" ]; then
        cp "$WORKFLOW_DIR/$f" "$CYCLE_DIR/$f"
    fi
done
[ -d "$WORKFLOW_DIR/runs" ] && cp -R "$WORKFLOW_DIR/runs" "$CYCLE_DIR/runs"

# Generate results.md and metrics.json
python3 - "$WORKFLOW_DIR/current.json" "$CYCLE_DIR" "$FEATURE_NAME" "$PROJECT_NAME" "$STATUS" << 'PYEOF'
import sys, json
from datetime import datetime

current_json_path = sys.argv[1]
cycle_dir = sys.argv[2]
feature_name = sys.argv[3]
project_name = sys.argv[4]
status = sys.argv[5]

try:
    with open(current_json_path) as f:
        d = json.load(f)
except Exception:
    d = {}

start = d.get("start_date", "")
end = d.get("end_date", "")
tokens_used = d.get("tokens_used", 0)
tasks_obj = d.get("tasks", {})
tasks_total = tasks_obj.get("total", 0)
tasks_completed = len([t for t in tasks_obj.get("items", []) if t.get("status") == "done"])
phases = d.get("phases", {})
backtracks = d.get("backtracks", [])

duration_minutes = 0
if start and end and "T" in start and "T" in end:
    try:
        s = datetime.fromisoformat(start.replace("Z", "+00:00"))
        e = datetime.fromisoformat(end.replace("Z", "+00:00"))
        duration_minutes = max(0, int((e - s).total_seconds() / 60))
    except Exception:
        pass

completion_rate = int(tasks_completed * 100 / tasks_total) if tasks_total > 0 else 0

# Generate results.md
phase_rows = ""
for pn in ["specify", "plan", "tasks", "implement", "verify"]:
    phase = phases.get(pn, {})
    if phase:
        ps, pe = phase.get("start", ""), phase.get("end", "")
        pd = 0
        if ps and pe:
            try:
                pd = max(0, int((datetime.fromisoformat(pe.replace("Z","+00:00")) - datetime.fromisoformat(ps.replace("Z","+00:00"))).total_seconds() / 60))
            except: pass
        phase_rows += f"| **{pn}** | {pd}m |\n"

results_md = f"""# Resultado — {feature_name}

| Campo | Valor |
|-------|-------|
| **Feature** | {feature_name} |
| **Project** | {project_name} |
| **Duration** | {duration_minutes}m |
| **Status** | {status} |
| **Tasks** | {tasks_completed}/{tasks_total} ({completion_rate}%) |
| **Tokens** | {tokens_used:,} |

### Timing por Fase
| Fase | Duracao |
|------|---------|
{phase_rows}
*Gerado em {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}*
"""

with open(f"{cycle_dir}/results.md", "w") as f:
    f.write(results_md)

metrics = {
    "feature": feature_name, "project": project_name,
    "start_date": start, "end_date": end,
    "duration_minutes": duration_minutes, "tokens_spent": tokens_used,
    "tasks_total": tasks_total, "tasks_completed": tasks_completed,
    "completion_rate": completion_rate, "status": status,
    "backtracks": backtracks, "phases": {},
}
for pn in ["specify", "plan", "tasks", "implement", "verify"]:
    phase = phases.get(pn, {})
    if phase:
        ps, pe = phase.get("start", ""), phase.get("end", "")
        pd = 0
        if ps and pe:
            try:
                pd = max(0, int((datetime.fromisoformat(pe.replace("Z","+00:00")) - datetime.fromisoformat(ps.replace("Z","+00:00"))).total_seconds() / 60))
            except: pass
        metrics["phases"][pn] = {"start": ps, "end": pe, "duration_minutes": pd}

with open(f"{cycle_dir}/metrics.json", "w") as f:
    json.dump(metrics, f, indent=2)

print(f"Archived to {cycle_dir}")
PYEOF

rm -rf "$WORKFLOW_DIR"
echo "Archive complete: $CYCLE_DIR"
