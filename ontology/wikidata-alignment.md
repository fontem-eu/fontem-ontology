# Wikidata alignment

> **Status: draft.** Populate during Phase 0; iterate as new sources
> land.

For every Fontem class and property, the Wikidata equivalent (or
absence thereof). Three reasons this matters:

1. **Federated queries** against Wikidata via `SERVICE` work without
   a translation layer when our properties are already aligned with
   theirs.
2. **External linkage**: when journalists / civic-tech projects link
   into Fontem entities, they should be able to traverse outward
   into Wikidata using their existing query habits.
3. **Reasoning**: `rdfs:subClassOf wd:…` lets the reasoner classify
   our entities consistently with the broader open data ecosystem.
   E.g. anything tagged `fontem:Authority` is also a `wd:Q327333`
   (governmental agency) for query purposes.

Where the Wikidata term is exactly equivalent, **use it directly**
instead of minting our own. `rdfs:label` for names; `wdt:P17` for
country. The fewer Fontem-specific terms we introduce, the cheaper
the federated queries.

## Classes

| Fontem | Wikidata | Relation | Notes |
|---|---|---|---|
| `fontem:Agent` | `wd:Q24229398` (agent) | `rdfs:subClassOf` | Top of our hierarchy |
| `fontem:Organisation` | `wd:Q43229` (organization) | `rdfs:subClassOf` | |
| `fontem:Person` | `wd:Q5` (human) | `rdfs:subClassOf` | |
| `fontem:Authority` | `wd:Q327333` (government agency) | `rdfs:subClassOf` | EU contracting authorities |
| `fontem:Company` | `wd:Q4830453` (business) | `rdfs:subClassOf` | |
| `fontem:Listing` | `wd:Q1166072` (publicly traded company listing) | `rdfs:subClassOf` | |
| `fontem:Contract` | `wd:Q2334719` (legal case / contract) | `rdfs:subClassOf` | TED procurement contracts |
| `fontem:Lobbyist` | `wd:Q353808` (lobbyist) | `rdfs:subClassOf` | |
| `fontem:SanctionedEntity` | (no clean equivalent) | — | Mint our own |
| `fontem:CPVCategory` | `wd:Q42848928` (Common Procurement Vocabulary code) | `rdfs:subClassOf` | EU CPV taxonomy |

## Datatype properties

Direct equivalences — use the Wikidata IRI itself, no Fontem mint:

| What | Use | Notes |
|---|---|---|
| Name (display) | `rdfs:label` | Multilingual via `@lang` |
| Alternate name | `skos:altLabel` | |
| Description | `rdfs:comment` | |
| Country | `wdt:P17` | ISO 3166-1 alpha-3, aligned with Wikidata's preferred form |
| Coordinate location | `wdt:P625` | If/when we add geo |
| Inception / founded | `wdt:P571` | |
| Dissolved / dissolution date | `wdt:P576` | |

Fontem-specific properties (no clean Wikidata equivalent or
domain-too-narrow):

| Fontem property | Wikidata equivalent (if any) | Relation |
|---|---|---|
| `fontem:hasLEI` | `wdt:P1278` (Legal Entity Identifier) | `owl:equivalentProperty` |
| `fontem:tickerSymbol` | `wdt:P249` | `owl:equivalentProperty` |
| `fontem:isin` | `wdt:P946` (ISIN) | `owl:equivalentProperty` |
| `fontem:cik` | (no Wikidata property) | mint own |
| `fontem:tedNoticeId` | (no Wikidata property) | mint own |
| `fontem:cpvCode` | `wdt:P5572` (CPV code) | `owl:equivalentProperty` |

## Object properties

| Fontem | Wikidata | Relation | Notes |
|---|---|---|---|
| `fontem:awarded` | `wdt:P2860` (cites work — wrong domain), no direct Wikidata equivalent | mint own | Authority → Contract |
| `fontem:awardedTo` | (no equivalent) | mint own | Contract → Company |
| `fontem:client` | (derived, no Wikidata) | property chain via reasoner | Authority → Company (CLIENT_OF) |
| `fontem:supplier` | (derived) | `owl:inverseOf fontem:client` | Company → Authority |
| `fontem:owns` | `wdt:P127` (owned by — opposite direction) | `owl:inverseOf wdt:P127` | Transitive |
| `fontem:lobbiesFor` | `wdt:P1830` (owner of) — wrong | mint own | Lobbyist → Company |
| `fontem:listedAs` | (derived from `wdt:P414` stock exchange) | mint own | Company → Listing |
| `fontem:sanctionedBy` | (no equivalent) | mint own | Company → Sanctioning body |

## SAME_AS bifurcation

Two distinct relations are needed where Neo4j had one:

| Use | Predicate | Semantics |
|---|---|---|
| Reasoner-recognised equivalence (after human review) | `owl:sameAs` | Triples from one IRI also assertable on the other; reasoner materialises |
| Review queue (proposed merge, not yet approved) | `fontem:proposedSameAs` | Custom predicate; reasoner ignores; UI surfaces for human decision |
| Rejected merge | `fontem:notSameAs` | Custom predicate; sticky; suppress future re-detection of same pair |

The rationale is in `MIGRATION.md` Phase 4. The short version:
`owl:sameAs` is too strong a commitment to make automatically — it
forces full equivalence including provenance, which we don't always
want. Custom predicates for the consolidator's review pipeline keep
human gating in the loop.

## To populate

This file is a stub. During Phase 0:

1. For every entity type, check whether a closer Wikidata superclass
   exists than `Q43229` (organization) — e.g. `Q3624078` (sovereign
   state) for state-level authorities. Refine as needed.
2. Run a sample federated query (e.g. fetch eu-LISA from Wikidata,
   compare property names) and verify the alignment table doesn't
   miss anything common.
3. Document any property where alignment is *intentional but
   imperfect* — e.g. `fontem:hasName` is a `rdfs:subPropertyOf
   rdfs:label` rather than `owl:equivalentProperty` because we
   sometimes carry multiple `hasName` values per entity (legal vs
   trading vs operational), which `rdfs:label` semantics don't
   strictly forbid but Wikidata convention treats differently.
