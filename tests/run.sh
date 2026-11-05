#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
bash bin.test.sh
node --test ./*.test.mjs
bash ../app/test/fixtures/gen.sh --check
