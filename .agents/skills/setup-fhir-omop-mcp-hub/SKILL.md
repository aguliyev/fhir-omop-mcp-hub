---
name: setup-fhir-omop-mcp-hub
description: Bootstrap or verify this repository's local Docker, PostgreSQL, and OHDSI Athena vocabulary prerequisite before ingestion or FhirToCdm spikes. Use when asked to set up the project, prepare Athena, resume after a vocabulary download, or diagnose setup readiness.
---

# Setup FHIR OMOP MCP Hub

## Overview

Orchestrate repository scripts to bootstrap or verify local Docker, PostgreSQL, and the Athena vocabulary prerequisite. Mechanics live in `bin/`; this skill routes the human handoff and never duplicates script logic.

## Workflow

1. Run `bin/check-prerequisites` before any mutation and fix failures first.
2. Run `bin/setup` rather than duplicating setup logic (it calls `prepare-data`, `start`, `db_init`, load/validate in order).
3. If `bin/setup` exits `20` with `ATHENA_REQUIRED`, follow `references/athena-download.md`: send the user only to https://athena.ohdsi.org/, explain the SNOMED, RxNorm, LOINC, CVX, and UCUM bundle plus Athena-selected dependencies, and pause.
4. Never request credentials, never automate Athena login or license acceptance, and never redistribute vocabulary files.
5. Ask the user for the absolute extracted-directory path of their Athena export. Explain the export holds nine tab-delimited files despite `.csv`: `CONCEPT.csv`, `CONCEPT_ANCESTOR.csv`, `CONCEPT_CLASS.csv`, `CONCEPT_RELATIONSHIP.csv`, `CONCEPT_SYNONYM.csv`, `DOMAIN.csv`, `DRUG_STRENGTH.csv`, `RELATIONSHIP.csv`, `VOCABULARY.csv`. `SOURCE_TO_CONCEPT_MAP.csv` is not required because `source_to_concept_map` is site-maintained and setup creates it empty.
6. Run `bin/stage-athena <absolute-path>` only after the user responds with the path. Never copy the user's original export path into tracked files; use it only as the staging command argument.
7. If `bin/setup` exits `21` with `ATHENA_REPLACE_APPROVAL_REQUIRED`, or staged and live manifests otherwise differ, first show the user the current and staged vocabulary versions, then obtain explicit approval before passing `--replace` to `bin/stage-athena` or `bin/load-vocab`. Never pass `--replace` without that approval.
8. Finish only after `bin/validate-setup` passes against the real Athena export.
9. On `READY`, hand off to the FhirToCdm spike in `docs/superpowers/plans/2026-09-27-fhir-to-cdm-container-feasibility-spike.md`, but do not start the spike in this task.

## Outcomes

- `BLOCKED`: waiting for user download/license, Docker/network permission, or disk.
- `FAILED`: setup accepted invalid input, exposed partial state, or failed validation.
- `READY`: `bin/validate-setup` passed against the real Athena export.
