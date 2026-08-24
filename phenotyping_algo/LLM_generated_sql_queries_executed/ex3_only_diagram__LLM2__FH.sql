-- Rule 1 (VUMC-specific database name): APPLIED (all tables are fully qualified with victr_sd.sd_omop_prod)
-- Rule 2 (Wildcard fix): NOT APPLICABLE
-- Rule 3 (Concept search in clinical tables): APPLIED (ICD codes in condition_source_value, RxNorm via concept_ancestor/concept, LOINC via measurement_concept_id)
-- Rule 4 (LOINC/RxNorm/ICD code handling): APPLIED (see above)
-- Rule 5 (Free-text LIKE): NOT APPLICABLE
-- Rule 6 (OR -> UNION): NOT APPLICABLE
-- Rule 7 (LEFT JOIN OR -> UNION): NOT APPLICABLE
-- Rule 8 (Remove NLP): NOT APPLICABLE
-- Rule 9 (Mark missing concepts): NOT APPLICABLE

CREATE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex3_only_diagram_LLM2_FH AS 

WITH eligible_population AS (
    SELECT DISTINCT 
        m.`person_id`,
        m.`measurement_date`,
        YEAR(m.`measurement_date`) - p.`year_of_birth` AS age_at_measurement
    FROM `victr_sd`.`sd_omop_prod`.`measurement` m
    INNER JOIN `victr_sd`.`sd_omop_prod`.`person` p ON m.`person_id` = p.`person_id`
    WHERE YEAR(m.`measurement_date`) - p.`year_of_birth` >= 18
      AND m.`measurement_concept_id` IN (3936423, 3935643, 3022192)
),
ldl_tg_measurements AS (
    SELECT 
        m.`person_id`,
        m.`measurement_date`,
        m.`measurement_concept_id`,
        m.`value_as_number`,
        CASE 
            WHEN m.`measurement_concept_id` IN (3936423, 3935643) THEN 'LDL'
            WHEN m.`measurement_concept_id` = 3022192 THEN 'TG'
        END AS measurement_type
    FROM `victr_sd`.`sd_omop_prod`.`measurement` m
    INNER JOIN eligible_population ep ON m.`person_id` = ep.`person_id`
    WHERE m.`measurement_concept_id` IN (3936423, 3935643, 3022192)
      AND m.`value_as_number` IS NOT NULL
      AND m.`unit_concept_id` = 8840
),
high_triglycerides_exclusion AS (
    SELECT `person_id`
    FROM ldl_tg_measurements
    WHERE measurement_type = 'TG'
      AND `value_as_number` >= 500
    GROUP BY `person_id`
    HAVING COUNT(*) >= 2
),
highest_ldl_identification AS (
    SELECT ltm.`person_id`, ltm.`value_as_number` AS max_ldl_value, ltm.`measurement_date` AS index_date
    FROM (
        SELECT `person_id`, `value_as_number`, `measurement_date`,
            ROW_NUMBER() OVER (PARTITION BY `person_id` ORDER BY `value_as_number` DESC, `measurement_date` DESC) AS rn
        FROM ldl_tg_measurements
        WHERE measurement_type = 'LDL'
    ) ltm
    WHERE ltm.rn = 1
),
index_date_info AS (
    SELECT 
        hli.`person_id`,
        hli.`index_date`,
        hli.`max_ldl_value`,
        YEAR(hli.`index_date`) - p.`year_of_birth` AS age_at_index,
        p.`gender_concept_id`,
        p.`race_concept_id`,
        p.`year_of_birth`
    FROM highest_ldl_identification hli
    INNER JOIN `victr_sd`.`sd_omop_prod`.`person` p ON hli.`person_id` = p.`person_id`
),
secondary_causes_identification AS (
    SELECT DISTINCT idi.`person_id`
    FROM index_date_info idi
    INNER JOIN `victr_sd`.`sd_omop_prod`.`condition_occurrence` co ON idi.`person_id` = co.`person_id`
    WHERE co.`condition_source_value` IN (
        '581', '581.0', '581.1', '581.2', '581.3', '581.8', '581.9',
        '244', '244.0', '244.1', '244.2', '244.3', '244.8', '244.9',
        '571', '571.0', '571.1', '571.2', '571.3', '571.4', '571.5', '571.6', '571.8', '571.9',
        '250', '250.0', '250.1', '250.2', '250.3', '250.4', '250.5', '250.6', '250.7', '250.8', '250.9',
        '272.1', '272.2',
        '585', '585.1', '585.2', '585.3', '585.4', '585.5', '585.6', '585.9',
        '255.0',
        'V22', 'V23', 'V24', 'V27', 'V28'
    )
      AND co.`condition_start_date` <= idi.`index_date`
      AND co.`condition_start_date` > DATEADD(year, -1, idi.`index_date`)
),
lipid_lowering_therapy AS (
    SELECT DISTINCT idi.`person_id`
    FROM index_date_info idi
    INNER JOIN `victr_sd`.`sd_omop_prod`.`drug_exposure` de ON idi.`person_id` = de.`person_id`
    INNER JOIN `victr_sd`.`sd_omop_prod`.`concept_ancestor` ca ON ca.`descendant_concept_id` = de.`drug_concept_id`
    INNER JOIN `victr_sd`.`sd_omop_prod`.`concept` c ON ca.`ancestor_concept_id` = c.`concept_id`
    WHERE c.`vocabulary_id` = 'RxNorm'
      AND c.`concept_code` IN (
        '83367', '83366', '83365', '83364', '83363', '83362', '83361',
        '83360', '83359', '83358', '83357', '83356', '83355', '83354', '83353', '83352'
    )
      AND de.`drug_exposure_start_date` > DATEADD(year, -1, idi.`index_date`)
      AND de.`drug_exposure_start_date` <= DATEADD(week, -6, idi.`index_date`)
),
pre_treatment_ldl AS (
    SELECT idi.`person_id`, idi.`index_date`, idi.`max_ldl_value` AS measured_ldl,
        CASE WHEN llt.`person_id` IS NOT NULL THEN try_divide(idi.`max_ldl_value`,0.7) ELSE idi.`max_ldl_value` END AS adjusted_ldl_value
    FROM index_date_info idi
    LEFT JOIN lipid_lowering_therapy llt ON idi.`person_id` = llt.`person_id`
),
stage1_classification AS (
    SELECT ptl.`person_id`, ptl.`index_date`, ptl.`adjusted_ldl_value`,
        CASE WHEN ptl.`adjusted_ldl_value` >= 155 THEN 'CASE'
             WHEN ptl.`adjusted_ldl_value` <= 130 THEN 'CONTROL'
             WHEN ptl.`adjusted_ldl_value` > 130 AND ptl.`adjusted_ldl_value` < 155 THEN 'UNKNOWN'
             ELSE 'UNKNOWN' END AS stage1_status
    FROM pre_treatment_ldl ptl
    LEFT JOIN high_triglycerides_exclusion hte ON ptl.`person_id` = hte.`person_id`
    LEFT JOIN secondary_causes_identification sci ON ptl.`person_id` = sci.`person_id`
    WHERE hte.`person_id` IS NULL AND sci.`person_id` IS NULL
),
group1_ldl_scoring AS (
    SELECT `person_id`, `adjusted_ldl_value`,
        CASE WHEN `adjusted_ldl_value` >= 325 THEN 8
             WHEN `adjusted_ldl_value` >= 251 AND `adjusted_ldl_value` < 325 THEN 5
             WHEN `adjusted_ldl_value` >= 191 AND `adjusted_ldl_value` < 251 THEN 3
             WHEN `adjusted_ldl_value` >= 155 AND `adjusted_ldl_value` < 191 THEN 1
             ELSE 0 END AS ldl_points
    FROM stage1_classification
    WHERE stage1_status = 'CASE'
),
group2_personal_history_scoring AS (
    SELECT `person_id`, MAX(score_value) AS personal_history_points
    FROM (
        SELECT s1.`person_id`,
            CASE 
                WHEN co.`condition_source_value` IN (
                    '410', '410.0', '410.1', '410.2', '410.3', '410.4', '410.5', '410.6', '410.7', '410.8', '410.9',
                    '411', '411.0', '411.1', '411.8', '411.81', '411.89',
                    '414', '414.0', '414.01', '414.1', '414.2', '414.3', '414.4', '414.8', '414.9',
                    '413', '413.0', '413.1', '413.9',
                    '434', '434.0', '434.1', '434.9',
                    '443.9', '443.81', '443.89', '443.9'
                ) AND (
                    (p.`gender_concept_id` = 8507 AND YEAR(co.`condition_start_date`) - p.`year_of_birth` < 55) OR
                    (p.`gender_concept_id` = 8532 AND YEAR(co.`condition_start_date`) - p.`year_of_birth` < 65)
                ) THEN 2
                WHEN co.`condition_source_value` IN (
                    '433', '433.0', '433.1', '433.2', '433.3', '433.8', '433.9',
                    '440', '440.0', '440.1', '440.2', '440.3', '440.8', '440.9',
                    '443.9', '443.81', '443.89', '443.9'
                ) AND (
                    (p.`gender_concept_id` = 8507 AND YEAR(co.`condition_start_date`) - p.`year_of_birth` < 55) OR
                    (p.`gender_concept_id` = 8532 AND YEAR(co.`condition_start_date`) - p.`year_of_birth` < 65)
                ) THEN 1
                ELSE 0 END AS score_value
        FROM stage1_classification s1
        INNER JOIN `victr_sd`.`sd_omop_prod`.`person` p ON s1.`person_id` = p.`person_id`
        LEFT JOIN `victr_sd`.`sd_omop_prod`.`condition_occurrence` co ON s1.`person_id` = co.`person_id`
        WHERE s1.stage1_status = 'CASE'
    ) scores
    GROUP BY `person_id`
),
group3_family_history_scoring AS (
    SELECT s1.`person_id`,
        MAX(CASE WHEN o.`observation_concept_id` IN (
            4167217, 4101344, 4054836, 4041664, 4053372, 46273729
        ) THEN 1 ELSE 0 END) AS family_history_points
    FROM stage1_classification s1
    LEFT JOIN `victr_sd`.`sd_omop_prod`.`observation` o ON s1.`person_id` = o.`person_id`
    WHERE s1.stage1_status = 'CASE'
    GROUP BY s1.`person_id`
),
group4_physical_exam_scoring AS (
    SELECT `person_id`, MAX(score_value) AS physical_exam_points
    FROM (
        SELECT s1.`person_id`,
            CASE 
                WHEN o.`observation_concept_id` IN (4169378, 4013650, 4012190) THEN 6
                WHEN o.`observation_concept_id` IN (4038838, 376414) AND YEAR(o.`observation_date`) - p.`year_of_birth` < 45 THEN 4
                ELSE 0 END AS score_value
        FROM stage1_classification s1
        INNER JOIN `victr_sd`.`sd_omop_prod`.`person` p ON s1.`person_id` = p.`person_id`
        LEFT JOIN `victr_sd`.`sd_omop_prod`.`observation` o ON s1.`person_id` = o.`person_id`
        WHERE s1.stage1_status = 'CASE'
    ) scores
    GROUP BY `person_id`
),
stage2_total_scores AS (
    SELECT s1.`person_id`, s1.stage1_status, s1.`adjusted_ldl_value`,
        COALESCE(g1.ldl_points, 0) AS group1_score,
        COALESCE(g2.personal_history_points, 0) AS group2_score,
        COALESCE(g3.family_history_points, 0) AS group3_score,
        COALESCE(g4.physical_exam_points, 0) AS group4_score,
        COALESCE(g1.ldl_points, 0) + COALESCE(g2.personal_history_points, 0) + COALESCE(g3.family_history_points, 0) + COALESCE(g4.physical_exam_points, 0) AS total_score
    FROM stage1_classification s1
    LEFT JOIN group1_ldl_scoring g1 ON s1.`person_id` = g1.`person_id`
    LEFT JOIN group2_personal_history_scoring g2 ON s1.`person_id` = g2.`person_id`
    LEFT JOIN group3_family_history_scoring g3 ON s1.`person_id` = g3.`person_id`
    LEFT JOIN group4_physical_exam_scoring g4 ON s1.`person_id` = g4.`person_id`
    WHERE s1.stage1_status = 'CASE'
),
final_classification AS (
    SELECT s1.`person_id`, s1.`adjusted_ldl_value`, s1.stage1_status, s2.total_score,
        CASE 
            WHEN s1.stage1_status = 'CONTROL' THEN 'CONTROL'
            WHEN s1.stage1_status = 'UNKNOWN' THEN 'UNKNOWN'
            WHEN s1.stage1_status = 'CASE' AND s2.total_score >= 6 THEN 'FH_CASE'
            WHEN s1.stage1_status = 'CASE' AND s2.total_score BETWEEN 3 AND 5 THEN 'FH_UNKNOWN'
            WHEN s1.stage1_status = 'CASE' AND s2.total_score BETWEEN 1 AND 2 THEN 'FH_CONTROL'
            WHEN s1.stage1_status = 'CASE' AND s2.total_score = 0 THEN 'FH_CONTROL'
            ELSE 'ERROR' END AS fh_classification
    FROM stage1_classification s1
    LEFT JOIN stage2_total_scores s2 ON s1.`person_id` = s2.`person_id`
)
SELECT `person_id`, `adjusted_ldl_value` AS pre_treatment_ldl_mg_dl, fh_classification, total_score AS fh_score,
    CASE WHEN fh_classification = 'FH_CASE' THEN 1
         WHEN fh_classification IN ('FH_CONTROL', 'CONTROL') THEN 0
         ELSE NULL END AS case_control_status
FROM final_classification
ORDER BY `person_id`