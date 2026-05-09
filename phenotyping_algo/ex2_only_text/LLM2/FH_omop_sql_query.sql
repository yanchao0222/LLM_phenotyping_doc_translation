/*=============================================================================
  FAMILIAL HYPERCHOLESTEROLEMIA (FH) PHENOTYPING ALGORITHM
  OMOP CDM Implementation
  Based on Modified Dutch Lipid Clinic Network (DLCN) Criteria
  
  Output: Cases and controls for FH based on:
  - Stage I: Primary hypercholesterolemia identification (LDL-C ≥155 mg/dL)
  - Stage II: DLCN scoring system (0-8+ points)
  
  Final Classification:
  - DEFINITE FH: DLCN score > 8 points → CASE
  - PROBABLE FH: DLCN score 6-8 points → CASE  
  - POSSIBLE FH: DLCN score 3-5 points → UNKNOWN
  - UNLIKELY FH: DLCN score 0-2 points → CONTROL
=============================================================================*/

WITH 
/*-----------------------------------------------------------------------------
  STAGE I: PRIMARY HYPERCHOLESTEROLEMIA IDENTIFICATION
-----------------------------------------------------------------------------*/

-- Step 1: Calculate LDL-C values using Friedewald equation or direct measurement
ldl_calculations AS (
    SELECT 
        m.person_id,
        m.measurement_date,
        p.year_of_birth,
        p.gender_concept_id,
        -- Direct LDL-C measurement
        MAX(CASE 
            WHEN m.measurement_concept_id IN (
                3028288,  -- LDL cholesterol calculated
                3001308,  -- LDL cholesterol direct
                3033638,  -- LDL cholesterol by beta-quantification
                3002089   -- LDL cholesterol
            ) THEN m.value_as_number 
        END) AS ldl_direct,
        -- Components for Friedewald equation
        MAX(CASE 
            WHEN m.measurement_concept_id IN (
                3027114,  -- Total cholesterol
                3019900   -- Cholesterol total
            ) THEN m.value_as_number 
        END) AS total_chol,
        MAX(CASE 
            WHEN m.measurement_concept_id IN (
                3023103,  -- HDL cholesterol
                3007070   -- Cholesterol in HDL
            ) THEN m.value_as_number 
        END) AS hdl_chol,
        MAX(CASE 
            WHEN m.measurement_concept_id IN (
                3022038,  -- Triglycerides
                3019747   -- Triglyceride
            ) THEN m.value_as_number 
        END) AS triglycerides
    FROM measurement m
    INNER JOIN person p ON m.person_id = p.person_id
    WHERE m.value_as_number IS NOT NULL 
        AND m.value_as_number > 0
        -- Age ≥ 18 years at measurement
        AND EXTRACT(YEAR FROM m.measurement_date) - p.year_of_birth >= 18
    GROUP BY m.person_id, m.measurement_date, p.year_of_birth, p.gender_concept_id
),

-- Step 2: Select highest LDL-C value (index date) for each patient
eligible_patients AS (
    SELECT 
        person_id,
        year_of_birth,
        gender_concept_id,
        measurement_date AS index_date,
        COALESCE(
            ldl_direct,
            -- Friedewald equation: LDL-C = Total cholesterol - HDL-C - (Triglycerides/5)
            CASE 
                WHEN total_chol IS NOT NULL 
                    AND hdl_chol IS NOT NULL 
                    AND triglycerides IS NOT NULL 
                    AND triglycerides < 400  -- Friedewald not valid if TG ≥ 400
                THEN total_chol - hdl_chol - (triglycerides / 5.0)
            END
        ) AS ldl_c_value,
        triglycerides,
        ROW_NUMBER() OVER (
            PARTITION BY person_id 
            ORDER BY COALESCE(
                ldl_direct,
                CASE 
                    WHEN total_chol IS NOT NULL AND hdl_chol IS NOT NULL 
                        AND triglycerides IS NOT NULL AND triglycerides < 400
                    THEN total_chol - hdl_chol - (triglycerides / 5.0)
                END
            ) DESC NULLS LAST
        ) AS rn
    FROM ldl_calculations
    WHERE COALESCE(
        ldl_direct,
        CASE 
            WHEN total_chol IS NOT NULL AND hdl_chol IS NOT NULL 
                AND triglycerides IS NOT NULL AND triglycerides < 400
            THEN total_chol - hdl_chol - (triglycerides / 5.0)
        END
    ) IS NOT NULL
),

patients_with_index AS (
    SELECT *
    FROM eligible_patients
    WHERE rn = 1
),

-- Step 3: Adjust LDL-C for lipid-lowering therapy (÷0.7 if on therapy within 1 year)
ldl_adjusted AS (
    SELECT 
        p.person_id,
        p.year_of_birth,
        p.gender_concept_id,
        p.index_date,
        p.ldl_c_value AS original_ldl_c,
        p.triglycerides,
        CASE 
            WHEN EXISTS (
                SELECT 1 FROM drug_exposure de
                WHERE de.person_id = p.person_id
                    AND de.drug_concept_id IN (
                        -- Statins
                        1539403, 1549686, 1592085, 1545958, 1510813,  -- Simvastatin
                        1549683, 1539463, 1551803, 1510831,            -- Fluvastatin  
                        1551860, 1551885, 1558254,                     -- Lovastatin
                        1549785, 1549687, 1539462,                     -- Pravastatin
                        40165636, 40165638,                             -- Pitavastatin
                        1545149, 1551099, 1539411,                     -- Atorvastatin
                        1510240, 1539418,                               -- Rosuvastatin
                        -- Fibrates
                        1304377, 1308738,                               -- Fenofibrate
                        1350489,                                        -- Gemfibrozil
                        -- Other lipid-lowering
                        1341268,                                        -- Ezetimibe
                        956874, 950637,                                 -- Niacin
                        1301267,                                        -- Cholestyramine
                        1392427,                                        -- Colestipol
                        1363053,                                        -- Colesevelam
                        40166035,                                       -- Lomitapide
                        42628089,                                       -- Mipomersen
                        44785829, 44816332                              -- PCSK9 inhibitors
                    )
                    AND de.drug_exposure_start_date BETWEEN 
                        p.index_date - INTERVAL '1 year' AND p.index_date
            )
            THEN p.ldl_c_value / 0.7  -- Adjust for 30% reduction
            ELSE p.ldl_c_value
        END AS adjusted_ldl_c
    FROM patients_with_index p
),

-- Step 4: Identify secondary causes of hypercholesterolemia
secondary_causes AS (
    SELECT DISTINCT la.person_id
    FROM ldl_adjusted la
    WHERE EXISTS (
        SELECT 1 FROM measurement m
        WHERE m.person_id = la.person_id
            AND m.measurement_date BETWEEN la.index_date - INTERVAL '1 year' AND la.index_date
            AND (
                -- Hypothyroidism: TSH ≥ 10 mIU/L
                (m.measurement_concept_id IN (3016431, 3020564) AND m.value_as_number >= 10)
                -- Biliary obstruction: Alkaline phosphatase ≥ 200 IU/L  
                OR (m.measurement_concept_id IN (3035995, 3004501) AND m.value_as_number >= 200)
                -- Liver disease: Total bilirubin > 2.0 mg/dL
                OR (m.measurement_concept_id IN (3024128, 3013721) AND m.value_as_number > 2.0)
                -- Nephrotic syndrome: 24h urine protein > 3g
                OR (m.measurement_concept_id IN (3014051, 3037110) AND m.value_as_number > 3000)
                -- Nephrotic syndrome: Urine protein/creatinine ratio > 3.0
                OR (m.measurement_concept_id IN (3021162, 3020630) AND m.value_as_number > 3.0)
                -- Renal failure: Serum creatinine > 2.6 mg/dL
                OR (m.measurement_concept_id IN (3016723, 3051825) AND m.value_as_number > 2.6)
                -- Renal failure: eGFR < 15 mL/min/1.73m2
                OR (m.measurement_concept_id IN (3049187, 3053283, 3030354) AND m.value_as_number < 15)
                -- Diabetes: HbA1c > 9%
                OR (m.measurement_concept_id IN (3004410, 3003309, 40758583) AND m.value_as_number > 9)
                -- Diabetes: Fasting glucose > 200 mg/dL
                OR (m.measurement_concept_id IN (3037110, 3004501) AND m.value_as_number > 200)
            )
    )
),

-- Step 5: Flag patients with high triglycerides or pregnancy
flagged_patients AS (
    SELECT DISTINCT person_id
    FROM (
        -- Triglycerides > 220 mg/dL at index date
        SELECT person_id 
        FROM ldl_adjusted
        WHERE triglycerides > 220
        
        UNION
        
        -- Pregnancy within 1 year prior to index date
        SELECT la.person_id
        FROM ldl_adjusted la
        WHERE EXISTS (
            SELECT 1 FROM condition_occurrence co
            WHERE co.person_id = la.person_id
                AND co.condition_concept_id IN (
                    433260,   -- Pregnancy
                    4299535,  -- Supervision of high-risk pregnancy  
                    4013978,  -- Pregnancy with abortive outcome
                    4218674,  -- Multiple gestation
                    4132711   -- Late pregnancy
                )
                AND co.condition_start_date BETWEEN 
                    la.index_date - INTERVAL '1 year' AND la.index_date
        )
    ) f
),

-- Step 6: Classify primary hypercholesterolemia status
primary_hypercholesterolemia AS (
    SELECT 
        la.person_id,
        la.year_of_birth,
        la.gender_concept_id,
        la.index_date,
        la.original_ldl_c,
        la.adjusted_ldl_c,
        CASE 
            WHEN la.adjusted_ldl_c >= 155 
                AND sc.person_id IS NULL  -- No secondary causes
                AND fp.person_id IS NULL  -- Not flagged
            THEN 'CASE'
            WHEN la.adjusted_ldl_c < 155 
            THEN 'CONTROL'
            ELSE 'EXCLUDED'
        END AS stage1_status
    FROM ldl_adjusted la
    LEFT JOIN secondary_causes sc ON la.person_id = sc.person_id
    LEFT JOIN flagged_patients fp ON la.person_id = fp.person_id
),

/*-----------------------------------------------------------------------------
  STAGE II: DLCN SCORING FOR FH CASES ONLY
-----------------------------------------------------------------------------*/

-- Component 1: LDL-C Score (1-8 points based on level)
ldl_score AS (
    SELECT 
        person_id,
        CASE 
            WHEN adjusted_ldl_c >= 330 THEN 8
            WHEN adjusted_ldl_c >= 250 THEN 5  
            WHEN adjusted_ldl_c >= 190 THEN 3
            WHEN adjusted_ldl_c >= 155 THEN 1
            ELSE 0
        END AS ldl_points
    FROM primary_hypercholesterolemia
    WHERE stage1_status = 'CASE'
),

-- Component 2: Family History of Premature ASCVD (1 point)
-- First-degree relatives: Males <56 years, Females <66 years
family_ascvd_score AS (
    SELECT 
        ph.person_id,
        -- Using observation table for family history (if available)
        MAX(CASE 
            WHEN o.observation_concept_id IN (
                4167217,  -- Family history of ischemic heart disease
                4165588,  -- Family history of myocardial infarction
                4212999,  -- Family history of stroke
                4051114   -- Family history cardiovascular disease
            ) THEN 1
            ELSE 0
        END) AS family_ascvd_points
    FROM primary_hypercholesterolemia ph
    LEFT JOIN observation o ON ph.person_id = o.person_id
    WHERE ph.stage1_status = 'CASE'
    GROUP BY ph.person_id
),

-- Component 3: Family History of Hypercholesterolemia (1 point)
family_chol_score AS (
    SELECT 
        ph.person_id,
        MAX(CASE 
            WHEN o.observation_concept_id IN (
                4167191,  -- Family history of hyperlipidemia
                40479314  -- Family history of hypercholesterolemia
            ) THEN 1
            ELSE 0
        END) AS family_chol_points
    FROM primary_hypercholesterolemia ph
    LEFT JOIN observation o ON ph.person_id = o.person_id
    WHERE ph.stage1_status = 'CASE'
    GROUP BY ph.person_id
),

-- Component 4: Personal History of Premature CHD (2 points)
personal_chd_score AS (
    SELECT 
        ph.person_id,
        MAX(CASE 
            WHEN co.condition_concept_id IN (
                -- Myocardial infarction
                4329847, 314666, 312327, 434376, 438447, 444406,
                -- Angina
                321318, 317576, 318443, 77670,
                -- Coronary atherosclerosis
                317576, 764123, 46273477, 4324693,
                -- Ischemic heart disease
                314378, 321886, 324203
            )
            AND (
                (ph.gender_concept_id = 8507 AND  -- Male
                 EXTRACT(YEAR FROM co.condition_start_date) - ph.year_of_birth < 56)
                OR 
                (ph.gender_concept_id = 8532 AND  -- Female
                 EXTRACT(YEAR FROM co.condition_start_date) - ph.year_of_birth < 66)
            )
            THEN 2
            ELSE 0
        END) AS personal_chd_points
    FROM primary_hypercholesterolemia ph
    LEFT JOIN condition_occurrence co ON ph.person_id = co.person_id
    WHERE ph.stage1_status = 'CASE'
    GROUP BY ph.person_id, ph.gender_concept_id, ph.year_of_birth
),

-- Component 5: Personal History of Premature CVD/PAD (1 point)
personal_cvd_pad_score AS (
    SELECT 
        ph.person_id,
        MAX(CASE 
            WHEN co.condition_concept_id IN (
                -- Cerebrovascular disease
                372924, 381591, 443454, 312939, 373503, 376713, 432923,
                -- Peripheral arterial disease
                321052, 4313767, 195834, 317309, 318072
            )
            AND (
                (ph.gender_concept_id = 8507 AND  -- Male
                 EXTRACT(YEAR FROM co.condition_start_date) - ph.year_of_birth < 56)
                OR 
                (ph.gender_concept_id = 8532 AND  -- Female
                 EXTRACT(YEAR FROM co.condition_start_date) - ph.year_of_birth < 66)
            )
            THEN 1
            ELSE 0
        END) AS personal_cvd_pad_points
    FROM primary_hypercholesterolemia ph
    LEFT JOIN condition_occurrence co ON ph.person_id = co.person_id
    WHERE ph.stage1_status = 'CASE'
    GROUP BY ph.person_id, ph.gender_concept_id, ph.year_of_birth
),

-- Component 6: Tendon Xanthomas (6 points)
xanthoma_score AS (
    SELECT 
        ph.person_id,
        MAX(CASE 
            WHEN co.condition_concept_id IN (
                4103295,  -- Tendon xanthomatosis
                4079843,  -- Xanthoma
                133444    -- Xanthomatosis
            ) THEN 6  
            ELSE 0
        END) AS xanthoma_points
    FROM primary_hypercholesterolemia ph
    LEFT JOIN condition_occurrence co ON ph.person_id = co.person_id
    WHERE ph.stage1_status = 'CASE'
    GROUP BY ph.person_id
),

-- Component 7: Early Corneal Arcus (4 points if age < 45)
arcus_score AS (
    SELECT 
        ph.person_id,
        MAX(CASE 
            WHEN co.condition_concept_id IN (
                4038838,  -- Corneal arcus
                373425    -- Arcus senilis
            )
            AND EXTRACT(YEAR FROM co.condition_start_date) - ph.year_of_birth < 45
            THEN 4
            ELSE 0
        END) AS arcus_points
    FROM primary_hypercholesterolemia ph
    LEFT JOIN condition_occurrence co ON ph.person_id = co.person_id
    WHERE ph.stage1_status = 'CASE'
    GROUP BY ph.person_id, ph.year_of_birth
),

/*-----------------------------------------------------------------------------
  CALCULATE TOTAL DLCN SCORE AND CLASSIFY FH
-----------------------------------------------------------------------------*/
dlcn_total_scores AS (
    SELECT 
        ph.person_id,
        ph.index_date,
        ph.original_ldl_c,
        ph.adjusted_ldl_c,
        COALESCE(ls.ldl_points, 0) AS ldl_points,
        COALESCE(fa.family_ascvd_points, 0) AS family_ascvd_points,
        COALESCE(fc.family_chol_points, 0) AS family_chol_points,
        COALESCE(pc.personal_chd_points, 0) AS personal_chd_points,
        COALESCE(pcv.personal_cvd_pad_points, 0) AS personal_cvd_pad_points,
        COALESCE(x.xanthoma_points, 0) AS xanthoma_points,
        COALESCE(a.arcus_points, 0) AS arcus_points,
        -- Calculate total DLCN score
        (COALESCE(ls.ldl_points, 0) + 
         COALESCE(fa.family_ascvd_points, 0) + 
         COALESCE(fc.family_chol_points, 0) + 
         COALESCE(pc.personal_chd_points, 0) + 
         COALESCE(pcv.personal_cvd_pad_points, 0) + 
         COALESCE(x.xanthoma_points, 0) + 
         COALESCE(a.arcus_points, 0)) AS total_dlcn_score
    FROM primary_hypercholesterolemia ph
    LEFT JOIN ldl_score ls ON ph.person_id = ls.person_id
    LEFT JOIN family_ascvd_score fa ON ph.person_id = fa.person_id
    LEFT JOIN family_chol_score fc ON ph.person_id = fc.person_id
    LEFT JOIN personal_chd_score pc ON ph.person_id = pc.person_id
    LEFT JOIN personal_cvd_pad_score pcv ON ph.person_id = pcv.person_id
    LEFT JOIN xanthoma_score x ON ph.person_id = x.person_id
    LEFT JOIN arcus_score a ON ph.person_id = a.person_id
    WHERE ph.stage1_status = 'CASE'
)

/*-----------------------------------------------------------------------------
  FINAL OUTPUT: FH Cases and Controls with Classification
-----------------------------------------------------------------------------*/
SELECT 
    person_id,
    index_date,
    original_ldl_c,
    adjusted_ldl_c,
    total_dlcn_score,
    -- Individual DLCN scoring components
    ldl_points,
    family_ascvd_points,
    family_chol_points,
    personal_chd_points,
    personal_cvd_pad_points,
    xanthoma_points,
    arcus_points,
    -- FH Classification based on DLCN score
    CASE 
        WHEN total_dlcn_score > 8 THEN 'DEFINITE_FH'
        WHEN total_dlcn_score BETWEEN 6 AND 8 THEN 'PROBABLE_FH'
        WHEN total_dlcn_score BETWEEN 3 AND 5 THEN 'POSSIBLE_FH'
        WHEN total_dlcn_score <= 2 THEN 'UNLIKELY_FH'
    END AS fh_classification,
    -- Final phenotype for analysis
    CASE 
        WHEN total_dlcn_score > 8 THEN 'FH_CASE'           -- Definite FH
        WHEN total_dlcn_score BETWEEN 6 AND 8 THEN 'FH_CASE'  -- Probable FH
        WHEN total_dlcn_score <= 2 THEN 'FH_CONTROL'      -- Unlikely FH
        ELSE 'FH_UNKNOWN'                                  -- Possible FH (3-5)
    END AS phenotype_status
FROM dlcn_total_scores

UNION ALL

-- Include Stage I controls (LDL-C < 155 mg/dL)
SELECT 
    person_id,
    index_date,
    original_ldl_c,
    adjusted_ldl_c,
    NULL AS total_dlcn_score,
    NULL AS ldl_points,
    NULL AS family_ascvd_points,
    NULL AS family_chol_points,
    NULL AS personal_chd_points,
    NULL AS personal_cvd_pad_points,
    NULL AS xanthoma_points,
    NULL AS arcus_points,
    'NOT_APPLICABLE' AS fh_classification,
    'FH_CONTROL' AS phenotype_status
FROM primary_hypercholesterolemia
WHERE stage1_status = 'CONTROL'

ORDER BY 
    CASE phenotype_status
        WHEN 'FH_CASE' THEN 1
        WHEN 'FH_UNKNOWN' THEN 2
        WHEN 'FH_CONTROL' THEN 3
    END,
    total_dlcn_score DESC NULLS LAST;