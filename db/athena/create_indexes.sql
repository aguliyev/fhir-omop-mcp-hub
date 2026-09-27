-- OMOP CDM v5.3.1 vocabulary primary keys + lookup indexes, schema-qualified.
-- Source:
--   https://raw.githubusercontent.com/OHDSI/CommonDataModel/v5.3.1/PostgreSQL/OMOP%20CDM%20postgresql%20indexes.txt
-- Local adaptations (see PROVENANCE.md):
--   * every object qualified with athena_vocabs; no search_path dependence.
--   * upstream CLUSTER statements removed (CLUSTER cannot run inside a
--     transaction block; clustering is a performance optimisation only).
--   * upstream typo idx_concept_vocabluary_id kept verbatim to preserve exact
--     upstream semantics.

ALTER TABLE athena_vocabs.concept ADD CONSTRAINT xpk_concept PRIMARY KEY (concept_id);
ALTER TABLE athena_vocabs.vocabulary ADD CONSTRAINT xpk_vocabulary PRIMARY KEY (vocabulary_id);
ALTER TABLE athena_vocabs.domain ADD CONSTRAINT xpk_domain PRIMARY KEY (domain_id);
ALTER TABLE athena_vocabs.concept_class ADD CONSTRAINT xpk_concept_class PRIMARY KEY (concept_class_id);
ALTER TABLE athena_vocabs.concept_relationship ADD CONSTRAINT xpk_concept_relationship PRIMARY KEY (concept_id_1, concept_id_2, relationship_id);
ALTER TABLE athena_vocabs.relationship ADD CONSTRAINT xpk_relationship PRIMARY KEY (relationship_id);
ALTER TABLE athena_vocabs.concept_ancestor ADD CONSTRAINT xpk_concept_ancestor PRIMARY KEY (ancestor_concept_id, descendant_concept_id);
ALTER TABLE athena_vocabs.source_to_concept_map ADD CONSTRAINT xpk_source_to_concept_map PRIMARY KEY (source_vocabulary_id, target_concept_id, source_code, valid_end_date);
ALTER TABLE athena_vocabs.drug_strength ADD CONSTRAINT xpk_drug_strength PRIMARY KEY (drug_concept_id, ingredient_concept_id);

CREATE UNIQUE INDEX idx_concept_concept_id ON athena_vocabs.concept (concept_id ASC);
CREATE INDEX idx_concept_code ON athena_vocabs.concept (concept_code ASC);
CREATE INDEX idx_concept_vocabluary_id ON athena_vocabs.concept (vocabulary_id ASC);
CREATE INDEX idx_concept_domain_id ON athena_vocabs.concept (domain_id ASC);
CREATE INDEX idx_concept_class_id ON athena_vocabs.concept (concept_class_id ASC);

CREATE UNIQUE INDEX idx_vocabulary_vocabulary_id ON athena_vocabs.vocabulary (vocabulary_id ASC);
CREATE UNIQUE INDEX idx_domain_domain_id ON athena_vocabs.domain (domain_id ASC);
CREATE UNIQUE INDEX idx_concept_class_class_id ON athena_vocabs.concept_class (concept_class_id ASC);

CREATE INDEX idx_concept_relationship_id_1 ON athena_vocabs.concept_relationship (concept_id_1 ASC);
CREATE INDEX idx_concept_relationship_id_2 ON athena_vocabs.concept_relationship (concept_id_2 ASC);
CREATE INDEX idx_concept_relationship_id_3 ON athena_vocabs.concept_relationship (relationship_id ASC);

CREATE UNIQUE INDEX idx_relationship_rel_id ON athena_vocabs.relationship (relationship_id ASC);
CREATE INDEX idx_concept_synonym_id ON athena_vocabs.concept_synonym (concept_id ASC);
CREATE INDEX idx_concept_ancestor_id_1 ON athena_vocabs.concept_ancestor (ancestor_concept_id ASC);
CREATE INDEX idx_concept_ancestor_id_2 ON athena_vocabs.concept_ancestor (descendant_concept_id ASC);

CREATE INDEX idx_source_to_concept_map_id_3 ON athena_vocabs.source_to_concept_map (target_concept_id ASC);
CREATE INDEX idx_source_to_concept_map_id_1 ON athena_vocabs.source_to_concept_map (source_vocabulary_id ASC);
CREATE INDEX idx_source_to_concept_map_id_2 ON athena_vocabs.source_to_concept_map (target_vocabulary_id ASC);
CREATE INDEX idx_source_to_concept_map_code ON athena_vocabs.source_to_concept_map (source_code ASC);

CREATE INDEX idx_drug_strength_id_1 ON athena_vocabs.drug_strength (drug_concept_id ASC);
CREATE INDEX idx_drug_strength_id_2 ON athena_vocabs.drug_strength (ingredient_concept_id ASC);
