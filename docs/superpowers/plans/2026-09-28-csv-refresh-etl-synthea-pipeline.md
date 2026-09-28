# CSV Refresh ETL-Synthea Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the v1 load path: claim CSV batches, assemble the cumulative snapshot, run ETL-Synthea 2.1.1 once, and replace `omop_csv` clinical data with accept/reject batch accounting.

**Architecture:** A one-shot `etl_synthea` container (linux/amd64, R/Java ETL-Synthea 2.1.1) mounts `/data` and Postgres, claims `csv_input/inbox/<batch_id>/` → `pending/`, unions `success/`+`pending/` into `work/<refresh_id>/csv/` with one header per table, truncates `omop_csv` clinical tables (never the vocab views), runs the ETL once, then moves the refresh set to `success/` or `rejected/` with an error report. Results/temp schemas are dropped+recreated (DDL owned by the WebAPI plan; this plan calls its script if present, else truncates clinical only).

**Tech Stack:** Docker Compose, PostgreSQL 16.4, ETL-Synthea 2.1.1 (R + Java), OMOP CDM 5.3.1 DDL, POSIX shell, `psql`, Python 3 (CSV merge only).

**Spec:** `docs/intro.md` §§2, 5, 6, 8, 9, 10 (CSV branch, snapshot rebuilds, in-place maintenance refresh).

**File ownership (parallel agents):** this plan owns `docker/etl_synthea/`, `db/omop_csv/`,
`bin/refresh-csv`, `tests/csv_refresh/`. It must not edit `compose.yaml` beyond appending its
own `etl_synthea:` block, and must not touch `db/webapi/` (owned by the WebAPI plan — mount it
read-only, never copy or modify it) or any other plan's files.

## Global Constraints

- Pin ETL-Synthea `2.1.1`, Synthea `3.3.0`, OMOP CDM `5.3.1`; record URLs+SHA-256 in `docker/etl_synthea/PROVENANCE.md`.
- Converter runs once per refresh over the assembled snapshot, never once per batch.
- Clinical refresh preserves the `omop_csv` schema; `TRUNCATE ... RESTART IDENTITY CASCADE` on physical clinical/helper tables, excluding the ten vocabulary views. Recreate a table only when its DDL changes.
- Vocabulary views in `omop_csv` are never dropped here; ETL skips `LoadVocabFromSchema` and reads views.
- ETL role reads `athena_vocabs` via views but cannot write it (existing `vocab_reader`-style grants).
- Batch states are whole directories: `inbox → pending → success|rejected`; `success/` is immutable except by this job's atomic moves.
- `refresh-csv` stops WebAPI/MCP before clearing tables and restarts only after load+validation succeed; a failed refresh leaves tables unexposed until the operator reruns.
- `platform: linux/amd64`, loopback-only ports, no secrets in tracked files.

---

## Planned File Structure

```text
docker/etl_synthea/{Dockerfile,PROVENANCE.md,run.sh,assemble.py,clean.sql}
db/omop_csv/{clinical_tables.sql,PROVENANCE.md}
bin/refresh-csv
tests/csv_refresh/{test_assemble.sh,test_refresh_flow.sh,fixtures/csv-batch-a/,fixtures/csv-batch-b/}
```

`assemble.py` merges CSVs; `run.sh` owns claim→assemble→clean→etl→accept/reject; `clean.sql` truncates clinical tables; `clinical_tables.sql` is the CDM 5.3.1 physical-table surface minus the ten vocab relations.

---

### Task 1: CDM clinical-table DDL + truncate contract

**Files:**
- Create: `db/omop_csv/PROVENANCE.md`
- Create: `db/omop_csv/clinical_tables.sql`
- Create: `docker/etl_synthea/clean.sql`
- Create: `tests/csv_refresh/test_refresh_flow.sh` (skeleton, failing)

**Interfaces:**
- Consumes: `db/bootstrap/schemas.sql` (schemas exist), `db/athena/*` (ten vocab view names to exclude).
- Produces: `clean.sql` + table list consumed by Task 3.

- [ ] **Step 1: Write the failing test**

```bash
#!/bin/bash
# tests/csv_refresh/test_refresh_flow.sh — truncate keeps views, empties clinical.
set -eu
for f in db/omop_csv/clinical_tables.sql docker/etl_synthea/clean.sql docker/etl_synthea/run.sh bin/refresh-csv; do
  [ -f "$f" ] || { echo "FAIL: missing $f"; exit 1; }
done
grep -q "RESTART IDENTITY CASCADE" docker/etl_synthea/clean.sql || { echo "FAIL: clean.sql not truncate-based"; exit 1; }
for v in concept concept_ancestor concept_class concept_relationship concept_synonym domain drug_strength relationship source_to_concept_map vocabulary; do
  grep -q "$v" docker/etl_synthea/clean.sql && { echo "FAIL: clean.sql touches vocab $v"; exit 1; }
done
echo "PASS: refresh flow files"
```

Run: `bash tests/csv_refresh/test_refresh_flow.sh`
Expected: FAIL (files missing).

- [ ] **Step 2: Extract clinical-table DDL**

From OHDSI CommonDataModel `v5.3.1` `OMOP CDM postgresql ddl.txt` take every `CREATE TABLE` except the ten vocab relations (`concept`, `concept_ancestor`, `concept_class`, `concept_relationship`, `concept_synonym`, `domain`, `drug_strength`, `relationship`, `source_to_concept_map`, `vocabulary`). Qualify with `omop_csv.`, add `IF NOT EXISTS`-style idempotence via a `DO` guard or `CREATE TABLE IF NOT EXISTS`. Record source URL + SHA-256 (`1c3dfa74...` per setup plan) in `db/omop_csv/PROVENANCE.md`. Core tables include at minimum: `person`, `observation_period`, `visit_occurrence`, `condition_occurrence`, `drug_exposure`, `procedure_occurrence`, `device_exposure`, `measurement`, `observation`, `death`, `note`, `specimen`, `fact_relationship`, `location`, `care_site`, `provider`, `payer_plan_period`, `cost`, `drug_era`, `dose_era`, `condition_era`, `cdm_source`, plus ETL-Synthea helper tables it requires.

- [ ] **Step 3: Write `clean.sql`**

```sql
-- Truncate physical clinical/helper tables; vocabulary views untouched.
TRUNCATE
  omop_csv.person, omop_csv.observation_period, omop_csv.visit_occurrence,
  omop_csv.condition_occurrence, omop_csv.drug_exposure,
  omop_csv.procedure_occurrence, omop_csv.device_exposure,
  omop_csv.measurement, omop_csv.observation, omop_csv.death,
  omop_csv.note, omop_csv.specimen, omop_csv.fact_relationship,
  omop_csv.location, omop_csv.care_site, omop_csv.provider,
  omop_csv.payer_plan_period, omop_csv.cost, omop_csv.drug_era,
  omop_csv.dose_era, omop_csv.condition_era, omop_csv.cdm_source
  RESTART IDENTITY CASCADE;
```

Extend the list to exactly the tables in `clinical_tables.sql` (minus views). Never name a vocab relation.

- [ ] **Step 4: Commit DDL**

```bash
git add db/omop_csv tests/csv_refresh/test_refresh_flow.sh
git commit -m "build: define omop_csv clinical tables and truncate"
```

Expected: test still FAIL (run.sh missing) — correct.

### Task 2: Snapshot assembly (claim + union + manifest)

**Files:**
- Create: `docker/etl_synthea/assemble.py`
- Create: `tests/csv_refresh/test_assemble.sh`
- Create: `tests/csv_refresh/fixtures/csv-batch-a/patients.csv`
- Create: `tests/csv_refresh/fixtures/csv-batch-b/patients.csv`

**Interfaces:**
- Consumes: batch-ID regex + `batch.json` schema from the Synthea plan.
- Produces: `work/<refresh_id>/{manifest.json,csv/}` consumed by Task 3.

- [ ] **Step 1: Write fixtures + failing test**

`fixtures/csv-batch-a/patients.csv`:

```text
Id,BIRTHDATE,DEATHDATE,SSN,DRIVERS,PASSPORT,PREFIX,FIRST,LAST
a1,1970-01-01,,111-11-1111,X,,Mr,Al,A
```

`fixtures/csv-batch-b/patients.csv`: same header, one row with `Id=b1`.

Test (`tests/csv_refresh/test_assemble.sh`):

```bash
#!/bin/bash
set -eu
rm -rf /tmp/asm-test
mkdir -p /tmp/asm-test/success/a /tmp/asm-test/success/b /tmp/asm-test/pending
cp tests/csv_refresh/fixtures/csv-batch-a/patients.csv /tmp/asm-test/success/a/
cp tests/csv_refresh/fixtures/csv-batch-b/patients.csv /tmp/asm-test/success/b/
python3 docker/etl_synthea/assemble.py /tmp/asm-test/success /tmp/asm-test/pending /tmp/asm-test/out
[ "$(grep -c '^' /tmp/asm-test/out/patients.csv)" -eq 3 ] || { echo "FAIL: header+2 rows expected"; exit 1; }
head -1 /tmp/asm-test/out/patients.csv | grep -q "^Id," || { echo "FAIL: single header"; exit 1; }
echo "PASS: assemble"
```

Run: `bash tests/csv_refresh/test_assemble.sh`
Expected: FAIL (`assemble.py` missing).

- [ ] **Step 2: Implement `assemble.py`**

```python
#!/usr/bin/env python3
"""Union CSV batches: one header per table, dedupe shared reference rows."""
import csv, sys
from pathlib import Path
success, pending, out = map(Path, sys.argv[1:4])
out.mkdir(parents=True, exist_ok=True)
tables: dict[str, list[Path]] = {}
for root in [success, pending]:
    if not root.exists():
        continue
    for batch in sorted(root.iterdir()):
        if not batch.is_dir():
            continue
        for f in sorted(batch.glob("*.csv")):
            tables.setdefault(f.name, []).append(f)
for name, files in tables.items():
    header = None
    seen = set()
    with open(out / name, "w", newline="") as outf:
        w = None
        for f in files:
            with open(f, newline="") as inf:
                r = csv.reader(inf)
                h = next(r)
                if header is None:
                    header = h
                    w = csv.writer(outf)
                    w.writerow(header)
                elif h != header:
                    raise SystemExit(f"header mismatch in {f}")
                for row in r:
                    key = (name, tuple(row))
                    if key not in seen:  # dedupes shared reference entities
                        seen.add(key)
                        w.writerow(row)
print(f"ASSEMBLED {len(tables)} tables")
```

- [ ] **Step 3: Run and commit**

```bash
bash tests/csv_refresh/test_assemble.sh
git add docker/etl_synthea/assemble.py tests/csv_refresh/
git commit -m "feat: assemble cumulative csv snapshot"
```

Expected: PASS.

### Task 3: `run.sh` (claim → load → accept/reject) + compose + `bin/refresh-csv`

**Files:**
- Create: `docker/etl_synthea/Dockerfile`
- Create: `docker/etl_synthea/PROVENANCE.md`
- Create: `docker/etl_synthea/run.sh`
- Create: `bin/refresh-csv`
- Modify: `compose.yaml` (add `etl_synthea` service)

**Interfaces:**
- Consumes: `assemble.py`, `clean.sql`, `clinical_tables.sql`, WebAPI results-recreate script if present (owned by the WebAPI plan; mounted read-only at `/webapi`, called only if executable).
- Produces: populated `omop_csv`, `success/`/`rejected/` accounting with `error.json` reports, `work/<refresh_id>/manifest.json`.

- [ ] **Step 1: Write the Dockerfile**

```dockerfile
# Pin the base-image digest at implementation time.
FROM rocker/r-ver:4.3.3
RUN apt-get update && apt-get install -y --no-install-recommends openjdk-17-jre-headless postgresql-client python3 openssl \
 && rm -rf /var/lib/apt/lists/*
ARG ETLSYNTHEA_VERSION=2.1.1
# Resolve the real SHA at implementation time and pin it here:
# curl -sL https://github.com/OHDSI/ETL-Synthea/archive/refs/tags/v2.1.1.tar.gz | sha256sum
ARG ETLSYNTHEA_SHA256
ADD https://github.com/OHDSI/ETL-Synthea/archive/refs/tags/v${ETLSYNTHEA_VERSION}.tar.gz /opt/etl-synthea.tar.gz
RUN echo "${ETLSYNTHEA_SHA256}  /opt/etl-synthea.tar.gz" | sha256sum -c - \
 && mkdir -p /opt/etl-synthea && tar xzf /opt/etl-synthea.tar.gz -C /opt/etl-synthea --strip-components=1
COPY run.sh assemble.py clean.sql /opt/etl-synthea/job/
ENTRYPOINT ["/opt/etl-synthea/job/run.sh"]
```

Record the download URL plus the SHA-256 computed with the command in the Dockerfile in PROVENANCE.md (build fails without a pinned value).

- [ ] **Step 2: Write `run.sh`**

```bash
#!/bin/bash
# run.sh [batch_id...] — empty args = all of inbox/. One invocation per refresh.
set -eu
: "${PGHOST:=postgres}" "${PGPORT:=5432}" "${PGUSER:=${POSTGRES_USER:-postgres}}"
: "${PGDATABASE:=${POSTGRES_DB:-fhir_omop_mcp_hub}}" "${POSTGRES_PASSWORD_FILE:=/run/secrets/postgres_password}"
export PGHOST PGPORT PGUSER PGDATABASE
PGPASSWORD="$(cat "$POSTGRES_PASSWORD_FILE")"; export PGPASSWORD
INBOX=/data/csv_input/inbox; PEND=/data/csv_input/pending; OKDIR=/data/csv_input/success; BAD=/data/csv_input/rejected
RID="$(date -u +%Y%m%d-%H%M%S)-$(openssl rand -hex 4)"; WORK="/data/work/$RID"
mkdir -p "$WORK/csv" "$WORK/fhir" "$WORK/generated_cdm" "$PEND" "$OKDIR" "$BAD"
IDS="${*:-$(ls "$INBOX" 2>/dev/null || true)}"
[ -n "$IDS" ] || { echo "NOOP: inbox empty"; exit 0; }
for b in $IDS; do
  case "$b" in ????-??????-????????) ;; *) echo "REFRESH_FAILED: invalid batch id '$b'" >&2; exit 1;; esac
  [ -d "$INBOX/$b" ] || { echo "REFRESH_FAILED: batch '$b' not in inbox" >&2; exit 1; }
done
for b in $IDS; do mv "$INBOX/$b" "$PEND/$b"; done
python3 /opt/etl-synthea/job/assemble.py "$OKDIR" "$PEND" "$WORK/csv"
printf '{"refresh_id":"%s","batches":[%s],"at_utc":"%s"}\n' "$RID" \
  "$(for b in $IDS; do printf '"%s",' "$b"; done | sed 's/,$//')" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$WORK/manifest.json"
psql -v ON_ERROR_STOP=1 -f /db-omop-csv/clinical_tables.sql
psql -v ON_ERROR_STOP=1 -f /opt/etl-synthea/job/clean.sql
if [ -x /webapi/recreate_results.sh ]; then /webapi/recreate_results.sh omop_csv; fi
set +e
Rscript -e "ETLSynthea::RunETLSynthea(...)"
STATUS=$?; set -e
if [ "$STATUS" -eq 0 ]; then for b in $IDS; do mv "$PEND/$b" "$OKDIR/$b"; done; echo "REFRESH_OK $RID"
else for b in $IDS; do R="$BAD/$b"; rm -rf "$R"; mv "$PEND/$b" "$R"
  printf '{"batch_id":"%s","refresh_id":"%s","exit":%s,"at_utc":"%s"}\n' "$b" "$RID" "$STATUS" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$R/error.json"
done; echo "REFRESH_FAILED $RID" >&2; exit 1; fi
```

The `Rscript` line above is a placeholder for the exact ETL-Synthea 2.1.1 invocation: take it
verbatim from the 2.1.1 README / `?ETLSynthea::RunETLSynthea` help (DB connection to `omop_csv`,
vocabulary via the `omop_csv` views, `cdmVersion='5.3.1'`, `syntheaVersion='3.3.0'`, skip
`LoadVocabFromSchema`) and record the final command in PROVENANCE.md. Failed batches keep input
+ `error.json` under `rejected/`. `clinical_tables.sql` uses `CREATE TABLE IF NOT EXISTS`, so
applying it on every refresh is idempotent. `/db-omop-csv` and `/webapi` are read-only mounts
(see compose below); `recreate_results.sh` is owned by the WebAPI plan and only called if present.

- [ ] **Step 3: Add compose service + `bin/refresh-csv`**

```yaml
  etl_synthea:
    build: ./docker/etl_synthea
    platform: linux/amd64
    depends_on:
      postgres: {condition: service_healthy}
      db_init: {condition: service_completed_successfully}
    volumes:
      - ${DATA_ROOT:-./data}:/data
      - ./db/omop_csv:/db-omop-csv:ro
      - ./db/webapi:/webapi:ro
    secrets: [postgres_password]
    restart: "no"
```

No `env_file` (consistent with existing services). Read-only mounts give `run.sh` the
versioned DDL and the WebAPI plan's recreate script without cross-plan file copies.

`bin/refresh-csv`: stop `mcp_server`+`ohdsi_webapi` if running, `compose run --rm etl_synthea "$@"`, restart on success only, propagate exit code. Make executable.

- [ ] **Step 4: Verify and commit**

```bash
bash tests/csv_refresh/test_assemble.sh && bash tests/csv_refresh/test_refresh_flow.sh
docker compose build etl_synthea
git add docker/etl_synthea compose.yaml bin/refresh-csv
git commit -m "feat: add csv refresh etl-synthea pipeline"
```

Expected: image builds; flow test passes; live load verified by the operator-UX plan's end-to-end test (not here).

## Stop Rules

- Stop if ETL-Synthea 2.1.1 CLI differs from assumed — use its README/`?RunETLSynthea` help, record real invocation, do not invent flags.
- Stop before dropping the `omop_csv` schema or any vocab view — truncate clinical tables only.
- Stop on partial accept (some batches moved, some not) — the whole refresh set moves to exactly one of `success/`/`rejected/` per run.
