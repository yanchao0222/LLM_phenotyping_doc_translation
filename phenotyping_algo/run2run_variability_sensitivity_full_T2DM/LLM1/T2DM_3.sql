/*====================================================================
  Northwestern University T2DM Phenotype – OMOP-CDM Implementation
  ------------------------------------------------------------------
  • Case logic: five mutually-exclusive paths
  • Control logic: one path
  • All concept sets use codes copied verbatim from the specification
====================================================================*/
WITH
/*--------------------------------------------------------------------
  1. CONCEPT SETS  (codes only – no names)
--------------------------------------------------------------------*/
t1dm_dx AS (      -- 250.x1, 250.x3
  SELECT concept_id
  FROM   concept
  WHERE  vocabulary_id = 'ICD9CM'
    AND  concept_code IN ('250.x1','250.x3')
),
t2dm_dx AS (      -- 250.x0, 250.x2   (exclude 250.10 & 250.12)
  SELECT concept_id
  FROM   concept
  WHERE  vocabulary_id = 'ICD9CM'
    AND  concept_code IN ('250.x0','250.x2')
      AND concept_code NOT IN ('250.10','250.12')
),
dm_dx AS (        -- All diabetes-related DX (Table 9)
  SELECT concept_id
  FROM   concept
  WHERE  vocabulary_id = 'ICD9CM'
    AND (concept_code LIKE '250.%'
         OR concept_code IN ('790.21','790.22','790.2','790.29',
                             '648.8x','648.0x','791.5','277.7',
                             'V18.0','V77.1'))
),
t1dm_rx AS (      -- Insulin & pramlintide (RxNorm CUIs)
  SELECT concept_id
  FROM   concept
  WHERE  vocabulary_id = 'RxNorm'
    AND  concept_code IN ('139825','274783','314684','352385','400008',
                          '51428','5856','86009','139953')
),
t2dm_rx AS (      -- Non-insulin T2DM meds (RxNorm CUIs)
  SELECT concept_id
  FROM   concept
  WHERE  vocabulary_id = 'RxNorm'
    AND  concept_code IN ('173','10633','2404','4821','217360','4815','25789',
                          '73044','274332','6809','84108','33738','72610',
                          '16681','30009','593411','60548')
),
dm_supplies AS (  -- Meters, syringes … (RxNorm, NDDF, VANDF)
  SELECT concept_id
  FROM   concept
  WHERE  (vocabulary_id = 'RxNorm' AND concept_code IN
          ('847187','847191','847197','847203','847207','847211',
           '847230','847239','847252','847256','847259','847263',
           '847278','847416','847417'))
      OR (vocabulary_id = 'NDDF'   AND concept_code IN
          ('126958','412956','412959','637321','668291','668370',
           '686655','692383','748611','880998','881056','806905',
           '806903','408119'))
      OR (vocabulary_id = 'VANDF'  AND concept_code = '751128')
),
lab_codes AS (    -- Fasting/Random glucose & HbA1c (LOINC)
  SELECT concept_id, concept_code
  FROM   concept
  WHERE  vocabulary_id = 'LOINC'
    AND  concept_code IN ('1558-6','2339-0','2345-7',
                          '4548-4','17856-6','4549-2','17855-8')
),

/*--------------------------------------------------------------------
  2. PATIENT-LEVEL AGGREGATES
--------------------------------------------------------------------*/
dx_aggr AS (
  SELECT person_id,
         SUM(CASE WHEN condition_concept_id IN (SELECT concept_id FROM t1dm_dx) THEN 1 END) AS t1_cnt,
         SUM(CASE WHEN condition_concept_id IN (SELECT concept_id FROM t2dm_dx) THEN 1 END) AS t2_cnt,
         SUM(CASE WHEN condition_concept_id IN (SELECT concept_id FROM dm_dx)  THEN 1 END) AS dm_cnt,
         SUM(CASE WHEN condition_concept_id IN (SELECT concept_id FROM t2dm_dx)
                   AND condition_type_concept_id IN (38000275,38000257) /* encounter / problem-list */
              THEN 1 END) AS t2_phys_cnt
  FROM   condition_occurrence
  GROUP  BY person_id
),
rx_aggr AS (
  SELECT person_id,
         MIN(CASE WHEN drug_concept_id IN (SELECT concept_id FROM t1dm_rx) THEN drug_exposure_start_date END) AS t1_rx_dt,
         MIN(CASE WHEN drug_concept_id IN (SELECT concept_id FROM t2dm_rx) THEN drug_exposure_start_date END) AS t2_rx_dt,
         COUNT(DISTINCT CASE WHEN drug_concept_id IN (
               SELECT concept_id FROM t1dm_rx
               UNION ALL SELECT concept_id FROM t2dm_rx
               UNION ALL SELECT concept_id FROM dm_supplies)
               THEN drug_exposure_start_date END) AS dm_rx_cnt
  FROM   drug_exposure
  GROUP  BY person_id
),
lab_aggr AS (
  SELECT  person_id,
          MAX(CASE WHEN concept_code = '1558-6'                           THEN value_as_number END) AS fast_gluc_max,
          MAX(CASE WHEN concept_code IN ('2339-0','2345-7')              THEN value_as_number END) AS rndm_gluc_max,
          MAX(CASE WHEN concept_code IN ('4548-4','17856-6','4549-2',
                                         '17855-8')                      THEN value_as_number END) AS hba1c_max
  FROM    measurement m
  JOIN    lab_codes c ON m.measurement_concept_id = c.concept_id
  GROUP   BY person_id
),
visit_aggr AS (
  SELECT person_id,
         COUNT(DISTINCT visit_start_date) AS visit_cnt    -- out-patient visits
  FROM   visit_occurrence
  WHERE  visit_concept_id = 9202          -- OMOP: “Outpatient Visit”
  GROUP  BY person_id
),
fam_hist AS (
  SELECT DISTINCT person_id             -- Observation 4053107
  FROM   observation
  WHERE  observation_concept_id = 4053107
),

/*--------------------------------------------------------------------
  3. MERGE AGGREGATES & DERIVE LAB FLAGS
--------------------------------------------------------------------*/
patients AS (
SELECT  p.person_id,
        dx_aggr.*, rx_aggr.*, lab_aggr.*,
        visit_aggr.visit_cnt,
        CASE WHEN fam_hist.person_id IS NULL THEN 0 ELSE 1 END AS fam_hist_dm,

        /* Abnormal for CASE */
        CASE WHEN rndm_gluc_max  > 200
               OR fast_gluc_max >= 125
               OR hba1c_max     >= 6.5 THEN 1 ELSE 0 END AS abn_case,

        /* Abnormal for CONTROL */
        CASE WHEN rndm_gluc_max  > 110
               OR fast_gluc_max >= 110
               OR hba1c_max     >= 6.0 THEN 1 ELSE 0 END AS abn_ctrl
FROM    person p
LEFT    JOIN dx_aggr    ON p.person_id = dx_aggr.person_id
LEFT    JOIN rx_aggr    ON p.person_id = rx_aggr.person_id
LEFT    JOIN lab_aggr   ON p.person_id = lab_aggr.person_id
LEFT    JOIN visit_aggr ON p.person_id = visit_aggr.person_id
LEFT    JOIN fam_hist   ON p.person_id = fam_hist.person_id
)

/*--------------------------------------------------------------------
  4. FINAL CLASSIFICATION
--------------------------------------------------------------------*/
SELECT person_id,

       /* ---------- CASE PATH 1 ---------- */
       CASE
         WHEN t1_cnt = 0
          AND t2_cnt > 0
          AND t1_rx_dt IS NOT NULL
          AND t2_rx_dt IS NOT NULL
          AND t2_rx_dt <  t1_rx_dt                          THEN 'T2DM_CASE_1'

       /* ---------- CASE PATH 2 ---------- */
         WHEN t1_cnt = 0
          AND t2_cnt > 0
          AND t1_rx_dt IS NULL
          AND t2_rx_dt IS NOT NULL                          THEN 'T2DM_CASE_2'

       /* ---------- CASE PATH 3 ---------- */
         WHEN t1_cnt = 0
          AND t2_cnt > 0
          AND t1_rx_dt IS NULL
          AND t2_rx_dt IS NULL
          AND abn_case = 1                                  THEN 'T2DM_CASE_3'

       /* ---------- CASE PATH 4 ---------- */
         WHEN t1_cnt = 0
          AND t2_cnt = 0
          AND t2_rx_dt IS NOT NULL
          AND abn_case = 1                                  THEN 'T2DM_CASE_4'

       /* ---------- CASE PATH 5 ---------- */
         WHEN t1_cnt = 0
          AND t2_cnt > 0
          AND t1_rx_dt IS NOT NULL
          AND t2_rx_dt IS NULL
          AND t2_phys_cnt >= 2                              THEN 'T2DM_CASE_5'

       /* ---------- CONTROL PATH ---------- */
         WHEN dm_cnt      = 0
          AND (fast_gluc_max IS NOT NULL         -- ≥1 glucose result
               OR rndm_gluc_max IS NOT NULL)
          AND abn_ctrl    = 0
          AND visit_cnt   >= 2
          AND dm_rx_cnt   = 0
          AND fam_hist_dm = 0                               THEN 'T2DM_CONTROL'

       /* ---------- ELSE ---------- */
         ELSE 'UNKNOWN'
       END AS t2dm_status
FROM   patients;