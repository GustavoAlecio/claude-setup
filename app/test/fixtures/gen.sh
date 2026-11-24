#!/usr/bin/env bash
# Regenerates workflow/, projects/ and stacks/ from src/*.json and src/history/*.json using the real `wf-event.py persist`
# and `wf-report.py` (the optional "report" steps of a project or history cycle).
# `--check` regenerates into a tmp dir and fails on any diff against the committed output.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
MODE="${1:-}"
case "$MODE" in
  ''|--check) ;;
  *) echo "uso: gen.sh [--check]" >&2; exit 2 ;;
esac

CLEAN_OUT=""
if [ "$MODE" = "--check" ]; then
  OUT="$(mktemp -d)"
  CLEAN_OUT="$OUT"
else
  OUT="$HERE"
fi

SHIM="$(mktemp -d)"
trap 'rm -rf "$SHIM" ${CLEAN_OUT:+"$CLEAN_OUT"}' EXIT
mkdir -p "$SHIM/.claude"
ln -s "$REPO/bin" "$SHIM/.claude/bin"
ln -s "$REPO/stacks" "$SHIM/.claude/stacks"

rm -rf "$OUT/workflow" "$OUT/projects" "$OUT/stacks" "$OUT/show"
mkdir -p "$OUT/workflow" "$OUT/projects" "$OUT/stacks" "$OUT/show"
cp "$REPO/stacks/flutter.json" "$OUT/stacks/flutter.json"

HOME="$SHIM" python3 - "$HERE/src" "$OUT/workflow" "$REPO/bin/wf-event.py" "$OUT/projects" "$REPO/bin/wf-report.py" "$OUT/show" <<'PY'
import json, os, subprocess, sys, tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

src, out, persist, projects = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4])
report_script = sys.argv[5]
show_dir = Path(sys.argv[6])

def dump(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + "\n")

def run_persist(run_dir, workflow_dir, result):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as tmp:
        json.dump(result, tmp)
    subprocess.run(
        ["python3", persist, "persist", "--run-dir", str(run_dir),
         "--workflow-dir", str(workflow_dir), "--result-file", tmp.name],
        check=True, stdout=subprocess.DEVNULL)
    os.unlink(tmp.name)

def run_report(wf, steps, project=None):
    """Runs wf-report.py steps against `wf` (which holds current.json) and pins the wall-clock stamps."""
    with tempfile.TemporaryDirectory() as scratch:
        for i, step in enumerate(steps):
            cmd = ["python3", report_script, step["cmd"]]
            if "stage" in step:
                cmd.append(step["stage"])
            if "name" in step:
                cmd.append(step["name"])
            cmd += ["--workflow-dir", str(wf)]
            def text_file(name, text):
                path = Path(scratch) / f"{i}-{name}"
                path.write_text(text)
                return str(path)
            if "session" in step:
                cmd += ["--session", step["session"]]
            if "summary" in step:
                cmd += ["--summary-file", text_file("summary.md", step["summary"])]
            if "status" in step:
                cmd += ["--status", step["status"]]
            for rel in step.get("artifacts", []):
                cmd += ["--artifact", rel]
            if "by" in step:
                cmd += ["--by", step["by"], "--text-file", text_file("text.md", step["text"])]
            if "alternative" in step:
                cmd += ["--alternative-file", text_file("alt.md", step["alternative"])]
            if step.get("mistake"):
                cmd.append("--mistake")
            if "source" in step:
                payload = text_file("findings.json", json.dumps(step["payload"], ensure_ascii=False))
                cmd += ["--source", step["source"], "--file", payload]
            if "run" in step:
                cmd += ["--run-dir", str(wf / "runs" / step["run"])]
            if "qa" in step:
                cmd += ["--file", text_file("qa.json", json.dumps(step["qa"], ensure_ascii=False))]
            if "real_data" in step:
                cmd += ["--file", text_file("real-data.md", step["real_data"])]
            if step.get("not_run"):
                cmd.append("--not-run")
            if "pr_url" in step:
                cmd += ["--url", step["pr_url"]]
            if "file" in step:
                cmd += ["--file", text_file("brief.json", json.dumps(step["file"], ensure_ascii=False))]
            if "candidates" in step:
                cmd += ["--candidates", text_file("candidates.json", json.dumps(step["candidates"], ensure_ascii=False))]
            if "question" in step:
                cmd += ["--question", step["question"]]
            if "option" in step:
                cmd += ["--option", step["option"]]
            if "answer_text" in step:
                cmd += ["--text-file", text_file("answer.md", step["answer_text"])]
            if step.get("approve"):
                cmd.append("--approve")
            if step.get("reject"):
                cmd.append("--reject")
            done = subprocess.run(cmd, check=True, stdout=subprocess.PIPE, text=True)
            if step["cmd"] == "show" and step.get("save"):
                dump(show_dir / f"{project}-{step['name']}.json", json.loads(done.stdout))
    for leftover in (".report.json.lock", "report.json.tmp"):
        (wf / leftover).unlink(missing_ok=True)
    report = wf / "report.json"
    data = json.loads(report.read_text())
    base = datetime(2026, 3, 10, 7, 0, 0, tzinfo=timezone.utc)
    stamp = lambda t: t.strftime("%Y-%m-%dT%H:%M:%SZ")
    for i, st in enumerate(data["stages"]):
        st["started_at"] = stamp(base + timedelta(minutes=15 * i))
        if "ended_at" in st:
            st["ended_at"] = stamp(base + timedelta(minutes=15 * i + 10))
    dump(report, data)

for f in sorted(src.glob("*.json")):
    spec = json.loads(f.read_text())
    if f.stem == "_root":
        for rel, obj in spec["hidden"].items():
            dump(out / rel, obj)
        dump(out / ".dashboard.json", spec["dashboard"])
        (out / "auto_mode.flag").write_text(spec["auto_mode"])
        continue
    proj = out / f.stem
    dump(proj / "current.json", spec["current"])
    for run in spec["runs"]:
        run_dir = proj / "runs" / run["id"]
        run_dir.mkdir(parents=True, exist_ok=True)
        if run.get("events") is not None:
            lines = "".join(json.dumps(e, ensure_ascii=False) + "\n" for e in run["events"])
            (run_dir / "events.jsonl").write_text(lines + run.get("events_tail_raw", ""))
        if run.get("result") is not None:
            run_persist(run_dir, proj, run["result"])
        if run.get("result_raw") is not None:
            (run_dir / "result.json").write_text(run["result_raw"])
    if spec.get("report"):
        run_report(proj, spec["report"], f.stem)
    (proj / ".current.json.lock").unlink(missing_ok=True)
    for t in (proj / "runs").glob("*/trace.jsonl"):
        t.unlink()

# persist stamps `persisted_at` with the wall clock; history traces are kept, so the stamp is pinned per run.
for f in sorted((src / "history").glob("*.json")):
    for cycle in json.loads(f.read_text())["cycles"]:
        cycle_dir = projects / f.stem / "history" / cycle["dir"]
        dump(cycle_dir / "metrics.json", cycle["metrics"])
        if cycle.get("report"):
            with tempfile.TemporaryDirectory() as scratch:
                wf = Path(scratch)
                dump(wf / "current.json", {"feature": cycle["metrics"]["feature"], "start_date": cycle["report_start_date"]})
                run_report(wf, cycle["report"])
                (cycle_dir / "report.json").write_text((wf / "report.json").read_text())
        for run in cycle.get("runs", []):
            run_dir = cycle_dir / "runs" / run["id"]
            run_dir.mkdir(parents=True, exist_ok=True)
            if run.get("events") is not None:
                (run_dir / "events.jsonl").write_text(
                    "".join(json.dumps(e, ensure_ascii=False) + "\n" for e in run["events"]))
            if run.get("result") is None:
                continue
            with tempfile.TemporaryDirectory() as scratch:
                run_persist(run_dir, scratch, run["result"])
            trace = run_dir / "trace.jsonl"
            lines = [json.loads(l) for l in trace.read_text().splitlines()]
            trace.write_text("".join(
                json.dumps({**l, "persisted_at": run["persisted_at"]}, ensure_ascii=False) + "\n" for l in lines))
PY

if [ "$MODE" = "--check" ]; then
  for d in workflow projects stacks show; do
    diff -r "$OUT/$d" "$HERE/$d" || { echo "fixtures drift em $d/: rode app/test/fixtures/gen.sh" >&2; exit 1; }
  done
  echo "fixtures ok"
fi
