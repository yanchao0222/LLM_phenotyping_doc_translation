/* =========================================================
   TYPE 2 DIABETES MELLITUS (T2DM) PHENOTYPE
   CASE–CONTROL ALGORITHM   —   READY TO RUN
   ========================================================= */

WITH
/* ---------- 1.  CODE LISTS (ICD-9, RxNorm, NDDF, VANDF, LOINC) ---------- */
t1dm_dx AS (
    SELECT '250.x1' AS code UNION ALL SELECT '250.x3'
),
t2dm_dx AS (
    SELECT '250.x0' UNION ALL SELECT '250.x2'
),
t2dm_dx_excl AS (
    SELECT '250.10' UNION ALL SELECT '250.12'
),
dm_related_dx AS (       -- broader DM list for CONTROL exclusion
    SELECT '250.xx' UNION ALL SELECT '790.21' UNION ALL SELECT '790.22'
    UNION ALL SELECT '790.2' UNION ALL SELECT '790.29'
    UNION ALL SELECT '648.8x' UNION ALL SELECT '648.0x'
    UNION ALL SELECT '791.5'  UNION ALL SELECT '277.7'
    UNION ALL SELECT 'V18.0'  UNION ALL SELECT 'V77.1'
),
t1dm_rx AS (
    SELECT '139825' UNION ALL SELECT '274783' UNION ALL SELECT '314684'
    UNION ALL SELECT '352385' UNION ALL SELECT '400008' UNION ALL SELECT '51428'
    UNION ALL SELECT '5856'   UNION ALL SELECT '86009'  UNION ALL SELECT '139953'
),
t2dm_rx AS (
    SELECT '173' UNION ALL  SELECT '10633' UNION ALL SELECT '2404' UNION ALL SELECT '4821'
    UNION ALL SELECT '217360' UNION ALL SELECT '4815' UNION ALL SELECT '25789'
    UNION ALL SELECT '73044' UNION ALL SELECT '274332' UNION ALL SELECT '6809'
    UNION ALL SELECT '84108' UNION ALL SELECT '33738' UNION ALL SELECT '72610'
    UNION ALL SELECT '16681' UNION ALL SELECT '30009' UNION ALL SELECT '593411'
    UNION ALL SELECT '60548'
),
dm_supplies AS (
    /* RxNorm insulin-syringe & meter CUIs */
    SELECT '847187' UNION ALL SELECT '847191' UNION ALL SELECT '847197' UNION ALL SELECT '847203'
    UNION ALL SELECT '847207' UNION ALL SELECT '847211' UNION ALL SELECT '847230' UNION ALL SELECT '847239'
    UNION ALL SELECT '847252' UNION ALL SELECT '847256' UNION ALL SELECT '847259' UNION ALL SELECT '847263'
    UNION ALL SELECT '847278' UNION ALL SELECT '847416' UNION ALL SELECT '847417'
    /* NDDF glucose-meter CUIs */
    UNION ALL SELECT '126958' UNION ALL SELECT '412956' UNION ALL SELECT '412959' UNION ALL SELECT '637321'
    UNION ALL SELECT '668291' UNION ALL SELECT '668370' UNION ALL SELECT '686655' UNION ALL SELECT '692383'
    UNION ALL SELECT '748611' UNION ALL SELECT '880998' UNION ALL SELECT '881056'
    UNION ALL SELECT '806905' UNION ALL SELECT '806903' UNION ALL SELECT '408119'
    /* VANDF */
    UNION ALL SELECT '751128'
),
glu_loinc AS (           -- glucose only (needed for CONTROL “has-lab” rule)
    SELECT '1558-6' UNION ALL SELECT '2339-0' UNION ALL SELECT '2345-7'
),
glu_a1c_loinc AS (       -- glucose + HbA1c (needed for abnormal-lab tests)
    SELECT * FROM glu_loinc
    UNION ALL
    SELECT '4548-4' UNION ALL SELECT '17856-6' UNION ALL SELECT '4549-2' UNION ALL SELECT '17855-8'
),

/* ---------- 2.  PATIENT-LEVEL FEATURE EXTRACTION ---------- */
feat AS (
SELECT
    p.person_id,

    /* 2.1  DIAGNOSIS COUNTS ------------------------------------------------ */
    SUM(CASE WHEN c.condition_source_value IN (SELECT code FROM t1dm_dx)                              THEN 1 ELSE 0 END) AS t1_cnt,
    SUM(CASE WHEN c.condition_source_value IN (SELECT code FROM t2dm_dx)
                 AND c.condition_source_value NOT IN (SELECT code FROM t2dm_dx_excl)                   THEN 1 ELSE 0 END) AS t2_cnt,

    /* physician-entered T2DM dx (encounter/problem-list sources) */
    SUM(CASE WHEN c.condition_source_value IN (SELECT code FROM t2dm_dx)
                 AND c.condition_source_value NOT IN (SELECT code FROM t2dm_dx_excl)
                 AND c.condition_type_concept_id IN (32020, 32817)                                     THEN 1 ELSE 0 END) AS phys_t2_cnt,

    /* 2.2  MEDICATION DATES ------------------------------------------------- */
    MIN(CASE WHEN d.drug_source_value IN (SELECT code FROM t1dm_rx) THEN d.drug_exposure_start_date END) AS t1_rx_dt,
    MIN(CASE WHEN d.drug_source_value IN (SELECT code FROM t2dm_rx) THEN d.drug_exposure_start_date END) AS t2_rx_dt,

    /* 2.3  ABNORMAL-LAB FLAGS ---------------------------------------------- */
    MAX(CASE
          WHEN m.measurement_source_value IN ('2339-0','2345-7') AND m.value_as_number  > 200 THEN 1
          WHEN m.measurement_source_value  = '1558-6'            AND m.value_as_number >= 125 THEN 1
          WHEN m.measurement_source_value IN ('4548-4','17856-6','4549-2','17855-8')
               AND m.value_as_number >= 6.5 THEN 1
          ELSE 0 END)                                                                                  AS abnl_case_lab,

    MAX(CASE
          WHEN m.measurement_source_value IN ('2339-0','2345-7') AND m.value_as_number  > 110 THEN 1
          WHEN m.measurement_source_value  = '1558-6'            AND m.value_as_number >= 110 THEN 1
          WHEN m.measurement_source_value IN ('4548-4','17856-6','4549-2','17855-8')
               AND m.value_as_number >= 6.0 THEN 1
          ELSE 0 END)                                                                                  AS abnl_ctrl_lab,

    /* 2.4  HAS-GLUCOSE-LAB FLAG ------------------------------------------- */
    MAX(CASE WHEN m.measurement_source_value IN (SELECT code FROM glu_loinc) THEN 1 ELSE 0 END)        AS has_glu_lab,

    /* 2.5  OUTPATIENT OFFICE VISITS ---------------------------------------- */
    COUNT(DISTINCT CASE WHEN v.visit_concept_id = 9202 THEN v.visit_start_date END)                     AS office_visits,

    /* 2.6  DIABETES MEDS OR SUPPLIES (distinct exposure dates) ------------- */
    COUNT(DISTINCT CASE WHEN d.drug_source_value IN (SELECT code FROM t1dm_rx UNION ALL SELECT code FROM t2dm_rx)
                         THEN d.drug_exposure_start_date END)
      + COUNT(DISTINCT CASE WHEN dv.device_source_value IN (SELECT code FROM dm_supplies)
                         THEN dv.device_exposure_start_date END)                                        AS dm_med_supp_dates,

    /* 2.7  FAMILY HISTORY OF DIABETES -------------------------------------- */
    MAX(CASE WHEN o.observation_concept_id = 4181412 THEN 1 ELSE 0 END)                                AS fam_hist_dm

FROM       @schema.person               p
LEFT JOIN  @schema.condition_occurrence c  ON c.person_id = p.person_id
LEFT JOIN  @schema.drug_exposure        d  ON d.person_id = p.person_id
LEFT JOIN  @schema.device_exposure      dv ON dv.person_id = p.person_id
LEFT JOIN  @schema.measurement          m  ON m.person_id = p.person_id
LEFT JOIN  @schema.visit_occurrence     v  ON v.person_id = p.person_id
LEFT JOIN  @schema.observation          o  ON o.person_id = p.person_id
GROUP BY   p.person_id
)

/* ---------- 3.  CASE / CONTROL / UNKNOWN ASSIGNMENT ----------------------- */
SELECT
    f.person_id,

    /* ----- DECISION TREE  (five CASE paths + one CONTROL path) ----- */
    CASE
        /* CASE – Path 1: Dx + both meds; T2DM med precedes T1DM med */
        WHEN f.t1_cnt = 0
         AND f.t2_cnt > 0
         AND f.t1_rx_dt IS NOT NULL
         AND f.t2_rx_dt IS NOT NULL
         AND f.t2_rx_dt <  f.t1_rx_dt                           THEN 'CASE'

        /* CASE – Path 2: Dx + T2DM med only */
        WHEN f.t1_cnt = 0
         AND f.t2_cnt > 0
         AND f.t1_rx_dt IS NULL
         AND f.t2_rx_dt IS NOT NULL                            THEN 'CASE'

        /* CASE – Path 3: Dx only + abnormal lab */
        WHEN f.t1_cnt = 0
         AND f.t2_cnt > 0
         AND f.t1_rx_dt IS NULL
         AND f.t2_rx_dt IS NULL
         AND f.abnl_case_lab = 1                              THEN 'CASE'

        /* CASE – Path 4: Med + abnormal lab (no diagnoses) */
        WHEN f.t1_cnt = 0
         AND f.t2_cnt = 0
         AND f.t2_rx_dt IS NOT NULL
         AND f.abnl_case_lab = 1                              THEN 'CASE'

        /* CASE – Path 5: Dx + T1DM med only + ≥2 physician T2DM dx */
        WHEN f.t1_cnt = 0
         AND f.t2_cnt > 0
         AND f.t1_rx_dt IS NOT NULL
         AND f.t2_rx_dt IS NULL
         AND f.phys_t2_cnt >= 2                               THEN 'CASE'

        /* CONTROL – single path (all criteria must be true) */
        WHEN NOT EXISTS (
                 SELECT 1
                 FROM   @schema.condition_occurrence c2
                 WHERE  c2.person_id = f.person_id
                   AND  c2.condition_source_value IN (SELECT code FROM dm_related_dx)
             )
         AND f.has_glu_lab          = 1
         AND f.abnl_ctrl_lab        = 0
         AND f.office_visits       >= 2
         AND f.dm_med_supp_dates    = 0
         AND f.fam_hist_dm          = 0                        THEN 'CONTROL'

        /* Otherwise -> UNKNOWN */
        ELSE 'UNKNOWN'
    END AS t2dm_status
FROM feat f;