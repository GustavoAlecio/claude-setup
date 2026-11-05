#!/usr/bin/env bash
# stdin: branch names (sem refs/heads/). stdout: base e versão X.Y.Z.
# exit 3: só há sufixos não-main na maior versão (stdout = candidatas); exit 1: nenhuma release elegível.
set -euo pipefail
re='^release/([0-9]+\.[0-9]+\.[0-9]+)(/.+)?$'
branches=(); versions=()
while IFS= read -r b; do
  if [[ "$b" =~ $re ]]; then branches+=("$b"); versions+=("${BASH_REMATCH[1]}"); fi
done
[ "${#branches[@]}" -gt 0 ] || exit 1
ver=$(printf '%s\n' "${versions[@]}" | sort -V | tail -1)
cands=()
for b in "${branches[@]}"; do
  case "$b" in "release/$ver"|"release/$ver/"*) cands+=("$b");; esac
done
for want in "release/$ver" "release/$ver/main"; do
  for b in "${cands[@]}"; do
    if [ "$b" = "$want" ]; then printf '%s\n%s\n' "$want" "$ver"; exit 0; fi
  done
done
printf '%s\n' "${cands[@]}"
exit 3
