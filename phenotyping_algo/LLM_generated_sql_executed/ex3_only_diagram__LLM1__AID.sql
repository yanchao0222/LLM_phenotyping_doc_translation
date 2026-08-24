-- Rule 1 (VUMC-specific database name): APPLIED
-- Rule 3 (search for concepts in clinical tables, not concept): APPLIED
-- Rule 4 (measurements: join concept, filter by LOINC): APPLIED
-- Rule 5 (free-text: use LOWER LIKE): APPLIED
-- Rule 6 (OR -> UNION): APPLIED
-- Rules 2, 7, 8, 9: NOT APPLICABLE

CREATE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex3_only_diagram_LLM1_AID AS 

WITH
/*----------------------------------------------------------------------
  1.  Condition ICD code set (autoimmune diseases)
----------------------------------------------------------------------*/
autoimmune_condition_icd AS (
  -- REVISED (was: SELECT concept_id FROM concept WHERE standard_concept = 'S' AND domain_id = 'Condition' AND LOWER(concept_name) IN (...))
  SELECT DISTINCT condition_source_value AS icd_code
  FROM victr_sd.sd_omop_prod.condition_occurrence
  WHERE LOWER(condition_source_value) IN (
    'm45', 'm08', 'l40.5', 'm02', 'm06', 'm35.2', 'm33.2', 'm33.1', 'm35.1', 'm94.1', 'm35.0', 'm32', 'm34', 'e27.1', 'e05', 'e06.3', 'e10', 'e23.0', 'e28.3', 'k29.4', 'k90.0', 'k50', 'd51.0', 'k74.3', 'k83.0', 'k51', 'd59.1', 'd69.5', 'd69.3', 'd59.5', 'd68.6', 'g70.0', 'g73.1', 'g04.8', 'g61.0', 'g35', 'g36.0', 'g37.3', 'g61.8', 'l63', 'l12.0', 'l13.0', 'l10', 'l40', 'l80', 'm31.6', 'm31.3', 'm31.7', 'm30.0', 'm31.4'
  )
),

/*----------------------------------------------------------------------
  2.  Measurement LOINC code set (autoantibody labs)
----------------------------------------------------------------------*/
autoantibody_loinc AS (
  -- REVISED (was: SELECT concept_id FROM concept WHERE standard_concept = 'S' AND domain_id = 'Measurement' AND (LOWER(concept_name) LIKE ...))
  SELECT DISTINCT c.concept_code AS loinc_code
  FROM victr_sd.sd_omop_prod.measurement m
  JOIN victr_sd.sd_omop_prod.concept c ON m.measurement_concept_id = c.concept_id
  WHERE c.vocabulary_id = 'LOINC'
    AND (
      LOWER(c.concept_name) LIKE 'antinuclear antibody%'
      OR LOWER(c.concept_name) LIKE '%neutrophil cytoplasmic antibody%'
      OR LOWER(c.concept_name) LIKE 'double stranded dna antibody%'
      OR LOWER(c.concept_name) LIKE 'cyclic citrullinated peptide antibody%'
      OR LOWER(c.concept_name) LIKE 'rheumatoid factor%'
      OR LOWER(c.concept_name) LIKE '%beta%2%glycoprotein i antibody%'
      OR LOWER(c.concept_name) LIKE 'rna polymerase iii antibody%'
      OR LOWER(c.concept_name) LIKE 'cardiolipin igg antibody%'
      OR LOWER(c.concept_name) LIKE 'cardiolipin igm antibody%'
      OR LOWER(c.concept_name) LIKE 'centromere antibody%'
      OR LOWER(c.concept_name) LIKE 'extractable nuclear antigen jo-1 antibody%'
      OR LOWER(c.concept_name) LIKE 'extractable nuclear antigen u1rnp antibody%'
      OR LOWER(c.concept_name) LIKE 'extractable nuclear antigen scl-70 antibody%'
      OR LOWER(c.concept_name) LIKE 'extractable nuclear antigen sm antibody%'
      OR LOWER(c.concept_name) LIKE 'extractable nuclear antigen ss-a antibody%'
      OR LOWER(c.concept_name) LIKE 'extractable nuclear antigen ss-b antibody%'
    )
),

/*----------------------------------------------------------------------
  3.  Evidence records
----------------------------------------------------------------------*/
autoimmune_dx AS (
  -- REVISED (was: SELECT person_id, condition_start_date AS event_date FROM condition_occurrence WHERE condition_concept_id IN (SELECT concept_id FROM autoimmune_condition_concepts))
  SELECT person_id, condition_start_date AS event_date
  FROM victr_sd.sd_omop_prod.condition_occurrence
  WHERE LOWER(condition_source_value) IN (SELECT icd_code FROM autoimmune_condition_icd)
),

autoantibody_lab AS (
  -- REVISED (was: SELECT person_id, measurement_date AS event_date FROM measurement WHERE measurement_concept_id IN (SELECT concept_id FROM autoantibody_measurement_concepts))
  SELECT m.person_id, m.measurement_date AS event_date
  FROM victr_sd.sd_omop_prod.measurement m
  JOIN victr_sd.sd_omop_prod.concept c ON m.measurement_concept_id = c.concept_id
  WHERE c.vocabulary_id = 'LOINC'
    AND c.concept_code IN (SELECT loinc_code FROM autoantibody_loinc)
),

/*----------------------------------------------------------------------
  4.  Case cohort
----------------------------------------------------------------------*/
autoimmune_cases AS (
  SELECT DISTINCT person_id, MIN(event_date) AS index_date
  FROM (
    SELECT * FROM autoimmune_dx
    UNION ALL
    SELECT * FROM autoantibody_lab
  ) AS evidence
  GROUP BY person_id
)

/*----------------------------------------------------------------------
  5.  Output: CASES only
----------------------------------------------------------------------*/
SELECT *
FROM autoimmune_cases
ORDER BY person_id;