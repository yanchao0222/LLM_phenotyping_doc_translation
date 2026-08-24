-- Rule 1 (VUMC-specific database name): APPLIED
-- Rule 3 (concept set search on clinical tables): APPLIED
-- Rule 4 (standard code filters =/IN): APPLIED
-- Rule 5 (free-text descriptive fields use ILIKE): APPLIED
-- Rule 6 (OR -> UNION): APPLIED
-- Rule 8 (remove NLP/free-text logic): APPLIED

CREATE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex1_all_content_LLM1_MACE AS

WITH
-- REVISED (was: ami_case_dx AS (SELECT concept_id FROM concept WHERE vocabulary_id = 'ICD9CM' AND (concept_code LIKE '410%' OR concept_code LIKE '411%')))
ami_case_dx AS (
    SELECT DISTINCT condition_source_value AS icd_code
    FROM victr_sd.sd_omop_prod.condition_occurrence
    WHERE condition_source_value LIKE '410%' OR condition_source_value LIKE '411%'
),
-- REVISED (was: ami_excl_dx AS (SELECT concept_id FROM concept WHERE vocabulary_id = 'ICD9CM' AND (concept_code LIKE '410%' OR concept_code LIKE '411%' OR concept_code LIKE '412%')))
ami_excl_dx AS (
    SELECT DISTINCT condition_source_value AS icd_code
    FROM victr_sd.sd_omop_prod.condition_occurrence
    WHERE condition_source_value LIKE '410%' OR condition_source_value LIKE '411%' OR condition_source_value LIKE '412%'
),
-- REVISED (was: revasc_proc AS (SELECT concept_id FROM concept WHERE (vocabulary_id = 'CPT4'  AND ((concept_code BETWEEN '33510' AND '33523') OR (concept_code BETWEEN '33533' AND '33536') OR concept_code IN ('92980','92981','92982','92984','92995','92996'))) OR (vocabulary_id = 'HCPCS' AND concept_code IN ('C1874','C1875','C1876','C1877'))))
revasc_proc AS (
    SELECT DISTINCT procedure_source_value AS proc_code
    FROM victr_sd.sd_omop_prod.procedure_occurrence
    WHERE (procedure_source_value BETWEEN '33510' AND '33523')
       OR (procedure_source_value BETWEEN '33533' AND '33536')
       OR procedure_source_value IN ('92980','92981','92982','92984','92995','92996','C1874','C1875','C1876','C1877')
),
-- REVISED (was: statin_drugs AS (SELECT concept_id FROM concept WHERE vocabulary_id = 'RxNorm' AND LOWER(concept_name) SIMILAR TO '%(simvastatin|fluvastatin|atorvastatin|pravastatin|lovastatin|cerivastatin|rosuvastatin)%'))
statin_drugs AS (
    SELECT DISTINCT ca.ancestor_concept_id AS concept_id
    FROM victr_sd.sd_omop_prod.concept_ancestor ca
    JOIN victr_sd.sd_omop_prod.concept c ON ca.ancestor_concept_id = c.concept_id
    WHERE c.vocabulary_id = 'RxNorm'
      AND (
        LOWER(c.concept_name) LIKE '%simvastatin%' OR
        LOWER(c.concept_name) LIKE '%fluvastatin%' OR
        LOWER(c.concept_name) LIKE '%atorvastatin%' OR
        LOWER(c.concept_name) LIKE '%pravastatin%' OR
        LOWER(c.concept_name) LIKE '%lovastatin%' OR
        LOWER(c.concept_name) LIKE '%cerivastatin%' OR
        LOWER(c.concept_name) LIKE '%rosuvastatin%'
      )
),
-- REVISED (was: troponin_i_labs AS (SELECT concept_id FROM concept WHERE vocabulary_id = 'LOINC' AND LOWER(concept_name) LIKE '%troponin i%'))
troponin_i_labs AS (
    SELECT concept_id
    FROM victr_sd.sd_omop_prod.concept
    WHERE vocabulary_id = 'LOINC' AND LOWER(concept_name) LIKE '%troponin i%'
),
-- REVISED (was: troponin_t_labs AS (SELECT concept_id FROM concept WHERE vocabulary_id = 'LOINC' AND LOWER(concept_name) LIKE '%troponin t%'))
troponin_t_labs AS (
    SELECT concept_id
    FROM victr_sd.sd_omop_prod.concept
    WHERE vocabulary_id = 'LOINC' AND LOWER(concept_name) LIKE '%troponin t%'
),
-- REVISED (was: ckmb_ratio_labs AS (SELECT concept_id FROM concept WHERE vocabulary_id = 'LOINC' AND LOWER(concept_name) LIKE '%ck-mb ratio%'))
ckmb_ratio_labs AS (
    SELECT concept_id
    FROM victr_sd.sd_omop_prod.concept
    WHERE vocabulary_id = 'LOINC' AND LOWER(concept_name) LIKE '%ck-mb ratio%'
),
-- REVISED (was: ckmb_labs AS (SELECT concept_id FROM concept WHERE vocabulary_id = 'LOINC' AND LOWER(concept_name) LIKE '%ck-mb%' AND LOWER(concept_name) NOT LIKE '%ratio%'))
ckmb_labs AS (
    SELECT concept_id
    FROM victr_sd.sd_omop_prod.concept
    WHERE vocabulary_id = 'LOINC' AND LOWER(concept_name) LIKE '%ck-mb%' AND LOWER(concept_name) NOT LIKE '%ratio%'
),

statin_era AS (
    SELECT person_id,
           drug_era_start_date,
           drug_era_end_date
    FROM   victr_sd.sd_omop_prod.drug_era
    WHERE  drug_concept_id IN (SELECT concept_id FROM statin_drugs)
),

candidate_ami AS (
    SELECT  idx.person_id,
            idx.condition_start_date AS index_date
    FROM    victr_sd.sd_omop_prod.condition_occurrence idx
            JOIN ami_case_dx d ON idx.condition_source_value = d.icd_code
    WHERE  (
            SELECT COUNT(*)
            FROM   victr_sd.sd_omop_prod.condition_occurrence c2
                   JOIN ami_case_dx d2 ON c2.condition_source_value = d2.icd_code
            WHERE  c2.person_id          = idx.person_id
              AND  c2.condition_start_date
                      BETWEEN idx.condition_start_date
                          AND DATE_ADD(idx.condition_start_date, 5)
           ) >= 2
      AND (
            EXISTS (
                SELECT 1
                FROM   victr_sd.sd_omop_prod.measurement m
                JOIN troponin_i_labs l ON m.measurement_concept_id = l.concept_id
                WHERE  m.person_id                = idx.person_id
                  AND  m.measurement_date
                         BETWEEN idx.condition_start_date
                             AND DATE_ADD(idx.condition_start_date, 5)
                  AND  m.value_as_number          >= 0.10
            )
            OR
            EXISTS (
                SELECT 1
                FROM   victr_sd.sd_omop_prod.measurement m
                JOIN troponin_t_labs l ON m.measurement_concept_id = l.concept_id
                WHERE  m.person_id                = idx.person_id
                  AND  m.measurement_date
                         BETWEEN idx.condition_start_date
                             AND DATE_ADD(idx.condition_start_date, 5)
                  AND  m.value_as_number          >= 0.10
            )
            OR
            (
              EXISTS (
                  SELECT 1
                  FROM   victr_sd.sd_omop_prod.measurement m
                  JOIN ckmb_ratio_labs l ON m.measurement_concept_id = l.concept_id
                  WHERE  m.person_id                = idx.person_id
                    AND  m.measurement_date
                           BETWEEN idx.condition_start_date
                               AND DATE_ADD(idx.condition_start_date, 5)
                    AND  m.value_as_number          >= 3.0
              )
              AND
              EXISTS (
                  SELECT 1
                  FROM   victr_sd.sd_omop_prod.measurement m
                  JOIN ckmb_labs l ON m.measurement_concept_id = l.concept_id
                  WHERE  m.person_id                = idx.person_id
                    AND  m.measurement_date
                           BETWEEN idx.condition_start_date
                               AND DATE_ADD(idx.condition_start_date, 5)
                    AND  m.value_as_number          >= 10.0
              )
            )
          )
      AND EXISTS (
            SELECT 1
            FROM   statin_era se
            WHERE  se.person_id            = idx.person_id
              AND  se.drug_era_start_date <= DATE_ADD(idx.condition_start_date, -180)
              AND  se.drug_era_end_date   >= DATE_ADD(idx.condition_start_date, -1)
          )
),

candidate_revasc AS (
    SELECT  p.person_id,
            p.procedure_date AS index_date
    FROM    victr_sd.sd_omop_prod.procedure_occurrence p
            JOIN revasc_proc r ON p.procedure_source_value = r.proc_code
    WHERE EXISTS (
            SELECT 1
            FROM   statin_era se
            WHERE  se.person_id            = p.person_id
              AND  se.drug_era_start_date <= DATE_ADD(p.procedure_date, -180)
              AND  se.drug_era_end_date   >= DATE_ADD(p.procedure_date, -1)
          )
),

prior_mace_dx AS (
    SELECT DISTINCT person_id
    FROM   victr_sd.sd_omop_prod.condition_occurrence
           JOIN ami_excl_dx e ON condition_source_value = e.icd_code
),
prior_revasc AS (
    SELECT DISTINCT person_id
    FROM   victr_sd.sd_omop_prod.procedure_occurrence
           JOIN revasc_proc r ON procedure_source_value = r.proc_code
),
-- REVISED (was: WHERE LOWER(observation_source_value) IN (...))
prior_mace_nlp AS (
    SELECT DISTINCT person_id
    FROM   victr_sd.sd_omop_prod.observation
    WHERE  observation_source_value ILIKE '%ami%'
        OR observation_source_value ILIKE '%mi%'
        OR observation_source_value ILIKE '%acute myocardial infarction%'
        OR observation_source_value ILIKE '%myocardial infarction%'
        OR observation_source_value ILIKE '%cabg%'
        OR observation_source_value ILIKE '%stent%'
        OR observation_source_value ILIKE '%bms%'
        OR observation_source_value ILIKE '%des%'
        OR observation_source_value ILIKE '%coronary artery bypass%'
        OR observation_source_value ILIKE '%cypher%'
        OR observation_source_value ILIKE '%taxus%'
),

ami_on_statin AS (
    SELECT * FROM candidate_ami
),
first_ami_on_statin AS (
    SELECT a.*
    FROM   candidate_ami a
    WHERE NOT EXISTS (SELECT 1 FROM prior_mace_dx  d WHERE d.person_id = a.person_id)
      AND NOT EXISTS (SELECT 1 FROM prior_revasc   r WHERE r.person_id = a.person_id)
      AND NOT EXISTS (SELECT 1 FROM prior_mace_nlp n WHERE n.person_id = a.person_id)
),
revasc_on_statin AS (
    SELECT * FROM candidate_revasc
),
first_revasc_on_statin AS (
    SELECT r.*
    FROM   candidate_revasc r
    WHERE NOT EXISTS (SELECT 1 FROM prior_mace_dx  d WHERE d.person_id = r.person_id)
      AND NOT EXISTS (SELECT 1 FROM prior_revasc   pr WHERE pr.person_id = r.person_id)
      AND NOT EXISTS (SELECT 1 FROM prior_mace_nlp n WHERE n.person_id = r.person_id)
),
mace_on_statin AS (
    SELECT * FROM ami_on_statin
    UNION ALL
    SELECT * FROM revasc_on_statin
),
first_mace_on_statin AS (
    SELECT * FROM first_ami_on_statin
    UNION ALL
    SELECT * FROM first_revasc_on_statin
),
statin_controls AS (
    SELECT DISTINCT se.person_id
    FROM   statin_era se
    WHERE  NOT EXISTS (SELECT 1 FROM prior_mace_dx  d WHERE d.person_id = se.person_id)
      AND  NOT EXISTS (SELECT 1 FROM prior_revasc   r WHERE r.person_id = se.person_id)
      AND  NOT EXISTS (SELECT 1 FROM prior_mace_nlp n WHERE n.person_id = se.person_id)
)

SELECT 'MACE_CASE'       AS cohort_type,
       person_id,
       index_date
FROM   mace_on_statin

UNION ALL

SELECT 'FIRST_MACE_CASE' AS cohort_type,
       person_id,
       index_date
FROM   first_mace_on_statin

UNION ALL

SELECT 'STATIN_CONTROL'  AS cohort_type,
       person_id,
       NULL              AS index_date
FROM   statin_controls
;