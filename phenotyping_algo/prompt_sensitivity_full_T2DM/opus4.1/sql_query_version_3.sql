-- Type 2 Diabetes Mellitus: final SQL query, version_3 (extracted from last response)

/*******************************************************************************
Type 2 Diabetes Mellitus EMR Phenotype Algorithm - FINAL VERSION
OMOP CDM v5.4 Implementation
PostgreSQL-compatible SQL

Based on Northwestern University T2DM algorithms
PDF Source: Type 2 Diabetes Mellitus Electronic Medical Record Case and Control Selection Algorithms
Date: August 19, 2011

IMPORTANT: Index date is not specified in source document. This implementation
uses earliest qualifying event as index date.
*******************************************************************************/

WITH

/*******************************************************************************
SECTION 1: ICD-9 to OMOP Concept Resolution
Source: Tables 3, 4, 9 (pages 21, 23)
*******************************************************************************/

-- CASE_C01: T1DM diagnosis codes (Table 3, page 21)
t1dm_dx_concepts AS (
    SELECT DISTINCT 
        c.concept_id,
        c.concept_code,
        c.concept_name
    FROM concept c
    WHERE c.vocabulary_id = 'ICD9CM'
        AND c.invalid_reason IS NULL
        AND (
            c.concept_code LIKE '250._1'  -- 250.x1 pattern
            OR c.concept_code LIKE '250._3'  -- 250.x3 pattern
        )
),

-- CASE_C02, CASE_C06: T2DM diagnosis codes (Table 4, page 21)
t2dm_dx_concepts AS (
    SELECT DISTINCT 
        c.concept_id,
        c.concept_code,
        c.concept_name
    FROM concept c
    WHERE c.vocabulary_id = 'ICD9CM'
        AND c.invalid_reason IS NULL
        AND (
            c.concept_code LIKE '250._0'  -- 250.x0 pattern
            OR c.concept_code LIKE '250._2'  -- 250.x2 pattern
        )
        AND c.concept_code NOT IN ('250.10', '250.12')  -- Explicit exclusions
),

-- CTRL_C01: Diabetes-related diagnosis codes (Table 9, page 23)
dm_related_dx_concepts AS (
    SELECT DISTINCT 
        c.concept_id,
        c.concept_code,
        c.concept_name
    FROM concept c
    WHERE c.vocabulary_id = 'ICD9CM'
        AND c.invalid_reason IS NULL
        AND (
            c.concept_code LIKE '250.%'     -- All diabetes codes
            OR c.concept_code = '790.21'    -- Impaired fasting glucose
            OR c.concept_code = '790.22'    -- Impaired oral glucose tolerance
            OR c.concept_code = '790.2'     -- Abnormal glucose NOS
            OR c.concept_code = '790.29'    -- Other abnormal glucose
            OR c.concept_code LIKE '648.8%' -- Abnormal glucose in pregnancy
            OR c.concept_code LIKE '648.0%' -- Gestational diabetes
            OR c.concept_code = '791.5'     -- Glycosuria
            OR c.concept_code = '277.7'     -- Dysmetabolic syndrome X
            OR c.concept_code = 'V18.0'     -- Family history of diabetes
            OR c.concept_code = 'V77.1'     -- Screening for diabetes
        )
),

/*******************************************************************************
SECTION 2: Medication Concept Resolution
Source: Tables 5, 6, 8 (pages 21-23)
*******************************************************************************/

-- CASE_C03, CTRL_C05: T1DM medications (Table 5, page 21)
t1dm_med_concepts AS (
    SELECT DISTINCT 
        c.concept_id,
        c.concept_code,
        c.concept_name
    FROM concept c
    WHERE c.vocabulary_id = 'RxNorm'
        AND c.invalid_reason IS NULL
        AND c.concept_code IN (
            '139825', '274783', '314684', '352385', 
            '400008', '51428', '5856', '86009',  -- Insulin codes
            '139953'  -- Pramlintide (Symlin)
        )
),

-- CASE_C04, CTRL_C05: T2DM medications (Table 6, page 22)
t2dm_med_concepts AS (
    SELECT DISTINCT 
        c.concept_id,
        c.concept_code,
        c.concept_name
    FROM concept c
    WHERE c.vocabulary_id = 'RxNorm'
        AND c.invalid_reason IS NULL
        AND c.concept_code IN (
            '173', '10633', '2404', '4821', '217360', '4815', 
            '25789', '73044', '274332', '6809', '84108', '33738', 
            '72610', '16681', '30009', '593411', '60548'
        )
),

-- CTRL_C05: Diabetes supplies (Table 8, page 23)
dm_supplies_concepts AS (
    SELECT DISTINCT 
        c.concept_id,
        c.concept_code,
        c.concept_name
    FROM concept c
    WHERE c.vocabulary_id = 'RxNorm'
        AND c.invalid_reason IS NULL
        AND c.concept_code IN (
            '847187', '847191', '847197', '847203', '847207', 
            '847211', '847230', '847239', '847252', '847256', 
            '847259', '847263', '847278', '847416', '847417'
        )
),

/*******************************************************************************
SECTION 3: Lab Test Concept Resolution
Source: Table 7 (page 22)
*******************************************************************************/

-- CASE_C05, CTRL_C02, CTRL_C03: Glucose lab concepts
glucose_lab_concepts AS (
    SELECT DISTINCT 
        c.concept_id,
        c.concept_code,
        c.concept_name,
        CASE 
            WHEN c.concept_code = '1558-6' THEN 'fasting'
            WHEN c.concept_code IN ('2339-0', '2345-7') THEN 'random'
            WHEN c.concept_code IN ('4548-4', '17856-6', '4549-2', '17855-8') THEN 'hba1c'
        END as glucose_type
    FROM concept c
    WHERE c.vocabulary_id = 'LOINC'
        AND c.invalid_reason IS NULL
        AND c.concept_code IN (
            '1558-6', '2339-0', '2345-7',  -- Glucose tests
            '4548-4', '17856-6', '4549-2', '17855-8'  -- HbA1c tests
        )
),

/*******************************************************************************
SECTION 4: Case Criteria Implementation
Based on Algorithms 2-7 (pages 5-7)
*******************************************************************************/

-- CASE_C01: T1DM diagnosis count (Algorithm 2, page 5)
t1dm_dx_counts AS (
    SELECT 
        co.person_id,
        COUNT(DISTINCT co.condition_start_date) as t1dm_dx_cnt
    FROM condition_occurrence co
    INNER JOIN t1dm_dx_concepts t1 ON co.condition_concept_id = t1.concept_id
    GROUP BY co.person_id
),

-- CASE_C02: T2DM diagnosis count (Algorithm 3, page 5)
t2dm_dx_counts AS (
    SELECT 
        co.person_id,
        COUNT(DISTINCT co.condition_start_date) as t2dm_dx_cnt
    FROM condition_occurrence co
    INNER JOIN t2dm_dx_concepts t2 ON co.condition_concept_id = t2.concept_id
    GROUP BY co.person_id
),

-- CASE_C03: First T1DM medication date (Algorithm 5, page 6)
t1dm_med_first AS (
    SELECT 
        de.person_id,
        MIN(de.drug_exposure_start_date) as t1dm_rx_dt
    FROM drug_exposure de
    INNER JOIN t1dm_med_concepts t1m ON de.drug_concept_id = t1m.concept_id
    GROUP BY de.person_id
),

-- CASE_C04: First T2DM medication date (Algorithm 4, page 5)
t2dm_med_first AS (
    SELECT 
        de.person_id,
        MIN(de.drug_exposure_start_date) as t2dm_rx_dt
    FROM drug_exposure de
    INNER JOIN t2dm_med_concepts t2m ON de.drug_concept_id = t2m.concept_id
    GROUP BY de.person_id
),

-- CASE_C05: Abnormal lab values for cases (Algorithm 6, page 6)
-- Random glucose > 200, Fasting glucose >= 125, HbA1c >= 6.5
abnormal_labs_case AS (
    SELECT 
        m.person_id,
        MIN(m.measurement_date) as first_abnormal_lab_dt,
        TRUE as has_abnormal_lab
    FROM measurement m
    INNER JOIN glucose_lab_concepts glc ON m.measurement_concept_id = glc.concept_id
    WHERE (
        (glc.glucose_type = 'random' AND m.value_as_number > 200)
        OR (glc.glucose_type = 'fasting' AND m.value_as_number >= 125)
        OR (glc.glucose_type = 'hba1c' AND m.value_as_number >= 6.5)
    )
    GROUP BY m.person_id
),

-- CASE_C06: T2DM physician-entered diagnosis count (Algorithm 7, page 7)
-- Physician-entered = from encounter or problem list sources only
t2dm_physician_dx_counts AS (
    SELECT 
        co.person_id,
        COUNT(DISTINCT co.condition_start_date) as t2dm_physcn_dx_cnt
    FROM condition_occurrence co
    INNER JOIN t2dm_dx_concepts t2 ON co.condition_concept_id = t2.concept_id
    WHERE co.condition_type_concept_id IN (
        -- EHR encounter diagnosis types (not billing)
        44786627,  -- EHR encounter diagnosis
        44786628,  -- EHR problem list
        42898140,  -- EHR problem list entry
        -- Exclude billing diagnosis types
        -- 44786629 (Primary billing diagnosis) 
        -- 44786630 (Secondary billing diagnosis)
    )
    GROUP BY co.person_id
),

/*******************************************************************************
SECTION 5: Control Criteria Implementation
Based on Algorithms 9-14 (pages 10-12)
*******************************************************************************/

-- CTRL_C01: Diabetes-related diagnosis count (Algorithm 9, page 10)
dm_dx_counts AS (
    SELECT 
        co.person_id,
        COUNT(DISTINCT co.condition_start_date) as dm_dx_cnt
    FROM condition_occurrence co
    INNER JOIN dm_related_dx_concepts dm ON co.condition_concept_id = dm.concept_id
    GROUP BY co.person_id
),

-- CTRL_C02: Glucose lab existence (Algorithm 10, page 10)
glucose_lab_exists AS (
    SELECT DISTINCT
        m.person_id,
        TRUE as has_glucose_lab
    FROM measurement m
    INNER JOIN glucose_lab_concepts glc ON m.measurement_concept_id = glc.concept_id
    WHERE glc.glucose_type IN ('fasting', 'random')
),

-- CTRL_C03: Check for abnormal labs per control threshold (Algorithm 11, page 11)
-- Random glucose > 110, Fasting glucose >= 110, HbA1c >= 6.0
abnormal_labs_control AS (
    SELECT DISTINCT
        m.person_id,
        TRUE as has_abnormal_lab
    FROM measurement m
    INNER JOIN glucose_lab_concepts glc ON m.measurement_concept_id = glc.concept_id
    WHERE (
        (glc.glucose_type = 'random' AND m.value_as_number > 110)
        OR (glc.glucose_type = 'fasting' AND m.value_as_number >= 110)
        OR (glc.glucose_type = 'hba1c' AND m.value_as_number >= 6.0)
    )
),

-- CTRL_C04: Face-to-face encounter count (Algorithm 12, page 11)
encounter_counts AS (
    SELECT 
        v.person_id,
        COUNT(DISTINCT v.visit_start_date) as enctrs_cnt
    FROM visit_occurrence v
    WHERE v.visit_concept_id IN (
        9202,      -- Outpatient visit
        9201,      -- Inpatient visit  
        9203,      -- Emergency room visit
        581477,    -- Office visit
        581478     -- Ambulatory clinic/center
    )
    GROUP BY v.person_id
),

-- CTRL_C05: Diabetes medications and supplies count (Algorithm 13, page 12)
dm_meds_supplies_counts AS (
    SELECT 
        person_id,
        COUNT(DISTINCT exposure_date) as dm_med_supplies_cnt
    FROM (
        -- T1DM medications
        SELECT de.person_id, de.drug_exposure_start_date as exposure_date
        FROM drug_exposure de
        INNER JOIN t1dm_med_concepts t1m ON de.drug_concept_id = t1m.concept_id
        
        UNION ALL
        
        -- T2DM medications
        SELECT de.person_id, de.drug_exposure_start_date as exposure_date
        FROM drug_exposure de
        INNER JOIN t2dm_med_concepts t2m ON de.drug_concept_id = t2m.concept_id
        
        UNION ALL
        
        -- Diabetes supplies in drug_exposure
        SELECT de.person_id, de.drug_exposure_start_date as exposure_date
        FROM drug_exposure de
        INNER JOIN dm_supplies_concepts dms ON de.drug_concept_id = dms.concept_id
        
        UNION ALL
        
        -- Diabetes supplies in device_exposure
        SELECT dev.person_id, dev.device_exposure_start_date as exposure_date
        FROM device_exposure dev
        INNER JOIN dm_supplies_concepts dms ON dev.device_concept_id = dms.concept_id
    ) all_exposures
    GROUP BY person_id
),

-- CTRL_C06: Family history of diabetes (Algorithm 14, page 12)
family_history_dm AS (
    SELECT DISTINCT
        o.person_id,
        TRUE as has_fam_hist_dm
    FROM observation o
    WHERE o.observation_concept_id = 4167217  -- Family history of diabetes mellitus
),

/*******************************************************************************
SECTION 6: Aggregate Patient Criteria
*******************************************************************************/

patient_criteria AS (
    SELECT 
        p.person_id,
        -- Case criteria
        COALESCE(t1dx.t1dm_dx_cnt, 0) as t1dm_dx_cnt,
        COALESCE(t2dx.t2dm_dx_cnt, 0) as t2dm_dx_cnt,
        t1med.t1dm_rx_dt,
        t2med.t2dm_rx_dt,
        alab_c.has_abnormal_lab as abnormal_lab_case,
        alab_c.first_abnormal_lab_dt,
        COALESCE(t2pdx.t2dm_physcn_dx_cnt, 0) as t2dm_physcn_dx_cnt,
        -- Control criteria
        COALESCE(dmdx.dm_dx_cnt, 0) as dm_dx_cnt,
        COALESCE(glab.has_glucose_lab, FALSE) as glucose_lab_exists,
        CASE WHEN alab_ctrl.has_abnormal_lab IS NULL THEN TRUE ELSE FALSE END as normal_labs_control,
        COALESCE(enc.enctrs_cnt, 0) as enctrs_cnt,
        COALESCE(dmms.dm_med_supplies_cnt, 0) as dm_med_supplies_cnt,
        COALESCE(fhist.has_fam_hist_dm, FALSE) as has_fam_hist_dm
    FROM person p
    LEFT JOIN t1dm_dx_counts t1dx ON p.person_id = t1dx.person_id
    LEFT JOIN t2dm_dx_counts t2dx ON p.person_id = t2dx.person_id
    LEFT JOIN t1dm_med_first t1med ON p.person_id = t1med.person_id
    LEFT JOIN t2dm_med_first t2med ON p.person_id = t2med.person_id
    LEFT JOIN abnormal_labs_case alab_c ON p.person_id = alab_c.person_id
    LEFT JOIN t2dm_physician_dx_counts t2pdx ON p.person_id = t2pdx.person_id
    LEFT JOIN dm_dx_counts dmdx ON p.person_id = dmdx.person_id
    LEFT JOIN glucose_lab_exists glab ON p.person_id = glab.person_id
    LEFT JOIN abnormal_labs_control alab_ctrl ON p.person_id = alab_ctrl.person_id
    LEFT JOIN encounter_counts enc ON p.person_id = enc.person_id
    LEFT JOIN dm_meds_supplies_counts dmms ON p.person_id = dmms.person_id
    LEFT JOIN family_history_dm fhist ON p.person_id = fhist.person_id
),

/*******************************************************************************
SECTION 7: Case Definition Logic
Algorithm 1 (page 4) - Five pathways to case identification
*******************************************************************************/

cases AS (
    SELECT 
        person_id,
        'CASE' as cohort_type,
        -- Index date: earliest qualifying event (not specified in PDF)
        CASE 
            WHEN pathway = 1 THEN t2dm_rx_dt  -- T2DM med date
            WHEN pathway = 2 THEN t2dm_rx_dt  -- T2DM med date
            WHEN pathway = 3 THEN first_abnormal_lab_dt  -- Abnormal lab date
            WHEN pathway = 4 THEN LEAST(t2dm_rx_dt, first_abnormal_lab_dt)  -- Earlier of med or lab
            WHEN pathway = 5 THEN t1dm_rx_dt  -- T1DM med date (only med present)
        END as index_date,
        pathway
    FROM (
        SELECT 
            person_id,
            t2dm_rx_dt,
            t1dm_rx_dt,
            first_abnormal_lab_dt,
            CASE 
                -- Pathway 1: No T1DM dx, has T2DM dx, both meds, T2DM meds first
                WHEN t1dm_dx_cnt = 0 
                    AND t2dm_dx_cnt > 0 
                    AND t2dm_rx_dt IS NOT NULL 
                    AND t1dm_rx_dt IS NOT NULL 
                    AND t2dm_rx_dt < t1dm_rx_dt 
                THEN 1
                
                -- Pathway 2: No T1DM dx, has T2DM dx, T2DM meds only
                WHEN t1dm_dx_cnt = 0 
                    AND t2dm_dx_cnt > 0 
                    AND t1dm_rx_dt IS NULL 
                    AND t2dm_rx_dt IS NOT NULL 
                THEN 2
                
                -- Pathway 3: No T1DM dx, has T2DM dx, no meds, abnormal lab
                WHEN t1dm_dx_cnt = 0 
                    AND t2dm_dx_cnt > 0 
                    AND t1dm_rx_dt IS NULL 
                    AND t2dm_rx_dt IS NULL 
                    AND abnormal_lab_case = TRUE 
                THEN 3
                
                -- Pathway 4: No diabetes dx, T2DM meds, abnormal lab
                WHEN t1dm_dx_cnt = 0 
                    AND t2dm_dx_cnt = 0 
                    AND t2dm_rx_dt IS NOT NULL 
                    AND abnormal_lab_case = TRUE 
                THEN 4
                
                -- Pathway 5: No T1DM dx, has T2DM dx, T1DM meds only, >=2 physician T2DM dx
                WHEN t1dm_dx_cnt = 0 
                    AND t2dm_dx_cnt > 0 
                    AND t1dm_rx_dt IS NOT NULL 
                    AND t2dm_rx_dt IS NULL 
                    AND t2dm_physcn_dx_cnt >= 2 
                THEN 5
                
                ELSE NULL
            END as pathway
        FROM patient_criteria
    ) pathways
    WHERE pathway IS NOT NULL
),

/*******************************************************************************
SECTION 8: Control Definition Logic
Algorithm 8 (page 9) - Single pathway requiring ALL conditions
*******************************************************************************/

controls AS (
    SELECT 
        person_id,
        'CONTROL' as cohort_type,
        NULL as index_date  -- Index date not specified for controls in PDF
    FROM patient_criteria
    WHERE dm_dx_cnt = 0                      -- CTRL_C01: No diabetes diagnoses
        AND glucose_lab_exists = TRUE        -- CTRL_C02: Has glucose lab
        AND normal_labs_control = TRUE       -- CTRL_C03: All labs normal
        AND enctrs_cnt >= 2                  -- CTRL_C04: At least 2 encounters
        AND dm_med_supplies_cnt = 0          -- CTRL_C05: No diabetes meds/supplies
        AND has_fam_hist_dm = FALSE          -- CTRL_C06: No family history
),

/*******************************************************************************
SECTION 9: Final Cohort Assembly with Case-Control Mutual Exclusivity
*******************************************************************************/

final_cohort AS (
    -- All cases
    SELECT 
        person_id,
        cohort_type,
        index_date,
        index_date as cohort_start_date,
        NULL as cohort_end_date  -- Not specified in PDF
    FROM cases
    
    UNION ALL
    
    -- Controls excluding anyone who is a case
    SELECT 
        c.person_id,
        c.cohort_type,
        c.index_date,
        c.index_date as cohort_start_date,
        NULL as cohort_end_date
    FROM controls c
    WHERE NOT EXISTS (
        SELECT 1 
        FROM cases cs 
        WHERE cs.person_id = c.person_id
    )
)

/*******************************************************************************
FINAL OUTPUT
Returns one row per qualifying person with their cohort assignment
*******************************************************************************/

SELECT 
    person_id,
    cohort_type,
    index_date,
    cohort_start_date,
    cohort_end_date
FROM final_cohort
ORDER BY cohort_type, person_id;
