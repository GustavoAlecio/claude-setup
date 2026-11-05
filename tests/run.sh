#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
bash bin.test.sh
node --test ./*.test.mjs
bash ../app/test/fixtures/gen.sh --check
if [ ! -d ../engine/node_modules ]; then
  echo "rode: cd engine && npm ci" >&2
  exit 1
fi
node --test '../engine/test/*.test.mjs'
