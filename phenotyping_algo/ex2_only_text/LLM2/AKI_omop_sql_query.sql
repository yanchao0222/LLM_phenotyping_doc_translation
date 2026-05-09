-- =====================================================
-- EXECUTABLE AKI PHENOTYPING QUERY FOR OMOP CDM
-- Version: 1.0
-- Purpose: Identify AKI cases and controls from OMOP database
-- Based on KDIGO/AKIN Classification System
-- =====================================================

WITH exclusion_criteria AS (
    -- ===== ESRD EXCLUSION CRITERIA =====
    -- Patients with pre-existing kidney failure are excluded
    SELECT DISTINCT person_id
    FROM (
        -- Dialysis diagnosis codes (ICD-10)
        SELECT person_id 
        FROM condition_occurrence
        WHERE condition_concept_id IN (
            45552870, 45577822, 45575617, 45609389, 45590127, 45575620,
            45604584, 35224814, 1576113, 1576114, 45609945, 45585835,
            1576115, 45556841, 45566436, 45561671, 35225436
        )
        UNION
        -- Dialysis diagnosis codes (ICD-9)
        SELECT person_id 
        FROM condition_occurrence
        WHERE condition_concept_id IN (
            44830102, 44837448, 44826028, 44830633, 44824846, 44828407,
            44831843, 44836535, 44835472, 44831947, 44834280, 44822716,
            44829649, 44829650, 44833130, 44833131, 44835496, 44835497,
            44821578
        )
        UNION
        -- Kidney transplant diagnosis codes (ICD-10)
        SELECT person_id 
        FROM condition_occurrence
        WHERE condition_concept_id IN (
            1575308, 45546763, 45609393, 45599829, 45575625, 45537090,
            45595522, 35225404
        )
        UNION
        -- Kidney transplant diagnosis codes (ICD-9)
        SELECT person_id 
        FROM condition_occurrence
        WHERE condition_concept_id IN (44836487, 44821546)
        UNION
        -- Dialysis procedure codes (CPT4)
        SELECT person_id 
        FROM procedure_occurrence
        WHERE procedure_concept_id IN (
            2101833, 2101834, 2106278, 42736574, 2108276, 2108277, 2108297,
            2108299, 2108302, 42628575, 42627979, 42628018, 42628576, 42628058,
            42628580, 2108564, 2108566, 2108567, 2108568, 2109463, 2213572,
            2213573, 2213575, 2213576, 2213577, 2213578, 2213579, 2213580,
            2213581, 2213582, 2213583, 2213584, 2213585, 2213586, 2213587,
            2213588, 2213589, 2213590, 2213591, 2213592, 2213593, 2213594,
            2213595, 2213596, 2213597, 2213601, 2313999
        )
        UNION
        -- Dialysis procedure codes (ICD-10PCS)
        SELECT person_id 
        FROM procedure_occurrence
        WHERE procedure_concept_id = 2786488
        UNION
        -- Dialysis procedure codes (ICD-9)
        SELECT person_id 
        FROM procedure_occurrence
        WHERE procedure_concept_id IN (
            2002176, 2002189, 2002208, 2002209, 2002282, 2003564
        )
        UNION
        -- Kidney transplant procedure codes (CPT4)
        SELECT person_id 
        FROM procedure_occurrence
        WHERE procedure_concept_id IN (2109586, 2109587, 2109589)
        UNION
        -- Kidney transplant procedure codes (ICD-10PCS)
        SELECT person_id 
        FROM procedure_occurrence
        WHERE procedure_concept_id IN (
            2774517, 2774518, 2774519, 2774520, 2774521, 2774522
        )
        UNION
        -- Kidney transplant procedure codes (ICD-9)
        SELECT person_id 
        FROM procedure_occurrence
        WHERE procedure_concept_id IN (2003622, 2003624, 2003625, 2003626)
    ) esrd_patients
),

emergency_visits AS (
    -- ===== IDENTIFY EMERGENCY VISITS =====
    -- These serve as the presentation time windows for AKI detection
    SELECT 
        person_id,
        visit_occurrence_id,
        visit_start_date AS presentation_date,
        COALESCE(visit_end_date, DATEADD(day, 7, visit_start_date)) AS visit_end_date
    FROM visit_occurrence
    WHERE visit_concept_id = 9203  -- Emergency Room Visit
        AND person_id NOT IN (SELECT person_id FROM exclusion_criteria)
),

serum_creatinine AS (
    -- ===== EXTRACT SERUM CREATININE MEASUREMENTS =====
    -- Using LOINC codes for serum creatinine tests
    SELECT 
        person_id,
        measurement_date,
        AVG(value_as_number) AS scr_value  -- Average if multiple measurements per day
    FROM measurement
    WHERE measurement_concept_id IN (
        3018968,  -- Creatinine post dialysis
        3022243,  -- Creatinine pre dialysis
        3020564,  -- Creatinine [Moles/volume]
        3016723,  -- Creatinine [Mass/volume]
        3032033,  -- Creatinine [Mass or Moles/volume]
        3041716,  -- Creatinine baseline
        3041735,  -- Creatinine baseline [Moles/volume]
        3050951,  -- HEDIS 2009 Serum creatinine
        40760920, -- HEDIS 2010,2011 Serum creatinine
        40770372, -- HEDIS 2012,2013 Serum creatinine
        43055236, -- Creatinine pre contrast
        44786911, -- HEDIS 2014-2019 Serum creatinine
        46235076  -- Creatinine [Moles/volume] in Serum/Plasma/Blood
    )
    AND value_as_number IS NOT NULL
    AND value_as_number > 0
    AND value_as_number < 50  -- Remove implausible values
    GROUP BY person_id, measurement_date
),

baseline_calculations AS (
    -- ===== CALCULATE BASELINE SERUM CREATININE =====
    -- Three-tier priority system for each emergency visit
    SELECT 
        v.person_id,
        v.visit_occurrence_id,
        v.presentation_date,
        -- Priority 1: Median SCr 7-365 days before presentation
        (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY scr_value)
         FROM serum_creatinine s1
         WHERE s1.person_id = v.person_id
           AND s1.measurement_date >= DATEADD(day, -365, v.presentation_date)
           AND s1.measurement_date <= DATEADD(day, -7, v.presentation_date)
        ) AS priority1_median,
        -- Priority 2: Minimum SCr 0-7 days before presentation
        (SELECT MIN(scr_value)
         FROM serum_creatinine s2
         WHERE s2.person_id = v.person_id
           AND s2.measurement_date > DATEADD(day, -7, v.presentation_date)
           AND s2.measurement_date < v.presentation_date
        ) AS priority2_min,
        -- Priority 3: Minimum SCr from presentation onwards
        (SELECT MIN(scr_value)
         FROM serum_creatinine s3
         WHERE s3.person_id = v.person_id
           AND s3.measurement_date >= v.presentation_date
        ) AS priority3_min
    FROM emergency_visits v
),

baseline_scr AS (
    -- ===== FINALIZE BASELINE VALUES =====
    SELECT 
        person_id,
        visit_occurrence_id,
        presentation_date,
        COALESCE(priority1_median, priority2_min, priority3_min) AS baseline_value
    FROM baseline_calculations
),

daily_aki_assessment AS (
    -- ===== ASSESS AKI STATUS FOR EACH DAY =====
    SELECT 
        v.person_id,
        v.visit_occurrence_id,
        v.presentation_date,
        s.measurement_date,
        s.scr_value,
        b.baseline_value,
        CASE 
            WHEN b.baseline_value > 0 THEN s.scr_value / b.baseline_value
            ELSE NULL
        END AS scr_ratio,
        CASE 
            WHEN b.baseline_value > 0 AND s.scr_value >= 1.5 * b.baseline_value THEN 1
            ELSE 0
        END AS aki_flag,
        -- AKIN staging
        CASE 
            WHEN b.baseline_value > 0 AND s.scr_value / b.baseline_value >= 3 THEN 3
            WHEN b.baseline_value > 0 AND s.scr_value / b.baseline_value >= 2 THEN 2
            WHEN b.baseline_value > 0 AND s.scr_value / b.baseline_value >= 1.5 THEN 1
            ELSE 0
        END AS akin_stage
    FROM emergency_visits v
    INNER JOIN baseline_scr b 
        ON v.person_id = b.person_id 
        AND v.visit_occurrence_id = b.visit_occurrence_id
    INNER JOIN serum_creatinine s 
        ON v.person_id = s.person_id
        AND s.measurement_date >= v.presentation_date
        AND s.measurement_date <= v.visit_end_date
    WHERE b.baseline_value IS NOT NULL
),

aki_with_gaps AS (
    -- ===== IDENTIFY GAPS BETWEEN AKI DAYS =====
    SELECT 
        *,
        LAG(measurement_date) OVER (
            PARTITION BY person_id, visit_occurrence_id 
            ORDER BY measurement_date
        ) AS prev_date,
        LAG(aki_flag) OVER (
            PARTITION BY person_id, visit_occurrence_id 
            ORDER BY measurement_date
        ) AS prev_aki_flag
    FROM daily_aki_assessment
),

aki_blocks_identified AS (
    -- ===== IDENTIFY AKI BLOCKS =====
    -- New block starts when: first AKI day OR >2 days since last AKI
    SELECT 
        *,
        SUM(CASE 
            WHEN aki_flag = 1 AND (
                prev_aki_flag = 0 
                OR prev_aki_flag IS NULL
                OR DATEDIFF(day, prev_date, measurement_date) > 2
            ) THEN 1 
            ELSE 0 
        END) OVER (
            PARTITION BY person_id, visit_occurrence_id 
            ORDER BY measurement_date
        ) AS block_id
    FROM aki_with_gaps
),

aki_blocks AS (
    -- ===== SUMMARIZE AKI BLOCKS =====
    SELECT 
        person_id,
        visit_occurrence_id,
        presentation_date,
        block_id,
        MIN(measurement_date) AS block_start,
        MAX(measurement_date) AS block_end,
        MAX(akin_stage) AS max_akin_stage,
        COUNT(DISTINCT measurement_date) AS block_days
    FROM aki_blocks_identified
    WHERE aki_flag = 1
    GROUP BY person_id, visit_occurrence_id, presentation_date, block_id
),

aki_characterization AS (
    -- ===== CHARACTERIZE AKI SEVERITY AND SUBTYPE =====
    SELECT 
        person_id,
        visit_occurrence_id,
        presentation_date,
        block_id,
        block_start,
        block_end,
        max_akin_stage,
        -- Subtype based on duration
        CASE 
            WHEN DATEDIFF(day, block_start, block_end) < 2 THEN 'Transient'
            ELSE 'Sustained'
        END AS aki_subtype,
        -- Rank blocks by start date
        ROW_NUMBER() OVER (
            PARTITION BY person_id, visit_occurrence_id 
            ORDER BY block_start
        ) AS block_rank
    FROM aki_blocks
),

aki_summary AS (
    -- ===== SUMMARIZE AKI FOR EACH VISIT =====
    -- Use first AKI block characteristics for overall phenotype
    SELECT 
        person_id,
        visit_occurrence_id,
        presentation_date,
        MAX(CASE WHEN block_rank = 1 THEN max_akin_stage END) AS aki_severity,
        MAX(CASE WHEN block_rank = 1 THEN aki_subtype END) AS aki_subtype,
        COUNT(DISTINCT block_id) AS recurrence_count
    FROM aki_characterization
    GROUP BY person_id, visit_occurrence_id, presentation_date
)

-- ===== FINAL OUTPUT: AKI CASES AND CONTROLS =====
SELECT 
    v.person_id,
    v.visit_occurrence_id,
    v.presentation_date,
    -- Primary phenotype classification
    CASE 
        WHEN b.baseline_value IS NULL THEN 'AKI_UNKNOWN'
        WHEN a.aki_severity IS NOT NULL THEN 'AKI_CASE'
        ELSE 'NO_AKI'
    END AS aki_phenotype,
    -- Detailed AKI characteristics (NULL for controls)
    a.aki_severity AS akin_stage,
    a.aki_subtype,
    a.recurrence_count,
    -- Supporting information
    b.baseline_value AS baseline_creatinine
FROM emergency_visits v
LEFT JOIN baseline_scr b 
    ON v.person_id = b.person_id 
    AND v.visit_occurrence_id = b.visit_occurrence_id
LEFT JOIN aki_summary a 
    ON v.person_id = a.person_id 
    AND v.visit_occurrence_id = a.visit_occurrence_id
ORDER BY v.person_id, v.presentation_date;

-- =====================================================
-- OUTPUT INTERPRETATION:
-- aki_phenotype = 'AKI_CASE': Patient had AKI during visit
-- aki_phenotype = 'NO_AKI': Patient did not have AKI (control)
-- aki_phenotype = 'AKI_UNKNOWN': Cannot determine (no baseline)
-- akin_stage: 1, 2, or 3 (severity, only for cases)
-- aki_subtype: 'Transient' (<48 hours) or 'Sustained' (>=48 hours)
-- recurrence_count: Number of separate AKI episodes
-- =====================================================