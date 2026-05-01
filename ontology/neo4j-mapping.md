# Neo4j → RDF mapping

> **Status: stub.** Will be expanded incrementally as ETLs are
> ported in Phase 4. This file is the contract between the existing
> Cypher-based loaders and the new Turtle-emitting writers — every
> Neo4j label and relationship type maps here.

The mapping below covers the labels / rel-types we know about today.
As Phase 4 progresses and we touch each loader, we'll extend this
file with property-by-property mappings (datatype hints,
multilingual handling, validation expectations).

## Node labels

| Neo4j label | RDF class | IRI pattern |
|---|---|---|
| `:Company` | `fontem:Company` | `fontem-id:Company/{gmr_id}` |
| `:Authority` | `fontem:Authority` | `fontem-id:Authority/{authority_id}` |
| `:Person` | `fontem:Person` | `fontem-id:Person/{person_id}` |
| `:Contract` | `fontem:Contract` | `fontem-id:Contract/{ted_notice_id}` |
| `:Listing` | `fontem:Listing` | `fontem-id:Listing/{ticker}.{exchange}` |
| `:Lobbyist` | `fontem:Lobbyist` | `fontem-id:Lobbyist/{tr_id}` |
| `:CPV` | `fontem:CPVCategory` | `fontem-id:CPV/{cpv_code}` |
| `:SanctionedEntity` | `fontem:SanctionedEntity` | `fontem-id:SanctionedEntity/{designation_id}` |
| `:NUTS` | `fontem:GeographicEntity` | `fontem-id:NUTS/{nuts_code}` |
| `:DataSource` | `fontem:DataSource` | `fontem-id:DataSource/{source_id}` (in `meta` graph) |
| `:MergeEvent` | `fontem:MergeEvent` | `fontem-id:MergeEvent/{uuid}` (in `meta` graph) |
| `:DecisionLog` | `fontem:DecisionLog` | `fontem-id:DecisionLog/{decision_id}` (in `meta` graph) |

## Relationships

| Neo4j rel | RDF property | Direction | Notes |
|---|---|---|---|
| `[:AWARDED]` | `fontem:awarded` | Authority → Contract | |
| `[:AWARDED_TO]` | `fontem:awardedTo` | Contract → Company | |
| `[:CATEGORIZED_AS]` | `fontem:hasCategory` | Contract → CPV | |
| `[:LISTED_AS]` | `fontem:listedAs` | Company → Listing | |
| `[:LOBBIES_FOR]` | `fontem:lobbiesFor` | Lobbyist → Company | |
| `[:SANCTIONED]` | `fontem:sanctionedBy` | Company → SanctionedEntity | |
| `[:CLIENT_OF]` | `fontem:client` | Authority → Company | **Derived** — property chain `(awarded ∘ awardedTo)`. Not stored. |
| `[:SUPPLIER_OF]` | `fontem:supplier` | Company → Authority | **Derived** — `owl:inverseOf fontem:client`. Not stored. |
| `[:SAME_AS]` (under review) | `fontem:proposedSameAs` | bidirectional | Review queue; reasoner ignores |
| `[:SAME_AS]` (approved) | `owl:sameAs` | bidirectional | Reasoner materialises equivalence |
| `[:REPORTED]` | (PROV-O in `meta` graph) | various | `prov:wasDerivedFrom` / `prov:wasGeneratedBy` |

## Edge attributes

Neo4j relationships can carry properties; RDF predicates cannot. Two
patterns to handle this:

### Pattern A: derive at query time (preferred)

For aggregate-style attributes like `[:CLIENT_OF {contracts: 4}]`,
**we don't store the count**. The count is computed at query time
off the underlying `:awarded` / `:awardedTo` edges:

```sparql
SELECT ?company (COUNT(?contract) AS ?contracts)
WHERE {
  fontem-id:Authority/{auth_id} fontem:awarded ?contract .
  ?contract fontem:awardedTo ?company .
}
GROUP BY ?company
```

### Pattern B: reify (when query-time aggregation is wrong)

Some edge attributes carry semantic information that can't be
derived (e.g. `[:SAME_AS {confidence: 0.95, detected_by: "fuzzy_name"}]`).
Reify the edge into a node:

```turtle
fontem-id:SameAsCandidate/foo a fontem:SameAsCandidate ;
    fontem:between fontem-id:Authority/A, fontem-id:Authority/B ;
    fontem:confidence "0.95"^^xsd:float ;
    fontem:detectedBy "fuzzy_name_same_country" ;
    fontem:detectedAt "2026-04-21T10:19:53Z"^^xsd:dateTime .
```

Use Pattern B only when the attribute is truly per-edge-instance and
not derivable. Most current attributes are aggregate (`contracts`,
`total_eur`, `last_loaded`) and become Pattern A.

## To expand

Per-loader mapping rows go here as Phase 4 progresses. Template:

```
## :Authority loader (load_authorities.py)

| Neo4j property | Type | RDF predicate | Datatype | Notes |
|---|---|---|---|---|
| name | string | rdfs:label | xsd:string @lang | Multilingual; `@lang` per source language |
| name_<lang> | string | rdfs:label | xsd:string @lang | Each variant becomes a separate triple |
| country | string | wdt:P17 | xsd:string | ISO 3166-1 alpha-3 |
| authority_id | string | (used as IRI suffix only) | - | Don't emit as triple |
| name_embedding | float[] | (out of band → pgvector) | - | Lives in Postgres sidecar |
```
