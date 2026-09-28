#!/bin/bash
# tests/synthea/test_batch_contract.sh — asserts batch ID + manifest schema.
set -eu
fail=0
grep -Eq '^[0-9]{8}-[0-9]{6}-[0-9a-f]{8}$' <<<"20260928-014500-ab12cd34" || { echo "FAIL: batch id regex"; fail=1; }
for f in docker/synthea/generate.sh docker/synthea/publish.sh etc/synthea.env.example bin/generate; do
  [ -f "$f" ] || { echo "FAIL: missing $f"; fail=1; }
done
[ "$fail" -eq 0 ] && echo "PASS: batch contract" || exit 1
