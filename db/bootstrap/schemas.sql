-- Fixed schema surface (Task 2). Idempotent; no secrets here.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'vocab_reader') THEN
    CREATE ROLE vocab_reader WITH NOLOGIN;
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'etl_loader') THEN
    CREATE ROLE etl_loader WITH LOGIN;
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

-- Dedicated ETL writer (CSV refresh plan): may write omop_csv clinical
-- tables and the omop_csv_temp staging schema, and read vocabulary views.
-- Never granted anything on athena_vocabs tables (denied by default); the
-- password is set by run.sh from /run/secrets/etl_password, never here.
GRANT USAGE ON SCHEMA omop_csv TO etl_loader;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON ALL TABLES IN SCHEMA omop_csv TO etl_loader;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres, etl_loader IN SCHEMA omop_csv
  GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLES TO etl_loader;
-- The blanket grant above also covers the ten vocabulary views (auto-updatable
-- SELECT * views would forward writes into athena_vocabs): strip everything
-- but SELECT. CREATE OR REPLACE VIEW preserves these grants across reloads.
REVOKE ALL ON TABLE
  omop_csv.concept, omop_csv.concept_ancestor, omop_csv.concept_class,
  omop_csv.concept_relationship, omop_csv.concept_synonym, omop_csv.domain,
  omop_csv.drug_strength, omop_csv.relationship,
  omop_csv.source_to_concept_map, omop_csv.vocabulary FROM etl_loader;
GRANT SELECT ON TABLE
  omop_csv.concept, omop_csv.concept_ancestor, omop_csv.concept_class,
  omop_csv.concept_relationship, omop_csv.concept_synonym, omop_csv.domain,
  omop_csv.drug_strength, omop_csv.relationship,
  omop_csv.source_to_concept_map, omop_csv.vocabulary TO etl_loader;
GRANT USAGE, CREATE ON SCHEMA omop_csv_temp TO etl_loader;
GRANT ALL ON ALL TABLES IN SCHEMA omop_csv_temp TO etl_loader;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres, etl_loader IN SCHEMA omop_csv_temp
  GRANT ALL ON TABLES TO etl_loader;
