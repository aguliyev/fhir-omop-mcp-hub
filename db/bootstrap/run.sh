#!/bin/bash
# One-shot db_init entrypoint (Task 2). Reads the secret file, never prints it.
set -eu

: "${PGHOST:=postgres}"
: "${PGPORT:=5432}"
: "${PGUSER:=${POSTGRES_USER:-postgres}}"
: "${PGDATABASE:=${POSTGRES_DB:-fhir_omop_mcp_hub}}"
: "${POSTGRES_PASSWORD_FILE:=/run/secrets/postgres_password}"
: "${ETL_PASSWORD_FILE:=/run/secrets/etl_password}"

[ -f "$POSTGRES_PASSWORD_FILE" ] || { echo "FAIL: missing password file $POSTGRES_PASSWORD_FILE" >&2; exit 1; }
PGPASSWORD="$(cat "$POSTGRES_PASSWORD_FILE")"
export PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD

export PGOPTIONS="-c statement_timeout=60000"
psql -v ON_ERROR_STOP=1 -f /bootstrap/schemas.sql
psql -v ON_ERROR_STOP=1 -f /webapi/results_ddl.sql

# Dedicated ETL login password from its own ignored secret (CSV refresh plan).
# Password travels via a temp SQL file, never argv or tracked files.
[ -s "$ETL_PASSWORD_FILE" ] || { echo "FAIL: missing ETL password file $ETL_PASSWORD_FILE" >&2; exit 1; }
ETL_TMP="$(mktemp)"; trap 'rm -f "$ETL_TMP"' EXIT
ETL_PW="$(cat "$ETL_PASSWORD_FILE")"
printf "ALTER ROLE etl_loader WITH LOGIN PASSWORD '%s';\n" "${ETL_PW//\'/\'\'}" >"$ETL_TMP"
psql -v ON_ERROR_STOP=1 -f "$ETL_TMP"
rm -f "$ETL_TMP"; trap - EXIT
unset ETL_PW ETL_TMP

# Integration assertion: etl_loader can log in but must not write athena_vocabs.
ETL_PGPASSWORD="$(cat "$ETL_PASSWORD_FILE")"
PGUSER=etl_loader PGPASSWORD="$ETL_PGPASSWORD" psql -v ON_ERROR_STOP=1 -c "SELECT 1;" \
  >/dev/null || { echo "FAIL: etl_loader login failed" >&2; exit 1; }
PGUSER=etl_loader PGPASSWORD="$ETL_PGPASSWORD" psql -v ON_ERROR_STOP=1 -c \
  "CREATE TABLE athena_vocabs.__deny_write_check (id integer);" \
  >/dev/null 2>&1 && { echo "FAIL: etl_loader can write athena_vocabs" >&2; exit 1; } || true
unset ETL_PGPASSWORD
echo "OK: etl_loader denied write to athena_vocabs"
