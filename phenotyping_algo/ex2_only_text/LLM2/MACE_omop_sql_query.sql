-- ============================================================================
-- PHENOTYPE: Major Adverse Cardiac Events (MACE) While on Statins
-- Description: Identifies patients with MACE events (AMI or Revascularization) 
--              while on statin therapy, including first events and controls
-- Database: OMOP Common Data Model
-- ============================================================================

-- ----------------------------------------------------------------------------
-- COHORT 1: AMI ON STATINS
-- Patients with acute myocardial infarction while on statin therapy
-- Requires: 1) At least 2 ICD9 codes for AMI within 5-day window
--          2) Confirmed lab values within same window  
--          3) Statin prescribed at least 180 days prior
-- ----------------------------------------------------------------------------
WITH ami_diagnosis_counts AS (
    -- Find patients with at least 2 AMI diagnoses within 5-day window
    SELECT 
        co1.person_id,
        co1.condition_start_date as event_date
    FROM condition_occurrence co1
    INNER JOIN concept c1 ON co1.condition_concept_id = c1.concept_id
    WHERE 
        -- ICD9 410.* (AMI) or 411.* (Other acute and subacute forms of ischemic heart disease)
        c1.vocabulary_id = 'ICD9CM'
        AND (c1.concept_code LIKE '410.%' OR c1.concept_code LIKE '411.%')
        AND EXISTS (
            -- Second diagnosis within 5 days
            SELECT 1
            FROM condition_occurrence co2
            INNER JOIN concept c2 ON co2.condition_concept_id = c2.concept_id
            WHERE co2.person_id = co1.person_id
                AND c2.vocabulary_id = 'ICD9CM'
                AND (c2.concept_code LIKE '410.%' OR c2.concept_code LIKE '411.%')
                AND co2.condition_start_date BETWEEN co1.condition_start_date 
                    AND DATEADD(day, 5, co1.condition_start_date)
                AND co2.condition_occurrence_id != co1.condition_occurrence_id
        )
),

ami_with_labs AS (
    -- Add lab confirmation requirement
    SELECT DISTINCT 
        adc.person_id,
        adc.event_date
    FROM ami_diagnosis_counts adc
    WHERE EXISTS (
        -- Lab confirmation within 5-day window
        SELECT 1 
        FROM measurement m
        INNER JOIN concept c ON m.measurement_concept_id = c.concept_id
        WHERE m.person_id = adc.person_id
            AND m.measurement_date BETWEEN adc.event_date 
                AND DATEADD(day, 5, adc.event_date)
            AND (
                -- Troponin I >= 0.10 ng/ml
                (UPPER(c.concept_name) LIKE '%TROPONIN I%' 
                 AND m.value_as_number >= 0.10)
                -- Troponin T >= 0.10 ng/ml  
                OR (UPPER(c.concept_name) LIKE '%TROPONIN T%' 
                    AND m.value_as_number >= 0.10)
                -- CK-MB ratio >= 3.0 AND CK-MB >= 10.0 ng/mL
                OR EXISTS (
                    SELECT 1
                    FROM measurement m1
                    INNER JOIN concept c1 ON m1.measurement_concept_id = c1.concept_id
                    WHERE m1.person_id = adc.person_id
                        AND m1.measurement_date BETWEEN adc.event_date 
                            AND DATEADD(day, 5, adc.event_date)
                        AND UPPER(c1.concept_name) LIKE '%CK%MB%RATIO%'
                        AND m1.value_as_number >= 3.0
                        AND EXISTS (
                            SELECT 1 
                            FROM measurement m2
                            INNER JOIN concept c2 ON m2.measurement_concept_id = c2.concept_id
                            WHERE m2.person_id = m1.person_id
                                AND m2.measurement_date = m1.measurement_date
                                AND UPPER(c2.concept_name) LIKE '%CK%MB%'
                                AND UPPER(c2.concept_name) NOT LIKE '%RATIO%'
                                AND m2.value_as_number >= 10.0
                        )
                )
            )
    )
),

ami_on_statins_final AS (
    -- Add statin requirement
    SELECT 
        awl.person_id,
        awl.event_date
    FROM ami_with_labs awl
    WHERE EXISTS (
        -- Statin prescribed at least 180 days prior to AMI
        SELECT 1
        FROM drug_exposure de
        INNER JOIN concept_ancestor ca ON de.drug_concept_id = ca.descendant_concept_id
        INNER JOIN concept c ON ca.ancestor_concept_id = c.concept_id
        WHERE de.person_id = awl.person_id
            AND DATEADD(day, 180, de.drug_exposure_start_date) <= awl.event_date
            -- OMOP concept for HMG CoA reductase inhibitors (statins) class
            AND c.concept_id = 1539403
            AND c.concept_class_id = 'Ingredient'
    )
),

-- ----------------------------------------------------------------------------
-- COHORT 2: FIRST AMI ON STATINS
-- Patients with their first AMI event while on statin therapy
-- ----------------------------------------------------------------------------
first_ami_on_statins AS (
    SELECT 
        aos.person_id,
        aos.event_date
    FROM ami_on_statins_final aos
    WHERE 
        -- No prior AMI (410.*), other acute/subacute ischemic (411.*), or old MI (412)
        NOT EXISTS (
            SELECT 1 
            FROM condition_occurrence co
            INNER JOIN concept c ON co.condition_concept_id = c.concept_id
            WHERE co.person_id = aos.person_id
                AND co.condition_start_date < aos.event_date
                AND c.vocabulary_id = 'ICD9CM'
                AND (c.concept_code LIKE '410.%'  
                    OR c.concept_code LIKE '411.%'  
                    OR c.concept_code = '412')
        )
        
        -- No prior revascularization CPT codes
        AND NOT EXISTS (
            SELECT 1 
            FROM procedure_occurrence po
            INNER JOIN concept c ON po.procedure_concept_id = c.concept_id
            WHERE po.person_id = aos.person_id
                AND po.procedure_date < aos.event_date
                AND c.vocabulary_id IN ('CPT4', 'HCPCS')
                AND c.concept_code IN (
                    -- CABG CPT codes
                    '33533', '33534', '33535', '33536', '33510', '33511', '33512', '33513',
                    '33514', '33515', '33516', '33517', '33518', '33519', '33520', '33521',
                    '33522', '33523',
                    -- PTCA CPT codes
                    '92980', '92981', '92982', '92984', '92995', '92996',
                    'C1874', 'C1875', 'C1876', 'C1877'
                )
        )
        
        -- No MACE keywords in prior notes (NLP check)
        AND NOT EXISTS (
            SELECT 1 
            FROM note n
            WHERE n.person_id = aos.person_id
                AND n.note_date < aos.event_date
                AND (
                    REGEXP_LIKE(LOWER(n.note_text), '(\s|^)ami(\s|$)')
                    OR REGEXP_LIKE(LOWER(n.note_text), '(\s|^)mi(\s|$)')
                    OR LOWER(n.note_text) LIKE '%acute myocardial infarction%'
                    OR LOWER(n.note_text) LIKE '%myocardial infarction%'
                    OR LOWER(n.note_text) LIKE '%cabg%'
                    OR LOWER(n.note_text) LIKE '%coronary artery bypass%'
                    OR LOWER(n.note_text) LIKE '%cypher%'
                    OR LOWER(n.note_text) LIKE '%taxus%'
                    OR LOWER(n.note_text) LIKE '%bms%'
                    OR LOWER(n.note_text) LIKE '%des%'
                    OR LOWER(n.note_text) LIKE '%stent%'
                )
        )
),

-- ----------------------------------------------------------------------------
-- COHORT 3: REVASCULARIZATION ON STATINS
-- Patients with revascularization procedures while on statin therapy
-- ----------------------------------------------------------------------------
revasc_on_statins AS (
    SELECT DISTINCT 
        po.person_id,
        po.procedure_date as event_date
    FROM procedure_occurrence po
    INNER JOIN concept c ON po.procedure_concept_id = c.concept_id
    WHERE 
        -- Revascularization CPT codes
        c.vocabulary_id IN ('CPT4', 'HCPCS')
        AND c.concept_code IN (
            -- CABG CPT codes
            '33533', '33534', '33535', '33536', '33510', '33511', '33512', '33513',
            '33514', '33515', '33516', '33517', '33518', '33519', '33520', '33521',
            '33522', '33523',
            -- PTCA CPT codes  
            '92980', '92981', '92982', '92984', '92995', '92996',
            'C1874', 'C1875', 'C1876', 'C1877'
        )
        
        -- Statin prescribed at least 180 days prior
        AND EXISTS (
            SELECT 1
            FROM drug_exposure de
            INNER JOIN concept_ancestor ca ON de.drug_concept_id = ca.descendant_concept_id
            INNER JOIN concept c2 ON ca.ancestor_concept_id = c2.concept_id
            WHERE de.person_id = po.person_id
                AND DATEADD(day, 180, de.drug_exposure_start_date) <= po.procedure_date
                -- OMOP concept for HMG CoA reductase inhibitors (statins) class
                AND c2.concept_id = 1539403
                AND c2.concept_class_id = 'Ingredient'
        )
),

-- ----------------------------------------------------------------------------
-- COHORT 4: FIRST REVASCULARIZATION ON STATINS
-- Patients with their first revascularization while on statin therapy
-- ----------------------------------------------------------------------------
first_revasc_on_statins AS (
    SELECT 
        ros.person_id,
        ros.event_date
    FROM revasc_on_statins ros
    WHERE 
        -- No prior AMI (410.*), other acute/subacute ischemic (411.*), or old MI (412)
        NOT EXISTS (
            SELECT 1 
            FROM condition_occurrence co
            INNER JOIN concept c ON co.condition_concept_id = c.concept_id
            WHERE co.person_id = ros.person_id
                AND co.condition_start_date < ros.event_date
                AND c.vocabulary_id = 'ICD9CM'
                AND (c.concept_code LIKE '410.%'  
                    OR c.concept_code LIKE '411.%'  
                    OR c.concept_code = '412')
        )
        
        -- No prior revascularization CPT codes
        AND NOT EXISTS (
            SELECT 1 
            FROM procedure_occurrence po
            INNER JOIN concept c ON po.procedure_concept_id = c.concept_id
            WHERE po.person_id = ros.person_id
                AND po.procedure_date < ros.event_date
                AND c.vocabulary_id IN ('CPT4', 'HCPCS')
                AND c.concept_code IN (
                    -- CABG CPT codes
                    '33533', '33534', '33535', '33536', '33510', '33511', '33512', '33513',
                    '33514', '33515', '33516', '33517', '33518', '33519', '33520', '33521',
                    '33522', '33523',
                    -- PTCA CPT codes
                    '92980', '92981', '92982', '92984', '92995', '92996',
                    'C1874', 'C1875', 'C1876', 'C1877'
                )
        )
        
        -- No MACE keywords in prior notes (NLP check)
        AND NOT EXISTS (
            SELECT 1 
            FROM note n
            WHERE n.person_id = ros.person_id
                AND n.note_date < ros.event_date
                AND (
                    REGEXP_LIKE(LOWER(n.note_text), '(\s|^)ami(\s|$)')
                    OR REGEXP_LIKE(LOWER(n.note_text), '(\s|^)mi(\s|$)')
                    OR LOWER(n.note_text) LIKE '%acute myocardial infarction%'
                    OR LOWER(n.note_text) LIKE '%myocardial infarction%'
                    OR LOWER(n.note_text) LIKE '%cabg%'
                    OR LOWER(n.note_text) LIKE '%coronary artery bypass%'
                    OR LOWER(n.note_text) LIKE '%cypher%'
                    OR LOWER(n.note_text) LIKE '%taxus%'
                    OR LOWER(n.note_text) LIKE '%bms%'
                    OR LOWER(n.note_text) LIKE '%des%'
                    OR LOWER(n.note_text) LIKE '%stent%'
                )
        )
),

-- ----------------------------------------------------------------------------
-- CONTROL COHORT: PATIENTS ON STATINS WITHOUT MACE
-- Patients prescribed statins with no MACE events ever
-- ----------------------------------------------------------------------------
controls AS (
    SELECT DISTINCT de.person_id
    FROM drug_exposure de
    INNER JOIN concept_ancestor ca ON de.drug_concept_id = ca.descendant_concept_id
    INNER JOIN concept c ON ca.ancestor_concept_id = c.concept_id
    WHERE 
        -- Has statin prescription
        c.concept_id = 1539403
        AND c.concept_class_id = 'Ingredient'
        
        -- No AMI (410.*), other acute/subacute ischemic (411.*), or old MI (412) ever
        AND NOT EXISTS (
            SELECT 1 
            FROM condition_occurrence co
            INNER JOIN concept c2 ON co.condition_concept_id = c2.concept_id
            WHERE co.person_id = de.person_id
                AND c2.vocabulary_id = 'ICD9CM'
                AND (c2.concept_code LIKE '410.%'  
                    OR c2.concept_code LIKE '411.%'  
                    OR c2.concept_code = '412')
        )
        
        -- No revascularization CPT codes ever
        AND NOT EXISTS (
            SELECT 1 
            FROM procedure_occurrence po
            INNER JOIN concept c3 ON po.procedure_concept_id = c3.concept_id
            WHERE po.person_id = de.person_id
                AND c3.vocabulary_id IN ('CPT4', 'HCPCS')
                AND c3.concept_code IN (
                    -- CABG CPT codes
                    '33533', '33534', '33535', '33536', '33510', '33511', '33512', '33513',
                    '33514', '33515', '33516', '33517', '33518', '33519', '33520', '33521',
                    '33522', '33523',
                    -- PTCA CPT codes
                    '92980', '92981', '92982', '92984', '92995', '92996',
                    'C1874', 'C1875', 'C1876', 'C1877'
                )
        )
        
        -- No MACE keywords in notes ever (NLP check)
        AND NOT EXISTS (
            SELECT 1 
            FROM note n
            WHERE n.person_id = de.person_id
                AND (
                    REGEXP_LIKE(LOWER(n.note_text), '(\s|^)ami(\s|$)')
                    OR REGEXP_LIKE(LOWER(n.note_text), '(\s|^)mi(\s|$)')
                    OR LOWER(n.note_text) LIKE '%acute myocardial infarction%'
                    OR LOWER(n.note_text) LIKE '%myocardial infarction%'
                    OR LOWER(n.note_text) LIKE '%cabg%'
                    OR LOWER(n.note_text) LIKE '%coronary artery bypass%'
                    OR LOWER(n.note_text) LIKE '%cypher%'
                    OR LOWER(n.note_text) LIKE '%taxus%'
                    OR LOWER(n.note_text) LIKE '%bms%'
                    OR LOWER(n.note_text) LIKE '%des%'
                    OR LOWER(n.note_text) LIKE '%stent%'
                )
        )
)

-- ============================================================================
-- FINAL OUTPUT: Combine all cohorts for MACE while on statins phenotype
-- Returns all cases and controls with appropriate labels
-- ============================================================================
SELECT 
    person_id,
    'AMI_on_statins' as cohort_type,
    event_date,
    1 as is_case,
    0 as is_first_event
FROM ami_on_statins_final

UNION ALL

SELECT 
    person_id,
    '1st_AMI_on_statins' as cohort_type,
    event_date,
    1 as is_case,
    1 as is_first_event
FROM first_ami_on_statins

UNION ALL

SELECT 
    person_id,
    'Revascularization_on_statins' as cohort_type,
    event_date,
    1 as is_case,
    0 as is_first_event
FROM revasc_on_statins

UNION ALL

SELECT 
    person_id,
    '1st_Revascularization_on_statins' as cohort_type,
    event_date,
    1 as is_case,
    1 as is_first_event
FROM first_revasc_on_statins

UNION ALL

SELECT 
    person_id,
    'Control' as cohort_type,
    NULL as event_date,
    0 as is_case,
    NULL as is_first_event
FROM controls

ORDER BY cohort_type, person_id, event_date;