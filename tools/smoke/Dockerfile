# Phase 0 smoke — dockerised Virtuoso for the reasoner check.
#
# The TBox and fixtures are baked into the image. CI rebuilds the
# image whenever ontology/ or tools/smoke/fixtures/ changes; the
# resulting container runs without any bind mounts (one fewer thing
# to fail). Memory tuned for CI: NumberOfBuffers=32000 (~256 MB
# working set), 4 server threads, total footprint ~512 MB.
#
# Build context expected: repository root.

FROM openlink/virtuoso-opensource-7:7.2.14

ENV VIRT_Parameters_NumberOfBuffers=32000 \
    VIRT_Parameters_MaxCheckpointRemap=8000 \
    VIRT_Parameters_DefaultIsolation=2 \
    VIRT_Parameters_ServerThreads=4 \
    VIRT_Parameters_DirsAllowed="., /opt/virtuoso-opensource/share, /opt/virtuoso-opensource/vad, /import" \
    DBA_PASSWORD=fontem-smoke-dba

# TBox + fixtures baked in. Order: ontology before fixtures so
# image-cache invalidation is granular per area.
COPY ontology/        /import/ontology/
COPY tools/smoke/fixtures/ /import/fixtures/

# Healthcheck: SPARQL endpoint up + responding.
HEALTHCHECK --interval=2s --timeout=2s --start-period=20s --retries=15 \
    CMD curl -fsS http://localhost:8890/sparql?query=ASK%20%7B%7D || exit 1
