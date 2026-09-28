# CSV Refresh ETL-Synthea Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the v1 load path: claim CSV batches, assemble the cumulative snapshot, run ETL-Synthea 2.1.1 once, and replace `omop_csv` clinical data with accept/reject batch accounting.

**Architecture:** A one-shot `etl_synthea` container (linux/amd64, R/Java ETL-Synthea 2.1.1) locks the CSV queue, verifies batch manifests and file checksums, claims selected inbox batches, and assembles the complete `success/` + new `pending/` snapshot. It records the full selection and assembled hashes, invalidates results/temp with the WebAPI plan's required script, rebuilds clinical data once, validates, then accepts or rejects the new set. `--rebuild-accepted` explicitly restores only the last accepted snapshot after failure; WebAPI/MCP stay stopped until validation succeeds.

**Tech Stack:** Docker Compose, PostgreSQL 16.4, ETL-Synthea 2.1.1 (R + Java), OMOP CDM 5.3.1 DDL, POSIX shell, `psql`, Python 3 (CSV merge only).

**Spec:** `docs/intro.md` §§2, 5, 6, 8, 9, 10 (CSV branch, snapshot rebuilds, in-place maintenance refresh).

**File ownership:** this plan owns `docker/etl_synthea/`, `db/omop_csv/`,
`bin/refresh-csv`, `tests/csv_refresh/`, plus the coordinated ETL-role additions
to `db/bootstrap/`, `bin/prepare-data`, and Compose's secret definition.
Do not edit `db/webapi/` (owned by the WebAPI plan — mount it read-only), or
replace another plan's service block. Apply shared-file changes sequentially,
not concurrently with WebAPI or operator plan edits.

## Global Constraints

- Pin ETL-Synthea `2.1.1`, Synthea `3.3.0`, OMOP CDM `5.3.1`; record URLs+SHA-256 in `docker/etl_synthea/PROVENANCE.md`.
- Converter runs once per refresh over the assembled snapshot, never once per batch.
- Clinical refresh preserves the `omop_csv` schema; `TRUNCATE ... RESTART IDENTITY CASCADE` on physical clinical/helper tables, excluding the ten vocabulary views. Recreate a table only when its DDL changes.
- Vocabulary views in `omop_csv` are never dropped here; ETL skips `LoadVocabFromSchema` and reads views.
- The R ETL runs with a dedicated login role permitted to write `omop_csv` clinical tables and read vocabulary views, but not write `athena_vocabs`; `vocab_reader` is NOLOGIN, and running the R ETL as `postgres` superuser does **not** satisfy this constraint. Admin-only table/results maintenance may use the existing Postgres secret. Task 1 must arrange role, grants, and a separate ignored ETL secret with the setup owner before a live load.
- Batch states are whole directories: `inbox → pending → success|rejected`; `success/` is immutable and its manifest/checksums are rechecked before every load.
- `refresh-csv` stops WebAPI/MCP before clearing tables and restarts only after load+validation succeed; a failed refresh leaves tables unexposed until the operator reruns.
- Require the WebAPI plan's results-recreation script before any destructive clinical step; never skip it when missing. Serialize refresh and accepted-only recovery with one advisory file lock, and fail visibly on pre-existing `pending/` work (manual recovery only in v1).
- `platform: linux/amd64`, loopback-only ports, no secrets in tracked files.

---

## Planned File Structure

```text
docker/etl_synthea/{Dockerfile,PROVENANCE.md,run.sh,run_etl.R,assemble.py,clean.sql}
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
- Modify: `db/bootstrap/schemas.sql`, `db/bootstrap/run.sh` (dedicated ETL login/grants provisioned using the separate secret)
- Modify: `bin/prepare-data` and `compose.yaml` secrets (create separate ignored ETL password; coordinate with setup owner)

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

Provision `etl_loader` as a login role from an ignored `/run/secrets/etl_password`, grant only the required `omop_csv` schema/table write permissions and vocabulary-view reads, and add an integration assertion that writes to `athena_vocabs` are denied. Extend `bin/prepare-data` to generate that secret mode `0600` without printing it; wire it to `db_init` and `etl_synthea` through Compose. The admin role still runs clinical DDL and results resets. Do not store the ETL password in a tracked SQL file or a command-line argument.

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

Extend the list to **every** physical table in `clinical_tables.sql`, including ETL helpers; never name a vocabulary view. Add a test comparing both complete table-name sets, not just checking that views are absent. `CREATE TABLE IF NOT EXISTS` does not apply later column changes: stop if the pinned CDM/ETL DDL changes until a deliberate migration or table recreation is documented.

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
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/success/20260928-014500-ab12cd34" "$TMP/pending/20260928-014501-ab12cd35"
cp tests/csv_refresh/fixtures/csv-batch-a/patients.csv "$TMP/success/20260928-014500-ab12cd34/"
cp tests/csv_refresh/fixtures/csv-batch-b/patients.csv "$TMP/pending/20260928-014501-ab12cd35/"
for batch in "$TMP"/success/* "$TMP"/pending/*; do
  (cd "$batch" && sha256sum patients.csv > files.sha256)
  printf '{"batch_id":"%s","synthea_version":"3.3.0","seed":12345,"population":1,"generated_at_utc":"2026-09-28T01:45:00Z","csv_files":["patients.csv"],"fhir_files":[]}' "${batch##*/}" > "$batch/batch.json"
done
python3 docker/etl_synthea/assemble.py "$TMP/success" "$TMP/pending" "$TMP/out"
[ "$(grep -c '^' "$TMP/out/patients.csv")" -eq 3 ] || { echo "FAIL: header+2 rows expected"; exit 1; }
grep -q '^Id,' "$TMP/out/patients.csv" || { echo "FAIL: single header"; exit 1; }
echo "PASS: assemble"
```

Run: `bash tests/csv_refresh/test_assemble.sh`
Expected: FAIL (`assemble.py` missing).

- [ ] **Step 2: Implement `assemble.py`**

```python
#!/usr/bin/env python3
"""Union verified CSV batches: one header per table; dedupe shared references."""
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
                    if name not in {"organizations.csv", "providers.csv", "payers.csv"} or key not in seen:
                        seen.add(key)
                        w.writerow(row)
print(f"ASSEMBLED {len(tables)} tables")
```

Before any output is assembled, require every selected batch directory name to match `^[0-9]{8}-[0-9]{6}-[0-9a-f]{8}$`, validate `batch.json` ID/seed/population and file inventory, and verify `files.sha256` against the actual regular CSV files. Reject tampered `success/` data without deleting it; verify reference-table duplicate IDs agree on all fields rather than silently keeping inconsistent organizations/providers/payers. Return sorted batch IDs and SHA-256 of each assembled CSV to the refresh manifest. The example loop above is only the merge core; implement these validations before calling it. Test corrupt checksums, duplicate conflicting reference IDs, mismatched headers and accepted-plus-new union.

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
- Create: `docker/etl_synthea/run_etl.R` (verified ETL-Synthea 2.1.1 invocation)
- Create: `bin/refresh-csv`
- Modify: `compose.yaml` (add `etl_synthea` service)

**Interfaces:**
- Consumes: `assemble.py`, `clean.sql`, `clinical_tables.sql`, the required WebAPI results-recreate script, and post-registration WebAPI readiness from the WebAPI plan.
- Produces: populated `omop_csv`, `success/`/`rejected/` accounting with `error.json` reports, `work/<refresh_id>/manifest.json`.

- [ ] **Step 1: Write the Dockerfile**

```dockerfile
# Pin the base-image digest at implementation time.
FROM rocker/r-ver:4.3.3
RUN apt-get update && apt-get install -y --no-install-recommends openjdk-17-jre-headless postgresql-client python3 openssl util-linux \
 && rm -rf /var/lib/apt/lists/*
ARG ETLSYNTHEA_VERSION=2.1.1
# Resolve the real SHA at implementation time and pin it here:
# curl -sL https://github.com/OHDSI/ETL-Synthea/archive/refs/tags/v2.1.1.tar.gz | sha256sum
ARG ETLSYNTHEA_SHA256
ADD https://github.com/OHDSI/ETL-Synthea/archive/refs/tags/v${ETLSYNTHEA_VERSION}.tar.gz /opt/etl-synthea.tar.gz
RUN echo "${ETLSYNTHEA_SHA256}  /opt/etl-synthea.tar.gz" | sha256sum -c - \
 && mkdir -p /opt/etl-synthea && tar xzf /opt/etl-synthea.tar.gz -C /opt/etl-synthea --strip-components=1
COPY run.sh run_etl.R assemble.py clean.sql /opt/etl-synthea/job/
ENTRYPOINT ["/opt/etl-synthea/job/run.sh"]
```

Record the download URL plus the SHA-256 computed with the command in the Dockerfile in PROVENANCE.md (build fails without a pinned value).

- [ ] **Step 2: Write `run.sh`**

```bash
#!/bin/bash
# run.sh [batch_id...] | --rebuild-accepted. One invocation per snapshot.
set -eu
: "${PGHOST:=postgres}" "${PGPORT:=5432}" "${PGUSER:=${POSTGRES_USER:-postgres}}"
: "${PGDATABASE:=${POSTGRES_DB:-fhir_omop_mcp_hub}}" "${POSTGRES_PASSWORD_FILE:=/run/secrets/postgres_password}"
export PGHOST PGPORT PGUSER PGDATABASE
PGPASSWORD="$(cat "$POSTGRES_PASSWORD_FILE")"; export PGPASSWORD
INBOX=/data/csv_input/inbox; PEND=/data/csv_input/pending; OKDIR=/data/csv_input/success; BAD=/data/csv_input/rejected
mkdir -p "$PEND" "$OKDIR" "$BAD"
exec 9>/data/csv_input/.refresh.lock
flock -n 9 || { echo "REFRESH_FAILED: another refresh is active" >&2; exit 1; }
[ -z "$(ls -A "$PEND")" ] || { echo "REFRESH_FAILED: abandoned pending batches need manual review" >&2; exit 1; }
MODE=normal
if [ "${1:-}" = --rebuild-accepted ]; then
  [ "$#" -eq 1 ] || exit 2
  MODE=recovery; shift
  [ -n "$(ls -A "$OKDIR")" ] || { echo "REFRESH_FAILED: no accepted snapshot" >&2; exit 1; }
fi
RID="$(date -u +%Y%m%d-%H%M%S)-$(openssl rand -hex 4)"; WORK="/data/work/$RID"
mkdir -p "$WORK/csv" "$PEND" "$OKDIR" "$BAD"
IDS="${*:-$(ls "$INBOX" 2>/dev/null || true)}"
[ "$MODE" != recovery ] || IDS=
[ -n "$IDS" ] || [ "$MODE" = recovery ] || { echo "NOOP: inbox empty"; exit 0; }
[ -x /webapi/recreate_results.sh ] || { echo "REFRESH_FAILED: results reset unavailable" >&2; exit 1; }
for b in $IDS; do
  case "$b" in ????????-??????-????????) ;; *) echo "REFRESH_FAILED: invalid batch id '$b'" >&2; exit 1;; esac
  [ -d "$INBOX/$b" ] || { echo "REFRESH_FAILED: batch '$b' not in inbox" >&2; exit 1; }
  [ ! -e "$BAD/$b" ] && [ ! -e "$OKDIR/$b" ] || { echo "REFRESH_FAILED: duplicate batch '$b'" >&2; exit 1; }
done
STAGE=claim
on_exit() {
  status=$?
  trap - EXIT
  [ "$status" -eq 0 ] && return
  for b in $IDS; do
    if [ -d "$PEND/$b" ]; then
      [ ! -e "$BAD/$b" ] || { echo "REFRESH_FAILED: rejected path exists for $b" >&2; continue; }
      mv -T "$PEND/$b" "$BAD/$b"
      printf '{"batch_id":"%s","refresh_id":"%s","stage":"%s","exit":%s,"manifest":"%s"}\n' \
        "$b" "$RID" "$STAGE" "$status" "$WORK/manifest.json" > "$BAD/$b/error.json"
    fi
  done
  exit "$status"
}
trap on_exit EXIT
for b in $IDS; do mv "$INBOX/$b" "$PEND/$b"; done
STAGE=assemble
python3 /opt/etl-synthea/job/assemble.py "$OKDIR" "$PEND" "$WORK/csv"
python3 - "$RID" "$WORK" "$OKDIR" "$PEND" <<'PY'
import datetime, hashlib, json, pathlib, sys
rid, work, accepted, pending = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), pathlib.Path(sys.argv[4])
old_ids = sorted(p.name for p in accepted.iterdir() if p.is_dir())
new_ids = sorted(p.name for p in pending.iterdir() if p.is_dir())
def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()
staged = pathlib.Path('/data/athena_input/current/manifest.sha256')
manifest = {'refresh_id': rid, 'at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'accepted_batch_ids': old_ids, 'new_batch_ids': new_ids, 'snapshot_batch_ids': old_ids + new_ids,
    'synthea_version': '3.3.0', 'etl_synthea_version': '2.1.1', 'cdm_version': '5.3.1',
    'athena_manifest_sha256': sha(staged),
    'assembled_sha256': {p.name: sha(p) for p in sorted((work / 'csv').glob('*.csv'))}}
(work / 'manifest.json').write_text(json.dumps(manifest, sort_keys=True) + '\n')
PY
STAGE=clean
psql -v ON_ERROR_STOP=1 -f /db-omop-csv/clinical_tables.sql
psql -v ON_ERROR_STOP=1 -f /opt/etl-synthea/job/clean.sql
STAGE=reset_results
/webapi/recreate_results.sh omop_csv
STAGE=etl
set +e
env -u PGUSER -u PGPASSWORD Rscript /opt/etl-synthea/job/run_etl.R "$WORK/csv"
STATUS=$?; set -e
[ "$STATUS" -eq 0 ] || exit "$STATUS"
STAGE=validate
# Run the live person-count and vocabulary-view assertions before accepting.
STAGE=accept
for b in $IDS; do mv -T "$PEND/$b" "$OKDIR/$b"; done
echo "REFRESH_OK $RID"
```

Before committing, replace the marked validation comment with real person-count and vocabulary-view assertions, and capture per-refresh sanitized logs below `work/<refresh_id>/`; include their path in `error.json`. Ensure the EXIT handler covers every post-claim failure without overwriting a rejected directory or altering accepted batches. A failed refresh keeps WebAPI/MCP stopped. A crash during multiple final directory renames can leave a partially accepted set: report it for manual reconciliation rather than claiming atomic acceptance or restarting queries; crash recovery remains out of scope. `--rebuild-accepted` has no new batches to move and never consumes inbox or rejected input. Implement `run_etl.R` from the pinned 2.1.1 entry point (CDM `5.3.1`, Synthea `3.3.0`, read vocab views, skip `LoadVocabFromSchema`) using the separate ETL login and `/run/secrets/etl_password`, **never** the inherited admin credentials; record the verified call in PROVENANCE.md. Do not claim this plan runnable until the ETL call and both branches of the failure handler pass a real load test. `/db-omop-csv` and `/webapi` are read-only mounts; the latter is a hard dependency.

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
    secrets: [postgres_password, etl_password]
    restart: "no"
```

No `env_file` (consistent with existing services). Read-only mounts give `run.sh` the
versioned DDL and the WebAPI plan's recreate script without cross-plan file copies.

`bin/refresh-csv`: stop `mcp_server`+`ohdsi_webapi` if running, `compose run --rm etl_synthea "$@"`, restart WebAPI, recreate `webapi_register` as a normal Compose one-shot service (`compose up -d --force-recreate webapi_register`), then start MCP only after that job completes successfully and source mapping validates; propagate failures. `--rebuild-accepted` must be the only way to reload when inbox is empty. Make executable.

- [ ] **Step 4: Verify and commit**

```bash
bash tests/csv_refresh/test_assemble.sh && bash tests/csv_refresh/test_refresh_flow.sh
docker compose build etl_synthea
git add docker/etl_synthea compose.yaml bin/refresh-csv
git commit -m "feat: add csv refresh etl-synthea pipeline"
```

Expected: image builds; flow test passes. Add tests for valid 8-6-8 vs invalid 4-6-8 IDs, lock contention, stale `pending/`, missing results script, checksum corruption, post-claim failure rejection, full-snapshot manifest, and accepted-only recovery. Operator-UX live test verifies real load and no stale results.

## Stop Rules

- Stop if ETL-Synthea 2.1.1 CLI differs from assumed — use its README/`?RunETLSynthea` help, record real invocation, do not invent flags.
- Stop before dropping the `omop_csv` schema or any vocab view — truncate clinical tables only.
- Stop on partial accept (some batches moved, some not); keep services stopped and require manual reconciliation. A set of per-batch directory renames is not atomic across a crash.
