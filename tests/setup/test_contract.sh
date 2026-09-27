#!/bin/sh
# Repository-contract test (Task 1). POSIX sh, grep-based assertions only.
set -eu

REPO_ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"

fail=0
ok() { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }

assert_exists() {
  if [ -e "$REPO_ROOT/$1" ]; then ok "$1 exists"; else bad "$1 exists"; fi
}

assert_executable() {
  if [ -x "$REPO_ROOT/$1" ]; then ok "$1 executable"; else bad "$1 executable"; fi
}

# Planned Task 1 paths.
assert_exists ".gitignore"
assert_exists "etc/setup.env.example"
assert_exists "etc/athena-required-files.txt"
assert_exists "etc/athena-required-vocabularies.txt"
assert_exists "bin/lib/common.sh"
assert_exists "bin/check-prerequisites"
assert_exists "tests/setup/test_contract.sh"
assert_executable "bin/lib/common.sh"
assert_executable "bin/check-prerequisites"

# .gitignore covers generated state.
for p in data etc/setup.env .env; do
  if git -C "$REPO_ROOT" check-ignore -q "$p" 2>/dev/null; then
    ok "git ignores $p"
  else
    bad "git ignores $p"
  fi
done

# Exact required-files contract.
EXPECTED_TMP="$(mktemp)"
cat >"$EXPECTED_TMP" <<'EOF'
CONCEPT.csv
CONCEPT_ANCESTOR.csv
CONCEPT_CLASS.csv
CONCEPT_RELATIONSHIP.csv
CONCEPT_SYNONYM.csv
DOMAIN.csv
DRUG_STRENGTH.csv
RELATIONSHIP.csv
VOCABULARY.csv
EOF
if [ -f "$REPO_ROOT/etc/athena-required-files.txt" ] \
  && cmp -s "$REPO_ROOT/etc/athena-required-files.txt" "$EXPECTED_TMP"; then
  ok "athena-required-files.txt exact"
else
  bad "athena-required-files.txt exact"
fi
rm -f "$EXPECTED_TMP"

# Non-secret defaults present (values pinned by plan).
for kv in \
  "COMPOSE_PROJECT_NAME=fhir_omop_mcp_hub" \
  "DATA_ROOT=./data" \
  "POSTGRES_DB=fhir_omop_mcp_hub" \
  "POSTGRES_USER=postgres" \
  "POSTGRES_HOST_PORT=5432" \
  "VOCAB_VIEW_TARGET_SCHEMAS=omop_csv"; do
  if [ -f "$REPO_ROOT/etc/setup.env.example" ] \
    && grep -F -q -- "$kv" "$REPO_ROOT/etc/setup.env.example"; then
    ok "setup.env.example has $kv"
  else
    bad "setup.env.example has $kv"
  fi
done
if grep -F -q -- "docker.io/library/postgres:16.4-alpine@sha256:5660c2cbfea50c7a9127d17dc4e48543eedd3d7a41a595a2dfa572471e37e64c" "$REPO_ROOT/etc/setup.env.example" 2>/dev/null; then
  ok "setup.env.example pins postgres image"
else
  bad "setup.env.example pins postgres image"
fi

# Required vocabulary families.
for v in CVX LOINC RxNorm SNOMED UCUM; do
  if [ -f "$REPO_ROOT/etc/athena-required-vocabularies.txt" ] \
    && grep -F -q -- "$v" "$REPO_ROOT/etc/athena-required-vocabularies.txt"; then
    ok "required vocabulary $v"
  else
    bad "required vocabulary $v"
  fi
done

# Port-ownership contract (idempotent rerun): an occupied loopback port passes
# only when bound by this exact Compose project's postgres service.
TPORT="${POSTGRES_HOST_PORT:-}"
if [ -z "$TPORT" ]; then
  TPORT="$(awk -F= '/^POSTGRES_HOST_PORT=/{print $2}' "$REPO_ROOT/etc/setup.env" 2>/dev/null || true)"
fi
[ -n "$TPORT" ] || TPORT=5432
# Isolate generated state from any other worker's DATA_ROOT; port logic is unaffected.
# Probe lives on the repository filesystem so the 30 GiB disk check can pass.
PROBE_TMP="$(mktemp -d "$REPO_ROOT/.tmp-contract-probe-XXXXXX")"
trap 'rm -rf "$PROBE_TMP"' EXIT
export DATA_ROOT="$PROBE_TMP/data"
mkdir -p "$DATA_ROOT"
own_ids="$("$REPO_ROOT/bin/compose" ps -q postgres 2>/dev/null || true)"
if [ -n "$own_ids" ]; then
  if "$REPO_ROOT/bin/check-prerequisites" >/dev/null 2>&1; then
    ok "preflight passes with own postgres on 127.0.0.1:$TPORT (idempotent rerun)"
  else
    bad "preflight passes with own postgres on 127.0.0.1:$TPORT (idempotent rerun)"
  fi
  if "$REPO_ROOT/bin/check-prerequisites" 2>&1 | grep -F -q -- "PASS: loopback port $TPORT"; then
    ok "port check attributes $TPORT to own postgres"
  else
    bad "port check attributes $TPORT to own postgres"
  fi
else
  ok "skip own-port test (no own postgres running)"
fi
if command -v python3 >/dev/null 2>&1; then
  FPORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])' 2>/dev/null || true)"
  if [ -n "$FPORT" ]; then
    python3 -m http.server "$FPORT" --bind 127.0.0.1 >/dev/null 2>&1 &
    srvpid=$!
    sleep 1
    if POSTGRES_HOST_PORT="$FPORT" "$REPO_ROOT/bin/check-prerequisites" >/dev/null 2>&1; then
      bad "preflight fails on foreign-occupied port $FPORT"
    else
      ok "preflight fails on foreign-occupied port $FPORT"
    fi
    if POSTGRES_HOST_PORT="$FPORT" "$REPO_ROOT/bin/check-prerequisites" 2>&1 | grep -F -q -- "FAIL: host port $FPORT"; then
      ok "port check names foreign port $FPORT"
    else
      bad "port check names foreign port $FPORT"
    fi
    kill "$srvpid" 2>/dev/null || true
    wait "$srvpid" 2>/dev/null || true
  else
    ok "skip foreign-port test (no free probe port)"
  fi
else
  ok "skip foreign-port test (python3 absent)"
fi
# M4: check mode creates nothing, even for an absent deep data root.
M4BASE="$(mktemp -d)"; M4D="$M4BASE/deep/a/b"
DATA_ROOT="$M4D" "$REPO_ROOT/bin/check-prerequisites" >/dev/null 2>&1 || true
[ -e "$M4BASE/deep" ] && bad "preflight creates nothing (M4)" || ok "preflight creates nothing (M4)"
# M3: disk check targets the data-root filesystem, not the repo filesystem.
diskline="$(DATA_ROOT="$M4D" "$REPO_ROOT/bin/check-prerequisites" 2>&1 | grep 'disk free' || true)"
case "$diskline" in
  *"$M4BASE"*) ok "disk check targets data-root filesystem (M3)" ;;
  *) bad "disk check targets data-root filesystem (M3)" ;;
esac
rm -rf "$M4BASE"
rm -rf "$PROBE_TMP"

if [ "$fail" -ne 0 ]; then
  printf 'contract: FAILED\n'
  exit 1
fi
printf 'contract: PASSED\n'
