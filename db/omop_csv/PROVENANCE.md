# omop_csv Clinical DDL Provenance (OMOP CDM v5.3.1)

Upstream: [OHDSI CommonDataModel](https://github.com/OHDSI/CommonDataModel), tag `v5.3.1`.

## Canonical source

| Artifact | URL | SHA-256 |
|---|---|---|
| DDL | https://raw.githubusercontent.com/OHDSI/CommonDataModel/v5.3.1/PostgreSQL/OMOP%20CDM%20postgresql%20ddl.txt | `1c3dfa742aac50dd0fe3c2fa3ec990678c734bb1803671fb32982ffb949d63ad` |

Verify with:

```bash
curl -sL "https://raw.githubusercontent.com/OHDSI/CommonDataModel/v5.3.1/PostgreSQL/OMOP%20CDM%20postgresql%20ddl.txt" | sha256sum
```

Digest verified 2026-09-28; matches the checksum pinned in `db/athena/PROVENANCE.md`.

## What is retained

`clinical_tables.sql` keeps **every `CREATE TABLE` from the DDL except the
ten vocabulary relations** (`concept`, `concept_ancestor`, `concept_class`,
`concept_relationship`, `concept_synonym`, `domain`, `drug_strength`,
`relationship`, `source_to_concept_map`, `vocabulary`): 29 tables, extracted
from the first occurrence of each block (the upstream file repeats sections).

## Local adaptations (semantics unchanged)

1. **Schema-qualified + idempotent.** `CREATE TABLE` → `CREATE TABLE IF NOT
   EXISTS omop_csv.<table>`; nothing depends on `search_path`.
2. **`DATETIME2` → `TIMESTAMP`.** The upstream "PostgreSQL" file leaves 19
   SQL Server `DATETIME2` columns; PostgreSQL rejects the type. All 19 map
   to `TIMESTAMP`, nullability unchanged.
3. **Upstream typo kept verbatim:** `cost.reveue_code_source_value`.
4. **No constraints/indexes.** The upstream DDL carries no inline PK/FK
   lines; constraints live in the separate indexes file and are intentionally
   omitted (truncate/rebuild owns the rows). `CREATE TABLE IF NOT EXISTS`
   does not evolve columns: if the pinned CDM/ETL DDL changes, stop and
   document a deliberate migration or table recreation.
5. **`measurement.value_source_value` widened to `VARCHAR(255)`.**
   ETL-Synthea 2.1.1 `insert_measurement.sql` maps raw Synthea observation
   `VALUE` text into this column without truncation (its sibling branch
   uses `left(o.value,50)`), while real Synthea 3.3.0 survey/SDOH answers
   reach 135 chars (e.g. homelessness-screening responses). Verbatim
   `VARCHAR(50)` aborts the whole refresh with `value too long`. Widening
   preserves generated values exactly; reads (WebAPI, MCP) are unaffected.
   The unconditional `ALTER COLUMN` after the `CREATE` migrates tables
   created before this adaptation and is a no-op afterwards.
