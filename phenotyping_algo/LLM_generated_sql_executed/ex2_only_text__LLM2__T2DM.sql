-- Rule 1 (VUMC-specific database name): APPLIED
-- Rule 4 (LOINC/RxNorm join logic): APPLIED
-- Rule 6 (OR -> UNION for multi-table concept search): APPLIED
-- Rules 2, 3, 5, 7, 8, 9: NOT APPLICABLE

CREATE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex2_only_text_LLM2_T2DM AS 

WITH 
-- Extract T1DM diagnoses with counts
t1dm_diagnoses AS (
    SELECT 
        co.person_id,
        COUNT(DISTINCT co.condition_occurrence_id) AS t1dm_dx_cnt
    FROM victr_sd.sd_omop_prod.condition_occurrence co -- REVISED (was: FROM condition_occurrence co)
    WHERE co.condition_source_value IN (
        '250.01', '250.03', '250.11', '250.13',
        '250.21', '250.23', '250.31', '250.33',
        '250.41', '250.43', '250.51', '250.53',
        '250.61', '250.63', '250.71', '250.73',
        '250.81', '250.83', '250.91', '250.93'
    )
    GROUP BY co.person_id
),

t2dm_diagnoses AS (
    SELECT 
        co.person_id,
        COUNT(DISTINCT co.condition_occurrence_id) AS t2dm_dx_cnt,
        COUNT(DISTINCT CASE 
            WHEN co.condition_type_concept_id IN (
                32817, 32840, 38000183, 38000184, 38000199, 38000200, 44786627, 44786629
            ) THEN co.condition_occurrence_id 
        END) AS t2dm_physcn_dx_cnt
    FROM victr_sd.sd_omop_prod.condition_occurrence co -- REVISED (was: FROM condition_occurrence co)
    WHERE co.condition_source_value IN (
        '250.00', '250.02', '250.20', '250.22',
        '250.30', '250.32', '250.40', '250.42',
        '250.50', '250.52', '250.60', '250.62',
        '250.70', '250.72', '250.80', '250.82',
        '250.90', '250.92'
    )
    GROUP BY co.person_id
),

-- T1DM medications (insulin and pramlintide)
t1dm_medications AS (
    SELECT 
        de.person_id,
        MIN(de.drug_exposure_start_date) AS t1dm_rx_dt
    FROM victr_sd.sd_omop_prod.drug_exposure de -- REVISED (was: FROM drug_exposure de)
    INNER JOIN victr_sd.sd_omop_prod.concept_ancestor ca ON ca.descendant_concept_id = de.drug_concept_id -- REVISED (was: INNER JOIN concept c ON de.drug_concept_id = c.concept_id)
    INNER JOIN victr_sd.sd_omop_prod.concept c ON ca.ancestor_concept_id = c.concept_id -- REVISED (was: INNER JOIN concept c ON de.drug_concept_id = c.concept_id)
    WHERE c.vocabulary_id = 'RxNorm' -- REVISED (was: WHERE c.concept_code IN (...) AND c.vocabulary_id = 'RxNorm')
      AND c.concept_code IN (
        '139825', '274783', '314684', '352385',
        '400008', '51428', '5856', '86009',
        '139953'
    )
    GROUP BY de.person_id
),

-- T2DM medications
t2dm_medications AS (
    SELECT 
        de.person_id,
        MIN(de.drug_exposure_start_date) AS t2dm_rx_dt
    FROM victr_sd.sd_omop_prod.drug_exposure de -- REVISED (was: FROM drug_exposure de)
    INNER JOIN victr_sd.sd_omop_prod.concept_ancestor ca ON ca.descendant_concept_id = de.drug_concept_id -- REVISED (was: INNER JOIN concept c ON de.drug_concept_id = c.concept_id)
    INNER JOIN victr_sd.sd_omop_prod.concept c ON ca.ancestor_concept_id = c.concept_id -- REVISED (was: INNER JOIN concept c ON de.drug_concept_id = c.concept_id)
    WHERE c.vocabulary_id = 'RxNorm' -- REVISED (was: WHERE c.concept_code IN (...) AND c.vocabulary_id = 'RxNorm')
      AND c.concept_code IN (
        '173', '10633', '2404', '4821', '217360', '4815',
        '25789', '73044', '274332', '6809', '84108', '33738',
        '72610', '16681', '30009', '593411', '60548'
    )
    GROUP BY de.person_id
),

-- Glucose and HbA1c labs
diabetes_labs AS (
    SELECT 
        m.person_id,
        MAX(CASE WHEN c.concept_code = '1558-6' THEN m.value_as_number END) AS max_fast_gluc_lab_val,
        MAX(CASE WHEN c.concept_code IN ('2339-0', '2345-7') THEN m.value_as_number END) AS max_rndm_gluc_lab_val,
        MAX(CASE WHEN c.concept_code IN ('4548-4', '17856-6', '4549-2', '17855-8') THEN m.value_as_number END) AS max_hba1c_lab_val
    FROM victr_sd.sd_omop_prod.measurement m -- REVISED (was: FROM measurement m)
    INNER JOIN victr_sd.sd_omop_prod.concept c ON m.measurement_concept_id = c.concept_id -- REVISED (was: INNER JOIN concept c ON m.measurement_concept_id = c.concept_id)
    WHERE c.vocabulary_id = 'LOINC'
      AND m.value_as_number IS NOT NULL
      AND m.value_as_number > 0
    GROUP BY m.person_id
),

case_criteria AS (
    SELECT 
        p.person_id,
        COALESCE(t1.t1dm_dx_cnt, 0) AS t1dm_dx_cnt,
        COALESCE(t2.t2dm_dx_cnt, 0) AS t2dm_dx_cnt,
        COALESCE(t2.t2dm_physcn_dx_cnt, 0) AS t2dm_physcn_dx_cnt,
        t1med.t1dm_rx_dt,
        t2med.t2dm_rx_dt,
        labs.max_fast_gluc_lab_val,
        labs.max_rndm_gluc_lab_val,
        labs.max_hba1c_lab_val
    FROM victr_sd.sd_omop_prod.person p -- REVISED (was: FROM person p)
    LEFT JOIN t1dm_diagnoses t1 ON p.person_id = t1.person_id
    LEFT JOIN t2dm_diagnoses t2 ON p.person_id = t2.person_id
    LEFT JOIN t1dm_medications t1med ON p.person_id = t1med.person_id
    LEFT JOIN t2dm_medications t2med ON p.person_id = t2med.person_id
    LEFT JOIN diabetes_labs labs ON p.person_id = labs.person_id
),

diabetes_dx_for_controls AS (
    SELECT 
        co.person_id,
        COUNT(DISTINCT co.condition_occurrence_id) AS dm_dx_cnt
    FROM victr_sd.sd_omop_prod.condition_occurrence co -- REVISED (was: FROM condition_occurrence co)
    WHERE 
        co.condition_source_value LIKE '250%'
        OR co.condition_source_value = '790.21'
        OR co.condition_source_value = '790.22'
        OR co.condition_source_value IN ('790.2', '790.29')
        OR co.condition_source_value LIKE '648.8%'
        OR co.condition_source_value LIKE '648.0%'
        OR co.condition_source_value = '791.5'
        OR co.condition_source_value = '277.7'
        OR co.condition_source_value = 'V18.0'
        OR co.condition_source_value = 'V77.1'
    GROUP BY co.person_id
),

diabetes_family_history AS (
    SELECT DISTINCT person_id, 1 AS fam_hist_of_dm
    FROM (
        SELECT person_id 
        FROM victr_sd.sd_omop_prod.condition_occurrence -- REVISED (was: FROM condition_occurrence)
        WHERE condition_source_value = 'V18.0'
        UNION -- REVISED (was: OR)
        SELECT person_id
        FROM victr_sd.sd_omop_prod.observation -- REVISED (was: FROM observation)
        WHERE observation_source_value = 'V18.0'
        UNION -- REVISED (was: OR)
        SELECT o.person_id
        FROM victr_sd.sd_omop_prod.observation o -- REVISED (was: FROM observation o)
        INNER JOIN victr_sd.sd_omop_prod.concept c ON o.observation_concept_id = c.concept_id -- REVISED (was: INNER JOIN concept c ON o.observation_concept_id = c.concept_id)
        WHERE c.concept_id IN (4167217, 4058286)
    ) fh
),

diabetes_med_supplies AS (
    SELECT 
        de.person_id,
        COUNT(DISTINCT de.drug_exposure_id) AS dm_med_supplies_cnt
    FROM victr_sd.sd_omop_prod.drug_exposure de -- REVISED (was: FROM drug_exposure de)
    INNER JOIN victr_sd.sd_omop_prod.concept_ancestor ca ON ca.descendant_concept_id = de.drug_concept_id -- REVISED (was: INNER JOIN concept c ON de.drug_concept_id = c.concept_id)
    INNER JOIN victr_sd.sd_omop_prod.concept c ON ca.ancestor_concept_id = c.concept_id -- REVISED (was: INNER JOIN concept c ON de.drug_concept_id = c.concept_id)
    WHERE c.vocabulary_id = 'RxNorm' -- REVISED (was: WHERE c.concept_code IN (...) AND c.vocabulary_id = 'RxNorm')
      AND c.concept_code IN (
        '139825', '274783', '314684', '352385',
        '400008', '51428', '5856', '86009', '139953',
        '173', '10633', '2404', '4821', '217360', '4815',
        '25789', '73044', '274332', '6809', '84108', '33738',
        '72610', '16681', '30009', '593411', '60548',
        '126958', '412956', '412959', '637321', '668291',
        '668370', '686655', '692383', '748611', '880998',
        '881056', '751128',
        '847187', '847191', '847197', '847203', '847207',
        '847211', '847230', '847239', '847252', '847256',
        '847259', '847263', '847278', '847416', '847417',
        '806905', '806903', '408119'
    )
    GROUP BY de.person_id
),

outpatient_encounters AS (
    SELECT 
        vo.person_id,
        COUNT(DISTINCT vo.visit_start_date) AS enctrs_cnt
    FROM victr_sd.sd_omop_prod.visit_occurrence vo -- REVISED (was: FROM visit_occurrence vo)
    INNER JOIN victr_sd.sd_omop_prod.concept c ON vo.visit_concept_id = c.concept_id -- REVISED (was: INNER JOIN concept c ON vo.visit_concept_id = c.concept_id)
    WHERE c.concept_id IN (
        9202, 9203, 581477, 581478, 5083
    )
    GROUP BY vo.person_id
),

control_criteria AS (
    SELECT 
        p.person_id,
        COALESCE(ddx.dm_dx_cnt, 0) AS dm_dx_cnt,
        COALESCE(fh.fam_hist_of_dm, 0) AS fam_hist_of_dm,
        COALESCE(ms.dm_med_supplies_cnt, 0) AS dm_med_supplies_cnt,
        labs.max_fast_gluc_lab_val,
        labs.max_rndm_gluc_lab_val,
        labs.max_hba1c_lab_val,
        COALESCE(enc.enctrs_cnt, 0) AS enctrs_cnt
    FROM victr_sd.sd_omop_prod.person p -- REVISED (was: FROM person p)
    LEFT JOIN diabetes_dx_for_controls ddx ON p.person_id = ddx.person_id
    LEFT JOIN diabetes_family_history fh ON p.person_id = fh.person_id
    LEFT JOIN diabetes_med_supplies ms ON p.person_id = ms.person_id
    LEFT JOIN diabetes_labs labs ON p.person_id = labs.person_id
    LEFT JOIN outpatient_encounters enc ON p.person_id = enc.person_id
),

final_cohort AS (
    SELECT 
        p.person_id,
        CASE 
            WHEN 
                (cc.t2dm_dx_cnt > 0 OR cc.t2dm_physcn_dx_cnt > 0)
                AND (
                    cc.t2dm_rx_dt IS NOT NULL
                    OR cc.max_rndm_gluc_lab_val > 200
                    OR cc.max_fast_gluc_lab_val >= 125
                    OR cc.max_hba1c_lab_val >= 6.5
                )
                AND (cc.t1dm_dx_cnt = 0 OR cc.t2dm_dx_cnt >= cc.t1dm_dx_cnt)
            THEN 1
            WHEN cc.t2dm_dx_cnt >= 2 AND cc.t1dm_dx_cnt = 0
            THEN 1
            WHEN cc.t2dm_physcn_dx_cnt >= 1 
                 AND cc.t1dm_dx_cnt = 0
                 AND (
                    cc.t2dm_rx_dt IS NOT NULL
                    OR cc.max_rndm_gluc_lab_val > 200
                    OR cc.max_fast_gluc_lab_val >= 125
                    OR cc.max_hba1c_lab_val >= 6.5
                 )
            THEN 1
            ELSE 0
        END AS is_case,
        CASE 
            WHEN 
                ctrl.dm_dx_cnt = 0
                AND (ctrl.max_fast_gluc_lab_val IS NULL OR ctrl.max_fast_gluc_lab_val < 110)
                AND (ctrl.max_rndm_gluc_lab_val IS NULL OR ctrl.max_rndm_gluc_lab_val <= 110)
                AND (ctrl.max_hba1c_lab_val IS NULL OR ctrl.max_hba1c_lab_val < 6.0)
                AND ctrl.fam_hist_of_dm = 0
                AND ctrl.dm_med_supplies_cnt = 0
                AND ctrl.enctrs_cnt >= 2
            THEN 1
            ELSE 0
        END AS is_control
    FROM victr_sd.sd_omop_prod.person p -- REVISED (was: FROM person p)
    LEFT JOIN case_criteria cc ON p.person_id = cc.person_id
    LEFT JOIN control_criteria ctrl ON p.person_id = ctrl.person_id
)

SELECT 
    person_id,
    CASE 
        WHEN is_case = 1 THEN 'T2DM_CASE'
        WHEN is_control = 1 THEN 'T2DM_CONTROL'
        ELSE 'EXCLUDED'
    END AS phenotype_status,
    CURRENT_DATE AS cohort_entry_date
FROM final_cohort
WHERE is_case = 1 OR is_control = 1
ORDER BY person_id;