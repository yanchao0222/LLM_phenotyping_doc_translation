-- Rule 1 (VUMC-specific database name): APPLIED
-- Rule 3 (ICD codes in condition_occurrence.condition_source_value): APPLIED
-- Rule 4 (LOINC/RxNorm join logic): APPLIED
-- Rule 5 (local lab names with LOWER LIKE): APPLIED
-- Rule 8 (remove NLP/free-text logic): APPLIED
-- Rules 2, 6, 7, 9: NOT APPLICABLE
-- FIX: Removed NLP/free-text logic (note table NOT EXISTS) from first_ami_on_statins, first_revasc_on_statins, and controls CTEs per Rule 8
-- FIX: Ensured CTE block is properly closed and followed by SELECT statement

CREATE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex2_only_text_LLM2_MACE AS 

WITH ami_diagnosis_counts AS (
    -- REVISED (was: FROM condition_occurrence co1 ...)
    SELECT co1.person_id, co1.condition_start_date as event_date
    FROM `victr_sd`.`sd_omop_prod`.`condition_occurrence` co1
    WHERE (
        co1.condition_source_value LIKE '410%' OR co1.condition_source_value LIKE '411%'
    )
    AND EXISTS (
        SELECT 1
        FROM `victr_sd`.`sd_omop_prod`.`condition_occurrence` co2
        WHERE co2.person_id = co1.person_id
            AND (co2.condition_source_value LIKE '410%' OR co2.condition_source_value LIKE '411%')
            AND co2.condition_start_date BETWEEN co1.condition_start_date AND DATE_ADD(co1.condition_start_date, 5)
            AND co2.condition_occurrence_id != co1.condition_occurrence_id
    )
),

ami_with_labs AS (
    SELECT DISTINCT adc.person_id, adc.event_date
    FROM ami_diagnosis_counts adc
    WHERE EXISTS (
        SELECT 1
        FROM `victr_sd`.`sd_omop_prod`.`measurement` m
        WHERE m.person_id = adc.person_id
            AND m.measurement_date BETWEEN adc.event_date AND DATE_ADD(adc.event_date, 5)
            AND (
                (LOWER(m.measurement_source_value) LIKE '%troponin i%' AND m.value_as_number >= 0.10)
                OR (LOWER(m.measurement_source_value) LIKE '%troponin t%' AND m.value_as_number >= 0.10)
                OR EXISTS (
                    SELECT 1
                    FROM `victr_sd`.`sd_omop_prod`.`measurement` m1
                    WHERE m1.person_id = adc.person_id
                        AND m1.measurement_date BETWEEN adc.event_date AND DATE_ADD(adc.event_date, 5)
                        AND LOWER(m1.measurement_source_value) LIKE '%ck%mb%ratio%'
                        AND m1.value_as_number >= 3.0
                        AND EXISTS (
                            SELECT 1
                            FROM `victr_sd`.`sd_omop_prod`.`measurement` m2
                            WHERE m2.person_id = m1.person_id
                                AND m2.measurement_date = m1.measurement_date
                                AND LOWER(m2.measurement_source_value) LIKE '%ck%mb%'
                                AND LOWER(m2.measurement_source_value) NOT LIKE '%ratio%'
                                AND m2.value_as_number >= 10.0
                        )
                )
            )
    )
),

ami_on_statins_final AS (
    SELECT awl.person_id, awl.event_date
    FROM ami_with_labs awl
    WHERE EXISTS (
        SELECT 1
        FROM `victr_sd`.`sd_omop_prod`.`drug_exposure` de
        INNER JOIN `victr_sd`.`sd_omop_prod`.`concept_ancestor` ca ON de.drug_concept_id = ca.descendant_concept_id
        INNER JOIN `victr_sd`.`sd_omop_prod`.`concept` c ON ca.ancestor_concept_id = c.concept_id
        WHERE de.person_id = awl.person_id
            AND DATE_ADD(de.drug_exposure_start_date, 180) <= awl.event_date
            AND c.concept_id = 1539403
            AND c.concept_class_id = 'Ingredient'
    )
),

first_ami_on_statins AS (
    SELECT aos.person_id, aos.event_date
    FROM ami_on_statins_final aos
    WHERE NOT EXISTS (
        SELECT 1
        FROM `victr_sd`.`sd_omop_prod`.`condition_occurrence` co
        WHERE co.person_id = aos.person_id
            AND co.condition_start_date < aos.event_date
            AND (
                co.condition_source_value LIKE '410%' OR co.condition_source_value LIKE '411%' OR co.condition_source_value = '412'
            )
    )
    AND NOT EXISTS (
        SELECT 1
        FROM `victr_sd`.`sd_omop_prod`.`procedure_occurrence` po
        WHERE po.person_id = aos.person_id
            AND po.procedure_date < aos.event_date
            AND po.procedure_source_value IN (
                '33533', '33534', '33535', '33536', '33510', '33511', '33512', '33513',
                '33514', '33515', '33516', '33517', '33518', '33519', '33520', '33521',
                '33522', '33523',
                '92980', '92981', '92982', '92984', '92995', '92996',
                'C1874', 'C1875', 'C1876', 'C1877'
            )
    )
),

revasc_on_statins AS (
    SELECT DISTINCT po.person_id, po.procedure_date as event_date
    FROM `victr_sd`.`sd_omop_prod`.`procedure_occurrence` po
    WHERE po.procedure_source_value IN (
        '33533', '33534', '33535', '33536', '33510', '33511', '33512', '33513',
        '33514', '33515', '33516', '33517', '33518', '33519', '33520', '33521',
        '33522', '33523',
        '92980', '92981', '92982', '92984', '92995', '92996',
        'C1874', 'C1875', 'C1876', 'C1877'
    )
    AND EXISTS (
        SELECT 1
        FROM `victr_sd`.`sd_omop_prod`.`drug_exposure` de
        INNER JOIN `victr_sd`.`sd_omop_prod`.`concept_ancestor` ca ON de.drug_concept_id = ca.descendant_concept_id
        INNER JOIN `victr_sd`.`sd_omop_prod`.`concept` c2 ON ca.ancestor_concept_id = c2.concept_id
        WHERE de.person_id = po.person_id
            AND DATE_ADD(de.drug_exposure_start_date, 180) <= po.procedure_date
            AND c2.concept_id = 1539403
            AND c2.concept_class_id = 'Ingredient'
    )
),

first_revasc_on_statins AS (
    SELECT ros.person_id, ros.event_date
    FROM revasc_on_statins ros
    WHERE NOT EXISTS (
        SELECT 1
        FROM `victr_sd`.`sd_omop_prod`.`condition_occurrence` co
        WHERE co.person_id = ros.person_id
            AND co.condition_start_date < ros.event_date
            AND (
                co.condition_source_value LIKE '410%' OR co.condition_source_value LIKE '411%' OR co.condition_source_value = '412'
            )
    )
    AND NOT EXISTS (
        SELECT 1
        FROM `victr_sd`.`sd_omop_prod`.`procedure_occurrence` po
        WHERE po.person_id = ros.person_id
            AND po.procedure_date < ros.event_date
            AND po.procedure_source_value IN (
                '33533', '33534', '33535', '33536', '33510', '33511', '33512', '33513',
                '33514', '33515', '33516', '33517', '33518', '33519', '33520', '33521',
                '33522', '33523',
                '92980', '92981', '92982', '92984', '92995', '92996',
                'C1874', 'C1875', 'C1876', 'C1877'
            )
    )
),

controls AS (
    SELECT DISTINCT de.person_id
    FROM `victr_sd`.`sd_omop_prod`.`drug_exposure` de
    INNER JOIN `victr_sd`.`sd_omop_prod`.`concept_ancestor` ca ON de.drug_concept_id = ca.descendant_concept_id
    INNER JOIN `victr_sd`.`sd_omop_prod`.`concept` c ON ca.ancestor_concept_id = c.concept_id
    WHERE c.concept_id = 1539403
        AND c.concept_class_id = 'Ingredient'
        AND NOT EXISTS (
            SELECT 1
            FROM `victr_sd`.`sd_omop_prod`.`condition_occurrence` co
            WHERE co.person_id = de.person_id
                AND (
                    co.condition_source_value LIKE '410%' OR co.condition_source_value LIKE '411%' OR co.condition_source_value = '412'
                )
        )
        AND NOT EXISTS (
            SELECT 1
            FROM `victr_sd`.`sd_omop_prod`.`procedure_occurrence` po
            WHERE po.person_id = de.person_id
                AND po.procedure_source_value IN (
                    '33533', '33534', '33535', '33536', '33510', '33511', '33512', '33513',
                    '33514', '33515', '33516', '33517', '33518', '33519', '33520', '33521',
                    '33522', '33523',
                    '92980', '92981', '92982', '92984', '92995', '92996',
                    'C1874', 'C1875', 'C1876', 'C1877'
                )
        )
)

SELECT person_id, 'AMI_on_statins' as cohort_type, event_date, 1 as is_case, 0 as is_first_event
FROM ami_on_statins_final
UNION ALL
SELECT person_id, '1st_AMI_on_statins' as cohort_type, event_date, 1 as is_case, 1 as is_first_event
FROM first_ami_on_statins
UNION ALL
SELECT person_id, 'Revascularization_on_statins' as cohort_type, event_date, 1 as is_case, 0 as is_first_event
FROM revasc_on_statins
UNION ALL
SELECT person_id, '1st_Revascularization_on_statins' as cohort_type, event_date, 1 as is_case, 1 as is_first_event
FROM first_revasc_on_statins
UNION ALL
SELECT person_id, 'Control' as cohort_type, NULL as event_date, 0 as is_case, NULL as is_first_event
FROM controls
ORDER BY cohort_type, person_id, event_date;