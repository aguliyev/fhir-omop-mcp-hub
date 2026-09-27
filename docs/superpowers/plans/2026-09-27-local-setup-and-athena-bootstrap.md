# Local Setup and Athena Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a clean checkout plus a user-downloaded OHDSI Athena export into a validated local Docker/PostgreSQL foundation that is ready to run the FhirToCdm feasibility spike.

**Architecture:** Repository scripts own deterministic setup; a project-local skill orchestrates them and pauses for the one unavoidable human action, downloading licensed vocabulary content from Athena. One configurable host data root is mounted at `/data`, PostgreSQL persists there, and a one-shot job transactionally replaces and validates the shared vocabulary schema. The converter spike reuses the staged files but retains scratch schemas so experimental failures cannot damage the canonical vocabulary load.

**Tech Stack:** POSIX shell, Docker Engine and Docker Compose, PostgreSQL 16.4 Alpine on Linux/amd64, OMOP CDM 5.3.1 PostgreSQL DDL, `psql`, SHA-256 manifests, and a repository-local Codex skill.

**Spec:** `docs/intro.md`

## Global Constraints

- Implement only the local platform and vocabulary prerequisite. Do not implement Synthea, ETL-Synthea, FhirToCdm, WebAPI, or MCP application code here.
- Use database `fhir_omop_mcp_hub` and the schema names fixed in `docs/intro.md`.
- Pin `docker.io/library/postgres:16.4-alpine@sha256:5660c2cbfea50c7a9127d17dc4e48543eedd3d7a41a595a2dfa572471e37e64c` and `platform: linux/amd64`.
- Default the host data root to ignored `data/`, canonicalize it before Compose runs, and mount it at `/data`.
- Bind PostgreSQL to `127.0.0.1`, never `0.0.0.0`.
- Generate secrets below `<data-root>/secrets/` with mode `0600`; never print or commit them.
- Athena login, license acceptance, export creation, and download are manual. Never automate them, request credentials, or redistribute vocabulary files.
- Direct the user to `https://athena.ohdsi.org/` and request SNOMED, RxNorm, LOINC, CVX, and UCUM plus Athena-selected dependencies.
- Require the nine standard files: `CONCEPT.csv`, `CONCEPT_ANCESTOR.csv`, `CONCEPT_CLASS.csv`, `CONCEPT_RELATIONSHIP.csv`, `CONCEPT_SYNONYM.csv`, `DOMAIN.csv`, `DRUG_STRENGTH.csv`, `RELATIONSHIP.csv`, and `VOCABULARY.csv`.
- Do not require `SOURCE_TO_CONCEPT_MAP.csv`; create `source_to_concept_map` empty because it is site-maintained.
- Base DDL on OHDSI CommonDataModel `v5.3.1`. Record these upstream checksums:
  - DDL: `1c3dfa742aac50dd0fe3c2fa3ec990678c734bb1803671fb32982ffb949d63ad`
  - Vocabulary loader: `bc884998569e01f8ec8a411a5494f88d84860343d51c41765384f2361bd73697`
  - Indexes: `e84d867eade16365c5425cebee8717137d7418abc7cf777d54292143d323651b`
- Never commit Athena archives/CSVs, PostgreSQL state, generated secrets, or generated setup evidence.
- A vocabulary replacement requires explicit approval, an advisory lock, and one database transaction so failure preserves the prior schema.
- Create vocabulary views only in allow-listed `omop_csv`; create none in `omop_fhir`.
- Name the skill `setup-fhir-omop-mcp-hub` at `.agents/skills/setup-fhir-omop-mcp-hub/SKILL.md`.
- Do not report readiness until the real Athena export and a clean idempotent rerun validate.

## Planned File Structure

```text
.agents/skills/setup-fhir-omop-mcp-hub/
├── SKILL.md
└── references/athena-download.md
bin/
├── lib/common.sh
├── compose
├── check-prerequisites
├── prepare-data
├── stage-athena
├── setup
├── start
├── stop
├── status
├── logs
├── load-vocab
├── validate-vocab
├── validate-setup
└── reset
db/
├── bootstrap/{run.sh,schemas.sql}
└── athena/{PROVENANCE.md,create_tables.sql,create_indexes.sql,create_views.sql,load.sh,validate.sql}
etc/
├── setup.env.example
├── athena-required-files.txt
└── athena-required-vocabularies.txt
tests/setup/
├── fixtures/athena-valid/
├── test_contract.sh
├── test_stage_athena.sh
├── test_compose_setup.sh
└── test_setup_skill.sh
compose.yaml
```

Generated state is ignored:

```text
data/
├── .fhir_omop_mcp_hub_data_root
├── postgres/
├── secrets/
├── athena_input/{current,previous}/
├── work/setup/
├── csv_input/{inbox,pending,success,rejected}/
└── fhir_input/{inbox,pending,success,rejected}/
```

---

### Task 1: Define the setup contract and safe local configuration

**Files:**
- Modify: `.gitignore`
- Create: `etc/setup.env.example`
- Create: `etc/athena-required-files.txt`
- Create: `etc/athena-required-vocabularies.txt`
- Create: `bin/lib/common.sh`
- Create: `bin/check-prerequisites`
- Create: `tests/setup/test_contract.sh`

**Interfaces:**
- Consumes: A clean checkout and host Docker installation.
- Produces: Shared shell invariants and a preflight command used by every later task.

- [ ] **Step 1: Write the failing repository-contract test**

Assert that planned paths exist, executable scripts have their bit set, and `.gitignore` covers `/data/`, `/etc/setup.env`, and `/.env`. Assert that `etc/athena-required-files.txt` is exactly:

```text
CONCEPT.csv
CONCEPT_ANCESTOR.csv
CONCEPT_CLASS.csv
CONCEPT_RELATIONSHIP.csv
CONCEPT_SYNONYM.csv
DOMAIN.csv
DRUG_STRENGTH.csv
RELATIONSHIP.csv
VOCABULARY.csv
```

Run `bash tests/setup/test_contract.sh`; expect failure because the files do not exist.

- [ ] **Step 2: Add ignored-state rules and non-secret defaults**

Create `etc/setup.env.example`:

```dotenv
COMPOSE_PROJECT_NAME=fhir_omop_mcp_hub
DATA_ROOT=./data
POSTGRES_IMAGE=docker.io/library/postgres:16.4-alpine@sha256:5660c2cbfea50c7a9127d17dc4e48543eedd3d7a41a595a2dfa572471e37e64c
POSTGRES_DB=fhir_omop_mcp_hub
POSTGRES_USER=postgres
POSTGRES_HOST_PORT=5432
VOCAB_VIEW_TARGET_SCHEMAS=omop_csv
```

Create `etc/athena-required-vocabularies.txt`:

```text
CVX
LOINC
RxNorm
SNOMED
UCUM
```

- [ ] **Step 3: Implement shared helpers and host checks**

`bin/lib/common.sh` must use `set -eu`, derive `REPO_ROOT` from its own path, load ignored `etc/setup.env`, canonicalize `DATA_ROOT`, avoid secret output, and provide `die`, `require_command`, `require_absolute_dir`, and `compose` functions.

`bin/check-prerequisites` must verify Docker, Compose, daemon access, Linux/x86_64, `openssl`, `sha256sum`, `awk`, `sed`, `find`, 30 GiB free space, a usable loopback port, an allowed absolute writable data root, the pinned image digest, and that ignored state is not tracked. Reject `/`, the home directory, and the repository root as `DATA_ROOT`. Print one actionable `PASS:` or `FAIL:` line per check.

- [ ] **Step 4: Verify and commit**

```bash
cp etc/setup.env.example etc/setup.env
bash tests/setup/test_contract.sh
bin/check-prerequisites
git check-ignore data etc/setup.env .env
git add .gitignore etc/setup.env.example etc/athena-required-files.txt etc/athena-required-vocabularies.txt bin/lib/common.sh bin/check-prerequisites tests/setup/test_contract.sh
git commit -m "build: define local setup contract"
```

Expected: tests and preflight pass; all three local paths are ignored.

### Task 2: Provide persistent PostgreSQL and idempotent database bootstrap

**Files:**
- Create: `compose.yaml`
- Create: `bin/compose`
- Create: `bin/prepare-data`
- Create: `bin/start`
- Create: `bin/stop`
- Create: `bin/status`
- Create: `bin/logs`
- Create: `db/bootstrap/run.sh`
- Create: `db/bootstrap/schemas.sql`
- Create: `tests/setup/test_compose_setup.sh`

**Interfaces:**
- Consumes: `etc/setup.env`, pinned PostgreSQL, and shared helpers.
- Produces: Healthy `postgres`, successful one-shot `db_init`, and the fixed schema surface.

- [ ] **Step 1: Write the failing Compose integration test**

Use `mktemp -d`, port `55433`, and project `fhir_omop_mcp_hub_setup_test`. Clean containers and data only after verifying the cleanup path begins with the test directory. Assert PostgreSQL becomes healthy, reports 16.4, binds to `127.0.0.1:55433`, `db_init` exits zero twice, all eight schemas exist, and `PUBLIC` cannot create in `public` or `athena_vocabs`. Run it and expect failure because Compose is absent.

- [ ] **Step 2: Implement data and secret preparation**

Create the full documented data tree and a root sentinel named `.fhir_omop_mcp_hub_data_root` containing only `fhir_omop_mcp_hub`. Generate `<data-root>/secrets/postgres_password` once with:

```bash
umask 077
openssl rand -hex 32
```

Require mode `0600`, never print the value, and replace relative `DATA_ROOT` in the ignored local env with its canonical absolute path.

- [ ] **Step 3: Define Compose and lifecycle wrappers**

Define `postgres` and one-shot `db_init`. Set `PGDATA=/data/postgres`, mount the data root at `/data`, mount the password at `/run/secrets/postgres_password`, use `POSTGRES_PASSWORD_FILE`, wait on `pg_isready`, force Linux/amd64, and publish only the loopback port. `bin/compose` owns all Compose flags; `start`, `stop`, `status`, and `logs` call it.

- [ ] **Step 4: Bootstrap the fixed schema surface**

Revoke `CREATE` on `public` from `PUBLIC`, create no-login `vocab_reader` if absent, and idempotently create:

```text
athena_vocabs
omop_csv
omop_csv_results
omop_csv_temp
omop_fhir
omop_fhir_results
omop_fhir_temp
ohdsi_webapi
```

Revoke all on `athena_vocabs` from `PUBLIC`, grant `USAGE` to `vocab_reader`, and invoke `psql` with `ON_ERROR_STOP=1` without exposing the password.

- [ ] **Step 5: Verify twice and commit**

```bash
bash tests/setup/test_compose_setup.sh
git add compose.yaml bin/compose bin/prepare-data bin/start bin/stop bin/status bin/logs db/bootstrap tests/setup/test_compose_setup.sh
git commit -m "build: add local PostgreSQL bootstrap"
```

Expected: the integration test passes, including the second `db_init` execution.

### Task 3: Stage and validate a manual Athena download

**Files:**
- Create: `bin/stage-athena`
- Create: `tests/setup/fixtures/athena-valid/*`
- Create: `tests/setup/test_stage_athena.sh`

**Interfaces:**
- Consumes: One absolute path to an extracted Athena export directory.
- Produces: `<data-root>/athena_input/current/` with nine validated CSVs, `manifest.sha256`, and `source.env`.

- [ ] **Step 1: Create minimal valid fixtures and failing tests**

Create one header and one type-correct row per required file. `VOCABULARY.csv` must contain CVX, LOINC, RxNorm, SNOMED, and UCUM. Test:

```text
valid nine-file directory succeeds
missing, empty, comma-delimited, or wrong-header file fails by name
duplicate basename in nested directories fails
symlink input fails
SOURCE_TO_CONCEPT_MAP.csv is not required
replacement without --replace fails
confirmed replacement moves current to previous
manifest contains SHA-256 and byte count for every CSV
staged state is ignored by Git
```

Run `bash tests/setup/test_stage_athena.sh`; expect failure because the command is absent.

- [ ] **Step 2: Implement exact intake validation**

`bin/stage-athena SOURCE_DIR` must require an absolute readable directory and exactly one regular nonsymlink file for each required basename. Validate the exact OMOP 5.3.1 tab-delimited header and at least one data row. An optional Athena `VERSION` or readme may be copied for provenance but never treated as table data.

Copy into `<data-root>/athena_input/.staging-<pid>`, write a sorted checksum manifest and a non-secret `source.env` containing UTC staging time and original path, then atomically rename to `current`. Remove staging state on failure.

- [ ] **Step 3: Make replacement explicit and recoverable**

If `current` has a different aggregate manifest, exit unless `--replace` is present. With `--replace`, move it to `previous`; replacing an existing `previous` requires an interactive confirmation. The setup skill must receive user approval before passing `--replace`.

- [ ] **Step 4: Verify and commit**

```bash
bash tests/setup/test_stage_athena.sh
git add bin/stage-athena tests/setup/fixtures tests/setup/test_stage_athena.sh
git commit -m "feat: validate and stage Athena exports"
```

Expected: all positive and negative cases pass.

### Task 4: Load, index, grant, and validate Athena vocabularies

**Files:**
- Create: `db/athena/PROVENANCE.md`
- Create: `db/athena/create_tables.sql`
- Create: `db/athena/create_indexes.sql`
- Create: `db/athena/create_views.sql`
- Create: `db/athena/load.sh`
- Create: `db/athena/validate.sql`
- Create: `bin/load-vocab`
- Create: `bin/validate-vocab`
- Modify: `compose.yaml`
- Modify: `tests/setup/test_compose_setup.sh`

**Interfaces:**
- Consumes: Healthy PostgreSQL and `/data/athena_input/current`.
- Produces: Ten physical OMOP vocabulary tables in `athena_vocabs`, nine populated, and ten read-only views in `omop_csv`.

- [ ] **Step 1: Record upstream provenance**

Record the three Global Constraints checksums and link directly to:

```text
https://raw.githubusercontent.com/OHDSI/CommonDataModel/v5.3.1/PostgreSQL/OMOP%20CDM%20postgresql%20ddl.txt
https://raw.githubusercontent.com/OHDSI/CommonDataModel/v5.3.1/PostgreSQL/VocabImport/OMOP%20CDM%20vocabulary%20load%20-%20PostgreSQL.sql
https://raw.githubusercontent.com/OHDSI/CommonDataModel/v5.3.1/PostgreSQL/OMOP%20CDM%20postgresql%20indexes.txt
```

Explain that the repository retains only vocabulary DDL/indexes, replaces Windows server-side paths with container-side `\copy`, and leaves `source_to_concept_map` empty.

- [ ] **Step 2: Add exact OMOP vocabulary DDL and indexes**

Copy column names, types, nullability, primary keys, and relevant lookup indexes for:

```text
concept
vocabulary
domain
concept_class
concept_relationship
relationship
concept_synonym
concept_ancestor
source_to_concept_map
drug_strength
```

Qualify every object with `athena_vocabs`; do not depend on `search_path`. Document any necessary local index-name correction in `PROVENANCE.md` without changing index semantics.

- [ ] **Step 3: Write assertions before the loader**

`validate.sql` must raise an exception unless:

```text
all ten physical tables exist
the nine Athena-backed tables are nonempty
source_to_concept_map is empty
vocabulary contains all five required vocabulary IDs
concept has a valid standard concept for each required vocabulary
official primary keys and lookup indexes exist
vocab_reader can SELECT but cannot write or CREATE
omop_csv has views for all ten relations
omop_fhir has no same-named relation
```

On success return vocabulary version, all row counts, staged aggregate checksum, and validation time.

- [ ] **Step 4: Implement the transactional one-shot job**

Add `athena_vocabs` to Compose as a one-shot profile service. Its `load.sh` must verify the staged manifest, read the secret without printing it, connect with `ON_ERROR_STOP=1`, and perform inside one transaction:

```text
pg_advisory_xact_lock(hashtext('fhir_omop_mcp_hub.athena_vocabs'))
drop athena_vocabs with CASCADE and recreate it
create ten tables
\copy nine files using FORMAT csv, HEADER true, DELIMITER E'\t', QUOTE E'\b'
leave source_to_concept_map empty
add keys and indexes
ANALYZE populated tables
grant read-only access to vocab_reader
create allow-listed omop_csv views
run validate.sql
commit
```

Reject every `VOCAB_VIEW_TARGET_SCHEMAS` value except the exact single identifier `omop_csv`. Any error must roll back and preserve the previous committed schema and views.

- [ ] **Step 5: Add guarded operator commands**

`bin/load-vocab` must require database health and a valid staged manifest. If live vocabulary data exists, require `--replace`, show current and staged versions, and obtain confirmation. Save sanitized logs below `<data-root>/work/setup/`.

`bin/validate-vocab` runs `validate.sql` read-only and returns nonzero on any assertion failure.

- [ ] **Step 6: Test initial load, rollback, and replacement**

Extend the Compose test to prove a fixture loads, a malformed replacement rolls back with old counts intact, a changed fixture is refused without `--replace`, a confirmed replacement succeeds, and every compatibility view points to the newly committed tables.

```bash
bash tests/setup/test_compose_setup.sh
git add db/athena bin/load-vocab bin/validate-vocab compose.yaml tests/setup/test_compose_setup.sh
git commit -m "feat: load and validate Athena vocabularies"
```

Expected: no partial schema becomes visible during the forced failure.

### Task 5: Assemble the idempotent setup lifecycle

**Files:**
- Create: `bin/setup`
- Create: `bin/validate-setup`
- Create: `bin/reset`
- Modify: `tests/setup/test_compose_setup.sh`

**Interfaces:**
- Consumes: All setup primitives from Tasks 1-4.
- Produces: One setup command and a machine-checkable readiness marker.

- [ ] **Step 1: Add lifecycle acceptance cases**

Test this state table:

| State | Required result |
|---|---|
| No local env | Copy example, canonicalize data root, continue |
| No staged Athena | Bootstrap PostgreSQL, exit `20`, print `ATHENA_REQUIRED` and official URL |
| Valid staged Athena | Load and exit `0` |
| Same manifest already loaded | Skip reload, validate, exit `0` |
| Different manifest loaded | Exit `21`, print `ATHENA_REPLACE_APPROVAL_REQUIRED` |
| Failed validation | Exit nonzero and do not write readiness marker |

- [ ] **Step 2: Implement setup orchestration**

Run in this order:

```text
check-prerequisites
prepare-data
start postgres
run db_init
check staged manifest
load or validate according to the state table
validate-setup
```

On success, atomically write `<data-root>/work/setup/ready.env` containing only `SETUP_STATUS`, `POSTGRES_VERSION`, `DATABASE_NAME`, `VOCAB_SCHEMA`, aggregate Athena checksum, live vocabulary version, and UTC validation time. Never include placeholder text or secrets.

- [ ] **Step 3: Implement read-only readiness validation**

`bin/validate-setup` reruns preflight and `db_init`, checks container health, invokes `validate-vocab`, verifies staged/live/readiness checksums agree, and prints versions and row counts. It must not modify vocabulary data.

- [ ] **Step 4: Add a guarded reset**

Show the exact canonical path and require the user to type `RESET fhir_omop_mcp_hub`. Reject root, home, repository root, empty paths, symlinks, and paths whose `.fhir_omop_mcp_hub_data_root` sentinel is missing or has different content. Stop only this Compose project, remove only the validated target, and state that PostgreSQL, staged copies, and secrets are deleted while the user's original download is untouched.

- [ ] **Step 5: Verify clean setup and rerun**

```bash
bash tests/setup/test_compose_setup.sh
bin/setup
bin/setup
bin/validate-setup
git add bin/setup bin/validate-setup bin/reset tests/setup/test_compose_setup.sh
git commit -m "feat: orchestrate reproducible local setup"
```

Expected under fixture configuration: both setup runs pass and the second does not reload Athena. Real-data acceptance is Task 8.

### Task 6: Create the project-local setup skill

**Files:**
- Create: `.agents/skills/setup-fhir-omop-mcp-hub/SKILL.md`
- Create: `.agents/skills/setup-fhir-omop-mcp-hub/references/athena-download.md`
- Create: `tests/setup/test_setup_skill.sh`

**Interfaces:**
- Consumes: A request to set up, bootstrap, repair, or verify this repository.
- Produces: A guided workflow that pauses for manual Athena download and finishes only after real-data validation.

- [ ] **Step 1: Write the skill behavioral contract test**

Verify YAML frontmatter, exact name, discriminating description, a discoverable Athena reference, and these instructions:

```text
run bin/check-prerequisites before mutation
use bin/setup rather than duplicating setup logic
interpret exit 20 as a human Athena-download pause
send the user only to https://athena.ohdsi.org/
never request credentials or automate license acceptance
name SNOMED, RxNorm, LOINC, CVX, and UCUM
explain nine files and that SOURCE_TO_CONCEPT_MAP.csv is not required
ask for the absolute extracted-directory path
run bin/stage-athena only after the user responds
obtain approval before --replace
finish only after bin/validate-setup passes
hand off to, but do not start, the FhirToCdm spike
```

- [ ] **Step 2: Write the concise skill entrypoint**

Use this exact frontmatter:

```yaml
---
name: setup-fhir-omop-mcp-hub
description: Bootstrap or verify this repository's local Docker, PostgreSQL, and OHDSI Athena vocabulary prerequisite before ingestion or FhirToCdm spikes. Use when asked to set up the project, prepare Athena, resume after a vocabulary download, or diagnose setup readiness.
---
```

Route to the Athena reference only when setup returns `ATHENA_REQUIRED`. Keep mechanics in repository scripts. Define outcomes:

```text
BLOCKED  waiting for user download/license, Docker/network permission, or disk
FAILED   setup accepted invalid input, exposed partial state, or failed validation
READY    bin/validate-setup passed against the real Athena export
```

- [ ] **Step 3: Write the Athena human-action reference**

Instruct the agent to tell the user:

1. Open [OHDSI Athena](https://athena.ohdsi.org/) in their own browser.
2. Sign in or create an account and personally accept required licenses.
3. Select SNOMED, RxNorm, LOINC, CVX, and UCUM and retain dependencies Athena selects.
4. Create the bundle, wait for preparation, and download the ZIP from Athena.
5. Extract locally without editing or renaming CSVs.
6. Give the agent only the absolute extracted-directory path, never credentials.

List the nine expected filenames, explain that they are tab-delimited despite `.csv`, and state why `SOURCE_TO_CONCEPT_MAP.csv` is not expected.

- [ ] **Step 4: Validate the package**

```bash
bash tests/setup/test_setup_skill.sh
python /home/anar/.codex/skills/.system/skill-creator/scripts/quick_validate.py .agents/skills/setup-fhir-omop-mcp-hub
```

Expected: both validators pass without scaffold placeholders.

- [ ] **Step 5: Perform a fresh-task behavior check**

In a fresh Codex task rooted here, invoke `$setup-fhir-omop-mcp-hub` without staged Athena data. Confirm it reports `BLOCKED`, gives the manual official-site instructions, asks only for the extracted path, and does not start the spike. Do not provide credentials or real data to this behavior test.

- [ ] **Step 6: Commit the skill**

```bash
git add .agents/skills/setup-fhir-omop-mcp-hub tests/setup/test_setup_skill.sh
git commit -m "feat: add guided local setup skill"
```

### Task 7: Document the setup-to-spike handoff

**Files:**
- Modify: `README.md`
- Modify: `docs/intro.md`
- Modify: `docs/superpowers/plans/2026-09-27-fhir-to-cdm-container-feasibility-spike.md`

**Interfaces:**
- Consumes: Completed commands and skill.
- Produces: One human entry point and one verified spike prerequisite contract.

- [ ] **Step 1: Add the quick start**

Document the skill flow and these direct equivalents:

```bash
bin/setup
bin/stage-athena /absolute/path/to/extracted/athena
bin/setup
bin/validate-setup
```

State that the second step requires the actual user-provided path and the spike begins only after `READY`.

- [ ] **Step 2: Record the boundary in the architecture**

State that the local setup skill owns host preparation, database bootstrap, manual Athena handoff, and canonical vocabulary validation. The converter spike starts only after `bin/validate-setup`, but loads the staged files into scratch state for isolation.

- [ ] **Step 3: Amend the converter spike prerequisites**

Require `bin/validate-setup` first. Set `ATHENA_FILES_DIR` to the absolute `<data-root>/athena_input/current` directory and require its manifest. Replace remaining ten-file language with nine exported files plus an empty `source_to_concept_map`. Keep the isolated scratch load.

- [ ] **Step 4: Verify and commit documentation**

```bash
rg -n 'setup-fhir-omop-mcp-hub|bin/validate-setup|athena.ohdsi.org|nine' README.md docs/intro.md docs/superpowers/plans
bash tests/setup/test_contract.sh
git add README.md docs/intro.md docs/superpowers/plans/2026-09-27-fhir-to-cdm-container-feasibility-spike.md
git commit -m "docs: connect local setup to converter spike"
```

Expected: every referenced path and command exists.

### Task 8: Run real-Athena acceptance and issue the readiness verdict

**Files:**
- Create: `<data-root>/work/setup/ready.env` (generated, ignored)
- Create: `<data-root>/work/setup/acceptance.txt` (generated, ignored)

**Interfaces:**
- Consumes: The user's real extracted export and completed implementation.
- Produces: Exactly one `READY`, `BLOCKED`, or `FAILED` verdict.

- [ ] **Step 1: Start through the skill**

Invoke `$setup-fhir-omop-mcp-hub`. If it reports `ATHENA_REQUIRED`, provide the manual instructions and wait. Fixture success never substitutes for real vocabulary acceptance.

- [ ] **Step 2: Resume with the real export**

After the user supplies the path, substitute it into:

```bash
bin/stage-athena /absolute/path/provided/by/user
bin/setup
bin/validate-setup
bin/setup
bin/validate-setup
```

Do not copy the user's actual path into tracked files. Expected: the second setup skips reload and leaves counts/version unchanged.

- [ ] **Step 3: Apply the verdict definitions**

Set `READY` only if all hold:

```text
host/Docker preflight passes
postgres is healthy on pinned Linux/amd64 and loopback-only
db_init is idempotent
the real staged manifest verifies
nine exported tables are populated
source_to_concept_map exists empty
five required vocabulary families have valid standard concepts
keys and lookup indexes exist
vocab_reader is read-only
ten omop_csv views work
omop_fhir has no vocabulary views
repeated setup preserves manifest, version, and counts
no secret or Athena file is tracked
```

Set `BLOCKED` only for external prerequisites: incomplete download/license, unavailable Docker/network approval, or insufficient disk. Record the exact resolution and resume command.

Set `FAILED` for implementation/validation defects: invalid files accepted, partial state exposed, incorrect permissions, missing required vocabularies in a claimed complete export, destructive rerun, or any failed readiness assertion.

- [ ] **Step 4: Record safe evidence**

Write `acceptance.txt` with exit statuses, image digest, PostgreSQL version, aggregate manifest checksum, vocabulary version, row counts, view/permission checks, rerun outcome, verdict, and next action. Include no credentials or vocabulary rows.

- [ ] **Step 5: Follow the verdict**

| Verdict | Mandatory next action |
|---|---|
| `READY` | Start `docs/superpowers/plans/2026-09-27-fhir-to-cdm-container-feasibility-spike.md` in a separate task and preserve setup state. |
| `BLOCKED` | Satisfy the external prerequisite and resume the setup skill; do not start the spike. |
| `FAILED` | Preserve logs/prior schema, fix under tests, and repeat real-data acceptance. |

- [ ] **Step 6: Run final checks**

```bash
git status --short
git diff --check
bash tests/setup/test_contract.sh
bash tests/setup/test_stage_athena.sh
bash tests/setup/test_compose_setup.sh
bash tests/setup/test_setup_skill.sh
bin/validate-setup
```

Expected: only ignored generated state exists, every test passes, and validation reports `READY`.

## Stop Rules

- Stop `BLOCKED` when real Athena data is unavailable; fixture tests do not authorize the spike.
- Stop before replacement until the user approves `--replace` after seeing current and candidate versions.
- Stop if a proposed solution would automate Athena login/license acceptance or commit/redistribute its data.
- Stop if the database platform or digest differs from the pinned contract.
- Stop on any manifest, header, load, index, permission, or vocabulary-family failure.
- Do not execute the FhirToCdm spike in the same task; `READY` is the handoff boundary.
