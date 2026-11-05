#!/bin/bash
# Must stay sourceable from zsh too: skills run `source ~/.claude/bin/get-project.sh` in the user's shell.
# Same rule as projectNameFor/inspectDirectory in app/lib/data; app/test/data/project_name_test.dart checks parity.
get-project-name() {
    local top root common raw remote name workflow
    workflow="${CLAUDE_HOME:-$HOME/.claude}/workflow"
    remote=""
    if top=$(git rev-parse --path-format=absolute --show-toplevel --git-common-dir 2>/dev/null); then
        root=$(printf '%s\n' "$top" | sed -n 1p)
        common=$(printf '%s\n' "$top" | sed -n 2p)
        raw=${root##*/}
        if [ "$common" != "$root/.git" ] && [ "${common%/.git}" != "$common" ]; then
            common=${common%/.git}
            raw=${common##*/}
        fi
        remote=$(git config --get remote.origin.url 2>/dev/null)
    else
        raw=$(basename "$(pwd)")
    fi
    name=""
    if [ -n "$remote" ]; then
        name=${remote##*[:/]}
        name=${name%.git}
    fi
    [ -n "$name" ] || name=$raw
    name=$(printf '%s' "$name" | tr '_' '-')
    if [ "$name" != "$raw" ] && [ ! -d "$workflow/$name" ] && [ -d "$workflow/$raw" ]; then
        echo "workflow existente em $raw; usando $raw (remote: $name)" >&2
        name=$raw
    fi
    echo "$name"
}

if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
    get-project-name
fi
