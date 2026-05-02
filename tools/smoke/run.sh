#!/usr/bin/env bash
# Phase 0 reasoner smoke + permanent CI gate.
#
# Brings up a dockerised Virtuoso, loads:
#   - the Fontem TBox (ontology/*.ttl) — the schema to test
#   - the synthetic fixture (tools/smoke/fixtures/*.ttl)
# Configures the OWL2-RL inference rules, runs the verification
# queries via SPARQL/HTTP, diffs each against expected output.
# Non-zero exit on any mismatch → CI gate fails.
#
# Usage: bash tools/smoke/run.sh
# Env: SMOKE_KEEP=1 to keep container running after the run for
#      manual poking via http://localhost:8890/sparql
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SMOKE_DIR="$REPO_ROOT/tools/smoke"
ONTOLOGY_DIR="$REPO_ROOT/ontology"
EXPECTED_DIR="$SMOKE_DIR/expected"
QUERIES_DIR="$SMOKE_DIR/queries"
FIXTURES_DIR="$SMOKE_DIR/fixtures"

CONTAINER=fontem-ontology-smoke
IMAGE=fontem-ontology-smoke:latest
RULESET="urn:fontem:smoke:rules"
TBOX_GRAPH="http://data.fontem.eu/graph/tbox"
DATA_GRAPH="http://data.fontem.eu/graph/data"
DBA_PASS=fontem-smoke-dba

cleanup() {
    if [[ "${SMOKE_KEEP:-0}" != "1" ]]; then
        echo "==> cleanup: removing container $CONTAINER"
        docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    else
        echo "==> SMOKE_KEEP=1: leaving $CONTAINER running. SPARQL UI: http://localhost:8890/sparql"
    fi
}
trap cleanup EXIT

# ── 1. Build the image (cached if ontology/ + fixtures unchanged).
# Build context is the repo root because the Dockerfile COPYs from
# ontology/ and tools/smoke/fixtures/.
echo "==> building $IMAGE"
docker build -q -f "$SMOKE_DIR/Dockerfile" -t "$IMAGE" "$REPO_ROOT" >/dev/null

# ── 2. Run. TBox + fixtures are baked into the image at /import.
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" -p 8890:8890 "$IMAGE" >/dev/null

echo "==> waiting for Virtuoso to come up"
for i in {1..60}; do
    if curl -fsS "http://localhost:8890/sparql?query=ASK%20%7B%7D" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# ── 3. Load TBox + fixtures via isql + TTLP_MT
isql() {
    docker exec -i "$CONTAINER" /opt/virtuoso-opensource/bin/isql 1111 dba "$DBA_PASS"
}

echo "==> loading TBox into <$TBOX_GRAPH>"
for tbox in core.ttl procurement.ttl corporate.ttl lobbying.ttl sanctions.ttl cohesion.ttl geo.ttl meta.ttl; do
    if [[ -f "$ONTOLOGY_DIR/$tbox" ]]; then
        echo "  - $tbox"
        out=$(printf "DB.DBA.TTLP_MT(file_to_string_output('/import/ontology/%s'), '', '%s');\n" "$tbox" "$TBOX_GRAPH" | isql 2>&1)
        if echo "$out" | grep -qE 'Error|denied|Cannot'; then
            echo "$out" | grep -E 'Error|denied|Cannot' | sed 's/^/    /'
            exit 1
        fi
    fi
done

echo "==> loading fixtures into <$DATA_GRAPH>"
for fix in "$FIXTURES_DIR"/*.ttl; do
    name=$(basename "$fix")
    echo "  - $name"
    out=$(printf "DB.DBA.TTLP_MT(file_to_string_output('/import/fixtures/%s'), '', '%s');\n" "$name" "$DATA_GRAPH" | isql 2>&1)
    if echo "$out" | grep -qE 'Error|denied|Cannot'; then
        echo "$out" | grep -E 'Error|denied|Cannot' | sed 's/^/    /'
        exit 1
    fi
done

# ── 4. Configure native Virtuoso reasoning over (TBox ∪ data).
# Virtuoso supports a subset of OWL2 (subClassOf, subPropertyOf,
# inverseOf, TransitiveProperty, sameAs, equivalent*). It does NOT
# support owl:propertyChainAxiom — see step 5 for the workaround.
echo "==> configuring reasoner ruleset"
printf "rdfs_rule_set('%s', '%s');\n" "$RULESET" "$TBOX_GRAPH" | isql >/dev/null

# ── 5. Materialise the fontem:client / fontem:supplier chain.
# Workaround for Virtuoso's missing property-chain support: run
# the chain as a SPARQL UPDATE via isql. The triples land in the
# data graph, then the reasoner uses owl:inverseOf to derive the
# supplier side from the client side.
echo "==> materialising property chains (Virtuoso lacks owl:propertyChainAxiom)"
chain_query=$(grep -v '^[[:space:]]*#' "$SMOKE_DIR/post-load.sparql" | grep -v '^[[:space:]]*$')
{
    printf "SPARQL\n%s\n;\n" "$chain_query"
} | isql >/dev/null

# ── 6. Run each verification query via the SPARQL HTTP endpoint.
# Use CSV result format — predictable, tab-able, no banner noise.
echo "==> running verification queries"
fail=0

run_query() {
    local query_file="$1"
    local expected_file="$2"
    local label
    label=$(basename "$query_file" .sparql)

    # Strip comments + blank lines.
    local body
    body=$(grep -v '^[[:space:]]*#' "$query_file" | grep -v '^[[:space:]]*$')

    local prefixed_query
    prefixed_query=$(cat <<EOF
DEFINE input:inference '$RULESET'
DEFINE input:default-graph-uri <$DATA_GRAPH>
$body
EOF
)

    # POST as application/sparql-query, request CSV results, drop
    # the header row, sort for stability.
    local actual
    actual=$(curl -sS -G \
        --data-urlencode "query=$prefixed_query" \
        -H 'Accept: text/csv' \
        "http://localhost:8890/sparql" \
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
