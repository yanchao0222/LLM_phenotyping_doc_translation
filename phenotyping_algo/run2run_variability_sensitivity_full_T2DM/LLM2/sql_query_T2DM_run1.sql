-- Type 2 Diabetes Mellitus: final SQL query, run 2 (extracted from content_clean_4)

-- ============================================================
-- TYPE 2 DIABETES MELLITUS PHENOTYPING ALGORITHM
-- ============================================================
-- Based on Northwestern University T2DM EMR Algorithm
-- Document Date: August 19, 2011
-- OMOP CDM Implementation
-- ============================================================
-- This query identifies T2DM cases and controls from an OMOP CDM database
-- Cases: Patients meeting one of 5 pathways for T2DM diagnosis
-- Controls: Patients meeting strict criteria for non-diabetic status
-- ============================================================

WITH 
-- ============================================================
-- STEP 1: Extract T1DM diagnosis information
-- ICD-9 codes: 250.x1, 250.x3
-- ============================================================
t1dm_diagnoses AS (
    SELECT 
        person_id,
        COUNT(DISTINCT condition_start_date) AS t1dm_dx_count
    FROM condition_occurrence co
    INNER JOIN concept c ON co.condition_concept_id = c.concept_id
    WHERE c.concept_code IN ('250.01','250.03','250.11','250.13','250.21','250.23',
                            '250.31','250.33','250.41','250.43','250.51','250.53',
                            '250.61','250.63','250.71','250.73','250.81','250.83',
                            '250.91','250.93')
        AND c.vocabulary_id = 'ICD9CM'
    GROUP BY person_id
),

-- ============================================================
-- STEP 2: Extract T2DM diagnosis information
-- ICD-9 codes: 250.x0, 250.x2 (excluding 250.10, 250.12)
-- ============================================================
t2dm_diagnoses AS (
    SELECT 
        person_id,
        COUNT(DISTINCT condition_start_date) AS t2dm_dx_count
    FROM condition_occurrence co
    INNER JOIN concept c ON co.condition_concept_id = c.concept_id
    WHERE c.concept_code IN ('250.00','250.02','250.20','250.22','250.30','250.32',
                            '250.40','250.42','250.50','250.52','250.60','250.62',
                            '250.70','250.72','250.80','250.82','250.90','250.92')
        AND c.vocabulary_id = 'ICD9CM'
    GROUP BY person_id
),

-- ============================================================
-- STEP 3: Extract T2DM physician-entered diagnoses
-- Only from encounter or problem list sources
-- ============================================================
t2dm_physician_diagnoses AS (
    SELECT 
        person_id,
        COUNT(DISTINCT condition_start_date) AS t2dm_physician_dx_count
    FROM condition_occurrence co
    INNER JOIN concept c ON co.condition_concept_id = c.concept_id
    WHERE c.concept_code IN ('250.00','250.02','250.20','250.22','250.30','250.32',
                            '250.40','250.42','250.50','250.52','250.60','250.62',
                            '250.70','250.72','250.80','250.82','250.90','250.92')
        AND c.vocabulary_id = 'ICD9CM'
        -- Filter for physician-entered diagnoses (encounter or problem list)
        AND co.condition_type_concept_id IN (
            SELECT concept_id FROM concept 
            WHERE domain_id = 'Type Concept' 
            AND concept_name IN ('EHR encounter diagnosis', 'EHR problem list')
        )
    GROUP BY person_id
),

-- ============================================================
-- STEP 4: Extract T1DM medications
-- Insulin (multiple RxNorm codes) and Pramlintide (139953)
-- ============================================================
t1dm_medications AS (
    SELECT 
        person_id,
        MIN(drug_exposure_start_date) AS t1dm_rx_date
    FROM drug_exposure de
    INNER JOIN concept_ancestor ca ON de.drug_concept_id = ca.descendant_concept_id
    INNER JOIN concept c ON ca.ancestor_concept_id = c.concept_id
    WHERE c.concept_code IN ('139825','274783','314684','352385','400008','51428',
                            '5856','86009',    -- Insulin codes
                            '139953')          -- Pramlintide
        AND c.vocabulary_id = 'RxNorm'
    GROUP BY person_id
),

-- ============================================================
-- STEP 5: Extract T2DM medications
-- Various oral hypoglycemics and injectables
-- ============================================================
t2dm_medications AS (
    SELECT 
        person_id,
        MIN(drug_exposure_start_date) AS t2dm_rx_date
    FROM drug_exposure de
    INNER JOIN concept_ancestor ca ON de.drug_concept_id = ca.descendant_concept_id
    INNER JOIN concept c ON ca.ancestor_concept_id = c.concept_id
    WHERE c.concept_code IN ('173','10633','2404','4821','217360','4815','25789',
                            '73044','274332','6809','84108','33738','72610',
                            '16681','30009','593411','60548')
        AND c.vocabulary_id = 'RxNorm'
    GROUP BY person_id
),

-- ============================================================
-- STEP 6: Extract laboratory test results
-- Fasting glucose, Random glucose, HbA1c
-- ============================================================
lab_results AS (
    SELECT 
        person_id,
        MAX(CASE WHEN c.concept_code = '1558-6' THEN m.value_as_number END) AS max_fasting_glucose,
        MAX(CASE WHEN c.concept_code IN ('2339-0','2345-7') THEN m.value_as_number END) AS max_random_glucose,
        MAX(CASE WHEN c.concept_code IN ('4548-4','17856-6','4549-2','17855-8') THEN m.value_as_number END) AS max_hba1c
    FROM measurement m
    INNER JOIN concept c ON m.measurement_concept_id = c.concept_id
    WHERE c.concept_code IN ('1558-6','2339-0','2345-7','4548-4','17856-6','4549-2','17855-8')
        AND c.vocabulary_id = 'LOINC'
        AND m.value_as_number IS NOT NULL
    GROUP BY person_id
),

-- ============================================================
-- STEP 7: Extract all diabetes-related diagnoses for controls
-- ============================================================
all_diabetes_diagnoses AS (
    SELECT 
        person_id,
        COUNT(DISTINCT condition_start_date) AS dm_dx_count
    FROM condition_occurrence co
    INNER JOIN concept c ON co.condition_concept_id = c.concept_id
    WHERE (
        -- All diabetes codes
        c.concept_code LIKE '250%'
        -- Glucose abnormalities
        OR c.concept_code IN ('790.21','790.22','790.2','790.29')
        -- Abnormal glucose in pregnancy
        OR c.concept_code LIKE '648.8%'
        -- Gestational diabetes
        OR c.concept_code LIKE '648.0%'
        -- Other diabetes-related codes
        OR c.concept_code IN ('791.5','277.7','V18.0','V77.1')
    )
    AND c.vocabulary_id = 'ICD9CM'
    GROUP BY person_id
),

-- ============================================================
-- STEP 8: Check for glucose lab existence (for controls)
-- ============================================================
glucose_lab_existence AS (
    SELECT 
        person_id,
        COUNT(*) AS glucose_lab_count
    FROM measurement m
    INNER JOIN concept c ON m.measurement_concept_id = c.concept_id
    WHERE c.concept_code IN ('1558-6','2339-0','2345-7')
        AND c.vocabulary_id = 'LOINC'
    GROUP BY person_id
),

-- ============================================================
-- STEP 9: Count office encounters (for controls)
-- ============================================================
office_encounters AS (
    SELECT 
        person_id,
        COUNT(DISTINCT visit_start_date) AS encounter_count
    FROM visit_occurrence
    WHERE visit_concept_id IN (
        SELECT concept_id FROM concept 
        WHERE concept_name LIKE '%office%visit%'
        OR concept_name LIKE '%outpatient%'
    )
    GROUP BY person_id
),

-- ============================================================
-- STEP 10: Count diabetes medications and supplies (for controls)
-- ============================================================
diabetes_med_supplies AS (
    SELECT 
        person_id,
        COUNT(DISTINCT COALESCE(de.drug_exposure_start_date, do.device_exposure_start_date)) AS dm_med_supplies_count
    FROM (
        -- Diabetes medications
        SELECT person_id, drug_exposure_start_date
        FROM drug_exposure de
        INNER JOIN concept_ancestor ca ON de.drug_concept_id = ca.descendant_concept_id
        INNER JOIN concept c ON ca.ancestor_concept_id = c.concept_id
        WHERE c.concept_code IN (
            -- T1DM medications
            '139825','274783','314684','352385','400008','51428','5856','86009','139953',
            -- T2DM medications
            '173','10633','2404','4821','217360','4815','25789','73044','274332',
            '6809','84108','33738','72610','16681','30009','593411','60548'
        )
        AND c.vocabulary_id = 'RxNorm'
        
        UNION ALL
        
        -- Diabetes supplies (as drugs)
        SELECT person_id, drug_exposure_start_date
        FROM drug_exposure de
        INNER JOIN concept c ON de.drug_concept_id = c.concept_id
        WHERE c.concept_code IN (
            -- Blood glucose meters/sensors
            '126958','412956','412959','637321','668291','668370','686655','692383',
            '748611','880998','881056','751128',
            -- Insulin syringes
            '847187','847191','847197','847203','847207','847211','847230','847239',
            '847252','847256','847259','847263','847278','847416','847417',
            '806905','806903','408119'
        )
    ) de
    FULL OUTER JOIN (
        -- Diabetes supplies (as devices)
        SELECT person_id, device_exposure_start_date
        FROM device_exposure do
        INNER JOIN concept c ON do.device_concept_id = c.concept_id
        WHERE c.concept_name LIKE '%glucose%meter%'
           OR c.concept_name LIKE '%insulin%syringe%'
           OR c.concept_name LIKE '%diabetes%supply%'
    ) do ON de.person_id = do.person_id
    GROUP BY COALESCE(de.person_id, do.person_id)
),

-- ============================================================
-- STEP 11: Family history of diabetes (for controls)
-- ============================================================
family_history AS (
    SELECT 
        person_id,
        MAX(1) AS has_family_history_dm
    FROM observation o
    INNER JOIN concept c ON o.observation_concept_id = c.concept_id
    WHERE (c.concept_name LIKE '%family%history%diabetes%'
           OR c.concept_code = 'V18.0')
    GROUP BY person_id
),

-- ============================================================
-- STEP 12: Combine features for case identification
-- ============================================================
case_features AS (
    SELECT 
        p.person_id,
        COALESCE(t1dx.t1dm_dx_count, 0) AS t1dm_dx_count,
        COALESCE(t2dx.t2dm_dx_count, 0) AS t2dm_dx_count,
        COALESCE(t2ph.t2dm_physician_dx_count, 0) AS t2dm_physician_dx_count,
        t1rx.t1dm_rx_date,
        t2rx.t2dm_rx_date,
        lab.max_fasting_glucose,
        lab.max_random_glucose,
        lab.max_hba1c
    FROM person p
    LEFT JOIN t1dm_diagnoses t1dx ON p.person_id = t1dx.person_id
    LEFT JOIN t2dm_diagnoses t2dx ON p.person_id = t2dx.person_id
    LEFT JOIN t2dm_physician_diagnoses t2ph ON p.person_id = t2ph.person_id
    LEFT JOIN t1dm_medications t1rx ON p.person_id = t1rx.person_id
    LEFT JOIN t2dm_medications t2rx ON p.person_id = t2rx.person_id
    LEFT JOIN lab_results lab ON p.person_id = lab.person_id
),

-- ============================================================
-- STEP 13: Combine features for control identification
-- ============================================================
control_features AS (
    SELECT 
        p.person_id,
        COALESCE(alldx.dm_dx_count, 0) AS dm_dx_count,
        COALESCE(glab.glucose_lab_count, 0) AS glucose_lab_count,
        lab.max_fasting_glucose,
        lab.max_random_glucose,
        lab.max_hba1c,
        COALESCE(enc.encounter_count, 0) AS encounter_count,
        COALESCE(dms.dm_med_supplies_count, 0) AS dm_med_supplies_count,
        COALESCE(fh.has_family_history_dm, 0) AS has_family_history_dm
    FROM person p
    LEFT JOIN all_diabetes_diagnoses alldx ON p.person_id = alldx.person_id
    LEFT JOIN glucose_lab_existence glab ON p.person_id = glab.person_id
    LEFT JOIN lab_results lab ON p.person_id = lab.person_id
    LEFT JOIN office_encounters enc ON p.person_id = enc.person_id
    LEFT JOIN diabetes_med_supplies dms ON p.person_id = dms.person_id
    LEFT JOIN family_history fh ON p.person_id = fh.person_id
),

-- ============================================================
-- STEP 14: Apply case selection algorithm (5 pathways)
-- ============================================================
t2dm_cases AS (
    SELECT 
        person_id,
        CASE
            -- PATHWAY 1: No T1DM dx, has T2DM dx, both meds, T2DM med first
            WHEN t1dm_dx_count = 0 
                AND t2dm_dx_count > 0 
                AND t2dm_rx_date IS NOT NULL 
                AND t1dm_rx_date IS NOT NULL 
                AND t2dm_rx_date < t1dm_rx_date
            THEN 1
            
            -- PATHWAY 2: No T1DM dx, has T2DM dx, T2DM med only
            WHEN t1dm_dx_count = 0 
                AND t2dm_dx_count > 0 
                AND t1dm_rx_date IS NULL 
                AND t2dm_rx_date IS NOT NULL
            THEN 2
            
            -- PATHWAY 3: No T1DM dx, has T2DM dx, no meds, abnormal lab
            -- Abnormal: Random glucose >200, Fasting glucose >=125, HbA1c >=6.5
            WHEN t1dm_dx_count = 0 
                AND t2dm_dx_count > 0 
                AND t1dm_rx_date IS NULL 
                AND t2dm_rx_date IS NULL
                AND (max_random_glucose > 200 
                    OR max_fasting_glucose >= 125 
                    OR max_hba1c >= 6.5)
            THEN 3
            
            -- PATHWAY 4: No dx codes, has T2DM med, abnormal lab
            WHEN t1dm_dx_count = 0 
                AND t2dm_dx_count = 0 
                AND t2dm_rx_date IS NOT NULL
                AND (max_random_glucose > 200 
                    OR max_fasting_glucose >= 125 
                    OR max_hba1c >= 6.5)
            THEN 4
            
            -- PATHWAY 5: No T1DM dx, has T2DM dx, T1DM med only, >=2 physician dx
            WHEN t1dm_dx_count = 0 
                AND t2dm_dx_count > 0 
                AND t1dm_rx_date IS NOT NULL 
                AND t2dm_rx_date IS NULL
                AND t2dm_physician_dx_count >= 2
            THEN 5
            
            ELSE 0
        END AS case_pathway
    FROM case_features
),

-- ============================================================
-- STEP 15: Apply control selection algorithm (all criteria required)
-- ============================================================
t2dm_controls AS (
    SELECT 
        person_id,
        CASE
            -- All criteria must be met for control status
            -- Abnormal thresholds: Random >110, Fasting >=110, HbA1c >=6.0
            WHEN dm_dx_count = 0                           -- No diabetes diagnoses
                AND glucose_lab_count > 0                  -- Has glucose measurements
                AND (max_random_glucose IS NULL OR max_random_glucose <= 110)
                AND (max_fasting_glucose IS NULL OR max_fasting_glucose < 110)
                AND (max_hba1c IS NULL OR max_hba1c < 6.0)
                AND encounter_count >= 2                   -- At least 2 office visits
                AND dm_med_supplies_count = 0              -- No diabetes meds/supplies
                AND has_family_history_dm = 0              -- No family history
            THEN 1
            ELSE 0
        END AS is_control
    FROM control_features
)

-- ============================================================
-- FINAL OUTPUT: T2DM phenotype status
-- ============================================================
SELECT 
    p.person_id,
    CASE 
        WHEN c.case_pathway > 0 THEN 'T2DM_CASE'
        WHEN ctrl.is_control = 1 THEN 'T2DM_CONTROL'
        ELSE 'UNKNOWN'
    END AS phenotype_status,
    CASE 
        WHEN c.case_pathway > 0 THEN 'Pathway_' || c.case_pathway
        ELSE NULL
    END AS case_pathway_detail,
    -- Additional details for verification
    CASE 
        WHEN c.case_pathway = 1 THEN 'No T1DM dx, T2DM dx, both meds with T2DM first'
        WHEN c.case_pathway = 2 THEN 'No T1DM dx, T2DM dx, T2DM med only'
        WHEN c.case_pathway = 3 THEN 'No T1DM dx, T2DM dx, no meds, abnormal lab'
        WHEN c.case_pathway = 4 THEN 'No dx, T2DM med, abnormal lab'
        WHEN c.case_pathway = 5 THEN 'No T1DM dx, T2DM dx, T1DM med only, >=2 physician dx'
        WHEN ctrl.is_control = 1 THEN 'Met all control criteria'
        ELSE NULL
    END AS phenotype_description
FROM person p
LEFT JOIN t2dm_cases c ON p.person_id = c.person_id
LEFT JOIN t2dm_controls ctrl ON p.person_id = ctrl.person_id
WHERE c.case_pathway > 0 OR ctrl.is_control = 1
ORDER BY p.person_id;
