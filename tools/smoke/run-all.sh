#!/usr/bin/env bash
# Run both reasoner smokes — Virtuoso + Fuseki — sequentially.
# Used by CI to gate merges on both engines passing.
#
# Sequential (not parallel) to avoid two ~500 MB Docker containers
# spinning up at once on the CI runner.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)

echo "=========================================="
echo "  Virtuoso engine"
echo "=========================================="
bash "$REPO_ROOT/tools/smoke/virtuoso/run.sh"

echo
echo "=========================================="
echo "  Fuseki engine"
echo "=========================================="
bash "$REPO_ROOT/tools/smoke/fuseki/run.sh"

echo
echo "=========================================="
echo "  All engines passed"
echo "=========================================="
