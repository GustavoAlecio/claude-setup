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
wfr() { HOME="$HOME_BIN_SHIM" python3 "$BIN/wf-report.py" "$@"; }
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

echo "- wf-report: stage-start records session_id only when --session is given"
S=$(tmp)
printf '{"feature":"Feat S","start_date":"2026-02-01T00:00:00Z"}' > "$S/current.json"
wfr stage-start plan --workflow-dir "$S"
wfr stage-start tasks --workflow-dir "$S" --session sess-42
python3 -c "
import json; st={x['stage']:x for x in json.load(open('$S/report.json'))['stages']}
assert 'session_id' not in st['plan'], st['plan']
assert st['tasks']['session_id']=='sess-42', st['tasks']
" || fail "session_id in stage-start"

echo "- wf-report: gate asks with autopilot off, follows gates.json with it on, exit 2 on unknown name"
GATE_HOME=$(tmp); mkdir -p "$GATE_HOME/.claude/workflow"; ln -s "$BIN" "$GATE_HOME/.claude/bin"
gate() { HOME="$GATE_HOME" python3 "$BIN/wf-report.py" gate "$1"; }
gates_are() { local want="$1" got=""; for g in spec plan tasks pr; do got="$got$g=$(gate "$g") "; done; [ "$got" = "$want" ] || fail "gate: want '$want', got '$got' ($2)"; }
gates_are "spec=ask plan=ask tasks=ask pr=ask " "autopilot off"
printf '{"required":["plan"]}' > "$GATE_HOME/.claude/workflow/gates.json"
gates_are "spec=ask plan=ask tasks=ask pr=ask " "autopilot off ignores gates.json"
rm "$GATE_HOME/.claude/workflow/gates.json"; touch "$GATE_HOME/.claude/workflow/auto_mode.flag"
gates_are "spec=ask plan=skip tasks=skip pr=ask " "no gates.json"
printf '{"required":["plan"]}' > "$GATE_HOME/.claude/workflow/gates.json"
gates_are "spec=skip plan=ask tasks=skip pr=skip " "required plan"
for bad in '{not json' '[]' '{"required":"plan"}' '{"required":[1]}' '{}'; do
  printf '%s' "$bad" > "$GATE_HOME/.claude/workflow/gates.json"
  gates_are "spec=ask plan=skip tasks=skip pr=ask " "invalid gates.json: $bad"
done
got=0; gate deploy >/dev/null 2>&1 || got=$?; [ "$got" = 2 ] || fail "gate deploy: expected exit 2, got $got"
got=0; HOME="$GATE_HOME" python3 "$BIN/wf-report.py" gate >/dev/null 2>&1 || got=$?; [ "$got" = 2 ] || fail "gate without name: expected exit 2, got $got"

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
HOME="$H" bash "$BIN/archive-cycle.sh" completed proj "Feat B" >/dev/null
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
PRIV='Grupo''OTG\|loss''-control\|r10''-mobile\|R10 Score Dev\|/development/r10\|/development/abm'
[ -z "$(grep -rn "$PRIV" "$SKILLS" || true)" ] || fail "private names in skills"

echo "- skills: gates are AskUserQuestion with the three options, no 'Seguir para', stage-start carries --session"
for f in "$SKILLS"/*/SKILL.md; do
  for n in $(grep -n 'wf-report.py gate ' "$f" | cut -d: -f1); do
    win=$(sed -n "${n},$((n + 15))p" "$f")
    for opt in 'Aprovar (Recommended)' 'Ajustar' 'Rejeitar'; do
      printf '%s\n' "$win" | grep -q "$opt" || fail "$f:$n: gate without '$opt' within 15 lines"
    done
  done
done
for s in challenge-spec plan tasks; do
  [ "$(grep -c 'wf-report.py gate ' "$SKILLS/$s/SKILL.md")" = "1" ] || fail "$s: expected exactly one gate"
done
[ -z "$(grep -ln 'Seguir para' "$SKILLS"/{specify,challenge-spec,plan,tasks}/SKILL.md || true)" ] || fail "'Seguir para' still in skills"
for s in kickoff specify challenge-spec plan tasks implement verify; do
  grep 'wf-report.py stage-start ' "$SKILLS/$s/SKILL.md" | grep -qv -- '--session "\$CLAUDE_FLOW_SESSION_ID"' && fail "$s: stage-start without --session"
done
grep -q 'gates.json' "$SKILLS/auto/SKILL.md" || fail "auto: does not explain gates"

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

echo "OK"
