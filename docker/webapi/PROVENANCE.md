# WebAPI Provenance (pinned release)

- Release: OHDSI WebAPI **v2.15.2** (`master-2.15`, published 2026-06-24).
- WAR URL: https://github.com/OHDSI/WebAPI/releases/download/v2.15.2/WebAPI.war
- WAR SHA-256: `e544c181138c5e1eef09c36c9310ed78ba41d649f6be72e30eb2d67aace11b7d`
  (GitHub release-asset digest; re-verified by `docker/webapi/Dockerfile` via
  `sha256sum -c` at build time — build fails on mismatch).
- Inspected source: `git clone --depth 1 --branch v2.15.2
  https://github.com/OHDSI/WebAPI.git` (tag `v2.15.2`).
- Servlet namespace: **`javax.servlet`** (`javax.servlet:javax.servlet-api` in
  `pom.xml`; entities import `javax.persistence.*`). Tomcat 10 (jakarta) will
  NOT work. Runtime: `tomcat:9-jre17` (Java target 1.8 runs on JRE 17).
- Runtime image digest: pinned in `docker/webapi/Dockerfile` (`FROM` with
  digest; recorded here once pulled at build time).

## Metadata contracts (from `src/main/resources/db/migration/postgresql/`, tag v2.15.2)

- `ohdsi_webapi.source`: `source_id` (default `nextval(source_sequence)`,
  set by `V2.7.0.201902130900__source-sequences.sql`), `source_name`,
  `source_key VARCHAR(50)` with `UNIQUE (source_key)` (added by
  `V2.2.6.20180215152023__source_key_unique.sql`), `source_connection`
  (JDBC URL), `source_dialect`. `username`/`password` columns are nullable
  (`V2.4.0.20180508090000__source-credentials.sql`); credentials are embedded
  in the JDBC URL instead, which `DataSourceDTOParser` parses first and only
  falls back to the columns (`src/main/java/.../util/DataSourceDTOParser.java`).
  `is_cache_enabled` defaults false, `check_connection` defaults true,
  `krb_auth_method` defaults `'PASSWORD'` — plain 4-column INSERT is valid.
- `ohdsi_webapi.source_daimon`: `source_daimon_id` (default
  `nextval(source_daimon_sequence)`), `source_id`, `daimon_type` (**ORDINAL**
  of `SourceDaimon.DaimonType`: `CDM=0, Vocabulary=1, Results=2, CEM=3,
  CEMResults=4, Temp=5`; `@Enumerated(EnumType.ORDINAL)` in
  `src/main/java/.../source/SourceDaimon.java`), `table_qualifier` (used
  verbatim as the schema prefix), `priority` (`0` = active; soft-delete sets
  `-1` via `@SQLDelete`).
- `db/webapi/register_source.sql` upserts by the real `source_key` UNIQUE
  constraint and DELETEs+re-inserts the four daimons in one transaction, so
  repeats update the same source and never duplicate daimon rows.
- v1 source mapping (single source): `omop_csv` → CDM `omop_csv`,
  Vocabulary `athena_vocabs`, Results `omop_csv_results`, Temp `omop_csv_temp`.

## Results DDL (from `src/main/java/.../service/DDLService.java`, tag v2.15.2)

- Documented generator: `GET /WebAPI/ddl/results?dialect=postgresql`
  `&schema=<results>&vocabSchema=<vocab>&tempSchema=<temp>&initConceptHierarchy=true`.
  It renders `RESULT_DDL_FILE_PATHS` (28 files: cohort, cohort_cache,
  censor/inclusion/summary stats + caches, feas_study_*, heracles_*,
  cohort_sample_element, ir_*, cohort_characterizations, pathway_*)
  plus `init_heracles_analysis.sql`, `init_heracles_periods.sql`,
  `concept_hierarchy.sql`, `init_concept_hierarchy.sql`, and indexes from
  `create_index.sql` + `pathway_analysis_events_indexes.sql`, SqlRender +
  SqlTranslate `postgresql`.
- `db/webapi/results_ddl.sql` is the captured output of that endpoint
  (header comment records release, command, checksum), qualified with
  `omop_csv_results`, idempotent (`CREATE TABLE IF NOT EXISTS`).

## Endpoints for the MCP plan (class paths from tag v2.15.2; live-proved in Task 4)

- `GET /WebAPI/source/sources` → `[{sourceId, sourceName, sourceKey,
  sourceDialect, ...}]` (`SourceController @Path("/source/") + @Path("sources")`).
- `GET /WebAPI/vocabulary/{sourceKey}/search/{query}` → `[{conceptId,
  conceptName, standardConcept, standardConceptCaption, invalidReason,
  invalidReasonCaption, conceptCode, domainId, vocabularyId, ...}]`
  (`VocabularyService @Path("vocabulary/")`).
- `POST /WebAPI/vocabulary/{sourceKey}/search` with `{"QUERY": "..."}`
  (ConceptSearch) → same shape.
- `POST /WebAPI/cohortdefinition/` with Atlas/Circe cohort JSON → created
  definition (`CohortDefinitionService @Path("/cohortdefinition")`).
- `GET /WebAPI/cohortdefinition/{id}/generate/{sourceKey}` → job resource.
- `GET /WebAPI/cohortdefinition/{id}/info` → generation list with status
  and record counts (poll until `COMPLETE`).
- `GET /WebAPI/ddl/results?...` (above) — results-DDL generator.
