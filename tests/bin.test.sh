#!/usr/bin/env bash
# Smoke tests for the deterministic helpers. Uses the repo's bin/, not ~/.claude/bin.
set -euo pipefail
BIN="$(cd "$(dirname "$0")/../bin" && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
tmp() { mktemp -d; }

echo "- wf-checkpoint: restore reverts only changed paths and keeps the real index"
T=$(tmp); git -C "$T" init -q
echo a > "$T/a.txt"; git -C "$T" add .; git -C "$T" -c user.email=t@t -c user.name=t commit -qm init
echo staged > "$T/s.txt"; git -C "$T" add s.txt
CP=$("$BIN/wf-checkpoint.sh" create "$T")
echo changed >> "$T/a.txt"; echo new > "$T/n.txt"; rm "$T/s.txt"
[ "$("$BIN/wf-checkpoint.sh" changed "$T" "$CP" | tr '\n' ' ')" = "a.txt n.txt s.txt " ] || fail "changed list"
[ "$("$BIN/wf-checkpoint.sh" numstat "$T" "$CP" | tr '\n' ' ')" = "$(printf '1\t0\ta.txt\n1\t0\tn.txt\n0\t1\ts.txt\n' | tr '\n' ' ')" ] || fail "numstat"
"$BIN/wf-checkpoint.sh" restore "$T" "$CP" >/dev/null
[ "$(cat "$T/a.txt")" = "a" ] || fail "a.txt not restored"
[ ! -e "$T/n.txt" ] || fail "n.txt not removed"
[ "$(git -C "$T" status --short)" = "A  s.txt" ] || fail "real index touched"
[ "$(git -C "$T" rev-list --count HEAD)" = "1" ] || fail "commit created"

echo "- wf-checkpoint/wf-event: @file refs resolve to the sha gate_g0 wrote"
REF=$(tmp)/T1.tree; echo "$CP" > "$REF"
echo changed >> "$T/a.txt"
[ "$("$BIN/wf-checkpoint.sh" changed "$T" "@$REF")" = "a.txt" ] || fail "@ref changed"
"$BIN/wf-checkpoint.sh" changed "$T" "@$REF.missing" >/dev/null 2>&1 && fail "@ref to a missing file must fail"
RD=$(tmp)/run; python3 "$BIN/wf-event.py" log --run-dir "$RD" --role dev --task T1 --verdict start --checkpoint "@$REF"
python3 -c "import json,sys; e=json.loads(open(sys.argv[1]).read().splitlines()[-1]); assert e['checkpoint']==sys.argv[2], e" "$RD/events.jsonl" "$CP" || fail "event stores resolved sha"
git -C "$T" checkout -q -- a.txt

echo "- adr-index: match respects affects globs and status"
T=$(tmp); mkdir -p "$T/docs/adr"
printf -- '---\nid: 0001\ntitle: A\nstatus: accepted\naffects: ["lib/features/**/bloc/**"]\n---\n' > "$T/docs/adr/0001-a.md"
printf -- '---\nid: 0002\ntitle: B\nstatus: proposed\naffects: ["lib/**"]\n---\n' > "$T/docs/adr/0002-b.md"
[ "$(python3 "$BIN/adr-index.py" match "$T" lib/features/auth/bloc/x.dart)" = "docs/adr/0001-a.md" ] || fail "match"
[ -z "$(python3 "$BIN/adr-index.py" match "$T" lib/main.dart)" ] || fail "proposed ADR matched"
[ "$(python3 "$BIN/adr-index.py" next-id "$T")" = "0003" ] || fail "next-id"

echo "- wf-event: persist folds tiers into current.json"
W=$(tmp)
echo '{"tasks":{"items":[{"id":"T1","tier":"haiku","status":"pending"}]}}' > "$W/current.json"
echo '{"status":"done","checkpoint":"abc","tasks":[{"id":"T1","status":"done","tier":"sonnet","attempts":3}],"trace":[{"role":"dev"}]}' > "$W/r.json"
HOME_BIN_SHIM=$(tmp); mkdir -p "$HOME_BIN_SHIM/.claude"; ln -s "$BIN" "$HOME_BIN_SHIM/.claude/bin"; ln -s "$(cd "$BIN/../stacks" && pwd)" "$HOME_BIN_SHIM/.claude/stacks"
HOME="$HOME_BIN_SHIM" python3 "$BIN/wf-event.py" persist --run-dir "$W/runs/x" --workflow-dir "$W" --result-file "$W/r.json" >/dev/null
python3 -c "import json,sys;d=json.load(open('$W/current.json'));i=d['tasks']['items'][0];sys.exit(0 if (i['tier'],i['status'],d['exec']['checkpoint'])==('sonnet','done','abc') else 1)" || fail "persist"

echo "- wf-event: persist writes result.json atomically and leaves no .tmp"
python3 -c "import json;assert json.load(open('$W/runs/x/result.json'))['checkpoint']=='abc'" || fail "result.json content"
echo '{"status":"blocked","checkpoint":"def","tasks":[],"trace":[]}' > "$W/r2.json"
HOME="$HOME_BIN_SHIM" python3 "$BIN/wf-event.py" persist --run-dir "$W/runs/x" --workflow-dir "$W" --result-file "$W/r2.json" >/dev/null
python3 -c "import json;assert json.load(open('$W/runs/x/result.json'))['checkpoint']=='def'" || fail "result.json overwrite"
[ -z "$(find "$W/runs/x" -name '*.tmp')" ] || fail ".tmp left behind"

echo "- wf-event: log records the checkpoint"
python3 "$BIN/wf-event.py" log --run-dir "$W/runs/y" --role dev --task T1 --attempt 1 --tier haiku --verdict start --checkpoint abc123
python3 -c "import json;e=json.loads(open('$W/runs/y/events.jsonl').readline());assert e['checkpoint']=='abc123' and e['attempt']==1" || fail "event checkpoint"

echo "- get-project: one naming rule (remote, git root, worktree, outside git, divergence)"
T=$(tmp); H="$T/home"; mkdir -p "$H/workflow"
gp() { (cd "$1" && CLAUDE_HOME="$H" bash "$BIN/get-project.sh" 2>"$T/err"); }
git -C "$T" init -q local_name; git -C "$T/local_name" remote add origin git@host:org/My_Repo.git
mkdir -p "$T/local_name/app/lib"
[ "$(gp "$T/local_name")" = "My-Repo" ] || fail "remote name"
[ "$(gp "$T/local_name/app/lib")" = "My-Repo" ] || fail "subdirectory"
[ ! -s "$T/err" ] || fail "stderr without divergence"
git -C "$T" init -q main_repo; echo a > "$T/main_repo/a.txt"
git -C "$T/main_repo" add .; git -C "$T/main_repo" -c user.email=t@t -c user.name=t commit -qm init
[ "$(gp "$T/main_repo")" = "main-repo" ] || fail "no remote"
git -C "$T/main_repo" worktree add -q "$T/wt-checkout"
[ "$(gp "$T/wt-checkout")" = "main-repo" ] || fail "worktree without remote"
mkdir -p "$T/plain_dir"
[ "$(gp "$T/plain_dir")" = "plain-dir" ] || fail "outside git"
git -C "$T" init -q old_name; git -C "$T/old_name" remote add origin https://host/org/new-name.git
mkdir -p "$H/workflow/old_name"
[ "$(gp "$T/old_name")" = "old_name" ] || fail "divergence stdout"
[ "$(cat "$T/err")" = "workflow existente em old_name; usando old_name (remote: new-name)" ] || fail "divergence stderr"
mkdir -p "$H/workflow/new-name"
[ "$(gp "$T/old_name")" = "new-name" ] || fail "remote workflow wins when both exist"
[ "$(cd "$T/local_name" && CLAUDE_HOME="$H" bash -c "source '$BIN/get-project.sh'")" = "" ] || fail "sourcing prints"
! grep -q CURRENT_PROJECT "$BIN/get-project.sh" || fail "CURRENT_PROJECT still read"

echo "- get-project: the 14 flow skills use it instead of basename"
SKILLS="$(cd "$BIN/../skills" && pwd)"
FLOW="specify plan tasks implement verify complete status fix challenge-spec review approve-review post-review refine ado-refine"
MISSING=$(cd "$SKILLS" && for s in $FLOW; do echo "$s/SKILL.md"; done | xargs grep -L 'source ~/.claude/bin/get-project.sh' || true)
[ -z "$MISSING" ] || fail "skills without get-project: $MISSING"
[ -z "$(grep -rn 'basename "\$PROJECT_PATH"\|basename \$(git rev-parse' "$SKILLS" || true)" ] || fail "skills still derive the name by basename"

if command -v dart >/dev/null; then
  echo "- gate_g0: formats, flags analyzer errors and missing tests"
  T=$(tmp); git -C "$T" init -q; mkdir -p "$T/lib"
  printf 'name: g0smoke\nenvironment:\n  sdk: ^3.0.0\n' > "$T/pubspec.yaml"
  echo 'int add(int a, int b) => a + b;' > "$T/lib/a.dart"
  git -C "$T" add .; git -C "$T" -c user.email=t@t -c user.name=t commit -qm init
  CP=$("$BIN/wf-checkpoint.sh" create "$T")
  printf 'int add(int a,int b)=>a+b;\nint bad() { return "x"; }\n' > "$T/lib/a.dart"
  OUT=$(HOME="$HOME_BIN_SHIM" python3 "$BIN/gate_g0.py" --repo "$T" --stack flutter --checkpoint "$CP" --tests test/a_test.dart)
  echo "$OUT" | python3 -c "
import json,sys; r=json.load(sys.stdin); ids={f['id'] for f in r['findings']}
assert r['verdict']=='fail', r; assert 'G0-ANALYZE-RETURN_OF_INVALID_TYPE' in ids, ids; assert 'G0-TEST-MISSING' in ids, ids" || fail "gate_g0 verdict"
  grep -q 'int add(int a, int b) => a + b;' "$T/lib/a.dart" || fail "autofix format"
else
  echo "- gate_g0: skipped (dart not on PATH)"
fi

echo "- routing-stats.py: --write creates bands and overrides, preserves other keys, exits 2 without --project"
H=$(tmp); mkdir -p "$H/.claude/projects/test1/history"
mkdir -p "$H/.claude/workflow/test1/runs/run1"
mkdir -p "$H/.claude/workflow/test1/runs/run2"
# First result.json with some tasks
printf '{"tasks":[
{"id":"T1","complexity":"S","risk":"low","status":"done","attempts":1,"escalations":[],"tier":"haiku"},
{"id":"T2","complexity":"S","risk":"low","status":"done","attempts":1,"escalations":[],"tier":"haiku"},
{"id":"T3","complexity":"S","risk":"low","status":"done","attempts":1,"escalations":[],"tier":"haiku"},
{"id":"T4","complexity":"S","risk":"low","status":"done","attempts":1,"escalations":[],"tier":"haiku"},
{"id":"T5","complexity":"S","risk":"low","status":"done","attempts":1,"escalations":[],"tier":"haiku"},
{"id":"T6","complexity":"S","risk":"low","status":"done","attempts":2,"escalations":["e1"],"tier":"sonnet"},
{"id":"T7","complexity":"M","risk":"high","status":"done","attempts":3,"escalations":[],"tier":"sonnet"},
{"id":"T10","complexity":"M","risk":"low","status":"done","attempts":2,"escalations":[],"tier":"haiku"}
]}' > "$H/.claude/workflow/test1/runs/run1/result.json"
# Second result.json with more tasks
printf '{"tasks":[
{"id":"T8","complexity":"M","risk":"high","status":"done","attempts":2,"escalations":["e1","e2"],"tier":"opus"},
{"id":"T9","complexity":"M","risk":"high","status":"blocked","attempts":4,"escalations":[],"tier":"unknown"}
]}' > "$H/.claude/workflow/test1/runs/run2/result.json"
# A verify run echoes the same tasks and must not be counted
mkdir -p "$H/.claude/workflow/test1/runs/verify-20260101T000000Z"
cp "$H/.claude/workflow/test1/runs/run1/result.json" "$H/.claude/workflow/test1/runs/verify-20260101T000000Z/result.json"
# Test with existing routing.json that has extra keys
printf '{"extra_key":"preserve_me","overrides":{"S:low":{"tier0":"haiku","reason":"old"}}}' > "$H/.claude/projects/test1/routing.json"
# Run routing-stats with --write
HOME="$H" python3 "$BIN/routing-stats.py" --project test1 --write >/dev/null
# Verify bands
python3 -c "
import json
data = json.load(open('$H/.claude/projects/test1/routing.json'))
assert 'bands' in data, 'bands not in output'
assert 'overrides' in data, 'overrides not in output'
assert data['extra_key'] == 'preserve_me', 'extra key not preserved'
assert len(data['bands']) == 3, f'expected 3 bands, got {len(data[\"bands\"])}'
# Check S:low band (5 pass, 1 escalated, 0 blocked, 6 total)
slo = [b for b in data['bands'] if b['complexity']=='S' and b['risk']=='low'][0]
assert slo['n'] == 6, f'S:low n={slo[\"n\"]}, expected 6'
assert slo['pass_tier0'] == 5, f'S:low pass_tier0={slo[\"pass_tier0\"]}, expected 5'
assert slo['escalated'] == 1, f'S:low escalated={slo[\"escalated\"]}, expected 1'
assert slo['blocked'] == 0, f'S:low blocked={slo[\"blocked\"]}, expected 0'
assert slo['attempts_per_task'] == 1.2, f'S:low attempts_per_task={slo[\"attempts_per_task\"]}, expected 1.2'
# Check M:low band (1 task, no escalations)
mlo = [b for b in data['bands'] if b['complexity']=='M' and b['risk']=='low'][0]
assert mlo['n'] == 1, f'M:low n={mlo[\"n\"]}, expected 1'
assert mlo['pass_tier0'] == 1, f'M:low pass_tier0={mlo[\"pass_tier0\"]}, expected 1'
assert mlo['escalated'] == 0, f'M:low escalated={mlo[\"escalated\"]}, expected 0'
assert mlo['blocked'] == 0, f'M:low blocked={mlo[\"blocked\"]}, expected 0'
assert mlo['attempts_per_task'] == 2.0, f'M:low attempts_per_task={mlo[\"attempts_per_task\"]}, expected 2.0'
# Check M:high band (1 pass, 1 escalated, 1 blocked, 3 total)
mhi = [b for b in data['bands'] if b['complexity']=='M' and b['risk']=='high'][0]
assert mhi['n'] == 3, f'M:high n={mhi[\"n\"]}, expected 3'
assert mhi['pass_tier0'] == 1, f'M:high pass_tier0={mhi[\"pass_tier0\"]}, expected 1'
assert mhi['escalated'] == 1, f'M:high escalated={mhi[\"escalated\"]}, expected 1'
assert mhi['blocked'] == 1, f'M:high blocked={mhi[\"blocked\"]}, expected 1'
assert mhi['attempts_per_task'] == 3.0, f'M:high attempts_per_task={mhi[\"attempts_per_task\"]}, expected 3.0'
" || fail "bands format or content"
# Test exit code 2 without --project
HOME="$H" python3 "$BIN/routing-stats.py" --write >/dev/null 2>&1 || EXIT_CODE=$?
[ "$EXIT_CODE" -eq 2 ] || fail "expected exit code 2, got $EXIT_CODE"
# Test with no runs: should write bands: [] and overrides: {}
H2=$(tmp); mkdir -p "$H2/.claude/projects/empty"
HOME="$H2" python3 "$BIN/routing-stats.py" --project empty --write >/dev/null
python3 -c "
import json
data = json.load(open('$H2/.claude/projects/empty/routing.json'))
assert data.get('bands') == [], f'expected empty bands, got {data.get(\"bands\")}'
assert data.get('overrides') == {}, f'expected empty overrides, got {data.get(\"overrides\")}'
" || fail "empty project output"

echo "- current_json: update_json writes any path atomically under its own lock"
T=$(tmp)
HOME="$HOME_BIN_SHIM" python3 - "$T" <<'PY2'
import sys; from pathlib import Path
sys.path.insert(0, str(Path.home() / ".claude" / "bin"))
from current_json import update_json
d = Path(sys.argv[1])
update_json(d / "x.json", d / ".x.json.lock", lambda x: {**x, "n": x.get("n", 0) + 1}, default={"n": 10})
r = update_json(d / "x.json", d / ".x.json.lock", lambda x: {**x, "n": x["n"] + 1})
assert r == {"n": 12}, r
PY2
[ -z "$(find "$T" -name '*.tmp')" ] || fail "update_json left .tmp"

echo "- wf-report: every subcommand is idempotent (byte-identical except ended_at)"
wfr() { env -u CLAUDE_FLOW_SESSION_ID HOME="$HOME_BIN_SHIM" python3 "$BIN/wf-report.py" "$@"; }
wfe() { local sid=$1; shift; HOME="$HOME_BIN_SHIM" CLAUDE_FLOW_SESSION_ID="$sid" python3 "$BIN/wf-report.py" "$@"; }
strip_ended() { grep -v '"ended_at"' "$1"; }
W=$(tmp)
printf '{"feature":"Feat A","start_date":"2026-01-01T00:00:00Z","status":"specifying"}' > "$W/current.json"
printf 'Resumo da etapa\n' > "$W/sum.md"
printf 'Escolhi A\n' > "$W/dec.md"
printf 'Usar B\n' > "$W/alt.md"
printf '{"accepted":[{"id":"B1","severity":"major","text_md":"t"}],"rejected":[{"id":"A2","text_md":"x","reason_md":"y"}]}' > "$W/f.json"
mkdir -p "$W/runs/impl-a"
printf '{"status":"done","tasks":[{"id":"T1","decisions":["d1"],"escalations":[]}]}' > "$W/runs/impl-a/result.json"
twice() {
  wfr "$@" >/dev/null; strip_ended "$W/report.json" > "$W/a.snap"
  wfr "$@" >/dev/null; strip_ended "$W/report.json" > "$W/b.snap"
  cmp -s "$W/a.snap" "$W/b.snap" || fail "not idempotent: $1"
}
twice stage-start specify --workflow-dir "$W" --session s-1
twice stage-end specify --workflow-dir "$W" --summary-file "$W/sum.md" --artifact spec.md
twice decision specify --workflow-dir "$W" --by orchestrator --text-file "$W/dec.md" --alternative-file "$W/alt.md"
twice findings challenge --workflow-dir "$W" --source challenger --file "$W/f.json"
twice import-run implement --workflow-dir "$W" --run-dir "$W/runs/impl-a"
[ "$(wfr stage-end specify --workflow-dir "$W" --summary-file "$W/sum.md")" = "decisions: 1" ] || fail "stage-end prints decision count"
python3 -c "
import json; r=json.load(open('$W/report.json'))
assert r['version']==1 and r['cycle']=={'feature':'Feat A','started_at':'2026-01-01T00:00:00Z'}, r['cycle']
assert [s['stage'] for s in r['stages']]==['specify','challenge','implement'], [s['stage'] for s in r['stages']]
sp=r['stages'][0]
assert sp['status']=='done' and sp['summary_md']=='Resumo da etapa\n' and sp['artifacts']==['spec.md'] and sp['session_id']=='s-1', sp
assert len(sp['decisions'])==1 and sp['decisions'][0]['alternative_md']=='Usar B\n' and len(sp['decisions'][0]['id'])==64, sp['decisions']
assert len(r['stages'][1]['findings'])==1 and r['stages'][1]['findings'][0]['accepted'][0]['id']=='B1'
" || fail "report content"
twice reset --workflow-dir "$W"
[ "$(ls "$W" | grep -c '^report\..*\.json$')" = "1" ] || fail "reset archives once, not the empty report"
python3 -c "import json; r=json.load(open('$W/report.json')); assert r['stages']==[]" || fail "reset leaves empty report"
python3 -c "import json; r=json.load(open('$W/report.2026-01-01T00:00:00Z.json')); assert r['stages'][0]['stage']=='specify'" || fail "reset archive content"

echo "- wf-report: attempt, closing the previous running stage, dedup, exit 2 and exit 3"
wfr stage-start plan --workflow-dir "$W"
wfr stage-end plan --workflow-dir "$W" --summary-file "$W/sum.md" >/dev/null
wfr stage-start plan --workflow-dir "$W"
python3 -c "import json; s=[x for x in json.load(open('$W/report.json'))['stages'] if x['stage']=='plan'][0]; assert (s['attempt'],s['status'])==(2,'running') and 'ended_at' not in s, s" || fail "reopen attempt 2"
wfr stage-start implement --workflow-dir "$W"
wfr stage-start verify --workflow-dir "$W"
python3 -c "
import json; st={x['stage']:x for x in json.load(open('$W/report.json'))['stages']}
assert st['implement']['status']=='blocked' and st['implement']['summary_md']=='encerrada sem relatório' and st['implement'].get('ended_at'), st['implement']
assert st['plan']['status']=='blocked'
assert st['verify']['status']=='running'
" || fail "previous running stage closed as blocked"
wfr decision verify --workflow-dir "$W" --by user --text-file "$W/dec.md"
wfr decision verify --workflow-dir "$W" --by user --text-file "$W/dec.md"
python3 -c "import json; s=[x for x in json.load(open('$W/report.json'))['stages'] if x['stage']=='verify'][0]; assert len(s['decisions'])==1" || fail "decision dedup"
cp "$W/report.json" "$W/before.json"
expect_exit() { local want=$1; shift; local got=0; wfr "$@" >/dev/null 2>&1 || got=$?; [ "$got" = "$want" ] || fail "expected exit $want, got $got: $*"; }
expect_exit 2 stage-start deploy --workflow-dir "$W"
expect_exit 2 stage-end verify --workflow-dir "$W" --summary-file "$W/sum.md" --status running
expect_exit 2 decision verify --workflow-dir "$W" --by robot --text-file "$W/dec.md"
expect_exit 2 decision verify --workflow-dir "$W" --by user --text-file "$W/missing.md"
expect_exit 2 findings verify --workflow-dir "$W" --source x --file "$W/missing.json"
expect_exit 2 import-run verify --workflow-dir "$W" --run-dir "$W/runs/none"
cmp -s "$W/before.json" "$W/report.json" || fail "invalid input touched report.json"
N=$(tmp)
expect_exit 3 stage-start specify --workflow-dir "$N"
expect_exit 3 reset --workflow-dir "$N"
[ ! -e "$N/report.json" ] || fail "report.json written without current.json"

echo "- wf-report: subcommands that never archive refuse a missing or foreign report untouched"
report_state() {
  if [ -f "$1/report.json" ]; then python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$1/report.json"; else echo absent; fi
  ls -A "$1" | grep '^report\..*\.json$' || true
}
report_snap() { SNAP_STATE=$(report_state "$1"); }
report_untouched() { [ "$(report_state "$1")" = "$SNAP_STATE" ] || fail "report.json changed or archived: $2"; }
wfr_as() {
  local cmd=$1 dir=$2 got=0
  env -u CLAUDE_FLOW_SESSION_ID HOME="$HOME_BIN_SHIM" python3 - "$BIN/wf-report.py" "$cmd" "$dir" "$BRIEF_OK" 2>"$dir/.err" <<'PY' || got=$?
import argparse, importlib.util, sys
spec = importlib.util.spec_from_file_location("wf_report", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.parse_args = lambda: argparse.Namespace(cmd=sys.argv[2], workflow_dir=sys.argv[3], name="plan", file=sys.argv[4], candidates=None)
m.main()
PY
  echo "$got"
}
BRIEF_OK=$(tmp)/brief.json
cat > "$BRIEF_OK" <<'JSON'
{"summary": "Grava em report.json. Fim.", "artifact": "plan.md",
 "risks": [{"id": "R1", "text": "Lock invertido trava o relatório", "source": "critic"}],
 "questions": [{"id": "Q1", "text": "Onde fica a regra de parada?",
   "options": [{"id": "a", "label": "No script", "consequence": "Testável por e2e"},
               {"id": "b", "label": "Na skill", "consequence": "Depende do modelo"}],
   "assumed": "a", "prefers": {"author": "a", "critic": "a"}}]}
JSON
G=$(tmp)
printf '{"feature":"Feat G","start_date":"2026-04-01T00:00:00Z"}' > "$G/current.json"
for cmd in brief answer show reopen; do
  report_snap "$G"
  [ "$(wfr_as "$cmd" "$G")" = 2 ] || fail "$cmd without report.json: expected exit 2"
  grep -q "bloco ausente" "$G/.err" || fail "$cmd: stderr names the missing block"
  report_untouched "$G" "$cmd without report.json"
done
wfr stage-start plan --workflow-dir "$G"
printf '{"feature":"Feat H","start_date":"2026-04-01T00:00:00Z"}' > "$G/current.json"
for cmd in brief answer show reopen; do
  report_snap "$G"
  [ "$(wfr_as "$cmd" "$G")" = 2 ] || fail "$cmd on a foreign cycle: expected exit 2"
  report_untouched "$G" "$cmd on a foreign cycle"
done
printf '{"version":2,"cycle":{"feature":"Feat H","started_at":"2026-04-01T00:00:00Z"},"stages":[]}' > "$G/report.json"
report_snap "$G"
[ "$(wfr_as brief "$G")" = 2 ] || fail "brief on another version: expected exit 2"
report_untouched "$G" "brief on another version"

echo "- wf-report: brief validates, cuts and is idempotent"
B=$(tmp); BD=$(tmp)
printf '{"feature":"Feat Br","start_date":"2026-05-01T00:00:00Z"}' > "$B/current.json"
wfr stage-start plan --workflow-dir "$B"
mkb() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); exec(sys.argv[2]); json.dump(d,open(sys.argv[3],'w'),ensure_ascii=False)" "$BRIEF_OK" "$2" "$BD/$1.json"; }
gate_ok() {
  python3 -c "
import json,sys; g=[s for s in json.load(open(sys.argv[1]))['stages'] if s['stage']=='plan'][0]['gate']
assert $1, g" "$B/report.json" || fail "$2"
}
brief_refused() {
  local label=$1 want=$2 got=0; shift 2
  report_snap "$B"
  wfr brief plan --workflow-dir "$B" "$@" >/dev/null 2>"$BD/err" || got=$?
  [ "$got" = 2 ] || fail "brief $label: expected exit 2, got $got"
  report_untouched "$B" "brief $label"
  grep -qF -- "$want" "$BD/err" || fail "brief $label: stderr '$(cat "$BD/err")' lacks '$want'"
}
OUT=$(wfr brief plan --workflow-dir "$B" --file "$BRIEF_OK")
gate_ok "g['name']=='plan' and g['status']=='open' and g['round']==1 and g['artifact']=='plan.md'" "brief writes round 1 open on the plan stage"
gate_ok "g['summary']=='Grava em report.json. Fim.'" "a dot inside report.json is not a sentence end"
gate_ok "g['questions'][0]['answer'] is None and g['history']==[] and g['changes']==[] and g['cut']==[]" "brief fields set by the script"
gate_ok "g['omitted']=={'risks':0,'questions':0,'candidates':0}" "omitted always carries the three counts"
[ "$OUT" = "$(wfr show plan --workflow-dir "$B")" ] || fail "brief prints the render of the written block"
report_snap "$B"
wfr brief plan --workflow-dir "$B" --file "$BRIEF_OK" >/dev/null
report_untouched "$B" "same file again is a byte-identical no-op"
python3 -c "
import json,sys; r=json.load(open(sys.argv[1]))
[s for s in r['stages'] if s['stage']=='plan'][0]['gate']['questions'][0]['answer']='b'
json.dump(r,open(sys.argv[1],'w'),indent=2)" "$B/report.json"
wfr brief plan --workflow-dir "$B" --file "$BRIEF_OK" >/dev/null
gate_ok "g['questions'][0]['answer'] is None and g['status']=='open'" "round 1 brief replaces the block and clears answers"
mkb other "d['summary']='Outro resumo.'"
wfr brief plan --workflow-dir "$B" --file "$BD/other.json" >/dev/null
gate_ok "g['summary']=='Outro resumo.' and g['round']==1" "another file replaces the round 1 block"
for k in round status answer history cut decided_at; do
  mkb "forbid-$k" "d['$k']=1"
  brief_refused "with $k" "$k: campo do script" --file "$BD/forbid-$k.json"
done
mkb qanswer "d['questions'][0]['answer']='a'"
brief_refused "with a question answer" "questions[0].answer: campo do script" --file "$BD/qanswer.json"

mkb cuts "
d['risks']=[{'id':f'R{i}','text':f'Risco {i}','source':'author'} for i in range(5)]
d['questions']=[dict(d['questions'][0], id=f'Q{i}') for i in range(4)]"
wfr brief plan --workflow-dir "$B" --file "$BD/cuts.json" >/dev/null
gate_ok "[r['id'] for r in g['risks']]==['R0','R1','R2'] and [q['id'] for q in g['questions']]==['Q0','Q1','Q2']" "risks and questions cut to 3 in the order received"
gate_ok "g['omitted']=={'risks':2,'questions':1,'candidates':0}" "omitted counts the cut risks and questions"
mkb s281 "d['summary']='a'*281"
brief_refused "summary of 281 chars" "summary: 281 caracteres, teto 280" --file "$BD/s281.json"
mkb s3 "d['summary']='A. B. C.'"
brief_refused "summary with 3 sentences" "summary: 3 frases, teto 2" --file "$BD/s3.json"
mkb o1 "d['questions'][0]['options']=d['questions'][0]['options'][:1]"
brief_refused "question with 1 option" "questions[0].options: 1 opções, precisa de 2 a 3" --file "$BD/o1.json"
mkb o4 "
o=d['questions'][0]['options']; o+=[dict(o[0], id='c'), dict(o[0], id='d')]"
brief_refused "question with 4 options" "questions[0].options: 4 opções, precisa de 2 a 3" --file "$BD/o4.json"
mkb c4 "d['changes']=['Linha']*4"
brief_refused "changes with 4 lines" "changes: 4 linhas, teto 3" --file "$BD/c4.json"
mkb m9 "d['map']={'nodes':[{'id':f'n{i}','label':'N','state':'new'} for i in range(9)]}"
brief_refused "map with 9 nodes" "map.nodes: 9 nós, teto 8" --file "$BD/m9.json"
mkb edge "
d['map']={'nodes':[{'id':'a','label':'A','state':'new','paths':['bin/a.py']}],'edges':[{'from':'a','to':'zz','label':'usa'}]}"
brief_refused "edge to a missing node" "map.edges[0].to: zz não é nó do mapa" --file "$BD/edge.json"
mkb state "
d['map']={'nodes':[{'id':'a','label':'A','state':'gone'}]}"
brief_refused "node state outside the enum" "map.nodes[0].state: gone fora de new|changed|existing" --file "$BD/state.json"
mkb assumed "d['questions'][0]['assumed']='z'"
brief_refused "assumed not an option" "questions[0].assumed: z não é opção da pergunta" --file "$BD/assumed.json"
mkb prefers "d['questions'][0]['prefers']['critic']='z'"
brief_refused "prefers not an option" "questions[0].prefers.critic: z não é opção da pergunta" --file "$BD/prefers.json"
mkb dup "d['risks'][0]['id']='Q1'"
brief_refused "repeated id" "questions[0].id: Q1 repetido" --file "$BD/dup.json"
mkb label "d['questions'][0]['options'][1]['label']='l'*41"
brief_refused "label above its cap" "questions[0].options[1].label: 41 caracteres, teto 40" --file "$BD/label.json"
report_snap "$B"; got=0; wfr brief tasks --workflow-dir "$B" --file "$BRIEF_OK" >/dev/null 2>"$BD/err" || got=$?
[ "$got" = 2 ] && grep -qF "etapa tasks ausente" "$BD/err" || fail "brief on a stage that never started"
report_untouched "$B" "brief on a stage that never started"
mkb map "
d['map']={'summary':'Dois nós.','nodes':[{'id':'a','label':'A','state':'new','note':'n','paths':['bin/a.py']},{'id':'b','label':'B','state':'existing'}],'edges':[{'from':'a','to':'b','label':'usa'}],'approaches':[]}"
wfr brief plan --workflow-dir "$B" --file "$BD/map.json" >/dev/null
gate_ok "g['map']['edges'][0]['to']=='b'" "a valid map is kept"

printf '[{"id":"Q1","text":"Onde fica a regra?"},{"id":"C2","text":"Nome do campo"},{"id":"C3","text":"Ordem dos locks"},{"id":"C4","text":"Teto de rodadas"}]' > "$BD/cand.json"
wfr brief plan --workflow-dir "$B" --file "$BRIEF_OK" --candidates "$BD/cand.json" >/dev/null
gate_ok "[c['id'] for c in g['cut']]==['C2','C3','C4'] and g['cut'][0]=={'id':'C2','text':'Nome do campo'}" "candidates outside questions go to cut"
gate_ok "g['omitted']['candidates']==3" "omitted counts the cut candidates"
python3 -c "import json; json.dump([{'id':f'C{i}','text':'t'} for i in range(12)], open('$BD/cand12.json','w'))"
wfr brief plan --workflow-dir "$B" --file "$BRIEF_OK" --candidates "$BD/cand12.json" >/dev/null
gate_ok "len(g['cut'])==10 and g['omitted']['candidates']==12" "cut keeps 10, omitted keeps the full count"
printf '[{"id":"C1"}]' > "$BD/bad.json"
brief_refused "with malformed candidates" "candidates[0].text" --file "$BRIEF_OK" --candidates "$BD/bad.json"

echo "- wf-report: show is read-only and recommends only when author and critic agree"
show_q() { python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert $1, d" "$(wfr show plan --workflow-dir "$B")" || fail "$2"; }
[ "$(wfr show tasks --workflow-dir "$B")" = '{"status":"absent"}' ] || fail "show without a block prints absent"
wfr brief plan --workflow-dir "$B" --file "$BRIEF_OK" >/dev/null
report_snap "$B"
show_q "d['status']=='open' and d['round']==1 and 'Grava em report.json. Fim.' in d['text_md'] and 'Lock invertido' in d['text_md']" "show prints status, round and text_md"
show_q "[o['label'] for o in d['questions'][0]['options']]==['No script (Recomendado)','Na skill'] and d['questions'][0]['multiSelect'] is False" "agreeing prefers mark the option recommended"
show_q "d['questions'][0]['question']=='Onde fica a regra de parada?' and d['questions'][0]['options'][1]['description']=='Depende do modelo'" "question text and consequence as description"
report_untouched "$B" "show is read-only"
mkb split "d['questions'][0]['prefers']={'author':'a','critic':'b'}"
wfr brief plan --workflow-dir "$B" --file "$BD/split.json" >/dev/null
show_q "not any('(Recomendado)' in o['label'] for o in d['questions'][0]['options'])" "diverging prefers recommend nothing"
show_q "[o['description'] for o in d['questions'][0]['options']]==['Testável por e2e. Preferida pelo autor.','Depende do modelo. Preferida pelo crítico.']" "diverging prefers say who prefers what"
mkb noprefers "del d['questions'][0]['prefers']"
wfr brief plan --workflow-dir "$B" --file "$BD/noprefers.json" >/dev/null
show_q "not any('(Recomendado)' in o['label'] for o in d['questions'][0]['options'])" "missing prefers count as disagreement"
show_q "d['questions'][0]['header']=='Q1'" "without header the id heads the question"
mkb dotted "d['questions'][0]['prefers']={'author':'a','critic':'b'}; d['questions'][0]['options'][0]['consequence']='Testável por e2e!'"
wfr brief plan --workflow-dir "$B" --file "$BD/dotted.json" >/dev/null
show_q "[o['description'] for o in d['questions'][0]['options']]==['Testável por e2e! Preferida pelo autor.','Depende do modelo. Preferida pelo crítico.']" "a consequence already ending in punctuation gets no extra dot"
mkb suffixed "d['questions'][0]['options'][0]['label']='No script (Recomendado)'"
wfr brief plan --workflow-dir "$B" --file "$BD/suffixed.json" >/dev/null
show_q "[o['label'] for o in d['questions'][0]['options']]==['No script (Recomendado)','Na skill']" "a label already ending in the recommended suffix does not get it twice"
mkb header "d['questions'][0]['header']='Regra parada'"
wfr brief plan --workflow-dir "$B" --file "$BD/header.json" >/dev/null
gate_ok "g['questions'][0]['header']=='Regra parada'" "brief keeps the header"
show_q "d['questions'][0]['header']=='Regra parada' and d['questions'][0]['id']=='Q1'" "the header replaces the id as the question header"
mkb longheader "d['questions'][0]['header']='Regra de parada'"
brief_refused "with a header above its cap" "questions[0].header: 15 caracteres, teto 12" --file "$BD/longheader.json"
mkb emptyheader "d['questions'][0]['header']=''"
brief_refused "with an empty header" "questions[0].header: precisa ser texto não vazio" --file "$BD/emptyheader.json"

echo "- wf-report: answer, rounds and show"
A=$(tmp); AD=$(tmp)
printf '{"feature":"Feat An","start_date":"2026-06-01T00:00:00Z"}' > "$A/current.json"
wfr stage-start plan --workflow-dir "$A"
mka() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); exec(sys.argv[2]); json.dump(d,open(sys.argv[3],'w'),ensure_ascii=False)" "$BRIEF_OK" "$2" "$AD/$1.json"; }
agate() {
  python3 -c "
import json,sys; g=[s for s in json.load(open(sys.argv[1]))['stages'] if s['stage']=='plan'][0]['gate']
assert $1, g" "$A/report.json" || fail "$2"
}
refused() {
  local label=$1 want=$2 got=0; shift 2
  report_snap "$A"
  wfr "$@" >/dev/null 2>"$AD/err" || got=$?
  [ "$got" = 2 ] || fail "$label: expected exit 2, got $got"
  report_untouched "$A" "$label"
  grep -qF -- "$want" "$AD/err" || fail "$label: stderr '$(cat "$AD/err")' lacks '$want'"
}
ans() { wfr answer plan --workflow-dir "$A" "$@"; }
STAMPED="__import__('re').fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ', g.get('decided_at') or '')"
pin_decided() {
  python3 -c "
import json,sys; r=json.load(open(sys.argv[1])); g=[s for s in r['stages'] if s['stage']=='plan'][0]['gate']
g['decided_at']='2000-01-01T00:00:00Z'; json.dump(r,open(sys.argv[1],'w'),indent=2)" "$1/report.json"
}
aq() { python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert $1, d" "$(wfr show plan --workflow-dir "$A")" || fail "$2"; }
mka two "d['questions'].append(dict(d['questions'][0], id='Q2', text='Quem grava o bloco?', prefers={'author':'a','critic':'b'}))"
printf 'Prefiro um terceiro caminho.\n' > "$AD/free.md"

wfr brief plan --workflow-dir "$A" --file "$AD/two.json" >/dev/null
aq "[o['label'] for o in d['questions'][0]['options']]==['No script (Recomendado)','Na skill']" "agreeing prefers keep (Recomendado)"
aq "not any('(Recomendado)' in o['label'] for o in d['questions'][1]['options'])" "diverging prefers drop (Recomendado)"
ans --question Q1 --option a
agate "g['status']=='open' and g['questions'][0]['answer']=='a' and g['questions'][1]['answer'] is None" "first of two answers keeps open"
aq "[q['id'] for q in d['questions']]==['Q2'] and 'Respostas:' in d['text_md'] and 'Onde fica a regra de parada? → No script' in d['text_md']" "show asks only the pending question and lists the recorded answer"
report_snap "$A"; ans --question Q1 --option a
report_untouched "$A" "the same answer again is a no-op"
refused "--approve with a pending question" "--approve: perguntas sem resposta: Q2" answer plan --workflow-dir "$A" --approve
refused "unknown question" "--question: Q9 não é pergunta do bloco" answer plan --workflow-dir "$A" --question Q9 --option a
refused "unknown option" "--option: z não é opção da pergunta" answer plan --workflow-dir "$A" --question Q2 --option z
refused "--text-file alone with questions" "--text-file sem --question só vale sem perguntas" answer plan --workflow-dir "$A" --text-file "$AD/free.md"
refused "--option without --question" "--option exige --question" answer plan --workflow-dir "$A" --option a
ans --question Q2 --option a
agate "g['status']=='approved'" "all answers equal to assumed approve the block"
agate "$STAMPED" "the answer that approves stamps decided_at"
pin_decided "$A"
aq "d['status']=='approved' and d['questions']==[]" "show of an approved block asks nothing"
report_snap "$A"; ans --question Q2 --option a
report_untouched "$A" "repeating a recorded answer on an approved block is a no-op"
agate "g['decided_at']=='2000-01-01T00:00:00Z'" "repeating the answer keeps decided_at"
refused "another answer on an approved block" "answer plan: bloco já está approved" answer plan --workflow-dir "$A" --question Q2 --option b
refused "--reject on an approved block" "bloco já está approved" answer plan --workflow-dir "$A" --reject

wfr brief plan --workflow-dir "$A" --file "$AD/two.json" >/dev/null
agate "g['status']=='open' and g['round']==1 and all(q['answer'] is None for q in g['questions'])" "round 1 brief over approved replaces it"
agate "'decided_at' not in g" "a replaced block starts without decided_at"
ans --question Q1 --option a
ans --question Q2 --option b
agate "g['status']=='revising' and 'decided_at' not in g" "an answer other than assumed leads to revising, with no decided_at"
F=$(tmp)
printf '{"feature":"Feat Ft","start_date":"2026-06-04T00:00:00Z"}' > "$F/current.json"
wfr stage-start plan --workflow-dir "$F"
wfr brief plan --workflow-dir "$F" --file "$AD/two.json" >/dev/null
wfr answer plan --workflow-dir "$F" --question Q2 --option a
wfr answer plan --workflow-dir "$F" --question Q1 --text-file "$AD/free.md"
python3 -c "
import json,sys; g=[s for s in json.load(open(sys.argv[1]))['stages'] if s['stage']=='plan'][0]['gate']
assert g['status']=='revising' and g['questions'][0]['answer']=={'text':'Prefiro um terceiro caminho.\n'}, g" "$F/report.json" || fail "free text counts as different from assumed"
ans --question Q1 --text-file "$AD/free.md"
ans --question Q2 --option a
agate "g['status']=='revising' and g['questions'][0]['answer']=={'text':'Prefiro um terceiro caminho.\n'}" "changing answers of a revising block re-evaluates the status"
aq "'texto livre: Prefiro um terceiro caminho.' in d['text_md']" "show lists free text answers"
refused "--approve on revising" "--approve: bloco revising, só vale com open" answer plan --workflow-dir "$A" --approve

refused "round 2 without changes" "changes: 0 linhas, a rodada 2 exige de 1 a 3" brief plan --workflow-dir "$A" --file "$BRIEF_OK"
mka r2dup "d['changes']=['Regra movida para o script']"
refused "round 2 reusing a history id" "questions[0].id: Q1 repetido (já usado em history, rodada 1)" brief plan --workflow-dir "$A" --file "$AD/r2dup.json"
mka r2 "d['changes']=['Regra movida para o script']; d['questions']=[dict(d['questions'][0], id='Q3')]"
wfr brief plan --workflow-dir "$A" --file "$AD/r2.json" >/dev/null
agate "g['round']==2 and g['status']=='open' and [q['id'] for q in g['questions']]==['Q3'] and g['questions'][0]['answer'] is None" "brief over revising writes round 2 with only the new questions"
agate "len(g['history'])==1 and g['history'][0]['round']==1 and [(q['id'],q['answer']) for q in g['history'][0]['questions']]==[('Q1',{'text':'Prefiro um terceiro caminho.\n'}),('Q2','a')]" "answered questions move to history[0] with their answers"
aq "d['round']==2 and 'Regra movida para o script' in d['text_md']" "show carries the round and the changes"
report_snap "$A"; wfr brief plan --workflow-dir "$A" --file "$AD/r2.json" >/dev/null
report_untouched "$A" "the same file over an open round 2 is a no-op"
refused "another file over an open round 2" "bloco open na rodada 2 só aceita o mesmo arquivo" brief plan --workflow-dir "$A" --file "$AD/two.json"
ans --question Q3 --option a
agate "g['status']=='approved' and g['round']==2" "round 2 approves"
agate "$STAMPED" "round 2 approval stamps decided_at"
pin_decided "$A"
refused "another file over an approved round 2" "bloco approved na rodada 2 só aceita o mesmo arquivo" brief plan --workflow-dir "$A" --file "$AD/r2dup.json"
report_snap "$A"; wfr brief plan --workflow-dir "$A" --file "$AD/r2.json" >/dev/null
report_untouched "$A" "the same file over an approved round 2 keeps the answers"
agate "g['decided_at']=='2000-01-01T00:00:00Z'" "the same file over an approved round 2 keeps decided_at"

python3 -c "
import json,sys; r=json.load(open(sys.argv[1])); g=[s for s in r['stages'] if s['stage']=='plan'][0]['gate']
g['status']='revising'; g['questions'][0]['answer']='b'
json.dump(r,open(sys.argv[1],'w'),indent=2)" "$A/report.json"
mka r3 "d['changes']=['Terceira rodada']; d['questions']=[dict(d['questions'][0], id='Q4')]"
wfr brief plan --workflow-dir "$A" --file "$AD/r3.json" >/dev/null
agate "g['round']==3 and [h['round'] for h in g['history']]==[1,2] and g['history'][1]['questions'][0]['id']=='Q3'" "round 3 appends to history"
ans --question Q4 --option b
agate "g['status']=='revising'" "round 3 diverges"
mka r4 "d['changes']=['Quarta rodada']; d['questions']=[dict(d['questions'][0], id='Q5')]"
refused "a fourth round" "rodadas esgotadas" brief plan --workflow-dir "$A" --file "$AD/r4.json"

mka noq "d['questions']=[]"
wfr brief plan --workflow-dir "$A" --file "$AD/noq.json" >/dev/null 2>&1 && fail "brief over revising round 3 must refuse"
printf "voltou" > "$AD/sum.md"; wfr stage-end plan --status blocked --workflow-dir "$A" --summary-file "$AD/sum.md" >/dev/null || fail "stage-end blocked"
wfr stage-start plan --workflow-dir "$A"
wfr brief plan --workflow-dir "$A" --file "$AD/r2.json" >/dev/null 2>&1 || fail "stage-start must clear a revising block that hit the round cap"
agate "g['round']==1" "brief after a capped block restarts at round 1"
python3 -c "
import json,sys; r=json.load(open(sys.argv[1])); s=[s for s in r['stages'] if s['stage']=='plan'][0]
s['gate']['status']='revising'; s['gate']['round']=3
r['stages'].append({'stage':'complete','status':'blocked','artifacts':[],'decisions':[],'gate':dict(s['gate'])})
json.dump(r,open(sys.argv[1],'w'),indent=2)" "$A/report.json"
wfr stage-start complete --workflow-dir "$A"
python3 -c "
import json,sys; s=[s for s in json.load(open(sys.argv[1]))['stages'] if s['stage']=='complete'][0]
assert s.get('gate',{}).get('status')=='revising' and s['gate']['round']==3, s" "$A/report.json" || fail "stage-start complete must keep a revising pr block at round 3"
R=$(tmp)
printf '{"feature":"Feat Rj","start_date":"2026-06-02T00:00:00Z"}' > "$R/current.json"
wfr stage-start plan --workflow-dir "$R"
wfr brief plan --workflow-dir "$R" --file "$AD/noq.json" >/dev/null
wfr answer plan --workflow-dir "$R" --text-file "$AD/free.md"
python3 -c "
import json,sys; g=[s for s in json.load(open(sys.argv[1]))['stages'] if s['stage']=='plan'][0]['gate']
assert g['status']=='revising' and g['answer']=={'text':'Prefiro um terceiro caminho.\n'}, g" "$R/report.json" || fail "--text-file alone adjusts a block without questions"
mka noq2 "d['questions']=[]; d['changes']=['Ajuste aplicado']"
wfr brief plan --workflow-dir "$R" --file "$AD/noq2.json" >/dev/null
python3 -c "
import json,sys; g=[s for s in json.load(open(sys.argv[1]))['stages'] if s['stage']=='plan'][0]['gate']
assert g['round']==2 and g['history']==[{'round':1,'questions':[],'answer':{'text':'Prefiro um terceiro caminho.\n'}}] and 'answer' not in g, g" "$R/report.json" || fail "the adjust text moves to history"
wfr answer plan --workflow-dir "$R" --approve
python3 -c "
import json,sys; g=[s for s in json.load(open(sys.argv[1]))['stages'] if s['stage']=='plan'][0]['gate']
assert g['status']=='approved' and $STAMPED, g" "$R/report.json" || fail "--approve without pending approves and stamps decided_at"
pin_decided "$R"
report_snap "$R"; wfr answer plan --workflow-dir "$R" --approve
report_untouched "$R" "--approve again keeps decided_at"
wfr brief plan --workflow-dir "$R" --file "$AD/noq.json" >/dev/null 2>&1 && fail "another file over approved round 2 must refuse"
R2=$(tmp)
printf '{"feature":"Feat Rj2","start_date":"2026-06-03T00:00:00Z"}' > "$R2/current.json"
wfr stage-start plan --workflow-dir "$R2"
wfr brief plan --workflow-dir "$R2" --file "$AD/two.json" >/dev/null
wfr answer plan --workflow-dir "$R2" --reject
python3 -c "
import json,sys; g=[s for s in json.load(open(sys.argv[1]))['stages'] if s['stage']=='plan'][0]['gate']
assert g['status']=='rejected' and $STAMPED, g" "$R2/report.json" || fail "--reject writes rejected and stamps decided_at"
pin_decided "$R2"
report_snap "$R2"; wfr answer plan --workflow-dir "$R2" --reject
report_untouched "$R2" "--reject again keeps decided_at"
R3=$(tmp)
printf '{"feature":"Feat Rj3","start_date":"2026-06-05T00:00:00Z"}' > "$R3/current.json"
wfr stage-start plan --workflow-dir "$R3"
wfr brief plan --workflow-dir "$R3" --file "$AD/noq.json" >/dev/null
pin_decided "$R3"
wfr answer plan --workflow-dir "$R3" --approve
python3 -c "
import json,sys; g=[s for s in json.load(open(sys.argv[1]))['stages'] if s['stage']=='plan'][0]['gate']
assert g['status']=='approved' and g['decided_at']=='2000-01-01T00:00:00Z', g" "$R3/report.json" || fail "a decided_at already on the block is never overwritten"
got=0; wfr answer plan --workflow-dir "$R2" --question Q1 --option a >/dev/null 2>&1 || got=$?
[ "$got" = 2 ] || fail "answer on a rejected block: expected exit 2, got $got"
got=0; wfr answer tasks --workflow-dir "$R2" --approve >/dev/null 2>"$AD/err" || got=$?
[ "$got" = 2 ] && grep -qF "answer tasks: bloco ausente" "$AD/err" || fail "answer without a block"

echo "- wf-report: glob_match is pure and shares glob_util with adr-index"
HOME="$HOME_BIN_SHIM" python3 - "$BIN/wf-report.py" "$BIN/glob_util.py" <<'PY' || fail "glob_match and check_glob"
import importlib.util, sys

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m

wr, gu = load("wf_report", sys.argv[1]), load("glob_util", sys.argv[2])
cases = {
    "star stays in one dir": ("bin/*.py", "bin/x/y.py", False),
    "star matches a file": ("bin/*.py", "bin/a.py", True),
    "double star crosses dirs": ("bin/**", "bin/x/y.py", True),
    "trailing slash is the whole tree": ("docs/", "docs/a/b.md", True),
    "trailing slash is not the dir itself": ("docs/", "docs", False),
    "trailing slash is not a sibling prefix": ("docs/", "docsx/a.md", False),
    "literal matches itself": ("README.md", "README.md", True),
    "literal is not a nested file": ("README.md", "docs/README.md", False),
    "literal is not a longer name": ("README.md", "README.mdx", False),
    "literal dot is not a wildcard": ("a.b", "axb", False),
    "leading **/ matches the root": ("**/test_*.py", "test_a.py", True),
    "leading **/ matches nested": ("**/test_*.py", "a/b/test_a.py", True),
    "question mark is one char": ("bin/?.py", "bin/ab.py", False),
    "class matches one of its chars": ("lib/[ab].dart", "lib/a.dart", True),
    "class is not a literal": ("lib/[ab].dart", "lib/[ab].dart", False),
    "class rejects other chars": ("lib/[ab].dart", "lib/c.dart", False),
    "class range": ("lib/[a-c].dart", "lib/b.dart", True),
    "negated class": ("lib/[!ab].dart", "lib/c.dart", True),
    "negated class rejects its chars": ("lib/[!ab].dart", "lib/a.dart", False),
    "negated class stays in one dir": ("lib[!a]x.dart", "lib/x.dart", False),
    "caret inside a class is a char": ("lib/[^a].dart", "lib/^.dart", True),
    "caret inside a class does not negate": ("lib/[^a].dart", "lib/b.dart", False),
    "braces are alternatives": ("lib/{x,y}.dart", "lib/y.dart", True),
    "braces reject the rest": ("lib/{x,y}.dart", "lib/z.dart", False),
    "braces are not a literal": ("lib/{x,y}.dart", "lib/{x,y}.dart", False),
    "wildcards inside braces": ("{lib,test}/**/*_{a,b*}.dart", "test/x/y_bz.dart", True),
    "braces with a trailing slash": ("{lib,test}/", "test/a/b.dart", True),
    "unclosed bracket is literal": ("lib/[ab.dart", "lib/[ab.dart", True),
    "empty class is literal": ("lib/[].dart", "lib/[].dart", True),
    "invalid range is literal": ("lib/[z-a].dart", "lib/[z-a].dart", True),
    "unclosed brace is literal": ("lib/{x,y.dart", "lib/{x,y.dart", True),
    "nested braces are literal": ("lib/{a,{b,c}}.dart", "lib/{a,{b,c}}.dart", True),
    "nested braces do not expand": ("lib/{a,{b,c}}.dart", "lib/a.dart", False),
}
for name, (glob, path, want) in cases.items():
    assert wr.glob_match(glob, path) is want, name
for glob, pattern in (("bin/*.py", r"^bin/[^/]*\.py$"), ("a?b", r"^a[^/]b$"), ("bin/**", r"^bin/.*$"),
                      ("**/x", r"^(?:.*/)?x$"), ("{x,y}", r"^(?:x|y)$"), ("[!ab]", r"^[^/ab]$")):
    assert gu.glob_re(glob).pattern == pattern, f"glob_re pattern: {glob}"
assert wr.glob_re.__module__ == "glob_util", "wf-report uses the glob_util glob_re"
assert gu.brace_end("{a,b}c", 0) == 4 and gu.brace_end("{a,b", 0) == 0, "brace_end"
assert gu.compiles("[ab]") and not gu.compiles("[z-a]"), "compiles"
for bad in ("", " ", "/etc/x", "a/../b", "..", "./bin/a.py", "bin\\a.py", "a" * 121):
    try:
        wr.check_glob("g", bad)
    except wr.InputError:
        continue
    raise AssertionError(f"check_glob accepted {bad!r}")
assert wr.check_glob("g", "bin/a..b.py") == "bin/a..b.py", "dots inside a name are not a .. segment"
PY

echo "- wf-report: a round 1 resend with a broken git keeps the previous map; list_changed times out"
FAKEGIT=$(tmp)
printf '#!/bin/sh\nsleep 30\n' > "$FAKEGIT/git"; chmod +x "$FAKEGIT/git"
HOME="$HOME_BIN_SHIM" FAKEGIT="$FAKEGIT" python3 - "$BIN/wf-report.py" <<'PY' || fail "pr_map_refs round 1 and list_changed timeout"
import importlib.util, os, sys, time

spec = importlib.util.spec_from_file_location("wf_report", sys.argv[1])
wr = importlib.util.module_from_spec(spec); spec.loader.exec_module(wr)

refs = {"base": "b1", "tree": "t1"}
prev_map = {"summary": "anterior", "nodes": [], "edges": []}
plan_block = {"map": {"summary": "plano", "nodes": [], "edges": []}}
report = {"stages": [{"stage": wr.GATE_OWNER["plan"], "gate": plan_block},
                     {"stage": wr.GATE_OWNER["pr"], "gate": dict(refs, round=1, status="open", map=prev_map)}]}
got, reason = wr.pr_map_refs(report, dict(refs), None, "git indisponível")
assert got == dict(refs, map=prev_map) and reason is None, (got, reason)

wr.GIT_TIMEOUT = 1
os.environ["PATH"] = os.environ["FAKEGIT"] + os.pathsep + os.environ["PATH"]
start = time.monotonic()
files, why = wr.list_changed(os.environ["FAKEGIT"], "a", "b")
assert files is None and "git diff passou de" in why, (files, why)
assert time.monotonic() - start < 5, "list_changed did not honor GIT_TIMEOUT"
PY

echo "- wf-report: plan map contract, refusals, drop-map and rounds"
M=$(tmp); MD=$(tmp)
printf '{"feature":"Feat Map","start_date":"2026-06-10T00:00:00Z"}' > "$M/current.json"
for st in challenge tasks plan; do wfr stage-start "$st" --workflow-dir "$M"; done
cat > "$MD/fullmap.json" <<'JSON'
{"summary": "Três peças, uma de cada estado.",
 "nodes": [{"id": "mapa", "label": "Mapa construído", "state": "new", "note": "Sai do diff", "paths": ["bin/**", "docs/"]},
           {"id": "gate", "label": "Gate do plano", "state": "changed", "paths": ["bin/wf-report.py"]},
           {"id": "app", "label": "App", "state": "existing"}],
 "edges": [{"from": "gate", "to": "mapa", "label": "grava"}, {"from": "mapa", "to": "app", "label": "lido por"}],
 "approaches": [{"id": "a1", "label": "No script", "text": "Calcula do diff", "chosen": true},
                {"id": "a2", "label": "No agente", "text": "Descreve o diff", "chosen": false}],
 "gains": ["Determinístico"], "costs": ["Roda git no gate"], "ignore": ["tests/**", "app/test/fixtures/"]}
JSON
mkm() { python3 -c "
import json,sys
d=json.load(open(sys.argv[1])); d['map']=json.load(open(sys.argv[2])); m=d['map']
exec(sys.argv[3]); json.dump(d,open(sys.argv[4],'w'),ensure_ascii=False)" "$BRIEF_OK" "$MD/fullmap.json" "$2" "$MD/$1.json"; }
mgate() {
  python3 -c "
import json,sys; g=[s for s in json.load(open(sys.argv[1]))['stages'] if s['stage']=='plan'][0]['gate']
full=json.load(open(sys.argv[2]))
assert $1, g" "${3:-$M}/report.json" "$MD/fullmap.json" || fail "$2"
}
mshow() { python3 -c "import json,sys; t=json.loads(sys.argv[1])['text_md']; assert $1, t" "$(wfr show plan --workflow-dir "${3:-$M}")" || fail "$2"; }
map_refused() {
  local label=$1 want=$2 got=0; shift 2
  report_snap "$M"
  wfr brief "$@" >/dev/null 2>"$MD/err" || got=$?
  [ "$got" = 2 ] || fail "map $label: expected exit 2, got $got"
  report_untouched "$M" "map $label"
  grep -qF -- "$want" "$MD/err" || fail "map $label: stderr '$(cat "$MD/err")' lacks '$want'"
  case "$(cat "$MD/err")" in "wf-report: map"*) ;; *) fail "map $label: refusal does not start with 'wf-report: map'" ;; esac
}
mkm full ""
wfr brief plan --workflow-dir "$M" --file "$MD/full.json" >/dev/null
mgate "g['map']==full" "a complete map is written with every field"
mshow "'\n\nArquitetura:\nTrês peças, uma de cada estado.\n- Mapa construído (nova)\n- Gate do plano (muda)\n- App (já existe)\n- No script: Calcula do diff (escolhida)\n- No agente: Descreve o diff\n' in t" "show plan lists pieces and approaches under Arquitetura:"
mshow "t.count('(escolhida)')==1 and t.index('Arquitetura:') < t.index('Riscos:')" "only the chosen approach is marked, right after the summary"

mkm nopaths "del m['nodes'][0]['paths']"
map_refused "new node without paths" "map.nodes[0].paths: obrigatório em peça new" plan --workflow-dir "$M" --file "$MD/nopaths.json"
mkm nopaths-changed "del m['nodes'][1]['paths']"
map_refused "changed node without paths" "map.nodes[1].paths: obrigatório em peça changed" plan --workflow-dir "$M" --file "$MD/nopaths-changed.json"
BAD_GLOBS=("''" "'/abs/x.py'" "'bin/../x.py'" "'./bin/a.py'" "'bin'+chr(92)+'a.py'" "'a'*121")
for i in "${!BAD_GLOBS[@]}"; do
  mkm "glob$i" "m['nodes'][0]['paths'][0]=${BAD_GLOBS[$i]}"
  map_refused "bad glob ${BAD_GLOBS[$i]}" "map.nodes[0].paths[0]: " plan --workflow-dir "$M" --file "$MD/glob$i.json"
done
mkm p7 "m['nodes'][0]['paths']=[f'bin/{i}.py' for i in range(7)]"
map_refused "7 globs" "map.nodes[0].paths: 7 globs, teto 6" plan --workflow-dir "$M" --file "$MD/p7.json"
mkm p0 "m['nodes'][0]['paths']=[]"
map_refused "0 globs" "map.nodes[0].paths: 0 globs, precisa de 1 a 6" plan --workflow-dir "$M" --file "$MD/p0.json"
mkm slash "m['nodes'][0]['label']='bin/wf-report.py'"
map_refused "label with a slash" "map.nodes[0].label: caminho de arquivo" plan --workflow-dir "$M" --file "$MD/slash.json"
mkm dupid "m['nodes'][1]['id']='mapa'"
map_refused "repeated node id" "map.nodes[1].id: mapa repetido" plan --workflow-dir "$M" --file "$MD/dupid.json"
mkm unplanned "m['nodes'][0]['id']='unplanned:bin'"
map_refused "node id starting with unplanned:" "map.nodes[0].id: unplanned:bin começa com unplanned:" plan --workflow-dir "$M" --file "$MD/unplanned.json"
mkm elabel "m['edges'][0]['label']='e'*61"
map_refused "edge label of 61 chars" "map.edges[0].label: 61 caracteres, teto 60" plan --workflow-dir "$M" --file "$MD/elabel.json"
mkm alabel "m['approaches'][0]['label']='a'*41"
map_refused "approach label of 41 chars" "map.approaches[0].label: 41 caracteres, teto 40" plan --workflow-dir "$M" --file "$MD/alabel.json"
mkm chosen2 "m['approaches'][1]['chosen']=True"
map_refused "two chosen approaches" "map.approaches: 2 escolhidas" plan --workflow-dir "$M" --file "$MD/chosen2.json"
mkm chosen0 "m['approaches'][0]['chosen']=False"
map_refused "no chosen approach" "map.approaches: 0 escolhidas" plan --workflow-dir "$M" --file "$MD/chosen0.json"
mkm a4 "m['approaches']+=[dict(m['approaches'][1], id=f'a{i}') for i in (3, 4)]"
map_refused "4 approaches" "map.approaches: 4 formas, teto 3" plan --workflow-dir "$M" --file "$MD/a4.json"
mkm gains4 "m['gains']=['Ganho']*4"
map_refused "4 gains" "map.gains: 4 itens, teto 3" plan --workflow-dir "$M" --file "$MD/gains4.json"
mkm cost161 "m['costs'][0]='c'*161"
map_refused "cost of 161 chars" "map.costs[0]: 161 caracteres, teto 160" plan --workflow-dir "$M" --file "$MD/cost161.json"
mkm ignore11 "m['ignore']=[f'x{i}/' for i in range(11)]"
map_refused "11 ignore globs" "map.ignore: 11 globs, teto 10" plan --workflow-dir "$M" --file "$MD/ignore11.json"
mkm ignorebad "m['ignore'][0]='./tests/'"
map_refused "ignore glob with ./" "map.ignore[0]: glob com prefixo ./" plan --workflow-dir "$M" --file "$MD/ignorebad.json"
mkm order "m['gains']=['Ganho']*4; del m['nodes'][0]['paths']"
map_refused "nodes before gains" "map.nodes[0].paths" plan --workflow-dir "$M" --file "$MD/order.json"
map_refused "Phase 1: 9 nodes" "map.nodes: 9 nós, teto 8" plan --workflow-dir "$M" --file "$BD/m9.json"
map_refused "Phase 1: edge to a missing node" "map.edges[0].to: zz não é nó do mapa" plan --workflow-dir "$M" --file "$BD/edge.json"
map_refused "Phase 1: state outside the enum" "map.nodes[0].state: gone fora de new|changed|existing" plan --workflow-dir "$M" --file "$BD/state.json"
map_refused "brief spec with map" "map: só vale no gate plan" spec --workflow-dir "$M" --file "$MD/full.json"
map_refused "brief tasks with map" "map: só vale no gate plan" tasks --workflow-dir "$M" --file "$MD/full.json"
report_snap "$M"; got=0; wfr brief tasks --workflow-dir "$M" --file "$BRIEF_OK" --drop-map >/dev/null 2>"$MD/err" || got=$?
[ "$got" = 2 ] && grep -qF -- "--drop-map: só vale no gate plan" "$MD/err" || fail "--drop-map outside the plan gate"
report_untouched "$M" "--drop-map outside the plan gate"

wfr brief plan --workflow-dir "$M" --file "$MD/nopaths.json" --drop-map >/dev/null || fail "--drop-map with an invalid map exits 0"
mgate "'map' not in g and g['status']=='open'" "--drop-map writes the block without map"
mshow "'Arquitetura:' not in t" "no map, no Arquitetura:"
wfr brief plan --workflow-dir "$M" --file "$MD/full.json" >/dev/null
wfr brief plan --workflow-dir "$M" --file "$BRIEF_OK" >/dev/null
mgate "'map' not in g" "brief plan without map is accepted and drops the previous map"
mshow "'Arquitetura:' not in t" "brief plan without map shows no Arquitetura:"

mkm r2map "d['changes']=['Mapa revisto']; d['questions']=[dict(d['questions'][0], id='Q2')]; m['summary']='Revisto.'"
mkm r2nomap "d['changes']=['Mapa removido']; d['questions']=[dict(d['questions'][0], id='Q2')]; del d['map']"
for r2 in r2map r2nomap; do
  MR=$(tmp)
  printf '{"feature":"Feat MR","start_date":"2026-06-11T00:00:00Z"}' > "$MR/current.json"
  wfr stage-start plan --workflow-dir "$MR"
  wfr brief plan --workflow-dir "$MR" --file "$MD/full.json" >/dev/null
  wfr answer plan --workflow-dir "$MR" --question Q1 --option b
  mgate "g['status']=='revising'" "round 1 with map goes to revising" "$MR"
  wfr brief plan --workflow-dir "$MR" --file "$MD/$r2.json" >/dev/null
  if [ "$r2" = r2map ]; then
    mgate "g['round']==2 and g['map']==dict(full, summary='Revisto.')" "round 2 over revising keeps the map of its file" "$MR"
  else
    mgate "g['round']==2 and 'map' not in g" "round 2 without map does not inherit the round 1 map" "$MR"
  fi
done

echo "- wf-report: pr change reopens the cycle"
P=$(tmp); PD=$(tmp)
BASE=1111111111111111111111111111111111111111
TREE=2222222222222222222222222222222222222222
cat > "$P/current.json" <<JSON
{"feature":"Feat Pr","start_date":"2026-07-01T00:00:00Z","exec":{"base_checkpoint":"$BASE"},
 "tasks":{"total":1,"completed":1,"items":[{"id":"T1","title":"Base","description":"**Contexto:** c\n**O que fazer:** f\n**Testes:** t\n**Concluído quando:** d",
  "complexity":"S","risk":"low","tier0":"haiku","affects":["bin/x.py"],"tests":[],"status":"done"}]}}
JSON
printf '# Tasks\n\n- [x] `S` `haiku` #T1 — Base\n' > "$P/tasks.md"
printf '%s\n' "$TREE" > "$PD/pr.tree"
printf 'not-a-sha\n' > "$PD/bad.tree"
wfr stage-start complete --workflow-dir "$P"
cat > "$PD/pr.json" <<'JSON'
{"summary": "Dois pontos do diff.", "artifact": "pr.diff",
 "questions": [
  {"id": "Q1", "text": "O lock do reopen está certo?", "why": "Inverter a ordem trava o relatório",
   "anchor": {"path": "bin/wf-report.py", "start": 10, "end": 20},
   "options": [{"id": "ok", "label": "Está ok", "consequence": "Segue para o PR"},
               {"id": "change", "label": "Mudar", "consequence": "Vira task P"}],
   "assumed": "ok", "prefers": {"author": "ok", "critic": "ok"}},
  {"id": "Q2", "text": "O nome do campo serve?", "why": "O app lê o campo",
   "anchor": {"path": "bin/b.py", "start": 3, "end": 3},
   "options": [{"id": "ok", "label": "Está ok", "consequence": "Segue para o PR"},
               {"id": "change", "label": "Mudar", "consequence": "Vira task P"}],
   "assumed": "ok"},
  {"id": "Q3", "text": "A mensagem de erro basta?", "why": "O crítico reenvia o stderr",
   "anchor": {"path": "tests/bin.test.sh", "start": 1, "end": 2},
   "options": [{"id": "ok", "label": "Está ok", "consequence": "Segue para o PR"},
               {"id": "change", "label": "Renomear", "consequence": "Nome curto"}],
   "assumed": "ok"}]}
JSON
mkp() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); exec(sys.argv[2]); json.dump(d,open(sys.argv[3],'w'),ensure_ascii=False)" "$PD/pr.json" "$2" "$PD/$1.json"; }
pgate() {
  python3 -c "
import json,sys; g=[s for s in json.load(open(sys.argv[1]))['stages'] if s['stage']=='complete'][0].get('gate')
assert $1, g" "$P/report.json" || fail "$2"
}
prefused() {
  local label=$1 want=$2 got=0; shift 2
  report_snap "$P"
  wfr "$@" >/dev/null 2>"$PD/err" || got=$?
  [ "$got" = 2 ] || fail "$label: expected exit 2, got $got"
  report_untouched "$P" "$label"
  grep -qF -- "$want" "$PD/err" || fail "$label: stderr '$(cat "$PD/err")' lacks '$want'"
}
prefused "brief pr without --tree" "--tree: obrigatório no gate pr" brief pr --workflow-dir "$P" --file "$PD/pr.json"
prefused "brief pr with a typed sha" "--tree: obrigatório no gate pr" brief pr --workflow-dir "$P" --file "$PD/pr.json" --tree "$TREE"
prefused "brief pr with a bad tree file" "não contém um sha de 40 hex" brief pr --workflow-dir "$P" --file "$PD/pr.json" --tree "@$PD/bad.tree"
prefused "--tree outside the pr gate" "--tree: só vale no gate pr" brief plan --workflow-dir "$P" --file "$BRIEF_OK" --tree "@$PD/pr.tree"
mkp nowhy "del d['questions'][1]['why']"
prefused "pr question without why" "questions[1].why: precisa ser texto não vazio" brief pr --workflow-dir "$P" --file "$PD/nowhy.json" --tree "@$PD/pr.tree"
mkp longwhy "d['questions'][0]['why']='w'*161"
prefused "why above its cap" "questions[0].why: 161 caracteres, teto 160" brief pr --workflow-dir "$P" --file "$PD/longwhy.json" --tree "@$PD/pr.tree"
mkp anchor "d['questions'][0]['anchor']['start']=30"
prefused "anchor start after end" "questions[0].anchor: start 30 maior que end 20" brief pr --workflow-dir "$P" --file "$PD/anchor.json" --tree "@$PD/pr.tree"
mkp noanchor "del d['questions'][2]['anchor']"
prefused "pr question without anchor" "questions[2].anchor: precisa ser objeto" brief pr --workflow-dir "$P" --file "$PD/noanchor.json" --tree "@$PD/pr.tree"
mkp opts "d['questions'][0]['options'][1]['id']='fix'; d['questions'][0]['prefers']={}"
prefused "pr options other than ok and change" "no gate pr são exatamente ok e change" brief pr --workflow-dir "$P" --file "$PD/opts.json" --tree "@$PD/pr.tree"
mkp assumed "d['questions'][0]['assumed']='change'"
prefused "pr assumed other than ok" "questions[0].assumed: change; no gate pr é sempre ok" brief pr --workflow-dir "$P" --file "$PD/assumed.json" --tree "@$PD/pr.tree"
python3 -c "
import json,sys; c=json.load(open(sys.argv[1])); c['exec']={}; json.dump(c,open(sys.argv[2],'w'))" "$P/current.json" "$PD/nobase.json"
cp "$P/current.json" "$PD/current.keep"; cp "$PD/nobase.json" "$P/current.json"
prefused "brief pr without exec.base_checkpoint" "exec.base_checkpoint" brief pr --workflow-dir "$P" --file "$PD/pr.json" --tree "@$PD/pr.tree"
cp "$PD/current.keep" "$P/current.json"

wfr brief pr --workflow-dir "$P" --file "$PD/pr.json" --tree "@$PD/pr.tree" >/dev/null
pgate "g['round']==1 and g['status']=='open' and g['base']=='$BASE' and g['tree']=='$TREE'" "brief pr records base from current.json and tree from the file"
pgate "g['questions'][0]['why']=='Inverter a ordem trava o relatório' and g['questions'][0]['anchor']=={'path':'bin/wf-report.py','start':10,'end':20}" "brief pr keeps why and anchor"
pshow() { python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert $1, d" "$(wfr show pr --workflow-dir "$P")" || fail "$2"; }
pshow "d['questions'][0]['why']=='Inverter a ordem trava o relatório' and d['questions'][0]['anchor']=={'path':'bin/wf-report.py','start':10,'end':20}" "show pr carries why and anchor on each question"
pshow "'Pontos:\n- Q1 \`bin/wf-report.py:10-20\`: Inverter a ordem trava o relatório\n- Q2 \`bin/b.py:3-3\`: O app lê o campo\n' in d['text_md']" "show pr lists the pending points with path, lines and why"
wfr show plan --workflow-dir "$B" | grep -q 'Pontos:' && fail "Pontos: only in the pr gate"
prefused "reopen pr on an open block" "reopen pr: bloco open, só vale com revising" reopen pr --workflow-dir "$P"
printf 'Inverter a ordem dos locks no reopen.\n' > "$PD/change.md"
wfr answer pr --workflow-dir "$P" --question Q1 --text-file "$PD/change.md"
wfr answer pr --workflow-dir "$P" --question Q2 --option ok
wfr answer pr --workflow-dir "$P" --question Q3 --option change
pgate "g['status']=='revising'" "a change answer leaves the pr block revising"
cp "$P/current.json" "$PD/c0.json"; cp "$P/tasks.md" "$PD/t0.md"
prefused "reopen pr with a change answer without text" "resposta change sem texto do ajuste em Q3" reopen pr --workflow-dir "$P"
cmp -s "$P/current.json" "$PD/c0.json" && cmp -s "$P/tasks.md" "$PD/t0.md" || fail "a refused reopen leaves current.json and tasks.md intact"
printf 'Encurtar a mensagem para caber no stderr do crítico.\n' > "$PD/q3.md"
prefused "text with option ok" "o texto do ajuste só vale no gate pr com change" answer pr --workflow-dir "$P" --question Q2 --option ok --text-file "$PD/q3.md"
prefused "text with approve" "--text-file não vai com --approve/--reject" answer pr --workflow-dir "$P" --approve --text-file "$PD/q3.md"
wfr answer pr --workflow-dir "$P" --question Q3 --option change --text-file "$PD/q3.md"
pgate "g['status']=='revising' and g['questions'][2]['answer']=='change' and g['questions'][2]['answer_text']=='Encurtar a mensagem para caber no stderr do crítico.\n'" "answer pr records the change option and its text together"
report_snap "$P"
wfr answer pr --workflow-dir "$P" --question Q3 --option change --text-file "$PD/q3.md"
report_untouched "$P" "repeating option and text is a no-op"
wfr show pr --workflow-dir "$P" | grep -qF 'Renomear: Encurtar a mensagem' || fail "show renders the change text next to the label"

report_snap "$P"
OUT=$(wfr reopen pr --workflow-dir "$P")
report_untouched "$P" "reopen pr never writes report.json"
[ "$OUT" = '{"tasks":["P1.1","P1.2"],"added":["P1.1","P1.2"]}' ] || fail "reopen prints the tasks and the added ids: $OUT"
python3 -c "
import json,sys; t=json.load(open(sys.argv[1]))['tasks']; it={x['id']:x for x in t['items']}
assert [x['id'] for x in t['items']]==['T1','P1.1','P1.2'] and t['total']==3, t
p=it['P1.1']
assert (p['status'],p['risk'],p['complexity'],p['tier0'],p['tier'],p['attempts'],p['tests'],p['affects'])==('pending','high','M','opus','opus',0,[],['bin/wf-report.py']), p
assert 'Inverter a ordem trava o relatório' in p['description'] and 'Inverter a ordem dos locks no reopen.' in p['description'], p['description']
q=it['P1.2']
assert q['affects']==['tests/bin.test.sh'] and 'O crítico reenvia o stderr' in q['description'], q
assert '**O que fazer:**\nEncurtar a mensagem para caber no stderr do crítico.\n\n' in q['description'] and 'Nome curto' not in q['description'], q['description']
" "$P/current.json" || fail "reopen pr appends P1.1 and P1.2 for the answers other than ok"
grep -qF '#P1.1 — Ajuste do gate pr: O lock do reopen está certo?' "$P/tasks.md" || fail "reopen pr appends P1.1 to tasks.md"
grep -qF '#P1.2 — ' "$P/tasks.md" && ! grep -q '#P1\.3' "$P/tasks.md" || fail "only change answers become tasks in tasks.md"
HOME="$HOME_BIN_SHIM" python3 "$BIN/wf_gate.py" tasks-check --workflow-dir "$P" >/dev/null || fail "tasks-check accepts the P tasks"
cp "$P/current.json" "$PD/c1.json"; cp "$P/tasks.md" "$PD/t1.md"
OUT=$(wfr reopen pr --workflow-dir "$P")
[ "$OUT" = '{"tasks":["P1.1","P1.2"],"added":[]}' ] || fail "repeated reopen adds nothing: $OUT"
cmp -s "$P/current.json" "$PD/c1.json" && cmp -s "$P/tasks.md" "$PD/t1.md" || fail "repeated reopen does not duplicate"
printf 'PR travado por ajuste.\n' > "$PD/sum.md"
wfr stage-end complete --workflow-dir "$P" --summary-file "$PD/sum.md" --status blocked >/dev/null
python3 -c "
import json,sys; r=json.load(open(sys.argv[1])); s=[x for x in r['stages'] if x['stage']=='complete'][0]
assert 'pr' not in r and s['status']=='blocked', (r.get('pr'), s['status'])" "$P/report.json" || fail "no pr in the report and complete blocked"

wfr stage-start complete --workflow-dir "$P"
pgate "g is not None and g['status']=='revising' and g['round']==1" "stage-start keeps a revising block"
mkp r2 "d['changes']=['Locks na ordem report e current']; d['questions']=[dict(d['questions'][0], id='Q4')]"
wfr brief pr --workflow-dir "$P" --file "$PD/r2.json" --tree "@$PD/pr.tree" >/dev/null
pgate "g['round']==2 and g['status']=='open' and g['history'][0]['round']==1 and [q['id'] for q in g['history'][0]['questions']]==['Q1','Q2','Q3']" "the next brief writes round 2 with history"

printf 'Trocar a ordem também no brief.\n' > "$PD/q4.md"
wfr answer pr --workflow-dir "$P" --question Q4 --option change --text-file "$PD/q4.md"
pgate "g['status']=='revising' and g['round']==2" "a change answer in round 2 leaves the block revising"
OUT=$(wfr reopen pr --workflow-dir "$P")
[ "$OUT" = '{"tasks":["P2.1"],"added":["P2.1"]}' ] || fail "reopen in round 2 numbers the task P2.1: $OUT"
python3 -c "
import json,sys; t=json.load(open(sys.argv[1]))['tasks']
assert [x['id'] for x in t['items']]==['T1','P1.1','P1.2','P2.1'] and t['total']==4, t
p=t['items'][3]
assert 'rodada 2' in p['description'] and 'Trocar a ordem também no brief.' in p['description'], p['description']
" "$P/current.json" || fail "reopen in round 2 appends P2.1 without duplicating P1.*"
for id in P1.1 P1.2 P2.1; do
  [ "$(grep -cF "#$id — " "$P/tasks.md")" = 1 ] || fail "tasks.md carries #$id exactly once after the round 2 reopen"
done
wfr answer pr --workflow-dir "$P" --question Q4 --option ok
pgate "g['status']=='approved' and g['round']==2 and 'answer_text' not in g['questions'][0]" "a revising block returns to approved when every answer equals assumed"
python3 -c "
import json,sys; r=json.load(open(sys.argv[1])); [s for s in r['stages'] if s['stage']=='complete'][0]['gate']['status']='passed'
json.dump(r,open(sys.argv[1],'w'),indent=2)" "$P/report.json"
prefused "answer on a passed block" "answer pr: bloco já está passed" answer pr --workflow-dir "$P" --question Q4 --option change --text-file "$PD/q4.md"
wfr stage-start complete --workflow-dir "$P"
pgate "g is None" "stage-start drops a passed block"

PN=$(tmp)
cp "$PD/current.keep" "$PN/current.json"
printf '# Tasks\n\n- [x] `S` `haiku` #T1 — Base\n' > "$PN/tasks.md"
wfr stage-start complete --workflow-dir "$PN"
mkp noq "d['questions']=[]"
wfr brief pr --workflow-dir "$PN" --file "$PD/noq.json" --tree "@$PD/pr.tree" >/dev/null
wfr answer pr --workflow-dir "$PN" --text-file "$PD/change.md"
cp "$PN/current.json" "$PD/cn.json"; cp "$PN/tasks.md" "$PD/tn.md"
report_snap "$PN"; got=0
wfr reopen pr --workflow-dir "$PN" >/dev/null 2>"$PD/err" || got=$?
[ "$got" = 2 ] && grep -qF "nenhuma pergunta com resposta diferente de ok" "$PD/err" || fail "reopen pr on a revising block without a change answer exits 2 (got $got)"
report_untouched "$PN" "reopen pr without a change answer"
cmp -s "$PN/current.json" "$PD/cn.json" && cmp -s "$PN/tasks.md" "$PD/tn.md" || fail "reopen pr without a change answer leaves current.json and tasks.md intact"

PX=$(tmp)
cp "$PD/current.keep" "$PX/current.json"
printf '# Tasks\n\n- [x] `S` `haiku` #T1 — Base\n- [ ] `M` `opus` #P1.10 — Ajuste anterior\n' > "$PX/tasks.md"
wfr stage-start complete --workflow-dir "$PX"
wfr brief pr --workflow-dir "$PX" --file "$PD/pr.json" --tree "@$PD/pr.tree" >/dev/null
wfr answer pr --workflow-dir "$PX" --question Q1 --option change --text-file "$PD/change.md"
wfr answer pr --workflow-dir "$PX" --question Q2 --option ok
wfr answer pr --workflow-dir "$PX" --question Q3 --option ok
OUT=$(wfr reopen pr --workflow-dir "$PX")
[ "$OUT" = '{"tasks":["P1.1"],"added":["P1.1"]}' ] || fail "reopen next to #P1.10 adds P1.1: $OUT"
grep -qF '#P1.1 — Ajuste do gate pr: O lock do reopen está certo?' "$PX/tasks.md" || fail "#P1.10 in tasks.md is not taken for #P1.1"
grep -qF '#P1.10 — Ajuste anterior' "$PX/tasks.md" || fail "the #P1.10 line is kept"
wfr stage-start plan --workflow-dir "$B"
python3 -c "
import json,sys; s=[x for x in json.load(open(sys.argv[1]))['stages'] if x['stage']=='plan'][0]
assert 'gate' not in s, s" "$B/report.json" || fail "stage-start drops an open block of its own stage"

echo "- wf-report: built_map is pure"
HOME="$HOME_BIN_SHIM" python3 - "$BIN/wf-report.py" <<'PY' || fail "built_map"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("wf_report", sys.argv[1])
wr = importlib.util.module_from_spec(spec); spec.loader.exec_module(wr)

def node(nid, state, *paths, **extra):
    n = {"id": nid, "label": nid.upper(), "state": state, **extra}
    if paths:
        n["paths"] = list(paths)
    return n

def by_id(m):
    return {n["id"]: n for n in m["nodes"]}

def assert_(cond):
    assert cond

def case(name, plan, files, check):
    m = wr.built_map(plan, files)
    try:
        check(m, by_id(m))
    except AssertionError as e:
        raise AssertionError(f"{name}: {e or ''} {m}")

plan = {"nodes": [node("n", "new", "bin/n/**", note="Nova"), node("c", "changed", "bin/c.py"),
                  node("e1", "existing", "lib/"), node("e2", "existing")],
        "edges": [{"from": "n", "to": "e1", "label": "usa"}],
        "approaches": [{"id": "a", "label": "A", "text": "t", "chosen": True}],
        "gains": ["g"], "costs": ["c"], "ignore": ["tests/**"]}
case("each state", plan, ["lib/y.py", "bin/n/x.py", "tools/z.sh", "README.md", "tests/t.sh"], lambda m, b: (
    assert_(b["n"]["built"] == "planned" and b["n"]["files"] == ["bin/n/x.py"]),
    assert_(b["c"]["built"] == "untouched" and b["c"]["files"] == []),
    assert_(b["e1"]["built"] == "touched" and b["e1"]["files"] == ["lib/y.py"]),
    assert_(b["e2"]["built"] == "existing" and "paths" not in b["e2"]),
    assert_([n["id"] for n in m["nodes"]] == ["n", "c", "e1", "e2", "unplanned:.", "unplanned:tools"]),
    assert_(b["unplanned:."] == {"id": "unplanned:.", "label": ".", "built": "unplanned", "files": ["README.md"]}),
    assert_(b["unplanned:tools"]["label"] == "tools" and "state" not in b["unplanned:tools"]),
    assert_(m["summary"] == "1 como planejado, 2 fora do plano, 1 sem tocar."),
))
case("copies state, note, paths and edges; drops approaches, gains, costs and ignore", plan, [], lambda m, b: (
    assert_(set(m) == {"summary", "nodes", "edges"} and m["edges"] == plan["edges"]),
    assert_(b["n"]["state"] == "new" and b["n"]["note"] == "Nova" and b["n"]["paths"] == ["bin/n/**"]),
    assert_(m["summary"] == "0 como planejado, 0 fora do plano, 2 sem tocar."),
))
case("paths win over ignore; ignore alone hides the file",
     {"nodes": [node("n", "new", "bin/n/**")], "ignore": ["bin/**"]}, ["bin/n/g.py", "bin/other.py"],
     lambda m, b: assert_([n["id"] for n in m["nodes"]] == ["n"] and b["n"]["files"] == ["bin/n/g.py"]))
case("a file matching two pieces goes to the first",
     {"nodes": [node("a", "new", "bin/a.py"), node("all", "existing", "bin/**")]}, ["bin/a.py", "bin/b.py"],
     lambda m, b: assert_(b["a"]["files"] == ["bin/a.py"] and b["all"]["files"] == ["bin/b.py"]
                          and b["all"]["built"] == "touched"))
dirs = {"d4": 4, "d3": 3, "d2": 2, "d1": 1}
loose = [f"{d}/f{i}.py" for d, k in dirs.items() for i in range(k)]
six = {"nodes": [node(f"p{i}", "new", f"p{i}/") for i in range(6)]}
case("6 pieces and 4 dirs: 7th is the biggest dir, 8th is outros", six, loose, lambda m, b: (
    assert_(len(m["nodes"]) == 8),
    assert_(m["nodes"][6]["id"] == "unplanned:d4" and len(m["nodes"][6]["files"]) == 4),
    assert_(m["nodes"][7] == {"id": "unplanned:outros", "label": "outros", "built": "unplanned",
                              "files": sorted(f for f in loose if not f.startswith("d4/"))}),
    assert_(len(m["nodes"][7]["files"]) == 6),
    assert_(m["summary"] == "0 como planejado, 2 fora do plano, 6 sem tocar."),
))
case("7 pieces and 1 dir: the dir fits without outros",
     {"nodes": [node(f"p{i}", "new", f"p{i}/") for i in range(7)]}, ["x/a.py", "x/b.py"],
     lambda m, b: assert_([n["id"] for n in m["nodes"]][7:] == ["unplanned:x"]))
case("8 pieces and 1 file outside: 9 pieces, the last one its dir",
     {"nodes": [node(f"p{i}", "new", f"p{i}/") for i in range(8)]}, ["out/a.py"],
     lambda m, b: assert_(len(m["nodes"]) == 9 and m["nodes"][8]["id"] == "unplanned:out"))
case("8 pieces and 2 dirs: one slot, everything goes to outros",
     {"nodes": [node(f"p{i}", "new", f"p{i}/") for i in range(8)]}, ["a/1.py", "b/1.py", "b/2.py"],
     lambda m, b: assert_([n["id"] for n in m["nodes"]][8:] == ["unplanned:outros"]
                          and m["nodes"][8]["files"] == ["a/1.py", "b/1.py", "b/2.py"]))
def single_outros(m, rest):
    ids = [n["id"] for n in m["nodes"]]
    assert_(len(ids) == len(set(ids)) and ids.count("unplanned:outros") == 1)
    assert_(m["nodes"][-1] == {"id": "unplanned:outros", "label": "outros", "built": "unplanned",
                               "files": sorted(rest)})
outros_big = ["outros/1.py", "outros/2.py", "outros/3.py", "a/1.py", "b/1.py"]
case("a kept dir named outros joins the folded tail", six, outros_big, lambda m, b: (
    assert_([n["id"] for n in m["nodes"]][6:] == ["unplanned:a", "unplanned:outros"]),
    single_outros(m, ["outros/1.py", "outros/2.py", "outros/3.py", "b/1.py"]),
))
outros_small = ["a/1.py", "a/2.py", "b/1.py", "b/2.py", "outros/1.py"]
case("a folded dir named outros joins the tail", six, outros_small, lambda m, b: (
    assert_([n["id"] for n in m["nodes"]][6:] == ["unplanned:a", "unplanned:outros"]),
    single_outros(m, ["b/1.py", "b/2.py", "outros/1.py"]),
))
case("brackets and braces",
     {"nodes": [node("cls", "new", "lib/[ab].dart"), node("alt", "changed", "lib/{x,y}.dart"),
                node("open", "new", "lib/[c.dart", "lib/{d,e.dart")]},
     ["lib/a.dart", "lib/y.dart", "lib/[c.dart", "lib/{d,e.dart", "lib/c.dart", "lib/d.dart"], lambda m, b: (
    assert_(b["cls"]["built"] == "planned" and b["cls"]["files"] == ["lib/a.dart"]),
    assert_(b["alt"]["built"] == "planned" and b["alt"]["files"] == ["lib/y.dart"]),
    assert_(b["open"]["files"] == ["lib/[c.dart", "lib/{d,e.dart"]),
    assert_(b["unplanned:lib"]["files"] == ["lib/c.dart", "lib/d.dart"]),
))
case("ties are alphabetical", {"nodes": []}, ["zz/a.py", "aa/b.py", "mm/c.py", "mm/d.py"],
     lambda m, b: assert_([n["id"] for n in m["nodes"]] == ["unplanned:mm", "unplanned:aa", "unplanned:zz"]))
deep = "very/long/directory/path/that/goes/on"
case("labels are cut on the left at 32 characters", {"nodes": []}, [f"{deep}/a.py", "short/b.py"], lambda m, b: (
    assert_(b[f"unplanned:{deep}"]["label"] == "…" + deep[-31:]),
    assert_(len(b[f"unplanned:{deep}"]["label"]) == 32 and b["unplanned:short"]["label"] == "short"),
))
PY

echo "- wf-report: built map from a real git repo"
GR=$(tmp); GD=$(tmp)
git -C "$GR" init -q
mkdir -p "$GR/bin/n/gen" "$GR/lib" "$GR/docs" "$GR/tests" "$GR/tools"
for f in bin/n/old.py bin/m.py lib/k.py docs/gone.md tests/t.sh; do echo v1 > "$GR/$f"; done
CK="$BIN/wf-checkpoint.sh"
GBASE=$(bash "$CK" create "$GR")
echo new > "$GR/bin/n/a.py"; echo gen > "$GR/bin/n/gen/g.py"; echo v2 > "$GR/tests/t.sh"
rm "$GR/docs/gone.md"; echo tool > "$GR/tools/x.sh"
bash "$CK" create "$GR" > "$GD/t1.tree"
cat > "$GD/planmap.json" <<'JSON'
{"summary": "Cinco peças.",
 "nodes": [{"id": "nova", "label": "Peça nova", "state": "new", "paths": ["bin/n/**"]},
           {"id": "muda", "label": "Mudança", "state": "changed", "paths": ["bin/m.py"]},
           {"id": "lib", "label": "Biblioteca", "state": "existing", "paths": ["lib/"]},
           {"id": "docs", "label": "Documentação", "state": "existing", "paths": ["docs/**"]},
           {"id": "bin", "label": "Scripts", "state": "existing", "paths": ["bin/**"]}],
 "edges": [{"from": "nova", "to": "lib", "label": "usa"}],
 "ignore": ["tests/**", "bin/n/gen/**"]}
JSON
python3 -c "
import json,sys; d=json.load(open(sys.argv[1])); d['map']=json.load(open(sys.argv[2])); json.dump(d,open(sys.argv[3],'w'),ensure_ascii=False)" "$BRIEF_OK" "$GD/planmap.json" "$GD/plan.json"
# mkwf DIR BASE [PROJECT_PATH] [nomap]: a cycle whose plan gate has the map (or none) and complete started
mkwf() {
  python3 -c "
import json,sys; c={'feature':'Feat Built','start_date':'2026-08-01T00:00:00Z','exec':{'base_checkpoint':sys.argv[2]}}
if sys.argv[3]: c['project_path']=sys.argv[3]
json.dump(c,open(sys.argv[1]+'/current.json','w'))" "$1" "$2" "${3:-}"
  wfr stage-start plan --workflow-dir "$1"
  if [ "${4:-}" = nomap ]; then wfr brief plan --workflow-dir "$1" --file "$BRIEF_OK" >/dev/null
  else wfr brief plan --workflow-dir "$1" --file "$GD/plan.json" >/dev/null; fi
  wfr stage-start complete --workflow-dir "$1"
}
bgate() {
  python3 -c "
import json,sys; g=[s for s in json.load(open(sys.argv[1]))['stages'] if s['stage']=='complete'][0]['gate']
n={x['id']:x for x in g.get('map',{}).get('nodes',[])}
assert $1, g" "$3/report.json" || fail "$2"
}
GW=$(tmp); mkwf "$GW" "$GBASE"
report_snap "$GW"
BUILT=$(wfr built-map --workflow-dir "$GW" --tree "@$GD/t1.tree" --repo "$GR")
report_untouched "$GW" "built-map never writes report.json"
mkp mapin "d['map']={'nodes':[]}"
report_snap "$GW"; got=0
wfr brief pr --workflow-dir "$GW" --file "$PD/mapin.json" --tree "@$GD/t1.tree" --repo "$GR" >/dev/null 2>"$GD/err" || got=$?
[ "$got" = 2 ] && grep -qF "map: campo do script no gate pr" "$GD/err" || fail "brief pr with map in the file exits 2 (got $got)"
report_untouched "$GW" "brief pr with map in the file"
report_snap "$GW"; got=0
wfr brief plan --workflow-dir "$GW" --file "$BRIEF_OK" --repo "$GR" >/dev/null 2>"$GD/err" || got=$?
[ "$got" = 2 ] && grep -qF -- "--repo: só vale no gate pr" "$GD/err" || fail "--repo outside the pr gate exits 2 (got $got)"
report_untouched "$GW" "--repo outside the pr gate"

wfr brief pr --workflow-dir "$GW" --file "$PD/pr.json" --tree "@$GD/t1.tree" --repo "$GR" >/dev/null 2>"$GD/err"
[ ! -s "$GD/err" ] || fail "brief pr with a working git prints nothing on stderr: $(cat "$GD/err")"
bgate "n['nova']['built']=='planned' and n['nova']['files']==['bin/n/a.py','bin/n/gen/g.py'] and n['nova']['state']=='new'" "new piece with files is planned; paths win over ignore" "$GW"
bgate "n['muda']['built']=='untouched' and n['muda']['files']==[] and n['muda']['paths']==['bin/m.py']" "changed piece without files is untouched and keeps its paths" "$GW"
bgate "n['lib']['built']=='existing' and n['docs']['built']=='touched' and n['docs']['files']==['docs/gone.md']" "existing pieces; a removed file counts" "$GW"
bgate "n['bin']['built']=='existing' and n['bin']['files']==[]" "a file matching two pieces goes to the first" "$GW"
bgate "n['unplanned:tools']=={'id':'unplanned:tools','label':'tools','built':'unplanned','files':['tools/x.sh']}" "a file outside every paths is an unplanned piece" "$GW"
bgate "not any('tests/t.sh' in x['files'] for x in g['map']['nodes']) and len(g['map']['nodes'])==6" "a file only in ignore does not show up" "$GW"
bgate "g['map']['summary']=='1 como planejado, 1 fora do plano, 1 sem tocar.' and g['map']['edges']==[{'from':'nova','to':'lib','label':'usa'}]" "summary and edges of the built map" "$GW"
python3 -c "
import json,sys; g=[s for s in json.load(open(sys.argv[1]))['stages'] if s['stage']=='complete'][0]['gate']
assert json.loads(sys.argv[2])==g['map'], (sys.argv[2], g['map'])" "$GW/report.json" "$BUILT" || fail "built-map prints the map brief pr writes"
SHOWPR=$(wfr show pr --workflow-dir "$GW")
python3 -c "
import json,sys; t=json.loads(sys.argv[1])['text_md']
want='\n\nConstruído:\n1 como planejado, 1 fora do plano, 1 sem tocar.\n- Mudança (não tocada)\n- Documentação (tocada sem estar no plano)\n- tools (fora do plano)\n\n'
assert want in t, t
sec=t[t.index('Construído:'):].split('\n\n')[0]
assert 'Peça nova' not in sec and 'Biblioteca' not in sec, sec
assert t.index('Construído:') < t.index('Pontos:'), t" "$SHOWPR" || fail "show pr lists unplanned, untouched and touched under Construído:"
wfr show plan --workflow-dir "$GW" | grep -q 'Construído:' && fail "Construído: only in the pr gate"

wfr answer pr --workflow-dir "$GW" --question Q1 --option change --text-file "$PD/change.md"
for q in Q2 Q3; do wfr answer pr --workflow-dir "$GW" --question "$q" --option ok; done
bgate "g['status']=='revising'" "a change answer leaves the pr block revising" "$GW"
echo v2 > "$GR/bin/m.py"
bash "$CK" create "$GR" > "$GD/t2.tree"
wfr brief pr --workflow-dir "$GW" --file "$PD/r2.json" --tree "@$GD/t2.tree" --repo "$GR" >/dev/null
bgate "g['round']==2 and n['muda']['built']=='planned' and n['muda']['files']==['bin/m.py'] and g['map']['summary']=='2 como planejado, 1 fora do plano, 0 sem tocar.'" "round 2 recomputes the untouched piece as planned" "$GW"
report_snap "$GW"
wfr brief pr --workflow-dir "$GW" --file "$PD/r2.json" --tree "@$GD/t2.tree" --repo "$GR" >/dev/null || fail "resending the round 2 file exits 0"
report_untouched "$GW" "resending the same file with the same tree is a no-op"
wfr brief pr --workflow-dir "$GW" --file "$PD/r2.json" --tree "@$GD/t2.tree" --repo "$GD/missing" >/dev/null 2>"$GD/err" || fail "resending with a broken git exits 0"
report_untouched "$GW" "resending with a broken git keeps the previous map and stays a no-op"

GX=$(tmp); mkwf "$GX" "$GBASE"
wfr brief pr --workflow-dir "$GX" --file "$PD/pr.json" --tree "@$GD/t1.tree" --repo "$GD/missing" >/dev/null 2>/dev/null
wfr answer pr --workflow-dir "$GX" --question Q1 --option change --text-file "$PD/change.md"
for q in Q2 Q3; do wfr answer pr --workflow-dir "$GX" --question "$q" --option ok; done
wfr brief pr --workflow-dir "$GX" --file "$PD/r2.json" --tree "@$GD/t2.tree" --repo "$GD/missing" >/dev/null 2>/dev/null
bgate "g['round']==2 and 'map' not in g" "round 2 written with a broken git has no map" "$GX"
report_snap "$GX"
wfr brief pr --workflow-dir "$GX" --file "$PD/r2.json" --tree "@$GD/t2.tree" --repo "$GR" >/dev/null 2>"$GD/err" || fail "resending a round 2 without map with a working git exits 0: $(cat "$GD/err")"
report_untouched "$GX" "resending a round 2 without map with a working git stays a no-op without map"

GP=$(tmp); mkwf "$GP" "$GBASE" "$GR"
wfr brief pr --workflow-dir "$GP" --file "$PD/pr.json" --tree "@$GD/t1.tree" >/dev/null
bgate "n['nova']['built']=='planned'" "without --repo the repo is project_path of current.json" "$GP"

GN=$(tmp); mkwf "$GN" "$GBASE" "" nomap
[ "$(wfr built-map --workflow-dir "$GN" --tree "@$GD/t1.tree" --repo "$GR")" = "{}" ] || fail "built-map without a plan map prints {}"
wfr brief pr --workflow-dir "$GN" --file "$PD/pr.json" --tree "@$GD/t1.tree" --repo "$GR" >/dev/null 2>"$GD/err"
[ ! -s "$GD/err" ] || fail "no plan map, no warning: $(cat "$GD/err")"
bgate "'map' not in g and g['tree']=='$(tr -d '[:space:]' < "$GD/t1.tree")'" "brief pr without a plan map writes no map" "$GN"
wfr show pr --workflow-dir "$GN" | grep -q 'Construído:' && fail "show pr without a plan map has no Construído:"

# unavailable LABEL WANT WFDIR [brief args...]: exit 0, block without map, the reason on stderr
unavailable() {
  local label=$1 want=$2 dir=$3; shift 3
  "$@" >/dev/null 2>"$GD/err" || fail "$label: expected exit 0"
  grep -qF "mapa construído indisponível: $want" "$GD/err" || fail "$label: stderr '$(cat "$GD/err")' lacks '$want'"
  bgate "'map' not in g and g['status']=='open'" "$label: block without map" "$dir"
}
GU=$(tmp); mkwf "$GU" 1111111111111111111111111111111111111111
unavailable "base unknown to git" "git diff saiu com" "$GU" wfr brief pr --workflow-dir "$GU" --file "$PD/pr.json" --tree "@$GD/t1.tree" --repo "$GR"
GM=$(tmp); mkwf "$GM" "$GBASE"
unavailable "--repo that does not exist" "repo não é diretório" "$GM" wfr brief pr --workflow-dir "$GM" --file "$PD/pr.json" --tree "@$GD/t1.tree" --repo "$GD/missing"
[ "$(wfr built-map --workflow-dir "$GM" --tree "@$GD/t1.tree" --repo "$GD/missing" 2>/dev/null)" = "{}" ] || fail "built-map with a broken git prints {}"
wfr show pr --workflow-dir "$GM" | grep -q 'Construído:' && fail "show pr with a broken git has no Construído:"
GO=$(tmp); mkwf "$GO" "$GBASE"
unavailable "neither --repo nor project_path" "sem --repo nem project_path" "$GO" wfr brief pr --workflow-dir "$GO" --file "$PD/pr.json" --tree "@$GD/t1.tree"
GG=$(tmp); mkwf "$GG" "$GBASE"
PY3=$(python3 -c 'import sys; print(sys.executable)')
unavailable "git missing from PATH" "git indisponível" "$GG" env -u CLAUDE_FLOW_SESSION_ID PATH=/nonexistent HOME="$HOME_BIN_SHIM" "$PY3" "$BIN/wf-report.py" brief pr --workflow-dir "$GG" --file "$PD/pr.json" --tree "@$GD/t1.tree" --repo "$GR"
got=0; python3 -c "
import json,sys; c=json.load(open(sys.argv[1])); c['exec']={}; json.dump(c,open(sys.argv[1],'w'))" "$GG/current.json"
wfr built-map --workflow-dir "$GG" --tree "@$GD/t1.tree" --repo "$GR" >/dev/null 2>"$GD/err" || got=$?
[ "$got" = 2 ] && grep -qF "built-map: exec.base_checkpoint" "$GD/err" || fail "built-map without a valid base exits 2 (got $got)"

echo "- wf-report: session_id comes from --session or CLAUDE_FLOW_SESSION_ID (--session wins)"
S=$(tmp)
printf '{"feature":"Feat S","start_date":"2026-02-01T00:00:00Z"}' > "$S/current.json"
wfr stage-start plan --workflow-dir "$S"
wfr stage-start tasks --workflow-dir "$S" --session sess-42
wfe s1 stage-start implement --workflow-dir "$S"
wfe s1 stage-start verify --workflow-dir "$S" --session s2
wfe s1 decision complete --workflow-dir "$S" --by user --text-file "$W/dec.md"
wfe "" stage-start kickoff --workflow-dir "$S"
python3 -c "
import json; st={x['stage']:x for x in json.load(open('$S/report.json'))['stages']}
assert 'session_id' not in st['plan'], st['plan']
assert st['tasks']['session_id']=='sess-42', st['tasks']
assert st['implement']['session_id']=='s1', st['implement']
assert st['verify']['session_id']=='s2', st['verify']
assert st['complete']['session_id']=='s1', st['complete']
assert 'session_id' not in st['kickoff'], st['kickoff']
" || fail "session_id in stage-start"

echo "- wf-report: progressive identity adopts a compatible report, archives a conflicting one"
A=$(tmp)
printf '{"feature":null,"start_date":null}' > "$A/current.json"
wfr stage-start kickoff --workflow-dir "$A"
printf '{"feature":"Feat P","start_date":"2026-03-01T00:00:00Z"}' > "$A/current.json"
wfr stage-start specify --workflow-dir "$A"
python3 -c "
import json; r=json.load(open('$A/report.json'))
assert r['cycle']=={'feature':'Feat P','started_at':'2026-03-01T00:00:00Z'}, r['cycle']
assert [s['stage'] for s in r['stages']]==['kickoff','specify'], r['stages']
" || fail "adopt null cycle"
[ -z "$(ls "$A" | grep '^report\..*\.json$')" ] || fail "adoption must not archive"
C=$(tmp)
printf '{"feature":"Feat Q","start_date":null}' > "$C/current.json"
wfr stage-start kickoff --workflow-dir "$C"
printf '{"feature":null,"start_date":"2026-03-02T00:00:00Z"}' > "$C/current.json"
wfr stage-start specify --workflow-dir "$C"
[ -f "$C/report.unknown.json" ] || fail "partial vs partial conflict must archive"
python3 -c "
import json; r=json.load(open('$C/report.json'))
assert [s['stage'] for s in r['stages']]==['specify'], r['stages']
" || fail "conflict starts fresh report"
D=$(tmp)
printf '{"feature":"Feat R","start_date":"2026-03-03T00:00:00Z"}' > "$D/current.json"
wfr stage-start plan --workflow-dir "$D"
printf '{"feature":"Feat Z","start_date":"2026-03-03T00:00:00Z"}' > "$D/current.json"
wfr stage-start plan --workflow-dir "$D"
[ -f "$D/report.2026-03-03T00:00:00Z.json" ] || fail "different feature must archive"

echo "- wf-report: gate follows the stop table"
GATE_HOME=$(tmp); mkdir -p "$GATE_HOME/.claude/workflow"; ln -s "$BIN" "$GATE_HOME/.claude/bin"
GW=$(tmp); GT=$(tmp)
printf '{"feature":"Feat Gt","start_date":"2026-08-01T00:00:00Z"}' > "$GW/current.json"
python3 - "$GT" <<'PY'
import json, sys
q = lambda answer: {"id": "Q1", "text": "Qual?", "options": [{"id": "a", "label": "A", "consequence": "c"},
    {"id": "b", "label": "B", "consequence": "c"}], "assumed": "a", "prefers": {}, "answer": answer}
blocks = {"absent": None, "open-pending": ("open", [q(None)]), "open-clear": ("open", []),
          "revising": ("revising", [q("b")]), "rejected": ("rejected", [q(None)]),
          "approved": ("approved", [q("a")]), "passed": ("passed", [])}
owners = {"spec": "challenge", "plan": "plan", "tasks": "tasks", "pr": "complete"}
for state, b in blocks.items():
    stages = []
    for name, owner in owners.items():
        s = {"stage": owner, "status": "done", "attempt": 1, "summary_md": "", "decisions": [], "findings": [],
             "artifacts": [], "run_ids": []}
        if b:
            s["gate"] = {"name": name, "round": 1, "status": b[0], "summary": "S.", "risks": [], "questions": b[1],
                         "history": [], "changes": [], "cut": [], "omitted": {"risks": 0, "questions": 0, "candidates": 0},
                         "artifact": "x.md"}
        stages.append(s)
    r = {"version": 1, "cycle": {"feature": "Feat Gt", "started_at": "2026-08-01T00:00:00Z"}, "stages": stages}
    json.dump(r, open(f"{sys.argv[1]}/{state}.json", "w"), indent=2)
PY
gate() { HOME="$GATE_HOME" python3 "$BIN/wf-report.py" gate "$1" --workflow-dir "${2:-$GW}"; }
gate_status() {
  python3 -c "
import json,sys; s=[x for x in json.load(open(sys.argv[1]))['stages'] if x['stage']==sys.argv[2]][0]
print(s['gate']['status'])" "$GW/report.json" "$1"
}
gate_decided() {
  python3 -c "
import json,re,sys; s=[x for x in json.load(open(sys.argv[1]))['stages'] if x['stage']==sys.argv[2]][0]
print(s['gate'].get('decided_at', 'absent'))" "$GW/report.json" "$1"
}
owner_of() { case $1 in spec) echo challenge ;; pr) echo complete ;; *) echo "$1" ;; esac; }
table() {
  case $1 in
    approved|passed) echo skip ;;
    open-clear) case $2 in plan|tasks) echo skip ;; *) echo ask ;; esac ;;
    *) echo ask ;;
  esac
}
for flag in off on; do
  if [ "$flag" = on ]; then touch "$GATE_HOME/.claude/workflow/auto_mode.flag"; else rm -f "$GATE_HOME/.claude/workflow/auto_mode.flag"; fi
  for state in absent open-pending open-clear revising rejected approved passed; do
    for g in spec plan tasks pr; do
      cp "$GT/$state.json" "$GW/report.json"; report_snap "$GW"
      got=$(gate "$g"); want=$(table "$state" "$g")
      [ "$got" = "$want" ] || fail "gate $g, $state, autopilot $flag: want $want, got $got"
      if [ "$state" = open-clear ] && [ "$want" = skip ]; then
        [ "$(gate_status "$(owner_of "$g")")" = passed ] || fail "gate $g, $state, autopilot $flag: skip writes passed"
      else
        report_untouched "$GW" "gate $g, $state, autopilot $flag"
      fi
    done
  done
done
rm -f "$GATE_HOME/.claude/workflow/auto_mode.flag"

gates_clear() {
  local want="$1" got=""
  for g in spec plan tasks pr; do cp "$GT/open-clear.json" "$GW/report.json"; got="$got$g=$(gate "$g") "; done
  [ "$got" = "$want" ] || fail "gate: want '$want', got '$got' ($2)"
}
printf '{"required":["plan"]}' > "$GATE_HOME/.claude/workflow/gates.json"
gates_clear "spec=ask plan=ask tasks=skip pr=ask " "gates.json adds plan to spec and pr"
for bad in '{"required":[]}' '{not json' '[]' '{"required":"plan"}' '{"required":[1]}' '{}'; do
  printf '%s' "$bad" > "$GATE_HOME/.claude/workflow/gates.json"
  gates_clear "spec=ask plan=skip tasks=skip pr=ask " "empty or invalid gates.json: $bad"
done
rm "$GATE_HOME/.claude/workflow/gates.json"

cp "$GT/open-clear.json" "$GW/report.json"
printf '{"feature":"Outro ciclo","start_date":"2026-08-02T00:00:00Z"}' > "$GW/current.json"
report_snap "$GW"
[ "$(gate plan)" = ask ] || fail "gate on a report from another cycle asks"
report_untouched "$GW" "gate on a report from another cycle"
printf '{"feature":"Feat Gt","start_date":"2026-08-01T00:00:00Z"}' > "$GW/current.json"
rm "$GW/report.json"
[ "$(gate plan)" = ask ] && [ ! -e "$GW/report.json" ] || fail "gate without report.json asks and writes nothing"
GN=$(tmp)
[ "$(gate plan "$GN")" = ask ] && [ -z "$(ls -A "$GN")" ] || fail "gate without current.json asks and writes nothing"

printf '{"summary": "Sem decisão.", "artifact": "plan.md", "questions": []}' > "$GT/noq.json"
wfr stage-start plan --workflow-dir "$GW"
wfr brief plan --workflow-dir "$GW" --file "$GT/noq.json" >/dev/null
[ "$(gate plan)" = skip ] && [ "$(gate_status plan)" = passed ] || fail "plan without questions passes"
[[ "$(gate_decided plan)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail "gate that writes passed stamps decided_at (got $(gate_decided plan))"
python3 -c "
import json,sys; r=json.load(open(sys.argv[1])); g=[s for s in r['stages'] if s['stage']=='plan'][0]['gate']
g['decided_at']='2000-01-01T00:00:00Z'; json.dump(r,open(sys.argv[1],'w'),indent=2)" "$GW/report.json"
[ "$(gate plan)" = skip ] && [ "$(gate_decided plan)" = 2000-01-01T00:00:00Z ] || fail "gate on a passed block keeps decided_at"
python3 -c "
import json,sys; r=json.load(open(sys.argv[1])); g=[s for s in r['stages'] if s['stage']=='plan'][0]['gate']
g['status']='open'; json.dump(r,open(sys.argv[1],'w'),indent=2)" "$GW/report.json"
[ "$(gate plan)" = skip ] && [ "$(gate_status plan)" = passed ] && [ "$(gate_decided plan)" = 2000-01-01T00:00:00Z ] || fail "gate never overwrites a decided_at already on the block"
wfr stage-start plan --workflow-dir "$GW"
[ "$(gate plan)" = ask ] || fail "stage-start plan after passed drops the block and the gate asks"

got=0; HOME="$GATE_HOME" python3 "$BIN/wf-report.py" gate plan >/dev/null 2>&1 || got=$?; [ "$got" = 2 ] || fail "gate without --workflow-dir: expected exit 2, got $got"
got=0; gate deploy >/dev/null 2>&1 || got=$?; [ "$got" = 2 ] || fail "gate deploy: expected exit 2, got $got"
got=0; HOME="$GATE_HOME" python3 "$BIN/wf-report.py" gate --workflow-dir "$GW" >/dev/null 2>&1 || got=$?; [ "$got" = 2 ] || fail "gate without name: expected exit 2, got $got"

echo "- wf-report: shell metacharacters in text files are stored verbatim and never run"
rm -f /tmp/pwn-wfr
printf '%s\n' 'crase `x` e $(touch /tmp/pwn-wfr) com "aspas" e '"'"'simples'"'" > "$W/evil.md"
wfr decision verify --workflow-dir "$W" --by orchestrator --text-file "$W/evil.md" --mistake
python3 -c "
import json; s=[x for x in json.load(open('$W/report.json'))['stages'] if x['stage']=='verify'][0]
d=s['decisions'][-1]; assert d['text_md']==open('$W/evil.md').read() and d['kind']=='mistake', d
" || fail "text not verbatim"
[ ! -e /tmp/pwn-wfr ] || fail "command substitution executed"
head -c 40000 /dev/zero | tr '\0' 'a' > "$W/big.md"
wfr decision verify --workflow-dir "$W" --by orchestrator --text-file "$W/big.md"
python3 -c "
import json; s=[x for x in json.load(open('$W/report.json'))['stages'] if x['stage']=='verify'][0]
t=s['decisions'][-1]['text_md']; assert t.endswith('…[truncado]') and len(t.encode())<=32768, len(t.encode())
" || fail "text not truncated at 32 KB"

echo "- wf-report: a new cycle identity archives the previous report; archive-cycle copies report.json"
cp "$W/report.json" "$W/old.json"
printf '{"feature":"Feat B","start_date":"2026-02-01T00:00:00Z","status":"specifying"}' > "$W/current.json"
wfr stage-start specify --workflow-dir "$W"
[ "$(ls "$W" | grep -c '^report\.2026-01-01T00:00:00Z\.2\.json$')" = "1" ] || fail "divergent identity not archived"
cmp -s "$W/old.json" "$W/report.2026-01-01T00:00:00Z.2.json" || fail "archived report changed"
python3 -c "
import json; r=json.load(open('$W/report.json'))
assert r['cycle']=={'feature':'Feat B','started_at':'2026-02-01T00:00:00Z'} and [s['stage'] for s in r['stages']]==['specify'], r
" || fail "new cycle report"
H=$(tmp); mkdir -p "$H/.claude/workflow/proj"
cp "$W/current.json" "$W/report.json" "$H/.claude/workflow/proj/"
HOME="$H" bash "$BIN/archive-cycle.sh" abandoned proj "Feat B" >/dev/null
ARCH=$(ls -d "$H/.claude/projects/proj/history/"*_feat-b)
cmp -s "$W/report.json" "$ARCH/report.json" || fail "archive-cycle did not copy report.json intact"

echo "- wf-report: 20 parallel decisions are all kept"
P=$(tmp)
printf '{"feature":"Par","start_date":"2026-03-01T00:00:00Z"}' > "$P/current.json"
for i in $(seq 1 20); do printf 'decisao %s\n' "$i" > "$P/d$i.md"; done
for i in $(seq 1 20); do wfr decision implement --workflow-dir "$P" --by orchestrator --text-file "$P/d$i.md" & done
wait
python3 -c "import json; s=json.load(open('$P/report.json'))['stages'][0]; assert len(s['decisions'])==20, len(s['decisions'])" || fail "parallel decisions lost"
[ -z "$(find "$P" -name '*.tmp')" ] || fail ".tmp left behind after parallel writes"

echo "- wf-report: import-run folds agent decisions, escalations, verify, backtracks, blockers and challenge"
I=$(tmp)
cat > "$I/current.json" <<'JSON'
{"feature":"Imp","start_date":"2026-04-01T00:00:00Z",
 "challenge":{"verdict":"ajustes","applied":["B1"],"rejected":["A2"],"choices":{"B1":"opcao a"}},
 "backtracks":[{"task":"T2","reason":"contrato ausente","resolution":"plano ajustado"}],
 "blockers":[{"run":"impl-1","task":"T2","reason":"max_attempts"},{"run":"impl-other","task":"T9","reason":"x"}]}
JSON
mkdir -p "$I/runs/impl-1" "$I/runs/verify-1"
cat > "$I/runs/impl-1/result.json" <<'JSON'
{"status":"blocked","tasks":[
 {"id":"T1","status":"done","decisions":["usar lock por arquivo","tmp ao lado do alvo"],"escalations":[]},
 {"id":"T2","status":"blocked","decisions":["schema novo"],"escalations":[{"from":"sonnet","to":"opus","at_attempt":2,"open":["G0-TEST-FAIL"]}]}]}
JSON
cat > "$I/runs/verify-1/result.json" <<'JSON'
{"status":"blocked","reason":"verify_rounds_exhausted","report":{"round":3,
 "g1":[{"gate":"G1:arch","verdict":"fail","findings":[{"id":"a","severity":"major"},{"id":"b","severity":"minor"}]}],
 "g2":{"verdict":"pass","findings":[]}},
 "tasks":[{"id":"V1","decisions":["corrigir lock"],"escalations":[]}]}
JSON
for _ in 1 2; do
  wfr import-run implement --workflow-dir "$I" --run-dir "$I/runs/impl-1"
  wfr import-run verify --workflow-dir "$I" --run-dir "$I/runs/verify-1"
done
python3 - "$I/report.json" <<'PY2' || fail "import-run content"
import json, sys
st = {s["stage"]: s for s in json.load(open(sys.argv[1]))["stages"]}
im, ve, ch = st["implement"], st["verify"], st["challenge"]
assert im["run_ids"] == ["impl-1"] and ve["run_ids"] == ["verify-1"], (im["run_ids"], ve["run_ids"])
agent = [(d["by"], d["text_md"]) for d in im["decisions"] if d["by"].startswith("agent:")]
assert agent == [("agent:T1", "usar lock por arquivo"), ("agent:T1", "tmp ao lado do alvo"), ("agent:T2", "schema novo"),
                 ("agent:T2", "Escalada na escada: sonnet → opus na tentativa 2 (abertos: G0-TEST-FAIL)")], agent
orch = [(d["text_md"], d["kind"]) for d in im["decisions"] if d["by"] == "orchestrator"]
assert orch == [("Backtrack em T2: contrato ausente → plano ajustado", "mistake"),
                ("Bloqueio em T2 (run impl-1): max_attempts", "mistake")], orch
assert [d["by"] for d in ve["decisions"]] == ["agent:V1"], ve["decisions"]
assert ve["verify"] == {"run_id": "verify-1", "round": 3, "status": "blocked", "reason": "verify_rounds_exhausted",
                        "gates": [{"gate": "G1:arch", "verdict": "fail", "findings": 2, "blocking": 1},
                                  {"gate": "G2", "verdict": "pass", "findings": 0, "blocking": 0}]}, ve["verify"]
assert [(d["by"], d["text_md"]) for d in ch["decisions"]] == [("challenger", "Achado aplicado na spec: B1"), ("user", "B1: opcao a")], ch["decisions"]
PY2

echo "- wf-report: qa, real-data and pr replace their fields, are idempotent and reject bad input untouched"
W=$(tmp)
printf '{"feature":"Feat Q","start_date":"2026-02-01T00:00:00Z"}' > "$W/current.json"
printf '["a","b","c"]' > "$W/qa.json"
wfr qa --workflow-dir "$W" --file "$W/qa.json"; cp "$W/report.json" "$W/q1.snap"
wfr qa --workflow-dir "$W" --file "$W/qa.json"
cmp -s "$W/q1.snap" "$W/report.json" || fail "qa not idempotent"
python3 -c "
import json; r=json.load(open('$W/report.json'))
assert r['qa']==['a','b','c'] and r['version']==1 and r['cycle']['feature']=='Feat Q', r
" || fail "qa content"
printf '{"a":1}' > "$W/badqa.json"
got=0; wfr qa --workflow-dir "$W" --file "$W/badqa.json" 2>/dev/null || got=$?; [ "$got" = 2 ] || fail "qa bad payload: expected exit 2, got $got"
cmp -s "$W/q1.snap" "$W/report.json" || fail "qa bad payload touched the report"
rm -f /tmp/pwn-wfr
printf '%s\n' 'crase `x` e $(touch /tmp/pwn-wfr) fim' > "$W/rd.md"
wfr real-data --workflow-dir "$W" --file "$W/rd.md"
[ ! -e /tmp/pwn-wfr ] || fail "real-data executed substitution"
python3 -c "
import json; r=json.load(open('$W/report.json'))
assert r['real_data_md']==open('$W/rd.md').read() and 'real_data_status' not in r and r['qa']==['a','b','c'], r
" || fail "real-data verbatim"
wfr real-data --workflow-dir "$W" --not-run
python3 -c "
import json; r=json.load(open('$W/report.json'))
assert r['real_data_md'] is None and r['real_data_status']=='não executado', r
" || fail "real-data --not-run"
got=0; wfr real-data --workflow-dir "$W" 2>/dev/null || got=$?; [ "$got" = 2 ] || fail "real-data without input: expected exit 2, got $got"
wfr pr --workflow-dir "$W" --url https://github.com/o/r/pull/12
python3 -c "
import json; r=json.load(open('$W/report.json'))
assert r['pr']=={'url':'https://github.com/o/r/pull/12','number':12}, r
" || fail "pr number"
cp "$W/report.json" "$W/p1.snap"
for u in https://github.com/o/r/issues/12 https://example.com/pull/12 not-a-url https://github.com/o/r/pull/x; do
  got=0; wfr pr --workflow-dir "$W" --url "$u" 2>/dev/null || got=$?; [ "$got" = 2 ] || fail "pr $u: expected exit 2, got $got"
done
cmp -s "$W/p1.snap" "$W/report.json" || fail "pr invalid url touched the report"
W2=$(tmp)
got=0; wfr qa --workflow-dir "$W2" --file "$W/qa.json" 2>/dev/null || got=$?; [ "$got" = 3 ] || fail "qa without current.json: expected exit 3, got $got"
[ ! -e "$W2/report.json" ] || fail "qa without current.json wrote a report"
printf '{"feature":"Feat R","start_date":"2026-03-01T00:00:00Z"}' > "$W/current.json"
wfr qa --workflow-dir "$W" --file "$W/qa.json"
python3 -c "
import json; r=json.load(open('$W/report.json'))
assert r['cycle']['feature']=='Feat R' and 'pr' not in r and 'real_data_md' not in r, r
" || fail "new cycle must start a fresh report"
[ -f "$W/report.2026-02-01T00:00:00Z.json" ] || fail "previous cycle not archived by qa"

echo "- archive-cycle: history keeps the cycle; phases.md, prs.json and details/ stay in the workflow"
AH=$(tmp); AW="$AH/.claude/workflow/demo"; mkdir -p "$AW/runs/r1" "$AW/details"
printf '{"feature":"Fechamento do ciclo","start_date":"2026-03-01"}' > "$AW/current.json"
printf '{"version":1,"stages":[]}' > "$AW/report.json"; echo spec > "$AW/spec.md"; echo "- [ ] fase" > "$AW/phases.md"
echo '{}' > "$AW/prs.json"; echo card > "$AW/details/42.md"; echo old > "$AW/report.2026-01-01T00:00:00Z.json"
HOME="$AH" bash "$BIN/archive-cycle.sh" abandoned demo >/dev/null
AC=$(ls -d "$AH/.claude/projects/demo/history/"*_fechamento-do-ciclo)
[ -f "$AC/report.json" ] && [ -f "$AC/spec.md" ] && [ -d "$AC/runs/r1" ] || fail "archive-cycle: history incomplete"
[ -f "$AC/details/42.md" ] && [ -f "$AC/report.2026-01-01T00:00:00Z.json" ] || fail "archive-cycle: details/ or archived report missing from history"
[ "$(ls "$AW" | tr '\n' ' ')" = "details phases.md prs.json " ] || fail "archive-cycle: workflow dir must keep only phases.md, prs.json, details/"
[ -f "$AW/details/42.md" ] || fail "archive-cycle: details/ content lost in workflow"
printf '{"feature":"Fechamento do ciclo","start_date":"2026-03-01"}' > "$AW/current.json"; mkdir -p "$AW/runs/r2"
HOME="$AH" bash "$BIN/archive-cycle.sh" abandoned demo >/dev/null
[ -d "$AC/runs/r2" ] && [ ! -e "$AC/runs/runs" ] && [ ! -e "$AC/details/details" ] || fail "archive-cycle: same-day rerun must merge, not nest"
rm -rf "$AW/details" "$AW/prs.json"; printf '{"feature":"Sem extras"}' > "$AW/current.json"
HOME="$AH" bash "$BIN/archive-cycle.sh" abandoned demo >/dev/null || fail "archive-cycle: must not fail without details/ or report.*.json"
AN=$(ls -d "$AH/.claude/projects/demo/history/"*_sem-extras)
[ ! -e "$AN/details" ] && [ ! -e "$AN/runs" ] || fail "archive-cycle: empty dirs created"
rm "$AW/phases.md"; printf '{"feature":"Outro"}' > "$AW/current.json"
HOME="$AH" bash "$BIN/archive-cycle.sh" abandoned demo >/dev/null
[ ! -e "$AW" ] || fail "archive-cycle: empty workflow dir must go away"

echo "- gate_g0: pkgs, golangci parser and stack_env"
G0=$(tmp); mkdir -p "$G0/.claude/stacks"; printf '# c\nA=1\nB=2\n' > "$G0/.claude/stacks/t.env"
HOME="$G0" B=9 PYTHONDONTWRITEBYTECODE=1 python3 - "$BIN" <<'PY' || fail "gate_g0 helpers"
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("gate_g0", Path(sys.argv[1]) / "gate_g0.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m.pkgs(["a/b/x.go", "a/b/y_test.go", "main.go", "c/z.go"]) == [".", "./a/b", "./c"]
env = m.stack_env("t")
assert (env["A"], env["B"]) == ("1", "9"), (env.get("A"), env.get("B"))
import json
out = "log line\n" + json.dumps({"Issues": [
    {"FromLinter": "errcheck", "Text": "unchecked ", "Severity": "", "Pos": {"Filename": "pkg/a.go", "Line": 7}},
    {"FromLinter": "govet", "Text": "bad", "Severity": "warning", "Pos": {"Filename": "pkg/b.go", "Line": 3}},
]}) + "\n"
root = Path("/repo"); got = m.parse_golangci_json(out, root, root, {"default": "major", "warning": "minor"})
assert [(g["id"], g["severity"], g["file"], g["line"]) for g in got] == [
    ("G0-ANALYZE-errcheck", "major", "pkg/a.go", 7), ("G0-ANALYZE-govet", "minor", "pkg/b.go", 3)], got
assert m.parse_golangci_json("garbage", root, root, {}) == []
PY

echo "- stacks: .env files are ignored and never tracked"
REPO_ROOT="$(cd "$BIN/.." && pwd)"
[ -z "$(git -C "$REPO_ROOT" ls-files stacks/ | grep '\.env$' || true)" ] || fail "stacks/*.env tracked"
git -C "$REPO_ROOT" check-ignore -q stacks/go.env || fail "stacks/*.env not gitignored"
python3 -c "import json,sys; g=json.load(open(sys.argv[1])); r=g['g2_runtime']; assert 'r10' not in r.lower() and 'APNs' not in r and 'internal/' not in r" "$REPO_ROOT/stacks/go.json" || fail "go.json g2_runtime not generic"

echo "- to-slug: accents are transliterated"
[ "$(bash "$BIN/to-slug.sh" "Mínimo Ação — Phase 3g.3")" = "minimo-acao-phase-3g-3" ] || fail "to-slug"

echo "- skills: pipeline skills report through wf-report.py"
for s in kickoff specify challenge-spec plan tasks implement verify complete; do
  f="$SKILLS/$s/SKILL.md"
  st=$s; [ "$s" = challenge-spec ] && st=challenge
  grep -q "wf-report.py stage-start $st " "$f" || fail "$s: no stage-start"
  grep -q "wf-report.py stage-end $st " "$f" || fail "$s: no stage-end"
  grep -q -- '--summary-file' "$f" || fail "$s: stage-end without summary file"
done
for s in implement verify; do
  grep -q "wf-report.py import-run $s " "$SKILLS/$s/SKILL.md" || fail "$s: no import-run"
done
grep -q "wf-report.py findings challenge " "$SKILLS/challenge-spec/SKILL.md" || fail "challenge-spec: no findings"
for s in kickoff specify; do
  grep -q 'Resetar.*OK do usu.*wf-report.py reset' "$SKILLS/$s/SKILL.md" || fail "$s: reset must follow the Resetar OK"
  [ "$(grep -c 'wf-report.py reset' "$SKILLS/$s/SKILL.md")" = "1" ] || fail "$s: reset outside the Resetar branch"
done
[ -z "$(grep -rln 'wf-report.py reset' "$SKILLS" | grep -v '/\(kickoff\|specify\)/' || true)" ] || fail "reset used outside kickoff/specify"
ln_of() { grep -n -m1 -- "$1" "$2" | cut -d: -f1; }
C="$SKILLS/complete/SKILL.md"; prev=0
for pat in 'wf-report.py qa ' 'wf-report.py gate pr' '/pr-open --from-complete' 'wf-report.py pr ' 'wf-report.py stage-end complete ' 'archive-cycle.sh completed'; do
  n=$(ln_of "$pat" "$C"); [ -n "$n" ] || fail "complete: missing '$pat'"
  [ "$n" -gt "$prev" ] || fail "complete: '$pat' out of order"
  prev=$n
done
grep -q 'AskUserQuestion' "$C" || fail "complete: gate pr without AskUserQuestion"
grep -q 'arquivo novo' "$C" || fail "complete: âncora dos pontos M- sem a numeração do arquivo novo"
! grep -q 'wf-report.py' "$SKILLS/pr-open/SKILL.md" || fail "pr-open must not write the report"
grep -q -- '--from-complete' "$SKILLS/pr-open/SKILL.md" || fail "pr-open: no --from-complete contract"
PRIV='Grupo''OTG\|loss''-control\|r10''-mobile\|R10 Score Dev\|/development/r10\|/development/abm'
[ -z "$(grep -rn "$PRIV" "$SKILLS" || true)" ] || fail "private names in skills"

echo "- skills: gates ask the brief's decisions, no 'Seguir para', stage-start carries --session"
for pair in challenge-spec:spec plan:plan tasks:tasks complete:pr; do
  s=${pair%%:*}; g=${pair#*:}; f="$SKILLS/$s/SKILL.md"; prev=0
  for pat in 'gate-critic' "wf-report.py brief $g " "wf-report.py gate $g --workflow-dir" "wf-report.py answer $g "; do
    n=$(ln_of "$pat" "$f"); [ -n "$n" ] || fail "$s: missing '$pat'"
    [ "$n" -gt "$prev" ] || fail "$s: '$pat' out of order"
    prev=$n
  done
  [ "$(grep -c 'wf-report.py gate ' "$f")" = "1" ] || fail "$s: expected exactly one gate"
  grep -q "\.gate-$g\.candidates\.json" "$f" || fail "$s: candidates file missing"
  [ "$(grep -c 'Aprovar (Recomendado)' "$f")" = "1" ] || fail "$s: the single approval question must appear once"
  [ "$(grep -c '`ask` sem perguntas' "$f")" = "1" ] || fail "$s: no single branch without questions"
  m=$(ln_of '`ask` sem perguntas' "$f"); a=$(ln_of 'Aprovar (Recomendado)' "$f")
  [ "$a" -gt "$m" ] && [ "$a" -le $((m + 4)) ] || fail "$s: the single approval question outside the branch without questions"
  for opt in 'Ajustar' 'Rejeitar'; do
    sed -n "${m},$((m + 8))p" "$f" | grep -q "$opt" || fail "$s: branch without questions lacks '$opt'"
  done
  [ "$(ln_of '`ask` com perguntas' "$f")" -lt "$m" ] || fail "$s: branch with questions must come first"
  st=$s; [ "$s" = challenge-spec ] && st=challenge
  for pat in 'resumo indisponível' 'rodadas esgotadas' 'Aprovar como está' 'Voltar à etapa anterior' 'Abortar' \
             "Gate $g: passed, sem decisão em aberto" "wf-report.py show $g " "wf-report.py decision $st --workflow-dir \"\$WF_DIR\" --by user"; do
    grep -qF -- "$pat" "$f" || fail "$s: missing '$pat'"
  done
  ! grep -E 'wf-report\.py (brief|answer) ' "$f" | grep -q '|| true' || fail "$s: brief and answer run without || true"
done
[ -z "$(grep -rn 'wf-report.py gate ' "$SKILLS" | grep -v -- '--workflow-dir' || true)" ] || fail "gate called without --workflow-dir"
grep -q 'wf-report.py reopen pr ' "$C" || fail "complete: change branch without reopen pr"
[ "$(ln_of 'wf-report.py reopen pr ' "$C")" -gt "$(ln_of 'archive-cycle.sh completed' "$C")" ] || fail "complete: change branch must come after step 10"
[ "$(ln_of 'wf-report.py show pr ' "$C")" -lt "$(ln_of 'routing-stats.py' "$C")" ] || fail "complete: re-entry check must come before ADR, lessons and routing"
grep -q 'pr\.diff' "$C" && grep -q 'pr\.tree' "$C" || fail "complete: pr.diff and pr.tree from shell"
[ -z "$(grep -ln 'Seguir para' "$SKILLS"/{specify,challenge-spec,plan,tasks}/SKILL.md || true)" ] || fail "'Seguir para' still in skills"
for s in kickoff specify challenge-spec plan tasks implement verify; do
  grep 'wf-report.py stage-start ' "$SKILLS/$s/SKILL.md" | grep -qv -- '--session "\$CLAUDE_FLOW_SESSION_ID"' && fail "$s: stage-start without --session"
done
grep -q 'gates.json' "$SKILLS/auto/SKILL.md" || fail "auto: does not explain gates"
section_has() { sed -n "$(ln_of "$2" "$1"),$(ln_of "$3" "$1")p" "$1" | grep -qF -- "$4"; }
P="$SKILLS/plan/SKILL.md"
section_has "$P" '### 9a.' '### 9b.' '$WF_DIR/.gate-plan.map.json' || fail "plan: 9a does not write the map draft"
section_has "$P" '### 9b.' '### 9c.' '$WF_DIR/.gate-plan.map.json' || fail "plan: 9b does not hand the map draft to the critic"
section_has "$P" '### 9e.' '### 9f.' '$WF_DIR/.gate-plan.map.json' || fail "plan: 9e does not rewrite the map draft"
section_has "$P" '### 9a.' '### 9b.' 'Arquivos impactados' || fail "plan: map draft not tied to the impacted files table"
section_has "$P" '### 9c.' '### 9d.' 'wf-report: map' || fail "plan: drop-map not tied to the map refusal prefix"
section_has "$P" '### 9c.' '### 9d.' 'mapa indisponível' || fail "plan: drop-map without warning"
[ "$(grep -c 'wf-report.py brief plan .*--drop-map' "$P")" = "1" ] || fail "plan: expected one brief with --drop-map"
G="$REPO_ROOT/agents/gate-critic.md"
for pat in '8 peças' 'linguagem de produto' 'paths' 'M-' '"map"' '.gate-plan.map.json' '`edges[].label` 60' 'até 10 globs'; do
  grep -qF -- "$pat" "$G" || fail "gate-critic: missing '$pat'"
done
grep -F 'M-' "$G" | grep -q 'não confira' || fail "gate-critic: M- anchors must skip the diff check"
grep -F 'M-' "$G" | grep -q 'cortáveis' || fail "gate-critic: M- points must be cuttable"
for pat in 'wf-report.py built-map --workflow-dir "$WF_DIR" --tree "@$WF_DIR/pr.tree" --repo "$PROJECT_PATH"' \
           'wf-report.py brief pr --workflow-dir' '--repo "$PROJECT_PATH"' 'unplanned' 'untouched' '`M-1`'; do
  grep -qF -- "$pat" "$C" || fail "complete: missing '$pat'"
done
grep -F 'wf-report.py brief pr ' "$C" | grep -qF -- '--repo "$PROJECT_PATH"' || fail "complete: brief pr without --repo"
section_has "$C" '### 8a.' '### 8b.' 'built-map' || fail "complete: built-map outside 8a"
[ "$(ln_of 'pr.diff"' "$C")" -lt "$(ln_of 'wf-report.py built-map' "$C")" ] || fail "complete: built-map must follow pr.diff"
[ "$(ln_of '"id": "C1"' "$C")" -lt "$(ln_of '`M-1`' "$C")" ] || fail "complete: map points must follow decision points"
[ -z "$(grep -F '.gate-pr.json' "$C" | grep -E '`map`|"map"' || true)" ] || fail "complete: map must not go into .gate-pr.json"

echo "- app/install.sh: running sessions stop the install, --force skips the check, unreachable engine only warns"
INSTALL="$(cd "$(dirname "$0")/../app" && pwd)/install.sh"
ROOT=$(tmp); SRV=$(tmp); mkdir -p "$ROOT/.dashboard/engine-sessions" "$SRV/api"
printf '%s' '[{"id":"s-run","status":"running","project":"demo","command":"/plan"},{"id":"s-perm","status":"waiting_permission","project":"demo","command":"/fix"},{"id":"s-idle","status":"idle","project":"demo","command":"/status"}]' > "$SRV/api/sessions"
python3 -m http.server 0 --bind 127.0.0.1 --directory "$SRV" >/dev/null 2>&1 &
FAKE_ENGINE=$!
trap 'kill "$FAKE_ENGINE" 2>/dev/null || true' EXIT
echo "$FAKE_ENGINE" > "$ROOT/.dashboard/engine-sessions/engine.pid"
for _ in $(seq 1 50); do
  lsof -nP -a -p "$FAKE_ENGINE" -iTCP -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.1
done
# Belt and braces: if the source guard ever regresses, main() must die on the stub before touching /Applications.
STUBS=$(tmp); for b in flutter osascript open; do printf '#!/bin/sh\necho "stub $0 called" >&2\nexit 97\n' > "$STUBS/$b"; chmod +x "$STUBS/$b"; done
guard() { PATH="$STUBS:$PATH" WORKFLOW_ROOT="$1" bash -c 'source "$1"; shift; guard_sessions "$@"' guard "$INSTALL" "${@:2}"; }
PATH="$STUBS:$PATH" bash -c 'source "$1" --force; echo sourced-ok' guard "$INSTALL" 2>"$ROOT/src" | grep -q sourced-ok || fail "install.sh: sourcing ran main"
! grep -q "stub" "$ROOT/src" || fail "install.sh: sourcing reached a build/quit command" 
got=0; guard "$ROOT" 2>"$ROOT/err" || got=$?
[ "$got" = 1 ] || fail "install guard: expected exit 1 with running sessions, got $got"
grep -q "s-run	running	demo	/plan" "$ROOT/err" || fail "install guard: running session not listed"
grep -q "s-perm	waiting_permission" "$ROOT/err" || fail "install guard: waiting_permission session not listed"
! grep -q "s-idle" "$ROOT/err" || fail "install guard: idle session listed"
guard "$ROOT" --force 2>/dev/null || fail "install guard: --force must pass"
printf '%s' '[{"id":"s-idle","status":"idle"}]' > "$SRV/api/sessions"
guard "$ROOT" 2>/dev/null || fail "install guard: idle-only engine must pass"
kill "$FAKE_ENGINE"; wait "$FAKE_ENGINE" 2>/dev/null || true
guard "$ROOT" 2>"$ROOT/err" || fail "install guard: unreachable engine must pass"
grep -q "engine inacessível" "$ROOT/err" || fail "install guard: no warning for an unreachable engine"
guard "$(tmp)" 2>/dev/null || fail "install guard: missing engine.pid must pass"

echo "- release-base.sh: maior versão, preferência por release/X.Y.Z e fallback /main"
RB="$BIN/release-base.sh"
out=$(printf '%s\n' release/3.12.0/main release/3.12.0/notified_bet_bookmaker release/3.12.0/merge-3.13 release/stable-merge-main release/draft release-1.0.0 release/3.11.0 | "$RB")
[ "$out" = "$(printf 'release/3.12.0/main\n3.12.0')" ] || fail "release-base: fixture da spec ($out)"
out=$(printf '%s\n' release/0.0.3 release/0.0.4 | "$RB")
[ "$out" = "$(printf 'release/0.0.4\n0.0.4')" ] || fail "release-base: 0.0.4 vs 0.0.3 ($out)"
out=$(printf '%s\n' release/1.0.0 release/1.0.0/main | "$RB")
[ "$(sed -n 1p <<<"$out")" = "release/1.0.0" ] || fail "release-base: release/X.Y.Z deve vencer /main"
got=0; out=$(printf '%s\n' release/2.0.0/a release/2.0.0/b release/1.0.0 | "$RB") || got=$?
[ "$got" = 3 ] || fail "release-base: esperava exit 3, veio $got"
[ "$out" = "$(printf 'release/2.0.0/a\nrelease/2.0.0/b')" ] || fail "release-base: candidatas ($out)"
got=0; out=$(printf '%s\n' main release/draft release/stable-x release-1.0.0 | "$RB") || got=$?
[ "$got" = 1 ] && [ -z "$out" ] || fail "release-base: nada casa deveria sair 1 sem saída"

echo "- skills: greps de kickoff, adr, pr-open e dev-implementer"
SK="$(cd "$(dirname "$0")/.." && pwd)"
grep -q "release-base.sh" "$SK/skills/kickoff/SKILL.md" || fail "kickoff: não chama release-base.sh"
[ "$(grep -c "for k in ('feature', 'start_date', 'end_date', 'phases'" "$SK/skills/kickoff/SKILL.md")" = 2 ] || fail "kickoff: os 2 seeds (card e manual) devem remover identidade"
! grep -qE "ado_id|linear_key" "$SK/skills/kickoff/SKILL.md" "$SK/skills/pr-open/SKILL.md" "$SK/skills/pr-status/SKILL.md" "$SK/skills/complete/SKILL.md" || fail "skills ainda citam ado_id/linear_key"
grep -q "rev-parse --show-superproject-working-tree" "$SK/skills/adr/SKILL.md" || fail "adr: sem detecção de submódulo"
grep -q "adr-candidates.md" "$SK/skills/adr/SKILL.md" || fail "adr: sem adr-candidates.md"
grep -q "adr-candidates.md" "$SK/skills/complete/SKILL.md" || fail "complete: sem adr-candidates.md"
grep -q "ADRs propostas" "$SK/skills/pr-open/SKILL.md" || fail "pr-open: sem seção ADRs propostas"
grep -q "pt-BR" "$SK/agents/dev-implementer.md" || fail "dev-implementer: sem pt-BR"
grep -q "repo inteiro" "$SK/agents/dev-implementer.md" || fail "dev-implementer: sem proibição de formatador no repo inteiro"

echo "- wf-cycle: pause/resume flag current.json under the lock; archive files the cycle as abandoned"
C=$(tmp); mkdir -p "$C/.claude/workflow/demo"
echo '{"feature":"F","start_date":"2026-10-01T00:00:00Z"}' > "$C/.claude/workflow/demo/current.json"
echo "# P" > "$C/.claude/workflow/demo/phases.md"
CLAUDE_HOME="$C/.claude" python3 "$BIN/wf-cycle.py" pause demo
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['paused'] is True and d['paused_at'], d" "$C/.claude/workflow/demo/current.json" || fail "pause flag"
CLAUDE_HOME="$C/.claude" python3 "$BIN/wf-cycle.py" resume demo
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert 'paused' not in d and 'paused_at' not in d, d" "$C/.claude/workflow/demo/current.json" || fail "resume flag"
CLAUDE_HOME="$C/.claude" python3 "$BIN/wf-cycle.py" archive demo >/dev/null
[ ! -e "$C/.claude/workflow/demo/current.json" ] || fail "archive left current.json"
[ -f "$C/.claude/workflow/demo/phases.md" ] || fail "archive dropped phases.md"
grep -q '"status": "abandoned"' "$C"/.claude/projects/demo/history/*/metrics.json || fail "archive status"
CLAUDE_HOME="$C/.claude" python3 "$BIN/wf-cycle.py" pause demo 2>/dev/null && fail "pause without a cycle must fail"
CLAUDE_HOME="$C/.claude" python3 "$BIN/wf-cycle.py" pause ../x 2>/dev/null && fail "unsafe project name accepted"

echo "- to-app: asks the connected app to open this session at the CLI's cwd; without a session it refuses"
C=$(tmp); mkdir -p "$C/.claude/sessions" "$C/.claude/workflow/.dashboard/engine-sessions" "$C/stub"
SID=11111111-1111-4111-8111-111111111111
echo "{\"pid\":4242,\"sessionId\":\"$SID\",\"cwd\":\"/repos/demo/pkg\"}" > "$C/.claude/sessions/4242.json"
printf '#!/bin/sh\necho "$@" >> "%s/opened"\n' "$C" > "$C/stub/open"; chmod +x "$C/stub/open"
printf '#!/bin/sh\nexit 1\n' > "$C/stub/pgrep"; chmod +x "$C/stub/pgrep"  # no instance open: falls back to open -b
python3 - "$C" <<'PY' &
import http.server, json, sys
root = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, body):
        self.send_response(200); self.send_header("content-type", "application/json"); self.end_headers()
        self.wfile.write(json.dumps(body).encode())
    def do_GET(self): self.reply({"clients": 1})
    def do_POST(self):
        open(f"{root}/posted", "w").write(self.path + " " + self.rfile.read(int(self.headers["content-length"])).decode())
        self.reply({"clients": 1})
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(f"{root}/.claude/workflow/.dashboard/engine-sessions/engine.json", "w").write(json.dumps({"pid": 1, "port": s.server_port}))
s.serve_forever()
PY
SRV=$!
for _ in $(seq 50); do [ -s "$C/.claude/workflow/.dashboard/engine-sessions/engine.json" ] && break; sleep 0.1; done
OUT=$(PATH="$C/stub:$PATH" CLAUDE_HOME="$C/.claude" CLAUDE_CODE_SESSION_ID=$SID CLAUDE_PID=4242 python3 "$BIN/to-app.py")
kill $SRV; wait $SRV 2>/dev/null || true
[ "$(cat "$C/posted")" = "/api/ui/open-terminal {\"sdkSessionId\": \"$SID\", \"cwd\": \"/repos/demo/pkg\"}" ] || fail "to-app body: $(cat "$C/posted")"
grep -q -- "-b dev.claudesetup.claudeFlow" "$C/opened" || fail "to-app did not bring the app forward"
case "$OUT" in "sessao 11111111 enviada"*) ;; *) fail "to-app output: $OUT" ;; esac
env -u CLAUDE_CODE_SESSION_ID CLAUDE_HOME="$C/.claude" python3 "$BIN/to-app.py" 2>/dev/null && fail "to-app without a session must fail"

echo "- tracker: org by root or explicit project, card ref per kind, ado env"
C=$(tmp); mkdir -p "$C/.claude/workflow" "$C/r10/app" "$C/likin/app" "$C/loose" "$C/other"
cat > "$C/.claude/workflow/.dashboard.json" <<JSON
{"orgs": [
  {"name": "OTG", "roots": ["$C/r10"], "tracker": {"kind": "ado", "org": "Grupo OTG", "project": "R10 Score", "base": "release"}},
  {"name": "Likin", "roots": ["$C/likin"], "tracker": {"kind": "jira", "site": "x.atlassian.net", "project": "LC", "email": "e"}},
  {"name": "Bare", "roots": ["$C/other"]}
 ],
 "projects": [{"name": "loose", "path": "$C/loose", "org": "Likin"}]}
JSON
trk() { CLAUDE_HOME="$C/.claude" python3 "$BIN/tracker.py" "$@"; }
[ "$(trk resolve "$C/r10/app" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["org"],d["tracker"]["kind"])')" = "OTG ado" ] || fail "resolve by root"
[ "$(trk resolve "$C/loose" | python3 -c 'import json,sys;print(json.load(sys.stdin)["org"])')" = "Likin" ] || fail "resolve by explicit project"
[ "$(trk resolve "$C/other")" = '{"org": "Bare", "tracker": null}' ] || fail "org without tracker"
[ "$(trk resolve /nowhere)" = '{"org": null, "tracker": null}' ] || fail "outside every org"
[ "$(trk ref '#4821' "$C/r10/app")" = '{"kind": "ado", "id": "4821", "url": "https://dev.azure.com/Grupo%20OTG/R10%20Score/_workitems/edit/4821"}' ] || fail "ado ref"
trk ref LC-1 "$C/r10/app" >/dev/null 2>&1 && fail "a key is not an ADO card"
[ "$(trk ref 77 "$C/likin/app")" = '{"kind": "jira", "id": "LC-77", "url": "https://x.atlassian.net/browse/LC-77"}' ] || fail "jira number gets the project key"
[ "$(trk ref lc-9 "$C/likin/app" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')" = "LC-9" ] || fail "jira key uppercased"
rc=0; trk ref 1 "$C/other" >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || fail "no tracker exits 2"
[ "$(trk env "$C/r10/app")" = "$(printf "export ADO_ORG='Grupo OTG'\nexport ADO_PROJECT='R10 Score'")" ] || fail "ado env"
[ -z "$(trk env "$C/likin/app")" ] || fail "jira has no env"

echo "- pr-registry: register stores the card as tracker, or null without one"
H=$(tmp); git -C "$H" init -q demo; mkdir -p "$H/.claude"; ln -s "$BIN" "$H/.claude/bin"
(cd "$H/demo" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$BIN/pr-registry.sh" register 7 feat/x main "T" https://github.com/o/demo/pull/7 jira LC-1 https://x/browse/LC-1 >/dev/null)
(cd "$H/demo" && HOME="$H" CLAUDE_HOME="$H/.claude" bash "$BIN/pr-registry.sh" register 8 feat/y main "U" https://github.com/o/demo/pull/8 >/dev/null)
python3 -c "
import json,sys
prs={p['pr_number']:p for p in json.load(open(sys.argv[1]))['prs']}
assert prs[7]['tracker']=={'kind':'jira','id':'LC-1','url':'https://x/browse/LC-1'}, prs[7]
assert prs[8]['tracker'] is None and 'ado_id' not in prs[8], prs[8]
" "$H/.claude/workflow/demo/prs.json" || fail "registry tracker"

echo "- verify/complete: verified binds to the tree, stale/forged/unverified cannot complete, only a human exception can"
GH=$(tmp); mkdir -p "$GH/.claude"; ln -s "$BIN" "$GH/.claude/bin"
GR=$(tmp); git -C "$GR" init -q; echo a > "$GR/a.dart"; git -C "$GR" add .; git -C "$GR" -c user.email=t@t -c user.name=t commit -qm init
GW="$GH/.claude/workflow/gp"; mkdir -p "$GW/runs/v1"
printf '{"feature":"Login","start_date":"2026-11-01","exec":{}}' > "$GW/current.json"
REV=$("$BIN/wf-checkpoint.sh" create "$GR"); echo "$REV" > "$GW/runs/v1/rev.tree"
verified_result() {
  cat <<JSON
{"status":"verified","reason":"VERIFIED","tasks":[],"trace":[],
 "decision":{"status":"verified","reason_code":"VERIFIED","reasons":[],"repo":"$GR","revision_start":"@$GW/runs/v1/rev.tree",
   "criteria":{"total":1,"passed":1,"failed":0,"partial":0,"untestable":0},"gates_run":["G1","G2"],"evidence_refs":["flutter test"]},
 "report":{"round":1,"g1":[{"gate":"G1","verdict":"pass","findings":[]}],
   "g2":{"verdict":"pass","criteria":[{"criterion":"c1","status":"PASS","evidence":"test/a_test.dart"}],"findings":[]}}}
JSON
}
persist() { HOME="$GH" python3 "$BIN/wf-event.py" persist --run-dir "$GW/runs/$1" --workflow-dir "$GW" --result-file "$2" >/dev/null; }
check() { HOME="$GH" python3 "$BIN/wf_gate.py" complete-check --workflow-dir "$GW"; }
verified_result > "$GW/r.json"; persist v1 "$GW/r.json"
python3 -c "
import json,sys; d=json.load(open(sys.argv[1])); v=d['exec']['verify']
assert v['status']=='verified' and v['revision_id']==sys.argv[2] and v['run']=='v1', v
r=json.load(open(sys.argv[3])); assert r['decision']['revision_id']==sys.argv[2]
" "$GW/current.json" "$REV" "$GW/runs/v1/result.json" || fail "persist binds verified to the revision"
check >/dev/null || fail "AC-08: verified for the current tree completes"
HOME="$GH" bash "$BIN/capture-metrics.sh" start verify gp "$GR" >/dev/null; HOME="$GH" bash "$BIN/capture-metrics.sh" end verify gp "$GR" >/dev/null
[ "$(python3 -c "import json;print(json.load(open('$GW/current.json'))['status'])")" = "verified" ] || fail "capture-metrics keeps verified"

echo b > "$GR/b.dart"
out=$(check) && fail "AC-12: tree changed after verify must not complete"
echo "$out" | grep -q '"reason_code": "REVISION_CHANGED"' || fail "AC-12 reason: $out"
rm "$GR/b.dart"

echo c >> "$GR/a.dart"; persist v1 "$GW/r.json"; git -C "$GR" checkout -q -- a.dart
[ "$(python3 -c "import json;print(json.load(open('$GW/runs/v1/result.json'))['reason'])")" = "REVISION_CHANGED" ] || fail "tree moved during verify downgrades to unverified"
check >/dev/null && fail "moved-during-verify result must not complete"

python3 -c "
import json,sys; r=json.loads(open(sys.argv[1]).read()); r['report']['g2']['criteria'][0]['status']='UNTESTABLE'
open(sys.argv[2],'w').write(json.dumps(r))" "$GW/r.json" "$GW/forged.json"
persist v1 "$GW/forged.json"
out=$(check) && fail "forged verified status with UNTESTABLE criteria must not complete"
echo "$out" | grep -q 'VERIFY_INCONSISTENT' || fail "forged reason: $out"

python3 -c "
import json,sys; r=json.loads(open(sys.argv[1]).read()); r['status']=r['decision']['status']='unverified'; r['reason']=r['decision']['reason_code']='G2_FAIL'
open(sys.argv[2],'w').write(json.dumps(r))" "$GW/r.json" "$GW/unv.json"
persist v1 "$GW/unv.json"
out=$(check) && fail "AC-11: unverified must not complete"
echo "$out" | grep -q '"reason_code": "G2_FAIL"' || fail "AC-11 reason: $out"
HOME="$GH" bash "$BIN/capture-metrics.sh" start verify gp "$GR" >/dev/null; HOME="$GH" bash "$BIN/capture-metrics.sh" end verify gp "$GR" >/dev/null
[ "$(python3 -c "import json;print(json.load(open('$GW/current.json'))['status'])")" = "unverified" ] || fail "capture-metrics must not mint verified"
HOME="$GH" bash "$BIN/archive-cycle.sh" completed gp >/dev/null 2>&1 && fail "AC-11: archive completed without verify"
[ -f "$GW/current.json" ] || fail "refused archive must keep the cycle"

python3 - "$GW" "$GR" "$BIN" <<'PY' || fail "AC-13/AC-14: human exception"
import json, sys
from pathlib import Path
wf, repo = Path(sys.argv[1]), sys.argv[2]
sys.path.insert(0, sys.argv[3]); import wf_gate as g
g.confirm = lambda text: False
assert not g.accept_unverified(wf, "QA manual ok", ["sem golden"], "complete")["accepted"], "dialog refused must reject"
assert not g.accept_unverified(wf, "  ", ["r"], "complete")["accepted"], "empty reason must reject"
assert not g.accept_unverified(wf, "motivo", [], "complete")["accepted"], "no risk must reject"
cur = json.loads((wf / "current.json").read_text())
cur["exec"]["override"] = {"actor": "agent", "at": "x", "reason": "r", "risks": ["r"], "revision_id": g.snapshot(repo)}
(wf / "current.json").write_text(json.dumps(cur))
c = g.complete_check(wf)
assert not c["allowed"] and c["override_error"] == "OVERRIDE_NOT_HUMAN", c
g.confirm = lambda text: "Motivo: QA manual ok" in text
r = g.accept_unverified(wf, "QA manual ok", ["sem golden"], "complete")
assert r["accepted"] and r["override"]["confirmed_via"] == "macos_dialog" and r["override"]["verify_status"] == "unverified", r
c = g.complete_check(wf)
assert c["allowed"] and c["human_override"] and c["verdict"] == "unverified", c
assert len((wf / "overrides.jsonl").read_text().splitlines()) == 1
Path(repo, "late.dart").write_text("x")
c = g.complete_check(wf)
assert not c["allowed"] and c["override_error"] == "OVERRIDE_STALE_REVISION", c
Path(repo, "late.dart").unlink()
PY
HOME="$GH" bash "$BIN/archive-cycle.sh" completed gp >/dev/null || fail "AC-13: archive with human exception"
GC=$(ls -d "$GH/.claude/projects/gp/history/"*_login)
python3 -c "
import json; m=json.load(open('$GC/metrics.json'))['verify']; assert m['human_override'] is True and m['verdict']=='unverified', m
" || fail "AC-13: history records human_override without verified"
[ -f "$GC/overrides.jsonl" ] && [ -f "$GC/completion.json" ] || fail "AC-15: exception and completion evidence archived"

mkdir -p "$GW/runs/i1" "$GW/runs/v1"; printf '{"feature":"Login","exec":{"verify":{"run":"v1","status":"verified"}}}' > "$GW/current.json"
echo '{"status":"done","tasks":[],"trace":[]}' > "$GW/i.json"; persist i1 "$GW/i.json"
python3 -c "import json;assert 'verify' not in json.load(open('$GW/current.json'))['exec']" || fail "a later implement run invalidates the verify of record"
echo '{bad' > "$GW/runs/v1/result.json"; printf '{"feature":"Login","exec":{"verify":{"run":"v1","status":"verified","repo":"'"$GR"'"}}}' > "$GW/current.json"
out=$(check) && fail "corrupted result.json must not complete"
echo "$out" | grep -q VERIFY_RESULT_UNREADABLE || fail "corrupted reason: $out"

echo "- tasks-check: Red-only tasks and tests nobody creates are rejected before implement"
TW=$(tmp); TR=$(tmp); mkdir -p "$TR/test"; echo t > "$TR/test/old_test.dart"
tc() { python3 "$BIN/wf_gate.py" tasks-check --workflow-dir "$TW" --repo "$TR"; }
python3 - "$TW" <<'PY'
import json, sys
D = lambda done: "**Contexto:** Passo 1.\n\n**O que fazer:**\n- x\n\n**Testes:**\n- t\n\n**Concluído quando:**\n" + done
b = {"complexity": "S", "risk": "low", "tier0": "haiku", "status": "pending"}
items = [
  {**b, "id": "T1", "title": "Teste do LoginBloc", "description": D("- teste escrito"), "affects": ["test/login_bloc_test.dart"], "tests": ["test/login_bloc_test.dart"]},
  {**b, "id": "T2", "title": "LoginBloc", "description": D("- teste passa"), "affects": ["lib/login_bloc.dart"], "tests": ["test/login_bloc_test.dart"], "depends_on": ["T1"]},
  {**b, "id": "T3", "title": "Validação", "description": D("- testes falhando aguardando implementação"), "affects": ["lib/v.dart", "test/v_test.dart"], "tests": ["test/v_test.dart"]},
  {**b, "id": "T4", "title": "Repo", "description": D("- ok"), "affects": ["lib/r.dart"], "tests": ["test/ghost_test.dart"], "depends_on": ["T9"]},
]
json.dump({"tasks": {"items": items}}, open(sys.argv[1] + "/current.json", "w"))
PY
out=$(tc) && fail "AC-09: Red-only plan must be rejected"
python3 -c "
import json,sys; e={(x['task'],x['code']) for x in json.loads(sys.argv[1])['errors']}
want={('T1','RED_ONLY'),('T3','RED_ONLY'),('T4','TEST_NOT_PRODUCED'),('T4','BAD_DEPENDENCY')}
assert e==want, e" "$out" || fail "AC-09 errors: $out"
python3 - "$TW" <<'PY'
import json, sys
D = lambda done: "**Contexto:** Passo 1.\n\n**O que fazer:**\n- x\n\n**Testes:**\n- t\n\n**Concluído quando:**\n" + done
b = {"complexity": "M", "risk": "low", "tier0": "sonnet", "status": "pending"}
items = [
  {**b, "id": "T1", "title": "LoginBloc (Red→Green)", "description": D("- teste falha antes da implementação e passa no fim"), "affects": ["lib/login_bloc.dart", "test/login_bloc_test.dart"], "tests": ["test/login_bloc_test.dart"]},
  {**b, "id": "T2", "title": "Regressão do bug de logout", "description": D("- `test/old_test.dart` cobre o caso e passa"), "affects": ["test/old_test.dart"], "tests": ["test/old_test.dart"], "depends_on": ["T1"]},
]
json.dump({"tasks": {"items": items}}, open(sys.argv[1] + "/current.json", "w"))
PY
tc >/dev/null || fail "AC-10: Red→Green in one task and a standalone regression test are accepted: $(tc)"

echo "- harness-audit: g2 targets come from the app roots and platform dirs of the repo"
G=$(tmp); mkdir -p "$G/apps/loja/lib" "$G/apps/loja/web" "$G/apps/loja/macos" "$G/apps/loja/build/web" "$G/packages/core/lib" "$G/mobile/lib" "$G/mobile/android"
touch "$G/pubspec.yaml" "$G/apps/loja/pubspec.yaml" "$G/apps/loja/lib/main.dart" "$G/packages/core/pubspec.yaml" "$G/mobile/pubspec.yaml" "$G/mobile/lib/main.dart"
python3 - "$BIN" "$G" <<'PY' || fail "g2 targets"
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("ha", sys.argv[1] + "/harness-audit.py"); ha = importlib.util.module_from_spec(spec); spec.loader.exec_module(ha)
repo = Path(sys.argv[2]).resolve(); prof = {"name": "flutter", "g2_device": "auto"}
devs = [{"id": "chrome", "name": "Chrome", "targetPlatform": "web-javascript"}, {"id": "macos", "name": "macOS", "targetPlatform": "darwin-arm64"}]
got = {(t["app"], t["platform"], t["device"]) for t in ha.g2_targets(prof, repo, devs)}
assert got == {("apps/loja", "web", "chrome"), ("apps/loja", "macos", "macos"), ("mobile", "android", None)}, got
ids = lambda out: [(f["id"], f["severity"]) for f in out]
ha.flutter_devices = lambda prof, repo: devs
out = []; ha.check_g2_device(prof, repo, "verify", out)
assert ids(out) == [("G2-TARGET-SKIP", "minor")], out
ha.flutter_devices = lambda prof, repo: []
out = []; ha.check_g2_device(prof, repo, "verify", out)
assert ("G2-DEVICE", "critical") in ids(out), out
out = []; ha.check_g2_device(prof, repo, "kickoff", out)
assert ("G2-DEVICE", "major") in ids(out), out
out = []; ha.check_g2_device(prof, repo / "packages" / "core", "verify", out)
assert ids(out) == [("G2-PLATFORM", "major")], out
PY

echo "- docs: the architecture map is documented next to brief plan and brief pr, and the ADR is indexed"
DOCS_ROOT="$(cd "$BIN/.." && pwd)"
for f in docs/smart-flow.md README.md; do
  grep -Eq 'brief plan.*map|map.*brief plan' "$DOCS_ROOT/$f" || fail "$f: map next to brief plan"
  grep -Eq 'brief pr.*map|map.*brief pr' "$DOCS_ROOT/$f" || fail "$f: map next to brief pr"
done
grep -q 'built-map' "$DOCS_ROOT/docs/smart-flow.md" || fail "smart-flow.md: built-map row"
ADR30="$DOCS_ROOT/docs/adr/0030-mapa-de-arquitetura-nos-gates.md"
[ -f "$ADR30" ] || fail "ADR 0030 missing"
grep -q '^status: accepted$' "$ADR30" || fail "ADR 0030 status"
grep -E '^affects:' "$ADR30" | grep -q 'bin/wf-report.py' || fail "ADR 0030 affects"
ADRT=$(tmp); cp -R "$DOCS_ROOT/docs/adr" "$ADRT/adr"; mkdir -p "$ADRT/docs"; mv "$ADRT/adr" "$ADRT/docs/adr"
python3 "$BIN/adr-index.py" reindex "$ADRT" >/dev/null || fail "reindex on a copy"
cmp -s "$ADRT/docs/adr/INDEX.md" "$DOCS_ROOT/docs/adr/INDEX.md" || fail "docs/adr/INDEX.md is not what reindex writes"

echo "- gen.sh: a project with repo whose gate pr has no map fails (sandbox, never the committed fixtures)"
T=$(tmp); G="$T/app/test/fixtures"; mkdir -p "$G/src"
cp "$DOCS_ROOT/app/test/fixtures/gen.sh" "$G/gen.sh"
ln -s "$DOCS_ROOT/bin" "$T/bin"; ln -s "$DOCS_ROOT/stacks" "$T/stacks"
cat > "$G/src/semmapa.json" <<'JSON'
{"current": {"feature": "Sem mapa", "start_date": "2026-03-12T08:00:00Z", "exec": {}},
 "runs": [],
 "repo": {"base": {"lib/a.dart": "a\n"}, "tree": {"lib/a.dart": "b\n"}},
 "files": {"pr.diff": ""},
 "report": [
  {"cmd": "stage-start", "stage": "plan"},
  {"cmd": "brief", "name": "plan", "file": {"summary": "Plano sem mapa.", "artifact": "plan.md"}},
  {"cmd": "stage-start", "stage": "complete"},
  {"cmd": "brief", "name": "pr", "file": {"summary": "PR sem mapa.", "artifact": "pr.diff"}}
 ]}
JSON
bash "$G/gen.sh" >/dev/null 2>"$T/err" && fail "gen.sh with repo and no map must fail"
grep -q "semmapa.json tem repo e o gate pr ficou sem map" "$T/err" || fail "gen.sh guard message: $(cat "$T/err")"

echo "OK"
