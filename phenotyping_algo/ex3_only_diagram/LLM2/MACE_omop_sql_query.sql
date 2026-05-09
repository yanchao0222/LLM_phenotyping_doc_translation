-- ============================================================================
-- EXECUTABLE SQL QUERY FOR PHENOTYPING MACE WHILE ON STATINS
-- OMOP CDM Database Query - Final Version
-- ============================================================================
-- This query identifies cases and controls for Major Adverse Cardiac Events (MACE) 
-- in patients on chronic statin therapy using OMOP CDM tables
-- ============================================================================

WITH 
-- ----------------------------------------------------------------------------
-- STEP 1: IDENTIFY STATIN EXPOSURES
-- Extract all statin prescriptions from drug_exposure table
-- ----------------------------------------------------------------------------
statin_exposures AS (
    SELECT DISTINCT
        de.person_id,
        de.drug_exposure_start_date as prescription_date,
        de.drug_concept_id
    FROM drug_exposure de
    INNER JOIN concept_ancestor ca ON de.drug_concept_id = ca.descendant_concept_id
    INNER JOIN concept c ON ca.ancestor_concept_id = c.concept_id
    WHERE LOWER(c.concept_name) LIKE '%statin%'
      AND c.domain_id = 'Drug'
),

-- ----------------------------------------------------------------------------
-- STEP 2: IDENTIFY AMI DIAGNOSES
-- Extract all AMI-related diagnosis codes
-- ----------------------------------------------------------------------------
ami_diagnoses AS (
    SELECT 
        co.person_id,
        co.condition_start_date as diagnosis_date,
        c.concept_code,
        -- Count AMI codes within 5-day window for each diagnosis
        COUNT(*) OVER (
            PARTITION BY co.person_id 
            ORDER BY co.condition_start_date 
            RANGE BETWEEN CURRENT ROW 
            AND INTERVAL '5 DAY' FOLLOWING
        ) as ami_count_in_window
    FROM condition_occurrence co
    INNER JOIN concept c ON co.condition_source_concept_id = c.concept_id
    WHERE c.vocabulary_id = 'ICD9CM'
      AND (c.concept_code LIKE '410%'  -- AMI codes
           OR c.concept_code LIKE '411%')  -- Other acute and subacute forms of ischemic heart disease
),

-- ----------------------------------------------------------------------------
-- STEP 3: IDENTIFY CARDIAC BIOMARKER LAB RESULTS
-- Extract Troponin-I, Troponin-T, CK-MB, and CK measurements
-- ----------------------------------------------------------------------------
cardiac_labs AS (
    SELECT 
        m.person_id,
        m.measurement_date as result_date,
        c.concept_name as test_name,
        m.value_as_number as value,
        uc.concept_name as unit
    FROM measurement m
    INNER JOIN concept c ON m.measurement_concept_id = c.concept_id
    LEFT JOIN concept uc ON m.unit_concept_id = uc.concept_id
    WHERE m.value_as_number IS NOT NULL
      AND (
        -- Troponin I concepts
        LOWER(c.concept_name) LIKE '%troponin i%'
        -- Troponin T concepts
        OR LOWER(c.concept_name) LIKE '%troponin t%'
        -- CK-MB concepts
        OR LOWER(c.concept_name) LIKE '%ck-mb%'
        OR LOWER(c.concept_name) LIKE '%creatine kinase mb%'
        OR LOWER(c.concept_name) LIKE '%ck mb%'
        -- CK total concepts (for ratio calculation)
        OR (LOWER(c.concept_name) LIKE '%creatine kinase%' 
            AND LOWER(c.concept_name) NOT LIKE '%mb%')
      )
),

-- ----------------------------------------------------------------------------
-- STEP 4: IDENTIFY AMI ON STATIN CASES
-- Requires: >= 2 AMI codes within 5 days + confirmed labs + statin >= 180 days
-- ----------------------------------------------------------------------------
ami_on_statin AS (
    SELECT DISTINCT 
        ami.person_id, 
        ami.diagnosis_date as event_date
    FROM ami_diagnoses ami
    WHERE ami.ami_count_in_window >= 2  -- At least 2 current AMI codes within 5-day window
    
    -- Criterion 2: Confirmed lab within the same 5-day time window
    AND EXISTS (
        SELECT 1
        FROM cardiac_labs lab
        WHERE lab.person_id = ami.person_id
          AND lab.result_date >= ami.diagnosis_date
          AND lab.result_date <= ami.diagnosis_date + INTERVAL '5 DAY'
          AND (
              -- Troponin-I >= 0.10 ng/ml
              (LOWER(lab.test_name) LIKE '%troponin i%' 
               AND lab.value >= 0.10)
              
              -- OR Troponin-T >= 0.10 ng/ml
              OR (LOWER(lab.test_name) LIKE '%troponin t%' 
                  AND lab.value >= 0.10)
              
              -- OR (CK-MB/CK ratio >= 3.0 AND CK-MB >= 10.0 ng/mL)
              OR EXISTS (
                  SELECT 1
                  FROM cardiac_labs ckmb
                  JOIN cardiac_labs ck_total 
                    ON ckmb.person_id = ck_total.person_id
                    AND ckmb.result_date = ck_total.result_date
                  WHERE ckmb.person_id = ami.person_id
                    AND ckmb.result_date >= ami.diagnosis_date
                    AND ckmb.result_date <= ami.diagnosis_date + INTERVAL '5 DAY'
                    AND LOWER(ckmb.test_name) LIKE '%ck%mb%'
                    AND ckmb.value >= 10.0
                    AND (LOWER(ck_total.test_name) LIKE '%creatine kinase%' 
                         AND LOWER(ck_total.test_name) NOT LIKE '%mb%')
                    AND ck_total.value > 0
                    AND (ckmb.value / ck_total.value) >= 0.03  -- 3% ratio (3.0 when expressed as percentage)
              )
          )
    )
    
    -- Criterion 3: Statin prescribed prior to the AMI event >= 180 days
    AND EXISTS (
        SELECT 1
        FROM statin_exposures se
        WHERE se.person_id = ami.person_id
          AND se.prescription_date <= ami.diagnosis_date - INTERVAL '180 DAY'
    )
),

-- ----------------------------------------------------------------------------
-- STEP 5: IDENTIFY PRIOR AMI/ISCHEMIC HEART DISEASE HISTORY
-- For exclusion criteria in first AMI cases
-- ----------------------------------------------------------------------------
prior_ami_history AS (
    SELECT DISTINCT
        co.person_id,
        co.condition_start_date as diagnosis_date
    FROM condition_occurrence co
    INNER JOIN concept c ON co.condition_source_concept_id = c.concept_id
    WHERE c.vocabulary_id = 'ICD9CM'
      AND (c.concept_code LIKE '410%'  -- AMI
           OR c.concept_code LIKE '411%'  -- Other acute and subacute forms of ischemic heart
           OR c.concept_code LIKE '412%')  -- Old myocardial infarction
),

-- ----------------------------------------------------------------------------
-- STEP 6: IDENTIFY 1ST AMI ON STATIN
-- AMI on statin with no prior cardiac history
-- ----------------------------------------------------------------------------
first_ami_on_statin AS (
    SELECT 
        aos.person_id, 
        aos.event_date
    FROM ami_on_statin aos
    WHERE 
        -- No any AMI codes (410.*, 411.*, or 412.*) assigned before the AMI event
        NOT EXISTS (
            SELECT 1
            FROM prior_ami_history pah
            WHERE pah.person_id = aos.person_id
              AND pah.diagnosis_date < aos.event_date
        )
        -- Note: "No AMI mentioned in previous problem list by NLP" 
        -- cannot be implemented without custom NLP tables
),

-- ----------------------------------------------------------------------------
-- STEP 7: IDENTIFY REVASCULARIZATION PROCEDURES
-- Any CPT code for angioplasty or stent
-- ----------------------------------------------------------------------------
revascularization_procedures AS (
    SELECT DISTINCT
        po.person_id,
        po.procedure_date
    FROM procedure_occurrence po
    INNER JOIN concept c ON po.procedure_concept_id = c.concept_id
    WHERE c.domain_id = 'Procedure'
      AND c.vocabulary_id IN ('CPT4', 'HCPCS', 'ICD9Proc', 'ICD10PCS')
      AND (
        -- Angioplasty procedures
        LOWER(c.concept_name) LIKE '%angioplasty%'
        OR LOWER(c.concept_name) LIKE '%percutaneous transluminal coronary%'
        OR LOWER(c.concept_name) LIKE '%ptca%'
        -- Stent procedures
        OR LOWER(c.concept_name) LIKE '%stent%'
        OR LOWER(c.concept_name) LIKE '%percutaneous coronary intervention%'
        OR LOWER(c.concept_name) LIKE '%pci%'
      )
),

-- ----------------------------------------------------------------------------
-- STEP 8: IDENTIFY REVASCULARIZATION WHILE ON STATIN
-- Any CPT code for angioplasty or stent + statin >= 180 days prior
-- ----------------------------------------------------------------------------
revasc_on_statin AS (
    SELECT DISTINCT 
        rp.person_id, 
        rp.procedure_date as event_date
    FROM revascularization_procedures rp
    -- Statin prescribed prior to the procedure >= 180 days
    WHERE EXISTS (
        SELECT 1
        FROM statin_exposures se
        WHERE se.person_id = rp.person_id
          AND se.prescription_date <= rp.procedure_date - INTERVAL '180 DAY'
    )
),

-- ----------------------------------------------------------------------------
-- STEP 9: IDENTIFY 1ST REVASCULARIZATION WHILE ON STATIN
-- Revascularization while on statin with no prior revascularization
-- ----------------------------------------------------------------------------
first_revasc_on_statin AS (
    SELECT 
        ros.person_id, 
        ros.event_date
    FROM revasc_on_statin ros
    WHERE 
        -- No revascularization mentioned in previous problem list by NLP
        -- Note: "No exclusion codes before starting statin" not specific enough to implement
        -- Note: NLP extraction cannot be implemented without custom tables
        NOT EXISTS (
            SELECT 1
            FROM revascularization_procedures rp2
            WHERE rp2.person_id = ros.person_id
              AND rp2.procedure_date < ros.event_date
        )
),

-- ----------------------------------------------------------------------------
-- STEP 10: IDENTIFY CONTROLS
-- Statin prescribed with no MACE events
-- ----------------------------------------------------------------------------
controls AS (
    SELECT DISTINCT se.person_id
    FROM statin_exposures se
    WHERE 
        -- No diagnosis code for AMI, other acute and subacute forms of ischemic heart,
        -- or historical AMI assigned previously
        NOT EXISTS (
            SELECT 1
            FROM prior_ami_history pah
            WHERE pah.person_id = se.person_id
        )
        -- No revascularization CPT codes assigned previously
        AND NOT EXISTS (
            SELECT 1
            FROM revascularization_procedures rp
            WHERE rp.person_id = se.person_id
        )
        -- Note: "No MACE found in previous problem list by NLP" 
        -- cannot be implemented without custom NLP tables
),

-- ----------------------------------------------------------------------------
-- STEP 11: CALCULATE STATIN EXPOSURE
-- The number of days that the earliest statin prescription prior to the event
-- ----------------------------------------------------------------------------
statin_exposure_duration AS (
    SELECT 
        events.person_id,
        events.event_date,
        MIN(se.prescription_date) as earliest_statin_date,
        DATEDIFF(day, MIN(se.prescription_date), events.event_date) as exposure_days
    FROM (
        SELECT person_id, event_date FROM ami_on_statin
        UNION ALL
        SELECT person_id, event_date FROM revasc_on_statin
    ) events
    INNER JOIN statin_exposures se 
        ON se.person_id = events.person_id
        AND se.prescription_date < events.event_date
    GROUP BY events.person_id, events.event_date
),

-- ----------------------------------------------------------------------------
-- STEP 12: ALL-CAUSE MORTALITY
-- EMR or social security death index (SSDI) defined mortality (date)
-- ----------------------------------------------------------------------------
all_cause_mortality AS (
    SELECT 
        d.person_id,
        d.death_date,
        CASE 
            WHEN d.cause_source_value LIKE '%SSDI%' THEN 'SSDI'
            ELSE 'EMR'
        END as death_source
    FROM death d
    WHERE d.death_date IS NOT NULL
)

-- ----------------------------------------------------------------------------
-- FINAL OUTPUT: COMBINE ALL PHENOTYPES
-- ----------------------------------------------------------------------------
SELECT 
    'AMI_ON_STATIN' as phenotype,
    person_id,
    event_date
FROM ami_on_statin

UNION ALL

SELECT 
    '1ST_AMI_ON_STATIN' as phenotype,
    person_id,
    event_date
FROM first_ami_on_statin

UNION ALL

SELECT 
    'REVASCULARIZATION_WHILE_ON_STATIN' as phenotype,
    person_id,
    event_date
FROM revasc_on_statin

UNION ALL

SELECT 
    '1ST_REVASCULARIZATION_WHILE_ON_STATIN' as phenotype,
    person_id,
    event_date
FROM first_revasc_on_statin

UNION ALL

SELECT 
    'CONTROL' as phenotype,
    person_id,
    NULL as event_date
FROM controls

ORDER BY phenotype, person_id;

-- ----------------------------------------------------------------------------
-- OPTIONAL: ENHANCED OUTPUT WITH ADDITIONAL MEASURES
-- Uncomment below to include statin exposure duration and mortality data
-- ----------------------------------------------------------------------------
/*
SELECT 
    p.phenotype,
    p.person_id,
    p.event_date,
    sed.exposure_days as statin_exposure_days_before_event,
    am.death_date,
    am.death_source
FROM (
    SELECT 'AMI_ON_STATIN' as phenotype, person_id, event_date
    FROM ami_on_statin
    UNION ALL
    SELECT '1ST_AMI_ON_STATIN' as phenotype, person_id, event_date
    FROM first_ami_on_statin
    UNION ALL
    SELECT 'REVASCULARIZATION_WHILE_ON_STATIN' as phenotype, person_id, event_date
    FROM revasc_on_statin
    UNION ALL
    SELECT '1ST_REVASCULARIZATION_WHILE_ON_STATIN' as phenotype, person_id, event_date
    FROM first_revasc_on_statin
    UNION ALL
    SELECT 'CONTROL' as phenotype, person_id, NULL as event_date
    FROM controls
) p
LEFT JOIN statin_exposure_duration sed 
    ON p.person_id = sed.person_id 
    AND p.event_date = sed.event_date
LEFT JOIN all_cause_mortality am 
    ON p.person_id = am.person_id
ORDER BY p.phenotype, p.person_id;
*/