# Operator UX, Compose Lifecycle, and Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the runnable system: thin `bin/` wrappers, full Compose topology with order+health, `etc/` config layout, and a `bin/validate` end-to-end check from inbox batch to MCP answer.

**Architecture:** All operator actions remain thin Compose wrappers. This plan extends `bin/lib/common.sh` for one ignored `etc/setup.env`; `bin/start` runs `db_init`, starts WebAPI for its own metadata migrations, runs the WebAPI registration job, then starts the Streamable HTTP MCP server. `bin/validate` checks the real inbox→CDM→WebAPI→MCP chain and prints READY/FAILED; only `--run-refresh` may generate/load a tiny batch.

**Tech Stack:** POSIX shell, Docker Compose, PostgreSQL 16.4, `psql`, `curl`, Python 3 (validate helper only).

**Spec:** `docs/intro.md` §§8, 10 (bin scripts, etc layout, secrets, in-place maintenance refresh, loopback ports).

**File ownership (parallel agents):** this plan owns `bin/{restart,validate}`, `bin/{start,stop,
status,logs,reset}` modifications, `bin/lib/common.sh` env forwarding, `etc/README.md`,
`tests/operator/`. It verifies — but never edits — service blocks in `compose.yaml`,
`bin/generate` (Synthea plan), `bin/refresh-csv` (CSV plan), and every `etc/*.env.example`
except none: each service plan owns its own env example; this plan only checks them.
No `etc/etl.env.example`: ETL values are fixed (`CDM_VERSION=5.3.1` per intro) or shared
(`POPULATION_SIZE` via `etc/setup.env`); a fifth env file adds confusion for zero knobs.

## Global Constraints

- `bin/` scripts are thin wrappers: parse args, call `bin/compose` or a container job, report status. No ETL/SQL/MCP logic in `bin/`.
- Destructive `bin/reset` already exists — do not weaken its typed-confirmation + sentinel checks; extend it only to stop new services.
- All host ports via `${*_HOST_PORT}` bound to `127.0.0.1`; defaults: postgres `5432`, WebAPI `8080`, MCP `8000`.
- `platform: linux/amd64` on every custom service; pinned digests from other plans reused verbatim.
- Secrets: `<data-root>/secrets/*` mode `0600`, via `/run/secrets/*` + `*_PASSWORD_FILE`; never print, log, or commit. The CSV plan's separate ETL credential must be generated and wired through this same mechanism.
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

**Run this task before any new service plan's Compose block.** `compose.yaml` interpolates `${POPULATION_SIZE}`, `${SEED}`, `${WEBAPI_HOST_PORT}`,
`${MCP_HOST_PORT}`, but `common.sh:compose()` only exports a fixed allow-list, so service
plans' defaults would silently win. In `bin/lib/common.sh`, add the four names to all three
places: the `_stash`/`_unstash` loop list, the `:=` defaults block (`POPULATION_SIZE=100`,
`SEED=` empty, `WEBAPI_HOST_PORT=8080`, `MCP_HOST_PORT=8000`), and the `export`/`compose()`
export lists. Env overrides keep winning over files (existing stash mechanism). Only `etc/setup.env` is loaded; `etc/{synthea,webapi,mcp}.env.example` are reference examples, not files to copy and source.

- [ ] **Step 3: Create `etc/README.md`**

`etc/README.md` (short): one ignored `etc/setup.env` for all non-secret local settings, service `*.env.example` files as **documentation only**, and secrets under `<data-root>/secrets/` via Docker secrets. Never tell operators to create separate `etc/<service>.env` files that `common.sh` does not read.

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
# bin/restart — stop and start the managed stack after config change.
set -eu; cd "$(dirname "$0")/.."
. bin/lib/common.sh
[ "$#" -eq 0 ] || die "usage: bin/restart (no service arguments)"
bin/stop
bin/start
```

`chmod +x bin/restart`. `bin/restart` restarts the complete managed stack, not arbitrary service arguments; reject nonempty `"$@"` with a usage error. `bin/start` first starts Postgres and runs `db_init` in the foreground (failure aborts startup), then starts WebAPI and waits for its **pre-registration** healthcheck, recreates `webapi_register` with `compose up -d --force-recreate webapi_register`, and starts MCP with `compose up -d mcp_server`. Compose must wait for `webapi_register` to complete successfully before starting MCP; explicitly verify its exit code and one-source mapping. Do not use `compose run --rm webapi_register`, whose removed container cannot satisfy MCP's `service_completed_successfully` dependency. On failure leave MCP stopped. After a CSV refresh, `bin/refresh-csv` uses the same sequence only after data validates.
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
for s in postgres db_init athena_vocabs synthea etl_synthea ohdsi_webapi webapi_register mcp_server; do
  grep -q "^  $s:" compose.yaml || { echo "FAIL: service $s"; exit 1; }
done
grep -q "service_healthy" compose.yaml || { echo "FAIL: no health gating"; exit 1; }
grep -q "service_completed_successfully" compose.yaml || { echo "FAIL: no db_init gate"; exit 1; }
```

- [ ] **Step 2: Verify the assembled topology**

Single default network (Compose-provided), no custom networks (YAGNI). Expected order:
`postgres` (healthy) → `db_init` (completed) → `athena_vocabs` (profile `athena`, manual) /
`etl_synthea` (manual `run`) / `synthea` (manual `run`); persistent `ohdsi_webapi` (healthy after migration) → one-shot `webapi_register` (completed) → `mcp_server`. One-shot jobs `restart: "no"`;
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

- [ ] **Step 1: Gate `READY` on real checks, not container status**

Write the `bin/validate [--run-refresh]` wrapper only **after** the WebAPI
source/vocabulary and MCP `/mcp` contracts have passed live tests. Reuse
`bin/lib/common.sh` and the password-file connection pattern in
`bin/validate-setup`; reject unknown flags. Each of these must return a
nonzero exit and print a named failure on a broken system:

1. Query `omop_csv.person` and its vocabulary views; require a positive person
   count without assuming the local `postgres` peer-auth user.
2. Check WebAPI has exactly one `omop_csv` source and its four correct daemon
   schema mappings; perform the pinned release's real vocabulary-search call.
3. Initialize an MCP client at `http://127.0.0.1:${MCP_HOST_PORT}/mcp`, call
   tools/list and the read-only translator, and inspect its valid Circe output.
4. With `--run-refresh` only: `bin/generate 5`, `bin/refresh-csv`, rerun the
   checks above, call a supported `cohort_query` and compare its count to
   `omop_csv_results.cohort`; assert old cohort membership is removed while
   definitions persist. Force a failed refresh in an isolated test and verify
   `--rebuild-accepted` restores the accepted snapshot without accepting the
   rejected batch.

Default validation must not generate, execute cohorts, or mutate state. Print
`READY` only if **every** required check ran and passed; otherwise print
`FAILED` and return nonzero. A container being `Up`, a guessed `/health`
endpoint, or a skipped check never counts as success.

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
