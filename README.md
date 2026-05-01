# fontem-ontology

The TBox (ontology), URI scheme, and migration plan for moving Fontem
off **Neo4j (labelled property graph)** onto **Virtuoso Open Source
(RDF / OWL)**.

This is a multi-phase, multi-week migration. The plan is living —
phases beyond 0 will be revised as earlier phases land.

## Why this repo exists

Fontem is a public-interest transparency platform pulling EU
procurement, lobbying, sanctions, ownership, and listing data into a
single knowledge graph. The current stack uses Neo4j Community as the
storage layer.

Two shortcomings have surfaced:

1. **No native reasoner.** Derived relationships like
   `(Authority)-[:CLIENT_OF]-(Company)` (chain `:AWARDED ∘ :AWARDED_TO`)
   are hand-materialised by an ETL job. When the underlying graph
   changes, the materialised summary drifts. We hit this in the eu-LISA
   incident — graph view showed 4 contracts, contracts list showed 0.
2. **No federation story.** Wikidata, OpenCorporates, EU Publications
   Office all publish SPARQL endpoints. Federating against them gives
   us biographical / structural data we don't have to maintain.
   Property graphs can simulate federation through HTTP-stitched joins
   in Python; an RDF stack gets it for free.

The right fix for both is a paradigm shift: RDF + OWL2-RL reasoner.
This repo holds the design and the plan.

## Repository layout

```
fontem-ontology/
├── README.md                    — you are here
├── MIGRATION.md                 — the migration plan (Phase 0 detailed; later phases sketched)
├── ontology/
│   ├── uri-scheme.md            — IRI conventions
│   ├── wikidata-alignment.md    — class/property alignment with Wikidata
│   ├── core.ttl                 — top-level classes (Agent, Organisation, Document)
│   ├── procurement.ttl          — Authority, Contract, Award (TED domain)
│   ├── corporate.ttl            — Company, Person, ownership, listings (GLEIF, EDGAR, ESEF)
│   ├── lobbying.ttl             — Lobbyist, lobby meetings
│   ├── sanctions.ttl            — sanctions vocabulary
│   └── meta.ttl                 — provenance, versioning, MergeEvent
└── shapes/
    └── *.shacl.ttl              — SHACL constraints (validated at write time by the ETL)
```

The Turtle files in `ontology/` are the *source of truth* for the
schema; everything else (SPARQL queries, ETL writers, SHACL
validation) refers back to them. They are populated during Phase 0
of the migration — see `MIGRATION.md`.

## Status

Phase 0 in flight. Nothing is loaded into Virtuoso yet.
Neo4j is still the production store; this repo is design-time work.
