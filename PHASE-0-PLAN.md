# Phase 0 — Detailed Plan (for review)

> **Status:** awaiting approval. Once approved, this becomes the
> execution checklist for Phase 0 and the source of truth for the
> ontology design work.

This document drills the high-level Phase 0 description in
[MIGRATION.md](./MIGRATION.md) into a concrete, sequenced workstream
list — small enough that each line is doable in a half-day to a day,
ordered so each step unblocks the next, and explicit about which
decisions need approval before execution.

## Locked decisions (no further discussion needed)

These are what we agreed on before Phase 0 starts:

| Decision | Choice |
|---|---|
| Storage target | Virtuoso Open Source |
| Primary IRI host | `http://fontem.eu/` |
| IRI patterns | `/id/{Class}/{uuid}` for entities, `/ontology#{Term}` for TBox, hash-namespaced |
| Stable IDs | Keep existing UUID5s from Neo4j; mechanical port |
| Embeddings | Postgres + pgvector sidecar; IRIs are the foreign key |
| Reasoner | OWL2-RL, materialised at load time |
| Wikidata alignment | **Top priority** — use Wikidata IRIs directly where alignment is exact |
| Federation | First-class via `SERVICE <…>`; weekly Wikidata mirror in named graph |
| `SAME_AS` semantics | Bifurcate: `fontem:proposedSameAs` (review queue) → `owl:sameAs` (approved) |
| Edge attributes | Default to query-time aggregation; reify only when truly per-edge |
| `:CLIENT_OF` / `:SUPPLIER_OF` | Derived via `owl:propertyChainAxiom`; **not stored** |
| Audit trail | PROV-O in a separate `meta` named graph |
| Pilot (Phase 2) | Sanctions — small, well-tested loader, end-to-end smoke for the *infra* path |
| Reasoner smoke (Phase 0) | Hand-crafted Turtle, **not** the sanctions ETL — see §6 below |

## Open questions (need your call before workstream 4 starts)

1. **IRI host (resolved by WS1, but flagging for visibility).**
   `fontem.eu` and `www.fontem.eu` both currently resolve to a
   Scaleway-hosted Kanboard installation, not the void42 cluster.
   The recommended answer is a sub-domain (`data.fontem.eu` or
   similar) routed separately to the cluster ingress, identical to
   Wikidata's pattern. WS1 will commit to a concrete sub-domain
   pre-Turtle authoring.

2. **Multilingual labels density.** Authority names already get
   translated into 24 EU languages by the existing LaBSE pipeline.
   Do we emit one `rdfs:label "..."@xx` triple per language per
   entity (could be tens of millions of label triples just for
   procurement authorities), or do we keep the canonical name on
   the entity and surface translations on demand from Wikidata
   `rdfs:label`s? My recommendation: **emit our own labels** because
   we have entities Wikidata doesn't (small contracting
   authorities, niche lobbyists). The volume cost is real but
   bounded.

3. **CPV vocabulary scope.** EU's Common Procurement Vocabulary
   has ~10,000 codes in a hierarchy. We import it as a SKOS
   concept scheme. Should we also emit `owl:equivalentClass`
   alignments to Wikidata where possible (`wdt:P5572` for CPV
   codes that have Wikidata items), or leave the vocabulary
   self-contained for now? My recommendation: **leave self-
   contained for Phase 0**; alignment is a follow-up.

4. **Pilot scope reconsideration (your concern: sanctions is
   isolated).** You're right that sanctions are weakly connected
   and don't exercise the reasoner. I split the proof into two
   pieces:

   - **Phase 0 reasoner smoke** (this document, §6) — hand-crafted
     Turtle with two Authorities, three Companies, five Contracts.
     Loads in seconds. Validates that `fontem:client` actually fires
     from the property chain. *This* is where we prove the design.
   - **Phase 2 ETL pilot — sanctions** — validates the *loader
     infrastructure* (Turtle emit, SHACL validate, SPARQL UPDATE
     against Virtuoso, ETL CronJob shape). Sanctions is fine for
     this because the test isn't about reasoning, it's about
     end-to-end mechanics.

   So sanctions stays as the Phase 2 pilot for the *infra* test.
   The reasoner question gets answered earlier and more
   surgically. **Approve this split, or push back?**

5. **Wikidata-aligned property choices.** For things like contract
   value (the EU exposes it as `eur` in TED data), do we want to
   align with `wdt:P2769` (budget) or mint our own
   `fontem:contractValue`? Wikidata's procurement-domain coverage
   is patchy. My current plan: **mint our own**, but with an
   `rdfs:subPropertyOf` to a generic monetary-amount predicate
   (probably `dcterms:valid` or a custom `fontem:hasMonetaryValue`).
   I'll surface specific cases in workstream 3 for your review.

---

## Workstreams (sequenced)

### Workstream 1 — IRI host decision (½ day)

Probe done up front (see "DNS finding" below); resolves to a real
question that needs an answer before WS4 writes the Turtle.

**DNS finding (May 2026):** `fontem.eu` and `www.fontem.eu` both
resolve to `51.159.141.141` (Scaleway), which is currently serving
a Kanboard installation (nginx 1.22.1, sets `KB_SID` cookie,
redirects `/` → `/login`). The TLS cert does not include `fontem.eu`
in its SAN. The void42 cluster ingress is not on this IP.

So `http://fontem.eu/id/Authority/…` as the entity IRI base would
dereference to a Kanboard login page — not what we want.

**Three options:**

1. **Re-point `fontem.eu` DNS** to the void42 cluster, migrate the
   Kanboard somewhere else (or have nginx in the cluster proxy back
   to it for `/kb` paths). Largest disruption.
2. **Use a sub-domain on a separate route.** Pattern Wikidata uses
   (`www.wikidata.org` for the site, `query.wikidata.org` for SPARQL,
   entity IRIs `http://www.wikidata.org/entity/Q…` independent of
   either). For Fontem: `http://data.fontem.eu/id/Authority/…` or
   `http://kg.fontem.eu/…`. Lowest disruption — add a sub-domain to
   the cluster ingress, no impact on whatever's at the apex. **My
   recommendation.**
3. **Different domain entirely.** Probably overkill.

The output of WS1 is the IRI base locked. Whatever we pick is the
single host string the entire ontology references; getting it right
once is cheap, getting it wrong gets discovered three phases later
when porting is half done.

- [ ] Pick option (recommendation: 2, sub-domain)
- [ ] Pick concrete sub-domain (`data.fontem.eu` / `kg.fontem.eu` /
      `id.fontem.eu` — preference)
- [ ] Add A/AAAA record pointing at the cluster ingress
- [ ] Get a TLS cert via the existing cluster cert-manager
- [ ] One-line `sed` across the repo to replace the placeholder
- [ ] Sketch content-negotiation routing on the ingress (Turtle
      vs HTML). Implementation lands in Phase 1; for Phase 0 we
      just confirm the URL pattern works at all.

Output: locked IRI base; one note pinned in `MIGRATION.md`.

### Workstream 2 — Neo4j schema audit (1-2 days)

The bedrock for everything else. Walk every Neo4j label, every
relationship type, every property on each, and write it down.

This is *not* "what should we have"; it's "what do we currently
have". The mapping comes after.

- [ ] Connect to staging Neo4j, run inventory queries:
  ```cypher
  CALL db.labels() YIELD label RETURN label;
  CALL db.relationshipTypes() YIELD relationshipType RETURN relationshipType;
  CALL db.schema.nodeTypeProperties();
  CALL db.schema.relTypeProperties();
  ```
- [ ] For each label, document:
  - What it represents (one-sentence definition)
  - Cardinality in current staging
  - Properties (name, type, optional/required, range/format)
  - Source (which ETL writes it)
  - Multilingual fields (which properties exist in language variants)
- [ ] For each relationship type, document:
  - Direction, domain label, range label
  - Properties on the relationship (these need special handling)
  - Cardinality (1:1, 1:N, M:N)
  - Source
- [ ] Note any "hidden schema" — labels/types created by ETLs but
  not documented anywhere (the auditor's job is to find these)

Output: `ontology/neo4j-audit.md` — the ground truth current
state. Different from `neo4j-mapping.md` (which proposes the RDF
target); this is just *what is*.

### Workstream 3 — Wikidata alignment deep dive (3-4 days, **highest priority**)

This is the dominant Phase 0 effort and the highest-value work.
Wikidata alignment determines whether federated queries work,
whether external linkers can navigate Fontem naturally, and how
"part of the open web" the published ontology feels.

For every Fontem class and property identified in workstream 2:

- [ ] Search Wikidata for the closest match. Tools:
  - `https://www.wikidata.org/wiki/Special:Search`
  - WDQS query: `SELECT ?item WHERE { ?item rdfs:label "X"@en }`
  - Manual review of the top 5 hits per term
- [ ] Decide alignment kind:
  - `owl:equivalentClass` / `owl:equivalentProperty` (exact match — rare)
  - `rdfs:subClassOf` / `rdfs:subPropertyOf` (Fontem term is more specific)
  - `skos:closeMatch` (related but not strictly equivalent)
  - `skos:exactMatch` (semantically identical, weaker than `owl:equivalentClass`)
  - **No alignment** — only when nothing in Wikidata fits
- [ ] For properties where Wikidata's term is exactly right (e.g.
  `wdt:P17` for country, `wdt:P1278` for LEI), **use the Wikidata
  IRI directly** in our ontology. Don't mint
  `fontem:hasCountry` if `wdt:P17` does the job.
- [ ] For properties where alignment is intentional but imperfect,
  document why in a comment in the Turtle file.
- [ ] Cross-check: pick 5 real entities (eu-LISA, Siemens AG,
  Apple Inc., a TED contract, a registered lobbyist), look them
  up on Wikidata, and confirm our planned alignment lets us
  federate against their Wikidata records cleanly.

Concrete deliverable expanding the existing
`ontology/wikidata-alignment.md`:

| Fontem term | Wikidata target | Relation | Justification | Confidence |
|---|---|---|---|---|
| (one row per Fontem class/property, with confidence H/M/L) |

Confidence flags matter: H = approved without review; M = surface
in your review; L = flag for second pass after Phase 0 ends.

Output: fully populated `ontology/wikidata-alignment.md` with a
row per Fontem term, and 5 worked examples (real entities,
showing how the alignment makes federation work).

### Workstream 4 — Turtle TBox authoring (3-4 days)

With the Neo4j audit (WS2) and Wikidata alignment (WS3) in hand,
the Turtle is mostly mechanical. Each domain file gets populated:

- [ ] `ontology/core.ttl` — `Agent`, `Organisation`, `Person`,
  `Document`, `GeographicEntity`, shared properties (`hasName`
  → `rdfs:label`, `hasCountry` → `wdt:P17`)
- [ ] `ontology/procurement.ttl` — `Authority`, `Contract`,
  `awarded`, `awardedTo`, **the property-chain axiom for
  `fontem:client`**, CPV vocabulary import
- [ ] `ontology/corporate.ttl` — `Company`, `Listing`, `Person`
  (re-used from core), ownership (`fontem:owns` as
  `owl:TransitiveProperty`), LEI / ISIN / ticker properties
- [ ] `ontology/lobbying.ttl` — `Lobbyist`, lobby meetings,
  EU Transparency Register properties
- [ ] `ontology/sanctions.ttl` — `SanctionedEntity`, designation
  date, sanctioning body
- [ ] `ontology/meta.ttl` — `DataSource`, `LoadEvent`,
  `MergeEvent` aligned with PROV-O

Style rules to apply consistently:

- Every class has `rdfs:label "..."@en` and `rdfs:comment "..."@en`
- Wikidata alignment via `rdfs:subClassOf wd:Q…` / `rdfs:subPropertyOf
  wdt:P…` shown explicitly per term, not just in the alignment doc
- Every property declares `rdfs:domain` and `rdfs:range` (the
  reasoner uses these)
- Every property is annotated with a `dcterms:source` pointing at
  the ETL that produces it (or "derived" for reasoner outputs)
- Lint pass: every file passes `pyshacl --shapes core.ttl --data
  procurement.ttl` style validation (shapes catch broken
  cross-references early)

Output: every `ontology/*.ttl` populated. Lint-clean. Reviewable
domain-by-domain.

### Workstream 5 — SHACL shapes for the sanctions pilot (1-2 days)

Validation is what catches malformed data before the reasoner
amplifies it. Phase 0 only needs the sanctions shapes (because
sanctions is the Phase 2 pilot); other shapes land per loader in
Phase 4.

- [ ] `shapes/sanctions.shacl.ttl` — constraints on
  `fontem:SanctionedEntity` (required name, valid date, exactly-
  one designation body, etc.)
- [ ] Validation harness: tiny Python script that runs `pyshacl`
  against fixture data and asserts pass/fail. Lives in this repo
  under `tools/` or similar so it's CI-runnable.

Output: shape file + validation script + a fixture pair (one
"good" sanctions entity, one "intentionally broken" one) that the
script catches as expected.

### Workstream 6 — End-to-end reasoner smoke + ontology CI (2 days)

**The proof point AND a permanent CI deliverable.** Before Phase 1
starts, this must work; from then on, every push to this repo
re-runs it and gates merge on success.

The smoke is intentionally small — hand-crafted Turtle, dockerised
Virtuoso, synthetic test data. The goal is *just* "does the
reasoner produce the inferred triple from the property chain". If
it doesn't, the design is wrong; figure that out *now*. After
Phase 0 closes the smoke stays in the repo as a regression gate
on the ontology — any future change to the TBox that breaks
inference fails CI before merge.

**Resource budget for the dockerised Virtuoso**: must be small.
Cluster runners have limited headroom and CI has to share. Target
shape:

```
NumberOfBuffers   = 32000      # ~256 MB working set
MaxCheckpointRemap = 8000
DefaultIsolation  = 2          # read committed
ServerThreads     = 4          # smoke is single-client
```

That's a ~512 MB total memory footprint for the test container.
Loads the test data + reasons in seconds, lets a CI runner finish
in well under a minute.

Test data:

```turtle
# Two authorities (one EU agency, one Portuguese ministry)
fontem-id:Authority/auth-1 a fontem:Authority ;
    rdfs:label "Test Authority Alpha"@en .
fontem-id:Authority/auth-2 a fontem:Authority ;
    rdfs:label "Test Authority Beta"@en .

# Three companies
fontem-id:Company/co-1 a fontem:Company ;
    rdfs:label "Test Co. One"@en .
fontem-id:Company/co-2 a fontem:Company ;
    rdfs:label "Test Co. Two"@en .
fontem-id:Company/co-3 a fontem:Company ;
    rdfs:label "Test Co. Three"@en .

# Five contracts wiring them
fontem-id:Contract/c-1 a fontem:Contract .
fontem-id:Contract/c-2 a fontem:Contract .
fontem-id:Contract/c-3 a fontem:Contract .
fontem-id:Contract/c-4 a fontem:Contract .
fontem-id:Contract/c-5 a fontem:Contract .

fontem-id:Authority/auth-1 fontem:awarded fontem-id:Contract/c-1, fontem-id:Contract/c-2, fontem-id:Contract/c-3 .
fontem-id:Authority/auth-2 fontem:awarded fontem-id:Contract/c-4, fontem-id:Contract/c-5 .

fontem-id:Contract/c-1 fontem:awardedTo fontem-id:Company/co-1 .
fontem-id:Contract/c-2 fontem:awardedTo fontem-id:Company/co-1 .   # auth-1 → co-1 twice
fontem-id:Contract/c-3 fontem:awardedTo fontem-id:Company/co-2 .   # auth-1 → co-2 once
fontem-id:Contract/c-4 fontem:awardedTo fontem-id:Company/co-2 .   # auth-2 → co-2 once
fontem-id:Contract/c-5 fontem:awardedTo fontem-id:Company/co-3 .   # auth-2 → co-3 once
```

Expected inferences after reasoner run:

```
auth-1 fontem:client co-1
auth-1 fontem:client co-2
auth-2 fontem:client co-2
auth-2 fontem:client co-3
co-1 fontem:supplier auth-1
co-2 fontem:supplier auth-1
co-2 fontem:supplier auth-2
co-3 fontem:supplier auth-2
```

Verification queries (must return the expected results):

```sparql
# Q1 — eu-LISA-style: list a single authority's clients
SELECT ?company WHERE {
  fontem-id:Authority/auth-1 fontem:client ?company
}
# Expect: co-1, co-2

# Q2 — count contracts per (authority, company) pair
# (the query that replaces the old CLIENT_OF.contracts property)
SELECT ?company (COUNT(?contract) AS ?contracts)
WHERE {
  fontem-id:Authority/auth-1 fontem:awarded ?contract .
  ?contract fontem:awardedTo ?company .
}
GROUP BY ?company
# Expect: co-1=2, co-2=1

# Q3 — inverse from Company side (the supplier inverse)
SELECT ?authority WHERE {
  fontem-id:Company/co-2 fontem:supplier ?authority
}
# Expect: auth-1, auth-2

# Q4 — federated probe: enrich auth-1 from Wikidata
# (only meaningful once auth-1 has a sameAs to a real Wikidata item)
SELECT ?wdLabel WHERE {
  fontem-id:Authority/auth-1 owl:sameAs ?wdItem .
  SERVICE <https://query.wikidata.org/sparql> {
    ?wdItem rdfs:label ?wdLabel . FILTER (lang(?wdLabel) = "en")
  }
}
```

Repo deliverables (kept; CI-runnable):

- `tools/smoke/Dockerfile` — Virtuoso image pinned to a known
  version, `virtuoso.ini` baked in with the small-memory tuning
  above. Image is ~150 MB, comparable to a Postgres image.
- `tools/smoke/fixtures/*.ttl` — synthetic test data (the worked
  example above; expanded as new domain TBoxes land — corporate,
  lobbying, sanctions each get their own fixture file).
- `tools/smoke/queries/*.sparql` — verification queries, one per
  invariant being checked.
- `tools/smoke/run.sh` — driver: starts the container, loads the
  TBox + fixtures, waits for the reasoner to materialise, runs
  each query, diffs against the expected output, exits non-zero
  on any mismatch.
- `.gitea/workflows/ci.yml` — runs `tools/smoke/run.sh` on every
  push and pull-request. Merge to `main` is gated on green.

What "permanent CI gate" buys us beyond Phase 0:

- Any future change to a `*.ttl` file that breaks the property
  chain or sameAs inference fails CI *before* merge — same shape
  as the schema-parity test we already have between the assistant's
  Python tool enum and the JS-side advertised actions.
- New domain ontologies (corporate, lobbying, when they land) each
  add a fixture file + a query file + a couple of expected
  inferences. Reasoning regressions across domains get caught the
  same way.
- When ETL writers come online in Phase 4, every loader can
  contribute a "loader output sample" fixture, and the same CI
  harness validates that real-shaped data inferences correctly.

When this CI is green, **Phase 0 is done and Phase 1 starts.**

---

## What Phase 0 explicitly does NOT do

- Stand up production Virtuoso (Phase 1)
- Port any real ETL (Phase 2 onward)
- Touch the existing Neo4j or production stack at all
- Address consolidator rule corrections (your "rules accepting
  things they shouldn't" rant) — out of scope, but I'll log it
  somewhere as a known issue to revisit when the consolidator
  ETL itself is ported in Phase 4

## Phase 0 → Phase 1 hand-off

When Phase 0 closes we have:

- Approved ontology in Turtle (every class & property mapped, lint-clean)
- Approved Wikidata alignment table (5 worked examples verified by hand)
- SHACL shapes for the sanctions pilot
- A green reasoner smoke (the design works on a real triplestore)
- A clean `neo4j-mapping.md` ready for the ETL writers in Phase 4
- A confirmed-reachable `fontem.eu` IRI host

Phase 1 inherits all of these and turns them into running infra.

## Sequence + tentative timeline

Single-threaded execution. Workstreams run strictly in order;
each one finishes before the next starts. (Other Fontem work
will continue in parallel on unrelated matters — that's
orthogonal.)

```
Day 1     WS1: DNS/IRI verification
Days 2-3  WS2: Neo4j schema audit
Days 4-7  WS3: Wikidata alignment deep dive  ← top priority, biggest spend
Days 8-11 WS4: Turtle TBox authoring (one domain file per day)
Day 12    WS5: SHACL shapes for sanctions pilot
Days 13-14  WS6: Reasoner smoke + CI deliverable
Day 15    Review buffer; address findings; close-out
```

~3 weeks of effort once spread across non-Fontem-Phase-0 work.
WS3 dominates. WS6 is now 2 days because it's a permanent
CI deliverable, not a throwaway.

## Approval points

Single-pass approval — I'll merge once you confirm:

1. **Phase 0 scope** — six workstreams, single-threaded, ~3 weeks.
2. **The pilot split** — Phase 0 ships a permanent CI-gated reasoner
   smoke (dockerised Virtuoso, ~512 MB, lives in `tools/smoke/`);
   Phase 2 ETL pilot stays as sanctions for the loader-infra test.
3. **IRI host strategy** — sub-domain (option 2 in WS1), concrete
   sub-domain to be picked in WS1 day-1.
4. **Multilingual labels** — emit our own `rdfs:label "..."@xx`
   triples per entity (don't depend on Wikidata for label resolution).
5. **CPV alignment depth** — self-contained vocabulary for Phase 0,
   Wikidata cross-links as follow-up.
6. **Single-threaded execution** — no parallel workstreams within
   Phase 0 (other Fontem work continues on unrelated matters; that's
   fine).

Reply approved/changes and I'll merge onto main and start WS1.
