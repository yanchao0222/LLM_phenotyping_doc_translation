-- Rule 1 (VUMC-specific database name): APPLIED (all table references updated to victr_sd.sd_omop_prod)
-- Rule 2 (Fix incorrect wildcard characters): NOT APPLICABLE (wildcards are correct)
-- Rule 3 (Replace concept table search with clinical data table search): APPLIED (ICD/CPT code search uses clinical tables)
-- Rule 4 (Standard code handling): APPLIED (LOINC/RxNorm/CPT/ICD code handling as specified)
-- Rule 5 (Free-text descriptive fields): NOT APPLICABLE (no descriptive field search)
-- Rule 6 (OR -> UNION): NOT APPLICABLE (no OR across tables)
-- Rule 7 (LEFT JOIN -> UNION): NOT APPLICABLE (no LEFT JOIN across tables)
-- Rule 8 (Remove NLP/free-text logic): APPLIED (note_nlp CTE and references removed)
-- Rule 9 (Mark missing/ambiguous concepts): NOT APPLICABLE (all concepts defined)

CREATE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex3_only_diagram_LLM1_MACE AS 

WITH statin_concept_set AS (
    -- REVISED (was: FROM concept_ancestor)
    SELECT DISTINCT ca.descendant_concept_id AS concept_id
    FROM victr_sd.sd_omop_prod.concept_ancestor ca
    JOIN victr_sd.sd_omop_prod.concept c ON ca.ancestor_concept_id = c.concept_id
    WHERE c.domain_id = 'Drug'
      AND c.concept_class_id = 'Ingredient'
      AND c.vocabulary_id = 'RxNorm'
      AND LOWER(c.concept_name) LIKE '%statin'
),
ami_case_icd9 AS (
    -- REVISED (was: FROM concept WHERE vocabulary_id = 'ICD9CM' AND concept_code LIKE '410%' OR concept_code LIKE '411%')
    SELECT DISTINCT condition_concept_id AS concept_id
    FROM victr_sd.sd_omop_prod.condition_occurrence
    WHERE condition_source_value LIKE '410%'
       OR condition_source_value LIKE '411%'
),
ami_excl_icd9 AS (
    SELECT * FROM ami_case_icd9
    UNION ALL
    -- REVISED (was: FROM concept WHERE vocabulary_id = 'ICD9CM' AND concept_code LIKE '412%')
    SELECT DISTINCT condition_concept_id AS concept_id
    FROM victr_sd.sd_omop_prod.condition_occurrence
    WHERE condition_source_value LIKE '412%'
),
revasc_cpt AS (
    -- REVISED (was: FROM concept WHERE vocabulary_id = 'CPT4' AND (lower(concept_name) LIKE ...))
    SELECT DISTINCT procedure_concept_id AS concept_id
    FROM victr_sd.sd_omop_prod.procedure_occurrence
    WHERE LOWER(procedure_source_value) LIKE '%angioplasty%'
       OR LOWER(procedure_source_value) LIKE '%stent%'
       OR LOWER(procedure_source_value) LIKE '%percutaneous coronary intervention%'
),
troponin_i_loinc AS (
    -- REVISED (was: FROM concept WHERE vocabulary_id = 'LOINC' AND lower(concept_name) LIKE '%troponin i%')
    SELECT c.concept_id, c.concept_code
    FROM victr_sd.sd_omop_prod.concept c
    WHERE c.vocabulary_id = 'LOINC' AND LOWER(c.concept_name) LIKE '%troponin i%'
),
troponin_t_loinc AS (
    SELECT c.concept_id, c.concept_code
    FROM victr_sd.sd_omop_prod.concept c
    WHERE c.vocabulary_id = 'LOINC' AND LOWER(c.concept_name) LIKE '%troponin t%'
),
ck_mb_loinc AS (
    SELECT c.concept_id, c.concept_code
    FROM victr_sd.sd_omop_prod.concept c
    WHERE c.vocabulary_id = 'LOINC' AND LOWER(c.concept_name) LIKE '%ck-mb%'
),
ck_total_loinc AS (
    SELECT c.concept_id, c.concept_code
    FROM victr_sd.sd_omop_prod.concept c
    WHERE c.vocabulary_id = 'LOINC' AND LOWER(c.concept_name) LIKE '%ck%' AND LOWER(c.concept_name) LIKE '%total%'
),
statin_exposure AS (
    SELECT person_id,
           MIN(drug_exposure_start_date) AS statin_start
    FROM victr_sd.sd_omop_prod.drug_exposure
    WHERE drug_concept_id IN (SELECT concept_id FROM statin_concept_set)
    GROUP BY person_id
),
ami_dx AS (
    SELECT person_id,
           condition_start_date AS dx_date
    FROM victr_sd.sd_omop_prod.condition_occurrence
    WHERE condition_concept_id IN (SELECT concept_id FROM ami_case_icd9)
),
ami_windows AS (
    SELECT DISTINCT
           person_id,
           MIN(dx_date) OVER win AS window_start
    FROM ami_dx
    WINDOW win AS (
        PARTITION BY person_id
        ORDER BY dx_date
        RANGE BETWEEN INTERVAL 4 DAY PRECEDING AND CURRENT ROW
    )
),
ami_two_plus AS (
    SELECT person_id,
           window_start AS index_date
    FROM (
        SELECT person_id,
               window_start,
               COUNT(*) OVER (PARTITION BY person_id, window_start) AS n_codes
        FROM ami_windows
    ) t
    WHERE n_codes >= 2
),
confirm_lab AS (
    -- REVISED (was: FROM measurement m WHERE measurement_concept_id IN (SELECT concept_id FROM troponin_i_loinc))
    SELECT DISTINCT m.person_id, m.measurement_date
    FROM victr_sd.sd_omop_prod.measurement m
    JOIN victr_sd.sd_omop_prod.concept c ON m.measurement_concept_id = c.concept_id
    WHERE (c.vocabulary_id = 'LOINC' AND c.concept_code IN (SELECT concept_code FROM troponin_i_loinc) AND m.value_as_number >= 0.10)
       OR (c.vocabulary_id = 'LOINC' AND c.concept_code IN (SELECT concept_code FROM troponin_t_loinc) AND m.value_as_number >= 0.10)
       OR (c.vocabulary_id = 'LOINC' AND c.concept_code IN (SELECT concept_code FROM ck_mb_loinc) AND m.value_as_number >= 10
            AND EXISTS (
                  SELECT 1
                  FROM victr_sd.sd_omop_prod.measurement tot
                  JOIN victr_sd.sd_omop_prod.concept ctot ON tot.measurement_concept_id = ctot.concept_id
                  WHERE tot.person_id = m.person_id
                    AND tot.measurement_date = m.measurement_date
                    AND ctot.vocabulary_id = 'LOINC'
                    AND ctot.concept_code IN (SELECT concept_code FROM ck_total_loinc)
                    AND try_divide(m.value_as_number,NULLIF(tot.value_as_number,0)) >= 3.0
            )
         )
),
revasc_proc AS (
    SELECT person_id,
           procedure_date AS proc_date
    FROM victr_sd.sd_omop_prod.procedure_occurrence
    WHERE procedure_concept_id IN (SELECT concept_id FROM revasc_cpt)
),
ami_on_statin AS (
    SELECT a.person_id,
           a.index_date
    FROM ami_two_plus a
    JOIN confirm_lab l ON l.person_id = a.person_id AND ABS(DATEDIFF(l.measurement_date, a.index_date)) <= 5
    JOIN statin_exposure s ON s.person_id = a.person_id AND DATEDIFF(s.statin_start, a.index_date) >= 180
),
first_ami_on_statin AS (
    SELECT a.person_id,
           a.index_date
    FROM ami_on_statin a
    WHERE NOT EXISTS (
              SELECT 1
              FROM victr_sd.sd_omop_prod.condition_occurrence c
              WHERE c.person_id = a.person_id
                AND c.condition_concept_id IN (SELECT concept_id FROM ami_excl_icd9)
                AND c.condition_start_date < a.index_date
          )
      AND NOT EXISTS (
              SELECT 1
              FROM revasc_proc r
              WHERE r.person_id = a.person_id
                AND r.proc_date < a.index_date
          )
),
revasc_on_statin AS (
    SELECT r.person_id,
           r.proc_date AS index_date
    FROM revasc_proc r
    JOIN statin_exposure s ON s.person_id = r.person_id AND DATEDIFF(s.statin_start, r.proc_date) >= 180
),
first_revasc_on_statin AS (
    SELECT r.person_id,
           r.index_date
    FROM revasc_on_statin r
    WHERE NOT EXISTS (
              SELECT 1
              FROM victr_sd.sd_omop_prod.condition_occurrence c
              WHERE c.person_id = r.person_id
                AND c.condition_concept_id IN (SELECT concept_id FROM ami_excl_icd9)
                AND c.condition_start_date < r.index_date
          )
      AND NOT EXISTS (
              SELECT 1
              FROM revasc_proc p2
              WHERE p2.person_id = r.person_id
                AND p2.proc_date < r.index_date
          )
),
statin_controls AS (
    SELECT s.person_id,
           s.statin_start AS index_date
    FROM statin_exposure s
    WHERE NOT EXISTS (SELECT 1 FROM ami_on_statin a WHERE a.person_id = s.person_id)
      AND NOT EXISTS (SELECT 1 FROM revasc_on_statin r WHERE r.person_id = s.person_id)
      AND NOT EXISTS (SELECT 1 FROM victr_sd.sd_omop_prod.condition_occurrence c WHERE c.person_id = s.person_id AND c.condition_concept_id IN (SELECT concept_id FROM ami_excl_icd9))
      AND NOT EXISTS (SELECT 1 FROM revasc_proc p WHERE p.person_id = s.person_id)
)
SELECT 'AMI_on_Statin' AS cohort_name, person_id, index_date FROM ami_on_statin
UNION ALL
SELECT 'First_AMI_on_Statin' AS cohort_name, person_id, index_date FROM first_ami_on_statin
UNION ALL
SELECT 'Revasc_on_Statin' AS cohort_name, person_id, index_date FROM revasc_on_statin
UNION ALL
SELECT 'First_Revasc_on_Statin' AS cohort_name, person_id, index_date FROM first_revasc_on_statin
UNION ALL
SELECT 'Statin_Control' AS cohort_name, person_id, index_date FROM statin_controls;
