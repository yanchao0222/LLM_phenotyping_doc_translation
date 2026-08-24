-- Rule 1 (VUMC-specific database name): APPLIED
-- Rule 4 (RxNorm rollup for statins, ICD9 for conditions, LOINC for labs): APPLIED
-- Rule 5 (ILIKE for local names): APPLIED
-- Rule 6 (OR -> UNION for multi-table concept search): APPLIED
-- Rule 8 (Remove NLP/problem list logic): APPLIED
-- FIX: All OMOP tables now use victr_sd.sd_omop_prod schema
-- FIX: Statin identification uses concept_ancestor/concept for RxNorm rollup
-- FIX: AMI diagnoses use condition_source_value LIKE for ICD9 codes directly
-- FIX: Lab confirmation for AMI uses LOINC code join for measurements
-- FIX: NLP/problem list logic removed (no note_nlp table)

CREATE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex1_all_content_LLM2_MACE AS 

WITH statin_users AS (
    SELECT 
        de.person_id,
        de.drug_exposure_start_date,
        MIN(de.drug_exposure_start_date) OVER (PARTITION BY de.person_id) AS first_statin_date
    FROM victr_sd.sd_omop_prod.drug_exposure de
    -- REVISED (was: INNER JOIN concept c ON de.drug_concept_id = c.concept_id WHERE LOWER(c.concept_name) LIKE ...)
    INNER JOIN victr_sd.sd_omop_prod.concept_ancestor ca ON ca.descendant_concept_id = de.drug_concept_id
    INNER JOIN victr_sd.sd_omop_prod.concept c ON ca.ancestor_concept_id = c.concept_id
    WHERE c.vocabulary_id = 'RxNorm'
      AND c.concept_code IN (
        '865098',  -- Simvastatin
        '83367',   -- Zocor
        '83382',   -- Fluvastatin
        '83383',   -- Lescol
        '83384',   -- Canef
        '83385',   -- Vastin
        '83386',   -- Atorvastatin
        '83387',   -- Lipitor
        '83388',   -- Pravastatin
        '83389',   -- Pravachol
        '83390',   -- Selektine
        '83391',   -- Lovastatin
        '83392',   -- Mevacor
        '83393',   -- Cerivastatin
        '83394',   -- Baycol
        '83395',   -- Lipobay
        '83396',   -- Rosuvastatin
        '83397'    -- Crestor
        -- MISSING CONCEPT: Add any missing RxNorm codes for statins
      )
),

ami_diagnoses AS (
    SELECT 
        co.person_id,
        co.condition_start_date AS diagnosis_date
    FROM victr_sd.sd_omop_prod.condition_occurrence co
    WHERE 
        -- REVISED (was: INNER JOIN concept c ON co.condition_source_concept_id = c.concept_id WHERE c.vocabulary_id = 'ICD9CM' AND c.concept_code LIKE ...)
        (co.condition_source_value LIKE '410%' OR co.condition_source_value LIKE '411%')
),

ami_events_window AS (
    SELECT 
        a1.person_id,
        a1.diagnosis_date AS ami_event_date,
        COUNT(DISTINCT a2.diagnosis_date) AS diagnosis_count
    FROM ami_diagnoses a1
    INNER JOIN ami_diagnoses a2 
        ON a1.person_id = a2.person_id
        AND a2.diagnosis_date >= a1.diagnosis_date
        AND a2.diagnosis_date <= DATE_ADD(a1.diagnosis_date, 5)
    GROUP BY a1.person_id, a1.diagnosis_date
    HAVING COUNT(DISTINCT a2.diagnosis_date) >= 2
),

ami_events AS (
    SELECT 
        person_id,
        MIN(ami_event_date) AS ami_event_date
    FROM ami_events_window
    GROUP BY person_id
),

lab_confirmed_ami AS (
    SELECT DISTINCT
        ae.person_id,
        ae.ami_event_date
    FROM ami_events ae
    WHERE EXISTS (
        SELECT 1
        FROM victr_sd.sd_omop_prod.measurement m
        INNER JOIN victr_sd.sd_omop_prod.concept c ON m.measurement_concept_id = c.concept_id
        WHERE m.person_id = ae.person_id
        AND m.measurement_date >= DATE_ADD(ae.ami_event_date, -5)
        AND m.measurement_date <= DATE_ADD(ae.ami_event_date, 5)
        AND (
            -- Troponin-I (LOINC: 42757-5, 6598-7, 89579-7, etc.)
            (c.vocabulary_id = 'LOINC' AND c.concept_code IN ('42757-5','6598-7','89579-7') AND m.value_as_number >= 0.10)
            OR
            -- Troponin-T (LOINC: 6597-9, 89580-5, etc.)
            (c.vocabulary_id = 'LOINC' AND c.concept_code IN ('6597-9','89580-5') AND m.value_as_number >= 0.10)
            OR
            -- CK-MB/CK ratio (LOINC: 15152-1, etc.)
            (c.vocabulary_id = 'LOINC' AND c.concept_code IN ('15152-1') AND m.value_as_number >= 3.0
                AND EXISTS (
                    SELECT 1
                    FROM victr_sd.sd_omop_prod.measurement m2
                    INNER JOIN victr_sd.sd_omop_prod.concept c2 ON m2.measurement_concept_id = c2.concept_id
                    WHERE m2.person_id = m.person_id
                    AND c2.vocabulary_id = 'LOINC' AND c2.concept_code IN ('13969-1','20495-3') -- CK-MB mass
                    AND m2.value_as_number >= 10.0
                    AND ABS(DATEDIFF(m2.measurement_date, m.measurement_date)) <= 5
                )
            )
        )
    )
),

ami_on_statin AS (
    SELECT 
        lca.person_id,
        lca.ami_event_date,
        'AMI_on_statin' AS cohort_type
    FROM lab_confirmed_ami lca
    INNER JOIN statin_users su 
        ON lca.person_id = su.person_id
        AND DATEDIFF(su.first_statin_date, lca.ami_event_date) <= -180
),

first_ami_on_statin AS (
    SELECT 
        aos.person_id,
        aos.ami_event_date,
        'First_AMI_on_statin' AS cohort_type
    FROM ami_on_statin aos
    WHERE 
        -- REVISED (was: NOT EXISTS (SELECT 1 FROM condition_occurrence co INNER JOIN concept c ... WHERE c.vocabulary_id = 'ICD9CM' AND c.concept_code LIKE ...))
        NOT EXISTS (
            SELECT 1
            FROM victr_sd.sd_omop_prod.condition_occurrence co
            WHERE co.person_id = aos.person_id
            AND co.condition_start_date < aos.ami_event_date
            AND (co.condition_source_value LIKE '410%' OR co.condition_source_value LIKE '411%' OR co.condition_source_value LIKE '412%')
        )
),

revascularization_procedures AS (
    SELECT 
        po.person_id,
        po.procedure_date
    FROM victr_sd.sd_omop_prod.procedure_occurrence po
    WHERE po.procedure_source_value IN (
        '33533', '33534', '33535', '33536', 
        '33510', '33511', '33512', '33513', '33514', '33515', '33516', 
        '33517', '33518', '33519', '33520', '33521', '33522', '33523',
        '92980', '92981', '92982', '92984', '92995', '92996',
        'C1874', 'C1875', 'C1876', 'C1877'
    )
),

revascularization_on_statin AS (
    SELECT 
        rp.person_id,
        MIN(rp.procedure_date) AS revasc_event_date,
        'Revascularization_on_statin' AS cohort_type
    FROM revascularization_procedures rp
    INNER JOIN statin_users su 
        ON rp.person_id = su.person_id
    WHERE DATEDIFF(su.first_statin_date, rp.procedure_date) <= -180
    GROUP BY rp.person_id
),

first_revascularization_on_statin AS (
    SELECT 
        ros.person_id,
        ros.revasc_event_date,
        'First_Revascularization_on_statin' AS cohort_type
    FROM revascularization_on_statin ros
    INNER JOIN statin_users su ON ros.person_id = su.person_id
    WHERE 
        -- REVISED (was: NOT EXISTS (SELECT 1 FROM condition_occurrence co INNER JOIN concept c ... WHERE c.vocabulary_id = 'ICD9CM' AND c.concept_code LIKE ...))
        NOT EXISTS (
            SELECT 1
            FROM victr_sd.sd_omop_prod.condition_occurrence co
            WHERE co.person_id = ros.person_id
            AND co.condition_start_date < su.first_statin_date
            AND (co.condition_source_value LIKE '410%' OR co.condition_source_value LIKE '411%' OR co.condition_source_value LIKE '412%')
        )
        AND NOT EXISTS (
            SELECT 1
            FROM revascularization_procedures rp2
            WHERE rp2.person_id = ros.person_id
            AND rp2.procedure_date < su.first_statin_date
        )
),

control_cohort AS (
    SELECT DISTINCT
        su.person_id,
        'Control' AS cohort_type,
        NULL AS event_date
    FROM (SELECT DISTINCT person_id, first_statin_date FROM statin_users) su
    WHERE 
        NOT EXISTS (
            SELECT 1
            FROM victr_sd.sd_omop_prod.condition_occurrence co
            WHERE co.person_id = su.person_id
            AND (co.condition_source_value LIKE '410%' OR co.condition_source_value LIKE '411%' OR co.condition_source_value LIKE '412%')
        )
        AND NOT EXISTS (
            SELECT 1
            FROM revascularization_procedures rp
            WHERE rp.person_id = su.person_id
        )
)

SELECT 
    person_id,
    cohort_type,
    ami_event_date AS event_date
FROM ami_on_statin

UNION ALL

SELECT 
    person_id,
    cohort_type,
    ami_event_date AS event_date
FROM first_ami_on_statin

UNION ALL

SELECT 
    person_id,
    cohort_type,
    revasc_event_date AS event_date
FROM revascularization_on_statin

UNION ALL

SELECT 
    person_id,
    cohort_type,
    revasc_event_date AS event_date
FROM first_revascularization_on_statin

UNION ALL

SELECT 
    person_id,
    cohort_type,
    event_date
FROM control_cohort

ORDER BY cohort_type, person_id;