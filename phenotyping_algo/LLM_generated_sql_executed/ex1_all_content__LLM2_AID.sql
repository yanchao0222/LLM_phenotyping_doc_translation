-- Rule 1 (VUMC-specific database name): APPLIED
-- Rule 2 (wildcard fix): NOT APPLICABLE
-- Rule 3 (search ICD in condition_source_value): APPLIED
-- Rule 4 (LOINC/RxNorm join for measurements/drugs): APPLIED (for measurements)
-- Rule 5 (free-text LIKE for names/descriptions): APPLIED
-- Rule 6 (OR->UNION for multi-table): NOT APPLICABLE (all logic in one table per section)
-- Rule 7 (LEFT JOIN->UNION): NOT APPLICABLE
-- Rule 8 (remove NLP/free-text): APPLIED
-- Rule 9 (mark missing concepts): NOT APPLICABLE

-- FIX: All OMOP tables now use victr_sd.sd_omop_prod prefix
-- FIX: ICD code logic now filters on condition_source_value, not concept_code
-- FIX: Measurement serology exclusion uses concept join and LOWER(concept_name) LIKE
-- FIX: Free-text disease/serology names use LOWER(column) LIKE

CREATE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex1_all_content_LLM2_AID AS 

WITH 
patient_autoimmune_conditions AS (
    SELECT DISTINCT
        co.person_id,
        co.condition_start_date as diagnosis_date,
        co.condition_source_value as icd_code, -- REVISED (was: c.concept_code)
        NULL as vocabulary_id, -- REVISED (was: c.vocabulary_id)
        CASE 
            -- Arthritis Group
            WHEN co.condition_source_value IN ('M45', 'M45.9', '720.0') THEN 'Arthritis:Ankylosing spondylitis'
            WHEN co.condition_source_value IN ('M35.2', '136.1') THEN 'Arthritis:Behcets disease'
            WHEN co.condition_source_value IN ('M79.39', '719.3') THEN 'Arthritis:Palindromic rheumatism'
            WHEN co.condition_source_value IN ('M35.3', '725') THEN 'Arthritis:Polymyalgia rheumatica'
            WHEN co.condition_source_value IN ('L40.5', 'L40.50', 'L40.51', 'L40.52', 'L40.53', 'L40.54', '696.0') THEN 'Arthritis:Psoriatic arthritis'
            WHEN co.condition_source_value IN ('M02.3', 'M02.30', '099.3') THEN 'Arthritis:Reiters syndrome'
            WHEN co.condition_source_value LIKE 'M05%' THEN 'Arthritis:Rheumatoid arthritis (RA)'
            WHEN co.condition_source_value LIKE 'M06%' THEN 'Arthritis:Rheumatoid arthritis (RA)'
            WHEN co.condition_source_value IN ('714.0') THEN 'Arthritis:Rheumatoid arthritis (RA)'
            -- Connective Tissue Group
            WHEN co.condition_source_value LIKE 'M32%' THEN 'Connective:Lupus erythematosus'
            WHEN co.condition_source_value IN ('710.0') THEN 'Connective:Lupus erythematosus'
            WHEN co.condition_source_value IN ('M35.1', '710.8') THEN 'Connective:Mixed Connective Tissue Disease (MCTD)'
            WHEN co.condition_source_value LIKE 'D86%' THEN 'Connective:Sarcoidosis'
            WHEN co.condition_source_value IN ('135') THEN 'Connective:Sarcoidosis'
            WHEN co.condition_source_value LIKE 'M34%' THEN 'Connective:Scleroderma'
            WHEN co.condition_source_value IN ('710.1') THEN 'Connective:Scleroderma'
            WHEN co.condition_source_value IN ('M35.0', 'M35.00', 'M35.01', '710.2') THEN 'Connective:Sjogrens syndrome'
            -- Endocrine Group
            WHEN co.condition_source_value IN ('E05.0', 'E05.00', '242.0') THEN 'Endocrine:Graves Disease'
            WHEN co.condition_source_value IN ('E06.3', '245.2') THEN 'Endocrine:Hashimotos thyroiditis'
            WHEN co.condition_source_value LIKE 'E10%' THEN 'Endocrine:T1D'
            WHEN co.condition_source_value IN ('250.01', '250.03', '250.11', '250.13', '250.21', '250.23', '250.31', '250.33', '250.41', '250.43', '250.51', '250.53', '250.61', '250.63', '250.71', '250.73', '250.81', '250.83', '250.91', '250.93') THEN 'Endocrine:T1D'
            -- GI Group
            WHEN co.condition_source_value IN ('K75.4', '571.42') THEN 'GI:Autoimmune hepatitis'
            WHEN co.condition_source_value IN ('K90.0', '579.0') THEN 'GI:Celiac Disease'
            WHEN co.condition_source_value LIKE 'K50%' THEN 'GI:Crohns disease'
            WHEN co.condition_source_value LIKE '555%' THEN 'GI:Crohns disease'
            WHEN co.condition_source_value IN ('K74.3', '571.6') THEN 'GI:Primary biliary cholangitis (PBC)'
            WHEN co.condition_source_value LIKE 'K51%' THEN 'GI:Ulcerative colitis (UC)'
            WHEN co.condition_source_value LIKE '556%' THEN 'GI:Ulcerative colitis (UC)'
            -- Hematologic Group
            WHEN co.condition_source_value IN ('D68.61', '289.81') THEN 'Heme:Antiphospholipid syndrome (APS)'
            WHEN co.condition_source_value IN ('D59.1', '283.0') THEN 'Heme:Autoimmune hemolytic anemia (AIHA)'
            WHEN co.condition_source_value IN ('D70.1', '288.09') THEN 'Heme:Autoimmune neutropenia'
            WHEN co.condition_source_value IN ('D69.3', '287.32') THEN 'Heme:Evans syndrome'
            WHEN co.condition_source_value IN ('M31.1', '446.6') THEN 'Heme:Thrombocytopenic purpura (TTP)'
            -- Muscle Group
            WHEN co.condition_source_value IN ('M33.1', 'M33.10', 'M33.11', 'M33.12', '710.3') THEN 'Muscle:Dermatomyositis'
            WHEN co.condition_source_value IN ('M33.2', 'M33.20', 'M33.21', 'M33.22', '710.4') THEN 'Muscle:Polymyositis'
            WHEN co.condition_source_value IN ('G72.49', '359.79') THEN 'Muscle:Inflammatory and immune myopathies'
            -- Neurologic Group
            WHEN co.condition_source_value IN ('G61.0', '357.0') THEN 'Neuro:Guillain-Barre Syndrome'
            WHEN co.condition_source_value IN ('G73.1', '358.1') THEN 'Neuro:Lambert-Eaton syndrome'
            WHEN co.condition_source_value IN ('G35', '340') THEN 'Neuro:Multiple sclerosis'
            WHEN co.condition_source_value IN ('G70.0', 'G70.00', 'G70.01', '358.0', '358.00', '358.01') THEN 'Neuro:Myasthenia gravis'
            WHEN co.condition_source_value IN ('G37.3', '323.82') THEN 'Neuro:Myelitis transversa'
            WHEN co.condition_source_value IN ('H46', 'H46.0', 'H46.00', 'H46.01', 'H46.02', 'H46.03', '377.30') THEN 'Neuro:Optic neuritis'
            WHEN co.condition_source_value IN ('H46.0', '377.31') THEN 'Neuro:Optic Papillitis'
            WHEN co.condition_source_value IN ('G37.0', '341.1') THEN 'Neuro:Schilders disease'
            -- Skin Group
            WHEN co.condition_source_value LIKE 'L63%' THEN 'Skin:Alopecia areata'
            WHEN co.condition_source_value IN ('704.01') THEN 'Skin:Alopecia areata'
            WHEN co.condition_source_value IN ('L13.0', '694.0') THEN 'Skin:Dermatitis herpetiformis'
            WHEN co.condition_source_value LIKE 'L12.1%' THEN 'Skin:Pemphigoid'
            WHEN co.condition_source_value IN ('694.5') THEN 'Skin:Pemphigoid'
            WHEN co.condition_source_value IN ('L12.0', '694.61') THEN 'Skin:Ocular cicatricial pemphigoid'
            WHEN co.condition_source_value LIKE 'L10%' THEN 'Skin:Pemphigus'
            WHEN co.condition_source_value IN ('694.4') THEN 'Skin:Pemphigus'
            WHEN co.condition_source_value LIKE 'L40%' THEN 'Skin:Psoriasis'
            WHEN co.condition_source_value IN ('696.1') THEN 'Skin:Psoriasis'
            WHEN co.condition_source_value IN ('L88', '686.01') THEN 'Skin:Pyoderma'
            WHEN co.condition_source_value IN ('I73.0', 'I73.00', 'I73.01', '443.0') THEN 'Skin:Raynaud'
            WHEN co.condition_source_value IN ('L80', '709.01') THEN 'Skin:Vitiligo'
            -- Vasculitis Group
            WHEN co.condition_source_value IN ('M31.6', '447.6') THEN 'Vasculitis:Arteritis'
            WHEN co.condition_source_value IN ('I67.7', '437.4') THEN 'Vasculitis:Cerebral Arteritis'
            WHEN co.condition_source_value IN ('M31.5', '446.5') THEN 'Vasculitis:Giant Cell Arteritis'
            WHEN co.condition_source_value IN ('N08.5', '446.21') THEN 'Vasculitis:Goodpastures syndrome'
            WHEN co.condition_source_value IN ('M31.3', 'M31.30', 'M31.31', '446.4') THEN 'Vasculitis:Granulomatosis'
            WHEN co.condition_source_value IN ('M31.4', '446.7') THEN 'Vasculitis:Takayasus disease'
            ELSE NULL
        END as disease_name
    FROM victr_sd.sd_omop_prod.condition_occurrence co -- REVISED (was: condition_occurrence)
),
disease_counts AS (
    SELECT 
        person_id,
        disease_name,
        COUNT(DISTINCT diagnosis_date) as distinct_days,
        MIN(diagnosis_date) as first_diagnosis_date,
        MAX(diagnosis_date) as last_diagnosis_date,
        DATEDIFF(MAX(diagnosis_date), MIN(diagnosis_date)) as days_span -- REVISED (was: DATEDIFF(day, MIN(diagnosis_date), MAX(diagnosis_date)))
    FROM patient_autoimmune_conditions
    WHERE disease_name IS NOT NULL
    GROUP BY person_id, disease_name
),
t2d_patients AS (
    SELECT DISTINCT co.person_id
    FROM victr_sd.sd_omop_prod.condition_occurrence co -- REVISED (was: condition_occurrence)
    WHERE (
        (co.condition_source_value LIKE 'E11%')
        OR (co.condition_source_value IN ('250.00', '250.02', '250.10', '250.12', '250.20', '250.22', '250.30', '250.32', '250.40', '250.42', '250.50', '250.52', '250.60', '250.62', '250.70', '250.72', '250.80', '250.82', '250.90', '250.92'))
    )
),
case_patients AS (
    SELECT 
        dc.person_id,
        dc.disease_name,
        CASE 
            WHEN dc.disease_name = 'Endocrine:T1D' AND t2d.person_id IS NOT NULL THEN 0
            WHEN dc.distinct_days >= 3 AND dc.days_span >= 7 THEN 1
            ELSE 0
        END as is_case
    FROM disease_counts dc
    LEFT JOIN t2d_patients t2d ON dc.person_id = t2d.person_id
),
excluded_by_diagnosis AS (
    SELECT DISTINCT co.person_id
    FROM victr_sd.sd_omop_prod.condition_occurrence co -- REVISED (was: condition_occurrence)
    INNER JOIN victr_sd.sd_omop_prod.concept c ON co.condition_concept_id = c.concept_id -- REVISED (was: concept)
    WHERE LOWER(c.concept_name) LIKE '%autoimmune%' OR LOWER(c.concept_name) LIKE '%auto-inflammatory%' OR c.concept_id IN (85828009, 257628001)
),
excluded_by_serology AS (
    SELECT DISTINCT m.person_id
    FROM victr_sd.sd_omop_prod.measurement m -- REVISED (was: measurement)
    INNER JOIN victr_sd.sd_omop_prod.concept c ON m.measurement_concept_id = c.concept_id -- REVISED (was: concept)
    WHERE (
        LOWER(c.concept_name) LIKE '%antinuclear antibod%'
        OR LOWER(c.concept_name) LIKE '%neutrophil cytoplasmic antibod%'
        OR LOWER(c.concept_name) LIKE '%double stranded dna%'
        OR LOWER(c.concept_name) LIKE '%dsdna%'
        OR LOWER(c.concept_name) LIKE '%cyclic citrullinated peptide%'
        OR LOWER(c.concept_name) LIKE '%ccp%'
        OR LOWER(c.concept_name) LIKE '%rheumatoid factor%'
        OR LOWER(c.concept_name) LIKE '%beta 2 glycoprotein%'
        OR LOWER(c.concept_name) LIKE '%rna polymerase%'
        OR LOWER(c.concept_name) LIKE '%cardiolipin%'
        OR LOWER(c.concept_name) LIKE '%centromere%'
        OR LOWER(c.concept_name) LIKE '%extractable nuclear%'
        OR LOWER(c.concept_name) LIKE '%ena%'
        OR LOWER(c.concept_name) LIKE '%jo-1%'
        OR LOWER(c.concept_name) LIKE '%ssa%'
        OR LOWER(c.concept_name) LIKE '%ssb%'
        OR LOWER(c.concept_name) LIKE '%sm antibod%'
        OR LOWER(c.concept_name) LIKE '%rnp antibod%'
        OR LOWER(c.concept_name) LIKE '%scl-70%'
    )
    AND (
        m.value_as_concept_id IN (4126681, 9191, 4181412)
        OR UPPER(m.value_source_value) IN ('POSITIVE', 'DETECTED', 'REACTIVE', 'PRESENT')
        OR (m.value_as_number > m.range_high AND m.range_high IS NOT NULL)
    )
),
all_patients AS (
    SELECT DISTINCT person_id FROM victr_sd.sd_omop_prod.person -- REVISED (was: person)
),
patient_status AS (
    SELECT 
        ap.person_id,
        CASE WHEN MAX(CAST(cp.is_case AS INT)) = 1 THEN 1 ELSE 0 END as is_case,
        CASE 
            WHEN ed.person_id IS NULL
            AND es.person_id IS NULL
            AND MAX(CAST(cp.is_case AS INT)) = 0
            THEN 1 
            ELSE 0 
        END as is_control
    FROM all_patients ap
    LEFT JOIN case_patients cp ON ap.person_id = cp.person_id
    LEFT JOIN excluded_by_diagnosis ed ON ap.person_id = ed.person_id
    LEFT JOIN excluded_by_serology es ON ap.person_id = es.person_id
    GROUP BY ap.person_id, ed.person_id, es.person_id
)
SELECT 
    ps.person_id,
    CASE 
        WHEN ps.is_case = 1 THEN 'CASE'
        WHEN ps.is_control = 1 THEN 'CONTROL'
        ELSE 'EXCLUDED'
    END as cohort_status,
    CASE 
        WHEN ps.is_case = 1 THEN (
            SELECT STRING_AGG(DISTINCT cp2.disease_name, '; ')
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
INNER JOIN victr_sd.sd_omop_prod.person p ON ps.person_id = p.person_id -- REVISED (was: person)
WHERE ps.is_case = 1 OR ps.is_control = 1
ORDER BY 
    CASE 
        WHEN ps.is_case = 1 THEN 1
        WHEN ps.is_control = 1 THEN 2
        ELSE 3
    END,
    ps.person_id;