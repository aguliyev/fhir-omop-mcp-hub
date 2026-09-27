-- Athena vocabulary validation. Read-only: raises EXCEPTION on any failure.
-- Run with: psql -v ON_ERROR_STOP=1 -f validate.sql
-- Optional: `SET athena.staged_checksum = '...'` before invoking (load.sh and
-- bin/validate-vocab do this from the staged manifest) so the success report
-- includes the staged aggregate checksum. Without it the column is NULL.
-- load.sh runs this file inside the load transaction; bin/validate-vocab runs
-- it standalone against the committed schema.

\set QUIET on
\pset footer off

-- 1. All ten physical tables exist in athena_vocabs.
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'concept','concept_ancestor','concept_class','concept_relationship',
    'concept_synonym','domain','drug_strength','relationship',
    'source_to_concept_map','vocabulary']
  LOOP
    IF to_regclass('athena_vocabs.' || t) IS NULL THEN
      RAISE EXCEPTION 'validate-vocab: missing table athena_vocabs.%', t;
    END IF;
  END LOOP;
END $$;

-- 2. Nine Athena-backed tables are nonempty.
DO $$
DECLARE
  t text; n bigint;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'concept','concept_ancestor','concept_class','concept_relationship',
    'concept_synonym','domain','drug_strength','relationship','vocabulary']
  LOOP
    EXECUTE format('SELECT count(*) FROM athena_vocabs.%I', t) INTO n;
    IF n < 1 THEN
      RAISE EXCEPTION 'validate-vocab: athena_vocabs.% is empty', t;
    END IF;
  END LOOP;
END $$;

-- 3. source_to_concept_map exists empty (site-maintained, not in Athena export).
DO $$
DECLARE n bigint;
BEGIN
  SELECT count(*) INTO n FROM athena_vocabs.source_to_concept_map;
  IF n <> 0 THEN
    RAISE EXCEPTION 'validate-vocab: athena_vocabs.source_to_concept_map must be empty, found % rows', n;
  END IF;
END $$;

-- 4. vocabulary contains all five required vocabulary IDs.
DO $$
DECLARE
  v text;
BEGIN
  FOREACH v IN ARRAY ARRAY['CVX','LOINC','RxNorm','SNOMED','UCUM']
  LOOP
    IF NOT EXISTS (SELECT 1 FROM athena_vocabs.vocabulary WHERE vocabulary_id = v) THEN
      RAISE EXCEPTION 'validate-vocab: vocabulary_id % missing from athena_vocabs.vocabulary', v;
    END IF;
  END LOOP;
END $$;

-- 5. concept has at least one valid standard concept per required vocabulary.
DO $$
DECLARE
  v text;
BEGIN
  FOREACH v IN ARRAY ARRAY['CVX','LOINC','RxNorm','SNOMED','UCUM']
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM athena_vocabs.concept
      WHERE vocabulary_id = v
        AND standard_concept = 'S'
        AND invalid_reason IS NULL
    ) THEN
      RAISE EXCEPTION 'validate-vocab: no valid standard concept for vocabulary %', v;
    END IF;
  END LOOP;
END $$;

-- 6. Official primary keys exist on the athena_vocabs tables
-- (schema-scoped: a same-named constraint elsewhere must not satisfy this).
DO $$
DECLARE
  cname text;
BEGIN
  FOREACH cname IN ARRAY ARRAY[
    'xpk_concept','xpk_vocabulary','xpk_domain','xpk_concept_class',
    'xpk_concept_relationship','xpk_relationship','xpk_concept_ancestor',
    'xpk_source_to_concept_map','xpk_drug_strength']
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint con
        JOIN pg_class cls ON cls.oid = con.conrelid
        JOIN pg_namespace nsp ON nsp.oid = cls.relnamespace
        WHERE con.conname = cname AND con.contype = 'p'
          AND nsp.nspname = 'athena_vocabs'
    ) THEN
      RAISE EXCEPTION 'validate-vocab: missing primary key constraint athena_vocabs.%', cname;
    END IF;
  END LOOP;
END $$;

-- 7. Lookup indexes exist in athena_vocabs (upstream names, see
-- PROVENANCE.md for vocabluary typo; schema-scoped like the PK check).
DO $$
DECLARE
  iname text;
BEGIN
  FOREACH iname IN ARRAY ARRAY[
    'idx_concept_concept_id','idx_concept_code','idx_concept_vocabluary_id',
    'idx_concept_domain_id','idx_concept_class_id',
    'idx_vocabulary_vocabulary_id','idx_domain_domain_id',
    'idx_concept_class_class_id','idx_concept_relationship_id_1',
    'idx_concept_relationship_id_2','idx_concept_relationship_id_3',
    'idx_relationship_rel_id','idx_concept_synonym_id',
    'idx_concept_ancestor_id_1','idx_concept_ancestor_id_2',
    'idx_source_to_concept_map_id_3','idx_source_to_concept_map_id_1',
    'idx_source_to_concept_map_id_2','idx_source_to_concept_map_code',
    'idx_drug_strength_id_1','idx_drug_strength_id_2']
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_class cls
        JOIN pg_namespace nsp ON nsp.oid = cls.relnamespace
        WHERE cls.relname = iname AND cls.relkind = 'i'
          AND nsp.nspname = 'athena_vocabs'
    ) THEN
      RAISE EXCEPTION 'validate-vocab: missing index athena_vocabs.%', iname;
    END IF;
  END LOOP;
END $$;

-- 8. vocab_reader can SELECT but cannot write or CREATE.
DO $$
DECLARE
  t text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vocab_reader') THEN
    RAISE EXCEPTION 'validate-vocab: role vocab_reader does not exist';
  END IF;
  IF NOT has_schema_privilege('vocab_reader', 'athena_vocabs', 'USAGE') THEN
    RAISE EXCEPTION 'validate-vocab: vocab_reader lacks USAGE on schema athena_vocabs';
  END IF;
  FOREACH t IN ARRAY ARRAY[
    'concept','concept_ancestor','concept_class','concept_relationship',
    'concept_synonym','domain','drug_strength','relationship',
    'source_to_concept_map','vocabulary']
  LOOP
    IF NOT has_table_privilege('vocab_reader', 'athena_vocabs.' || t, 'SELECT') THEN
      RAISE EXCEPTION 'validate-vocab: vocab_reader lacks SELECT on athena_vocabs.%', t;
    END IF;
    IF has_table_privilege('vocab_reader', 'athena_vocabs.' || t, 'INSERT')
      OR has_table_privilege('vocab_reader', 'athena_vocabs.' || t, 'UPDATE')
      OR has_table_privilege('vocab_reader', 'athena_vocabs.' || t, 'DELETE')
      OR has_table_privilege('vocab_reader', 'athena_vocabs.' || t, 'TRUNCATE') THEN
      RAISE EXCEPTION 'validate-vocab: vocab_reader must be read-only on athena_vocabs.%', t;
    END IF;
  END LOOP;
  IF has_schema_privilege('vocab_reader', 'athena_vocabs', 'CREATE') THEN
    RAISE EXCEPTION 'validate-vocab: vocab_reader must not have CREATE on schema athena_vocabs';
  END IF;
END $$;

-- 9. omop_csv has views for all ten relations, readable by vocab_reader.
DO $$
DECLARE
  t text; k char;
BEGIN
  IF NOT has_schema_privilege('vocab_reader', 'omop_csv', 'USAGE') THEN
    RAISE EXCEPTION 'validate-vocab: vocab_reader lacks USAGE on schema omop_csv';
  END IF;
  FOREACH t IN ARRAY ARRAY[
    'concept','concept_ancestor','concept_class','concept_relationship',
    'concept_synonym','domain','drug_strength','relationship',
    'source_to_concept_map','vocabulary']
  LOOP
    SELECT relkind INTO k FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'omop_csv' AND c.relname = t;
    IF k IS NULL THEN
      RAISE EXCEPTION 'validate-vocab: missing omop_csv.%', t;
    ELSIF k <> 'v' THEN
      RAISE EXCEPTION 'validate-vocab: omop_csv.% is not a view (relkind=%)', t, k;
    END IF;
    IF NOT has_table_privilege('vocab_reader', 'omop_csv.' || t, 'SELECT') THEN
      RAISE EXCEPTION 'validate-vocab: vocab_reader lacks SELECT on omop_csv.%', t;
    END IF;
  END LOOP;
END $$;

-- 10. omop_fhir has no same-named relation (table, view, or materialized view).
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'concept','concept_ancestor','concept_class','concept_relationship',
    'concept_synonym','domain','drug_strength','relationship',
    'source_to_concept_map','vocabulary']
  LOOP
    IF to_regclass('omop_fhir.' || t) IS NOT NULL THEN
      RAISE EXCEPTION 'validate-vocab: omop_fhir.% must not exist', t;
    END IF;
  END LOOP;
END $$;

-- Success report: vocabulary versions, row counts, staged checksum, time.
SELECT vocabulary_id, vocabulary_version
  FROM athena_vocabs.vocabulary ORDER BY 1;

SELECT rel, cnt FROM (
  SELECT 'concept' AS rel, count(*) AS cnt FROM athena_vocabs.concept UNION ALL
  SELECT 'concept_ancestor', count(*) FROM athena_vocabs.concept_ancestor UNION ALL
  SELECT 'concept_class', count(*) FROM athena_vocabs.concept_class UNION ALL
  SELECT 'concept_relationship', count(*) FROM athena_vocabs.concept_relationship UNION ALL
  SELECT 'concept_synonym', count(*) FROM athena_vocabs.concept_synonym UNION ALL
  SELECT 'domain', count(*) FROM athena_vocabs.domain UNION ALL
  SELECT 'drug_strength', count(*) FROM athena_vocabs.drug_strength UNION ALL
  SELECT 'relationship', count(*) FROM athena_vocabs.relationship UNION ALL
  SELECT 'source_to_concept_map', count(*) FROM athena_vocabs.source_to_concept_map UNION ALL
  SELECT 'vocabulary', count(*) FROM athena_vocabs.vocabulary
) s ORDER BY 1;

SELECT current_setting('athena.staged_checksum', true) AS staged_aggregate_checksum,
       now() AS validation_time;
