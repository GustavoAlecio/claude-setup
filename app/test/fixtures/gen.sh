#!/usr/bin/env bash
# Regenerates workflow/, projects/ and stacks/ from src/*.json and src/history/*.json using the real `wf-event.py persist`
# and `wf-report.py` (the optional "report" steps of a project or history cycle; a `brief` step may carry `tree`,
# and a project may carry `files`, a name -> text map written into workflow/<project>/).
# A project's `repo` {base, tree} (path -> text maps) becomes two trees of a throwaway git repo: base goes to
# exec.base_checkpoint, tree and the repo to `brief pr`, and the script fails if that gate pr has no map.
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

HOME="$SHIM" python3 - "$HERE/src" "$OUT/workflow" "$REPO/bin/wf-event.py" "$OUT/projects" "$REPO/bin/wf-report.py" "$OUT/show" "$REPO/bin/wf-checkpoint.sh" <<'PY'
import json, os, subprocess, sys, tempfile
from contextlib import ExitStack
from datetime import datetime, timedelta, timezone
from pathlib import Path

# A hook or gate exports GIT_DIR/GIT_INDEX_FILE (git would act on the real repo), CLAUDE_FLOW_SESSION_ID becomes the
# default stage session, and a global excludesFile/autocrlf would change the tree hashes.
for key in [k for k in os.environ if k.startswith("GIT_")] + ["CLAUDE_FLOW_SESSION_ID"]:
    os.environ.pop(key, None)
os.environ["GIT_CONFIG_GLOBAL"] = "/dev/null"
os.environ["GIT_CONFIG_NOSYSTEM"] = "1"

src, out, persist, projects = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4])
report_script = sys.argv[5]
show_dir = Path(sys.argv[6])
checkpoint_script = sys.argv[7]

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

def checkpoint(repo, files, old=()):
    for rel in old:
        (repo / rel).unlink()
    for rel, text in files.items():
        (repo / rel).parent.mkdir(parents=True, exist_ok=True)
        (repo / rel).write_text(text)
    done = subprocess.run(["bash", checkpoint_script, "create", str(repo)], check=True, stdout=subprocess.PIPE, text=True)
    return done.stdout.strip()

def build_repo(repo, spec):
    """(dir, base, tree): both trees of a project's `repo` key as git tree objects in a throwaway repo."""
    subprocess.run(["git", "-c", "init.defaultBranch=main", "init", "-q", str(repo)], check=True)
    base = checkpoint(repo, spec["base"])
    tree = checkpoint(repo, spec["tree"], old=spec["base"])
    return str(repo), base, tree

def run_report(wf, steps, project=None, repo=None):
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
            built = repo is not None and step["cmd"] == "brief" and step.get("name") == "pr"
            tree = repo[2] if built else step.get("tree")
            if tree:
                cmd += ["--tree", "@" + text_file("tree.txt", tree + "\n")]
            if built:
                cmd += ["--repo", repo[0]]
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
        if "decided_at" in (st.get("gate") or {}):
            st["gate"]["decided_at"] = stamp(base + timedelta(minutes=15 * i + 5))
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
    with ExitStack() as scope:
        repo = None
        if "repo" in spec:
            # `brief pr` runs `git diff` in this repo, so it lives until the project's report is done.
            repo = build_repo(Path(scope.enter_context(tempfile.TemporaryDirectory())), spec["repo"])
            spec["current"].setdefault("exec", {})["base_checkpoint"] = repo[1]
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
        for name, text in spec.get("files", {}).items():
            (proj / name).write_text(text)
        if spec.get("report"):
            run_report(proj, spec["report"], f.stem, repo)
    if repo is not None:
        stages = json.loads((proj / "report.json").read_text())["stages"]
        gate = next((s.get("gate") for s in stages if s["stage"] == "complete"), None)
        if not isinstance(gate, dict) or not isinstance(gate.get("map"), dict):
            sys.exit(f"gen.sh: {f.name} tem repo e o gate pr ficou sem map "
                     "(confira o map do brief plan e as árvores base/tree)")
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
