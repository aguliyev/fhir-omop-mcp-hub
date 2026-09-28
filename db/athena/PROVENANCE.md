# Athena Vocabulary DDL Provenance (OMOP CDM v5.3.1)

Upstream: [OHDSI CommonDataModel](https://github.com/OHDSI/CommonDataModel), tag `v5.3.1`.

## Canonical sources

| Artifact | URL | SHA-256 |
|---|---|---|
| DDL | https://raw.githubusercontent.com/OHDSI/CommonDataModel/v5.3.1/PostgreSQL/OMOP%20CDM%20postgresql%20ddl.txt | `1c3dfa742aac50dd0fe3c2fa3ec990678c734bb1803671fb32982ffb949d63ad` |
| Vocabulary loader | https://raw.githubusercontent.com/OHDSI/CommonDataModel/v5.3.1/PostgreSQL/VocabImport/OMOP%20CDM%20vocabulary%20load%20-%20PostgreSQL.sql | `bc884998569e01f8ec8a411a5494f88d84860343d51c41765384f2361bd73697` |
| Indexes | https://raw.githubusercontent.com/OHDSI/CommonDataModel/v5.3.1/PostgreSQL/OMOP%20CDM%20postgresql%20indexes.txt | `e84d867eade16365c5425cebee8717137d7418abc7cf777d54292143d323651b` |

Verify with:

```bash
curl -sL "https://raw.githubusercontent.com/OHDSI/CommonDataModel/v5.3.1/PostgreSQL/OMOP%20CDM%20postgresql%20ddl.txt" | sha256sum
curl -sL "https://raw.githubusercontent.com/OHDSI/CommonDataModel/v5.3.1/PostgreSQL/VocabImport/OMOP%20CDM%20vocabulary%20load%20-%20PostgreSQL.sql" | sha256sum
curl -sL "https://raw.githubusercontent.com/OHDSI/CommonDataModel/v5.3.1/PostgreSQL/OMOP%20CDM%20postgresql%20indexes.txt" | sha256sum
```

All three digests verified 2026-09-27; they match the checksums pinned in
`docs/superpowers/plans/2026-09-27-local-setup-and-athena-bootstrap.md`.

## What is retained

`db/athena/` keeps **only the vocabulary surface** (10 relations):

`concept`, `vocabulary`, `domain`, `concept_class`, `concept_relationship`,
`relationship`, `concept_synonym`, `concept_ancestor`,
`source_to_concept_map`, `drug_strength`.

- `create_tables.sql`: column names, types, and nullability copied verbatim
  from the DDL file's "Standardized vocabulary" section. Every statement is
  qualified with `athena_vocabs`; nothing depends on `search_path`.
- `create_indexes.sql`: the nine vocabulary primary-key constraints and the
  vocabulary lookup indexes copied from the indexes file's vocabulary
  sections, schema-qualified the same way.
- Grants (in `load.sh`, inside the load transaction): `REVOKE ALL ON SCHEMA
  athena_vocabs FROM PUBLIC`, `USAGE` + `SELECT` to `vocab_reader` on the
  vocabulary schema/tables, and `USAGE` on `omop_csv` plus `SELECT` on the
  ten views to `vocab_reader` and `PUBLIC` (schema `USAGE` is required in
  addition to table `SELECT`, otherwise the views are not readable).

Clinical, health-system, health-economics, and derived tables, keys, and
indexes from the upstream files are intentionally omitted: the vocabulary
job must not create them.

## Local adaptations (semantics unchanged)

1. **Windows `COPY` → container-side `\copy`.** The upstream vocabulary
   loader uses server-side `COPY ... FROM 'C:\CDMV5VOCAB\*.csv'`. `load.sh`
   instead runs psql `\copy <table> FROM '/data/athena_input/current/*.csv'
   WITH (FORMAT csv, HEADER true, DELIMITER E'\t', QUOTE E'\b')` so the
   tab-delimited Athena export is read client-side from the mounted data
   root with the exact upstream delimiter/quote settings.
2. **`source_to_concept_map` stays empty.** A standard Athena download
   supplies nine CSVs and no `SOURCE_TO_CONCEPT_MAP.csv`; the table is
   site-maintained. The loader creates it and loads nothing into it, and
   `validate.sql` requires it to exist **empty**. (The 2014-era loader
   header notes the same table as deprecated/unshipped.)
3. **`CLUSTER` statements removed.** The upstream indexes file issues
   `CLUSTER <table> USING <index>` after several indexes. `CLUSTER`
   cannot execute inside a transaction block, and the loader must run as
   one transaction so any failure rolls back and preserves the prior
   schema/views. Clustering is a physical-ordering optimisation only, so
   the statements are dropped without changing constraints or query
   semantics.
4. **Index typo kept verbatim.** Upstream names the vocabulary lookup
   index `idx_concept_vocabluary_id` (misspelled "vocabluary").
   `create_indexes.sql` and `validate.sql` keep that exact name so the
   constraint/index surface matches upstream byte-for-byte in meaning.
   No correction is applied; none is needed.
5. **Read-only views.** `create_views.sql` defines ten same-named
   `omop_csv` views as `SELECT * FROM athena_vocabs.<table>`. `load.sh`
   is the only writer and refuses any `VOCAB_VIEW_TARGET_SCHEMAS` value
   except the exact single identifier `omop_csv`; no views are ever
   created in `omop_fhir` (asserted by `validate.sql`).
6. **`vocabulary_version` is nullable.** Upstream declares it `NOT NULL`,
   but real Athena exports ship an empty `vocabulary_version` for
   OMOP-generated vocabularies (e.g. Cohort Type, Concept Class, UB04
   entries — 27 such rows in September 2026 exports), and `COPY ... CSV`
   maps the unquoted empty field to `NULL`, so a verbatim schema rejects
   real data (`null value in column "vocabulary_version" violates
   not-null constraint`). The column is relaxed to `NULL`; views
   (`SELECT *`) and `validate.sql` pass it through unchanged.

## Aggregate checksum convention

`bin/stage-athena` writes `manifest.sha256` lines as `"<sha256> <bytes>
<basename>"` sorted by basename. The staged aggregate checksum is the SHA-256
of the sorted per-file hashes (field 1), so filenames and byte counts do
not enter the aggregate itself:

```bash
awk '{print $1}' manifest.sha256 | LC_ALL=C sort | sha256sum | awk '{print $1}'
```

This matches Task 5 (`bin/setup`). Per-file bytes and names are still
verified field-by-field: `sha256sum -c` cannot be used because it misparses
the byte-count field as part of the filename, so `bin/load-vocab` and
`db/athena/load.sh` each carry a small `verify_staged_manifest` check (exact
nine files, no duplicates/extras, safe basenames, matching byte count and
hash). The two copies are kept in sync textually; they cannot share code
across the host/container boundary.

`load.sh` records it as `COMMENT ON SCHEMA athena_vocabs`
(`athena_staged_checksum=<hex>`) inside the same transaction so `bin/setup`
(Task 5) can compare staged vs. live without touching vocabulary rows.
