# Engine comparison — Virtuoso vs Apache Jena Fuseki

> Phase 0 / WS6 follow-up. The same fixtures, the same queries, the
> same expected outputs run against both engines so we can pick the
> right substrate for Phase 1 with our eyes open.

## Headline result

Both engines pass all four smoke tests. Different paths there.

| | Virtuoso 7.2 OS | Apache Jena Fuseki 5.1 |
|---|---|---|
| **Bundled reasoner covers `owl:propertyChainAxiom`** | ❌ no | ❌ no |
| **Workaround** | One-shot SPARQL INSERT after load (`post-load.sparql`) | Custom Jena rules in a rules file (`rules.txt`) wired into a `GenericRuleReasoner` |
| **Workaround re-fires on writes** | ❌ no — INSERT runs once per load; new writes need re-running | ✅ yes — rules fire on every query (forward-chained, kept up to date by the InfModel) |
| **Drift risk** | Same as `materialize_trade_edges` had: state goes stale between loads | None — the rule is part of the inference layer, not stored output |
| **Ontology declarative axiom** (`owl:propertyChainAxiom`) | Ignored | Ignored (Jena's bundled OWL reasoners are pre-OWL2) |
| **Federation (`SERVICE`)** | Native | Native |
| **Storage scale ceiling** | ~10B triples single-node (DBpedia runs ~3B in prod 15 yrs) | ~1B triples comfortable; degrades non-linearly past that |
| **Storage engine** | C++, vectored, bitmap indexes | TDB/TDB2, Java, B-tree |
| **Fulltext search** | `bif:contains` (built-in) | Lucene via `text:query` (separate index, configured per dataset) |
| **OWL alignment** (subClassOf, inverseOf, transitive, sameAs, equivalent\*) | ✅ full | ✅ full |
| **License** | GPL-2 (OS edition) | Apache-2.0 |
| **Operational shape** | DBMS-grade — `virtuoso.ini` tuning, page-buffer config, multi-process | Single JVM, one binary, simple |
| **Ops familiarity in our stack** | New | New |
| **Image size** | ~250 MB (`openlink/virtuoso-opensource-7:7.2.14`) | ~480 MB (`stain/jena-fuseki:5.1.0`) |
| **Memory footprint (smoke)** | ~512 MB | ~340 MB |
| **Cold start time** | ~15 s | ~5 s |
| **Auth out-of-the-box** | `dba/dba` (must change immediately) | Random admin password generated, basic auth on writes / admin |

## Critical finding for the migration call

**Neither engine implements `owl:propertyChainAxiom` from the
declared ontology.** That was the killer feature we expected to get
"for free" from RDF + OWL. So the question isn't "does the reasoner
do it" — it's "what's the shape of the workaround, and does that
workaround have the same drift problem we're migrating to escape".

### Virtuoso's workaround

```sparql
# tools/smoke/virtuoso/post-load.sparql — runs once after data load
INSERT { GRAPH <…/data> { ?auth fontem:client ?co .
                          ?co fontem:supplier ?auth . } }
WHERE  { GRAPH <…/data> { ?auth fontem:awarded ?ct .
                          ?ct fontem:awardedTo ?co . } }
```

This **re-creates the eu-LISA bug class**: the materialised
`fontem:client` triples are stored output that goes stale every
time something mutates the AWARDED graph without running the
post-load step. Same shape as `materialize_trade_edges` — just
moved from Cypher to SPARQL.

You can mitigate by running the post-load on every write or on a
cron, but that's exactly the architecture we're trying to retire.

### Fuseki's workaround

```
# tools/smoke/fuseki/rules.txt — fires on every query
[client_chain:
    (?auth fontem:awarded ?ct) (?ct fontem:awardedTo ?co)
    -> (?auth fontem:client ?co)]
[supplier_inverse:
    (?auth fontem:client ?co) -> (?co fontem:supplier ?auth)]
```

The `GenericRuleReasoner` evaluates these rules forward-chained
inside an `InfModel`. There's nothing materialised — `?auth
fontem:client ?co` triples don't exist in the underlying TDB; they
appear at query time because the rule fires when the query asks for
them. **Adding a new contract is automatically reflected in
fontem:client queries on the very next read.**

This is genuinely closer to "native reasoner" semantics. It's not
declarative-from-the-ontology-axiom, but it's fire-on-every-query
which is what we actually wanted.

## Recommendation: Virtuoso

The first cut of this doc recommended Fuseki on the strength of the
drift property. After reviewing the **realistic full-build-out
workload**, that recommendation flips.

### The scale calculation that flips it

| Component | Triples (loaded) |
|---|---:|
| Fontem own data (procurement, GLEIF, lobbying, sanctions, listings, NUTS) | 2–5 B |
| Wikidata truthy mirror (`<http://wikidata.org/entity>` named graph) | ~12 B |
| EU Knowledge Graph mirror (`<http://linkedopendata.eu/entity>` named graph) | 0.1–1 B |
| OWL2-RL materialised closure (subClassOf, sameAs, transitive owns, …) | +30–80% |
| **Total ceiling** | **18–25 B** |

That's not Fuseki territory. Fuseki on a single JVM is comfortable
to ~1 B; query latency turns multi-second around 5 B; loading the
full Wikidata dump runs 48+ hours and the JVM heap profile is
uncomfortable. We'd hit the wall mid-Phase 3.

Virtuoso is the only FOSS engine in this comparison set actually
proven at that scale: DBpedia has run ~3 B on it for 15 years; the
qEndpoint that powers WDQS-scholarly is a sibling C++ store at
similar volumes.

### Why drift turned out not to be the dominant factor

The drift property is real but solvable as a write-pattern problem,
not an architecture problem. The fix is the same shape as
`_refresh_trade_edges` we shipped in `gmr-consolidator` a couple of
weeks ago: every writer calls a small post-write maintenance SPARQL
that updates the derived triples for the affected neighbourhood.
Localised, transactional, well-understood, ~5 lines per writer.
Plus a defence-in-depth nightly re-materialise — same belt-and-
braces shape as the existing `materialize_trade_edges` cron we just
landed.

By contrast, Fuseki's scale ceiling is **not** solvable as a
write-pattern problem. It's solvable only by switching engines.

### What we get from picking Virtuoso

- **`owl:sameAs` semantics** — full transitive closure, triple
  replication on both sides, query rewriting. This is the actual
  prize of the migration; Neo4j's `:SAME_AS` edge sits there with
  no semantic teeth.
- **Wikidata + EUKG mirrors as named graphs** — sub-100ms
  cross-graph joins instead of 1–5s remote `SERVICE` calls.
- **`bif:contains` fulltext** built in; works on every literal
  without a separate Lucene assembler.
- **GeoSPARQL** out of the box (matters when Atlas/NUTS data
  eventually wants spatial queries).
- **15-year production track record** at our projected scale.

### What we accept as the cost

- **No native `owl:propertyChainAxiom`.** Same finding as Fuseki's
  bundled reasoner. Workaround = write-time hooks on derived
  predicates (`fontem:client`, `fontem:supplier`, eventually
  `fontem:ultimateParent` if we add it). The hooks are SPARQL
  versions of the same `_refresh_trade_edges` pattern; this
  problem is well-understood in our codebase.
- **GPL-2 license** (OS edition). For an internal/public-interest
  tool that doesn't redistribute modified Virtuoso, contagion
  concern is essentially zero.
- **Heavier ops shape**: `virtuoso.ini` tuning, page-buffer
  config. Phase 1 absorbs this once.

### Engines we considered and rejected

- **GraphDB Free** — has native `owl:propertyChainAxiom`. But the
  free tier caps at 2 concurrent queries; non-starter for a
  public SPARQL endpoint. Paid clustering is serious money.
- **Stardog Free** — cleanest OWL semantics, commercial license
  tier becomes a real concern at scale.
- **QLever** — purpose-built for our exact scale, ms latency on
  10B+. But it's read-mostly; rebuild on writes is slow. Wrong
  fit for a writeable data graph; could become a future hybrid
  (QLever for the Wikidata mirror, Virtuoso for the write side).
- **RDFox** — Oxford spin-out, real OWL2-RL native. Commercial
  only. Skip.

### What this comparison was worth

The Fuseki experiment wasn't wasted. We now have:

1. An empirical comparison instead of a vibe.
2. A working dual-engine harness (`tools/smoke/{virtuoso,fuseki}/`)
   if we ever want to swap or run in parallel.
3. A written record (this doc) for the "why did you pick
   Virtuoso" question two years from now.

Phase 1 ships on Virtuoso.

## What stays the same regardless of engine

- The Turtle TBox files (`ontology/*.ttl`) — portable.
- The Wikidata alignment — portable.
- The SHACL shapes — portable.
- The fixtures, queries, and expected outputs — portable; that's
  why they're in `tools/smoke/{fixtures,queries,expected}/`
  shared, not in either engine subdirectory.
- The migration phases (1-7) — same shape; only the helm chart
  and the ETL writer libraries change between engines.

## How to run

```
bash tools/smoke/virtuoso/run.sh   # Virtuoso engine
bash tools/smoke/fuseki/run.sh     # Fuseki engine
bash tools/smoke/run-all.sh        # both, sequentially
```

CI gates on both.
