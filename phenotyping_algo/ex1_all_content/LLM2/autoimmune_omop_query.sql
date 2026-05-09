/**************************************************************************
 * AUTOIMMUNE DISEASE (AID) PHENOTYPING ALGORITHM V4 - OMOP CDM EXECUTABLE
 * 
 * Purpose: Identify cases and controls for autoimmune disease studies
 * Database: OMOP CDM v5.3 or higher
 * 
 * Algorithm Requirements:
 * - Cases: 3+ diagnosis codes on distinct days, 7+ days apart for same disease
 * - T1D exclusion: No T2D codes for T1D patients
 * - Controls: No autoimmune/auto-inflammatory codes AND no positive serologies
 **************************************************************************/

WITH 
-- ========================================================================
-- SECTION 1: PATIENT DIAGNOSES FOR AUTOIMMUNE DISEASES
-- Maps conditions to 51 autoimmune diseases using ICD9CM, ICD10CM, SNOMED
-- ========================================================================
patient_autoimmune_conditions AS (
    SELECT DISTINCT
        co.person_id,
        co.condition_start_date as diagnosis_date,
        c.concept_code,
        c.vocabulary_id,
        -- Map diagnosis codes to disease names based on algorithm specification
        CASE 
            -- Arthritis Group
            WHEN c.concept_code IN ('M45', 'M45.9', '720.0') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Arthritis:Ankylosing spondylitis'
            WHEN c.concept_code IN ('M35.2', '136.1') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Arthritis:Behcets disease'
            WHEN c.concept_code IN ('M79.39', '719.3') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Arthritis:Palindromic rheumatism'
            WHEN c.concept_code IN ('M35.3', '725') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Arthritis:Polymyalgia rheumatica'
            WHEN c.concept_code IN ('L40.5', 'L40.50', 'L40.51', 'L40.52', 'L40.53', 'L40.54', '696.0') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Arthritis:Psoriatic arthritis'
            WHEN c.concept_code IN ('M02.3', 'M02.30', '099.3') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Arthritis:Reiters syndrome'
            WHEN c.concept_code LIKE 'M05%' AND c.vocabulary_id = 'ICD10CM' THEN 'Arthritis:Rheumatoid arthritis (RA)'
            WHEN c.concept_code LIKE 'M06%' AND c.vocabulary_id = 'ICD10CM' THEN 'Arthritis:Rheumatoid arthritis (RA)'
            WHEN c.concept_code IN ('714.0') AND c.vocabulary_id = 'ICD9CM' THEN 'Arthritis:Rheumatoid arthritis (RA)'
            
            -- Connective Tissue Group
            WHEN c.concept_code LIKE 'M32%' AND c.vocabulary_id = 'ICD10CM' THEN 'Connective:Lupus erythematosus'
            WHEN c.concept_code IN ('710.0') AND c.vocabulary_id = 'ICD9CM' THEN 'Connective:Lupus erythematosus'
            WHEN c.concept_code IN ('M35.1', '710.8') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Connective:Mixed Connective Tissue Disease (MCTD)'
            WHEN c.concept_code LIKE 'D86%' AND c.vocabulary_id = 'ICD10CM' THEN 'Connective:Sarcoidosis'
            WHEN c.concept_code IN ('135') AND c.vocabulary_id = 'ICD9CM' THEN 'Connective:Sarcoidosis'
            WHEN c.concept_code LIKE 'M34%' AND c.vocabulary_id = 'ICD10CM' THEN 'Connective:Scleroderma'
            WHEN c.concept_code IN ('710.1') AND c.vocabulary_id = 'ICD9CM' THEN 'Connective:Scleroderma'
            WHEN c.concept_code IN ('M35.0', 'M35.00', 'M35.01', '710.2') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Connective:Sjogrens syndrome'
            
            -- Endocrine Group
            WHEN c.concept_code IN ('E05.0', 'E05.00', '242.0') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Endocrine:Graves Disease'
            WHEN c.concept_code IN ('E06.3', '245.2') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Endocrine:Hashimotos thyroiditis'
            WHEN c.concept_code LIKE 'E10%' AND c.vocabulary_id = 'ICD10CM' THEN 'Endocrine:T1D'
            WHEN c.concept_code IN ('250.01', '250.03', '250.11', '250.13', '250.21', '250.23', '250.31', '250.33', '250.41', '250.43', '250.51', '250.53', '250.61', '250.63', '250.71', '250.73', '250.81', '250.83', '250.91', '250.93') AND c.vocabulary_id = 'ICD9CM' THEN 'Endocrine:T1D'
            
            -- GI Group
            WHEN c.concept_code IN ('K75.4', '571.42') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'GI:Autoimmune hepatitis'
            WHEN c.concept_code IN ('K90.0', '579.0') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'GI:Celiac Disease'
            WHEN c.concept_code LIKE 'K50%' AND c.vocabulary_id = 'ICD10CM' THEN 'GI:Crohns disease'
            WHEN c.concept_code LIKE '555%' AND c.vocabulary_id = 'ICD9CM' THEN 'GI:Crohns disease'
            WHEN c.concept_code IN ('K74.3', '571.6') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'GI:Primary biliary cholangitis (PBC)'
            WHEN c.concept_code LIKE 'K51%' AND c.vocabulary_id = 'ICD10CM' THEN 'GI:Ulcerative colitis (UC)'
            WHEN c.concept_code LIKE '556%' AND c.vocabulary_id = 'ICD9CM' THEN 'GI:Ulcerative colitis (UC)'
            
            -- Hematologic Group
            WHEN c.concept_code IN ('D68.61', '289.81') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Heme:Antiphospholipid syndrome (APS)'
            WHEN c.concept_code IN ('D59.1', '283.0') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Heme:Autoimmune hemolytic anemia (AIHA)'
            WHEN c.concept_code IN ('D70.1', '288.09') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Heme:Autoimmune neutropenia'
            WHEN c.concept_code IN ('D69.3', '287.32') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Heme:Evans syndrome'
            WHEN c.concept_code IN ('M31.1', '446.6') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Heme:Thrombocytopenic purpura (TTP)'
            
            -- Muscle Group
            WHEN c.concept_code IN ('M33.1', 'M33.10', 'M33.11', 'M33.12', '710.3') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Muscle:Dermatomyositis'
            WHEN c.concept_code IN ('M33.2', 'M33.20', 'M33.21', 'M33.22', '710.4') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Muscle:Polymyositis'
            WHEN c.concept_code IN ('G72.49', '359.79') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Muscle:Inflammatory and immune myopathies'
            
            -- Neurologic Group
            WHEN c.concept_code IN ('G61.0', '357.0') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Neuro:Guillain-Barre Syndrome'
            WHEN c.concept_code IN ('G73.1', '358.1') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Neuro:Lambert-Eaton syndrome'
            WHEN c.concept_code IN ('G35', '340') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Neuro:Multiple sclerosis'
            WHEN c.concept_code IN ('G70.0', 'G70.00', 'G70.01', '358.0', '358.00', '358.01') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Neuro:Myasthenia gravis'
            WHEN c.concept_code IN ('G37.3', '323.82') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Neuro:Myelitis transversa'
            WHEN c.concept_code IN ('H46', 'H46.0', 'H46.00', 'H46.01', 'H46.02', 'H46.03', '377.30') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Neuro:Optic neuritis'
            WHEN c.concept_code IN ('H46.0', '377.31') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Neuro:Optic Papillitis'
            WHEN c.concept_code IN ('G37.0', '341.1') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Neuro:Schilders disease'
            
            -- Skin Group
            WHEN c.concept_code LIKE 'L63%' AND c.vocabulary_id = 'ICD10CM' THEN 'Skin:Alopecia areata'
            WHEN c.concept_code IN ('704.01') AND c.vocabulary_id = 'ICD9CM' THEN 'Skin:Alopecia areata'
            WHEN c.concept_code IN ('L13.0', '694.0') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Skin:Dermatitis herpetiformis'
            WHEN c.concept_code LIKE 'L12.1%' AND c.vocabulary_id = 'ICD10CM' THEN 'Skin:Pemphigoid'
            WHEN c.concept_code IN ('694.5') AND c.vocabulary_id = 'ICD9CM' THEN 'Skin:Pemphigoid'
            WHEN c.concept_code IN ('L12.0', '694.61') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Skin:Ocular cicatricial pemphigoid'
            WHEN c.concept_code LIKE 'L10%' AND c.vocabulary_id = 'ICD10CM' THEN 'Skin:Pemphigus'
            WHEN c.concept_code IN ('694.4') AND c.vocabulary_id = 'ICD9CM' THEN 'Skin:Pemphigus'
            WHEN c.concept_code LIKE 'L40%' AND c.vocabulary_id = 'ICD10CM' THEN 'Skin:Psoriasis'
            WHEN c.concept_code IN ('696.1') AND c.vocabulary_id = 'ICD9CM' THEN 'Skin:Psoriasis'
            WHEN c.concept_code IN ('L88', '686.01') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Skin:Pyoderma'
            WHEN c.concept_code IN ('I73.0', 'I73.00', 'I73.01', '443.0') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Skin:Raynaud'
            WHEN c.concept_code IN ('L80', '709.01') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Skin:Vitiligo'
            
            -- Vasculitis Group
            WHEN c.concept_code IN ('M31.6', '447.6') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Vasculitis:Arteritis'
            WHEN c.concept_code IN ('I67.7', '437.4') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Vasculitis:Cerebral Arteritis'
            WHEN c.concept_code IN ('M31.5', '446.5') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Vasculitis:Giant Cell Arteritis'
            WHEN c.concept_code IN ('N08.5', '446.21') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Vasculitis:Goodpastures syndrome'
            WHEN c.concept_code IN ('M31.3', 'M31.30', 'M31.31', '446.4') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Vasculitis:Granulomatosis'
            WHEN c.concept_code IN ('M31.4', '446.7') AND c.vocabulary_id IN ('ICD10CM', 'ICD9CM') THEN 'Vasculitis:Takayasus disease'
            
            -- SNOMED mappings for diseases
            WHEN c.concept_id = 359789008 AND c.vocabulary_id = 'SNOMED' THEN 'Vasculitis:Takayasus disease'
            
            ELSE NULL
        END as disease_name
    FROM condition_occurrence co
    INNER JOIN concept c ON co.condition_concept_id = c.concept_id
    WHERE c.vocabulary_id IN ('ICD10CM', 'ICD9CM', 'SNOMED')
),

-- ========================================================================
-- SECTION 2: CALCULATE CASE CRITERIA FOR EACH DISEASE
-- ========================================================================
disease_counts AS (
    SELECT 
        person_id,
        disease_name,
        COUNT(DISTINCT diagnosis_date) as distinct_days,
        MIN(diagnosis_date) as first_diagnosis_date,
        MAX(diagnosis_date) as last_diagnosis_date,
        DATEDIFF(day, MIN(diagnosis_date), MAX(diagnosis_date)) as days_span
    FROM patient_autoimmune_conditions
    WHERE disease_name IS NOT NULL
    GROUP BY person_id, disease_name
),

-- Identify patients with Type 2 Diabetes (for T1D exclusion)
t2d_patients AS (
    SELECT DISTINCT co.person_id
    FROM condition_occurrence co
    INNER JOIN concept c ON co.condition_concept_id = c.concept_id
    WHERE (
        -- ICD10CM codes for T2DM
        (c.concept_code LIKE 'E11%' AND c.vocabulary_id = 'ICD10CM')
        -- ICD9CM codes for T2DM
        OR (c.concept_code IN ('250.00', '250.02', '250.10', '250.12', '250.20', '250.22', '250.30', '250.32', '250.40', '250.42', '250.50', '250.52', '250.60', '250.62', '250.70', '250.72', '250.80', '250.82', '250.90', '250.92') AND c.vocabulary_id = 'ICD9CM')
    )
),

-- Apply case determination logic
case_patients AS (
    SELECT 
        dc.person_id,
        dc.disease_name,
        CASE 
            -- Exclude T1D patients who have T2D
            WHEN dc.disease_name = 'Endocrine:T1D' AND t2d.person_id IS NOT NULL THEN 0
            -- Standard case criteria: 3+ diagnoses on distinct days, 7+ days apart
            WHEN dc.distinct_days >= 3 AND dc.days_span >= 7 THEN 1
            ELSE 0
        END as is_case
    FROM disease_counts dc
    LEFT JOIN t2d_patients t2d ON dc.person_id = t2d.person_id
),

-- ========================================================================
-- SECTION 3: IDENTIFY CONTROL PATIENTS
-- ========================================================================
-- Control Condition A: No autoimmune or auto-inflammatory diagnoses
excluded_by_diagnosis AS (
    SELECT DISTINCT co.person_id
    FROM condition_occurrence co
    INNER JOIN concept c ON co.condition_concept_id = c.concept_id
    INNER JOIN concept_ancestor ca ON c.concept_id = ca.descendant_concept_id
    INNER JOIN concept c2 ON ca.ancestor_concept_id = c2.concept_id
    WHERE c.vocabulary_id = 'SNOMED'
    AND (
        c2.concept_name LIKE '%autoimmune%'
        OR c2.concept_name LIKE '%auto-inflammatory%'
        OR c2.concept_id IN (85828009, 257628001)  -- SNOMED codes for autoimmune/auto-inflammatory
    )
),

-- Control Condition B: No positive serology tests
excluded_by_serology AS (
    SELECT DISTINCT m.person_id
    FROM measurement m
    INNER JOIN concept c ON m.measurement_concept_id = c.concept_id
    WHERE 
    (
        -- ANA test
        c.concept_name LIKE '%antinuclear antibod%'
        -- ANCA test
        OR c.concept_name LIKE '%neutrophil cytoplasmic antibod%'
        -- Anti-dsDNA
        OR c.concept_name LIKE '%double stranded DNA%'
        OR c.concept_name LIKE '%dsDNA%'
        -- CCP
        OR c.concept_name LIKE '%cyclic citrullinated peptide%'
        OR c.concept_name LIKE '%CCP%'
        -- RF
        OR c.concept_name LIKE '%rheumatoid factor%'
        -- B2 Glycoprotein
        OR c.concept_name LIKE '%beta 2 glycoprotein%'
        -- RNA Polymerase III
        OR c.concept_name LIKE '%RNA polymerase%'
        -- Cardiolipin
        OR c.concept_name LIKE '%cardiolipin%'
        -- Centromere
        OR c.concept_name LIKE '%centromere%'
        -- ENA panel
        OR c.concept_name LIKE '%extractable nuclear%'
        OR c.concept_name LIKE '%ENA%'
        OR c.concept_name LIKE '%Jo-1%'
        OR c.concept_name LIKE '%SSA%'
        OR c.concept_name LIKE '%SSB%'
        OR c.concept_name LIKE '%Sm antibod%'
        OR c.concept_name LIKE '%RNP antibod%'
        OR c.concept_name LIKE '%Scl-70%'
    )
    AND (
        -- Positive result indicators
        m.value_as_concept_id IN (4126681, 9191, 4181412)  -- Positive, Present, Detected
        OR UPPER(m.value_source_value) IN ('POSITIVE', 'DETECTED', 'REACTIVE', 'PRESENT')
        OR (m.value_as_number > m.range_high AND m.range_high IS NOT NULL)
    )
),

-- ========================================================================
-- SECTION 4: FINAL COHORT ASSIGNMENT
-- ========================================================================
all_patients AS (
    SELECT DISTINCT person_id FROM person
),

patient_status AS (
    SELECT 
        ap.person_id,
        -- Determine if patient is a case
        CASE WHEN MAX(CAST(cp.is_case AS INT)) = 1 THEN 1 ELSE 0 END as is_case,
        -- Determine if patient is a control
        CASE 
            WHEN ed.person_id IS NULL  -- No autoimmune/auto-inflammatory diagnoses
            AND es.person_id IS NULL   -- No positive serology tests
            AND MAX(CAST(cp.is_case AS INT)) = 0  -- Not a case
            THEN 1 
            ELSE 0 
        END as is_control
    FROM all_patients ap
    LEFT JOIN case_patients cp ON ap.person_id = cp.person_id
    LEFT JOIN excluded_by_diagnosis ed ON ap.person_id = ed.person_id
    LEFT JOIN excluded_by_serology es ON ap.person_id = es.person_id
    GROUP BY ap.person_id, ed.person_id, es.person_id
)

-- ========================================================================
-- FINAL OUTPUT QUERY
-- ========================================================================
SELECT 
    ps.person_id,
    CASE 
        WHEN ps.is_case = 1 THEN 'CASE'
        WHEN ps.is_control = 1 THEN 'CONTROL'
        ELSE 'EXCLUDED'
    END as cohort_status,
    -- List diseases for cases (using GROUP_CONCAT for MySQL or equivalent)
    CASE 
        WHEN ps.is_case = 1 THEN (
            SELECT GROUP_CONCAT(DISTINCT cp2.disease_name SEPARATOR '; ')
            FROM case_patients cp2
            WHERE cp2.person_id = ps.person_id
            AND cp2.is_case = 1
        )
        ELSE NULL
    END as disease_subphenotypes,
    p.year_of_birth,
    p.gender_concept_id,
    p.race_concept_id,
    p.ethnicity_concept_id
FROM patient_status ps
INNER JOIN person p ON ps.person_id = p.person_id
WHERE ps.is_case = 1 OR ps.is_control = 1  -- Only include cases and controls
ORDER BY 
    CASE 
        WHEN ps.is_case = 1 THEN 1
        WHEN ps.is_control = 1 THEN 2
        ELSE 3
    END,
    ps.person_id;