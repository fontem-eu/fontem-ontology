# Phase D: consolidator trigger

> Design doc. Lives next to [MIGRATION.md](MIGRATION.md). Anyone
> picking up Phase D reads this top-to-bottom; it answers
> "what changes" so we don't need to redesign mid-implementation.

## TL;DR

**The consolidator's business logic doesn't change.** It keeps
running its resolver, rules, fulltext + vector indexes against
Neo4j; it keeps emitting `SAME_AS` edges, `apoc.refactor.mergeNodes`
calls, and the rest. We don't translate any of that to SPARQL.

**What changes is when the consolidator runs.** Today it's
called inline by ETL loaders at write-time (e.g.
`load_eu_sanctions` POSTs every entity to `/resolve` while
inserting). Under the event-log architecture the loader doesn't
write Neo4j directly any more — it emits events, and the
sinks project them. So inline calls don't see fresh data.

The fix is a tiny new component, **`consolidator-trigger`**: an
event-log consumer that fires the consolidator's existing HTTP
endpoints once per event, **after** all upstream consumers
have caught up to that event's seq. A semaphore-driven webhook.

## Why this is simple

The consolidator already exposes its logic over HTTP (`/resolve`
today, `/consolidate/<entity_type>/<id>` and friends). The whole
question of "how do I reach into its internals from a Python
consumer" disappears: we're just calling the API.

The hard parts of Phase D that I was previously dreading
(porting `apoc.refactor.mergeNodes` to SPARQL, replacing GDS
Jaccard/WCC, redesigning the resolver) **are not in scope**.
Those stay in Neo4j; the consolidator owns its store and its
algorithms. We're only changing the trigger mechanism.

## Architecture

```
events.entity_events
        │
        ▼
   ┌────────────────────────────┐
   │ consolidator-trigger       │
   │ (EventConsumer subclass)   │
   │                            │
   │ For each event seq N:      │
   │  1. wait until ALL upstream│
   │     offsets ≥ N            │
   │  2. POST consolidator API  │
   │     with the event payload │
   │  3. on 2xx → advance own   │
   │     offset past N          │
   │  4. on error → retry, DLQ  │
   └──────┬─────────────────────┘
          │ HTTP POST
          ▼
   ┌──────────────────────────────────┐
   │ gmr-consolidator (unchanged)     │
   │ - resolver (Neo4j fulltext +     │
   │   vector + GDS, today's code)    │
   │ - rules engine                   │
   │ - apoc.refactor.mergeNodes       │
   │ - writes SAME_AS edges to Neo4j  │
   └──────────────────────────────────┘
```

`consolidator-trigger` lives in the existing `gmr-consolidator`
repo (not a new one). It's a sibling subprocess in the same
container or a separate Deployment; both work.

## Dependency / watermark semantics

The trigger has a list of "upstream consumer names" it depends
on. For most events that's `["neo4j_sink"]` — we want the
Neo4j projection to reflect the new entity before the
consolidator looks at it. For consolidation rules that also
need property data we'd add `"virtuoso_sink"`.

The watermark check runs in `fetch_window()`, the same hook
the existing high-watermark gating uses in `gmr-events`:

```python
class ConsolidatorTrigger(EventConsumer):
    UPSTREAM = ["neo4j_sink"]   # configurable per deployment

    def fetch_window(self):
        my_offset = self.read_offset()
        upstream_min = min(
            self.read_offset(name) for name in self.UPSTREAM
        )
        return self.fetch(my_offset + 1, upstream_min)
```

The trigger never processes seq > min(upstream offsets). If any
upstream falls behind, the trigger waits; back-pressure on the
consolidator falls out automatically.

## What gets posted to the consolidator

One endpoint, generic:

```
POST /events/dispatch
Content-Type: application/json

{
  "seq":         12345,
  "event_type":  "UpsertCompany",
  "iri":         "http://data.fontem.eu/id/Company/abc-…",
  "domain":      "company",
  "payload":     { ...the event body... },
  "batch_id":    "uuid",
  "producer":    "load_us_companies"
}
```

The consolidator dispatches by `event_type` to the matching
rule(s). Today the rule set is: name-similarity dedup,
sanction-overlap detector, subsidiary-of inference, etc. New
rules just register against new event types — no protocol
change.

The endpoint is **idempotent** — re-posting the same event
must produce the same effect (or no effect). The existing
rules engine already has this property because it's
MERGE-based, not INSERT-based.

## Failure handling

- **2xx**: advance offset.
- **5xx / timeout**: retry with exponential backoff (5
  attempts, same as other consumers).
- **4xx that isn't 409 (conflict)**: DLQ immediately —
  payload-shape errors aren't retryable.
- **409**: treat as success (conflict means "already done").

If the consolidator is slow or down, the trigger lags but
events accumulate cleanly — backpressure is on the trigger,
not on the producers (which keep emitting at their normal
ETL pace) and not on the sinks (which have their own offsets).

## Consolidator outputs

This is the one substantive piece beyond the trigger.

Today the consolidator writes Neo4j directly: `MERGE (a)-[:SAME_AS]->(b)`,
`apoc.refactor.mergeNodes`, etc. Under the event-log
architecture, the canonical projection of "entity A is the
same as entity B" is in Virtuoso (`owl:sameAs`); Neo4j
gets it as a SAME_AS edge for traversal/GDS purposes.

Two paths to consider, with a recommendation:

| Path | Effort | Cost | Recommendation |
|---|---|---|---|
| (a) Consolidator emits `AssertSameAs` events; sinks apply them. | Higher: consolidator stops writing Neo4j directly, refactors every rule's output side. | Both stores stay derived from log. Replay-from-zero recovers consolidation results. | **Eventually yes**, in a follow-up after Phase D's webhook lands. |
| (b) Consolidator keeps writing Neo4j directly + emits a synthetic `AssertSameAs` event so Virtuoso sees it. | Lower: tiny shim. Neo4j is dual-written (rule's existing Cypher + the same edge from the sink), but that's idempotent because both use MERGE. | Phase D delivers the trigger semantics quickly. The dual-write is bounded — only consolidation outputs, ~100s/day, not the bulk ETL. | **Yes for Phase D**. |

Path (b) is what we ship. The rule writes Neo4j AND emits the
event. The Neo4j sink picks up the event and re-MERGEs the same
edge (no-op, because MERGE). The Virtuoso sink picks up the
event and asserts `owl:sameAs`. Replay-from-zero works for
both stores because the event is canonical even though the
consolidator also writes Neo4j directly during its own run.

When we feel like tightening this in a follow-up: remove the
direct Neo4j write from the consolidator, let the event +
Neo4j sink do it. Pure path (a). Not blocking for Phase D.

## Implementation outline

1. **`gmr-consolidator/src/consolidator/api/dispatch.py`**:
   new FastAPI route `POST /events/dispatch`. Reads `event_type`,
   looks up the matching rule, runs it, returns 200/409/4xx as
   above. Shape ~50 lines including error handling.

2. **`gmr-consolidator/src/consolidator/trigger/`** *(new
   subpackage)*: subclass of `gmr_events.EventConsumer`.
   `handle()` receives a batch, POSTs each event to its own
   dispatch endpoint sequentially, advances offset on 2xx,
   DLQs on permanent 4xx. Emits a `_consolidation_emit_event(...)`
   helper for rules to call when they want their output to land
   in the log (path (b) above).

3. **gitops Deployment** for `consolidator-trigger`:
   - One pod, single replica.
   - Env: `EVENT_CONSUMER_NAME=consolidator_trigger`,
     `EVENT_UPSTREAM_CONSUMERS=neo4j_sink`,
     `CONSOLIDATOR_URL=http://gmr-consolidator.gmr.svc.cluster.local:8000`.
   - Same Prometheus + Kuma instrumentation as other sinks.

4. **Cron retirement**: today's hourly consolidator sweeps
   stay (they catch the long tail and reasoner-driven cases).
   The trigger handles immediate per-event reactivity. Coexist;
   they don't conflict because rules are idempotent.

5. **Testing**: mock the consolidator URL with httpx test
   transport; assert `dispatch` gets called once per event,
   with retries on simulated 5xx, with DLQ on 400. The
   integration test mirrors the gmr-events end-to-end shape.

## What this does NOT do

- Does NOT port the resolver, fulltext, vector, or GDS to SPARQL
- Does NOT touch `apoc.refactor.mergeNodes`
- Does NOT change rule logic
- Does NOT remove Neo4j as the consolidator's primary store

The plan from MIGRATION.md still holds: Virtuoso owns
properties + federation, Neo4j owns traversal + algorithms,
the event log is canonical for ETL writes. Phase D adds:
**the consolidator runs the right moment after upstream sinks
project new data, via a small webhook trigger that gates on
the consumer-offsets table.**

## Status

- Design: this doc (today)
- Implementation: not started; pattern proven by sanctions
  end-to-end already
- Estimate: ~1 day of focused work for the trigger consumer
  + dispatch endpoint + Deployment manifest. The "long tail"
  pieces (rule output emit, full removal of direct Neo4j writes
  from rules) are a follow-up that landing Phase D doesn't block.
