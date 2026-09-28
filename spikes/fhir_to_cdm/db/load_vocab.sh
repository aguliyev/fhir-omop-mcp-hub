#!/bin/sh
# Scratch vocabulary load: OMOP 5.3.1 tables + tab-delimited \copy + empty source_to_concept_map.
# Runs inside spike postgres via `docker compose exec -T postgres`. Fails on any rejected row.
set -eu
ATHENA_INPUT_DIR="${ATHENA_INPUT_DIR:-/data/athena_input/current}"
for f in CONCEPT.csv CONCEPT_ANCESTOR.csv CONCEPT_CLASS.csv CONCEPT_RELATIONSHIP.csv CONCEPT_SYNONYM.csv DOMAIN.csv DRUG_STRENGTH.csv RELATIONSHIP.csv VOCABULARY.csv; do
  [ -f "$ATHENA_INPUT_DIR/$f" ] || { echo "ERROR: missing $f" >&2; exit 1; }
done
psql -v ON_ERROR_STOP=1 <<SQL
BEGIN;
DROP SCHEMA IF EXISTS athena_vocabs CASCADE;
CREATE SCHEMA athena_vocabs;
CREATE TABLE athena_vocabs.concept (concept_id INTEGER NOT NULL, concept_name VARCHAR(255) NOT NULL, domain_id VARCHAR(20) NOT NULL, vocabulary_id VARCHAR(20) NOT NULL, concept_class_id VARCHAR(20) NOT NULL, standard_concept VARCHAR(1) NULL, concept_code VARCHAR(50) NOT NULL, valid_start_date DATE NOT NULL, valid_end_date DATE NOT NULL, invalid_reason VARCHAR(1) NULL);
CREATE TABLE athena_vocabs.vocabulary (vocabulary_id VARCHAR(20) NOT NULL, vocabulary_name VARCHAR(255) NOT NULL, vocabulary_reference VARCHAR(255) NOT NULL, vocabulary_version VARCHAR(255) NULL, vocabulary_concept_id INTEGER NOT NULL);
CREATE TABLE athena_vocabs.domain (domain_id VARCHAR(20) NOT NULL, domain_name VARCHAR(255) NOT NULL, domain_concept_id INTEGER NOT NULL);
CREATE TABLE athena_vocabs.concept_class (concept_class_id VARCHAR(20) NOT NULL, concept_class_name VARCHAR(255) NOT NULL, concept_class_concept_id INTEGER NOT NULL);
CREATE TABLE athena_vocabs.concept_relationship (concept_id_1 INTEGER NOT NULL, concept_id_2 INTEGER NOT NULL, relationship_id VARCHAR(20) NOT NULL, valid_start_date DATE NOT NULL, valid_end_date DATE NOT NULL, invalid_reason VARCHAR(1) NULL);
CREATE TABLE athena_vocabs.relationship (relationship_id VARCHAR(20) NOT NULL, relationship_name VARCHAR(255) NOT NULL, is_hierarchical VARCHAR(1) NOT NULL, defines_ancestry VARCHAR(1) NOT NULL, reverse_relationship_id VARCHAR(20) NOT NULL, relationship_concept_id INTEGER NOT NULL);
CREATE TABLE athena_vocabs.concept_synonym (concept_id INTEGER NOT NULL, concept_synonym_name VARCHAR(1000) NOT NULL, language_concept_id INTEGER NOT NULL);
CREATE TABLE athena_vocabs.concept_ancestor (ancestor_concept_id INTEGER NOT NULL, descendant_concept_id INTEGER NOT NULL, min_levels_of_separation INTEGER NOT NULL, max_levels_of_separation INTEGER NOT NULL);
CREATE TABLE athena_vocabs.source_to_concept_map (source_code VARCHAR(50) NOT NULL, source_concept_id INTEGER NOT NULL, source_vocabulary_id VARCHAR(20) NOT NULL, source_code_description VARCHAR(255) NULL, target_concept_id INTEGER NOT NULL, target_vocabulary_id VARCHAR(20) NOT NULL, valid_start_date DATE NOT NULL, valid_end_date DATE NOT NULL, invalid_reason VARCHAR(1) NULL);
CREATE TABLE athena_vocabs.drug_strength (drug_concept_id INTEGER NOT NULL, ingredient_concept_id INTEGER NOT NULL, amount_value NUMERIC NULL, amount_unit_concept_id INTEGER NULL, numerator_value NUMERIC NULL, numerator_unit_concept_id INTEGER NULL, denominator_value NUMERIC NULL, denominator_unit_concept_id INTEGER NULL, box_size INTEGER NULL, valid_start_date DATE NOT NULL, valid_end_date DATE NOT NULL, invalid_reason VARCHAR(1) NULL);
\copy athena_vocabs.drug_strength FROM '$ATHENA_INPUT_DIR/DRUG_STRENGTH.csv' WITH (FORMAT csv, HEADER true, DELIMITER E'\t', QUOTE E'\b')
\copy athena_vocabs.concept FROM '$ATHENA_INPUT_DIR/CONCEPT.csv' WITH (FORMAT csv, HEADER true, DELIMITER E'\t', QUOTE E'\b')
\copy athena_vocabs.concept_relationship FROM '$ATHENA_INPUT_DIR/CONCEPT_RELATIONSHIP.csv' WITH (FORMAT csv, HEADER true, DELIMITER E'\t', QUOTE E'\b')
\copy athena_vocabs.concept_ancestor FROM '$ATHENA_INPUT_DIR/CONCEPT_ANCESTOR.csv' WITH (FORMAT csv, HEADER true, DELIMITER E'\t', QUOTE E'\b')
\copy athena_vocabs.concept_synonym FROM '$ATHENA_INPUT_DIR/CONCEPT_SYNONYM.csv' WITH (FORMAT csv, HEADER true, DELIMITER E'\t', QUOTE E'\b')
\copy athena_vocabs.vocabulary FROM '$ATHENA_INPUT_DIR/VOCABULARY.csv' WITH (FORMAT csv, HEADER true, DELIMITER E'\t', QUOTE E'\b')
\copy athena_vocabs.relationship FROM '$ATHENA_INPUT_DIR/RELATIONSHIP.csv' WITH (FORMAT csv, HEADER true, DELIMITER E'\t', QUOTE E'\b')
\copy athena_vocabs.concept_class FROM '$ATHENA_INPUT_DIR/CONCEPT_CLASS.csv' WITH (FORMAT csv, HEADER true, DELIMITER E'\t', QUOTE E'\b')
\copy athena_vocabs.domain FROM '$ATHENA_INPUT_DIR/DOMAIN.csv' WITH (FORMAT csv, HEADER true, DELIMITER E'\t', QUOTE E'\b')
COMMIT;
SQL
echo "vocab load: OK"
