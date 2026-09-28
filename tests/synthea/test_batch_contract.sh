#!/bin/bash
# tests/synthea/test_batch_contract.sh — asserts batch ID + manifest schema + uniqueness + lifecycle failure behavior.
set -eu
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

fail=0
ok() { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }

# 1. Batch ID regex
if grep -Eq '^[0-9]{8}-[0-9]{6}-[0-9a-f]{8}$' <<<"20260928-014500-ab12cd34"; then
  ok "batch id regex"
else
  bad "batch id regex"
fi

# 2. File existence & executables
for f in docker/synthea/Dockerfile docker/synthea/PROVENANCE.md docker/synthea/generate.sh docker/synthea/publish.sh etc/synthea.env.example bin/generate; do
  if [ -f "$f" ]; then
    ok "$f exists"
  else
    bad "missing $f"
  fi
done

for x in docker/synthea/generate.sh docker/synthea/publish.sh bin/generate; do
  if [ -x "$x" ]; then
    ok "$x is executable"
  else
    bad "$x is not executable"
  fi
done

# 3. Existing batches validation & two-batch uniqueness
DATA_ROOT="${DATA_ROOT:-./data}"
csv_inbox="$DATA_ROOT/csv_input/inbox"
fhir_inbox="$DATA_ROOT/fhir_input/inbox"

if [ -d "$csv_inbox" ]; then
  batch_count=0
  declare -A seen_batches
  declare -A seen_seeds

  for bdir in "$csv_inbox"/*; do
    [ -d "$bdir" ] || continue
    bid="$(basename "$bdir")"
    if grep -Eq '^[0-9]{8}-[0-9]{6}-[0-9a-f]{8}$' <<<"$bid"; then
      ok "batch ID format valid: $bid"
    else
      bad "batch ID format invalid: $bid"
    fi

    if [ -n "${seen_batches[$bid]:-}" ]; then
      bad "duplicate batch ID: $bid"
    fi
    seen_batches[$bid]=1
    batch_count=$((batch_count + 1))

    # Manifest schema validation
    mf="$bdir/batch.json"
    if [ -f "$mf" ]; then
      ok "manifest exists in csv inbox: $bid"
      python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
required = ["batch_id", "synthea_version", "seed", "clinician_seed", "reference_date", "population", "generated_at_utc", "csv_files", "fhir_files"]
for k in required:
    assert k in data, f"missing {k}"
assert data["batch_id"] == sys.argv[2], "batch_id mismatch"
assert data["synthea_version"] == "3.3.0", "synthea_version mismatch"
assert isinstance(data["seed"], int), "seed must be int"
assert isinstance(data["clinician_seed"], int), "clinician_seed must be int"
assert isinstance(data["population"], int), "population must be int"
assert isinstance(data["csv_files"], list) and len(data["csv_files"]) > 0, "csv_files non-empty list"
assert isinstance(data["fhir_files"], list) and len(data["fhir_files"]) > 0, "fhir_files non-empty list"
' "$mf" "$bid" || bad "manifest schema invalid: $bid"

      seed=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["seed"])' "$mf")
      if [ -n "${seen_seeds[$seed]:-}" ]; then
        bad "duplicate patient seed: $seed in batch $bid"
      else
        seen_seeds[$seed]=1
      fi
    else
      bad "missing batch.json in csv inbox: $bid"
    fi

    # Check checksums
    if [ -f "$bdir/files.sha256" ]; then
      (cd "$bdir" && sha256sum -c files.sha256 >/dev/null) || bad "csv checksum mismatch: $bid"
    else
      bad "missing files.sha256 in csv inbox: $bid"
    fi

    # Check matching fhir inbox
    fdir="$fhir_inbox/$bid"
    if [ -d "$fdir" ]; then
      ok "matching fhir batch dir exists: $bid"
      if cmp -s "$bdir/batch.json" "$fdir/batch.json"; then
        ok "batch.json matches between csv and fhir: $bid"
      else
        bad "batch.json differs between csv and fhir: $bid"
      fi
      if [ -f "$fdir/files.sha256" ]; then
        (cd "$fdir" && sha256sum -c files.sha256 >/dev/null) || bad "fhir checksum mismatch: $bid"
      else
        bad "missing files.sha256 in fhir inbox: $bid"
      fi
    else
      bad "missing matching fhir batch dir for $bid"
    fi
  done

  if [ "$batch_count" -ge 2 ]; then
    ok "two or more unique batches verified: count=$batch_count"
  else
    bad "expected at least 2 batches in inbox, found $batch_count"
  fi
fi

# 4. Duplicate patient seed rejection test
TEST_ENV_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_ENV_DIR"' EXIT
mkdir -p "$TEST_ENV_DIR/data/csv_input/inbox/20260101-000000-aaaaaaaa"
cat >"$TEST_ENV_DIR/data/csv_input/inbox/20260101-000000-aaaaaaaa/batch.json" <<'EOF'
{"batch_id":"20260101-000000-aaaaaaaa","synthea_version":"3.3.0","seed":99999,"clinician_seed":11111,"reference_date":"20240101","population":1,"generated_at_utc":"2026-01-01T00:00:00Z","csv_files":["patients.csv"],"fhir_files":["p.json"]}
EOF
if (DATA_DIR="$TEST_ENV_DIR/data" SEED=99999 bash -c '. docker/synthea/generate.sh' >/dev/null 2>&1); then
  bad "duplicate seed was not rejected"
else
  ok "duplicate seed properly rejected"
fi

# 5. Atomic publish failure test (simulate failure on rename to CSV inbox)
# Mock Synthea output
SRC_DIR="$TEST_ENV_DIR/src"
mkdir -p "$SRC_DIR/csv" "$SRC_DIR/fhir"
echo "id,name" > "$SRC_DIR/csv/patients.csv"
echo '{"resourceType":"Patient"}' > "$SRC_DIR/fhir/p.json"

FAIL_BID="20260101-000000-bbbbbbbb"
# Force failure on CSV destination by making destination path an unwritable directory or existing file that mv cannot overwrite
mkdir -p "$TEST_ENV_DIR/data/csv_input/inbox"
# Block C_STAGE rename by making a non-directory file or conflict
touch "$TEST_ENV_DIR/data/csv_input/inbox/$FAIL_BID"

if (DATA_DIR="$TEST_ENV_DIR/data" bash docker/synthea/publish.sh "$SRC_DIR" "$FAIL_BID" 123 1 456 20240101 >/dev/null 2>&1); then
  bad "publish should have failed on existing CSV batch path"
else
  ok "publish correctly aborted on collision"
fi
# Assert FHIR destination was cleaned up (or never published)
if [ -d "$TEST_ENV_DIR/data/fhir_input/inbox/$FAIL_BID" ]; then
  bad "FHIR inbox batch was not cleaned up on publication failure"
else
  ok "FHIR inbox batch cleaned up on publication failure"
fi
# Assert CSV inbox batch remains untouched / no partial staged content
if [ -d "$TEST_ENV_DIR/data/csv_input/.staging-$FAIL_BID" ] || [ -d "$TEST_ENV_DIR/data/fhir_input/.staging-$FAIL_BID" ]; then
  bad "staging directory left behind after failure"
else
  ok "staging directories removed after failure"
fi

# 6. Verify successful atomic publish in isolation
SUCC_BID="20260101-000000-cccccccc"
if (DATA_DIR="$TEST_ENV_DIR/data" bash docker/synthea/publish.sh "$SRC_DIR" "$SUCC_BID" 777 1 888 20240101 >/dev/null 2>&1); then
  ok "publish succeeded for $SUCC_BID"
  [ -d "$TEST_ENV_DIR/data/csv_input/inbox/$SUCC_BID" ] || bad "missing CSV inbox for $SUCC_BID"
  [ -d "$TEST_ENV_DIR/data/fhir_input/inbox/$SUCC_BID" ] || bad "missing FHIR inbox for $SUCC_BID"
  cmp -s "$TEST_ENV_DIR/data/csv_input/inbox/$SUCC_BID/batch.json" "$TEST_ENV_DIR/data/fhir_input/inbox/$SUCC_BID/batch.json" || bad "manifest mismatch for $SUCC_BID"
  (cd "$TEST_ENV_DIR/data/csv_input/inbox/$SUCC_BID" && sha256sum -c files.sha256 >/dev/null) || bad "csv checksum mismatch for $SUCC_BID"
  (cd "$TEST_ENV_DIR/data/fhir_input/inbox/$SUCC_BID" && sha256sum -c files.sha256 >/dev/null) || bad "fhir checksum mismatch for $SUCC_BID"
  ok "isolated atomic publish verified with valid hashes"
else
  bad "publish failed unexpectedly for $SUCC_BID"
fi

[ "$fail" -eq 0 ] && echo "PASS: batch contract" || exit 1
