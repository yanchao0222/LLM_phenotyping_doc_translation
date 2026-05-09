-- =====================================================
-- TYPE 2 DIABETES MELLITUS PHENOTYPING ALGORITHM
-- EXECUTABLE SQL QUERY FOR OMOP CDM DATABASE
-- =====================================================
-- This query identifies T2DM cases and controls from OMOP CDM v5.x
-- Based on Northwestern University T2DM algorithm (August 19, 2011)
-- Output: patient cohort with case/control status

-- =====================================================
-- PART 1: T2DM CASE SELECTION
-- =====================================================
-- Required data elements for cases:
-- 1. Counts of T1DM ICD-9 codes by diagnostic source
-- 2. Counts of T2DM ICD-9 codes by diagnostic source  
-- 3. T1DM medications (earliest date)
-- 4. T2DM medications (earliest date)
-- 5. Fasting blood glucose (maximum value)
-- 6. Random blood glucose (maximum value)
-- 7. HbA1c (maximum value)

WITH 
-- Extract T1DM diagnoses with counts
t1dm_diagnoses AS (
    SELECT 
        co.person_id,
        COUNT(DISTINCT co.condition_occurrence_id) AS t1dm_dx_cnt
    FROM condition_occurrence co
    WHERE co.condition_source_value IN (
        -- T1DM ICD-9 codes: 250.x1, 250.x3
        '250.01', '250.03', '250.11', '250.13',
        '250.21', '250.23', '250.31', '250.33',
        '250.41', '250.43', '250.51', '250.53',
        '250.61', '250.63', '250.71', '250.73',
        '250.81', '250.83', '250.91', '250.93'
    )
    GROUP BY co.person_id
),

-- Extract T2DM diagnoses with total and physician-entered counts
t2dm_diagnoses AS (
    SELECT 
        co.person_id,
        COUNT(DISTINCT co.condition_occurrence_id) AS t2dm_dx_cnt,
        -- Count physician-entered diagnoses (from encounter or problem list sources)
        COUNT(DISTINCT CASE 
            WHEN co.condition_type_concept_id IN (
                32817,    -- EHR problem list entry
                32840,    -- EHR encounter diagnosis
                38000183, -- Inpatient header - primary
                38000184, -- Inpatient header - 1st position
                38000199, -- Outpatient header - primary
                38000200, -- Outpatient header - 1st position
                44786627, -- Primary condition
                44786629  -- Admitting diagnosis
            ) THEN co.condition_occurrence_id 
        END) AS t2dm_physcn_dx_cnt
    FROM condition_occurrence co
    WHERE co.condition_source_value IN (
        -- T2DM ICD-9 codes: 250.x0, 250.x2 (excluding 250.10, 250.12)
        '250.00', '250.02', '250.20', '250.22',
        '250.30', '250.32', '250.40', '250.42',
        '250.50', '250.52', '250.60', '250.62',
        '250.70', '250.72', '250.80', '250.82',
        '250.90', '250.92'
    )
    GROUP BY co.person_id
),

-- Extract T1DM medications (insulin and pramlintide)
t1dm_medications AS (
    SELECT 
        de.person_id,
        MIN(de.drug_exposure_start_date) AS t1dm_rx_dt
    FROM drug_exposure de
    INNER JOIN concept c ON de.drug_concept_id = c.concept_id
    WHERE c.concept_code IN (
        -- Insulin RxNorm CUIs
        '139825', '274783', '314684', '352385',
        '400008', '51428', '5856', '86009',
        -- Pramlintide (Symlin) RxNorm CUI
        '139953'
    )
    AND c.vocabulary_id = 'RxNorm'
    GROUP BY de.person_id
),

-- Extract T2DM medications  
t2dm_medications AS (
    SELECT 
        de.person_id,
        MIN(de.drug_exposure_start_date) AS t2dm_rx_dt
    FROM drug_exposure de
    INNER JOIN concept c ON de.drug_concept_id = c.concept_id
    WHERE c.concept_code IN (
        -- T2DM medication RxNorm CUIs (from Table 6)
        '173',     -- acetohexamide (Dymelor)
        '10633',   -- tolazamide (Tolinase)
        '2404',    -- chlorpropamide (Diabinese)
        '4821',    -- glipizide (Glucotrol)
        '217360',  -- glipizide (Glucotrol XL)
        '4815',    -- glyburide (Micronase, Glynase, Diabeta)
        '25789',   -- glimepiride (Amaryl)
        '73044',   -- repaglinide (Prandin)
        '274332',  -- nateglinide (Starlix)
        '6809',    -- metformin (Glucophage)
        '84108',   -- rosiglitazone (Avandia)
        '33738',   -- pioglitazone (ACTOS)
        '72610',   -- troglitazone (Rezulin)
        '16681',   -- acarbose (Precose)
        '30009',   -- miglitol (Glyset)
        '593411',  -- sitagliptin (Januvia)
        '60548'    -- exenatide (Byetta)
    )
    AND c.vocabulary_id = 'RxNorm'
    GROUP BY de.person_id
),

-- Extract glucose and HbA1c lab values
diabetes_labs AS (
    SELECT 
        m.person_id,
        -- Fasting glucose (LOINC: 1558-6)
        MAX(CASE 
            WHEN c.concept_code = '1558-6' 
            THEN m.value_as_number 
        END) AS max_fast_gluc_lab_val,
        -- Random glucose (LOINC: 2339-0, 2345-7)
        MAX(CASE 
            WHEN c.concept_code IN ('2339-0', '2345-7')
            THEN m.value_as_number 
        END) AS max_rndm_gluc_lab_val,
        -- HbA1c (LOINC: 4548-4, 17856-6, 4549-2, 17855-8)
        MAX(CASE 
            WHEN c.concept_code IN ('4548-4', '17856-6', '4549-2', '17855-8')
            THEN m.value_as_number 
        END) AS max_hba1c_lab_val
    FROM measurement m
    INNER JOIN concept c ON m.measurement_concept_id = c.concept_id
    WHERE c.vocabulary_id = 'LOINC'
    AND m.value_as_number IS NOT NULL
    AND m.value_as_number > 0
    GROUP BY m.person_id
),

-- Aggregate all case criteria per patient
case_criteria AS (
    SELECT 
        p.person_id,
        
        -- Diagnosis counts
        COALESCE(t1.t1dm_dx_cnt, 0) AS t1dm_dx_cnt,
        COALESCE(t2.t2dm_dx_cnt, 0) AS t2dm_dx_cnt,
        COALESCE(t2.t2dm_physcn_dx_cnt, 0) AS t2dm_physcn_dx_cnt,
        
        -- Medication dates
        t1med.t1dm_rx_dt,
        t2med.t2dm_rx_dt,
        
        -- Lab values
        labs.max_fast_gluc_lab_val,
        labs.max_rndm_gluc_lab_val,
        labs.max_hba1c_lab_val
        
    FROM person p
    LEFT JOIN t1dm_diagnoses t1 ON p.person_id = t1.person_id
    LEFT JOIN t2dm_diagnoses t2 ON p.person_id = t2.person_id
    LEFT JOIN t1dm_medications t1med ON p.person_id = t1med.person_id
    LEFT JOIN t2dm_medications t2med ON p.person_id = t2med.person_id
    LEFT JOIN diabetes_labs labs ON p.person_id = labs.person_id
),

-- =====================================================
-- PART 2: T2DM CONTROL SELECTION
-- =====================================================
-- Required data elements for controls:
-- 1. Counts of diabetes-related ICD-9 codes
-- 2. Fasting/random glucose and HbA1c (maximum values)
-- 3. Diabetes family history
-- 4. T1DM medications
-- 5. T2DM medications
-- 6. Diabetes medical supplies
-- 7. Count of face-to-face outpatient encounters

-- Extract all diabetes-related diagnoses for exclusion
diabetes_dx_for_controls AS (
    SELECT 
        co.person_id,
        COUNT(DISTINCT co.condition_occurrence_id) AS dm_dx_cnt
    FROM condition_occurrence co
    WHERE 
        -- Diabetes mellitus (T1 & T2) - 250.xx
        co.condition_source_value LIKE '250%'
        -- Impaired fasting glucose - 790.21
        OR co.condition_source_value = '790.21'
        -- Impaired oral glucose tolerance test - 790.22
        OR co.condition_source_value = '790.22'
        -- Abnormal glucose not otherwise spec - 790.2, 790.29
        OR co.condition_source_value IN ('790.2', '790.29')
        -- Abnormal glucose during pregnancy - 648.8x
        OR co.condition_source_value LIKE '648.8%'
        -- Gestational diabetes - 648.0x
        OR co.condition_source_value LIKE '648.0%'
        -- Glycosuria - 791.5
        OR co.condition_source_value = '791.5'
        -- Dysmetabolic syndrome X - 277.7
        OR co.condition_source_value = '277.7'
        -- Family history of diabetes mellitus - V18.0
        OR co.condition_source_value = 'V18.0'
        -- Screening for diabetes mellitus - V77.1
        OR co.condition_source_value = 'V77.1'
    GROUP BY co.person_id
),

-- Extract diabetes family history
diabetes_family_history AS (
    SELECT DISTINCT person_id, 1 AS fam_hist_of_dm
    FROM (
        -- Check condition_occurrence
        SELECT person_id 
        FROM condition_occurrence
        WHERE condition_source_value = 'V18.0'
        
        UNION
        
        -- Check observation table
        SELECT person_id
        FROM observation
        WHERE observation_source_value = 'V18.0'
        
        UNION
        
        -- Check for family history concepts
        SELECT o.person_id
        FROM observation o
        INNER JOIN concept c ON o.observation_concept_id = c.concept_id
        WHERE c.concept_id IN (
            4167217,  -- Family history of diabetes mellitus
            4058286   -- FH: Diabetes mellitus
        )
    ) fh
),

-- Count diabetes medications and supplies
diabetes_med_supplies AS (
    SELECT 
        de.person_id,
        COUNT(DISTINCT de.drug_exposure_id) AS dm_med_supplies_cnt
    FROM drug_exposure de
    INNER JOIN concept c ON de.drug_concept_id = c.concept_id
    WHERE c.concept_code IN (
        -- T1DM medications (Table 5)
        '139825', '274783', '314684', '352385',
        '400008', '51428', '5856', '86009', '139953',
        -- T2DM medications (Table 6)
        '173', '10633', '2404', '4821', '217360', '4815',
        '25789', '73044', '274332', '6809', '84108', '33738',
        '72610', '16681', '30009', '593411', '60548',
        -- Blood-glucose meters & sensors (Table 8)
        '126958', '412956', '412959', '637321', '668291',
        '668370', '686655', '692383', '748611', '880998',
        '881056', '751128',
        -- Insulin syringes (Table 8)
        '847187', '847191', '847197', '847203', '847207',
        '847211', '847230', '847239', '847252', '847256',
        '847259', '847263', '847278', '847416', '847417',
        '806905', '806903', '408119'
    )
    AND c.vocabulary_id = 'RxNorm'
    GROUP BY de.person_id
),

-- Count face-to-face outpatient encounters
outpatient_encounters AS (
    SELECT 
        vo.person_id,
        COUNT(DISTINCT vo.visit_start_date) AS enctrs_cnt
    FROM visit_occurrence vo
    INNER JOIN concept c ON vo.visit_concept_id = c.concept_id
    WHERE c.concept_id IN (
        9202,     -- Outpatient visit
        9203,     -- Emergency room visit
        581477,   -- Office visit
        581478,   -- Ambulatory clinic/center
        5083      -- Outpatient physician visit
    )
    GROUP BY vo.person_id
),

-- Aggregate all control criteria
control_criteria AS (
    SELECT 
        p.person_id,
        
        -- Diabetes diagnoses count
        COALESCE(ddx.dm_dx_cnt, 0) AS dm_dx_cnt,
        
        -- Family history
        COALESCE(fh.fam_hist_of_dm, 0) AS fam_hist_of_dm,
        
        -- Medications and supplies count
        COALESCE(ms.dm_med_supplies_cnt, 0) AS dm_med_supplies_cnt,
        
        -- Lab values (same extraction as for cases)
        labs.max_fast_gluc_lab_val,
        labs.max_rndm_gluc_lab_val,
        labs.max_hba1c_lab_val,
        
        -- Encounter count
        COALESCE(enc.enctrs_cnt, 0) AS enctrs_cnt
        
    FROM person p
    LEFT JOIN diabetes_dx_for_controls ddx ON p.person_id = ddx.person_id
    LEFT JOIN diabetes_family_history fh ON p.person_id = fh.person_id
    LEFT JOIN diabetes_med_supplies ms ON p.person_id = ms.person_id
    LEFT JOIN diabetes_labs labs ON p.person_id = labs.person_id
    LEFT JOIN outpatient_encounters enc ON p.person_id = enc.person_id
),

-- =====================================================
-- FINAL COHORT SELECTION
-- =====================================================
-- Apply case and control algorithms to identify cohort

final_cohort AS (
    SELECT 
        p.person_id,
        
        -- T2DM CASE DETERMINATION
        -- Based on algorithm with 5 paths (specific path logic from document)
        -- Abnormal lab defined as: Random glucose > 200 OR Fasting glucose >= 125 OR HbA1c >= 6.5
        CASE 
            WHEN 
                -- Has some T2DM evidence
                (cc.t2dm_dx_cnt > 0 OR cc.t2dm_physcn_dx_cnt > 0)
                -- Plus medications or abnormal labs
                AND (
                    cc.t2dm_rx_dt IS NOT NULL
                    OR cc.max_rndm_gluc_lab_val > 200
                    OR cc.max_fast_gluc_lab_val >= 125
                    OR cc.max_hba1c_lab_val >= 6.5
                )
                -- Not predominantly T1DM
                AND (cc.t1dm_dx_cnt = 0 OR cc.t2dm_dx_cnt >= cc.t1dm_dx_cnt)
            THEN 1
            
            -- Multiple T2DM diagnoses without T1DM
            WHEN cc.t2dm_dx_cnt >= 2 AND cc.t1dm_dx_cnt = 0
            THEN 1
            
            -- Physician-entered T2DM with supporting evidence
            WHEN cc.t2dm_physcn_dx_cnt >= 1 
                 AND cc.t1dm_dx_cnt = 0
                 AND (
                    cc.t2dm_rx_dt IS NOT NULL
                    OR cc.max_rndm_gluc_lab_val > 200
                    OR cc.max_fast_gluc_lab_val >= 125
                    OR cc.max_hba1c_lab_val >= 6.5
                 )
            THEN 1
            
            ELSE 0
        END AS is_case,
        
        -- T2DM CONTROL DETERMINATION
        -- Must have NO diabetes indicators and adequate follow-up
        -- Abnormal lab for controls: Random glucose > 110 OR Fasting glucose >= 110 OR HbA1c >= 6.0
        CASE 
            WHEN 
                -- No diabetes diagnoses
                ctrl.dm_dx_cnt = 0
                -- No abnormal labs (using control thresholds)
                AND (ctrl.max_fast_gluc_lab_val IS NULL OR ctrl.max_fast_gluc_lab_val < 110)
                AND (ctrl.max_rndm_gluc_lab_val IS NULL OR ctrl.max_rndm_gluc_lab_val <= 110)
                AND (ctrl.max_hba1c_lab_val IS NULL OR ctrl.max_hba1c_lab_val < 6.0)
                -- No family history of diabetes
                AND ctrl.fam_hist_of_dm = 0
                -- No diabetes medications or supplies
                AND ctrl.dm_med_supplies_cnt = 0
                -- At least 2 face-to-face outpatient encounters
                AND ctrl.enctrs_cnt >= 2
            THEN 1
            ELSE 0
        END AS is_control
        
    FROM person p
    LEFT JOIN case_criteria cc ON p.person_id = cc.person_id
    LEFT JOIN control_criteria ctrl ON p.person_id = ctrl.person_id
)

-- =====================================================
-- FINAL OUTPUT
-- =====================================================
-- Return identified T2DM cases and controls

SELECT 
    person_id,
    CASE 
        WHEN is_case = 1 THEN 'T2DM_CASE'
        WHEN is_control = 1 THEN 'T2DM_CONTROL'
        ELSE 'EXCLUDED'
    END AS phenotype_status,
    CURRENT_DATE AS cohort_entry_date
FROM final_cohort
WHERE is_case = 1 OR is_control = 1
ORDER BY person_id;