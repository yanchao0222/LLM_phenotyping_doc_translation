-- Type 2 Diabetes Mellitus: final SQL query, version_1 (extracted from last response)

/*******************************************************************************
Type 2 Diabetes Mellitus (T2DM) Case and Control Selection Algorithm
Northwestern University EMR Algorithm Implementation for OMOP CDM

Source: Northwestern T2DM Algorithm (PDF pages 1-23)
OMOP CDM Compatibility: v5.x
SQL Dialect: PostgreSQL/ANSI SQL

CRITICAL NOTE: Source algorithm does not define index date. 
Using first qualifying event date for each pathway.
*******************************************************************************/

WITH 
-- =============================================================================
-- SECTION 1: Source Code Concept Sets (PDF Appendix A, pages 21-23)
-- =============================================================================

-- T1DM diagnosis codes - ICD-9: 250.x1, 250.x3 (PDF page 21, Table 3)
-- Note: 'x' represents any single digit (0-9)
t1dm_dx_source AS (
    SELECT c.concept_id, c.concept_code
    FROM concept c
    WHERE c.vocabulary_id = 'ICD9CM'
    AND c.concept_code IN (
        '250.01','250.11','250.21','250.31','250.41','250.51','250.61','250.71','250.81','250.91',
        '250.03','250.13','250.23','250.33','250.43','250.53','250.63','250.73','250.83','250.93'
    )
),

-- T2DM diagnosis codes - ICD-9: 250.x0, 250.x2 excluding 250.10, 250.12 (PDF page 21, Table 4)
t2dm_dx_source AS (
    SELECT c.concept_id, c.concept_code
    FROM concept c
    WHERE c.vocabulary_id = 'ICD9CM'
    AND c.concept_code IN (
        '250.00','250.20','250.30','250.40','250.50','250.60','250.70','250.80','250.90',
        '250.02','250.22','250.32','250.42','250.52','250.62','250.72','250.82','250.92'
        -- Note: 250.10 and 250.12 explicitly excluded per source
    )
),

-- Diabetes-related diagnosis codes for control exclusion (PDF page 23, Table 9)
dm_related_dx_source AS (
    SELECT c.concept_id, c.concept_code
    FROM concept c
    WHERE c.vocabulary_id = 'ICD9CM'
    AND (
        -- All 250.xx codes
        c.concept_code LIKE '250.%'
        -- Impaired glucose codes
        OR c.concept_code IN ('790.21', '790.22', '790.2', '790.29')
        -- Gestational diabetes and abnormal glucose in pregnancy
        OR c.concept_code IN ('648.80','648.81','648.82','648.83','648.84',
                              '648.00','648.01','648.02','648.03','648.04')
        -- Other diabetes-related codes
        OR c.concept_code IN ('791.5', '277.7', 'V18.0', 'V77.1')
    )
),

-- T1DM medications - insulin and pramlintide (PDF page 21, Table 5)
t1dm_rx_ingredients AS (
    SELECT c.concept_id
    FROM concept c
    WHERE c.vocabulary_id = 'RxNorm'
    AND c.concept_class_id = 'Ingredient'
    AND c.concept_id IN (
        139825, 274783, 314684, 352385, 400008, 51428, 5856, 86009, -- insulin
        139953  -- pramlintide (Symlin)
    )
),

-- T2DM medications (PDF page 22, Table 6)
t2dm_rx_ingredients AS (
    SELECT c.concept_id
    FROM concept c
    WHERE c.vocabulary_id = 'RxNorm'
    AND c.concept_class_id = 'Ingredient'
    AND c.concept_id IN (
        173,    -- acetohexamide
        10633,  -- tolazamide
        2404,   -- chlorpropamide
        4821,   -- glipizide
        217360, -- glipizide XL
        4815,   -- glyburide
        25789,  -- glimepiride
        73044,  -- repaglinide
        274332, -- nateglinide
        6809,   -- metformin
        84108,  -- rosiglitazone
        33738,  -- pioglitazone
        72610,  -- troglitazone
        16681,  -- acarbose
        30009,  -- miglitol
        593411, -- sitagliptin
        60548   -- exenatide
    )
),

-- Glucose lab codes - LOINC (PDF page 22, Table 7)
glucose_lab_codes AS (
    SELECT c.concept_id, c.concept_code,
           CASE 
               WHEN c.concept_code = '1558-6' THEN 'fasting'
               WHEN c.concept_code IN ('2339-0', '2345-7') THEN 'random'
           END AS glucose_type
    FROM concept c
    WHERE c.vocabulary_id = 'LOINC'
    AND c.concept_code IN ('1558-6', '2339-0', '2345-7')
),

-- HbA1c lab codes - LOINC (PDF page 22, Table 7)
hba1c_lab_codes AS (
    SELECT c.concept_id
    FROM concept c
    WHERE c.vocabulary_id = 'LOINC'
    AND c.concept_code IN ('4548-4', '17856-6', '4549-2', '17855-8')
),

-- =============================================================================
-- SECTION 2: Map Source to Standard Concepts
-- =============================================================================

t1dm_dx_concepts AS (
    SELECT DISTINCT COALESCE(cr.concept_id_2, s.concept_id) AS concept_id
    FROM t1dm_dx_source s
    LEFT JOIN concept_relationship cr ON s.concept_id = cr.concept_id_1
        AND cr.relationship_id = 'Maps to'
        AND cr.invalid_reason IS NULL
),

t2dm_dx_concepts AS (
    SELECT DISTINCT COALESCE(cr.concept_id_2, s.concept_id) AS concept_id
    FROM t2dm_dx_source s
    LEFT JOIN concept_relationship cr ON s.concept_id = cr.concept_id_1
        AND cr.relationship_id = 'Maps to'
        AND cr.invalid_reason IS NULL
),

dm_related_dx_concepts AS (
    SELECT DISTINCT COALESCE(cr.concept_id_2, s.concept_id) AS concept_id
    FROM dm_related_dx_source s
    LEFT JOIN concept_relationship cr ON s.concept_id = cr.concept_id_1
        AND cr.relationship_id = 'Maps to'
        AND cr.invalid_reason IS NULL
),

glucose_lab_concepts AS (
    SELECT DISTINCT 
        COALESCE(cr.concept_id_2, g.concept_id) AS concept_id,
        g.glucose_type
    FROM glucose_lab_codes g
    LEFT JOIN concept_relationship cr ON g.concept_id = cr.concept_id_1
        AND cr.relationship_id = 'Maps to'
        AND cr.invalid_reason IS NULL
),

hba1c_lab_concepts AS (
    SELECT DISTINCT COALESCE(cr.concept_id_2, h.concept_id) AS concept_id
    FROM hba1c_lab_codes h
    LEFT JOIN concept_relationship cr ON h.concept_id = cr.concept_id_1
        AND cr.relationship_id = 'Maps to'
        AND cr.invalid_reason IS NULL
),

-- Include descendants for drug ingredients
t1dm_rx_concepts AS (
    SELECT DISTINCT ca.descendant_concept_id AS concept_id
    FROM t1dm_rx_ingredients i
    JOIN concept_ancestor ca ON i.concept_id = ca.ancestor_concept_id
),

t2dm_rx_concepts AS (
    SELECT DISTINCT ca.descendant_concept_id AS concept_id
    FROM t2dm_rx_ingredients i
    JOIN concept_ancestor ca ON i.concept_id = ca.ancestor_concept_id
),

-- =============================================================================
-- SECTION 3: Patient Diagnosis Aggregations
-- =============================================================================

-- T1DM diagnoses - count distinct dates (PDF page 2, Algorithm 2)
patient_t1dm_dx AS (
    SELECT 
        co.person_id,
        COUNT(DISTINCT co.condition_start_date::date) AS distinct_dx_dates
    FROM condition_occurrence co
    WHERE co.condition_concept_id IN (SELECT concept_id FROM t1dm_dx_concepts)
    GROUP BY co.person_id
),

-- T2DM diagnoses - count distinct dates (PDF page 2, Algorithm 3)
patient_t2dm_dx AS (
    SELECT 
        co.person_id,
        COUNT(DISTINCT co.condition_start_date::date) AS distinct_dx_dates,
        MIN(co.condition_start_date) AS first_dx_date
    FROM condition_occurrence co
    WHERE co.condition_concept_id IN (SELECT concept_id FROM t2dm_dx_concepts)
    GROUP BY co.person_id
),

-- T2DM physician-entered diagnoses for Path 5 (PDF page 7, Algorithm 7)
-- NOTE: Cannot reliably identify "physician-entered" from "encounter or problem list"
-- without institution-specific condition_type_concept_id mapping
-- Using all T2DM diagnoses as approximation
patient_t2dm_physician_dx AS (
    SELECT 
        co.person_id,
        COUNT(DISTINCT co.condition_start_date::date) AS distinct_dx_dates
    FROM condition_occurrence co
    WHERE co.condition_concept_id IN (SELECT concept_id FROM t2dm_dx_concepts)
    -- Institution-specific: Add condition_type_concept_id filter here if known
    GROUP BY co.person_id
),

-- DM-related diagnoses for control exclusion (PDF page 10, Algorithm 9)
patient_dm_related_dx AS (
    SELECT 
        co.person_id,
        COUNT(DISTINCT co.condition_start_date::date) AS distinct_dx_dates
    FROM condition_occurrence co
    WHERE co.condition_concept_id IN (SELECT concept_id FROM dm_related_dx_concepts)
    GROUP BY co.person_id
),

-- =============================================================================
-- SECTION 4: Patient Medication Aggregations
-- =============================================================================

-- T1DM medications - first date (PDF page 6, Algorithm 5)
patient_t1dm_rx AS (
    SELECT 
        de.person_id,
        MIN(de.drug_exposure_start_date) AS first_rx_date
    FROM drug_exposure de
    WHERE de.drug_concept_id IN (SELECT concept_id FROM t1dm_rx_concepts)
    GROUP BY de.person_id
),

-- T2DM medications - first date (PDF page 5, Algorithm 4)
patient_t2dm_rx AS (
    SELECT 
        de.person_id,
        MIN(de.drug_exposure_start_date) AS first_rx_date
    FROM drug_exposure de
    WHERE de.drug_concept_id IN (SELECT concept_id FROM t2dm_rx_concepts)
    GROUP BY de.person_id
),

-- Combined DM medications for control exclusion (PDF page 12, Algorithm 13)
patient_dm_medications AS (
    SELECT person_id, COUNT(DISTINCT drug_exposure_start_date::date) AS distinct_rx_dates
    FROM (
        SELECT person_id, drug_exposure_start_date
        FROM drug_exposure
        WHERE drug_concept_id IN (SELECT concept_id FROM t1dm_rx_concepts)
        UNION ALL
        SELECT person_id, drug_exposure_start_date
        FROM drug_exposure
        WHERE drug_concept_id IN (SELECT concept_id FROM t2dm_rx_concepts)
    ) all_dm_rx
    GROUP BY person_id
),

-- =============================================================================
-- SECTION 5: Laboratory Results
-- =============================================================================

-- Patient glucose measurements (PDF page 6, Algorithm 6 for cases; page 11, Algorithm 11 for controls)
patient_glucose_values AS (
    SELECT 
        m.person_id,
        glc.glucose_type,
        MAX(m.value_as_number) AS max_value,
        MIN(CASE WHEN m.value_as_number IS NOT NULL THEN m.measurement_date END) AS first_date
    FROM measurement m
    INNER JOIN glucose_lab_concepts glc ON m.measurement_concept_id = glc.concept_id
    WHERE m.value_as_number IS NOT NULL
    GROUP BY m.person_id, glc.glucose_type
),

-- Patient HbA1c measurements
patient_hba1c_values AS (
    SELECT 
        m.person_id,
        MAX(m.value_as_number) AS max_value,
        MIN(CASE WHEN m.value_as_number IS NOT NULL THEN m.measurement_date END) AS first_date
    FROM measurement m
    WHERE m.measurement_concept_id IN (SELECT concept_id FROM hba1c_lab_concepts)
    AND m.value_as_number IS NOT NULL
    GROUP BY m.person_id
),

-- Check for existence of glucose lab (for controls) (PDF page 10, Algorithm 10)
patient_has_glucose_lab AS (
    SELECT DISTINCT person_id
    FROM measurement
    WHERE measurement_concept_id IN (SELECT concept_id FROM glucose_lab_concepts)
),

-- Abnormal labs for CASES (PDF page 6, Algorithm 6)
-- Random glucose >= 200 mg/dl, Fasting glucose >= 125 mg/dl, HbA1c >= 6.5%
patient_abnormal_labs_case AS (
    SELECT 
        p.person_id,
        CASE WHEN 
            COALESCE(fg.max_value, 0) >= 125 OR
            COALESCE(rg.max_value, 0) >= 200 OR
            COALESCE(hb.max_value, 0) >= 6.5
        THEN 1 ELSE 0 END AS has_abnormal_lab,
        LEAST(
            CASE WHEN fg.max_value >= 125 THEN fg.first_date END,
            CASE WHEN rg.max_value >= 200 THEN rg.first_date END,
            CASE WHEN hb.max_value >= 6.5 THEN hb.first_date END
        ) AS first_abnormal_date
    FROM person p
    LEFT JOIN patient_glucose_values fg ON p.person_id = fg.person_id AND fg.glucose_type = 'fasting'
    LEFT JOIN patient_glucose_values rg ON p.person_id = rg.person_id AND rg.glucose_type = 'random'
    LEFT JOIN patient_hba1c_values hb ON p.person_id = hb.person_id
),

-- Abnormal labs for CONTROLS (PDF page 11, Algorithm 11)
-- Random glucose > 110 mg/dl (not >=), Fasting glucose >= 110 mg/dl, HbA1c >= 6.0%
patient_abnormal_labs_control AS (
    SELECT 
        p.person_id,
        CASE WHEN 
            COALESCE(fg.max_value, 0) >= 110 OR
            COALESCE(rg.max_value, 0) > 110 OR  -- Note: > not >=
            COALESCE(hb.max_value, 0) >= 6.0
        THEN 1 ELSE 0 END AS has_abnormal_lab
    FROM person p
    LEFT JOIN patient_glucose_values fg ON p.person_id = fg.person_id AND fg.glucose_type = 'fasting'
    LEFT JOIN patient_glucose_values rg ON p.person_id = rg.person_id AND rg.glucose_type = 'random'
    LEFT JOIN patient_hba1c_values hb ON p.person_id = hb.person_id
),

-- =============================================================================
-- SECTION 6: Office Encounters for Controls (PDF page 11, Algorithm 12)
-- =============================================================================

-- Count distinct dates of office encounters
-- NOTE: Cannot reliably identify "office" visits without institution-specific mapping
-- Counting all outpatient visits as approximation
patient_encounters AS (
    SELECT 
        vo.person_id,
        COUNT(DISTINCT vo.visit_start_date::date) AS distinct_encounter_dates
    FROM visit_occurrence vo
    WHERE vo.visit_concept_id IN (
        9201, -- Inpatient Visit
        9202, -- Outpatient Visit
        9203, -- Emergency Room Visit
        581477 -- Office Visit
    )
    AND vo.visit_concept_id = 9202 -- Outpatient as proxy for office
    GROUP BY vo.person_id
),

-- =============================================================================
-- SECTION 7: T2DM CASES - Five Paths (PDF page 4, Algorithm 1)
-- =============================================================================

t2dm_cases AS (
    -- Path 1: No T1DM dx, has T2DM dx, has both T2DM and T1DM rx, T2DM rx first
    SELECT 
        p.person_id,
        LEAST(t2dx.first_dx_date, t2rx.first_rx_date) AS index_date
    FROM person p
    INNER JOIN patient_t2dm_dx t2dx ON p.person_id = t2dx.person_id AND t2dx.distinct_dx_dates > 0
    INNER JOIN patient_t2dm_rx t2rx ON p.person_id = t2rx.person_id
    INNER JOIN patient_t1dm_rx t1rx ON p.person_id = t1rx.person_id
    WHERE t2rx.first_rx_date < t1rx.first_rx_date
    AND NOT EXISTS (
        SELECT 1 FROM patient_t1dm_dx t1dx 
        WHERE t1dx.person_id = p.person_id AND t1dx.distinct_dx_dates > 0
    )
    
    UNION
    
    -- Path 2: No T1DM dx, has T2DM dx, no T1DM rx, has T2DM rx
    SELECT 
        p.person_id,
        LEAST(t2dx.first_dx_date, t2rx.first_rx_date) AS index_date
    FROM person p
    INNER JOIN patient_t2dm_dx t2dx ON p.person_id = t2dx.person_id AND t2dx.distinct_dx_dates > 0
    INNER JOIN patient_t2dm_rx t2rx ON p.person_id = t2rx.person_id
    WHERE NOT EXISTS (
        SELECT 1 FROM patient_t1dm_dx t1dx 
        WHERE t1dx.person_id = p.person_id AND t1dx.distinct_dx_dates > 0
    )
    AND NOT EXISTS (
        SELECT 1 FROM patient_t1dm_rx t1rx WHERE t1rx.person_id = p.person_id
    )
    
    UNION
    
    -- Path 3: No T1DM dx, has T2DM dx, no T1DM rx, no T2DM rx, has abnormal lab
    SELECT 
        p.person_id,
        LEAST(t2dx.first_dx_date, abn.first_abnormal_date) AS index_date
    FROM person p
    INNER JOIN patient_t2dm_dx t2dx ON p.person_id = t2dx.person_id AND t2dx.distinct_dx_dates > 0
    INNER JOIN patient_abnormal_labs_case abn ON p.person_id = abn.person_id AND abn.has_abnormal_lab = 1
    WHERE NOT EXISTS (
        SELECT 1 FROM patient_t1dm_dx t1dx 
        WHERE t1dx.person_id = p.person_id AND t1dx.distinct_dx_dates > 0
    )
    AND NOT EXISTS (
        SELECT 1 FROM patient_t1dm_rx t1rx WHERE t1rx.person_id = p.person_id
    )
    AND NOT EXISTS (
        SELECT 1 FROM patient_t2dm_rx t2rx WHERE t2rx.person_id = p.person_id
    )
    
    UNION
    
    -- Path 4: No T1DM dx, no T2DM dx, has T2DM rx, has abnormal lab
    SELECT 
        p.person_id,
        LEAST(t2rx.first_rx_date, abn.first_abnormal_date) AS index_date
    FROM person p
    INNER JOIN patient_t2dm_rx t2rx ON p.person_id = t2rx.person_id
    INNER JOIN patient_abnormal_labs_case abn ON p.person_id = abn.person_id AND abn.has_abnormal_lab = 1
    WHERE NOT EXISTS (
        SELECT 1 FROM patient_t1dm_dx t1dx 
        WHERE t1dx.person_id = p.person_id AND t1dx.distinct_dx_dates > 0
    )
    AND NOT EXISTS (
        SELECT 1 FROM patient_t2dm_dx t2dx 
        WHERE t2dx.person_id = p.person_id AND t2dx.distinct_dx_dates > 0
    )
    
    UNION
    
    -- Path 5: No T1DM dx, has T2DM dx, has T1DM rx, no T2DM rx, >=2 physician T2DM dx
    SELECT 
        p.person_id,
        LEAST(t2dx.first_dx_date, t1rx.first_rx_date) AS index_date
    FROM person p
    INNER JOIN patient_t2dm_dx t2dx ON p.person_id = t2dx.person_id AND t2dx.distinct_dx_dates > 0
    INNER JOIN patient_t1dm_rx t1rx ON p.person_id = t1rx.person_id
    INNER JOIN patient_t2dm_physician_dx phys ON p.person_id = phys.person_id AND phys.distinct_dx_dates >= 2
    WHERE NOT EXISTS (
        SELECT 1 FROM patient_t1dm_dx t1dx 
        WHERE t1dx.person_id = p.person_id AND t1dx.distinct_dx_dates > 0
    )
    AND NOT EXISTS (
        SELECT 1 FROM patient_t2dm_rx t2rx WHERE t2rx.person_id = p.person_id
    )
),

-- =============================================================================
-- SECTION 8: T2DM CONTROLS (PDF page 9, Algorithm 8)
-- =============================================================================

t2dm_controls AS (
    SELECT 
        p.person_id,
        glab.first_glucose_date AS index_date
    FROM person p
    -- Must have glucose lab (PDF page 10, Algorithm 10)
    INNER JOIN (
        SELECT person_id, MIN(measurement_date) AS first_glucose_date
        FROM measurement
        WHERE measurement_concept_id IN (SELECT concept_id FROM glucose_lab_concepts)
        GROUP BY person_id
    ) glab ON p.person_id = glab.person_id
    -- Must have >=2 office encounters (PDF page 11, Algorithm 12)
    INNER JOIN patient_encounters enc ON p.person_id = enc.person_id AND enc.distinct_encounter_dates >= 2
    -- Must not have abnormal labs (PDF page 11, Algorithm 11)
    LEFT JOIN patient_abnormal_labs_control abn ON p.person_id = abn.person_id
    WHERE (abn.has_abnormal_lab IS NULL OR abn.has_abnormal_lab = 0)
    -- Must not have DM-related diagnoses (PDF page 10, Algorithm 9)
    AND NOT EXISTS (
        SELECT 1 FROM patient_dm_related_dx dx 
        WHERE dx.person_id = p.person_id AND dx.distinct_dx_dates > 0
    )
    -- Must not have DM medications/supplies (PDF page 12, Algorithm 13)
    AND NOT EXISTS (
        SELECT 1 FROM patient_dm_medications meds 
        WHERE meds.person_id = p.person_id AND meds.distinct_rx_dates > 0
    )
    -- Exclude anyone who is a case
    AND NOT EXISTS (
        SELECT 1 FROM t2dm_cases cases WHERE cases.person_id = p.person_id
    )
    -- NOTE: Family history check omitted - no reliable OMOP mapping available
    -- NOTE: Medical supplies check omitted - NDDF/VANDF not standard OMOP vocabularies
)

-- =============================================================================
-- SECTION 9: Final Result Set
-- =============================================================================

SELECT 
    person_id,
    'CASE' AS phenotype_group,
    index_date
FROM t2dm_cases

UNION ALL

SELECT 
    person_id,
    'CONTROL' AS phenotype_group,
    index_date
FROM t2dm_controls

ORDER BY phenotype_group, person_id;
