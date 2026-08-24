CREATE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex3_only_diagram_LLM2_T2DM AS 

WITH t2dm_cases AS (
    SELECT DISTINCT 
        p.person_id,
        'T2DM_CASE' as phenotype_status
    FROM victr_sd.sd_omop_prod.person p
    WHERE 
        -- ===== PATHWAY 1: Has T1DM Dx with specific medication patterns =====
        (
            -- Has T1DM diagnosis (T1DM Dx = YES)
            EXISTS (
                SELECT 1 FROM victr_sd.sd_omop_prod.condition_occurrence co
                WHERE co.person_id = p.person_id 
                -- T1DM diagnosis codes (ICD10: E10.*, ICD9: 250.x1, 250.x3)
                AND (
                    (co.condition_source_value LIKE 'E10%' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD10CM'))
                    OR (co.condition_source_value LIKE '250._1' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD9CM'))
                    OR (co.condition_source_value LIKE '250._3' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD9CM'))
                    OR co.condition_concept_id IN (201254, 435216, 201530, 201531, 201826, 40484648)
                )
            )
            AND (
                -- Sub-path 1a: Rx T1DM med = YES AND Rx T2DM med = YES AND T2DM Rx precedes T1DM Rx = YES
                (
                    -- Has T1DM medications
                    EXISTS (
                        SELECT 1 FROM victr_sd.sd_omop_prod.drug_exposure de
                        WHERE de.person_id = p.person_id 
                        -- T1DM medications (primarily insulins)
                        AND de.drug_concept_id IN (
                            SELECT descendant_concept_id FROM victr_sd.sd_omop_prod.concept_ancestor 
                            WHERE ancestor_concept_id IN (21600713, 1502905, 1502855, 1502809, 1596977, 1550023)
                        )
                    )
                    -- Has T2DM medications
                    AND EXISTS (
                        SELECT 1 FROM victr_sd.sd_omop_prod.drug_exposure de
                        WHERE de.person_id = p.person_id 
                        -- T2DM medications (metformin, sulfonylureas, etc.)
                        AND de.drug_concept_id IN (
                            SELECT descendant_concept_id FROM victr_sd.sd_omop_prod.concept_ancestor 
                            WHERE ancestor_concept_id IN (1529331, 1502826, 1502855, 1510202, 1516766, 1525215, 1583722, 40239216, 43526465, 44785829, 45774751, 44816332)
                        )
                    )
                    -- T2DM Rx precedes T1DM Rx
                    AND (
                        SELECT MIN(de.drug_exposure_start_date) 
                        FROM victr_sd.sd_omop_prod.drug_exposure de
                        WHERE de.person_id = p.person_id 
                        AND de.drug_concept_id IN (
                            SELECT descendant_concept_id FROM victr_sd.sd_omop_prod.concept_ancestor 
                            WHERE ancestor_concept_id IN (1529331, 1502826, 1502855, 1510202, 1516766, 1525215, 1583722, 40239216, 43526465, 44785829, 45774751, 44816332)
                        )
                    ) < (
                        SELECT MIN(de.drug_exposure_start_date) 
                        FROM victr_sd.sd_omop_prod.drug_exposure de
                        WHERE de.person_id = p.person_id 
                        AND de.drug_concept_id IN (
                            SELECT descendant_concept_id FROM victr_sd.sd_omop_prod.concept_ancestor 
                            WHERE ancestor_concept_id IN (21600713, 1502905, 1502855, 1502809, 1596977, 1550023)
                        )
                    )
                )
                -- Sub-path 1b: Rx T1DM med = YES AND Rx T2DM med = NO AND Abnormal Lab = YES
                OR (
                    -- Has T1DM medications
                    EXISTS (
                        SELECT 1 FROM victr_sd.sd_omop_prod.drug_exposure de
                        WHERE de.person_id = p.person_id 
                        AND de.drug_concept_id IN (
                            SELECT descendant_concept_id FROM victr_sd.sd_omop_prod.concept_ancestor 
                            WHERE ancestor_concept_id IN (21600713, 1502905, 1502855, 1502809, 1596977, 1550023)
                        )
                    )
                    -- Does NOT have T2DM medications
                    AND NOT EXISTS (
                        SELECT 1 FROM victr_sd.sd_omop_prod.drug_exposure de
                        WHERE de.person_id = p.person_id 
                        AND de.drug_concept_id IN (
                            SELECT descendant_concept_id FROM victr_sd.sd_omop_prod.concept_ancestor 
                            WHERE ancestor_concept_id IN (1529331, 1502826, 1502855, 1510202, 1516766, 1525215, 1583722, 40239216, 43526465, 44785829, 45774751, 44816332)
                        )
                    )
                    -- Has Abnormal Lab
                    AND EXISTS (
                        SELECT 1 FROM victr_sd.sd_omop_prod.measurement m
                        WHERE m.person_id = p.person_id 
                        AND (
                            -- Fasting glucose > 126 mg/dL
                            (m.measurement_concept_id IN (40758583, 3004501) AND m.value_as_number > 126 AND m.unit_concept_id = 8840)
                            -- Random/2hr glucose > 200 mg/dL
                            OR (m.measurement_concept_id IN (3020399, 40764999, 3003309) AND m.value_as_number > 200 AND m.unit_concept_id = 8840)
                            -- HbA1c > 6.5%
                            OR (m.measurement_concept_id = 40762352 AND m.value_as_number > 6.5 AND m.unit_concept_id = 8554)
                        )
                    )
                )
                -- Sub-path 1c: Rx T1DM med = NO AND Rx T2DM med = YES
                OR (
                    -- Does NOT have T1DM medications
                    NOT EXISTS (
                        SELECT 1 FROM victr_sd.sd_omop_prod.drug_exposure de
                        WHERE de.person_id = p.person_id 
                        AND de.drug_concept_id IN (
                            SELECT descendant_concept_id FROM victr_sd.sd_omop_prod.concept_ancestor 
                            WHERE ancestor_concept_id IN (21600713, 1502905, 1502855, 1502809, 1596977, 1550023)
                        )
                    )
                    -- Has T2DM medications
                    AND EXISTS (
                        SELECT 1 FROM victr_sd.sd_omop_prod.drug_exposure de
                        WHERE de.person_id = p.person_id 
                        AND de.drug_concept_id IN (
                            SELECT descendant_concept_id FROM victr_sd.sd_omop_prod.concept_ancestor 
                            WHERE ancestor_concept_id IN (1529331, 1502826, 1502855, 1510202, 1516766, 1525215, 1583722, 40239216, 43526465, 44785829, 45774751, 44816332)
                        )
                    )
                )
            )
        )
        
        -- ===== PATHWAY 2: T1DM Dx = NO AND T2DM Dx = YES =====
        OR (
            -- No T1DM diagnosis
            NOT EXISTS (
                SELECT 1 FROM victr_sd.sd_omop_prod.condition_occurrence co
                WHERE co.person_id = p.person_id 
                AND (
                    (co.condition_source_value LIKE 'E10%' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD10CM'))
                    OR (co.condition_source_value LIKE '250._1' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD9CM'))
                    OR (co.condition_source_value LIKE '250._3' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD9CM'))
                    OR co.condition_concept_id IN (201254, 435216, 201530, 201531, 201826, 40484648)
                )
            )
            -- Has T2DM diagnosis
            AND EXISTS (
                SELECT 1 FROM victr_sd.sd_omop_prod.condition_occurrence co
                WHERE co.person_id = p.person_id 
                -- T2DM diagnosis codes (ICD10: E11.*, ICD9: 250.x0, 250.x2)
                AND (
                    (co.condition_source_value LIKE 'E11%' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD10CM'))
                    OR (co.condition_source_value LIKE '250._0' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD9CM'))
                    OR (co.condition_source_value LIKE '250._2' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD9CM'))
                    OR co.condition_concept_id IN (201820, 442793, 443238, 4193704, 4196141)
                )
            )
            AND (
                -- Sub-path 2a: Rx T2DM med = YES
                EXISTS (
                    SELECT 1 FROM victr_sd.sd_omop_prod.drug_exposure de
                    WHERE de.person_id = p.person_id 
                    AND de.drug_concept_id IN (
                        SELECT descendant_concept_id FROM victr_sd.sd_omop_prod.concept_ancestor 
                        WHERE ancestor_concept_id IN (1529331, 1502826, 1502855, 1510202, 1516766, 1525215, 1583722, 40239216, 43526465, 44785829, 45774751, 44816332)
                    )
                )
                -- Sub-path 2b: Rx T2DM med = NO AND T2DM Dx by physscn >= 2
                OR (
                    -- No T2DM medications
                    NOT EXISTS (
                        SELECT 1 FROM victr_sd.sd_omop_prod.drug_exposure de
                        WHERE de.person_id = p.person_id 
                        AND de.drug_concept_id IN (
                            SELECT descendant_concept_id FROM victr_sd.sd_omop_prod.concept_ancestor 
                            WHERE ancestor_concept_id IN (1529331, 1502826, 1502855, 1510202, 1516766, 1525215, 1583722, 40239216, 43526465, 44785829, 45774751, 44816332)
                        )
                    )
                    -- T2DM diagnosed by physician at least 2 times
                    AND (
                        SELECT COUNT(DISTINCT co.condition_occurrence_id) 
                        FROM victr_sd.sd_omop_prod.condition_occurrence co
                        LEFT JOIN victr_sd.sd_omop_prod.provider pr ON co.provider_id = pr.provider_id
                        WHERE co.person_id = p.person_id 
                        AND (
                            (co.condition_source_value LIKE 'E11%' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD10CM'))
                            OR (co.condition_source_value LIKE '250._0' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD9CM'))
                            OR (co.condition_source_value LIKE '250._2' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD9CM'))
                            OR co.condition_concept_id IN (201820, 442793, 443238, 4193704, 4196141)
                        )
                        -- Physician specialties
                        AND (pr.specialty_concept_id IN (38004446, 38004451, 38004453, 38004497) OR pr.provider_id IS NOT NULL)
                    ) >= 2
                )
            )
        )
        
        -- ===== PATHWAY 3: T1DM Dx = NO AND T2DM Dx = NO AND Rx T2DM med = YES AND Abnormal Lab = YES =====
        OR (
            -- No T1DM diagnosis
            NOT EXISTS (
                SELECT 1 FROM victr_sd.sd_omop_prod.condition_occurrence co
                WHERE co.person_id = p.person_id 
                AND (
                    (co.condition_source_value LIKE 'E10%' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD10CM'))
                    OR (co.condition_source_value LIKE '250._1' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD9CM'))
                    OR (co.condition_source_value LIKE '250._3' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD9CM'))
                    OR co.condition_concept_id IN (201254, 435216, 201530, 201531, 201826, 40484648)
                )
            )
            -- No T2DM diagnosis
            AND NOT EXISTS (
                SELECT 1 FROM victr_sd.sd_omop_prod.condition_occurrence co
                WHERE co.person_id = p.person_id 
                AND (
                    (co.condition_source_value LIKE 'E11%' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD10CM'))
                    OR (co.condition_source_value LIKE '250._0' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD9CM'))
                    OR (co.condition_source_value LIKE '250._2' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD9CM'))
                    OR co.condition_concept_id IN (201820, 442793, 443238, 4193704, 4196141)
                )
            )
            -- Has T2DM medications
            AND EXISTS (
                SELECT 1 FROM victr_sd.sd_omop_prod.drug_exposure de
                WHERE de.person_id = p.person_id 
                AND de.drug_concept_id IN (
                    SELECT descendant_concept_id FROM victr_sd.sd_omop_prod.concept_ancestor 
                    WHERE ancestor_concept_id IN (1529331, 1502826, 1502855, 1510202, 1516766, 1525215, 1583722, 40239216, 43526465, 44785829, 45774751, 44816332)
                )
            )
            -- Has Abnormal Lab
            AND EXISTS (
                SELECT 1 FROM victr_sd.sd_omop_prod.measurement m
                WHERE m.person_id = p.person_id 
                AND (
                    -- Fasting glucose > 126 mg/dL
                    (m.measurement_concept_id IN (40758583, 3004501) AND m.value_as_number > 126 AND m.unit_concept_id = 8840)
                    -- Random/2hr glucose > 200 mg/dL
                    OR (m.measurement_concept_id IN (3020399, 40764999, 3003309) AND m.value_as_number > 200 AND m.unit_concept_id = 8840)
                    -- HbA1c > 6.5%
                    OR (m.measurement_concept_id = 40762352 AND m.value_as_number > 6.5 AND m.unit_concept_id = 8554)
                )
            )
        )
),

-- =====================================================
-- PART 2: IDENTIFY T2DM CONTROLS
-- =====================================================
-- A patient is classified as CONTROL if they meet ALL criteria below

t2dm_controls AS (
    SELECT DISTINCT 
        p.person_id,
        'CONTROL' as phenotype_status
    FROM victr_sd.sd_omop_prod.person p
    WHERE 
        -- ===== CRITERION 1: >= 2 in person pyhscn visits =====
        (
            SELECT COUNT(DISTINCT vo.visit_occurrence_id)
            FROM victr_sd.sd_omop_prod.visit_occurrence vo
            LEFT JOIN victr_sd.sd_omop_prod.provider pr ON vo.provider_id = pr.provider_id
            WHERE vo.person_id = p.person_id
            -- In-person visit types (outpatient, office visit, clinic visit)
            AND vo.visit_concept_id IN (9201, 9202, 581477, 581478, 5083)
            -- Physician provider
            AND (pr.specialty_concept_id IN (38004446, 38004451, 38004453, 38004497) OR vo.provider_id IS NOT NULL)
        ) >= 2
        
        -- ===== CRITERION 2: >= 1 glucose measure =====
        AND EXISTS (
            SELECT 1 FROM victr_sd.sd_omop_prod.measurement m
            WHERE m.person_id = p.person_id 
            -- Glucose measurement codes
            AND m.measurement_concept_id IN (3004501, 3020399, 40758583, 40764999, 3003309, 40762352)
        )
        
        -- ===== CRITERION 3: NOT abnormal lab OR (abnormal lab AND NOT DM related DX) =====
        AND (
            -- No abnormal lab
            NOT EXISTS (
                SELECT 1 FROM victr_sd.sd_omop_prod.measurement m
                WHERE m.person_id = p.person_id 
                AND (
                    -- Fasting glucose > 126 mg/dL
                    (m.measurement_concept_id IN (40758583, 3004501) AND m.value_as_number > 126 AND m.unit_concept_id = 8840)
                    -- Random/2hr glucose > 200 mg/dL
                    OR (m.measurement_concept_id IN (3020399, 40764999, 3003309) AND m.value_as_number > 200 AND m.unit_concept_id = 8840)
                    -- HbA1c > 6.5%
                    OR (m.measurement_concept_id = 40762352 AND m.value_as_number > 6.5 AND m.unit_concept_id = 8554)
                )
            )
            -- OR has abnormal lab but no DM related diagnosis
            OR (
                EXISTS (
                    SELECT 1 FROM victr_sd.sd_omop_prod.measurement m
                    WHERE m.person_id = p.person_id 
                    AND (
                        (m.measurement_concept_id IN (40758583, 3004501) AND m.value_as_number > 126 AND m.unit_concept_id = 8840)
                        OR (m.measurement_concept_id IN (3020399, 40764999, 3003309) AND m.value_as_number > 200 AND m.unit_concept_id = 8840)
                        OR (m.measurement_concept_id = 40762352 AND m.value_as_number > 6.5 AND m.unit_concept_id = 8554)
                    )
                )
                AND NOT EXISTS (
                    SELECT 1 FROM victr_sd.sd_omop_prod.condition_occurrence co
                    WHERE co.person_id = p.person_id 
                    -- All diabetes-related diagnoses
                    AND (
                        -- T1DM
                        (co.condition_source_value LIKE 'E10%' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD10CM'))
                        OR (co.condition_source_value LIKE '250._1' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD9CM'))
                        OR (co.condition_source_value LIKE '250._3' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD9CM'))
                        -- T2DM
                        OR (co.condition_source_value LIKE 'E11%' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD10CM'))
                        OR (co.condition_source_value LIKE '250._0' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD9CM'))
                        OR (co.condition_source_value LIKE '250._2' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD9CM'))
                        -- Other DM
                        OR (co.condition_source_value LIKE 'E08%' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD10CM'))
                        OR (co.condition_source_value LIKE 'E09%' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD10CM'))
                        OR (co.condition_source_value LIKE 'E13%' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD10CM'))
                        OR (co.condition_source_value LIKE 'O24%' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD10CM'))
                        OR (co.condition_source_value LIKE 'R73%' AND co.condition_source_concept_id IN (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id = 'ICD10CM'))
                        OR co.condition_concept_id IN (201254, 435216, 201530, 201531, 201826, 40484648, 201820, 442793, 443238, 4193704, 4196141)
                    )
                )
            )
        )
        
        -- ===== CRITERION 4: NOT family Hx of DM =====
        AND NOT EXISTS (
            SELECT 1 FROM victr_sd.sd_omop_prod.observation o
            WHERE o.person_id = p.person_id 
            -- Family history of diabetes codes
            AND o.observation_concept_id IN (4167217, 4058286, 43054928, 4212540)
        )
        
        -- ===== CRITERION 5: NOT DM med or supplies order =====
        AND NOT EXISTS (
            SELECT 1 FROM victr_sd.sd_omop_prod.drug_exposure de
            WHERE de.person_id = p.person_id 
            AND (
                -- Any diabetes medications (T1DM or T2DM)
                de.drug_concept_id IN (
                    SELECT descendant_concept_id FROM victr_sd.sd_omop_prod.concept_ancestor 
                    WHERE ancestor_concept_id IN (
                        -- T1DM meds
                        21600713, 1502905, 1502855, 1502809, 1596977, 1550023,
                        -- T2DM meds
                        1529331, 1502826, 1502855, 1510202, 1516766, 1525215, 1583722, 40239216, 43526465, 44785829, 45774751, 44816332
                    )
                )
                -- Diabetes supplies
                OR de.drug_concept_id IN (2213407, 2213697, 2617960, 46273477)
            )
        )
        
        -- ===== Exclude patients already identified as cases =====
        AND p.person_id NOT IN (SELECT person_id FROM t2dm_cases)
)

-- =====================================================
-- FINAL OUTPUT: Combine cases and controls
-- =====================================================
SELECT 
    person_id,
    phenotype_status
FROM t2dm_cases

UNION ALL

SELECT 
    person_id,
    phenotype_status
FROM t2dm_controls

ORDER BY phenotype_status DESC, person_id;