# FhirToCdm feasibility spike (disposable, non-production)

Goal: determine whether unmodified upstream OHDSI FhirToCdm
(commit `4991f90`) runs in a reproducible Linux container, consumes
pinned Synthea 3.3.0 FHIR output, uses PostgreSQL Athena vocabularies,
emits loadable OMOP CDM 5.3 files, and preserves relationships across
two generated batches.

All generated state lives under `<data-root>/work/fhir_to_cdm_spike/`
(mounted at `/work` in spike containers). Nothing generated is committed.

## Layout

- `compose.yaml` — spike postgres + converter + synthea services
- `converter/` — wrapper Dockerfile/entrypoint around unmodified upstream
- `synthea/` — pinned Synthea image + generation script
- `db/` — scratch schema init, vocab loader, CDM loader
- `bin/` — `check-prerequisites generate assemble convert load validate run-spike`
- `tests/` — input / file / loaded-CDM checks
- `REPORT.md` — evidence + single verdict

## Quick start

```bash
cp spikes/fhir_to_cdm/.env.example spikes/fhir_to_cdm/.env  # add secret password
spikes/fhir_to_cdm/bin/check-prerequisites
spikes/fhir_to_cdm/bin/run-spike
```

Requires repository-level `bin/validate-setup` to report READY first.
If Athena files are absent the spike is `BLOCKED`, not `FAILED`.
