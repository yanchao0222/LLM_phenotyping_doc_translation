-- =====================================================
-- ACUTE KIDNEY INJURY (AKI) PHENOTYPING QUERY
-- FOR OMOP COMMON DATA MODEL
-- =====================================================
-- This query identifies AKI cases and controls with staging and subtyping
-- Based on serum creatinine measurements and temporal patterns
-- Following the algorithm from the provided flowchart

-- Define the presentation time window for analysis
-- Adjust these dates based on your study period
WITH presentation_window AS (
    SELECT 
        DATE '2020-01-01' AS study_start_date,
        DATE '2023-12-31' AS study_end_date
),

-- =====================================================
-- IDENTIFY ALL PATIENTS IN THE PRESENTATION TIME WINDOW
-- =====================================================
all_patients AS (
    SELECT DISTINCT
        vo.person_id,
        MIN(vo.visit_start_date) AS presentation_start_date,
        MAX(COALESCE(vo.visit_end_date, vo.visit_start_date)) AS presentation_end_date
    FROM 
        visit_occurrence vo
    CROSS JOIN 
        presentation_window pw
    WHERE 
        vo.visit_start_date >= pw.study_start_date
        AND vo.visit_start_date <= pw.study_end_date
    GROUP BY 
        vo.person_id
),

-- =====================================================
-- STEP 1: CHECK FOR KIDNEY TRANSPLANT OR DIALYSIS BEFORE PRESENTATION
-- =====================================================
-- Identify ESRD patients for exclusion
esrd_exclusions AS (
    -- Kidney transplant from conditions
    SELECT DISTINCT 
        co.person_id
    FROM 
        condition_occurrence co
    INNER JOIN 
        all_patients ap ON co.person_id = ap.person_id
    INNER JOIN
        concept c ON co.condition_concept_id = c.concept_id
    WHERE 
        (
            -- Using concept hierarchies for kidney transplant
            co.condition_concept_id IN (
                42539502,  -- History of kidney transplant
                4340306,   -- Kidney transplant
                4239233,   -- Renal transplant status
                4322471    -- Complication of kidney transplant
            )
            OR LOWER(c.concept_name) LIKE '%kidney transplant%'
            OR LOWER(c.concept_name) LIKE '%renal transplant%'
        )
        AND co.condition_start_date < ap.presentation_start_date
    
    UNION
    
    -- Kidney transplant from procedures
    SELECT DISTINCT 
        po.person_id
    FROM 
        procedure_occurrence po
    INNER JOIN 
        all_patients ap ON po.person_id = ap.person_id
    INNER JOIN
        concept c ON po.procedure_concept_id = c.concept_id
    WHERE 
        (
            po.procedure_concept_id IN (
                4146256,   -- Kidney transplantation
                4322471,   -- Transplantation of kidney
                4021780,   -- Allotransplantation of kidney
                4180347    -- Cadaveric renal transplant
            )
            OR LOWER(c.concept_name) LIKE '%kidney transplant%'
            OR LOWER(c.concept_name) LIKE '%renal transplant%'
        )
        AND po.procedure_date < ap.presentation_start_date
    
    UNION
    
    -- Dialysis procedures
    SELECT DISTINCT 
        po.person_id
    FROM 
        procedure_occurrence po
    INNER JOIN 
        all_patients ap ON po.person_id = ap.person_id
    INNER JOIN
        concept c ON po.procedure_concept_id = c.concept_id
    WHERE 
        (
            po.procedure_concept_id IN (
                4027133,   -- Dialysis procedure
                4032640,   -- Hemodialysis
                4019829,   -- Peritoneal dialysis
                4353741,   -- Continuous renal replacement therapy
                4031139    -- Renal dialysis
            )
            OR LOWER(c.concept_name) LIKE '%dialysis%'
        )
        AND po.procedure_date < ap.presentation_start_date
),

-- =====================================================
-- ELIGIBLE PATIENTS (EXCLUDE ESRD)
-- =====================================================
eligible_patients AS (
    SELECT 
        ap.person_id,
        ap.presentation_start_date,
        ap.presentation_end_date
    FROM 
        all_patients ap
    WHERE 
        -- Exclude ESRD patients
        ap.person_id NOT IN (SELECT person_id FROM esrd_exclusions)
),

-- =====================================================
-- STEP 2: EXTRACT ALL SERUM CREATININE (SCr) MEASUREMENTS
-- =====================================================
scr_measurements AS (
    SELECT 
        ep.person_id,
        ep.presentation_start_date,
        ep.presentation_end_date,
        m.measurement_date,
        m.value_as_number AS scr_value
    FROM 
        eligible_patients ep
    INNER JOIN 
        measurement m ON ep.person_id = m.person_id
    WHERE 
        m.measurement_concept_id IN (
            3016723,   -- Creatinine serum/plasma
            3051825,   -- Creatinine [Mass/volume] in Serum or Plasma
            37071652,  -- Serum creatinine
            3020564    -- Creatinine [Mass/volume] in Blood
        )
        AND m.value_as_number IS NOT NULL
        AND m.value_as_number > 0
        AND m.value_as_number < 30  -- Remove obvious outliers
),

-- =====================================================
-- STEP 3: DEFINE BASELINE SCr FOR EACH PRESENTATION
-- =====================================================
-- Using hierarchical approach: 1st Line -> 2nd Line -> 3rd Line
baseline_scr AS (
    SELECT 
        ep.person_id,
        ep.presentation_start_date,
        ep.presentation_end_date,
        COALESCE(
            -- 1st Line: Median SCr in 7-365 days before the presentation
            (
                SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY scr_value)
                FROM scr_measurements sm1
                WHERE sm1.person_id = ep.person_id
                AND sm1.measurement_date > (ep.presentation_start_date - INTERVAL '365 day')
                AND sm1.measurement_date <= (ep.presentation_start_date - INTERVAL '7 day')
            ),
            -- 2nd Line: Min SCr between 0-7 days before the presentation
            (
                SELECT MIN(scr_value)
                FROM scr_measurements sm2
                WHERE sm2.person_id = ep.person_id
                AND sm2.measurement_date > (ep.presentation_start_date - INTERVAL '7 day')
                AND sm2.measurement_date <= ep.presentation_start_date
            ),
            -- 3rd Line: Min SCr from the presentation to the SCr under consideration
            (
                SELECT MIN(scr_value)
                FROM scr_measurements sm3
                WHERE sm3.person_id = ep.person_id
                AND sm3.measurement_date >= ep.presentation_start_date
                AND sm3.measurement_date <= ep.presentation_end_date
            )
        ) AS baseline_scr_value
    FROM 
        eligible_patients ep
),

-- =====================================================
-- STEP 4: CHECK DATA SUFFICIENCY AND CALCULATE KIDNEY FUNCTION
-- =====================================================
-- Calculate daily kidney excretory function loss (SCr / Baseline SCr)
daily_kidney_function AS (
    SELECT 
        sm.person_id,
        sm.measurement_date,
        sm.scr_value,
        bs.baseline_scr_value,
        CASE 
            WHEN bs.baseline_scr_value IS NULL THEN NULL
            WHEN bs.baseline_scr_value = 0 THEN NULL
            ELSE sm.scr_value / bs.baseline_scr_value 
        END AS scr_ratio
    FROM 
        scr_measurements sm
    INNER JOIN 
        baseline_scr bs ON sm.person_id = bs.person_id 
        AND sm.presentation_start_date = bs.presentation_start_date
),

-- =====================================================
-- STEP 5: DETERMINE IF ANY DAILY KIDNEY FUNCTION IS ABNORMAL
-- =====================================================
-- Abnormal defined as >=50% SCr increase from Baseline (ratio >= 1.5)
patient_aki_status_initial AS (
    SELECT 
        ep.person_id,
        CASE 
            -- Check if sufficient data available
            WHEN bs.baseline_scr_value IS NULL THEN 'Unknown'
            -- Check if any SCr ratio >= 1.5 (50% increase)
            WHEN EXISTS (
                SELECT 1 
                FROM daily_kidney_function dkf
                WHERE dkf.person_id = ep.person_id
                AND dkf.scr_ratio >= 1.5
            ) THEN 'AKI'
            ELSE 'No AKI'
        END AS aki_status
    FROM 
        eligible_patients ep
    LEFT JOIN 
        baseline_scr bs ON ep.person_id = bs.person_id
),

-- =====================================================
-- STEP 6: DEFINE AKI BLOCKS AND AKI RECURRENCE
-- =====================================================
-- AKI Blocks: consecutive days with SCr higher than 50% baseline
-- AKI Recurrence: SCr >50% baseline more than 2 days after previous block
aki_days_with_gaps AS (
    SELECT 
        person_id,
        measurement_date,
        scr_value,
        baseline_scr_value,
        scr_ratio,
        -- Check if this starts a new block
        CASE 
            WHEN scr_ratio >= 1.5 AND (
                LAG(scr_ratio, 1) OVER (PARTITION BY person_id ORDER BY measurement_date) < 1.5
                OR LAG(measurement_date, 1) OVER (PARTITION BY person_id ORDER BY measurement_date) < (measurement_date - INTERVAL '2 day')
                OR LAG(scr_ratio, 1) OVER (PARTITION BY person_id ORDER BY measurement_date) IS NULL
            ) THEN 1
            ELSE 0
        END AS new_block_flag
    FROM 
        daily_kidney_function
    WHERE 
        scr_ratio IS NOT NULL
),

aki_blocks AS (
    SELECT 
        person_id,
        measurement_date,
        scr_value,
        baseline_scr_value,
        scr_ratio,
        SUM(new_block_flag) OVER (PARTITION BY person_id ORDER BY measurement_date) AS block_id
    FROM 
        aki_days_with_gaps
    WHERE 
        scr_ratio >= 1.5  -- Only keep abnormal days
),

-- =====================================================
-- STEP 7: DETERMINE AKI STAGE FOR EACH BLOCK
-- =====================================================
-- Based on Max Block SCr compared to Baseline SCr
aki_staging AS (
    SELECT 
        person_id,
        block_id,
        MIN(measurement_date) AS block_start_date,
        MAX(measurement_date) AS block_end_date,
        COUNT(*) AS measurements_in_block,
        MAX(scr_ratio) AS max_block_scr_ratio,
        MAX(scr_value) AS max_scr_value,
        MIN(baseline_scr_value) AS baseline_scr_value,
        -- AKI Staging
        CASE 
            WHEN MAX(scr_ratio) >= 3 THEN 3        -- Stage 3: >3-fold increase
            WHEN MAX(scr_ratio) >= 2 THEN 2        -- Stage 2: 2- to 3-fold increase
            WHEN MAX(scr_ratio) >= 1.5 THEN 1      -- Stage 1: >=1.5- to 2-fold increase
        END AS aki_stage
    FROM 
        aki_blocks
    GROUP BY 
        person_id, block_id
),

-- =====================================================
-- STEP 8: DETERMINE AKI SUBTYPE (sAKI vs tAKI)
-- =====================================================
-- Based on temporal pattern from the flowchart matrix
aki_subtype_determination AS (
    SELECT 
        ab.person_id,
        ab.block_id,
        s.aki_stage,
        s.block_start_date,
        s.block_end_date,
        s.max_block_scr_ratio,
        s.baseline_scr_value,
        -- Count days with measurements in the block
        COUNT(DISTINCT ab.measurement_date) AS distinct_days,
        -- Check pattern for subtyping
        CASE
            -- sAKI: Sustained pattern (Yes-Yes-Yes in early consecutive days)
            WHEN COUNT(DISTINCT ab.measurement_date) >= 3 
                AND (MAX(ab.measurement_date) - MIN(ab.measurement_date)) <= 4
            THEN 'sAKI'
            -- tAKI: Transient pattern (Yes-NA-NA-No or non-sustained)
            ELSE 'tAKI'
        END AS aki_subtype
    FROM 
        aki_blocks ab
    INNER JOIN 
        aki_staging s ON ab.person_id = s.person_id AND ab.block_id = s.block_id
    GROUP BY 
        ab.person_id, ab.block_id, s.aki_stage, s.block_start_date, 
        s.block_end_date, s.max_block_scr_ratio, s.baseline_scr_value
)

-- =====================================================
-- FINAL OUTPUT: AKI STAGE AND SUBTYPE FOR EACH AKI BLOCK
-- =====================================================
SELECT 
    p.person_id,
    p.gender_concept_id,
    EXTRACT(YEAR FROM ep.presentation_start_date) - p.year_of_birth AS age_at_presentation,
    ep.presentation_start_date,
    ep.presentation_end_date,
    
    -- Phenotype classification
    pas.aki_status AS phenotype_status,
    CASE 
        WHEN pas.aki_status = 'Unknown' THEN 'Excluded - Insufficient Data'
        WHEN pas.aki_status = 'AKI' THEN 'Case'
        WHEN pas.aki_status = 'No AKI' THEN 'Control'
    END AS phenotype_category,
    
    -- For AKI cases: provide detailed information
    ast.block_id AS aki_block_number,
    ast.block_start_date AS aki_block_start,
    ast.block_end_date AS aki_block_end,
    ast.aki_stage,
    ast.aki_subtype,
    ast.max_block_scr_ratio,
    ast.baseline_scr_value,
    
    -- Summary statistics
    CASE 
        WHEN pas.aki_status = 'AKI' THEN 
            (SELECT COUNT(DISTINCT block_id) FROM aki_subtype_determination WHERE person_id = p.person_id)
        ELSE NULL
    END AS total_aki_blocks,
    
    CASE 
        WHEN pas.aki_status = 'AKI' THEN 
            (SELECT MAX(aki_stage) FROM aki_subtype_determination WHERE person_id = p.person_id)
        ELSE NULL
    END AS max_aki_stage

FROM 
    eligible_patients ep
INNER JOIN 
    person p ON ep.person_id = p.person_id
INNER JOIN 
    patient_aki_status_initial pas ON ep.person_id = pas.person_id
LEFT JOIN 
    aki_subtype_determination ast ON ep.person_id = ast.person_id

ORDER BY 
    phenotype_category,
    p.person_id,
    aki_block_number;