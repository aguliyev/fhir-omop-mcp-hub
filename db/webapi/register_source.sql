-- WebAPI v2.15.2 source registration for the single v1 source `omop_csv`.
-- Derived from the release migrations (see docker/webapi/PROVENANCE.md):
--   * ohdsi_webapi.source has UNIQUE (source_key); upsert by that constraint.
--   * ohdsi_webapi.source_daimon.daimon_type is the ORDINAL of
--     SourceDaimon.DaimonType { CDM=0, Vocabulary=1, Results=2, Temp=5 }.
--   * Credentials travel in the JDBC URL (parsed first by DataSourceDTOParser);
--     username/password columns stay NULL (they are Hibernate-encrypted).
-- Requires psql variable: -v source_password=<postgres password> (from
-- /run/secrets/postgres_password via db/webapi/register.sh; never tracked).
-- Run ONLY after WebAPI has migrated its metadata (webapi_register job),
-- never from db_init. Re-runnable: same source row, exactly four daimons.
-- v1 registers omop_csv ONLY; omop_fhir stays unregistered.

-- psql parses :'var' only inside the script; fail fast if unset.
\if :{?source_password}
\else
\echo 'FAIL: missing -v source_password'
\q 1
\endif

BEGIN;

WITH upsert AS (
  INSERT INTO ohdsi_webapi.source (source_name, source_key, source_connection, source_dialect)
  VALUES (
    'SYNTHETIC OMOP CSV',
    'omop_csv',
    'jdbc:postgresql://postgres:5432/fhir_omop_mcp_hub?user=postgres&password=' || :'source_password',
    'postgresql'
  )
  ON CONFLICT (source_key) DO UPDATE SET
    source_name = EXCLUDED.source_name,
    source_connection = EXCLUDED.source_connection,
    source_dialect = EXCLUDED.source_dialect
  RETURNING source_id
),
del AS (
  DELETE FROM ohdsi_webapi.source_daimon
  USING upsert
  WHERE source_daimon.source_id = upsert.source_id
  RETURNING source_daimon.source_id
)
INSERT INTO ohdsi_webapi.source_daimon (source_id, daimon_type, table_qualifier, priority)
SELECT upsert.source_id, d.daimon_type, d.table_qualifier, 0
FROM upsert
CROSS JOIN (VALUES
  (0, 'omop_csv'),
  (1, 'athena_vocabs'),
  (2, 'omop_csv_results'),
  (5, 'omop_csv_temp')
) AS d(daimon_type, table_qualifier);

-- Guard: exactly one source row and four daimons, correctly qualified.
DO $$
DECLARE
  sid integer;
  n_daimon integer;
BEGIN
  SELECT source_id INTO sid FROM ohdsi_webapi.source WHERE source_key = 'omop_csv';
  IF sid IS NULL THEN RAISE EXCEPTION 'omop_csv source missing after upsert'; END IF;
  SELECT count(*) INTO n_daimon FROM ohdsi_webapi.source_daimon WHERE source_id = sid;
  IF n_daimon <> 4 THEN RAISE EXCEPTION 'expected 4 daimons for omop_csv, found %', n_daimon; END IF;
  IF EXISTS (
    SELECT 1 FROM ohdsi_webapi.source_daimon
    WHERE source_id = sid
      AND (daimon_type, table_qualifier)::text NOT IN (
        '(0,omop_csv)', '(1,athena_vocabs)', '(2,omop_csv_results)', '(5,omop_csv_temp)')
  ) THEN RAISE EXCEPTION 'omop_csv daimon mapping mismatch'; END IF;
END
$$;

COMMIT;
