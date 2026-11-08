#!/usr/bin/env python3
"""
Deterministic gates around verify and complete. No LLM judgment.

  wf_gate.py complete-check     --workflow-dir W [--repo R]
  wf_gate.py accept-unverified  --workflow-dir W --reason TEXT --risk TEXT [--risk ...] [--scope TEXT] [--repo R]
  wf_gate.py tasks-check        --workflow-dir W [--repo R]

complete-check exits 0 only when the last verify is `verified` for the tree on disk, or a human accepted this exact
tree as unverified. accept-unverified asks for that acceptance in a macOS dialog, which an agent cannot click.
tasks-check rejects task plans G0 cannot approve by construction (Red-only tasks, tests nobody creates).
"""
import argparse
import fnmatch
import getpass
import json
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from current_json import read_current_json, update_current_json  # noqa: E402

BLOCKING = {"critical", "major"}
CONFIRMED_VIA = "macos_dialog"
ACCEPT_BUTTON = "Aceitar sem verificação"


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def snapshot(repo):
    p = subprocess.run(["bash", str(HERE / "wf-checkpoint.sh"), "create", str(repo)], capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 and p.stdout.strip() else None


def resolve_ref(value):
    if isinstance(value, str) and value.startswith("@"):
        try:
            return Path(value[1:]).read_text().strip() or None
        except OSError:
            return None
    return value or None


def bind_revision(result: dict) -> dict:
    """Pins a verify result to the tree it judged. A tree that moved during verify cannot keep `verified`."""
    d = result.get("decision")
    if not isinstance(d, dict):
        return result
    start = resolve_ref(d.get("revision_start"))
    end = snapshot(d["repo"]) if d.get("repo") else None
    d["revision_start"] = start
    d["revision_id"] = end
    if result.get("status") == "verified":
        reason = "REVISION_UNBOUND" if not start or not end else "REVISION_CHANGED" if start != end else None
        if reason:
            result["status"] = d["status"] = "unverified"
            result["reason"] = d["reason_code"] = reason
            d["reasons"] = [reason, *(d.get("reasons") or [])]
    return result


def recheck(result: dict) -> list:
    """Re-derives `verified` from the raw gate report, so a relayed status alone is never trusted."""
    problems = []
    d = result.get("decision") if isinstance(result.get("decision"), dict) else {}
    rep = result.get("report") if isinstance(result.get("report"), dict) else {}
    if result.get("status") != "verified" or d.get("status") != "verified" or d.get("reason_code") != "VERIFIED":
        problems.append("status_not_verified")
    g1 = rep.get("g1")
    if not isinstance(g1, list) or not g1:
        problems.append("g1_missing")
    else:
        for g in g1:
            if not isinstance(g, dict) or g.get("verdict") != "pass":
                problems.append("g1_not_pass")
            elif any(isinstance(f, dict) and f.get("severity") in BLOCKING for f in g.get("findings") or []):
                problems.append("g1_blocking_findings")
    g2 = rep.get("g2")
    if not isinstance(g2, dict) or g2.get("verdict") != "pass":
        problems.append("g2_not_pass")
    else:
        crit = g2.get("criteria")
        if not isinstance(crit, list) or not crit:
            problems.append("no_criteria")
        elif any(not isinstance(c, dict) or c.get("status") != "PASS" or not str(c.get("evidence") or "").strip() for c in crit):
            problems.append("criteria_not_all_pass")
        if any(isinstance(f, dict) and f.get("severity") in BLOCKING for f in g2.get("findings") or []):
            problems.append("g2_blocking_findings")
    return sorted(set(problems))


def load_verify(wf: Path):
    cur = read_current_json(str(wf))
    v = (cur.get("exec") or {}).get("verify")
    if not isinstance(v, dict) or not v.get("run"):
        return cur, None, None, "NO_VERIFY"
    try:
        result = json.loads((wf / "runs" / v["run"] / "result.json").read_text())
    except (OSError, ValueError):
        return cur, v, None, "VERIFY_RESULT_UNREADABLE"
    return cur, v, result, None


def valid_override(o, revision):
    if not isinstance(o, dict):
        return "OVERRIDE_MISSING"
    if o.get("confirmed_via") != CONFIRMED_VIA or not o.get("actor") or not o.get("at"):
        return "OVERRIDE_NOT_HUMAN"
    if not str(o.get("reason") or "").strip() or not o.get("risks"):
        return "OVERRIDE_INCOMPLETE"
    if not revision or o.get("revision_id") != revision:
        return "OVERRIDE_STALE_REVISION"
    return None


def complete_check(wf: Path, repo=None) -> dict:
    cur, v, result, err = load_verify(wf)
    d = (result or {}).get("decision") or {}
    repo = repo or d.get("repo") or (v or {}).get("repo")
    revision = snapshot(repo) if repo else None
    crit = d.get("criteria") or {}
    out = {
        "allowed": False,
        "verdict": (result or {}).get("status"),
        "reason_code": err,
        "verify_run": (v or {}).get("run"),
        "evidence_refs": d.get("evidence_refs") or [],
        "criteria_passed": crit.get("passed", 0),
        "criteria_failed": crit.get("failed", 0),
        "criteria_partial": crit.get("partial", 0),
        "criteria_untestable": crit.get("untestable", 0),
        "gates_run": d.get("gates_run") or [],
        "human_override": False,
        "revision_id": revision,
        "verified_revision": d.get("revision_id"),
    }
    if not err:
        problems = recheck(result)
        if not problems and d.get("revision_id") and d.get("revision_id") == revision:
            out.update(allowed=True, reason_code="VERIFIED")
            return out
        out["reason_code"] = ("REVISION_CHANGED" if not problems else
                              "VERIFY_INCONSISTENT" if result.get("status") == "verified" else
                              d.get("reason_code") or "VERIFY_NOT_VERIFIED")
        if problems:
            out["problems"] = problems
    o = (cur.get("exec") or {}).get("override")
    o_err = valid_override(o, revision)
    if o_err is None:
        out.update(allowed=True, human_override=True, override=o)
    elif o is not None:
        out["override_error"] = o_err
    return out


def confirm(text: str) -> bool:
    if sys.platform != "darwin" or not shutil.which("osascript"):
        return False
    script = ('on run argv\n'
              f'display dialog (item 1 of argv) with title "Fluxo Smart" buttons {{"Cancelar", "{ACCEPT_BUTTON}"}} '
              'default button "Cancelar" cancel button "Cancelar" with icon caution giving up after 300\n'
              'end run')
    p = subprocess.run(["osascript", "-e", script, text], capture_output=True, text=True)
    return p.returncode == 0 and f"button returned:{ACCEPT_BUTTON}" in p.stdout and "gave up:true" not in p.stdout


def accept_unverified(wf: Path, reason: str, risks: list, scope: str, repo=None) -> dict:
    reason = (reason or "").strip()
    risks = [r.strip() for r in risks or [] if r and r.strip()]
    if not reason or not risks:
        return {"accepted": False, "error": "reason e ao menos um risk são obrigatórios"}
    cur, v, result, err = load_verify(wf)
    d = (result or {}).get("decision") or {}
    repo = repo or d.get("repo") or (v or {}).get("repo")
    revision = snapshot(repo) if repo else None
    if not revision:
        return {"accepted": False, "error": "sem repo/revisão para vincular a exceção (rode /verify ou passe --repo)"}
    text = (f"Encerrar o ciclo \"{cur.get('feature', '?')}\" SEM verificação válida?\n\n"
            f"Verify: {(result or {}).get('status') or 'ausente'} ({d.get('reason_code') or err})\n"
            f"Revisão: {revision[:12]}\nMotivo: {reason}\nRiscos aceitos: {'; '.join(risks)}")
    if not confirm(text):
        return {"accepted": False, "error": "exceção não confirmada por humano (diálogo cancelado, expirado ou indisponível)"}
    record = {
        "actor": getpass.getuser(),
        "at": now(),
        "reason": reason,
        "risks": risks,
        "scope": scope or "complete",
        "revision_id": revision,
        "verify_run": (v or {}).get("run"),
        "verify_status": (result or {}).get("status"),
        "verify_reason_code": d.get("reason_code") or err,
        "confirmed_via": CONFIRMED_VIA,
    }

    def modify(data):
        data.setdefault("exec", {})["override"] = record
        return data

    update_current_json(str(wf), modify)
    with open(wf / "overrides.jsonl", "a") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")
    return {"accepted": True, "override": record}


TEST_PATH = re.compile(r"(^|/)(test|tests|integration_test|__tests__|testing)/|_test\.(dart|go|py)$|\.(test|spec)\.[cm]?[jt]sx?$|(^|/)test_[^/]+\.py$")
RED_TEXT = re.compile(r"\bred\b|(testes?|tests?|suíte|suite)\s+(falham|falhando|falha|vermelh\w*|fails?|failing)\b|\b(failing|vermelh\w*)\s+(testes?|tests?)", re.I)
GREEN_TEXT = re.compile(r"\bpass(a|am|ando|ing|es)?\b|\bverdes?\b|\bgreen\b", re.I)
BLOCKS = ["**Contexto:**", "**O que fazer:**", "**Testes:**", "**Concluído quando:**"]
REQUIRED = {"complexity": {"S", "M", "L"}, "risk": {"low", "high"}, "tier0": {"haiku", "sonnet", "opus", "fable"}}


def is_test(path: str) -> bool:
    return bool(TEST_PATH.search(path))


def done_block(desc: str) -> str:
    i = desc.find(BLOCKS[3])
    return desc[i + len(BLOCKS[3]):] if i >= 0 else ""


def covers(globs, path):
    return any(g == path or fnmatch.fnmatch(path, g) for g in globs)


def tasks_check(items: list, repo=None) -> list:
    errors = []
    err = lambda tid, code, msg: errors.append({"task": tid, "code": code, "message": msg})
    seen = {}
    for i, t in enumerate(items):
        tid = t.get("id") or f"#{i + 1}"
        if tid in seen:
            err(tid, "DUPLICATE_ID", "id repetido")
        seen[tid] = i
        for k in ("title", "description"):
            if not str(t.get(k) or "").strip():
                err(tid, "MISSING_FIELD", f"campo `{k}` vazio")
        for k, allowed in REQUIRED.items():
            if t.get(k) not in allowed:
                err(tid, "MISSING_FIELD", f"`{k}` deve ser um de {sorted(allowed)}")
        if not isinstance(t.get("affects"), list) or not t["affects"]:
            err(tid, "MISSING_FIELD", "`affects` precisa listar os paths/globs que a task toca")
        if not isinstance(t.get("tests"), list):
            err(tid, "MISSING_FIELD", "`tests` precisa ser lista (vazia quando não há teste aplicável)")
        desc = str(t.get("description") or "")
        pos = [desc.find(b) for b in BLOCKS]
        if any(p < 0 for p in pos) or pos != sorted(pos):
            err(tid, "DESCRIPTION_BLOCKS", "description precisa dos 4 blocos na ordem: " + ", ".join(BLOCKS))
        for dep in t.get("depends_on") or []:
            if dep not in seen or seen[dep] >= i:
                err(tid, "BAD_DEPENDENCY", f"depends_on `{dep}` não é uma task anterior")

        title = str(t.get("title") or "")
        red_title = re.search(r"\bred\b", title, re.I) and not re.search(r"\bgreen\b", title, re.I)
        done = done_block(desc)
        if red_title or (RED_TEXT.search(done) and not GREEN_TEXT.search(done)):
            err(tid, "RED_ONLY", "a task termina com testes falhando, e o G0 só aprova testes passando. "
                "Junte Red e Green na mesma task: escreva o teste, implemente, e conclua com o teste verde.")

    for i, t in enumerate(items):
        affects, tests = t.get("affects") or [], t.get("tests") or []
        if not affects or not all(is_test(a) for a in affects) or not tests:
            continue
        for later in items[i + 1:]:
            shared = set(tests) & set(later.get("tests") or [])
            if shared and any(not is_test(a) for a in later.get("affects") or []):
                err(t.get("id"), "RED_ONLY", f"só cria {', '.join(sorted(shared))}, que {later.get('id')} faz passar: "
                    f"o teste fica vermelho no G0 desta task. Junte com {later.get('id')} (Red→Green na mesma task).")
                break

    if repo:
        root = Path(repo)
        for i, t in enumerate(items):
            produced = [g for x in items[: i + 1] for g in x.get("affects") or []]
            for test in t.get("tests") or []:
                if not (root / test).exists() and not covers(produced, test):
                    err(t.get("id"), "TEST_NOT_PRODUCED", f"`{test}` não existe e nenhuma task até aqui o cria (affects); G0 vai falhar com G0-TEST-MISSING")
    seen_err = set()
    return [e for e in errors if (e["task"], e["code"]) not in seen_err and not seen_err.add((e["task"], e["code"]))]


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("complete-check", "accept-unverified", "tasks-check"):
        p = sub.add_parser(name)
        p.add_argument("--workflow-dir", required=True)
        p.add_argument("--repo")
        if name == "accept-unverified":
            p.add_argument("--reason", required=True)
            p.add_argument("--risk", action="append", default=[])
            p.add_argument("--scope", default="complete")
    a = ap.parse_args()
    wf = Path(a.workflow_dir)

    if a.cmd == "complete-check":
        out = complete_check(wf, a.repo)
        ok = out["allowed"]
    elif a.cmd == "accept-unverified":
        out = accept_unverified(wf, a.reason, a.risk, a.scope, a.repo)
        ok = out["accepted"]
    else:
        items = ((read_current_json(str(wf)).get("tasks") or {}).get("items")) or []
        errors = tasks_check(items, a.repo) if items else [{"task": None, "code": "NO_TASKS", "message": "current.json sem tasks.items"}]
        out = {"ok": not errors, "tasks": len(items), "errors": errors}
        ok = out["ok"]
    print(json.dumps(out, ensure_ascii=False, indent=2))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
