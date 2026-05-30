# Plan: Wikidata + CELLAR + EuroVoc + CORDIS ingestion

**Target:** production Virtuoso (`virtuoso.fontem-prod.svc.cluster.local:8890/sparql`)
on cluster-node-3-prod. Single-node, Community Edition, **local-path PVC
(1500 GiB)** — not NFS-backed.

**Total disk footprint at completion:** ~350-450 GiB virtuoso.db.

**License posture:** all four datasets are CC0 1.0 (Wikidata) or CC BY 4.0
(EuroVoc / CELLAR / CORDIS) and compatible with our donation-funded,
non-commercial model.

---

## Federation vs single instance

Single Virtuoso. Our value is exactly the cross-graph joins
(`Company.LEI` ↔ `wd:Q.../P1278` ↔ `cellar:.../oj-reg` ↔
`Authority.country`) that federation taxes hardest. Named graphs give
us the logical separation at zero query cost.

The only argument for a second Virtuoso is reload isolation: Wikidata's
~3-6 day drop-and-reload window degrades SPARQL availability. Defer
that decision until the first refresh cycle produces measurable pain;
splitting later via `MOVE_KEYS_OF_GRAPH` is straightforward.

---

## Phase 0 — Foundations (~3 days)

Prep work before the first bulk load. Lands as code/config PRs only,
no data loads yet.

### Storage staging

Reuse the existing PVC. Create a staging subdirectory inside the
Virtuoso `/database` mount: `/database/staging/{wikidata,eurovoc,cellar,cordis}/`.
The PVC is 1500 GiB local-path; staging never persists more than one
dataset's worth of N-Triples at a time (peak ~150 GiB during the
Wikidata bunzip2).

### virtuoso.ini tuning

The chart currently sets `NumberOfBuffers=800000` via env var (≈6.5 GiB
buffer pool, 8 GiB container memory limit). Bulk loads benefit from
more buffer pool than the steady-state SPARQL surface needs:

```
VIRT_Parameters_NumberOfBuffers     = 1000000   # ≈8 GiB, fits in 12 GiB limit
VIRT_Parameters_MaxDirtyBuffers     = 800000
VIRT_Parameters_MaxCheckpointRemap  = 1000000
VIRT_Parameters_DirsAllowed         = /database, /database/staging
```

Plus bump the container memory limit to 16 GiB during ingestion (revert
to 8 GiB afterward — the steady-state graph fits in 6 GiB cache).

### `fontem-virtuoso-sink` gets a `bulk-load-dir` mode

New entry point: `python -m sink.bulk_load --dir /database/staging/foo
--graph http://data.fontem.eu/graph/foo --workers 4`. Wraps:

```sql
ld_dir('/database/staging/foo', '*.nt', 'http://data.fontem.eu/graph/foo');
-- and N parallel:
rdf_loader_run();
```

over the isql interface. Workers = floor(cores / 2.5); on the
production node that's 4 workers given the 4-CPU limit.

### `virtuoso-exporter` gets per-graph counts

One SPARQL `SELECT (COUNT(*)) WHERE { GRAPH <g> { ?s ?p ?o } }` per
declared graph, cached 15 min (these are expensive — Virtuoso has no
fast graph-cardinality counter on CE). Surfaced as
`virtuoso_graph_triple_count{graph="..."}`. Feeds the
`/data-quality/triples` dashboard.

### Named-graph convention

| IRI | Source |
|---|---|
| `http://data.fontem.eu/graph/wikidata/truthy` | Wikidata `latest-truthy.nt.bz2` |
| `http://data.fontem.eu/graph/eu/eurovoc` | EuroVoc SKOS |
| `http://data.fontem.eu/graph/eu/cellar` | CELLAR (subset, sector-scoped) |
| `http://data.fontem.eu/graph/eu/cordis` | CORDIS, RDF generated from XML |
| `http://data.fontem.eu/graph/links/wikidata` | SAME_AS reflector: our IRIs ↔ wd: |
| `http://data.fontem.eu/graph/links/cellar` | SAME_AS reflector: our IRIs ↔ cellar: |

### Phase 0 gate

- `bulk-load-dir` mode loads a synthetic 1 M-triple file in <2 min
- `virtuoso_graph_triple_count` surfaces for the existing
  `/graph/sanctions` graph
- `/database/staging` writable from the Virtuoso pod (verify via isql
  `ld_dir` smoke call)
- Container memory limit bumped to 16 GiB

---

## Phase 1 — EuroVoc (~1 day)

Smallest dataset, end-to-end pipeline test.

### Source

- Catalogue: <https://data.europa.eu/data/datasets/eurovoc>
- Latest release: **EuroVoc 4.23** (releases every 4-6 months)
- Distribution: the SKOS-Core RDF/XML inside the EuroVoc zip
  (~30-40 MB total zip; <5 MB after picking just the skos-core variant)
- Refresh cadence: every 4-6 months. Cron quarterly is fine.
- License: CC BY 4.0

### Procedure

1. Download the zip via the op.europa.eu download handler (pin the
   `cellarURI` to the latest release notice rather than scraping HTML);
   `If-Modified-Since` honoured (skip when unchanged)
2. Unzip, drop the SKOS-Core RDF/XML into `/database/staging/eurovoc/`
3. `bulk-load-dir --graph http://data.fontem.eu/graph/eu/eurovoc`
4. Verify count via `virtuoso_graph_triple_count` (expect ~1 M triples)
5. Smoke SPARQL: `SELECT ?label WHERE { GRAPH <…/eurovoc> { <…/eurovoc/100142> skos:prefLabel ?label . FILTER(lang(?label) = "en") } }` returns a hit

### Attribution

Surface "EuroVoc © European Union, reused under CC BY 4.0" in the
`/data-quality/triples` dashboard footer.

### Phase 1 gate

- Triple count ≥ 800 000 (allow for release-to-release variance)
- SPARQL probe returns a label in en, de, fr, es

---

## Phase 2 — Wikidata truthy dump (~1-2 weeks elapsed)

The big one. Encyclopedic context for report-writing + AI-helper
sandboxing (the MCP `sparql_query` tool hits our local Virtuoso instead
of `query.wikidata.org`, eliminating an entire egress surface for
jailbreak attempts).

### Source — use a mirror, not the primary

- Primary `https://dumps.wikimedia.org/` rate-limits to **3 connections
  per IP** and the front page explicitly tells heavy users to use a
  mirror. Primary mirror in EU: `mirror.accum.se` (Academic Computer
  Club Umeå)
- File: `latest-truthy.nt.bz2`, ~42.7 GiB compressed, ~1.5 TiB raw
  N-Triples (~15 B triples)
- Compressed with **multi-stream bz2** — must use `lbzip2`, not stock
  `bzip2` (parallel decompression, ~10× faster on a 4-core box)
- Refresh cadence: dated dumps every 2-3 days under `entities/YYYYMMDD/`,
  `latest-truthy.nt.bz2` is a symlink. We refresh **monthly**.
- License: **CC0 1.0** — no attribution obligation; we'll attribute
  anyway in the dashboard footer.
- Required UA: Wikimedia's
  [User-Agent policy](https://foundation.wikimedia.org/wiki/Policy:User-Agent_policy)
  requires `<client>/<ver> (<contact>) <lib>/<ver>`. Our
  `Fontem-ETL/1.0 (+https://fontem.eu; team@fontem.eu)` already
  matches.

### Procedure

1. Download to `/database/staging/wikidata/latest-truthy.nt.bz2` from
   mirror.accum.se with `curl --header "User-Agent: Fontem-ETL/..."`
2. `lbzip2 -d --keep` → ~1.5 TiB N-Triples. **Disk check before this
   step** — we need 150 GiB free in `/database/staging` (we'll shard
   and load the file in 10 M-line chunks, not write the whole 1.5 TiB
   uncompressed at once)
3. `split -l 10000000 latest-truthy.nt truthy-` produces ~150 shards
4. `bulk-load-dir --dir /database/staging/wikidata --pattern 'truthy-*'
   --graph http://data.fontem.eu/graph/wikidata/truthy-staging --workers 4`
5. Expected load: 3-6 days. Run during a planned maintenance window.
6. Once load completes, atomic swap:
   `DB.DBA.MOVE_KEYS_OF_GRAPH(<...wikidata/truthy-staging>,
   <...wikidata/truthy>)` — SPARQL queries hitting the steady-state
   graph see the swap as a single transaction.
7. Drop `…/truthy-staging`. Run `checkpoint;` to flush.

### Refresh strategy

Monthly cron in `fontem-virtuoso-sink`: same flow but always loads into
`…/truthy-staging`, then atomic-swaps. The previous month's data lives
in `…/truthy` continuously, so SPARQL stays available throughout.

### Phase 2 gate

- Triple count ≥ 14 B in `/graph/wikidata/truthy`
- `virtuoso.db` size 250-400 GiB (depending on compression)
- SPARQL probe: `SELECT ?qid WHERE { GRAPH <…/wikidata/truthy> { ?qid <http://www.wikidata.org/prop/direct/P1278> "5493000IBP32UQZ0KL24" } }` returns Apple Inc's QID
- Existing `/graph/sanctions` SPARQL latency unchanged (p99 measurement
  before + after)

---

## Phase 3 — CELLAR (~1 week + EU Login dependency)

EU legal acts + dossiers. Highest compliance value (link sanctions to
the regulations enacting them; procurement contracts to the directive
they're filed under).

### Source — EU Login required

- Bulk-dump portal: <https://datadump.publications.europa.eu/> —
  **requires EU Login** (free registration, takes ~10 min)
- EUR-Lex's data-reuse page explicitly directs bulk users here, away
  from the SPARQL endpoint (which has a 60 s query timeout and is
  intended for exploration, not harvest)
- Format: per-sector / per-language Turtle + N-Triples
- License: CC BY 4.0 via Commission Decision 2011/833
- Full corpus is hundreds of GB; we pick the sectors that matter:
  - `oj` — Official Journal (legal acts, regulations, directives)
  - `dossier` — inter-institutional dossiers
  - English + French + the languages our user base reads
- Refresh cadence: weekly upstream; we refresh **quarterly**

### Prerequisite ⚠️

EU Login account registered for `team@fontem.eu`. Out-of-band task —
the platform owner handles this once. The bearer token gets stored in
Vault under `secret/fontem-prod/cellar` with key `bearer_token`. VSO
syncs it to a K8s Secret in `fontem-prod`.

### Procedure

1. Authenticate against EU Login, store bearer in Vault, VSO syncs to
   `secret/cellar-credentials`
2. Download selected sector tarballs to `/database/staging/cellar/`
   (parallel up to 4 streams — within their "reasonable use" guidance)
3. Untar, point `ld_dir` at the resulting Turtle / N-Triples files
4. `bulk-load-dir --graph http://data.fontem.eu/graph/eu/cellar`
5. Expected load: ~24 h for the OJ + dossier subset (~100 GiB raw)
6. Cross-link: SPARQL `CONSTRUCT` that emits SAME_AS triples between
   `cellar:` entity IRIs and our `data.fontem.eu/id/Authority/*` IRIs
   (join on the agency identifier). Lands in `/graph/links/cellar`.

### Attribution

"Source: EU Publications Office, reused under CC BY 4.0" on the
`/data-quality/triples` dashboard.

### Phase 3 gate

- Triple count ≥ 500 M in `/graph/eu/cellar`
- SPARQL probe: a known sanctions regulation (e.g. Council Regulation
  269/2014) resolves with its title in EN + FR
- `/graph/links/cellar` populated with ≥ 100 SAME_AS edges to existing
  Authority IRIs

---

## Phase 4 — CORDIS (~2 weeks)

EU Horizon / H2020 / FP7 research-project funding flows. Adds two new
node types to Neo4j on top of the Virtuoso load.

### CORDIS no longer publishes RDF directly

CORDIS retired the linked-data dump. Only CSV / XML / JSON now. So
Phase 4 has two parts: ingest into Neo4j directly via a new ETL loader
(the value-creation path) and generate RDF from the XML for Virtuoso
(the encyclopedic-context path, optional).

### Sources

| Programme | Dataset | Size (zip) |
|---|---|---|
| Horizon Europe (2021-2027) | <https://data.europa.eu/data/datasets/cordis-eu-research-projects-under-horizon-europe-2021-2027> | ~250 MB |
| H2020 (2014-2020) | <https://data.europa.eu/data/datasets/cordish2020projects> | ~600 MB |
| FP7 (2007-2013) | <https://data.europa.eu/data/datasets/cordisfp7projects> | ~200 MB |

License: CC BY 4.0. Refresh cadence: monthly (Horizon Europe), quarterly
(legacy programmes). All hosted behind data.europa.eu's CDN; parallel
ranges fine.

### Neo4j side (new node types)

New event types in `fontem-event-schemas`:

- `UpsertGrant` — id, programme, title, funding_amount_eur, ec_contribution_eur, start_date, end_date, status, summary
- `UpsertProgramme` — id, label, framework (Horizon Europe / H2020 / FP7), start_year, end_year

New node types: `Grant`, `Programme`. New edges:

- `AWARDED_GRANT` (`Company` → `Grant`) — beneficiary relationship
- `UNDER_PROGRAMME` (`Grant` → `Programme`) — framework membership

New ETL loader: `fontem-api/src/etl/load_cordis.py`. Reads the
project + organization XML from each programme dump, resolves
organizations to existing `Company` nodes by LEI / VAT / name (existing
resolver pattern, same as `load_eu_lobbying.py`). Emits the events.

### Virtuoso side (generated RDF)

In the same loader, also emit Turtle: one `cordis:Project` per project,
one `cordis:Organization` per participating organization, linked to
the corresponding `data.fontem.eu/id/Company/{gmr_id}` IRI via SAME_AS.
Written to `/database/staging/cordis/cordis.ttl`, loaded into
`/graph/eu/cordis`.

### Phase 4 gate

- `Grant` node count ≥ 50 000 in Neo4j (Horizon Europe ~5 000 + H2020
  ~35 000 + FP7 ~25 000, of which we keep the active subset)
- `Programme` node count = 3 (Horizon Europe, H2020, FP7)
- ≥ 5 000 `AWARDED_GRANT` edges resolve to existing `Company` nodes
  (cross-link rate; the rest get an `Organization` shim node)
- Virtuoso `/graph/eu/cordis` triple count ≥ 5 M

---

## Phase 5 — Refresh hardening + monitoring (ongoing)

- **Per-graph counts** on `/data-quality/triples` as load-verification
  source of truth (continues from Phase 0)
- **Alerts**: `virtuoso.db` size >300 GiB (warn), >1.2 TiB (critical);
  per-graph triple count drops >10% week-over-week (warn — suggests a
  reload bug); SPARQL endpoint p99 >5 s during business hours (warn)
- **Refresh runbook** in
  `fontem-ontology/runbooks/virtuoso-bulk-load.md`: pre-checks (disk
  free, exporter healthy), drop-and-reload procedure for each graph,
  post-checks
- **One-Virtuoso-vs-two decision point**: after the first Wikidata
  refresh cycle (~6 weeks from start), measure SPARQL p99 during the
  reload window. If p99 >10 s for >2 h, schedule a second instance
  dedicated to Wikidata + federate the cross-graph joins.

---

## License summary (recap)

| Source | License | Attribution shipped |
|---|---|---|
| Wikidata | CC0 1.0 — no obligation | Yes (custom) |
| EuroVoc | CC BY 4.0 | Yes |
| CELLAR | CC BY 4.0 (Decision 2011/833) | Yes |
| CORDIS | CC BY 4.0 | Yes |

---

## Fair-use posture summary

| Source | Bulk-access channel | Concurrency | Required UA |
|---|---|---|---|
| Wikidata | Mirror (`mirror.accum.se`), not primary | 1 serial download | `<client>/<ver> (<contact>)` |
| EuroVoc | Single zip via op.europa.eu | 1 GET | Any (contact-bearing UA polite) |
| CELLAR | datadump.publications.europa.eu, EU-Login auth | ≤4 parallel | Any (Bearer required) |
| CORDIS | data.europa.eu CDN per programme | Parallel ranges fine | Any |

**Don't-do gotcha**: parallel-fetching `latest-truthy.nt.bz2` from
`dumps.wikimedia.org` directly trips Wikimedia's 3-connections-per-IP
cap. Always use a mirror.

---

## MCP integration

`fontem-mcp-server` gains a `sparql_query` tool that proxies SPARQL to
our Virtuoso (`http://virtuoso.fontem-prod.svc.cluster.local:8890/sparql`).
The AI helper queries our local Virtuoso for Wikidata facts, EuroVoc
labels, CELLAR regulatory context — eliminating external network
egress for those classes of question. The system prompt is updated
with the named-graph inventory so the agent knows which graph to query
for what.

Two security follow-throughs:

- Query timeout enforced server-side (default 60 s)
- SPARQL `UPDATE` / `INSERT` / `DELETE` blocked at the MCP layer
  (read-only against the helper's view of Virtuoso). The MCP server's
  Virtuoso role is `SPARQL_SELECT`, not `SPARQL_UPDATE`.

---

## What to ship first (PR sequence)

1. **fontem-virtuoso-sink**: `bulk-load-dir` mode + unit tests
2. **virtuoso-exporter**: per-graph triple-count metric + Grafana panel
3. **gitops**: virtuoso.ini buffer bump, `DirsAllowed` for staging,
   container memory limit bumped to 16 GiB for ingestion, staging
   sub-PVC if needed
4. **fontem-mcp-server**: `sparql_query` tool + dataset inventory in
   the agent system prompt
5. **fontem-ontology**: this runbook (the one you're reading) + per-
   source attribution snippets for `/data-quality/triples`
6. **First load**: EuroVoc — end-to-end smoke test on the smallest
   dataset

After EuroVoc lands clean, Wikidata + CELLAR + CORDIS follow as
operational data loads driven by the runbook above, with the CORDIS
event-schema PR being the only additional code work.
