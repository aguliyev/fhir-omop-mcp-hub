#!/bin/sh
# Wrapper only: builds the PostgreSQL ODBC string and execs the unmodified converter.
set -eu
if [ "${1:-}" = "--contract-check" ]; then
  dotnet --info
  dotnet /opt/fhir-to-cdm/FHIRtoCDM.dll --help
  odbcinst -q -d
  cat /opt/fhir-to-cdm/UPSTREAM_COMMIT
  exit 0
fi
FHIR_INPUT_DIR="${FHIR_INPUT_DIR:?set FHIR_INPUT_DIR}"
CDM_OUTPUT_DIR="${CDM_OUTPUT_DIR:?set CDM_OUTPUT_DIR}"
VOCAB_SCHEMA="${VOCAB_SCHEMA:-athena_vocabs}"
CDM_VERSION="${CDM_VERSION:-V53}"
CHUNK="${CHUNK:-4}"
V="Driver={PostgreSQL UNICODE};Server=${PGHOST:-postgres};Port=${PGPORT:-5432};Database=${PGDATABASE:?set PGDATABASE};Uid=${PGUSER:?set PGUSER};Pwd=${PGPASSWORD:?set PGPASSWORD};sslmode=disable;UseDeclareFetch=1;"
exec dotnet /opt/fhir-to-cdm/FHIRtoCDM.dll --fhir "$FHIR_INPUT_DIR" --vocabulary "$V" --schema "$VOCAB_SCHEMA" --cdm "$CDM_VERSION" --result "$CDM_OUTPUT_DIR" --chunk "$CHUNK"
