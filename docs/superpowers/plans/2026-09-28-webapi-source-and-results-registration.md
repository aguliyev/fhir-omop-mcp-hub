# WebAPI Source and Results Registration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run one OHDSI WebAPI instance that serves vocabulary search and cohort-definition/generation/execution against the single v1 `omop_csv` source.

**Architecture:** `ohdsi_webapi` container (pinned WebAPI release, linux/amd64) connects to `fhir_omop_mcp_hub` with one JDBC connection per source. `db_init` idempotently creates `omop_csv_results`/`omop_csv_temp` via WebAPI-generated results DDL and registers the `omop_csv` source + daimons from repo config. Clinical refresh drops+recreates only this source's results/temp schemas. No `omop_fhir` registration in v1.

**Tech Stack:** Docker Compose, PostgreSQL 16.4, OHDSI WebAPI 2.x (pinned war), Tomcat/Java 17, `psql`, POSIX shell.

**Spec:** `docs/intro.md` §§4, 6, 8, 10 (one WebAPI, one source `omop_csv`, own results/temp, shared `athena_vocabs`).

**File ownership (parallel agents):** this plan owns `docker/webapi/`, `db/webapi/`,
`etc/webapi.env.example`, `tests/webapi/`, plus the `db_init` service definition and
`db/bootstrap/run.sh` extension. It must not edit `compose.yaml` beyond appending its own
`ohdsi_webapi:` block and extending the existing `db_init:` block's volumes, and must not
touch any other plan's files. (`omop_fhir*` schemas already created empty by bootstrap stay
empty and unregistered in v1 — do not remove them.)

## Global Constraints

- Pin the exact WebAPI release (war URL + SHA-256) in `docker/webapi/PROVENANCE.md`; `platform: linux/amd64`.
- One database `fhir_omop_mcp_hub`; source key exactly `omop_csv` (lowercase snake case).
- Source wiring: CDM `omop_csv`, vocabulary `athena_vocabs`, results `omop_csv_results`, temp `omop_csv_temp`.
- `ohdsi_webapi` schema holds WebAPI metadata + source/daimon rows; cohort definitions persist across clinical refreshes, executions do not.
- Results DDL is the WebAPI-generated DDL for the results schema, stored versioned under `db/webapi/`.
- WebAPI host port bound to `127.0.0.1` only (configurable, default `8080`); container-to-container via Compose network.
- No secrets in tracked files; DB password via `/run/secrets/postgres_password`.

---

## Planned File Structure

```text
docker/webapi/{Dockerfile,PROVENANCE.md,entrypoint.sh,settings.xml}
db/webapi/{results_ddl.sql,register_source.sql,recreate_results.sh}
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

Choose the newest WebAPI 2.x release that supports CDM 5.3.1 + Postgres 16; record war URL + SHA-256 in `docker/webapi/PROVENANCE.md`. `db/webapi/register_source.sql` (idempotent, runs in `db_init`):

```sql
-- Idempotent omop_csv source + daimon registration.
INSERT INTO ohdsi_webapi.webapi.source (source_id, source_name, source_key, source_connection, source_dialect)
VALUES (100, 'Synthea CSV', 'omop_csv',
  'jdbc:postgresql://postgres:5432/fhir_omop_mcp_hub?currentSchema=omop_csv,athena_vocabs',
  'postgresql')
ON CONFLICT (source_key) DO UPDATE SET source_name='Synthea CSV',
  source_connection='jdbc:postgresql://postgres:5432/fhir_omop_mcp_hub?currentSchema=omop_csv,athena_vocabs';
INSERT INTO ohdsi_webapi.webapi.source_daimon (source_id, daimon_type, table_qualifier, priority)
VALUES (100, 0, 'omop_csv', 0), (100, 1, 'athena_vocabs', 0),
       (100, 2, 'omop_csv_results', 0), (100, 3, 'omop_csv_temp', 0)
ON CONFLICT DO NOTHING;
```

Adjust table/column names to the pinned WebAPI's actual `source`/`source_daimon` DDL — inspect the war's `WEB-INF/db/postgresql/` migration scripts and record any correction in PROVENANCE.md. Daimon types: 0 CDM, 1 vocabulary, 2 results, 3 temp.

- [ ] **Step 3: Commit contract**

```bash
git add docker/webapi/PROVENANCE.md db/webapi/register_source.sql tests/webapi/test_webapi_contract.sh
git commit -m "build: define webapi source contract"
```

### Task 2: Results DDL + recreate script + `db_init` wiring

**Files:**
- Create: `db/webapi/results_ddl.sql`
- Create: `db/webapi/recreate_results.sh`
- Modify: `db/bootstrap/run.sh` (apply `results_ddl.sql` + `register_source.sql` idempotently)
- Create: `etc/webapi.env.example`

**Interfaces:**
- Consumes: `register_source.sql` from Task 1.
- Produces: `recreate_results.sh omop_csv` called by the CSV-refresh plan; `ohdsi_webapi` metadata consumed by Task 3.

- [ ] **Step 1: Capture results DDL**

Generate `results_ddl.sql` from the pinned WebAPI war (its `ddl/results/postgresql.sql` or the WebAPI "generate results DDL" endpoint against an empty schema). Qualify objects with `omop_csv_results`. Header-comment the WebAPI version + generation command. Minimal viable surface: `cohort`, `cohort_inclusion`, `cohort_inclusion_result`, `cohort_inclusion_stats`, `cohort_summary_stats`, `achilles_*` tables WebAPI requires at startup.

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

Make executable.

- [ ] **Step 3: Wire into `db_init` + env example**

Append to `db/bootstrap/run.sh`:

```bash
psql -v ON_ERROR_STOP=1 -f /bootstrap/../webapi/results_ddl.sql || true  # mount-aware; see compose
psql -v ON_ERROR_STOP=1 -f /bootstrap/../webapi/register_source.sql
```

Prefer mounting `./db:/db:ro` in compose and referencing `/db/webapi/...`. `etc/webapi.env.example`:

```dotenv
WEBAPI_IMAGE_CUSTOM=local
WEBAPI_HOST_PORT=8080
WEBAPI_DB_SCHEMA=ohdsi_webapi
```

- [ ] **Step 4: Verify + commit**

```bash
bash tests/webapi/test_webapi_contract.sh
psql -v ON_ERROR_STOP=1 -f db/webapi/register_source.sql  # against dev db if up
git add db/webapi db/bootstrap etc/webapi.env.example
git commit -m "feat: add webapi results ddl and source registration"
```

### Task 3: WebAPI container + compose + health check

**Files:**
- Create: `docker/webapi/Dockerfile`
- Create: `docker/webapi/entrypoint.sh`
- Create: `docker/webapi/settings.xml`
- Modify: `compose.yaml` (add `ohdsi_webapi` service)

**Interfaces:**
- Consumes: Tasks 1–2 (source rows + results schema exist via `db_init`).
- Produces: `http://ohdsi_webapi:8080/WebAPI/` with `omop_csv` source; base URL consumed by the MCP plan.

- [ ] **Step 1: Write the Dockerfile + settings**

```dockerfile
FROM tomcat:10.1-jre17
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

`settings.xml` points at `postgres:5432/fhir_omop_mcp_hub`, schema `ohdsi_webapi`, `${datasource.password}` from env; `entrypoint.sh` waits for `pg_isready`, substitutes the secret-file password, then `catalina.sh run`.

- [ ] **Step 2: Add compose service**

```yaml
  ohdsi_webapi:
    build: ./docker/webapi
    platform: linux/amd64
    depends_on:
      postgres: {condition: service_healthy}
      db_init: {condition: service_completed_successfully}
    env_file: [etc/setup.env, etc/webapi.env]
    volumes: [${DATA_ROOT:-./data}:/data]
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
curl -s http://127.0.0.1:8080/WebAPI/source/sources | grep -q omop_csv
bash tests/webapi/test_webapi_contract.sh
git add docker/webapi compose.yaml
git commit -m "feat: run webapi with omop_csv source"
```

Expected: sources endpoint lists exactly `omop_csv`; contract PASS.

## Stop Rules

- Stop if the pinned WebAPI's `source`/`source_daimon` DDL differs — read the war's migration SQL, adapt `register_source.sql`, record in PROVENANCE.md.
- Stop before registering `omop_fhir` or a second source — v1 has exactly one source.
- Stop on `0.0.0.0` port binding — loopback only.
