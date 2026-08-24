-- Rule 1 (VUMC-specific database name): APPLIED (qualified OMOP tables with `victr_sd`.`sd_omop_prod`)
-- Rule 2 (fix incorrect wildcard characters): NOT APPLICABLE
-- Rule 3 (replace Concept table searching with standardized clinical data tables): APPLIED (removed Concept-table code-set derivation for conditions/procedures/observations; filtered directly on OMOP clinical tables)
-- Rule 4 (standard codes use exact equality/IN; measurement/drug handling specifics): APPLIED (measurements use `concept` join with exact LOINC `concept_code`; conditions/procedures/observations use exact `IN`)
-- Rule 5 (free-text descriptive fields use LOWER LIKE): NOT APPLICABLE
-- Rule 6 (replace OR with UNION across tables): NOT APPLICABLE
-- Rule 7 (replace LEFT JOIN + OR combinations with UNION): NOT APPLICABLE
-- Rule 8 (remove unclear NLP/free-text logic): NOT APPLICABLE
-- Rule 9 (mark missing/undefined/ambiguous concept codes inline): NOT APPLICABLE
-- FIX: replaced timeout-prone correlated baseline subqueries with pre-aggregated self-join CTEs keyed to each measurement row
-- FIX: restricted visit-level classification to visits with creatinine data or ESRD exclusions instead of scanning all visits
-- FIX: replaced non-Spark `DATEADD(day, n, date)` with Spark `date_add(date, n)`
-- FIX: replaced non-Spark `DATEDIFF(day, start, end)` with Spark `datediff(end, start)`
-- FIX: replaced non-Spark ordered-set `PERCENTILE_CONT` with Spark `percentile_approx`
-- FIX: replaced non-Spark `DATEDIFF(hour, ...)` with hour calculation from `unix_timestamp`

CREATE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex1_all_content_LLM2_AKI AS 

WITH 
-- -----------------------------------------------------
-- STEP 1: IDENTIFY ESRD EXCLUSIONS
-- Patients with kidney transplant or dialysis before/during visit
-- -----------------------------------------------------
esrd_exclusions AS (
    SELECT DISTINCT `person_id`, `visit_occurrence_id`
    FROM (
        SELECT co.`person_id`, co.`visit_occurrence_id`
        -- REVISED (was: FROM condition_occurrence co)
        FROM `victr_sd`.`sd_omop_prod`.`condition_occurrence` co
        WHERE co.`condition_concept_id` IN (
            45552870, 45577822, 45575617, 45609389, 45590127, 45575620,
            45604584, 35224814, 1576113, 1576114, 45609945, 45585835,
            1576115, 45556841, 45566436, 45561671, 35225436,
            44830102, 44837448, 44826028, 44830633, 44824846, 44828407,
            44831843, 44836535, 44835472, 44831947, 44834280, 44822716,
            44829649, 44829650, 44833130, 44833131, 44835496, 44835497,
            44821578,
            1575308, 45546763, 45609393, 45599829, 45575625, 45537090,
            45595522, 35225404,
            44836487, 44821546
        )
        -- REVISED (was: WHERE co.`condition_source_value` IN (SELECT ccs.`concept_code` FROM condition_code_sets ccs ...))
        AND co.`person_id` IS NOT NULL AND co.`visit_occurrence_id` IS NOT NULL

        UNION

        SELECT po.`person_id`, po.`visit_occurrence_id`
        FROM `victr_sd`.`sd_omop_prod`.`procedure_occurrence` po
        WHERE po.`procedure_concept_id` IN (
            2101833, 2101834, 2106278, 42736574, 2108276, 2108277,
            2108297, 2108299, 2108302, 42628575, 42627979, 42628018,
            42628576, 42628058, 42628580, 2108564, 2108566, 2108567,
            2108568, 2109463, 2213572, 2213573, 2213575, 2213576,
            2213577, 2213578, 2213579, 2213580, 2213581, 2213582,
            2213583, 2213584, 2213585, 2213586, 2213587, 2213588,
            2213589, 2213590, 2213591, 2213592, 2213593, 2213594,
            2213595, 2213596, 2213597, 2213601, 2313999,
            2786488,
            2002176, 2002189, 2002208, 2002209, 2002282, 2003564,
            2109586, 2109587, 2109589,
            2774517, 2774518, 2774519, 2774520, 2774521, 2774522,
            2003622, 2003624, 2003625, 2003626
        )
        -- REVISED (was: WHERE po.`procedure_source_value` IN (SELECT pcs.`concept_code` FROM procedure_code_sets pcs ...))
        AND po.`person_id` IS NOT NULL AND po.`visit_occurrence_id` IS NOT NULL

        UNION

        SELECT o.`person_id`, o.`visit_occurrence_id`
        FROM `victr_sd`.`sd_omop_prod`.`observation` o
        WHERE o.`observation_concept_id` IN (
            2101833, 2101834, 2106278, 2108564, 2108566, 2108567, 2108568,
            2213578, 2213579, 2213580, 2213581, 2213582, 2213583, 2213584,
            2213585, 2213586, 2213587, 2213588, 2213589, 2213590, 2213591,
            2213592, 2213593, 2213594, 2213595, 2213596, 2213597
        )
        -- REVISED (was: INNER JOIN `victr_sd`.`sd_omop_prod`.`concept` oc ON o.`observation_concept_id` = oc.`concept_id` | WHERE oc.`concept_code` IN ( SELECT ocs.`concept_code` FROM observation_code_sets ocs ))
        AND o.`person_id` IS NOT NULL AND o.`visit_occurrence_id` IS NOT NULL
    ) esrd_all
),

-- -----------------------------------------------------
-- STEP 2: EXTRACT ALL SERUM CREATININE MEASUREMENTS
-- -----------------------------------------------------
scr_measurements AS (
    SELECT 
        m.`person_id`,
        m.`visit_occurrence_id`,
        m.`measurement_date`,
        m.`measurement_datetime`,
        m.`value_as_number` AS `scr_value`,
        v.`visit_start_date`,
        v.`visit_end_date`
    -- REVISED (was: FROM measurement m)
    FROM `victr_sd`.`sd_omop_prod`.`measurement` m
    INNER JOIN `victr_sd`.`sd_omop_prod`.`visit_occurrence` v
        ON m.`visit_occurrence_id` = v.`visit_occurrence_id`
    INNER JOIN `victr_sd`.`sd_omop_prod`.`concept` c
        ON m.`measurement_concept_id` = c.`concept_id`
    WHERE c.`vocabulary_id` = 'LOINC'
      AND c.`concept_code` IN (
          '11041-1','11042-9','14682-9','2160-0','35203-9','40248-7','40264-4',
          '54052-6','57811-2','67764-1','72271-0','74256-9','77140-2'
      )
    -- REVISED (was: WHERE m.measurement_concept_id IN ( 3018968, 3022243, 3020564, 3016723, 3032033, 3041716, 3041735, 3050951, 40760920, 40770372, 43055236, 44786911, 46235076 ))
    AND m.`value_as_number` IS NOT NULL
    AND m.`value_as_number` > 0
    AND m.`person_id` IS NOT NULL
    AND m.`visit_occurrence_id` IS NOT NULL
    AND m.`measurement_date` IS NOT NULL
),

-- -----------------------------------------------------
-- STEP 3: CALCULATE BASELINE SCR FOR EACH MEASUREMENT
-- -----------------------------------------------------
baseline_priority_1 AS (
    SELECT
        s.`person_id`,
        s.`visit_occurrence_id`,
        s.`measurement_date`,
        s.`measurement_datetime`,
        s.`scr_value`,
        s.`visit_start_date`,
        percentile_approx(b1.`scr_value`, 0.5) AS `baseline_priority_1`
    -- REVISED (was: correlated subquery using PERCENTILE_CONT over scr_measurements b1 for each row)
    FROM scr_measurements s
    LEFT JOIN scr_measurements b1
        ON b1.`person_id` = s.`person_id`
       AND b1.`measurement_date` > date_add(s.`visit_start_date`, -365)
       AND b1.`measurement_date` <= date_add(s.`visit_start_date`, -7)
    -- REVISED (was: DATEADD(day, -365, s.visit_start_date) | DATEADD(day, -7, s.visit_start_date))
    GROUP BY
        s.`person_id`, s.`visit_occurrence_id`, s.`measurement_date`, s.`measurement_datetime`,
        s.`scr_value`, s.`visit_start_date`
),

baseline_priority_2 AS (
    SELECT
        s.`person_id`,
        s.`visit_occurrence_id`,
        s.`measurement_date`,
        s.`measurement_datetime`,
        s.`scr_value`,
        s.`visit_start_date`,
        MIN(b2.`scr_value`) AS `baseline_priority_2`
    -- REVISED (was: correlated subquery selecting MIN(b2.scr_value) for each row)
    FROM scr_measurements s
    LEFT JOIN scr_measurements b2
        ON b2.`person_id` = s.`person_id`
       AND b2.`measurement_date` > date_add(s.`visit_start_date`, -7)
       AND b2.`measurement_date` <= s.`visit_start_date`
    -- REVISED (was: DATEADD(day, -7, s.visit_start_date))
    GROUP BY
        s.`person_id`, s.`visit_occurrence_id`, s.`measurement_date`, s.`measurement_datetime`,
        s.`scr_value`, s.`visit_start_date`
),

baseline_priority_3 AS (
    SELECT
        s.`person_id`,
        s.`visit_occurrence_id`,
        s.`measurement_date`,
        s.`measurement_datetime`,
        s.`scr_value`,
        s.`visit_start_date`,
        MIN(b3.`scr_value`) AS `baseline_priority_3`
    -- REVISED (was: correlated subquery selecting MIN(b3.scr_value) for each row)
    FROM scr_measurements s
    LEFT JOIN scr_measurements b3
        ON b3.`person_id` = s.`person_id`
       AND b3.`visit_occurrence_id` = s.`visit_occurrence_id`
       AND b3.`measurement_date` >= s.`visit_start_date`
       AND b3.`measurement_date` <= s.`measurement_date`
    GROUP BY
        s.`person_id`, s.`visit_occurrence_id`, s.`measurement_date`, s.`measurement_datetime`,
        s.`scr_value`, s.`visit_start_date`
),

baseline_scr_calculation AS (
    SELECT 
        s.`person_id`,
        s.`visit_occurrence_id`,
        s.`measurement_date`,
        s.`measurement_datetime`,
        s.`scr_value`,
        s.`visit_start_date`,
        p1.`baseline_priority_1`,
        p2.`baseline_priority_2`,
        p3.`baseline_priority_3`
    FROM scr_measurements s
    LEFT JOIN baseline_priority_1 p1
        ON s.`person_id` = p1.`person_id`
       AND s.`visit_occurrence_id` = p1.`visit_occurrence_id`
       AND s.`measurement_date` = p1.`measurement_date`
       AND s.`measurement_datetime` <=> p1.`measurement_datetime`
       AND s.`scr_value` = p1.`scr_value`
       AND s.`visit_start_date` = p1.`visit_start_date`
    LEFT JOIN baseline_priority_2 p2
        ON s.`person_id` = p2.`person_id`
       AND s.`visit_occurrence_id` = p2.`visit_occurrence_id`
       AND s.`measurement_date` = p2.`measurement_date`
       AND s.`measurement_datetime` <=> p2.`measurement_datetime`
       AND s.`scr_value` = p2.`scr_value`
       AND s.`visit_start_date` = p2.`visit_start_date`
    LEFT JOIN baseline_priority_3 p3
        ON s.`person_id` = p3.`person_id`
       AND s.`visit_occurrence_id` = p3.`visit_occurrence_id`
       AND s.`measurement_date` = p3.`measurement_date`
       AND s.`measurement_datetime` <=> p3.`measurement_datetime`
       AND s.`scr_value` = p3.`scr_value`
       AND s.`visit_start_date` = p3.`visit_start_date`
),

baseline_scr AS (
    SELECT 
        `person_id`,
        `visit_occurrence_id`,
        `measurement_date`,
        `measurement_datetime`,
        `scr_value`,
        `visit_start_date`,
        COALESCE(`baseline_priority_1`, `baseline_priority_2`, `baseline_priority_3`) AS `baseline_scr`
    FROM baseline_scr_calculation
),

-- -----------------------------------------------------
-- STEP 4: CALCULATE DAILY KIDNEY FUNCTION
-- -----------------------------------------------------
daily_scr AS (
    SELECT 
        `person_id`,
        `visit_occurrence_id`,
        `measurement_date`,
        AVG(`scr_value`) AS `daily_avg_scr`,
        AVG(`baseline_scr`) AS `baseline_scr`
    FROM baseline_scr
    WHERE `baseline_scr` IS NOT NULL
    GROUP BY `person_id`, `visit_occurrence_id`, `measurement_date`
),

daily_kidney_function AS (
    SELECT 
        `person_id`,
        `visit_occurrence_id`,
        `measurement_date`,
        `daily_avg_scr`,
        `baseline_scr`,
        try_divide(`daily_avg_scr`, `baseline_scr`) AS `scr_ratio`,
        CASE 
            WHEN try_divide(`daily_avg_scr`, `baseline_scr`) >= 1.5 THEN 1
            ELSE 0
        END AS `aki_flag`
    FROM daily_scr
),

-- -----------------------------------------------------
-- STEP 5: IDENTIFY AKI BLOCKS
-- -----------------------------------------------------
aki_days_with_gaps AS (
    SELECT 
        `person_id`,
        `visit_occurrence_id`,
        `measurement_date`,
        `scr_ratio`,
        `aki_flag`,
        LAG(`measurement_date`) OVER (
            PARTITION BY `person_id`, `visit_occurrence_id` 
            ORDER BY `measurement_date`
        ) AS `prev_date`
    FROM daily_kidney_function
    WHERE `aki_flag` = 1
),

aki_blocks AS (
    SELECT 
        `person_id`,
        `visit_occurrence_id`,
        `measurement_date`,
        `scr_ratio`,
        SUM(CASE 
            WHEN `prev_date` IS NULL 
                 OR datediff(`measurement_date`, `prev_date`) > 2 
            THEN 1 
            ELSE 0 
        END) OVER (
            PARTITION BY `person_id`, `visit_occurrence_id` 
            ORDER BY `measurement_date`
        ) AS `block_number`
        -- REVISED (was: OR DATEDIFF(day, prev_date, measurement_date) > 2)
    FROM aki_days_with_gaps
),

-- -----------------------------------------------------
-- STEP 6: CHARACTERIZE EACH AKI BLOCK
-- -----------------------------------------------------
aki_block_characteristics AS (
    SELECT 
        `person_id`,
        `visit_occurrence_id`,
        `block_number`,
        MIN(`measurement_date`) AS `block_start_date`,
        MAX(`measurement_date`) AS `block_end_date`,
        COUNT(DISTINCT `measurement_date`) AS `block_duration_days`,
        MAX(`scr_ratio`) AS `max_block_scr_ratio`,
        CASE 
            WHEN MAX(`scr_ratio`) >= 3.0 THEN 3
            WHEN MAX(`scr_ratio`) >= 2.0 THEN 2
            WHEN MAX(`scr_ratio`) >= 1.5 THEN 1
        END AS `akin_stage`,
        CASE
            WHEN COUNT(DISTINCT `measurement_date`) > 2 
                 OR try_divide((unix_timestamp(CAST(MAX(`measurement_date`) AS TIMESTAMP)) - unix_timestamp(CAST(MIN(`measurement_date`) AS TIMESTAMP))),3600.0) > 48 
            THEN 'sAKI'
            ELSE 'tAKI'
        END AS `aki_subtype`
        -- REVISED (was: OR DATEDIFF(hour, MIN(measurement_date), MAX(measurement_date)) > 48)
    FROM aki_blocks
    GROUP BY `person_id`, `visit_occurrence_id`, `block_number`
),

visit_scope AS (
    SELECT DISTINCT `person_id`, `visit_occurrence_id`
    FROM scr_measurements
    UNION
    SELECT DISTINCT `person_id`, `visit_occurrence_id`
    FROM esrd_exclusions
),

-- -----------------------------------------------------
-- STEP 7: DETERMINE AKI STATUS FOR EACH VISIT
-- -----------------------------------------------------
visit_aki_status AS (
    SELECT 
        v.`person_id`,
        v.`visit_occurrence_id`,
        v.`visit_start_date`,
        v.`visit_end_date`,
        CASE 
            WHEN e.`person_id` IS NOT NULL THEN 'ESRD'
            WHEN b.`baseline_count` = 0 OR b.`baseline_count` IS NULL THEN 'AKI_UNKNOWN'
            WHEN d.`max_aki_flag` = 1 THEN 'AKI'
            ELSE 'NO_AKI'
        END AS `aki_status`
    FROM visit_scope vs
    INNER JOIN `victr_sd`.`sd_omop_prod`.`visit_occurrence` v
        ON vs.`person_id` = v.`person_id`
       AND vs.`visit_occurrence_id` = v.`visit_occurrence_id`
    -- REVISED (was: FROM `victr_sd`.`sd_omop_prod`.`visit_occurrence` v)
    LEFT JOIN esrd_exclusions e 
        ON v.`person_id` = e.`person_id` 
        AND v.`visit_occurrence_id` = e.`visit_occurrence_id`
    LEFT JOIN (
        SELECT `person_id`, `visit_occurrence_id`, COUNT(*) AS `baseline_count`
        FROM baseline_scr
        WHERE `baseline_scr` IS NOT NULL
        GROUP BY `person_id`, `visit_occurrence_id`
    ) b ON v.`person_id` = b.`person_id` 
        AND v.`visit_occurrence_id` = b.`visit_occurrence_id`
    LEFT JOIN (
        SELECT `person_id`, `visit_occurrence_id`, MAX(`aki_flag`) AS `max_aki_flag`
        FROM daily_kidney_function
        GROUP BY `person_id`, `visit_occurrence_id`
    ) d ON v.`person_id` = d.`person_id` 
        AND v.`visit_occurrence_id` = d.`visit_occurrence_id`
),

-- -----------------------------------------------------
-- STEP 8: COMPILE FINAL AKI PHENOTYPE
-- -----------------------------------------------------
aki_phenotype AS (
    SELECT 
        vas.`person_id`,
        vas.`visit_occurrence_id`,
        vas.`visit_start_date`,
        vas.`visit_end_date`,
        vas.`aki_status`,
        first_block.`akin_stage`,
        first_block.`aki_subtype`,
        COALESCE(block_count.`total_blocks`, 0) AS `aki_recurrence_count`,
        CASE
            WHEN vas.`aki_status` = 'AKI' THEN 'CASE'
            WHEN vas.`aki_status` = 'NO_AKI' THEN 'CONTROL'
            WHEN vas.`aki_status` = 'ESRD' THEN 'EXCLUDED_ESRD'
            WHEN vas.`aki_status` = 'AKI_UNKNOWN' THEN 'EXCLUDED_INSUFFICIENT_DATA'
        END AS `phenotype_label`
    FROM visit_aki_status vas
    LEFT JOIN (
        SELECT `person_id`, `visit_occurrence_id`, `akin_stage`, `aki_subtype`
        FROM aki_block_characteristics
        WHERE `block_number` = 1
    ) first_block 
        ON vas.`person_id` = first_block.`person_id` 
        AND vas.`visit_occurrence_id` = first_block.`visit_occurrence_id`
    LEFT JOIN (
        SELECT `person_id`, `visit_occurrence_id`, COUNT(DISTINCT `block_number`) AS `total_blocks`
        FROM aki_block_characteristics
        GROUP BY `person_id`, `visit_occurrence_id`
    ) block_count
        ON vas.`person_id` = block_count.`person_id` 
        AND vas.`visit_occurrence_id` = block_count.`visit_occurrence_id`
)

SELECT 
    `person_id`,
    `visit_occurrence_id`,
    `visit_start_date`,
    `visit_end_date`,
    `aki_status`,
    CASE 
        WHEN `akin_stage` = 1 THEN 'AKIN Stage 1 (1.5-2x baseline)'
        WHEN `akin_stage` = 2 THEN 'AKIN Stage 2 (2-3x baseline)'
        WHEN `akin_stage` = 3 THEN 'AKIN Stage 3 (>3x baseline)'
        ELSE NULL
    END AS `akin_stage_description`,
    CASE
        WHEN `aki_subtype` = 'tAKI' THEN 'Transient AKI (<=48 hours)'
        WHEN `aki_subtype` = 'sAKI' THEN 'Sustained AKI (>48 hours)'
        ELSE NULL
    END AS `aki_subtype_description`,
    `aki_recurrence_count`,
    `phenotype_label`
FROM aki_phenotype
WHERE `phenotype_label` IN ('CASE', 'CONTROL')
ORDER BY `person_id`, `visit_occurrence_id`