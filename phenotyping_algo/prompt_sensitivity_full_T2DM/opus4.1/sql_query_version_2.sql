-- Type 2 Diabetes Mellitus: final SQL query, version_2 (extracted from last response)

/* ============================================================
   TYPE 2 DIABETES MELLITUS PHENOTYPE
   Source: Northwestern University T2DM EMR Algorithm
   Version: August 19, 2011
   OMOP CDM v5.4 Implementation - PostgreSQL
   ============================================================ */

WITH

/* ============================================================
   CODE SET DEFINITIONS FROM SOURCE DOCUMENT
   ============================================================ */

-- T1DM Diagnosis Codes (Table 3, page 21)
-- ICD-9: 250.x1, 250.x3 where x = any digit
t1dm_diagnosis_concepts AS (
    SELECT DISTINCT
        c.concept_id AS source_concept_id,
        COALESCE(c2.concept_id, c.concept_id) AS standard_concept_id
    FROM concept c
    LEFT JOIN concept_relationship cr 
        ON c.concept_id = cr.concept_id_1
        AND cr.relationship_id = 'Maps to'
        AND cr.invalid_reason IS NULL
    LEFT JOIN concept c2 
        ON cr.concept_id_2 = c2.concept_id
        AND c2.standard_concept = 'S'
        AND c2.invalid_reason IS NULL
    WHERE c.vocabulary_id = 'ICD9CM'
        AND (c.concept_code LIKE '250._1' OR c.concept_code LIKE '250._3')
        AND c.invalid_reason IS NULL
),

-- T2DM Diagnosis Codes (Table 4, page 21)  
-- ICD-9: 250.x0, 250.x2 (excluding 250.10, 250.12) where x = any digit
t2dm_diagnosis_concepts AS (
    SELECT DISTINCT
        c.concept_id AS source_concept_id,
        COALESCE(c2.concept_id, c.concept_id) AS standard_concept_id
    FROM concept c
    LEFT JOIN concept_relationship cr 
        ON c.concept_id = cr.concept_id_1
        AND cr.relationship_id = 'Maps to'
        AND cr.invalid_reason IS NULL
    LEFT JOIN concept c2 
        ON cr.concept_id_2 = c2.concept_id
        AND c2.standard_concept = 'S'
        AND c2.invalid_reason IS NULL
    WHERE c.vocabulary_id = 'ICD9CM'
        AND (c.concept_code LIKE '250._0' OR c.concept_code LIKE '250._2')
        AND c.concept_code NOT IN ('250.10', '250.12')
        AND c.invalid_reason IS NULL
),

-- T1DM Medications (Table 5, pages 21-22)
-- RxNorm ingredient-level codes
t1dm_medication_concepts AS (
    SELECT DISTINCT
        c.concept_id AS source_concept_id,
        COALESCE(c2.concept_id, c.concept_id) AS standard_concept_id
    FROM concept c
    LEFT JOIN concept_relationship cr 
        ON c.concept_id = cr.concept_id_1
        AND cr.relationship_id = 'Maps to'
        AND cr.invalid_reason IS NULL
    LEFT JOIN concept c2 
        ON cr.concept_id_2 = c2.concept_id
        AND c2.standard_concept = 'S'
        AND c2.invalid_reason IS NULL
    WHERE c.vocabulary_id = 'RxNorm'
        AND c.concept_code IN (
            '139825', '274783', '314684', '352385', '400008', 
            '51428', '5856', '86009', '139953'
        )
        AND c.invalid_reason IS NULL
),

-- T2DM Medications (Table 6, page 22)
-- RxNorm ingredient-level codes
t2dm_medication_concepts AS (
    SELECT DISTINCT
        c.concept_id AS source_concept_id,
        COALESCE(c2.concept_id, c.concept_id) AS standard_concept_id
    FROM concept c
    LEFT JOIN concept_relationship cr 
        ON c.concept_id = cr.concept_id_1
        AND cr.relationship_id = 'Maps to'
        AND cr.invalid_reason IS NULL
    LEFT JOIN concept c2 
        ON cr.concept_id_2 = c2.concept_id
        AND c2.standard_concept = 'S'
        AND c2.invalid_reason IS NULL
    WHERE c.vocabulary_id = 'RxNorm'
        AND c.concept_code IN (
            '173', '10633', '2404', '4821', '217360', '4815', 
            '25789', '73044', '274332', '6809', '84108', '33738', 
            '72610', '16681', '30009', '593411', '60548'
        )
        AND c.invalid_reason IS NULL
),

-- Glucose Lab Tests - Fasting and Random (Table 7, page 22)
-- LOINC codes
glucose_lab_concepts AS (
    SELECT DISTINCT
        c.concept_id AS source_concept_id,
        COALESCE(c2.concept_id, c.concept_id) AS standard_concept_id,
        CASE 
            WHEN c.concept_code = '1558-6' THEN 'fasting'
            WHEN c.concept_code IN ('2339-0', '2345-7') THEN 'random'
        END AS glucose_type
    FROM concept c
    LEFT JOIN concept_relationship cr 
        ON c.concept_id = cr.concept_id_1
        AND cr.relationship_id = 'Maps to'
        AND cr.invalid_reason IS NULL
    LEFT JOIN concept c2 
        ON cr.concept_id_2 = c2.concept_id
        AND c2.standard_concept = 'S'
        AND c2.invalid_reason IS NULL
    WHERE c.vocabulary_id = 'LOINC'
        AND c.concept_code IN ('1558-6', '2339-0', '2345-7')
        AND c.invalid_reason IS NULL
),

-- HbA1c Lab Tests (Table 7, page 22)
-- LOINC codes
hba1c_lab_concepts AS (
    SELECT DISTINCT
        c.concept_id AS source_concept_id,
        COALESCE(c2.concept_id, c.concept_id) AS standard_concept_id
    FROM concept c
    LEFT JOIN concept_relationship cr 
        ON c.concept_id = cr.concept_id_1
        AND cr.relationship_id = 'Maps to'
        AND cr.invalid_reason IS NULL
    LEFT JOIN concept c2 
        ON cr.concept_id_2 = c2.concept_id
        AND c2.standard_concept = 'S'
        AND c2.invalid_reason IS NULL
    WHERE c.vocabulary_id = 'LOINC'
        AND c.concept_code IN ('4548-4', '17856-6', '4549-2', '17855-8')
        AND c.invalid_reason IS NULL
),

-- All Diabetes-Related Diagnoses for Control Exclusion (Table 9, page 23)
-- ICD-9 codes
all_dm_diagnosis_concepts AS (
    SELECT DISTINCT
        c.concept_id AS source_concept_id,
        COALESCE(c2.concept_id, c.concept_id) AS standard_concept_id
    FROM concept c
    LEFT JOIN concept_relationship cr 
        ON c.concept_id = cr.concept_id_1
        AND cr.relationship_id = 'Maps to'
        AND cr.invalid_reason IS NULL
    LEFT JOIN concept c2 
        ON cr.concept_id_2 = c2.concept_id
        AND c2.standard_concept = 'S'
        AND c2.invalid_reason IS NULL
    WHERE c.vocabulary_id = 'ICD9CM'
        AND (
            c.concept_code LIKE '250.%'  -- All diabetes codes
            OR c.concept_code IN ('790.21', '790.22', '790.2', '790.29')  -- Impaired glucose
            OR c.concept_code LIKE '648.8%'  -- Abnormal glucose in pregnancy
            OR c.concept_code LIKE '648.0%'  -- Gestational diabetes
            OR c.concept_code = '791.5'  -- Glycosuria
            OR c.concept_code = '277.7'  -- Dysmetabolic syndrome X
            OR c.concept_code = 'V18.0'  -- Family history of diabetes
            OR c.concept_code = 'V77.1'  -- Screening for diabetes
        )
        AND c.invalid_reason IS NULL
),

/* ============================================================
   PATIENT DATA AGGREGATION
   Per Algorithm Requirements
   ============================================================ */

-- T1DM diagnosis count by distinct dates (Algorithm 2, page 5)
t1dm_dx_counts AS (
    SELECT 
        co.person_id,
        COUNT(DISTINCT co.condition_start_date) AS t1dm_dx_count
    FROM condition_occurrence co
    WHERE co.condition_concept_id IN (SELECT standard_concept_id FROM t1dm_diagnosis_concepts)
        OR co.condition_source_concept_id IN (SELECT source_concept_id FROM t1dm_diagnosis_concepts)
    GROUP BY co.person_id
),

-- T2DM diagnosis count by distinct dates (Algorithm 3, page 5)  
t2dm_dx_counts AS (
    SELECT 
        co.person_id,
        COUNT(DISTINCT co.condition_start_date) AS t2dm_dx_count,
        MIN(co.condition_start_date) AS first_t2dm_dx_date
    FROM condition_occurrence co
    WHERE co.condition_concept_id IN (SELECT standard_concept_id FROM t2dm_diagnosis_concepts)
        OR co.condition_source_concept_id IN (SELECT source_concept_id FROM t2dm_diagnosis_concepts)
    GROUP BY co.person_id
),

-- T2DM physician-entered diagnosis count (Algorithm 7, page 7)
-- Source: encounter or problem-list only
t2dm_physician_dx_counts AS (
    SELECT 
        co.person_id,
        COUNT(DISTINCT co.condition_start_date) AS t2dm_physician_dx_count
    FROM condition_occurrence co
    WHERE (co.condition_concept_id IN (SELECT standard_concept_id FROM t2dm_diagnosis_concepts)
           OR co.condition_source_concept_id IN (SELECT source_concept_id FROM t2dm_diagnosis_concepts))
        -- Physician-entered: EHR encounter or problem list
        AND co.condition_type_concept_id IN (
            32817,    -- EHR encounter diagnosis
            32840,    -- EHR problem list
            38000183, -- Observation recorded from EHR encounter
            38000184  -- Observation recorded from EHR problem list
        )
    GROUP BY co.person_id
),

-- First T1DM medication date (Algorithm 5, page 6)
t1dm_med_first AS (
    SELECT 
        de.person_id,
        MIN(de.drug_exposure_start_date) AS first_t1dm_med_date
    FROM drug_exposure de
    WHERE de.drug_concept_id IN (SELECT standard_concept_id FROM t1dm_medication_concepts)
        OR de.drug_source_concept_id IN (SELECT source_concept_id FROM t1dm_medication_concepts)
    GROUP BY de.person_id
),

-- First T2DM medication date (Algorithm 4, page 5)
t2dm_med_first AS (
    SELECT 
        de.person_id,
        MIN(de.drug_exposure_start_date) AS first_t2dm_med_date
    FROM drug_exposure de
    WHERE de.drug_concept_id IN (SELECT standard_concept_id FROM t2dm_medication_concepts)
        OR de.drug_source_concept_id IN (SELECT source_concept_id FROM t2dm_medication_concepts)
    GROUP BY de.person_id
),

-- Maximum lab values for case definition (Algorithm 6, page 6)
-- Abnormal thresholds: Random glucose >= 200 mg/dl, Fasting >= 125 mg/dl, HbA1c >= 6.5%
case_lab_values AS (
    SELECT 
        m.person_id,
        MAX(CASE WHEN g.glucose_type = 'fasting' THEN m.value_as_number END) AS max_fasting_glucose,
        MAX(CASE WHEN g.glucose_type = 'random' THEN m.value_as_number END) AS max_random_glucose,
        MAX(CASE WHEN h.standard_concept_id IS NOT NULL THEN m.value_as_number END) AS max_hba1c,
        MIN(CASE 
            WHEN g.glucose_type = 'random' AND m.value_as_number >= 200 THEN m.measurement_date
            WHEN g.glucose_type = 'fasting' AND m.value_as_number >= 125 THEN m.measurement_date
            WHEN h.standard_concept_id IS NOT NULL AND m.value_as_number >= 6.5 THEN m.measurement_date
        END) AS first_abnormal_lab_date
    FROM measurement m
    LEFT JOIN glucose_lab_concepts g 
        ON (m.measurement_concept_id = g.standard_concept_id 
            OR m.measurement_source_concept_id = g.source_concept_id)
    LEFT JOIN hba1c_lab_concepts h 
        ON (m.measurement_concept_id = h.standard_concept_id 
            OR m.measurement_source_concept_id = h.source_concept_id)
    WHERE g.standard_concept_id IS NOT NULL OR h.standard_concept_id IS NOT NULL
    GROUP BY m.person_id
),

-- Any DM diagnosis count for control exclusion (Algorithm 9, page 10)
any_dm_dx_counts AS (
    SELECT 
        co.person_id,
        COUNT(DISTINCT co.condition_start_date) AS any_dm_dx_count
    FROM condition_occurrence co
    WHERE co.condition_concept_id IN (SELECT standard_concept_id FROM all_dm_diagnosis_concepts)
        OR co.condition_source_concept_id IN (SELECT source_concept_id FROM all_dm_diagnosis_concepts)
    GROUP BY co.person_id
),

-- Glucose lab existence for controls (Algorithm 10, page 10)
glucose_lab_exists AS (
    SELECT 
        m.person_id,
        COUNT(*) AS glucose_lab_count
    FROM measurement m
    WHERE m.measurement_concept_id IN (SELECT standard_concept_id FROM glucose_lab_concepts)
        OR m.measurement_source_concept_id IN (SELECT source_concept_id FROM glucose_lab_concepts)
    GROUP BY m.person_id
),

-- Lab values for control definition (Algorithm 11, page 11)
-- Abnormal thresholds: Random glucose >= 110 mg/dl, Fasting >= 110 mg/dl, HbA1c >= 6.0%
control_lab_values AS (
    SELECT 
        m.person_id,
        MAX(CASE WHEN g.glucose_type = 'fasting' THEN m.value_as_number END) AS max_fasting_glucose,
        MAX(CASE WHEN g.glucose_type = 'random' THEN m.value_as_number END) AS max_random_glucose,
        MAX(CASE WHEN h.standard_concept_id IS NOT NULL THEN m.value_as_number END) AS max_hba1c
    FROM measurement m
    LEFT JOIN glucose_lab_concepts g 
        ON (m.measurement_concept_id = g.standard_concept_id 
            OR m.measurement_source_concept_id = g.source_concept_id)
    LEFT JOIN hba1c_lab_concepts h 
        ON (m.measurement_concept_id = h.standard_concept_id 
            OR m.measurement_source_concept_id = h.source_concept_id)
    WHERE g.standard_concept_id IS NOT NULL OR h.standard_concept_id IS NOT NULL
    GROUP BY m.person_id
),

-- Office encounter count by distinct dates (Algorithm 12, page 11)
office_encounter_counts AS (
    SELECT 
        vo.person_id,
        COUNT(DISTINCT vo.visit_start_date) AS office_encounter_count
    FROM visit_occurrence vo
    WHERE vo.visit_concept_id IN (
        9202,     -- Outpatient Visit
        581477    -- Office Visit
    )
    GROUP BY vo.person_id
),

-- DM medication and supply count (Algorithm 13, page 12)
-- Note: Table 8 supplies use NDDF/VANDF codes not in standard OMOP
dm_med_supply_counts AS (
    SELECT 
        person_id,
        COUNT(DISTINCT event_date) AS dm_med_supply_count
    FROM (
        -- T1DM medications (Table 5)
        SELECT de.person_id, de.drug_exposure_start_date AS event_date
        FROM drug_exposure de
        WHERE de.drug_concept_id IN (SELECT standard_concept_id FROM t1dm_medication_concepts)
            OR de.drug_source_concept_id IN (SELECT source_concept_id FROM t1dm_medication_concepts)
        
        UNION ALL
        
        -- T2DM medications (Table 6)
        SELECT de.person_id, de.drug_exposure_start_date AS event_date
        FROM drug_exposure de
        WHERE de.drug_concept_id IN (SELECT standard_concept_id FROM t2dm_medication_concepts)
            OR de.drug_source_concept_id IN (SELECT source_concept_id FROM t2dm_medication_concepts)
        
        /* SOURCE_AMBIGUITY: Table 8 DM supplies use NDDF/VANDF vocabularies
           which are not standard in OMOP CDM. RxNorm insulin syringe codes
           from Table 8 could be mapped if available in implementation. */
    ) t
    GROUP BY person_id
),

/* ============================================================
   CASE COHORT DEFINITION
   Source: Figure 1 (page 3) and Algorithm 1 (page 4)
   Five pathways defined by if-elseif logic
   ============================================================ */

case_cohort AS (
    SELECT DISTINCT
        p.person_id,
        /* SOURCE_AMBIGUITY: Index date not defined in source document.
           Using earliest qualifying date from the satisfied pathway. */
        CASE
            -- Path 1: Use T2DM med date (first of the two meds)
            WHEN COALESCE(t1dx.t1dm_dx_count, 0) = 0
                 AND COALESCE(t2dx.t2dm_dx_count, 0) > 0
                 AND t2med.first_t2dm_med_date IS NOT NULL
                 AND t1med.first_t1dm_med_date IS NOT NULL
                 AND t2med.first_t2dm_med_date < t1med.first_t1dm_med_date
            THEN t2med.first_t2dm_med_date
            
            -- Path 2: Use T2DM med date
            WHEN COALESCE(t1dx.t1dm_dx_count, 0) = 0
                 AND COALESCE(t2dx.t2dm_dx_count, 0) > 0
                 AND t1med.first_t1dm_med_date IS NULL
                 AND t2med.first_t2dm_med_date IS NOT NULL
            THEN t2med.first_t2dm_med_date
            
            -- Path 3: Use earliest of T2DM dx or abnormal lab
            WHEN COALESCE(t1dx.t1dm_dx_count, 0) = 0
                 AND COALESCE(t2dx.t2dm_dx_count, 0) > 0
                 AND t1med.first_t1dm_med_date IS NULL
                 AND t2med.first_t2dm_med_date IS NULL
                 AND (COALESCE(clab.max_random_glucose, 0) >= 200
                      OR COALESCE(clab.max_fasting_glucose, 0) >= 125
                      OR COALESCE(clab.max_hba1c, 0) >= 6.5)
            THEN LEAST(
                COALESCE(t2dx.first_t2dm_dx_date, DATE '9999-12-31'),
                COALESCE(clab.first_abnormal_lab_date, DATE '9999-12-31')
            )
            
            -- Path 4: Use earliest of T2DM med or abnormal lab
            WHEN COALESCE(t1dx.t1dm_dx_count, 0) = 0
                 AND COALESCE(t2dx.t2dm_dx_count, 0) = 0
                 AND t2med.first_t2dm_med_date IS NOT NULL
                 AND (COALESCE(clab.max_random_glucose, 0) >= 200
                      OR COALESCE(clab.max_fasting_glucose, 0) >= 125
                      OR COALESCE(clab.max_hba1c, 0) >= 6.5)
            THEN LEAST(
                COALESCE(t2med.first_t2dm_med_date, DATE '9999-12-31'),
                COALESCE(clab.first_abnormal_lab_date, DATE '9999-12-31')
            )
            
            -- Path 5: Use T1DM med date
            WHEN COALESCE(t1dx.t1dm_dx_count, 0) = 0
                 AND COALESCE(t2dx.t2dm_dx_count, 0) > 0
                 AND t1med.first_t1dm_med_date IS NOT NULL
                 AND t2med.first_t2dm_med_date IS NULL
                 AND COALESCE(t2pdx.t2dm_physician_dx_count, 0) >= 2
            THEN t1med.first_t1dm_med_date
            
            ELSE NULL
        END AS index_date
    FROM person p
    LEFT JOIN t1dm_dx_counts t1dx ON p.person_id = t1dx.person_id
    LEFT JOIN t2dm_dx_counts t2dx ON p.person_id = t2dx.person_id
    LEFT JOIN t2dm_physician_dx_counts t2pdx ON p.person_id = t2pdx.person_id
    LEFT JOIN t1dm_med_first t1med ON p.person_id = t1med.person_id
    LEFT JOIN t2dm_med_first t2med ON p.person_id = t2med.person_id
    LEFT JOIN case_lab_values clab ON p.person_id = clab.person_id
    WHERE
        -- Path 1 (Algorithm 1, line 1)
        (COALESCE(t1dx.t1dm_dx_count, 0) = 0
         AND COALESCE(t2dx.t2dm_dx_count, 0) > 0
         AND t2med.first_t2dm_med_date IS NOT NULL
         AND t1med.first_t1dm_med_date IS NOT NULL
         AND t2med.first_t2dm_med_date < t1med.first_t1dm_med_date)
        
        OR
        
        -- Path 2 (Algorithm 1, line 2)
        (COALESCE(t1dx.t1dm_dx_count, 0) = 0
         AND COALESCE(t2dx.t2dm_dx_count, 0) > 0
         AND t1med.first_t1dm_med_date IS NULL
         AND t2med.first_t2dm_med_date IS NOT NULL)
        
        OR
        
        -- Path 3 (Algorithm 1, line 3)
        (COALESCE(t1dx.t1dm_dx_count, 0) = 0
         AND COALESCE(t2dx.t2dm_dx_count, 0) > 0
         AND t1med.first_t1dm_med_date IS NULL
         AND t2med.first_t2dm_med_date IS NULL
         AND (COALESCE(clab.max_random_glucose, 0) >= 200
              OR COALESCE(clab.max_fasting_glucose, 0) >= 125
              OR COALESCE(clab.max_hba1c, 0) >= 6.5))
        
        OR
        
        -- Path 4 (Algorithm 1, line 4)
        (COALESCE(t1dx.t1dm_dx_count, 0) = 0
         AND COALESCE(t2dx.t2dm_dx_count, 0) = 0
         AND t2med.first_t2dm_med_date IS NOT NULL
         AND (COALESCE(clab.max_random_glucose, 0) >= 200
              OR COALESCE(clab.max_fasting_glucose, 0) >= 125
              OR COALESCE(clab.max_hba1c, 0) >= 6.5))
        
        OR
        
        -- Path 5 (Algorithm 1, line 5)
        (COALESCE(t1dx.t1dm_dx_count, 0) = 0
         AND COALESCE(t2dx.t2dm_dx_count, 0) > 0
         AND t1med.first_t1dm_med_date IS NOT NULL
         AND t2med.first_t2dm_med_date IS NULL
         AND COALESCE(t2pdx.t2dm_physician_dx_count, 0) >= 2)
),

/* ============================================================
   CONTROL COHORT DEFINITION
   Source: Figure 2 (page 9) and Algorithm 8 (page 9)
   Single pathway with all conditions AND'd
   ============================================================ */

control_cohort AS (
    SELECT DISTINCT
        p.person_id,
        /* SOURCE_AMBIGUITY: Index date not defined in source document.
           Using arbitrary date for controls as no event-based date available. */
        CURRENT_DATE AS index_date
    FROM person p
    LEFT JOIN any_dm_dx_counts adx ON p.person_id = adx.person_id
    LEFT JOIN glucose_lab_exists gle ON p.person_id = gle.person_id
    LEFT JOIN control_lab_values clv ON p.person_id = clv.person_id
    LEFT JOIN office_encounter_counts oec ON p.person_id = oec.person_id
    LEFT JOIN dm_med_supply_counts dms ON p.person_id = dms.person_id
    WHERE
        -- No DM-related diagnoses (Algorithm 9)
        COALESCE(adx.any_dm_dx_count, 0) = 0
        -- Has at least one glucose lab (Algorithm 10)
        AND COALESCE(gle.glucose_lab_count, 0) > 0
        -- No abnormal labs per control thresholds (Algorithm 11)
        AND NOT (COALESCE(clv.max_random_glucose, 0) >= 110
                 OR COALESCE(clv.max_fasting_glucose, 0) >= 110
                 OR COALESCE(clv.max_hba1c, 0) >= 6.0)
        -- At least 2 office encounters (Algorithm 12)
        AND COALESCE(oec.office_encounter_count, 0) >= 2
        -- No DM medications or supplies (Algorithm 13)
        AND COALESCE(dms.dm_med_supply_count, 0) = 0
        -- Must not be a case
        AND p.person_id NOT IN (SELECT person_id FROM case_cohort)
        
        /* SOURCE_AMBIGUITY: Algorithm 14 requires no family history of DM,
           but OMOP CDM v5.4 has no standard family history table.
           This criterion cannot be implemented without custom tables. */
),

/* ============================================================
   FINAL COHORT OUTPUT
   Combining cases and controls with required output columns
   ============================================================ */

final_cohort AS (
    SELECT
        person_id,
        'CASE'::VARCHAR(10) AS cohort_label,
        index_date::DATE AS index_date,
        index_date::DATE AS cohort_start_date,
        NULL::DATE AS cohort_end_date
    FROM case_cohort
    WHERE index_date IS NOT NULL
    
    UNION ALL
    
    SELECT
        person_id,
        'CONTROL'::VARCHAR(10) AS cohort_label,
        index_date::DATE AS index_date,
        index_date::DATE AS cohort_start_date,
        NULL::DATE AS cohort_end_date
    FROM control_cohort
    WHERE index_date IS NOT NULL
)

-- Final output with required columns
SELECT 
    person_id,
    cohort_label,
    index_date,
    cohort_start_date,
    cohort_end_date
FROM final_cohort
ORDER BY cohort_label, person_id;
