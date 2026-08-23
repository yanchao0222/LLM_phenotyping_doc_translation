/* ================================================================
   T2DM CASE & CONTROL COHORT
   Implements corrected canonical phenotype specification
   ================================================================
   Output columns:
     person_id
     cohort_type   -- 'CASE' | 'CONTROL'
     index_date    -- TECHNICAL DECISION: earliest qualifying event
     cohort_start_date
     cohort_end_date
   ================================================================
*/

/* ---------------------------
   1. CONCEPT SETS
   ---------------------------
   Each block is labelled with Criterion IDs and PDF citations.
*/

WITH
/* ICD-9-CM Type 1 DM diagnosis codes
   CASE_C01  (PDF p 21) */
t1dm_dx_concepts AS (
  SELECT concept_id
  FROM concept
  WHERE vocabulary_id = 'ICD9CM'
    AND concept_code IN ('25001','25003')  -- 250.x1, 250.x3
    AND invalid_reason IS NULL
),

/* ICD-9-CM Type 2 DM diagnosis codes
   CASE_C02  (PDF p 21) */
t2dm_dx_concepts AS (
  SELECT concept_id
  FROM concept
  WHERE vocabulary_id = 'ICD9CM'
    AND concept_code IN ('25000','25002')  -- 250.x0, 250.x2
    AND concept_code NOT IN ('25010','25012')  -- explicit exclusions
    AND invalid_reason IS NULL
),

/* ICD-9-CM DM-related codes (Table 9)  CTRL_C01 (PDF p 23) */
dm_related_dx_concepts AS (
  SELECT concept_id
  FROM concept
  WHERE vocabulary_id = 'ICD9CM'
    AND (
         concept_code LIKE '250%'         -- 250.xx
      OR concept_code IN ('79021','79022','7902','79029',
                          '6488','64880','64881','64882','64883','64884','64885','64886','64887','64889',
                          '7915','2777','V180','V771')
    )
    AND invalid_reason IS NULL
),

/* RxNorm ingredient CUIs – T1DM meds
   CASE_C04A / CASE_C04B  (PDF p 21) */
t1dm_rx_ing AS (
  SELECT concept_id
  FROM concept
  WHERE vocabulary_id = 'RxNorm'
    AND concept_code IN ('139825','274783','314684','352385','400008','51428','5856','86009','139953')
    AND invalid_reason IS NULL
),

/* RxNorm ingredient CUIs – T2DM meds
   CASE_C03  (PDF p 22) */
t2dm_rx_ing AS (
  SELECT concept_id
  FROM concept
  WHERE vocabulary_id = 'RxNorm'
    AND concept_code IN ('173','10633','2404','4821','217360','4815','25789','73044','274332','6809',
                         '84108','33738','72610','16681','30009','593411','60548')
    AND invalid_reason IS NULL
),

/* Diabetes supplies (Tables 5,6,8)
   CTRL_C05  (PDF p 22-23) */
dm_supply_concepts AS (
  SELECT concept_id
  FROM concept
  WHERE (vocabulary_id = 'RxNorm' AND concept_code IN
            ('847187','847191','847197','847203','847207','847211',
             '847230','847239','847252','847256','847259','847263','847278','847416','847417'))
     OR (vocabulary_id = 'NDFRT' AND concept_code IN
            ('126958','412956','412959','637321','668291','668370',
             '686655','692383','748611','880998','881056','806905','806903','408119'))
     OR (vocabulary_id = 'VANDF' AND concept_code IN ('751128'))
     AND invalid_reason IS NULL
),

/* LOINC glucose & HbA1c – full set
   CASE_C06, CTRL_C03  (PDF p 22) */
loinc_glu_hba1c AS (
  SELECT concept_id, concept_code
  FROM concept
  WHERE vocabulary_id = 'LOINC'
    AND concept_code IN ('1558-6','2339-0','2345-7','4548-4','17856-6','4549-2','17855-8')
    AND invalid_reason IS NULL
),

/* LOINC glucose only (1558-6, 2339-0, 2345-7)
   CTRL_C02  (PDF p 22, Algorithm 10) */
loinc_glucose_only AS (
  SELECT concept_id
  FROM concept
  WHERE concept_id IN (
        SELECT concept_id FROM loinc_glu_hba1c WHERE concept_code IN ('1558-6','2339-0','2345-7')
  )
),

/* -----------------------------------------------------------
   2. EVENT CTEs – domain-specific rows + earliest dates
   ----------------------------------------------------------- */
t1dm_dx AS (
  SELECT person_id,
         MIN(condition_start_date) AS first_t1dm_dx_date
  FROM condition_occurrence
  WHERE condition_concept_id IN (SELECT concept_id FROM t1dm_dx_concepts)
  GROUP BY person_id
),

t2dm_dx AS (
  SELECT person_id,
         MIN(condition_start_date) AS first_t2dm_dx_date
  FROM condition_occurrence
  WHERE condition_concept_id IN (SELECT concept_id FROM t2dm_dx_concepts)
  GROUP BY person_id
),

/* Physician-entered T2DM Dx: limited to encounter & problem-list types
   CASE_C07  (PDF p 7) */
t2dm_physcn_dx AS (
  SELECT person_id,
         COUNT(DISTINCT condition_start_date) AS physcn_t2dm_dx_dates,
         MIN(condition_start_date)           AS first_physcn_t2dm_dx_date
  FROM condition_occurrence
  WHERE condition_concept_id IN (SELECT concept_id FROM t2dm_dx_concepts)
    AND condition_type_concept_id IN (38000183,42894222)  -- TECHNICAL DECISION
  GROUP BY person_id
),

dm_related_dx AS (
  SELECT person_id
  FROM condition_occurrence
  WHERE condition_concept_id IN (SELECT concept_id FROM dm_related_dx_concepts)
  GROUP BY person_id
),

t1dm_rx AS (
  SELECT person_id,
         MIN(drug_exposure_start_date) AS first_t1dm_rx_date
  FROM drug_exposure
  WHERE drug_concept_id IN (SELECT concept_id FROM t1dm_rx_ing)
  GROUP BY person_id
),

t2dm_rx AS (
  SELECT person_id,
         MIN(drug_exposure_start_date) AS first_t2dm_rx_date
  FROM drug_exposure
  WHERE drug_concept_id IN (SELECT concept_id FROM t2dm_rx_ing)
  GROUP BY person_id
),

dm_supplies_rx AS (
  SELECT person_id
  FROM drug_exposure
  WHERE drug_concept_id IN (SELECT concept_id FROM dm_supply_concepts)
  GROUP BY person_id
),

/* Glucose measurements – any */
glucose_measure AS (
  SELECT person_id,
         MIN(measurement_date) AS first_glu_date
  FROM measurement
  WHERE measurement_concept_id IN (SELECT concept_id FROM loinc_glucose_only)
  GROUP BY person_id
),

/* Abnormal lab for CASE (random >200, fasting ≥125, HbA1c ≥6.5)
   CASE_C06  (PDF p 2-3) */
abnl_lab_case AS (
  SELECT DISTINCT m.person_id,
         MIN(m.measurement_date) AS first_abnl_case_lab_date
  FROM measurement m
  JOIN loinc_glu_hba1c l ON m.measurement_concept_id = l.concept_id
  WHERE (
        /* Random glucose */
        l.concept_code IN ('2339-0','2345-7') AND m.value_as_number > 200
      OR /* Fasting glucose */
        l.concept_code = '1558-6'             AND m.value_as_number >= 125
      OR /* HbA1c */
        l.concept_code IN ('4548-4','17856-6','4549-2','17855-8') AND m.value_as_number >= 6.5
  )
  GROUP BY m.person_id
),

/* Abnormal lab for CONTROL thresholds (random >110, fasting ≥110, HbA1c ≥6.0)
   CTRL_C03  (PDF p 8) */
abnl_lab_ctrl AS (
  SELECT DISTINCT m.person_id
  FROM measurement m
  JOIN loinc_glu_hba1c l ON m.measurement_concept_id = l.concept_id
  WHERE (
        l.concept_code IN ('2339-0','2345-7') AND m.value_as_number > 110
     OR l.concept_code =  '1558-6'            AND m.value_as_number >= 110
     OR l.concept_code IN ('4548-4','17856-6','4549-2','17855-8') AND m.value_as_number >= 6.0
  )
),

/* Office visits – TECHNICAL DECISION: visit_concept_id = 9202 (Out-patient)
   CTRL_C04  (PDF p 11) */
office_visit_dates AS (
  SELECT person_id,
         visit_start_date::date AS visit_date
  FROM visit_occurrence
  WHERE visit_concept_id = 9202
),

office_visit_counts AS (
  SELECT person_id,
         COUNT(DISTINCT visit_date) AS office_visit_days
  FROM office_visit_dates
  GROUP BY person_id
),

/* Family history of DM – implemented via ICD-9 V18.0
   CTRL_C06  (PDF p 23) */
fam_hist_dm AS (
  SELECT DISTINCT person_id
  FROM condition_occurrence
  WHERE condition_concept_id IN (
        SELECT concept_id FROM concept
        WHERE vocabulary_id = 'ICD9CM'
          AND concept_code = 'V180'
          AND invalid_reason IS NULL
  )
),

/* ---------------------------------------------
   3. PERSON-LEVEL FLAGS PER CRITERION
   --------------------------------------------- */
criteria AS (
  SELECT p.person_id,

         /* CASE flags */
         NOT EXISTS (SELECT 1 FROM t1dm_dx t WHERE t.person_id = p.person_id)              AS CASE_C01,
         EXISTS (SELECT 1 FROM t2dm_dx t WHERE t.person_id = p.person_id)                  AS CASE_C02,
         EXISTS (SELECT 1 FROM t2dm_rx t WHERE t.person_id = p.person_id)                  AS CASE_C03,
         /* split C04 */
         EXISTS (SELECT 1 FROM t1dm_rx t WHERE t.person_id = p.person_id)                  AS CASE_C04A,
         NOT EXISTS (SELECT 1 FROM t1dm_rx t WHERE t.person_id = p.person_id)              AS CASE_C04B,
         EXISTS (SELECT 1 FROM abnl_lab_case t WHERE t.person_id = p.person_id)            AS CASE_C06,
         EXISTS (SELECT 1
                 FROM t2dm_physcn_dx t
                 WHERE t.person_id = p.person_id
                   AND t.physcn_t2dm_dx_dates >= 2)                                        AS CASE_C07,

         /* Dates needed for ordering / index */
         (SELECT first_t2dm_rx_date FROM t2dm_rx t WHERE t.person_id = p.person_id)        AS t2dm_rx_date,
         (SELECT first_t1dm_rx_date FROM t1dm_rx t WHERE t.person_id = p.person_id)        AS t1dm_rx_date,
         (SELECT first_abnl_case_lab_date FROM abnl_lab_case t WHERE t.person_id = p.person_id) AS abnl_case_lab_date,
         (SELECT first_t2dm_dx_date FROM t2dm_dx t WHERE t.person_id = p.person_id)        AS t2dm_dx_date,
         (SELECT first_physcn_t2dm_dx_date FROM t2dm_physcn_dx t WHERE t.person_id = p.person_id) AS phys_t2dm_dx_date,

         /* CONTROL flags */
         NOT EXISTS (SELECT 1 FROM dm_related_dx d WHERE d.person_id = p.person_id)        AS CTRL_C01,
         EXISTS (SELECT 1 FROM glucose_measure g WHERE g.person_id = p.person_id)          AS CTRL_C02,
         NOT EXISTS (SELECT 1 FROM abnl_lab_ctrl a WHERE a.person_id = p.person_id)        AS CTRL_C03,
         (SELECT office_visit_days FROM office_visit_counts v WHERE v.person_id = p.person_id) >= 2 AS CTRL_C04,
         NOT EXISTS (SELECT 1 FROM dm_supplies_rx s WHERE s.person_id = p.person_id)       AS CTRL_C05,
         NOT EXISTS (SELECT 1 FROM fam_hist_dm f WHERE f.person_id = p.person_id)          AS CTRL_C06,

         /* Date for control index (earliest glucose measurement) */
         (SELECT first_glu_date FROM glucose_measure g WHERE g.person_id = p.person_id)    AS first_glu_meas_date,

         /* Office visit earliest date */
         (SELECT MIN(visit_date) FROM office_visit_dates ov WHERE ov.person_id = p.person_id) AS first_office_visit_date

  FROM person p
)

/* ---------------------------------------------
   4. CASE PATHS (P1-P5)
   --------------------------------------------- */
, path1 AS (
  SELECT person_id,
         LEAST(t2dm_rx_date, t1dm_rx_date, t2dm_dx_date) AS index_date
  FROM criteria
  WHERE CASE_C01
    AND CASE_C02
    AND CASE_C03
    AND CASE_C04A
    AND t2dm_rx_date < t1dm_rx_date          -- CASE_C05
)

, path2 AS (
  SELECT person_id,
         LEAST(t2dm_rx_date, t2dm_dx_date) AS index_date
  FROM criteria
  WHERE CASE_C01
    AND CASE_C02
    AND CASE_C03
    AND CASE_C04B          -- no T1DM Rx
)

, path3 AS (
  SELECT person_id,
         LEAST(abnl_case_lab_date, t2dm_dx_date) AS index_date
  FROM criteria
  WHERE CASE_C01
    AND CASE_C02
    AND NOT CASE_C03        -- no T2DM Rx
    AND CASE_C04B           -- no T1DM Rx
    AND CASE_C06
)

, path4 AS (
  SELECT person_id,
         LEAST(abnl_case_lab_date, t2dm_rx_date) AS index_date
  FROM criteria
  WHERE CASE_C01
    AND NOT CASE_C02       -- no T2DM Dx
    AND CASE_C03
    AND CASE_C06
)

, path5 AS (
  SELECT person_id,
         LEAST(phys_t2dm_dx_date, t1dm_rx_date) AS index_date
  FROM criteria
  WHERE CASE_C01
    AND CASE_C02
    AND CASE_C04A          -- T1DM Rx present
    AND NOT CASE_C03       -- no T2DM Rx
    AND CASE_C07
)

/* ---------------------------------------------
   5. CONTROL COHORT
   --------------------------------------------- */
, controls AS (
  SELECT person_id,
         first_glu_meas_date AS index_date
  FROM criteria
  WHERE CTRL_C01
    AND CTRL_C02
    AND CTRL_C03
    AND CTRL_C04
    AND CTRL_C05
    AND CTRL_C06
)

/* ---------------------------------------------
   6. UNION ALL COHORTS & DEDUPLICATE
   --------------------------------------------- */
, all_cases AS (
  SELECT person_id, index_date, 1 AS path_priority FROM path1
  UNION ALL
  SELECT person_id, index_date, 2 FROM path2
  UNION ALL
  SELECT person_id, index_date, 3 FROM path3
  UNION ALL
  SELECT person_id, index_date, 4 FROM path4
  UNION ALL
  SELECT person_id, index_date, 5 FROM path5
)

/* Deduplicate: keep earliest path priority per person */
, dedup_cases AS (
  SELECT DISTINCT ON (person_id)
         person_id,
         index_date,
         'CASE' AS cohort_type
  FROM all_cases
  ORDER BY person_id, path_priority
)

/* Exclude case persons from controls to maintain exclusivity */
, final_controls AS (
  SELECT c.person_id,
         c.index_date,
         'CONTROL' AS cohort_type
  FROM controls c
  LEFT JOIN dedup_cases dc
         ON dc.person_id = c.person_id
  WHERE dc.person_id IS NULL
)

/* ---------------------------------------------
   7. FINAL RESULT
   --------------------------------------------- */
SELECT
    person_id,
    cohort_type,
    index_date                                       AS index_date,
    index_date                                       AS cohort_start_date,   -- not specified in PDF
    index_date                                       AS cohort_end_date      -- not specified in PDF
FROM dedup_cases

UNION ALL

SELECT
    person_id,
    cohort_type,
    index_date,
    index_date,
    index_date
FROM final_controls
ORDER BY person_id, cohort_type;