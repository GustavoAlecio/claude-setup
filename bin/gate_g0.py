#!/usr/bin/env python3
"""
G0 — deterministic gate (format, codegen, analyze, task tests). No LLM judgment.

  gate_g0.py --repo R --stack flutter --checkpoint TREE [--tests a,b] [--run-dir D --task T --attempt N --tier X]

Prints a verdict JSON (same shape the LLM gates return) plus `snapshot`: the tree after autofix,
which becomes the next task's checkpoint when this attempt passes.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

BIN = Path.home() / ".claude" / "bin"
STACKS = Path.home() / ".claude" / "stacks"
BLOCKING = {"critical", "major"}
TAIL = 4000


def sh(cmd, cwd, timeout=900, env=None):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", f"timeout after {timeout}s: {' '.join(cmd)}"
    except FileNotFoundError as e:
        return 127, "", str(e)


def checkpoint(*args):
    return subprocess.run([str(BIN / "wf-checkpoint.sh"), *args], capture_output=True, text=True, check=True).stdout


def pkg_root(path: Path, repo: Path, markers):
    d = path.parent
    while True:
        if any((d / m).exists() for m in markers):
            return d
        if d == repo or d == d.parent:
            return repo
        d = d.parent


def pkgs(files):
    # Go tooling works per package, not per file: `a/b/x_test.go` -> `./a/b`.
    dirs = sorted({str(Path(f).parent) for f in files})
    return ["./" + d if d != "." else "." for d in dirs]


def expand(cmd, files, prefix):
    out = []
    for c in cmd:
        if c == "{files}":
            out.extend(files)
        elif c == "{pkgs}":
            out.extend(pkgs(files))
        else:
            out.append(c)
    return prefix + out if prefix and out[0] in ("dart", "flutter") else out


def stack_env(stack):
    env = dict(os.environ)
    f = STACKS / f"{stack}.env"
    if f.exists():
        for line in f.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env.setdefault(k.strip(), v.strip())
    return env


def group(paths, repo, markers):
    g = {}
    for p in paths:
        root = pkg_root(repo / p, repo, markers)
        g.setdefault(root, []).append(str((repo / p).relative_to(root)))
    return g


def parse_dart_machine(stdout, root, repo, sev_map):
    found = []
    for line in stdout.splitlines():
        parts = line.split("|")
        if len(parts) < 8:
            continue
        sev, _type, code, file, ln = parts[0], parts[1], parts[2], parts[3], parts[4]
        msg = "|".join(parts[7:])
        try:
            rel = str(Path(file).resolve().relative_to(repo))
        except ValueError:
            rel = file
        found.append({
            "id": f"G0-ANALYZE-{code}",
            "severity": sev_map.get(sev, "minor"),
            "file": rel,
            "line": int(ln) if ln.isdigit() else 0,
            "rule_ref": code.lower(),
            "message": msg.strip(),
        })
    return found


def parse_golangci_json(stdout, root, repo, sev_map):
    found = []
    line = next((l for l in stdout.splitlines() if l.startswith("{")), "")
    try:
        issues = json.loads(line).get("Issues") or []
    except ValueError:
        return found
    for i in issues:
        pos = i.get("Pos") or {}
        try:
            rel = str((root / pos.get("Filename", "")).resolve().relative_to(repo))
        except ValueError:
            rel = pos.get("Filename", "")
        found.append({
            "id": f"G0-ANALYZE-{i.get('FromLinter', 'lint')}",
            "severity": sev_map.get(i.get("Severity", ""), sev_map.get("default", "major")),
            "file": rel,
            "line": int(pos.get("Line") or 0),
            "rule_ref": i.get("FromLinter", "lint"),
            "message": i.get("Text", "").strip(),
        })
    return found


PARSERS = {"dart_machine": parse_dart_machine, "golangci_json": parse_golangci_json}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--stack", required=True)
    ap.add_argument("--checkpoint", required=True)
    ap.add_argument("--tests", default="")
    ap.add_argument("--run-dir")
    ap.add_argument("--task")
    ap.add_argument("--attempt")
    ap.add_argument("--tier")
    a = ap.parse_args()

    repo = Path(a.repo).resolve()
    prof = json.loads((STACKS / f"{a.stack}.json").read_text())
    markers = prof["detect"]
    sp = prof.get("sdk_prefix") or []
    prefix = sp if sp and shutil.which(sp[0]) and any((repo / m).exists() for m in prof.get("sdk_prefix_when", [])) else []
    env = stack_env(a.stack)

    findings, evidence = [], []
    changed = [p for p in checkpoint("changed", str(repo), a.checkpoint).splitlines() if p]
    src = [p for p in changed
           if any(p.endswith(e) for e in prof["source_ext"])
           and not any(p.endswith(s) for s in prof["generated_suffixes"])
           and (repo / p).exists()]
    evidence.append(f"changed: {len(changed)} path(s), {len(src)} source file(s)")

    if src:
        for cmd in prof.get("autofix", []):
            for root, files in group(src, repo, markers).items():
                sh(expand(cmd, files, prefix), root)

        cg = prof.get("codegen")
        if cg:
            rx = re.compile(cg["when_regex"], re.M)
            needs = [p for p in src if rx.search((repo / p).read_text(errors="ignore"))]
            for root in group(needs, repo, markers):
                rc, out, err = sh(expand(cg["cmd"], [], prefix), root)
                if rc != 0:
                    findings.append({"id": "G0-CODEGEN", "severity": "critical", "file": str(root.relative_to(repo)) or ".",
                                     "line": 0, "rule_ref": "codegen", "message": (out + err)[-TAIL:]})
                else:
                    evidence.append(f"codegen ok in {root.relative_to(repo) or '.'}")

        an = prof["analyze"]
        for root, files in group(src, repo, markers).items():
            rc, out, err = sh(expand(an["cmd"], files, prefix), root)
            parsed = PARSERS[an.get("parser", "dart_machine")](out + "\n" + err, root, repo, an["severity_map"])
            if an.get("only_changed"):
                # Package-level linters report on untouched files too; pre-existing debt is not this task's.
                parsed = [f for f in parsed if f["file"] in src]
            if rc != 0 and not parsed:
                findings.append({"id": "G0-ANALYZE-FAILED", "severity": "critical", "file": str(root.relative_to(repo)) or ".",
                                 "line": 0, "rule_ref": "analyze", "message": (out + err)[-TAIL:]})
            findings.extend(parsed)
        evidence.append("analyze ran on changed files")

    tests = [t.strip() for t in a.tests.split(",") if t.strip()]
    missing = [t for t in tests if not (repo / t).exists()]
    for t in missing:
        findings.append({"id": "G0-TEST-MISSING", "severity": "major", "file": t, "line": 0,
                         "rule_ref": "missing_test", "message": "test mapped in plan/tasks does not exist"})
    present = [t for t in tests if t not in missing]
    if not tests:
        evidence.append("no task tests mapped")
    tc = prof["test"]
    tagged = tc.get("tagged")
    runs = []
    if tagged:
        rx = re.compile(tagged["regex"], re.M)
        is_tagged = lambda t: bool(rx.search((repo / t).read_text(errors="ignore")))
        plain = [t for t in present if not is_tagged(t)]
        tag_files = [t for t in present if is_tagged(t)]
        runs.append((plain, tc["cmd"]))
        if tag_files:
            lack = [k for k in tagged.get("env_required", []) if not env.get(k)]
            if lack:
                for t in tag_files:
                    findings.append({"id": "G0-TEST-ENV", "severity": "major", "file": t, "line": 0, "rule_ref": "test_env",
                                     "message": f"tagged test needs {', '.join(lack)} (env or ~/.claude/stacks/{a.stack}.env)"})
            else:
                i = tc["cmd"].index("{pkgs}") if "{pkgs}" in tc["cmd"] else len(tc["cmd"])
                runs.append((tag_files, tc["cmd"][:i] + tagged["args"] + tc["cmd"][i:]))
    else:
        runs.append((present, tc["cmd"]))
    for run_files, run_cmd in runs:
        for root, files in group(run_files, repo, markers).items():
            rc, out, err = sh(expand(run_cmd, files, prefix), root, env=env)
            tries = 0
            while rc != 0 and tries < tc.get("flaky_retries", 0):
                tries += 1
                rc, out, err = sh(expand(run_cmd, files, prefix), root, env=env)
                if rc == 0:
                    evidence.append(f"FLAKY: tests in {root.relative_to(repo) or '.'} passed on retry {tries}")
            if rc != 0:
                for f in files:
                    findings.append({"id": "G0-TEST-FAIL", "severity": "major", "file": str((root / f).relative_to(repo)),
                                     "line": 0, "rule_ref": "test_failure", "message": (out + err)[-TAIL:]})
            else:
                evidence.append(f"tests pass: {', '.join(files)}")

    verdict = "fail" if any(f["severity"] in BLOCKING for f in findings) else "pass"
    snapshot = checkpoint("create", str(repo)).strip()
    if a.run_dir and a.task:
        ref = Path(a.run_dir) / "checkpoints" / f"{a.task}.tree"
        ref.parent.mkdir(parents=True, exist_ok=True)
        ref.write_text(snapshot + "\n")
    result = {"gate": "G0", "verdict": verdict, "findings": findings, "evidence": evidence,
              "snapshot": snapshot, "changed_files": changed}

    if a.run_dir:
        blocking = sum(1 for f in findings if f["severity"] in BLOCKING)
        cmd = [str(BIN / "wf-event.py"), "log", "--run-dir", a.run_dir, "--role", "g0", "--verdict", verdict, "--count", str(blocking)]
        for k in ("task", "attempt", "tier"):
            if getattr(a, k):
                cmd += [f"--{k}", getattr(a, k)]
        subprocess.run(cmd, check=False)

    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
