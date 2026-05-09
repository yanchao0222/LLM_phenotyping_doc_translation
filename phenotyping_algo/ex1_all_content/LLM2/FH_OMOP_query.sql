-- ==============================================================================
-- FAMILIAL HYPERCHOLESTEROLEMIA (FH) PHENOTYPING ALGORITHM
-- Based on Modified Dutch Lipid Clinic Network (DLCN) Criteria
-- Version 2.0 from June 2016
-- ==============================================================================

WITH 
-- -----------------------------------------------------------------------------
-- STAGE I: PRIMARY HYPERCHOLESTEROLEMIA IDENTIFICATION
-- -----------------------------------------------------------------------------

eligible_patients AS (
    -- Include patients >=18 years old with lipid profile
    SELECT DISTINCT person_id, 
           MAX(value_as_number) as highest_ldl_c,
           MAX(measurement_date) as index_date
    FROM measurement
    WHERE measurement_concept_id IN (
        -- LDL-C LOINC codes
        '2089-1', '18262-6', '49132-4', '35198-1', '39469-2',
        '12773-8', '18261-8', '22748-8', '13457-7', '9346-8',
        '2574-2', '14815-5'
    )
    AND person_id IN (
        SELECT person_id 
        FROM person 
        WHERE EXTRACT(YEAR FROM measurement_date) - year_of_birth >= 18
    )
    GROUP BY person_id
),

triglyceride_flag AS (
    -- Flag patients with TG > 220 mg/dL
    SELECT DISTINCT person_id
    FROM measurement
    WHERE measurement_concept_id IN (
        -- Triglyceride LOINC codes
        '2571-8', '30524-3', '3048-6', '35217-9', 
        '28554-4', '14927-8', '47210-0'
    )
    AND value_as_number > 220
),

secondary_causes_exclusion AS (
    -- Exclude patients with secondary causes within 1 year prior to index date
    SELECT DISTINCT m.person_id
    FROM measurement m
    JOIN eligible_patients e ON m.person_id = e.person_id
    WHERE m.measurement_date BETWEEN DATEADD(year, -1, e.index_date) AND e.index_date
    AND (
        -- Hypothyroidism: TSH >= 10 mIU/L
        (m.measurement_concept_id IN ('11579-0', '24348-5') AND m.value_as_number >= 10)
        OR
        -- Biliary obstruction: Alkaline phosphatase >= 200 IU/L  
        (m.measurement_concept_id IN ('6768-6', '12805-8') AND m.value_as_number >= 200)
        OR
        -- Liver disease: Total bilirubin > 2.0 mg/dL
        (m.measurement_concept_id IN ('35194-0', '1975-2', '14631-6') AND m.value_as_number > 2.0)
        OR
        -- Nephrotic syndrome: 24h urine protein > 3g OR protein/creatinine ratio > 3.0
        (m.measurement_concept_id IN ('21482-5', '2889-4', '21028-6') AND m.value_as_number > 3)
        OR
        (m.measurement_concept_id IN ('13801-6', '2890-2') AND m.value_as_number > 3.0)
        OR
        -- Renal failure: Creatinine > 2.6 mg/dL
        (m.measurement_concept_id IN ('14682-9', '2160-0', '35203-9', '38483-4', '59826-8', '77140-2') 
         AND m.value_as_number > 2.6)
        OR
        -- Renal failure: eGFR < 15 mL/min/BSA
        (m.measurement_concept_id IN ('50261-7', '45066-8', '48642-3', '48643-1', '33914-3')
         AND m.value_as_number < 15)
        OR
        -- Diabetes: HbA1c > 9%
        (m.measurement_concept_id IN ('4549-2', '17855-8', '17856-6', '41995-2')
         AND m.value_as_number > 9)
        OR
        -- Diabetes: Fasting glucose > 200 mg/dL (>220 mg/dL for code 1558-6)
        (m.measurement_concept_id = '1556-0' AND m.value_as_number > 200)
        OR
        (m.measurement_concept_id = '1558-6' AND m.value_as_number > 220)
    )
),

pregnancy_flag AS (
    -- Flag pregnant patients with LDL-C >= 155 mg/dL within 1 year prior to index
    SELECT DISTINCT c.person_id
    FROM condition_occurrence c
    JOIN eligible_patients e ON c.person_id = e.person_id
    WHERE c.condition_concept_id IN ('V22', 'V23', '645', '651', '652')
    AND c.condition_start_date BETWEEN DATEADD(year, -1, e.index_date) AND e.index_date
    AND e.highest_ldl_c >= 155
),

lipid_lowering_treatment AS (
    -- Identify patients on lipid-lowering treatment within 1 year prior to index
    SELECT DISTINCT d.person_id
    FROM drug_exposure d
    JOIN eligible_patients e ON d.person_id = e.person_id
    WHERE d.drug_exposure_start_date BETWEEN DATEADD(year, -1, e.index_date) AND e.index_date
    AND d.drug_concept_id IN (
        -- RxNorm codes for lipid-lowering medications
        '36567', '41127', '6472', '42463', '861634', '83367', '301542', 
        '221072', '1152441', '7393', '8703', '4719', '341248', '141626',
        '2447', '2685', '1367839', '1364479', '1665895', '1665900',
        '1665904', '1665906', '1659156', '1659161', '1659165', '1659167',
        '1659177', '1659179', '1659182', '1659183', '495215', '1372731',
        '327008', '404914', '1372754'
    )
),

adjusted_ldl_c AS (
    -- Adjust LDL-C by dividing by 0.7 if on lipid-lowering treatment
    SELECT e.person_id,
           e.highest_ldl_c,
           e.index_date,
           CASE 
               WHEN l.person_id IS NOT NULL THEN e.highest_ldl_c / 0.7
               ELSE e.highest_ldl_c
           END AS adjusted_ldl_value
    FROM eligible_patients e
    LEFT JOIN lipid_lowering_treatment l ON e.person_id = l.person_id
),

primary_hypercholesterolemia AS (
    -- Stage I case/control assignment
    SELECT a.person_id,
           a.adjusted_ldl_value,
           a.index_date,
           CASE 
               WHEN a.adjusted_ldl_value >= 155 THEN 'CASE'
               WHEN a.adjusted_ldl_value < 130 THEN 'CONTROL'
               ELSE 'UNKNOWN'
           END AS stage1_status
    FROM adjusted_ldl_c a
    WHERE a.person_id NOT IN (SELECT person_id FROM secondary_causes_exclusion)
    -- Note: Patients in triglyceride_flag and pregnancy_flag are flagged but not excluded
),

-- -----------------------------------------------------------------------------
-- STAGE II: FH SCORING USING MODIFIED DLCN CRITERIA
-- -----------------------------------------------------------------------------

group1_ldl_score AS (
    -- Group I: LDL-C levels
    SELECT person_id,
           CASE 
               WHEN adjusted_ldl_value >= 325 THEN 8
               WHEN adjusted_ldl_value >= 251 AND adjusted_ldl_value < 325 THEN 5
               WHEN adjusted_ldl_value >= 191 AND adjusted_ldl_value < 251 THEN 3
               WHEN adjusted_ldl_value >= 155 AND adjusted_ldl_value < 191 THEN 1
               ELSE 0
           END AS ldl_points
    FROM primary_hypercholesterolemia
    WHERE stage1_status = 'CASE'
),

group2_personal_history AS (
    -- Group II: Personal history of premature ASCVD
    -- Premature: <56 years for males, <66 years for females
    SELECT co.person_id,
           MAX(CASE
               -- Premature CHD (2 points)
               WHEN co.condition_concept_id IN (
                   -- Angina
                   '413.0', '413.1', '413.9',
                   -- Myocardial infarction
                   '410.00', '410.01', '410.02', '410.10', '410.11', '410.12',
                   '410.20', '410.21', '410.22', '410.30', '410.31', '410.32',
                   '410.40', '410.41', '410.42', '410.50', '410.51', '410.52',
                   '410.60', '410.61', '410.62', '410.70', '410.71', '410.72',
                   '410.80', '410.81', '410.82', '410.90', '410.91', '410.92',
                   '412', '429.71', '429.79',
                   -- Coronary atherosclerosis
                   '414.00', '414.01', '414.02', '414.03', '414.04', '414.05',
                   '414.06', '414.07'
               )
               AND ((p.gender_concept_id = 8507 AND 
                     EXTRACT(YEAR FROM co.condition_start_date) - p.year_of_birth < 56)
                    OR 
                    (p.gender_concept_id = 8532 AND 
                     EXTRACT(YEAR FROM co.condition_start_date) - p.year_of_birth < 66))
               THEN 2
               
               -- Premature CVD/PAD (1 point)
               WHEN co.condition_concept_id IN (
                   -- Stroke
                   '434.00', '434.01', '434.10', '434.11', '434.90', '434.91',
                   '437.0', '437.1',
                   -- TIA
                   '435.0', '435.1', '435.2', '435.3', '435.8', '435.9',
                   -- Carotid disease
                   '433.00', '433.01', '433.10', '433.11', '433.20', '433.21',
                   '433.30', '433.31', '433.80', '433.81', '433.90', '433.91',
                   -- PAD
                   '440.20', '440.21', '440.22', '440.23', '440.24', '440.29'
               )
               AND ((p.gender_concept_id = 8507 AND 
                     EXTRACT(YEAR FROM co.condition_start_date) - p.year_of_birth < 56)
                    OR 
                    (p.gender_concept_id = 8532 AND 
                     EXTRACT(YEAR FROM co.condition_start_date) - p.year_of_birth < 66))
               THEN 1
               
               ELSE 0
           END) AS personal_history_points
    FROM condition_occurrence co
    JOIN person p ON co.person_id = p.person_id
    JOIN primary_hypercholesterolemia ph ON co.person_id = ph.person_id
    WHERE ph.stage1_status = 'CASE'
    GROUP BY co.person_id
),

-- Note: Group III (Family History) and Group IV (Physical Exam) would require 
-- NLP processing of clinical notes as described in the document
-- These would be implemented as separate processes feeding into this algorithm

group3_family_history AS (
    -- Placeholder for NLP-extracted family history
    -- Would contain: family_history_premature_ascvd (1 point)
    --                family_history_hypercholesterolemia (1 point)
    SELECT person_id, 0 AS family_history_points
    FROM primary_hypercholesterolemia
    WHERE stage1_status = 'CASE'
),

group4_physical_exam AS (
    -- Placeholder for NLP-extracted physical exam findings
    -- Would contain: tendon_xanthomas (6 points)
    --                early_corneal_arcus if age < 45 (4 points)
    SELECT person_id, 0 AS physical_exam_points
    FROM primary_hypercholesterolemia  
    WHERE stage1_status = 'CASE'
),

-- -----------------------------------------------------------------------------
-- FINAL FH CLASSIFICATION
-- -----------------------------------------------------------------------------

fh_total_score AS (
    -- Sum highest score from each group
    SELECT g1.person_id,
           COALESCE(g1.ldl_points, 0) + 
           COALESCE(g2.personal_history_points, 0) + 
           COALESCE(g3.family_history_points, 0) + 
           COALESCE(g4.physical_exam_points, 0) AS total_score
    FROM group1_ldl_score g1
    LEFT JOIN group2_personal_history g2 ON g1.person_id = g2.person_id
    LEFT JOIN group3_family_history g3 ON g1.person_id = g3.person_id
    LEFT JOIN group4_physical_exam g4 ON g1.person_id = g4.person_id
)

-- Final FH status classification
SELECT person_id,
       total_score,
       CASE 
           WHEN total_score > 8 THEN 'DEFINITE_FH'
           WHEN total_score >= 6 AND total_score <= 8 THEN 'PROBABLE_FH'
           WHEN total_score >= 3 AND total_score <= 5 THEN 'POSSIBLE_FH'
           WHEN total_score >= 0 AND total_score <= 2 THEN 'UNLIKELY_FH'
       END AS fh_diagnosis,
       CASE 
           WHEN total_score >= 6 THEN 'FH_CASE'
           WHEN total_score >= 3 AND total_score <= 5 THEN 'FH_UNKNOWN'
           WHEN total_score <= 2 THEN 'FH_CONTROL'
       END AS final_classification
FROM fh_total_score;