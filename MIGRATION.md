# Migration: event-log-driven write architecture

> **Status**: in execution. This document is the single source of
> truth for the migration; if you're picking up the work midway,
> read top-to-bottom and you should know exactly where to resume.
> The previous "Neo4j → Virtuoso (drop Neo4j entirely)" plan is
> archived at [MIGRATION.archived.md](MIGRATION.archived.md) for
> reference; the architecture below supersedes it.

## TL;DR

We are **not** removing Neo4j. We're moving from "two stores
written by ETLs in lockstep" to "**one event log**, multiple
projection stores".

```
                                ┌──────────────────────────┐
                                │  Postgres (events ts)    │
                                │  ┌────────────────────┐  │
   ETL loaders ──emit──►        │  │ entity_events      │  │  ┌──────────────┐
   (~30, refactored)            │  │ (BIGSERIAL seq, …) │  │  │  Sinks       │
                                │  └────────────────────┘  │  │  (consumers, │
   Consolidator ──emit──►       │  ┌────────────────────┐  │  │  per-store)  │
   (SameAs, Merge,…)            │  │ consumer_offsets   │◄─┤  │              │
                                │  └────────────────────┘  │  └──────────────┘
                                │  ┌────────────────────┐  │   ▲          ▲
                                │  │ dead_letter        │  │   │          │
                                │  └────────────────────┘  │   │          │
                                └──────────────────────────┘   │          │
                                                               │          │
                                       ┌───────────────────────┘          │
                                       │                                  │
                                ┌──────┴────────┐               ┌─────────┴──────┐
                                │ Virtuoso sink │               │ Neo4j sink     │
                                │ (batched      │               │ (Cypher MERGE  │
                                │  PUT-replace) │               │  per event)    │
                                └───────────────┘               └────────────────┘
                                                                         ▲
                                                                         │   reads
                                                            ┌────────────┴────────┐
                                                            │  Consolidator       │
                                                            │  (consumer,         │
                                                            │   high-watermark    │
                                                            │   gated by Neo4j    │
                                                            │   sink offset)      │
                                                            │   emits SameAs /    │
                                                            │   Merge / Flagged   │
                                                            └─────────────────────┘
```

**Roles after migration:**

- **Postgres `events.entity_events`** — canonical event log. Source
  of truth for what happened and when.
- **Virtuoso** — projection. Owns properties, federation, public
  SPARQL endpoint at `data.fontem.eu`, owl:sameAs equivalence
  closure, ontology + SHACL.
- **Neo4j** — projection. Owns graph traversal, GDS, fulltext
  index, vector index. Internal-only. Single instance, community
  license.
- **Postgres `vectors.embeddings`** — projection for k-NN
  similarity (already deployed in the postgres-fontem warm-up).

Both stores are derivable from the event log; replay-from-zero is
a hard requirement we test in Phase F.

## Why this shape

We considered three architectures:

| Approach | Decision |
|---|---|
| Pure derived (Virtuoso canonical, periodic Neo4j refresh) | **Rejected** — bridge job becomes critical path. Drift window between an ETL succeeding on Virtuoso and Neo4j catching up causes the consolidator to miss duplicates. |
| Dual-write + idempotent reconciliation | **Rejected** — stores write each other. Drift detection is heavy (timestamp scans). Adding a third store later means rewriting all ETLs. |
| **Event-log + per-store sinks** | **Selected.** Each store is a projection of the same log. Failures isolate cleanly. Adding a store later is "add a sink, replay from offset 0". Audit is the queue. |

The trade-off we accept: ~10–12 days of upfront work for a
cleaner long-term shape. We're pre-prod, so the time for deep
rewrites is now.

## Where Neo4j stays useful

| Capability | Why Neo4j wins | Used by |
|---|---|---|
| Property paths, shortest-path | First-class Cypher support; fast against an in-memory native graph | `gmr-api/graph.py`, public report builder |
| GDS (Jaccard, WCC, betweenness) | Native graph algorithms with index-aware traversal | Consolidator's clustering rules |
| Fulltext with Lucene scoring | Full-text index with proper relevance ranking | Resolver name-matching |
| Vector index (k-NN cosine) | LaBSE embedding lookup for multilingual entity matching | `embedding_similarity_authority` rule |
| `apoc.refactor.mergeNodes` | Merges duplicate nodes, rewrites all incident edges atomically | Consolidator merge step |

Trying to do any of these in SPARQL is a redesign, not a port.
Keeping them in Neo4j is the pragmatic call. Virtuoso gets
`owl:sameAs` for cross-source equivalence (which it handles
natively in OWL2-RL); the materialised merge stays a Neo4j
operation.

## Schema (Postgres)

The event log lives in a dedicated `events` schema in `gmr_app`,
on its own tablespace `events_ts` so it can be detached and
replaced independently of the rest of the database.

```sql
-- One-time bootstrap (DBA / migration job):
CREATE TABLESPACE events_ts LOCATION '/var/lib/postgresql/events';
CREATE SCHEMA events;
ALTER SCHEMA events OWNER TO postgres;

CREATE TABLE events.entity_events (
    seq            BIGSERIAL PRIMARY KEY,
    ts             TIMESTAMPTZ NOT NULL DEFAULT now(),
    event_type     TEXT NOT NULL,        -- 'UpsertCompany', 'AssertSameAs', …
    schema_version INT  NOT NULL DEFAULT 1,
    iri            TEXT NOT NULL,        -- canonical IRI
    domain         TEXT NOT NULL,        -- 'company', 'contract', …
    op             TEXT NOT NULL,        -- 'upsert' | 'delete' | 'control'
    payload        JSONB NOT NULL,
    batch_id       UUID,                 -- correlates events from one ETL run
    producer       TEXT NOT NULL         -- 'load_eu_sanctions' | 'consolidator' | …
) TABLESPACE events_ts;

CREATE INDEX entity_events_domain_seq    ON events.entity_events (domain, seq) TABLESPACE events_ts;
CREATE INDEX entity_events_iri_seq       ON events.entity_events (iri,    seq) TABLESPACE events_ts;
CREATE INDEX entity_events_batch         ON events.entity_events (batch_id) TABLESPACE events_ts;

CREATE TABLE events.consumer_offsets (
    consumer_name TEXT PRIMARY KEY,
    last_seq      BIGINT NOT NULL,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
) TABLESPACE events_ts;

CREATE TABLE events.dead_letter (
    seq             BIGINT NOT NULL,
    consumer        TEXT NOT NULL,
    error           TEXT NOT NULL,
    attempts        INT NOT NULL,
    first_failed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (seq, consumer)
) TABLESPACE events_ts;

CREATE INDEX dead_letter_consumer ON events.dead_letter (consumer) TABLESPACE events_ts;
```

Concurrent consumers use `SELECT … FOR UPDATE SKIP LOCKED` on
the cursor; offset writes commit in the same transaction as
work, so a crash between work and ack causes a redo (at-least-once
delivery) rather than a loss.

## Event taxonomy

**Entity events** — one per (entity-type, op):

```
UpsertCompany          DeleteCompany
UpsertListing          DeleteListing
UpsertContract         DeleteContract
UpsertAuthority        DeleteAuthority
UpsertCPV              DeleteCPV
UpsertNUTSRegion       DeleteNUTSRegion
UpsertLobbyist         DeleteLobbyist
UpsertLobbyInterest    DeleteLobbyInterest
UpsertCohesionProject  DeleteCohesionProject
UpsertSanctionedEntity DeleteSanctionedEntity
UpsertFiling           DeleteFiling
```

**Edge events** — emitted only when a relationship is independent
of any single entity body (most of the time edges live as
properties of one of the endpoints):

```
AssertListedAs          RetractListedAs
AssertSubsidiaryOf      RetractSubsidiaryOf
AssertLocatedIn         RetractLocatedIn
AssertSanctionedBy      RetractSanctionedBy
AssertReportedBy        RetractReportedBy
…
```

**Consolidation events** — emitted by the consolidator after
detection:

```
AssertSameAs            RetractSameAs
MergeRequested          MergeApplied
EntityFlagged
```

**Control events** — instruct sinks about boundary semantics:

```
BeginGraphReplace   { graph_iri }
EndGraphReplace     { graph_iri }
```

A loader that wants "replace this whole named graph" emits
`BeginGraphReplace`, then the per-entity Upserts, then
`EndGraphReplace`. The Virtuoso sink uses the bracket as PUT
semantics; the Neo4j sink translates it to `DETACH DELETE` of
all matching nodes followed by `MERGE` of the new ones,
within a single transaction.

## Schema versioning

Each event type has a JSON Schema at:

```
gmr-event-schemas/
  v1/
    UpsertCompany.json
    UpsertFiling.json
    AssertSameAs.json
    …
  v2/                 # added when an event type gains a field
    UpsertCompany.json
```

The `schema_version` column on every row pins which schema the
payload conforms to. Sinks fail loudly on unknown versions —
schema regressions don't silently corrupt projections.

`gmr-event-schemas` is a Python package. Producers
(`pip install gmr-event-schemas`) get typed payload
constructors; consumers get validators. CI on the schemas repo
runs example payloads through the validator on every commit so
breaking changes can't merge.

## Consumer chain (high-watermark gating)

The consolidator depends on Neo4j freshness (it uses Neo4j's
fulltext + vector indexes for matching). To prevent the
consolidator running ahead of the Neo4j sink:

```python
class ConsolidatorConsumer(EventConsumer):
    def fetch_window(self):
        my_offset    = self.read_offset()
        upstream     = self.read_offset("neo4j_sink")
        return self.fetch(my_offset + 1, upstream)
```

The consolidator never processes seq > Neo4j sink's last_seq.
This is a "high-watermark" pattern; documented as the standard
way to chain consumers where order matters. No new broker
primitive needed.

## Sink design

Both sinks share a `EventConsumer` base class providing:
poll loop, offset tracking, retry+DLQ, batch handoff,
Prometheus instrumentation, Uptime Kuma heartbeat.

**Virtuoso sink** — batches by `(domain, batch_id)`. When the
batch closes (different `batch_id` observed, or N seconds idle),
serialise to Turtle and PUT to the per-domain named graph.
PUT-replace semantics are preserved via the
`BeginGraphReplace` / `EndGraphReplace` bracket. Per-entity
events outside a bracket (e.g. consolidator outputs) flush as
small bursts via SPARQL UPDATE.

**Neo4j sink** — per-event Cypher `MERGE`, batched in 1000-row
`UNWIND`s within a single transaction. `BeginGraphReplace` /
`EndGraphReplace` translate to `DETACH DELETE … MATCH n:Label
WHERE …` followed by the inserts.

Both run as Kubernetes Deployments (long-lived poll loop, not
CronJobs) with HPA disabled (single replica per sink for
ordering guarantees).

## Observability (existing stack)

| Signal | Source | Stack |
|---|---|---|
| Per-consumer `event_lag_seconds` | Sink + consolidator | Prometheus → Grafana |
| `events_processed_total`, `events_failed_total` | Sink + consolidator | Prometheus |
| `dlq_size{consumer}` | Postgres `events.dead_letter` | Custom exporter (small) |
| `batch_size_p50/p95` | Sink | Prometheus histogram |
| Per-consumer heartbeat | Sink + consolidator | Uptime Kuma push |
| Per-consumer logs | Sink + consolidator | stdout → Loki (Phase G) |

Grafana dashboard per consumer plus one cross-consumer "queue
health" overview (lag heatmap, DLQ size over time, throughput).

PrometheusRule alerts:

- `EventSinkDown` — heartbeat absent >5m
- `EventLagHigh` — lag_seconds > 600s for 15m
- `DLQGrowing` — dlq_size delta > 0 for 30m
- `EventBacklog` — events table grew but consumer didn't advance

## Repo layout

| Repo | Purpose | Status |
|---|---|---|
| **gmr-event-schemas** | JSON Schema definitions for every event type; published as Python package | new (Phase A) |
| **gmr-events** | Shared client lib: `EventLog.emit()`, `EventConsumer` base, observability helpers | new (Phase A) |
| **gmr-virtuoso-sink** | Sink runtime (Python long-poll, Deployment) | new (Phase B) |
| **gmr-neo4j-sink** | Sink runtime (Python long-poll, Deployment) | new (Phase C) |
| **edgar-gmr-etl** | All loaders refactored to `EventLog.emit()`; `RdfFilingsWriter`/`RdfSanctionsWriter` retired | refactor across Phase E |
| **gmr-consolidator** | Refactored as event consumer + producer | refactor in Phase D |
| **fontem-ontology** | This document; ontology + shapes unchanged | this PR |
| **gitops** | New Deployments, Postgres tablespace + schema migration | rolling per phase |

## Phases & deliverables

Each phase is one or more PRs. Phase boundaries are gates: do
not start the next phase until the previous phase's gate passes.

### Phase A — Foundation

**Deliverables:**
- Postgres `events_ts` tablespace and `events.*` schema (PVC,
  mount, migration job)
- `gmr-event-schemas` repo published with the starter taxonomy
  above; CI validates example payloads
- `gmr-events` Python lib: `EventLog.emit_*()`, `EventConsumer`
  base class, idempotency-key support, JSON Schema validation,
  Prometheus + Kuma helpers
- Unit tests against an ephemeral Postgres

**Gate:** ETL produces an event in test → consumer base class
ingests, advances offset, retries on simulated failure, lands
in DLQ on permanent failure, emits Prometheus metrics. Validated
by an integration test in `gmr-events`.

**Estimate:** 1.5 days.

### Phase B — Virtuoso sink end-to-end

**Deliverables:**
- `gmr-virtuoso-sink` Deployment with `(domain, batch_id)` batching
- `BeginGraphReplace`/`EndGraphReplace` semantics translated
  to PUT-replace on the corresponding named graph
- Refactor `load_eu_sanctions` to emit events via the
  `gmr-events` lib (no direct Virtuoso write any more)
- Bootstrap: snapshot existing `…/graph/sanctions` state into
  events table once, so the sink can replay-from-zero into a
  clean Virtuoso and reproduce today's data
- Grafana dashboard, PrometheusRule alerts, Kuma push

**Gate:** sanctions ETL emits → Virtuoso sink projects → public
`/api/data-quality/sanctions` returns the same body as before.
Replay test: drop the sanctions named graph, reset the sink's
offset to 0, watch the graph rebuild bit-identical.

**Estimate:** 1.5 days.

### Phase C — Neo4j sink

**Deliverables:**
- `gmr-neo4j-sink` Deployment, mirror shape of Virtuoso sink
  but using Cypher `UNWIND` + `MERGE`
- `BeginGraphReplace` → `DETACH DELETE` of all nodes with the
  matching label, then upserts
- Same observability surface

**Gate:** sanctions Cypher view in Neo4j matches Virtuoso content
after both sinks have caught up. Replay test mirroring Phase B.

**Estimate:** 0.5 day.

### Phase D — Consolidator as consumer

**Deliverables:**
- Consolidator refactored to consume from `entity_events` with
  high-watermark gating against `neo4j_sink`
- Detection rules read entities from the event stream rather
  than polling Neo4j for "new since last run"
- Outputs (`AssertSameAs`, `MergeRequested`, `Flagged`) emitted
  back into the event log via `EventLog.emit()`; sinks pick them
  up as they pick up everything else
- Existing Neo4j-side `apoc.refactor.mergeNodes`, GDS, fulltext,
  and vector index calls stay — but they're now triggered by
  events rather than DB polling

**Gate:** sanctions ETL emits a new entity → Neo4j sink commits
→ consolidator consumes within watermark → emits an
`AssertSameAs` for a real-world prior known-duplicate fixture →
both sinks observe the equivalence. End-to-end test in CI.

**Estimate:** 2 days. The hardest individual lift; gets its own
sub-design doc as a follow-up issue.

### Phase E — ETL fleet refactor

**Deliverables:** every loader migrated to `EventLog.emit()` —
one PR per loader, mostly mechanical:

- load_us_companies
- load_eu_listings (Listings + financials, both halves)
- load_us_financials
- load_ted_contracts
- load_gleif
- load_gleif_relationships
- load_eu_lobbying
- load_nuts
- load_cpv
- load_cdp
- load_firds
- load_openfigi
- load_eu_knowledge_graph
- materialize_trade_edges
- load_eu_sanctions (already in Phase B)

After this phase, `RdfFilingsWriter`, `RdfSanctionsWriter`, and
the legacy in-loader Cypher `MERGE` blocks are deleted.

**Gate:** every domain is event-driven. No loader writes Neo4j
or Virtuoso directly; all goes through the queue. Verified by a
CI job that greps for direct `driver.session()` calls in
loaders and the Virtuoso graph-CRUD endpoint outside the sinks.

**Estimate:** 3–4 days.

### Phase F — Replay-from-zero validation

**Deliverables:**
- Bootstrap script: enumerate every entity in current Virtuoso,
  emit synthetic Upsert events to seed the log, archive the
  bridge script
- Reset both stores to empty; replay from offset 0; assert
  convergence with a snapshot-comparison test
- "Rebuild a store from log" runbook documented in
  [REPLAY-RUNBOOK.md](REPLAY-RUNBOOK.md)

**Gate:** both stores rebuild from `entity_events` alone
(modulo blank-node IDs) to a state functionally identical to
before. Difference report is empty for every domain.

**Estimate:** 1 day.

### Phase G — Operational polish

**Deliverables:**
- Loki for sink + consolidator logs; correlation by `batch_id`
- Final PrometheusRule tuning based on observed lag/throughput
- DLQ-replay tooling: one-shot CronJob that re-fetches and
  retries DLQ entries
- Schema-evolution runbook (`v1 → v2` cookbook with example)
- Consumer-restart-from-offset recipe

**Gate:** alert fires + auto-resolves end-to-end on a deliberate
sink stall. DLQ-replay tooling round-trips a bad event.

**Estimate:** 0.5 day.

**Total: 10–12 days of focused work.**

## Cross-cutting decisions (decided)

| Decision | Choice | Reason |
|---|---|---|
| Event grain | Per-entity, correlated by `batch_id` | Replay granularity + flexible audit views |
| Idempotency key | `(producer, batch_id, iri)` | Lets sinks dedupe on retry |
| Failure budget | 5 retries with exponential backoff, then DLQ | Standard at-least-once shape |
| Schema-version mismatch | Fail loud on unknown versions, manual unblock | Avoid silent corruption |
| Bulk PUT semantics | `BeginGraphReplace`/`EndGraphReplace` brackets | Preserves Virtuoso PUT-replace at sink, Neo4j wholesale-delete-then-merge |
| Backpressure | Token bucket on producer side gated by max consumer lag | Prevents queue blow-up during sink outage |
| Retention | Keep events forever in Phase B; revisit pruning in Phase G | Replay-from-zero always works until we explicitly prune |
| Tablespace | Dedicated `events_ts` on its own PVC | Operational isolation; can detach + replace |

## Open questions for during execution

These are NOT blockers; they get answered as the relevant phase
lands and we have measurements. Recorded here so we don't lose
them:

1. **Sink replica count.** Single replica preserves ordering. Do
   we want partition-by-domain so each domain has its own
   Deployment + offset for parallelism? Probably yes for Neo4j
   (write-heavy); probably no for Virtuoso (PUT-replace is
   already serialised at the named-graph level). Decide after
   Phase E load-test.

2. **Event retention.** With ~4M entities × per-entity events ×
   weekly ETL cycles, the queue grows by ~4M rows/week. Postgres
   handles billions of rows but the index hot-set matters.
   Pruning policy probably "compact events older than 90d into
   a snapshot+delta", but defer to Phase G.

3. **Schema-evolution discipline.** Additive-only changes only
   for the first year? Or rev the version on every change?
   Decide as we approach the first real schema rev.

4. **Consolidator idempotency.** The consolidator's outputs
   should be idempotent under replay (re-running it on the same
   inputs produces the same outputs). Easy in principle; verify
   in Phase D.

5. **Bootstrap from existing data.** Virtuoso currently has 4M+
   entities loaded from the bridge script. For replay-from-zero
   to mean anything, we need either: (a) reproducible synthesis
   of starter events from current Virtuoso state, or (b) accept
   that "from zero" means "from the moment the event log went
   live, with current data as the synthetic genesis batch". (b)
   is simpler and what most teams do. Decide in Phase F.

## Status / where we are

- ✅ Phase 0 + 1 + 2 + 3 from the **archived** plan are complete:
  Virtuoso staging stand-up, ontology + SHACL shapes, sanctions
  domain, FinancialYear domain, the postgres-fontem custom
  image, virtuoso-exporter + dashboard, ETL signing chain,
  bridge `migrate_neo4j_to_virtuoso.py`. All running in prod.
- ⚠️ The earlier "remove Neo4j entirely" goal has been retired
  in favour of this architecture. Sanctions and FinancialYear
  are currently in Virtuoso only — they will get re-bridged
  back to Neo4j as part of Phase B/C so the consolidator can
  see them again.
- 🛠 **Phase A is in flight.** First commits land:
  - This document (in this PR)
  - Postgres tablespace + schema migration (next PR)
  - `gmr-event-schemas` repo skeleton (next PR)
  - `gmr-events` Python lib skeleton (next PR)

If you're picking this up cold: read this file top to bottom,
look at TODOs in the codebase tagged `# event-log:`, and check
ArgoCD for any sink/consumer Deployment that's not at status
`Synced/Healthy`. Then continue from the open phase.
