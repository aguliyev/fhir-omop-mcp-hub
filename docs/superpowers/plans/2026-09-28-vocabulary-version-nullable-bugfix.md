# `vocabulary_version` Nullability Bugfix Implementation Plan

**Outcome (2026-09-28):** Tasks 1-2 are committed: nullable DDL, provenance,
and fixture regression coverage exist. Task 3 is a separate, approval-gated
real-Athena replacement; do not rerun it automatically. Its absolute download
and temporary merge paths describe the original local environment, not portable
instructions; obtain the operator's actual source path and explicit approval
before staging/replacing any live vocabulary.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Athena vocabulary load accept real Athena exports by allowing `NULL` in `athena_vocabs.vocabulary.vocabulary_version`, with regression coverage.

**Architecture:** One-column DDL relaxation (`NOT NULL` → `NULL`) recorded as a documented local adaptation in `db/athena/PROVENANCE.md`, plus a real-shaped fixture row (empty-version `Cohort Type`) so the existing Compose integration test guards the fix. No loader, staging, validation, or view changes: `NULL` flows through `\copy`, views, and `validate.sql` untouched.

**Tech Stack:** PostgreSQL 16.4 Alpine (`docker.io/library/postgres:16.4-alpine@sha256:5660c2cbfea50c7a9127d17dc4e48543eedd3d7a41a595a2dfa572471e37e64c`), POSIX shell test scripts in `tests/setup/`, OMOP CDM v5.3.1 vocabulary DDL.

**Spec:** `docs/superpowers/plans/2026-09-27-local-setup-and-athena-bootstrap.md` (Tasks 4 and 8) and `db/athena/PROVENANCE.md`. This plan argues from both; executors read all three.

## Global Constraints

- Pin `docker.io/library/postgres:16.4-alpine@sha256:5660c2cbfea50c7a9127d17dc4e48543eedd3d7a41a595a2dfa572471e37e64c` and `platform: linux/amd64`.
- Bind PostgreSQL to `127.0.0.1`, never `0.0.0.0` (tests use port `55433`).
- Never automate Athena login/license acceptance, request credentials, or commit/redistribute vocabulary files.
- Keep the nine-file Athena contract: `CONCEPT.csv`, `CONCEPT_ANCESTOR.csv`, `CONCEPT_CLASS.csv`, `CONCEPT_RELATIONSHIP.csv`, `CONCEPT_SYNONYM.csv`, `DOMAIN.csv`, `DRUG_STRENGTH.csv`, `RELATIONSHIP.csv`, `VOCABULARY.csv`; never require `SOURCE_TO_CONCEPT_MAP.csv`.
- Keep upstream DDL/index meaning except adaptations documented in `db/athena/PROVENANCE.md`; every new deviation must be recorded there.
- A vocabulary replacement requires explicit user approval, an advisory lock, and one database transaction so failure preserves the prior schema (already owned by `db/athena/load.sh` / `bin/load-vocab`; this plan adds no bypass).
- Never write placeholder or synthetic versions into staged/loaded vocabulary data as a fix; the dev-only `DEV-PLACEHOLDER` rows in the current live schema are removed by the Task 3 reload.
- Never commit Athena archives/CSVs, PostgreSQL state, generated secrets, or generated setup evidence (`data/`, `etc/setup.env`, `.env` stay ignored and untracked).

---

## The bug

**Symptom.** `bin/setup` → `bin/load-vocab` fails inside the one-shot `athena_vocabs` transaction (log: `data/work/setup/load-vocab-20260928T004101Z.log`):

```text
COPY 2440270
psql:/tmp/athena_load.DeiAdm:105: ERROR:  null value in column "vocabulary_version" of relation "vocabulary" violates not-null constraint
DETAIL:  Failing row contains (Cohort Type, OMOP Cohort Type, OMOP generated, null, 44819234).
CONTEXT:  COPY vocabulary, line 4: "Cohort Type	OMOP Cohort Type	OMOP generated		44819234"
ERROR: load transaction failed; prior schema preserved
```

**Root cause (verified 2026-09-28).** Three facts combine:

1. Real Athena `VOCABULARY.csv` ships an **empty** `vocabulary_version` for OMOP-generated vocabularies (Cohort Type, Concept Class, Condition Status, UB04 entries, … — 27 such rows in the 2026-09 exports; the identical empty row is byte-present in all four per-domain downloads, so an official single-bundle export carries the same empties and **re-downloading cannot fix this**).
2. `db/athena/load.sh` loads with `\copy ... WITH (FORMAT csv, HEADER true, DELIMITER E'\t', QUOTE E'\b')` (same settings as the upstream 2014 vocabulary loader). In `COPY ... CSV` an unquoted empty field becomes `NULL`.
3. `db/athena/create_tables.sql:23` declares `vocabulary_version VARCHAR(255) NOT NULL`, copied verbatim from upstream OMOP CDM v5.3.1 DDL (verified against `https://raw.githubusercontent.com/OHDSI/CommonDataModel/v5.3.1/PostgreSQL/OMOP%20CDM%20postgresql%20ddl.txt`, whose `vocabulary` table also says `NOT NULL`). Upstream's 2014-era vocabulary zip predates these empty-version rows, so the verbatim pipeline breaks on today's Athena output.

**Why tests never caught it.** `tests/setup/fixtures/athena-valid/VOCABULARY.csv` contains exactly five rows (CVX, LOINC, RxNorm, SNOMED, UCUM), all with `2024-01-01` versions — no empty-version row exists anywhere in test data.

**Fix chosen (laziest correct option).** Relax the column to `NULL` and document it as local adaptation 6 in `PROVENANCE.md`. Rejected alternatives: loader-side `COALESCE`/placeholder (falsifies vocabulary data), stage-time fill of empties (same falsification, plus touches the staging contract), keeping `NOT NULL` (permanently incompatible with real Athena data).

## Planned File Structure

```text
Modify: db/athena/create_tables.sql          # one line: vocabulary_version NULL
Modify: db/athena/PROVENANCE.md              # adaptation 6: why we deviate
Modify: tests/setup/fixtures/athena-valid/VOCABULARY.csv  # real-shaped empty-version row
Modify: tests/setup/test_compose_setup.sh    # assert empty version loads as NULL
```

Each file keeps its current responsibility; no new files. The fixture stays minimal (one added row), the test keeps its existing structure (one added assertion next to the other vocabulary checks).

---

### Task 1: Reproduce with a real-shaped fixture row

**Files:**
- Modify: `tests/setup/fixtures/athena-valid/VOCABULARY.csv`
- Modify: `tests/setup/test_compose_setup.sh`

**Interfaces:**
- Consumes: existing `test_compose_setup.sh` fixture staging (lines 86–99: copies `fixtures/athena-valid/*.csv` to `$SRC1`, appends family concept rows, runs `stage-athena` then `load-vocab`).
- Produces: a failing `initial load` caused by the `NULL` violation (proves the reproduction), then the regression assertion Task 2 must turn green.

- [ ] **Step 1: Add the real-shaped empty-version row to the fixture**

Append exactly this tab-delimited line (empty 4th field mirrors the real `Cohort Type` row):

```bash
printf 'Cohort Type\tOMOP Cohort Type\tOMOP generated\t\t44819234\n' >> tests/setup/fixtures/athena-valid/VOCABULARY.csv
```

- [ ] **Step 2: Add the NULL-version assertion to the integration test**

Insert after the `concept rows=$N1` check (line 102), before the view loop (line 104):

```bash
[ -z "$(dbq "SELECT coalesce(vocabulary_version,'') FROM athena_vocabs.vocabulary WHERE vocabulary_id='Cohort Type';" | tr -d ' \r\n')" ] && ok "empty upstream version loads as NULL" || bad "empty upstream version loads as NULL"
```

- [ ] **Step 3: Run the integration test to confirm it fails on the bug**

```bash
bash tests/setup/test_compose_setup.sh
```

Expected: `FAIL: initial load`, and the sanitized load log named in the output contains `null value in column "vocabulary_version"`. All checks after `initial load` cascade-fail; that is the reproduction, not a regression.

- [ ] **Step 4: Commit the reproduction**

```bash
git add tests/setup/fixtures/athena-valid/VOCABULARY.csv tests/setup/test_compose_setup.sh
git commit -m "test: reproduce empty vocabulary_version load failure"
```

### Task 2: Relax the column and document the deviation

**Files:**
- Modify: `db/athena/create_tables.sql:23`
- Modify: `db/athena/PROVENANCE.md`

**Interfaces:**
- Consumes: failing assertion from Task 1.
- Produces: `initial load` and `empty upstream version loads as NULL` green; `validate.sql`, views, and indexes untouched (`SELECT *` views and version display pass `NULL` through).

- [ ] **Step 1: Make `vocabulary_version` nullable**

In `db/athena/create_tables.sql`, replace:

```sql
  vocabulary_version VARCHAR(255) NOT NULL,
```

with:

```sql
  vocabulary_version VARCHAR(255) NULL,
```

Nothing else in the file changes. `validate.sql` needs no edit: its success report selects `vocabulary_version` without a nullability assumption, and its family checks match on `vocabulary_id`, not version.

- [ ] **Step 2: Record local adaptation 6 in PROVENANCE.md**

Append to the `## Local adaptations` list (after item 5, before `## Aggregate checksum convention`):

```markdown
6. **`vocabulary_version` is nullable.** Upstream declares it `NOT NULL`,
   but real Athena exports ship an empty `vocabulary_version` for
   OMOP-generated vocabularies (e.g. Cohort Type, Concept Class, UB04
   entries — 27 such rows in September 2026 exports), and `COPY ... CSV`
   maps the unquoted empty field to `NULL`, so a verbatim schema rejects
   real data (`null value in column "vocabulary_version" violates
   not-null constraint`). The column is relaxed to `NULL`; views
   (`SELECT *`) and `validate.sql` pass it through unchanged.
```

- [ ] **Step 3: Run the integration test to confirm the fix**

```bash
bash tests/setup/test_compose_setup.sh
```

Expected: `compose-setup: PASSED`, including `PASS: initial load` and `PASS: empty upstream version loads as NULL`. The malformed-replacement rollback and `--replace` guard checks must still pass unchanged.

- [ ] **Step 4: Commit the fix**

```bash
git add db/athena/create_tables.sql db/athena/PROVENANCE.md tests/setup/fixtures/athena-valid/VOCABULARY.csv tests/setup/test_compose_setup.sh
git commit -m "fix: allow NULL vocabulary_version for real Athena exports"
```

### Task 3: Full suite and real-data acceptance

**Files:**
- No tracked-file changes. Generated state only: re-staged Athena input under ignored `data/`, reloaded live schema, `data/work/setup/ready.env`.

**Interfaces:**
- Consumes: fixed loader from Task 2, unpatched real data (merged per-domain source rebuilt without placeholders).
- Produces: `READY` against real data with zero `DEV-PLACEHOLDER` versions; prior placeholder rows purged by the transactional replace.

- [ ] **Step 1: Run the full setup test suite**

```bash
bash tests/setup/test_contract.sh
bash tests/setup/test_stage_athena.sh
bash tests/setup/test_compose_setup.sh
bash tests/setup/test_setup_skill.sh
bash tests/setup/test_lifecycle.sh
```

Expected: every script prints its `PASSED` line. (`test_compose_setup.sh` re-runs the Task 2 green result; the rest prove no collateral damage.)

- [ ] **Step 2: Rebuild the real-data merge without placeholders**

Regenerate `/tmp/kilo/athena-merged-dev` from `/home/anar/Downloads/athena` (CVX, LOINC, RxNorm, SNOMED) by full-line-dedup union of the nine required files, exactly as done for the dev load, but do **not** fill any empty `vocabulary_version`. Verify the merge still carries the 27 real empties and a unique `concept_id` key:

```bash
python3 -c "
import csv
p='/tmp/kilo/athena-merged-dev/VOCABULARY.csv'
rows=list(csv.DictReader(open(p, encoding='utf-8'), delimiter='\t'))
print('empty versions:', sum(1 for r in rows if r['vocabulary_version']==''))
print('has placeholder:', any('DEV-PLACEHOLDER' in r['vocabulary_version'] for r in rows))
"
```

Expected: `empty versions: 27`, `has placeholder: False`.

- [ ] **Step 3: Show versions and obtain approval before `--replace`**

Print current live vs staged versions (stop rule: never pass `--replace` without explicit user approval after the user sees both):

```bash
bin/compose exec -T postgres psql -U postgres -d fhir_omop_mcp_hub -tAc "SELECT string_agg(DISTINCT vocabulary_version, ' | ' ORDER BY vocabulary_version) FROM athena_vocabs.vocabulary;"
awk -F'\t' 'NR>1{print $1": "$4}' /tmp/kilo/athena-merged-dev/VOCABULARY.csv | LC_ALL=C sort -u
```

Then stage only after the user replies YES:

```bash
bin/stage-athena /tmp/kilo/athena-merged-dev --replace
bin/setup
bin/validate-setup
```

Expected: `LOAD_OK`, `VALIDATION=PASSED`, `READY postgres=16.4 ...`. The transactional replace rolls the placeholder-loaded schema away; nothing of the old load survives a successful commit.

- [ ] **Step 4: Prove no placeholder survives and versions are real**

```bash
bin/compose exec -T postgres psql -U postgres -d fhir_omop_mcp_hub -tAc "SELECT count(*) FROM athena_vocabs.vocabulary WHERE vocabulary_version LIKE 'DEV-PLACEHOLDER%';"
bin/compose exec -T postgres psql -U postgres -d fhir_omop_mcp_hub -tAc "SELECT count(*) FROM athena_vocabs.vocabulary WHERE vocabulary_version IS NULL;"
bin/compose exec -T postgres psql -U postgres -d fhir_omop_mcp_hub -tAc "SELECT count(*) FROM athena_vocabs.concept WHERE vocabulary_id='SNOMED' AND standard_concept='S' AND invalid_reason IS NULL;"
```

Expected: `0`, `27`, and a nonzero SNOMED count (`356613` for the current exports). First number proves the dev placeholder is purged; second proves the fix (real `NULL`s live in the table); third proves SNOMED survived the reload.

- [ ] **Step 5: Confirm clean git state**

```bash
git status --short
git diff --check
git check-ignore data etc/setup.env .env
```

Expected: no output from `git status --short` except possibly untracked plan-doc work (this file); `git diff --check` clean; all three generated paths ignored. The user's original downloads and `/tmp` merge source must never appear in any tracked file.
