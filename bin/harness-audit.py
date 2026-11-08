#!/usr/bin/env python3
"""
Harness audit — checks that a repo is ready for the Smart Flow gates before any model runs.

  harness-audit.py --repo R --stack flutter [--phase kickoff|verify] [--fix] [--quick] [--text]

Checks the stack profile against the repo (rules/ADR dirs, G2 device), submodules, and, for
flutter, the pinned SDK, resolved deps and generated code; unless --quick, it runs the G0
analyze/test commands on one file to prove they work. --fix repairs what is local and safe
(SDK link, pub get + build_runner, clean submodules) and re-audits.

Prints a verdict JSON (gate shape); verdict is fail when a critical finding remains. Exit 1 on fail.
"""
import argparse
import json
import re
import shutil
import subprocess
from pathlib import Path

STACKS = Path.home() / ".claude" / "stacks"
FVM_VERSIONS = Path.home() / "fvm" / "versions"
TAIL = 2000
PLATFORM_DIRS = {"ios": "ios", "darwin": "macos", "android": "android", "web": "web", "linux": "linux", "windows": "windows"}
QA_TOOLS = {"qa/ios.sh": ["idevice_id", "idevicesyslog", "iproxy", "xcrun"], "qa/android.sh": ["adb"]}


def sh(cmd, cwd, timeout=600):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", f"timeout after {timeout}s: {' '.join(cmd)}"
    except FileNotFoundError as e:
        return 127, "", str(e)


def finding(fid, severity, message, file=".", fix=None):
    f = {"id": fid, "severity": severity, "file": file, "message": message}
    if fix:
        f["fix"] = fix
    return f


def sdk_prefix(prof, repo):
    sp = prof.get("sdk_prefix") or []
    pinned = any((repo / m).exists() for m in prof.get("sdk_prefix_when", []))
    return sp, pinned


def check_profile(prof, repo, out):
    rules = prof.get("rules_dir")
    if rules and not (repo / rules).is_dir():
        out.append(finding("PROFILE-RULES", "minor", f"{rules} não existe: o implementer não tem rules para seguir", rules))
    adr = prof.get("adr_dir")
    if adr and not (repo / adr).is_dir():
        out.append(finding("PROFILE-ADR", "major", f"{adr} não existe: ADRs não chegam ao implementer nem ao G1", adr))


def check_submodules(prof, repo, out, fix):
    rc, stdout, _ = sh(["git", "submodule", "status"], repo)
    if rc != 0:
        return
    adr = prof.get("adr_dir") or ""
    for line in stdout.splitlines():
        state, path = line[:1], line[1:].split()[1]
        if state not in "-+U":
            continue
        holds_adr = adr == path or adr.startswith(path + "/")
        what = {"-": "não inicializado", "+": "fora do commit registrado", "U": "com conflito"}[state]
        sev = "critical" if state == "-" and holds_adr else "major"
        msg = f"submódulo {path} {what}" + (f"; {adr} vem dele, então ADRs lidos não são os desta branch" if holds_adr else "")
        if state == "+":
            _, head, _ = sh(["git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD"], repo)
            msg += f" (HEAD em {head.strip()})"
        dirty = sh(["git", "-C", path, "status", "--porcelain"], repo)[1].strip() if state != "-" else ""
        if dirty:
            msg += "; tem mudanças locais, não atualizo sozinho"
        cmd = ["git", "submodule", "update", "--init", path]
        if fix is not None and not dirty and state != "U":
            rc2, _, err = sh(cmd, repo)
            if rc2 == 0:
                fix.append(f"submódulo {path} atualizado para o commit registrado")
                continue
            msg += f"; update falhou: {err[-TAIL:]}"
        out.append(finding("SUBMODULE", sev, msg, path, None if dirty else " ".join(cmd)))


def flutter_pinned_version(repo):
    for name, key in ((".fvmrc", "flutter"), (".fvm/fvm_config.json", "flutterSdkVersion")):
        f = repo / name
        if f.exists():
            return json.loads(f.read_text()).get(key)
    return None


def check_flutter_sdk(prof, repo, out, fix):
    sp, pinned = sdk_prefix(prof, repo)
    if not pinned:
        return
    if not shutil.which(sp[0]):
        out.append(finding("SDK-PREFIX", "critical", f"repo fixa o SDK mas {sp[0]} não está no PATH: o G0 cai no flutter global em silêncio"))
        return
    want = flutter_pinned_version(repo)
    if not want:
        return
    if not (FVM_VERSIONS / want).is_dir():
        if fix is not None:
            rc, _, err = sh(["fvm", "install", want], repo, timeout=1800)
            if rc == 0:
                fix.append(f"fvm install {want}")
            else:
                out.append(finding("SDK-MISSING", "critical", f"Flutter {want} não instalado e fvm install falhou: {err[-TAIL:]}"))
                return
        else:
            out.append(finding("SDK-MISSING", "critical", f"Flutter {want} fixado no repo mas não instalado", fix=f"fvm install {want}"))
            return
    rc, stdout, err = sh(sp + ["flutter", "--version", "--machine"], repo)
    got = None
    if rc == 0:
        m = re.search(r"\{.*\}", stdout, re.S)
        got = json.loads(m.group(0)).get("frameworkVersion") if m else None
    if got != want:
        out.append(finding("SDK-VERSION", "critical", f"{' '.join(sp)} flutter resolve {got or 'nada'}, repo fixa {want}: {err[-TAIL:]}".rstrip(": ")))
    link = repo / ".fvm" / "flutter_sdk"
    target = FVM_VERSIONS / want
    # IDE and the dart MCP (launch_app in G2) read this link, not .fvmrc; fvm leaves it stale after a pin bump.
    if not link.is_symlink() or Path(link.readlink()) != target:
        current = link.readlink() if link.is_symlink() else "ausente"
        if fix is not None:
            link.parent.mkdir(exist_ok=True)
            link.unlink(missing_ok=True)
            link.symlink_to(target)
            (repo / ".fvm" / "versions").mkdir(exist_ok=True)
            vlink = repo / ".fvm" / "versions" / want
            if not vlink.exists():
                vlink.symlink_to(target)
            fix.append(f".fvm/flutter_sdk -> {target}")
        else:
            out.append(finding("SDK-LINK", "major", f".fvm/flutter_sdk aponta para {current}, repo fixa {want}: IDE e dart MCP usam outro SDK",
                               ".fvm/flutter_sdk", f"ln -sfn {target} .fvm/flutter_sdk"))


def make_excluded(repo):
    mk = repo / "Makefile"
    m = re.search(r"^EXCLUDED_PKGS\s*:?=\s*(.*)$", mk.read_text(), re.M) if mk.exists() else None
    return set(m.group(1).split()) if m else set()


def dart_packages(repo):
    dirs = [repo] if (repo / "pubspec.yaml").exists() else []
    excluded = make_excluded(repo)
    dirs += sorted(p.parent for p in repo.glob("packages/*/pubspec.yaml") if p.parent.name not in excluded)
    return [d for d in dirs if "resolution: workspace" not in (d / "pubspec.yaml").read_text()]


LOCK_ENTRY = re.compile(r'^  (\S+):\n(?:    .*\n)*?    version: "([^"]+)"', re.M)


def stale_packages(repo):
    # Compares content, not mtimes: branch switches touch pubspec.lock without changing what it resolves.
    stale = []
    for d in dart_packages(repo):
        cfg, lock = d / ".dart_tool" / "package_config.json", d / "pubspec.lock"
        if not cfg.exists():
            stale.append(d)
            continue
        if not lock.exists():
            continue
        resolved = {p["name"]: p["rootUri"] for p in json.loads(cfg.read_text())["packages"]}
        for name, version in LOCK_ENTRY.findall(lock.read_text()):
            uri = resolved.get(name)
            if uri is None or ("/hosted/" in uri and f"/{name}-{version}" not in uri):
                stale.append(d)
                break
    return stale


def missing_codegen(repo):
    rx = re.compile(r"^part '([^']+\.(?:freezed|g)\.dart)';", re.M)
    missing = {}
    for d in dart_packages(repo):
        for src in (d / "lib").rglob("*.dart") if (d / "lib").is_dir() else []:
            if src.name.endswith((".g.dart", ".freezed.dart")):
                continue
            for part in rx.findall(src.read_text(errors="ignore")):
                if not (src.parent / part).exists():
                    missing.setdefault(d, []).append(str((src.parent / part).relative_to(repo)))
    return missing


def check_flutter_deps(prof, repo, out, fix):
    stale, missing = stale_packages(repo), missing_codegen(repo)
    if not stale and not missing:
        return
    has_make_setup = (repo / "Makefile").exists() and re.search(r"^setup:", (repo / "Makefile").read_text(), re.M)
    if fix is not None:
        if has_make_setup:
            rc, stdout, err = sh(["make", "setup"], repo, timeout=3600)
        else:
            sp, pinned = sdk_prefix(prof, repo)
            prefix = sp if pinned else []
            rc, stdout, err = 0, "", ""
            for d in sorted(set(stale) | set(missing)):
                rc, stdout, err = sh(prefix + ["flutter", "pub", "get"], d)
                if rc == 0 and d in missing:
                    rc, stdout, err = sh(prefix + ["dart", "run", "build_runner", "build", "--delete-conflicting-outputs"], d, timeout=1800)
                if rc != 0:
                    break
        if rc == 0:
            fix.append("make setup" if has_make_setup else "pub get + build_runner nos pacotes afetados")
            stale, missing = stale_packages(repo), missing_codegen(repo)
        else:
            out.append(finding("DEPS-SETUP", "critical", f"setup falhou: {(stdout + err)[-TAIL:]}"))
            return
    how = "make setup" if has_make_setup else "flutter pub get + build_runner"
    for d in stale:
        out.append(finding("DEPS-STALE", "major", ".dart_tool/package_config.json não resolve o que o pubspec.lock pede", str(d.relative_to(repo)) or ".", how))
    for d, files in missing.items():
        out.append(finding("CODEGEN-MISSING", "critical", f"{len(files)} arquivo(s) gerado(s) ausente(s), ex.: {files[0]}",
                           str(d.relative_to(repo)) or ".", how))


def sample_file(repo, prof, pattern, under):
    rc, stdout, _ = sh(["git", "ls-files", "--", f"{under}/{pattern}" if under else pattern], repo)
    files = [f for f in stdout.splitlines()
             if any(f.endswith(e) for e in prof["source_ext"]) and not any(f.endswith(s) for s in prof["generated_suffixes"])]
    files = [f for f in files if (repo / f).exists()]
    return min(files, key=lambda f: (repo / f).stat().st_size) if files else None


def pkg_root(path, repo, markers):
    d = path.parent
    while d != repo and d != d.parent and not any((d / m).exists() for m in markers):
        d = d.parent
    return d


def run_g0_cmd(prof, repo, key, rel):
    sp, pinned = sdk_prefix(prof, repo)
    prefix = sp if pinned and shutil.which(sp[0]) else []
    root = pkg_root(repo / rel, repo, prof["detect"])
    target = str((repo / rel).relative_to(root))
    cmd = prof[key]["cmd"]
    args = []
    for c in cmd:
        if c == "{files}":
            args.append(target)
        elif c == "{pkgs}":
            parent = str(Path(target).parent)
            args.append("./" + parent if parent != "." else ".")
        else:
            args.append(c)
    if prefix and args[0] in ("dart", "flutter"):
        args = prefix + args
    return root, args, sh(args, root, timeout=900)


def check_g0_smoke(prof, repo, out, evidence):
    src = sample_file(repo, prof, "*", "lib") or sample_file(repo, prof, "*", "")
    if src:
        root, args, (rc, stdout, err) = run_g0_cmd(prof, repo, "analyze", src)
        # dart analyze exits 1-3 for infos/warnings/errors found; anything else means the command itself broke.
        if rc not in (0, 1, 2, 3):
            out.append(finding("G0-ANALYZE", "critical", f"`{' '.join(args)}` não roda em {root.relative_to(repo) or '.'}: {(stdout + err)[-TAIL:]}", src))
        else:
            evidence.append(f"G0 analyze ok: {' '.join(args)} ({src})")
    test = sample_file(repo, prof, "*_test*", "")
    if test:
        root, args, (rc, stdout, err) = run_g0_cmd(prof, repo, "test", test)
        if rc != 0:
            out.append(finding("G0-TEST", "major", f"`{' '.join(args)}` falha num teste existente; gate vai reprovar tasks por ambiente: {(stdout + err)[-TAIL:]}", test))
        else:
            evidence.append(f"G0 test ok: {' '.join(args)} ({test})")


def check_g2_device(prof, repo, phase, out):
    device = prof.get("g2_device")
    if not device or prof["name"] != "flutter":
        return
    sp, pinned = sdk_prefix(prof, repo)
    prefix = sp if pinned and shutil.which(sp[0]) else []
    rc, stdout, err = sh(prefix + ["flutter", "devices", "--machine"], repo, timeout=120)
    m = re.search(r"\[.*\]", stdout, re.S)
    devices = json.loads(m.group(0)) if rc == 0 and m else []
    dev = next((d for d in devices if device in (d["id"], d["name"])), None)
    platform = (dev or {}).get("targetPlatform", "darwin" if device == "macos" else "")
    pdir = next((v for k, v in PLATFORM_DIRS.items() if platform.startswith(k)), None)
    if pdir and not (repo / pdir).is_dir():
        sev = "critical" if phase == "verify" else "major"
        out.append(finding("G2-PLATFORM", sev, f"g2_device={device} roda em {pdir}, mas o repo não tem {pdir}/: G2 em runtime não sobe",
                           f"~/.claude/stacks/{prof['name']}.json"))
    elif phase == "verify" and not dev:
        out.append(finding("G2-DEVICE", "critical", f"g2_device={device} não está conectado (flutter devices)"))


def check_qa_tools(repo, out):
    for script, tools in QA_TOOLS.items():
        if (repo / script).exists():
            lack = [t for t in tools if not shutil.which(t)]
            if script == "qa/android.sh" and lack == ["adb"] and (Path.home() / "Library/Android/sdk/platform-tools/adb").exists():
                lack = []
            if lack:
                out.append(finding("QA-TOOLS", "minor", f"{script} precisa de {', '.join(lack)} no PATH", script))


def audit(prof, repo, phase, quick, fix):
    out, evidence = [], []
    check_profile(prof, repo, out)
    check_submodules(prof, repo, out, fix)
    if prof["name"] == "flutter":
        check_flutter_sdk(prof, repo, out, fix)
        check_flutter_deps(prof, repo, out, fix)
        check_qa_tools(repo, out)
    if not quick and not any(f["severity"] == "critical" for f in out):
        check_g0_smoke(prof, repo, out, evidence)
    check_g2_device(prof, repo, phase, out)
    return out, evidence


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--stack", required=True)
    ap.add_argument("--phase", choices=["kickoff", "verify"], default="kickoff")
    ap.add_argument("--fix", action="store_true")
    ap.add_argument("--quick", action="store_true", help="skip running the G0 analyze/test commands")
    ap.add_argument("--text", action="store_true")
    a = ap.parse_args()
    repo = Path(a.repo).expanduser().resolve()
    prof = json.loads((STACKS / f"{a.stack}.json").read_text())

    fixed = [] if a.fix else None
    findings, evidence = audit(prof, repo, a.phase, a.quick, fixed)
    order = {"critical": 0, "major": 1, "minor": 2}
    findings.sort(key=lambda f: order[f["severity"]])
    verdict = "fail" if any(f["severity"] == "critical" for f in findings) else "pass"
    result = {"gate": "AUDIT", "phase": a.phase, "verdict": verdict, "findings": findings,
              "evidence": evidence, "fixed": fixed or []}

    if a.text:
        print(f"harness-audit {repo.name} [{a.stack}/{a.phase}]: {verdict.upper()}")
        for e in evidence:
            print(f"  ok        {e}")
        for f in fixed or []:
            print(f"  fixed     {f}")
        for f in findings:
            print(f"  {f['severity']:<9} {f['id']:<16} {f['file']}: {f['message']}")
            if f.get("fix"):
                print(f"  {'':<26} fix: {f['fix']}")
    else:
        print(json.dumps(result, ensure_ascii=False))
    raise SystemExit(1 if verdict == "fail" else 0)


if __name__ == "__main__":
    main()
