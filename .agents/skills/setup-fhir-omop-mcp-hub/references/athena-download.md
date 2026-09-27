# Manual Athena Download

Tell the user to perform these steps in their own browser. Never automate Athena login or license acceptance, never request credentials, and never download on their behalf.

1. Open [OHDSI Athena](https://athena.ohdsi.org/) in their own browser.
2. Sign in or create an account and personally accept the required licenses (SNOMED, RxNorm, LOINC, CVX, UCUM each carry license terms).
3. Select the SNOMED, RxNorm, LOINC, CVX, and UCUM vocabularies and retain any dependencies Athena selects automatically.
4. Create the bundle, wait for Athena to prepare it, and download the ZIP from Athena.
5. Extract the ZIP locally without editing or renaming the CSVs.
6. Give the agent only the absolute extracted-directory path, never credentials.

## Expected files

The export contains nine tab-delimited files despite the `.csv` extension:

```text
CONCEPT.csv
CONCEPT_ANCESTOR.csv
CONCEPT_CLASS.csv
CONCEPT_RELATIONSHIP.csv
CONCEPT_SYNONYM.csv
DOMAIN.csv
DRUG_STRENGTH.csv
RELATIONSHIP.csv
VOCABULARY.csv
```

`SOURCE_TO_CONCEPT_MAP.csv` is not expected: `source_to_concept_map` is a site-maintained OMOP table, not part of a standard Athena download, so setup creates it empty.
