#!/bin/sh
# Pure edge-rule tests for the Herdr mod (integrations/herdr-mod/edges.js).
# Needs node (built-in test runner); fails loudly without it — no fake green.
set -eu
cd "$(dirname "$0")/.."
if ! command -v node >/dev/null 2>&1; then
    echo "❌ node not found: install node to run the Herdr mod tests" >&2
    exit 1
fi
exec node --test integrations/herdr-mod/edges.test.mjs
