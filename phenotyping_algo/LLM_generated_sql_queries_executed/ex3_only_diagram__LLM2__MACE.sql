-- Rule 1 (VUMC-specific database name): APPLIED -- All tables use `victr_sd`.`sd_omop_prod`
-- Rule 2 (wildcard fix): NOT APPLICABLE
-- Rule 3 (search concepts in clinical tables): APPLIED -- ICD codes filtered in condition_source_value, LOINC/RxNorm via concept join
-- Rule 4 (concept search in clinical tables): APPLIED -- See above
-- Rule 5 (IN -> LIKE + LOWER for descriptive fields): APPLIED -- Not used for codes, only for names if needed
-- Rule 6 (OR -> UNION): NOT APPLICABLE
-- Rule 7 (LEFT JOIN -> UNION): NOT APPLICABLE
-- Rule 8 (Remove NLP/free-text logic): APPLIED -- NLP logic removed
-- Rule 9 (missing concept codes): APPLIED -- MISSING CONCEPT: statin RxNorm codes, cardiac lab LOINC codes, revascularization codes
-- FIX: Replaced invalid IN clause with 1=0 for missing statin codes
-- FIX: Replaced invalid IN clause with 1=0 for missing cardiac lab LOINC codes
-- FIX: Replaced invalid IN clause with 1=0 for missing revascularization codes

CREATE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex3_only_diagram_LLM2_MACE AS 

WITH
statin_exposures AS (
    SELECT DISTINCT
        de.person_id,
        de.drug_exposure_start_date as prescription_date,
        de.drug_concept_id
    FROM `victr_sd`.`sd_omop_prod`.`drug_exposure` de
    INNER JOIN `victr_sd`.`sd_omop_prod`.`concept_ancestor` ca ON de.drug_concept_id = ca.descendant_concept_id
    INNER JOIN `victr_sd`.`sd_omop_prod`.`concept` c ON ca.ancestor_concept_id = c.concept_id
    -- REVISED (was: WHERE c.vocabulary_id = 'RxNorm' AND c.concept_code IN (-- MISSING CONCEPT: statin RxNorm codes))
    WHERE c.vocabulary_id = 'RxNorm' AND 1=0 -- MISSING CONCEPT: statin RxNorm codes
),
ami_diagnoses AS (
    SELECT 
        co.person_id,
        co.condition_start_date as diagnosis_date,
        co.condition_source_value as icd_code,
        (
            SELECT COUNT(*)
            FROM `victr_sd`.`sd_omop_prod`.`condition_occurrence` co2
            WHERE co2.person_id = co.person_id
              AND (co2.condition_source_value LIKE '410%' OR co2.condition_source_value LIKE '411%')
              AND co2.condition_start_date >= co.condition_start_date
              AND co2.condition_start_date <= DATE_ADD(co.condition_start_date, 5)
        ) as ami_count_in_window
    FROM `victr_sd`.`sd_omop_prod`.`condition_occurrence` co
    WHERE co.condition_source_value LIKE '410%' OR co.condition_source_value LIKE '411%'
),
cardiac_labs AS (
    SELECT 
        m.person_id,
        m.measurement_date as result_date,
        c.concept_name as test_name,
        m.value_as_number as value,
        uc.concept_name as unit
    FROM `victr_sd`.`sd_omop_prod`.`measurement` m
    INNER JOIN `victr_sd`.`sd_omop_prod`.`concept` c ON m.measurement_concept_id = c.concept_id
    LEFT JOIN `victr_sd`.`sd_omop_prod`.`concept` uc ON m.unit_concept_id = uc.concept_id
    WHERE m.value_as_number IS NOT NULL
      -- REVISED (was: AND (c.vocabulary_id = 'LOINC' AND c.concept_code IN ('MISSING_TROPONIN_I_LOINC', ...)))
      AND 1=0 -- MISSING CONCEPT: LOINC codes for cardiac labs
),
ami_on_statin AS (
    SELECT DISTINCT 
        ami.person_id, 
        ami.diagnosis_date as event_date
    FROM ami_diagnoses ami
    WHERE ami.ami_count_in_window >= 2
    AND EXISTS (
        SELECT 1
        FROM cardiac_labs lab
        WHERE lab.person_id = ami.person_id
          AND lab.result_date >= ami.diagnosis_date
          AND lab.result_date <= DATE_ADD(ami.diagnosis_date, 5)
          -- REVISED (was: AND (lab.test_name = 'MISSING_TROPONIN_I_LOINC' AND lab.value >= 0.10) ...)
          AND 1=0 -- MISSING CONCEPT: cardiac lab logic
    )
    AND EXISTS (
        SELECT 1
        FROM statin_exposures se
        WHERE se.person_id = ami.person_id
          AND se.prescription_date <= DATE_ADD(ami.diagnosis_date, -180)
    )
),
prior_ami_history AS (
    SELECT DISTINCT
        co.person_id,
        co.condition_start_date as diagnosis_date
    FROM `victr_sd`.`sd_omop_prod`.`condition_occurrence` co
    WHERE co.condition_source_value LIKE '410%' OR co.condition_source_value LIKE '411%' OR co.condition_source_value LIKE '412%'
),
first_ami_on_statin AS (
    SELECT 
        aos.person_id, 
        aos.event_date
    FROM ami_on_statin aos
    WHERE 
        NOT EXISTS (
            SELECT 1
            FROM prior_ami_history pah
            WHERE pah.person_id = aos.person_id
              AND pah.diagnosis_date < aos.event_date
        )
),
revascularization_procedures AS (
    SELECT DISTINCT
        po.person_id,
        po.procedure_date
    FROM `victr_sd`.`sd_omop_prod`.`procedure_occurrence` po
    INNER JOIN `victr_sd`.`sd_omop_prod`.`concept` c ON po.procedure_concept_id = c.concept_id
    -- REVISED (was: AND c.concept_code IN ('MISSING_ANGIOPLASTY_CODES', ...))
    WHERE c.vocabulary_id IN ('CPT4', 'HCPCS', 'ICD9Proc', 'ICD10PCS') AND 1=0 -- MISSING CONCEPT: CPT/ICD codes for revascularization
),
revasc_on_statin AS (
    SELECT DISTINCT 
        rp.person_id, 
        rp.procedure_date as event_date
    FROM revascularization_procedures rp
    WHERE EXISTS (
        SELECT 1
        FROM statin_exposures se
        WHERE se.person_id = rp.person_id
          AND se.prescription_date <= DATE_ADD(rp.procedure_date, -180)
    )
),
first_revasc_on_statin AS (
    SELECT 
        ros.person_id, 
        ros.event_date
    FROM revasc_on_statin ros
    WHERE 
        NOT EXISTS (
            SELECT 1
            FROM revascularization_procedures rp2
            WHERE rp2.person_id = ros.person_id
              AND rp2.procedure_date < ros.event_date
        )
),
controls AS (
    SELECT DISTINCT se.person_id
    FROM statin_exposures se
    WHERE 
        NOT EXISTS (
            SELECT 1
            FROM prior_ami_history pah
            WHERE pah.person_id = se.person_id
        )
        AND NOT EXISTS (
            SELECT 1
            FROM revascularization_procedures rp
            WHERE rp.person_id = se.person_id
        )
),
statin_exposure_duration AS (
    SELECT 
        events.person_id,
        events.event_date,
        MIN(se.prescription_date) as earliest_statin_date,
        DATEDIFF(events.event_date, MIN(se.prescription_date)) as exposure_days
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
all_cause_mortality AS (
    SELECT 
        d.person_id,
        d.death_date,
        CASE 
            WHEN d.cause_source_value LIKE '%SSDI%' THEN 'SSDI'
            ELSE 'EMR'
        END as death_source
    FROM `victr_sd`.`sd_omop_prod`.`death` d
    WHERE d.death_date IS NOT NULL
)
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
