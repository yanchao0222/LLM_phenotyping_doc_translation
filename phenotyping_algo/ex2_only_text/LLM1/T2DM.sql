/* =======================================================================
   TYPE 2 DIABETES MELLITUS PHENOTYPE  —  Northwestern eMERGE Algorithm
   Target CDM: OMOP v5+            |     Author: automated extraction
   -----------------------------------------------------------------------
   Output columns
   ---------------
   person_id        – OMOP person identifier
   is_t2dm_case     – 1 = meets ≥ 1 case path (and no T1DM evidence), else 0
   is_t2dm_control  – 1 = satisfies every control guard, else 0
   ======================================================================= */


/* ---------------- 1. Laboratory evidence (flags & counts) -------------- */
WITH lab_flags AS (
  SELECT  m.person_id,

          /* ----- CASE‑level abnormal lab flags ----- */
          MAX(CASE WHEN m.measurement_source_value = '1558-6'
                        AND m.value_as_number >= 125              THEN 1 END) AS fast_case,
          MAX(CASE WHEN m.measurement_source_value IN ('2339-0','2345-7')
                        AND m.value_as_number  > 200              THEN 1 END) AS rnd_case,
          MAX(CASE WHEN m.measurement_source_value IN ('4548-4','17856-6',
                                                       '4549-2','17855-8')
                        AND m.value_as_number >= 6.5              THEN 1 END) AS a1c_case,

          /* ----- CONTROL‑screen abnormal lab flags ----- */
          MAX(CASE WHEN m.measurement_source_value = '1558-6'
                        AND m.value_as_number >= 110              THEN 1 END) AS fast_ctrl,
          MAX(CASE WHEN m.measurement_source_value IN ('2339-0','2345-7')
                        AND m.value_as_number  > 110              THEN 1 END) AS rnd_ctrl,
          MAX(CASE WHEN m.measurement_source_value IN ('4548-4','17856-6',
                                                       '4549-2','17855-8')
                        AND m.value_as_number >= 6.0              THEN 1 END) AS a1c_ctrl,

          /* distinct abnormal CASE‑level lab dates (path 5) */
          COUNT(DISTINCT CASE
                 WHEN (
                        (m.measurement_source_value = '1558-6'            AND m.value_as_number >= 125) OR
                        (m.measurement_source_value IN ('2339-0','2345-7')AND m.value_as_number  > 200) OR
                        (m.measurement_source_value IN ('4548-4','17856-6',
                                                        '4549-2','17855-8')AND m.value_as_number >= 6.5)
                      )
                 THEN m.measurement_date
               END) AS abnl_case_dates
  FROM   measurement  m
  GROUP BY m.person_id
),

/* ---------------- 2. Diagnosis evidence ---------------- */
dx AS (
  SELECT  c.person_id,

    /* ---- T2DM diagnoses ------------------------------------------------
       rule: ICD‑9 code begins '250.' and 5th digit = 0 OR 2,
             but exclude ketoacidosis codes 250.10 & 250.12            */
    COUNT(DISTINCT CASE
            WHEN LEFT(c.condition_source_value,4) = '250.' 
                 AND RIGHT(c.condition_source_value,1) IN ('0','2')
                 AND c.condition_source_value NOT IN ('250.10','250.12')
            THEN c.condition_start_date END)            AS dx_t2_cnt,

    /* only those T2 codes entered by clinician (problem list / encounter) */
    COUNT(DISTINCT CASE
            WHEN LEFT(c.condition_source_value,4) = '250.'
                 AND RIGHT(c.condition_source_value,1) IN ('0','2')
                 AND c.condition_source_value NOT IN ('250.10','250.12')
                 AND c.condition_type_concept_id IN (38000250,38000275)
            THEN c.condition_start_date END)            AS dx_t2_phys_cnt,

    /* ---- T1DM diagnoses (exclusion) ----------------------------------- */
    COUNT(DISTINCT CASE
            WHEN LEFT(c.condition_source_value,4) = '250.'
                 AND RIGHT(c.condition_source_value,1) IN ('1','3')
            THEN c.condition_start_date END)            AS dx_t1_cnt,

    /* ---- Any diabetes‑related codes for control screening ------------- */
    COUNT(DISTINCT CASE
            WHEN c.condition_source_value LIKE '250.%'
                 OR c.condition_source_value IN ('790.21','790.22','790.2',
                                                 '790.29','648.8','648.80',
                                                 '648.81','648.82','648.83',
                                                 '648.84','648.0','648.00',
                                                 '648.01','648.02','648.03',
                                                 '648.04','791.5','277.7',
                                                 'V18.0','V77.1')
            THEN c.condition_start_date END)            AS dx_dm_any_cnt
  FROM   condition_occurrence c
  GROUP BY c.person_id
),

/* ---------------- 3. Medication evidence ---------------- */
rx AS (
  SELECT  d.person_id,
          -- T2DM therapeutics (RxNorm concept_ids)
          MAX(CASE WHEN d.drug_concept_id IN (173,10633,2404,4821,217360,4815,
                                              25789,73044,274332,6809,84108,
                                              33738,72610,16681,30009,593411,
                                              60548)
                   THEN 1 END)                            AS rx_t2,
          -- T1DM therapeutics
          MAX(CASE WHEN d.drug_concept_id IN (139825,274783,314684,352385,
                                              400008,51428,5856,86009,139953)
                   THEN 1 END)                            AS rx_t1
  FROM   drug_exposure d
  GROUP BY d.person_id
),

/* ---------------- 4. Supplies (glucometers, syringes) ---------------- */
supplies AS (
  SELECT  de.person_id,
          MAX(1) AS dm_supply_flag
  FROM    device_exposure de
  WHERE   de.device_source_value IN (
            '126958','412956','412959','637321','668291','668370','686655',
            '692383','748611','880998','881056','751128','847187','847191',
            '847197','847203','847207','847211','847230','847239','847252',
            '847256','847259','847263','847278','847416','847417','806905',
            '806903','408119')
  GROUP BY de.person_id
),

/* ---------------- 5. Family‑history evidence ------------------------- */
fam_hist AS (
  SELECT  o.person_id,
          MAX(1) AS fam_hist_dm
  FROM    observation o
  WHERE   o.observation_source_value = 'V18.0'
  GROUP BY o.person_id
),

/* ---------------- 6. Utilization (≥ 1 face‑to‑face visit) ------------ */
visits AS (
  SELECT  v.person_id,
          COUNT(DISTINCT v.visit_start_date) AS visit_cnt
  FROM    visit_occurrence v
  WHERE   v.visit_concept_id = 9201   -- outpatient visit (face‑to‑face)
  GROUP BY v.person_id
),

/* ---------------- 7. Collate all evidence per person ----------------- */
evidence AS (
  SELECT  p.person_id,

          /* labs */
          COALESCE(lf.fast_case,0)        AS fast_case,
          COALESCE(lf.rnd_case,0)         AS rnd_case,
          COALESCE(lf.a1c_case,0)         AS a1c_case,
          COALESCE(lf.fast_ctrl,0)        AS fast_ctrl,
          COALESCE(lf.rnd_ctrl,0)         AS rnd_ctrl,
          COALESCE(lf.a1c_ctrl,0)         AS a1c_ctrl,
          COALESCE(lf.abnl_case_dates,0)  AS abnl_case_dates,

          /* diagnoses */
          COALESCE(dx.dx_t2_cnt,0)        AS dx_t2_cnt,
          COALESCE(dx.dx_t2_phys_cnt,0)   AS dx_t2_phys_cnt,
          COALESCE(dx.dx_t1_cnt,0)        AS dx_t1_cnt,
          COALESCE(dx.dx_dm_any_cnt,0)    AS dx_dm_any_cnt,

          /* meds */
          COALESCE(rx.rx_t2,0)            AS rx_t2,
          COALESCE(rx.rx_t1,0)            AS rx_t1,

          /* supplies, FHx, visits */
          COALESCE(sp.dm_supply_flag,0)   AS dm_supply_flag,
          COALESCE(fh.fam_hist_dm,0)      AS fam_hist_dm,
          COALESCE(v.visit_cnt,0)         AS visit_cnt
  FROM    person             p
  LEFT JOIN lab_flags    lf  ON lf.person_id = p.person_id
  LEFT JOIN dx           dx  ON dx.person_id = p.person_id
  LEFT JOIN rx           rx  ON rx.person_id = p.person_id
  LEFT JOIN supplies     sp  ON sp.person_id = p.person_id
  LEFT JOIN fam_hist     fh  ON fh.person_id = p.person_id
  LEFT JOIN visits       v   ON v.person_id = p.person_id
)

/* ======================================================================
   8. Final CASE & CONTROL labels
   ====================================================================== */
SELECT person_id,

       /* ---------- CASE status --------------------------------------- */
       CASE
         WHEN dx_t1_cnt > 0 OR rx_t1 = 1                        THEN 0  -- T1 evidence => not a T2 case
         WHEN ( dx_t2_phys_cnt >= 2                              -- Path 1
                OR (dx_t2_cnt >= 1 AND rx_t2 = 1)                -- Path 2
                OR (dx_t2_cnt >= 1 AND (fast_case=1 OR rnd_case=1 OR a1c_case=1)) -- Path 3
                OR (rx_t2 = 1   AND (fast_case=1 OR rnd_case=1 OR a1c_case=1))    -- Path 4
                OR (abnl_case_dates >= 2)                        -- Path 5
              )
              THEN 1
         ELSE 0
       END  AS is_t2dm_case,

       /* ---------- CONTROL status ------------------------------------ */
       CASE
         WHEN visit_cnt < 1                                   THEN 0
         WHEN dx_t1_cnt  > 0 OR dx_t2_cnt  > 0                THEN 0
         WHEN dx_dm_any_cnt > 0                               THEN 0
         WHEN rx_t1 = 1 OR rx_t2 = 1                          THEN 0
         WHEN dm_supply_flag = 1                              THEN 0
         WHEN (fast_ctrl=1 OR rnd_ctrl=1 OR a1c_ctrl=1)       THEN 0
         WHEN fam_hist_dm = 1                                 THEN 0
         ELSE 1
       END  AS is_t2dm_control

FROM evidence;
