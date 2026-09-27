#!/bin/bash
# One-shot db_init entrypoint (Task 2). Reads the secret file, never prints it.
set -eu

: "${PGHOST:=postgres}"
: "${PGPORT:=5432}"
: "${PGUSER:=${POSTGRES_USER:-postgres}}"
: "${PGDATABASE:=${POSTGRES_DB:-fhir_omop_mcp_hub}}"
: "${POSTGRES_PASSWORD_FILE:=/run/secrets/postgres_password}"

[ -f "$POSTGRES_PASSWORD_FILE" ] || { echo "FAIL: missing password file $POSTGRES_PASSWORD_FILE" >&2; exit 1; }
PGPASSWORD="$(cat "$POSTGRES_PASSWORD_FILE")"
export PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD

export PGOPTIONS="-c statement_timeout=60000"
psql -v ON_ERROR_STOP=1 -f /bootstrap/schemas.sql
