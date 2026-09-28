#!/bin/bash
# publish.sh <synthea-output-root> <batch-id> <seed> <population> <clinician-seed> <reference-date>
set -eu
SRC="$1"; BID="$2"; SEED="$3"; POP="$4"; CSEED="$5"; REF="$6"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for q in csv_input fhir_input; do mkdir -p "/data/$q/inbox" "/data/$q/pending" "/data/$q/success" "/data/$q/rejected"; done
C_STAGE="/data/csv_input/.staging-$BID"; F_STAGE="/data/fhir_input/.staging-$BID"
F_DEST="/data/fhir_input/inbox/$BID"
for d in "$C_STAGE" "$F_STAGE" "/data/csv_input/inbox/$BID" "/data/fhir_input/inbox/$BID"; do
  [ ! -e "$d" ] || { echo "FAIL: batch path exists: $d" >&2; exit 1; }
done
mkdir -p "$C_STAGE" "$F_STAGE"
PUBLISHED=0
trap '[ "$PUBLISHED" -eq 1 ] || { rm -rf "$C_STAGE" "$F_STAGE"; [ ! -d "$F_DEST" ] || rm -rf "$F_DEST"; }' EXIT
find "$SRC/csv" -name '*.csv' -exec cp {} "$C_STAGE/" \;
find "$SRC/fhir" -name '*.json' -exec cp {} "$F_STAGE/" \;
compgen -G "$C_STAGE/*.csv" >/dev/null && compgen -G "$F_STAGE/*.json" >/dev/null || { echo "FAIL: empty CSV or FHIR export" >&2; exit 1; }
gen_manifest() { # $1=stagedir $2=extension
  (cd "$1" && sha256sum -- *."$2" | LC_ALL=C sort > files.sha256)
  csv_list=$(python3 -c 'import json,sys,pathlib; print(json.dumps(sorted(p.name for p in pathlib.Path(sys.argv[1]).glob("*.csv"))))' "$C_STAGE")
  fhir_list=$(python3 -c 'import json,sys,pathlib; print(json.dumps(sorted(p.name for p in pathlib.Path(sys.argv[1]).glob("*.json"))))' "$F_STAGE")
  printf '{"batch_id":"%s","synthea_version":"3.3.0","seed":%s,"clinician_seed":%s,"reference_date":"%s","population":%s,"generated_at_utc":"%s","csv_files":%s,"fhir_files":%s}\n' \
    "$BID" "$SEED" "$CSEED" "$REF" "$POP" "$TS" "$csv_list" "$fhir_list" > "$1/batch.json"
}
gen_manifest "$C_STAGE" csv; gen_manifest "$F_STAGE" json
cmp "$C_STAGE/batch.json" "$F_STAGE/batch.json" || { echo "FAIL: batch.json mismatch" >&2; exit 1; }
(cd "$C_STAGE" && sha256sum -c files.sha256 >/dev/null)
(cd "$F_STAGE" && sha256sum -c files.sha256 >/dev/null)
mv -T "$F_STAGE" "$F_DEST"
mv -T "$C_STAGE" "/data/csv_input/inbox/$BID"
PUBLISHED=1
