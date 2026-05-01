# Neo4j schema audit — current state of truth

> **Workstream**: WS2 of Phase 0.
> **Date**: 2026-05-01.
> **Source**: live `gmr` namespace Neo4j pod (`neo4j-85bc495f4c-g8k44`).
> **Note**: there is only one Neo4j deployment across all "environments"
> (gmr, gmr-staging, gmr-dev, gmr-dast); all four namespaces' API
> services point at this same backend. So this audit is the truth
> for every environment.

This is *what is*, not *what we want*. The Turtle authoring in WS4
maps from this baseline; the Wikidata alignment in WS3 references
it. The mapping table in `neo4j-mapping.md` becomes concrete once
both this audit and the WS3 alignment land.

## Cardinality summary

```
Nodes      ─ ~2.5M total
Edges      ─ ~2.8M total
Largest:     Company (2.14M) ─ dominant; >85 % of all nodes
             FinancialYear (67K)
             ConsolidationRun (58K)
             Contract (57K)
Audit-only:  DecisionLog, RuleApplication, MergeEvent, ConsolidationRun
             (~131K combined; not part of the published graph but
             must be ported as PROV-O metadata)
```

Per-label exact counts:

| Label | Count | Class? | Source ETL |
|---|---:|---|---|
| Company | 2,144,215 | yes | load_gleif, load_us_companies, load_eu_listings |
| FinancialYear | 66,854 | yes (data) | load_us_financials |
| ConsolidationRun | 58,491 | meta (audit) | gmr-consolidator (`actions.py`) |
| Contract | 57,019 | yes | load_ted_contracts |
| DecisionLog | 37,157 | meta (audit) | gmr-consolidator |
| RuleApplication | 37,151 | meta (audit) | gmr-consolidator |
| Authority | 34,440 | yes | load_ted_contracts (extracted from contracts) |
| Listing | 17,293 | yes | load_eu_listings, load_firds |
| Lobbyist | 16,986 | yes | load_eu_lobbying |
| CohesionProject | 10,911 | yes | load_eu_knowledge_graph |
| CPV | 6,714 | yes (taxonomy) | load_cpv |
| SanctionedEntity | 4,089 | yes | load_eu_sanctions |
| MergeEvent | 3,528 | meta (audit) | gmr-consolidator |
| NUTSRegion | 1,808 | yes (taxonomy) | load_nuts |
| LobbyInterest | 40 | yes | load_eu_lobbying |

`Person` and `BeneficialOwner` were declared (UNIQUE constraints
existed) but had zero nodes. **Dropped from the schema 2026-05-01
per GDPR call** — Fontem deliberately does not store data about
natural persons. Constraints removed from Neo4j with:

```
DROP CONSTRAINT person_id IF EXISTS;
DROP CONSTRAINT bo_id    IF EXISTS;
```

These classes do not migrate to the new ontology.

## Per-label property catalog

### `Authority` (34,440 nodes)

| Property | Type | Mandatory | Note |
|---|---|---|---|
| `authority_id` | String | yes | UNIQUE constraint; UUID5 |
| `name` | String | yes | Source language |
| `country` | String | yes | ISO-3166-1 alpha-3 |
| `name_<lang>` × 24 | String | no | One column per EU language (`name_bg`, `name_cs`, …, `name_sv`) |
| `name_lang` | String | no | Detected source-language code |
| `name_embedding` | DoubleArray | no | LaBSE 768-d vector |
| `name_embedding_dim` | Long | no | Always 768 (sanity) |
| `name_embedding_encoder` | String | no | e.g. `labse@1.0.0-836121a` |
| `multilingual_updated_at` | DateTime | no | Last enrichment timestamp |

**RDF call (porting):**
- 24 `name_<lang>` columns → 24 `rdfs:label "..."@<lang>` triples
- `name_embedding` → out of band (pgvector sidecar, not RDF)
- `multilingual_updated_at` → PROV-O `prov:wasGeneratedAtTime` on the enrichment activity

### `Company` (2,144,215 nodes)

| Property | Type | Mandatory | Note |
|---|---|---|---|
| `gmr_id` | String | yes | UNIQUE constraint; UUID5 |
| `name` | String | yes | |
| `country` | String | yes | ISO-3166-1 alpha-3 |
| `lei` | String | no | Legal Entity Identifier (ISO 17442); INDEXED |
| `historic_leis` | StringArray | no | Past LEIs (successor merges); INDEXED |
| `vat` | String | no | VAT number |
| `cik` | String | no | SEC EDGAR CIK; INDEXED |
| `legal_form` | String | no | XJHM, etc. |
| `active` | Boolean | no | |

**Notable**: no multilingual columns — Company names ship as-is. No
embedding (yet — would be added if cross-language Company resolution
becomes a thing).

### `Contract` (57,019 nodes)

Identity: `ted_notice_id` (UNIQUE, e.g. `2024-OJS-…`).

Heavy multilingual surface (24 `title_<lang>` columns + `title_lang`).

| Property | Type | Mandatory | Note |
|---|---|---|---|
| `ted_notice_id` | String | yes | UNIQUE |
| `ted_url` | String | yes | |
| `title` | String | yes | Source language |
| `title_<lang>` × 24 | String | no | EU languages |
| `title_lang` | String | no | Source language code |
| `description` | String | yes | |
| `cpv_main` | String | yes | CPV code (FK to `:CPV.code`) |
| `country` | String | yes | |
| `award_date` | String | yes | |
| `award_date_source` | String | yes | Provenance of the date |
| `publication_date` | String | yes | |
| `notice_type` | String | yes | |
| `procedure_type` | String | no | |
| `bt701` | String | yes | TED business term identifier |
| `value_eur` | Double | no | Normalised value (EUR) |
| `value_eur_str` | String | no | Original string |
| `value_currency` | String | no | Source currency |
| `value_original` | Double | no | Source-currency amount |
| `value_original_str` | String | no | |
| `value_undisclosed` | Boolean | yes | True when contract value not published |
| `currency_inferred` | Boolean | yes | True when currency was guessed (not stated) |
| `loaded_at` | String | yes | ETL load timestamp |
| `multilingual_updated_at` | DateTime | no | |

### `Listing` (17,293 nodes)

| Property | Type | Mandatory |
|---|---|---|
| `ticker` | String | yes (UNIQUE) |
| `exchange` | String | yes |
| `currency` | String | yes |
| `active` | Boolean | yes |

Worth noting: ISIN does not appear as a node property here; FIRDS
loader uses `Listing.isin` constraint, but the live schema doesn't
show `isin` — likely the property exists but is sparse, so
`db.schema.nodeTypeProperties` doesn't surface it. Worth confirming
in WS4.

### `Lobbyist` (16,986 nodes)

| Property | Type | Mandatory |
|---|---|---|
| `tr_id` | String | yes (UNIQUE) — Transparency Register ID |
| `name` | String | yes |
| `acronym` | String | yes |
| `category` | String | yes |
| `country` | String | yes |
| `city` | String | yes |
| `entity_form` | String | yes |
| `cost_min` / `cost_max` | Long | yes — annual lobbying spend bracket |
| `members_fte` | Double | yes |
| `goals` | String | yes |
| `website` | String | yes |
| `registration_date` | String | yes |
| `last_updated` | String | yes |
| `ep_passes` | Long | yes — number of European Parliament access passes |

Heavily structured. Most fields mandatory.

### `LobbyInterest` (40 nodes)

| Property | Type | Mandatory |
|---|---|---|
| `name` | String | yes |

Tiny vocabulary (40 distinct interests). Probably belongs as a
`skos:Concept` in a small concept scheme, not a class with
instances.

### `SanctionedEntity` (4,089 nodes)

| Property | Type | Mandatory |
|---|---|---|
| `entity_id` | String | yes (UNIQUE) — EU FSD entity ID |
| `name` | String | yes |
| `aliases` | StringArray | yes |
| `entity_type` | String | yes — "P" (person) or "E" (entity) |
| `nationality` | String | yes |
| `designation_date` | String | yes |
| `eu_reference` | String | yes — EU regulation cite |
| `legal_basis` | String | yes |
| `listing_reason` | String | yes |
| `sanction_regime` | String | yes |

### `CohesionProject` (10,911 nodes)

EU Cohesion Funds beneficiary projects. Connects via
`(Company)-[:BENEFICIARY_OF]->(CohesionProject)`.

| Property | Type | Mandatory |
|---|---|---|
| `project_id` | String | yes (UNIQUE) |
| `programme` | String | yes |
| `fund` | String | yes |
| `country` | String | yes |
| `title` | String | yes |
| `description` | String | no |
| `total_budget` | Double | yes |
| `eu_contribution` | Double | no |
| `start_date` / `end_date` | String | no |
| `nuts_code` | String | no — links to `:NUTSRegion.code` |
| `wikibase_qid` | String | yes — **already carries Wikidata Q-number** |

**Notable**: `wikibase_qid` is the only property in the whole graph
that already does Wikidata alignment explicitly. In RDF this
becomes `owl:sameAs wd:Q…` directly.

### `FinancialYear` (66,854 nodes)

US/EU listed-company filing data per fiscal year. ~25 numeric
properties (revenue, net_income, total_assets, etc.). Connects via
`(Company)-[:REPORTED {year: int}]->(FinancialYear)`.

The `year` is on the **edge**, not the node — the edge is what
distinguishes "Apple's FY2023" from "Apple's FY2024". Worth a flag:
this is exactly the kind of edge attribute that becomes awkward in
RDF. Two options for the port:
- Reify: `Filing` as a class, with `forCompany`, `forYear`, and the
  numeric properties on it. The current `:FinancialYear` node
  becomes the reified Filing.
- RDF-star: keep `(Company) -[:reportedFor]-> (Year)` and annotate
  the edge.

I recommend **reify**. Filing is conceptually a thing in itself
(it has a filing date, a source URL, a fiscal year, and lots of
numbers); it deserves to be a node.

### `CPV` (6,714 nodes — taxonomy)

| Property | Type | Mandatory |
|---|---|---|
| `code` | String | yes (UNIQUE) |
| `description` | String | no |
| `division` | String | no |

Imports nicely as a SKOS concept scheme: `:CPV.code` →
`skos:notation`, `:CPV.description` → `skos:prefLabel`,
`:CPV.division` → `skos:broader`.

### `NUTSRegion` (1,808 nodes — taxonomy)

| Property | Type | Mandatory |
|---|---|---|
| `code` | String | yes (UNIQUE) |
| `name` | String | yes |
| `level` | Long | yes (0, 1, 2, 3) |
| `country_alpha3` | String | no |

Connected by `[:PART_OF]` (1,768 edges, NUTSRegion → NUTSRegion)
forming the hierarchy. Same SKOS pattern as CPV.

### Audit / meta labels

`MergeEvent`, `DecisionLog`, `RuleApplication`, `ConsolidationRun`
— the consolidator's audit trail. Together ~136K nodes. Should NOT
end up in the main `data` graph; they're PROV-O `prov:Activity` /
`prov:Entity` records and belong in a separate `meta` named graph.

### Empty (declared, no nodes)

`Person` and `BeneficialOwner` have UNIQUE constraints
(`person_id`, `bo_id`) but zero nodes. The intent is clearly there
— directors, lobby contacts, beneficial-ownership chains — but no
ETL is currently writing them. Recommendation for the Turtle:
**define the classes** (the ontology is decoupled from instances)
so that when ETLs eventually populate them, the schema is already
in place.

## Per-relationship catalog

| Type | Domain | Range | Count | Properties |
|---|---|---|---:|---|
| `LOCATED_IN` | Company | NUTSRegion | 1,918,709 | none |
| `SUBSIDIARY_OF` | Company | Company | 251,028 | `type` (String) — relationship kind from GLEIF |
| `INTERESTED_IN` | Lobbyist | LobbyInterest | 164,278 | none |
| `AWARDED_TO` | Contract | Company | 105,542 | none |
| `CLIENT_OF` | Authority | Company | 84,315 | `contracts` (Long), `total_eur` (Long\|Double), `earliest`/`latest` (String) — **derived/materialised** |
| `SUPPLIER_OF` | Company | Authority | 84,315 | mirror of CLIENT_OF (`contracts`, `total_eur`, `earliest`, `latest`) |
| `REPORTED` | Company | FinancialYear | 66,854 | `year` (Long) — distinguishes filings |
| `AWARDED` | Authority | Contract | 57,021 | none |
| `CATEGORIZED_AS` | Contract | CPV | 57,019 | none |
| `APPLIED` | ConsolidationRun | RuleApplication | 37,151 | none — audit |
| `PRODUCED` | RuleApplication | DecisionLog | 37,151 | none — audit |
| `LISTED_AS` | Company | Listing | 17,293 | none |
| `BENEFICIARY_OF` | Company | CohesionProject | 10,911 | none |
| `SAME_AS` (Authority↔Authority) | Authority | Authority | 2,078 | review-queue metadata (see below) |
| `PART_OF` | NUTSRegion | NUTSRegion | 1,768 | none — taxonomy hierarchy |
| `SAME_AS` (Company↔Company) | Company | Company | 705 | review-queue metadata |

`:SAME_AS` properties (review queue):

| Property | Type | Note |
|---|---|---|
| `confidence` | Double | summary (highest of detection_confidences) |
| `method` | String | rule_name at max-confidence index |
| `detected_at` | String | timestamp at max-confidence index |
| `detection_rules` | StringArray | per-detection (parallel arrays) |
| `detection_confidences` | DoubleArray | per-detection |
| `detection_dates` | StringArray | per-detection |
| `reviewed` | Boolean | sticky-once-true |
| `verdict` | String | "rejected" / unset |
| `conflict` | Boolean | sticky-once-true |

## Constraints + indexes

9 UNIQUE constraints (the identity properties), post-GDPR cleanup:

```
Authority.authority_id
CohesionProject.project_id
Company.gmr_id
Contract.ted_notice_id
CPV.code
Listing.ticker
Lobbyist.tr_id
NUTSRegion.code
SanctionedEntity.entity_id
```

(`Person.person_id` and `BeneficialOwner.bo_id` were dropped —
see the labels table above.)

Range/lookup indexes on Company secondary identifiers
(`Company.cik`, `Company.lei`, `Company.historic_leis`); range
indexes on consolidator audit (`DecisionLog.*`, `ConsolidationRun.*`);
fulltext on `Company.name` (`company_name_ft`); vector on
`Authority.name_embedding` (768-d, cosine).

## Hidden / surprise findings

Things the live graph carries that the loader DDL didn't make
obvious. Each finding is followed by the ✅ decision (call made
2026-05-01).

1. **`Person` and `BeneficialOwner` declared but empty.** Both had
   UNIQUE constraints; neither had any nodes.
   **✅ Decision: drop entirely.** Fontem deliberately does not
   store data about natural persons (GDPR + scope). Constraints
   already removed from Neo4j. These classes do not appear in the
   ontology.

2. **`SANCTIONED` rel does not exist in the live graph.** Declared
   in `load_eu_sanctions.py` for confident matches; zero edges.
   **✅ Decision: keep the predicate, accept zero is fine.**
   Sanctions are defamation-class — a confident automated link
   between a specific company and a sanctioned entity *is* a
   journalism-grade story. Zero edges means no automated rule
   has crossed that bar; if one ever does, the journalists handle
   it. The predicate stays defined in the ontology so the loader
   can write into it whenever the resolver produces a confident
   hit.

3. **`SUBSIDIARY_OF` carries a `type` property** (DIRECT_PARENT /
   ULTIMATE_PARENT / etc. from GLEIF).
   **✅ Decision: split into two predicates on port.** WS4 emits
   `fontem:directParent` and `fontem:ultimateParent` instead of
   one predicate with a discriminator. Cleaner SPARQL.

4. **`REPORTED` carries `year` on the edge.** Real edge attribute.
   **✅ Decision: reify on port.** `Filing` becomes a class with
   `forCompany` / `forYear` / numeric properties. The current
   `:FinancialYear` node merges into the reified Filing.

5. **`CLIENT_OF` and `SUPPLIER_OF` are the eu-LISA bug class.**
   84,315 materialised edges each.
   **✅ Decision: derive via property chain, do not store.**
   `fontem:client owl:propertyChainAxiom (fontem:awarded
   fontem:awardedTo)`. The contract count becomes a query-time
   `COUNT(?contract)`. The reasoner replaces
   `materialize_trade_edges`.

6. **`LobbyInterest` (40 nodes, single `name` property)** is a
   small controlled vocabulary, not a class with instances.
   **✅ Decision: model as SKOS concept scheme** (`skos:Concept`,
   `skos:prefLabel`).

7. **`CohesionProject.wikibase_qid` is a `linkedopendata.eu`
   Q-number** — the EU Knowledge Graph (EUKG), the EU's own
   Wikibase instance for cohesion data, separate from Wikidata.
   1.83M projects + 643K beneficiaries; ~10% cross-linked to
   Wikidata. Hosted at `https://query.linkedopendata.eu/sparql`,
   backed by qEndpoint.
   **✅ Decision: align with EUKG, don't mint our own
   `fontem:CohesionProject` class.**
   - Phase 0 / WS4: emit `<our-iri> owl:sameAs
     <http://linkedopendata.eu/entity/Q…>` for every cohesion
     project we already carry.
   - Phase 5 (read APIs): use `SERVICE
     <https://query.linkedopendata.eu/sparql>` for live federation
     when the API needs data we don't carry locally.
   - Phase 3 (Wikidata mirror): same cron pattern adds an EUKG
     mirror as a `<http://linkedopendata.eu/>` named graph in
     Virtuoso, dropping federation latency for hot paths.
   The `wikibase_qid` we already store is the bridge — no new ETL
   needed for Phase 2; alignment is mechanical at write time.

8. **24 multilingual columns per `Authority` and per `Contract`**
   (~2M extra label triples on port).
   **✅ Decision: emit our own per-language labels.** Bounded
   cost; Wikidata wouldn't cover most of these entities.

## Deltas from `neo4j-mapping.md`

The mapping doc in `ontology/neo4j-mapping.md` was a stub written
before this audit. Differences worth correcting in WS4:

- `LobbyInterest` was missing from the labels table — add as a
  SKOS concept scheme, not an OWL class.
- `RuleApplication` was missing — add to the audit-only table
  (PROV-O Activity).
- `ConsolidationRun` was missing — same, audit-only.
- `BeneficialOwner` and `Person` rows were drafted; **drop**
  per GDPR finding #1.
- `CohesionProject` should align with EUKG (linkedopendata.eu),
  not mint a `fontem:CohesionProject`. Use the existing
  `wikibase_qid` to emit `owl:sameAs <http://linkedopendata.eu/entity/Q…>`.
- `FinancialYear` should map to a reified `Filing` class, not a
  one-to-one port.
- `SUBSIDIARY_OF.type` discriminator — split into two predicates,
  not preserved as an edge attribute.

`neo4j-mapping.md` will be rewritten as part of WS4 once the
Wikidata alignment (WS3) lands.

## Ready for WS3

WS3 takes this audit and matches every class / property in it to
Wikidata terms (deep dive). Confidence-rated table; 5 worked
examples. The starting set is:

- 12 OWL classes to align (Person + BeneficialOwner dropped per
  GDPR; CohesionProject aligned with EUKG instead of Wikidata)
- ~80 datatype / object properties to align
- 2 SKOS concept schemes to align (CPV, LobbyInterest, NUTSRegion
  — 3 actually)
- The audit / meta labels (4 of them) align with PROV-O, not
  Wikidata
