#!/bin/sh
# Failing-first input validation: 5 Bundles per batch/format, 1 Patient each, unique ids, 10 assembled per format.
set -eu
SPIKE_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SPIKE_DIR/../.." && pwd)"
DATA_ROOT=$(sed -n 's/^DATA_ROOT=//p' "$REPO_ROOT/etc/setup.env" | head -n 1)
case "$DATA_ROOT" in /*) ;; *) DATA_ROOT="$REPO_ROOT/$DATA_ROOT";; esac
WORK="$DATA_ROOT/work/fhir_to_cdm_spike"
fail=0
need() { if [ "$2" = "$3" ]; then echo "ok: $1 ($2)"; else echo "FAIL: $1 expected $3 got $2"; fail=1; fi; }
for fmt in r4 stu3; do
  for b in batch_001 batch_002; do
    d="$WORK/batches/$b/$fmt"
    n=$(grep -l '"resourceType": *"Bundle"' "$d"/*.json 2>/dev/null | wc -l | tr -d ' ')
    need "$b/$fmt file count" "$n" 5
  done
  d="$WORK/assembled/$fmt"
  n=$(ls "$d"/*.json 2>/dev/null | wc -l | tr -d ' ')
  need "assembled/$fmt count" "$n" 10
  if ls "$d"/*.ndjson >/dev/null 2>&1; then echo "FAIL: NDJSON present in $fmt"; fail=1; else echo "ok: no NDJSON in $fmt"; fi
done
python3 - "$WORK" <<'EOF'
import json, glob, sys
work = sys.argv[1]
seen = {}
fail = False
for fmt in ("r4", "stu3"):
    for f in sorted(glob.glob(f"{work}/assembled/{fmt}/*.json")):
        try:
            b = json.load(open(f))
        except Exception as e:
            print(f"FAIL: {f} not JSON: {e}"); fail = True; continue
        if b.get("resourceType") != "Bundle":
            print(f"FAIL: {f} root is {b.get('resourceType')}, want Bundle"); fail = True; continue
        pats = [e.get("resource", {}) for e in b.get("entry", []) if e.get("resource", {}).get("resourceType") == "Patient"]
        if len(pats) != 1:
            print(f"FAIL: {f} has {len(pats)} Patients, want 1"); fail = True; continue
        pid = pats[0].get("id")
        if not pid:
            print(f"FAIL: {f} Patient missing id"); fail = True; continue
        key = (fmt, pid)
        if key in seen:
            print(f"FAIL: duplicate Patient id {pid} in {fmt}: {seen[key]} vs {f}"); fail = True
        seen[key] = f
print("ok: all Bundles valid, Patient ids unique" if not fail else "input validation FAILED")
sys.exit(1 if fail else 0)
EOF
[ "$fail" -eq 0 ] || exit 1
echo "input validation: PASSED"
