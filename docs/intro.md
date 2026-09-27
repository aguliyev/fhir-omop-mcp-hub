# FHIR-to-OMOP Ingestion & Cohort-Query MCP Server — Architecture

## 1. Purpose

A reproducible local demonstration that transforms a fixed FHIR-formatted
clinical-data snapshot into an OMOP Common Data Model (CDM), using OHDSI's
Athena vocabularies, and exposes the resulting OMOP data through MCP (Model
Context Protocol) tools. The initial MCP capability is natural-language
clinical cohort-definition queries; more tools may be added later.

## 2. Features (not the purpose — capabilities layered on top of it)

- **Two setup paths.** Alongside the FHIR path (the system's core
  purpose), a CSV-based path using ETL-Synthea demonstrates a second way to
  ingest the same generated population. The paths remain isolated and can be
  queried independently; automated comparison between them is not part of v1.
- **Synthetic data generation.** Synthea generates matching CSV and FHIR
  exports for each synthetic-population batch. It may run more than once;
  every run uses a unique recorded seed and publishes to both paths with the
  same batch identifier. Successful batches are immutable accepted source
  data. A later source refresh combines all previously accepted batches with
  the newly selected batches and treats their union as one complete input
  snapshot.
- **Snapshot rebuilds.** ETL-Synthea and OHDSI FhirToCdm are treated as
  initial-load tools. Re-running either path replaces that path's clinical
  OMOP data from a complete source snapshot; it does not append a delta. The
  converter is invoked once for the entire selected batch set, not once per
  batch.
- **Extensible MCP tool surface.** Cohort-definition queries are the first
  tools; more can be added later.

## 3. Non-goals (v1)

- No write-back to OMOP via MCP.
- No FHIR Subscriptions, streaming ingestion, or real-time push.
- No effect-estimation or safety-signal comparison (drug A vs. drug B
  outcomes) — roadmap only.
- No automated comparison or reconciliation between the CSV-derived and
  FHIR-derived OMOP data.
- No ongoing, incremental, or real-time FHIR ingestion. Supporting additional
  FHIR data without a full snapshot rebuild requires a future loader with
  persistent source-identity mapping and database-backed OMOP key allocation.
- No local FHIR submission API in v1.
- No duplicate detection, idempotent replay, automatic retry, crash recovery,
  or exactly-once processing guarantees for future incremental ingestion.
- No production deployment posture, high availability, or externally exposed
  ingestion endpoint.
- No automated fetch from OHDSI's Athena vocabulary site — the export is
  selected and downloaded manually.

## 4. Components

| Container | Type | Role |
|---|---|---|
| `postgres` | Persistent | Hosts the single `fhir_omop_mcp_hub` database and all schemas |
| `db_init` | Setup/re-runnable batch | Applies versioned database DDL and grants, initializes source-specific schemas, and idempotently registers WebAPI sources and daimons from repository configuration. No manual database setup is required |
| `athena_vocabs` | Batch, re-runnable | Loads a previously downloaded OHDSI Athena export into the `athena_vocabs` schema, then creates or recreates read-only compatibility views in configured target schemas. A refresh is a maintenance operation run while dependent ingestion and query services are stopped |
| `synthea` | Batch, re-runnable | Generates matching CSV and FHIR outputs, assigns a shared batch ID and unique recorded seed, and publishes complete batch directories to `csv_input/inbox/` and `fhir_input/inbox/` |
| `etl_synthea` | Setup/full-refresh batch | Claims one or more new CSV batches, combines them with all accepted CSV batches under `success/`, assembles the union as a complete snapshot, empties the CSV-derived physical clinical and helper tables in `omop_csv`, runs OHDSI ETL-Synthea once against the snapshot and vocabulary compatibility views, and accepts or rejects the new batches as one refresh set |
| `fhir_to_cdm` | Setup/full-refresh batch | Claims one or more new FHIR batches, combines them with all accepted FHIR batches under `success/`, assembles the union as a complete snapshot, runs OHDSI FhirToCdm once to generate intermediate CDM files, replaces the physical clinical-table data in `omop_fhir`, and accepts or rejects the new batches as one refresh set |
| `ohdsi_webapi` | Persistent | Provides vocabulary search and cohort-definition, generation, and execution endpoints. Registers `omop_csv` and `omop_fhir` as separate sources, gives each source separate results and temp schemas, and uses the shared `athena_vocabs` schema |
| `mcp_server` | Persistent | Python MCP server and the primary deliverable. It exposes separate translation and execution tools plus a high-level tool that chains them |

## 5. Data flow

**Vocabulary refresh (manual maintenance operation):**

Manually downloaded Athena export → `athena_vocabs` container → drop and
recreate the `athena_vocabs` schema → validate the loaded vocabulary → create
or recreate compatibility views in every configured target schema

**Synthetic data publication:**

`synthea` → complete `<batch_id>/` directories in both
`csv_input/inbox/` and `fhir_input/inbox/`

Synthea may run repeatedly. Each run uses a unique recorded random seed; using
the same seed and configuration would reproduce the same generated population.
Each source refresh selects one or more matching new batch IDs, combines them
with every previously accepted batch for that source, and treats their union
as its complete input snapshot.

**CSV branch:**

selected `csv_input/inbox/<batch_id>/` directories → `etl_synthea` claims
the new batches under `pending/` → assemble all `success/` batches plus the
new `pending/` refresh set into one work directory → truncate or recreate
the physical CSV-derived clinical and helper tables in `omop_csv` → run
ETL-Synthea once over the complete snapshot → move every new batch in the
refresh set to `success/` or `rejected/`

**FHIR branch:**

selected `fhir_input/inbox/<batch_id>/` directories → `fhir_to_cdm` claims
the new batches under `pending/` → assemble all `success/` batches plus the
new `pending/` refresh set into one work directory → FhirToCdm runs once
over the complete snapshot and writes intermediate files under the work
directory → truncate or recreate the physical clinical tables in
`omop_fhir` and load the generated snapshot → move every new batch in the
refresh set to `success/` or `rejected/`

**Query path:**

User question + selected `source_key` → MCP high-level cohort query tool →
translator → `ohdsi_webapi` vocabulary search → cohort-definition JSON →
executor → `ohdsi_webapi` cohort generation/execution → plain-language result

## 6. PostgreSQL layout

One PostgreSQL database, named `fhir_omop_mcp_hub`, contains every schema.
This lets each WebAPI source use one JDBC database connection while assigning
different schemas to its CDM, vocabulary, results, and temporary daimons.

| Schema | Role |
|---|---|
| `athena_vocabs` | Shared OMOP vocabulary tables used by both sources |
| `omop_csv` | OMOP CDM populated by `etl_synthea`; its standard vocabulary relations are read-only views into `athena_vocabs` |
| `omop_csv_results` | WebAPI/Achilles results for the CSV source |
| `omop_csv_temp` | WebAPI temporary workspace for the CSV source |
| `omop_fhir` | OMOP CDM populated by `fhir_to_cdm` |
| `omop_fhir_results` | WebAPI/Achilles results for the FHIR source |
| `omop_fhir_temp` | WebAPI temporary workspace for the FHIR source |
| `ohdsi_webapi` | WebAPI application metadata, including source registrations and cohort definitions |

WebAPI registers two sources:

| Source key | CDM | Vocabulary | Results | Temp |
|---|---|---|---|---|
| `omop_csv` | `omop_csv` | `athena_vocabs` | `omop_csv_results` | `omop_csv_temp` |
| `omop_fhir` | `omop_fhir` | `athena_vocabs` | `omop_fhir_results` | `omop_fhir_temp` |

The two sources do not share results or temp schemas. Results contain writable
cohort membership, inclusion statistics, Achilles characterization output,
and WebAPI caches whose identifiers are meaningful only for one CDM source.
After a clinical refresh, an old `person_id` may identify a different synthetic
person, so retaining old results could produce silently incorrect results in
addition to possible key conflicts. The refreshed source's results schema is
therefore dropped and recreated using the WebAPI-generated results DDL. Cohort
definitions and source/daimon registrations remain in `ohdsi_webapi`, but
cohort executions and any Achilles characterization must be run again.

Temp schemas allow WebAPI to create and drop arbitrary intermediate objects;
sharing one would risk name collisions between source jobs. With WebAPI jobs
for the source stopped, the refreshed source's temp schema is dropped and
recreated. The other source's results and temp schemas are not touched.

## 7. MCP server — tools (v1, extensible)

1. **Translator** — extracts supported structured intent from natural
   language, calls WebAPI vocabulary search to resolve OMOP concept IDs, and
   returns inspectable cohort-definition JSON. It does not execute the cohort.
2. **Executor** — accepts cohort-definition JSON and a `source_key`, invokes
   the required WebAPI cohort lifecycle, and returns structured results.
3. **Cohort query** — convenient high-level tool that accepts a natural-
   language question and `source_key`, then chains the translator and executor
   and returns a plain-language summary together with relevant structured
   provenance.

The separate tools support inspection and advanced composition; the high-level
tool gives MCP clients a simple default path.

## 8. Configuration

Environment variable files live under `etc/`, one per service, with no
hardcoded connection strings. All database-backed services connect to the
`fhir_omop_mcp_hub` database. WebAPI contains both source registrations at the
same time; the MCP request selects `omop_csv` or `omop_fhir` rather than
reconfiguring or restarting WebAPI.

The repository is the source of truth for setup. Declarative configuration,
non-secret environment defaults, and WebAPI source definitions live under
`etc/`. Versioned database DDL, generated WebAPI results DDL, grants, and seed
statements live under `db/`. The `db_init` container applies them as part of
`bin/setup`; developers do not configure PostgreSQL manually. Actual secrets
are supplied through uncommitted local environment files or Docker secrets.

The initial compatibility baseline is Synthea 3.3.0, ETL-Synthea 2.1.1, and
OMOP CDM 5.3.1. The exact unmodified OHDSI FhirToCdm commit, supported FHIR
format, runtime image, WebAPI version, PostgreSQL image digest, and platform
constraints are pinned after the pre-development feasibility spike succeeds.

The `athena_vocabs` service has an allow-listed configuration setting such as
`VOCAB_VIEW_TARGET_SCHEMAS=omop_csv`. After successfully loading the physical
Athena tables, it creates same-named compatibility views in every configured
target schema for these ten relations:

```text
concept
concept_ancestor
concept_class
concept_relationship
concept_synonym
domain
drug_strength
relationship
source_to_concept_map
vocabulary
```

A standard Athena download supplies nine CSV files. It does not supply
`SOURCE_TO_CONCEPT_MAP.csv`; `source_to_concept_map` is a site-maintained OMOP
table. Setup creates that tenth physical table empty so software expecting the
complete OMOP vocabulary-table surface can query it. Future local mappings may
populate it through a separate controlled process.

The target schemas exist before the vocabulary job runs, and their CDM
initialization does not create physical tables with these names. The
`etl_synthea` workflow skips `LoadVocabFromSchema`; its database role can read
the views but cannot modify `athena_vocabs`. `omop_fhir` is not a configured
view target because OHDSI FhirToCdm accepts the vocabulary connection and
schema separately. A clinical refresh preserves both OMOP schemas. It therefore
does not recreate the `omop_csv` vocabulary views, and `omop_fhir` has no such
views to recreate. The views are recreated only when `athena_vocabs` itself is
refreshed or their definitions change.

Credentials must not be committed. The exact local secret-injection mechanism
is left to implementation planning.

All operator actions are exposed as executable scripts under `bin/`. At
minimum, the repository provides `setup`, `start`, `stop`, `restart`, `status`,
`logs`, `generate`, `load-vocab`, `refresh-csv`, `refresh-fhir`, `refresh-all`,
`validate`, and `reset`. These scripts are thin Docker Compose wrappers;
pipeline behavior remains inside the relevant container. Destructive commands
such as `reset` require explicit confirmation.

For development, PostgreSQL, WebAPI, and the MCP server publish configurable
host ports bound to `127.0.0.1` by default. They are reachable from local
development tools but are not exposed on every network interface. Internal
container-to-container traffic uses the Compose network and container ports.

## 9. Storage and batch lifecycle

One host directory is bind-mounted into participating containers at `/data`:

```text
/data/
├── postgres/
├── athena_input/
├── work/<refresh_id>/
│   ├── manifest.json
│   ├── csv/
│   ├── fhir/
│   └── generated_cdm/
├── csv_input/
│   ├── inbox/<batch_id>/
│   ├── pending/<batch_id>/
│   ├── success/<batch_id>/
│   └── rejected/<batch_id>/
└── fhir_input/
    ├── inbox/<batch_id>/
    ├── pending/<batch_id>/
    ├── success/<batch_id>/
    └── rejected/<batch_id>/
```

Each inbox entry is a complete Synthea generation batch directory, never an
individual CSV file from a multi-file export. Producers prepare the whole
batch and publish it by an atomic directory rename. A refresh selects one or
more matching new batch IDs and claims them by moving each whole directory to
`pending/`. The work directory contains a refresh manifest and an assembled
snapshot made from all immutable batches already under `success/` plus the new
`pending/` refresh set. CSV assembly writes one header per merged table and
deduplicates shared reference entities; FHIR assembly flattens Bundle files
under collision-free names because FhirToCdm does not recurse into batch
subdirectories.

The converter is invoked once over the assembled snapshot. On success, every
new batch in the refresh set moves to `success/` and becomes part of future
cumulative rebuilds. On failure, those new batches move to `rejected/`, while
previously successful batches remain accepted. Rejected batches retain an
error report alongside their input and generated artifacts.

Synthea does not need a persistent directory of its own. It can generate into
temporary container storage and publish its completed CSV and FHIR batch
directories directly to the two inboxes.

## 10. V1 operating semantics

- The target is a reproducible local demonstration rather than a
  production-ready service.
- A complete input snapshot may contain one or more Synthea generation batches.
  Each batch has a unique recorded seed. Every refresh combines all accepted
  batches with its newly pending refresh set and passes the assembled snapshot
  to the converter in one invocation.
- Each source is loaded from one complete snapshot during setup. A later
  refresh replaces that source's clinical data from another complete snapshot.
- A clinical refresh preserves the `omop_csv` or `omop_fhir` schema itself and
  truncates or recreates only that schema's physical clinical and helper tables.
  Stable table definitions favor `TRUNCATE ... RESTART IDENTITY CASCADE`;
  individual tables are recreated when their DDL changes.
- The `omop_csv` cleanup explicitly excludes its vocabulary views, so they
  remain usable without recreation. `omop_fhir` has no vocabulary views.
- A source refresh drops and recreates that source's results schema using the
  WebAPI-generated results DDL, and drops and recreates its disposable temp
  schema. It leaves `ohdsi_webapi`, `athena_vocabs`, and the other source's
  schemas untouched. WebAPI jobs for the source are stopped during this
  operation.
- V1 performs an in-place maintenance refresh. MCP and WebAPI are stopped
  before clinical tables are cleared and restart only after loading and
  validation succeed. A failed refresh may leave empty or partial physical
  tables, but they are never exposed to query clients; the operator reruns the
  complete refresh. Atomic shadow-schema cutover is deferred.
- ETL-Synthea's `row_number()` identifiers and OHDSI FhirToCdm's process-local
  identifiers are acceptable only because their destination clinical tables
  are rebuilt rather than appended.
- Processing errors move a batch to `rejected/`; v1 does not retry it
  automatically.
- Recovery of abandoned `pending/` work after a crash is a future capability.
- Refreshing `athena_vocabs` drops and recreates the schema. Dependent services
  are stopped for the duration of the refresh, and the vocabulary job
  recreates all configured compatibility views before dependent services
  restart.
- External exposure, authentication, authorization, rate limiting, and
  production secret management are deferred.

## 11. Decisions made

- The FHIR-to-OMOP-to-MCP system is the purpose; Synthea and the CSV branch are
  supporting demonstration features.
- One PostgreSQL database, `fhir_omop_mcp_hub`, contains all schemas.
- The shared vocabulary schema is named `athena_vocabs`.
- The two OMOP CDM schemas are `omop_csv` and `omop_fhir`.
- One WebAPI instance registers both OMOP schemas as separate sources.
- Each source has its own results and temp schemas and shares
  `athena_vocabs`.
- One host data root is mounted at `/data` and contains both queue trees.
- Queue entries are complete batch directories with
  `inbox/pending/success/rejected` states.
- Synthea publishes directly to both inboxes and has no persistent directory.
- Synthea may publish multiple batches. Each uses a unique recorded seed, and
  a refresh processes all previously accepted batches plus one or more newly
  selected batches as a single complete snapshot.
- `fhir_to_cdm` is one setup/full-refresh container that performs conversion
  followed by database loading.
- Both data paths empty their source-specific physical clinical OMOP tables and
  load a complete snapshot without dropping the enclosing OMOP schema; ongoing
  append ingestion is deferred.
- The `athena_vocabs` job creates and recreates configured compatibility views;
  initially only `omop_csv` is a view target.
- Clinical refreshes retain the `omop_csv` vocabulary views. `omop_fhir` uses
  `athena_vocabs` directly and has no local vocabulary views.
- A clinical refresh drops and recreates only the refreshed source's results
  and temp schemas; WebAPI metadata, source/daimon registrations, and cohort
  definitions remain in `ohdsi_webapi`.
- Repository configuration under `etc/` and versioned database assets under
  `db/` drive an idempotent `db_init` setup job; PostgreSQL requires no manual
  configuration.
- Executable scripts under `bin/` provide every setup, lifecycle, generation,
  refresh, validation, and reset operation.
- PostgreSQL, WebAPI, and MCP publish configurable development ports on
  `127.0.0.1` by default.
- The compatibility baseline is Synthea 3.3.0, ETL-Synthea 2.1.1, and OMOP
  CDM 5.3.1. The feasibility spike pins the remaining compatible versions.
- WebAPI source keys are lowercase snake case: `omop_csv` and `omop_fhir`.
- No automated CSV/FHIR comparison is required.
- MCP exposes translator, executor, and chained cohort-query tools.
- Exact FHIR compatibility is discovered and documented while implementing
  the FhirToCdm integration.

## 12. Left for implementation planning

- Implement and run the local setup and Athena bootstrap documented in
  `docs/superpowers/plans/2026-09-27-local-setup-and-athena-bootstrap.md`.
  Its `bin/validate-setup` command must report `READY` before the converter
  spike begins.
- Execute the pre-development FhirToCdm container feasibility spike documented
  in `docs/superpowers/plans/2026-09-27-fhir-to-cdm-container-feasibility-spike.md`.
- After the spike, record the verified FhirToCdm commit, FHIR format, runtime
  image, supported resource subset, loader contract, and platform constraints.
- Define the exact setup/full-refresh command sequence and failure reporting
  for the agreed in-place maintenance refresh.
- Define how each source refresh atomically selects and claims new batch IDs,
  assembles its accepted-plus-pending snapshot, and records that selection in
  a refresh manifest. `refresh-all` may coordinate matching Synthea batch IDs,
  but the CSV and FHIR sources remain independently refreshable.
- Define Docker Compose services, networks, initialization jobs, startup order,
  and health checks.
- Generate and initialize the two WebAPI results schemas and source/daimon
  registrations.
- Define the Athena vocabulary-view publisher configuration, identifier
  allow-list validation, grants, and post-refresh checks.
- Define batch naming, the minimal batch manifest, and error-report format.
- Define the supported cohort-expression subset, translator output schema,
  concept-resolution behavior, WebAPI execution lifecycle, and provenance
  returned by each MCP tool.
- Define the `etc/` layout and local secret-injection approach.
- Document future production work: ongoing FHIR ingestion, persistent source
  identity and OMOP key mapping, deduplication, idempotency, retries, crash
  recovery, an authenticated receiver API, observability, and deployment
  hardening.
