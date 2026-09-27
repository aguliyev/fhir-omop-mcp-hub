-- Read-only compatibility views into athena_vocabs.
-- Only ever created in the allow-listed schema omop_csv (enforced by load.sh
-- which rejects any VOCAB_VIEW_TARGET_SCHEMAS value except the exact string
-- "omop_csv"). Never created in omop_fhir. Ten relations per docs/intro.md.

CREATE OR REPLACE VIEW omop_csv.concept AS SELECT * FROM athena_vocabs.concept;
CREATE OR REPLACE VIEW omop_csv.concept_ancestor AS SELECT * FROM athena_vocabs.concept_ancestor;
CREATE OR REPLACE VIEW omop_csv.concept_class AS SELECT * FROM athena_vocabs.concept_class;
CREATE OR REPLACE VIEW omop_csv.concept_relationship AS SELECT * FROM athena_vocabs.concept_relationship;
CREATE OR REPLACE VIEW omop_csv.concept_synonym AS SELECT * FROM athena_vocabs.concept_synonym;
CREATE OR REPLACE VIEW omop_csv.domain AS SELECT * FROM athena_vocabs.domain;
CREATE OR REPLACE VIEW omop_csv.drug_strength AS SELECT * FROM athena_vocabs.drug_strength;
CREATE OR REPLACE VIEW omop_csv.relationship AS SELECT * FROM athena_vocabs.relationship;
CREATE OR REPLACE VIEW omop_csv.source_to_concept_map AS SELECT * FROM athena_vocabs.source_to_concept_map;
CREATE OR REPLACE VIEW omop_csv.vocabulary AS SELECT * FROM athena_vocabs.vocabulary;
