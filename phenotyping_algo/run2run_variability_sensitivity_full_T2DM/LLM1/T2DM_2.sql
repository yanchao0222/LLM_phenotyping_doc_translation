/*****************************************************************************************
  TYPE-2 DIABETES MELLITUS  –  CASE, CONTROL, UNKNOWN
  Executable on OMOP-CDM v5.3+        (no tables created, single SELECT statement)
  -------------------------------------------------------------------------
  CODE & THRESHOLD SOURCES
    • ICD-9 250.x1 / 250.x3           – T1DM diagnoses
    • ICD-9 250.x0 / 250.x2           – T2DM diagnoses  (excludes 250.10, 250.12)
    • Broader diabetes ICD-9 set      – differential for controls
    • RxNorm CUIs                     – diabetes medications & supplies
    • LOINC codes                     – fasting / random glucose, HbA1c
    • Abnormal lab cut-offs           – 200 / 125 / 6.5 (case)  and 110 / 110 / 6.0 (control)
*****************************************************************************************/

WITH
/* ------------------------------------------------------------------
   CONCEPT SETS  (lists are codes only, later resolved to concept_id)
------------------------------------------------------------------ */
t1dm_dx_codes AS (SELECT concept_id FROM concept
                  WHERE vocabulary_id='ICD9CM'
                    AND concept_code IN ('250.x1','250.x3')),

t2dm_dx_codes AS (SELECT concept_id FROM concept
                  WHERE vocabulary_id='ICD9CM'
                    AND concept_code IN ('250.x0','250.x2')
                    AND concept_code NOT IN ('250.10','250.12')),

dm_broad_dx AS (SELECT concept_id FROM concept
                WHERE vocabulary_id='ICD9CM'
                  AND concept_code IN ('250.xx','790.21','790.22','790.2','790.29',
                                       '648.8x','648.0x','791.5','277.7','V18.0','V77.1')),

t1dm_rx_codes AS (SELECT concept_id FROM concept
                  WHERE vocabulary_id='RxNorm'
                    AND concept_code IN (139825,274783,314684,352385,400008,
                                         51428,5856,86009,139953)),

t2dm_rx_codes AS (SELECT concept_id FROM concept
                  WHERE vocabulary_id='RxNorm'
                    AND concept_code IN (173,10633,2404,4821,217360,4815,25789,
                                         73044,274332,6809,84108,33738,72610,
                                         16681,30009,593411,60548)),

dm_supply_codes AS (SELECT concept_id FROM concept
                    WHERE vocabulary_id IN ('RxNorm','NDDF','VANDF')
                      AND concept_code IN (126958,412956,412959,637321,668291,668370,
                                           686655,692383,748611,880998,881056,751128,
                                           847187,847191,847197,847203,847207,847211,
                                           847230,847239,847252,847256,847259,847263,
                                           847278,847416,847417,806905,806903,408119)),

fast_gluc_loinc AS (SELECT concept_id FROM concept
                    WHERE vocabulary_id='LOINC' AND concept_code='1558-6'),
rand_gluc_loinc AS (SELECT concept_id FROM concept
                    WHERE vocabulary_id='LOINC' AND concept_code IN ('2339-0','2345-7')),
hba1c_loinc     AS (SELECT concept_id FROM concept
                    WHERE vocabulary_id='LOINC' AND concept_code IN ('4548-4','17856-6',
                                                                     '4549-2','17855-8')),

/* ------------------------------------------------------------------
   PATIENT-LEVEL FEATURES
------------------------------------------------------------------ */
dx AS (
  SELECT  person_id,
          COUNT(DISTINCT CASE WHEN condition_concept_id IN (SELECT concept_id FROM t1dm_dx_codes)
                              THEN condition_start_date END)                    AS t1dx_dates,
          COUNT(DISTINCT CASE WHEN condition_concept_id IN (SELECT concept_id FROM t2dm_dx_codes)
                              THEN condition_start_date END)                    AS t2dx_dates,
          COUNT(DISTINCT CASE WHEN condition_concept_id IN (SELECT concept_id FROM dm_broad_dx)
                              THEN condition_start_date END)                    AS dm_broad_dates,
          /* Physician-entered T2DM DX: encounter or problem-list */
          COUNT(DISTINCT CASE WHEN condition_concept_id IN (SELECT concept_id FROM t2dm_dx_codes)
                                AND condition_type_concept_id IN (38000275,38000280)
                              THEN condition_start_date END)                    AS t2dx_phys_dates
  FROM    condition_occurrence
  GROUP   BY person_id
),

rx AS (
  SELECT  person_id,
          MIN(CASE WHEN drug_concept_id IN (SELECT concept_id FROM t1dm_rx_codes)
                   THEN drug_exposure_start_date END)                           AS first_t1rx,
          MIN(CASE WHEN drug_concept_id IN (SELECT concept_id FROM t2dm_rx_codes)
                   THEN drug_exposure_start_date END)                           AS first_t2rx,
          COUNT(DISTINCT CASE WHEN drug_concept_id IN (
                               SELECT concept_id FROM t1dm_rx_codes
                               UNION ALL
                               SELECT concept_id FROM t2dm_rx_codes
                               UNION ALL
                               SELECT concept_id FROM dm_supply_codes)
                   THEN drug_exposure_start_date END)                           AS dm_rx_dates
  FROM    drug_exposure
  GROUP   BY person_id
),

labs AS (
  SELECT  person_id,
          MAX(CASE WHEN measurement_concept_id IN (SELECT concept_id FROM fast_gluc_loinc)
                   THEN value_as_number END)                                    AS max_fast_gluc,
          MAX(CASE WHEN measurement_concept_id IN (SELECT concept_id FROM rand_gluc_loinc)
                   THEN value_as_number END)                                    AS max_rand_gluc,
          MAX(CASE WHEN measurement_concept_id IN (SELECT concept_id FROM hba1c_loinc)
                   THEN value_as_number END)                                    AS max_hba1c
  FROM    measurement
  GROUP   BY person_id
),

abn_flags AS (
  SELECT  person_id,
          /* Case abnormal-lab definition */
          CASE WHEN max_rand_gluc > 200
                 OR max_fast_gluc >= 125
                 OR max_hba1c   >= 6.5 THEN 1 ELSE 0 END                        AS abn_case,
          /* Control abnormal-lab definition */
          CASE WHEN max_rand_gluc > 110
                 OR max_fast_gluc >= 110
                 OR max_hba1c   >= 6.0 THEN 1 ELSE 0 END                        AS abn_ctrl,
          /* At least one glucose measurement? */
          CASE WHEN max_rand_gluc IS NOT NULL
                 OR max_fast_gluc IS NOT NULL THEN 1 ELSE 0 END                 AS has_gluc
  FROM    labs
),

visits AS (
  SELECT  person_id,
          COUNT(DISTINCT visit_start_date)                                      AS office_visits
  FROM    visit_occurrence
  WHERE   visit_concept_id = 9202   -- outpatient clinic visit
  GROUP   BY person_id
),

fam_hist AS (
  SELECT  person_id, 1 AS fam_dm
  FROM    observation
  WHERE   value_as_concept_id IN (SELECT concept_id
                                  FROM concept
                                  WHERE concept_code IN ('4167217','4167218'))  -- family hx codes
  GROUP   BY person_id
),

/* ------------------------------------------------------------------
   COLLATE FEATURES PER PERSON
------------------------------------------------------------------ */
pt AS (
  SELECT  p.person_id,
          COALESCE(d.t1dx_dates,0)        AS t1dx_dates,
          COALESCE(d.t2dx_dates,0)        AS t2dx_dates,
          COALESCE(d.t2dx_phys_dates,0)   AS t2dx_phys_dates,
          r.first_t1rx,
          r.first_t2rx,
          COALESCE(a.abn_case,0)          AS abn_case,
          COALESCE(a.abn_ctrl,0)          AS abn_ctrl,
          COALESCE(a.has_gluc,0)          AS has_gluc,
          COALESCE(r.dm_rx_dates,0)       AS dm_rx_dates,
          COALESCE(v.office_visits,0)     AS office_visits,
          COALESCE(f.fam_dm,0)            AS fam_dm,
          COALESCE(d.dm_broad_dates,0)    AS dm_broad_dates
  FROM    person p
  LEFT JOIN dx       d ON d.person_id = p.person_id
  LEFT JOIN rx       r ON r.person_id = p.person_id
  LEFT JOIN abn_flags a ON a.person_id = p.person_id
  LEFT JOIN visits   v ON v.person_id = p.person_id
  LEFT JOIN fam_hist f ON f.person_id = p.person_id
)

/* ------------------------------------------------------------------
   FINAL CASE / CONTROL ASSIGNMENT
------------------------------------------------------------------ */
SELECT
    person_id,

    /* --------------- CASE LOGIC (5 mutually-exclusive paths) --------------- */
    CASE
      WHEN t1dx_dates = 0
       AND t2dx_dates > 0
       AND first_t1rx IS NOT NULL
       AND first_t2rx IS NOT NULL
       AND first_t2rx < first_t1rx                                            THEN 'CASE'        -- Path 1

      WHEN t1dx_dates = 0
       AND t2dx_dates > 0
       AND first_t1rx IS NULL
       AND first_t2rx IS NOT NULL                                             THEN 'CASE'        -- Path 2

      WHEN t1dx_dates = 0
       AND t2dx_dates > 0
       AND first_t1rx IS NULL
       AND first_t2rx IS NULL
       AND abn_case = 1                                                       THEN 'CASE'        -- Path 3

      WHEN t1dx_dates = 0
       AND t2dx_dates = 0
       AND first_t2rx IS NOT NULL
       AND abn_case = 1                                                       THEN 'CASE'        -- Path 4

      WHEN t1dx_dates = 0
       AND t2dx_dates > 0
       AND first_t1rx IS NOT NULL
       AND first_t2rx IS NULL
       AND t2dx_phys_dates >= 2                                               THEN 'CASE'        -- Path 5

    /* --------------- CONTROL LOGIC (all conditions required) --------------- */
      WHEN dm_rx_dates = 0
       AND t1dx_dates = 0
       AND t2dx_dates = 0
       AND dm_broad_dates = 0
       AND has_gluc = 1
       AND abn_ctrl = 0
       AND office_visits >= 2
       AND fam_dm = 0                                                         THEN 'CONTROL'

    /* --------------- OTHERWISE --------------------------------------------- */
      ELSE 'UNKNOWN'
    END  AS t2dm_status

FROM pt;