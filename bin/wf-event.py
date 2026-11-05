#!/usr/bin/env python3
"""
Event log for the smart pipeline.

  wf-event.py log     --run-dir D --role R [--task T --attempt N --tier X --verdict V --count C --note S]
  wf-event.py persist --run-dir D --workflow-dir W --result-file F

`log` is the live, best-effort stream (events.jsonl) the dashboard tails.
`persist` stores the workflow's returned trace as the canonical record (trace.jsonl + result.json)
and folds per-task tier/attempts/status back into current.json.
"""
import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path.home() / ".claude" / "bin"))
from current_json import update_current_json  # noqa: E402


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def append(path: Path, obj: dict):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a") as f:
        f.write(json.dumps(obj, ensure_ascii=False) + "\n")


def cmd_log(a):
    ev = {"ts": now(), "run_id": Path(a.run_dir).name, "role": a.role}
    for k in ("task", "tier", "verdict", "note", "stage"):
        v = getattr(a, k)
        if v is not None:
            ev[k] = v
    for k in ("attempt", "count"):
        v = getattr(a, k)
        if v is not None:
            ev[k] = int(v)
    append(Path(a.run_dir) / "events.jsonl", ev)


def cmd_persist(a):
    run_dir = Path(a.run_dir)
    result = json.loads(Path(a.result_file).read_text())
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "result.json").write_text(json.dumps(result, indent=2, ensure_ascii=False))

    ts = now()
    with open(run_dir / "trace.jsonl", "a") as f:
        for i, ev in enumerate(result.get("trace", [])):
            f.write(json.dumps({"persisted_at": ts, "seq": i, "run_id": run_dir.name, **ev}, ensure_ascii=False) + "\n")

    by_id = {t["id"]: t for t in result.get("tasks", [])}

    def modifier(d):
        tasks = d.setdefault("tasks", {"total": 0, "completed": 0, "current_task_id": None, "items": []})
        for item in tasks.get("items", []):
            r = by_id.get(item.get("id"))
            if not r:
                continue
            for k in ("status", "tier", "tier0", "attempts", "files_changed", "escalations"):
                if k in r:
                    item[k] = r[k]
        tasks["completed"] = sum(1 for i in tasks.get("items", []) if i.get("status") == "done")
        tasks["current_task_id"] = None
        ex = d.setdefault("exec", {})
        ex.setdefault("runs", [])
        if run_dir.name not in ex["runs"]:
            ex["runs"].append(run_dir.name)
        if result.get("checkpoint"):
            ex["checkpoint"] = result["checkpoint"]
        ex["last_status"] = result.get("status")
        if result.get("status") == "blocked":
            d.setdefault("blockers", []).append({"run": run_dir.name, "task": result.get("blocked_task"), "reason": result.get("reason")})
        return d

    update_current_json(a.workflow_dir, modifier)
    done = sum(1 for t in result.get("tasks", []) if t.get("status") == "done")
    print(json.dumps({"status": result.get("status"), "tasks_done": done, "tasks": len(by_id), "trace_events": len(result.get("trace", []))}))


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    lg = sub.add_parser("log")
    lg.add_argument("--run-dir", required=True)
    lg.add_argument("--role", required=True)
    for k in ("task", "attempt", "tier", "verdict", "count", "note", "stage"):
        lg.add_argument(f"--{k}")
    ps = sub.add_parser("persist")
    ps.add_argument("--run-dir", required=True)
    ps.add_argument("--workflow-dir", required=True)
    ps.add_argument("--result-file", required=True)
    a = p.parse_args()
    {"log": cmd_log, "persist": cmd_persist}[a.cmd](a)


if __name__ == "__main__":
    main()
