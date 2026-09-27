# FHIR-to-OMOP Ingestion & Cohort-Query MCP Server — Architecture

## 1. Purpose

A reproducible local demonstration that accepts FHIR-formatted clinical data,
maps it to OMOP standard concepts using OHDSI's Athena vocabularies, and
persists it into an OMOP Common Data Model (CDM) database. It exposes that
OMOP data through MCP (Model Context Protocol) tools — initially
natural-language clinical cohort-definition queries, with more MCP tools
expected to be added later.

## 2. Features (not the purpose — capabilities layered on top of it)

- **Two ingestion paths.** Alongside the FHIR path (the system's core
  purpose), a CSV-based path using ETL-Synthea demonstrates a second way to
  ingest the same generated population. The paths remain isolated and can be
  queried independently; automated comparison between them is not part of v1.
- **Synthetic data generation.** Synthea generates CSV and FHIR exports for
  the same synthetic population. Each run publishes one complete batch to
  both ingestion queues using the same batch identifier.
- **Append-only ingestion.** Re-running Synthea or submitting another FHIR
  batch appends new OMOP records. V1 does not detect duplicate source data;
  replaying the same source batch therefore creates additional records. The
  loaders must still allocate non-conflicting OMOP identifiers and preserve
  relationships within each loaded batch.
- **Locally demonstrated FHIR ingestion API**, gated by spec-level validation
  before a submission enters the queue.
- **Extensible MCP tool surface.** Cohort-definition queries are the first
  tools; more can be added later.

## 3. Non-goals (v1)

- No write-back to OMOP via MCP.
- No FHIR Subscriptions or real-time push — ingestion is sweep/schedule-based.
- No effect-estimation or safety-signal comparison (drug A vs. drug B
  outcomes) — roadmap only.
- No automated comparison or reconciliation between the CSV-derived and
  FHIR-derived OMOP data.
- No duplicate detection, idempotent replay, automatic retry, crash recovery,
  or exactly-once processing guarantees.
- No production deployment posture, high availability, or exposure of the
  FHIR receiver to untrusted external clients.
- No automated fetch from OHDSI's Athena vocabulary site — the export is
  selected and downloaded manually.

## 4. Components

| Container | Type | Role |
|---|---|---|
| `postgres` | Persistent | Hosts the single `fhir_omop_mcp_hub` database and all schemas |
| `athena_vocabs` | Batch, re-runnable | Loads a previously downloaded OHDSI Athena export into the `athena_vocabs` schema. A refresh drops and recreates the schema and is run as a maintenance operation while dependent ingestion and query services are stopped |
| `synthea` | Batch, re-runnable | Generates one synthetic population as CSV and FHIR, assigns a shared batch ID, and publishes complete batch directories to `csv_input/inbox/` and `fhir_input/inbox/` |
| `etl_synthea` | Scheduled batch | Claims complete batches from `csv_input/inbox/`, runs the OHDSI ETL-Synthea workflow, append-loads them into the `csv_input` schema using non-conflicting OMOP identifiers, and moves each batch to `success/` or `rejected/` |
| `fhir_to_cdm` | Scheduled batch | Claims complete batches from `fhir_input/inbox/`, runs OHDSI FhirToCdm to generate intermediate CDM files, loads those files into the `fhir_input` schema using non-conflicting OMOP identifiers, and moves each batch to `success/` or `rejected/` |
| `fhir_validator` | Persistent, internal-only | Performs stateless FHIR validation. It has no database or persisted state and is not directly exposed to clients. It may use HAPI FHIR validation support or the HL7 standalone FHIR Validator library |
| `fhir_receiver` | Persistent, local demonstration API | Accepts FHIR submissions, calls `fhir_validator`, and publishes each accepted submission as a complete batch under `fhir_input/inbox/`. A rejected submission is returned to the caller and is not queued |
| `ohdsi_webapi` | Persistent | Provides vocabulary search and cohort-definition, generation, and execution endpoints. Registers `csv_input` and `fhir_input` as separate sources and uses the shared `athena_vocabs` schema |
| `mcp_server` | Persistent | Python MCP server and the primary deliverable. It exposes separate translation and execution tools plus a high-level tool that chains them |

## 5. Data flow

**Vocabulary refresh (manual maintenance operation):**

Manually downloaded Athena export → `athena_vocabs` container → drop and
recreate the `athena_vocabs` schema

**Synthetic data publication:**

`synthea` → complete `<batch_id>/` directories in both
`csv_input/inbox/` and `fhir_input/inbox/`

**CSV branch:**

`csv_input/inbox/<batch_id>/` → `etl_synthea` claims the batch under
`pending/` → append to the `csv_input` schema → move the batch to `success/`
or `rejected/`

**FHIR branch — Synthea or locally submitted data:**

`fhir_input/inbox/<batch_id>/` → `fhir_to_cdm` claims the batch under
`pending/` → FhirToCdm writes intermediate files to
`pending/<batch_id>/generated_cdm/` → loader appends them to the `fhir_input`
schema → move the batch to `success/` or `rejected/`

**Local FHIR receiver:**

local caller → `fhir_receiver` → `fhir_validator`
→ (pass) publish a complete batch to `fhir_input/inbox/`
→ (fail) return the validation result and do not queue the submission

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
| `csv_input` | OMOP CDM populated by `etl_synthea` |
| `csv_results` | WebAPI/Achilles results for the CSV source |
| `csv_temp` | WebAPI temporary workspace for the CSV source |
| `fhir_input` | OMOP CDM populated by `fhir_to_cdm` |
| `fhir_results` | WebAPI/Achilles results for the FHIR source |
| `fhir_temp` | WebAPI temporary workspace for the FHIR source |
| `ohdsi_webapi` | WebAPI application metadata, including source registrations and cohort definitions |

WebAPI registers two sources:

| Source key | CDM | Vocabulary | Results | Temp |
|---|---|---|---|---|
| `OMOP_CSV` | `csv_input` | `athena_vocabs` | `csv_results` | `csv_temp` |
| `OMOP_FHIR` | `fhir_input` | `athena_vocabs` | `fhir_results` | `fhir_temp` |

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
same time; the MCP request selects `OMOP_CSV` or `OMOP_FHIR` rather than
reconfiguring or restarting WebAPI.

Credentials must not be committed. The exact local secret-injection mechanism
is left to implementation planning.

## 9. Storage and batch lifecycle

One host directory is bind-mounted into participating containers at `/data`:

```text
/data/
├── csv_input/
│   ├── inbox/<batch_id>/
│   ├── pending/<batch_id>/
│   ├── success/<batch_id>/
│   └── rejected/<batch_id>/
└── fhir_input/
    ├── inbox/<batch_id>/
    ├── pending/<batch_id>/
    │   └── generated_cdm/
    ├── success/<batch_id>/
    └── rejected/<batch_id>/
```

Each inbox entry is a complete batch directory, never an individual CSV file
from a multi-file export. Producers prepare a complete batch before publishing
it to `inbox/`. A consumer claims work by moving the whole directory to
`pending/`. Success or failure moves the whole directory to the corresponding
terminal directory. Rejected batches retain an error report alongside their
input and generated artifacts.

Synthea does not need a persistent directory of its own. It can generate into
temporary container storage and publish its completed CSV and FHIR batch
directories directly to the two inboxes.

## 10. V1 operating semantics

- The target is a reproducible local demonstration rather than a
  production-ready service.
- Ingestion is append-only. The loaders are responsible for primary-key
  uniqueness and valid foreign-key relationships across batches.
- V1 does not remember source identities for deduplication. Submitting the same
  clinical data twice creates additional OMOP records.
- Processing errors move a batch to `rejected/`; v1 does not retry it
  automatically.
- Recovery of abandoned `pending/` work after a crash is a future capability.
- Refreshing `athena_vocabs` drops and recreates the schema. Dependent services
  are stopped for the duration of the refresh in v1.
- External exposure, authentication, authorization, rate limiting, and
  production secret management are deferred.

## 11. Decisions made

- The FHIR-to-OMOP-to-MCP system is the purpose; Synthea and the CSV branch are
  supporting demonstration features.
- One PostgreSQL database, `fhir_omop_mcp_hub`, contains all schemas.
- The shared vocabulary schema is named `athena_vocabs`.
- The two OMOP CDM schemas are `csv_input` and `fhir_input`.
- One WebAPI instance registers both OMOP schemas as separate sources.
- Each source has its own results and temp schemas and shares
  `athena_vocabs`.
- One host data root is mounted at `/data` and contains both queue trees.
- Queue entries are complete batch directories with
  `inbox/pending/success/rejected` states.
- Synthea publishes directly to both inboxes and has no persistent directory.
- `fhir_to_cdm` is one container that performs conversion followed by database
  loading.
- New ingestion appends records and performs no duplicate-source detection.
- No automated CSV/FHIR comparison is required.
- MCP exposes translator, executor, and chained cohort-query tools.
- Exact FHIR compatibility is discovered and documented while implementing
  the FhirToCdm integration.

## 12. Left for implementation planning

- Verify which FHIR version, resource types, profiles, Bundle forms, and
  Synthea versions the selected FhirToCdm revision actually supports.
- Define how the FHIR loader assigns non-conflicting OMOP identifiers across
  appended batches while preserving all within-batch relationships.
- Verify ETL-Synthea's append behavior and define its cross-batch OMOP key
  allocation strategy.
- Select the scheduling mechanism and interval for the `etl_synthea` and
  `fhir_to_cdm` sweeps.
- Define Docker Compose services, networks, initialization jobs, startup order,
  and health checks.
- Generate and initialize the two WebAPI results schemas and source/daimon
  registrations.
- Choose between HAPI FHIR validation support and the HL7 standalone FHIR
  Validator library.
- Define batch naming, the minimal batch manifest, and error-report format.
- Define the supported cohort-expression subset, translator output schema,
  concept-resolution behavior, WebAPI execution lifecycle, and provenance
  returned by each MCP tool.
- Define the `etc/` layout and local secret-injection approach.
- Document future production work: deduplication, idempotency, retries, crash
  recovery, external authentication, authorization, observability, and
  deployment hardening.
