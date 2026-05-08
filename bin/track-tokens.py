#!/usr/bin/env python3
"""
Stop hook: reads transcript, sums token usage, updates current.json of active workflow.
Called by Claude Code after each assistant response.
Receives JSON on stdin: { session_id, transcript_path, cwd, ... }
"""

import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from current_json import update_current_json as atomic_update

WORKFLOW_BASE = Path.home() / ".claude" / "workflow"


def get_project_name(cwd: str):
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=cwd, capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            return Path(result.stdout.strip()).name
    except Exception:
        pass
    return Path(cwd).name


def find_active_workflow(project_name: str):
    candidate = WORKFLOW_BASE / project_name / "current.json"
    if candidate.exists():
        return candidate
    return None


def sum_transcript_tokens(transcript_path: str) -> dict:
    totals = {"input": 0, "output": 0, "cache_creation": 0, "cache_read": 0}
    try:
        with open(transcript_path) as f:
            for line in f:
                try:
                    entry = json.loads(line)
                    if entry.get("type") != "assistant":
                        continue
                    usage = entry.get("message", {}).get("usage", {})
                    if not usage:
                        continue
                    totals["input"] += usage.get("input_tokens", 0)
                    totals["output"] += usage.get("output_tokens", 0)
                    totals["cache_creation"] += usage.get("cache_creation_input_tokens", 0)
                    totals["cache_read"] += usage.get("cache_read_input_tokens", 0)
                except Exception:
                    continue
    except Exception as e:
        print(f"[track-tokens] Error reading transcript: {e}", file=sys.stderr)
    totals["total"] = sum(totals.values())
    return totals


def update_tokens(current_json_path: Path, session_id: str, session_tokens: dict):
    workflow_dir = str(current_json_path.parent)

    def modifier(data):
        sessions = data.get("_sessions", {})
        sessions[session_id] = session_tokens["total"]
        data["_sessions"] = sessions
        data["tokens_used"] = sum(sessions.values())
        return data

    data = atomic_update(workflow_dir, modifier)
    print(
        f"[track-tokens] Updated {current_json_path.parent.name}: "
        f"{session_tokens['total']:,} tokens this session, "
        f"{data['tokens_used']:,} total",
        file=sys.stderr,
    )


def main():
    try:
        hook_input = json.load(sys.stdin)
    except Exception as e:
        print(f"[track-tokens] Failed to parse hook input: {e}", file=sys.stderr)
        sys.exit(0)

    session_id = hook_input.get("session_id", "")
    transcript_path = hook_input.get("transcript_path", "")
    cwd = hook_input.get("cwd", os.getcwd())

    if not transcript_path or not os.path.exists(transcript_path):
        sys.exit(0)

    project_name = get_project_name(cwd)
    if not project_name:
        sys.exit(0)

    current_json = find_active_workflow(project_name)
    if not current_json:
        sys.exit(0)

    session_tokens = sum_transcript_tokens(transcript_path)
    if session_tokens["total"] == 0:
        sys.exit(0)

    update_tokens(current_json, session_id, session_tokens)
    sys.exit(0)


if __name__ == "__main__":
    main()
