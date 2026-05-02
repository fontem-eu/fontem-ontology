# Wikidata alignment

> **Status:** populated (Phase 0 / WS3 deliverable). Updates per
> domain land as ETLs are ported in Phase 4.

For every Fontem class and property, the Wikidata equivalent (or
absence thereof). Three reasons this matters:

1. **Federated queries** against Wikidata via `SERVICE` work without
   a translation layer when our terms are aligned with theirs.
2. **External linkage**: when journalists / civic-tech projects
   navigate into Fontem, they should be able to traverse outward
   into Wikidata using their existing query habits.
3. **Reasoning**: `rdfs:subClassOf wd:…` lets the reasoner classify
   our entities consistently with the broader open-data ecosystem.

## How to read the tables

Each row carries a **confidence flag** (H/M/L). H = exact match,
ship as is. M = good fit but worth a sanity check on a real entity.
L = best available, may revise once we see live data.

Where the Wikidata term is exactly equivalent and we'd never ship a
different one (`rdfs:label`, `wdt:P17`, `wdt:P1278`), we **use the
Wikidata IRI directly** in our ontology and skip the
Fontem-namespaced wrapper. Fewer terms = lower porting cost +
cheaper federation.

## Classes

| Fontem term | Wikidata target | Relation | Confidence | Justification |
|---|---|---|---|---|
| `fontem:Agent` | `wd:Q24229398` | `rdfs:subClassOf` | M | Top-of-hierarchy "being" with agency; aligns with PROV-O `prov:Agent` too |
| `fontem:Organisation` | `wd:Q43229` | `rdfs:subClassOf` | H | "Organization — social entity established to meet needs or pursue goals" — exact |
| `fontem:Authority` | `wd:Q294272` | `rdfs:subClassOf` | H | "Contracting authority that has to comply with public procurement law when awarding a public contract in the EU" — exact match for our domain |
| `fontem:Company` | `wd:Q783794` | `rdfs:subClassOf` | H | "Legal entity representing an association of people…" — standard "company" class, preferred over the activity-flavoured `Q4830453` |
| `fontem:Listing` | `wd:Q798505` | `rdfs:subClassOf` | H | "In corporate finance, the company's shares being on the list of stock that are traded" — exact for our `:Listing` (security on an exchange, not the company) |
| `fontem:Contract` | `wd:Q529458` | `rdfs:subClassOf` | H | "Public contract" / "public procurement" — precise match. (`Q93288` is the generic contract; `Q2334719` was wrong — that's "legal case".) |
| `fontem:Lobbyist` | `wd:Q431603` | `rdfs:subClassOf` | M | "Advocacy group" / "lobbying organization" — entity-class fit. (`Q353808` was a disambiguation page.) |
| `fontem:SanctionedEntity` | `wd:Q116276316` | `rdfs:subClassOf` | H | "Sanctioned entity — person or organization subject of sanctions" — exact match |
| `fontem:CPVCategory` | `wd:Q1500936` | `rdfs:subClassOf` | H | "Common Procurement Vocabulary — classification system…" — exact. (`Q42848928` was a pharmacology paper, wrong.) |
| `fontem:NUTSRegion` | `wd:Q193083` (scheme) + `wd:Q406957` / `wd:Q20719690` / `wd:Q41773366` (level-specific) | `rdfs:subClassOf` per level | H | Q193083 is the NUTS scheme; level-1/-2/-3 region classes are separate Q-numbers — model accordingly via `fontem:nutsLevel` |
| `fontem:Document` | `wd:Q49848` | `rdfs:subClassOf` | H | "Document — form for preservation of structured information" — generic parent for Contract / Filing |
| `fontem:Filing` *(reified from `:FinancialYear`)* | `wd:Q192907` | `rdfs:subClassOf` | H | "Financial statement — formal record of the financial activities of a business" — covers 10-K, ESEF |
| `fontem:CohesionProject` *(NOT MINTED)* | `<http://linkedopendata.eu/entity/…>` | `owl:sameAs` per instance | H | EU Knowledge Graph (Kohesio) is the upstream Wikibase. Don't mint our own class — align to EUKG via the existing `wikibase_qid` field |
| `fontem:LobbyInterest` | (no class — model as SKOS) | `rdfs:subClassOf skos:Concept` | H | 40-entity controlled vocabulary; `skos:prefLabel` carries the name |

## Datatype properties — use Wikidata directly

These are exact equivalences. We don't mint `fontem:hasCountry` —
we just write `wdt:P17` directly in our triples.

| What | Use | Confidence |
|---|---|---|
| Display name | `rdfs:label "..."@xx` | H |
| Alternate / acronym | `skos:altLabel` | H |
| Description / comment | `rdfs:comment` | H |
| Country | `wdt:P17` (sovereign state) | H |
| LEI (Legal Entity Identifier) | `wdt:P1278` | H |
| EU VAT number | `wdt:P3608` | H |
| ISIN | `wdt:P946` (on `:Listing`) | H |
| Ticker symbol | `wdt:P249` (qualifier on stock-exchange relation) | H |
| SEC CIK | `wdt:P5531` | H |
| Inception / founded | `wdt:P571` | H |
| Dissolved date | `wdt:P576` | H |
| CPV code (the literal string) | `wdt:P5417` | H |
| EU Transparency Register ID | `wdt:P2657` | H |
| NUTS code | `wdt:P605` | H |

**Wrong proposals corrected during research** (to save anyone else
the time):
- CPV code is `P5417`, **not** `P5572` (which is a gene expression
  property).
- EU Transparency Register ID is `P2657`, **not** `P11770` (Qobuz
  album ID — totally unrelated).
- `Q1166072` is "financial transaction", not a security listing
  class — use `Q798505` for `:Listing`.
- `Q1764572` is a commune in Mali, not the NUTS region class.

## Object properties — Fontem-specific (mint own)

These are domain-specific and have no clean Wikidata equivalent.
Mint our own predicates; align with PROV-O / SKOS where applicable.

| Fontem property | Domain → Range | Wikidata bridge | Notes |
|---|---|---|---|
| `fontem:awarded` | `Authority → Contract` | none | EU procurement domain; no Wikidata predicate fits |
| `fontem:awardedTo` | `Contract → Company` | none | Same |
| `fontem:client` | `Authority → Company` | (derived) | `owl:propertyChainAxiom (fontem:awarded fontem:awardedTo)` — reasoner materialises |
| `fontem:supplier` | `Company → Authority` | (derived) | `owl:inverseOf fontem:client` |
| `fontem:hasCategory` | `Contract → CPVCategory` | `skos:related` | Treat as SKOS-style categorisation |
| `fontem:listedAs` | `Company → Listing` | `wdt:P414` (stock exchange — different shape) | We model the listing as a separate node; align via `rdfs:subPropertyOf` only |
| `fontem:directParent` | `Company → Company` | `wdt:P749` (parent organization) | `owl:subPropertyOf wdt:P749` |
| `fontem:ultimateParent` | `Company → Company` | `wdt:P749` | Distinguished from `directParent` by transitivity, both are subproperties |
| `fontem:locatedIn` | `Company → NUTSRegion` | `wdt:P131` (located in admin entity) | `owl:equivalentProperty` |
| `fontem:beneficiaryOf` | `Company → CohesionProject` | none | EU funding domain; mint own |
| `fontem:lobbiesFor` | `Lobbyist → Company` | none | Mint own |
| `fontem:interestedIn` | `Lobbyist → LobbyInterest` | `dcterms:subject` | Treat lobby interest as a SKOS subject |
| `fontem:partOf` | `NUTSRegion → NUTSRegion` | `skos:broader` | NUTS hierarchy = SKOS hierarchy |
| `fontem:reportedIn` | `Filing → Year` | none | Reified from `:REPORTED.year` edge attribute |
| `fontem:filedBy` | `Filing → Company` | none | Reified |
| `fontem:nutsLevel` | `NUTSRegion → integer` | `wdt:P1545` (series ordinal) | `wdt:P1545` is a stretch — datatype property is fine on its own |
| `fontem:cohesionFund` | `CohesionProject → string` | none | Mint own |
| `fontem:sanctionedBy` | `Company → SanctionedEntity` | `wdt:P31 wd:Q116276316` (instance of sanctioned entity) | Wikidata pattern: model as `wdt:P31` on the targeted entity, not as a relation. We keep our own predicate for explicitness. |
| `fontem:proposedSameAs` | `T → T` (any class) | none | Review queue; reasoner ignores |
| `owl:sameAs` | `T → T` (any class) | (built-in OWL) | Approved equivalence; reasoner materialises full closure |

## SKOS concept schemes

Three controlled vocabularies model as SKOS, not OWL classes:

| Scheme | Concepts | Notes |
|---|---|---|
| `fontem:CPVScheme` | 6,714 `CPVCategory` instances | `skos:notation` carries the code; `skos:broader` carries `:CPV.division` |
| `fontem:NUTSScheme` | 1,808 `NUTSRegion` instances | `skos:notation` for the NUTS code; `skos:broader` for `:PART_OF` |
| `fontem:LobbyInterestScheme` | 40 concepts | `skos:prefLabel` for `:name` |

## PROV-O alignment (audit / meta graph)

Audit nodes from the consolidator align with PROV-O, not Wikidata:

| Fontem class | PROV-O class | Note |
|---|---|---|
| `fontem:DataSource` | `prov:Entity` | Each upstream loader |
| `fontem:LoadEvent` | `prov:Activity` | A single ETL run |
| `fontem:ConsolidationRun` | `prov:Activity` | The consolidator's batch sweep |
| `fontem:RuleApplication` | `prov:Activity` | One rule firing during a run |
| `fontem:DecisionLog` | `prov:Entity` | Output of a `RuleApplication` |
| `fontem:MergeEvent` | `prov:Activity` | A node-merge action |

Standard PROV-O predicates: `prov:wasGeneratedBy`,
`prov:wasDerivedFrom`, `prov:used`, `prov:startedAtTime`,
`prov:endedAtTime`.

## Five worked examples (federation sanity check)

For each, the planned Fontem IRI, the Wikidata Q-number it should
align with via `owl:sameAs`, and one federated query that should
work after Phase 3.

### 1. eu-LISA (the bug-class canary)

```
Fontem:    <http://data.fontem.eu/id/Authority/78d8b920-1a05-56f2-a84b-6a5e5afe8a59>
Wikidata:  wd:Q15724226 (European Union Agency for the Operational Management of Large-Scale IT Systems)
```

Federated probe:

```sparql
SELECT ?wdLabel ?inception WHERE {
  <http://data.fontem.eu/id/Authority/78d8b920-1a05-56f2-a84b-6a5e5afe8a59> owl:sameAs ?wd .
  SERVICE <https://query.wikidata.org/sparql> {
    ?wd rdfs:label ?wdLabel ; wdt:P571 ?inception .
    FILTER (lang(?wdLabel) = "en")
  }
}
```

Expected: "eu-LISA", `2011-10-25`.

### 2. Siemens AG

```
Fontem:    <http://data.fontem.eu/id/Company/<gleif-uuid5>>
Wikidata:  wd:Q81230 (Siemens)
```

Federated probe (cross-language label resolution):

```sparql
SELECT ?label WHERE {
  <http://data.fontem.eu/id/Company/...> owl:sameAs ?wd .
  SERVICE <https://query.wikidata.org/sparql> {
    ?wd rdfs:label ?label .
    FILTER (lang(?label) IN ("en", "de", "fr", "it"))
  }
}
```

### 3. Apple Inc.

```
Fontem:    <http://data.fontem.eu/id/Company/<edgar-uuid5>>
Wikidata:  wd:Q312
Listing:   <http://data.fontem.eu/id/Listing/AAPL.NASDAQ>
           with wdt:P946 = "US0378331005" (ISIN)
                wdt:P249 = "AAPL"
                wdt:P414 = wd:Q82059 (NASDAQ)
```

Federated probe (find peer companies on the same exchange):

```sparql
SELECT ?peer ?peerLabel WHERE {
  SERVICE <https://query.wikidata.org/sparql> {
    ?peer wdt:P414 wd:Q82059 ; wdt:P31 wd:Q783794 ;
          rdfs:label ?peerLabel .
    FILTER (lang(?peerLabel) = "en")
  }
} LIMIT 20
```

### 4. A TED contract

```
Fontem:    <http://data.fontem.eu/id/Contract/2024-OJS-...>
Wikidata:  none (TED contracts don't have Wikidata items)
EU TED:    <https://ted.europa.eu/...>
```

No `owl:sameAs` to mint here — the contract is a Fontem
identifier with no upstream Wikidata equivalent. That's expected:
TED contract notices are too narrow to be on Wikidata. We carry
them as first-class Fontem entities.

### 5. A registered lobbyist (e.g. Google EU)

```
Fontem:    <http://data.fontem.eu/id/Lobbyist/03181945560-59>
EU TR:     wdt:P2657 = "03181945560-59"
Wikidata:  wd:Q95 (Google) when carrier company is on Wikidata
```

Federated probe:

```sparql
SELECT ?wd ?budget WHERE {
  ?lobbyist wdt:P2657 "03181945560-59" .
  SERVICE <https://query.wikidata.org/sparql> {
    ?lobbyist wdt:P2769 ?budget .  # operating budget if available
  }
}
```

## EU Knowledge Graph (Kohesio) alignment

10,911 `:CohesionProject` nodes already carry `wikibase_qid` (the
EUKG Q-number). On port:

```
<http://data.fontem.eu/id/CohesionProject/{project_id}>
  owl:sameAs <http://linkedopendata.eu/entity/Q{wikibase_qid}> .
```

Federation pattern (Phase 5):

```sparql
SELECT ?title ?budget WHERE {
  <http://data.fontem.eu/id/CohesionProject/...> owl:sameAs ?eukg .
  SERVICE <https://query.linkedopendata.eu/sparql> {
    ?eukg rdfs:label ?title ; ?budgetProp ?budget .
  }
}
```

(Specific predicate names within EUKG — TBD once we connect to
their endpoint with sample queries.)

## Open alignment questions (defer to Phase 4)

These are things WS3 noted but doesn't lock now — too speculative
without seeing live data shapes during ETL port:

1. **`Listing` vs `Company`'s `wdt:P414`**: should the *Company*
   carry `wdt:P414 ?exchange`, or the *Listing* node carry it?
   Wikidata models this as a Company property. We'd lose the
   ticker-as-node abstraction. Decide during the corporate ETL
   port.

2. **OpenSanctions cross-walk**: `wdt:P10632` is OpenSanctions ID
   on Wikidata. Should we also emit `wdt:P10632` for our
   `SanctionedEntity` instances when we have it? Surface in
   sanctions ETL port.

3. **`CohesionProject` upstream predicates** — until we federate
   live against `query.linkedopendata.eu/sparql` with a real
   query, we don't know the exact EUKG predicate names. Lock in
   Phase 4 / Phase 5.

Sources:
- [Q294272 contracting authority](https://www.wikidata.org/wiki/Q294272)
- [Q798505 listing](https://www.wikidata.org/wiki/Q798505)
- [Q529458 public contract](https://www.wikidata.org/wiki/Q529458)
- [Q116276316 sanctioned entity](https://www.wikidata.org/wiki/Q116276316)
- [Q1500936 CPV](https://www.wikidata.org/wiki/Q1500936)
- [Q193083 NUTS](https://www.wikidata.org/wiki/Q193083)
- [Q192907 financial statement](https://www.wikidata.org/wiki/Q192907)
- [Q431603 advocacy group](https://www.wikidata.org/wiki/Q431603)
- [P5417 CPV code](https://www.wikidata.org/wiki/Property:P5417)
- [P2657 EU Transparency Register ID](https://www.wikidata.org/wiki/Property:P2657)
- [P749 parent organization](https://www.wikidata.org/wiki/Property:P749)
