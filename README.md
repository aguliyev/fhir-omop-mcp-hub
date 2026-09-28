# fhir-omop-mcp-hub
Local v1 target: generate matching Synthea CSV and FHIR batches, load the CSV export into OMOP using Athena vocabularies, and query cohorts through WebAPI and a Streamable HTTP MCP server. FHIR is archived but not imported or compared in v1. PostgreSQL/Athena setup is implemented; generation, CSV ETL, WebAPI and MCP are still planned. The FhirToCdm feasibility spike failed; see `spikes/fhir_to_cdm/REPORT.md`.

## Quick start: local setup

Invoke the `setup-fhir-omop-mcp-hub` skill to bootstrap or verify local Docker, PostgreSQL, and the nine-file OHDSI Athena vocabulary prerequisite. The skill pauses for the one manual step — downloading the export from [OHDSI Athena](https://athena.ohdsi.org/) — then resumes. Direct equivalents:

```bash
bin/setup
bin/stage-athena /absolute/path/to/extracted/athena
bin/setup
bin/validate-setup
```

The first `bin/setup` bootstraps PostgreSQL and exits `20` with `ATHENA_REQUIRED` when no vocabulary is staged yet. The second step requires the actual user-provided absolute path to the extracted Athena export; after staging, the second `bin/setup` loads and validates. The completed FhirToCdm spike is documented for future converter selection, not part of the CSV-only v1 startup path.
