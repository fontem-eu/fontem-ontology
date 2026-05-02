-- pgvector sidecar schema for embeddings. Lives in the existing
-- gmr-postgres deployment.
--
-- IRI is the foreign key into Virtuoso. Application code reads /
-- writes embeddings here, then resolves the IRI in Virtuoso for
-- the corresponding RDF triples.
--
-- Apply with:
--   kubectl exec -n gmr deploy/postgres -- \
--       psql -U postgres -f /tmp/10-pgvector-schema.sql
-- (after copying this file in via `kubectl cp`)

CREATE EXTENSION IF NOT EXISTS vector;
CREATE SCHEMA IF NOT EXISTS vectors;

-- LaBSE embeddings — 768-d, cosine similarity. Encoder ID is
-- pinned so we can detect when an entity's vector was produced
-- with a stale encoder version and re-embed it on the next sweep.
CREATE TABLE IF NOT EXISTS vectors.embeddings (
    entity_iri    text PRIMARY KEY,
    embedding     vector(768) NOT NULL,
    encoder_id    text NOT NULL,
    updated_at    timestamptz NOT NULL DEFAULT now()
);

-- HNSW index for cosine — the standard for LaBSE-style cross-
-- language semantic similarity. ~100 ms p95 lookup at our scale.
CREATE INDEX IF NOT EXISTS embeddings_hnsw_cosine
    ON vectors.embeddings
    USING hnsw (embedding vector_cosine_ops);

-- Trigger to keep updated_at fresh.
CREATE OR REPLACE FUNCTION vectors.touch_updated_at()
RETURNS trigger AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS embeddings_touch ON vectors.embeddings;
CREATE TRIGGER embeddings_touch
    BEFORE UPDATE ON vectors.embeddings
    FOR EACH ROW EXECUTE FUNCTION vectors.touch_updated_at();
