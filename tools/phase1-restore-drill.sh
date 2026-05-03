#!/bin/bash
# Restore drill — full backup → restore loop on the same pod.
#
# 1. Snapshot current triple counts in graph/ontology and graph/data
# 2. CLEAR both graphs
# 3. Reload from /backup/<latest>/*.nt via /sparql-graph-crud-auth
# 4. Re-run the 4 verification queries
# 5. Confirm results match the pre-clear state
set -euo pipefail

NS=gmr
POD=virtuoso-0
TBOX_GRAPH="http://data.fontem.eu/graph/ontology"
DATA_GRAPH="http://data.fontem.eu/graph/data"
RULESET="urn:fontem:phase1:rules"
DBA_PASS=$(kubectl get secret -n "$NS" virtuoso-credentials -o jsonpath='{.data.VIRTUOSO_DBA_PASSWORD}' | base64 -d)

isql() {
    kubectl exec -n "$NS" -i "$POD" -- /opt/virtuoso-opensource/bin/isql 1111 dba "$DBA_PASS"
}

count_triples() {
    local graph="$1"
    # isql output for SPARQL count: header line, type line, dashes, value, blank, "1 Rows."
    # Extract the integer line that comes after the dashes.
    printf "SPARQL SELECT COUNT(*) FROM <%s> WHERE { ?s ?p ?o };\n" "$graph" | isql 2>&1 \
        | awk '/^_{20,}/{getline; print; exit}' \
        | tr -d ' '
}

echo "==> snapshot triple counts before restore"
TBOX_BEFORE=$(count_triples "$TBOX_GRAPH")
DATA_BEFORE=$(count_triples "$DATA_GRAPH")
echo "    ontology=$TBOX_BEFORE  data=$DATA_BEFORE"

LATEST=$(kubectl exec -n "$NS" "$POD" -- bash -c 'ls -1d /backup/virtuoso-* 2>/dev/null | sort -r | head -1')
echo "==> restoring from $LATEST"

echo "==> CLEAR both graphs"
printf "SPARQL CLEAR GRAPH <%s>;\n" "$TBOX_GRAPH" | isql >/dev/null
printf "SPARQL CLEAR GRAPH <%s>;\n" "$DATA_GRAPH" | isql >/dev/null

echo "    after clear: ontology=$(count_triples "$TBOX_GRAPH")  data=$(count_triples "$DATA_GRAPH")"

echo "==> reloading from backup .nt files"
# Use TTLP_MT to load N-Triples (it auto-detects format).
echo "  - $LATEST/ontology.nt -> <$TBOX_GRAPH>"
printf "DB.DBA.TTLP_MT(file_to_string_output('%s/ontology.nt'), '', '%s');\n" "$LATEST" "$TBOX_GRAPH" | isql >/dev/null
echo "  - $LATEST/data.nt -> <$DATA_GRAPH>"
printf "DB.DBA.TTLP_MT(file_to_string_output('%s/data.nt'), '', '%s');\n" "$LATEST" "$DATA_GRAPH" | isql >/dev/null

TBOX_AFTER=$(count_triples "$TBOX_GRAPH")
DATA_AFTER=$(count_triples "$DATA_GRAPH")
echo "==> after restore: ontology=$TBOX_AFTER  data=$DATA_AFTER"

if [[ "$TBOX_BEFORE" != "$TBOX_AFTER" || "$DATA_BEFORE" != "$DATA_AFTER" ]]; then
    echo "==> COUNT MISMATCH — restore did not yield identical triple counts"
    echo "    ontology: $TBOX_BEFORE -> $TBOX_AFTER"
    echo "    data:     $DATA_BEFORE -> $DATA_AFTER"
    exit 1
fi

echo "==> rebuilding reasoner ruleset + materialising property chain"
printf "rdfs_rule_set('%s', '%s');\n" "$RULESET" "$TBOX_GRAPH" | isql >/dev/null
printf "SPARQL\nPREFIX fontem: <http://data.fontem.eu/ontology#>\nINSERT { GRAPH <%s> { ?auth fontem:client ?co . ?co fontem:supplier ?auth . } } WHERE { GRAPH <%s> { ?auth a fontem:Authority ; fontem:awarded ?ct . ?ct fontem:awardedTo ?co . } } ;\n" "$DATA_GRAPH" "$DATA_GRAPH" | isql >/dev/null

echo "==> verification queries against restored data"
SVC=http://virtuoso.gmr.svc.cluster.local:8890/sparql
fail=0

run_q() {
    local label="$1" body="$2" expected_file="$3"
    local prefixed
    prefixed=$(printf "DEFINE input:inference '%s'\nDEFINE input:default-graph-uri <%s>\n%s" "$RULESET" "$DATA_GRAPH" "$body")
    local enc
    enc=$(python3 -c 'import sys, urllib.parse; sys.stdout.write(urllib.parse.quote(sys.stdin.read(), safe=""))' <<< "$prefixed")
    local actual
    actual=$(kubectl exec -n "$NS" "$POD" -- wget -qO- \
        --header='Accept: text/csv' \
        "${SVC}?query=${enc}" \
        | tr -d '\r' | tail -n +2 \
        | sed -e 's/"//g' -e 's/,/\t/g' \
        | sort)
    local expected
    expected=$(sort "$expected_file")
    if [[ "$actual" == "$expected" ]]; then
        echo "  ✓ $label"
    else
        echo "  ✗ $label"
        diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed 's/^/      /'
        fail=$((fail+1))
    fi
}

REPO=/config/repos/fontem-ontology
for q in 01-client-derived 02-contract-count 03-supplier-inverse 04-class-hierarchy; do
    body=$(grep -v '^[[:space:]]*#' "$REPO/tools/smoke/queries/$q.sparql" | grep -v '^[[:space:]]*$')
    run_q "$q" "$body" "$REPO/tools/smoke/expected/$q.txt"
done

if [[ $fail -gt 0 ]]; then
    echo "==> RESTORE DRILL FAILED ($fail mismatches)"
    exit 1
fi
echo "==> RESTORE DRILL PASSED"
