
-- Rule 1 (VUMC-specific database name): APPLIED - replaced unqualified OMOP tables with `victr_sd`.`sd_omop_prod` tables
-- Rule 2 (incorrect wildcard characters): NOT APPLICABLE
-- Rule 3 (search standardized clinical data tables instead of Concept table for codes): APPLIED - condition logic uses `condition_occurrence`; measurement logic keeps OMOP measurement + concept join pattern
-- Rule 4 (standard codes exact match; measurement/drug handling): APPLIED - measurement section revised to join `concept` for LOINC; no RxNorm logic present
-- Rule 5 (free-text descriptive fields use LOWER LIKE): NOT APPLICABLE
-- Rule 6 (replace OR with UNION across tables): NOT APPLICABLE
-- Rule 7 (replace LEFT JOIN chains combined with OR using UNION): NOT APPLICABLE
-- Rule 8 (remove NLP/free-text logic not runnable in SQL): APPLIED - removed citation/contentReference artifacts as non-SQL text
-- Rule 9 (mark missing/undefined/ambiguous concepts inline): APPLIED - staging coding dictionary and unresolved phenotype code lists marked missing inline

/*======================================================================
  AUTOIMMUNE DISEASE (AID) PHENOTYPE - FINAL EXECUTABLE SQL
  ---------------------------------------------------------------------
  Preserves cohort logic structure, but source code lists are undefined in the
  provided schema and are therefore marked inline instead of guessed.
======================================================================*/

CREATE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex2_only_text_LLM1_AID AS 

WITH
/*--------------------------------------------------------------------
  1. CODE-SET MATERIALISATION
  ------------------------------------------------------------------*/
coding_dictionary AS (
    -- MISSING CONCEPT: source code list table `staging.aid_coding_dictionary` is not available in provided schema
    SELECT *
    FROM workspace_sdphenotypecore.phenotyping_algorithm_agent.all_phenotype_codes
),

autoimmune_dx AS (
    SELECT
        concept_id,
        CAST(REGEXP_REPLACE(vocabulary, '.*subphenotype', '') AS INT) AS disease_id
    FROM coding_dictionary
    WHERE vocabulary ILIKE 'dx.autoimmune.subphenotype%'
       OR vocabulary ILIKE 'autoimmune.subphenotype%'
),

autoinflammatory_dx AS (
    SELECT concept_id
    FROM coding_dictionary
    WHERE vocabulary ILIKE '%dx.autoinflammatoryautoimmune%'
),

t2dm_dx AS (
    SELECT concept_id
    FROM coding_dictionary
    WHERE vocabulary ILIKE '%dx.t2dm%'
),

serology_tests AS (
    SELECT concept_id
    FROM coding_dictionary
    WHERE vocabulary ILIKE 'lab.serology.%'
),

/*--------------------------------------------------------------------
  2. PATIENT-LEVEL DERIVED FLAGS
  ------------------------------------------------------------------*/
autoimmune_episode AS (
    SELECT
        co.person_id,
        ad.disease_id,
        COUNT(DISTINCT co.condition_start_date) AS dx_days,
        MIN(co.condition_start_date) AS first_day,
        MAX(co.condition_start_date) AS last_day
    FROM
        -- REVISED (was: FROM    condition_occurrence      co)
        `victr_sd`.`sd_omop_prod`.`condition_occurrence` co
    JOIN autoimmune_dx ad
        ON ad.concept_id = co.condition_concept_id
    GROUP BY co.person_id, ad.disease_id
    HAVING COUNT(DISTINCT co.condition_start_date) >= 3
       AND DATEDIFF(MAX(co.condition_start_date), MIN(co.condition_start_date)) >= 7
),

t2dm_flag AS (
    SELECT DISTINCT person_id
    FROM
        -- REVISED (was: FROM    condition_occurrence)
        `victr_sd`.`sd_omop_prod`.`condition_occurrence`
    WHERE condition_concept_id IN (SELECT concept_id FROM t2dm_dx)
),

any_auto_dx AS (
    SELECT DISTINCT person_id
    FROM
        -- REVISED (was: FROM   condition_occurrence)
        `victr_sd`.`sd_omop_prod`.`condition_occurrence`
    WHERE condition_concept_id IN (
        SELECT concept_id FROM autoimmune_dx
        UNION
        SELECT concept_id FROM autoinflammatory_dx
    )
),

positive_serology AS (
    SELECT DISTINCT m.person_id
    FROM
        -- REVISED (was: FROM   measurement m)
        `victr_sd`.`sd_omop_prod`.`measurement` m
    JOIN
        -- REVISED (was: no concept join present for LOINC-coded measurements)
        `victr_sd`.`sd_omop_prod`.`concept` c
        ON c.concept_id = m.measurement_concept_id
    WHERE m.measurement_concept_id IN (SELECT concept_id FROM serology_tests)
      -- REVISED (was: no vocabulary guard present for LOINC-coded measurements)
      AND c.vocabulary_id = 'LOINC'
      AND (
            m.value_as_concept_id = 45877985
            OR m.value_as_number > COALESCE(m.range_low, 0)
          )
),

/*--------------------------------------------------------------------
  3. COHORT ASSIGNMENT
  ------------------------------------------------------------------*/
case_cohort AS (
    SELECT DISTINCT ae.person_id
    FROM autoimmune_episode ae
    LEFT JOIN t2dm_flag t2
        ON t2.person_id = ae.person_id
    WHERE NOT (
        ae.disease_id = 15
        AND t2.person_id IS NOT NULL
    )
),

control_cohort AS (
    SELECT p.person_id
    FROM
        -- REVISED (was: FROM    person               p)
        `victr_sd`.`sd_omop_prod`.`person` p
    LEFT JOIN any_auto_dx ad
        ON ad.person_id = p.person_id
    LEFT JOIN positive_serology ps
        ON ps.person_id = p.person_id
    WHERE ad.person_id IS NULL
      AND ps.person_id IS NULL
      AND p.person_id NOT IN (SELECT person_id FROM case_cohort)
)

/*--------------------------------------------------------------------
  4. FINAL RESULTSET
  ------------------------------------------------------------------*/
SELECT 'CASE' AS cohort_type, person_id FROM case_cohort
UNION ALL
SELECT 'CONTROL' AS cohort_type, person_id FROM control_cohort;