# WebAPI Source and Results Registration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run one OHDSI WebAPI instance that serves vocabulary search and cohort-definition/generation/execution against the single v1 `omop_csv` source.

**Architecture:** `db_init` prepares schemas and the pinned WebAPI results DDL; `ohdsi_webapi` boots and migrates its own metadata tables; then a one-shot `webapi_register` job idempotently registers and verifies `omop_csv`. `mcp_server` starts only after registration succeeds. Clinical refresh drops+recreates only this source's results/temp schemas. No `omop_fhir` registration in v1.

**Tech Stack:** Docker Compose, PostgreSQL 16.4, OHDSI WebAPI 2.x (pinned war), a servlet-compatible pinned Tomcat/Java runtime, `psql`, POSIX shell.

**Spec:** `docs/intro.md` §§4, 6, 8, 10 (one WebAPI, one source `omop_csv`, own results/temp, shared `athena_vocabs`).

**File ownership (parallel agents):** this plan owns `docker/webapi/`, `db/webapi/`,
`etc/webapi.env.example`, `tests/webapi/`, plus the `db_init` service definition and
`db/bootstrap/run.sh` extension. It must not edit `compose.yaml` beyond appending its own
`ohdsi_webapi:`/`webapi_register:` blocks and extending the existing `db_init:` block's volumes, and must not
touch any other plan's files. (`omop_fhir*` schemas already created empty by bootstrap stay
empty and unregistered in v1 — do not remove them.)

## Global Constraints

- Pin the exact WebAPI release (war URL + SHA-256) in `docker/webapi/PROVENANCE.md`; `platform: linux/amd64`.
- One database `fhir_omop_mcp_hub`; source key exactly `omop_csv` (lowercase snake case).
- Source wiring: CDM `omop_csv`, vocabulary `athena_vocabs`, results `omop_csv_results`, temp `omop_csv_temp`.
- `ohdsi_webapi` schema holds WebAPI metadata + source/daimon rows; cohort definitions persist across clinical refreshes, executions do not.
- Results DDL is the complete WebAPI-generated DDL for the pinned release, stored versioned under `db/webapi/`.
- Do not invent metadata columns, daimon codes, Circe endpoints, or a servlet runtime: inspect the pinned release and prove each contract against a running instance before dependent plans use it.
- WebAPI host port bound to `127.0.0.1` only (configurable, default `8080`); container-to-container via Compose network.
- No secrets in tracked files; DB password via `/run/secrets/postgres_password`.

---

## Planned File Structure

```text
docker/webapi/{Dockerfile,PROVENANCE.md,entrypoint.sh,settings.xml}
db/webapi/{results_ddl.sql,register_source.sql,recreate_results.sh,register.sh}
db/bootstrap/{schemas.sql (extend),run.sh (extend)}
etc/webapi.env.example
tests/webapi/test_webapi_contract.sh
```

---

### Task 1: Version pin + source registration contract

**Files:**
- Create: `docker/webapi/PROVENANCE.md`
- Create: `db/webapi/register_source.sql`
- Create: `tests/webapi/test_webapi_contract.sh`

**Interfaces:**
- Consumes: schema names from `db/bootstrap/schemas.sql`.
- Produces: source-key + schema mapping consumed by Tasks 2–3 and the MCP plan.

- [ ] **Step 1: Write the failing contract test**

```bash
#!/bin/bash
# tests/webapi/test_webapi_contract.sh
set -eu
for f in docker/webapi/Dockerfile db/webapi/results_ddl.sql db/webapi/register_source.sql db/webapi/recreate_results.sh etc/webapi.env.example; do
  [ -f "$f" ] || { echo "FAIL: missing $f"; exit 1; }
done
grep -q "omop_csv" db/webapi/register_source.sql || { echo "FAIL: no omop_csv source"; exit 1; }
grep -q "omop_fhir" db/webapi/register_source.sql && { echo "FAIL: omop_fhir must not register in v1"; exit 1; }
echo "PASS: webapi contract"
```

Run: `bash tests/webapi/test_webapi_contract.sh`
Expected: FAIL.

- [ ] **Step 2: Pin WebAPI + write registration SQL**

Choose and pin a WebAPI release whose war actually boots against Postgres 16 and the selected Java runtime; record the war URL, SHA-256, runtime image digest, and the WAR's servlet namespace (`javax` or `jakarta`) in `docker/webapi/PROVENANCE.md`. Extract its metadata migrations, identify the actual source and daimon columns, uniqueness constraints, and daimon type values, and derive `register_source.sql` from those facts. Upsert by the actual source-key constraint; repeated runs must update the same source, never allocate duplicate daemon rows. Do not execute this SQL from `db_init`: the metadata tables are not present until WebAPI finishes its first migration.

- [ ] **Step 3: Commit contract**

```bash
git add docker/webapi/PROVENANCE.md db/webapi/register_source.sql tests/webapi/test_webapi_contract.sh
git commit -m "build: define webapi source contract"
```

### Task 2: Results DDL + recreate script + `db_init` wiring

**Files:**
- Create: `db/webapi/results_ddl.sql`
- Create: `db/webapi/recreate_results.sh`
- Modify: `db/bootstrap/run.sh` (apply `results_ddl.sql` idempotently; no metadata inserts)
- Modify: `compose.yaml` (`db_init:` volumes add `./db/webapi:/webapi:ro`)
- Create: `etc/webapi.env.example`

**Interfaces:**
- Consumes: the results-DDL contract from the pinned release.
- Produces: `recreate_results.sh omop_csv` called by the CSV-refresh plan; results tables consumed by Task 3.

- [ ] **Step 1: Capture results DDL**

Generate the **complete** results DDL for the pinned WebAPI release using its documented results-DDL generator (or versioned SQL if provided), not a hand-picked table subset. Qualify objects with `omop_csv_results`; header-comment the release, source, generation command, and checksum. Verify the schema is writable by the configured WebAPI source connection and that a test cohort can execute. Do not assume that creating the schema grants a non-owner WebAPI role access.

- [ ] **Step 2: Write `recreate_results.sh`**

```bash
#!/bin/bash
# recreate_results.sh <source-key> — drops+recreates results+temp for that source only.
set -eu
KEY="${1:?usage: recreate_results.sh omop_csv}"
[ "$KEY" = "omop_csv" ] || { echo "FAIL: unknown source $KEY" >&2; exit 1; }
: "${PGHOST:=postgres}" "${PGPORT:=5432}" "${PGUSER:=${POSTGRES_USER:-postgres}}" "${PGDATABASE:=${POSTGRES_DB:-fhir_omop_mcp_hub}}"
export PGHOST PGPORT PGUSER PGDATABASE
PGPASSWORD="$(cat "${POSTGRES_PASSWORD_FILE:-/run/secrets/postgres_password}")"; export PGPASSWORD
psql -v ON_ERROR_STOP=1 -c "DROP SCHEMA IF EXISTS omop_csv_results CASCADE; CREATE SCHEMA omop_csv_results;"
psql -v ON_ERROR_STOP=1 -c "DROP SCHEMA IF EXISTS omop_csv_temp CASCADE; CREATE SCHEMA omop_csv_temp;"
psql -v ON_ERROR_STOP=1 -f "$(dirname "$0")/results_ddl.sql"
```

Make executable. Require that WebAPI/MCP are stopped before either `DROP`; restore the source connection's `USAGE`/`CREATE` grants after each recreation if it does not own those schemas. Add a live test that definitions remain in `ohdsi_webapi` while prior results/cohort membership are removed.

- [ ] **Step 3: Wire into `db_init` + env example**

`db_init` needs the new SQL files. Extend its `volumes` in `compose.yaml`:

```yaml
  db_init:
    volumes:
      - ${DATA_ROOT:-./data}:/data
      - ./db/bootstrap:/bootstrap:ro
      - ./db/webapi:/webapi:ro
```

Append to `db/bootstrap/run.sh` (strict — no `|| true`; a registration failure must fail setup):

```bash
psql -v ON_ERROR_STOP=1 -f /webapi/results_ddl.sql
```

`results_ddl.sql` is idempotent (all objects `IF NOT EXISTS` or guarded), because `db_init`
reruns on every `bin/setup`. `etc/webapi.env.example` (only variables actually consumed):

```dotenv
WEBAPI_HOST_PORT=8080
```

(`WEBAPI_HOST_PORT` is the only WebAPI variable `compose.yaml` interpolates; DB connectivity
comes from `POSTGRES_*` in `etc/setup.env` plus the Docker secret.)

- [ ] **Step 4: Verify + commit**

```bash
bash tests/webapi/test_webapi_contract.sh
bin/compose run --rm db_init  # results DDL is idempotent; metadata registration waits for Task 4
git add db/webapi db/bootstrap compose.yaml etc/webapi.env.example
git commit -m "feat: add webapi results ddl and source registration"
```

### Task 3: WebAPI container + metadata migration health check

**Files:**
- Create: `docker/webapi/Dockerfile`
- Create: `docker/webapi/entrypoint.sh`
- Create: `docker/webapi/settings.xml`
- Modify: `compose.yaml` (append `ohdsi_webapi:` service block only)

**Interfaces:**
- Consumes: Tasks 1–2 (results schema exists via `db_init`; metadata created by WebAPI itself).
- Produces: `http://ohdsi_webapi:8080/WebAPI/` with migrated metadata; registration is Task 4.

- [ ] **Step 1: Write the Dockerfile + settings**

```dockerfile
# Pin an image compatible with the verified WAR servlet namespace; WebAPI 2.x
# commonly uses javax.servlet, which cannot deploy on Tomcat 10 (jakarta.servlet).
FROM tomcat:9-jre17
# Resolve the real war URL+SHA at implementation time and pin both here,
# e.g. curl -sL <release-war-url> | sha256sum; build fails without pinned values.
ARG WEBAPI_WAR_URL
ARG WEBAPI_SHA256
ADD ${WEBAPI_WAR_URL} /tmp/WebAPI.war
RUN echo "${WEBAPI_SHA256}  /tmp/WebAPI.war" | sha256sum -c - \
 && rm -rf /usr/local/tomcat/webapps/WebAPI \
 && unzip /tmp/WebAPI.war -d /usr/local/tomcat/webapps/WebAPI
COPY settings.xml /usr/local/tomcat/webapps/WebAPI/WEB-INF/classes/settings.xml
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
```

`settings.xml` points at `postgres:5432/fhir_omop_mcp_hub`, schema `ohdsi_webapi`, `${datasource.password}` from env; `entrypoint.sh` reads the secret file without logging it, then starts Tomcat. Install or verify every executable the image uses (`unzip`, `pg_isready` if waiting for DB, and `curl` if used in the healthcheck). Test WAR deployment and metadata migration on the pinned runtime before proceeding; use a different runtime only if proved compatible and recorded in PROVENANCE.md.

- [ ] **Step 2: Add compose service**

```yaml
  ohdsi_webapi:
    build: ./docker/webapi
    platform: linux/amd64
    depends_on:
      postgres: {condition: service_healthy}
      db_init: {condition: service_completed_successfully}
    secrets: [postgres_password]
    ports: ["127.0.0.1:${WEBAPI_HOST_PORT:-8080}:8080"]
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8080/WebAPI/source/sources || exit 1"]
      interval: 15s
      timeout: 10s
      retries: 20
      start_period: 120s
    restart: unless-stopped
```

- [ ] **Step 3: Verify live**

```bash
docker compose build ohdsi_webapi && docker compose up -d postgres ohdsi_webapi
curl -fsS http://127.0.0.1:8080/WebAPI/source/sources >/dev/null
bash tests/webapi/test_webapi_contract.sh
git add docker/webapi compose.yaml
git commit -m "feat: run webapi with omop_csv source"
```

Expected: WebAPI boots and creates its metadata tables; before Task 4 its source list may be empty. Contract PASS does not by itself prove migration or source registration.

### Task 4: Register and verify source after WebAPI migration

**Files:**
- Create: `db/webapi/register.sh`
- Modify: `compose.yaml` (append `webapi_register:` one-shot service)
- Modify: `tests/webapi/test_webapi_contract.sh` (live two-run idempotence and source mapping)

**Interfaces:**
- Consumes: healthy WebAPI from Task 3, `register_source.sql` from Task 1.
- Produces: exactly one `omop_csv` source with four correctly qualified daimons; MCP startup depends on successful completion.

- [ ] **Step 1: Prove the empty-source and repeat-registration cases**

Boot WebAPI on a fresh database and assert the source list is empty before registration. Run the registration job twice; assert one source key, four expected daemon mappings, and no duplicate rows. Use the running release's source endpoint, not a string grep over SQL. Verify a vocabulary request and a results write against this source.

- [ ] **Step 2: Add the post-migration registration job**

`register.sh` reads `/run/secrets/postgres_password`, runs `psql -v ON_ERROR_STOP=1 -f /webapi/register_source.sql`, and asserts the source and daimon rows match the mapping in Global Constraints. Add `webapi_register` using the pinned Postgres image, `/webapi:ro`, the password secret, and `depends_on: ohdsi_webapi: {condition: service_healthy}`; set `restart: "no"`. `bin/start` (operator plan) starts/recreates this **normal Compose service**, then starts MCP with `depends_on: webapi_register: {condition: service_completed_successfully}`; do not use `compose run --rm webapi_register`, since the removed container cannot satisfy that dependency. Do not gate WebAPI's pre-registration healthcheck on an already-registered source.

- [ ] **Step 3: Verify and commit**

Run the two-run live registration test, restart WebAPI, and verify its source endpoint still exposes exactly `omop_csv`; commit only `db/webapi/`, `compose.yaml`, and `tests/webapi/`.

## Stop Rules

- Stop if the pinned WebAPI cannot migrate its own metadata, the servlet namespace mismatches the runtime, or the live source/daimon/results contracts cannot be proved. Record the actual schema and endpoints in PROVENANCE.md before MCP implementation.
- Stop before registering `omop_fhir` or a second source — v1 has exactly one source.
- Stop on `0.0.0.0` port binding — loopback only.
