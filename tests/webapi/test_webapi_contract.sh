#!/bin/bash
# tests/webapi/test_webapi_contract.sh
set -eu
for f in docker/webapi/Dockerfile db/webapi/results_ddl.sql db/webapi/register_source.sql db/webapi/recreate_results.sh etc/webapi.env.example; do
  [ -f "$f" ] || { echo "FAIL: missing $f"; exit 1; }
done
grep -q "omop_csv" db/webapi/register_source.sql || { echo "FAIL: no omop_csv source"; exit 1; }
grep -q "omop_fhir" db/webapi/register_source.sql && { echo "FAIL: omop_fhir must not register in v1"; exit 1; }
echo "PASS: webapi contract"
