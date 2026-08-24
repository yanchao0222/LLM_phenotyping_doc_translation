-- Rule 1 (VUMC-specific database name): APPLIED (all tables fully qualified with victr_sd.sd_omop_prod)
-- Rule 2 (wildcard fix): NOT APPLICABLE
-- Rule 3 (ICD codes in condition_occurrence.condition_source_value): APPLIED (all ICD code filters use condition_source_value)
-- Rule 4 (LOINC/RxNorm codes via concept join): APPLIED (LOINC via concept join on measurement, RxNorm via concept_ancestor join on drug_exposure)
-- Rule 5 (descriptive fields use LOWER LIKE): APPLIED (concept_name LIKE replaced with LOWER(concept_name) LIKE LOWER('%term%'))
-- Rule 6 (OR replaced with UNION): APPLIED (family_history uses UNION)
-- Rule 7 (LEFT JOINs with OR replaced by UNION): NOT APPLICABLE
-- Rule 8 (NLP/free-text logic removed): NOT APPLICABLE
-- Rule 9 (missing/ambiguous concept codes): NOT APPLICABLE

CREATE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex1_all_content_LLM2_T2DM AS 

WITH 
-- SECTION 1: T1DM DIAGNOSIS COUNTS
-- REVISED (was: INNER JOIN concept c ON co.condition_concept_id = c.concept_id WHERE c.concept_code IN (...))
t1dm_diagnoses AS (
    SELECT 
        co.person_id,
        COUNT(DISTINCT co.condition_start_date) AS t1dm_dx_count
    FROM victr_sd.sd_omop_prod.condition_occurrence co
    WHERE co.condition_source_value IN (
        '250.01', '250.03', '250.11', '250.13', '250.21', 
        '250.23', '250.31', '250.33', '250.41', '250.43',
        '250.51', '250.53', '250.61', '250.63', '250.71',
        '250.73', '250.81', '250.83', '250.91', '250.93'
    )
    GROUP BY co.person_id
),

-- SECTION 2: T2DM DIAGNOSIS COUNTS
-- REVISED (was: INNER JOIN concept c ON co.condition_concept_id = c.concept_id WHERE c.concept_code IN (...))
t2dm_diagnoses AS (
    SELECT 
        co.person_id,
        COUNT(DISTINCT co.condition_start_date) AS t2dm_dx_count,
        COUNT(DISTINCT CASE 
            WHEN co.condition_type_concept_id IN (
                38000183, 38000184, 38000199, 38000200, 38000230, 38000245, 38000280, 42898140, 44786627, 44786629
            )
            THEN co.condition_start_date 
        END) AS t2dm_physician_dx_count
    FROM victr_sd.sd_omop_prod.condition_occurrence co
    WHERE co.condition_source_value IN (
        '250.00', '250.02', '250.20', '250.22', '250.30',
        '250.32', '250.40', '250.42', '250.50', '250.52',
        '250.60', '250.62', '250.70', '250.72', '250.80',
        '250.82', '250.90', '250.92'
    )
    GROUP BY co.person_id
),

-- SECTION 3: MEDICATION DATES
-- REVISED (was: INNER JOIN concept c ON de.drug_concept_id = c.concept_id WHERE c.concept_code IN (...))
medications AS (
    SELECT 
        de.person_id,
        MIN(CASE 
            WHEN c.concept_code IN (
                '139825', '274783', '314684', '352385', 
                '400008', '51428', '5856', '86009', '139953'
            ) AND c.vocabulary_id = 'RxNorm'
            THEN de.drug_exposure_start_date 
        END) AS t1dm_rx_date,
        MIN(CASE 
            WHEN c.concept_code IN (
                '173', '10633', '2404', '4821', '217360', '4815', '25789', '73044', '274332',
                '6809', '84108', '33738', '72610', '16681', '30009', '593411', '60548'
            ) AND c.vocabulary_id = 'RxNorm'
            THEN de.drug_exposure_start_date 
        END) AS t2dm_rx_date
    FROM victr_sd.sd_omop_prod.drug_exposure de
    INNER JOIN victr_sd.sd_omop_prod.concept_ancestor ca ON ca.descendant_concept_id = de.drug_concept_id
    INNER JOIN victr_sd.sd_omop_prod.concept c ON ca.ancestor_concept_id = c.concept_id
    WHERE c.vocabulary_id = 'RxNorm'
    GROUP BY de.person_id
),

-- SECTION 4: LABORATORY VALUES
-- REVISED (was: INNER JOIN concept c ON m.measurement_concept_id = c.concept_id WHERE c.concept_code = ...)
lab_values AS (
    SELECT 
        m.person_id,
        MAX(CASE 
            WHEN c.concept_code = '1558-6' AND c.vocabulary_id = 'LOINC'
            THEN m.value_as_number 
        END) AS max_fasting_glucose,
        MAX(CASE 
            WHEN c.concept_code IN ('2339-0', '2345-7') AND c.vocabulary_id = 'LOINC'
            THEN m.value_as_number 
        END) AS max_random_glucose,
        MAX(CASE 
            WHEN c.concept_code IN ('4548-4', '17856-6', '4549-2', '17855-8') AND c.vocabulary_id = 'LOINC'
            THEN m.value_as_number 
        END) AS max_hba1c,
        MAX(CASE 
            WHEN c.concept_code IN ('1558-6', '2339-0', '2345-7') AND c.vocabulary_id = 'LOINC'
            THEN 1 ELSE 0 
        END) AS glucose_lab_exists
    FROM victr_sd.sd_omop_prod.measurement m
    INNER JOIN victr_sd.sd_omop_prod.concept c ON m.measurement_concept_id = c.concept_id
    WHERE c.vocabulary_id = 'LOINC'
    GROUP BY m.person_id
),

-- SECTION 5: DIABETES-RELATED DIAGNOSES (FOR CONTROLS)
-- REVISED (was: INNER JOIN concept c ON co.condition_concept_id = c.concept_id WHERE c.concept_code IN (...))
all_diabetes_diagnoses AS (
    SELECT 
        co.person_id,
        COUNT(DISTINCT co.condition_start_date) AS dm_dx_count
    FROM victr_sd.sd_omop_prod.condition_occurrence co
    WHERE co.condition_source_value IN (
        '250.00', '250.01', '250.02', '250.03', '250.10', '250.11', '250.12', '250.13',
        '250.20', '250.21', '250.22', '250.23', '250.30', '250.31', '250.32', '250.33',
        '250.40', '250.41', '250.42', '250.43', '250.50', '250.51', '250.52', '250.53',
        '250.60', '250.61', '250.62', '250.63', '250.70', '250.71', '250.72', '250.73',
        '250.80', '250.81', '250.82', '250.83', '250.90', '250.91', '250.92', '250.93',
        '790.21', '790.22', '790.2', '790.29',
        '648.80', '648.81', '648.82', '648.83', '648.84', '648.85', '648.86', '648.87', '648.88', '648.89',
        '648.00', '648.01', '648.02', '648.03', '648.04', '648.05', '648.06', '648.07', '648.08', '648.09',
        '791.5', '277.7', 'V18.0', 'V77.1'
    )
    GROUP BY co.person_id
),

-- SECTION 6: DIABETES MEDICATIONS AND SUPPLIES (FOR CONTROLS)
-- REVISED (was: INNER JOIN concept c ON de.drug_concept_id = c.concept_id WHERE c.concept_code IN (...))
diabetes_meds_supplies AS (
    SELECT 
        de.person_id,
        COUNT(DISTINCT de.drug_exposure_start_date) AS dm_med_supplies_count
    FROM victr_sd.sd_omop_prod.drug_exposure de
    INNER JOIN victr_sd.sd_omop_prod.concept_ancestor ca ON ca.descendant_concept_id = de.drug_concept_id
    INNER JOIN victr_sd.sd_omop_prod.concept c ON ca.ancestor_concept_id = c.concept_id
    WHERE c.vocabulary_id = 'RxNorm'
    AND c.concept_code IN (
        '139825', '274783', '314684', '352385', '400008', '51428', '5856', '86009', '139953',
        '173', '10633', '2404', '4821', '217360', '4815', '25789', '73044', '274332',
        '6809', '84108', '33738', '72610', '16681', '30009', '593411', '60548',
        '126958', '412956', '412959', '637321', '668291', '668370', '686655', '692383',
        '748611', '880998', '881056', '751128',
        '847187', '847191', '847197', '847203', '847207', '847211', '847230', '847239',
        '847252', '847256', '847259', '847263', '847278', '847416', '847417',
        '806905', '806903', '408119'
    )
    GROUP BY de.person_id
),

-- SECTION 7: OUTPATIENT ENCOUNTERS (FOR CONTROLS)
-- REVISED (was: WHERE c.concept_code IN ('OP', 'OUTPATIENT') OR c.concept_name LIKE '%office%' OR c.concept_name LIKE '%outpatient%' OR vo.visit_concept_id IN (...))
outpatient_encounters AS (
    SELECT 
        vo.person_id,
        COUNT(DISTINCT vo.visit_start_date) AS encounter_count
    FROM victr_sd.sd_omop_prod.visit_occurrence vo
    INNER JOIN victr_sd.sd_omop_prod.concept c ON vo.visit_concept_id = c.concept_id
    WHERE c.concept_code IN ('OP', 'OUTPATIENT')
    OR LOWER(c.concept_name) LIKE LOWER('%office%')
    OR LOWER(c.concept_name) LIKE LOWER('%outpatient%')
    OR vo.visit_concept_id IN (9202, 581477)
    GROUP BY vo.person_id
),

-- SECTION 8: FAMILY HISTORY (FOR CONTROLS)
-- REVISED (was: WHERE c.concept_code = 'V18.0' AND c.vocabulary_id = 'ICD9CM' OR c.concept_name LIKE '%family history%diabetes%')
family_history AS (
    SELECT DISTINCT
        co.person_id,
        1 AS has_dm_family_history
    FROM victr_sd.sd_omop_prod.condition_occurrence co
    WHERE co.condition_source_value = 'V18.0'
    
    UNION
    
    SELECT DISTINCT
        o.person_id,
        1 AS has_dm_family_history
    FROM victr_sd.sd_omop_prod.observation o
    INNER JOIN victr_sd.sd_omop_prod.concept c ON o.observation_concept_id = c.concept_id
    WHERE (c.concept_code = 'V18.0' AND c.vocabulary_id = 'ICD9CM')
    OR LOWER(c.concept_name) LIKE LOWER('%family history%diabetes%')
),

-- SECTION 9: T2DM CASE IDENTIFICATION
-- No revision needed; logic unchanged
t2dm_cases AS (
    SELECT 
        p.person_id,
        CASE 
            WHEN COALESCE(t1.t1dm_dx_count, 0) = 0 
                AND COALESCE(t2.t2dm_dx_count, 0) > 0
                AND m.t2dm_rx_date IS NOT NULL
                AND m.t1dm_rx_date IS NOT NULL
                AND m.t2dm_rx_date < m.t1dm_rx_date
            THEN 1
            WHEN COALESCE(t1.t1dm_dx_count, 0) = 0
                AND COALESCE(t2.t2dm_dx_count, 0) > 0
                AND m.t1dm_rx_date IS NULL
                AND m.t2dm_rx_date IS NOT NULL
            THEN 1
            WHEN COALESCE(t1.t1dm_dx_count, 0) = 0
                AND COALESCE(t2.t2dm_dx_count, 0) > 0
                AND m.t1dm_rx_date IS NULL
                AND m.t2dm_rx_date IS NULL
                AND (
                    l.max_random_glucose > 200
                    OR l.max_fasting_glucose >= 125
                    OR l.max_hba1c >= 6.5
                )
            THEN 1
            WHEN COALESCE(t1.t1dm_dx_count, 0) = 0
                AND COALESCE(t2.t2dm_dx_count, 0) = 0
                AND m.t2dm_rx_date IS NOT NULL
                AND (
                    l.max_random_glucose > 200
                    OR l.max_fasting_glucose >= 125
                    OR l.max_hba1c >= 6.5
                )
            THEN 1
            WHEN COALESCE(t1.t1dm_dx_count, 0) = 0
                AND COALESCE(t2.t2dm_dx_count, 0) > 0
                AND m.t1dm_rx_date IS NOT NULL
                AND m.t2dm_rx_date IS NULL
                AND COALESCE(t2.t2dm_physician_dx_count, 0) >= 2
            THEN 1
            ELSE 0
        END AS is_case
    FROM victr_sd.sd_omop_prod.person p
    LEFT JOIN t1dm_diagnoses t1 ON p.person_id = t1.person_id
    LEFT JOIN t2dm_diagnoses t2 ON p.person_id = t2.person_id
    LEFT JOIN medications m ON p.person_id = m.person_id
    LEFT JOIN lab_values l ON p.person_id = l.person_id
),

-- SECTION 10: T2DM CONTROL IDENTIFICATION
-- No revision needed; logic unchanged
t2dm_controls AS (
    SELECT 
        p.person_id,
        CASE 
            WHEN COALESCE(ad.dm_dx_count, 0) = 0
                AND COALESCE(l.glucose_lab_exists, 0) = 1
                AND (
                    COALESCE(l.max_random_glucose, 0) <= 110
                    AND COALESCE(l.max_fasting_glucose, 0) < 110
                    AND COALESCE(l.max_hba1c, 0) < 6.0
                )
                AND COALESCE(oe.encounter_count, 0) >= 2
                AND COALESCE(dms.dm_med_supplies_count, 0) = 0
                AND COALESCE(fh.has_dm_family_history, 0) = 0
            THEN 1
            ELSE 0
        END AS is_control
    FROM victr_sd.sd_omop_prod.person p
    LEFT JOIN all_diabetes_diagnoses ad ON p.person_id = ad.person_id
    LEFT JOIN lab_values l ON p.person_id = l.person_id
    LEFT JOIN outpatient_encounters oe ON p.person_id = oe.person_id
    LEFT JOIN diabetes_meds_supplies dms ON p.person_id = dms.person_id
    LEFT JOIN family_history fh ON p.person_id = fh.person_id
)

SELECT 
    p.person_id,
    p.gender_concept_id,
    p.year_of_birth,
    CASE 
        WHEN tc.is_case = 1 THEN 'T2DM_CASE'
        WHEN tctl.is_control = 1 THEN 'T2DM_CONTROL'
        ELSE 'UNKNOWN'
    END AS phenotype_status,
    tc.is_case AS case_flag,
    tctl.is_control AS control_flag,
    CURRENT_DATE AS cohort_entry_date
FROM victr_sd.sd_omop_prod.person p
LEFT JOIN t2dm_cases tc ON p.person_id = tc.person_id
LEFT JOIN t2dm_controls tctl ON p.person_id = tctl.person_id
WHERE tc.is_case = 1 OR tctl.is_control = 1
ORDER BY 
    phenotype_status,
    p.person_id;
