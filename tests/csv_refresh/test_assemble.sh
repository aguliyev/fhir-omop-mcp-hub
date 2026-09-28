#!/bin/bash
# tests/csv_refresh/test_assemble.sh — union of accepted + new batches.
set -eu
cd "$(dirname "$0")/../.."
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

# Negative cases: each must make assemble.py fail without writing output.
neg() { # $1=description; dirs already staged under $TMP/neg*
  if python3 docker/etl_synthea/assemble.py "$TMP/neg-success" "$TMP/neg-pending" "$TMP/neg-out" 2>/dev/null; then
    echo "FAIL: negative case passed: $1"; exit 1;
  fi
  rm -rf "$TMP/neg-success" "$TMP/neg-pending" "$TMP/neg-out"
}
setup_neg() { # $1=csv content for the pending batch file
  rm -rf "$TMP/neg-success" "$TMP/neg-pending" "$TMP/neg-out"
  mkdir -p "$TMP/neg-success/20260928-014500-ab12cd34" "$TMP/neg-pending/20260928-014501-ab12cd35"
  cp tests/csv_refresh/fixtures/csv-batch-a/patients.csv "$TMP/neg-success/20260928-014500-ab12cd34/"
  printf '%s' "$1" > "$TMP/neg-pending/20260928-014501-ab12cd35/patients.csv"
  for batch in "$TMP"/neg-success/* "$TMP"/neg-pending/*; do
    (cd "$batch" && sha256sum patients.csv > files.sha256)
    printf '{"batch_id":"%s","synthea_version":"3.3.0","seed":12345,"population":1,"generated_at_utc":"2026-09-28T01:45:00Z","csv_files":["patients.csv"],"fhir_files":[]}' "${batch##*/}" > "$batch/batch.json"
  done
}
# Corrupt checksum.
setup_neg "$(cat tests/csv_refresh/fixtures/csv-batch-b/patients.csv)"
echo "0000000000000000000000000000000000000000000000000000000000000000  patients.csv" > "$TMP/neg-pending/20260928-014501-ab12cd35/files.sha256"
neg "corrupt checksum"
# Mismatched header.
setup_neg "Id,OTHER
b1,x
"
neg "mismatched header"
# Conflicting reference-table Id with differing fields.
setup_neg "$(cat tests/csv_refresh/fixtures/csv-batch-b/patients.csv)"
mkdir -p "$TMP/neg-extra"
printf 'Id,NAME\norg1,Same\n' > "$TMP/neg-success/20260928-014500-ab12cd34/organizations.csv"
printf 'Id,NAME\norg1,Different\n' > "$TMP/neg-pending/20260928-014501-ab12cd35/organizations.csv"
for batch in "$TMP"/neg-success/* "$TMP"/neg-pending/*; do
  (cd "$batch" && sha256sum patients.csv organizations.csv > files.sha256)
  printf '{"batch_id":"%s","synthea_version":"3.3.0","seed":12345,"population":1,"generated_at_utc":"2026-09-28T01:45:00Z","csv_files":["organizations.csv","patients.csv"],"fhir_files":[]}' "${batch##*/}" > "$batch/batch.json"
done
neg "conflicting reference Id"
# Aggregate-only reference difference merges (Synthea 3.3.0 per-run counters).
rm -rf "$TMP/neg-success" "$TMP/neg-pending" "$TMP/neg-out"
mkdir -p "$TMP/neg-success/20260928-014500-ab12cd34" "$TMP/neg-pending/20260928-014501-ab12cd35"
cp tests/csv_refresh/fixtures/csv-batch-a/patients.csv "$TMP/neg-success/20260928-014500-ab12cd34/"
cp tests/csv_refresh/fixtures/csv-batch-b/patients.csv "$TMP/neg-pending/20260928-014501-ab12cd35/"
printf 'Id,NAME,REVENUE,UTILIZATION\norg1,Same,0.0,13\n' > "$TMP/neg-success/20260928-014500-ab12cd34/organizations.csv"
printf 'Id,NAME,REVENUE,UTILIZATION\norg1,Same,0.0,168\n' > "$TMP/neg-pending/20260928-014501-ab12cd35/organizations.csv"
for batch in "$TMP"/neg-success/* "$TMP"/neg-pending/*; do
  (cd "$batch" && sha256sum patients.csv organizations.csv > files.sha256)
  printf '{"batch_id":"%s","synthea_version":"3.3.0","seed":12345,"population":1,"generated_at_utc":"2026-09-28T01:45:00Z","csv_files":["organizations.csv","patients.csv"],"fhir_files":[]}' "${batch##*/}" > "$batch/batch.json"
done
python3 docker/etl_synthea/assemble.py "$TMP/neg-success" "$TMP/neg-pending" "$TMP/neg-out" | grep -q "1 aggregate-only reference duplicates merged" || { echo "FAIL: aggregate-only merge not reported"; exit 1; }
[ "$(grep -c '^' "$TMP/neg-out/organizations.csv")" -eq 2 ] || { echo "FAIL: header+1 org row expected"; exit 1; }
rm -rf "$TMP/neg-success" "$TMP/neg-pending" "$TMP/neg-out"
echo "PASS: assemble"
