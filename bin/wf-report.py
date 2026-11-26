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
  wf-report.py gate        spec|plan|tasks|pr --workflow-dir W
  wf-report.py brief      spec|plan|tasks|pr --workflow-dir W --file JSON [--candidates JSON] [--tree @FILE]
                           [--drop-map] [--repo DIR]
  wf-report.py built-map   --workflow-dir W --tree @FILE [--repo DIR]
  wf-report.py answer      spec|plan|tasks|pr --workflow-dir W
                           (--question ID (--option ID [--text-file MD] | --text-file MD) | --text-file MD
                            | --approve | --reject)
  wf-report.py show        spec|plan|tasks|pr --workflow-dir W
  wf-report.py reopen      pr --workflow-dir W

`gate` prints `ask` or `skip` from the stage's brief (the stop table), never from the autopilot
flag. Required gates are spec, pr and the names in ~/.claude/workflow/gates.json
{"required": [...]} (missing, invalid or empty: spec and pr). No block, an `open` block with a
question unanswered, `revising` and `rejected` ask; `approved` and `passed` skip untouched; an
`open` block with nothing pending asks when required, otherwise skips and is written `passed`
with `decided_at` (rechecked under the report lock). No current.json, no report.json or a report from another
cycle asks and writes nothing.

`brief` writes the decision brief as `gate` on the owner stage (spec → challenge, plan → plan,
tasks → tasks, pr → complete) and prints the same payload as `show`. The file is
{summary, artifact, risks?, questions?, changes?, map?}; round, status, answer, history, cut and
decided_at are the script's and refuse the file. Risks and questions above 3 are cut in the order received
and counted in `omitted`. `--candidates` is a JSON array of {id, text}: those whose id is not a
kept question go to `cut` (up to 10).
Rounds: with no block, or over a round 1 block that is not `revising`, it writes round 1 `open`,
answers cleared. Over a `revising` block it writes round + 1: the answered questions move to
`history`, the file must bring 1 to 3 `changes` and no id already in `history`; round 4 exits 2
with `rodadas esgotadas`. Over any other block of round 2 or more, only the same file is
accepted (a no-op).
Architecture map. In gate `plan` the file's `map` is the author's, cut by the critic:
{summary, nodes[], edges[]?, approaches[]?, gains[]?, costs[]?, ignore[]?}. Each node is
{id, label, state new|changed|existing, note?, paths[]} (up to 8 nodes, 1 to 6 relative globs each,
required on `new` and `changed`, an id never starts with `unplanned:`); edges join node ids;
`approaches` has up to 3 entries and exactly one `chosen`. Any other gate refuses `map`, and
`--drop-map` (plan only) writes the block without it, for the retry after a refusal that starts
with `wf-report: map`. In gate `pr` the map is the script's, never the file's: `brief pr` computes
it from `git diff --no-renames --name-only` between `exec.base_checkpoint` and `--tree`, run in
`--repo` (default: `project_path` of current.json), against the map recorded in gate `plan`. Each
changed file goes to the first node whose glob matches it, and each piece carries `built`:
`planned`, `untouched` (planned and not touched), `touched` (existing, touched without being in the
plan), `existing`, or `unplanned` (files in no node and not in `ignore`, grouped by directory as
`unplanned:<dir>`, the tail folded into `unplanned:outros`, which also takes a directory named
`outros`; the planned pieces plus at least one `unplanned` group, so 9 pieces when the plan uses 8).
No plan map: the block is written without a map, silently. No file list or no git: the block is
written without a map and stderr says `mapa construído indisponível`; exit 0 in both. Resending
the same file over a round 2 or later block with the same base and tree keeps that block's map, or
its lack of one, whatever git says now.
`built-map` prints that same map as JSON without writing anything (`{}` when unavailable); it
needs `--tree`, resolves `base` like `brief pr` and never archives the report.

`answer` records one answer; the block leaves `open` only when every question has one: all equal
to `assumed` → `approved`, any other option or free text → `revising`. `--option` with `--text-file`
records the option plus the text of the adjust (`answer_text`) and only exists in gate pr with
`change`; `--option` alone clears that text. `--text-file` alone is
the adjust of a block without questions (→ `revising`), `--approve` needs nothing pending and
`--reject` writes `rejected`. Repeating a recorded value is a no-op; an unknown question or
option, or any other answer on an `approved`, `passed` or `rejected` block, exits 2.
`decided_at` (ISO UTC) is stamped once, when `answer` or `gate` moves the block into `approved`,
`rejected` or `passed`; it is never overwritten and resending the same file ignores it.
`show` is read-only and prints {status, round, text_md, questions} in AskUserQuestion shape, with
only the questions still unanswered and the recorded answers in `text_md`, or
{"status":"absent"} when the stage has no brief. None of the three ever archives the report: a
missing report or one from another cycle exits 2.

A question may bring `header` (up to 12 characters), shown as the AskUserQuestion header in
place of its id.

Gate `pr`: every question also brings `why` and `anchor {path, start, end}` (start <= end), its
options are exactly `ok` and `change` and `assumed` is `ok`. `show` carries both on each pending
question and lists them under `Pontos:` in `text_md`. `--tree @FILE` is required and names
the file `wf-checkpoint.sh create` wrote (40 hex); `base` comes from `exec.base_checkpoint` of
current.json, so no hash is ever typed. `reopen pr` turns each answer other than `ok` of the
`revising` pr block into a pending task `P<round>.<n>` appended to current.json `tasks` and to
tasks.md. It never writes report.json, adds only ids not already there, and takes the report
lock before the current.json one. A `change` answer without `answer_text` makes it exit 2 naming
the questions, before anything is written: the task would have nothing to do but the option label.
`stage-start` on an owner stage drops its `gate` unless it is `revising` below the round cap: the pending round
survives the re-entry of /complete, but a block that exhausted the rounds does not stay stuck.

Free text only ever arrives through files, so nothing the user or an agent wrote is
interpolated by a shell. Exit 2: invalid value or missing input file. Exit 3: no current.json.
Nothing is written on either.
"""
import argparse
import copy
import fcntl
import hashlib
import json
import os
import posixpath
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path.home() / ".claude" / "bin"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from current_json import read_current_json, update_json  # noqa: E402
from glob_util import glob_re  # noqa: E402

STAGES = ["kickoff", "specify", "challenge", "plan", "tasks", "implement", "verify", "complete"]
BY_RE = re.compile(r"^(orchestrator|challenger|user|agent:[A-Za-z0-9._-]+)$")
MAX_TEXT = 32 * 1024
TRUNC = "…[truncado]"
BLOCKING = ("critical", "major")
CLOSED_WITHOUT_REPORT = "encerrada sem relatório"
GATES = ["spec", "plan", "tasks", "pr"]
DEFAULT_REQUIRED = ["spec", "pr"]
NEVER_ARCHIVE = ("brief", "answer", "show", "reopen")
GATE_OWNER = {"spec": "challenge", "plan": "plan", "tasks": "tasks", "pr": "complete"}
BRIEF_FORBIDDEN = ("round", "status", "answer", "history", "cut", "decided_at")
BRIEF_KEEP = 3
CUT_MAX = 10
ROUNDS_MAX = 3
CLOSED_GATE = ("approved", "passed", "rejected")
CAPS = {
    "summary": 280,
    "risk": 160,
    "question": 140,
    "header": 12,
    "label": 40,
    "consequence": 120,
    "change": 120,
    "why": 160,
    "map.summary": 200,
    "node.label": 32,
    "node.note": 80,
    "edge.label": 60,
    "approach.label": 40,
    "approach.text": 200,
    "map.item": 160,
    "glob": 120,
}
MAP_NODES_MAX = 8
NODE_PATHS_MAX = 6
APPROACHES_MAX = 3
MAP_ITEMS_MAX = 3
IGNORE_MAX = 10
UNPLANNED = "unplanned:"
GIT_TIMEOUT = 10
BUILT_TEXT = {"unplanned": "fora do plano", "untouched": "não tocada", "touched": "tocada sem estar no plano"}
SENTENCE_END = re.compile(r"[.!?](?:\s|$)")
RISK_SOURCE_RE = re.compile(r"^(challenger:\S+|critic|author)$")
NODE_STATES = ("new", "changed", "existing")
PR_OPTIONS = ("change", "ok")
SHA_RE = re.compile(r"[0-9a-f]{40}")
RECOMMENDED = " (Recomendado)"


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
    if a.stage in GATE_OWNER.values() and "gate" in s:
        g = s["gate"]
        capped = a.stage != GATE_OWNER["pr"] and int(g.get("round") or 1) >= ROUNDS_MAX
        if not (isinstance(g, dict) and g.get("status") == "revising") or capped:
            del s["gate"]
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


def required_gates(workflow_root: Path) -> set:
    try:
        data = json.loads((workflow_root / "gates.json").read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, ValueError):
        return set(DEFAULT_REQUIRED)
    required = data.get("required") if isinstance(data, dict) else None
    if not isinstance(required, list) or not all(isinstance(x, str) for x in required):
        return set(DEFAULT_REQUIRED)
    return set(DEFAULT_REQUIRED) | set(required)


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


def decide(name: str, block, required) -> tuple:
    """(verdict, write_passed) for a gate given its block and the required names (the stop table)."""
    if not isinstance(block, dict):
        return "ask", False
    status = block.get("status")
    if status in ("approved", "passed"):
        return "skip", False
    if status != "open":
        return "ask", False
    questions = block.get("questions") if isinstance(block.get("questions"), list) else []
    if any(not isinstance(q, dict) or q.get("answer") is None for q in questions):
        return "ask", False
    if name in required:
        return "ask", False
    return "skip", True


def gate_block(report, cycle: dict, name: str):
    if not (isinstance(report, dict) and report.get("version") == 1 and cycle_compatible(report.get("cycle"), cycle)):
        return None
    stages = report.get("stages") if isinstance(report.get("stages"), list) else []
    s = next((x for x in stages if isinstance(x, dict) and x.get("stage") == GATE_OWNER[name]), None)
    return s.get("gate") if s else None


class _GateChanged(Exception):
    def __init__(self, verdict):
        self.verdict = verdict


def cmd_gate(a) -> str:
    wf = Path(a.workflow_dir)
    if not (wf / "current.json").is_file():
        return "ask"
    current = read_current_json(str(wf))
    cycle = {"feature": current.get("feature"), "started_at": current.get("start_date")}
    required = required_gates(Path.home() / ".claude" / "workflow")
    try:
        report = json.loads((wf / "report.json").read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, ValueError):
        return "ask"
    verdict, write = decide(a.name, gate_block(report, cycle, a.name), required)
    if not write:
        return verdict

    def modify(report):
        block = gate_block(report, cycle, a.name)
        again, still = decide(a.name, block, required)
        if not still:
            raise _GateChanged(again)
        block["status"] = "passed"
        block.setdefault("decided_at", now())
        return report

    try:
        update_json(wf / "report.json", wf / ".report.json.lock", modify, default={})
    except _GateChanged as e:
        return e.verdict
    return verdict


def excerpt(v) -> str:
    s = v if isinstance(v, str) else as_text(v)
    return s if len(s) <= 60 else s[:57] + "…"


def sentences(text: str) -> int:
    return sum(1 for part in SENTENCE_END.split(text) if part.strip())


def check_obj(field, v) -> dict:
    if not isinstance(v, dict):
        raise InputError(f"{field}: precisa ser objeto (valor: {excerpt(v)})")
    return v


def check_list(field, v) -> list:
    if not isinstance(v, list):
        raise InputError(f"{field}: precisa ser lista (valor: {excerpt(v)})")
    return v


def check_text(field, v, cap=None) -> str:
    if not isinstance(v, str) or not v.strip():
        raise InputError(f"{field}: precisa ser texto não vazio (valor: {excerpt(v)})")
    if cap is not None and len(v) > cap:
        raise InputError(f"{field}: {len(v)} caracteres, teto {cap} (valor: {excerpt(v)})")
    return v


def check_option_ref(field, v, option_ids):
    if v not in option_ids:
        raise InputError(f"{field}: {excerpt(v)} não é opção da pergunta (opções: {', '.join(option_ids)})")


def glob_match(glob: str, path: str) -> bool:
    """`*` stays inside one directory, `**` crosses them, `x/` is `x/**`, a glob without wildcards is one file."""
    return bool(glob_re(glob + "**" if glob.endswith("/") else glob).match(path))


def check_glob(field, v) -> str:
    check_text(field, v, CAPS["glob"])
    if v.startswith("/"):
        raise InputError(f"{field}: glob absoluto; use caminho relativo à raiz do repo (valor: {excerpt(v)})")
    if ".." in v.split("/"):
        raise InputError(f"{field}: glob com segmento .. (valor: {excerpt(v)})")
    if v.startswith("./"):
        raise InputError(f"{field}: glob com prefixo ./ (valor: {excerpt(v)})")
    if "\\" in v:
        raise InputError(f"{field}: glob com barra invertida; use / (valor: {excerpt(v)})")
    return v


def check_short_list(field, v, cap, unit) -> list:
    items = check_list(field, v)
    if len(items) > cap:
        raise InputError(f"{field}: {len(items)} {unit}, teto {cap}")
    return items


def validate_map(m):
    m = check_obj("map", m)
    if "summary" in m:
        check_text("map.summary", m["summary"], CAPS["map.summary"])
    nodes = check_list("map.nodes", m.get("nodes", []))
    if len(nodes) > MAP_NODES_MAX:
        raise InputError(f"map.nodes: {len(nodes)} nós, teto {MAP_NODES_MAX}")
    ids = []
    for k, n in enumerate(nodes):
        f = f"map.nodes[{k}]"
        check_obj(f, n)
        nid = check_text(f"{f}.id", n.get("id"))
        if nid in ids:
            raise InputError(f"{f}.id: {excerpt(nid)} repetido (já usado em map.nodes[{ids.index(nid)}])")
        if nid.startswith(UNPLANNED):
            raise InputError(f"{f}.id: {excerpt(nid)} começa com {UNPLANNED}, reservado ao mapa construído")
        ids.append(nid)
        label = check_text(f"{f}.label", n.get("label"), CAPS["node.label"])
        if "/" in label:
            raise InputError(f"{f}.label: caminho de arquivo; o rótulo é o nome da peça (valor: {excerpt(label)})")
        if n.get("state") not in NODE_STATES:
            raise InputError(f"{f}.state: {excerpt(n.get('state'))} fora de {'|'.join(NODE_STATES)}")
        if "note" in n:
            check_text(f"{f}.note", n["note"], CAPS["node.note"])
        if "paths" not in n and n["state"] != "existing":
            raise InputError(f"{f}.paths: obrigatório em peça {n['state']} (1 a {NODE_PATHS_MAX} globs)")
        if "paths" in n:
            paths = check_short_list(f"{f}.paths", n["paths"], NODE_PATHS_MAX, "globs")
            if not paths:
                raise InputError(f"{f}.paths: 0 globs, precisa de 1 a {NODE_PATHS_MAX}")
            for i, g in enumerate(paths):
                check_glob(f"{f}.paths[{i}]", g)
    for j, e in enumerate(check_list("map.edges", m.get("edges", []))):
        f = f"map.edges[{j}]"
        check_obj(f, e)
        for end in ("from", "to"):
            if e.get(end) not in ids:
                raise InputError(f"{f}.{end}: {excerpt(e.get(end))} não é nó do mapa (nós: {', '.join(ids)})")
        if "label" in e:
            check_text(f"{f}.label", e["label"], CAPS["edge.label"])
    approaches = check_short_list("map.approaches", m.get("approaches", []), APPROACHES_MAX, "formas")
    for j, ap in enumerate(approaches):
        f = f"map.approaches[{j}]"
        check_obj(f, ap)
        check_text(f"{f}.id", ap.get("id"))
        check_text(f"{f}.label", ap.get("label"), CAPS["approach.label"])
        check_text(f"{f}.text", ap.get("text"), CAPS["approach.text"])
        if not isinstance(ap.get("chosen"), bool):
            raise InputError(f"{f}.chosen: precisa ser booleano (valor: {excerpt(ap.get('chosen'))})")
    chosen = sum(1 for ap in approaches if ap["chosen"])
    if approaches and chosen != 1:
        raise InputError(f"map.approaches: {chosen} escolhidas, precisa de exatamente 1")
    for key in ("gains", "costs"):
        for j, t in enumerate(check_short_list(f"map.{key}", m.get(key, []), MAP_ITEMS_MAX, "itens")):
            check_text(f"map.{key}[{j}]", t, CAPS["map.item"])
    for j, g in enumerate(check_short_list("map.ignore", m.get("ignore", []), IGNORE_MAX, "globs")):
        check_glob(f"map.ignore[{j}]", g)


def left_trunc(text: str, cap: int) -> str:
    return text if len(text) <= cap else "…" + text[len(text) - cap + 1:]


def built_map(plan: dict, files) -> dict:
    """The map of what was built: each changed file goes to the first planned piece whose paths match it."""
    nodes = plan.get("nodes", [])
    ignore = plan.get("ignore", [])
    owned = {n["id"]: [] for n in nodes}
    loose = {}
    for path in sorted(set(files)):
        owner = next((n["id"] for n in nodes if any(glob_match(g, path) for g in n.get("paths", []))), None)
        if owner is not None:
            owned[owner].append(path)
        elif not any(glob_match(g, path) for g in ignore):
            loose.setdefault(posixpath.dirname(path) or ".", []).append(path)
    pieces = []
    for n in nodes:
        got = owned[n["id"]]
        if n["state"] == "existing":
            built = "touched" if got else "existing"
        else:
            built = "planned" if got else "untouched"
        piece = {"id": n["id"], "label": n["label"], "state": n["state"], "built": built, "files": got}
        for k in ("note", "paths"):
            if k in n:
                piece[k] = copy.deepcopy(n[k])
        pieces.append(piece)
    groups = [(UNPLANNED + d, left_trunc(d, CAPS["node.label"]), fs)
              for d, fs in sorted(loose.items(), key=lambda kv: (-len(kv[1]), kv[0]))]
    slots = max(1, MAP_NODES_MAX - len(nodes))
    if len(groups) > slots:
        tail = UNPLANNED + "outros"
        kept = [g for g in groups if g[0] != tail][:slots - 1]
        rest = sorted(p for g in groups if g not in kept for p in g[2])
        groups = kept + [(tail, "outros", rest)]
    pieces += [{"id": gid, "label": label, "built": "unplanned", "files": fs} for gid, label, fs in groups]
    count = {b: sum(1 for p in pieces if p["built"] == b) for b in ("planned", "unplanned", "untouched")}
    return {
        "summary": f"{count['planned']} como planejado, {count['unplanned']} fora do plano, "
                   f"{count['untouched']} sem tocar.",
        "nodes": pieces,
        "edges": copy.deepcopy(plan.get("edges", [])),
    }


def list_changed(repo, base: str, tree: str) -> tuple:
    """(files, None) from `git diff` between base and tree, or (None, reason); never raises."""
    if not repo:
        return None, "sem --repo nem project_path"
    if not Path(repo).is_dir():
        return None, f"repo não é diretório: {repo}"
    try:
        r = subprocess.run(["git", "-C", str(repo), "diff", "--no-renames", "--name-only", "-z", base, tree],
                           capture_output=True, timeout=GIT_TIMEOUT)
    except subprocess.TimeoutExpired:
        return None, f"git diff passou de {GIT_TIMEOUT} s"
    except OSError as e:
        return None, f"git indisponível ({e.strerror or e})"
    if r.returncode != 0:
        err = r.stderr.decode("utf-8", errors="replace").strip().splitlines()
        return None, f"git diff saiu com {r.returncode}" + (f": {err[0]}" if err else "")
    return [p for p in r.stdout.decode("utf-8", errors="replace").split("\0") if p], None


def plan_map(report: dict):
    s = find_stage(report, GATE_OWNER["plan"])
    block = s.get("gate") if s else None
    m = block.get("map") if isinstance(block, dict) else None
    return m if isinstance(m, dict) else None


def built_map_for(report: dict, files):
    """The built map `brief pr` writes and `built-map` prints; None without a plan map or without the file list."""
    m = plan_map(report)
    return built_map(m, files) if m is not None and files is not None else None


def pr_map_refs(report: dict, refs: dict, files, reason):
    """(refs with the built map, warning). Over the same base and tree, a failed git keeps the previous map,
    and a round 2 or later block that is not revising keeps its map or its lack of one whatever git says,
    so resending the same file stays the no-op of that block."""
    s = find_stage(report, GATE_OWNER["pr"])
    prev = s.get("gate") if s else None
    same = isinstance(prev, dict) and all(prev.get(k) == refs[k] for k in ("base", "tree"))
    if same and prev.get("status") != "revising" and int(prev.get("round") or 1) > 1:
        if isinstance(prev.get("map"), dict):
            return dict(refs, map=prev["map"]), None
        return refs, reason if files is None and plan_map(report) is not None else None
    m = built_map_for(report, files)
    if m is not None:
        return dict(refs, map=m), None
    if files is not None or plan_map(report) is None:
        return refs, None
    if same and isinstance(prev.get("map"), dict):
        return dict(refs, map=prev["map"]), None
    return refs, reason


def check_line(field, v) -> int:
    if not isinstance(v, int) or isinstance(v, bool) or v < 1:
        raise InputError(f"{field}: precisa ser inteiro >= 1 (valor: {excerpt(v)})")
    return v


def validate_pr_question(f, q):
    check_text(f"{f}.why", q.get("why"), CAPS["why"])
    anchor = check_obj(f"{f}.anchor", q.get("anchor"))
    check_text(f"{f}.anchor.path", anchor.get("path"))
    start = check_line(f"{f}.anchor.start", anchor.get("start"))
    end = check_line(f"{f}.anchor.end", anchor.get("end"))
    if start > end:
        raise InputError(f"{f}.anchor: start {start} maior que end {end}")
    ids = sorted(o.get("id") for o in q["options"] if isinstance(o, dict))
    if ids != list(PR_OPTIONS):
        raise InputError(f"{f}.options: {', '.join(map(str, ids))}; no gate pr são exatamente ok e change")
    if q.get("assumed") != "ok":
        raise InputError(f"{f}.assumed: {excerpt(q.get('assumed'))}; no gate pr é sempre ok")


def validate_brief(payload, gate=None):
    """Static checks of a brief file; the message names field, index, value and cap for the critic's retry."""
    p = check_obj("--file", payload)
    for k in BRIEF_FORBIDDEN:
        if k in p:
            raise InputError(f"{k}: campo do script, não pode vir no arquivo")
    summary = check_text("summary", p.get("summary"), CAPS["summary"])
    if sentences(summary) > 2:
        raise InputError(f"summary: {sentences(summary)} frases, teto 2 (valor: {excerpt(summary)})")
    check_text("artifact", p.get("artifact"))

    seen = {}

    def unique_id(field, v):
        check_text(field, v)
        if v in seen:
            raise InputError(f"{field}: {excerpt(v)} repetido (já usado em {seen[v]}); ids são únicos no bloco")
        seen[v] = field

    for i, r in enumerate(check_list("risks", p.get("risks", []))):
        f = f"risks[{i}]"
        check_obj(f, r)
        unique_id(f"{f}.id", r.get("id"))
        check_text(f"{f}.text", r.get("text"), CAPS["risk"])
        if not isinstance(r.get("source"), str) or not RISK_SOURCE_RE.match(r["source"]):
            raise InputError(f"{f}.source: {excerpt(r.get('source'))} fora de challenger:<id>|critic|author")

    for i, q in enumerate(check_list("questions", p.get("questions", []))):
        f = f"questions[{i}]"
        check_obj(f, q)
        if "answer" in q:
            raise InputError(f"{f}.answer: campo do script, não pode vir no arquivo")
        unique_id(f"{f}.id", q.get("id"))
        check_text(f"{f}.text", q.get("text"), CAPS["question"])
        if "header" in q:
            check_text(f"{f}.header", q["header"], CAPS["header"])
        options =check_list(f"{f}.options", q.get("options"))
        if not 2 <= len(options) <= 3:
            raise InputError(f"{f}.options: {len(options)} opções, precisa de 2 a 3")
        option_ids = []
        for j, o in enumerate(options):
            of = f"{f}.options[{j}]"
            check_obj(of, o)
            oid = check_text(f"{of}.id", o.get("id"))
            if oid in option_ids:
                raise InputError(f"{of}.id: {excerpt(oid)} repetido na pergunta")
            option_ids.append(oid)
            check_text(f"{of}.label", o.get("label"), CAPS["label"])
            check_text(f"{of}.consequence", o.get("consequence"), CAPS["consequence"])
        check_option_ref(f"{f}.assumed", q.get("assumed"), option_ids)
        prefers = check_obj(f"{f}.prefers", q.get("prefers", {}))
        for who in ("author", "critic"):
            if who in prefers:
                check_option_ref(f"{f}.prefers.{who}", prefers[who], option_ids)
        if gate == "pr":
            validate_pr_question(f, q)

    changes = check_list("changes", p.get("changes", []))
    if len(changes) > 3:
        raise InputError(f"changes: {len(changes)} linhas, teto 3")
    for i, c in enumerate(changes):
        check_text(f"changes[{i}]", c, CAPS["change"])

    if "map" in p:
        if gate in ("spec", "tasks"):
            raise InputError("map: só vale no gate plan")
        if gate == "pr":
            raise InputError("map: campo do script no gate pr")
        validate_map(p["map"])


def validate_candidates(payload) -> list:
    for i, c in enumerate(check_list("--candidates", payload)):
        check_obj(f"candidates[{i}]", c)
        check_text(f"candidates[{i}].id", c.get("id"))
        check_text(f"candidates[{i}].text", c.get("text"))
    return payload


def round1_block(gate: str, payload: dict, candidates, refs=None) -> dict:
    risks = [{k: r[k] for k in ("id", "text", "source")} for r in payload.get("risks", [])]
    questions = []
    for q in payload.get("questions", []):
        questions.append({
            "id": q["id"],
            "text": q["text"],
            "options": [{k: o[k] for k in ("id", "label", "consequence")} for o in q["options"]],
            "assumed": q["assumed"],
            "prefers": {k: v for k, v in q.get("prefers", {}).items() if k in ("author", "critic")},
            "answer": None,
        })
        if "header" in q:
            questions[-1]["header"] = q["header"]
        if gate == "pr":
            questions[-1]["why"] = q["why"]
            questions[-1]["anchor"] = {k: q["anchor"][k] for k in ("path", "start", "end")}
    kept = questions[:BRIEF_KEEP]
    kept_ids = {q["id"] for q in kept}
    dropped = [{"id": c["id"], "text": c["text"]} for c in candidates or [] if c["id"] not in kept_ids]
    block = {
        "name": gate,
        "round": 1,
        "status": "open",
        "summary": payload["summary"],
        "risks": risks[:BRIEF_KEEP],
        "questions": kept,
        "history": [],
        "changes": list(payload.get("changes", [])),
        "cut": dropped[:CUT_MAX],
        "omitted": {
            "risks": max(0, len(risks) - BRIEF_KEEP),
            "questions": max(0, len(questions) - BRIEF_KEEP),
            "candidates": len(dropped),
        },
        "artifact": payload["artifact"],
    }
    if "map" in payload:
        block["map"] = payload["map"]
    if refs:
        block.update(refs)
    return block


def without_answers(block: dict) -> dict:
    b = copy.deepcopy(block)
    b.pop("status", None)
    b.pop("answer", None)
    b.pop("decided_at", None)
    for q in b.get("questions") or []:
        q["answer"] = None
        q.pop("answer_text", None)
    return b


def apply_brief(gate: str, payload: dict, candidates, prev=None, refs=None) -> dict:
    """The stage's block after a validated file, given the block already there (see the docstring's Rounds)."""
    block = round1_block(gate, payload, candidates, refs)
    if not isinstance(prev, dict):
        return block
    status, rnd = prev.get("status"), int(prev.get("round") or 1)
    if status == "revising":
        if rnd + 1 > ROUNDS_MAX:
            raise InputError(f"brief {gate}: rodadas esgotadas (rodada {rnd} em revising, teto {ROUNDS_MAX})")
        if not block["changes"]:
            raise InputError(f"changes: 0 linhas, a rodada {rnd + 1} exige de 1 a 3")
        entry = {"round": rnd, "questions": [q for q in prev.get("questions") or [] if q.get("answer") is not None]}
        if prev.get("answer") is not None:
            entry["answer"] = prev["answer"]
        history = list(prev.get("history") or []) + [entry]
        taken = {q["id"]: h["round"] for h in history for q in h["questions"]}
        for field in ("risks", "questions"):
            for i, item in enumerate(payload.get(field, [])):
                if item["id"] in taken:
                    raise InputError(f"{field}[{i}].id: {excerpt(item['id'])} repetido (já usado em history, "
                                     f"rodada {taken[item['id']]}); ids são únicos no bloco")
        block["round"] = rnd + 1
        block["history"] = history
        return block
    if rnd == 1:
        return block
    block["round"] = rnd
    block["history"] = prev.get("history") or []
    if without_answers(block) == without_answers(prev):
        return prev
    raise InputError(f"brief {gate}: bloco {status} na rodada {rnd} só aceita o mesmo arquivo; "
                     f"nova rodada só sobre revising")


def apply_answer(block: dict, question=None, option=None, text=None, approve=False, reject=False) -> dict:
    """The block after one answer; repeating a recorded value returns it unchanged, whatever the status."""
    b = copy.deepcopy(block)
    questions = b.get("questions") or []
    status = b.get("status")
    if reject:
        if status == "rejected":
            return b
        new_status = "rejected"
    elif approve:
        if status == "approved":
            return b
        pending = [q["id"] for q in questions if q.get("answer") is None]
        if pending:
            raise InputError(f"--approve: perguntas sem resposta: {', '.join(pending)}")
        new_status = "approved"
    elif question is None:
        if questions:
            raise InputError(f"--text-file sem --question só vale sem perguntas "
                             f"(perguntas: {', '.join(q['id'] for q in questions)})")
        if b.get("answer") == {"text": text}:
            return b
        b["answer"] = {"text": text}
        new_status = "revising"
    else:
        q = next((x for x in questions if x["id"] == question), None)
        if q is None:
            raise InputError(f"--question: {excerpt(question)} não é pergunta do bloco "
                             f"(perguntas: {', '.join(x['id'] for x in questions) or 'nenhuma'})")
        if option is not None:
            check_option_ref("--option", option, [o["id"] for o in q["options"]])
            if text is not None and not (b.get("name") == "pr" and option == "change"):
                raise InputError(f"--option {option} com --text-file: o texto do ajuste só vale no gate pr com change")
        value = option if option is not None else {"text": text}
        note = text if option is not None else None
        if q.get("answer") == value and q.get("answer_text") == note:
            return b
        q["answer"] = value
        q.pop("answer_text", None)
        if note is not None:
            q["answer_text"] = note
        if any(x.get("answer") is None for x in questions):
            new_status = status
        else:
            new_status = "approved" if all(x["answer"] == x["assumed"] for x in questions) else "revising"
    if status in CLOSED_GATE:
        raise InputError(f"answer {b.get('name')}: bloco já está {status}")
    if approve and status != "open":
        raise InputError(f"--approve: bloco {status}, só vale com open")
    b["status"] = new_status
    return b


def answer_text(q: dict) -> str:
    a = q["answer"]
    if isinstance(a, dict):
        return f"texto livre: {excerpt(a.get('text', ''))}"
    label = next((o["label"] for o in q["options"] if o["id"] == a), as_text(a))
    return f"{label}: {excerpt(q['answer_text'])}" if q.get("answer_text") else label


def render_option(o: dict, prefers: dict) -> dict:
    author, critic = prefers.get("author"), prefers.get("critic")
    label, description = o["label"], o["consequence"]
    if author is not None and author == critic:
        if author == o["id"] and not label.endswith(RECOMMENDED):
            label += RECOMMENDED
    else:
        who = next((name for name, pick in (("autor", author), ("crítico", critic)) if pick == o["id"]), None)
        if who:
            if not description.endswith((".", "!", "?")):
                description += "."
            description += f" Preferida pelo {who}."
    return {"id": o["id"], "label": label, "description": description}


NODE_STATE_TEXT = {"new": "nova", "changed": "muda", "existing": "já existe"}


def architecture_lines(m: dict) -> list:
    lines = [m["summary"]] if m.get("summary") else []
    lines += [f"- {n['label']} ({NODE_STATE_TEXT[n['state']]})" for n in m.get("nodes", [])]
    lines += [f"- {ap['label']}: {ap['text']}" + (" (escolhida)" if ap["chosen"] else "")
              for ap in m.get("approaches", [])]
    return lines


def render(block: dict) -> dict:
    """The AskUserQuestion payload of a block; the skill asks from this, never from the raw report."""
    lines = [f"**Gate {block['name']}** (rodada {block['round']})", "", block["summary"]]
    if block.get("name") == "plan" and isinstance(block.get("map"), dict):
        lines += ["", "Arquitetura:"] + architecture_lines(block["map"])
    if block.get("name") == "pr" and isinstance(block.get("map"), dict):
        m = block["map"]
        lines += ["", "Construído:", m["summary"]] + [
            f"- {n['label']} ({BUILT_TEXT[n['built']]})" for n in m["nodes"] if n["built"] in BUILT_TEXT]
    if block.get("risks"):
        lines += ["", "Riscos:"] + [f"- {r['text']} ({r['source']})" for r in block["risks"]]
    if block.get("changes"):
        lines += ["", "Mudanças desde a rodada anterior:"] + [f"- {c}" for c in block["changes"]]
    omitted = block.get("omitted") or {}
    cut = [f"{n} {what}" for what, n in (("riscos", omitted.get("risks")), ("perguntas", omitted.get("questions")),
                                          ("candidatas", omitted.get("candidates"))) if n]
    if cut:
        lines += ["", f"Fora do resumo: {', '.join(cut)}."]
    answered = [q for q in block.get("questions") or [] if q.get("answer") is not None]
    if answered or isinstance(block.get("answer"), dict):
        lines += ["", "Respostas:"] + [f"- {q['text']} → {answer_text(q)}" for q in answered]
        if isinstance(block.get("answer"), dict):
            lines.append(f"- Ajuste: {excerpt(block['answer'].get('text', ''))}")
    pending = [q for q in block.get("questions") or [] if q.get("answer") is None]
    if block.get("name") == "pr" and pending:
        lines += ["", "Pontos:"] + [
            f"- {q['id']} `{q['anchor']['path']}:{q['anchor']['start']}-{q['anchor']['end']}`: {q['why']}"
            for q in pending]
    questions = []
    for q in pending:
        options = [render_option(o, q.get("prefers") or {}) for o in q["options"]]
        options.sort(key=lambda o: not o["label"].endswith(RECOMMENDED))
        rendered = {"id": q["id"], "header": q.get("header") or q["id"][:12], "question": q["text"],
                    "options": options, "multiSelect": False}
        if block.get("name") == "pr":
            rendered["why"] = q["why"]
            rendered["anchor"] = q["anchor"]
        questions.append(rendered)
    return {"status": block["status"], "round": block["round"], "text_md": "\n".join(lines), "questions": questions}


def dumps_compact(obj) -> str:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


def cmd_brief(a, report, payload, candidates, refs) -> str:
    owner = GATE_OWNER[a.name]
    s = find_stage(report, owner)
    if s is None:
        raise InputError(f"brief {a.name}: etapa {owner} ausente no relatório; rode stage-start {owner} antes")
    s["gate"] = apply_brief(a.name, payload, candidates, s.get("gate"), refs)
    return dumps_compact(render(s["gate"]))


def pr_base(cmd: str, current: dict) -> str:
    exec_ = current.get("exec")
    base = exec_.get("base_checkpoint") if isinstance(exec_, dict) else None
    if not isinstance(base, str) or not SHA_RE.fullmatch(base):
        raise InputError(f"{cmd}: exec.base_checkpoint do current.json não é um sha de 40 hex (valor: {excerpt(base)})")
    return base


def pr_refs(a, inputs, current):
    if a.name != "pr":
        return None
    return {"base": pr_base("brief pr", current), "tree": inputs["tree"]}


def pr_repo(a, current: dict):
    return getattr(a, "repo", None) or current.get("project_path")


def cmd_built_map(a, inputs, wf: Path, cycle: dict, current: dict) -> str:
    base = pr_base("built-map", current)
    try:
        report = json.loads((wf / "report.json").read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, ValueError):
        report = None
    if not (isinstance(report, dict) and report.get("version") == 1 and cycle_compatible(report.get("cycle"), cycle)
            and isinstance(report.get("stages"), list)) or plan_map(report) is None:
        return dumps_compact({})
    files, reason = list_changed(pr_repo(a, current), base, inputs["tree"])
    if files is None:
        print(f"wf-report: mapa construído indisponível: {reason}", file=sys.stderr)
    return dumps_compact(built_map_for(report, files) or {})


def change_text(q: dict) -> str:
    a = q["answer"]
    if isinstance(a, dict):
        return a.get("text", "").strip()
    return (q.get("answer_text") or "").strip()


def pr_change_tasks(block: dict) -> list:
    """The P<round>.<n> tasks of a revising pr block, one per answer other than ok, in question order."""
    rnd = int(block.get("round") or 1)
    answered = [q for q in block.get("questions") or [] if q.get("answer") not in (None, "ok")]
    missing = [q["id"] for q in answered if not change_text(q)]
    if missing:
        raise InputError(f"reopen pr: resposta change sem texto do ajuste em {', '.join(missing)}; grave com "
                         f"answer pr --question <id> --option change --text-file <md>")
    tasks = []
    for q in answered:
        anchor = q["anchor"]
        where = f"`{anchor['path']}:{anchor['start']}-{anchor['end']}`"
        tasks.append({
            "id": f"P{rnd}.{len(tasks) + 1}",
            "title": f"Ajuste do gate pr: {q['text']}",
            "description": (
                f"**Contexto:** Ponto `{q['id']}` do gate pr, rodada {rnd}, em {where}. {q['text']}\n"
                f"Por quê: {q['why']}\n\n"
                f"**O que fazer:**\n{change_text(q)}\n\n"
                f"**Testes:**\n- os testes que cobrem `{anchor['path']}` continuam passando\n\n"
                f"**Concluído quando:**\n- o pedido do usuário está aplicado em `{anchor['path']}`"
            ),
            "complexity": "M",
            "risk": "high",
            "tier0": "opus",
            "tier": "opus",
            "attempts": 0,
            "affects": [anchor["path"]],
            "tests": [],
            "depends_on": [],
            "status": "pending",
        })
    return tasks


def append_tasks_md(path: Path, tasks: list):
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    lines = [f"- [ ] `{t['complexity']}` `{t['tier0']}` #{t['id']} — {t['title']}" for t in tasks
             if not re.search(rf"#{re.escape(t['id'])}\b(?![.\d])", text)]
    if not lines:
        return
    if text and not text.endswith("\n"):
        text += "\n"
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text + "\n".join(lines) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def cmd_reopen(wf: Path, cycle: dict) -> str:
    with open(wf / ".report.json.lock", "w") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            try:
                report = json.loads((wf / "report.json").read_text(encoding="utf-8"))
            except (OSError, UnicodeDecodeError, ValueError):
                report = None
            if not (isinstance(report, dict) and report.get("version") == 1
                    and cycle_compatible(report.get("cycle"), cycle)):
                raise InputError("reopen: bloco ausente (report.json inexistente, de outra versão ou de outro ciclo)")
            stages = report.get("stages") if isinstance(report.get("stages"), list) else []
            s = next((x for x in stages if isinstance(x, dict) and x.get("stage") == GATE_OWNER["pr"]), None)
            block = s.get("gate") if s else None
            if not isinstance(block, dict):
                raise InputError("reopen pr: bloco ausente na etapa complete; rode brief pr antes")
            if block.get("status") != "revising":
                raise InputError(f"reopen pr: bloco {block.get('status')}, só vale com revising")
            tasks = pr_change_tasks(block)
            if not tasks:
                raise InputError("reopen pr: nenhuma pergunta com resposta diferente de ok; "
                                 "o ajuste sem pergunta não tem âncora para virar task")
            added = []

            def modify(current):
                t = current.get("tasks") if isinstance(current.get("tasks"), dict) else {}
                items = t.get("items") if isinstance(t.get("items"), list) else []
                have = {x.get("id") for x in items if isinstance(x, dict)}
                for task in tasks:
                    if task["id"] not in have:
                        items.append(task)
                        added.append(task["id"])
                t["items"] = items
                t["total"] = len(items)
                current["tasks"] = t
                return current

            update_json(wf / "current.json", wf / ".current.json.lock", modify)
            append_tasks_md(wf / "tasks.md", tasks)
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    return dumps_compact({"tasks": [t["id"] for t in tasks], "added": added})


def cmd_answer(a, report, text):
    s = find_stage(report, GATE_OWNER[a.name])
    block = s.get("gate") if s else None
    if not isinstance(block, dict):
        raise InputError(f"answer {a.name}: bloco ausente na etapa {GATE_OWNER[a.name]}; rode brief {a.name} antes")
    after = apply_answer(block, question=a.question, option=a.option, text=text,
                         approve=a.approve, reject=a.reject)
    if after["status"] != block.get("status") and after["status"] in CLOSED_GATE:
        after.setdefault("decided_at", now())
    s["gate"] = after


def cmd_show(a, wf: Path, cycle: dict) -> str:
    try:
        report = json.loads((wf / "report.json").read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, ValueError):
        report = None
    if not (isinstance(report, dict) and report.get("version") == 1 and cycle_compatible(report.get("cycle"), cycle)):
        raise InputError("show: bloco ausente (report.json inexistente, de outra versão ou de outro ciclo)")
    stages = report.get("stages") if isinstance(report.get("stages"), list) else []
    s = next((x for x in stages if isinstance(x, dict) and x.get("stage") == GATE_OWNER[a.name]), None)
    block = s.get("gate") if s else None
    return dumps_compact(render(block) if isinstance(block, dict) else {"status": "absent"})


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
    sp.add_argument("--workflow-dir", required=True)
    sp = sub.add_parser("brief")
    sp.add_argument("name", choices=GATES)
    sp.add_argument("--workflow-dir", required=True)
    sp.add_argument("--file", required=True)
    sp.add_argument("--candidates")
    sp.add_argument("--tree")
    sp.add_argument("--drop-map", action="store_true")
    sp.add_argument("--repo")
    sp = sub.add_parser("built-map")
    sp.add_argument("--workflow-dir", required=True)
    sp.add_argument("--tree", required=True)
    sp.add_argument("--repo")
    answer = sub.add_parser("answer")
    answer.add_argument("name", choices=GATES)
    answer.add_argument("--workflow-dir", required=True)
    answer.add_argument("--question")
    answer.add_argument("--text-file")
    grp = answer.add_mutually_exclusive_group()
    grp.add_argument("--option")
    grp.add_argument("--approve", action="store_true")
    grp.add_argument("--reject", action="store_true")
    sp = sub.add_parser("show")
    sp.add_argument("name", choices=GATES)
    sp.add_argument("--workflow-dir", required=True)
    sp = sub.add_parser("reopen")
    sp.add_argument("name", choices=["pr"])
    sp.add_argument("--workflow-dir", required=True)
    a = p.parse_args()
    if a.cmd == "answer":
        if a.option is None and a.text_file is None and not (a.approve or a.reject):
            answer.error("um de --option, --text-file, --approve ou --reject é obrigatório")
        if a.text_file is not None and (a.approve or a.reject):
            answer.error("--text-file não vai com --approve/--reject")
        if a.option is not None and a.question is None:
            answer.error("--option exige --question")
        if a.question is not None and (a.approve or a.reject):
            answer.error("--question vai com --option ou --text-file, não com --approve/--reject")
    return a


def read_tree(gate: str, ref):
    if gate != "pr":
        if ref is not None:
            raise InputError("--tree: só vale no gate pr")
        return None
    if not ref or not ref.startswith("@"):
        raise InputError(f"--tree: obrigatório no gate pr como @ARQUIVO gravado por wf-checkpoint.sh create "
                         f"(valor: {excerpt(ref)})")
    try:
        sha = "".join(Path(ref[1:]).read_text(encoding="utf-8").split())
    except (OSError, UnicodeDecodeError) as e:
        raise InputError(f"--tree: arquivo ilegível: {ref[1:]} ({e})")
    if not SHA_RE.fullmatch(sha):
        raise InputError(f"--tree: {ref[1:]} não contém um sha de 40 hex (valor: {excerpt(sha)})")
    return sha


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
    if a.cmd == "brief":
        payload = read_json(a.file)
        if getattr(a, "drop_map", False):
            if a.name != "plan":
                raise InputError("--drop-map: só vale no gate plan")
            if isinstance(payload, dict):
                payload.pop("map", None)
        if getattr(a, "repo", None) is not None and a.name != "pr":
            raise InputError("--repo: só vale no gate pr")
        validate_brief(payload, a.name)
        candidates = validate_candidates(read_json(a.candidates)) if a.candidates else None
        return {"payload": payload, "candidates": candidates, "tree": read_tree(a.name, getattr(a, "tree", None))}
    if a.cmd == "built-map":
        return {"tree": read_tree("pr", a.tree)}
    if a.cmd == "answer" and getattr(a, "text_file", None):
        return {"text": check_text("--text-file", read_text(a.text_file))}
    return {}


def main():
    a = parse_args()
    if a.cmd == "gate":
        print(cmd_gate(a))
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
    if a.cmd in ("show", "reopen", "built-map"):
        try:
            if a.cmd == "show":
                print(cmd_show(a, wf, cycle))
            elif a.cmd == "reopen":
                print(cmd_reopen(wf, cycle))
            else:
                print(cmd_built_map(a, inputs, wf, cycle, current))
        except InputError as e:
            print(f"wf-report: {e}", file=sys.stderr)
            sys.exit(2)
        return
    if a.cmd == "brief":
        try:
            inputs["refs"] = pr_refs(a, inputs, current)
        except InputError as e:
            print(f"wf-report: {e}", file=sys.stderr)
            sys.exit(2)
        if a.name == "pr":
            inputs["changed"] = list_changed(pr_repo(a, current), inputs["refs"]["base"], inputs["refs"]["tree"])
    out = []
    warn = []

    def modify(report):
        if isinstance(report, dict) and report.get("version") == 1 and cycle_compatible(report.get("cycle"), cycle):
            report["cycle"] = dict(cycle)
        elif a.cmd in NEVER_ARCHIVE:
            raise InputError(f"{a.cmd}: bloco ausente (report.json inexistente, de outra versão ou de outro ciclo)")
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
        elif a.cmd == "brief":
            refs = inputs["refs"]
            if a.name == "pr":
                refs, reason = pr_map_refs(report, refs, *inputs["changed"])
                warn[:] = [reason] if reason else []
            out.append(cmd_brief(a, report, inputs["payload"], inputs["candidates"], refs))
        elif a.cmd == "answer":
            cmd_answer(a, report, inputs.get("text"))
        return report

    default = {} if a.cmd in NEVER_ARCHIVE else empty_report(cycle)
    try:
        update_json(wf / "report.json", wf / ".report.json.lock", modify, default=default)
    except InputError as e:
        print(f"wf-report: {e}", file=sys.stderr)
        sys.exit(2)
    for reason in warn:
        print(f"wf-report: mapa construído indisponível: {reason}", file=sys.stderr)
    for line in out:
        print(line)


if __name__ == "__main__":
    main()
