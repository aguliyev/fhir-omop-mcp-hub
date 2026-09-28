#!/bin/bash
# Prior art: spikes/fhir_to_cdm/synthea/generate.sh proves the 3.3.0 CLI shape
# (-p, -s, -cs, -r, --exporter.* overrides). Reuse its flags; record deviations.
set -eu
: "${POPULATION_SIZE:=100}"
REF="${SYNTHEA_REFERENCE_DATE:-20240101}"
DATA_DIR="${DATA_DIR:-/data}"

# Seed check: reject duplicate patient seeds already in inbox/ or success/
is_seed_used() {
  local s="$1"
  for dir in "$DATA_DIR/csv_input/inbox" "$DATA_DIR/csv_input/success" "$DATA_DIR/fhir_input/inbox" "$DATA_DIR/fhir_input/success"; do
    [ -d "$dir" ] || continue
    for mf in "$dir"/*/batch.json; do
      [ -f "$mf" ] || continue
      if grep -Eq '"seed"[[:space:]]*:[[:space:]]*'"$s"'\b' "$mf" 2>/dev/null; then
        return 0
      fi
    done
  done
  return 1
}

if [ -n "${SEED:-}" ]; then
  if is_seed_used "$SEED"; then
    echo "FAIL: patient seed $SEED already used in existing batch" >&2
    exit 1
  fi
else
  while true; do
    SEED=$((RANDOM * 32768 + RANDOM))
    if ! is_seed_used "$SEED"; then
      break
    fi
  done
fi

CSEED="${CLINICIAN_SEED:-$((RANDOM * 32768 + RANDOM))}"
BATCH_ID="$(date -u +%Y%m%d-%H%M%S)-$(openssl rand -hex 4)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP"  # Synthea writes ./output/{csv,fhir}/ relative to CWD.
java -jar /opt/synthea/synthea.jar -p "$POPULATION_SIZE" -s "$SEED" -cs "$CSEED" -r "$REF" \
  --exporter.csv.export true --exporter.fhir.export true \
  --exporter.use_uuid_filenames true \
  --exporter.hospital.fhir.export false --exporter.practitioner.fhir.export false
/opt/synthea/publish.sh "$TMP/output" "$BATCH_ID" "$SEED" "$POPULATION_SIZE" "$CSEED" "$REF"
echo "GENERATED batch=$BATCH_ID seed=$SEED population=$POPULATION_SIZE"
