# Migration: Neo4j → Virtuoso (RDF / OWL)

This is the master plan for replacing Fontem's storage layer. It's a
multi-week, multi-phase project. Phase 0 is detailed because we
can start it on day one. Phases 1+ are sketched — they'll be
detailed once the preceding phase has landed and informed the next.

## Why we're moving

Two architectural gaps in the current stack, both already surfaced
as bugs:

- **No reasoner.** Derived relationships (`CLIENT_OF`, `SUPPLIER_OF`,
  transitive ownership) are hand-materialised by an ETL job and drift
  silently when the underlying graph mutates. The eu-LISA incident
  was this bug class. With OWL2-RL the property chain
  `:awarded ∘ :awardedTo ⊑ :client` becomes a one-line declarative
  axiom that the reasoner maintains.
- **No federation.** Wikidata, OpenCorporates, EU Publications
  Office, DBpedia all publish SPARQL endpoints. With our own SPARQL
  endpoint, federated joins (`SERVICE <…>`) become first-class. With
  Cypher they're hand-stitched HTTP joins.

A third reason, less architectural but real: **multi-node Neo4j is
paid**. Virtuoso Open Source ships clustering in the FOSS edition.
We won't need it for years (single-node Virtuoso comfortably handles
multi-billion-triple workloads), but the ceiling is higher.

## Constraints

The migration runs against these realities:

- **Single 32GB / 12c+20HT / 4TB SSD prod node.** Fontem's full
  prod stack lives here.
- **Memory budget** (firm):
  - Virtuoso: 20 GB
  - Postgres (reports + fontem-stats + pgvector sidecar): 4 GB
  - APIs (gmr-api, gmr-community-api, gmr-web SSR, claude-proxy): 4 GB
  - OS / page cache / headroom: 4 GB
- **ETL on the dev node.** Bulk loads, the consolidator's batch
  rules, and the weekly Wikidata refresh run on the dev node and
  write to prod Virtuoso over the cluster network. Prod node never
  pays the ETL CPU cost.
- **We're in staging, the data is throwaway.** Iterate fast. We
  don't need a parallel-write / shadow-compare phase for data
  fidelity — we'll re-run the loaders against Virtuoso from scratch.
- **pgvector for embeddings.** LaBSE embeddings move out of Neo4j
  (where they live as float arrays on Authority nodes) into a
  pgvector table in the existing Postgres deployment. IRIs become
  the foreign key.

## What stays where

Not everything moves to RDF. Right-tool-for-the-job:

| Data | Store | Why |
|---|---|---|
| Procurement, GLEIF, EDGAR, ESEF, sanctions, lobbying, persons | **Virtuoso** | Graph-shaped, needs reasoning, federation |
| LaBSE embeddings | **Postgres + pgvector** | Vector similarity isn't RDF's job |
| Reports (TipTap docs) | **Postgres** | Document blobs, no graph value |
| Atlas / fontem-stats observations | **Postgres** | Tabular `(region × indicator × year × value)` — RDF would 10× the storage for no gain |
| Conversation history (assistant) | **Postgres** | Append-only per-user log, not a graph |
| Search indexes | **Virtuoso FTS** + **pgvector** | `bif:contains` for exact / fuzzy text; pgvector for cross-language semantic |

## Target architecture

```
        ┌──────────────────────────┐
        │  ETL jobs (dev node)     │
        │  - load_eu_sanctions     │
        │  - load_ted_contracts    │
        │  - load_gleif            │
        │  - …                     │
        │  - wikidata_weekly_sync  │
        └────────────┬─────────────┘
                     │ SPARQL UPDATE
                     │ (ISQL bulk-load for full reloads)
                     ▼
   ┌─────────────────────────────────────────────────┐
   │  Virtuoso OS — 20 GB, prod node                 │
   │                                                 │
   │  Named graphs:                                  │
   │    <http://fontem.eu/ontology>          │
   │    <http://fontem.eu/data>              │
   │    <http://wikidata.org/entity>                 │  ← weekly truthy mirror
   │    <http://dbpedia.org/resource>                │  ← optional, future
   │                                                 │
   │  Reasoning: OWL2-RL forward-chained, materialised│
   │  Indexes: full SPARQL + bif:contains FTS        │
   └────────────────────┬────────────────────────────┘
                        │ SPARQL SELECT
        ┌───────────────┴─────────────────┐
        │       APIs (4 GB shared)        │
        │   gmr-api │ gmr-community-api   │
        │   gmr-web SSR │ claude-proxy    │
        └─────────────────────────────────┘

        Sidecar (no graph involvement):
   ┌────────────────────────────────────────┐
   │  Postgres — 4 GB, prod node            │
   │   - schema: reports                    │
   │   - schema: fontem_stats (atlas)       │
   │   - schema: vectors (pgvector)         │
   │     embeddings (entity_iri, vec(768))  │
   │   - schema: assistant (conversations)  │
   └────────────────────────────────────────┘
```

## Phases at a glance

| Phase | Goal | Effort (solo) | Detail level |
|---|---|---|---|
| **0** — Design | Ontology in Turtle, URI scheme, Wikidata alignment, decision docs | 1–2 weeks | **Detailed below** |
| **1** — Infrastructure | Virtuoso Helm chart, pgvector schema, backups | 1 week | Sketched |
| **2** — Pilot ETL: sanctions | One source, end-to-end, validate everything | 1 week | Sketched |
| **3** — Wikidata mirror | Bulk-load truthy, weekly refresh, federated query patterns | 1 week | Sketched |
| **4** — Remaining ETLs | Port each loader to write Turtle / SPARQL | 3–4 weeks | Sketched |
| **5** — Read API cutover | Every Cypher → SPARQL; feature-flagged endpoint switch | 2 weeks | Sketched |
| **6** — Reasoner activation | Property chains, sameAs, derived classes; delete materialise ETL | 1 week | Sketched |
| **7** — Decommission | Remove Neo4j from cluster, codebase, docs | 1 week | Sketched |

**Total realistic budget: 10-12 weeks elapsed for one focused engineer.**
Two engineers can roughly halve it; phases 1, 4, and 5 parallelise.

---

# Phase 0 — Design

The single highest-leverage phase. Everything downstream pivots on
the decisions made here, and getting them wrong gets discovered three
phases later when porting is half done. Spend the time.

Phase 0 produces four artefacts, all in this repo:

1. **URI scheme** (`ontology/uri-scheme.md`) — how every entity, class,
   and property is named.
2. **Wikidata alignment** (`ontology/wikidata-alignment.md`) — which
   Fontem classes / properties are `owl:equivalentClass` /
   `owl:equivalentProperty` to existing Wikidata terms.
3. **Turtle ontology** (`ontology/*.ttl`) — the actual TBox.
4. **SHACL shapes** (`shapes/*.shacl.ttl`) — write-time validation.

## 0.1 URI scheme

Decisions to make and pin:

- **Base IRI** — proposed: `http://fontem.eu/`
  - `…/id/{ClassName}/{stable_id}` for entities
  - `…/ontology#{TermName}` for the TBox (classes, properties)
  - `…/graph/{name}` for named graphs
- **Stable ID strategy.** Companies use `gmr_id` (UUID5), Authorities
  use `authority_id` (UUID5). Migration: keep the same UUIDs, slot
  them into the `…/id/Authority/{uuid}` IRI form. Existing IDs are
  stable and externally referenced — don't re-mint.
- **Trailing slash convention** — entities end without slash
  (`…/Authority/foo`), properties with `#` (`…/ontology#hasContract`).
  Standard pattern, no surprises.
- **Hash vs slash** for the ontology — `#`-namespaced. Smaller
  Vocabulary. Easier to dereference single terms.

Output: `ontology/uri-scheme.md` with the full decision and examples
for every entity type currently in Neo4j.

## 0.2 Wikidata alignment

For every Fontem class and property, decide:

1. Is there an equivalent Wikidata class / property? If yes, use
   `owl:equivalentClass` / `rdfs:subClassOf` / `owl:equivalentProperty`
   to map.
2. If no but a parent class exists, use `rdfs:subClassOf` to align
   with the closest Wikidata supertype.
3. If neither, mint our own (it's our ontology — no shame).

Examples to seed the table:

| Fontem term | Wikidata equivalent | Relation |
|---|---|---|
| `fontem:Authority` (contracting authority) | `wd:Q327333` (gov agency), `wd:Q43229` (organization) | `rdfs:subClassOf wd:Q327333` |
| `fontem:Company` | `wd:Q4830453` (business), `wd:Q43229` | `rdfs:subClassOf wd:Q4830453` |
| `fontem:Contract` | `wd:Q2334719` (contract) | `rdfs:subClassOf` |
| `fontem:Lobbyist` | `wd:Q353808` (lobbyist) | `rdfs:subClassOf` |
| `fontem:Person` | `wd:Q5` (human) | `rdfs:subClassOf` |
| `fontem:hasLEI` | `wdt:P1278` (Legal Entity Identifier) | `owl:equivalentProperty` |
| `fontem:hasCountry` | `wdt:P17` (country) | `owl:equivalentProperty` |
| `fontem:hasName` | `rdfs:label` | use `rdfs:label` directly |
| `fontem:tickerSymbol` | `wdt:P249` | `owl:equivalentProperty` |

Where it makes sense, **use the Wikidata IRI directly** instead of
minting our own — `wdt:P17` for country, `rdfs:label` for names. The
goal: queries from Fontem against Wikidata work without translation,
and queries from outside Fontem against our endpoint feel familiar
to anyone who's used Wikidata.

Output: `ontology/wikidata-alignment.md` with the full table and
notes per term.

## 0.3 Class hierarchy + properties (Turtle)

The actual TBox. Five files, organised by domain:

### `ontology/core.ttl`

Top of the hierarchy. The classes everything else extends.

```turtle
fontem:Agent             rdf:type owl:Class .              # parent of Person, Organisation
fontem:Organisation      rdfs:subClassOf fontem:Agent .
fontem:Person            rdfs:subClassOf fontem:Agent ;
                         rdfs:subClassOf wd:Q5 .
fontem:Document          rdf:type owl:Class .              # parent of Contract, Report
fontem:GeographicEntity  rdf:type owl:Class .              # parent of NUTS regions, countries
fontem:hasName           rdfs:subPropertyOf rdfs:label .
fontem:hasCountry        owl:equivalentProperty wdt:P17 .
fontem:hasIdentifier     rdf:type owl:DatatypeProperty .
```

### `ontology/procurement.ttl`

The TED domain. **The property chain that makes the eu-LISA bug
class disappear**:

```turtle
fontem:Authority         rdfs:subClassOf fontem:Organisation ;
                         rdfs:subClassOf wd:Q327333 .
fontem:Contract          rdfs:subClassOf fontem:Document ;
                         rdfs:subClassOf wd:Q2334719 .

fontem:awarded           rdfs:domain fontem:Authority ;
                         rdfs:range  fontem:Contract .
fontem:awardedTo         rdfs:domain fontem:Contract ;
                         rdfs:range  fontem:Company .

# THE LINE THAT FIXES THE WHOLE BUG CLASS
fontem:client            owl:propertyChainAxiom (
                           fontem:awarded
                           fontem:awardedTo
                         ) .
fontem:supplier          owl:inverseOf fontem:client .
```

That `owl:propertyChainAxiom` is the entire CLIENT_OF /
SUPPLIER_OF subsystem, declaratively. The reasoner materialises it on
load. We delete `materialize_trade_edges.py` and the consolidator's
`_refresh_trade_edges` helper.

### `ontology/corporate.ttl`

Companies, listings, ownership.

```turtle
fontem:Company           rdfs:subClassOf fontem:Organisation ;
                         rdfs:subClassOf wd:Q4830453 .
fontem:Listing           rdfs:subClassOf fontem:Document .
fontem:hasLEI            owl:equivalentProperty wdt:P1278 .
fontem:tickerSymbol      owl:equivalentProperty wdt:P249 .
fontem:listedAs          rdfs:domain fontem:Company ;
                         rdfs:range  fontem:Listing .
fontem:owns              owl:TransitiveProperty .   # transitive ownership chains
```

### `ontology/lobbying.ttl`, `ontology/sanctions.ttl`

Smaller; populate after the bigger files settle.

### `ontology/meta.ttl`

Provenance + change tracking. Use **PROV-O** (W3C standard) — every
triple of consequence has provenance:

```turtle
fontem:DataSource        rdfs:subClassOf prov:Entity .
fontem:LoadEvent         rdfs:subClassOf prov:Activity .
# Each ETL run logs (sourceTriples, derivationTime, sourceURL)
```

This *replaces* the current `:DataSource` Neo4j marker — we get
provenance graphs for free.

## 0.4 SHACL shapes (write-time validation)

SHACL is to RDF what JSON Schema is to JSON: assert constraints,
validate writes. Don't skip this — it's how the ETL catches
malformed data before it hits the reasoner.

Minimum starting set:

```turtle
fontem-shapes:CompanyShape
    a sh:NodeShape ;
    sh:targetClass fontem:Company ;
    sh:property [
        sh:path fontem:hasLEI ;
        sh:datatype xsd:string ;
        sh:pattern  "^[A-Z0-9]{18}[0-9]{2}$" ;     # ISO 17442 LEI format
        sh:minCount 0 ; sh:maxCount 1 ;
    ] ;
    sh:property [
        sh:path fontem:hasCountry ;
        sh:datatype xsd:string ;
        sh:pattern  "^[A-Z]{3}$" ;                 # ISO 3166-1 alpha-3
    ] .
```

Every ETL writer runs the data through `pyshacl` (or Virtuoso's
built-in SHACL endpoint) before commit. The current "in-cypher
defensive guards" pattern (e.g. the sanctions matcher's `MIN_NAME_LEN`)
becomes a SHACL constraint — declarative, reusable, test-friendly.

## 0.5 Mapping table: Neo4j → RDF

For every existing Neo4j label and relationship type, a one-line
mapping. This is what the ETL writers consume. Lives in
`ontology/neo4j-mapping.md` (created during Phase 0).

Sketch (will be expanded):

```
Neo4j label        RDF class
-----------------  -----------------------------
Company            fontem:Company
Authority          fontem:Authority
Contract           fontem:Contract
Person             fontem:Person
Lobbyist           fontem:Lobbyist
Listing            fontem:Listing
CPV                fontem:CPVCategory
SanctionedEntity   fontem:SanctionedEntity

Neo4j rel          RDF property
-----------------  -----------------------------
:AWARDED           fontem:awarded
:AWARDED_TO        fontem:awardedTo
:CATEGORIZED_AS    fontem:hasCategory
:LISTED_AS         fontem:listedAs
:CLIENT_OF         (DERIVED — reasoner materialises)
:SUPPLIER_OF       (DERIVED — owl:inverseOf fontem:client)
:SAME_AS (review)  fontem:proposedSameAs (custom — review queue)
:SAME_AS (approved)owl:sameAs
:SANCTIONED        fontem:sanctionedBy
:LOBBIES_FOR       fontem:lobbiesFor
:REPORTED          (becomes prov:wasDerivedFrom in meta graph)
```

Key calls:

- **CLIENT_OF / SUPPLIER_OF do not exist as stored properties.** They
  are derived via OWL property chains. Queries that today read
  `(:Authority)-[r:CLIENT_OF]->(:Company) RETURN r.contracts`
  become `… ?contract … COUNT(?contract)` SPARQL queries. The count
  is computed at query time off the underlying contracts.
- **SAME_AS bifurcates.** The consolidator's review queue (proposed
  merges awaiting human approval) is a custom predicate
  (`fontem:proposedSameAs`) so the reasoner doesn't mistakenly treat
  unreviewed candidates as equivalences. On approval, the reviewer's
  action rewrites `fontem:proposedSameAs` → `owl:sameAs`, the
  reasoner kicks in, and the equivalence is materialised.
- **REPORTED edges** (audit trail of who said what) become a PROV-O
  meta graph, not first-class triples. Saves billions of triples in
  the main graph and gives us proper provenance semantics.

## 0.6 Pilot scope decision

Sanctions is the pilot source. Reasons:

- Smallest dataset (~3K entities, ~50K triples after enrichment).
- Simple shape: `SanctionedEntity` + designation date + jurisdiction
  + alias list.
- Existing test suite (`test_load_eu_sanctions.py`) validates the
  shape, useful for regression-testing the SPARQL writer.
- Defamation-class consequences if data is wrong, so the testing
  bar is already high in the existing pipeline.

If the pilot works end-to-end (ETL writes → Virtuoso → reasoner runs
→ SPARQL query → API → UI displays correctly), every other source
is a known-shape repeat.

## 0.7 What Phase 0 outputs

By end of Phase 0 we have:

- [x] This `MIGRATION.md`
- [ ] `ontology/uri-scheme.md`
- [ ] `ontology/wikidata-alignment.md`
- [ ] `ontology/core.ttl` (skeleton)
- [ ] `ontology/procurement.ttl` (with the property-chain axiom)
- [ ] `ontology/corporate.ttl`
- [ ] `ontology/lobbying.ttl`
- [ ] `ontology/sanctions.ttl`
- [ ] `ontology/meta.ttl`
- [ ] `ontology/neo4j-mapping.md`
- [ ] `shapes/sanctions.shacl.ttl` (pilot-scoped; others later)
- [ ] One end-to-end smoke: load a hand-crafted Turtle file into a
      throwaway Virtuoso (Docker on dev node), run a SPARQL query
      that exercises the property chain, watch the reasoner produce
      the inferred triple. **This is the proof point that the
      design works before we touch any production code.**

Until that smoke fires, Phase 1 doesn't start.

---

# Phase 1 — Infrastructure (sketched)

Once the ontology is settled, stand up real Virtuoso in the cluster.

- Helm chart for Virtuoso OS (StatefulSet, PVC, ConfigMap for
  `virtuoso.ini`, Secret for `dba` password). No good off-the-shelf
  one; we write our own.
- `virtuoso.ini` tuning for the 20 GB allocation:
  `NumberOfBuffers ≈ 2,500,000` (each = 8 KB → ~19 GB working set,
  leaving 1 GB headroom inside the cgroup).
- `MaxClientConnections`, `ServerThreads`, `IndexTreeMaps` per the
  Virtuoso performance tuning guide for a single 12c+20HT box.
- Postgres: add `vectors` schema with `embeddings` table
  `(entity_iri text PRIMARY KEY, embedding vector(768),
  encoder_id text)`. pgvector index: HNSW.
- Backup: cron `backup_online()` to S3-compatible (MinIO) or NFS.
  **Practice the restore path before committing to anything else.**
- Auth: SPARQL UPDATE behind basic auth (or Vault-issued cred);
  SPARQL SELECT public. Reverse proxy via the existing Ingress.
- Monitoring: Prometheus exporter for Virtuoso (community one
  exists); dashboards for query latency, buffer hit rate,
  reasoner materialisation time, disk usage.

# Phase 2 — Pilot ETL: sanctions (sketched)

End-to-end on the smallest source.

- Add `RdfSanctionsSink` to gmr-consolidator (writes to Virtuoso via
  `rdflib` + SPARQL UPDATE, or ISQL bulk-load for full reloads).
- Port `load_eu_sanctions.py` to write Turtle for one ETL run,
  validate against the SHACL shapes, push to Virtuoso.
- Verify: the reasoner fires, sanctions show up in the right named
  graph, queries return them.
- Add an integration test that loads a fixture, runs a SPARQL query,
  asserts on the result. This is the reusable shape every subsequent
  source follows.

The validation criterion isn't "the data loaded" — it's "the data
loaded AND a property chain inference fires AND the SHACL validator
caught at least one synthetic bad-row injection."

# Phase 3 — Wikidata mirror (sketched)

- One-shot bulk-load of the `latest-truthy.nt.bz2` dump into the
  named graph `<http://wikidata.org/entity>` on Virtuoso. Expect
  12-24 hours wall clock, run on the dev node, write to prod over
  the network with `ld_dir_all`.
- Cron weekly: download new dump, load into a side graph, atomic
  `MOVE GRAPH` to swap the alias when load succeeds, drop the old
  side graph. Same pattern Wikipedia mirrors use.
- Document a few canonical federated query patterns:
  - "Enrich a Fontem Authority with Wikidata's biographical fields"
  - "Find Wikidata entities that match a Fontem Company by LEI"
  - "Cross-language label resolution via Wikidata's `rdfs:label`"
- One smoke test: run the `eu-LISA` round-trip — fetch the Fontem
  authority IRI, federate against Wikidata to retrieve its founding
  date and director list, render in the UI.

# Phase 4 — Remaining ETLs (sketched)

In ascending complexity:

1. CDP, NUTS, FIRDS, OpenFIGI (no entity resolution, simple shape)
2. GLEIF (entity resolution, but well-defined LEIs)
3. Authorities + lobbying (multilingual, fuzzy matching — needs the
   pgvector sidecar)
4. TED contracts (largest, most relations — also the test for the
   property chain reasoner under realistic load)
5. Companies (largest write volume — final stress test)

Each loader: write Turtle, validate against SHACL, push via SPARQL
UPDATE. Existing unit tests for ETL shapes mostly transfer (we're
testing the same input → output relationship, just with a different
target store).

The consolidator changes meaningfully here:
- Embedding similarity moves to pgvector (already in Phase 1 infra).
- `apoc.refactor.mergeNodes` is replaced by either:
  - "assert `owl:sameAs`, let the reasoner handle equivalence" (clean,
    matches RDF semantics, but every query must traverse `owl:sameAs`
    which costs at scale), OR
  - "rewrite all triples from URI A to URI B, delete A" (analog of
    physical merge — same write semantics as today, easier to query)
- We pick during Phase 4 design, informed by reasoner cost
  measurements from Phase 2's pilot.

# Phase 5 — Read API cutover (sketched)

Inventory: ~15 endpoints in `edgar-gmr-etl/src/api/routers/` and
~10 in `gmr-community-api/src/api/routers/`.

For each:
- Write a SPARQL implementation alongside the Cypher one.
- Feature-flag the choice via env var.
- Validate with a shadow-comparison test: same input → same shape
  out (modulo ordering).
- Flip the flag. If anything looks wrong, flip back.

The hard ones (allow extra time):
- `GET /graph/{id}` (the explorer): variable-depth traversal with
  edge attribute return. SPARQL property paths handle most of it,
  but the response shape (nodes + edges with attributes) needs
  rewriting from "Cypher path objects" to "explicit triple
  bindings".
- `GET /search` (unified search): currently uses Neo4j fulltext
  indexes. Becomes a `bif:contains` SPARQL query in Virtuoso, with
  a parallel pgvector lookup for semantic similarity, results
  merged by score.
- The assistant's MCP tools (`investigate_entity`, `find_paths`,
  `search_entities`): tool surface to the model stays the same;
  the implementation behind each is rewritten in SPARQL.

# Phase 6 — Reasoner activation (sketched)

Up to this point the property chain axioms are *defined* in the
TBox but not yet *enabled* — the materialise ETL is still running
in parallel. Phase 6 is the cutover:

- Enable the OWL2-RL reasoner on the data graph.
- Wait for materialisation (could be hours on full data).
- Run shadow queries: the inferred `:client` triples should match
  the materialised `CLIENT_OF` edges from `materialize_trade_edges`,
  modulo any drift bugs in the latter.
- Once parity is confirmed:
  - Delete `materialize_trade_edges.py` and its CronJob.
  - Delete `_refresh_trade_edges` from gmr-consolidator's
    `actions.py`.
  - Delete the smoke test `CONSOLIDATION-1` (it asserts a now-
    impossible failure mode — the reasoner can't go stale).
- The eu-LISA bug class is structurally impossible from this point.

# Phase 7 — Decommission Neo4j (sketched)

- Remove the Neo4j Helm release from gitops.
- Remove Neo4j client deps + Cypher from every repo.
- Reclaim the storage.
- Remove the `kubectl get pods -n gmr -l app=neo4j` from runbooks.
- Update `MIGRATION.md` history section: "Phase 7 completed YYYY-MM-DD".

# Open questions / decisions deferred

These are real and need deciding, but only once earlier phases have
informed them:

- **Reasoner cost vs query cost trade-off.** OWL2-RL materialised vs
  query-time inference. Virtuoso defaults to materialised; that's
  almost certainly right for our workload but we measure during
  Phase 2.
- **`owl:sameAs` traversal cost at query time.** If we go the
  "assert `sameAs`, don't merge" route in Phase 4, every query
  must `OPTION (transitive)` traverse `sameAs` chains. Could be
  expensive on busy hubs. Decision deferred to Phase 4.
- **RDF-star vs reification** for edge attributes. Some attributes
  (contract value on a relationship) are awkward in pure RDF.
  Virtuoso supports RDF-star. Default to "drop the attribute,
  derive from underlying triples"; revisit only where that's
  clearly worse.
- **Data versioning / time-travel queries.** Right now we can't
  answer "what was the state of the graph as of date X". With
  PROV-O metadata we can — but the queries get complex. Build the
  capability into Phase 0's `meta.ttl`; decide on UI surfacing
  later.

# Living document

This file changes as the migration progresses. Phases 1+ get
detailed when they start. Decisions made during a phase get
back-ported to the relevant section. Don't treat this as a frozen
spec — treat it as the running record of where we are.

Last updated: phase 0 starting.
