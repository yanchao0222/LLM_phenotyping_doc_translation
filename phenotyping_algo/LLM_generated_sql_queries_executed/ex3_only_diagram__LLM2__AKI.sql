-- Rule 1 (VUMC-specific database name): APPLIED
-- Rule 4 (LOINC for SCr): APPLIED
-- Rule 5 (concept_name free-text LIKE): APPLIED
-- Rule 6 (OR -> UNION for multi-table concept search): APPLIED
-- Rule 7 (LEFT JOIN with OR -> UNION): APPLIED
-- Rules 2, 3, 8, 9: NOT APPLICABLE
-- FIX: Replaced (MAX(ab.measurement_date) - MIN(ab.measurement_date)) <= 4 with DATEDIFF(MAX(ab.measurement_date), MIN(ab.measurement_date)) <= 4 for correct date difference calculation in Databricks SQL
-- FIX: Removed trailing semicolon after ORDER BY to avoid syntax error in Databricks SQL

CREATE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex3_only_diagram_LLM2_AKI AS 

WITH presentation_window AS (
    SELECT 
        DATE '2020-01-01' AS study_start_date,
        DATE '2023-12-31' AS study_end_date
),

all_patients AS (
    SELECT DISTINCT
        vo.person_id,
        MIN(vo.visit_start_date) AS presentation_start_date,
        MAX(COALESCE(vo.visit_end_date, vo.visit_start_date)) AS presentation_end_date
    FROM 
        -- REVISED (was: visit_occurrence vo)
        victr_sd.sd_omop_prod.visit_occurrence vo
    CROSS JOIN 
        presentation_window pw
    WHERE 
        vo.visit_start_date >= pw.study_start_date
        AND vo.visit_start_date <= pw.study_end_date
    GROUP BY 
        vo.person_id
),

-- ESRD exclusions: UNION for multi-table concept search (Rule 6/7)
esrd_exclusions AS (
    -- Kidney transplant from conditions
    SELECT DISTINCT 
        co.person_id
    FROM 
        victr_sd.sd_omop_prod.condition_occurrence co
    INNER JOIN 
        all_patients ap ON co.person_id = ap.person_id
    INNER JOIN
        -- REVISED (was: concept c)
        victr_sd.sd_omop_prod.concept c ON co.condition_concept_id = c.concept_id
    WHERE 
        (
            co.condition_concept_id IN (42539502,4340306,4239233,4322471)
            -- REVISED (was: OR LOWER(c.concept_name) LIKE '%kidney transplant%' OR LOWER(c.concept_name) LIKE '%renal transplant%')
            OR LOWER(c.concept_name) LIKE '%kidney transplant%' OR LOWER(c.concept_name) LIKE '%renal transplant%'
        )
        AND co.condition_start_date < ap.presentation_start_date
    
    UNION
    
    -- Kidney transplant from procedures
    SELECT DISTINCT 
        po.person_id
    FROM 
        victr_sd.sd_omop_prod.procedure_occurrence po
    INNER JOIN 
        all_patients ap ON po.person_id = ap.person_id
    INNER JOIN
        victr_sd.sd_omop_prod.concept c ON po.procedure_concept_id = c.concept_id
    WHERE 
        (
            po.procedure_concept_id IN (4146256,4322471,4021780,4180347)
            OR LOWER(c.concept_name) LIKE '%kidney transplant%' OR LOWER(c.concept_name) LIKE '%renal transplant%'
        )
        AND po.procedure_date < ap.presentation_start_date
    
    UNION
    
    -- Dialysis procedures
    SELECT DISTINCT 
        po.person_id
    FROM 
        victr_sd.sd_omop_prod.procedure_occurrence po
    INNER JOIN 
        all_patients ap ON po.person_id = ap.person_id
    INNER JOIN
        victr_sd.sd_omop_prod.concept c ON po.procedure_concept_id = c.concept_id
    WHERE 
        (
            po.procedure_concept_id IN (4027133,4032640,4019829,4353741,4031139)
            OR LOWER(c.concept_name) LIKE '%dialysis%'
        )
        AND po.procedure_date < ap.presentation_start_date
),

eligible_patients AS (
    SELECT 
        ap.person_id,
        ap.presentation_start_date,
        ap.presentation_end_date
    FROM 
        all_patients ap
    WHERE 
        ap.person_id NOT IN (SELECT person_id FROM esrd_exclusions)
),

-- SCr measurements: join to concept for LOINC (Rule 4)
scr_measurements AS (
    SELECT 
        ep.person_id,
        ep.presentation_start_date,
        ep.presentation_end_date,
        m.measurement_date,
        m.value_as_number AS scr_value
    FROM 
        eligible_patients ep
    INNER JOIN 
        victr_sd.sd_omop_prod.measurement m ON ep.person_id = m.person_id
    INNER JOIN
        -- REVISED (was: m.measurement_concept_id IN (...))
        victr_sd.sd_omop_prod.concept c ON m.measurement_concept_id = c.concept_id
    WHERE 
        c.vocabulary_id = 'LOINC'
        AND c.concept_code IN ('3016723','3051825','37071652','3020564')
        AND m.value_as_number IS NOT NULL
        AND m.value_as_number > 0
        AND m.value_as_number < 30
),

baseline_scr AS (
    SELECT 
        ep.person_id,
        ep.presentation_start_date,
        ep.presentation_end_date,
        COALESCE(
            (
                SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY scr_value)
                FROM scr_measurements sm1
                WHERE sm1.person_id = ep.person_id
                AND sm1.measurement_date > (ep.presentation_start_date - INTERVAL 365 DAYS)
                AND sm1.measurement_date <= (ep.presentation_start_date - INTERVAL 7 DAYS)
            ),
            (
                SELECT MIN(scr_value)
                FROM scr_measurements sm2
                WHERE sm2.person_id = ep.person_id
                AND sm2.measurement_date > (ep.presentation_start_date - INTERVAL 7 DAYS)
                AND sm2.measurement_date <= ep.presentation_start_date
            ),
            (
                SELECT MIN(scr_value)
                FROM scr_measurements sm3
                WHERE sm3.person_id = ep.person_id
                AND sm3.measurement_date >= ep.presentation_start_date
                AND sm3.measurement_date <= ep.presentation_end_date
            )
        ) AS baseline_scr_value
    FROM 
        eligible_patients ep
),

daily_kidney_function AS (
    SELECT 
        sm.person_id,
        sm.measurement_date,
        sm.scr_value,
        bs.baseline_scr_value,
        CASE 
            WHEN bs.baseline_scr_value IS NULL THEN NULL
            WHEN bs.baseline_scr_value = 0 THEN NULL
            ELSE try_divide(sm.scr_value,bs.baseline_scr_value) 
        END AS scr_ratio
    FROM 
        scr_measurements sm
    INNER JOIN 
        baseline_scr bs ON sm.person_id = bs.person_id 
        AND sm.presentation_start_date = bs.presentation_start_date
),

patient_aki_status_initial AS (
    SELECT 
        ep.person_id,
        CASE 
            WHEN bs.baseline_scr_value IS NULL THEN 'Unknown'
            WHEN EXISTS (
                SELECT 1 
                FROM daily_kidney_function dkf
                WHERE dkf.person_id = ep.person_id
                AND dkf.scr_ratio >= 1.5
            ) THEN 'AKI'
            ELSE 'No AKI'
        END AS aki_status
    FROM 
        eligible_patients ep
    LEFT JOIN 
        baseline_scr bs ON ep.person_id = bs.person_id
),

aki_days_with_gaps AS (
    SELECT 
        person_id,
        measurement_date,
        scr_value,
        baseline_scr_value,
        scr_ratio,
        CASE 
            WHEN scr_ratio >= 1.5 AND (
                LAG(scr_ratio, 1) OVER (PARTITION BY person_id ORDER BY measurement_date) < 1.5
                OR LAG(measurement_date, 1) OVER (PARTITION BY person_id ORDER BY measurement_date) < (measurement_date - INTERVAL 2 DAYS)
                OR LAG(scr_ratio, 1) OVER (PARTITION BY person_id ORDER BY measurement_date) IS NULL
            ) THEN 1
            ELSE 0
        END AS new_block_flag
    FROM 
        daily_kidney_function
    WHERE 
        scr_ratio IS NOT NULL
),

aki_blocks AS (
    SELECT 
        person_id,
        measurement_date,
        scr_value,
        baseline_scr_value,
        scr_ratio,
        SUM(new_block_flag) OVER (PARTITION BY person_id ORDER BY measurement_date) AS block_id
    FROM 
        aki_days_with_gaps
    WHERE 
        scr_ratio >= 1.5
),

aki_staging AS (
    SELECT 
        person_id,
        block_id,
        MIN(measurement_date) AS block_start_date,
        MAX(measurement_date) AS block_end_date,
        COUNT(*) AS measurements_in_block,
        MAX(scr_ratio) AS max_block_scr_ratio,
        MAX(scr_value) AS max_scr_value,
        MIN(baseline_scr_value) AS baseline_scr_value,
        CASE 
            WHEN MAX(scr_ratio) >= 3 THEN 3
            WHEN MAX(scr_ratio) >= 2 THEN 2
            WHEN MAX(scr_ratio) >= 1.5 THEN 1
        END AS aki_stage
    FROM 
        aki_blocks
    GROUP BY 
        person_id, block_id
),

aki_subtype_determination AS (
    SELECT 
        ab.person_id,
        ab.block_id,
        s.aki_stage,
        s.block_start_date,
        s.block_end_date,
        s.max_block_scr_ratio,
        s.baseline_scr_value,
        COUNT(DISTINCT ab.measurement_date) AS distinct_days,
        -- REVISED (was: (MAX(ab.measurement_date) - MIN(ab.measurement_date)) <= 4)
        CASE
            WHEN COUNT(DISTINCT ab.measurement_date) >= 3 
                AND DATEDIFF(MAX(ab.measurement_date), MIN(ab.measurement_date)) <= 4
            THEN 'sAKI'
            ELSE 'tAKI'
        END AS aki_subtype
    FROM 
        aki_blocks ab
    INNER JOIN 
        aki_staging s ON ab.person_id = s.person_id AND ab.block_id = s.block_id
    GROUP BY 
        ab.person_id, ab.block_id, s.aki_stage, s.block_start_date, 
        s.block_end_date, s.max_block_scr_ratio, s.baseline_scr_value
)

SELECT 
    p.person_id,
    p.gender_concept_id,
    EXTRACT(YEAR FROM ep.presentation_start_date) - p.year_of_birth AS age_at_presentation,
    ep.presentation_start_date,
    ep.presentation_end_date,
    pas.aki_status AS phenotype_status,
    CASE 
        WHEN pas.aki_status = 'Unknown' THEN 'Excluded - Insufficient Data'
        WHEN pas.aki_status = 'AKI' THEN 'Case'
        WHEN pas.aki_status = 'No AKI' THEN 'Control'
    END AS phenotype_category,
    ast.block_id AS aki_block_number,
    ast.block_start_date AS aki_block_start,
    ast.block_end_date AS aki_block_end,
    ast.aki_stage,
    ast.aki_subtype,
    ast.max_block_scr_ratio,
    ast.baseline_scr_value,
    CASE 
        WHEN pas.aki_status = 'AKI' THEN 
            (SELECT COUNT(DISTINCT block_id) FROM aki_subtype_determination WHERE person_id = p.person_id)
        ELSE NULL
    END AS total_aki_blocks,
    CASE 
        WHEN pas.aki_status = 'AKI' THEN 
            (SELECT MAX(aki_stage) FROM aki_subtype_determination WHERE person_id = p.person_id)
        ELSE NULL
    END AS max_aki_stage
FROM 
    eligible_patients ep
INNER JOIN 
    victr_sd.sd_omop_prod.person p ON ep.person_id = p.person_id
INNER JOIN 
    patient_aki_status_initial pas ON ep.person_id = pas.person_id
LEFT JOIN 
    aki_subtype_determination ast ON ep.person_id = ast.person_id
ORDER BY 
    phenotype_category,
    p.person_id,
    aki_block_number