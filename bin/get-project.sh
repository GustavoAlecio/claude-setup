#!/bin/bash
get-project-name() {
    local project_name=""
    if [ -d .git ] 2>/dev/null; then
        project_name=$(git config --get remote.origin.url 2>/dev/null | \
            sed 's|.*[:/]||' | sed 's|\.git$||' | sed 's|_|-|g')
    fi
    if [ -z "$project_name" ] && [ -n "$CURRENT_PROJECT" ]; then
        project_name="$CURRENT_PROJECT"
    fi
    if [ -z "$project_name" ]; then
        project_name=$(basename "$(pwd)" | sed 's|_|-|g')
    fi
    echo "$project_name"
}

if [ "$#" -eq 0 ]; then
    get-project-name
fi
