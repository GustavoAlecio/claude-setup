#!/usr/bin/env bash
# Regenerates workflow/, projects/ and stacks/ from src/*.json and src/history/*.json using the real `wf-event.py persist`.
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

rm -rf "$OUT/workflow" "$OUT/projects" "$OUT/stacks"
mkdir -p "$OUT/workflow" "$OUT/projects" "$OUT/stacks"
cp "$REPO/stacks/flutter.json" "$OUT/stacks/flutter.json"

HOME="$SHIM" python3 - "$HERE/src" "$OUT/workflow" "$REPO/bin/wf-event.py" "$OUT/projects" <<'PY'
import json, os, subprocess, sys, tempfile
from pathlib import Path

src, out, persist, projects = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4])

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
    (proj / ".current.json.lock").unlink(missing_ok=True)
    for t in (proj / "runs").glob("*/trace.jsonl"):
        t.unlink()

# persist stamps `persisted_at` with the wall clock; history traces are kept, so the stamp is pinned per run.
for f in sorted((src / "history").glob("*.json")):
    for cycle in json.loads(f.read_text())["cycles"]:
        cycle_dir = projects / f.stem / "history" / cycle["dir"]
        dump(cycle_dir / "metrics.json", cycle["metrics"])
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
  for d in workflow projects stacks; do
    diff -r "$OUT/$d" "$HERE/$d" || { echo "fixtures drift em $d/: rode app/test/fixtures/gen.sh" >&2; exit 1; }
  done
  echo "fixtures ok"
fi
