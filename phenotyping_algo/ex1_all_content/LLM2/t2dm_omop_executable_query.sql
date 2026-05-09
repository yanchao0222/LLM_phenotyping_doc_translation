-- =====================================================
-- TYPE 2 DIABETES MELLITUS PHENOTYPING ALGORITHM
-- FOR OMOP COMMON DATA MODEL
-- =====================================================
-- Purpose: Identify T2DM cases and controls from OMOP CDM
-- Algorithm Source: Northwestern University T2DM EMR Algorithm (August 19, 2011)
-- OMOP CDM Version: 5.x
-- Note: This query uses ICD9CM codes as specified in the source algorithm.
--       For databases with only SNOMED mappings, concept_relationship table
--       should be used to map from ICD9CM to SNOMED.
-- =====================================================

-- =====================================================
-- MAIN QUERY: IDENTIFY T2DM CASES AND CONTROLS
-- =====================================================

WITH 
-- =====================================================
-- SECTION 1: T1DM DIAGNOSIS COUNTS
-- Count distinct dates with T1DM diagnosis codes (250.x1, 250.x3)
-- =====================================================
t1dm_diagnoses AS (
    SELECT 
        co.person_id,
        COUNT(DISTINCT co.condition_start_date) AS t1dm_dx_count
    FROM condition_occurrence co
    INNER JOIN concept c ON co.condition_concept_id = c.concept_id
    WHERE c.concept_code IN (
        -- Type 1 Diabetes codes (250.x1, 250.x3)
        '250.01', '250.03', '250.11', '250.13', '250.21', 
        '250.23', '250.31', '250.33', '250.41', '250.43',
        '250.51', '250.53', '250.61', '250.63', '250.71',
        '250.73', '250.81', '250.83', '250.91', '250.93'
    )
    AND c.vocabulary_id = 'ICD9CM'
    AND c.invalid_reason IS NULL
    GROUP BY co.person_id
),

-- =====================================================
-- SECTION 2: T2DM DIAGNOSIS COUNTS
-- Count all T2DM diagnoses and physician-entered T2DM diagnoses
-- T2DM codes: 250.x0, 250.x2 (excluding 250.10, 250.12)
-- =====================================================
t2dm_diagnoses AS (
    SELECT 
        co.person_id,
        COUNT(DISTINCT co.condition_start_date) AS t2dm_dx_count,
        -- Count physician-entered diagnoses (encounter or problem list sources only)
        COUNT(DISTINCT CASE 
            WHEN co.condition_type_concept_id IN (
                -- EHR encounter diagnoses
                38000183,  -- Inpatient header - primary
                38000184,  -- Inpatient header - 1st position
                38000199,  -- Outpatient header - primary
                38000200,  -- Outpatient header - 1st position
                38000230,  -- EHR encounter diagnosis
                38000245,  -- EHR Chief Complaint
                38000280,  -- EHR problem list entry
                42898140,  -- Problem list from EHR
                44786627,  -- Primary condition
                44786629   -- First position condition
            )
            THEN co.condition_start_date 
        END) AS t2dm_physician_dx_count
    FROM condition_occurrence co
    INNER JOIN concept c ON co.condition_concept_id = c.concept_id
    WHERE c.concept_code IN (
        -- Type 2 Diabetes codes (250.x0, 250.x2)
        '250.00', '250.02', '250.20', '250.22', '250.30',
        '250.32', '250.40', '250.42', '250.50', '250.52',
        '250.60', '250.62', '250.70', '250.72', '250.80',
        '250.82', '250.90', '250.92'
    )
    AND c.vocabulary_id = 'ICD9CM'
    AND c.invalid_reason IS NULL
    GROUP BY co.person_id
),

-- =====================================================
-- SECTION 3: MEDICATION DATES
-- Get earliest dates for T1DM and T2DM medications
-- =====================================================
medications AS (
    SELECT 
        de.person_id,
        -- First T1DM medication date (insulin and pramlintide)
        MIN(CASE 
            WHEN c.concept_code IN (
                -- Insulin RxNorm CUIs
                '139825', '274783', '314684', '352385', 
                '400008', '51428', '5856', '86009',
                -- Pramlintide (Symlin)
                '139953'
            ) AND c.vocabulary_id = 'RxNorm'
            THEN de.drug_exposure_start_date 
        END) AS t1dm_rx_date,
        -- First T2DM medication date
        MIN(CASE 
            WHEN c.concept_code IN (
                '173',      -- acetohexamide (Dymelor)
                '10633',    -- tolazamide (Tolinase)
                '2404',     -- chlorpropamide (Diabinese)
                '4821',     -- glipizide (Glucotrol)
                '217360',   -- glipizide (Glucotrol XL)
                '4815',     -- glyburide (Micronase, Glynase, Diabeta)
                '25789',    -- glimepiride (Amaryl)
                '73044',    -- repaglinide (Prandin)
                '274332',   -- nateglinide (Starlix)
                '6809',     -- metformin (Glucophage)
                '84108',    -- rosiglitazone (Avandia)
                '33738',    -- pioglitazone (ACTOS)
                '72610',    -- troglitazone (Rezulin)
                '16681',    -- acarbose (Precose)
                '30009',    -- miglitol (Glyset)
                '593411',   -- sitagliptin (Januvia)
                '60548'     -- exenatide (Byetta)
            ) AND c.vocabulary_id = 'RxNorm'
            THEN de.drug_exposure_start_date 
        END) AS t2dm_rx_date
    FROM drug_exposure de
    INNER JOIN concept c ON de.drug_concept_id = c.concept_id
    WHERE c.invalid_reason IS NULL
    GROUP BY de.person_id
),

-- =====================================================
-- SECTION 4: LABORATORY VALUES
-- Get maximum glucose and HbA1c values
-- =====================================================
lab_values AS (
    SELECT 
        m.person_id,
        -- Maximum fasting glucose (LOINC: 1558-6)
        MAX(CASE 
            WHEN c.concept_code = '1558-6' 
                AND c.vocabulary_id = 'LOINC'
            THEN m.value_as_number 
        END) AS max_fasting_glucose,
        -- Maximum random glucose (LOINC: 2339-0, 2345-7)
        MAX(CASE 
            WHEN c.concept_code IN ('2339-0', '2345-7') 
                AND c.vocabulary_id = 'LOINC'
            THEN m.value_as_number 
        END) AS max_random_glucose,
        -- Maximum HbA1c (LOINC: 4548-4, 17856-6, 4549-2, 17855-8)
        MAX(CASE 
            WHEN c.concept_code IN ('4548-4', '17856-6', '4549-2', '17855-8') 
                AND c.vocabulary_id = 'LOINC'
            THEN m.value_as_number 
        END) AS max_hba1c,
        -- Check if glucose lab exists (for controls)
        MAX(CASE 
            WHEN c.concept_code IN ('1558-6', '2339-0', '2345-7') 
                AND c.vocabulary_id = 'LOINC'
            THEN 1 ELSE 0 
        END) AS glucose_lab_exists
    FROM measurement m
    INNER JOIN concept c ON m.measurement_concept_id = c.concept_id
    WHERE c.invalid_reason IS NULL
    GROUP BY m.person_id
),

-- =====================================================
-- SECTION 5: DIABETES-RELATED DIAGNOSES (FOR CONTROLS)
-- Count any diabetes-related diagnosis codes
-- =====================================================
all_diabetes_diagnoses AS (
    SELECT 
        co.person_id,
        COUNT(DISTINCT co.condition_start_date) AS dm_dx_count
    FROM condition_occurrence co
    INNER JOIN concept c ON co.condition_concept_id = c.concept_id
    WHERE c.vocabulary_id = 'ICD9CM'
    AND c.invalid_reason IS NULL
    AND c.concept_code IN (
        -- All Type 1 and Type 2 diabetes codes (250.xx)
        '250.00', '250.01', '250.02', '250.03', '250.10', '250.11', '250.12', '250.13',
        '250.20', '250.21', '250.22', '250.23', '250.30', '250.31', '250.32', '250.33',
        '250.40', '250.41', '250.42', '250.43', '250.50', '250.51', '250.52', '250.53',
        '250.60', '250.61', '250.62', '250.63', '250.70', '250.71', '250.72', '250.73',
        '250.80', '250.81', '250.82', '250.83', '250.90', '250.91', '250.92', '250.93',
        -- Impaired fasting glucose
        '790.21',
        -- Impaired oral glucose tolerance test
        '790.22',
        -- Abnormal glucose not otherwise specified
        '790.2', '790.29',
        -- Abnormal glucose during pregnancy (648.8x)
        '648.80', '648.81', '648.82', '648.83', '648.84', '648.85', '648.86', '648.87', '648.88', '648.89',
        -- Gestational diabetes (648.0x)
        '648.00', '648.01', '648.02', '648.03', '648.04', '648.05', '648.06', '648.07', '648.08', '648.09',
        -- Glycosuria
        '791.5',
        -- Dysmetabolic syndrome X
        '277.7',
        -- Family history of diabetes mellitus
        'V18.0',
        -- Screening for diabetes mellitus
        'V77.1'
    )
    GROUP BY co.person_id
),

-- =====================================================
-- SECTION 6: DIABETES MEDICATIONS AND SUPPLIES (FOR CONTROLS)
-- Count distinct dates with diabetes medications or supplies
-- =====================================================
diabetes_meds_supplies AS (
    SELECT 
        de.person_id,
        COUNT(DISTINCT de.drug_exposure_start_date) AS dm_med_supplies_count
    FROM drug_exposure de
    INNER JOIN concept c ON de.drug_concept_id = c.concept_id
    WHERE c.vocabulary_id = 'RxNorm'
    AND c.invalid_reason IS NULL
    AND c.concept_code IN (
        -- T1DM medications (insulin and pramlintide)
        '139825', '274783', '314684', '352385', '400008', '51428', '5856', '86009', '139953',
        -- T2DM medications
        '173', '10633', '2404', '4821', '217360', '4815', '25789', '73044', '274332',
        '6809', '84108', '33738', '72610', '16681', '30009', '593411', '60548',
        -- Blood glucose meters and sensors (from NDDF and VANDF)
        '126958', '412956', '412959', '637321', '668291', '668370', '686655', '692383',
        '748611', '880998', '881056', '751128',
        -- Insulin syringes (RxNorm and NDDF)
        '847187', '847191', '847197', '847203', '847207', '847211', '847230', '847239',
        '847252', '847256', '847259', '847263', '847278', '847416', '847417',
        '806905', '806903', '408119'
    )
    GROUP BY de.person_id
),

-- =====================================================
-- SECTION 7: OUTPATIENT ENCOUNTERS (FOR CONTROLS)
-- Count face-to-face outpatient office visits
-- =====================================================
outpatient_encounters AS (
    SELECT 
        vo.person_id,
        COUNT(DISTINCT vo.visit_start_date) AS encounter_count
    FROM visit_occurrence vo
    INNER JOIN concept c ON vo.visit_concept_id = c.concept_id
    WHERE c.concept_code IN ('OP', 'OUTPATIENT')
    OR c.concept_name LIKE '%office%'
    OR c.concept_name LIKE '%outpatient%'
    OR vo.visit_concept_id IN (
        9202,      -- Outpatient Visit
        581477     -- Office Visit
    )
    GROUP BY vo.person_id
),

-- =====================================================
-- SECTION 8: FAMILY HISTORY (FOR CONTROLS)
-- Check for family history of diabetes
-- =====================================================
family_history AS (
    -- From condition_occurrence (ICD9 V18.0)
    SELECT DISTINCT
        co.person_id,
        1 AS has_dm_family_history
    FROM condition_occurrence co
    INNER JOIN concept c ON co.condition_concept_id = c.concept_id
    WHERE c.concept_code = 'V18.0' 
    AND c.vocabulary_id = 'ICD9CM'
    AND c.invalid_reason IS NULL
    
    UNION
    
    -- From observation table
    SELECT DISTINCT
        o.person_id,
        1 AS has_dm_family_history
    FROM observation o
    INNER JOIN concept c ON o.observation_concept_id = c.concept_id
    WHERE (c.concept_code = 'V18.0' AND c.vocabulary_id = 'ICD9CM')
    OR c.concept_name LIKE '%family history%diabetes%'
    AND c.invalid_reason IS NULL
),

-- =====================================================
-- SECTION 9: T2DM CASE IDENTIFICATION
-- Apply 5 pathways for case identification
-- =====================================================
t2dm_cases AS (
    SELECT 
        p.person_id,
        CASE 
            -- PATH 1: No T1DM dx, has T2DM dx, both med types, T2DM meds first
            WHEN COALESCE(t1.t1dm_dx_count, 0) = 0 
                AND COALESCE(t2.t2dm_dx_count, 0) > 0
                AND m.t2dm_rx_date IS NOT NULL
                AND m.t1dm_rx_date IS NOT NULL
                AND m.t2dm_rx_date < m.t1dm_rx_date
            THEN 1
            
            -- PATH 2: No T1DM dx, has T2DM dx, T2DM meds only (no T1DM meds)
            WHEN COALESCE(t1.t1dm_dx_count, 0) = 0
                AND COALESCE(t2.t2dm_dx_count, 0) > 0
                AND m.t1dm_rx_date IS NULL
                AND m.t2dm_rx_date IS NOT NULL
            THEN 1
            
            -- PATH 3: No T1DM dx, has T2DM dx, no meds, abnormal lab
            WHEN COALESCE(t1.t1dm_dx_count, 0) = 0
                AND COALESCE(t2.t2dm_dx_count, 0) > 0
                AND m.t1dm_rx_date IS NULL
                AND m.t2dm_rx_date IS NULL
                AND (
                    -- Abnormal lab thresholds for cases
                    l.max_random_glucose > 200      -- mg/dl
                    OR l.max_fasting_glucose >= 125 -- mg/dl
                    OR l.max_hba1c >= 6.5           -- percent
                )
            THEN 1
            
            -- PATH 4: No diabetes dx, has T2DM meds, abnormal lab
            WHEN COALESCE(t1.t1dm_dx_count, 0) = 0
                AND COALESCE(t2.t2dm_dx_count, 0) = 0
                AND m.t2dm_rx_date IS NOT NULL
                AND (
                    -- Abnormal lab thresholds for cases
                    l.max_random_glucose > 200      -- mg/dl
                    OR l.max_fasting_glucose >= 125 -- mg/dl
                    OR l.max_hba1c >= 6.5           -- percent
                )
            THEN 1
            
            -- PATH 5: No T1DM dx, has T2DM dx, T1DM meds only, >=2 physician T2DM dx
            WHEN COALESCE(t1.t1dm_dx_count, 0) = 0
                AND COALESCE(t2.t2dm_dx_count, 0) > 0
                AND m.t1dm_rx_date IS NOT NULL
                AND m.t2dm_rx_date IS NULL
                AND COALESCE(t2.t2dm_physician_dx_count, 0) >= 2
            THEN 1
            
            ELSE 0
        END AS is_case
    FROM person p
    LEFT JOIN t1dm_diagnoses t1 ON p.person_id = t1.person_id
    LEFT JOIN t2dm_diagnoses t2 ON p.person_id = t2.person_id
    LEFT JOIN medications m ON p.person_id = m.person_id
    LEFT JOIN lab_values l ON p.person_id = l.person_id
),

-- =====================================================
-- SECTION 10: T2DM CONTROL IDENTIFICATION
-- All 6 control criteria must be met
-- =====================================================
t2dm_controls AS (
    SELECT 
        p.person_id,
        CASE 
            -- All control criteria must be met
            WHEN COALESCE(ad.dm_dx_count, 0) = 0  -- No diabetes diagnoses
                AND COALESCE(l.glucose_lab_exists, 0) = 1  -- Has at least one glucose lab
                AND (  -- No abnormal labs (control thresholds - lower than case thresholds)
                    COALESCE(l.max_random_glucose, 0) <= 110   -- mg/dl
                    AND COALESCE(l.max_fasting_glucose, 0) < 110  -- mg/dl
                    AND COALESCE(l.max_hba1c, 0) < 6.0           -- percent
                )
                AND COALESCE(oe.encounter_count, 0) >= 2  -- At least 2 outpatient encounters
                AND COALESCE(dms.dm_med_supplies_count, 0) = 0  -- No DM meds or supplies
                AND COALESCE(fh.has_dm_family_history, 0) = 0  -- No family history of DM
            THEN 1
            ELSE 0
        END AS is_control
    FROM person p
    LEFT JOIN all_diabetes_diagnoses ad ON p.person_id = ad.person_id
    LEFT JOIN lab_values l ON p.person_id = l.person_id
    LEFT JOIN outpatient_encounters oe ON p.person_id = oe.person_id
    LEFT JOIN diabetes_meds_supplies dms ON p.person_id = dms.person_id
    LEFT JOIN family_history fh ON p.person_id = fh.person_id
)

-- =====================================================
-- FINAL OUTPUT: COMBINE CASES AND CONTROLS
-- Returns all persons identified as either case or control
-- =====================================================
SELECT 
    p.person_id,
    p.gender_concept_id,
    p.year_of_birth,
    CASE 
        WHEN tc.is_case = 1 THEN 'T2DM_CASE'
        WHEN tctl.is_control = 1 THEN 'T2DM_CONTROL'
        ELSE 'UNKNOWN'
    END AS phenotype_status,
    -- Additional flags for validation
    tc.is_case AS case_flag,
    tctl.is_control AS control_flag,
    -- Current date for documentation
    CURRENT_DATE AS cohort_entry_date
FROM person p
LEFT JOIN t2dm_cases tc ON p.person_id = tc.person_id
LEFT JOIN t2dm_controls tctl ON p.person_id = tctl.person_id
WHERE tc.is_case = 1 OR tctl.is_control = 1
ORDER BY 
    phenotype_status,
    p.person_id;