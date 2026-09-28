#!/bin/bash
# recreate_results.sh <source-key> — drops+recreates results+temp for that source only.
set -eu
KEY="${1:?usage: recreate_results.sh omop_csv}"
[ "$KEY" = "omop_csv" ] || { echo "FAIL: unknown source $KEY" >&2; exit 1; }
: "${PGHOST:=postgres}" "${PGPORT:=5432}" "${PGUSER:=${POSTGRES_USER:-postgres}}" "${PGDATABASE:=${POSTGRES_DB:-fhir_omop_mcp_hub}}"
export PGHOST PGPORT PGUSER PGDATABASE
PGPASSWORD="$(cat "${POSTGRES_PASSWORD_FILE:-/run/secrets/postgres_password}")"; export PGPASSWORD
psql -v ON_ERROR_STOP=1 -c "DROP SCHEMA IF EXISTS omop_csv_results CASCADE; CREATE SCHEMA omop_csv_results;"
psql -v ON_ERROR_STOP=1 -c "DROP SCHEMA IF EXISTS omop_csv_temp CASCADE; CREATE SCHEMA omop_csv_temp;"
psql -v ON_ERROR_STOP=1 -f "$(dirname "$0")/results_ddl.sql"
