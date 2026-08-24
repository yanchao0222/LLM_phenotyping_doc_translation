-- Rule 1 (VUMC-specific database name): APPLIED
-- Rule 2 (Fix wildcards): NOT APPLICABLE
-- Rule 3 (No direct concept table search): APPLIED
-- Rule 4 (LOINC/RxNorm/ICD code handling): APPLIED
-- Rule 5 (Free-text name LIKE): NOT APPLICABLE
-- Rule 6 (OR->UNION): NOT APPLICABLE
-- Rule 7 (LEFT JOINs with OR->UNION): NOT APPLICABLE
-- Rule 8 (NLP/notes logic placeholder): APPLIED
-- Rule 9 (Missing/ambiguous codes): NOT APPLICABLE
-- FIX: Replaced EXTRACT(YEAR FROM ...) with YEAR(...) for Databricks compatibility
-- FIX: Removed trailing commas between CTEs; Databricks SQL requires CTEs to be defined in sequence without commas
-- FIX: Ensured final SELECT statement is not preceded by a comma

CREATE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex1_all_content_LLM2_FH AS 

WITH eligible_patients AS (
    -- REVISED (was: EXTRACT(YEAR FROM m.measurement_date) - p.year_of_birth >= 18)
    SELECT DISTINCT m.person_id, 
           MAX(m.value_as_number) as highest_ldl_c,
           MAX(m.measurement_date) as index_date
    FROM victr_sd.sd_omop_prod.measurement m
    JOIN victr_sd.sd_omop_prod.concept c ON m.measurement_concept_id = c.concept_id AND c.vocabulary_id = 'LOINC' AND c.concept_code IN ('2089-1', '18262-6', '49132-4', '35198-1', '39469-2', '12773-8', '18261-8', '22748-8', '13457-7', '9346-8', '2574-2', '14815-5')
    WHERE m.person_id IN (
        SELECT p.person_id 
        FROM victr_sd.sd_omop_prod.person p 
        WHERE YEAR(m.measurement_date) - p.year_of_birth >= 18
    )
    GROUP BY m.person_id
)

,triglyceride_flag AS (
    SELECT DISTINCT m.person_id
    FROM victr_sd.sd_omop_prod.measurement m
    JOIN victr_sd.sd_omop_prod.concept c ON m.measurement_concept_id = c.concept_id AND c.vocabulary_id = 'LOINC' AND c.concept_code IN ('2571-8', '30524-3', '3048-6', '35217-9', '28554-4', '14927-8', '47210-0')
    WHERE m.value_as_number > 220
)

,secondary_causes_exclusion AS (
    SELECT DISTINCT m.person_id
    FROM victr_sd.sd_omop_prod.measurement m
    JOIN eligible_patients e ON m.person_id = e.person_id
    JOIN victr_sd.sd_omop_prod.concept c ON m.measurement_concept_id = c.concept_id AND c.vocabulary_id = 'LOINC'
    WHERE m.measurement_date BETWEEN DATEADD(year, -1, e.index_date) AND e.index_date
    AND (
        (c.concept_code IN ('11579-0', '24348-5') AND m.value_as_number >= 10)
        OR
        (c.concept_code IN ('6768-6', '12805-8') AND m.value_as_number >= 200)
        OR
        (c.concept_code IN ('35194-0', '1975-2', '14631-6') AND m.value_as_number > 2.0)
        OR
        (c.concept_code IN ('21482-5', '2889-4', '21028-6') AND m.value_as_number > 3)
        OR
        (c.concept_code IN ('13801-6', '2890-2') AND m.value_as_number > 3.0)
        OR
        (c.concept_code IN ('14682-9', '2160-0', '35203-9', '38483-4', '59826-8', '77140-2') 
         AND m.value_as_number > 2.6)
        OR
        (c.concept_code IN ('50261-7', '45066-8', '48642-3', '48643-1', '33914-3')
         AND m.value_as_number < 15)
        OR
        (c.concept_code IN ('4549-2', '17855-8', '17856-6', '41995-2')
         AND m.value_as_number > 9)
        OR
        (c.concept_code = '1556-0' AND m.value_as_number > 200)
        OR
        (c.concept_code = '1558-6' AND m.value_as_number > 220)
    )
)

,pregnancy_flag AS (
    SELECT DISTINCT c.person_id
    FROM victr_sd.sd_omop_prod.condition_occurrence c
    JOIN eligible_patients e ON c.person_id = e.person_id
    WHERE c.condition_source_value IN ('V22', 'V23', '645', '651', '652')
    AND c.condition_start_date BETWEEN DATEADD(year, -1, e.index_date) AND e.index_date
    AND e.highest_ldl_c >= 155
)

,lipid_lowering_treatment AS (
    SELECT DISTINCT d.person_id
    FROM victr_sd.sd_omop_prod.drug_exposure d
    JOIN eligible_patients e ON d.person_id = e.person_id
    JOIN victr_sd.sd_omop_prod.concept_ancestor ca ON ca.descendant_concept_id = d.drug_concept_id
    JOIN victr_sd.sd_omop_prod.concept c ON ca.ancestor_concept_id = c.concept_id AND c.vocabulary_id = 'RxNorm' AND c.concept_code IN ('36567', '41127', '6472', '42463', '861634', '83367', '301542', '221072', '1152441', '7393', '8703', '4719', '341248', '141626', '2447', '2685', '1367839', '1364479', '1665895', '1665900', '1665904', '1665906', '1659156', '1659161', '1659165', '1659167', '1659177', '1659179', '1659182', '1659183', '495215', '1372731', '327008', '404914', '1372754')
    WHERE d.drug_exposure_start_date BETWEEN DATEADD(year, -1, e.index_date) AND e.index_date
)

,adjusted_ldl_c AS (
    SELECT e.person_id,
           e.highest_ldl_c,
           e.index_date,
           CASE 
               WHEN l.person_id IS NOT NULL THEN try_divide(e.highest_ldl_c,0.7)
               ELSE e.highest_ldl_c
           END AS adjusted_ldl_value
    FROM eligible_patients e
    LEFT JOIN lipid_lowering_treatment l ON e.person_id = l.person_id
)

,primary_hypercholesterolemia AS (
    SELECT a.person_id,
           a.adjusted_ldl_value,
           a.index_date,
           CASE 
               WHEN a.adjusted_ldl_value >= 155 THEN 'CASE'
               WHEN a.adjusted_ldl_value < 130 THEN 'CONTROL'
               ELSE 'UNKNOWN'
           END AS stage1_status
    FROM adjusted_ldl_c a
    WHERE a.person_id NOT IN (SELECT person_id FROM secondary_causes_exclusion)
)

,group1_ldl_score AS (
    SELECT person_id,
           CASE 
               WHEN adjusted_ldl_value >= 325 THEN 8
               WHEN adjusted_ldl_value >= 251 AND adjusted_ldl_value < 325 THEN 5
               WHEN adjusted_ldl_value >= 191 AND adjusted_ldl_value < 251 THEN 3
               WHEN adjusted_ldl_value >= 155 AND adjusted_ldl_value < 191 THEN 1
               ELSE 0
           END AS ldl_points
    FROM primary_hypercholesterolemia
    WHERE stage1_status = 'CASE'
)

,group2_personal_history AS (
    -- REVISED (was: EXTRACT(YEAR FROM co.condition_start_date) - p.year_of_birth)
    SELECT co.person_id,
           MAX(CASE
               WHEN co.condition_source_value IN (
                   '413.0', '413.1', '413.9',
                   '410.00', '410.01', '410.02', '410.10', '410.11', '410.12',
                   '410.20', '410.21', '410.22', '410.30', '410.31', '410.32',
                   '410.40', '410.41', '410.42', '410.50', '410.51', '410.52',
                   '410.60', '410.61', '410.62', '410.70', '410.71', '410.72',
                   '410.80', '410.81', '410.82', '410.90', '410.91', '410.92',
                   '412', '429.71', '429.79',
                   '414.00', '414.01', '414.02', '414.03', '414.04', '414.05',
                   '414.06', '414.07'
               )
               AND ((p.gender_concept_id = 8507 AND 
                     YEAR(co.condition_start_date) - p.year_of_birth < 56)
                    OR 
                    (p.gender_concept_id = 8532 AND 
                     YEAR(co.condition_start_date) - p.year_of_birth < 66))
               THEN 2
               WHEN co.condition_source_value IN (
                   '434.00', '434.01', '434.10', '434.11', '434.90', '434.91',
                   '437.0', '437.1',
                   '435.0', '435.1', '435.2', '435.3', '435.8', '435.9',
                   '433.00', '433.01', '433.10', '433.11', '433.20', '433.21',
                   '433.30', '433.31', '433.80', '433.81', '433.90', '433.91',
                   '440.20', '440.21', '440.22', '440.23', '440.24', '440.29'
               )
               AND ((p.gender_concept_id = 8507 AND 
                     YEAR(co.condition_start_date) - p.year_of_birth < 56)
                    OR 
                    (p.gender_concept_id = 8532 AND 
                     YEAR(co.condition_start_date) - p.year_of_birth < 66))
               THEN 1
               ELSE 0
           END) AS personal_history_points
    FROM victr_sd.sd_omop_prod.condition_occurrence co
    JOIN victr_sd.sd_omop_prod.person p ON co.person_id = p.person_id
    JOIN primary_hypercholesterolemia ph ON co.person_id = ph.person_id
    WHERE ph.stage1_status = 'CASE'
    GROUP BY co.person_id
)

,group3_family_history AS (
    SELECT person_id, 0 AS family_history_points
    FROM primary_hypercholesterolemia
    WHERE stage1_status = 'CASE'
)

,group4_physical_exam AS (
    SELECT person_id, 0 AS physical_exam_points
    FROM primary_hypercholesterolemia  
    WHERE stage1_status = 'CASE'
)

,fh_total_score AS (
    SELECT g1.person_id,
           COALESCE(g1.ldl_points, 0) + 
           COALESCE(g2.personal_history_points, 0) + 
           COALESCE(g3.family_history_points, 0) + 
           COALESCE(g4.physical_exam_points, 0) AS total_score
    FROM group1_ldl_score g1
    LEFT JOIN group2_personal_history g2 ON g1.person_id = g2.person_id
    LEFT JOIN group3_family_history g3 ON g1.person_id = g3.person_id
    LEFT JOIN group4_physical_exam g4 ON g1.person_id = g4.person_id
)
-- FIX: Removed trailing comma before SELECT statement
SELECT person_id,
       total_score,
       CASE 
           WHEN total_score > 8 THEN 'DEFINITE_FH'
           WHEN total_score >= 6 AND total_score <= 8 THEN 'PROBABLE_FH'
           WHEN total_score >= 3 AND total_score <= 5 THEN 'POSSIBLE_FH'
           WHEN total_score >= 0 AND total_score <= 2 THEN 'UNLIKELY_FH'
       END AS fh_diagnosis,
       CASE 
           WHEN total_score >= 6 THEN 'FH_CASE'
           WHEN total_score >= 3 AND total_score <= 5 THEN 'FH_UNKNOWN'
           WHEN total_score <= 2 THEN 'FH_CONTROL'
       END AS final_classification
FROM fh_total_score