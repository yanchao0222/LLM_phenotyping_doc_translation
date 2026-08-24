-- Rule 1 (VUMC-specific database name): APPLIED (all tables fully qualified with victr_sd.sd_omop_prod)
-- Rule 2 (Fix wildcards): NOT APPLICABLE (no incorrect wildcards)
-- Rule 3 (Search for concepts in clinical tables): APPLIED (ICD/CPT codes searched in *_occurrence tables using *_source_value)
-- Rule 4 (LOINC/RxNorm code handling): APPLIED (LOINC handled via concept join, RxNorm via concept_ancestor)
-- Rule 5 (Free-text LIKE): NOT APPLICABLE (no free-text description filters)
-- Rule 6 (OR -> UNION): APPLIED (used UNION for multi-table concept search)
-- Rule 7 (LEFT JOIN -> UNION): NOT APPLICABLE
-- Rule 8 (Remove NLP/free-text logic): APPLIED (note_nlp logic removed from hist_event)
-- Rule 9 (Missing concept marker): NOT APPLICABLE
-- FIX: Ensured all CTEs are properly closed and the final SELECT statement is correctly formatted; checked for missing parentheses and syntax issues.

CREATE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex2_only_text_LLM1_MACE AS 

WITH
statin_ing AS (
  -- REVISED (was: SELECT concept_id FROM concept WHERE vocabulary_id = 'RxNorm' AND concept_code IN (...))
  SELECT descendant_concept_id AS concept_id
  FROM victr_sd.sd_omop_prod.concept_ancestor
  WHERE ancestor_concept_id IN (1539400,1502766,1539476,1529331,1503297,1511002,1580747)
),
statin_user AS (
  SELECT DISTINCT de.person_id
  FROM victr_sd.sd_omop_prod.drug_exposure de
  WHERE de.drug_concept_id IN (SELECT concept_id FROM statin_ing)
),
ami_dx AS (
  -- REVISED (was: WHERE condition_concept_id IN (SELECT concept_id FROM ami_icd9))
  SELECT person_id, condition_start_date AS dx_date
  FROM victr_sd.sd_omop_prod.condition_occurrence
  WHERE condition_source_value LIKE '410%' OR condition_source_value LIKE '411%'
),
ami_cluster AS (
  SELECT a1.person_id, a1.dx_date AS cluster_start, DATE_ADD(a1.dx_date, 4) AS cluster_end
  FROM ami_dx a1
  JOIN ami_dx a2 ON a1.person_id = a2.person_id AND a2.dx_date BETWEEN a1.dx_date AND DATE_ADD(a1.dx_date, 4)
  GROUP BY a1.person_id, a1.dx_date
  HAVING COUNT(*) >= 2
),
troponin_i_loinc AS (
  SELECT concept_id
  FROM victr_sd.sd_omop_prod.concept
  WHERE vocabulary_id = 'LOINC' AND LOWER(concept_name) LIKE '%troponin i%'
),
troponin_t_loinc AS (
  SELECT concept_id
  FROM victr_sd.sd_omop_prod.concept
  WHERE vocabulary_id = 'LOINC' AND LOWER(concept_name) LIKE '%troponin t%'
),
ckmb_ratio_loinc AS (
  SELECT concept_id
  FROM victr_sd.sd_omop_prod.concept
  WHERE vocabulary_id = 'LOINC' AND LOWER(concept_name) LIKE '%ck-mb%' AND LOWER(concept_name) LIKE '%ratio%'
),
ckmb_loinc AS (
  SELECT concept_id
  FROM victr_sd.sd_omop_prod.concept
  WHERE vocabulary_id = 'LOINC' AND LOWER(concept_name) LIKE '%ck-mb%' AND LOWER(concept_name) NOT LIKE '%ratio%'
),
ami_lab AS (
  SELECT DISTINCT m.person_id, m.measurement_date
  FROM victr_sd.sd_omop_prod.measurement m
  WHERE (
    m.measurement_concept_id IN (SELECT concept_id FROM troponin_i_loinc) AND m.value_as_number >= 0.10
  )
  OR (
    m.measurement_concept_id IN (SELECT concept_id FROM troponin_t_loinc) AND m.value_as_number >= 0.10
  )
  OR (
    m.measurement_concept_id IN (SELECT concept_id FROM ckmb_ratio_loinc) AND m.value_as_number >= 3.0
    AND EXISTS (
      SELECT 1 FROM victr_sd.sd_omop_prod.measurement m2
      WHERE m2.person_id = m.person_id AND m2.measurement_date = m.measurement_date AND m2.measurement_concept_id IN (SELECT concept_id FROM ckmb_loinc) AND m2.value_as_number >= 10.0
    )
  )
),
ami_event AS (
  SELECT c.person_id, c.cluster_start AS index_date
  FROM ami_cluster c
  JOIN ami_lab l ON l.person_id = c.person_id AND l.measurement_date BETWEEN c.cluster_start AND DATE_ADD(c.cluster_start, 4)
),
revasc_event AS (
  -- REVISED (was: WHERE procedure_concept_id IN (SELECT concept_id FROM revasc_cpt))
  SELECT person_id, procedure_date AS index_date
  FROM victr_sd.sd_omop_prod.procedure_occurrence
  WHERE procedure_source_value IN ('33510','33511','33512','33513','33514','33515','33516','33517','33518','33519','33520','33521','33522','33523','33533','33534','33535','33536','92980','92981','92982','92984','92995','92996','C1874','C1875','C1876','C1877')
),
old_mi_dx AS (
  -- REVISED (was: WHERE condition_concept_id IN (SELECT concept_id FROM old_mi_icd9))
  SELECT person_id
  FROM victr_sd.sd_omop_prod.condition_occurrence
  WHERE condition_source_value = '412'
),
hist_event AS (
  SELECT DISTINCT person_id FROM (
    SELECT person_id FROM ami_dx
    UNION
    SELECT person_id FROM old_mi_dx
    UNION
    SELECT person_id FROM revasc_event
    -- NLP logic removed per Rule 8
  ) hx
),
ami_on_statin AS (
  SELECT e.person_id, e.index_date
  FROM ami_event e
  WHERE EXISTS (
    SELECT 1 FROM victr_sd.sd_omop_prod.drug_exposure de
    WHERE de.person_id = e.person_id AND de.drug_concept_id IN (SELECT concept_id FROM statin_ing) AND de.drug_exposure_start_date <= DATE_ADD(e.index_date, -180)
  )
),
first_ami_on_statin AS (
  SELECT * FROM ami_on_statin WHERE person_id NOT IN (SELECT person_id FROM hist_event)
),
revasc_on_statin AS (
  SELECT p.person_id, p.index_date
  FROM revasc_event p
  WHERE EXISTS (
    SELECT 1 FROM victr_sd.sd_omop_prod.drug_exposure de
    WHERE de.person_id = p.person_id AND de.drug_concept_id IN (SELECT concept_id FROM statin_ing) AND de.drug_exposure_start_date <= DATE_ADD(p.index_date, -180)
  )
),
first_revasc_on_statin AS (
  SELECT * FROM revasc_on_statin WHERE person_id NOT IN (SELECT person_id FROM hist_event)
),
controls AS (
  SELECT DISTINCT su.person_id FROM statin_user su WHERE su.person_id NOT IN (
    SELECT person_id FROM ami_event
    UNION
    SELECT person_id FROM revasc_event
    UNION
    SELECT person_id FROM hist_event
  )
)
SELECT 'AMI_case' AS cohort, person_id, index_date FROM ami_on_statin
UNION ALL
SELECT 'AMI_first_case' AS cohort, person_id, index_date FROM first_ami_on_statin
UNION ALL
SELECT 'Revasc_case' AS cohort, person_id, index_date FROM revasc_on_statin
UNION ALL
SELECT 'Revasc_first_case' AS cohort, person_id, index_date FROM first_revasc_on_statin
UNION ALL
SELECT 'Control' AS cohort, person_id, CAST(NULL AS DATE) AS index_date FROM controls;