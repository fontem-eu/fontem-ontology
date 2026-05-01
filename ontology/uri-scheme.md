# URI scheme

> **Status: draft.** Lock during Phase 0.

Pinning IRI conventions. Once written into the ontology and ETL
loaders, these are expensive to change — every triple in the graph
references them, every external system that links into Fontem (via
`owl:sameAs` or otherwise) does so by IRI. Decide carefully, decide
once.

## Base IRI

Proposed: `http://data.fontem.eu/`

`fontem.eu` is the live production hostname. Using it as the base
gives us a stable, externally-resolvable namespace — content
negotiation can return the entity's RDF representation to a SPARQL
client (`Accept: text/turtle`) and the human-readable HTML view to a
browser hitting the same URL (`Accept: text/html`). This is the
pattern Wikidata uses, and the one external linkers will expect.

## IRI patterns

```
http://data.fontem.eu/id/{ClassName}/{stable_id}    — entities
http://data.fontem.eu/ontology#{TermName}           — TBox terms
http://data.fontem.eu/graph/{name}                  — named graphs
http://data.fontem.eu/shape/{ClassName}             — SHACL shapes
```

Concrete examples:

| Kind | Example IRI |
|---|---|
| Authority entity | `http://data.fontem.eu/id/Authority/78d8b920-1a05-56f2-a84b-6a5e5afe8a59` |
| Company entity | `http://data.fontem.eu/id/Company/00040372-dad6-5d34-882c-8b8624b4e734` |
| Contract entity | `http://data.fontem.eu/id/Contract/2024-OJS-123-456789` |
| Class | `http://data.fontem.eu/ontology#Authority` |
| Property | `http://data.fontem.eu/ontology#hasContract` |
| Named graph (data) | `http://data.fontem.eu/graph/data` |
| Named graph (Wikidata mirror) | `http://wikidata.org/entity` (Wikidata's own IRI; we mirror under it) |
| SHACL shape | `http://data.fontem.eu/shape/Authority` |

## Prefix conventions

The standard prefix bindings in every Turtle file:

```turtle
@prefix fontem:   <http://data.fontem.eu/ontology#> .
@prefix fontem-id: <http://data.fontem.eu/id/> .
@prefix shape:    <http://data.fontem.eu/shape/> .

@prefix rdf:    <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
@prefix rdfs:   <http://www.w3.org/2000/01/rdf-schema#> .
@prefix owl:    <http://www.w3.org/2002/07/owl#> .
@prefix xsd:    <http://www.w3.org/2001/XMLSchema#> .
@prefix sh:     <http://www.w3.org/ns/shacl#> .
@prefix prov:   <http://www.w3.org/ns/prov#> .
@prefix skos:   <http://www.w3.org/2004/02/skos/core#> .
@prefix foaf:   <http://xmlns.com/foaf/0.1/> .
@prefix dcterms: <http://purl.org/dc/terms/> .

# Wikidata / DBpedia for federation
@prefix wd:     <http://www.wikidata.org/entity/> .
@prefix wdt:    <http://www.wikidata.org/prop/direct/> .
@prefix dbo:    <http://dbpedia.org/ontology/> .
@prefix dbr:    <http://dbpedia.org/resource/> .
```

These prefixes go in every `.ttl` file in `ontology/` and at the top
of every SPARQL query in the codebase.

## Stable ID strategy

Don't re-mint identifiers — keep the existing UUIDs. The current
Neo4j schema already uses UUID5 for `gmr_id`, `authority_id`,
`person_id`, etc. (deterministic from natural keys per the project's
conventions). The migration:

- `(:Authority {authority_id: "78d8…"})` →
  `<http://data.fontem.eu/id/Authority/78d8…>`

The mapping is mechanical. The ETL writers consume the source data,
mint the deterministic UUID5 the same way they do today, and emit
the IRI form.

External references (Fontem URLs in journalism articles, PR
attachments, OPP citations) remain stable through the migration
because the UUID half of the IRI doesn't change. We can publish a
content-negotiation rule on the IRI host that serves either the RDF
view (`Accept: text/turtle`) or the human-readable HTML view (`Accept:
text/html`) for the same URL, which is the pattern Wikidata uses.

## What about the ontology IRI vs ontology terms

`http://data.fontem.eu/ontology` (no fragment) is the IRI of the
ontology itself — used in `<...> a owl:Ontology` headers.
`http://data.fontem.eu/ontology#Authority` (with fragment) is the
IRI of a single class within that ontology.

Hash-namespace (`#term`) over slash-namespace (`/term`) for the
ontology because:

- Single-document fetch resolves the whole vocabulary in one HTTP
  request.
- Smaller VOID descriptor.
- Standard pattern in OWL ontologies (FOAF, DC, SKOS all use it).
