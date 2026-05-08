#!/bin/bash
to-slug() {
    local input="$1"
    echo "$input" | \
        tr '[:upper:]' '[:lower:]' | \
        sed 's/[^a-z0-9-]/-/g' | \
        sed 's/-\{2,\}/-/g' | \
        sed 's/^-\|^-$//g'
}

if [ "$#" -gt 0 ]; then
    to-slug "$@"
fi
