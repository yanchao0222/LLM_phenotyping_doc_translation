/*=====================================================================
  OMOP CDM 5.x  |  TYPE 2 DIABETES MELLITUS  CASE / CONTROL PHENOTYPE
  --------------------------------------------------------------------
  • Five mutually‑exclusive decision paths classify CASES.
  • One exclusionary path produces CONTROLS.
  • Remaining individuals are labeled UNKNOWN.
  • Concept sets expand via concept_ancestor to include descendants.
=====================================================================*/

WITH
/*------------------------------------------------------------------*
 | 1. DIAGNOSIS CONCEPT SETS (ICD‑9‑CM)                             |
 *------------------------------------------------------------------*/
t1dm_dx AS (  /* 250.x1 / 250.x3 -----------------------------------*/
  SELECT DISTINCT ca.descendant_concept_id
  FROM   concept            c
  JOIN   concept_ancestor   ca ON ca.ancestor_concept_id = c.concept_id
  WHERE  c.vocabulary_id = 'ICD9CM'
    AND  c.concept_code IN (
      '250.01','250.03','250.11','250.13','250.21','250.23',
      '250.31','250.33','250.41','250.43','250.51','250.53',
      '250.61','250.63','250.71','250.73','250.81','250.83',
      '250.91','250.93'
    )
),
t2dm_dx AS (  /* 250.x0 / 250.x2  (‑ 250.10, 250.12) --------------*/
  SELECT DISTINCT ca.descendant_concept_id
  FROM   concept            c
  JOIN   concept_ancestor   ca ON ca.ancestor_concept_id = c.concept_id
  WHERE  c.vocabulary_id = 'ICD9CM'
    AND  c.concept_code IN (
      '250.00','250.02','250.20','250.22','250.30','250.32',
      '250.40','250.42','250.50','250.52','250.60','250.62',
      '250.70','250.72','250.80','250.82','250.90','250.92'
    )
),
any_dm_dx AS ( /* All DM‑related diagnoses ------------------------*/
  SELECT DISTINCT ca.descendant_concept_id
  FROM   concept            c
  JOIN   concept_ancestor   ca ON ca.ancestor_concept_id = c.concept_id
  WHERE  c.vocabulary_id = 'ICD9CM'
    AND (
      c.concept_code LIKE '250.%'
      OR c.concept_code IN ('790.21','790.22','790.2','790.29',
                            '791.5','277.7','V18.0','V77.1')
      OR c.concept_code LIKE '648.8%'
      OR c.concept_code LIKE '648.0%'
    )
),

/*------------------------------------------------------------------*
 | 2. DRUG & SUPPLY CONCEPT SETS (RxNorm / NDDF / VANDF)            |
 *------------------------------------------------------------------*/
t1dm_rx AS ( /* Insulins & pramlintide -----------------------------*/
  SELECT DISTINCT ca.descendant_concept_id
  FROM   concept            c
  JOIN   concept_ancestor   ca ON ca.ancestor_concept_id = c.concept_id
  WHERE  c.vocabulary_id = 'RxNorm'
    AND  c.concept_code IN (
      '139825','274783','314684','352385','400008',
      '51428','5856','86009','139953'
    )
),
t2dm_rx AS ( /* Non‑insulin antihyperglycemics --------------------*/
  SELECT DISTINCT ca.descendant_concept_id
  FROM   concept            c
  JOIN   concept_ancestor   ca ON ca.ancestor_concept_id = c.concept_id
  WHERE  c.vocabulary_id = 'RxNorm'
    AND  c.concept_code IN (
      '173','10633','2404','4821','217360','4815','25789',
      '73044','274332','6809','84108','33738','72610',
      '16681','30009','593411','60548'
    )
),
dm_supplies AS ( /* Meters, strips, syringes, sensors --------------*/
  SELECT DISTINCT ca.descendant_concept_id
  FROM   concept            c
  JOIN   concept_ancestor   ca ON ca.ancestor_concept_id = c.concept_id
  WHERE  c.vocabulary_id IN ('NDDF','VANDF','RxNorm')
    AND  c.concept_code IN (
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
fast_gluc AS (SELECT concept_id FROM concept WHERE vocabulary_id = 'LOINC' AND concept_code = '1558-6'),
rand_gluc AS (SELECT concept_id FROM concept WHERE vocabulary_id = 'LOINC' AND concept_code IN ('2339-0','2345-7')),
hba1c     AS (SELECT concept_id FROM concept WHERE vocabulary_id = 'LOINC' AND concept_code IN ('4548-4','4549-2','17855-8','17856-6')),

/*------------------------------------------------------------------*
 | 4. PERSON‑LEVEL FEATURES                                         |
 *------------------------------------------------------------------*/
dx AS (
  SELECT co.person_id,
         COUNT(DISTINCT co.condition_start_date)
           FILTER (WHERE co.condition_concept_id IN (SELECT descendant_concept_id FROM t1dm_dx))
           AS t1dx_cnt,
         COUNT(DISTINCT co.condition_start_date)
           FILTER (WHERE co.condition_concept_id IN (SELECT descendant_concept_id FROM t2dm_dx))
           AS t2dx_cnt,
         COUNT(DISTINCT co.condition_start_date)
           FILTER (WHERE co.condition_concept_id IN (SELECT descendant_concept_id FROM any_dm_dx))
           AS anydx_cnt,
         /* ≥2 physician‑documented outpatient / inpatient T2DM diagnoses */
         COUNT(DISTINCT co.condition_start_date) FILTER (
           WHERE co.condition_concept_id IN (SELECT descendant_concept_id FROM t2dm_dx)
             AND co.provider_id IS NOT NULL
             AND EXISTS (
               SELECT 1
               FROM   visit_occurrence vo
               WHERE  vo.visit_occurrence_id = co.visit_occurrence_id
                 AND  vo.visit_concept_id    IN (9202,9203)
             )
         ) AS t2_phys_cnt
  FROM   condition_occurrence co
  GROUP  BY co.person_id
),
rx AS (
  SELECT de.person_id,
         MIN(de.drug_exposure_start_date)
           FILTER (WHERE de.drug_concept_id IN (SELECT descendant_concept_id FROM t1dm_rx))
           AS first_t1_rx_dt,
         MIN(de.drug_exposure_start_date)
           FILTER (WHERE de.drug_concept_id IN (SELECT descendant_concept_id FROM t2dm_rx))
           AS first_t2_rx_dt,
         COUNT(DISTINCT de.drug_exposure_start_date)
           FILTER (WHERE de.drug_concept_id IN (
                    SELECT descendant_concept_id FROM t1dm_rx
                    UNION ALL
                    SELECT descendant_concept_id FROM t2dm_rx
                    UNION ALL
                    SELECT descendant_concept_id FROM dm_supplies
                  ))
           AS dm_rx_sup_cnt
  FROM   drug_exposure de
  GROUP  BY de.person_id
),
lab AS (
  SELECT m.person_id,
         MAX(m.value_as_number)
           FILTER (WHERE m.measurement_concept_id IN (SELECT concept_id FROM fast_gluc))
           AS max_fast_gluc,
         MAX(m.value_as_number)
           FILTER (WHERE m.measurement_concept_id IN (SELECT concept_id FROM rand_gluc))
           AS max_rand_gluc,
         MAX(m.value_as_number)
           FILTER (WHERE m.measurement_concept_id IN (SELECT concept_id FROM hba1c))
           AS max_hba1c,
         COUNT(*) FILTER (WHERE m.measurement_concept_id IN (
                           SELECT concept_id FROM fast_gluc
                           UNION ALL
                           SELECT concept_id FROM rand_gluc))
           AS gluc_lab_cnt
  FROM   measurement m
  GROUP  BY m.person_id
),
enc AS (
  SELECT person_id,
         COUNT(DISTINCT visit_start_date)
           FILTER (WHERE visit_concept_id = 9202)  AS office_visit_cnt
  FROM   visit_occurrence
  GROUP  BY person_id
),
fh AS (
  SELECT DISTINCT co.person_id, 1 AS has_fh
  FROM   condition_occurrence co
  WHERE  co.condition_source_value = 'V18.0'  /* family history of DM */
)

/*------------------------------------------------------------------*
 | 5. COHORT CLASSIFICATION                                         |
 *------------------------------------------------------------------*/
SELECT p.person_id,

       CASE
         /*================== CASE PATH 1 ===================*/
         WHEN dx.t1dx_cnt = 0
          AND dx.t2dx_cnt > 0
          AND rx.first_t2_rx_dt IS NOT NULL
          AND rx.first_t1_rx_dt IS NOT NULL
          AND rx.first_t2_rx_dt < rx.first_t1_rx_dt                     THEN 'CASE'

         /*================== CASE PATH 2 ===================*/
         WHEN dx.t1dx_cnt = 0
          AND dx.t2dx_cnt > 0
          AND rx.first_t1_rx_dt IS NULL
          AND rx.first_t2_rx_dt IS NOT NULL                             THEN 'CASE'

         /*================== CASE PATH 3 ===================*/
         WHEN dx.t1dx_cnt = 0
          AND dx.t2dx_cnt > 0
          AND rx.first_t1_rx_dt IS NULL
          AND rx.first_t2_rx_dt IS NULL
          AND (
               lab.max_rand_gluc >  200
            OR lab.max_fast_gluc >= 125
            OR lab.max_hba1c     >= 6.5
          )                                                             THEN 'CASE'

         /*================== CASE PATH 4 ===================*/
         WHEN dx.t1dx_cnt = 0
          AND dx.t2dx_cnt = 0
          AND rx.first_t2_rx_dt IS NOT NULL
          AND (
               lab.max_rand_gluc >  200
            OR lab.max_fast_gluc >= 125
            OR lab.max_hba1c     >= 6.5
          )                                                             THEN 'CASE'

         /*================== CASE PATH 5 ===================*/
         WHEN dx.t1dx_cnt = 0
          AND dx.t2dx_cnt > 0
          AND rx.first_t1_rx_dt IS NOT NULL
          AND rx.first_t2_rx_dt IS NULL
          AND dx.t2_phys_cnt   >= 2                                     THEN 'CASE'

         /*================= CONTROL PATH ===================*/
         WHEN dx.anydx_cnt   = 0
          AND lab.gluc_lab_cnt > 0
          AND COALESCE(lab.max_rand_gluc, 0) < 110
          AND COALESCE(lab.max_fast_gluc, 0) < 110
          AND COALESCE(lab.max_hba1c,   0) < 6.0
          AND enc.office_visit_cnt >= 2
          AND rx.dm_rx_sup_cnt    = 0
          AND COALESCE(fh.has_fh,0) = 0                                  THEN 'CONTROL'

         /*=================== OTHERWISE ====================*/
         ELSE 'UNKNOWN'
       END AS t2dm_status

FROM   person p
LEFT   JOIN dx  ON dx.person_id  = p.person_id
LEFT   JOIN rx  ON rx.person_id  = p.person_id
LEFT   JOIN lab ON lab.person_id = p.person_id
LEFT   JOIN enc ON enc.person_id = p.person_id
LEFT   JOIN fh  ON fh.person_id  = p.person_id
;
