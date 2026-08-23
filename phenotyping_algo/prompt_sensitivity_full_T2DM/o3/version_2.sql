/*************************************************************************
  TYPE-2 DIABETES MELLITUS CASE & CONTROL COHORTS  – OMOP CDM v5.4
  Source: “Type 2 Diabetes Mellitus Electronic Medical Record Case
  and Control Selection Algorithms” (19-Aug-2011)

  All PDF line numbers follow the audit (e.g. p4 L16-18).
*************************************************************************/

/* ============================================================
   1. CONCEPT SETS
   ============================================================ */

/* ---------- Diagnosis code sets ------------------------------------ */
WITH t1dm_dx_concepts AS (      /* CS_T1DM_DX – Table 3 (p21 L13-16) */
    SELECT DISTINCT COALESCE(cr.concept_id_2, c.concept_id) AS concept_id
    FROM concept            AS c
    LEFT JOIN concept_relationship AS cr
      ON cr.concept_id_1 = c.concept_id
     AND cr.relationship_id = 'Maps to'
    WHERE c.vocabulary_id = 'ICD9CM'
      AND (c.concept_code LIKE '250.%1' OR  -- 250.x1
           c.concept_code LIKE '250.%3')    -- 250.x3
      AND COALESCE(cr.invalid_reason, c.invalid_reason) IS NULL
),

t2dm_dx_concepts AS (           /* CS_T2DM_DX – Table 4 (p21 L16-19) */
    SELECT DISTINCT COALESCE(cr.concept_id_2, c.concept_id) AS concept_id
    FROM concept            AS c
    LEFT JOIN concept_relationship AS cr
      ON cr.concept_id_1 = c.concept_id
     AND cr.relationship_id = 'Maps to'
    WHERE c.vocabulary_id = 'ICD9CM'
      AND (
            c.concept_code LIKE '250.%0' OR   -- 250.x0
            c.concept_code LIKE '250.%2'      -- 250.x2
          )
      AND c.concept_code NOT IN ('250.10','250.12')
      AND COALESCE(cr.invalid_reason, c.invalid_reason) IS NULL
),

dm_dx_concepts AS (             /* CS_DM_DX – Table 9 (p23 L76-87)  */
    SELECT DISTINCT COALESCE(cr.concept_id_2, c.concept_id) AS concept_id
    FROM concept            AS c
    LEFT JOIN concept_relationship AS cr
      ON cr.concept_id_1 = c.concept_id
     AND cr.relationship_id = 'Maps to'
    WHERE c.vocabulary_id = 'ICD9CM'
      AND (
            c.concept_code LIKE '250.%'  OR
            c.concept_code IN ('790.21','790.22','790.2','790.29',
                               '791.5','277.7','V18.0','V77.1') OR
            c.concept_code LIKE '648.8%' OR
            c.concept_code LIKE '648.0%'
          )
      AND COALESCE(cr.invalid_reason, c.invalid_reason) IS NULL
),

/* ---------- Drug & supply code sets -------------------------------- */
t1dm_drug_concepts AS (         /* CS_T1DM_MEDS – Table 5 (p21 L20-26) */
    SELECT DISTINCT COALESCE(cr.concept_id_2, c.concept_id) AS concept_id
    FROM concept            AS c
    LEFT JOIN concept_relationship AS cr
      ON cr.concept_id_1 = c.concept_id
     AND cr.relationship_id = 'Maps to'
    WHERE c.vocabulary_id = 'RxNorm'
      AND c.concept_code IN
          ('139825','274783','314684','352385','400008',
           '51428','5856','86009','139953')
      AND COALESCE(cr.invalid_reason, c.invalid_reason) IS NULL
),

t2dm_drug_concepts AS (         /* CS_T2DM_MEDS – Table 6 (p22 L29-45,49-51) */
    SELECT DISTINCT COALESCE(cr.concept_id_2, c.concept_id) AS concept_id
    FROM concept            AS c
    LEFT JOIN concept_relationship AS cr
      ON cr.concept_id_1 = c.concept_id
     AND cr.relationship_id = 'Maps to'
    WHERE c.vocabulary_id = 'RxNorm'
      AND c.concept_code IN
          ('173','10633','2404','4821','217360','4815','25789','73044',
           '274332','6809','84108','33738','72610','16681','30009',
           '593411','60548')
      AND COALESCE(cr.invalid_reason, c.invalid_reason) IS NULL
),

dm_supply_concepts AS (         /* CS_DM_SUPPLIES – Table 8 (p23 L20-35) */
    SELECT DISTINCT COALESCE(cr.concept_id_2, c.concept_id) AS concept_id
    FROM concept            AS c
    LEFT JOIN concept_relationship AS cr
      ON cr.concept_id_1 = c.concept_id
     AND cr.relationship_id = 'Maps to'
    WHERE (
            (c.vocabulary_id = 'RxNorm' AND c.concept_code IN
                 ('847187','847191','847197','847203','847207','847211',
                  '847230','847239','847252','847256','847259','847263',
                  '847278','847416','847417'))
         OR (c.vocabulary_id = 'NDFRT'  AND c.concept_code IN
                 ('126958','412956','412959','637321','668291','668370',
                  '686655','692383','748611','880998','881056',
                  '806905','806903','408119'))
         OR (c.vocabulary_id = 'VANDF'  AND c.concept_code = '751128')
          )
      AND COALESCE(cr.invalid_reason, c.invalid_reason) IS NULL
),

dm_meds_supplies_concepts AS (
    SELECT concept_id FROM t1dm_drug_concepts
    UNION
    SELECT concept_id FROM t2dm_drug_concepts
    UNION
    SELECT concept_id FROM dm_supply_concepts
),

/* ---------- Laboratory code sets ----------------------------------- */
fasting_glucose_concepts AS (   /* 1558-6 – fasting (p22 L52-55)   */
    SELECT COALESCE(cr.concept_id_2, c.concept_id) AS concept_id
    FROM concept c
    LEFT JOIN concept_relationship cr
      ON cr.concept_id_1 = c.concept_id
     AND cr.relationship_id = 'Maps to'
    WHERE c.vocabulary_id = 'LOINC' AND c.concept_code = '1558-6'
      AND COALESCE(cr.invalid_reason, c.invalid_reason) IS NULL
),
random_glucose_concepts AS (    /* 2339-0, 2345-7 – random (p22 L52-55) */
    SELECT COALESCE(cr.concept_id_2, c.concept_id) AS concept_id
    FROM concept c
    LEFT JOIN concept_relationship cr
      ON cr.concept_id_1 = c.concept_id
     AND cr.relationship_id = 'Maps to'
    WHERE c.vocabulary_id = 'LOINC'
      AND c.concept_code IN ('2339-0','2345-7')
      AND COALESCE(cr.invalid_reason, c.invalid_reason) IS NULL
),
hba1c_concepts AS (             /* HbA1c codes – p22 L52-57        */
    SELECT COALESCE(cr.concept_id_2, c.concept_id) AS concept_id
    FROM concept c
    LEFT JOIN concept_relationship cr
      ON cr.concept_id_1 = c.concept_id
     AND cr.relationship_id = 'Maps to'
    WHERE c.vocabulary_id = 'LOINC'
      AND c.concept_code IN ('4548-4','17856-6','4549-2','17855-8')
      AND COALESCE(cr.invalid_reason, c.invalid_reason) IS NULL
),

dm_lab_concepts AS (            /* union for convenience           */
    SELECT concept_id FROM fasting_glucose_concepts
    UNION
    SELECT concept_id FROM random_glucose_concepts
    UNION
    SELECT concept_id FROM hba1c_concepts
),

glucose_lab_concepts AS (       /* union fasting+random            */
    SELECT concept_id FROM fasting_glucose_concepts
    UNION
    SELECT concept_id FROM random_glucose_concepts
),

/* ============================================================
   2. PERSON-LEVEL FEATURES
   ============================================================ */
person_feats AS (
  SELECT
      p.person_id,

      /* ---- diagnoses (distinct dates) ---- */
      (SELECT COUNT(DISTINCT condition_start_date)
       FROM condition_occurrence co
       WHERE co.person_id = p.person_id
         AND co.condition_concept_id IN (SELECT concept_id FROM t1dm_dx_concepts)
      ) AS t1dm_dx_dates,

      (SELECT COUNT(DISTINCT condition_start_date)
       FROM condition_occurrence co
       WHERE co.person_id = p.person_id
         AND co.condition_concept_id IN (SELECT concept_id FROM t2dm_dx_concepts)
      ) AS t2dm_dx_dates,

      /* CASE_09 physician DX ≥ 2 – SOURCE_AMBIGUITY: OMOP has no source flag */
      (SELECT COUNT(DISTINCT condition_start_date)
       FROM condition_occurrence co
       WHERE co.person_id = p.person_id
         AND co.condition_concept_id IN (SELECT concept_id FROM t2dm_dx_concepts)
      ) AS t2dm_phys_dx_dates,   /* May over-count – see note above */

      /* CTRL_01 DM-related diagnoses */
      (SELECT COUNT(DISTINCT condition_start_date)
       FROM condition_occurrence co
       WHERE co.person_id = p.person_id
         AND co.condition_concept_id IN (SELECT concept_id FROM dm_dx_concepts)
      ) AS dm_dx_dates,

      /* ---- prescriptions ---- */
      /* earliest dates for type-1 and type-2 meds */
      (SELECT MIN(drug_exposure_start_date)
       FROM drug_exposure de
       WHERE de.person_id = p.person_id
         AND de.drug_concept_id IN (SELECT concept_id FROM t1dm_drug_concepts)
      ) AS first_t1dm_rx,

      (SELECT MIN(drug_exposure_start_date)
       FROM drug_exposure de
       WHERE de.person_id = p.person_id
         AND de.drug_concept_id IN (SELECT concept_id FROM t2dm_drug_concepts)
      ) AS first_t2dm_rx,

      /* CTRL_05 – any DM medication or supply order (drug/device) */
      (SELECT COUNT(DISTINCT order_date) FROM (
           SELECT de2.drug_exposure_start_date    AS order_date
           FROM drug_exposure   de2
           WHERE de2.person_id = p.person_id
             AND de2.drug_concept_id IN (SELECT concept_id FROM dm_meds_supplies_concepts)
           UNION ALL
           SELECT dx2.device_exposure_start_date  AS order_date
           FROM device_exposure dx2
           WHERE dx2.person_id = p.person_id
             AND dx2.device_concept_id IN (SELECT concept_id FROM dm_meds_supplies_concepts)
      ) q) AS dm_meds_supplies_dates,

      /* ---- visits ---- */
      (SELECT COUNT(DISTINCT vo.visit_start_date)
       FROM visit_occurrence vo
       WHERE vo.person_id      = p.person_id
         AND vo.visit_concept_id = 9202   -- Out-patient visit (office) CTRL_04 p11 L43-52
      ) AS office_visit_dates,

      /* ---- laboratory flags ---- */
      /* CTRL_02 – at least one glucose measurement */
      EXISTS (
        SELECT 1 FROM measurement m
        WHERE m.person_id = p.person_id
          AND m.measurement_concept_id IN (SELECT concept_id FROM glucose_lab_concepts)
      ) AS has_glucose_lab,

      /* CASE_07 – abnormal lab (Algorithm 6, p6 L53-60) */
      EXISTS (
        SELECT 1 FROM measurement m
        WHERE m.person_id = p.person_id
          AND m.value_as_number IS NOT NULL
          AND (
               (m.measurement_concept_id IN (SELECT concept_id FROM random_glucose_concepts)
                    AND m.value_as_number  > 200)                                  /* Random > 200 */
            OR (m.measurement_concept_id IN (SELECT concept_id FROM fasting_glucose_concepts)
                    AND m.value_as_number >= 125)                                  /* Fasting ≥ 125 */
            OR (m.measurement_concept_id IN (SELECT concept_id FROM hba1c_concepts)
                    AND m.value_as_number >= 6.5)                                  /* HbA1c ≥ 6.5 % */
          )
      ) AS case_abnormal_lab,

      /* CTRL_03 – abnormal lab must be FALSE (Algorithm 11, p11 L25-41) */
      EXISTS (
        SELECT 1 FROM measurement m
        WHERE m.person_id = p.person_id
          AND m.value_as_number IS NOT NULL
          AND (
               (m.measurement_concept_id IN (SELECT concept_id FROM random_glucose_concepts)
                    AND m.value_as_number  > 110)                                  /* Random > 110 */
            OR (m.measurement_concept_id IN (SELECT concept_id FROM fasting_glucose_concepts)
                    AND m.value_as_number >= 110)                                  /* Fasting ≥ 110 */
            OR (m.measurement_concept_id IN (SELECT concept_id FROM hba1c_concepts)
                    AND m.value_as_number >= 6.0)                                  /* HbA1c ≥ 6.0 % */
          )
      ) AS control_abnormal_lab

      /* ---- family history ---- */
      /* SOURCE_AMBIGUITY: Algorithm 14 (p12 L68-70) cites a separate family-history
         table with no codes.  PDF does not supply codes.  Criterion cannot
         be implemented deterministically and is therefore omitted. */

  FROM person p
),

/* ============================================================
   3. CASE COHORT  – five paths (Algorithm 1, p4 L16-44)
   ============================================================ */
case_cohort AS (
  SELECT
      person_id,
      NULL::DATE AS index_date,        -- source supplies no index rule
      NULL::DATE AS cohort_start_date,
      NULL::DATE AS cohort_end_date
  FROM person_feats f
  WHERE
        t1dm_dx_dates = 0                                   /* CASE_01 */
    AND (
            /* ---- Path 1 ---- */
            ( t2dm_dx_dates > 0                 /* CASE_02 */
              AND first_t2dm_rx IS NOT NULL     /* CASE_03 */
              AND first_t1dm_rx IS NOT NULL     /* CASE_04 */
              AND first_t2dm_rx < first_t1dm_rx /* CASE_05 */
            )
         OR /* ---- Path 2 ---- */
            ( t2dm_dx_dates > 0                 /* CASE_02 */
              AND first_t2dm_rx IS NOT NULL     /* CASE_03 */
              AND first_t1dm_rx IS NULL         /* CASE_06 */
            )
         OR /* ---- Path 3 ---- */
            ( t2dm_dx_dates > 0                 /* CASE_02 */
              AND first_t2dm_rx IS NULL         /* CASE_10 */
              AND first_t1dm_rx IS NULL         /* CASE_06 */
              AND case_abnormal_lab = TRUE      /* CASE_07 */
            )
         OR /* ---- Path 4 ---- */
            ( t2dm_dx_dates = 0                 /* CASE_08 */
              AND first_t2dm_rx IS NOT NULL     /* CASE_03 */
              AND case_abnormal_lab = TRUE      /* CASE_07 */
            )
         OR /* ---- Path 5 ---- */
            ( t2dm_dx_dates > 0                 /* CASE_02 */
              AND first_t1dm_rx IS NOT NULL     /* CASE_04 */
              AND first_t2dm_rx IS NULL         /* CASE_10 */
              AND t2dm_phys_dx_dates >= 2       /* CASE_09  (approx.) */
            )
        )
),

/* ============================================================
   4. CONTROL COHORT  (Algorithm 8, p9 L50-57)
   ============================================================ */
control_cohort AS (
  SELECT
      person_id,
      NULL::DATE AS index_date,        -- source supplies no index rule
      NULL::DATE AS cohort_start_date,
      NULL::DATE AS cohort_end_date
  FROM person_feats f
  WHERE
        dm_dx_dates             = 0            -- CTRL_01
    AND has_glucose_lab         = TRUE         -- CTRL_02
    AND control_abnormal_lab    = FALSE        -- CTRL_03
    AND office_visit_dates      >= 2           -- CTRL_04
    AND dm_meds_supplies_dates  = 0            -- CTRL_05
    /* SOURCE_AMBIGUITY: CTRL_06 (family history) cannot be
       implemented – omitted per instructions. */
    AND person_id NOT IN (SELECT person_id FROM case_cohort)
)

/* ============================================================
   5. FINAL RESULT – one row per person per cohort
   ============================================================ */
SELECT
    person_id,
    'CASE'    AS cohort_label,
    index_date,
    cohort_start_date,
    cohort_end_date
FROM case_cohort

UNION ALL

SELECT
    person_id,
    'CONTROL' AS cohort_label,
    index_date,
    cohort_start_date,
    cohort_end_date
FROM control_cohort;