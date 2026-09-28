# ETL-Synthea 2.1.1 Provenance

## Pinned versions

- ETL-Synthea `2.1.1` (R package `ETLSyntheaBuilder`, DESCRIPTION `Version: 2.1`)
- Synthea `3.3.0` (generator; see `docker/synthea/PROVENANCE.md`)
- OMOP CDM `5.3.1` (clinical DDL; see `db/omop_csv/PROVENANCE.md`)
- Base image `rocker/r-ver:4.3.3`, linux/amd64
  `sha256:20ede1f846d2423b483b1019a499cc0f8c1d15192f47812c92d0900af4029039`
  (resolved 2026-09-28 via `docker buildx imagetools inspect`)
- PostgreSQL JDBC driver `42.7.4`
  `sha256:188976721ead8e8627eb6d8389d500dccc0c9bebd885268a3047180274a6031e`

## Canonical sources

| Artifact | URL | SHA-256 |
|---|---|---|
| ETL-Synthea | https://github.com/OHDSI/ETL-Synthea/archive/refs/tags/v2.1.1.tar.gz | `76c4104d2d89ce73e1cc4f0ac00c3937cd684e2f19cd871cdcee423853beb126` |
| JDBC driver | https://jdbc.postgresql.org/download/postgresql-42.7.4.jar | `188976721ead8e8627eb6d8389d500dccc0c9bebd885268a3047180274a6031e` |

Verify with:

```bash
curl -sL "https://github.com/OHDSI/ETL-Synthea/archive/refs/tags/v2.1.1.tar.gz" | sha256sum
curl -sL "https://jdbc.postgresql.org/download/postgresql-42.7.4.jar" | sha256sum
```

Both digests verified 2026-09-28; the Docker build fails without them.

## Verified invocation (Stop Rules record)

ETL-Synthea 2.1.1 has **no CLI** — it is the R package `ETLSyntheaBuilder`
(ex entry: `R/ETLSyntheaBuilder.R`, full call sequence in `README.md`).
`run_etl.R` calls the real exported functions with CDM `5.3` (the package's
name for CDM 5.3.1 DDL) and Synthea `3.3.0` (both in the package's supported
lists — anything else `stop()`s inside the package):

1. `CreateSyntheaTables(cd, syntheaSchema="omop_csv_temp", syntheaVersion="3.3.0")`
2. `LoadSyntheaTables(cd, syntheaSchema="omop_csv_temp", syntheaFileLoc=<assembled csv>)`
3. `CreateMapAndRollupTables(cd, cdmSchema="omop_csv", syntheaSchema="omop_csv_temp", cdmVersion="5.3", syntheaVersion="3.3.0")`
4. `LoadEventTables(cd, cdmSchema="omop_csv", syntheaSchema="omop_csv_temp", cdmVersion="5.3", syntheaVersion="3.3.0")`
5. `DropSyntheaTables(cd, syntheaSchema="omop_csv_temp")`

Deliberately **not** called:

- `CreateCDMTables` — clinical DDL is owned by `db/omop_csv/clinical_tables.sql`
  (applied by `run.sh` before the ETL); the package would rebuild/constraint
  tables it does not own.
- `LoadVocabFromCsv` / `LoadVocabFromSchema` — vocabulary already lives in
  `athena_vocabs` and is projected as same-named `omop_csv` views; the map and
  event loaders read `CONCEPT`/`CONCEPT_RELATIONSHIP` through `cdmSchema`, so
  the views satisfy them with no copy. Copying into `omop_csv` would collide
  with the views.

No flags were invented: every argument above matches the roxygen `@param`
docs in `R/LoadSyntheaTables.r`, `R/CreateMapAndRollupTables.r`,
`R/LoadEventTables.r`, `R/CreateSyntheaTables.r`, `R/DropSyntheaTables.r`.

## Credentials

`run_etl.R` connects as `etl_loader` with the password read from
`/run/secrets/etl_password` inside R — never from inherited `PGUSER` /
`PGPASSWORD` (run.sh unsets both before `Rscript`). Host/port/database come
from `PGHOST` / `PGPORT` / `PGDATABASE`.
