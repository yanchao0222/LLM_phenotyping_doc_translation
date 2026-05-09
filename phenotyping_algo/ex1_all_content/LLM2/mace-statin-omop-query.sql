-- ============================================================================
-- EXECUTABLE OMOP CDM QUERY: Major Adverse Cardiac Events (MACE) While on Statins
-- ============================================================================
-- Purpose: Identify patients with MACE events while on statin therapy from OMOP CDM
-- Output: Four case cohorts and one control cohort with patient identifiers and event dates
-- Database: OMOP Common Data Model v5.x
-- Compatibility: SQL Server, PostgreSQL, Oracle, Redshift
-- ============================================================================

-- ============================================================================
-- STEP 1: IDENTIFY STATIN USERS
-- ============================================================================
-- Extract all patients with statin prescriptions and their earliest prescription dates
-- Medications: Simvastatin, Zocor, Fluvastatin, Lescol, Canef, Vastin,
--              Atorvastatin, Lipitor, Pravastatin, Pravachol, Selektine,
--              Lovastatin, Mevacor, Cerivastatin, Baycol, Lipobay,
--              Rosuvastatin, Crestor

WITH statin_users AS (
    SELECT 
        de.person_id,
        de.drug_exposure_start_date,
        MIN(de.drug_exposure_start_date) OVER (PARTITION BY de.person_id) AS first_statin_date
    FROM drug_exposure de
    INNER JOIN concept c ON de.drug_concept_id = c.concept_id
    WHERE 
        -- Statin medications by concept name (as no codes provided in source)
        LOWER(c.concept_name) LIKE '%simvastatin%'
        OR LOWER(c.concept_name) LIKE '%zocor%'
        OR LOWER(c.concept_name) LIKE '%fluvastatin%'
        OR LOWER(c.concept_name) LIKE '%lescol%'
        OR LOWER(c.concept_name) LIKE '%canef%'
        OR LOWER(c.concept_name) LIKE '%vastin%'
        OR LOWER(c.concept_name) LIKE '%atorvastatin%'
        OR LOWER(c.concept_name) LIKE '%lipitor%'
        OR LOWER(c.concept_name) LIKE '%pravastatin%'
        OR LOWER(c.concept_name) LIKE '%pravachol%'
        OR LOWER(c.concept_name) LIKE '%selektine%'
        OR LOWER(c.concept_name) LIKE '%lovastatin%'
        OR LOWER(c.concept_name) LIKE '%mevacor%'
        OR LOWER(c.concept_name) LIKE '%cerivastatin%'
        OR LOWER(c.concept_name) LIKE '%baycol%'
        OR LOWER(c.concept_name) LIKE '%lipobay%'
        OR LOWER(c.concept_name) LIKE '%rosuvastatin%'
        OR LOWER(c.concept_name) LIKE '%crestor%'
),

-- ============================================================================
-- STEP 2: IDENTIFY AMI DIAGNOSES
-- ============================================================================
-- Find all AMI diagnoses using ICD9 codes
-- 410.*: Acute myocardial infarction
-- 411.*: Other acute and subacute forms of ischemic heart disease

ami_diagnoses AS (
    SELECT 
        co.person_id,
        co.condition_start_date AS diagnosis_date
    FROM condition_occurrence co
    INNER JOIN concept c ON co.condition_source_concept_id = c.concept_id
    WHERE 
        -- ICD9 codes from source document
        (c.vocabulary_id = 'ICD9CM' AND (
            c.concept_code LIKE '410%'  -- AMI
            OR c.concept_code LIKE '411%'  -- Other acute/subacute ischemic heart disease
        ))
),

-- Identify patients with at least 2 AMI codes within 5-day window
ami_events_window AS (
    SELECT 
        a1.person_id,
        a1.diagnosis_date AS ami_event_date,
        COUNT(DISTINCT a2.diagnosis_date) AS diagnosis_count
    FROM ami_diagnoses a1
    INNER JOIN ami_diagnoses a2 
        ON a1.person_id = a2.person_id
        AND a2.diagnosis_date >= a1.diagnosis_date
        AND a2.diagnosis_date <= DATEADD(day, 5, a1.diagnosis_date)
    GROUP BY a1.person_id, a1.diagnosis_date
    HAVING COUNT(DISTINCT a2.diagnosis_date) >= 2
),

-- Get earliest AMI event for each patient
ami_events AS (
    SELECT 
        person_id,
        MIN(ami_event_date) AS ami_event_date
    FROM ami_events_window
    GROUP BY person_id
),

-- ============================================================================
-- STEP 3: LABORATORY CONFIRMATION FOR AMI
-- ============================================================================
-- Lab criteria (within 5-day window of AMI):
-- Troponin-I (TnI) >= 0.10 ng/ml OR
-- Troponin-T (TnT) >= 0.10 ng/ml OR
-- (CK-MB/CK ratio >= 3.0 AND CK-MB >= 10.0 ng/mL)

lab_confirmed_ami AS (
    SELECT DISTINCT
        ae.person_id,
        ae.ami_event_date
    FROM ami_events ae
    WHERE EXISTS (
        SELECT 1
        FROM measurement m
        INNER JOIN concept c ON m.measurement_concept_id = c.concept_id
        WHERE m.person_id = ae.person_id
        -- Within 5-day window of AMI event
        AND m.measurement_date >= DATEADD(day, -5, ae.ami_event_date)
        AND m.measurement_date <= DATEADD(day, 5, ae.ami_event_date)
        AND (
            -- Troponin-I >= 0.10 ng/ml
            (UPPER(c.concept_name) LIKE '%TROPONIN%I%' AND m.value_as_number >= 0.10)
            -- Troponin-T >= 0.10 ng/ml
            OR (UPPER(c.concept_name) LIKE '%TROPONIN%T%' AND m.value_as_number >= 0.10)
            -- CK-MB/CK ratio >= 3.0
            OR (
                (UPPER(c.concept_name) LIKE '%CK%MB%RATIO%' 
                 OR UPPER(c.concept_name) LIKE '%CKMB%RATIO%')
                AND m.value_as_number >= 3.0
                -- AND CK-MB >= 10.0 ng/mL
                AND EXISTS (
                    SELECT 1 
                    FROM measurement m2
                    INNER JOIN concept c2 ON m2.measurement_concept_id = c2.concept_id
                    WHERE m2.person_id = m.person_id
                    AND (UPPER(c2.concept_name) LIKE '%CK%MB%' 
                         OR UPPER(c2.concept_name) LIKE '%CKMB%')
                    AND UPPER(c2.concept_name) NOT LIKE '%RATIO%'
                    AND m2.value_as_number >= 10.0
                    AND ABS(DATEDIFF(day, m2.measurement_date, m.measurement_date)) <= 5
                )
            )
        )
    )
),

-- ============================================================================
-- COHORT 1: AMI ON STATIN
-- ============================================================================
-- Requirements:
-- 1. At least 2 current AMI codes within 5-day window (from ami_events)
-- 2. Confirmed lab within same time window (from lab_confirmed_ami)
-- 3. Statin prescribed prior to AMI event >= 180 days

ami_on_statin AS (
    SELECT 
        lca.person_id,
        lca.ami_event_date,
        'AMI_on_statin' AS cohort_type
    FROM lab_confirmed_ami lca
    INNER JOIN statin_users su 
        ON lca.person_id = su.person_id
        AND DATEDIFF(day, su.first_statin_date, lca.ami_event_date) >= 180
),

-- ============================================================================
-- COHORT 2: FIRST AMI ON STATIN
-- ============================================================================
-- Additional requirements:
-- 4. No AMI codes (410.*, 411.*, 412.*) assigned before the AMI event
-- 5. No AMI mentioned in previous problem list by NLP

first_ami_on_statin AS (
    SELECT 
        aos.person_id,
        aos.ami_event_date,
        'First_AMI_on_statin' AS cohort_type
    FROM ami_on_statin aos
    WHERE 
        -- No prior AMI diagnoses (ICD9: 410.*, 411.*, 412.*)
        NOT EXISTS (
            SELECT 1
            FROM condition_occurrence co
            INNER JOIN concept c ON co.condition_source_concept_id = c.concept_id
            WHERE co.person_id = aos.person_id
            AND co.condition_start_date < aos.ami_event_date
            AND c.vocabulary_id = 'ICD9CM'
            AND (c.concept_code LIKE '410%'  -- AMI
                 OR c.concept_code LIKE '411%'  -- Other acute/subacute ischemic
                 OR c.concept_code LIKE '412%')  -- Old myocardial infarction
        )
        -- No AMI mentioned in previous problem list (NLP check)
        AND NOT EXISTS (
            SELECT 1
            FROM note_nlp nn
            WHERE nn.person_id = aos.person_id
            AND nn.note_date < aos.ami_event_date
            AND (LOWER(nn.lexical_variant) = 'ami'
                 OR LOWER(nn.lexical_variant) = 'mi'
                 OR LOWER(nn.lexical_variant) = 'acute myocardial infarction'
                 OR LOWER(nn.lexical_variant) = 'myocardial infarction')
        )
),

-- ============================================================================
-- STEP 4: IDENTIFY REVASCULARIZATION PROCEDURES
-- ============================================================================
-- CABG CPT codes: 33533-33536, 33510-33523
-- PTCA CPT codes: 92980, 92981, 92982, 92984, 92995, 92996
-- Stent codes: C1874, C1875, C1876, C1877

revascularization_procedures AS (
    SELECT 
        po.person_id,
        po.procedure_date
    FROM procedure_occurrence po
    WHERE 
        -- Using procedure_source_value for CPT codes from source document
        po.procedure_source_value IN (
            -- CABG CPT codes
            '33533', '33534', '33535', '33536', 
            '33510', '33511', '33512', '33513', '33514', '33515', '33516', 
            '33517', '33518', '33519', '33520', '33521', '33522', '33523',
            -- PTCA CPT codes
            '92980', '92981', '92982', '92984', '92995', '92996',
            -- Stent codes
            'C1874', 'C1875', 'C1876', 'C1877'
        )
),

-- ============================================================================
-- COHORT 3: REVASCULARIZATION WHILE ON STATIN
-- ============================================================================
-- Requirements:
-- 1. Any CPT code for angioplasty or stent
-- 2. Statin prescribed prior to procedure >= 180 days

revascularization_on_statin AS (
    SELECT 
        rp.person_id,
        MIN(rp.procedure_date) AS revasc_event_date,
        'Revascularization_on_statin' AS cohort_type
    FROM revascularization_procedures rp
    INNER JOIN statin_users su 
        ON rp.person_id = su.person_id
    WHERE DATEDIFF(day, su.first_statin_date, rp.procedure_date) >= 180
    GROUP BY rp.person_id
),

-- ============================================================================
-- COHORT 4: FIRST REVASCULARIZATION WHILE ON STATIN
-- ============================================================================
-- Additional requirements:
-- 3. No exclusion codes before starting statin
-- 4. No revascularization mentioned in previous problem list by NLP

first_revascularization_on_statin AS (
    SELECT 
        ros.person_id,
        ros.revasc_event_date,
        'First_Revascularization_on_statin' AS cohort_type
    FROM revascularization_on_statin ros
    INNER JOIN statin_users su ON ros.person_id = su.person_id
    WHERE 
        -- No AMI diagnoses before starting statin (ICD9: 410.*, 411.*, 412.*)
        NOT EXISTS (
            SELECT 1
            FROM condition_occurrence co
            INNER JOIN concept c ON co.condition_source_concept_id = c.concept_id
            WHERE co.person_id = ros.person_id
            AND co.condition_start_date < su.first_statin_date
            AND c.vocabulary_id = 'ICD9CM'
            AND (c.concept_code LIKE '410%'  -- AMI
                 OR c.concept_code LIKE '411%'  -- Other acute/subacute ischemic
                 OR c.concept_code LIKE '412%')  -- Old MI
        )
        -- No prior revascularization procedures before starting statin
        AND NOT EXISTS (
            SELECT 1
            FROM revascularization_procedures rp2
            WHERE rp2.person_id = ros.person_id
            AND rp2.procedure_date < su.first_statin_date
        )
        -- No revascularization mentioned in previous problem list (NLP check)
        AND NOT EXISTS (
            SELECT 1
            FROM note_nlp nn
            WHERE nn.person_id = ros.person_id
            AND nn.note_date < ros.revasc_event_date
            AND (LOWER(nn.lexical_variant) = 'cabg'
                 OR LOWER(nn.lexical_variant) = 'coronary artery bypass'
                 OR LOWER(nn.lexical_variant) = 'cypher'
                 OR LOWER(nn.lexical_variant) = 'taxus'
                 OR LOWER(nn.lexical_variant) = 'bms'
                 OR LOWER(nn.lexical_variant) = 'des'
                 OR LOWER(nn.lexical_variant) = 'stent')
        )
),

-- ============================================================================
-- CONTROL COHORT: PATIENTS ON STATINS WITHOUT MACE
-- ============================================================================
-- Requirements:
-- 1. Statin prescribed
-- 2. No diagnosis code for AMI/ischemic heart disease (410.*, 411.*, 412.*)
-- 3. No revascularization CPT codes
-- 4. No MACE found in problem list by NLP

control_cohort AS (
    SELECT DISTINCT
        su.person_id,
        'Control' AS cohort_type,
        NULL AS event_date
    FROM (SELECT DISTINCT person_id, first_statin_date FROM statin_users) su
    WHERE 
        -- No AMI/ischemic heart disease diagnoses (ICD9: 410.*, 411.*, 412.*)
        NOT EXISTS (
            SELECT 1
            FROM condition_occurrence co
            INNER JOIN concept c ON co.condition_source_concept_id = c.concept_id
            WHERE co.person_id = su.person_id
            AND c.vocabulary_id = 'ICD9CM'
            AND (c.concept_code LIKE '410%'  -- AMI
                 OR c.concept_code LIKE '411%'  -- Other acute/subacute ischemic
                 OR c.concept_code LIKE '412%')  -- Old MI
        )
        -- No revascularization procedures
        AND NOT EXISTS (
            SELECT 1
            FROM revascularization_procedures rp
            WHERE rp.person_id = su.person_id
        )
        -- No MACE keywords in problem list (NLP check)
        AND NOT EXISTS (
            SELECT 1
            FROM note_nlp nn
            WHERE nn.person_id = su.person_id
            AND (LOWER(nn.lexical_variant) = 'ami'
                 OR LOWER(nn.lexical_variant) = 'mi'
                 OR LOWER(nn.lexical_variant) = 'acute myocardial infarction'
                 OR LOWER(nn.lexical_variant) = 'myocardial infarction'
                 OR LOWER(nn.lexical_variant) = 'cabg'
                 OR LOWER(nn.lexical_variant) = 'coronary artery bypass'
                 OR LOWER(nn.lexical_variant) = 'cypher'
                 OR LOWER(nn.lexical_variant) = 'taxus'
                 OR LOWER(nn.lexical_variant) = 'bms'
                 OR LOWER(nn.lexical_variant) = 'des'
                 OR LOWER(nn.lexical_variant) = 'stent')
        )
)

-- ============================================================================
-- FINAL OUTPUT: COMBINE ALL COHORTS
-- ============================================================================
-- Union all cohorts to create final phenotype dataset
-- Output columns: person_id, cohort_type, event_date

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