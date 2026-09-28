#!/bin/sh
# Generate one Synthea batch: $1=batch_id $2=patient_seed $3=clinician_seed $4=r4|stu3
set -eu
BATCH="${1:?batch id}"; PSEED="${2:?patient seed}"; CSEED="${3:?clinician seed}"; FMT="${4:?r4|stu3}"
REF="${SYNTHEA_REFERENCE_DATE:-20240101}"
OUT="/work/batches/$BATCH/$FMT"
mkdir -p "$OUT"
RUN="/tmp/synrun_${BATCH}_${FMT}"
rm -rf "$RUN"; mkdir -p "$RUN"; cd "$RUN"
if [ "$FMT" = "r4" ]; then R4=true; STU3=false; else R4=false; STU3=true; fi
java -jar /opt/synthea/synthea-with-dependencies.jar \
  -p 5 -s "$PSEED" -cs "$CSEED" -r "$REF" \
  --exporter.use_uuid_filenames true \
  --exporter.csv.export false \
  --exporter.fhir.export "$R4" \
  --exporter.fhir_stu3.export "$STU3" \
  --exporter.hospital.fhir.export false \
  --exporter.hospital.fhir_stu3.export false \
  --exporter.practitioner.fhir.export false \
  --exporter.practitioner.fhir_stu3.export false
find "$RUN/output" -name '*.json' -exec cp {} "$OUT/" \;
echo "wrote $(ls "$OUT" | wc -l) files to $OUT"
ls "$OUT"
