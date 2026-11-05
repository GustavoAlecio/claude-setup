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
echo "OK"
