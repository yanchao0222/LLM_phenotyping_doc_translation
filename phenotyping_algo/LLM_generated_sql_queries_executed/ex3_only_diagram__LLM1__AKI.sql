-- Rule 1 (VUMC-specific database name): APPLIED (all tables use victr_sd.sd_omop_prod)
-- Rule 2 (wildcard fix): NOT APPLICABLE
-- Rule 3 (search concepts in clinical tables): APPLIED (see SCr and dialysis/kidney transplant logic)
-- Rule 4 (LOINC join for measurement): APPLIED (now uses correct LOINC codes for SCr)
-- Rule 5 (free-text LIKE): NOT APPLICABLE
-- Rule 6 (OR -> UNION): APPLIED (see esrd_excl)
-- Rule 7 (LEFT JOIN -> UNION): APPLIED (see esrd_excl)
-- Rule 8 (remove NLP): NOT APPLICABLE
-- Rule 9 (missing concept): NOT APPLICABLE
-- FIX: SCr measurement_concept_id filter now uses join to concept for LOINC codes, using correct LOINC codes for OMOP concept_ids 3016723 and 3024561

CREATE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex3_only_diagram_LLM1_AKI AS 

WITH
scr_loinc AS (
    -- REVISED (was: VALUES (3016723), (3024561))
    SELECT concept_code FROM victr_sd.sd_omop_prod.concept WHERE concept_id IN (3016723, 3024561) AND vocabulary_id = 'LOINC'
),
dialysis_concept(concept_id) AS (
    VALUES (4029915), (4042913), (4282611)
),
kidney_tx_proc(concept_id) AS (
    VALUES (2108184)
),

candidates AS (
    SELECT DISTINCT m.person_id
    FROM victr_sd.sd_omop_prod.measurement m
    -- REVISED (was: JOIN victr_sd.sd_omop_prod.concept c ON m.measurement_concept_id = c.concept_id WHERE c.vocabulary_id = 'LOINC' AND c.concept_code IN ('3016723', '3024561'))
    JOIN victr_sd.sd_omop_prod.concept c ON m.measurement_concept_id = c.concept_id
    WHERE c.vocabulary_id = 'LOINC' AND c.concept_code IN (SELECT concept_code FROM scr_loinc)
),

esrd_excl AS (
    SELECT DISTINCT person_id FROM (
        -- dialysis procedures
        SELECT po.person_id
        FROM victr_sd.sd_omop_prod.procedure_occurrence po
        WHERE po.procedure_concept_id IN (SELECT concept_id FROM dialysis_concept)
        UNION ALL
        -- dialysis diagnoses
        SELECT co.person_id
        FROM victr_sd.sd_omop_prod.condition_occurrence co
        WHERE co.condition_concept_id IN (SELECT concept_id FROM dialysis_concept)
        UNION ALL
        -- kidney transplant procedures
        SELECT po2.person_id
        FROM victr_sd.sd_omop_prod.procedure_occurrence po2
        WHERE po2.procedure_concept_id IN (SELECT concept_id FROM kidney_tx_proc)
    ) x
),
eligible AS (
    SELECT person_id
    FROM candidates
    WHERE person_id NOT IN (SELECT person_id FROM esrd_excl)
),

scr AS (
    SELECT
        m.person_id,
        m.measurement_date          AS meas_date,
        m.value_as_number           AS scr_val
    FROM victr_sd.sd_omop_prod.measurement m
    -- REVISED (was: JOIN victr_sd.sd_omop_prod.concept c ON m.measurement_concept_id = c.concept_id WHERE c.vocabulary_id = 'LOINC' AND c.concept_code IN ('3016723', '3024561'))
    JOIN victr_sd.sd_omop_prod.concept c ON m.measurement_concept_id = c.concept_id
    WHERE c.vocabulary_id = 'LOINC' AND c.concept_code IN (SELECT concept_code FROM scr_loinc)
      AND m.value_as_number IS NOT NULL
      AND m.person_id IN (SELECT person_id FROM eligible)
),

pres AS (
    SELECT DISTINCT person_id, meas_date FROM scr
),

baseline_raw AS (
    SELECT
        p.person_id,
        p.meas_date,
        COALESCE(
            (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY s.scr_val)
               FROM scr s
               WHERE s.person_id = p.person_id
                 AND s.meas_date BETWEEN DATE_ADD(p.meas_date, -365) AND DATE_ADD(p.meas_date, -7)),
            (SELECT MIN(s.scr_val)
               FROM scr s
               WHERE s.person_id = p.person_id
                 AND s.meas_date BETWEEN DATE_ADD(p.meas_date, -7) AND p.meas_date),
            (SELECT MIN(s2.scr_val)
               FROM scr s2
               WHERE s2.person_id = p.person_id
                 AND s2.meas_date = p.meas_date)
        ) AS baseline_scr
    FROM pres p
),
baseline AS (
    SELECT *
    FROM baseline_raw
    WHERE baseline_scr IS NOT NULL
),

abnormal AS (
    SELECT
        s.person_id,
        s.meas_date,
        s.scr_val,
        b.baseline_scr,
        try_divide(s.scr_val,b.baseline_scr)  AS ratio
    FROM scr s
    JOIN baseline b
      ON b.person_id = s.person_id
     AND b.meas_date = s.meas_date
    WHERE try_divide(s.scr_val,b.baseline_scr) >= 1.5
),

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
        CASE WHEN prev_date = DATE_ADD(meas_date, -1)
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
        CASE
            WHEN max_ratio >  3.0 THEN 3
            WHEN max_ratio >= 2.0 THEN 2
            ELSE                       1
        END AS akin_stage,
        CASE
            WHEN block_days >= 2 THEN 'sAKI'
            ELSE                       'tAKI'
        END AS aki_subtype
    FROM block_summary
),

block_rec AS (
    SELECT
        b.*,
        LAG(block_end) OVER (PARTITION BY person_id ORDER BY block_start) AS prev_end,
        CASE
            WHEN prev_end IS NULL THEN 0
            WHEN block_start > DATE_ADD(prev_end, 2) THEN 1
            ELSE 0
        END AS is_recurrence
    FROM block_classified b
),

aki_cases AS (
    SELECT DISTINCT person_id FROM block_rec
),
controls AS (
    SELECT person_id
    FROM eligible
    WHERE person_id NOT IN (SELECT person_id FROM aki_cases)
)

SELECT person_id,
       'CASE'    AS aki_cohort_flag
FROM   aki_cases

UNION ALL

SELECT person_id,
       'CONTROL' AS aki_cohort_flag
FROM   controls
