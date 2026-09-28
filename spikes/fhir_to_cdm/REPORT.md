# FhirToCdm Feasibility Spike — Report

Verdict: `FAILED`

## Host / platform

- Linux x86_64, native `linux/amd64` (no emulation).
- Docker Compose v5.4.0, Postgres `postgres:16.4-alpine` (spike scratch DB
  `fhir_to_cdm_spike` on 127.0.0.1:55432, isolated from canonical
  `fhir_omop_mcp_hub`).
- Repository `bin/validate-setup` reported READY before experiments.

## Resolved pins and checksums

- Synthea tag `v3.3.0` → commit `995cf2fd33e67918d4e33110d9f68ad248002221`.
- Synthea release asset `synthea-with-dependencies.jar` SHA-256:
  `8ba04f7d73abadd5a377e41edf24c5c83935a1cb07c6d982cd5db731ef1cf445`
  (182,655,376 bytes).
- FhirToCdm short ref `4991f90` → full
  `4991f907ba075cb5875020b3a83995ba15185dae` (recorded in image
  `/opt/fhir-to-cdm/UPSTREAM_COMMIT`).
- No upstream source file, project target, package reference, lookup content,
  or checked-in executable was changed.

## Build evidence

Source build from the exact commit succeeded after two wrapper-level
environment adaptations (Dockerfile/entrypoint only, no converter behavior
change):

1. Debian buster apt sources moved to `archive.debian.org` (base images EOL).
2. `WORKDIR /opt/fhir-to-cdm` so relative `Lookups/` resolves.
3. `odbcinst` alias `[PostgreSQL UNICODE]` for the exact driver name in the
   upstream README template (Debian registers `PostgreSQL Unicode`).
4. Upstream `Vocabulary.cs` reads `@"Lookups\Base.sql"` (Windows separator)
   as the shared template while enumerating `Lookups/` and skipping that same
   literal. On Linux the backslash names a different file and the skip never
   matches, so `Base.sql` would load as a query fragment and fail. The image
   moves the forward-slash copy aside to `/opt/fhir-to-cdm/Base.sql.ref`
   (bytes preserved, SHA-256
   `6a950b2ca66a715df7bb6d11a20c683996b85613e54d0f5ff8bcdb2884f06f4d`)
   and exposes identical bytes under the single-backslash name the program
   asks for. Enumeration then sees only the five real lookups.
5. Spike postgres `shm_size: 2g` (13M-row vocabulary join exhausted /dev/shm).

Image contract verified: .NET Core 3.1.32 runtime, `--help` lists
fhir/vocabulary/schema/cdm/result/chunk, PostgreSQL Unicode ODBC driver
listed, `UPSTREAM_COMMIT` matches the pinned full SHA. The checked-in
`executable/` fallback was not needed.

## Vocabulary evidence

Scratch `athena_vocabs` loaded from staged
`<data-root>/athena_input/current` (tab-delimited, nine files;
`source_to_concept_map` created empty, 0 rows):

| table | rows |
|---|---|
| concept | 1,918,849 |
| concept_relationship | 12,928,348 |
| concept_ancestor | 10,900,123 |
| concept_class | 433 |
| concept_synonym | 2,440,270 |
| domain | 50 |
| drug_strength | 209,849 |
| relationship | 724 |
| vocabulary | 41 |

`vocabulary_id='None'` present (1 row); all five families
(SNOMED/RxNorm/LOINC/CVX/UCUM) present with valid standard concepts.
Read-only concept count through the converter image ODBC path returned
1,918,849. All five lookups filled: Cvx 289, Unit 1,082, Snomed 1,106,309,
RxNorm 316,330, Loinc 287,814 keys.

## R4 result

Two batches × five deterministic patient Bundles (seeds 8675309/8675310,
reference 20240101, UUID filenames), assembled to ten Bundles; input
validation passed. Conversion with `--cdm V53 --chunk 4`:

- Vocabulary phase: all five lookups DONE (see above).
- Then: `Unhandled exception. System.Exception: unknown vocabulary
  http://www.ada.org/cdt` at `FhirToCdmMappings.LookupCode`
  (`FhirToCdmMappings.cs:621`) via `CreateProcedureOccurrence`
  (`:428`). Exit nonzero. No output files written.
- Upstream supports only SNOMED, RxNorm, CVX, and LOINC system URIs and
  throws on anything else. Default Synthea output contains 67 CDT-coded
  procedures, plus one Condition carrying only `http://hl7.org/fhir/sid/icd-10`
  (no SNOMED dual coding), which would throw next.
- Fixing this requires changing upstream source (new vocabulary branches) or
  surgically filtering Synthea output — both forbidden by the spike contract.

## STU3 result

Same ten-Bundle assembly; input validation passed. Conversion failed at
parse time:

- `System.FormatException: ... unknown element 'reason' at location
  'Bundle.entry[1].resource[0].reason[0]' while parsing` at `Program.Main
  (:112)`. Exit nonzero. No output files written.
- The project references `Hl7.Fhir.R4` only; STU3 bundles are unparseable by
  design. Fixing this requires a source/dependency change — forbidden.

## Multi-batch result

Not reached: no candidate completed a single ten-Bundle invocation, so
multi-batch identity behavior is unproven.

## Database validation

Not reached: no V53 files were emitted, so nothing was loaded into OMOP
5.3.1 DDL and no relational checks ran. Tasks 6–7 scripts were omitted as
inapplicable on the FAILED path.

## Reproducibility

`bin/run-spike` chains prerequisites → generation → assembly → validation →
vocab load → both conversions → file validation. Reruns reproduce the same
two exceptions deterministically (same seeds, same pinned commits).

## Limitations

- .NET Core 3.1 is end-of-support; the image is a local demonstration only.
- Wrapper adaptations (ODBC alias, backslash filename shim, archive apt,
  shm) are documented above and change no converter behavior.

## Verdict

`FAILED`

- Neither unchanged source nor the fallback question arises (source builds
  and runs; it rejects the data).
- Neither R4 nor STU3 parses completely: R4 throws on CDT (then ICD-10);
  STU3 fails at the R4-only parser.
- Supporting default Synthea output requires an upstream source patch
  (CDT/ICD-10 vocabulary branches) or a parser dependency change (STU3) —
  both explicitly out of scope.

## Next action

Stop FHIR-path development on FhirToCdm; do not patch or fork it. Reopen
converter selection against the same acceptance criteria (must ingest
default Synthea 3.3.0 R4 output including CDT procedures and ICD-10
conditions, or document the exact supported subset before any main-plan
commitment).
