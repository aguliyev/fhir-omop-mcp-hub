# FhirToCdm Container Feasibility Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Determine whether unmodified upstream OHDSI FhirToCdm can run in a reproducible Linux container, consume pinned Synthea FHIR output, use PostgreSQL Athena vocabularies, emit loadable OMOP CDM 5.3 files, and preserve correct relationships across multiple generated batches.

**Architecture:** Build a disposable harness under `spikes/fhir_to_cdm/`. Generate two deterministic Synthea 3.3.0 batches in both candidate FHIR formats, assemble each format into a flat input directory, invoke one pinned FhirToCdm process per candidate, load successful V53 output into a scratch PostgreSQL schema, and validate structure and relationships. Do not modify, patch, retarget, or fork upstream FhirToCdm.

**Tech Stack:** Docker Compose, Linux/amd64, PostgreSQL 16, Synthea 3.3.0, OHDSI FhirToCdm commit `4991f90`, .NET Core 3.1, unixODBC/PostgreSQL ODBC, OMOP CDM 5.3.1, POSIX shell, SQL, and `psql`.

**Spec:** `docs/intro.md`

## Global Constraints

- First complete `docs/superpowers/plans/2026-09-27-local-setup-and-athena-bootstrap.md` and require `bin/validate-setup` to report `READY`. Use the validated `<data-root>/athena_input/current` directory as `ATHENA_FILES_DIR`.
- Keep every generated spike artifact, including scratch PostgreSQL state, below `<data-root>/work/fhir_to_cdm_spike/`; do not create generated state in the tracked repository tree.
- This is a pre-development feasibility spike. Everything under `spikes/fhir_to_cdm/` is non-production and disposable except the final report.
- Use Synthea tag `v3.3.0` and record the resolved full commit SHA and release-asset SHA-256 in the report.
- Use upstream OHDSI FhirToCdm commit `4991f90` and record the resolved full commit SHA in the report.
- Do not change any upstream FhirToCdm source file, project target, package reference, lookup file, or checked-in executable.
- A wrapper Dockerfile, entrypoint, loader, and validation queries are allowed; changes to converter behavior are not.
- Test `linux/amd64` and record emulation if the host is not amd64.
- Use OMOP output mode `V53` and test loading against OMOP CDM 5.3.1.
- Use an actual Athena vocabulary export containing its nine standard CSV files. Create `source_to_concept_map` empty because it is a site-maintained OMOP table and is not part of a standard Athena download. Never commit Athena files, database data, generated patients, passwords, or generated CDM files.
- Generate two batches of five patients with seeds `8675309` and `8675310` and reference date `2024-01-01`.
- Configure Synthea to use UUID filenames so files from separate batches can be flattened without collisions.
- Test Synthea FHIR R4 JSON Bundles and STU3 JSON Bundles independently. Do not test NDJSON: upstream FhirToCdm enumerates top-level `*.json` files and casts each root resource to `Bundle`.
- Database load and validation are required; converter exit code zero alone is not success.
- The loader may add exactly one `cdm_source` row containing spike provenance after loading generated data. It must not modify or synthesize generated clinical rows.
- If required Athena files are unavailable, classify the spike as `BLOCKED`, not `FAILED`.
- Commit only scripts, Dockerfiles, small configuration files, test SQL, and the final report.

## Planned File Structure

```text
spikes/fhir_to_cdm/
├── README.md
├── .env.example
├── .gitignore
├── compose.yaml
├── converter/
│   ├── Dockerfile
│   └── entrypoint.sh
├── synthea/
│   ├── Dockerfile
│   └── generate.sh
├── db/
│   ├── init.sql
│   ├── load_vocab.sh
│   └── load_generated_cdm.sh
├── bin/
│   ├── check-prerequisites
│   ├── generate
│   ├── assemble
│   ├── convert
│   ├── load
│   ├── validate
│   └── run-spike
├── tests/
│   ├── validate_input.sh
│   ├── validate_output_files.sh
│   └── validate_loaded_cdm.sql
└── REPORT.md
```

Generated state belongs under `<data-root>/work/fhir_to_cdm_spike/` and is ignored by Git. Mount that directory at `/work` in spike containers.

---

### Task 1: Establish the disposable harness and evidence contract

**Files:**
- Create: `spikes/fhir_to_cdm/README.md`
- Create: `spikes/fhir_to_cdm/.env.example`
- Create: `spikes/fhir_to_cdm/.gitignore`
- Create: `spikes/fhir_to_cdm/compose.yaml`
- Create: `spikes/fhir_to_cdm/bin/check-prerequisites`
- Create: `spikes/fhir_to_cdm/REPORT.md`

**Interfaces:**
- Consumes: Docker Engine with Compose and a host path containing the nine standard Athena export files.
- Produces: A validated spike configuration and report template.

- [ ] **Step 1: Write prerequisite checks**

`check-prerequisites` must fail unless:

```text
the repository-level bin/validate-setup command reports READY
docker and docker compose are available
the Docker daemon is reachable
the configured platform is linux/amd64
ATHENA_FILES_DIR is an absolute readable directory
CONCEPT.csv, CONCEPT_ANCESTOR.csv, CONCEPT_CLASS.csv,
CONCEPT_RELATIONSHIP.csv, CONCEPT_SYNONYM.csv, DOMAIN.csv,
DRUG_STRENGTH.csv, RELATIONSHIP.csv, and VOCABULARY.csv all exist
no plaintext database password is tracked by Git
```

- [ ] **Step 2: Add deterministic non-secret defaults**

Place these values in `.env.example`:

```dotenv
COMPOSE_PROJECT_NAME=fhir_to_cdm_spike
SPIKE_PLATFORM=linux/amd64
POSTGRES_IMAGE=postgres:16.4-alpine
POSTGRES_HOST_PORT=55432
POSTGRES_DB=fhir_to_cdm_spike
POSTGRES_USER=spike_admin
SYNTHEA_VERSION=3.3.0
SYNTHEA_SEED_1=8675309
SYNTHEA_SEED_2=8675310
SYNTHEA_CLINICIAN_SEED_1=9675309
SYNTHEA_CLINICIAN_SEED_2=9675310
SYNTHEA_REFERENCE_DATE=20240101
FHIR_TO_CDM_REF=4991f90
OMOP_CDM_VERSION=5.3.1
```

The spike wrapper must read the canonical `DATA_ROOT` from the repository-level ignored `etc/setup.env`, derive `ATHENA_FILES_DIR="$DATA_ROOT/athena_input/current"`, and export both values to Compose. Do not duplicate paths in the spike configuration. The real password belongs only in ignored `.env` or a Compose secret.

- [ ] **Step 3: Define report sections before experiments**

`REPORT.md` must contain host/platform, resolved pins and checksums, build evidence, vocabulary evidence, R4 result, STU3 result, multi-batch result, database validation, reproducibility, limitations, verdict, and next action. Initialize verdict to `NOT RUN`.

- [ ] **Step 4: Run the prerequisite check**

Run:

```bash
spikes/fhir_to_cdm/bin/check-prerequisites
```

Expected: exit 0 and one line per satisfied check. If Athena files are absent, record `BLOCKED: Athena export unavailable` and stop without declaring converter failure.

- [ ] **Step 5: Commit the harness**

```bash
git add spikes/fhir_to_cdm
git commit -m "spike: define FhirToCdm feasibility harness"
```

### Task 2: Package unmodified upstream FhirToCdm

**Files:**
- Create: `spikes/fhir_to_cdm/converter/Dockerfile`
- Create: `spikes/fhir_to_cdm/converter/entrypoint.sh`
- Modify: `spikes/fhir_to_cdm/compose.yaml`
- Modify: `spikes/fhir_to_cdm/REPORT.md`

**Interfaces:**
- Consumes: FhirToCdm commit `4991f90`, Linux/amd64 .NET Core 3.1, and PostgreSQL ODBC.
- Produces: A converter image accepting `FHIR_INPUT_DIR`, `CDM_OUTPUT_DIR`, and vocabulary ODBC settings.

- [ ] **Step 1: Define the image-contract check before the image**

The Compose check runs:

```bash
dotnet --info
dotnet /opt/fhir-to-cdm/FHIRtoCDM.dll --help
odbcinst -q -d
```

Expected before implementation: failure because the service cannot build.

- [ ] **Step 2: Build from the exact upstream commit**

The Dockerfile must:

```text
use a .NET Core 3.1 SDK build stage
clone https://github.com/OHDSI/FhirToCdm.git
checkout 4991f90 in detached-head mode
write git rev-parse HEAD to /opt/fhir-to-cdm/UPSTREAM_COMMIT
run dotnet restore and dotnet publish for linux-x64
use a .NET Core 3.1 runtime stage
install unixODBC and the PostgreSQL Unicode ODBC driver
copy the published application and upstream Lookups directory
run as a non-root user
```

Do not use `sed`, `apply_patch`, project retargeting, package upgrades, or source edits inside the upstream checkout.

- [ ] **Step 3: Permit exactly one fallback packaging experiment**

If unchanged source cannot build, try the upstream checked-in `executable/` artifacts with the matching .NET Core 3.1 runtime. Record both attempts and full errors. Do not modify the artifacts and do not add a third approach.

- [ ] **Step 4: Verify the image contract**

Expected:

```text
.NET Core 3.1 is reported
FHIRtoCDM help lists fhir, vocabulary, schema, cdm, result, and chunk options
the PostgreSQL Unicode ODBC driver is listed
UPSTREAM_COMMIT contains the resolved 40-character SHA
```

- [ ] **Step 5: Record the legacy-runtime constraint**

Record that .NET Core 3.1 is end-of-support. Even a successful spike authorizes only this local, internally networked demonstration.

- [ ] **Step 6: Commit converter packaging**

```bash
git add spikes/fhir_to_cdm/converter spikes/fhir_to_cdm/compose.yaml spikes/fhir_to_cdm/REPORT.md
git commit -m "spike: package unmodified OHDSI FhirToCdm"
```

### Task 3: Generate deterministic R4 and STU3 inputs

**Files:**
- Create: `spikes/fhir_to_cdm/synthea/Dockerfile`
- Create: `spikes/fhir_to_cdm/synthea/generate.sh`
- Create: `spikes/fhir_to_cdm/bin/generate`
- Create: `spikes/fhir_to_cdm/bin/assemble`
- Create: `spikes/fhir_to_cdm/tests/validate_input.sh`
- Modify: `spikes/fhir_to_cdm/compose.yaml`

**Interfaces:**
- Consumes: Synthea 3.3.0, fixed seeds, and fixed reference date.
- Produces: `/work/batches/{batch_001,batch_002}/{r4,stu3}` and `/work/assembled/{r4,stu3}` inside `<data-root>/work/fhir_to_cdm_spike/`.

- [ ] **Step 1: Write the failing input validation**

Assert:

```text
each batch/format directory has five JSON Bundle roots
each Bundle contains exactly one Patient
every Patient id exists
Patient ids are unique across batches
assembled filenames are unique
each assembled format directory contains ten Bundles
no NDJSON file is present
```

Run before generation; expect failure because inputs do not exist.

- [ ] **Step 2: Package Synthea v3.3.0**

Download the released dependencies JAR, capture and verify its SHA-256, and run it as non-root. Do not build `master`.

- [ ] **Step 3: Generate both formats for both seeds**

Use commands equivalent to:

```bash
java -jar /opt/synthea/synthea-with-dependencies.jar \
  -p 5 -s 8675309 -cs 9675309 -r 20240101 \
  --exporter.use_uuid_filenames true \
  --exporter.csv.export false \
  --exporter.fhir.export true \
  --exporter.fhir_stu3.export false \
  --exporter.hospital.fhir.export false \
  --exporter.hospital.fhir_stu3.export false \
  --exporter.practitioner.fhir.export false \
  --exporter.practitioner.fhir_stu3.export false
```

Run a corresponding STU3 export with R4 disabled, then repeat both formats using patient seed `8675310` and clinician seed `9675310`. Keep the standalone hospital and practitioner exporters disabled so the input contract contains only the five patient Bundles. Capture the exact command, resolved configuration, metadata, and logs per batch.

- [ ] **Step 4: Assemble without modifying JSON**

Copy or hard-link Bundles into flat format-specific directories and prefix each filename with its batch ID.

- [ ] **Step 5: Run input validation**

```bash
spikes/fhir_to_cdm/tests/validate_input.sh
```

Expected: both assembled directories contain ten validated Bundles.

- [ ] **Step 6: Commit deterministic input generation**

```bash
git add spikes/fhir_to_cdm/synthea spikes/fhir_to_cdm/bin/generate spikes/fhir_to_cdm/bin/assemble spikes/fhir_to_cdm/tests/validate_input.sh spikes/fhir_to_cdm/compose.yaml
git commit -m "spike: generate deterministic FHIR fixtures"
```

### Task 4: Load and verify Athena vocabularies

**Files:**
- Create: `spikes/fhir_to_cdm/db/init.sql`
- Create: `spikes/fhir_to_cdm/db/load_vocab.sh`
- Modify: `spikes/fhir_to_cdm/compose.yaml`
- Modify: `spikes/fhir_to_cdm/REPORT.md`

**Interfaces:**
- Consumes: The nine standard Athena CSV files.
- Produces: Physical vocabulary tables in `athena_vocabs` readable through PostgreSQL ODBC.

- [ ] **Step 1: Create isolated spike schemas**

Create only `athena_vocabs`, `spike_omop_fhir_r4`, and `spike_omop_fhir_stu3` inside the Compose PostgreSQL database.

- [ ] **Step 2: Populate the complete vocabulary-table surface**

Use OMOP 5.3.1 definitions and PostgreSQL `\copy` with Athena's tab delimiter and header. Load the nine exported tables and create `source_to_concept_map` empty. Fail on a missing exported file, rejected row, or type error; do not require a non-standard `SOURCE_TO_CONCEPT_MAP.csv`.

- [ ] **Step 3: Verify vocabulary completeness**

Run:

```sql
SELECT count(*) > 0 FROM athena_vocabs.concept;
SELECT count(*) > 0 FROM athena_vocabs.concept_relationship;
SELECT count(*) > 0 FROM athena_vocabs.concept_ancestor;
SELECT count(*) = 1
FROM athena_vocabs.vocabulary
WHERE vocabulary_id = 'None';
```

Record every table count and `vocabulary_version`.

- [ ] **Step 4: Verify ODBC from the converter image**

Execute a read-only concept count through the exact ODBC configuration used by FhirToCdm. Expected: a positive result.

- [ ] **Step 5: Commit vocabulary setup**

```bash
git add spikes/fhir_to_cdm/db spikes/fhir_to_cdm/compose.yaml spikes/fhir_to_cdm/REPORT.md
git commit -m "spike: provide PostgreSQL vocabulary dependency"
```

### Task 5: Execute the format compatibility matrix

**Files:**
- Create: `spikes/fhir_to_cdm/bin/convert`
- Create: `spikes/fhir_to_cdm/tests/validate_output_files.sh`
- Modify: `spikes/fhir_to_cdm/REPORT.md`

**Interfaces:**
- Consumes: Flat R4 and STU3 input plus verified ODBC.
- Produces: Separate logs and generated output for both candidates.

- [ ] **Step 1: Write the failing output-contract test**

For each candidate require:

```text
converter exit code 0
no unhandled, parser, KeyNotFoundException, or duplicate-key exception
person output has at least one data row
exactly ten distinct person_source_value values across chunks
visit_occurrence has at least one data row
all files are tab-delimited with stable column counts
the output directory was empty before conversion
```

Run before conversion; expect failure.

- [ ] **Step 2: Convert all ten R4 Bundles once**

Invoke:

```text
--fhir /work/assembled/r4
--vocabulary <the configured PostgreSQL Unicode ODBC connection>
--schema athena_vocabs
--cdm V53
--result /work/generated/r4
--chunk 4
```

Chunk size four deliberately exercises multi-chunk identifiers.

- [ ] **Step 3: Convert all ten STU3 Bundles once**

Use identical settings except input and output directories. Never mix formats.

- [ ] **Step 4: Record both outcomes independently**

Record command, exit code, duration, processed-file count, tables, row counts, and first complete error for each failed candidate.

- [ ] **Step 5: Run output validation**

At least one candidate must satisfy every assertion. If neither does, classify `FAILED` and continue only to Task 8.

- [ ] **Step 6: Commit conversion evidence**

```bash
git add spikes/fhir_to_cdm/bin/convert spikes/fhir_to_cdm/tests/validate_output_files.sh spikes/fhir_to_cdm/REPORT.md
git commit -m "spike: test FhirToCdm format compatibility"
```

### Task 6: Load successful output into OMOP 5.3.1

**Files:**
- Create: `spikes/fhir_to_cdm/db/load_generated_cdm.sh`
- Create: `spikes/fhir_to_cdm/bin/load`
- Create: `spikes/fhir_to_cdm/tests/validate_loaded_cdm.sql`
- Modify: `spikes/fhir_to_cdm/REPORT.md`

**Interfaces:**
- Consumes: A file-level passing candidate and official PostgreSQL OMOP 5.3.1 DDL.
- Produces: A populated candidate scratch schema and SQL validation evidence.

- [ ] **Step 1: Preserve official DDL provenance**

Acquire PostgreSQL DDL from the OHDSI CommonDataModel `v5.3.1` release and record the source URL and SHA-256. Mount it read-only and do not edit it to fit output.

- [ ] **Step 2: Implement a strict chunk loader**

Discover every chunk, require identical headers per table, and load with `\copy`. Filename casing and delimiter handling may be normalized; generated values may not be changed, invented, discarded, remapped, or deduplicated. Afterward, insert one loader-owned `cdm_source` row recording the pinned converter, Synthea, FHIR, and OMOP versions; this provenance row is the only permitted synthesized CDM data.

- [ ] **Step 3: Load, then add keys and indexes**

Create the scratch schema, load every chunk, then apply official primary keys and indexes. Capture all rejected rows and DDL errors. Do not use `ON CONFLICT`, `DISTINCT`, or silent deduplication.

- [ ] **Step 4: Write relational assertions**

Fail if:

```text
person count is not exactly 10
person_id or person_source_value is duplicated
a person-linked clinical row lacks a person
a visit-linked clinical row lacks a visit
a visit lacks a person
a populated domain has duplicate primary IDs
all representative clinical domains are empty despite corresponding source resources
cdm_source lacks converter, Synthea, FHIR, and OMOP provenance
```

Report total rows, concept ID zero rows, nonzero concept rows, and distinct source codes for every populated domain.

- [ ] **Step 5: Execute validation**

Run `psql` with `ON_ERROR_STOP=1`. Expected: zero assertion failures and zero orphans.

- [ ] **Step 6: Commit loader and checks**

```bash
git add spikes/fhir_to_cdm/db/load_generated_cdm.sh spikes/fhir_to_cdm/bin/load spikes/fhir_to_cdm/tests/validate_loaded_cdm.sql spikes/fhir_to_cdm/REPORT.md
git commit -m "spike: validate generated OMOP V53 data"
```

### Task 7: Verify repeatability and failure visibility

**Files:**
- Create: `spikes/fhir_to_cdm/bin/validate`
- Create: `spikes/fhir_to_cdm/bin/run-spike`
- Modify: `spikes/fhir_to_cdm/REPORT.md`

**Interfaces:**
- Consumes: The passing candidate and prior commands.
- Produces: One-command repeatability and negative-case evidence.

- [ ] **Step 1: Run the passing conversion twice from clean state**

For each run, empty generated output, recreate the scratch schema, convert the same ten Bundles once, load, and validate.

- [ ] **Step 2: Compare normalized relational exports**

Export each populated CDM table ordered by primary key and compare SHA-256 hashes. Exclude a wall-clock field only if the report proves the converter or loader creates it. Require identical counts, IDs, foreign keys, source values, and concept IDs.

- [ ] **Step 3: Prove multi-batch single invocation**

The log must show one converter start and ten Bundle inputs. The manifest must attribute five loaded persons to each source batch.

- [ ] **Step 4: Exercise negative cases**

Require nonzero exit and no database load for:

```text
missing vocabulary schema
empty FHIR input directory
one malformed JSON file mixed with valid Bundles
```

- [ ] **Step 5: Build the end-to-end command**

`run-spike` executes:

```text
prerequisite checks
image builds
input generation and validation
PostgreSQL and vocabulary setup
R4 conversion
STU3 conversion
file validation
successful candidate load
relational validation
clean repeat and comparison
negative cases
final evidence summary
```

- [ ] **Step 6: Commit end-to-end automation**

```bash
git add spikes/fhir_to_cdm/bin/validate spikes/fhir_to_cdm/bin/run-spike spikes/fhir_to_cdm/REPORT.md
git commit -m "spike: verify repeatable multi-batch conversion"
```

### Task 8: Classify the result and prescribe the next action

**Files:**
- Modify: `spikes/fhir_to_cdm/REPORT.md`
- Modify: `docs/intro.md`

**Interfaces:**
- Consumes: Complete evidence.
- Produces: Exactly one verdict and mandatory next action.

- [ ] **Step 1: Apply the definition of success**

Set `SUCCESS` only if all hold:

```text
unchanged source builds or unchanged upstream executable runs on linux/amd64
the pinned commit and PostgreSQL ODBC driver are proven
one exact Synthea 3.3.0 Bundle format parses all ten inputs
one converter invocation processes both batches
the converter reads athena_vocabs through ODBC
V53 files load into unmodified official OMOP 5.3.1 DDL
all row-count, uniqueness, key, and orphan checks pass
every populated mapped domain has at least one nonzero standard concept
the clean rerun is relationally equivalent
negative cases fail visibly without loading partial output
the exact compatibility contract is recorded
```

- [ ] **Step 2: Apply qualified success**

Use `QUALIFIED SUCCESS` only if correctness passes but a bounded constraint remains, such as linux/amd64 emulation, using the upstream executable instead of a source build, or supporting only one FHIR format. The user must explicitly accept every constraint before main development.

- [ ] **Step 3: Apply failure**

Use `FAILED` if any hold:

```text
a source patch, project retarget, or dependency upgrade is required
neither unchanged source nor upstream executable runs in a container
neither R4 nor STU3 parses completely
PostgreSQL vocabulary ODBC access fails
output cannot load without changing or discarding data
IDs collide inside the one multi-batch invocation
person or visit relationships are broken
input is silently skipped or partial failure returns success
identical reruns change IDs or relationships
```

- [ ] **Step 4: Distinguish blocked**

Use `BLOCKED` only for a missing external prerequisite: Athena data, approved dependency download, Docker daemon, disk, or equivalent. Record the exact missing prerequisite and rerun command. Do not infer converter viability.

- [ ] **Step 5: Follow the verdict**

| Verdict | Mandatory next action |
|---|---|
| `SUCCESS` | Pin proven commits and image digests in `docs/intro.md`, carry the contracts into the main plan, and reimplement production-quality wrappers instead of silently promoting spike scripts. |
| `QUALIFIED SUCCESS` | Present constraints to the user and proceed only after explicit acceptance and documentation as v1 limitations. |
| `FAILED` | Stop FHIR-path development, do not patch or fork FhirToCdm, and reopen converter selection against the same acceptance criteria. |
| `BLOCKED` | Obtain the prerequisite and rerun from a clean Compose project; make no architecture decision. |

- [ ] **Step 6: Verify final evidence**

Run:

```bash
git diff --check
git status --short
spikes/fhir_to_cdm/bin/run-spike
```

Expected: formatting passes, only intended files differ, and the command ends with the verdict recorded in `REPORT.md`.

- [ ] **Step 7: Commit the verdict**

```bash
git add spikes/fhir_to_cdm/REPORT.md docs/intro.md
git commit -m "docs: record FhirToCdm feasibility verdict"
```

## Stop Rules

- Stop and report `BLOCKED` when an external prerequisite is missing.
- Stop experiments and report `FAILED` when upstream source modification appears necessary.
- Do not optimize performance, image size, retries, or production security during this spike.
- Do not integrate spike files into the main Compose stack.
- Do not begin the main implementation plan until the verdict's mandatory next action is completed.
