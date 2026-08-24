-- Rule 1 (VUMC-specific database name): APPLIED (all OMOP tables use victr_sd.sd_omop_prod)
-- Rule 2 (Fix wildcards): NOT APPLICABLE
-- Rule 3 (Concept table vs. clinical data): APPLIED (ICD code logic uses condition_source_value, LOINC logic uses concept join, RxNorm not used here)
-- Rule 4 (Standard code handling): APPLIED (ICD/LOINC code logic per OMOP conventions)
-- Rule 5 (Free-text LIKE): NOT APPLICABLE
-- Rule 6 (OR -> UNION): NOT APPLICABLE
-- Rule 7 (LEFT JOINs with OR -> UNION): NOT APPLICABLE
-- Rule 8 (Remove NLP/free-text): NOT APPLICABLE
-- Rule 9 (Missing/ambiguous concept codes): NOT APPLICABLE
-- FIX: All ICD code lookups use condition_source_value, not concept_id
-- FIX: All code set lookups reference the correct columns per OMOP conventions
-- FIX: LOINC logic uses concept join on measurement_concept_id

CREATE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex1_all_content_LLM1_AID AS 

WITH
-- REVISED (was: FROM condition_occurrence AS co)
dx AS (
    SELECT  co.person_id,
            cs.disease_id,
            co.condition_start_date
    FROM    victr_sd.sd_omop_prod.condition_occurrence AS co
    JOIN    workspace_sdphenotypecore.phenotyping_algorithm_agent.aid_case_codes AS cs
           ON cs.concept_id = co.condition_concept_id -- Fixed by Sander
),
dx_agg AS (
    SELECT  person_id,
            disease_id,
            COUNT(DISTINCT condition_start_date)                AS dx_cnt,
            MIN(condition_start_date)                           AS first_dt,
            MAX(condition_start_date)                           AS last_dt
    FROM    dx
    GROUP BY person_id, disease_id
    HAVING  dx_cnt >= 3
       AND  DATEDIFF(last_dt, first_dt) >= 7 -- REVISED (was: DATE_PART('day', last_dt - first_dt) >= 7)
),
case_candidates AS (
    SELECT  d.person_id
    FROM    dx_agg AS d
    LEFT JOIN victr_sd.sd_omop_prod.condition_occurrence t2
           ON t2.person_id = d.person_id
          AND t2.condition_source_value IN (SELECT concept_id FROM workspace_sdphenotypecore.phenotyping_algorithm_agent.t2dm_codes) -- Fixed by Sander
    WHERE NOT (d.disease_id = 'T1DM' AND t2.person_id IS NOT NULL)
),
CASES AS (SELECT DISTINCT person_id FROM case_candidates),
ctl_dx_excl AS (
    SELECT DISTINCT person_id
    FROM   victr_sd.sd_omop_prod.condition_occurrence
    WHERE  condition_source_value IN (SELECT concept_code FROM workspace_sdphenotypecore.phenotyping_algorithm_agent.aai_exclude_codes) -- Fixed by Sander
),
ctl_serology_excl AS (
    SELECT DISTINCT m.person_id
    FROM   victr_sd.sd_omop_prod.measurement AS m
    JOIN   victr_sd.sd_omop_prod.concept AS c
           ON m.measurement_concept_id = c.concept_id
    WHERE  c.vocabulary_id = 'LOINC' -- Fixed by Sander
      AND  c.concept_code IN (SELECT concept_code FROM workspace_sdphenotypecore.phenotyping_algorithm_agent.serology_codes)
      AND (
        m.value_as_number  IS NOT NULL
            AND m.range_high    IS NOT NULL
            AND m.value_as_number >= m.range_high
          )
),
CONTROLS AS (
    SELECT  p.person_id
    FROM    victr_sd.sd_omop_prod.person               AS p
    LEFT JOIN CASES              AS c  ON c.person_id = p.person_id
    LEFT JOIN ctl_dx_excl        AS d  ON d.person_id = p.person_id
    LEFT JOIN ctl_serology_excl  AS s  ON s.person_id = p.person_id
    WHERE   c.person_id IS NULL   -- not a case
      AND   d.person_id IS NULL   -- no excluded diagnoses
      AND   s.person_id IS NULL   -- no positive serology
)
SELECT 'CASE'    AS cohort_type, person_id FROM CASES
UNION ALL
SELECT 'CONTROL' AS cohort_type, person_id FROM CONTROLS;
