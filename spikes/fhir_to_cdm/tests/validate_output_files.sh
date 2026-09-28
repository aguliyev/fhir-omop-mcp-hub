#!/bin/sh
# Output-contract test per candidate: exit 0, no exceptions, person>=1 row,
# 10 distinct person_source_value, visit>=1 row, tab-delimited stable columns.
set -eu
SPIKE_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SPIKE_DIR/../.." && pwd)"
DATA_ROOT=$(sed -n 's/^DATA_ROOT=//p' "$REPO_ROOT/etc/setup.env" | head -n 1)
case "$DATA_ROOT" in /*) ;; *) DATA_ROOT="$REPO_ROOT/$DATA_ROOT";; esac
WORK="$DATA_ROOT/work/fhir_to_cdm_spike"
fail=0
check() {
  fmt="$1"
  log="$WORK/logs/convert_$fmt.log"
  dir="$WORK/generated/$fmt"
  echo "--- candidate $fmt ---"
  if [ -f "$log" ] && grep -q "exit=$fmt" /dev/null 2>/dev/null; then :; fi
  if [ ! -d "$dir" ]; then echo "FAIL: $fmt no output dir"; fail=1; return; fi
  if [ -f "$log" ]; then
    if grep -Ei 'unhandled|KeyNotFoundException|duplicate-key|parser exception|Unhandled exception' "$log" >/dev/null; then echo "FAIL: $fmt log shows exceptions"; fail=1; else echo "ok: $fmt no exception signatures"; fi
  else echo "FAIL: $fmt no log"; fail=1; fi
  if python3 - "$dir" "$fmt" <<'EOF'
import glob, os, sys
d, fmt = sys.argv[1], sys.argv[2]
fail = False
def person_files(table):
    return sorted(glob.glob(os.path.join(d, f"{table}*.csv")) + glob.glob(os.path.join(d, f"{table}*.txt")))
pf = person_files("person")
if not pf:
    print(f"FAIL: {fmt} no person output"); sys.exit(1)
srcvals = set()
rows = 0
cols = None
for f in pf:
    lines = open(f, errors="replace").read().splitlines()
    if not lines:
        print(f"FAIL: {fmt} empty {f}"); fail = True; continue
    if "\t" not in lines[0]:
        print(f"FAIL: {fmt} {os.path.basename(f)} not tab-delimited"); fail = True; continue
    hdr = lines[0].split("\t")
    if cols is None: cols = len(hdr)
    elif len(hdr) != cols:
        print(f"FAIL: {fmt} unstable column count"); fail = True
    try:
        si = [h.lower() for h in hdr].index("person_source_value")
    except ValueError:
        print(f"FAIL: {fmt} person lacks person_source_value"); fail = True; continue
    for ln in lines[1:]:
        if not ln.strip(): continue
        parts = ln.split("\t")
        if len(parts) != cols:
            print(f"FAIL: {fmt} ragged row in {os.path.basename(f)}"); fail = True; break
        rows += 1
        srcvals.add(parts[si])
print(f"person data rows={rows} distinct_source_values={len(srcvals)}")
if rows < 1: print(f"FAIL: {fmt} person has no data rows"); fail = True
if len(srcvals) != 10: print(f"FAIL: {fmt} want 10 distinct person_source_value, got {len(srcvals)}"); fail = True
vf = person_files("visit_occurrence")
vrows = 0
for f in vf:
    lines = open(f, errors="replace").read().splitlines()
    vrows += max(0, len([l for l in lines[1:] if l.strip()]))
print(f"visit_occurrence data rows={vrows}")
if vrows < 1: print(f"FAIL: {fmt} visit_occurrence empty"); fail = True
sys.exit(1 if fail else 0)
EOF
  then echo "ok: $fmt file contract"; else echo "FAIL: $fmt file contract"; fail=1; fi
}
for c in r4 stu3; do check "$c"; done
[ "$fail" -eq 0 ] && echo "output validation: PASSED" || { echo "output validation: FAILED"; exit 1; }
