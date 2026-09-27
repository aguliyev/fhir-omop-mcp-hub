# fhir-omop-mcp-hub
Ingests FHIR clinical data, maps it to OMOP standard concepts via OHDSI Athena vocabularies, and persists it into an OMOP CDM. Exposes the data through MCP tools — natural-language cohort queries via OHDSI WebAPI to start, more planned. Includes synthetic Synthea data and dual CSV/FHIR ingestion paths for demo and comparison.

## Quick start: local setup

Invoke the `setup-fhir-omop-mcp-hub` skill to bootstrap or verify local Docker, PostgreSQL, and the nine-file OHDSI Athena vocabulary prerequisite. The skill pauses for the one manual step — downloading the export from [OHDSI Athena](https://athena.ohdsi.org/) — then resumes. Direct equivalents:

```bash
bin/setup
bin/stage-athena /absolute/path/to/extracted/athena
bin/setup
bin/validate-setup
```

The first `bin/setup` bootstraps PostgreSQL and exits `20` with `ATHENA_REQUIRED` when no vocabulary is staged yet. The second step requires the actual user-provided absolute path to the extracted Athena export; after staging, the second `bin/setup` loads and validates. The FhirToCdm converter spike begins only after `bin/validate-setup` reports `READY`.
