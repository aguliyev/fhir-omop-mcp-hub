#!/bin/bash
# run.sh [batch_id...] | --rebuild-accepted. One invocation per snapshot.
# Claim -> assemble -> clean -> ETL -> validate -> accept/reject.
set -eu
: "${PGHOST:=postgres}" "${PGPORT:=5432}" "${PGUSER:=${POSTGRES_USER:-postgres}}"
: "${PGDATABASE:=${POSTGRES_DB:-fhir_omop_mcp_hub}}" "${POSTGRES_PASSWORD_FILE:=/run/secrets/postgres_password}"
export PGHOST PGPORT PGUSER PGDATABASE
PGPASSWORD="$(cat "$POSTGRES_PASSWORD_FILE")"; export PGPASSWORD
INBOX=/data/csv_input/inbox; PEND=/data/csv_input/pending; OKDIR=/data/csv_input/success; BAD=/data/csv_input/rejected
mkdir -p "$PEND" "$OKDIR" "$BAD"
exec 9>/data/csv_input/.refresh.lock
flock -n 9 || { echo "REFRESH_FAILED: another refresh is active" >&2; exit 1; }
[ -z "$(ls -A "$PEND")" ] || { echo "REFRESH_FAILED: abandoned pending batches need manual review" >&2; exit 1; }
MODE=normal
if [ "${1:-}" = --rebuild-accepted ]; then
  [ "$#" -eq 1 ] || exit 2
  MODE=recovery; shift
  [ -n "$(ls -A "$OKDIR")" ] || { echo "REFRESH_FAILED: no accepted snapshot" >&2; exit 1; }
fi
RID="$(date -u +%Y%m%d-%H%M%S)-$(openssl rand -hex 4)"; WORK="/data/work/$RID"
mkdir -p "$WORK/csv" "$PEND" "$OKDIR" "$BAD"
IDS="${*:-$(ls "$INBOX" 2>/dev/null || true)}"
[ "$MODE" != recovery ] || IDS=
[ -n "$IDS" ] || [ "$MODE" = recovery ] || { echo "NOOP: inbox empty"; exit 0; }
[ -x /webapi/recreate_results.sh ] || { echo "REFRESH_FAILED: results reset unavailable" >&2; exit 1; }
for b in $IDS; do
  case "$b" in ????????-??????-????????) ;; *) echo "REFRESH_FAILED: invalid batch id '$b'" >&2; exit 1;; esac
  [ -d "$INBOX/$b" ] || { echo "REFRESH_FAILED: batch '$b' not in inbox" >&2; exit 1; }
  [ ! -e "$BAD/$b" ] && [ ! -e "$OKDIR/$b" ] || { echo "REFRESH_FAILED: duplicate batch '$b'" >&2; exit 1; }
done
STAGE=claim
on_exit() {
  status=$?
  trap - EXIT
  [ "$status" -eq 0 ] && return
  for b in $IDS; do
    if [ -d "$PEND/$b" ]; then
      [ ! -e "$BAD/$b" ] || { echo "REFRESH_FAILED: rejected path exists for $b" >&2; continue; }
      mv -T "$PEND/$b" "$BAD/$b"
      printf '{"batch_id":"%s","refresh_id":"%s","stage":"%s","exit":%s,"manifest":"%s","log":"%s"}\n' \
        "$b" "$RID" "$STAGE" "$status" "$WORK/manifest.json" "$WORK/etl.log" > "$BAD/$b/error.json"
    fi
  done
  exit "$status"
}
trap on_exit EXIT
for b in $IDS; do mv "$INBOX/$b" "$PEND/$b"; done
STAGE=assemble
python3 /opt/etl-synthea/job/assemble.py "$OKDIR" "$PEND" "$WORK/csv" 2>&1 | tee "$WORK/etl.log"
python3 - "$RID" "$WORK" "$OKDIR" "$PEND" <<'PY'
import datetime, hashlib, json, pathlib, sys
rid, work, accepted, pending = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), pathlib.Path(sys.argv[4])
old_ids = sorted(p.name for p in accepted.iterdir() if p.is_dir())
new_ids = sorted(p.name for p in pending.iterdir() if p.is_dir())
def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()
staged = pathlib.Path('/data/athena_input/current/manifest.sha256')
manifest = {'refresh_id': rid, 'at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'accepted_batch_ids': old_ids, 'new_batch_ids': new_ids, 'snapshot_batch_ids': old_ids + new_ids,
    'synthea_version': '3.3.0', 'etl_synthea_version': '2.1.1', 'cdm_version': '5.3.1',
    'athena_manifest_sha256': sha(staged),
    'assembled_sha256': {p.name: sha(p) for p in sorted((work / 'csv').glob('*.csv'))}}
(work / 'manifest.json').write_text(json.dumps(manifest, sort_keys=True) + '\n')
PY
STAGE=clean
psql -v ON_ERROR_STOP=1 -f /db-omop-csv/clinical_tables.sql >>"$WORK/etl.log" 2>&1
psql -v ON_ERROR_STOP=1 -f /opt/etl-synthea/job/clean.sql >>"$WORK/etl.log" 2>&1
STAGE=reset_results
/webapi/recreate_results.sh omop_csv >>"$WORK/etl.log" 2>&1
STAGE=etl
set +e
env -u PGUSER -u PGPASSWORD Rscript /opt/etl-synthea/job/run_etl.R "$WORK/csv" >>"$WORK/etl.log" 2>&1
STATUS=$?; set -e
[ "$STATUS" -eq 0 ] || exit "$STATUS"
STAGE=validate
{
  PERSONS="$(psql -tA -v ON_ERROR_STOP=1 -c "SELECT count(*) FROM omop_csv.person;")"
  [ "$PERSONS" -gt 0 ] || { echo "REFRESH_FAILED: omop_csv.person empty after load" >&2; exit 1; }
  if [ -f "$WORK/csv/patients.csv" ]; then
    EXPECTED="$(( $(grep -c '^' "$WORK/csv/patients.csv" || true) - 1 ))"
    [ "$PERSONS" -eq "$EXPECTED" ] || { echo "REFRESH_FAILED: person=$PERSONS != patients.csv rows=$EXPECTED" >&2; exit 1; }
  fi
  for v in concept concept_ancestor concept_class concept_relationship concept_synonym domain drug_strength relationship source_to_concept_map vocabulary; do
    psql -v ON_ERROR_STOP=1 -c "SELECT count(*) FROM omop_csv.$v;" >/dev/null
  done
  CONCEPTS="$(psql -tA -v ON_ERROR_STOP=1 -c "SELECT count(*) FROM omop_csv.concept;")"
  [ "$CONCEPTS" -gt 0 ] || { echo "REFRESH_FAILED: vocabulary view omop_csv.concept empty" >&2; exit 1; }
  echo "VALIDATED persons=$PERSONS concepts=$CONCEPTS"
} >>"$WORK/etl.log" 2>&1
STAGE=accept
for b in $IDS; do mv -T "$PEND/$b" "$OKDIR/$b"; done
echo "REFRESH_OK $RID"
