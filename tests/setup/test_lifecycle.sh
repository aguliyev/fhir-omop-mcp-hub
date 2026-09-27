#!/bin/sh
# Lifecycle acceptance test for Task 5 (bin/setup, bin/validate-setup, bin/reset).
# Hermetic: every case builds a sandbox repo + unique data root under mktemp -d,
# with stubbed sibling commands. No Docker, no network, no shared state.
# Assumed sibling interfaces (owned by other tasks/agents):
#   bin/lib/common.sh        sourced if present; scripts fall back inline if absent
#   etc/setup.env(.example)  COMPOSE_PROJECT_NAME, DATA_ROOT, POSTGRES_IMAGE,
#                            POSTGRES_DB, POSTGRES_USER, POSTGRES_HOST_PORT,
#                            VOCAB_VIEW_TARGET_SCHEMAS
#   bin/check-prerequisites  exit 0 on pass; prints PASS:/FAIL: lines
#   bin/prepare-data         creates data tree + sentinel, canonicalizes DATA_ROOT
#   bin/start                no args; prepares data, starts postgres, runs db_init
#   bin/compose ...          passthrough to `docker compose` for this project;
#                            supports `up --exit-code-from db_init db_init`,
#                            `exec -T [-e ...] postgres psql ...`,
#                            `exec -T postgres pg_isready ...`, `down`
#   bin/load-vocab           loads staged manifest; exit 0 on success.
#                            setup NEVER passes --yes/--replace (operator
#                            approval stays manual + interactive in load-vocab)
#   bin/validate-vocab       read-only validate.sql run; exit 0 on pass
#   bin/validate-setup       read-only gate incl. staged/live/marker agreement;
#                            honors $READY_ENV_OVERRIDE (temp marker used by setup)
# Env semantics everywhere (mirrors bin/lib/common.sh): explicit environment
# wins over etc/setup.env; the file only fills unset variables.
# Live proof (db/athena/load.sh commits it, read-only here):
#   COMMENT ON SCHEMA athena_vocabs IS 'athena_staged_checksum=<hex>'
#   queried via obj_description('athena_vocabs'::regnamespace); empty = never
#   loaded. Stubbed per-case via $STUB_LIVE_SUM (empty = no live load).
# Conventions asserted here (also documented in bin/setup):
#   staged manifest:  <data-root>/athena_input/current/manifest.sha256 in the
#                     real 3-field format "<sha> <bytes> <basename>" written by
#                     bin/stage-athena (NOT sha256sum -c compatible; content is
#                     verified field-by-field instead)
#   aggregate:        sha256 of sorted per-file hashes in the manifest, i.e.
#                     awk '{print $1}' manifest | LC_ALL=C sort | sha256sum
#                     (same definition as bin/load-vocab, bin/validate-vocab,
#                     db/athena/load.sh)
#   loaded marker:    <data-root>/work/setup/loaded_athena.sha256 (hex only).
#                     Advisory cache only; authority is the live schema comment.
#   readiness marker: <data-root>/work/setup/ready.env with SETUP_STATUS,
#                     POSTGRES_VERSION, DATABASE_NAME, VOCAB_SCHEMA,
#                     ATHENA_MANIFEST_SHA256, VOCAB_VERSION, VALIDATED_AT
#   exit 20 + ATHENA_REQUIRED (+ https://athena.ohdsi.org/) when nothing staged
#   exit 21 + ATHENA_REPLACE_APPROVAL_REQUIRED when loaded aggregate differs
#   reset confirm phrase: RESET fhir_omop_mcp_hub (read from stdin, exact match)
#   sentinel: <data-root>/.fhir_omop_mcp_hub_data_root containing only fhir_omop_mcp_hub
set -eu

REAL_ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
ATHENA_URL="https://athena.ohdsi.org/"
pass=0
fail=0

ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }

# Build sandbox: $1 = case name. Sets globals SANDBOX, SREPO, SDATA, CALLS.
new_sandbox() {
  SANDBOX="$(mktemp -d)"
  SREPO="$SANDBOX/repo"
  SDATA="$SANDBOX/data-root-$1"
  CALLS="$SANDBOX/calls.log"
  mkdir -p "$SREPO/bin" "$SREPO/etc" "$SREPO/db/athena" "$SDATA"
  : >"$CALLS"
  unset STUB_LIVE_SUM VALIDATE_EXIT DB_INIT_FAIL_SECOND LOAD_EXIT DATA_ROOT COMPOSE_DOWN_TAMPER TAMPER_TARGET || true
  for s in setup validate-setup reset; do
    if [ -f "$REAL_ROOT/bin/$s" ]; then
      cp "$REAL_ROOT/bin/$s" "$SREPO/bin/$s"
    fi
    chmod +x "$SREPO/bin/$s" 2>/dev/null || true
  done
  cp "$REAL_ROOT/db/athena/verify_manifest.sh" "$SREPO/db/athena/verify_manifest.sh"
  cat >"$SREPO/etc/setup.env.example" <<EOF
COMPOSE_PROJECT_NAME=lifecycle_$1
DATA_ROOT=$SDATA
POSTGRES_IMAGE=docker.io/library/postgres:16.4-alpine@sha256:5660c2cbfea50c7a9127d17dc4e48543eedd3d7a41a595a2dfa572471e37e64c
POSTGRES_DB=fhir_omop_mcp_hub
POSTGRES_USER=postgres
POSTGRES_HOST_PORT=55434
VOCAB_VIEW_TARGET_SCHEMAS=omop_csv
EOF
  cp "$SREPO/etc/setup.env.example" "$SREPO/etc/setup.env"
  # --- stubs for sibling commands owned by other agents ---
  cat >"$SREPO/bin/check-prerequisites" <<'EOS'
#!/bin/sh
echo "PASS: stub preflight"
exit "${PREFLIGHT_EXIT:-0}"
EOS
  cat >"$SREPO/bin/prepare-data" <<'EOS'
#!/bin/sh
set -eu
ROOT="${REPO_ROOT:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}"
# Explicit environment wins over the file (mirrors bin/lib/common.sh).
if [ -z "${DATA_ROOT:-}" ] && [ -f "$ROOT/etc/setup.env" ]; then
  # shellcheck disable=SC1091
  set -a; . "$ROOT/etc/setup.env"; set +a
fi
DR="${DATA_ROOT:-$ROOT/data}"
case "$DR" in
  /*) ;;
  *) DR="$ROOT/$DR" ;;
esac
mkdir -p "$DR/athena_input" "$DR/work/setup" "$DR/secrets"
printf 'fhir_omop_mcp_hub' >"$DR/.fhir_omop_mcp_hub_data_root"
# Real prepare-data creates this; lifecycle scripts under test must NOT read it.
printf 'stub-secret' >"$DR/secrets/postgres_password"
chmod 600 "$DR/secrets/postgres_password"
echo "stub-prepare $DR" >>"${CALLS_DIR:-/dev/null}"
EOS
  cat >"$SREPO/bin/start" <<'EOS'
#!/bin/sh
echo "stub-start $*" >>"${CALLS_DIR:-/dev/null}"
exit 0
EOS
  cat >"$SREPO/bin/compose" <<'EOS'
#!/bin/sh
echo "compose $*" >>"${CALLS_DIR:-/dev/null}"
if [ "${1:-}" = "exec" ]; then
  case "$*" in
    *SHOW*server_version*) printf '16.4\n';;
    *vocabulary_version*)
      # Faithful to PostgreSQL: ORDER BY <position> is invalid inside a
      # DISTINCT aggregate, so reject the old syntax like the real server.
      case "$*" in *"ORDER BY 1"*)
        echo "ERROR: in an aggregate with DISTINCT, ORDER BY expressions must appear in argument list" >&2
        exit 1;;
      esac
      printf '2024.0-stub\n';;
    *obj_description*|*athena_staged_checksum*)
      if [ -f "${CALLS_DIR}.live" ]; then cat "${CALLS_DIR}.live"; else printf '%s\n' "${STUB_LIVE_SUM:-}"; fi;;
    *pg_isready*) exit "${PG_READY_EXIT:-0}";;
  esac
  exit 0
fi
if [ "${1:-}" = "up" ]; then
  n=0
  if [ -f "${CALLS_DIR}.upcount" ]; then n=$(cat "${CALLS_DIR}.upcount"); fi
  n=$((n + 1)); printf '%s' "$n" >"${CALLS_DIR}.upcount"
  if [ "${DB_INIT_FAIL_SECOND:-0}" = "1" ] && [ "$n" -ge 2 ]; then exit 1; fi
  exit "${DB_INIT_EXIT:-0}"
fi
if [ "${1:-}" = "down" ]; then
  # TOCTOU hook: simulate the target changing while compose down runs.
  if [ "${COMPOSE_DOWN_TAMPER:-0}" = "1" ] && [ -n "${TAMPER_TARGET:-}" ]; then
    printf 'foreign' >"$TAMPER_TARGET/.fhir_omop_mcp_hub_data_root"
  fi
  exit 0
fi
exit 0
EOS
  cat >"$SREPO/bin/load-vocab" <<'EOS'
#!/bin/sh
echo "load-vocab $*" >>"${CALLS_DIR:-/dev/null}"
if [ "${LOAD_EXIT:-0}" = "0" ]; then
  # Faithful to db/athena/load.sh: a successful load commits the staged
  # aggregate as the live schema comment, which setup observes via compose.
  ROOT="${REPO_ROOT:-.}"
  DR="${DATA_ROOT:-}"
  if [ -z "$DR" ]; then
    DR="$(sed -n 's/^DATA_ROOT=//p' "$ROOT/etc/setup.env" 2>/dev/null | head -n 1)"
  fi
  DR="${DR:-$ROOT/data}"
  if [ -n "$DR" ] && [ -f "$DR/athena_input/current/manifest.sha256" ]; then
    awk '{print $1}' "$DR/athena_input/current/manifest.sha256" | LC_ALL=C sort | sha256sum | awk '{print $1}' >"${CALLS_DIR}.live"
  fi
fi
exit "${LOAD_EXIT:-0}"
EOS
  cat >"$SREPO/bin/validate-vocab" <<'EOS'
#!/bin/sh
echo "validate-vocab" >>"${CALLS_DIR:-/dev/null}"
if [ "${VALIDATE_EXIT:-0}" != "0" ]; then echo "FAIL: stub validation"; exit 1; fi
printf 'vocabulary_id | vocabulary_version\nRxNorm | 2024.0-stub\nconcept rows=100\n'
exit 0
EOS
  chmod +x "$SREPO/bin/"*
}

sandbox_env() {
  # export per-case env; must be eval'd: sandbox_env $SANDBOX
  printf 'REPO_ROOT=%s CALLS_DIR=%s/calls.log\n' "$1/repo" "$1"
}

manifest_agg() {
  # $1 = manifest path; shared aggregate definition (first field, sorted).
  awk '{print $1}' "$1" | LC_ALL=C sort | sha256sum | awk '{print $1}'
}

write_manifest() {
  # $1 = staged dir; writes the sorted 3-field manifest for the nine files.
  : >"$1/manifest.sha256"
  for f in CONCEPT.csv CONCEPT_ANCESTOR.csv CONCEPT_CLASS.csv CONCEPT_RELATIONSHIP.csv CONCEPT_SYNONYM.csv DOMAIN.csv DRUG_STRENGTH.csv RELATIONSHIP.csv VOCABULARY.csv; do
    h="$(sha256sum "$1/$f" | awk '{print $1}')"
    b="$(wc -c <"$1/$f" | tr -d '[:space:]')"
    printf '%s %s %s\n' "$h" "$b" "$f" >>"$1/manifest.sha256"
  done
}

stage_manifest() {
  # $1 = data root, $2 = optional bytes appended to CONCEPT.csv.
  # Stages all nine real fixture CSVs plus a valid sorted 3-field manifest
  # into $1/athena_input/current, and prints the aggregate hex.
  dir="$1/athena_input/current"
  mkdir -p "$dir"
  for f in CONCEPT.csv CONCEPT_ANCESTOR.csv CONCEPT_CLASS.csv CONCEPT_RELATIONSHIP.csv CONCEPT_SYNONYM.csv DOMAIN.csv DRUG_STRENGTH.csv RELATIONSHIP.csv VOCABULARY.csv; do
    cp "$REAL_ROOT/tests/setup/fixtures/athena-valid/$f" "$dir/$f"
  done
  if [ -n "${2:-}" ]; then printf '%s' "$2" >>"$dir/CONCEPT.csv"; fi
  write_manifest "$dir"
  manifest_agg "$dir/manifest.sha256"
}

# --- T1: missing local env is recreated from example, then ATHENA_REQUIRED ---
s=$(mktemp -d); rm -rf "$s"; SANDBOX=""; new_sandbox "t1"
rm "$SREPO/etc/setup.env"
eval "$(sandbox_env "$SANDBOX")"; export REPO_ROOT CALLS_DIR
if "$SREPO/bin/setup" >"$SANDBOX/out.txt" 2>&1; then code=0; else code=$?; fi
if [ "$code" = "20" ] && [ -f "$SREPO/etc/setup.env" ] \
  && grep -q ATHENA_REQUIRED "$SANDBOX/out.txt" \
  && grep -q "$ATHENA_URL" "$SANDBOX/out.txt"; then
  ok "T1 missing env copied, exit 20 ATHENA_REQUIRED"
else
  bad "T1 missing env (code=$code)"; cat "$SANDBOX/out.txt" 2>/dev/null || true
fi
rm -rf "$SANDBOX"

# --- T2: no staged Athena -> exit 20, no marker ---
new_sandbox "t2"
eval "$(sandbox_env "$SANDBOX")"; export REPO_ROOT CALLS_DIR
if "$SREPO/bin/setup" >"$SANDBOX/out.txt" 2>&1; then code=0; else code=$?; fi
if [ "$code" = "20" ] && grep -q ATHENA_REQUIRED "$SANDBOX/out.txt" \
  && grep -q "$ATHENA_URL" "$SANDBOX/out.txt" \
  && [ ! -f "$SDATA/work/setup/ready.env" ]; then
  ok "T2 unstaged exit 20, no marker"
else
  bad "T2 unstaged (code=$code)"; cat "$SANDBOX/out.txt" 2>/dev/null || true
fi

# --- T3: valid staged fresh -> load, exit 0, marker complete, no secrets ---
agg=$(stage_manifest "$SDATA")
if "$SREPO/bin/setup" >"$SANDBOX/out2.txt" 2>&1; then code=0; else code=$?; fi
M="$SDATA/work/setup/ready.env"
if [ "$code" = "0" ] && grep -q '^load-vocab' "$CALLS" 2>/dev/null \
  && [ -f "$M" ] \
  && grep -qx 'SETUP_STATUS=READY' "$M" \
  && grep -qx 'DATABASE_NAME=fhir_omop_mcp_hub' "$M" \
  && grep -qx 'VOCAB_SCHEMA=athena_vocabs' "$M" \
  && grep -qx "ATHENA_MANIFEST_SHA256=$agg" "$M" \
  && grep -qx 'VOCAB_VERSION=2024.0-stub' "$M" \
  && grep -qx 'POSTGRES_VERSION=16.4' "$M" \
  && grep -q '^VALIDATED_AT=' "$M" \
  && ! grep -i -E 'password|secret' "$M" \
  && ! ls "$SDATA/work/setup" | grep -q '^ready\.env\.'; then
  ok "T3 fresh staged loads, marker complete"
else
  bad "T3 fresh staged (code=$code)"; cat "$SANDBOX/out2.txt" 2>/dev/null || true; cat "$M" 2>/dev/null || true
fi
# The stub load-vocab committed the aggregate as the live schema comment,
# exactly like db/athena/load.sh does; later cases observe it via compose.

# --- T4: same manifest -> skip reload, still exit 0 ---
: >"$CALLS"
if "$SREPO/bin/setup" >"$SANDBOX/out3.txt" 2>&1; then code=0; else code=$?; fi
if [ "$code" = "0" ] && ! grep -q '^load-vocab' "$CALLS" 2>/dev/null \
  && [ -f "$M" ]; then
  ok "T4 same manifest skips reload"
else
  bad "T4 idempotent rerun (code=$code)"; cat "$SANDBOX/out3.txt" 2>/dev/null || true
fi

# --- T5: live schema differs from staged -> exit 21, no reload ---
# Restage different content: live still carries A, staged is now B.
aggB=$(stage_manifest "$SDATA" "concept-row-2")
: >"$CALLS"
if "$SREPO/bin/setup" >"$SANDBOX/out4.txt" 2>&1; then code=0; else code=$?; fi
if [ "$code" = "21" ] && grep -q ATHENA_REPLACE_APPROVAL_REQUIRED "$SANDBOX/out4.txt" \
  && ! grep -q '^load-vocab' "$CALLS" 2>/dev/null \
  && grep -qx "ATHENA_MANIFEST_SHA256=$agg" "$M"; then
  ok "T5 changed live data requires approval, marker untouched"
else
  bad "T5 replace guard (code=$code)"; cat "$SANDBOX/out4.txt" 2>/dev/null || true
fi
rm -rf "$SANDBOX"

# --- T6: failed validation -> nonzero, no marker ---
new_sandbox "t6"
eval "$(sandbox_env "$SANDBOX")"; export REPO_ROOT CALLS_DIR
stage_manifest "$SDATA" >/dev/null
VALIDATE_EXIT=1; export VALIDATE_EXIT
if "$SREPO/bin/setup" >"$SANDBOX/out.txt" 2>&1; then code=0; else code=$?; fi
unset VALIDATE_EXIT
if [ "$code" != "0" ] && [ "$code" != "20" ] && [ "$code" != "21" ] \
  && [ ! -f "$SDATA/work/setup/ready.env" ]; then
  ok "T6 validation failure, no marker"
else
  bad "T6 validation failure (code=$code)"; cat "$SANDBOX/out.txt" 2>/dev/null || true
fi
rm -rf "$SANDBOX"

# --- T7: validate-setup read-only, checksum agreement enforced ---
new_sandbox "t7"
eval "$(sandbox_env "$SANDBOX")"; export REPO_ROOT CALLS_DIR
agg7=$(stage_manifest "$SDATA")
"$SREPO/bin/setup" >/dev/null 2>&1
: >"$CALLS"
if "$SREPO/bin/validate-setup" >"$SANDBOX/v.txt" 2>&1; then code=0; else code=$?; fi
if [ "$code" = "0" ] && ! grep -q '^load-vocab' "$CALLS" 2>/dev/null \
  && grep -q 'POSTGRES_VERSION=16.4' "$SANDBOX/v.txt" \
  && grep -q '2024.0-stub' "$SANDBOX/v.txt"; then
  ok "T7 validate-setup read-only pass"
else
  bad "T7 validate-setup (code=$code)"; cat "$SANDBOX/v.txt" 2>/dev/null || true
fi
printf 'tampered' >>"$SDATA/athena_input/current/manifest.sha256"
if "$SREPO/bin/validate-setup" >/dev/null 2>&1; then code=0; else code=$?; fi
if [ "$code" != "0" ]; then
  ok "T7 validate-setup rejects checksum drift"
else
  bad "T7 checksum drift undetected"
fi
# The host loaded file is advisory only: without it, live proof still passes.
# (The drift failure above removed the marker, so re-establish it first.)
write_manifest "$SDATA/athena_input/current"
"$SREPO/bin/setup" >/dev/null 2>&1
rm -f "$SDATA/work/setup/loaded_athena.sha256"
if "$SREPO/bin/validate-setup" >/dev/null 2>&1; then code=0; else code=$?; fi
if [ "$code" != "0" ]; then
  bad "T7 validate-setup without loaded file (code=$code)"
else
  ok "T7 loaded file optional when live proof agrees"
fi
rm -rf "$SANDBOX"

# --- T8: reset guards + happy path ---
new_sandbox "t8"
eval "$(sandbox_env "$SANDBOX")"; export REPO_ROOT CALLS_DIR
printf 'fhir_omop_mcp_hub' >"$SDATA/.fhir_omop_mcp_hub_data_root"
mkdir -p "$SDATA/athena_input/current"
printf 'x' >"$SDATA/athena_input/current/manifest.sha256"
if printf 'WRONG\n' | "$SREPO/bin/reset" >/dev/null 2>&1; then code=0; else code=$?; fi
if [ "$code" != "0" ] && [ -d "$SDATA" ]; then ok "T8a reset rejects wrong phrase"; else bad "T8a reset wrong phrase (code=$code)"; fi
rm -f "$SDATA/.fhir_omop_mcp_hub_data_root"
if printf 'RESET fhir_omop_mcp_hub\n' | "$SREPO/bin/reset" >/dev/null 2>&1; then code=0; else code=$?; fi
if [ "$code" != "0" ] && [ -d "$SDATA" ]; then ok "T8b reset rejects missing sentinel"; else bad "T8b reset missing sentinel (code=$code)"; fi
printf 'fhir_omop_mcp_hub' >"$SDATA/.fhir_omop_mcp_hub_data_root"
ln -s "$SDATA" "$SANDBOX/linkroot"
printf 'COMPOSE_PROJECT_NAME=lifecycle_t8\nDATA_ROOT=%s\nPOSTGRES_DB=fhir_omop_mcp_hub\nPOSTGRES_USER=postgres\n' "$SANDBOX/linkroot" >"$SREPO/etc/setup.env"
if printf 'RESET fhir_omop_mcp_hub\n' | "$SREPO/bin/reset" >/dev/null 2>&1; then code=0; else code=$?; fi
if [ "$code" != "0" ] && [ -d "$SDATA" ]; then ok "T8c reset rejects symlink"; else bad "T8c reset symlink (code=$code)"; fi
printf 'COMPOSE_PROJECT_NAME=lifecycle_t8\nDATA_ROOT=%s\nPOSTGRES_DB=fhir_omop_mcp_hub\nPOSTGRES_USER=postgres\n' "$SDATA" >"$SREPO/etc/setup.env"
: >"$CALLS"
if printf 'RESET fhir_omop_mcp_hub\n' | "$SREPO/bin/reset" >"$SANDBOX/r.txt" 2>&1; then code=0; else code=$?; fi
if [ "$code" = "0" ] && [ ! -e "$SDATA" ] && grep -q '^compose down' "$CALLS" 2>/dev/null \
  && grep -qi 'untouched' "$SANDBOX/r.txt"; then
  ok "T8d reset happy path removes only target"
else
  bad "T8d reset happy path (code=$code)"; cat "$SANDBOX/r.txt" 2>/dev/null || true
fi
rm -rf "$SANDBOX"

# --- T9: reset rejects /, home, repo root ---
new_sandbox "t9"
eval "$(sandbox_env "$SANDBOX")"; export REPO_ROOT CALLS_DIR
for target in "/" "$HOME" "$SREPO"; do
  printf 'COMPOSE_PROJECT_NAME=lifecycle_t9\nDATA_ROOT=%s\n' "$target" >"$SREPO/etc/setup.env"
  if printf 'RESET fhir_omop_mcp_hub\n' | "$SREPO/bin/reset" >/dev/null 2>&1; then
    bad "T9 reset allowed $target"
  else
    ok "T9 reset rejects $target"
  fi
done
rm -rf "$SANDBOX"

# --- T10: real bash-only common.sh must not break POSIX sh or bash runs ---
new_sandbox "t10"
eval "$(sandbox_env "$SANDBOX")"; export REPO_ROOT CALLS_DIR
mkdir -p "$SREPO/bin/lib"
cp "$REAL_ROOT/bin/lib/common.sh" "$SREPO/bin/lib/common.sh"
if sh "$SREPO/bin/setup" >"$SANDBOX/out-sh.txt" 2>&1; then code=0; else code=$?; fi
if [ "$code" = "20" ] && grep -q ATHENA_REQUIRED "$SANDBOX/out-sh.txt"; then
  ok "T10a setup works under POSIX sh with bash-only common.sh present"
else
  bad "T10a setup under sh (code=$code)"; cat "$SANDBOX/out-sh.txt" 2>/dev/null || true
fi
if bash "$SREPO/bin/setup" >"$SANDBOX/out-bash.txt" 2>&1; then code=0; else code=$?; fi
if [ "$code" = "20" ] && grep -q ATHENA_REQUIRED "$SANDBOX/out-bash.txt"; then
  ok "T10b setup works under bash with real common.sh sourced"
else
  bad "T10b setup under bash (code=$code)"; cat "$SANDBOX/out-bash.txt" 2>/dev/null || true
fi
rm -rf "$SANDBOX"

# --- T11: gate failure after a good load leaves no READY marker ---
new_sandbox "t11"
eval "$(sandbox_env "$SANDBOX")"; export REPO_ROOT CALLS_DIR
stage_manifest "$SDATA" >/dev/null
DB_INIT_FAIL_SECOND=1; export DB_INIT_FAIL_SECOND
if "$SREPO/bin/setup" >"$SANDBOX/out.txt" 2>&1; then code=0; else code=$?; fi
unset DB_INIT_FAIL_SECOND
if [ "$code" != "0" ] && [ "$code" != "20" ] && [ "$code" != "21" ] \
  && ! ls "$SDATA/work/setup" 2>/dev/null | grep -q '^ready\.env'; then
  ok "T11 gate failure leaves no marker"
else
  bad "T11 gate failure (code=$code)"; cat "$SANDBOX/out.txt" 2>/dev/null || true
fi
rm -rf "$SANDBOX"

# --- T13: manual load-vocab --replace outside setup, then rerun setup ---
new_sandbox "t13"
eval "$(sandbox_env "$SANDBOX")"; export REPO_ROOT CALLS_DIR
aggA=$(stage_manifest "$SDATA" "concept-row-A")
"$SREPO/bin/setup" >/dev/null 2>&1
# Operator stages a new export and runs an approved manual replace outside setup.
aggB=$(stage_manifest "$SDATA" "concept-row-B")
"$SREPO/bin/load-vocab" --replace >/dev/null 2>&1
# Host cache is now stale (still A) but live carries B: setup must not block.
if [ "$(cat "$SDATA/work/setup/loaded_athena.sha256")" != "$aggA" ]; then
  bad "T13 fixture did not leave a stale host cache"
else
  : >"$CALLS"
  if "$SREPO/bin/setup" >"$SANDBOX/out.txt" 2>&1; then code=0; else code=$?; fi
  M13="$SDATA/work/setup/ready.env"
  if [ "$code" = "0" ] && ! grep -q '^load-vocab' "$CALLS" 2>/dev/null \
    && [ "$(cat "$SDATA/work/setup/loaded_athena.sha256")" = "$aggB" ] \
    && grep -qx "ATHENA_MANIFEST_SHA256=$aggB" "$M13"; then
    ok "T13 manual replace then rerun skips reload, heals cache"
  else
    bad "T13 manual replace rerun (code=$code)"; cat "$SANDBOX/out.txt" 2>/dev/null || true
  fi
fi
rm -rf "$SANDBOX"

# --- T14: host file claims loaded but live schema disagrees -> exit 21 ---
new_sandbox "t14"
eval "$(sandbox_env "$SANDBOX")"; export REPO_ROOT CALLS_DIR
aggT=$(stage_manifest "$SDATA")
mkdir -p "$SDATA/work/setup"
printf '%s' "$aggT" >"$SDATA/work/setup/loaded_athena.sha256"
STUB_LIVE_SUM="live-schema-holds-something-else"; export STUB_LIVE_SUM
: >"$CALLS"
if "$SREPO/bin/setup" >"$SANDBOX/out.txt" 2>&1; then code=0; else code=$?; fi
if [ "$code" = "21" ] && grep -q ATHENA_REPLACE_APPROVAL_REQUIRED "$SANDBOX/out.txt" \
  && ! grep -q '^load-vocab' "$CALLS" 2>/dev/null \
  && [ ! -f "$SDATA/work/setup/ready.env" ]; then
  ok "T14 live schema is authority over host file"
else
  bad "T14 live authority (code=$code)"; cat "$SANDBOX/out.txt" 2>/dev/null || true
fi
rm -rf "$SANDBOX"

# --- T15: staged file content rots after staging -> setup fails, no marker ---
new_sandbox "t15"
eval "$(sandbox_env "$SANDBOX")"; export REPO_ROOT CALLS_DIR
stage_manifest "$SDATA" >/dev/null
"$SREPO/bin/setup" >/dev/null 2>&1
printf 'tampered-bytes' >>"$SDATA/athena_input/current/CONCEPT.csv"
if "$SREPO/bin/setup" >"$SANDBOX/out.txt" 2>&1; then code=0; else code=$?; fi
if [ "$code" != "0" ] && [ "$code" != "20" ] && [ "$code" != "21" ] \
  && [ ! -f "$SDATA/work/setup/ready.env" ]; then
  ok "T15 content verification fails closed, no marker"
else
  bad "T15 content verification (code=$code)"; cat "$SANDBOX/out.txt" 2>/dev/null || true
fi
rm -rf "$SANDBOX"

# --- T12: owned scripts must not handle the DB secret, nor auto-approve loads ---
if grep -q 'PGPASSWORD' "$REAL_ROOT/bin/setup" "$REAL_ROOT/bin/validate-setup" "$REAL_ROOT/bin/reset" 2>/dev/null; then
  bad "T12 PGPASSWORD referenced in lifecycle scripts"
else
  ok "T12 no PGPASSWORD in lifecycle scripts"
fi
if grep -q 'secrets/postgres_password' "$REAL_ROOT/bin/setup" "$REAL_ROOT/bin/validate-setup" "$REAL_ROOT/bin/reset" 2>/dev/null; then
  bad "T12 secret file read in lifecycle scripts"
else
  ok "T12 no secret file read in lifecycle scripts"
fi
if grep -E -q '"bin/load-vocab" +-' "$REAL_ROOT/bin/setup" 2>/dev/null; then
  bad "T12 setup passes flags to load-vocab (approval must stay manual)"
else
  ok "T12 setup never auto-approves load-vocab"
fi

# --- T16: no filesystem mutation before preflight passes ---
new_sandbox "t16"
eval "$(sandbox_env "$SANDBOX")"; export REPO_ROOT CALLS_DIR
printf 'COMPOSE_PROJECT_NAME=lifecycle_t16\nDATA_ROOT=%s\nPOSTGRES_DB=fhir_omop_mcp_hub\nPOSTGRES_USER=postgres\n' \
  "$SANDBOX/never-created" >"$SREPO/etc/setup.env"
PREFLIGHT_EXIT=1; export PREFLIGHT_EXIT
if "$SREPO/bin/setup" >/dev/null 2>&1; then code=0; else code=$?; fi
unset PREFLIGHT_EXIT
if [ "$code" != "0" ] && [ ! -e "$SANDBOX/never-created" ]; then
  ok "T16 failed preflight creates nothing"
else
  bad "T16 preflight-time mutation (code=$code)"
fi
rm -rf "$SANDBOX"

# --- T17: explicit DATA_ROOT env override wins over etc/setup.env ---
new_sandbox "t17"
eval "$(sandbox_env "$SANDBOX")"; export REPO_ROOT CALLS_DIR
OVR="$SANDBOX/env-override"
aggO=$(stage_manifest "$OVR" "override-row")
DATA_ROOT="$OVR"; export DATA_ROOT
if "$SREPO/bin/setup" >"$SANDBOX/out.txt" 2>&1; then code=0; else code=$?; fi
unset DATA_ROOT
if [ "$code" = "0" ] \
  && grep -qx "ATHENA_MANIFEST_SHA256=$aggO" "$OVR/work/setup/ready.env" \
  && [ ! -f "$SDATA/work/setup/ready.env" ]; then
  ok "T17 env override wins over file"
else
  bad "T17 env override (code=$code)"; cat "$SANDBOX/out.txt" 2>/dev/null || true
fi
rm -rf "$SANDBOX"

# --- T18: validate-setup enforces staged content verification ---
new_sandbox "t18"
eval "$(sandbox_env "$SANDBOX")"; export REPO_ROOT CALLS_DIR
stage_manifest "$SDATA" >/dev/null
"$SREPO/bin/setup" >/dev/null 2>&1
printf 'rot-bytes' >>"$SDATA/athena_input/current/CONCEPT.csv"
if "$SREPO/bin/validate-setup" >"$SANDBOX/v.txt" 2>&1; then code=0; else code=$?; fi
if [ "$code" != "0" ] && [ ! -f "$SDATA/work/setup/ready.env" ]; then
  ok "T18 validate-setup rejects rotted staged content"
else
  bad "T18 staged content gate (code=$code)"; cat "$SANDBOX/v.txt" 2>/dev/null || true
fi
rm -rf "$SANDBOX"

# --- T19: reset refuses a symlink at any path component ---
new_sandbox "t19"
eval "$(sandbox_env "$SANDBOX")"; export REPO_ROOT CALLS_DIR
mkdir -p "$SANDBOX/real/data-root-t19"
printf 'fhir_omop_mcp_hub' >"$SANDBOX/real/data-root-t19/.fhir_omop_mcp_hub_data_root"
ln -s "$SANDBOX/real" "$SANDBOX/link"
printf 'COMPOSE_PROJECT_NAME=lifecycle_t19\nDATA_ROOT=%s\nPOSTGRES_DB=fhir_omop_mcp_hub\nPOSTGRES_USER=postgres\n' \
  "$SANDBOX/link/data-root-t19" >"$SREPO/etc/setup.env"
if printf 'RESET fhir_omop_mcp_hub\n' | "$SREPO/bin/reset" >/dev/null 2>&1; then code=0; else code=$?; fi
if [ "$code" != "0" ] && [ -d "$SANDBOX/real/data-root-t19" ]; then
  ok "T19 reset rejects symlinked parent component"
else
  bad "T19 symlink component (code=$code)"
fi
rm -rf "$SANDBOX"

# --- T20: preflight runs before the env-example copy ---
new_sandbox "t20"
eval "$(sandbox_env "$SANDBOX")"; export REPO_ROOT CALLS_DIR
rm "$SREPO/etc/setup.env"
PREFLIGHT_EXIT=1; export PREFLIGHT_EXIT
if "$SREPO/bin/setup" >/dev/null 2>&1; then code=0; else code=$?; fi
unset PREFLIGHT_EXIT
if [ "$code" != "0" ] && [ ! -f "$SREPO/etc/setup.env" ]; then
  ok "T20 failed preflight copies nothing"
else
  bad "T20 preflight ordering (code=$code)"
fi
rm -rf "$SANDBOX"

# --- T22: duplicate manifest entries fail closed ---
new_sandbox "t22"
eval "$(sandbox_env "$SANDBOX")"; export REPO_ROOT CALLS_DIR
stage_manifest "$SDATA" >/dev/null
head -n 1 "$SDATA/athena_input/current/manifest.sha256" >>"$SDATA/athena_input/current/manifest.sha256"
if "$SREPO/bin/setup" >"$SANDBOX/out.txt" 2>&1; then code=0; else code=$?; fi
if [ "$code" != "0" ] && [ "$code" != "20" ] && [ "$code" != "21" ] \
  && [ ! -f "$SDATA/work/setup/ready.env" ]; then
  ok "T22 duplicate manifest entries fail closed"
else
  bad "T22 duplicate entries (code=$code)"; cat "$SANDBOX/out.txt" 2>/dev/null || true
fi
rm -rf "$SANDBOX"

# --- T23: manifest-listed file missing fails closed ---
new_sandbox "t23"
eval "$(sandbox_env "$SANDBOX")"; export REPO_ROOT CALLS_DIR
stage_manifest "$SDATA" >/dev/null
rm "$SDATA/athena_input/current/DRUG_STRENGTH.csv"
if "$SREPO/bin/setup" >"$SANDBOX/out.txt" 2>&1; then code=0; else code=$?; fi
if [ "$code" != "0" ] && [ "$code" != "20" ] && [ "$code" != "21" ] \
  && [ ! -f "$SDATA/work/setup/ready.env" ]; then
  ok "T23 missing staged file fails closed"
else
  bad "T23 missing file (code=$code)"; cat "$SANDBOX/out.txt" 2>/dev/null || true
fi
rm -rf "$SANDBOX"

# --- T24: non-allow-listed manifest entry fails closed ---
new_sandbox "t24"
eval "$(sandbox_env "$SANDBOX")"; export REPO_ROOT CALLS_DIR
stage_manifest "$SDATA" >/dev/null
printf 'payload' >"$SDATA/athena_input/current/EXTRA.csv"
eh=$(sha256sum "$SDATA/athena_input/current/EXTRA.csv" | awk '{print $1}')
eb=$(wc -c <"$SDATA/athena_input/current/EXTRA.csv" | tr -d '[:space:]')
printf '%s %s %s\n' "$eh" "$eb" "EXTRA.csv" >>"$SDATA/athena_input/current/manifest.sha256"
if "$SREPO/bin/setup" >"$SANDBOX/out.txt" 2>&1; then code=0; else code=$?; fi
if [ "$code" != "0" ] && [ "$code" != "20" ] && [ "$code" != "21" ] \
  && [ ! -f "$SDATA/work/setup/ready.env" ]; then
  ok "T24 foreign manifest entry fails closed"
else
  bad "T24 foreign entry (code=$code)"; cat "$SANDBOX/out.txt" 2>/dev/null || true
fi
rm -rf "$SANDBOX"

# --- T26: reset honors explicit DATA_ROOT env over the file ---
new_sandbox "t26"
eval "$(sandbox_env "$SANDBOX")"; export REPO_ROOT CALLS_DIR
mkdir -p "$SANDBOX/env-target"
printf 'fhir_omop_mcp_hub' >"$SANDBOX/env-target/.fhir_omop_mcp_hub_data_root"
printf 'fhir_omop_mcp_hub' >"$SDATA/.fhir_omop_mcp_hub_data_root"
DATA_ROOT="$SANDBOX/env-target"; export DATA_ROOT
if printf 'RESET fhir_omop_mcp_hub\n' | "$SREPO/bin/reset" >/dev/null 2>&1; then code=0; else code=$?; fi
unset DATA_ROOT
if [ "$code" = "0" ] && [ ! -e "$SANDBOX/env-target" ] && [ -d "$SDATA" ]; then
  ok "T26 reset env override wins over file"
else
  bad "T26 reset env override (code=$code)"
fi
rm -rf "$SANDBOX"

# --- T27: sentinel tampered during compose down aborts before rm ---
new_sandbox "t27"
eval "$(sandbox_env "$SANDBOX")"; export REPO_ROOT CALLS_DIR
printf 'fhir_omop_mcp_hub' >"$SDATA/.fhir_omop_mcp_hub_data_root"
COMPOSE_DOWN_TAMPER=1; export COMPOSE_DOWN_TAMPER
TAMPER_TARGET="$SDATA"; export TAMPER_TARGET
if printf 'RESET fhir_omop_mcp_hub\n' | "$SREPO/bin/reset" >/dev/null 2>&1; then code=0; else code=$?; fi
unset COMPOSE_DOWN_TAMPER TAMPER_TARGET
if [ "$code" != "0" ] && [ -d "$SDATA" ]; then
  ok "T27 mid-reset tampering aborts without rm"
else
  bad "T27 TOCTOU recheck (code=$code)"
fi
rm -rf "$SANDBOX"

# --- T28: sentinel that is a symlink is refused ---
new_sandbox "t28"
eval "$(sandbox_env "$SANDBOX")"; export REPO_ROOT CALLS_DIR
printf 'fhir_omop_mcp_hub' >"$SANDBOX/real-sentinel"
ln -s "$SANDBOX/real-sentinel" "$SDATA/.fhir_omop_mcp_hub_data_root"
if printf 'RESET fhir_omop_mcp_hub\n' | "$SREPO/bin/reset" >/dev/null 2>&1; then code=0; else code=$?; fi
if [ "$code" != "0" ] && [ -d "$SDATA" ]; then
  ok "T28 symlinked sentinel refused"
else
  bad "T28 sentinel symlink (code=$code)"
fi
rm -rf "$SANDBOX"

if [ "$fail" -ne 0 ]; then printf 'lifecycle: FAILED (%d pass, %d fail)\n' "$pass" "$fail"; exit 1; fi
printf 'lifecycle: PASSED (%d checks)\n' "$pass"
