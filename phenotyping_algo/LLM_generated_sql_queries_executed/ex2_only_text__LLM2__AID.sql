-- Rule 1 (VUMC-specific database name): APPLIED
-- Rule 3 (ICD code search in condition_occurrence.condition_source_value): APPLIED
-- Rule 4 (LOINC/RxNorm/SNOMED code handling): APPLIED
-- Rule 5 (free-text LIKE for local names): NOT APPLICABLE
-- Rule 6 (OR->UNION for multi-table): NOT APPLICABLE
-- Rule 7 (LEFT JOIN->UNION): NOT APPLICABLE
-- Rule 2 (wildcard fix): NOT APPLICABLE
-- Rule 8 (remove NLP): APPLIED
-- Rule 9 (mark missing codes): APPLIED

-- FIX: All OMOP tables now use victr_sd.sd_omop_prod schema
-- FIX: ICD code search is on condition_occurrence.condition_source_value, not concept
-- FIX: LOINC code search is via join on concept, not measurement_source_value
-- FIX: Marked missing code lists inline

CREATE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex2_only_text_LLM2_AID AS 

WITH autoimmune_disease_diagnoses AS (
    SELECT DISTINCT
        co.person_id,
        -- REVISED (was: c.concept_code as diagnosis_code)
        co.condition_source_value as diagnosis_code,
        -- REVISED (was: c.vocabulary_id as code_type)
        CASE 
            WHEN co.condition_source_value LIKE '446.7' THEN 'ICD9CM'
            WHEN co.condition_source_value LIKE 'M31.4' THEN 'ICD10CM'
            WHEN co.condition_source_value LIKE '359789008' THEN 'SNOMED'
            ELSE 'UNKNOWN' 
        END as code_type,
        co.condition_start_date as diagnosis_date,
        -- Map diagnosis codes to disease names
        CASE 
            WHEN co.condition_source_value = '446.7' THEN 'Takayasus_disease'
            WHEN co.condition_source_value = 'M31.4' THEN 'Takayasus_disease'
            WHEN co.condition_source_value = '359789008' THEN 'Takayasus_disease'
            -- MISSING CONCEPT: Additional 1,525 diagnosis codes from AIDalgorithm_V1_coding_cases.csv
            ELSE 'Autoimmune_disease' 
        END as disease_name
    FROM 
        victr_sd.sd_omop_prod.condition_occurrence co
    WHERE 
        (
            co.condition_source_value IN ('446.7', 'M31.4', '359789008')
            -- MISSING CONCEPT: Additional 1,525 diagnosis codes from AIDalgorithm_V1_coding_cases.csv
        )
        AND co.condition_start_date IS NOT NULL
),

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

t1d_patients AS (
    SELECT DISTINCT person_id
    FROM patient_disease_summary
    WHERE disease_name = 'T1D'
),

t2dm_patients AS (
    SELECT DISTINCT co.person_id
    FROM 
        victr_sd.sd_omop_prod.condition_occurrence co
    WHERE 
        co.condition_source_value IN ('250.00', 'E11.9')
        -- MISSING CONCEPT: Additional T2DM codes from AIDalgorithm_V1_coding_cases.csv
),

confirmed_cases AS (
    SELECT DISTINCT
        pds.person_id,
        pds.disease_name
    FROM patient_disease_summary pds
    WHERE 
        pds.distinct_diagnosis_days >= 3
        AND DATEDIFF(pds.last_diagnosis_date, pds.first_diagnosis_date) >= 7
        AND pds.person_id NOT IN (
            SELECT t1d.person_id 
            FROM t1d_patients t1d
            INNER JOIN t2dm_patients t2dm ON t1d.person_id = t2dm.person_id
        )
),

excluded_by_diagnosis AS (
    SELECT DISTINCT co.person_id
    FROM 
        victr_sd.sd_omop_prod.condition_occurrence co
    WHERE 
        co.condition_source_value IN ('PLACEHOLDER_SNOMED_CODE')
        -- MISSING CONCEPT: 49,960 SNOMED codes from AIDalgorithm_V1_coding_control.csv
),

excluded_by_positive_serology AS (
    SELECT DISTINCT m.person_id
    FROM 
        victr_sd.sd_omop_prod.measurement m
        INNER JOIN victr_sd.sd_omop_prod.concept c ON m.measurement_concept_id = c.concept_id
    WHERE 
        c.vocabulary_id = 'LOINC'
        AND (
            (m.value_as_number IS NOT NULL AND m.value_as_number > m.range_high)
            OR (m.value_as_concept_id IN (
                SELECT concept_id 
                FROM victr_sd.sd_omop_prod.concept 
                WHERE concept_name IN ('Positive', 'Detected', 'Reactive', 'Present')
            ))
            OR (UPPER(m.value_source_value) IN ('POSITIVE', 'POS', 'DETECTED', 'REACTIVE', 'PRESENT'))
        )
        AND (
            c.concept_code IN ('PLACEHOLDER_ANA_LOINC')
            OR c.concept_code IN ('PLACEHOLDER_ANCA_LOINC')
            OR c.concept_code IN ('PLACEHOLDER_DSDNA_LOINC')
            OR c.concept_code IN ('PLACEHOLDER_CCP_LOINC')
            OR c.concept_code IN ('PLACEHOLDER_RF_LOINC')
            OR c.concept_code IN ('PLACEHOLDER_B2GLYC_LOINC')
            OR c.concept_code IN ('PLACEHOLDER_RNAPIII_LOINC')
            OR c.concept_code IN ('PLACEHOLDER_CARDIOLIPIN_LOINC')
            OR c.concept_code IN ('PLACEHOLDER_CENTROMERE_LOINC')
            OR c.concept_code IN ('PLACEHOLDER_ENA_LOINC')
            -- MISSING CONCEPT: LOINC codes for all 10 serology categories from AIDalgorithm_V1_coding_control.csv
        )
),

all_persons AS (
    SELECT DISTINCT person_id
    FROM victr_sd.sd_omop_prod.person
    WHERE person_id IS NOT NULL
),

confirmed_controls AS (
    SELECT DISTINCT
        ap.person_id
    FROM all_persons ap
    WHERE 
        ap.person_id NOT IN (
            SELECT person_id FROM excluded_by_diagnosis
        )
        AND ap.person_id NOT IN (
            SELECT person_id FROM excluded_by_positive_serology  
        )
        AND ap.person_id NOT IN (
            SELECT person_id FROM confirmed_cases
        )
)

SELECT 
    person_id,
    phenotype_status,
    disease_name,
    CURRENT_DATE() as classification_date
FROM (
    SELECT 
        person_id,
        'CASE' as phenotype_status,
        disease_name
    FROM confirmed_cases
    UNION ALL
    SELECT 
        person_id,
        'CONTROL' as phenotype_status,
        NULL as disease_name
    FROM confirmed_controls
) final_cohort
ORDER BY 
    phenotype_status DESC,
    person_id
-- END OF AUTOIMMUNE DISEASE PHENOTYPING ALGORITHM
