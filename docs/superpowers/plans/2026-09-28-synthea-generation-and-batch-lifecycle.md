# Synthea Generation and Batch Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reproducible `synthea` batch container that generates matching CSV+FHIR exports and publishes them as atomic batch directories to both inboxes.

**Architecture:** Synthea 3.3.0 runs once per invocation in an ephemeral container with recorded patient and clinician seeds, writes to temp storage, then publishes complete `<batch_id>/` directories to the FHIR inbox **before** the CSV inbox. CSV publication is the consumer-visible commit point; each directory rename is atomic, but a crash between two renames cannot be a cross-directory atomic transaction. Only CSV is consumed downstream in v1; FHIR is archived parity.

**Tech Stack:** Docker Compose (linux/amd64), Synthea 3.3.0 jar, POSIX shell, SHA-256 manifest, JSON batch manifest.

**Spec:** `docs/intro.md` §§2, 4, 5, 9, 10, 11 (v1 CSV-only; FHIR generated but not imported).

**File ownership (parallel agents):** this plan owns `docker/synthea/`, `etc/synthea.env.example`,
`bin/generate`, `tests/synthea/`. It must not edit `compose.yaml` beyond appending its own
`synthea:` block, and must not touch `bin/prepare-data` (queue trees already created there),
`bin/lib/common.sh`, or any other plan's files.

## Global Constraints

- Pin Synthea `3.3.0` (v3.3.0 release jar); record exact download URL+SHA-256 in `docker/synthea/PROVENANCE.md`.
- Every run uses a unique recorded patient seed and records the clinician seed, reference date, population, and exporter settings needed to reproduce the population; reject reuse of a seed from any existing accepted/inbox batch.
- Publish by atomic directory rename only; never publish partial batches or individual files.
- Batch ID format: `YYYYMMDD-HHMMSS-<8-hex-lower>` (UTC time + `openssl rand -hex 4`); one batch ID covers both CSV and FHIR outputs.
- CSV batch dir contains the full Synthea CSV export (with header rows); FHIR batch dir contains Bundle JSON files.
- FHIR output is archived only; this plan must not build any FHIR-to-OMOP loader.
- Host data root stays at `${DATA_ROOT:-./data}` mounted at `/data`; new queue dirs are ignored by git.
- No secrets in tracked files; no hardcoded connection strings (this service needs none).

---

## Planned File Structure

```text
docker/synthea/{Dockerfile,PROVENANCE.md,generate.sh,publish.sh}
etc/synthea.env.example            # POPULATION_SIZE, SEED(optional), SYNTHEA_JAR_URL
bin/generate                       # thin wrapper: compose run synthea
tests/synthea/test_batch_contract.sh
```

`generate.sh`+`publish.sh` live in the image; `bin/generate` only passes env and asserts the two inbox batch dirs appeared with equal batch IDs.

---

### Task 1: Batch contract (manifest, naming, queue layout)

**Files:**
- Create: `tests/synthea/test_batch_contract.sh`
- Create: `etc/synthea.env.example`

**Interfaces:**
- Consumes: `docs/intro.md` §9 storage layout.
- Produces: `batch.json` schema + batch-ID regex consumed by Tasks 2–3 and the CSV-refresh plan.

- [ ] **Step 1: Write the failing contract test**

```bash
#!/bin/bash
# tests/synthea/test_batch_contract.sh — asserts batch ID + manifest schema.
set -eu
fail=0
grep -Eq '^[0-9]{8}-[0-9]{6}-[0-9a-f]{8}$' <<<"20260928-014500-ab12cd34" || { echo "FAIL: batch id regex"; fail=1; }
for f in docker/synthea/generate.sh docker/synthea/publish.sh etc/synthea.env.example bin/generate; do
  [ -f "$f" ] || { echo "FAIL: missing $f"; fail=1; }
done
[ "$fail" -eq 0 ] && echo "PASS: batch contract" || exit 1
```

Run: `bash tests/synthea/test_batch_contract.sh`
Expected: FAIL (files missing).

- [ ] **Step 2: Define the batch manifest schema (contract, no code yet)**

`csv_input/inbox/<batch_id>/batch.json` and the identical FHIR-side copy contain exactly:

```json
{
  "batch_id": "20260928-014500-ab12cd34",
  "synthea_version": "3.3.0",
  "seed": 12345,
  "clinician_seed": 67890,
  "reference_date": "20240101",
  "population": 100,
  "generated_at_utc": "2026-09-28T01:45:00Z",
  "csv_files": ["patients.csv"],
  "fhir_files": ["Patient_abc.json"]
}
```

Batch ID regex: `^[0-9]{8}-[0-9]{6}-[0-9a-f]{8}$`. `seed`/`clinician_seed` are the exact integers passed to Synthea `-s`/`-cs`. Both inbox batch dirs share identical `batch.json` and each has its own `files.sha256` for its data files. The CSV refresh plan validates both the batch manifest and CSV checksums before assembly.

- [ ] **Step 3: Create non-secret defaults**

`etc/synthea.env.example`:

```dotenv
SYNTHEA_VERSION=3.3.0
POPULATION_SIZE=100
# SEED empty = random unique seed per run, recorded in batch.json
SEED=
```

- [ ] **Step 4: Run and commit**

```bash
bash tests/synthea/test_batch_contract.sh # still FAIL (scripts missing) — expected
git add tests/synthea/test_batch_contract.sh etc/synthea.env.example
git commit -m "build: define synthea batch contract"
```

Expected: contract files tracked; test fails until Task 2.

### Task 2: Synthea container (generate + atomic publish)

**Files:**
- Create: `docker/synthea/Dockerfile`
- Create: `docker/synthea/PROVENANCE.md`
- Create: `docker/synthea/generate.sh`
- Create: `docker/synthea/publish.sh`
- Modify: `compose.yaml` (append `synthea:` service block only)

Queue directories (`csv_input/`, `fhir_input/` with all four states) already exist via
`bin/prepare-data` — do not modify it.

**Interfaces:**
- Consumes: batch-ID + manifest schema from Task 1.
- Produces: `csv_input/inbox/<batch_id>/` + `fhir_input/inbox/<batch_id>/` consumed by the CSV-refresh plan.

- [ ] **Step 1: Write the Dockerfile**

```dockerfile
# Synthea 3.3.0 generator, linux/amd64. Pin the base-image digest at implementation time.
FROM eclipse-temurin:17-jre-jammy
ARG SYNTHEA_VERSION=3.3.0
# Resolve the real SHA at implementation time and pin it here:
# curl -sL https://github.com/synthetichealth/synthea/releases/download/v3.3.0/synthea-with-dependencies.jar | sha256sum
ARG SYNTHEA_SHA256
ADD https://github.com/synthetichealth/synthea/releases/download/v${SYNTHEA_VERSION}/synthea-with-dependencies.jar /opt/synthea/synthea.jar
RUN echo "${SYNTHEA_SHA256}  /opt/synthea/synthea.jar" | sha256sum -c - \
 && mkdir -p /tmp/synthea-out /data/csv_input /data/fhir_input
COPY generate.sh publish.sh /opt/synthea/
ENTRYPOINT ["/opt/synthea/generate.sh"]
```

`PROVENANCE.md` records the release URL and the SHA-256 computed with the command above (build fails without a pinned value; verify with `sha256sum`).

- [ ] **Step 2: Write `generate.sh` (generate → publish)**

```bash
#!/bin/bash
# Prior art: spikes/fhir_to_cdm/synthea/generate.sh proves the 3.3.0 CLI shape
# (-p, -s, -cs, -r, --exporter.* overrides). Reuse its flags; record deviations.
set -eu
: "${POPULATION_SIZE:=100}"
SEED="${SEED:-$((RANDOM * 32768 + RANDOM))}"
CSEED="${CLINICIAN_SEED:-$((RANDOM * 32768 + RANDOM))}"
REF="${SYNTHEA_REFERENCE_DATE:-20240101}"
BATCH_ID="$(date -u +%Y%m%d-%H%M%S)-$(openssl rand -hex 4)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP"  # Synthea writes ./output/{csv,fhir}/ relative to CWD.
java -jar /opt/synthea/synthea.jar -p "$POPULATION_SIZE" -s "$SEED" -cs "$CSEED" -r "$REF" \
  --exporter.csv.export true --exporter.fhir.export true \
  --exporter.use_uuid_filenames true \
  --exporter.hospital.fhir.export false --exporter.practitioner.fhir.export false
/opt/synthea/publish.sh "$TMP/output" "$BATCH_ID" "$SEED" "$POPULATION_SIZE" "$CSEED" "$REF"
echo "GENERATED batch=$BATCH_ID seed=$SEED population=$POPULATION_SIZE"
```

Run from the fresh `$TMP` CWD, so `$TMP/output` is exactly this run's output. Reject duplicate patient seeds already in `inbox/` or `success/`, including supplied `SEED`. Pin only flags Synthea 3.3.0 supports;
if a flag differs, use the 3.3.0 `--help` equivalent and record it in PROVENANCE.md.

- [ ] **Step 3: Write `publish.sh` (atomic rename)**

```bash
#!/bin/bash
# publish.sh <synthea-output-root> <batch-id> <seed> <population> <clinician-seed> <reference-date>
set -eu
SRC="$1"; BID="$2"; SEED="$3"; POP="$4"; CSEED="$5"; REF="$6"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for q in csv_input fhir_input; do mkdir -p "/data/$q/inbox" "/data/$q/pending" "/data/$q/success" "/data/$q/rejected"; done
C_STAGE="/data/csv_input/.staging-$BID"; F_STAGE="/data/fhir_input/.staging-$BID"
F_DEST="/data/fhir_input/inbox/$BID"
for d in "$C_STAGE" "$F_STAGE" "/data/csv_input/inbox/$BID" "/data/fhir_input/inbox/$BID"; do
  [ ! -e "$d" ] || { echo "FAIL: batch path exists: $d" >&2; exit 1; }
done
mkdir -p "$C_STAGE" "$F_STAGE"
PUBLISHED=0
trap '[ "$PUBLISHED" -eq 1 ] || { rm -rf "$C_STAGE" "$F_STAGE"; [ ! -d "$F_DEST" ] || rm -rf "$F_DEST"; }' EXIT
find "$SRC/csv" -name '*.csv' -exec cp {} "$C_STAGE/" \;
find "$SRC/fhir" -name '*.json' -exec cp {} "$F_STAGE/" \;
compgen -G "$C_STAGE/*.csv" >/dev/null && compgen -G "$F_STAGE/*.json" >/dev/null || { echo "FAIL: empty CSV or FHIR export" >&2; exit 1; }
gen_manifest() { # $1=stagedir $2=extension
  (cd "$1" && sha256sum -- *."$2" | LC_ALL=C sort > files.sha256)
  csv_list=$(python3 -c 'import json,sys,pathlib; print(json.dumps(sorted(p.name for p in pathlib.Path(sys.argv[1]).glob("*.csv"))))' "$C_STAGE")
  fhir_list=$(python3 -c 'import json,sys,pathlib; print(json.dumps(sorted(p.name for p in pathlib.Path(sys.argv[1]).glob("*.json"))))' "$F_STAGE")
  printf '{"batch_id":"%s","synthea_version":"3.3.0","seed":%s,"clinician_seed":%s,"reference_date":"%s","population":%s,"generated_at_utc":"%s","csv_files":%s,"fhir_files":%s}\n' \
    "$BID" "$SEED" "$CSEED" "$REF" "$POP" "$TS" "$csv_list" "$fhir_list" > "$1/batch.json"
}
gen_manifest "$C_STAGE" csv; gen_manifest "$F_STAGE" json
mv -T "$F_STAGE" "$F_DEST"
mv -T "$C_STAGE" "/data/csv_input/inbox/$BID"
PUBLISHED=1
```

Require nonempty CSV/FHIR inventories and verify both checksums and matching `batch.json` before either rename. On an ordinary failure after the FHIR rename, remove only this invocation's FHIR inbox dir; after a process/host crash it may remain orphaned and `bin/validate` must report that explicitly rather than claim perfect pair atomicity. Never remove an already accepted CSV batch.

- [ ] **Step 4: Wire compose + queue dirs**

`compose.yaml` addition:

```yaml
  synthea:
    build: ./docker/synthea
    platform: linux/amd64
    environment:
      POPULATION_SIZE: ${POPULATION_SIZE:-100}
      SEED: ${SEED:-}
    volumes:
      - ${DATA_ROOT:-./data}:/data
    restart: "no"
```

No `env_file` (consistent with existing services; missing optional env files break Compose).
Callers export `POPULATION_SIZE`/`SEED` in-process from the single ignored `etc/setup.env`;
`etc/synthea.env.example` documents values but is not sourced. The operator plan extends
`common.sh` forwarding before this service is used. Never add `env_file` entries. (Queue directories
already exist via `bin/prepare-data`; nothing to create here.)

- [ ] **Step 5: Run, verify, commit**

```bash
bash tests/synthea/test_batch_contract.sh
docker compose build synthea && POPULATION_SIZE=5 docker compose run --rm synthea
ls data/csv_input/inbox data/fhir_input/inbox
git add docker/synthea compose.yaml etc/synthea.env.example bin/generate
git commit -m "feat: add synthea batch generator"
```

Expected: two inbox dirs share one batch ID, each with `batch.json`+`files.sha256`; contract test passes.

### Task 3: `bin/generate` wrapper + idempotence test

**Files:**
- Create: `bin/generate`
- Modify: `tests/synthea/test_batch_contract.sh` (append two-batch uniqueness check)

**Interfaces:**
- Consumes: `synthea` compose service from Task 2.
- Produces: operator command used by the operator-UX plan.

- [ ] **Step 1: Write `bin/generate`**

```bash
#!/bin/bash
# bin/generate [population] — runs synthea once, asserts matched inbox pair.
set -eu; cd "$(dirname "$0")/.."
. bin/lib/common.sh
POP="${1:-${POPULATION_SIZE:-100}}"
export POPULATION_SIZE="$POP"
OUT="$(compose run --rm synthea)"
BID="$(printf '%s\n' "$OUT" | sed -n 's/^GENERATED batch=\([^ ]*\) .*/\1/p')"
[ -n "$BID" ] || die "generator did not report a batch ID"
[ -d "$DATA_ROOT/csv_input/inbox/$BID" ] && [ -d "$DATA_ROOT/fhir_input/inbox/$BID" ] || die "missing matched batch $BID"
cmp "$DATA_ROOT/csv_input/inbox/$BID/batch.json" "$DATA_ROOT/fhir_input/inbox/$BID/batch.json" || die "batch manifest mismatch $BID"
echo "OK: batch=$BID"
```

Make executable: `chmod +x bin/generate`.

- [ ] **Step 2: Verify two runs give two unique batch IDs**

```bash
bin/generate 5 && bin/generate 5
ls data/csv_input/inbox | wc -l  # expect ≥2, all unique
bash tests/synthea/test_batch_contract.sh
git add bin/generate tests/synthea/test_batch_contract.sh
git commit -m "feat: add bin/generate wrapper"
```

Expected: PASS; no inbox overwrite (unique IDs), rerun safe. Do not compare total CSV/FHIR inbox counts: a successful CSV refresh moves CSV out of inbox while FHIR remains archived there. Test that a failure on the second rename leaves no CSV batch visible and that both hashes match the published files.

## Stop Rules

- Stop if Synthea 3.3.0 flags differ from those assumed — use `--help` output, record real flags in PROVENANCE.md, do not invent flags.
- Stop if the FhirToCdm spike tempts loader work here — FHIR import is out of scope; archive only.
- Stop on non-atomic publish (copy directly into inbox) — must stage hidden then `mv`.
