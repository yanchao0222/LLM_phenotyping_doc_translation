-- Rule 1 (VUMC-specific database name): APPLIED
-- Rule 3 (search ICD codes in condition_occurrence.condition_source_value): APPLIED
-- Rule 4 (LOINC/RxNorm code handling): APPLIED
-- Rule 6 (OR -> UNION): APPLIED
-- Rule 5 (free-text LIKE): NOT APPLICABLE
-- Rule 2 (wildcard): NOT APPLICABLE
-- Rule 7 (LEFT JOIN -> UNION): NOT APPLICABLE
-- Rule 8 (remove NLP): NOT APPLICABLE
-- Rule 9 (missing concept): NOT APPLICABLE

CREATE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex1_all_content_LLM1_T2DM AS

WITH
/*------------------------------------------------------------------*
 | 1. DIAGNOSIS CONCEPT SETS (ICD‑9‑CM)                             |
 *------------------------------------------------------------------*/
t1dm_dx AS (
  -- REVISED (was: SELECT DISTINCT ca.descendant_concept_id FROM concept c JOIN concept_ancestor ca ON ca.ancestor_concept_id = c.concept_id WHERE c.vocabulary_id = 'ICD9CM' AND c.concept_code IN (...))
  SELECT DISTINCT co.condition_source_value AS icd_code
  FROM `victr_sd`.`sd_omop_prod`.`condition_occurrence` co
  WHERE co.condition_source_value IN (
    '250.01','250.03','250.11','250.13','250.21','250.23',
    '250.31','250.33','250.41','250.43','250.51','250.53',
    '250.61','250.63','250.71','250.73','250.81','250.83',
    '250.91','250.93'
  )
),
t2dm_dx AS (
  -- REVISED (was: SELECT DISTINCT ca.descendant_concept_id FROM concept c JOIN concept_ancestor ca ON ca.ancestor_concept_id = c.concept_id WHERE c.vocabulary_id = 'ICD9CM' AND c.concept_code IN (...))
  SELECT DISTINCT co.condition_source_value AS icd_code
  FROM `victr_sd`.`sd_omop_prod`.`condition_occurrence` co
  WHERE co.condition_source_value IN (
    '250.00','250.02','250.20','250.22','250.30','250.32',
    '250.40','250.42','250.50','250.52','250.60','250.62',
    '250.70','250.72','250.80','250.82','250.90','250.92'
  )
),
any_dm_dx AS (
  -- REVISED (was: SELECT DISTINCT ca.descendant_concept_id FROM concept c JOIN concept_ancestor ca ON ca.ancestor_concept_id = c.concept_id WHERE c.vocabulary_id = 'ICD9CM' AND (c.concept_code LIKE '250.%' OR ...))
  SELECT DISTINCT co.condition_source_value AS icd_code
  FROM `victr_sd`.`sd_omop_prod`.`condition_occurrence` co
  WHERE (
    co.condition_source_value LIKE '250.%'
    OR co.condition_source_value IN ('790.21','790.22','790.2','790.29','791.5','277.7','V18.0','V77.1')
    OR co.condition_source_value LIKE '648.8%'
    OR co.condition_source_value LIKE '648.0%'
  )
),

/*------------------------------------------------------------------*
 | 2. DRUG & SUPPLY CONCEPT SETS (RxNorm / NDDF / VANDF)            |
 *------------------------------------------------------------------*/
t1dm_rx AS (
  -- REVISED (was: SELECT DISTINCT ca.descendant_concept_id FROM concept c JOIN concept_ancestor ca ON ca.ancestor_concept_id = c.concept_id WHERE c.vocabulary_id = 'RxNorm' AND c.concept_code IN (...))
  SELECT DISTINCT ca.descendant_concept_id
  FROM `victr_sd`.`sd_omop_prod`.`concept` c
  JOIN `victr_sd`.`sd_omop_prod`.`concept_ancestor` ca ON ca.ancestor_concept_id = c.concept_id
  WHERE c.vocabulary_id = 'RxNorm'
    AND c.concept_code IN (
      '139825','274783','314684','352385','400008',
      '51428','5856','86009','139953'
    )
),
t2dm_rx AS (
  -- REVISED (was: SELECT DISTINCT ca.descendant_concept_id FROM concept c JOIN concept_ancestor ca ON ca.ancestor_concept_id = c.concept_id WHERE c.vocabulary_id = 'RxNorm' AND c.concept_code IN (...))
  SELECT DISTINCT ca.descendant_concept_id
  FROM `victr_sd`.`sd_omop_prod`.`concept` c
  JOIN `victr_sd`.`sd_omop_prod`.`concept_ancestor` ca ON ca.ancestor_concept_id = c.concept_id
  WHERE c.vocabulary_id = 'RxNorm'
    AND c.concept_code IN (
      '173','10633','2404','4821','217360','4815','25789',
      '73044','274332','6809','84108','33738','72610',
      '16681','30009','593411','60548'
    )
),
dm_supplies AS (
  -- REVISED (was: SELECT DISTINCT ca.descendant_concept_id FROM concept c JOIN concept_ancestor ca ON ca.ancestor_concept_id = c.concept_id WHERE c.vocabulary_id IN ('NDDF','VANDF','RxNorm') AND c.concept_code IN (...))
  SELECT DISTINCT ca.descendant_concept_id
  FROM `victr_sd`.`sd_omop_prod`.`concept` c
  JOIN `victr_sd`.`sd_omop_prod`.`concept_ancestor` ca ON ca.ancestor_concept_id = c.concept_id
  WHERE c.vocabulary_id IN ('NDDF','VANDF','RxNorm')
    AND c.concept_code IN (
      '126958','412956','412959','637321','668291','668370',
      '686655','692383','748611','880998','881056','751128',
      '847187','847191','847197','847203','847207','847211',
      '847230','847239','847252','847256','847259','847263',
      '847278','847416','847417','806905','806903','408119'
    )
),

/*------------------------------------------------------------------*
 | 3. LABORATORY CONCEPT SETS (LOINC)                               |
 *------------------------------------------------------------------*/
fast_gluc AS (
  -- REVISED (was: SELECT concept_id FROM concept WHERE vocabulary_id = 'LOINC' AND concept_code = '1558-6')
  SELECT concept_id
  FROM `victr_sd`.`sd_omop_prod`.`concept`
  WHERE vocabulary_id = 'LOINC' AND concept_code = '1558-6'
),
rand_gluc AS (
  -- REVISED (was: SELECT concept_id FROM concept WHERE vocabulary_id = 'LOINC' AND concept_code IN ('2339-0','2345-7'))
  SELECT concept_id
  FROM `victr_sd`.`sd_omop_prod`.`concept`
  WHERE vocabulary_id = 'LOINC' AND concept_code IN ('2339-0','2345-7')
),
hba1c AS (
  -- REVISED (was: SELECT concept_id FROM concept WHERE vocabulary_id = 'LOINC' AND concept_code IN ('4548-4','4549-2','17855-8','17856-6'))
  SELECT concept_id
  FROM `victr_sd`.`sd_omop_prod`.`concept`
  WHERE vocabulary_id = 'LOINC' AND concept_code IN ('4548-4','4549-2','17855-8','17856-6')
),

/*------------------------------------------------------------------*
 | 4. PERSON‑LEVEL FEATURES                                         |
 *------------------------------------------------------------------*/
dx AS (
  -- REVISED (was: WHERE co.condition_concept_id IN (SELECT descendant_concept_id FROM t1dm_dx))
  SELECT co.person_id,
         COUNT(DISTINCT co.condition_start_date)
           FILTER (WHERE co.condition_source_value IN (SELECT icd_code FROM t1dm_dx)) AS t1dx_cnt,
         COUNT(DISTINCT co.condition_start_date)
           FILTER (WHERE co.condition_source_value IN (SELECT icd_code FROM t2dm_dx)) AS t2dx_cnt,
         COUNT(DISTINCT co.condition_start_date)
           FILTER (WHERE co.condition_source_value IN (SELECT icd_code FROM any_dm_dx)) AS anydx_cnt,
         COUNT(DISTINCT co.condition_start_date) FILTER (
           WHERE co.condition_source_value IN (SELECT icd_code FROM t2dm_dx)
             AND co.provider_id IS NOT NULL
             AND EXISTS (
               SELECT 1
               FROM `victr_sd`.`sd_omop_prod`.`visit_occurrence` vo
               WHERE vo.visit_occurrence_id = co.visit_occurrence_id
                 AND vo.visit_concept_id IN (9202,9203)
             )
         ) AS t2_phys_cnt
  FROM `victr_sd`.`sd_omop_prod`.`condition_occurrence` co
  GROUP BY co.person_id
),
rx AS (
  -- REVISED (was: WHERE de.drug_concept_id IN (SELECT descendant_concept_id FROM t1dm_rx))
  SELECT de.person_id,
         MIN(de.drug_exposure_start_date)
           FILTER (WHERE de.drug_concept_id IN (SELECT descendant_concept_id FROM t1dm_rx)) AS first_t1_rx_dt,
         MIN(de.drug_exposure_start_date)
           FILTER (WHERE de.drug_concept_id IN (SELECT descendant_concept_id FROM t2dm_rx)) AS first_t2_rx_dt,
         COUNT(DISTINCT de.drug_exposure_start_date)
           FILTER (WHERE de.drug_concept_id IN (
                    SELECT descendant_concept_id FROM t1dm_rx
                    UNION ALL
                    SELECT descendant_concept_id FROM t2dm_rx
                    UNION ALL
                    SELECT descendant_concept_id FROM dm_supplies
                  )) AS dm_rx_sup_cnt
  FROM `victr_sd`.`sd_omop_prod`.`drug_exposure` de
  GROUP BY de.person_id
),
lab AS (
  -- REVISED (was: WHERE m.measurement_concept_id IN (SELECT concept_id FROM fast_gluc))
  SELECT m.person_id,
         MAX(m.value_as_number)
           FILTER (WHERE m.measurement_concept_id IN (SELECT concept_id FROM fast_gluc)) AS max_fast_gluc,
         MAX(m.value_as_number)
           FILTER (WHERE m.measurement_concept_id IN (SELECT concept_id FROM rand_gluc)) AS max_rand_gluc,
         MAX(m.value_as_number)
           FILTER (WHERE m.measurement_concept_id IN (SELECT concept_id FROM hba1c)) AS max_hba1c,
         COUNT(*) FILTER (WHERE m.measurement_concept_id IN (
                           SELECT concept_id FROM fast_gluc
                           UNION ALL
                           SELECT concept_id FROM rand_gluc)) AS gluc_lab_cnt
  FROM `victr_sd`.`sd_omop_prod`.`measurement` m
  GROUP BY m.person_id
),
enc AS (
  SELECT person_id,
         COUNT(DISTINCT visit_start_date)
           FILTER (WHERE visit_concept_id = 9202) AS office_visit_cnt
  FROM `victr_sd`.`sd_omop_prod`.`visit_occurrence`
  GROUP BY person_id
),
fh AS (
  SELECT DISTINCT co.person_id, 1 AS has_fh
  FROM `victr_sd`.`sd_omop_prod`.`condition_occurrence` co
  WHERE co.condition_source_value = 'V18.0'
)

SELECT p.person_id,
       CASE
         WHEN dx.t1dx_cnt = 0
          AND dx.t2dx_cnt > 0
          AND rx.first_t2_rx_dt IS NOT NULL
          AND rx.first_t1_rx_dt IS NOT NULL
          AND rx.first_t2_rx_dt < rx.first_t1_rx_dt                     THEN 'CASE'
         WHEN dx.t1dx_cnt = 0
          AND dx.t2dx_cnt > 0
          AND rx.first_t1_rx_dt IS NULL
          AND rx.first_t2_rx_dt IS NOT NULL                             THEN 'CASE'
         WHEN dx.t1dx_cnt = 0
          AND dx.t2dx_cnt > 0
          AND rx.first_t1_rx_dt IS NULL
          AND rx.first_t2_rx_dt IS NULL
          AND (
               lab.max_rand_gluc >  200
            OR lab.max_fast_gluc >= 125
            OR lab.max_hba1c     >= 6.5
          )                                                             THEN 'CASE'
         WHEN dx.t1dx_cnt = 0
          AND dx.t2dx_cnt = 0
          AND rx.first_t2_rx_dt IS NOT NULL
          AND (
               lab.max_rand_gluc >  200
            OR lab.max_fast_gluc >= 125
            OR lab.max_hba1c     >= 6.5
          )                                                             THEN 'CASE'
         WHEN dx.t1dx_cnt = 0
          AND dx.t2dx_cnt > 0
          AND rx.first_t1_rx_dt IS NOT NULL
          AND rx.first_t2_rx_dt IS NULL
          AND dx.t2_phys_cnt   >= 2                                     THEN 'CASE'
         WHEN dx.anydx_cnt   = 0
          AND lab.gluc_lab_cnt > 0
          AND COALESCE(lab.max_rand_gluc, 0) < 110
          AND COALESCE(lab.max_fast_gluc, 0) < 110
          AND COALESCE(lab.max_hba1c,   0) < 6.0
          AND enc.office_visit_cnt >= 2
          AND rx.dm_rx_sup_cnt    = 0
          AND COALESCE(fh.has_fh,0) = 0                                  THEN 'CONTROL'
         ELSE 'UNKNOWN'
       END AS t2dm_status
FROM `victr_sd`.`sd_omop_prod`.`person` p
LEFT JOIN dx  ON dx.person_id  = p.person_id
LEFT JOIN rx  ON rx.person_id  = p.person_id
LEFT JOIN lab ON lab.person_id = p.person_id
LEFT JOIN enc ON enc.person_id = p.person_id
LEFT JOIN fh  ON fh.person_id  = p.person_id;
