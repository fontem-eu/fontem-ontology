# Phase 0 smoke — dockerised Virtuoso for the reasoner check.
#
# The TBox and fixtures are baked into the image. CI rebuilds the
# image whenever ontology/ or tools/smoke/fixtures/ changes; the
# resulting container runs without any bind mounts (one fewer thing
# to fail). Memory tuned for CI: NumberOfBuffers=32000 (~256 MB
# working set), 4 server threads, total footprint ~512 MB.
#
# Build context expected: repository root.

# Pinned by digest, not by tag. On 2026-08-05 Docker Hub re-pushed
# `7.2.17` as a 7.2.18-dev build whose reasoner rejects the property-chain
# query (SP031), and this smoke went red with no change of ours. The
# digest is the 7.2.16 release, identical to the image prod and shared run
# (our signed mirror, contribute.void42.internal/fontem/virtuoso-opensource-7),
# so the smoke tests the engine production actually uses. Renovate
# (pinDigests) proposes tag and digest updates as reviewable PRs.
FROM openlink/virtuoso-opensource-7:7.2.17@sha256:0dbe1ab4fa0cb7bbafc1f6c0c2b0a5d6f22d918dbd17672f2ddb24580aa6756a

ENV VIRT_Parameters_NumberOfBuffers=32000 \
    VIRT_Parameters_MaxCheckpointRemap=8000 \
    VIRT_Parameters_DefaultIsolation=2 \
    VIRT_Parameters_ServerThreads=4 \
    VIRT_Parameters_DirsAllowed="., /opt/virtuoso-opensource/share, /opt/virtuoso-opensource/vad, /import" \
    DBA_PASSWORD=fontem-smoke-dba

# TBox + fixtures baked in. Order: ontology before fixtures so
# image-cache invalidation is granular per area. Fixtures live at
# tools/smoke/fixtures/ (shared across engines); the Virtuoso-specific
# Dockerfile + run.sh + post-load.sparql are in this directory.
COPY ontology/             /import/ontology/
COPY tools/smoke/fixtures/ /import/fixtures/

# Healthcheck: SPARQL endpoint up + responding.
HEALTHCHECK --interval=2s --timeout=2s --start-period=20s --retries=15 \
    CMD curl -fsS http://localhost:8890/sparql?query=ASK%20%7B%7D || exit 1
