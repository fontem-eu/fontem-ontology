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

## Recommendation

**Fuseki is the right substrate for Phase 1.** Reasons:

1. **No drift risk.** The `client_chain` rule fires on every query.
   No cron, no post-load step, no stale-summary class of bug.
2. **The ontology declares the chain** (`owl:propertyChainAxiom` in
   `procurement.ttl`); even though Jena's bundled reasoner doesn't
   pick it up, our rules file mechanically restates the same axiom
   right next to it. The intent stays declarative; the
   implementation is two extra lines per chain in `rules.txt`.
3. **Apache 2.0** — no GPL contagion concerns.
4. **Operationally simpler** — one JVM, one binary, less to tune.
5. **Smaller cold start + memory footprint** — matters on a 32 GB
   shared node.

Reasons we'd reconsider:
- **Scale**: ~1B triples comfortable on Fuseki; ~10B on Virtuoso.
  At Fontem's projected 2-5B triples we're in the borderline zone.
  If we cross 1B and start seeing query latency degrade, we'd want
  to revisit. But that's a problem for Phase 4 / 5, not Phase 0.
- **Fulltext search**: Virtuoso's `bif:contains` is built in and
  works on every literal; Fuseki's text-search story is separate
  setup per dataset (Lucene assembler). For our entity-resolution
  needs (`Company.name` matching) this is real work, but bounded.

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
