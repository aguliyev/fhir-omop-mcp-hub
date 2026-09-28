# Synthea 3.3.0 Provenance and CLI Flags

## Canonical Source

- Upstream Release: [Synthea v3.3.0](https://github.com/synthetichealth/synthea/releases/tag/v3.3.0)
- Jar URL: `https://github.com/synthetichealth/synthea/releases/download/v3.3.0/synthea-with-dependencies.jar`
- SHA-256: `8ba04f7d73abadd5a377e41edf24c5c83935a1cb07c6d982cd5db731ef1cf445`
- Base Image: `eclipse-temurin:17-jre-jammy@sha256:97137382c6f0c30427d9b7c44ad8b2d55ac823b0768c171d81a643ed219023c5`

Verify jar checksum with:

```bash
curl -sL "https://github.com/synthetichealth/synthea/releases/download/v3.3.0/synthea-with-dependencies.jar" | sha256sum
```

Digest verified 2026-09-28: `8ba04f7d73abadd5a377e41edf24c5c83935a1cb07c6d982cd5db731ef1cf445`.

## Verified CLI Flags (Synthea 3.3.0)

Verified against `java -jar synthea.jar --help`:

- `-p <populationSize>`: Population count to generate.
- `-s <seed>`: Patient seed (integer).
- `-cs <clinicianSeed>`: Clinician / provider seed (integer).
- `-r <referenceDate as YYYYMMDD>`: Fixed reference date for synthetic history generation.
- `--exporter.csv.export=true`: Exports tabular patient records to `./output/csv/`.
- `--exporter.fhir.export=true`: Exports FHIR R4 JSON bundles to `./output/fhir/`.
- `--exporter.use_uuid_filenames=true`: Assigns UUID-based filenames to avoid naming collisions.
- `--exporter.hospital.fhir.export=false`: Disables hospital resource bundle generation (archive scope patient bundles only).
- `--exporter.practitioner.fhir.export=false`: Disables practitioner resource bundle generation.
