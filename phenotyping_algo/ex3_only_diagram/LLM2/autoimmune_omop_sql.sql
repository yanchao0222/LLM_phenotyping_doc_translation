-- ============================================================================
-- AUTOIMMUNE DISEASE PHENOTYPING ALGORITHM - EXECUTABLE SQL
-- Purpose: Identify cases and controls for autoimmune disease studies
-- Based on eMERGE cohort phenotyping criteria
-- OMOP CDM Compatible Query
-- ============================================================================

-- ----------------------------------------------------------------------------
-- MAIN QUERY: IDENTIFY CASES AND CONTROLS FOR AUTOIMMUNE DISEASE
-- ----------------------------------------------------------------------------

WITH autoimmune_diagnoses AS (
  -- ----------------------------------------------------------------------------
  -- STEP 1: IDENTIFY ALL AUTOIMMUNE DISEASE DIAGNOSES
  -- 51 diseases across 9 groups (46 non-overlapping after combining overlaps)
  -- Using OMOP standard concept IDs for autoimmune conditions
  -- ----------------------------------------------------------------------------
  SELECT DISTINCT 
    person_id,
    condition_start_date,
    condition_concept_id
  FROM condition_occurrence
  WHERE condition_concept_id IN (
    -- Arthritis Group (7 diseases)
    81097,      -- Ankylosing spondylitis
    81571,      -- Behcet's disease  
    433581,     -- Palindromic rheumatism
    73840,      -- Polymyalgia rheumatica
    4116440,    -- Psoriatic arthritis
    81281,      -- Reiter's syndrome
    80809,      -- Rheumatoid arthritis
    
    -- Connective Tissue Group (5 diseases)
    4063581,    -- Lupus erythematosus (SLE)
    197494,     -- Mixed Connective Tissue Disease
    257628,     -- Sarcoidosis
    81893,      -- Scleroderma/Systemic sclerosis
    80182,      -- Sjogren's syndrome
    
    -- Endocrine Group (3 diseases)
    82960,      -- Graves' Disease
    140168,     -- Hashimoto's thyroiditis
    201826,     -- Type 1 Diabetes Mellitus
    
    -- Gastrointestinal Group (5 diseases)
    200762,     -- Autoimmune hepatitis
    4134662,    -- Celiac Disease
    201606,     -- Crohn's disease
    4058243,    -- Primary biliary cholangitis (PBC)
    81893,      -- Ulcerative colitis
    
    -- Hematologic Group (5 diseases)
    4098292,    -- Antiphospholipid syndrome
    437264,     -- Autoimmune hemolytic anemia
    4218641,    -- Autoimmune neutropenia
    432923,     -- Evans syndrome
    434557,     -- Thrombocytopenic purpura (TTP)
    
    -- Muscle Group (3 diseases - combined due to overlap)
    374919,     -- Dermatomyositis
    4063556,    -- Polymyositis
    4341687,    -- Inflammatory and immune myopathies
    
    -- Neurological Group (8 diseases)
    374925,     -- Guillain-Barre Syndrome
    375806,     -- Lambert-Eaton syndrome
    374919,     -- Multiple sclerosis
    76685,      -- Myasthenia gravis
    139803,     -- Myelitis transversa
    374945,     -- Optic neuritis
    4334765,    -- Optic Papillitis
    192367,     -- Schilder's disease
    
    -- Skin Group (9 diseases)
    141933,     -- Alopecia areata
    133547,     -- Dermatitis herpetiformis
    136774,     -- Pemphigoid
    45766714,   -- Ocular cicatricial pemphigoid
    138825,     -- Pemphigus
    140168,     -- Psoriasis
    4305080,    -- Pyoderma
    201820,     -- Raynaud's disease/phenomenon
    45766160,   -- Vitiligo
    
    -- Vasculitis Group (6 diseases)
    320749,     -- Arteritis
    44782772,   -- Cerebral Arteritis
    4182929,    -- Giant Cell Arteritis
    4112853,    -- Goodpasture's syndrome
    313223,     -- Granulomatosis with polyangiitis
    4028670     -- Takayasu's disease
  )
),

diabetes_status AS (
  -- ----------------------------------------------------------------------------
  -- STEP 2: IDENTIFY TYPE 1 AND TYPE 2 DIABETES STATUS
  -- Needed for special case handling in the algorithm
  -- ----------------------------------------------------------------------------
  SELECT 
    person_id,
    MAX(CASE WHEN condition_concept_id = 201826 THEN 1 ELSE 0 END) AS has_t1d,
    MAX(CASE WHEN condition_concept_id IN (201820, 443238, 442793) THEN 1 ELSE 0 END) AS has_t2d
  FROM condition_occurrence
  WHERE condition_concept_id IN (
    201826,     -- Type 1 Diabetes Mellitus
    201820,     -- Type 2 Diabetes Mellitus
    443238,     -- Type 2 Diabetes Mellitus without complication
    442793      -- Type 2 Diabetes Mellitus with complication
  )
  GROUP BY person_id
),

positive_serology AS (
  -- ----------------------------------------------------------------------------
  -- STEP 3: IDENTIFY POSITIVE SEROLOGY ANTIBODY TESTS
  -- 10 main antibody test categories with sub-components
  -- ----------------------------------------------------------------------------
  SELECT DISTINCT person_id
  FROM measurement
  WHERE 
    measurement_concept_id IN (
      -- Anti Nuclear Antibody (ANA)
      3003694,    -- ANA measurement
      40764999,   -- ANA titer
      
      -- Anti-Cytoplasmic Neutrophil Antibodies (ANCA)
      3019550,    -- ANCA measurement
      3030692,    -- c-ANCA measurement
      3007220,    -- p-ANCA measurement
      
      -- Anti-DNA Antibody
      3018486,    -- Anti-dsDNA measurement
      3005757,    -- Anti-DNA antibodies
      
      -- Cyclic Citrullinated Peptide Antibody
      3037556,    -- Anti-CCP measurement
      37393863,   -- Anti-CCP IgG
      
      -- Rheumatoid Factor
      3023230,    -- RF measurement
      3004588,    -- RF quantitative
      
      -- Beta 2 Glycoprotein I Antibody
      40764126,   -- Beta-2 glycoprotein 1 Ab
      3035637,    -- Beta-2 glycoprotein 1 IgG
      3030152,    -- Beta-2 glycoprotein 1 IgM
      
      -- RNA Polymerase 3 Antibody
      3002482,    -- RNA polymerase III Ab
      
      -- Anti-Cardiolipin Antibodies
      3003885,    -- Cardiolipin Ab
      3032370,    -- Cardiolipin Ab IgG
      3014576,    -- Cardiolipin Ab IgM
      
      -- Centromere Antibody
      3016914,    -- Anti-centromere Ab
      
      -- Extractable Nuclear Antibodies (ENA) - includes multiple sub-tests
      3019550,    -- ENA panel
      3013537,    -- Anti-Jo-1 Ab
      3018171,    -- Anti-RNP Ab
      3016891,    -- Anti-Scl-70 Ab
      3045424,    -- Anti-Smith Ab
      3003396,    -- Anti-SSA/Ro Ab
      3011708     -- Anti-SSB/La Ab
    )
    AND (
      -- Positive result indicated by various methods
      value_as_concept_id IN (
        4126681,  -- Positive
        4181412,  -- Present
        9191      -- Positive finding
      )
      OR (value_as_number > 0 AND unit_concept_id IS NOT NULL)
      OR LOWER(value_source_value) IN ('positive', 'detected', 'reactive', 'abnormal')
    )
),

antiinflammatory_diagnoses AS (
  -- ----------------------------------------------------------------------------
  -- STEP 4: IDENTIFY ANTI-INFLAMMATORY RELATED DIAGNOSES
  -- These are autoimmune diseases other than T1D that would indicate
  -- inflammatory processes (all non-T1D autoimmune diseases from our list)
  -- ----------------------------------------------------------------------------
  SELECT DISTINCT person_id
  FROM condition_occurrence
  WHERE condition_concept_id IN (
    -- All autoimmune disease codes EXCEPT Type 1 Diabetes (201826)
    81097, 81571, 433581, 73840, 4116440, 81281, 80809,
    4063581, 197494, 257628, 81893, 80182,
    82960, 140168,  -- Excluding T1D from endocrine group
    200762, 4134662, 201606, 4058243, 81893,
    4098292, 437264, 4218641, 432923, 434557,
    374919, 4063556, 4341687,
    374925, 375806, 374919, 76685, 139803, 374945, 4334765, 192367,
    141933, 133547, 136774, 45766714, 138825, 140168, 4305080, 201820, 45766160,
    320749, 44782772, 4182929, 4112853, 313223, 4028670
  )
),

diagnosis_summary AS (
  -- ----------------------------------------------------------------------------
  -- STEP 5: CALCULATE DIAGNOSIS COUNTS AND DATE SPANS
  -- Need at least 3 diagnoses on distinct days, 7+ days apart
  -- ----------------------------------------------------------------------------
  SELECT 
    ad.person_id,
    COUNT(DISTINCT ad.condition_start_date) AS distinct_diagnosis_days,
    MIN(ad.condition_start_date) AS first_diagnosis_date,
    MAX(ad.condition_start_date) AS last_diagnosis_date,
    DATEDIFF(day, 
             MIN(ad.condition_start_date), 
             MAX(ad.condition_start_date)) AS days_between_first_last
  FROM autoimmune_diagnoses ad
  GROUP BY ad.person_id
),

case_evaluation AS (
  -- ----------------------------------------------------------------------------
  -- STEP 6: COMBINE ALL CRITERIA FOR CASE EVALUATION
  -- ----------------------------------------------------------------------------
  SELECT 
    ds.person_id,
    ds.distinct_diagnosis_days,
    ds.days_between_first_last,
    COALESCE(diab.has_t1d, 0) AS has_t1d,
    COALESCE(diab.has_t2d, 0) AS has_t2d,
    CASE WHEN ps.person_id IS NOT NULL THEN 1 ELSE 0 END AS has_positive_serology,
    CASE WHEN ai.person_id IS NOT NULL THEN 1 ELSE 0 END AS has_antiinflammatory
  FROM diagnosis_summary ds
  LEFT JOIN diabetes_status diab ON ds.person_id = diab.person_id
  LEFT JOIN positive_serology ps ON ds.person_id = ps.person_id
  LEFT JOIN antiinflammatory_diagnoses ai ON ds.person_id = ai.person_id
),

final_cases AS (
  -- ----------------------------------------------------------------------------
  -- STEP 7: APPLY FINAL CASE DEFINITION LOGIC
  -- Based on flowchart: timing requirements + specific disease combinations
  -- ----------------------------------------------------------------------------
  SELECT 
    person_id,
    'CASE' AS phenotype_status
  FROM case_evaluation
  WHERE 
    -- Timing requirements: ≥3 distinct days AND ≥7 days between first and last
    distinct_diagnosis_days >= 3
    AND days_between_first_last >= 7
    
    -- Disease-specific logic
    AND (
      -- Has non-T1D autoimmune disease(s)
      (has_antiinflammatory = 1)
      
      -- OR has T1D with other autoimmune diseases
      OR (has_t1d = 1 AND has_antiinflammatory = 1)
      
      -- OR has T1D with positive serology
      OR (has_t1d = 1 AND has_positive_serology = 1)
      
      -- OR has T2D with positive serology (indicating autoimmune process)
      OR (has_t2d = 1 AND has_positive_serology = 1 AND has_t1d = 0)
    )
),

all_subjects AS (
  -- ----------------------------------------------------------------------------
  -- STEP 8: IDENTIFY ALL SUBJECTS IN DATABASE FOR CONTROL SELECTION
  -- ----------------------------------------------------------------------------
  SELECT DISTINCT person_id
  FROM person
  WHERE person_id IN (
    -- Ensure person has some data in the database
    SELECT DISTINCT person_id FROM observation
    UNION
    SELECT DISTINCT person_id FROM condition_occurrence
    UNION
    SELECT DISTINCT person_id FROM measurement
    UNION
    SELECT DISTINCT person_id FROM procedure_occurrence
    UNION
    SELECT DISTINCT person_id FROM drug_exposure
  )
),

final_controls AS (
  -- ----------------------------------------------------------------------------
  -- STEP 9: DEFINE CONTROLS
  -- Subjects without any autoimmune disease diagnoses
  -- ----------------------------------------------------------------------------
  SELECT 
    s.person_id,
    'CONTROL' AS phenotype_status
  FROM all_subjects s
  WHERE s.person_id NOT IN (
    SELECT person_id FROM autoimmune_diagnoses
  )
  AND s.person_id NOT IN (
    SELECT person_id FROM final_cases
  )
)

-- ----------------------------------------------------------------------------
-- FINAL OUTPUT: COMBINE CASES AND CONTROLS WITH SUMMARY
-- ----------------------------------------------------------------------------
SELECT 
  person_id,
  phenotype_status,
  'Autoimmune Disease' AS phenotype_name,
  CURRENT_DATE AS execution_date
FROM final_cases

UNION ALL

SELECT 
  person_id,
  phenotype_status,
  'Autoimmune Disease' AS phenotype_name,
  CURRENT_DATE AS execution_date
FROM final_controls

ORDER BY phenotype_status DESC, person_id;