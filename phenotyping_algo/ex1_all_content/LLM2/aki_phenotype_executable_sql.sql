-- =====================================================
-- ACUTE KIDNEY INJURY (AKI) PHENOTYPING ALGORITHM
-- Executable Query for OMOP CDM Database
-- Based on KDIGO/AKIN Classification
-- Version 1.0 - Corrected and Verified
-- =====================================================
-- This query identifies AKI cases and controls from an OMOP CDM database
-- Output: person_id, visit_occurrence_id, phenotype classification, AKI staging and subtyping
-- =====================================================

WITH 
-- -----------------------------------------------------
-- STEP 1: IDENTIFY ESRD EXCLUSIONS
-- Patients with kidney transplant or dialysis before/during visit
-- Using actual concept_id values from the coding file
-- -----------------------------------------------------
esrd_exclusions AS (
    SELECT DISTINCT person_id, visit_occurrence_id
    FROM (
        -- Dialysis ICD10 diagnosis codes
        SELECT co.person_id, co.visit_occurrence_id
        FROM condition_occurrence co
        WHERE co.condition_concept_id IN (
            45552870, 45577822, 45575617, 45609389, 45590127, 45575620,
            45604584, 35224814, 1576113, 1576114, 45609945, 45585835,
            1576115, 45556841, 45566436, 45561671, 35225436
        )
        
        UNION
        
        -- Dialysis ICD9 diagnosis codes
        SELECT co.person_id, co.visit_occurrence_id
        FROM condition_occurrence co
        WHERE co.condition_concept_id IN (
            44830102, 44837448, 44826028, 44830633, 44824846, 44828407,
            44831843, 44836535, 44835472, 44831947, 44834280, 44822716,
            44829649, 44829650, 44833130, 44833131, 44835496, 44835497,
            44821578
        )
        
        UNION
        
        -- Kidney transplant ICD10 diagnosis codes
        SELECT co.person_id, co.visit_occurrence_id
        FROM condition_occurrence co
        WHERE co.condition_concept_id IN (
            1575308, 45546763, 45609393, 45599829, 45575625, 45537090,
            45595522, 35225404
        )
        
        UNION
        
        -- Kidney transplant ICD9 diagnosis codes
        SELECT co.person_id, co.visit_occurrence_id
        FROM condition_occurrence co
        WHERE co.condition_concept_id IN (
            44836487, 44821546
        )
        
        UNION
        
        -- Dialysis CPT4 procedure codes
        SELECT po.person_id, po.visit_occurrence_id
        FROM procedure_occurrence po
        WHERE po.procedure_concept_id IN (
            2101833, 2101834, 2106278, 42736574, 2108276, 2108277,
            2108297, 2108299, 2108302, 42628575, 42627979, 42628018,
            42628576, 42628058, 42628580, 2108564, 2108566, 2108567,
            2108568, 2109463, 2213572, 2213573, 2213575, 2213576,
            2213577, 2213578, 2213579, 2213580, 2213581, 2213582,
            2213583, 2213584, 2213585, 2213586, 2213587, 2213588,
            2213589, 2213590, 2213591, 2213592, 2213593, 2213594,
            2213595, 2213596, 2213597, 2213601, 2313999
        )
        
        UNION
        
        -- Dialysis ICD10PCS procedure codes
        SELECT po.person_id, po.visit_occurrence_id
        FROM procedure_occurrence po
        WHERE po.procedure_concept_id IN (
            2786488
        )
        
        UNION
        
        -- Dialysis ICD9 procedure codes
        SELECT po.person_id, po.visit_occurrence_id
        FROM procedure_occurrence po
        WHERE po.procedure_concept_id IN (
            2002176, 2002189, 2002208, 2002209, 2002282, 2003564
        )
        
        UNION
        
        -- Kidney transplant CPT4 procedure codes
        SELECT po.person_id, po.visit_occurrence_id
        FROM procedure_occurrence po
        WHERE po.procedure_concept_id IN (
            2109586, 2109587, 2109589
        )
        
        UNION
        
        -- Kidney transplant ICD10PCS procedure codes
        SELECT po.person_id, po.visit_occurrence_id
        FROM procedure_occurrence po
        WHERE po.procedure_concept_id IN (
            2774517, 2774518, 2774519, 2774520, 2774521, 2774522
        )
        
        UNION
        
        -- Kidney transplant ICD9 procedure codes
        SELECT po.person_id, po.visit_occurrence_id
        FROM procedure_occurrence po
        WHERE po.procedure_concept_id IN (
            2003622, 2003624, 2003625, 2003626
        )
        
        UNION
        
        -- Dialysis-related observations (codes that mapped to Observation domain)
        SELECT o.person_id, o.visit_occurrence_id
        FROM observation o
        WHERE o.observation_concept_id IN (
            -- These CPT4 codes mapped to Observation domain
            2101833, 2101834, 2106278, 2108564, 2108566, 2108567, 2108568,
            2213578, 2213579, 2213580, 2213581, 2213582, 2213583, 2213584,
            2213585, 2213586, 2213587, 2213588, 2213589, 2213590, 2213591,
            2213592, 2213593, 2213594, 2213595, 2213596, 2213597
        )
    ) esrd_all
),

-- -----------------------------------------------------
-- STEP 2: EXTRACT ALL SERUM CREATININE MEASUREMENTS
-- Using LOINC concept_id values from coding file
-- -----------------------------------------------------
scr_measurements AS (
    SELECT 
        m.person_id,
        m.visit_occurrence_id,
        m.measurement_date,
        m.measurement_datetime,
        m.value_as_number as scr_value,
        v.visit_start_date,
        v.visit_end_date
    FROM measurement m
    INNER JOIN visit_occurrence v
        ON m.visit_occurrence_id = v.visit_occurrence_id
    WHERE m.measurement_concept_id IN (
        3018968,  -- 11041-1: Creatinine post dialysis
        3022243,  -- 11042-9: Creatinine pre dialysis
        3020564,  -- 14682-9: Creatinine [Moles/volume]
        3016723,  -- 2160-0: Creatinine [Mass/volume]
        3032033,  -- 35203-9: Creatinine [Mass or Moles/volume]
        3041716,  -- 40248-7: Creatinine baseline
        3041735,  -- 40264-4: Creatinine [Moles/volume] baseline
        3050951,  -- 54052-6: HEDIS 2009 SCr
        40760920, -- 57811-2: HEDIS 2010,2011 SCr
        40770372, -- 67764-1: HEDIS 2012,2013 SCr
        43055236, -- 72271-0: Creatinine pre contrast
        44786911, -- 74256-9: HEDIS 2014-2019 SCr
        46235076  -- 77140-2: Creatinine [Moles/volume] in Serum/Plasma/Blood
    )
    AND m.value_as_number IS NOT NULL
    AND m.value_as_number > 0
),

-- -----------------------------------------------------
-- STEP 3: CALCULATE BASELINE SCR FOR EACH MEASUREMENT
-- Using 3-tier priority system as specified in algorithm
-- -----------------------------------------------------
baseline_scr_calculation AS (
    SELECT 
        s.person_id,
        s.visit_occurrence_id,
        s.measurement_date,
        s.scr_value,
        s.visit_start_date,
        -- Priority 1: Median SCr in 7-365 days before visit start
        (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY b1.scr_value)
         FROM scr_measurements b1
         WHERE b1.person_id = s.person_id
         AND b1.measurement_date > DATEADD(day, -365, s.visit_start_date) 
         AND b1.measurement_date <= DATEADD(day, -7, s.visit_start_date)) as baseline_priority_1,
        -- Priority 2: Min SCr between 0-7 days before visit start
        (SELECT MIN(b2.scr_value)
         FROM scr_measurements b2
         WHERE b2.person_id = s.person_id
         AND b2.measurement_date > DATEADD(day, -7, s.visit_start_date)
         AND b2.measurement_date <= s.visit_start_date) as baseline_priority_2,
        -- Priority 3: Min SCr from visit start to current measurement
        (SELECT MIN(b3.scr_value)
         FROM scr_measurements b3
         WHERE b3.person_id = s.person_id
         AND b3.visit_occurrence_id = s.visit_occurrence_id
         AND b3.measurement_date >= s.visit_start_date
         AND b3.measurement_date <= s.measurement_date) as baseline_priority_3
    FROM scr_measurements s
),

baseline_scr AS (
    SELECT 
        person_id,
        visit_occurrence_id,
        measurement_date,
        scr_value,
        visit_start_date,
        -- Use COALESCE to select baseline by priority order
        COALESCE(baseline_priority_1, baseline_priority_2, baseline_priority_3) as baseline_scr
    FROM baseline_scr_calculation
),

-- -----------------------------------------------------
-- STEP 4: CALCULATE DAILY KIDNEY FUNCTION
-- Average SCr for days with multiple measurements
-- -----------------------------------------------------
daily_scr AS (
    SELECT 
        person_id,
        visit_occurrence_id,
        measurement_date,
        AVG(scr_value) as daily_avg_scr,
        AVG(baseline_scr) as baseline_scr
    FROM baseline_scr
    WHERE baseline_scr IS NOT NULL
    GROUP BY person_id, visit_occurrence_id, measurement_date
),

daily_kidney_function AS (
    SELECT 
        person_id,
        visit_occurrence_id,
        measurement_date,
        daily_avg_scr,
        baseline_scr,
        daily_avg_scr / baseline_scr as scr_ratio,
        -- Flag days with 50% or greater increase from baseline
        CASE 
            WHEN daily_avg_scr / baseline_scr >= 1.5 THEN 1
            ELSE 0
        END as aki_flag
    FROM daily_scr
),

-- -----------------------------------------------------
-- STEP 5: IDENTIFY AKI BLOCKS
-- Consecutive days with SCr >= 1.5x baseline
-- Blocks separated by >2 days without elevated SCr
-- -----------------------------------------------------
aki_days_with_gaps AS (
    SELECT 
        person_id,
        visit_occurrence_id,
        measurement_date,
        scr_ratio,
        aki_flag,
        LAG(measurement_date) OVER (
            PARTITION BY person_id, visit_occurrence_id 
            ORDER BY measurement_date
        ) as prev_date
    FROM daily_kidney_function
    WHERE aki_flag = 1
),

aki_blocks AS (
    SELECT 
        person_id,
        visit_occurrence_id,
        measurement_date,
        scr_ratio,
        -- Assign block number based on gaps >2 days
        SUM(CASE 
            WHEN prev_date IS NULL 
                 OR DATEDIFF(day, prev_date, measurement_date) > 2 
            THEN 1 
            ELSE 0 
        END) OVER (
            PARTITION BY person_id, visit_occurrence_id 
            ORDER BY measurement_date
        ) as block_number
    FROM aki_days_with_gaps
),

-- -----------------------------------------------------
-- STEP 6: CHARACTERIZE EACH AKI BLOCK
-- Determine AKIN stage and subtype (tAKI vs sAKI)
-- -----------------------------------------------------
aki_block_characteristics AS (
    SELECT 
        person_id,
        visit_occurrence_id,
        block_number,
        MIN(measurement_date) as block_start_date,
        MAX(measurement_date) as block_end_date,
        COUNT(DISTINCT measurement_date) as block_duration_days,
        MAX(scr_ratio) as max_block_scr_ratio,
        -- AKIN Stage Classification based on maximum SCr ratio
        CASE 
            WHEN MAX(scr_ratio) >= 3.0 THEN 3  -- >3-fold increase
            WHEN MAX(scr_ratio) >= 2.0 THEN 2  -- 2-3 fold increase  
            WHEN MAX(scr_ratio) >= 1.5 THEN 1  -- 1.5-2 fold increase
        END as akin_stage,
        -- AKI Subtype Classification based on duration
        CASE
            WHEN COUNT(DISTINCT measurement_date) > 2 
                 OR DATEDIFF(hour, MIN(measurement_date), MAX(measurement_date)) > 48 
            THEN 'sAKI'  -- Sustained AKI (>48 hours)
            ELSE 'tAKI'   -- Transient AKI (<=48 hours)
        END as aki_subtype
    FROM aki_blocks
    GROUP BY person_id, visit_occurrence_id, block_number
),

-- -----------------------------------------------------
-- STEP 7: DETERMINE AKI STATUS FOR EACH VISIT
-- -----------------------------------------------------
visit_aki_status AS (
    SELECT 
        v.person_id,
        v.visit_occurrence_id,
        v.visit_start_date,
        v.visit_end_date,
        -- Classify based on exclusions and data availability
        CASE 
            WHEN e.person_id IS NOT NULL THEN 'ESRD'
            WHEN b.baseline_count = 0 OR b.baseline_count IS NULL THEN 'AKI_UNKNOWN'
            WHEN d.max_aki_flag = 1 THEN 'AKI'
            ELSE 'NO_AKI'
        END as aki_status
    FROM visit_occurrence v
    LEFT JOIN esrd_exclusions e 
        ON v.person_id = e.person_id 
        AND v.visit_occurrence_id = e.visit_occurrence_id
    LEFT JOIN (
        SELECT person_id, visit_occurrence_id, COUNT(*) as baseline_count
        FROM baseline_scr
        WHERE baseline_scr IS NOT NULL
        GROUP BY person_id, visit_occurrence_id
    ) b ON v.person_id = b.person_id 
        AND v.visit_occurrence_id = b.visit_occurrence_id
    LEFT JOIN (
        SELECT person_id, visit_occurrence_id, MAX(aki_flag) as max_aki_flag
        FROM daily_kidney_function
        GROUP BY person_id, visit_occurrence_id
    ) d ON v.person_id = d.person_id 
        AND v.visit_occurrence_id = d.visit_occurrence_id
),

-- -----------------------------------------------------
-- STEP 8: COMPILE FINAL AKI PHENOTYPE
-- Use first AKI block for overall characterization
-- -----------------------------------------------------
aki_phenotype AS (
    SELECT 
        vas.person_id,
        vas.visit_occurrence_id,
        vas.visit_start_date,
        vas.visit_end_date,
        vas.aki_status,
        first_block.akin_stage,
        first_block.aki_subtype,
        COALESCE(block_count.total_blocks, 0) as aki_recurrence_count,
        -- Final phenotype classification
        CASE
            WHEN vas.aki_status = 'AKI' THEN 'CASE'
            WHEN vas.aki_status = 'NO_AKI' THEN 'CONTROL'
            WHEN vas.aki_status = 'ESRD' THEN 'EXCLUDED_ESRD'
            WHEN vas.aki_status = 'AKI_UNKNOWN' THEN 'EXCLUDED_INSUFFICIENT_DATA'
        END as phenotype_label
    FROM visit_aki_status vas
    LEFT JOIN (
        -- Get characteristics from first AKI block
        SELECT person_id, visit_occurrence_id, akin_stage, aki_subtype
        FROM aki_block_characteristics
        WHERE block_number = 1
    ) first_block 
        ON vas.person_id = first_block.person_id 
        AND vas.visit_occurrence_id = first_block.visit_occurrence_id
    LEFT JOIN (
        -- Count total AKI blocks for recurrence
        SELECT person_id, visit_occurrence_id, COUNT(DISTINCT block_number) as total_blocks
        FROM aki_block_characteristics
        GROUP BY person_id, visit_occurrence_id
    ) block_count
        ON vas.person_id = block_count.person_id 
        AND vas.visit_occurrence_id = block_count.visit_occurrence_id
)

-- -----------------------------------------------------
-- FINAL OUTPUT: AKI CASES AND CONTROLS
-- Returns only definitive cases and controls
-- -----------------------------------------------------
SELECT 
    person_id,
    visit_occurrence_id,
    visit_start_date,
    visit_end_date,
    aki_status,
    -- AKIN Stage with description
    CASE 
        WHEN akin_stage = 1 THEN 'AKIN Stage 1 (1.5-2x baseline)'
        WHEN akin_stage = 2 THEN 'AKIN Stage 2 (2-3x baseline)'
        WHEN akin_stage = 3 THEN 'AKIN Stage 3 (>3x baseline)'
        ELSE NULL
    END as akin_stage_description,
    -- AKI Subtype with description
    CASE
        WHEN aki_subtype = 'tAKI' THEN 'Transient AKI (<=48 hours)'
        WHEN aki_subtype = 'sAKI' THEN 'Sustained AKI (>48 hours)'
        ELSE NULL
    END as aki_subtype_description,
    -- Number of AKI recurrences
    aki_recurrence_count,
    -- Final phenotype label
    phenotype_label
FROM aki_phenotype
-- Only return definitive cases and controls
WHERE phenotype_label IN ('CASE', 'CONTROL')
ORDER BY person_id, visit_occurrence_id;