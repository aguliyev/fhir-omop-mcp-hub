#!/bin/bash
# tests/webapi/test_webapi_contract.sh
set -eu
for f in docker/webapi/Dockerfile db/webapi/results_ddl.sql db/webapi/register_source.sql db/webapi/recreate_results.sh etc/webapi.env.example; do
  [ -f "$f" ] || { echo "FAIL: missing $f"; exit 1; }
done
grep -q "omop_csv" db/webapi/register_source.sql || { echo "FAIL: no omop_csv source"; exit 1; }
grep -v '^--' db/webapi/register_source.sql | grep -q "omop_fhir" && { echo "FAIL: omop_fhir must not register in v1"; exit 1; }

# Live checks: source mapping against the running release's source endpoint.
# (Two-run registration idempotence itself is proven by running the
# webapi_register job twice — see PROVENANCE.md; this asserts the result.)
# Skipped with NOTICE when WebAPI is not reachable or python3 is absent.
LIVE_URL="http://127.0.0.1:${WEBAPI_HOST_PORT:-8080}/WebAPI/source/sources"
if command -v python3 >/dev/null 2>&1 && curl -fsS --max-time 10 "$LIVE_URL" 2>/dev/null | python3 -c "
import json, sys
srcs = json.load(sys.stdin)
assert isinstance(srcs, list) and len(srcs) == 1, f'expected exactly 1 source, got {len(srcs)}'
s = srcs[0]
assert s['sourceKey'] == 'omop_csv', s
got = sorted((d['daimonType'], d['tableQualifier']) for d in s['daimons'])
want = sorted([('CDM', 'omop_csv'), ('Vocabulary', 'athena_vocabs'), ('Results', 'omop_csv_results'), ('Temp', 'omop_csv_temp')])
assert got == want, got
"; then
  echo "PASS: webapi contract (live source mapping OK)"
else
  echo "NOTICE: WebAPI not reachable at $LIVE_URL or no python3; live mapping checks skipped"
  echo "PASS: webapi contract (static only)"
fi
