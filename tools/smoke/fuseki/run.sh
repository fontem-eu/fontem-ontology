#!/usr/bin/env bash
# Phase 0 reasoner smoke — Apache Jena Fuseki engine.
#
# Counterpart to tools/smoke/virtuoso/run.sh. Same fixtures, same
# queries, same expected outputs. Different engine.
#
# What's different from Virtuoso:
#   - Inference is configured via an assembler (config.ttl) that
#     wraps the in-memory dataset in an InfModel using
#     GenericRuleReasoner. Custom rules live in rules.txt.
#   - Property chain is implemented as a Jena rule (Jena's bundled
#     reasoner doesn't honour owl:propertyChainAxiom from the TBox).
#     But unlike Virtuoso's one-shot SPARQL INSERT, the Jena rule
#     fires on every query — there's no materialised state to drift.
#   - Triples are uploaded over HTTP rather than via an internal SQL
#     loader.
#
# Usage: bash tools/smoke/fuseki/run.sh
# Env: SMOKE_KEEP=1 to leave the container running afterwards.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
ENGINE_DIR="$REPO_ROOT/tools/smoke/fuseki"
SHARED_DIR="$REPO_ROOT/tools/smoke"
ONTOLOGY_DIR="$REPO_ROOT/ontology"
EXPECTED_DIR="$SHARED_DIR/expected"
QUERIES_DIR="$SHARED_DIR/queries"
FIXTURES_DIR="$SHARED_DIR/fixtures"

CONTAINER=fontem-smoke-fuseki
IMAGE=fontem-smoke-fuseki:latest
ADMIN_PASS=fontem-smoke-admin
DATASET=fontem
PORT=3030

cleanup() {
    if [[ "${SMOKE_KEEP:-0}" != "1" ]]; then
        docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    else
        echo "==> SMOKE_KEEP=1: leaving $CONTAINER running. SPARQL UI: http://localhost:$PORT/$DATASET/sparql"
    fi
}
trap cleanup EXIT

# ── 1. Build the image. Same context as Virtuoso (repo root) so the
# image carries the latest ontology + fixtures.
echo "==> building $IMAGE"
docker build -q -f "$ENGINE_DIR/Dockerfile" -t "$IMAGE" "$REPO_ROOT" >/dev/null

# ── 2. Run. Mount config + rules so Fuseki uses our assembler.
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
# Config + rules are baked into the image (see Dockerfile).
# fuseki-server auto-loads /fuseki/config.ttl on startup.
docker run -d --name "$CONTAINER" -p "$PORT:3030" \
    -e ADMIN_PASSWORD="$ADMIN_PASS" \
    "$IMAGE" >/dev/null

echo "==> waiting for Fuseki to come up"
for _ in {1..60}; do
    if curl -fsS "http://localhost:$PORT/\$/ping" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# ── 3. Upload TBox + fixtures via the Graph Store Protocol.
# Each Turtle file is POSTed to /fontem/data which Fuseki adds to
# the default graph (which is wrapped in the InfModel — so the
# reasoner sees both schema and data immediately).

echo "==> loading TBox + fixtures into the inference dataset"
upload() {
    local file="$1"
    local label="$2"
    echo "  - $label"
    local code
    # Fuseki's default shiro.ini protects /*/data/** behind basic
    # auth (admin user). SPARQL reads stay anonymous.
    code=$(curl -sS -o /tmp/upload.body -w "%{http_code}" \
        -u "admin:$ADMIN_PASS" \
        -X POST "http://localhost:$PORT/$DATASET/data?default" \
        -H "Content-Type: text/turtle" \
        --data-binary "@$file")
    if [[ "$code" -ge 400 ]]; then
        echo "    HTTP $code:"
        cat /tmp/upload.body | sed 's/^/      /'
        exit 1
    fi
}

for tbox in core.ttl procurement.ttl corporate.ttl lobbying.ttl sanctions.ttl cohesion.ttl geo.ttl meta.ttl; do
    [[ -f "$ONTOLOGY_DIR/$tbox" ]] && upload "$ONTOLOGY_DIR/$tbox" "tbox/$tbox"
done

for fix in "$FIXTURES_DIR"/*.ttl; do
    upload "$fix" "fixture/$(basename "$fix")"
done

# ── 4. Run each verification query via the SPARQL HTTP endpoint.
# Same diff harness as the Virtuoso engine for parity.
echo "==> running verification queries"
fail=0

run_query() {
    local query_file="$1"
    local expected_file="$2"
    local label
    label=$(basename "$query_file" .sparql)

    local body
    body=$(grep -v '^[[:space:]]*#' "$query_file" | grep -v '^[[:space:]]*$')

    local actual
    actual=$(curl -sS -G \
        --data-urlencode "query=$body" \
        -H 'Accept: text/csv' \
        "http://localhost:$PORT/$DATASET/sparql" \
        | tr -d '\r' \
        | tail -n +2 \
        | sed -e 's/"//g' -e 's/,/	/g' \
        | sort)

    local expected
    expected=$(sort "$expected_file")

    if [[ "$actual" == "$expected" ]]; then
        echo "  ✓ $label"
    else
        echo "  ✗ $label — mismatch"
        diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed 's/^/      /'
        fail=$((fail + 1))
    fi
}

for q in "$QUERIES_DIR"/*.sparql; do
    name=$(basename "$q" .sparql)
    run_query "$q" "$EXPECTED_DIR/$name.txt"
done

if [[ $fail -gt 0 ]]; then
    echo
    echo "==> SMOKE FAILED ($fail mismatch(es))"
    exit 1
fi

echo
echo "==> SMOKE PASSED"
