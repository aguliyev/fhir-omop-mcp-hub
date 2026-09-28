-- Truncate physical clinical/helper tables; vocabulary views untouched.
-- Covers every table in db/omop_csv/clinical_tables.sql. ETL-Synthea runtime
-- helpers (source_to_standard_vocab_map, source_to_source_vocab_map,
-- states_map, ip/er/op/all_visits, assign_all_visit_ids, final_visit_ids)
-- are dropped/recreated by the ETL itself and only ever exist as a group
-- after a successful load, so each is truncated only when present: a failed
-- run can leave a subset behind, and an all-or-nothing guard would still
-- fail on the missing ones.
TRUNCATE
  omop_csv.attribute_definition, omop_csv.care_site, omop_csv.cdm_source,
  omop_csv.cohort, omop_csv.cohort_attribute, omop_csv.cohort_definition,
  omop_csv.condition_era, omop_csv.condition_occurrence, omop_csv.cost,
  omop_csv.death, omop_csv.device_exposure, omop_csv.dose_era,
  omop_csv.drug_era, omop_csv.drug_exposure, omop_csv.fact_relationship,
  omop_csv.location, omop_csv.measurement, omop_csv.metadata, omop_csv.note,
  omop_csv.note_nlp, omop_csv.observation, omop_csv.observation_period,
  omop_csv.payer_plan_period, omop_csv.person, omop_csv.procedure_occurrence,
  omop_csv.provider, omop_csv.specimen, omop_csv.visit_detail,
  omop_csv.visit_occurrence
  RESTART IDENTITY CASCADE;
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'omop_csv.states_map', 'omop_csv.source_to_standard_vocab_map',
    'omop_csv.source_to_source_vocab_map', 'omop_csv.ip_visits',
    'omop_csv.er_visits', 'omop_csv.op_visits', 'omop_csv.all_visits',
    'omop_csv.assign_all_visit_ids', 'omop_csv.final_visit_ids'
  ] LOOP
    IF to_regclass(t) IS NOT NULL THEN
      EXECUTE format('TRUNCATE %s', t);
    END IF;
  END LOOP;
END
$$;
