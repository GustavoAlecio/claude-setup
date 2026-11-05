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

echo "OK"
