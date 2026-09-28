#!/bin/bash
# Shared shell invariants for local setup (Task 1).
# Sources ignored etc/setup.env, canonicalizes DATA_ROOT, never prints secrets.
set -eu

# Repository root derived from this file's location.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd -P)"
export REPO_ROOT

# Env overrides win over the ignored local file: stash, source, restore.
_stash() { _v="$1"; if [ -n "${!_v+x}" ]; then printf -v "_saved_$_v" '%s' "${!_v}"; else printf -v "_saved_$_v" '__unset__'; fi; }
_unstash() { _v="$1"; _s="_saved_$_v"; if [ "${!_s}" != '__unset__' ]; then printf -v "$_v" '%s' "${!_s}"; else unset "$_v" || true; fi; }
case "${DATA_ROOT+x}" in x) _env_has_data_root=1;; *) _env_has_data_root=0;; esac
for _k in COMPOSE_PROJECT_NAME DATA_ROOT POSTGRES_IMAGE POSTGRES_DB POSTGRES_USER POSTGRES_HOST_PORT VOCAB_VIEW_TARGET_SCHEMAS POPULATION_SIZE SEED WEBAPI_HOST_PORT MCP_HOST_PORT; do _stash "$_k"; done
if [ -f "$REPO_ROOT/etc/setup.env" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$REPO_ROOT/etc/setup.env"
  set +a
fi
for _k in COMPOSE_PROJECT_NAME DATA_ROOT POSTGRES_IMAGE POSTGRES_DB POSTGRES_USER POSTGRES_HOST_PORT VOCAB_VIEW_TARGET_SCHEMAS POPULATION_SIZE SEED WEBAPI_HOST_PORT MCP_HOST_PORT; do _unstash "$_k"; done
unset _k _v _s _stash _unstash _saved_COMPOSE_PROJECT_NAME _saved_DATA_ROOT _saved_POSTGRES_IMAGE _saved_POSTGRES_DB _saved_POSTGRES_USER _saved_POSTGRES_HOST_PORT _saved_VOCAB_VIEW_TARGET_SCHEMAS _saved_POPULATION_SIZE _saved_SEED _saved_WEBAPI_HOST_PORT _saved_MCP_HOST_PORT || true

# Resolve a path to canonical absolute form WITHOUT creating anything:
# follows symlinks and collapses '.'/'..' so denylist checks see the real path (H3).
resolve_path() {
  _rp="$1"
  case "$_rp" in /*) ;; *) _rp="$REPO_ROOT/$_rp";; esac
  if command -v realpath >/dev/null 2>&1 && _out="$(realpath -m -- "$_rp" 2>/dev/null)"; then printf '%s\n' "$_out"; return 0; fi
  if command -v readlink >/dev/null 2>&1 && _out="$(readlink -m -- "$_rp" 2>/dev/null)"; then printf '%s\n' "$_out"; return 0; fi
  if command -v python3 >/dev/null 2>&1 && _out="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$_rp" 2>/dev/null)"; then printf '%s\n' "$_out"; return 0; fi
  printf '%s\n' "$_rp" | sed -e 's|/\./|/|g' -e 's|//*|/|g' -e 's|/$||'
  return 0
}

: "${COMPOSE_PROJECT_NAME:=fhir_omop_mcp_hub}"
: "${DATA_ROOT:=./data}"
: "${POSTGRES_IMAGE:=docker.io/library/postgres:16.4-alpine@sha256:5660c2cbfea50c7a9127d17dc4e48543eedd3d7a41a595a2dfa572471e37e64c}"
: "${POSTGRES_DB:=fhir_omop_mcp_hub}"
: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_HOST_PORT:=5432}"
: "${VOCAB_VIEW_TARGET_SCHEMAS:=omop_csv}"
: "${POPULATION_SIZE:=100}"
: "${SEED:=}"
: "${WEBAPI_HOST_PORT:=8080}"
: "${MCP_HOST_PORT:=8000}"

# Resolved absolute DATA_ROOT (no mkdir here; creation belongs to prepare-data).
# DATA_ROOT_FROM_ENV=1 when the value came from the environment (M2: callers
# must not write env overrides back into ignored etc/setup.env).
DATA_ROOT_FROM_ENV="$_env_has_data_root"
unset _env_has_data_root || true
DATA_ROOT="$(resolve_path "$DATA_ROOT")"
[ -n "$DATA_ROOT" ] || DATA_ROOT="/"
export COMPOSE_PROJECT_NAME DATA_ROOT DATA_ROOT_FROM_ENV POSTGRES_IMAGE POSTGRES_DB POSTGRES_USER POSTGRES_HOST_PORT VOCAB_VIEW_TARGET_SCHEMAS POPULATION_SIZE SEED WEBAPI_HOST_PORT MCP_HOST_PORT

die() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command '$1'"
}

require_absolute_dir() {
  case "$1" in
    /*) ;;
    *) die "$2 must be absolute, got '$1'" ;;
  esac
}

# Owns all Compose flags: canonical file + project. Callers pass subcommands.
compose() {
  export DATA_ROOT COMPOSE_PROJECT_NAME POSTGRES_IMAGE POSTGRES_DB POSTGRES_USER POSTGRES_HOST_PORT VOCAB_VIEW_TARGET_SCHEMAS POPULATION_SIZE SEED WEBAPI_HOST_PORT MCP_HOST_PORT
  docker compose --file "$REPO_ROOT/compose.yaml" --project-name "$COMPOSE_PROJECT_NAME" "$@"
}
