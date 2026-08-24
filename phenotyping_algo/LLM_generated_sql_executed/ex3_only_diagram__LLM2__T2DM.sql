-- =============================================================================
-- VUMC OMOP CONVERSION: RULES APPLIED
-- =============================================================================
-- Rule 1 (DB prefix): All tables prefixed with victr_sd.sd_omop_prod.*
-- Rule 2 (Wildcards): '_' in '250._1' etc. is correct single-char wildcard for ICD-9 4th digit — no fix needed
-- Rule 3 (Source tables): ICD codes filtered directly on condition_source_value (LIKE); removed redundant concept table subqueries
-- Rule 4 (Source value != codes): Drugs use concept_ancestor on drug_concept_id (not drug_source_value); measurements use measurement_concept_id (not measurement_source_value)
-- Rule 5 (Free-text LIKE): Not applicable — no free-text descriptive field filters in this query
-- Rule 6 (OR→UNION across tables): Not applicable — OR clauses operate within same table, not across different tables
-- Rule 7 (LEFT JOIN→UNION): Not applicable — single LEFT JOIN to provider in sub-path 2b, no consecutive LEFT JOINs with OR
-- Rule 8 (Remove NLP): Not applicable — no NLP/free-text extraction logic present
-- Rule 9 (Missing concepts): No missing/undefined codes identified — all concept_ids are standard OMOP IDs for T1DM/T2DM phenotyping
-- =============================================================================

WITH t2dm_cases AS (
    SELECT DISTINCT 
        p.person_id,
        'T2DM_CASE' AS phenotype_status
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
                    co.condition_source_value LIKE 'E10%'
                    OR co.condition_source_value LIKE '250._1'
                    OR co.condition_source_value LIKE '250._3'
                    OR co.condition_concept_id IN (201254, 435216, 201530, 201531, 201826, 40484648)
                )
            )
            AND (
                -- Sub-path 1a: Rx T1DM med = YES AND Rx T2DM med = YES AND T2DM Rx precedes T1DM Rx = YES
                (
                    -- Has T1DM medications (primarily insulins)
                    EXISTS (
                        SELECT 1 FROM victr_sd.sd_omop_prod.drug_exposure de
                        WHERE de.person_id = p.person_id 
                        AND de.drug_concept_id IN (
                            SELECT descendant_concept_id FROM victr_sd.sd_omop_prod.concept_ancestor 
                            WHERE ancestor_concept_id IN (21600713, 1502905, 1502855, 1502809, 1596977, 1550023)
                        )
                    )
                    -- Has T2DM medications (metformin, sulfonylureas, etc.)
                    AND EXISTS (
                        SELECT 1 FROM victr_sd.sd_omop_prod.drug_exposure de
                        WHERE de.person_id = p.person_id 
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
                    co.condition_source_value LIKE 'E10%'
                    OR co.condition_source_value LIKE '250._1'
                    OR co.condition_source_value LIKE '250._3'
                    OR co.condition_concept_id IN (201254, 435216, 201530, 201531, 201826, 40484648)
                )
            )
            -- Has T2DM diagnosis (ICD10: E11.*, ICD9: 250.x0, 250.x2)
            AND EXISTS (
                SELECT 1 FROM victr_sd.sd_omop_prod.condition_occurrence co
                WHERE co.person_id = p.person_id 
                AND (
                    co.condition_source_value LIKE 'E11%'
                    OR co.condition_source_value LIKE '250._0'
                    OR co.condition_source_value LIKE '250._2'
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
                -- Sub-path 2b: Rx T2DM med = NO AND T2DM Dx by physician >= 2
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
                            co.condition_source_value LIKE 'E11%'
                            OR co.condition_source_value LIKE '250._0'
                            OR co.condition_source_value LIKE '250._2'
                            OR co.condition_concept_id IN (201820, 442793, 443238, 4193704, 4196141)
                        )
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
                    co.condition_source_value LIKE 'E10%'
                    OR co.condition_source_value LIKE '250._1'
                    OR co.condition_source_value LIKE '250._3'
                    OR co.condition_concept_id IN (201254, 435216, 201530, 201531, 201826, 40484648)
                )
            )
            -- No T2DM diagnosis
            AND NOT EXISTS (
                SELECT 1 FROM victr_sd.sd_omop_prod.condition_occurrence co
                WHERE co.person_id = p.person_id 
                AND (
                    co.condition_source_value LIKE 'E11%'
                    OR co.condition_source_value LIKE '250._0'
                    OR co.condition_source_value LIKE '250._2'
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
        'CONTROL' AS phenotype_status
    FROM victr_sd.sd_omop_prod.person p
    WHERE 
        -- ===== CRITERION 1: >= 2 in-person physician visits =====
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
            AND m.measurement_concept_id IN (3004501, 3020399, 40758583, 40764999, 3003309, 40762352)
        )
        
        -- ===== CRITERION 3: NOT abnormal lab OR (abnormal lab AND NOT DM related DX) =====
        AND (
            -- No abnormal lab
            NOT EXISTS (
                SELECT 1 FROM victr_sd.sd_omop_prod.measurement m
                WHERE m.person_id = p.person_id 
                AND (
                    (m.measurement_concept_id IN (40758583, 3004501) AND m.value_as_number > 126 AND m.unit_concept_id = 8840)
                    OR (m.measurement_concept_id IN (3020399, 40764999, 3003309) AND m.value_as_number > 200 AND m.unit_concept_id = 8840)
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
                    AND (
                        -- T1DM
                        co.condition_source_value LIKE 'E10%'
                        OR co.condition_source_value LIKE '250._1'
                        OR co.condition_source_value LIKE '250._3'
                        -- T2DM
                        OR co.condition_source_value LIKE 'E11%'
                        OR co.condition_source_value LIKE '250._0'
                        OR co.condition_source_value LIKE '250._2'
                        -- Other DM
                        OR co.condition_source_value LIKE 'E08%'
                        OR co.condition_source_value LIKE 'E09%'
                        OR co.condition_source_value LIKE 'E13%'
                        OR co.condition_source_value LIKE 'O24%'
                        OR co.condition_source_value LIKE 'R73%'
                        OR co.condition_concept_id IN (201254, 435216, 201530, 201531, 201826, 40484648, 201820, 442793, 443238, 4193704, 4196141)
                    )
                )
            )
        )
        
        -- ===== CRITERION 4: NOT family Hx of DM =====
        AND NOT EXISTS (
            SELECT 1 FROM victr_sd.sd_omop_prod.observation o
            WHERE o.person_id = p.person_id 
            AND o.observation_concept_id IN (4167217, 4058286, 43054928, 4212540)
        )
        
        -- ===== CRITERION 5: NOT DM med or supplies order =====
        AND NOT EXISTS (
            SELECT 1 FROM victr_sd.sd_omop_prod.drug_exposure de
            WHERE de.person_id = p.person_id 
            AND (
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