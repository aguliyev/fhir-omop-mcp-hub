#!/bin/bash
# tests/csv_refresh/test_refresh_flow.sh — truncate keeps views, empties clinical.
set -eu
cd "$(dirname "$0")/../.."
fail=0
for f in db/omop_csv/clinical_tables.sql docker/etl_synthea/clean.sql docker/etl_synthea/run.sh bin/refresh-csv; do
  [ -f "$f" ] || { echo "FAIL: missing $f"; fail=1; }
done
[ "$fail" -eq 0 ] || exit 1
grep -q "RESTART IDENTITY CASCADE" docker/etl_synthea/clean.sql || { echo "FAIL: clean.sql not truncate-based"; exit 1; }
for v in concept concept_ancestor concept_class concept_relationship concept_synonym domain drug_strength relationship source_to_concept_map vocabulary; do
  grep -q "omop_csv\.$v" docker/etl_synthea/clean.sql && { echo "FAIL: clean.sql touches vocab $v"; exit 1; }
done
# Every physical table in clinical_tables.sql must be truncated in clean.sql.
# clean.sql may additionally name ETL-Synthea runtime helpers (created and
# owned by the ETL itself, truncated only when present) — nothing else.
clinical=$(grep -o "omop_csv\.[a-z_]*" db/omop_csv/clinical_tables.sql | sed 's/omop_csv\.//' | sort -u)
cleaned=$(grep -o "omop_csv\.[a-z_]*" docker/etl_synthea/clean.sql | sed 's/omop_csv\.//' | sort -u)
helpers="assign_all_visit_ids all_visits er_visits final_visit_ids ip_visits op_visits source_to_source_vocab_map source_to_standard_vocab_map states_map"
missing=$(comm -23 <(echo "$clinical") <(echo "$cleaned") || true)
[ -z "$missing" ] || { echo "FAIL: clinical tables missing from clean.sql: $missing"; exit 1; }
extra=$(comm -13 <(echo "$clinical") <(echo "$cleaned") || true)
for t in $extra; do
  echo "$helpers" | grep -qw "$t" || { echo "FAIL: clean.sql truncates unknown $t"; exit 1; }
done
# Dedicated ETL login (never postgres superuser) must be provisioned and wired.
grep -q "etl_loader" db/bootstrap/schemas.sql db/bootstrap/run.sh || { echo "FAIL: etl_loader not provisioned"; exit 1; }
grep -q "etl_password" bin/prepare-data compose.yaml || { echo "FAIL: etl_password secret not wired"; exit 1; }
echo "PASS: refresh flow files"
