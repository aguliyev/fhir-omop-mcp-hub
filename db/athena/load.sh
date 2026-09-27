#!/bin/sh
# Athena vocabulary one-shot loader, run inside the `athena_vocabs` container.
# Single transaction: any error rolls back and preserves the prior committed
# schema and omop_csv views. Never prints secrets.
#
# Environment (provided by Compose / etc/setup.env):
#   PGHOST (default postgres), PGPORT (default 5432),
#   PGDATABASE (default fhir_omop_mcp_hub), PGUSER (default postgres),
#   PGPASSWORD_FILE (default /run/secrets/postgres_password),
#   ATHENA_INPUT_DIR (default /data/athena_input/current),
#   VOCAB_VIEW_TARGET_SCHEMAS (must be exactly "omop_csv").
set -eu

SQL_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PGHOST="${PGHOST:-postgres}"
PGPORT="${PGPORT:-5432}"
PGDATABASE="${POSTGRES_DB:-${PGDATABASE:-fhir_omop_mcp_hub}}"
PGUSER="${POSTGRES_USER:-${PGUSER:-postgres}}"
PGPASSWORD_FILE="${PGPASSWORD_FILE:-/run/secrets/postgres_password}"
ATHENA_INPUT_DIR="${ATHENA_INPUT_DIR:-/data/athena_input/current}"
VOCAB_VIEW_TARGET_SCHEMAS="${VOCAB_VIEW_TARGET_SCHEMAS:-omop_csv}"

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# 0. ATHENA_INPUT_DIR is interpolated into \copy file literals below. Reject
#    characters that would break psql single-quoting (single quote,
#    backslash, newline). Staged paths come from bin/stage-athena and never
#    need them; the value is not echoed back (it may contain a newline).
_LF='
'
_Q="'"
_BS="$(printf '\134')"
case "$ATHENA_INPUT_DIR" in
  *"$_Q"*|*"$_LF"*|*"$_BS"*)
    die "ATHENA_INPUT_DIR must not contain single quotes, backslashes, or newlines" ;;
esac

# 1. Exact allow-listed view target. Reject everything else, including lists,
#    empty values, paths, or qualified names.
[ "$VOCAB_VIEW_TARGET_SCHEMAS" = "omop_csv" ] \
  || die "VOCAB_VIEW_TARGET_SCHEMAS must be exactly 'omop_csv', got '$VOCAB_VIEW_TARGET_SCHEMAS'"

# Staged-manifest proof via the shared db/athena/verify_manifest.sh helper
# (3-field "<sha256> <bytes> <basename>" lines; sha256sum -c cannot parse
# them). Host wrappers call the same file; single source of truth.

# 2. Staged manifest checks (files laid down by bin/stage-athena, Task 3).
[ -d "$ATHENA_INPUT_DIR" ] || die "staged dir missing: $ATHENA_INPUT_DIR"
[ -f "$ATHENA_INPUT_DIR/manifest.sha256" ] || die "staged manifest missing: $ATHENA_INPUT_DIR/manifest.sha256"
for f in CONCEPT.csv CONCEPT_ANCESTOR.csv CONCEPT_CLASS.csv CONCEPT_RELATIONSHIP.csv \
         CONCEPT_SYNONYM.csv DOMAIN.csv DRUG_STRENGTH.csv RELATIONSHIP.csv VOCABULARY.csv; do
  [ -f "$ATHENA_INPUT_DIR/$f" ] || die "staged file missing: $f"
  [ -s "$ATHENA_INPUT_DIR/$f" ] || die "staged file empty: $f"
done
# NOTE: SOURCE_TO_CONCEPT_MAP.csv is never required and never loaded;
# source_to_concept_map stays empty (site-maintained).
log "verifying staged manifest in $ATHENA_INPUT_DIR"
[ -x "$SQL_DIR/verify_manifest.sh" ] \
  || die "helper missing: $SQL_DIR/verify_manifest.sh"
"$SQL_DIR/verify_manifest.sh" "$ATHENA_INPUT_DIR" \
  || die "staged manifest verification failed"
AGG="$(awk '{print $1}' "$ATHENA_INPUT_DIR/manifest.sha256" | LC_ALL=C sort | sha256sum | awk '{print $1}')"
log "staged aggregate checksum: $AGG"

# 3. Credentials without printing. psql reads PGPASSWORD from the environment.
[ -f "$PGPASSWORD_FILE" ] || die "password file missing: $PGPASSWORD_FILE"
PGPASSWORD="$(cat "$PGPASSWORD_FILE")"
export PGPASSWORD
[ -n "$PGPASSWORD" ] || die "password file is empty"
export PGHOST PGPORT PGDATABASE PGUSER

for f in create_tables.sql create_indexes.sql create_views.sql validate.sql; do
  [ -f "$SQL_DIR/$f" ] || die "SQL file missing: $SQL_DIR/$f"
done
command -v psql >/dev/null 2>&1 || die "psql not found"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum not found"
command -v awk >/dev/null 2>&1 || die "awk not found"

# 4. Assemble one transaction. \copy rows participate in the transaction, so
#    a bad row, duplicate key, failed grant, bad view target, or failed
#    validate.sql aborts everything and prior committed state stays visible.
TMP="$(mktemp /tmp/athena_load.XXXXXX)"
trap 'rm -f "$TMP"; unset PGPASSWORD' EXIT INT TERM
{
  printf '%s\n' "BEGIN;"
  printf '%s\n' "SELECT pg_advisory_xact_lock(hashtext('fhir_omop_mcp_hub.athena_vocabs'));"
  printf '%s\n' "DROP SCHEMA IF EXISTS athena_vocabs CASCADE;"
  printf '%s\n' "CREATE SCHEMA athena_vocabs;"
  cat "$SQL_DIR/create_tables.sql"
  # Nine explicit \copy lines via here-doc: printf formats are not used
  # because busybox ash printf truncates output at "\\c".
  BS="$(printf '\134')" # one backslash byte; avoids busybox printf "\c" truncation
  cat <<EOF
${BS}copy athena_vocabs.drug_strength FROM '$ATHENA_INPUT_DIR/DRUG_STRENGTH.csv' WITH (FORMAT csv, HEADER true, DELIMITER E'\t', QUOTE E'\b')
${BS}copy athena_vocabs.concept FROM '$ATHENA_INPUT_DIR/CONCEPT.csv' WITH (FORMAT csv, HEADER true, DELIMITER E'\t', QUOTE E'\b')
${BS}copy athena_vocabs.concept_relationship FROM '$ATHENA_INPUT_DIR/CONCEPT_RELATIONSHIP.csv' WITH (FORMAT csv, HEADER true, DELIMITER E'\t', QUOTE E'\b')
${BS}copy athena_vocabs.concept_ancestor FROM '$ATHENA_INPUT_DIR/CONCEPT_ANCESTOR.csv' WITH (FORMAT csv, HEADER true, DELIMITER E'\t', QUOTE E'\b')
${BS}copy athena_vocabs.concept_synonym FROM '$ATHENA_INPUT_DIR/CONCEPT_SYNONYM.csv' WITH (FORMAT csv, HEADER true, DELIMITER E'\t', QUOTE E'\b')
${BS}copy athena_vocabs.vocabulary FROM '$ATHENA_INPUT_DIR/VOCABULARY.csv' WITH (FORMAT csv, HEADER true, DELIMITER E'\t', QUOTE E'\b')
${BS}copy athena_vocabs.relationship FROM '$ATHENA_INPUT_DIR/RELATIONSHIP.csv' WITH (FORMAT csv, HEADER true, DELIMITER E'\t', QUOTE E'\b')
${BS}copy athena_vocabs.concept_class FROM '$ATHENA_INPUT_DIR/CONCEPT_CLASS.csv' WITH (FORMAT csv, HEADER true, DELIMITER E'\t', QUOTE E'\b')
${BS}copy athena_vocabs.domain FROM '$ATHENA_INPUT_DIR/DOMAIN.csv' WITH (FORMAT csv, HEADER true, DELIMITER E'\t', QUOTE E'\b')
EOF
  cat "$SQL_DIR/create_indexes.sql"
  printf '%s\n' "ANALYZE athena_vocabs.concept;" \
    "ANALYZE athena_vocabs.concept_ancestor;" \
    "ANALYZE athena_vocabs.concept_class;" \
    "ANALYZE athena_vocabs.concept_relationship;" \
    "ANALYZE athena_vocabs.concept_synonym;" \
    "ANALYZE athena_vocabs.domain;" \
    "ANALYZE athena_vocabs.drug_strength;" \
    "ANALYZE athena_vocabs.relationship;" \
    "ANALYZE athena_vocabs.vocabulary;"
  printf '%s\n' "REVOKE ALL ON SCHEMA athena_vocabs FROM PUBLIC;" \
    "GRANT USAGE ON SCHEMA athena_vocabs TO vocab_reader;" \
    "GRANT SELECT ON ALL TABLES IN SCHEMA athena_vocabs TO vocab_reader;"
  cat "$SQL_DIR/create_views.sql"
  printf '%s\n' "GRANT USAGE ON SCHEMA omop_csv TO vocab_reader;" \
    "GRANT USAGE ON SCHEMA omop_csv TO PUBLIC;" \
    "GRANT SELECT ON TABLE omop_csv.concept, omop_csv.concept_ancestor, omop_csv.concept_class, omop_csv.concept_relationship, omop_csv.concept_synonym, omop_csv.domain, omop_csv.drug_strength, omop_csv.relationship, omop_csv.source_to_concept_map, omop_csv.vocabulary TO vocab_reader;" \
    "GRANT SELECT ON TABLE omop_csv.concept, omop_csv.concept_ancestor, omop_csv.concept_class, omop_csv.concept_relationship, omop_csv.concept_synonym, omop_csv.domain, omop_csv.drug_strength, omop_csv.relationship, omop_csv.source_to_concept_map, omop_csv.vocabulary TO PUBLIC;"
  # Record staged checksum on the schema for setup/readiness comparison (Task 5).
  esc_agg="$(printf '%s' "$AGG" | sed "s/'/''/g")"
  printf '%s\n' "COMMENT ON SCHEMA athena_vocabs IS 'athena_staged_checksum=$esc_agg';"
  printf '%s\n' "SET athena.staged_checksum = '$esc_agg';"
  cat "$SQL_DIR/validate.sql"
  printf '%s\n' "COMMIT;"
} > "$TMP"

log "loading nine Athena CSVs into athena_vocabs (single transaction)"
psql -v ON_ERROR_STOP=1 -f "$TMP" || die "load transaction failed; prior schema preserved"
log "LOAD_OK aggregate=$AGG"
