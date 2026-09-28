#!/bin/bash
# WebAPI entrypoint: wire the prebuilt WAR to postgres via JVM system
# properties (the v2.15.2 WAR has no settings.xml loading mechanism; its
# application.properties ${...} placeholders resolve from system properties).
# Secret travels via /run/secrets/postgres_password, never logs, never image.
set -eu

: "${POSTGRES_PASSWORD_FILE:=/run/secrets/postgres_password}"
: "${PGHOST:=postgres}"
: "${PGPORT:=5432}"
: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_DB:=fhir_omop_mcp_hub}"
: "${OHDSI_SCHEMA:=ohdsi_webapi}"

[ -f "$POSTGRES_PASSWORD_FILE" ] || { echo "FAIL: missing password file $POSTGRES_PASSWORD_FILE" >&2; exit 1; }
PW="$(cat "$POSTGRES_PASSWORD_FILE")"
[ -n "$PW" ] || { echo "FAIL: empty password file" >&2; exit 1; }

# Wait for the database with bash builtins (no extra client needed).
for _ in $(seq 1 60); do
  if (echo >"/dev/tcp/$PGHOST/$PGPORT") >/dev/null 2>&1; then break; fi
  sleep 2
done
(echo >"/dev/tcp/$PGHOST/$PGPORT") >/dev/null 2>&1 \
  || { echo "FAIL: cannot reach $PGHOST:$PGPORT" >&2; exit 1; }

URL="jdbc:postgresql://$PGHOST:$PGPORT/$POSTGRES_DB"
# shellcheck disable=SC2089
OPTS="\
 -Ddatasource.driverClassName=org.postgresql.Driver \
 -Ddatasource.url=$URL \
 -Ddatasource.username=$POSTGRES_USER \
 -Ddatasource.dialect=postgresql \
 -Ddatasource.ohdsi.schema=$OHDSI_SCHEMA \
 -Dflyway.datasource.driverClassName=org.postgresql.Driver \
 -Dflyway.datasource.url=$URL \
 -Dflyway.datasource.username=$POSTGRES_USER \
 -Dflyway.locations=classpath:db/migration/postgresql \
 -Dflyway.schemas=$OHDSI_SCHEMA \
 -Dflyway.placeholders.ohdsiSchema=$OHDSI_SCHEMA \
 -Dspring.jpa.properties.hibernate.default_schema=$OHDSI_SCHEMA \
 -Dspring.batch.repository.tableprefix=$OHDSI_SCHEMA.BATCH_ \
 -Dsecurity.provider=DisabledSecurity \
 -Dsecurity.origin=* \
 -Dsecurity.db.datasource.driverClassName=org.postgresql.Driver \
 -Dsecurity.db.datasource.url=$URL \
 -Dsecurity.db.datasource.username=$POSTGRES_USER \
 -Dsecurity.db.datasource.schema=$OHDSI_SCHEMA"
# Password appended last so it never appears in error paths above; unset right after.
# shellcheck disable=SC2090
export CATALINA_OPTS="${CATALINA_OPTS:-}${OPTS} -Ddatasource.password=${PW} -Dflyway.datasource.password=${PW} -Dsecurity.db.datasource.password=${PW}"
unset PW OPTS URL

exec /usr/local/tomcat/bin/catalina.sh run
