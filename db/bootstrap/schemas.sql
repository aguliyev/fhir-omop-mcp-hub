-- Fixed schema surface (Task 2). Idempotent; no secrets here.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'vocab_reader') THEN
    CREATE ROLE vocab_reader WITH NOLOGIN;
  END IF;
END
$$;

CREATE SCHEMA IF NOT EXISTS athena_vocabs;
CREATE SCHEMA IF NOT EXISTS omop_csv;
CREATE SCHEMA IF NOT EXISTS omop_csv_results;
CREATE SCHEMA IF NOT EXISTS omop_csv_temp;
CREATE SCHEMA IF NOT EXISTS omop_fhir;
CREATE SCHEMA IF NOT EXISTS omop_fhir_results;
CREATE SCHEMA IF NOT EXISTS omop_fhir_temp;
CREATE SCHEMA IF NOT EXISTS ohdsi_webapi;

REVOKE ALL ON SCHEMA athena_vocabs FROM PUBLIC;
GRANT USAGE ON SCHEMA athena_vocabs TO vocab_reader;
