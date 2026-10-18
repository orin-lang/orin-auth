#!/usr/bin/env bash
# Runs every check of this repository: the library tests, the known-answer tests of the temporary crypto (they live beside the code
# because tests/ cannot import private files), the example's tests and run, and formatting.
# ORIN selects the launcher (default: `orin` on PATH).
set -euo pipefail
cd "$(dirname "$0")/.."
ORIN="${ORIN:-orin}"

echo "== orin-auth tests"
"$ORIN" fetch
"$ORIN" test

echo "== internal tests (temporary crypto, key-value owner task)"
for f in src/internal/*_test.or; do
  "$ORIN" test "$f"
done

echo "== examples/web-login"
(cd examples/web-login && "$ORIN" fetch && "$ORIN" test && "$ORIN" run >/dev/null)

echo "== formatting"
# Named paths only: CI checks orin-lang out inside the workspace, and a bare `fmt --check` would scan it too.
"$ORIN" fmt --check src tests
(cd examples/web-login && "$ORIN" fmt --check src tests)

echo "ok"
