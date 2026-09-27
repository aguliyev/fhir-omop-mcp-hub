# FHIR-to-OMOP Ingestion & Cohort-Query MCP Server — Architecture

## 1. Purpose

A system that accepts FHIR-formatted clinical data, maps it to OMOP standard
concepts using OHDSI's Athena vocabularies, and persists it into an OMOP
Common Data Model (CDM) database. Exposes that OMOP data through MCP (Model
Context Protocol) tools — initially natural-language clinical cohort-
definition queries, with more MCP tools expected to be added later as the
system grows.

## 2. Features (not the purpose — capabilities layered on top of it)

- **Dual ingestion paths for comparison.** Alongside the FHIR path (the
  system's core purpose), a CSV-based path (via ETL-Synthea) runs against
  the same source data, so the two ingestion strategies can be evaluated
  side by side.
- **Synthetic data generation.** Synthea generates synthetic patients (no
  real PHI). This is a demo/testing feature, not the system's purpose — it
  lets the pipeline be exercised end-to-end without real clinical data.
  Synthea is re-runnable, not a single setup-time step: running it
  repeatedly adds new batches over time, which is how the scheduled
  ingestion sweeps' handling of incrementally arriving data gets
  exercised/demoed.
- **Live FHIR ingestion API**, gated by spec-level validation before
  anything enters the pipeline.
- **MCP tool surface, extensible.** Cohort-definition queries are the first
  tools; more are expected later.

## 3. Non-goals (v1)

- No write-back to OMOP via MCP.
- No FHIR Subscriptions / real-time push — ingestion is sweep/schedule-based.
- No effect-estimation or safety-signal comparison (drug A vs B outcomes) —
  roadmap only.
- No automated fetch from OHDSI's Athena vocabulary site — that requires a
  manual selection/download step on OHDSI's side (see `athena_vocabs`).

## 4. Components

| Container | Type | Role |
|---|---|---|
| `postgres` | Persistent | Single Postgres instance, hosts all schemas |
| `athena_vocabs` | Batch, re-runnable | Loads a previously-downloaded OHDSI Athena vocabulary export (SNOMED, RxNorm, LOINC, etc.) into the `vocab` schema. Run once at setup; re-run whenever a newer export bundle needs loading to refresh vocabularies. Does not fetch the export itself |
| `synthea` | Batch, re-runnable | Generates synthetic patients — CSV export + FHIR export together, same population per run. Invokable multiple times; each run adds a new batch, dropped into `csv_path/inbox/` and `fhir_path/inbox/` |
| `etl_synthea` | Scheduled batch | R tool (OHDSI). Sweeps `csv_path/inbox/`, loads each file (+ `vocab`) into `omop_csv`, moves files through `pending/` to `processed/` or `rejected/` |
| `fhirtocdm` | Scheduled batch | C# tool (OHDSI). Sweeps `fhir_path/inbox/`, converts and loads each file (+ `vocab`) into `omop_fhir`, moves files through `pending/` to `processed/` or `rejected/` |
| `fhir_validator` | Persistent, internal-only | Stateless FHIR spec validation — no database, nothing persisted. Implementable via HAPI FHIR's `$validate` operation or HL7's standalone FHIR Validator library (neither needs a full JPA server). Not reachable by external clients |
| `fhir_receiver` | Persistent, client-facing | Own REST API — the only FHIR ingestion surface exposed to clients. Accepts external/live FHIR submissions, calls `fhir_validator`; on success writes the file to `fhir_path/inbox/`, on failure returns the validator's REST error to the caller |
| `ohdsi_webapi` | Persistent | OHDSI WebAPI — vocabulary-search + cohort-definition/generation/execution endpoints. Reads exactly one OMOP schema at a time (`omop_csv` or `omop_fhir`, chosen via env var — not both simultaneously) plus `vocab`; writes its own `ohdsi_webapi` schema |
| `mcp_server` | Persistent | Python MCP server — the actual deliverable. Initial tools below; designed to grow over time |

## 5. Data flow

**Vocabulary load (setup, re-runnable):**
Manually-downloaded Athena export → `athena_vocabs` → `vocab` schema

**CSV branch:**
`synthea` → `csv_path/inbox/` → `etl_synthea` sweep (+ `vocab`) → `omop_csv`

**FHIR branch — demo/comparison data:**
`synthea` → `fhir_path/inbox/` → `fhirtocdm` sweep (+ `vocab`) → `omop_fhir`

**FHIR branch — live ingestion:**
external client → `fhir_receiver` → `fhir_validator`
→ (pass) `fhir_path/inbox/` → `fhirtocdm` sweep (+ `vocab`) → `omop_fhir`
→ (fail) REST error returned directly to the client, nothing written

**Query path:**
User question → `mcp_server` translator tool → `ohdsi_webapi` vocab-search
(concept ID resolution) → cohort-definition JSON → `mcp_server` executor
tool → `ohdsi_webapi` cohort generation/execution → results → plain-language
summary

## 6. Schemas (single Postgres instance)

| Schema | Populated by | Read by |
|---|---|---|
| `athena_vocabs` | `athena_vocabs` | `etl_synthea`, `fhirtocdm`, `ohdsi_webapi` |
| `omop_csv` | `etl_synthea` | `ohdsi_webapi` (when configured to this schema) |
| `omop_fhir` | `fhirtocdm` | `ohdsi_webapi` (when configured to this schema) |
| `ohdsi_webapi` | `ohdsi_webapi` service itself (cohort defs, generation status, results) | `ohdsi_webapi` service only |

## 7. MCP server — tools (v1, extensible)

1. **Executor** — wraps OHDSI WebAPI's cohort-definition/execution
   endpoints. Input: cohort-definition JSON. Output: cohort results JSON.
2. **Translator** — extracts structured intent (drug, condition, age,
   temporal relationship) from natural language via LLM, calls WebAPI's
   vocabulary-search endpoint to resolve OMOP concept IDs, assembles a
   cohort-definition JSON. Does not call execution itself.

An MCP client chains translator → executor to answer one natural-language
question. More tools beyond cohort queries are expected later — this pair
is the v1 baseline, not the ceiling.

## 8. Configuration

All environment variable files live under `etc/` (one per service, e.g.
`etc/postgres.env`, `etc/athena_vocabs.env`, `etc/ohdsi_webapi.env`). No
hardcoded connection strings anywhere. `ohdsi_webapi`'s target OMOP schema
(`omop_csv` vs `omop_fhir`) is one of these env vars — switching which
branch it queries is a config change, not a code change. Running two
`ohdsi_webapi` instances with different configs is how both branches would
be queried concurrently, if that's ever needed.

## 9. Storage / volumes

Bind-mounted host directories, shared as Docker volumes between
producer/consumer containers:

- `csv_path/{inbox,pending,rejected,processed}` — `synthea` writes to
  `inbox/`; `etl_synthea` sweeps and moves files through the stages
- `fhir_path/{inbox,pending,rejected,processed}` — `synthea` and
  `fhir_receiver` both write to `inbox/`; `fhirtocdm` sweeps and moves files
  through the stages

On the CSV side, rejection is driven by processing failure, not upfront
schema checking — a file that fails to load moves to `rejected/` with the
error logged. On the FHIR side, `fhir_validator` catches spec-invalid
submissions before they ever reach `inbox/`; anything that reaches `inbox/`
but still fails conversion also moves to `rejected/`.

## 10. Decisions made this session (not open)

- Purpose is the FHIR-accepting, Athena-mapped, OMOP-persisting,
  MCP-exposing system. Synthetic data (Synthea) and the CSV comparison
  branch are features layered on that purpose, not the purpose itself.
- Two separate OMOP schemas (`omop_csv`, `omop_fhir`) for isolated,
  comparable branch output.
- No FHIR Subscriptions — ingestion is sweep/schedule-based throughout.
- `fhirtocdm` and `etl_synthea` are scheduled sweepers over `inbox/`, not
  continuous daemons and not manual one-offs.
- `synthea` is re-runnable, not a single setup-time run — used to exercise
  how the scheduled sweeps handle incrementally arriving data.
- `athena_vocabs` is its own re-runnable batch container, loading a
  manually-downloaded export bundle; it does not auto-fetch from Athena.
- HAPI FHIR (or the standalone validator, e.g. HL7's standalone FHIR Validator library) is used purely as a stateless
  `$validate` gateway — no database, no persistence, not exposed to clients
  directly.
- `fhir_receiver` is the only client-facing FHIR ingestion surface; it owns
  the validate-then-write-or-reject logic.
- `ohdsi_webapi` targets exactly one OMOP schema at a time, chosen via env
  var.
- Lowercase snake_case naming across all containers/schemas.
- All env var files live under `etc/`.

## 11. Left for the implementation-planning agent

- Exact scheduling mechanism and interval for the `etl_synthea`/`fhirtocdm`
  sweeps (cron sidecar, external scheduler, orchestration tool).
- Docker Compose service definitions, network, and startup
  ordering/health checks.
- Whether `omop_csv`/`omop_fhir` need the OMOP `results` schema convention
  WebAPI typically expects, or whether the `ohdsi_webapi` schema covers it.
- Choice between the full HAPI FHIR JPA server (pointed at an
  in-memory/throwaway DB, since nothing is persisted through it) vs. HL7's
  standalone FHIR Validator library for `fhir_validator`.
- Auth/access control on `fhir_receiver`'s public endpoint.
- Concrete cohort-definition JSON schema and the translator's
  prompt/parsing design.
- Exact `etc/` file layout and secret-handling approach (e.g. whether
  Postgres credentials belong in `etc/` at all, vs. a secrets manager).