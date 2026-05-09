/* ==============================================================
   Acute Kidney Injury (AKI) Phenotype  —  OMOP CDM v5.x
   --------------------------------------------------------------
   ▸ Removes patients with a history of ESRD (dialysis / transplant)
   ▸ Calculates three‑tier baseline serum‑creatinine (SCr)
   ▸ Flags daily SCr rises ≥50 % of baseline
   ▸ Builds AKI blocks (≥1 abnormal day, separated by ≥2 days
     without any SCr measurement)
   ▸ Determines AKIN stage, transient vs sustained subtype,
     and recurrence count
   ▸ Labels visits as CASE (AKI_YES) or CONTROL (AKI_NO)
   =============================================================*/

/* ----------------------------------------------------------------
   SECTION 0 — Concept sets
-----------------------------------------------------------------*/
WITH
-- 0.1  ESRD‑related diagnoses
esrd_dx AS (
    SELECT concept_id FROM (VALUES
        (45552870),(45577822),(45575617),(45609389),(45590127),
        (45575620),(45604584),(35224814),(1576113),(1576114),
        (45609945),(44830633),(44824846),(44828407),(44831843),
        (44836535),(44822716),(44829650),(44833130),(44833131),
        (44835496),(44835497),(44821578),(44835472),(44831947),
        (44834280),(1575308),(45546763),(45609393),(45599829),
        (45575625),(45537090),(4081759),(42539502),(199991),
        (4128369),(4127554)
    ) AS x(concept_id)
),

-- 0.2  ESRD‑related procedures / observations
esrd_proc AS (
    SELECT concept_id FROM (VALUES
        (2101833),(2101834),(2106278),(42736574),(2108276),(2108277),
        (2108297),(2108299),(2108302),(42628575),(42627979),(42628018),
        (42628576),(42628058),(42628580),(2108564),(2108566),(2108567),
        (2108568),(2109463),(2213572),(2213573),(2213575),(2213576),
        (2213577),(2213578),(2213579),(2213580),(2213581),(2213582),
        (2213583),(2213584),(2213585),(2213586),(2213587),(2213588),
        (2213589),(2213590),(2213591),(2213592),(2213593),(2213594),
        (2213595),(2213596),(2213597),(2213598),(2213599),(2213600),
        (2213601),(2313999),(2786488),(4289454),(4197217),(4026915),
        (4214705),(4120120),(4324124),(2002176),(2002189),(2002208),
        (2002209),(2002282),(2003564),(2109586),(2109587),(2109589),
        (2774517),(2774518),(2774519),(2774520),(2774521),(2774522),
        (4146256),(4322471),(2003622),(2003624)
    ) AS x(concept_id)
),

-- 0.3  Serum‑creatinine measurement concepts
scr_lab AS (
    SELECT concept_id FROM (VALUES
        (3018968),(3022243),(3020564),(3016723),(3032033),
        (3041716),(3041735),(3050951),(40760920),(40770372),
        (43055236),(44786911),(46235076)
    ) AS x(concept_id)
),

/* ----------------------------------------------------------------
   SECTION 1 — Candidate presentation windows (ED + IP visits)
-----------------------------------------------------------------*/
candidate_visits AS (
    SELECT  person_id,
            visit_occurrence_id,
            visit_start_date,
            visit_end_date
    FROM    visit_occurrence
    WHERE   visit_concept_id IN (262, 9201)   -- 262 = ER, 9201 = Inpatient
),

/* ----------------------------------------------------------------
   SECTION 2 — ESRD history exclusion
-----------------------------------------------------------------*/
excluded_esrd AS (
    SELECT DISTINCT cv.person_id, cv.visit_occurrence_id
    FROM   candidate_visits cv
    LEFT   JOIN condition_occurrence co
           ON co.person_id=cv.person_id
          AND co.condition_concept_id IN (SELECT concept_id FROM esrd_dx)
          AND co.condition_start_date < cv.visit_start_date
    LEFT   JOIN procedure_occurrence po
           ON po.person_id=cv.person_id
          AND po.procedure_concept_id IN (SELECT concept_id FROM esrd_proc)
          AND po.procedure_date < cv.visit_start_date
    WHERE  co.condition_occurrence_id IS NOT NULL
       OR  po.procedure_occurrence_id IS NOT NULL
),

/* ----------------------------------------------------------------
   SECTION 3 — Three‑tier baseline SCr
-----------------------------------------------------------------
   Tier 1 : median SCr 7‑365 days before visit
   Tier 2 : minimum SCr 0‑7 days before visit   (if Tier 1 absent)
   Tier 3 : minimum SCr on/after visit start    (if Tier 1–2 absent)
-----------------------------------------------------------------*/
baseline_t1 AS (
    SELECT  cv.person_id,
            cv.visit_occurrence_id,
            PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY m.value_as_number)
            AS baseline_scr
    FROM    candidate_visits cv
    JOIN    measurement m
           ON m.person_id=cv.person_id
          AND m.measurement_concept_id IN (SELECT concept_id FROM scr_lab)
          AND m.measurement_date BETWEEN cv.visit_start_date - INTERVAL '365 day'
                                     AND cv.visit_start_date - INTERVAL '7 day'
    GROUP BY cv.person_id, cv.visit_occurrence_id
),
baseline_t2 AS (
    SELECT  cv.person_id,
            cv.visit_occurrence_id,
            MIN(m.value_as_number) AS baseline_scr
    FROM    candidate_visits cv
    JOIN    measurement m
           ON m.person_id=cv.person_id
          AND m.measurement_concept_id IN (SELECT concept_id FROM scr_lab)
          AND m.measurement_date BETWEEN cv.visit_start_date - INTERVAL '7 day'
                                     AND cv.visit_start_date
    WHERE  NOT EXISTS (SELECT 1
                       FROM   baseline_t1 b1
                       WHERE  b1.person_id=cv.person_id
                         AND  b1.visit_occurrence_id=cv.visit_occurrence_id)
    GROUP BY cv.person_id, cv.visit_occurrence_id
),
baseline_t3 AS (
    SELECT  cv.person_id,
            cv.visit_occurrence_id,
            MIN(m.value_as_number) AS baseline_scr
    FROM    candidate_visits cv
    JOIN    measurement m
           ON m.person_id=cv.person_id
          AND m.measurement_concept_id IN (SELECT concept_id FROM scr_lab)
          AND m.measurement_date >= cv.visit_start_date
    WHERE  NOT EXISTS (SELECT 1
                       FROM   baseline_t1 b1
                       WHERE  b1.person_id=cv.person_id
                         AND  b1.visit_occurrence_id=cv.visit_occurrence_id)
      AND  NOT EXISTS (SELECT 1
                       FROM   baseline_t2 b2
                       WHERE  b2.person_id=cv.person_id
                         AND  b2.visit_occurrence_id=cv.visit_occurrence_id)
    GROUP BY cv.person_id, cv.visit_occurrence_id
),
baseline_scr AS (
    SELECT * FROM baseline_t1
    UNION ALL
    SELECT * FROM baseline_t2
    UNION ALL
    SELECT * FROM baseline_t3
),

/* ----------------------------------------------------------------
   SECTION 4 — Daily kidney‑function assessment
-----------------------------------------------------------------*/
daily_scr AS (
    SELECT  m.person_id,
            m.visit_occurrence_id,
            m.measurement_date,
            ROUND(AVG(m.value_as_number),3) AS mean_scr
    FROM    measurement m
    JOIN    candidate_visits cv
           ON cv.person_id           = m.person_id
          AND cv.visit_occurrence_id = m.visit_occurrence_id
    WHERE   m.measurement_concept_id IN (SELECT concept_id FROM scr_lab)
    GROUP BY m.person_id, m.visit_occurrence_id, m.measurement_date
),
daily_ratio AS (
    SELECT  ds.*,
            ds.mean_scr / bs.baseline_scr                  AS scr_ratio,
            CASE WHEN ds.mean_scr / bs.baseline_scr >= 1.5 THEN 1 ELSE 0 END AS abnormal_flag
    FROM    daily_scr  ds
    JOIN    baseline_scr bs
           ON bs.person_id=ds.person_id
          AND bs.visit_occurrence_id=ds.visit_occurrence_id
),

/* ----------------------------------------------------------------
   SECTION 5 — AKI status per visit
-----------------------------------------------------------------*/
aki_status AS (
    SELECT  cv.person_id,
            cv.visit_occurrence_id,
            CASE
                WHEN bs.baseline_scr IS NULL
                     OR NOT EXISTS (
                          SELECT 1 FROM daily_ratio dr
                          WHERE  dr.person_id=cv.person_id
                            AND  dr.visit_occurrence_id=cv.visit_occurrence_id)
                     THEN 'AKI_UNKNOWN'
                WHEN NOT EXISTS (
                          SELECT 1 FROM daily_ratio dr
                          WHERE  dr.person_id=cv.person_id
                            AND  dr.visit_occurrence_id=cv.visit_occurrence_id
                            AND  dr.abnormal_flag=1)
                     THEN 'AKI_NO'
                ELSE 'AKI_YES'
            END AS aki_status
    FROM    candidate_visits cv
    LEFT    JOIN baseline_scr bs
           ON bs.person_id=cv.person_id
          AND bs.visit_occurrence_id=cv.visit_occurrence_id
),

/* ----------------------------------------------------------------
   SECTION 6 — AKI blocks, stage, subtype, recurrence
-----------------------------------------------------------------*/
abn_days AS (
    SELECT  dr.*,
            LAG(dr.measurement_date) OVER (
                PARTITION BY dr.person_id, dr.visit_occurrence_id
                ORDER BY     dr.measurement_date)                      AS prev_abn_date
    FROM    daily_ratio dr
    WHERE   dr.abnormal_flag = 1
),
abn_days_flagged AS (
    SELECT  *,
            CASE
                WHEN prev_abn_date IS NULL
                     OR (dr.measurement_date - prev_abn_date) > 2
                     THEN 1 ELSE 0
            END AS new_block_flag
    FROM    abn_days dr
),
abn_days_grouped AS (
    SELECT  *,
            SUM(new_block_flag) OVER (
                PARTITION BY person_id, visit_occurrence_id
                ORDER BY     measurement_date)                        AS grp
    FROM    abn_days_flagged
),
aki_blocks AS (
    SELECT  person_id,
            visit_occurrence_id,
            MIN(measurement_date)                          AS block_start,
            MAX(measurement_date)                          AS block_end,
            COUNT(*)                                       AS block_days,
            MAX(scr_ratio)                                 AS max_ratio
    FROM    abn_days_grouped
    GROUP BY person_id, visit_occurrence_id, grp
),
aki_blocks_enhanced AS (
    SELECT  *,
            CASE WHEN max_ratio < 2.0  THEN 1
                 WHEN max_ratio <= 3.0 THEN 2
                 ELSE                      3 END          AS akin_stage,
            CASE WHEN block_days < 2   THEN 'tAKI'
                 ELSE                     'sAKI' END      AS aki_subtype
    FROM    aki_blocks
),
aki_rec AS (
    SELECT  person_id,
            visit_occurrence_id,
            COUNT(*) AS total_blocks
    FROM    aki_blocks
    GROUP BY person_id, visit_occurrence_id
),

/* ----------------------------------------------------------------
   SECTION 7 — Final cohort  (cases & controls, ESRD‑free)
-----------------------------------------------------------------*/
final_aki AS (
    SELECT  cv.person_id,
            cv.visit_occurrence_id,
            a.aki_status,
            CASE WHEN a.aki_status='AKI_YES' THEN 'CASE'
                 WHEN a.aki_status='AKI_NO'  THEN 'CONTROL'
                 ELSE NULL END                      AS case_control_flag,
            ab.block_start,
            ab.block_end,
            ab.akin_stage,
            ab.aki_subtype,
            ar.total_blocks
    FROM    candidate_visits cv
    LEFT    JOIN excluded_esrd ex
           ON ex.person_id=cv.person_id
          AND ex.visit_occurrence_id=cv.visit_occurrence_id
    JOIN    aki_status a
           ON a.person_id=cv.person_id
          AND a.visit_occurrence_id=cv.visit_occurrence_id
    LEFT    JOIN aki_blocks_enhanced ab
           ON ab.person_id=cv.person_id
          AND ab.visit_occurrence_id=cv.visit_occurrence_id
          AND ab.block_start = (
                SELECT MIN(block_start)
                FROM   aki_blocks
                WHERE  person_id=cv.person_id
                  AND  visit_occurrence_id=cv.visit_occurrence_id)
    LEFT    JOIN aki_rec ar
           ON ar.person_id=cv.person_id
          AND ar.visit_occurrence_id=cv.visit_occurrence_id
    WHERE   ex.person_id IS NULL          -- exclude prior ESRD
)

/* ----------------------------------------------------------------
   SECTION 8 — Output
-----------------------------------------------------------------*/
SELECT *
FROM   final_aki;
