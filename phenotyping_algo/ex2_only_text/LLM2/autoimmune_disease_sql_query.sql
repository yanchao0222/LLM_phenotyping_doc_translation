-- ============================================================================
-- AUTOIMMUNE DISEASE (AID) PHENOTYPING ALGORITHM V4 - EXECUTABLE SQL
-- ============================================================================
-- Purpose: Identify autoimmune disease cases and controls from OMOP CDM database
-- Based on structured EHR elements using ICD9CM, ICD10CM, and SNOMED codes
-- OMOP CDM Version: 5.x
-- ============================================================================

-- ============================================================================
-- SECTION 1: AUTOIMMUNE DISEASE CASES
-- ============================================================================
-- Case Definition: Patient has at least one autoimmune disease
-- Requirement: Any 3 diagnosis codes on distinct days within the same disease
-- with first and last diagnoses at least 7 days apart
-- Special rule: T1D patients cannot have T2D codes
-- ============================================================================

WITH autoimmune_disease_diagnoses AS (
    SELECT DISTINCT
        co.person_id,
        c.concept_code as diagnosis_code,
        c.vocabulary_id as code_type,
        co.condition_start_date as diagnosis_date,
        -- Map diagnosis codes to disease names
        -- Based on 51 diseases across 9 groups (46 non-overlapping)
        CASE 
            -- Example mapping from PDF: Vasculitis: Takayasu's disease
            WHEN c.vocabulary_id = 'ICD9CM' AND c.concept_code = '446.7' THEN 'Takayasus_disease'
            WHEN c.vocabulary_id = 'ICD10CM' AND c.concept_code = 'M31.4' THEN 'Takayasus_disease'
            WHEN c.vocabulary_id = 'SNOMED' AND c.concept_code = '359789008' THEN 'Takayasus_disease'
            
            -- Additional disease mappings would be included here based on 
            -- the complete code list from AIDalgorithm_V1_coding_cases.csv
            -- Total of 1,528 diagnosis codes for all 51 diseases
            
            ELSE 'Autoimmune_disease' -- Generic label for other codes
        END as disease_name
    FROM 
        condition_occurrence co
        INNER JOIN concept c ON co.condition_concept_id = c.concept_id
    WHERE 
        -- Filter for autoimmune disease codes only
        -- PDF states: "1528 diagnosis codes were used to determine case status"
        -- Codes are listed in AIDalgorithm_V1_coding_cases.csv
        (
            -- ICD9CM codes
            (c.vocabulary_id = 'ICD9CM' AND c.concept_code IN (
                '446.7'  -- Takayasu's disease (example from PDF)
                -- Additional ICD9CM codes from CSV file would be listed here
            ))
            OR
            -- ICD10CM codes  
            (c.vocabulary_id = 'ICD10CM' AND c.concept_code IN (
                'M31.4'  -- Aortic arch syndrome [Takayasu] (example from PDF)
                -- Additional ICD10CM codes from CSV file would be listed here
            ))
            OR
            -- SNOMED codes
            (c.vocabulary_id = 'SNOMED' AND c.concept_code IN (
                '359789008'  -- Takayasu's disease (example from PDF)
                -- Additional SNOMED codes from CSV file would be listed here
            ))
        )
        AND co.condition_start_date IS NOT NULL
),

-- Calculate distinct days and date ranges per patient-disease combination
patient_disease_summary AS (
    SELECT 
        person_id,
        disease_name,
        COUNT(DISTINCT diagnosis_date) as distinct_diagnosis_days,
        MIN(diagnosis_date) as first_diagnosis_date,
        MAX(diagnosis_date) as last_diagnosis_date
    FROM autoimmune_disease_diagnoses
    GROUP BY person_id, disease_name
),

-- Identify patients with Type 1 Diabetes
t1d_patients AS (
    SELECT DISTINCT person_id
    FROM patient_disease_summary
    WHERE disease_name = 'T1D'
),

-- Identify patients with Type 2 Diabetes for exclusion
t2dm_patients AS (
    SELECT DISTINCT co.person_id
    FROM 
        condition_occurrence co
        INNER JOIN concept c ON co.condition_concept_id = c.concept_id
    WHERE 
        -- Type 2 Diabetes Mellitus codes
        -- Listed in AIDalgorithm_V1_coding_cases.csv under "Type 2 Diabetes Mellitus (T2DM)"
        (
            (c.vocabulary_id = 'ICD9CM' AND c.concept_code IN (
                -- T2DM ICD9 codes from CSV file would be listed here
                '250.00'  -- Example T2DM code
            ))
            OR
            (c.vocabulary_id = 'ICD10CM' AND c.concept_code IN (
                -- T2DM ICD10 codes from CSV file would be listed here
                'E11.9'  -- Example T2DM code
            ))
        )
),

-- Apply Case Cohort: Condition A
confirmed_cases AS (
    SELECT DISTINCT
        pds.person_id,
        pds.disease_name
    FROM patient_disease_summary pds
    WHERE 
        -- Condition A: Any 3 diagnosis codes on distinct days within the same disease
        pds.distinct_diagnosis_days >= 3
        
        -- AND first and last diagnoses at least 7 days apart
        AND DATEDIFF(day, pds.first_diagnosis_date, pds.last_diagnosis_date) >= 7
        
        -- Exclude T1D patients who also have T2DM codes
        AND pds.person_id NOT IN (
            SELECT t1d.person_id 
            FROM t1d_patients t1d
            INNER JOIN t2dm_patients t2dm ON t1d.person_id = t2dm.person_id
        )
),

-- ============================================================================
-- SECTION 2: AUTOIMMUNE DISEASE CONTROLS  
-- ============================================================================
-- Control Definition: Must meet BOTH conditions:
-- Condition A: No autoimmune and auto-inflammatory diagnosis codes (SNOMED)
-- Condition B: No instances of any positive serologies
-- ============================================================================

-- Control Cohort: Condition A - Exclusion by diagnosis
excluded_by_diagnosis AS (
    SELECT DISTINCT co.person_id
    FROM 
        condition_occurrence co
        INNER JOIN concept c ON co.condition_concept_id = c.concept_id
    WHERE 
        -- No autoimmune and auto-inflammatory diagnosis codes
        -- PDF states: "49960 diagnosis codes and measurement codes were used for controls"
        -- Codes listed in AIDalgorithm_V1_coding_control.csv under "Auto-inflammatory + Autoimmune (SNOMED)"
        c.vocabulary_id = 'SNOMED'
        AND c.concept_code IN (
            -- Placeholder for comprehensive SNOMED code list from CSV file
            -- This would include all 49,960 codes for autoimmune and auto-inflammatory conditions
            'PLACEHOLDER_SNOMED_CODE'
            -- Full list would be inserted from AIDalgorithm_V1_coding_control.csv
        )
),

-- Control Cohort: Condition B - Exclusion by positive serology
excluded_by_positive_serology AS (
    SELECT DISTINCT m.person_id
    FROM 
        measurement m
        INNER JOIN concept c ON m.measurement_concept_id = c.concept_id
    WHERE 
        -- Check for positive results in any of 10 serology test categories
        -- Codes listed in AIDalgorithm_V1_coding_control.csv under variables starting with "Serology"
        c.vocabulary_id = 'LOINC'
        AND (
            -- Serology test is positive based on value
            (
                -- Check numeric values that indicate positive
                (m.value_as_number IS NOT NULL AND m.value_as_number > m.range_high)
                OR
                -- Check concept values for positive result
                (m.value_as_concept_id IN (
                    SELECT concept_id 
                    FROM concept 
                    WHERE concept_name IN ('Positive', 'Detected', 'Reactive', 'Present')
                ))
                OR
                -- Check source values for positive result
                (UPPER(m.value_source_value) IN ('POSITIVE', 'POS', 'DETECTED', 'REACTIVE', 'PRESENT'))
            )
            AND
            (
                -- 1. Anti Nuclear Antibody (ANA)
                c.concept_code IN (
                    -- LOINC codes from "Serology: ANA" in CSV file
                    'PLACEHOLDER_ANA_LOINC'
                )
                OR
                -- 2. Anti-Cytoplasmic Neutrophil Antibodies (ANCA)
                c.concept_code IN (
                    -- LOINC codes from "Serology: ANCA" in CSV file
                    'PLACEHOLDER_ANCA_LOINC'
                )
                OR
                -- 3. Anti-DNA Antibody (dsDNA)
                c.concept_code IN (
                    -- LOINC codes from "Serology: dsDNA" in CSV file
                    'PLACEHOLDER_DSDNA_LOINC'
                )
                OR
                -- 4. Cyclic Citrullinated Peptide Antibody (CCP)
                c.concept_code IN (
                    -- LOINC codes from "Serology: CCP" in CSV file
                    'PLACEHOLDER_CCP_LOINC'
                )
                OR
                -- 5. Rheumatoid Factor (RF)
                c.concept_code IN (
                    -- LOINC codes from "Serology: RF" in CSV file
                    'PLACEHOLDER_RF_LOINC'
                )
                OR
                -- 6. Beta 2 Glycoprotein I Antibody
                c.concept_code IN (
                    -- LOINC codes from "Serology: B2 Glycoprotein 1" in CSV file
                    'PLACEHOLDER_B2GLYC_LOINC'
                )
                OR
                -- 7. RNA Polymerase 3 Antibody (RNA PIII, RNAP3)
                c.concept_code IN (
                    -- LOINC codes from "Serology: RNA PIII" in CSV file
                    'PLACEHOLDER_RNAPIII_LOINC'
                )
                OR
                -- 8. Anti-Cardiolipin Antibodies (IgG and IgM)
                c.concept_code IN (
                    -- LOINC codes from "Serology: Cardiolipin" in CSV file
                    'PLACEHOLDER_CARDIOLIPIN_LOINC'
                )
                OR
                -- 9. Centromere Antibody IgG
                c.concept_code IN (
                    -- LOINC codes from "Serology: Centromere IgG" in CSV file
                    'PLACEHOLDER_CENTROMERE_LOINC'
                )
                OR
                -- 10. Extractable Nuclear Antibodies (ENA)
                -- Including Jo-1, RNP, Scl-70, Sm, SSA, SSB
                c.concept_code IN (
                    -- LOINC codes from "Serology: ENA" in CSV file
                    'PLACEHOLDER_ENA_LOINC'
                )
            )
        )
),

-- Get all persons in database for control evaluation
all_persons AS (
    SELECT DISTINCT person_id
    FROM person
    WHERE person_id IS NOT NULL
),

-- Identify confirmed control patients meeting both conditions
confirmed_controls AS (
    SELECT DISTINCT
        ap.person_id
    FROM all_persons ap
    WHERE 
        -- Control Cohort: Condition A - No autoimmune/auto-inflammatory diagnosis
        ap.person_id NOT IN (
            SELECT person_id FROM excluded_by_diagnosis
        )
        
        -- AND Control Cohort: Condition B - No positive serologies
        AND ap.person_id NOT IN (
            SELECT person_id FROM excluded_by_positive_serology  
        )
        
        -- AND not already identified as a case
        AND ap.person_id NOT IN (
            SELECT person_id FROM confirmed_cases
        )
)

-- ============================================================================
-- FINAL OUTPUT: Combine cases and controls
-- ============================================================================
SELECT 
    person_id,
    phenotype_status,
    disease_name,
    CURRENT_DATE as classification_date
FROM (
    -- All confirmed cases with their disease names
    SELECT 
        person_id,
        'CASE' as phenotype_status,
        disease_name
    FROM confirmed_cases
    
    UNION ALL
    
    -- All confirmed controls (no disease name)
    SELECT 
        person_id,
        'CONTROL' as phenotype_status,
        NULL as disease_name
    FROM confirmed_controls
) final_cohort
ORDER BY 
    phenotype_status DESC,  -- Cases first, then controls
    person_id;

-- ============================================================================
-- END OF AUTOIMMUNE DISEASE PHENOTYPING ALGORITHM
-- ============================================================================
-- Note: This query requires the complete code lists from:
-- 1. AIDalgorithm_V1_coding_cases.csv (1,528 diagnosis codes for cases)
-- 2. AIDalgorithm_V1_coding_control.csv (49,960 codes for controls)
-- The placeholder values above should be replaced with actual codes from these files
-- ============================================================================