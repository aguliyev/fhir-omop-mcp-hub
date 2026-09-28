#!/bin/bash
# Compose + bootstrap integration test (Task 2). Needs Docker; skips otherwise.
# Uses mktemp dir, port 55433, project fhir_omop_mcp_hub_setup_test.
set -eu

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

if ! docker info >/dev/null 2>&1; then
  printf 'SKIP: docker daemon unavailable\n'
  exit 0
fi

fail=0
ok() { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }

TEST_TMP="$(mktemp -d)"
export COMPOSE_PROJECT_NAME="fhir_omop_mcp_hub_setup_test"
export DATA_ROOT="$TEST_TMP/data"
export POSTGRES_HOST_PORT="55433"
export POSTGRES_DB="fhir_omop_mcp_hub"
export POSTGRES_USER="postgres"
export VOCAB_VIEW_TARGET_SCHEMAS="omop_csv"

cleanup() {
  case "$TEST_TMP" in
    /tmp/*|/var/tmp/*)
      "$REPO_ROOT/bin/compose" down -v >/dev/null 2>&1 || true
      # PGDATA files are container-owned; remove them via a container.
      docker run --rm -v "$TEST_TMP:/t" "${POSTGRES_IMAGE:-docker.io/library/postgres:16.4-alpine@sha256:5660c2cbfea50c7a9127d17dc4e48543eedd3d7a41a595a2dfa572471e37e64c}" rm -rf /t/data/postgres >/dev/null 2>&1 || true
      rm -rf "$TEST_TMP"
      ;;
    *) printf 'FAIL: refusing to clean unexpected path %s\n' "$TEST_TMP" >&2 ;;
  esac
}
trap cleanup EXIT

"$REPO_ROOT/bin/prepare-data" >/dev/null

[ "$(cat "$DATA_ROOT/.fhir_omop_mcp_hub_data_root")" = "fhir_omop_mcp_hub" ] && ok "sentinel content" || bad "sentinel content"
[ "$(stat -c %a "$DATA_ROOT/secrets/postgres_password")" = "600" ] && ok "secret mode 0600" || bad "secret mode 0600"

"$REPO_ROOT/bin/compose" up -d postgres >/dev/null

# Wait for health (60s).
healthy=0
for _ in $(seq 1 60); do
  if "$REPO_ROOT/bin/compose" exec -T postgres pg_isready -U postgres -d fhir_omop_mcp_hub >/dev/null 2>&1; then healthy=1; break; fi
  sleep 1
done
[ "$healthy" -eq 1 ] && ok "postgres healthy" || bad "postgres healthy"

# Local-socket auth needs no password; never export PGPASSWORD (argv leak).
dbq() { "$REPO_ROOT/bin/compose" exec -T postgres psql -U postgres -d fhir_omop_mcp_hub -v ON_ERROR_STOP=1 -tA -c "$1"; }

ver="$(dbq "SHOW server_version;" | tr -d ' \r\n')"
case "$ver" in 16.4*) ok "postgres reports 16.4 ($ver)" ;; *) bad "postgres reports 16.4 (got $ver)" ;; esac

binding="$(docker inspect -f '{{(index .NetworkSettings.Ports "5432/tcp" 0).HostIp}}:{{(index .NetworkSettings.Ports "5432/tcp" 0).HostPort}}' "${COMPOSE_PROJECT_NAME}-postgres-1" 2>/dev/null || true)"
[ "$binding" = "127.0.0.1:55433" ] && ok "binds 127.0.0.1:55433" || bad "binds 127.0.0.1:55433 (got $binding)"

if "$REPO_ROOT/bin/compose" up --exit-code-from db_init db_init >/dev/null 2>&1; then ok "db_init first run exits zero"; else bad "db_init first run exits zero"; fi
if "$REPO_ROOT/bin/compose" up --exit-code-from db_init db_init >/dev/null 2>&1; then ok "db_init second run exits zero"; else bad "db_init second run exits zero"; fi

for s in athena_vocabs omop_csv omop_csv_results omop_csv_temp omop_fhir omop_fhir_results omop_fhir_temp ohdsi_webapi; do
  if [ "$(dbq "SELECT count(*) FROM information_schema.schemata WHERE schema_name='$s';" | tr -d ' \r\n')" = "1" ]; then ok "schema $s exists"; else bad "schema $s exists"; fi
done

# PUBLIC must lack CREATE: inspect the schema ACL for a PUBLIC (=) entry with C.
no_public_create() {
  schema="$1"
  acl="$(dbq "SELECT coalesce(nspacl::text,'') FROM pg_namespace WHERE nspname='$schema';" | tr -d ' \r\n')"
  pub="$(printf '%s' "$acl" | tr ',' '\n' | grep '^=' || true)"
  # No PUBLIC entry means no grants to PUBLIC: cannot CREATE.
  [ -z "$pub" ] && return 0
  privs="$(printf '%s' "$pub" | sed -e 's/^=//' -e 's|/.*||')"
  case "$privs" in *C*) return 1 ;; *) return 0 ;; esac
}
if no_public_create public; then ok "PUBLIC cannot CREATE in public"; else bad "PUBLIC cannot CREATE in public"; fi
if no_public_create athena_vocabs; then ok "PUBLIC cannot CREATE in athena_vocabs"; else bad "PUBLIC cannot CREATE in athena_vocabs"; fi

# --- Task 4: Athena vocabulary load, rollback, and replacement ---

if "$REPO_ROOT/bin/compose" --profile athena config --services 2>/dev/null | grep -qx athena_vocabs; then ok "service athena_vocabs defined"; else bad "service athena_vocabs defined"; fi

FIX="$REPO_ROOT/tests/setup/fixtures/athena-valid"
SRC1="$TEST_TMP/src1"
mkdir -p "$SRC1"
cp "$FIX"/*.csv "$SRC1"/
# Fixtures ship one RxNorm concept row; validation requires one valid standard
# concept per required vocabulary, so stage four more family rows with them.
printf '2\tAspirin ingredient\tDrug\tCVX\tIngredient\tS\tCVX-1\t1970-01-01\t2099-12-31\t\n' >>"$SRC1/CONCEPT.csv"
printf '3\tSodium measurement\tMeasurement\tLOINC\tClinical Observation\tS\t1234-5\t1970-01-01\t2099-12-31\t\n' >>"$SRC1/CONCEPT.csv"
printf '4\tAspirin product\tDrug\tSNOMED\tClinical Drug\tS\tSN-1\t1970-01-01\t2099-12-31\t\n' >>"$SRC1/CONCEPT.csv"
printf '5\tMilligram\tUnit\tUCUM\tUnit\tS\tmg\t1970-01-01\t2099-12-31\t\n' >>"$SRC1/CONCEPT.csv"

if "$REPO_ROOT/bin/stage-athena" "$SRC1" >"$TEST_TMP/stage1.log" 2>&1; then ok "stage fixtures"; else bad "stage fixtures"; cat "$TEST_TMP/stage1.log"; fi
if "$REPO_ROOT/bin/load-vocab" >"$TEST_TMP/load1.log" 2>&1; then ok "initial load"; else bad "initial load"; cat "$TEST_TMP/load1.log"; fi
if "$REPO_ROOT/bin/validate-vocab" >/dev/null 2>&1; then ok "validate-vocab passes"; else bad "validate-vocab passes"; fi

N1="$(dbq "SELECT count(*) FROM athena_vocabs.concept;" | tr -d ' \r\n')"
case "$N1" in 5) ok "concept rows=$N1" ;; *) bad "concept rows (got '${N1:-empty}', want 5)"; N1="UNSET-BASELINE" ;; esac

[ -z "$(dbq "SELECT coalesce(vocabulary_version,'') FROM athena_vocabs.vocabulary WHERE vocabulary_id='Cohort Type';" | tr -d ' \r\n')" ] && ok "empty upstream version loads as NULL" || bad "empty upstream version loads as NULL"

for v in concept concept_ancestor concept_class concept_relationship concept_synonym domain drug_strength relationship source_to_concept_map vocabulary; do
  if [ "$(dbq "SELECT relkind FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='omop_csv' AND c.relname='$v';" | tr -d ' \r\n')" = "v" ]; then ok "view omop_csv.$v"; else bad "view omop_csv.$v"; fi
  if [ -z "$(dbq "SELECT to_regclass('omop_fhir.$v');" | tr -d ' \r\n')" ]; then ok "no omop_fhir.$v"; else bad "no omop_fhir.$v"; fi
done

[ "$(dbq "SELECT count(*) FROM omop_csv.concept;" | tr -d ' \r\n')" = "$N1" ] && ok "views read committed load" || bad "views read committed load"
[ "$(dbq "SELECT count(*) FROM athena_vocabs.source_to_concept_map;" | tr -d ' \r\n')" = "0" ] && ok "source_to_concept_map empty" || bad "source_to_concept_map empty"
[ "$(dbq "SELECT has_table_privilege('vocab_reader','athena_vocabs.concept','SELECT');" | tr -d ' \r\n')" = "t" ] && ok "vocab_reader SELECT" || bad "vocab_reader SELECT"
[ "$(dbq "SELECT has_table_privilege('vocab_reader','athena_vocabs.concept','INSERT');" | tr -d ' \r\n')" = "f" ] && ok "vocab_reader read-only" || bad "vocab_reader read-only"
[ "$(dbq "SELECT has_schema_privilege('vocab_reader','athena_vocabs','CREATE');" | tr -d ' \r\n')" = "f" ] && ok "vocab_reader no CREATE" || bad "vocab_reader no CREATE"
[ "$(dbq "SELECT has_table_privilege('vocab_reader','omop_csv.concept','SELECT');" | tr -d ' \r\n')" = "t" ] && ok "vocab_reader view SELECT" || bad "vocab_reader view SELECT"

# Malformed replacement must fail inside one transaction; old counts stay.
SRCBAD="$TEST_TMP/srcbad"
mkdir -p "$SRCBAD"
cp "$SRC1"/*.csv "$SRCBAD"/
printf 'BAD\tBroken\tDrug\tRxNorm\tIngredient\tS\tbad\t1970-01-01\t2099-12-31\t\n' >>"$SRCBAD/CONCEPT.csv"
if "$REPO_ROOT/bin/stage-athena" "$SRCBAD" --replace >/dev/null 2>&1; then ok "stage malformed replacement"; else bad "stage malformed replacement"; fi
if printf 'YES\n' | "$REPO_ROOT/bin/load-vocab" --replace >"$TEST_TMP/loadbad.log" 2>&1; then bad "malformed load fails"; else ok "malformed load fails"; fi
# Must fail in the DB COPY/transaction, not on approval/flag handling. The
# container output lands in the sanitized log named by the failure message.
BADLOG="$(sed -n 's/.*see //p' "$TEST_TMP/loadbad.log" | tail -n 1)"
if [ -n "$BADLOG" ] && [ -f "$BADLOG" ] && grep -Ei "invalid input syntax|COPY|load transaction failed" "$BADLOG" >/dev/null 2>&1; then
  ok "malformed load fails in DB COPY"
else
  bad "malformed load fails in DB COPY"; cat "$TEST_TMP/loadbad.log"
fi
if grep -Ei "unknown argument|refusing to replace|confirmation required" "$TEST_TMP/loadbad.log" >/dev/null 2>&1; then
  bad "no approval-path error"; cat "$TEST_TMP/loadbad.log"
else
  ok "no approval-path error"
fi
[ "$(dbq "SELECT count(*) FROM athena_vocabs.concept;" | tr -d ' \r\n')" = "$N1" ] && ok "rollback preserves counts" || bad "rollback preserves counts"
if "$REPO_ROOT/bin/validate-vocab" >/dev/null 2>&1; then ok "prior schema intact"; else bad "prior schema intact"; fi

# Changed data is refused without --replace, then succeeds with confirmation.
if "$REPO_ROOT/bin/load-vocab" >/dev/null 2>&1; then bad "--replace guard"; else ok "--replace guard"; fi
SRC2="$TEST_TMP/src2"
mkdir -p "$SRC2"
cp "$SRC1"/*.csv "$SRC2"/
sed -i 's/2024-01-01/2024-06-01/' "$SRC2/VOCABULARY.csv"
if printf 'YES\n' | "$REPO_ROOT/bin/stage-athena" "$SRC2" --replace >/dev/null 2>&1; then ok "stage changed replacement"; else bad "stage changed replacement"; fi
if printf 'YES\n' | "$REPO_ROOT/bin/load-vocab" --replace >/dev/null 2>&1; then ok "confirmed replacement"; else bad "confirmed replacement"; fi
[ "$(dbq "SELECT vocabulary_version FROM omop_csv.vocabulary WHERE vocabulary_id='CVX';" | tr -d ' \r\n')" = "2024-06-01" ] && ok "views point to new load" || bad "views point to new load"
[ "$(dbq "SELECT count(*) FROM athena_vocabs.concept;" | tr -d ' \r\n')" = "$N1" ] && ok "replacement counts intact" || bad "replacement counts intact"
if "$REPO_ROOT/bin/validate-vocab" >/dev/null 2>&1; then ok "validate-vocab passes after replace"; else bad "validate-vocab passes after replace"; fi

# db_init stays idempotent after vocabulary loads and preserves vocab data.
if "$REPO_ROOT/bin/compose" up --exit-code-from db_init db_init >/dev/null 2>&1; then ok "db_init third run exits zero"; else bad "db_init third run exits zero"; fi
[ "$(dbq "SELECT count(*) FROM athena_vocabs.concept;" | tr -d ' \r\n')" = "$N1" ] && ok "db_init preserves vocab" || bad "db_init preserves vocab"
[ "$(dbq "SELECT count(*) FROM omop_csv.concept;" | tr -d ' \r\n')" = "$N1" ] && ok "db_init preserves views" || bad "db_init preserves views"

if [ "$fail" -ne 0 ]; then printf 'compose-setup: FAILED\n'; exit 1; fi
printf 'compose-setup: PASSED\n'
