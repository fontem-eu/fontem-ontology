# Phase 0 smoke — dockerised Apache Jena Fuseki for the reasoner check.
#
# Counterpart to tools/smoke/virtuoso/Dockerfile. Same fixtures,
# same queries, same expected outputs — different engine. The
# whole point of running both is to compare their handling of
# owl:propertyChainAxiom (which Virtuoso doesn't natively support
# but Fuseki's OWL-FB rule reasoner does).
#
# Build context expected: repository root.

FROM stain/jena-fuseki:5.1.0

# TBox + fixtures baked in (same paths as the Virtuoso image).
# The run.sh loader uploads them through Fuseki's HTTP endpoints
# rather than baking them into the dataset at build time — that's
# the simplest way to keep the image generic and re-use the same
# bytes for any TBox change.
COPY ontology/             /staging/ontology/
COPY tools/smoke/fixtures/ /staging/fixtures/

# Assembler config + Jena rules. Baked in rather than mounted
# because /fuseki is a declared VOLUME in the upstream image and
# mounting a single file into a volume target produces broken
# behaviour ("file exists but unreadable: is a directory"). Build-
# time copy is the simplest fix.
COPY tools/smoke/fuseki/config.ttl /fuseki/config.ttl
COPY tools/smoke/fuseki/rules.txt  /fuseki-config/rules.txt

# Runtime tuning: small heap for CI. The fixtures are tiny (a few
# dozen triples) and the TBox is small (hundreds of triples), so
# 256 MiB is comfortable.
ENV JVM_ARGS="-Xms64m -Xmx256m" \
    ADMIN_PASSWORD=fontem-smoke-admin

# stain/jena-fuseki listens on 3030. Healthcheck via /$/ping.
EXPOSE 3030

HEALTHCHECK --interval=2s --timeout=2s --start-period=10s --retries=15 \
    CMD wget -q -O - http://localhost:3030/\$/ping || exit 1
