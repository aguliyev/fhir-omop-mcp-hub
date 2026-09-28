#!/bin/bash
# Post-migration source registration (Task 4). Runs AFTER ohdsi_webapi is
# healthy (its Flyway migration creates ohdsi_webapi.source/source_daimon);
# never from db_init. Idempotent: reruns update the same source row.
# Secret travels via /run/secrets/postgres_password, never logs, never image.
set -eu

: "${PGHOST:=postgres}"
: "${PGPORT:=5432}"
: "${PGUSER:=${POSTGRES_USER:-postgres}}"
: "${PGDATABASE:=${POSTGRES_DB:-fhir_omop_mcp_hub}}"
: "${POSTGRES_PASSWORD_FILE:=/run/secrets/postgres_password}"
export PGHOST PGPORT PGUSER PGDATABASE

[ -f "$POSTGRES_PASSWORD_FILE" ] || { echo "FAIL: missing password file $POSTGRES_PASSWORD_FILE" >&2; exit 1; }
PW="$(cat "$POSTGRES_PASSWORD_FILE")"
[ -n "$PW" ] || { echo "FAIL: empty password file" >&2; exit 1; }
PGPASSWORD="$PW"; export PGPASSWORD

psql -v ON_ERROR_STOP=1 -v source_password="$PW" -f /webapi/register_source.sql

# Post-apply assertion (the SQL already guards; this is the job-level receipt):
# exactly one omop_csv source with the four v1 daimons, no duplicates.
N_SRC="$(psql -tA -v ON_ERROR_STOP=1 -c "SELECT count(*) FROM ohdsi_webapi.source WHERE source_key = 'omop_csv';")"
N_DAIMON="$(psql -tA -v ON_ERROR_STOP=1 -c "SELECT count(*) FROM ohdsi_webapi.source_daimon d JOIN ohdsi_webapi.source s USING (source_id) WHERE s.source_key = 'omop_csv';")"
unset PW PGPASSWORD
[ "$N_SRC" = "1" ] || { echo "FAIL: expected 1 omop_csv source, found $N_SRC" >&2; exit 1; }
[ "$N_DAIMON" = "4" ] || { echo "FAIL: expected 4 omop_csv daimons, found $N_DAIMON" >&2; exit 1; }
echo "OK: omop_csv registered ($N_SRC source, $N_DAIMON daimons)"
