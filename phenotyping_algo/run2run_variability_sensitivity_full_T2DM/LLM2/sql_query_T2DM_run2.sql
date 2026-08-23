-- Type 2 Diabetes Mellitus: final SQL query, run 3 (extracted from content_clean_4)

-- =====================================================
-- T2DM PHENOTYPING ALGORITHM - EXECUTABLE SQL QUERY
-- =====================================================
-- This query identifies Type 2 Diabetes Mellitus cases and controls
-- from an OMOP CDM database using validated phenotyping algorithms
-- Based on Northwestern University T2DM EMR algorithms
-- =====================================================

WITH 
-- =====================================================
-- STEP 1: Extract patient-level features for T2DM phenotyping
-- =====================================================
patient_features AS (
    SELECT 
        p.person_id,
        
        -- ===== DIAGNOSIS COUNTS =====
        -- Count T1DM diagnoses (ICD-9: 250.x1, 250.x3)
        COALESCE(SUM(
            CASE WHEN co.condition_source_value IN (
                '250.01','250.03','250.11','250.13','250.21','250.23','250.31','250.33',
                '250.41','250.43','250.51','250.53','250.61','250.63','250.71','250.73',
                '250.81','250.83','250.91','250.93'
            ) THEN 1 ELSE 0 END
        ), 0) AS t1dm_dx_count,
        
        -- Count T2DM diagnoses (ICD-9: 250.x0, 250.x2, excluding 250.10, 250.12)
        COALESCE(SUM(
            CASE WHEN co.condition_source_value IN (
                '250.00','250.02','250.20','250.22','250.30','250.32','250.40','250.42',
                '250.50','250.52','250.60','250.62','250.70','250.72','250.80','250.82',
                '250.90','250.92'
            ) THEN 1 ELSE 0 END
        ), 0) AS t2dm_dx_count,
        
        -- Count physician-entered T2DM diagnoses (from encounter or problem list only)
        -- Using condition_type_concept_id for EHR vs claims determination
        COALESCE(SUM(
            CASE WHEN co.condition_source_value IN (
                '250.00','250.02','250.20','250.22','250.30','250.32','250.40','250.42',
                '250.50','250.52','250.60','250.62','250.70','250.72','250.80','250.82',
                '250.90','250.92'
            ) AND co.condition_type_concept_id IN (32817, 32840) -- EHR encounter, problem list
            THEN 1 ELSE 0 END
        ), 0) AS t2dm_physician_dx_count,
        
        -- Count any diabetes-related diagnoses for control exclusion
        COALESCE(SUM(
            CASE WHEN (co.condition_source_value LIKE '250%'
                OR co.condition_source_value IN (
                    '790.21','790.22','790.2','790.29',
                    '648.80','648.81','648.82','648.83','648.84',
                    '648.00','648.01','648.02','648.03','648.04',
                    '791.5','277.7','V18.0','V77.1'
                )) THEN 1 ELSE 0 END
        ), 0) AS dm_any_dx_count,
        
        -- ===== MEDICATION DATES =====
        -- First T1DM medication date (insulin and pramlintide - RxNorm CUIs)
        MIN(CASE WHEN de.drug_source_value IN (
            '139825','274783','314684','352385','400008','51428','5856','86009','139953'
        ) THEN de.drug_exposure_start_date END) AS t1dm_rx_date,
        
        -- First T2DM medication date (RxNorm CUIs)
        MIN(CASE WHEN de.drug_source_value IN (
            '173','10633','2404','4821','217360','4815','25789','73044','274332',
            '6809','84108','33738','72610','16681','30009','593411','60548'
        ) THEN de.drug_exposure_start_date END) AS t2dm_rx_date,
        
        -- Count diabetes medications and supplies for control exclusion
        COALESCE(COUNT(DISTINCT 
            CASE WHEN de.drug_source_value IN (
                -- T1DM medications
                '139825','274783','314684','352385','400008','51428','5856','86009','139953',
                -- T2DM medications
                '173','10633','2404','4821','217360','4815','25789','73044','274332',
                '6809','84108','33738','72610','16681','30009','593411','60548',
                -- Diabetes medical supplies
                '126958','412956','412959','637321','668291','668370','686655','692383',
                '748611','880998','881056','751128','847187','847191','847197','847203',
                '847207','847211','847230','847239','847252','847256','847259','847263',
                '847278','847416','847417','806905','806903','408119'
            ) THEN de.drug_exposure_start_date END
        ), 0) AS dm_med_supplies_count,
        
        -- ===== LAB VALUES =====
        -- Maximum random glucose value (LOINC: 2339-0, 2345-7) in mg/dl
        MAX(CASE WHEN m.measurement_source_value IN ('2339-0','2345-7') 
            THEN m.value_as_number END) AS max_random_glucose,
        
        -- Maximum fasting glucose value (LOINC: 1558-6) in mg/dl
        MAX(CASE WHEN m.measurement_source_value = '1558-6' 
            THEN m.value_as_number END) AS max_fasting_glucose,
        
        -- Maximum HbA1c value (LOINC: 4548-4, 17856-6, 4549-2, 17855-8) in %
        MAX(CASE WHEN m.measurement_source_value IN ('4548-4','17856-6','4549-2','17855-8') 
            THEN m.value_as_number END) AS max_hba1c,
        
        -- Check if any glucose lab exists (for control requirement)
        CASE WHEN COUNT(CASE WHEN m.measurement_source_value IN ('1558-6','2339-0','2345-7') 
            THEN 1 END) > 0 THEN 1 ELSE 0 END AS has_glucose_lab,
        
        -- ===== ENCOUNTERS =====
        -- Count in-person office visits (outpatient visits)
        COUNT(DISTINCT CASE WHEN vo.visit_concept_id = 9202 -- Outpatient Visit
            THEN vo.visit_start_date END) AS encounter_count,
        
        -- ===== FAMILY HISTORY =====
        -- Family history of diabetes (ICD-9: V18.0 or from observation table)
        MAX(CASE 
            WHEN co.condition_source_value = 'V18.0' THEN 1
            WHEN o.observation_source_value = 'V18.0' THEN 1
            ELSE 0 
        END) AS family_history_dm
        
    FROM person p
    LEFT JOIN condition_occurrence co ON p.person_id = co.person_id
    LEFT JOIN drug_exposure de ON p.person_id = de.person_id
    LEFT JOIN measurement m ON p.person_id = m.person_id
    LEFT JOIN visit_occurrence vo ON p.person_id = vo.person_id
    LEFT JOIN observation o ON p.person_id = o.person_id
    
    GROUP BY p.person_id
),

-- =====================================================
-- STEP 2: Apply Phenotyping Algorithms
-- =====================================================
phenotype_classification AS (
    SELECT 
        person_id,
        
        -- ===== T2DM CASE ALGORITHM (5 PATHWAYS) =====
        -- PATHWAY 1: No T1DM dx, has T2DM dx, both med types, T2DM meds first
        CASE 
            WHEN t1dm_dx_count = 0 
                AND t2dm_dx_count > 0
                AND t1dm_rx_date IS NOT NULL
                AND t2dm_rx_date IS NOT NULL
                AND t2dm_rx_date < t1dm_rx_date
            THEN 1 ELSE 0
        END AS case_pathway_1,
        
        -- PATHWAY 2: No T1DM dx, has T2DM dx, T2DM meds only (no T1DM meds)
        CASE 
            WHEN t1dm_dx_count = 0
                AND t2dm_dx_count > 0
                AND t1dm_rx_date IS NULL
                AND t2dm_rx_date IS NOT NULL
            THEN 1 ELSE 0
        END AS case_pathway_2,
        
        -- PATHWAY 3: No T1DM dx, has T2DM dx, no meds, abnormal lab
        CASE 
            WHEN t1dm_dx_count = 0
                AND t2dm_dx_count > 0
                AND t1dm_rx_date IS NULL
                AND t2dm_rx_date IS NULL
                AND (max_random_glucose > 200 
                     OR max_fasting_glucose >= 125 
                     OR max_hba1c >= 6.5)
            THEN 1 ELSE 0
        END AS case_pathway_3,
        
        -- PATHWAY 4: No diabetes dx, T2DM meds with abnormal lab
        CASE 
            WHEN t1dm_dx_count = 0
                AND t2dm_dx_count = 0
                AND t2dm_rx_date IS NOT NULL
                AND (max_random_glucose > 200 
                     OR max_fasting_glucose >= 125 
                     OR max_hba1c >= 6.5)
            THEN 1 ELSE 0
        END AS case_pathway_4,
        
        -- PATHWAY 5: No T1DM dx, has T2DM dx, T1DM meds only, 2+ physician T2DM dx
        CASE 
            WHEN t1dm_dx_count = 0
                AND t2dm_dx_count > 0
                AND t1dm_rx_date IS NOT NULL
                AND t2dm_rx_date IS NULL
                AND t2dm_physician_dx_count >= 2
            THEN 1 ELSE 0
        END AS case_pathway_5,
        
        -- ===== T2DM CONTROL ALGORITHM =====
        -- All conditions must be met for control status
        CASE 
            WHEN dm_any_dx_count = 0                    -- No diabetes diagnoses
                AND has_glucose_lab = 1                 -- Has glucose lab
                AND (max_random_glucose <= 110          -- Normal random glucose
                     OR max_random_glucose IS NULL)
                AND (max_fasting_glucose < 110          -- Normal fasting glucose
                     OR max_fasting_glucose IS NULL)
                AND (max_hba1c < 6.0                    -- Normal HbA1c
                     OR max_hba1c IS NULL)
                AND encounter_count >= 2                -- At least 2 office visits
                AND dm_med_supplies_count = 0           -- No diabetes meds/supplies
                AND family_history_dm = 0               -- No family history
            THEN 1 ELSE 0
        END AS meets_control_criteria,
        
        -- Store feature values for validation
        t1dm_dx_count,
        t2dm_dx_count,
        t2dm_physician_dx_count,
        t1dm_rx_date,
        t2dm_rx_date,
        max_random_glucose,
        max_fasting_glucose,
        max_hba1c,
        dm_any_dx_count,
        has_glucose_lab,
        encounter_count,
        dm_med_supplies_count,
        family_history_dm
        
    FROM patient_features
)

-- =====================================================
-- FINAL OUTPUT: Assign phenotype status
-- =====================================================
SELECT 
    person_id,
    
    -- Final phenotype classification
    CASE 
        WHEN (case_pathway_1 = 1 
              OR case_pathway_2 = 1 
              OR case_pathway_3 = 1 
              OR case_pathway_4 = 1 
              OR case_pathway_5 = 1) THEN 'T2DM_CASE'
        WHEN meets_control_criteria = 1 THEN 'T2DM_CONTROL'
        ELSE 'UNKNOWN'
    END AS phenotype_status,
    
    -- Case pathway indicators (1 if pathway triggered, 0 otherwise)
    case_pathway_1,
    case_pathway_2,
    case_pathway_3,
    case_pathway_4,
    case_pathway_5,
    
    -- Control criteria indicator
    meets_control_criteria,
    
    -- Supporting diagnostic data
    t1dm_dx_count,
    t2dm_dx_count,
    t2dm_physician_dx_count,
    
    -- Medication exposure dates
    t1dm_rx_date,
    t2dm_rx_date,
    dm_med_supplies_count,
    
    -- Laboratory values
    max_random_glucose,
    max_fasting_glucose,
    max_hba1c,
    has_glucose_lab,
    
    -- Other criteria
    encounter_count,
    family_history_dm,
    
    -- Algorithm assignment reason summary
    CASE 
        WHEN case_pathway_1 = 1 THEN 'Case: T2DM dx, both meds, T2DM first'
        WHEN case_pathway_2 = 1 THEN 'Case: T2DM dx, T2DM meds only'
        WHEN case_pathway_3 = 1 THEN 'Case: T2DM dx, no meds, abnormal lab'
        WHEN case_pathway_4 = 1 THEN 'Case: No dx, T2DM meds, abnormal lab'
        WHEN case_pathway_5 = 1 THEN 'Case: T2DM dx, T1DM meds, 2+ physician dx'
        WHEN meets_control_criteria = 1 THEN 'Control: All criteria met'
        ELSE 'Unknown: No criteria met'
    END AS assignment_reason

FROM phenotype_classification

ORDER BY 
    phenotype_status DESC,  -- Cases first, then controls, then unknown
    person_id;
