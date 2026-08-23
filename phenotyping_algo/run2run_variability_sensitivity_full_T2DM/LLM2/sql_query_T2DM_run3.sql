-- Type 2 Diabetes Mellitus: final SQL query, run 4 (extracted from content_clean_4)

-- =====================================================
-- TYPE 2 DIABETES MELLITUS PHENOTYPING ALGORITHM
-- OMOP CDM Implementation
-- =====================================================
-- This query identifies T2DM cases and controls from an EHR database
-- following the OMOP Common Data Model structure
-- Based on Northwestern University T2DM EMR algorithms
-- =====================================================

WITH 
-- =====================================================
-- STEP 1: Extract patient diagnoses with ICD-9 codes
-- =====================================================
patient_diagnoses AS (
    SELECT 
        co.person_id,
        co.condition_start_date AS diagnosis_date,
        -- Get ICD-9 code from source_value or mapped concept
        CASE 
            WHEN co.condition_source_value LIKE '250.%' THEN co.condition_source_value
            WHEN c.vocabulary_id = 'ICD9CM' THEN c.concept_code
            ELSE co.condition_source_value
        END AS diagnosis_code,
        -- Determine source type based on condition_type_concept_id
        -- 32817: EHR encounter diagnosis, 32818: EHR episode entry, 32819: EHR chief complaint
        -- 32840: EHR problem list entry
        CASE 
            WHEN co.condition_type_concept_id IN (32817, 32818, 32819) THEN 'encounter'
            WHEN co.condition_type_concept_id = 32840 THEN 'problem-list'
            ELSE 'other'
        END AS diagnosis_source
    FROM condition_occurrence co
    LEFT JOIN concept c ON co.condition_source_concept_id = c.concept_id
    WHERE (
        co.condition_source_value LIKE '250.%'  -- Direct ICD-9 codes for diabetes
        OR co.condition_source_value LIKE '790.2%'  -- Glucose abnormalities
        OR co.condition_source_value LIKE '648.0%'  -- Gestational diabetes
        OR co.condition_source_value LIKE '648.8%'  -- Abnormal glucose in pregnancy
        OR co.condition_source_value IN ('791.5', '277.7', 'V18.0', 'V77.1')
        OR c.concept_code LIKE '250.%'
        OR c.concept_code LIKE '790.2%'
        OR c.concept_code LIKE '648.0%'
        OR c.concept_code LIKE '648.8%'
        OR c.concept_code IN ('791.5', '277.7', 'V18.0', 'V77.1')
    )
),

-- =====================================================
-- STEP 2: Extract patient medications with RxNorm codes
-- =====================================================
patient_medications AS (
    SELECT 
        de.person_id,
        de.drug_exposure_start_date AS prescription_date,
        -- Get RxNorm ingredient code through concept ancestor
        ca.ancestor_concept_id,
        c_ing.concept_code AS rxnorm_code
    FROM drug_exposure de
    JOIN concept_ancestor ca ON de.drug_concept_id = ca.descendant_concept_id
    JOIN concept c_ing ON ca.ancestor_concept_id = c_ing.concept_id
    WHERE c_ing.vocabulary_id = 'RxNorm'
    AND c_ing.concept_class_id = 'Ingredient'
    AND c_ing.invalid_reason IS NULL
    AND c_ing.concept_code IN (
        -- T1DM medications (insulin and pramlintide)
        '139825', '274783', '314684', '352385', '400008', '51428', '5856', '86009', '139953',
        -- T2DM medications
        '173', '10633', '2404', '4821', '217360', '4815', '25789', '73044', '274332', 
        '6809', '84108', '33738', '72610', '16681', '30009', '593411', '60548',
        -- Diabetes medical supplies
        '126958', '412956', '412959', '637321', '668291', '668370', '686655', '692383', 
        '748611', '880998', '881056', '751128', '847187', '847191', '847197', '847203', 
        '847207', '847211', '847230', '847239', '847252', '847256', '847259', '847263', 
        '847278', '847416', '847417', '806905', '806903', '408119'
    )
),

-- =====================================================
-- STEP 3: Extract patient lab results with LOINC codes
-- =====================================================
patient_labs AS (
    SELECT 
        m.person_id,
        m.measurement_date AS lab_date,
        -- Get LOINC code from measurement
        CASE 
            WHEN m.measurement_source_value IN ('1558-6', '2339-0', '2345-7', '4548-4', '17856-6', '4549-2', '17855-8') 
                THEN m.measurement_source_value
            WHEN c.vocabulary_id = 'LOINC' THEN c.concept_code
            ELSE m.measurement_source_value
        END AS loinc_code,
        m.value_as_number AS lab_value
    FROM measurement m
    LEFT JOIN concept c ON m.measurement_concept_id = c.concept_id
    WHERE m.value_as_number IS NOT NULL
    AND (
        m.measurement_source_value IN ('1558-6', '2339-0', '2345-7', '4548-4', '17856-6', '4549-2', '17855-8')
        OR c.concept_code IN ('1558-6', '2339-0', '2345-7', '4548-4', '17856-6', '4549-2', '17855-8')
    )
),

-- =====================================================
-- STEP 4: Extract patient encounters
-- =====================================================
patient_encounters AS (
    SELECT 
        vo.person_id,
        vo.visit_start_date AS encounter_date,
        -- Office visit concept IDs: 9202 (Outpatient Visit), 581477 (Office Visit)
        CASE 
            WHEN vo.visit_concept_id IN (9202, 581477) THEN 'office'
            ELSE 'other'
        END AS encounter_type
    FROM visit_occurrence vo
),

-- =====================================================
-- STEP 5: Extract family history of diabetes
-- =====================================================
patient_family_history AS (
    SELECT DISTINCT
        o.person_id,
        1 AS has_diabetes_family_history
    FROM observation o
    JOIN concept c ON o.observation_concept_id = c.concept_id
    WHERE (
        -- Family history of diabetes concepts
        c.concept_name ILIKE '%family history%diabetes%'
        OR o.observation_source_value = 'V18.0'
        OR (o.observation_concept_id IN (4167217, 4058243, 4051114) -- Common family history of diabetes concept IDs
    ))
),

-- =====================================================
-- STEP 6: Aggregate data for T2DM CASE algorithm
-- =====================================================
case_data AS (
    SELECT 
        p.person_id,
        
        -- Count of distinct dates with T1DM diagnoses (ICD-9: 250.x1, 250.x3)
        COALESCE(COUNT(DISTINCT pd.diagnosis_date) FILTER (
            WHERE (pd.diagnosis_code LIKE '250._1' OR pd.diagnosis_code LIKE '250._3')
        ), 0) AS t1dm_dx_dt_cnt,
        
        -- Count of distinct dates with T2DM diagnoses (ICD-9: 250.x0, 250.x2, excluding 250.10, 250.12)
        COALESCE(COUNT(DISTINCT pd.diagnosis_date) FILTER (
            WHERE (pd.diagnosis_code LIKE '250._0' OR pd.diagnosis_code LIKE '250._2')
            AND pd.diagnosis_code NOT IN ('250.10', '250.12')
        ), 0) AS t2dm_dx_dt_cnt,
        
        -- Count of distinct dates with physician-entered T2DM diagnoses
        COALESCE(COUNT(DISTINCT pd.diagnosis_date) FILTER (
            WHERE (pd.diagnosis_code LIKE '250._0' OR pd.diagnosis_code LIKE '250._2')
            AND pd.diagnosis_code NOT IN ('250.10', '250.12')
            AND pd.diagnosis_source IN ('encounter', 'problem-list')
        ), 0) AS t2dm_physcn_dx_dt_cnt,
        
        -- First date of T1DM medications
        MIN(pm.prescription_date) FILTER (
            WHERE pm.rxnorm_code IN ('139825', '274783', '314684', '352385', 
                                    '400008', '51428', '5856', '86009', '139953')
        ) AS t1dm_rx_dt,
        
        -- First date of T2DM medications
        MIN(pm.prescription_date) FILTER (
            WHERE pm.rxnorm_code IN ('173', '10633', '2404', '4821', '217360', '4815', 
                                    '25789', '73044', '274332', '6809', '84108', '33738', 
                                    '72610', '16681', '30009', '593411', '60548')
        ) AS t2dm_rx_dt,
        
        -- Maximum fasting glucose (LOINC: 1558-6)
        MAX(pl.lab_value) FILTER (WHERE pl.loinc_code = '1558-6') AS max_fast_gluc_lab_val,
        
        -- Maximum random glucose (LOINC: 2339-0, 2345-7)
        MAX(pl.lab_value) FILTER (WHERE pl.loinc_code IN ('2339-0', '2345-7')) AS max_rndm_gluc_lab_val,
        
        -- Maximum HbA1c (LOINC: 4548-4, 17856-6, 4549-2, 17855-8)
        MAX(pl.lab_value) FILTER (WHERE pl.loinc_code IN ('4548-4', '17856-6', '4549-2', '17855-8')) AS max_hba1c_lab_val
        
    FROM person p
    LEFT JOIN patient_diagnoses pd ON p.person_id = pd.person_id
    LEFT JOIN patient_medications pm ON p.person_id = pm.person_id
    LEFT JOIN patient_labs pl ON p.person_id = pl.person_id
    GROUP BY p.person_id
),

-- =====================================================
-- STEP 7: Aggregate data for T2DM CONTROL algorithm
-- =====================================================
control_data AS (
    SELECT 
        p.person_id,
        
        -- Count of distinct dates with any diabetes-related diagnoses
        COALESCE(COUNT(DISTINCT pd.diagnosis_date) FILTER (
            WHERE pd.diagnosis_code LIKE '250.%'  -- Diabetes mellitus (T1 & T2)
            OR pd.diagnosis_code = '790.21'  -- Impaired fasting glucose
            OR pd.diagnosis_code = '790.22'  -- Impaired oral glucose tolerance test
            OR pd.diagnosis_code IN ('790.2', '790.29')  -- Abnormal glucose not otherwise specified
            OR pd.diagnosis_code LIKE '648.8%'  -- Abnormal glucose during pregnancy
            OR pd.diagnosis_code LIKE '648.0%'  -- Gestational diabetes
            OR pd.diagnosis_code = '791.5'  -- Glycosuria
            OR pd.diagnosis_code = '277.7'  -- Dysmetabolic syndrome X
            OR pd.diagnosis_code = 'V18.0'  -- Family history of diabetes mellitus
            OR pd.diagnosis_code = 'V77.1'  -- Screening for diabetes mellitus
        ), 0) AS dm_dx_dt_cnt,
        
        -- Check for glucose lab existence
        CASE
            WHEN COUNT(pl.person_id) FILTER (WHERE pl.loinc_code IN ('1558-6', '2339-0', '2345-7')) > 0 
            THEN TRUE
            ELSE FALSE
        END AS glucose_lab_exists,
        
        -- Maximum lab values
        MAX(pl.lab_value) FILTER (WHERE pl.loinc_code = '1558-6') AS max_fast_gluc_lab_val,
        MAX(pl.lab_value) FILTER (WHERE pl.loinc_code IN ('2339-0', '2345-7')) AS max_rndm_gluc_lab_val,
        MAX(pl.lab_value) FILTER (WHERE pl.loinc_code IN ('4548-4', '17856-6', '4549-2', '17855-8')) AS max_hba1c_lab_val,
        
        -- Count of face-to-face outpatient encounters
        COALESCE(COUNT(DISTINCT pe.encounter_date) FILTER (WHERE pe.encounter_type = 'office'), 0) AS enctrs_dt_cnt,
        
        -- Count of diabetes medications and supplies
        COALESCE(COUNT(DISTINCT pm.prescription_date) FILTER (
            WHERE pm.rxnorm_code IN (
                -- All T1DM, T2DM medications and diabetes supplies
                '139825', '274783', '314684', '352385', '400008', '51428', '5856', '86009', '139953',
                '173', '10633', '2404', '4821', '217360', '4815', '25789', '73044', '274332', 
                '6809', '84108', '33738', '72610', '16681', '30009', '593411', '60548',
                '126958', '412956', '412959', '637321', '668291', '668370', '686655', '692383', 
                '748611', '880998', '881056', '751128', '847187', '847191', '847197', '847203', 
                '847207', '847211', '847230', '847239', '847252', '847256', '847259', '847263', 
                '847278', '847416', '847417', '806905', '806903', '408119'
            )
        ), 0) AS dm_meds_supplies_rx_dt_cnt,
        
        -- Family history of diabetes
        CASE 
            WHEN MAX(pfh.has_diabetes_family_history) = 1 THEN TRUE
            ELSE FALSE
        END AS fam_hist_of_dm
        
    FROM person p
    LEFT JOIN patient_diagnoses pd ON p.person_id = pd.person_id
    LEFT JOIN patient_medications pm ON p.person_id = pm.person_id
    LEFT JOIN patient_labs pl ON p.person_id = pl.person_id
    LEFT JOIN patient_encounters pe ON p.person_id = pe.person_id
    LEFT JOIN patient_family_history pfh ON p.person_id = pfh.person_id
    GROUP BY p.person_id
)

-- =====================================================
-- FINAL QUERY: Identify T2DM cases and controls
-- =====================================================
SELECT 
    p.person_id,
    
    -- T2DM CASE identification (5 pathways)
    CASE 
        -- PATH 1: No T1DM dx, has T2DM dx, has both T1DM and T2DM rx, T2DM rx before T1DM rx
        WHEN cd.t1dm_dx_dt_cnt = 0 
            AND cd.t2dm_dx_dt_cnt > 0 
            AND cd.t2dm_rx_dt IS NOT NULL 
            AND cd.t1dm_rx_dt IS NOT NULL 
            AND cd.t2dm_rx_dt < cd.t1dm_rx_dt 
        THEN 'CASE'
        
        -- PATH 2: No T1DM dx, has T2DM dx, no T1DM rx, has T2DM rx
        WHEN cd.t1dm_dx_dt_cnt = 0 
            AND cd.t2dm_dx_dt_cnt > 0 
            AND cd.t1dm_rx_dt IS NULL 
            AND cd.t2dm_rx_dt IS NOT NULL 
        THEN 'CASE'
        
        -- PATH 3: No T1DM dx, has T2DM dx, no T1DM rx, no T2DM rx, has abnormal lab
        -- Abnormal lab for cases: Random glucose > 200 mg/dl OR Fasting glucose >= 125 mg/dl OR HbA1c >= 6.5%
        WHEN cd.t1dm_dx_dt_cnt = 0 
            AND cd.t2dm_dx_dt_cnt > 0 
            AND cd.t1dm_rx_dt IS NULL 
            AND cd.t2dm_rx_dt IS NULL 
            AND (cd.max_rndm_gluc_lab_val > 200 
                OR cd.max_fast_gluc_lab_val >= 125 
                OR cd.max_hba1c_lab_val >= 6.5)
        THEN 'CASE'
        
        -- PATH 4: No T1DM dx, no T2DM dx, has T2DM rx, has abnormal lab
        WHEN cd.t1dm_dx_dt_cnt = 0 
            AND cd.t2dm_dx_dt_cnt = 0 
            AND cd.t2dm_rx_dt IS NOT NULL 
            AND (cd.max_rndm_gluc_lab_val > 200 
                OR cd.max_fast_gluc_lab_val >= 125 
                OR cd.max_hba1c_lab_val >= 6.5)
        THEN 'CASE'
        
        -- PATH 5: No T1DM dx, has T2DM dx, has T1DM rx, no T2DM rx, >= 2 physician-entered T2DM dx dates
        WHEN cd.t1dm_dx_dt_cnt = 0 
            AND cd.t2dm_dx_dt_cnt > 0 
            AND cd.t1dm_rx_dt IS NOT NULL 
            AND cd.t2dm_rx_dt IS NULL 
            AND cd.t2dm_physcn_dx_dt_cnt >= 2 
        THEN 'CASE'
        
        ELSE NULL
    END AS case_status,
    
    -- T2DM CONTROL identification (all 6 criteria must be met)
    CASE 
        WHEN ctr.dm_dx_dt_cnt = 0  -- No diabetes-related diagnoses
            AND ctr.glucose_lab_exists = TRUE  -- At least one glucose measurement performed
            AND (ctr.max_rndm_gluc_lab_val IS NULL OR ctr.max_rndm_gluc_lab_val <= 110)  -- No abnormal random glucose
            AND (ctr.max_fast_gluc_lab_val IS NULL OR ctr.max_fast_gluc_lab_val < 110)  -- No abnormal fasting glucose
            AND (ctr.max_hba1c_lab_val IS NULL OR ctr.max_hba1c_lab_val < 6.0)  -- No abnormal HbA1c
            AND ctr.enctrs_dt_cnt >= 2  -- At least 2 face-to-face outpatient encounters
            AND ctr.dm_meds_supplies_rx_dt_cnt = 0  -- No diabetes medications or supplies
            AND ctr.fam_hist_of_dm = FALSE  -- No family history of diabetes
        THEN 'CONTROL'
        ELSE NULL
    END AS control_status,
    
    -- Final phenotype assignment
    CASE 
        WHEN (
            -- Any of the 5 case pathways
            (cd.t1dm_dx_dt_cnt = 0 AND cd.t2dm_dx_dt_cnt > 0 AND cd.t2dm_rx_dt IS NOT NULL 
                AND cd.t1dm_rx_dt IS NOT NULL AND cd.t2dm_rx_dt < cd.t1dm_rx_dt)
            OR (cd.t1dm_dx_dt_cnt = 0 AND cd.t2dm_dx_dt_cnt > 0 AND cd.t1dm_rx_dt IS NULL 
                AND cd.t2dm_rx_dt IS NOT NULL)
            OR (cd.t1dm_dx_dt_cnt = 0 AND cd.t2dm_dx_dt_cnt > 0 AND cd.t1dm_rx_dt IS NULL 
                AND cd.t2dm_rx_dt IS NULL AND (cd.max_rndm_gluc_lab_val > 200 
                OR cd.max_fast_gluc_lab_val >= 125 OR cd.max_hba1c_lab_val >= 6.5))
            OR (cd.t1dm_dx_dt_cnt = 0 AND cd.t2dm_dx_dt_cnt = 0 AND cd.t2dm_rx_dt IS NOT NULL 
                AND (cd.max_rndm_gluc_lab_val > 200 OR cd.max_fast_gluc_lab_val >= 125 
                OR cd.max_hba1c_lab_val >= 6.5))
            OR (cd.t1dm_dx_dt_cnt = 0 AND cd.t2dm_dx_dt_cnt > 0 AND cd.t1dm_rx_dt IS NOT NULL 
                AND cd.t2dm_rx_dt IS NULL AND cd.t2dm_physcn_dx_dt_cnt >= 2)
        ) THEN 'CASE'
        
        WHEN ctr.dm_dx_dt_cnt = 0 AND ctr.glucose_lab_exists = TRUE
            AND (ctr.max_rndm_gluc_lab_val IS NULL OR ctr.max_rndm_gluc_lab_val <= 110)
            AND (ctr.max_fast_gluc_lab_val IS NULL OR ctr.max_fast_gluc_lab_val < 110)
            AND (ctr.max_hba1c_lab_val IS NULL OR ctr.max_hba1c_lab_val < 6.0)
            AND ctr.enctrs_dt_cnt >= 2 AND ctr.dm_meds_supplies_rx_dt_cnt = 0 
            AND ctr.fam_hist_of_dm = FALSE 
        THEN 'CONTROL'
        
        ELSE 'UNKNOWN'
    END AS phenotype_status

FROM person p
LEFT JOIN case_data cd ON p.person_id = cd.person_id
LEFT JOIN control_data ctr ON p.person_id = ctr.person_id
WHERE p.person_id IS NOT NULL
ORDER BY p.person_id;
