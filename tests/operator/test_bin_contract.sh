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
