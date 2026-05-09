-- ============================================================================
-- EXECUTABLE SQL QUERY FOR FAMILIAL HYPERCHOLESTEROLEMIA (FH) PHENOTYPING
-- Mayo Clinic Algorithm for Identification of FH from EHR
-- OMOP CDM Compatible Version - Final Executable Query
-- ============================================================================
-- This query identifies FH cases and controls using a two-stage algorithm:
-- Stage I: Identifies primary hypercholesterolemia (excludes secondary causes)
-- Stage II: Applies scoring system to classify FH cases
-- Output: person_id with case (1), control (0), or unknown (NULL) status
-- ============================================================================

WITH eligible_population AS (
    -- Identify adults >= 18 years old with at least one lipid profile measurement
    SELECT DISTINCT 
        m.person_id,
        m.measurement_date,
        YEAR(m.measurement_date) - p.year_of_birth AS age_at_measurement
    FROM measurement m
    INNER JOIN person p ON m.person_id = p.person_id
    WHERE YEAR(m.measurement_date) - p.year_of_birth >= 18
    AND m.measurement_concept_id IN (
        -- LDL-C measurement concept IDs
        3936423,  -- LDL Cholesterol [Mass/volume] in Serum or Plasma
        3935643,  -- LDL Cholesterol [Mass/volume] in Serum or Plasma by calculation
        -- Triglycerides measurement concept ID
        3022192   -- Triglycerides [Mass/volume] in Serum or Plasma
    )
),

ldl_tg_measurements AS (
    -- Extract all LDL-C and TG measurements with values in mg/dL
    SELECT 
        m.person_id,
        m.measurement_date,
        m.measurement_concept_id,
        m.value_as_number,
        CASE 
            WHEN m.measurement_concept_id IN (3936423, 3935643) THEN 'LDL'
            WHEN m.measurement_concept_id = 3022192 THEN 'TG'
        END AS measurement_type
    FROM measurement m
    INNER JOIN eligible_population ep ON m.person_id = ep.person_id
    WHERE m.measurement_concept_id IN (3936423, 3935643, 3022192)
    AND m.value_as_number IS NOT NULL
    AND m.unit_concept_id = 8840  -- mg/dL
),

high_triglycerides_exclusion AS (
    -- Identify patients to exclude: TG >= 500 mg/dL on >= 2 occurrences
    SELECT 
        person_id
    FROM ldl_tg_measurements
    WHERE measurement_type = 'TG'
    AND value_as_number >= 500
    GROUP BY person_id
    HAVING COUNT(*) >= 2
),

highest_ldl_identification AS (
    -- Find the highest LDL-C value and its date (index date) for each person
    SELECT 
        ltm.person_id,
        ltm.value_as_number AS max_ldl_value,
        ltm.measurement_date AS index_date
    FROM (
        SELECT 
            person_id,
            value_as_number,
            measurement_date,
            ROW_NUMBER() OVER (PARTITION BY person_id ORDER BY value_as_number DESC, measurement_date DESC) AS rn
        FROM ldl_tg_measurements
        WHERE measurement_type = 'LDL'
    ) ltm
    WHERE ltm.rn = 1
),

index_date_info AS (
    -- Combine index date with demographic information
    SELECT 
        hli.person_id,
        hli.index_date,
        hli.max_ldl_value,
        YEAR(hli.index_date) - p.year_of_birth AS age_at_index,
        p.gender_concept_id,
        p.race_concept_id
    FROM highest_ldl_identification hli
    INNER JOIN person p ON hli.person_id = p.person_id
),

secondary_causes_identification AS (
    -- Identify secondary causes of hypercholesterolemia within 1 year prior to index
    SELECT DISTINCT idi.person_id
    FROM index_date_info idi
    INNER JOIN condition_occurrence co ON idi.person_id = co.person_id
    WHERE co.condition_concept_id IN (
        -- Secondary causes of hypercholesterolemia (ICD codes mapped to OMOP)
        -- Nephrotic syndrome
        4195231, 197320, 195314,
        -- Hypothyroidism
        4058243, 140673, 4096682,
        -- Liver diseases
        4212540, 4058695, 194692, 4245975,
        -- Diabetes mellitus
        201826, 443238, 442793,
        -- Hyperglyceridemia/Hypertriglyceridemia
        4027663, 4060985,
        -- Chronic kidney disease
        443597, 442862,
        -- Cushing's syndrome
        4000483,
        -- Pregnancy
        4299535, 4013978
    )
    AND co.condition_start_date <= idi.index_date
    AND co.condition_start_date > DATEADD(year, -1, idi.index_date)
),

lipid_lowering_therapy AS (
    -- Identify LLT exposure within 1 year to 6 weeks prior to index date
    SELECT DISTINCT 
        idi.person_id
    FROM index_date_info idi
    INNER JOIN drug_exposure de ON idi.person_id = de.person_id
    WHERE de.drug_concept_id IN (
        -- Statins (RxNorm codes mapped to OMOP)
        1545958,  -- Atorvastatin
        1549686,  -- Rosuvastatin  
        1592085,  -- Simvastatin
        1541766,  -- Pravastatin
        1549701,  -- Fluvastatin
        1510813,  -- Lovastatin
        40165636, -- Pitavastatin
        -- Fibrates
        1517824,  -- Fenofibrate
        1502826,  -- Gemfibrozil
        -- Bile acid sequestrants
        1551803,  -- Cholestyramine
        998717,   -- Colesevelam
        953076,   -- Colestipol
        -- PCSK9 inhibitors
        45775372, -- Evolocumab
        45774751, -- Alirocumab
        -- Cholesterol absorption inhibitors
        1546322,  -- Ezetimibe
        -- Niacin
        1529331   -- Niacin
    )
    AND de.drug_exposure_start_date > DATEADD(year, -1, idi.index_date)
    AND de.drug_exposure_start_date <= DATEADD(week, -6, idi.index_date)
),

pre_treatment_ldl AS (
    -- Calculate pre-treatment LDL: divide by 0.7 if on LLT, otherwise use actual value
    SELECT 
        idi.person_id,
        idi.index_date,
        idi.max_ldl_value AS measured_ldl,
        CASE 
            WHEN llt.person_id IS NOT NULL THEN idi.max_ldl_value / 0.7
            ELSE idi.max_ldl_value
        END AS adjusted_ldl_value
    FROM index_date_info idi
    LEFT JOIN lipid_lowering_therapy llt ON idi.person_id = llt.person_id
),

-- ============================================================================
-- STAGE I CLASSIFICATION: Primary Hypercholesterolemia Cases and Controls
-- ============================================================================

stage1_classification AS (
    -- Classify as Cases (LDL>=155), Controls (LDL<=130), or Unknown (131-154)
    -- after excluding high TG and secondary causes
    SELECT 
        ptl.person_id,
        ptl.index_date,
        ptl.adjusted_ldl_value,
        CASE 
            WHEN ptl.adjusted_ldl_value >= 155 THEN 'CASE'
            WHEN ptl.adjusted_ldl_value <= 130 THEN 'CONTROL'
            WHEN ptl.adjusted_ldl_value > 130 AND ptl.adjusted_ldl_value < 155 THEN 'UNKNOWN'
            ELSE 'UNKNOWN'
        END AS stage1_status
    FROM pre_treatment_ldl ptl
    LEFT JOIN high_triglycerides_exclusion hte ON ptl.person_id = hte.person_id
    LEFT JOIN secondary_causes_identification sci ON ptl.person_id = sci.person_id
    WHERE hte.person_id IS NULL  -- Exclude high triglycerides
    AND sci.person_id IS NULL     -- Exclude secondary causes
),

-- ============================================================================
-- STAGE II SCORING: Apply scoring system to Stage I cases only
-- ============================================================================

group1_ldl_scoring AS (
    -- Group I: LDL-C level scoring (1-8 points based on ranges)
    SELECT 
        person_id,
        adjusted_ldl_value,
        CASE 
            WHEN adjusted_ldl_value >= 325 THEN 8
            WHEN adjusted_ldl_value >= 251 AND adjusted_ldl_value < 325 THEN 5
            WHEN adjusted_ldl_value >= 191 AND adjusted_ldl_value < 251 THEN 3
            WHEN adjusted_ldl_value >= 155 AND adjusted_ldl_value < 191 THEN 1
            ELSE 0
        END AS ldl_points
    FROM stage1_classification
    WHERE stage1_status = 'CASE'
),

group2_personal_history_scoring AS (
    -- Group II: Personal history of premature CHD (2 points) or CVD/PAD (1 point)
    -- Premature: Male <55 years, Female <65 years
    SELECT 
        s1.person_id,
        MAX(score_value) AS personal_history_points
    FROM (
        SELECT 
            s1.person_id,
            CASE 
                -- Premature CHD = 2 points
                WHEN co.condition_concept_id IN (
                    -- Myocardial infarction
                    4329847, 312327, 444406,
                    -- Acute coronary syndrome
                    314666, 319844,
                    -- Coronary atherosclerosis
                    317576, 764123,
                    -- Angina pectoris
                    321318, 77670, 194828
                ) AND (
                    (p.gender_concept_id = 8507 AND YEAR(co.condition_start_date) - p.year_of_birth < 55) OR
                    (p.gender_concept_id = 8532 AND YEAR(co.condition_start_date) - p.year_of_birth < 65)
                ) THEN 2
                -- Premature CVD/PAD = 1 point
                WHEN co.condition_concept_id IN (
                    -- Cerebral infarction/stroke
                    443454, 4043731, 4110189,
                    -- Peripheral arterial disease
                    321052, 321588, 4313767
                ) AND (
                    (p.gender_concept_id = 8507 AND YEAR(co.condition_start_date) - p.year_of_birth < 55) OR
                    (p.gender_concept_id = 8532 AND YEAR(co.condition_start_date) - p.year_of_birth < 65)
                ) THEN 1
                ELSE 0
            END AS score_value
        FROM stage1_classification s1
        INNER JOIN person p ON s1.person_id = p.person_id
        LEFT JOIN condition_occurrence co ON s1.person_id = co.person_id
        WHERE s1.stage1_status = 'CASE'
    ) scores
    GROUP BY person_id
),

group3_family_history_scoring AS (
    -- Group III: Family history of premature ASCVD or hypercholesterolemia (1 point)
    SELECT 
        s1.person_id,
        MAX(
            CASE 
                WHEN o.observation_concept_id IN (
                    -- Family history of premature ASCVD
                    4167217,  -- Family history of ischemic heart disease
                    4101344,  -- Family history of stroke
                    4054836,  -- Family history of cardiovascular disease
                    -- Family history of hypercholesterolemia
                    4041664,  -- Family history of lipid metabolism disorder
                    4053372,  -- Family history of pure hypercholesterolemia
                    46273729  -- Family history of familial hypercholesterolemia
                ) THEN 1
                ELSE 0
            END
        ) AS family_history_points
    FROM stage1_classification s1
    LEFT JOIN observation o ON s1.person_id = o.person_id
    WHERE s1.stage1_status = 'CASE'
    GROUP BY s1.person_id
),

group4_physical_exam_scoring AS (
    -- Group IV: Tendon xanthomas (6 points) or early-onset corneal arcus (4 points)
    SELECT 
        s1.person_id,
        MAX(score_value) AS physical_exam_points
    FROM (
        SELECT 
            s1.person_id,
            CASE 
                -- Tendon xanthomas = 6 points
                WHEN o.observation_concept_id IN (
                    4169378,  -- Tendon xanthomas
                    4013650,  -- Xanthoma tuberosum
                    4012190   -- Xanthomatosis
                ) THEN 6
                -- Early-onset corneal arcus (age <45) = 4 points
                WHEN o.observation_concept_id IN (
                    4038838,  -- Arcus senilis/corneal arcus
                    376414    -- Corneal arcus
                ) AND YEAR(o.observation_date) - p.year_of_birth < 45 THEN 4
                ELSE 0
            END AS score_value
        FROM stage1_classification s1
        INNER JOIN person p ON s1.person_id = p.person_id
        LEFT JOIN observation o ON s1.person_id = o.person_id
        WHERE s1.stage1_status = 'CASE'
    ) scores
    GROUP BY person_id
),

stage2_total_scores AS (
    -- Sum scores from all 4 groups for Stage I cases
    SELECT 
        s1.person_id,
        s1.stage1_status,
        s1.adjusted_ldl_value,
        COALESCE(g1.ldl_points, 0) AS group1_score,
        COALESCE(g2.personal_history_points, 0) AS group2_score,
        COALESCE(g3.family_history_points, 0) AS group3_score,
        COALESCE(g4.physical_exam_points, 0) AS group4_score,
        COALESCE(g1.ldl_points, 0) + 
        COALESCE(g2.personal_history_points, 0) + 
        COALESCE(g3.family_history_points, 0) + 
        COALESCE(g4.physical_exam_points, 0) AS total_score
    FROM stage1_classification s1
    LEFT JOIN group1_ldl_scoring g1 ON s1.person_id = g1.person_id
    LEFT JOIN group2_personal_history_scoring g2 ON s1.person_id = g2.person_id
    LEFT JOIN group3_family_history_scoring g3 ON s1.person_id = g3.person_id
    LEFT JOIN group4_physical_exam_scoring g4 ON s1.person_id = g4.person_id
    WHERE s1.stage1_status = 'CASE'
),

-- ============================================================================
-- FINAL FH CLASSIFICATION
-- ============================================================================

final_classification AS (
    -- Combine Stage I and Stage II results for final classification
    SELECT 
        s1.person_id,
        s1.adjusted_ldl_value,
        s1.stage1_status,
        s2.total_score,
        CASE 
            -- Non-cases from Stage I retain their classification
            WHEN s1.stage1_status = 'CONTROL' THEN 'CONTROL'
            WHEN s1.stage1_status = 'UNKNOWN' THEN 'UNKNOWN'
            -- Stage I cases classified by Stage II total score
            WHEN s1.stage1_status = 'CASE' AND s2.total_score >= 6 THEN 'FH_CASE'
            WHEN s1.stage1_status = 'CASE' AND s2.total_score BETWEEN 3 AND 5 THEN 'FH_UNKNOWN'
            WHEN s1.stage1_status = 'CASE' AND s2.total_score BETWEEN 1 AND 2 THEN 'FH_CONTROL'
            WHEN s1.stage1_status = 'CASE' AND s2.total_score = 0 THEN 'FH_CONTROL'
            ELSE 'ERROR'
        END AS fh_classification
    FROM stage1_classification s1
    LEFT JOIN stage2_total_scores s2 ON s1.person_id = s2.person_id
)

-- ============================================================================
-- FINAL OUTPUT: Return person_id with case/control/unknown status
-- ============================================================================

SELECT 
    person_id,
    adjusted_ldl_value AS pre_treatment_ldl_mg_dl,
    fh_classification,
    total_score AS fh_score,
    -- Binary case-control status for analysis
    CASE 
        WHEN fh_classification = 'FH_CASE' THEN 1          -- Definite FH case
        WHEN fh_classification IN ('FH_CONTROL', 'CONTROL') THEN 0  -- Control
        ELSE NULL  -- Unknown/Uncertain cases
    END AS case_control_status
FROM final_classification
ORDER BY person_id;