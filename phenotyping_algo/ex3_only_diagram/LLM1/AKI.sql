/**********************************************************************
  Acute Kidney Injury (AKI) Phenotype – OMOP CDM v5.4
  --------------------------------------------------------------------
  • ESRD exclusion: any dialysis or kidney‑transplant code recorded
    before the presentation window (diagnostic OR procedural).
  • Baseline SCr: three‑line rule (median 7‑365 d, min 0‑7 d, same‑day min).
  • Abnormal kidney‑function day: SCr / Baseline ≥ 1.5  (≥ 50 % rise).
  • AKI block: consecutive abnormal days.
  • Recurrence: first abnormal day > 2 clean days after previous block.
  • Stage: max SCr/Baseline in block (1 = 1.5‑<2, 2 = 2‑≤3, 3 > 3).
  • Subtype: sAKI if block ≥ 2 days, else tAKI.
  • Output: one row per person with CASE / CONTROL flag.
**********************************************************************/

/* ===================================================================
   1.  HARD‑CODED CONCEPT SETS  (OMOP concept_id ONLY)
   -------------------------------------------------------------------
   • Use VALUES() so the list is explicit, stable and engine‑neutral.
   • Extend / replace the IDs below if your vocabulary set differs.
=================================================================== */
WITH
scr_meas(concept_id) AS (          -- Serum‑creatinine measurements
    VALUES (3016723), (3024561)
),
dialysis_concept(concept_id) AS (  -- Dialysis (diag or proc)
    VALUES (4029915), (4042913), (4282611)
),
kidney_tx_proc(concept_id) AS (    -- Kidney‑transplant procedures
    VALUES (2108184)
),

/* ===================================================================
   2.  CANDIDATE POOL  – has at least one serum‑creatinine result
=================================================================== */
candidates AS (
    SELECT DISTINCT person_id
    FROM measurement
    WHERE measurement_concept_id IN (SELECT concept_id FROM scr_meas)
),

/* ===================================================================
   3.  ESRD EXCLUSION – dialysis OR kidney‑transplant ever recorded
=================================================================== */
esrd_excl AS (
    SELECT DISTINCT person_id FROM (
        -- dialysis procedures
        SELECT person_id
        FROM procedure_occurrence
        WHERE procedure_concept_id IN (SELECT concept_id FROM dialysis_concept)
        UNION ALL
        -- dialysis diagnoses
        SELECT person_id
        FROM condition_occurrence
        WHERE condition_concept_id IN (SELECT concept_id FROM dialysis_concept)
        UNION ALL
        -- kidney transplant procedures
        SELECT person_id
        FROM procedure_occurrence
        WHERE procedure_concept_id IN (SELECT concept_id FROM kidney_tx_proc)
    ) x
),
eligible AS (
    SELECT person_id
    FROM candidates
    WHERE person_id NOT IN (SELECT person_id FROM esrd_excl)
),

/* ===================================================================
   4.  SERUM‑CREATININE TIMELINE  (one row per test)
=================================================================== */
scr AS (
    SELECT
        m.person_id,
        m.measurement_date          AS meas_date,
        m.value_as_number           AS scr_val
    FROM measurement m
    WHERE m.measurement_concept_id IN (SELECT concept_id FROM scr_meas)
      AND m.value_as_number IS NOT NULL
      AND m.person_id IN (SELECT person_id FROM eligible)
),

/* All presentation dates (distinct person‑date pairs) */
pres AS (
    SELECT DISTINCT person_id, meas_date FROM scr
),

/* ===================================================================
   5.  BASELINE SCr – THREE‑LINE RULE
=================================================================== */
baseline_raw AS (
    SELECT
        p.person_id,
        p.meas_date,
        -- 1️⃣ Median of SCr 7‑365 days prior
        COALESCE(
            (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY s.scr_val)
               FROM scr s
               WHERE s.person_id = p.person_id
                 AND s.meas_date BETWEEN p.meas_date - INTERVAL '365 day'
                                     AND p.meas_date - INTERVAL '7 day'),
            -- 2️⃣ Minimum SCr 0‑7 days prior
            (SELECT MIN(s.scr_val)
               FROM scr s
               WHERE s.person_id = p.person_id
                 AND s.meas_date BETWEEN p.meas_date - INTERVAL '7 day'
                                     AND p.meas_date),
            -- 3️⃣ Minimum SCr on the same day up to current sample
            (SELECT MIN(s2.scr_val)
               FROM scr s2
               WHERE s2.person_id = p.person_id
                 AND s2.meas_date = p.meas_date)
        ) AS baseline_scr
    FROM pres p
),
baseline AS (                      -- keep only dates with a baseline
    SELECT *
    FROM baseline_raw
    WHERE baseline_scr IS NOT NULL
),

/* ===================================================================
   6.  ABNORMAL DAYS  (SCr/Baseline ≥ 1.5)
=================================================================== */
abnormal AS (
    SELECT
        s.person_id,
        s.meas_date,
        s.scr_val,
        b.baseline_scr,
        s.scr_val / b.baseline_scr  AS ratio
    FROM scr s
    JOIN baseline b
      ON b.person_id = s.person_id
     AND b.meas_date = s.meas_date
    WHERE s.scr_val / b.baseline_scr >= 1.5
),

/* ===================================================================
   7.  AKI BLOCKS  – consecutive abnormal days
=================================================================== */
lagged AS (
    SELECT
        a.*,
        LAG(meas_date) OVER (PARTITION BY person_id ORDER BY meas_date) AS prev_date
    FROM abnormal a
),
flag_blocks AS (
    SELECT
        person_id,
        meas_date,
        ratio,
        CASE WHEN prev_date = meas_date - INTERVAL '1 day'
             THEN 0 ELSE 1 END AS new_block
    FROM lagged
),
blocks AS (
    SELECT
        person_id,
        meas_date,
        ratio,
        SUM(new_block) OVER (PARTITION BY person_id ORDER BY meas_date) AS block_id
    FROM flag_blocks
),

/* ===================================================================
   8.  BLOCK METRICS, STAGE & SUBTYPE
=================================================================== */
block_summary AS (
    SELECT
        person_id,
        block_id,
        MIN(meas_date)  AS block_start,
        MAX(meas_date)  AS block_end,
        MAX(ratio)      AS max_ratio,
        COUNT(*)        AS block_days
    FROM blocks
    GROUP BY person_id, block_id
),
block_classified AS (
    SELECT
        *,
        /* AKIN Stage by peak ratio */
        CASE
            WHEN max_ratio >  3.0 THEN 3
            WHEN max_ratio >= 2.0 THEN 2
            ELSE                       1
        END AS akin_stage,
        /* Subtype: sustained vs. transient */
        CASE
            WHEN block_days >= 2 THEN 'sAKI'
            ELSE                       'tAKI'
        END AS aki_subtype
    FROM block_summary
),

/* ===================================================================
   9.  RECURRENCE FLAG  – new block if gap > 2 clean days
=================================================================== */
block_rec AS (
    SELECT
        b.*,
        LAG(block_end) OVER (PARTITION BY person_id ORDER BY block_start) AS prev_end,
        CASE
            WHEN prev_end IS NULL THEN 0
            WHEN block_start > prev_end + INTERVAL '2 day' THEN 1
            ELSE 0
        END AS is_recurrence
    FROM block_classified b
),

/* ===================================================================
   10.  FINAL COHORTS
=================================================================== */
aki_cases AS (
    SELECT DISTINCT person_id FROM block_rec
),
controls AS (
    SELECT person_id
    FROM eligible
    WHERE person_id NOT IN (SELECT person_id FROM aki_cases)
)

/* ===================================================================
   11.  OUTPUT  – ONE ROW PER PERSON WITH CASE / CONTROL FLAG
=================================================================== */
SELECT person_id,
       'CASE'    AS aki_cohort_flag
FROM   aki_cases

UNION ALL

SELECT person_id,
       'CONTROL' AS aki_cohort_flag
FROM   controls
;
