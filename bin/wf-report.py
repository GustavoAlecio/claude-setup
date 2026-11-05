#!/usr/bin/env python3
"""
Stage report for the smart pipeline: $WF_DIR/report.json, written only by this script.

  wf-report.py stage-start <stage> --workflow-dir W [--session ID]   (default: $CLAUDE_FLOW_SESSION_ID)
  wf-report.py stage-end   <stage> --workflow-dir W --summary-file MD [--status done|blocked] [--artifact REL]...
  wf-report.py decision    <stage> --workflow-dir W --by WHO --text-file MD [--alternative-file MD] [--mistake]
  wf-report.py findings    <stage> --workflow-dir W --source X --file JSON
  wf-report.py import-run  <stage> --workflow-dir W --run-dir D
  wf-report.py qa          --workflow-dir W --file JSON
  wf-report.py real-data   --workflow-dir W (--file MD | --not-run)
  wf-report.py pr          --workflow-dir W --url URL
  wf-report.py reset       --workflow-dir W
  wf-report.py gate        spec|plan|tasks|pr

`gate` prints `ask` or `skip`: autopilot off always asks; on, it asks only for names in
~/.claude/workflow/gates.json {"required": [...]} (missing or invalid file: spec and pr).

Free text only ever arrives through files, so nothing the user or an agent wrote is
interpolated by a shell. Exit 2: invalid value or missing input file. Exit 3: no current.json.
Nothing is written on either.
"""
import argparse
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path.home() / ".claude" / "bin"))
from current_json import read_current_json, update_json  # noqa: E402

STAGES = ["kickoff", "specify", "challenge", "plan", "tasks", "implement", "verify", "complete"]
BY_RE = re.compile(r"^(orchestrator|challenger|user|agent:[A-Za-z0-9._-]+)$")
MAX_TEXT = 32 * 1024
TRUNC = "…[truncado]"
BLOCKING = ("critical", "major")
CLOSED_WITHOUT_REPORT = "encerrada sem relatório"
GATES = ["spec", "plan", "tasks", "pr"]
DEFAULT_REQUIRED = ["spec", "pr"]


class InputError(Exception):
    pass


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def clip(text: str) -> str:
    raw = text.encode("utf-8")
    if len(raw) <= MAX_TEXT:
        return text
    room = MAX_TEXT - len(TRUNC.encode("utf-8"))
    return raw[:room].decode("utf-8", errors="ignore") + TRUNC


def read_text(path) -> str:
    try:
        return clip(Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError) as e:
        raise InputError(f"arquivo ilegível: {path} ({e})")


def read_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, ValueError) as e:
        raise InputError(f"JSON ilegível: {path} ({e})")


def as_text(x) -> str:
    if isinstance(x, str):
        return x
    return json.dumps(x, ensure_ascii=False, sort_keys=True)


def empty_report(cycle: dict) -> dict:
    return {"version": 1, "cycle": cycle, "stages": []}


def archive_path(wf: Path, old: dict) -> Path:
    started = str((old.get("cycle") or {}).get("started_at") or "unknown").replace("/", "_")
    p = wf / f"report.{started}.json"
    n = 2
    while p.exists():
        p = wf / f"report.{started}.{n}.json"
        n += 1
    return p


def archive(wf: Path, old: dict):
    if (wf / "report.json").exists():
        os.replace(wf / "report.json", archive_path(wf, old))


def env_session():
    return os.environ.get("CLAUDE_FLOW_SESSION_ID") or None


def cycle_compatible(old, current: dict) -> bool:
    if not isinstance(old, dict):
        return False
    return all(old.get(k) is None or old.get(k) == current[k] for k in ("feature", "started_at"))


def find_stage(report: dict, stage: str):
    return next((s for s in report["stages"] if isinstance(s, dict) and s.get("stage") == stage), None)


def ensure_stage(report: dict, stage: str) -> dict:
    s = find_stage(report, stage)
    if s is not None:
        for k, v in (("decisions", []), ("findings", []), ("artifacts", []), ("run_ids", []), ("summary_md", "")):
            s.setdefault(k, v)
        return s
    s = {
        "stage": stage,
        "status": "running",
        "attempt": 1,
        "started_at": now(),
        "summary_md": "",
        "decisions": [],
        "findings": [],
        "artifacts": [],
        "run_ids": [],
    }
    if env_session():
        s["session_id"] = env_session()
    report["stages"].append(s)
    order = {name: i for i, name in enumerate(STAGES)}
    report["stages"].sort(key=lambda x: order.get(x.get("stage"), len(STAGES)) if isinstance(x, dict) else len(STAGES))
    return s


def add_decision(stage: dict, by: str, text: str, alternative=None, kind="decision") -> bool:
    text = clip(text)
    did = hashlib.sha256(f"{stage['stage']}|{by}|{text}".encode("utf-8")).hexdigest()
    if any(d.get("id") == did for d in stage["decisions"] if isinstance(d, dict)):
        return False
    d = {"id": did, "by": by, "text_md": text, "kind": kind}
    if alternative is not None:
        d["alternative_md"] = clip(alternative)
    stage["decisions"].append(d)
    return True


def has_decision_anywhere(report: dict, by: str, text: str) -> bool:
    text = clip(text)
    return any(
        isinstance(d, dict) and d.get("by") == by and d.get("text_md") == text
        for s in report["stages"] if isinstance(s, dict)
        for d in s.get("decisions", [])
    )


def cmd_stage_start(a, report):
    s = find_stage(report, a.stage)
    for other in report["stages"]:
        if isinstance(other, dict) and other is not s and other.get("status") == "running":
            other["status"] = "blocked"
            other["summary_md"] = CLOSED_WITHOUT_REPORT
            other["ended_at"] = now()
    if s is None:
        s = ensure_stage(report, a.stage)
    elif s.get("status") != "running":
        ensure_stage(report, a.stage)
        s["status"] = "running"
        s["attempt"] = int(s.get("attempt") or 1) + 1
        s["started_at"] = now()
        s.pop("ended_at", None)
    session = a.session or env_session()
    if session:
        s["session_id"] = session


def cmd_stage_end(a, report, summary):
    s = ensure_stage(report, a.stage)
    s["status"] = a.status
    s["summary_md"] = summary
    s["ended_at"] = now()
    for rel in a.artifact or []:
        if rel not in s["artifacts"]:
            s["artifacts"].append(rel)
    return f"decisions: {len(s['decisions'])}"


def cmd_decision(a, report, text, alternative):
    s = ensure_stage(report, a.stage)
    add_decision(s, a.by, text, alternative, "mistake" if a.mistake else "decision")


def clip_findings(entries):
    out = []
    for e in entries:
        if isinstance(e, dict):
            e = {k: clip(v) if k.endswith("_md") and isinstance(v, str) else v for k, v in e.items()}
        out.append(e)
    return out


def cmd_findings(a, report, payload):
    s = ensure_stage(report, a.stage)
    entry = {
        "source": a.source,
        "accepted": clip_findings(payload.get("accepted") or []),
        "rejected": clip_findings(payload.get("rejected") or []),
    }
    for i, f in enumerate(s["findings"]):
        if isinstance(f, dict) and f.get("source") == a.source:
            s["findings"][i] = entry
            break
    else:
        s["findings"].append(entry)


def escalation_text(e) -> str:
    if not isinstance(e, dict):
        return f"Escalada na escada: {as_text(e)}"
    opened = ", ".join(as_text(x) for x in e.get("open") or [])
    text = f"Escalada na escada: {e.get('from')} → {e.get('to')} na tentativa {e.get('at_attempt')}"
    return text + (f" (abertos: {opened})" if opened else "")


def backtrack_text(b) -> str:
    if not isinstance(b, dict):
        return f"Backtrack: {as_text(b)}"
    text = f"Backtrack em {b.get('task') or '-'}: {as_text(b.get('reason') or '')}"
    return text + (f" → {as_text(b['resolution'])}" if b.get("resolution") else "")


def blocker_text(b) -> str:
    if not isinstance(b, dict):
        return f"Bloqueio: {as_text(b)}"
    return f"Bloqueio em {b.get('task') or '-'} (run {b.get('run') or '-'}): {as_text(b.get('reason') or '')}"


def choice_items(choices):
    if isinstance(choices, dict):
        return [f"{k}: {as_text(v)}" for k, v in choices.items()]
    if isinstance(choices, list):
        return [as_text(c) for c in choices]
    return [as_text(choices)] if choices else []


def gate_summary(gate: str, v: dict) -> dict:
    findings = [f for f in v.get("findings") or [] if isinstance(f, dict)]
    return {
        "gate": gate,
        "verdict": v.get("verdict"),
        "findings": len(findings),
        "blocking": sum(1 for f in findings if f.get("severity") in BLOCKING),
    }


def cmd_import_run(a, report, result, current):
    run_id = Path(a.run_dir).resolve().name
    s = ensure_stage(report, a.stage)
    if run_id not in s["run_ids"]:
        s["run_ids"].append(run_id)

    for t in result.get("tasks") or []:
        if not isinstance(t, dict) or not t.get("id"):
            continue
        by = f"agent:{t['id']}"
        for d in t.get("decisions") or []:
            add_decision(s, by, as_text(d))
        for e in t.get("escalations") or []:
            add_decision(s, by, escalation_text(e))

    rep = result.get("report")
    if a.stage == "verify" and isinstance(rep, dict):
        gates = [gate_summary(g.get("gate") or "G1", g) for g in rep.get("g1") or [] if isinstance(g, dict)]
        if isinstance(rep.get("g2"), dict):
            gates.append(gate_summary("G2", rep["g2"]))
        s["verify"] = {
            "run_id": run_id,
            "round": rep.get("round"),
            "status": result.get("status"),
            "reason": result.get("reason"),
            "gates": gates,
        }

    for b in current.get("backtracks") or []:
        text = backtrack_text(b)
        if not has_decision_anywhere(report, "orchestrator", text):
            add_decision(s, "orchestrator", text, kind="mistake")
    for b in current.get("blockers") or []:
        if isinstance(b, dict) and b.get("run") and b["run"] != run_id:
            continue
        text = blocker_text(b)
        if not has_decision_anywhere(report, "orchestrator", text):
            add_decision(s, "orchestrator", text, kind="mistake")

    ch = current.get("challenge")
    if isinstance(ch, dict) and (ch.get("applied") or ch.get("choices")):
        cs = ensure_stage(report, "challenge")
        for x in ch.get("applied") or []:
            add_decision(cs, "challenger", f"Achado aplicado na spec: {as_text(x)}")
        for x in choice_items(ch.get("choices")):
            add_decision(cs, "user", x)


def required_gates(workflow_root: Path) -> list:
    try:
        data = json.loads((workflow_root / "gates.json").read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, ValueError):
        return DEFAULT_REQUIRED
    required = data.get("required") if isinstance(data, dict) else None
    if not isinstance(required, list) or not all(isinstance(x, str) for x in required):
        return DEFAULT_REQUIRED
    return required


def cmd_qa(report, qa):
    report["qa"] = qa


def cmd_real_data(report, md):
    report["real_data_md"] = md
    if md is None:
        report["real_data_status"] = "não executado"
    else:
        report.pop("real_data_status", None)


def cmd_pr(report, pr):
    report["pr"] = pr


def cmd_gate(name: str) -> str:
    root = Path.home() / ".claude" / "workflow"
    if not (root / "auto_mode.flag").exists():
        return "ask"
    return "ask" if name in required_gates(root) else "skip"


def parse_args():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    def stage_cmd(name):
        sp = sub.add_parser(name)
        sp.add_argument("stage", choices=STAGES)
        sp.add_argument("--workflow-dir", required=True)
        return sp

    sp = stage_cmd("stage-start")
    sp.add_argument("--session")
    sp = stage_cmd("stage-end")
    sp.add_argument("--summary-file", required=True)
    sp.add_argument("--status", choices=["done", "blocked"], default="done")
    sp.add_argument("--artifact", action="append")
    sp = stage_cmd("decision")
    sp.add_argument("--by", required=True)
    sp.add_argument("--text-file", required=True)
    sp.add_argument("--alternative-file")
    sp.add_argument("--mistake", action="store_true")
    sp = stage_cmd("findings")
    sp.add_argument("--source", required=True)
    sp.add_argument("--file", required=True)
    sp = stage_cmd("import-run")
    sp.add_argument("--run-dir", required=True)
    sp = sub.add_parser("qa")
    sp.add_argument("--workflow-dir", required=True)
    sp.add_argument("--file", required=True)
    sp = sub.add_parser("real-data")
    sp.add_argument("--workflow-dir", required=True)
    grp = sp.add_mutually_exclusive_group(required=True)
    grp.add_argument("--file")
    grp.add_argument("--not-run", action="store_true")
    sp = sub.add_parser("pr")
    sp.add_argument("--workflow-dir", required=True)
    sp.add_argument("--url", required=True)
    sp = sub.add_parser("reset")
    sp.add_argument("--workflow-dir", required=True)
    sp = sub.add_parser("gate")
    sp.add_argument("name", choices=GATES)
    return p.parse_args()


def load_inputs(a):
    """Reads and validates every input before the report is touched."""
    if a.cmd == "stage-end":
        return {"summary": read_text(a.summary_file)}
    if a.cmd == "decision":
        if not BY_RE.match(a.by):
            raise InputError(f"--by inválido: {a.by}")
        alt = read_text(a.alternative_file) if a.alternative_file else None
        return {"text": read_text(a.text_file), "alternative": alt}
    if a.cmd == "findings":
        payload = read_json(a.file)
        if not isinstance(payload, dict) or not all(isinstance(payload.get(k, []), list) for k in ("accepted", "rejected")):
            raise InputError("--file precisa ser {accepted: [...], rejected: [...]}")
        return {"payload": payload}
    if a.cmd == "import-run":
        result = read_json(Path(a.run_dir) / "result.json")
        if not isinstance(result, dict):
            raise InputError("result.json não é um objeto")
        return {"result": result}
    if a.cmd == "qa":
        payload = read_json(a.file)
        if not isinstance(payload, list) or not all(isinstance(x, str) for x in payload):
            raise InputError("--file precisa ser um array de strings")
        return {"qa": payload}
    if a.cmd == "real-data":
        return {"md": None if a.not_run else read_text(a.file)}
    if a.cmd == "pr":
        m = re.fullmatch(r"https://github\.com/[^/\s]+/[^/\s]+/pull/(\d+)(?:[/?#]\S*)?", a.url)
        if not m:
            raise InputError(f"--url não é um PR do GitHub: {a.url}")
        return {"pr": {"url": a.url, "number": int(m.group(1))}}
    return {}


def main():
    a = parse_args()
    if a.cmd == "gate":
        print(cmd_gate(a.name))
        return
    try:
        inputs = load_inputs(a)
    except InputError as e:
        print(f"wf-report: {e}", file=sys.stderr)
        sys.exit(2)

    wf = Path(a.workflow_dir)
    if not (wf / "current.json").is_file():
        print(f"wf-report: sem current.json em {wf}", file=sys.stderr)
        sys.exit(3)
    current = read_current_json(str(wf))
    cycle = {"feature": current.get("feature"), "started_at": current.get("start_date")}
    out = []

    def modify(report):
        if isinstance(report, dict) and report.get("version") == 1 and cycle_compatible(report.get("cycle"), cycle):
            report["cycle"] = dict(cycle)
        if not isinstance(report, dict) or report.get("version") != 1 or report.get("cycle") != cycle or a.cmd == "reset":
            if not (a.cmd == "reset" and isinstance(report, dict) and report.get("cycle") == cycle and not report.get("stages")):
                archive(wf, report if isinstance(report, dict) else {})
            report = empty_report(cycle)
        if not isinstance(report.get("stages"), list):
            report["stages"] = []
        if a.cmd == "stage-start":
            cmd_stage_start(a, report)
        elif a.cmd == "stage-end":
            out.append(cmd_stage_end(a, report, inputs["summary"]))
        elif a.cmd == "decision":
            cmd_decision(a, report, inputs["text"], inputs["alternative"])
        elif a.cmd == "findings":
            cmd_findings(a, report, inputs["payload"])
        elif a.cmd == "import-run":
            cmd_import_run(a, report, inputs["result"], current)
        elif a.cmd == "qa":
            cmd_qa(report, inputs["qa"])
        elif a.cmd == "real-data":
            cmd_real_data(report, inputs["md"])
        elif a.cmd == "pr":
            cmd_pr(report, inputs["pr"])
        return report

    update_json(wf / "report.json", wf / ".report.json.lock", modify, default=empty_report(cycle))
    for line in out:
        print(line)


if __name__ == "__main__":
    main()
