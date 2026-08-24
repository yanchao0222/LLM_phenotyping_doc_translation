-- Rule 1 (VUMC-specific database name): APPLIED -- All OMOP tables prefixed with victr_sd.sd_omop_prod
-- Rule 4 (Standard code handling): APPLIED -- Measurement LOINC codes handled via JOIN to concept
-- Rule 5 (Free-text LIKE): APPLIED -- Free-text positive serology handled with LIKE
-- Rule 6 (OR -> UNION): APPLIED -- Multi-table person_id selection uses UNION
-- Rule 7 (LEFT JOIN -> UNION): APPLIED -- Multi-table person_id selection uses UNION
-- FIX: Added missing SELECT statements to CTEs (autoimmune_diagnoses, diabetes_status, antiinflammatory_diagnoses)
-- FIX: Corrected DATEDIFF argument order in diagnosis_summary
-- FIX: Added commas between CTEs to ensure proper syntax

CREATE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex3_only_diagram_LLM2_AID AS 

WITH autoimmune_diagnoses AS (
  SELECT DISTINCT person_id, condition_start_date, condition_concept_id
  FROM victr_sd.sd_omop_prod.condition_occurrence
  WHERE condition_concept_id IN (
    81097,81571,433581,73840,4116440,81281,80809,4063581,197494,257628,81893,80182,82960,140168,201826,200762,4134662,201606,4058243,81893,4098292,437264,4218641,432923,434557,374919,4063556,4341687,374925,375806,374919,76685,139803,374945,4334765,192367,141933,133547,136774,45766714,138825,140168,4305080,201820,45766160,320749,44782772,4182929,4112853,313223,4028670
  )
),
diabetes_status AS (
  SELECT person_id,
    MAX(CASE WHEN condition_concept_id = 201826 THEN 1 ELSE 0 END) AS has_t1d,
    MAX(CASE WHEN condition_concept_id IN (201820, 443238, 442793) THEN 1 ELSE 0 END) AS has_t2d
  FROM victr_sd.sd_omop_prod.condition_occurrence
  WHERE condition_concept_id IN (
    201826,201820,443238,442793
  )
  GROUP BY person_id
),
positive_serology AS (
  SELECT DISTINCT m.person_id
  FROM victr_sd.sd_omop_prod.measurement m
  JOIN victr_sd.sd_omop_prod.concept c ON m.measurement_concept_id = c.concept_id
  WHERE c.vocabulary_id = 'LOINC' AND c.concept_code IN (
    '3003694','40764999','3019550','3030692','3007220','3018486','3005757','3037556','37393863','3023230','3004588','40764126','3035637','3030152','3002482','3003885','3032370','3014576','3016914','3019550','3013537','3018171','3016891','3045424','3003396','3011708'
  )
  AND (
    m.value_as_concept_id IN (4126681,4181412,9191)
    OR (m.value_as_number > 0 AND m.unit_concept_id IS NOT NULL)
    OR LOWER(m.value_source_value) LIKE '%positive%' OR LOWER(m.value_source_value) LIKE '%detected%' OR LOWER(m.value_source_value) LIKE '%reactive%' OR LOWER(m.value_source_value) LIKE '%abnormal%'
  )
),
antiinflammatory_diagnoses AS (
  SELECT DISTINCT person_id
  FROM victr_sd.sd_omop_prod.condition_occurrence
  WHERE condition_concept_id IN (
    81097,81571,433581,73840,4116440,81281,80809,4063581,197494,257628,81893,80182,82960,140168,200762,4134662,201606,4058243,81893,4098292,437264,4218641,432923,434557,374919,4063556,4341687,374925,375806,374919,76685,139803,374945,4334765,192367,141933,133547,136774,45766714,138825,140168,4305080,201820,45766160,320749,44782772,4182929,4112853,313223,4028670
  )
),
diagnosis_summary AS (
  SELECT 
    ad.person_id,
    COUNT(DISTINCT ad.condition_start_date) AS distinct_diagnosis_days,
    MIN(ad.condition_start_date) AS first_diagnosis_date,
    MAX(ad.condition_start_date) AS last_diagnosis_date,
    DATEDIFF(MAX(ad.condition_start_date), MIN(ad.condition_start_date)) AS days_between_first_last
  FROM autoimmune_diagnoses ad
  GROUP BY ad.person_id
),
case_evaluation AS (
  SELECT 
    ds.person_id,
    ds.distinct_diagnosis_days,
    ds.days_between_first_last,
    COALESCE(diab.has_t1d, 0) AS has_t1d,
    COALESCE(diab.has_t2d, 0) AS has_t2d,
    CASE WHEN ps.person_id IS NOT NULL THEN 1 ELSE 0 END AS has_positive_serology,
    CASE WHEN ai.person_id IS NOT NULL THEN 1 ELSE 0 END AS has_antiinflammatory
  FROM diagnosis_summary ds
  LEFT JOIN diabetes_status diab ON ds.person_id = diab.person_id
  LEFT JOIN positive_serology ps ON ds.person_id = ps.person_id
  LEFT JOIN antiinflammatory_diagnoses ai ON ds.person_id = ai.person_id
),
final_cases AS (
  SELECT 
    person_id,
    'CASE' AS phenotype_status
  FROM case_evaluation
  WHERE 
    distinct_diagnosis_days >= 3
    AND days_between_first_last >= 7
    AND (
      (has_antiinflammatory = 1)
      OR (has_t1d = 1 AND has_antiinflammatory = 1)
      OR (has_t1d = 1 AND has_positive_serology = 1)
      OR (has_t2d = 1 AND has_positive_serology = 1 AND has_t1d = 0)
    )
),
all_subjects AS (
  SELECT DISTINCT person_id
  FROM victr_sd.sd_omop_prod.person
  WHERE person_id IN (
    SELECT DISTINCT person_id FROM victr_sd.sd_omop_prod.observation
    UNION
    SELECT DISTINCT person_id FROM victr_sd.sd_omop_prod.condition_occurrence
    UNION
    SELECT DISTINCT person_id FROM victr_sd.sd_omop_prod.measurement
    UNION
    SELECT DISTINCT person_id FROM victr_sd.sd_omop_prod.procedure_occurrence
    UNION
    SELECT DISTINCT person_id FROM victr_sd.sd_omop_prod.drug_exposure
  )
),
final_controls AS (
  SELECT 
    s.person_id,
    'CONTROL' AS phenotype_status
  FROM all_subjects s
  WHERE s.person_id NOT IN (
    SELECT person_id FROM autoimmune_diagnoses
  )
  AND s.person_id NOT IN (
    SELECT person_id FROM final_cases
  )
)
SELECT 
  person_id,
  phenotype_status,
  'Autoimmune Disease' AS phenotype_name,
  CURRENT_DATE AS execution_date
FROM final_cases
UNION ALL
SELECT 
  person_id,
  phenotype_status,
  'Autoimmune Disease' AS phenotype_name,
  CURRENT_DATE AS execution_date
FROM final_controls
ORDER BY phenotype_status DESC, person_id;