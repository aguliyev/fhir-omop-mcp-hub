# Operator UX, Compose Lifecycle, and Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the runnable system: thin `bin/` wrappers, full Compose topology with order+health, `etc/` config layout, and a `bin/validate` end-to-end check from inbox batch to MCP answer.

**Architecture:** All operator actions are thin Docker Compose wrappers; pipeline logic stays in containers (built by the other four plans). This plan owns only: `bin/{restart,validate}`, `bin/{start,stop,status,logs}` extensions for new services, `bin/lib/common.sh` forwarding for new variables, final topology verification, `etc/README.md` secret-injection docs, and `bin/validate` which asserts inbox→`omop_csv`→WebAPI→MCP chain on a tiny population and prints READY/FAILED.

**Tech Stack:** POSIX shell, Docker Compose, PostgreSQL 16.4, `psql`, `curl`, Python 3 (validate helper only).

**Spec:** `docs/intro.md` §§8, 10 (bin scripts, etc layout, secrets, in-place maintenance refresh, loopback ports).

**File ownership (parallel agents):** this plan owns `bin/{restart,validate}`, `bin/{start,stop,
status,logs,reset}` modifications, `bin/lib/common.sh` env forwarding, `etc/README.md`,
`tests/operator/`. It verifies — but never edits — service blocks in `compose.yaml`,
`bin/generate` (Synthea plan), `bin/refresh-csv` (CSV plan), and every `etc/*.env.example`
except none: each service plan owns its own env example; this plan only checks them.
No `etc/etl.env.example`: ETL values are fixed (`CDM_VERSION=5.3.1` per intro) or shared
(`POPULATION_SIZE` via `etc/synthea.env`); a fifth env file adds confusion for zero knobs.

## Global Constraints

- `bin/` scripts are thin wrappers: parse args, call `bin/compose` or a container job, report status. No ETL/SQL/MCP logic in `bin/`.
- Destructive `bin/reset` already exists — do not weaken its typed-confirmation + sentinel checks; extend it only to stop new services.
- All host ports via `${*_HOST_PORT}` bound to `127.0.0.1`; defaults: postgres `5432`, WebAPI `8080`, MCP `8000`.
- `platform: linux/amd64` on every custom service; pinned digests from other plans reused verbatim.
- Secrets: `<data-root>/secrets/*` mode `0600`, via `/run/secrets/*` + `*_PASSWORD_FILE`; never print, log, or commit.
- `bin/validate` is read-only except for running a disposable `generate 5` + `refresh-csv` cycle on demand with explicit `--run-refresh` flag; default mode only checks.
- Keep FHIR out: no `refresh-fhir`/`refresh-all` in v1.

---

## Planned File Structure

```text
bin/{restart,validate}
bin/{start,stop,status,logs,reset} (service-list extensions only)
bin/lib/common.sh (env forwarding for new vars)
etc/README.md
tests/operator/test_bin_contract.sh
compose.yaml (verify only — service blocks owned by their plans)
```

If a file was already created by another plan, this plan only wires/verifies it — never duplicates it.

---

### Task 1: `bin/` contract + `etc/` inventory

**Files:**
- Create: `tests/operator/test_bin_contract.sh`
- Create: `etc/README.md`
- Modify: `bin/lib/common.sh` (forward new vars to Compose)

**Interfaces:**
- Consumes: script list from `docs/intro.md` §8.
- Produces: contract all later tasks satisfy.

- [ ] **Step 1: Write the failing contract test**

```bash
#!/bin/bash
# tests/operator/test_bin_contract.sh
set -eu
for s in setup start stop restart status logs generate load-vocab refresh-csv validate reset; do
  [ -x "bin/$s" ] || { echo "FAIL: bin/$s missing/not executable"; exit 1; }
done
[ ! -e bin/refresh-fhir ] || { echo "FAIL: bin/refresh-fhir must not exist in v1"; exit 1; }
for e in setup.env.example synthea.env.example webapi.env.example mcp.env.example; do
  [ -f "etc/$e" ] || { echo "FAIL: etc/$e missing"; exit 1; }
done
grep -q "0.0.0.0" compose.yaml && { echo "FAIL: non-loopback bind"; exit 1; }
echo "PASS: operator contract"
```

Run: `bash tests/operator/test_bin_contract.sh`
Expected: FAIL (restart/validate/README missing).

- [ ] **Step 2: Forward new variables through `bin/lib/common.sh`**

`compose.yaml` interpolates `${POPULATION_SIZE}`, `${SEED}`, `${WEBAPI_HOST_PORT}`,
`${MCP_HOST_PORT}`, but `common.sh:compose()` only exports a fixed allow-list, so service
plans' defaults would silently win. In `bin/lib/common.sh`, add the four names to all three
places: the `_stash`/`_unstash` loop list, the `:=` defaults block (`POPULATION_SIZE=100`,
`SEED=` empty, `WEBAPI_HOST_PORT=8080`, `MCP_HOST_PORT=8000`), and the `export`/`compose()`
export lists. Env overrides keep winning over files (existing stash mechanism).

- [ ] **Step 3: Create `etc/README.md`**

`etc/README.md` (short): layout table (`setup.env` local-ignored, `*.env.example` tracked defaults, secrets under `<data-root>/secrets/` via Docker secrets), "copy example → `etc/<name>.env`, never commit", and per-service env file mapping used by compose.

- [ ] **Step 4: Commit**

```bash
git add tests/operator/test_bin_contract.sh bin/lib/common.sh etc/README.md
git commit -m "build: define operator contract"
```

### Task 2: Lifecycle wrappers (`restart`, extend start/stop/status/logs)

**Files:**
- Create: `bin/restart`
- Modify: `bin/start`, `bin/stop`, `bin/status`, `bin/reset` (service list only)

**Interfaces:**
- Consumes: `bin/lib/common.sh` `compose()` helper + contract from Task 1.
- Produces: lifecycle used by Task 4 validation.

- [ ] **Step 1: Write `bin/restart`**

```bash
#!/bin/bash
# bin/restart [service...] — recreate services after config change.
set -eu; cd "$(dirname "$0")/.."
. bin/lib/common.sh
compose up -d "$@"
compose ps
```

`chmod +x bin/restart`. `bin/start` must `compose up db_init` in the foreground (logs visible,
failure aborts startup — never suppress its stderr), then `compose up -d postgres ohdsi_webapi mcp_server`.
`bin/stop` stops only this project (`compose stop`, never `down -v`). `bin/status` = `compose ps` + container health lines. `bin/reset` keeps its confirmation flow; add new service names to its stop list only.

- [ ] **Step 2: Verify + commit**

```bash
bash tests/operator/test_bin_contract.sh  # still FAIL until validate exists — expected
bin/status
git add bin/restart bin/start bin/stop bin/status bin/reset
git commit -m "feat: complete lifecycle wrappers"
```

### Task 3: Final Compose topology (verify only)

**Files:**
- Modify: `tests/operator/test_bin_contract.sh` (append topology assertions; `compose.yaml`
  itself is owned by the service plans — this task verifies, never edits)

**Interfaces:**
- Consumes: service blocks from the Synthea/ETL/WebAPI/MCP plans.
- Produces: topology gate consumed by Task 4.

- [ ] **Step 1: Assert the topology test**

Extend `tests/operator/test_bin_contract.sh` (already checks loopback) with:

```bash
for s in postgres db_init athena_vocabs synthea etl_synthea ohdsi_webapi mcp_server; do
  grep -q "^  $s:" compose.yaml || { echo "FAIL: service $s"; exit 1; }
done
grep -q "service_healthy" compose.yaml || { echo "FAIL: no health gating"; exit 1; }
grep -q "service_completed_successfully" compose.yaml || { echo "FAIL: no db_init gate"; exit 1; }
```

- [ ] **Step 2: Verify the assembled topology**

Single default network (Compose-provided), no custom networks (YAGNI). Expected order:
`postgres` (healthy) → `db_init` (completed) → `athena_vocabs` (profile `athena`, manual) /
`etl_synthea` (manual `run`) / `synthea` (manual `run`); persistent `ohdsi_webapi` (healthy,
after `db_init`) → `mcp_server` (after `ohdsi_webapi` healthy). One-shot jobs `restart: "no"`;
persistent `restart: unless-stopped`. Ports only `127.0.0.1:${X_HOST_PORT}:<container>`.
`postgres_password` secret on every DB-backed service. If any assertion fails, file the
correction against the owning service plan — do not edit its block here.

- [ ] **Step 3: Verify + commit**

```bash
docker compose config --quiet && echo OK
git add tests/operator/test_bin_contract.sh
git commit -m "build: gate compose topology"
```

Expected: config validates; contract passes except `bin/validate` still missing.

### Task 4: `bin/validate` end-to-end readiness check

**Files:**
- Create: `bin/validate`

**Interfaces:**
- Consumes: everything above + live `omop_csv`, WebAPI, MCP.
- Produces: `READY`/`FAILED` verdict; last gate before demo.

- [ ] **Step 1: Write `bin/validate`**

```bash
#!/bin/bash
# bin/validate [--run-refresh] — default read-only; flag permits generate(5)+refresh cycle.
set -eu; cd "$(dirname "$0")/.."
. bin/lib/common.sh
FAIL=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi; }
check "postgres healthy" "compose ps postgres | grep -q healthy"
check "omop_csv has persons table" "compose exec -T postgres psql -U postgres -d fhir_omop_mcp_hub -c '\\d omop_csv.person' >/dev/null"
check "omop_csv vocab views" "compose exec -T postgres psql -U postgres -d fhir_omop_mcp_hub -tc \"select count(*) from omop_csv.concept\" | grep -qv '^ 0'"
check "webapi source" "curl -sf http://127.0.0.1:${WEBAPI_HOST_PORT:-8080}/WebAPI/source/sources | grep -q omop_csv"
check "vocab search" "curl -sf 'http://127.0.0.1:${WEBAPI_HOST_PORT:-8080}/WebAPI/vocabulary/search?query=diabetes' | grep -q CONCEPT_ID"
check "mcp up" "curl -sf http://127.0.0.1:${MCP_HOST_PORT:-8000}/health 2>/dev/null || compose ps mcp_server | grep -q Up"
if [ "${1:-}" = "--run-refresh" ]; then
  bin/generate 5 && bin/refresh-csv || FAIL=1
  check "refresh populated persons" "compose exec -T postgres psql -U postgres -d fhir_omop_mcp_hub -tc 'select count(*) from omop_csv.person' | grep -qv '^ 0'"
fi
[ "$FAIL" -eq 0 ] && echo "READY" || { echo "FAILED"; exit 1; }
```

`chmod +x bin/validate`. Adapt the MCP health probe to the MCP plan's actual endpoint (if no HTTP health endpoint, check `compose ps` + a `translate_tool` smoke call); record the final probe here.

- [ ] **Step 2: Run full gate + commit**

```bash
bash tests/operator/test_bin_contract.sh
bin/validate
git add bin/validate
git commit -m "feat: add end-to-end validate"
```

Expected: contract PASS; `bin/validate` prints READY on a loaded system (or FAILED with the exact failing line on a fresh checkout — correct, fix system not the check).

## Stop Rules

- Stop before adding pipeline logic to `bin/` — wrappers only; logic lives in containers.
- Stop before `down -v`, mass `rm`, or weakening `reset` confirmation — destructive ops keep typed confirmation.
- Stop on exposing ports beyond `127.0.0.1` or committing secrets/env — fail the check instead.
