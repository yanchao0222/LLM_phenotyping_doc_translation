-- Rule 1 (VUMC-specific database name): APPLIED
-- Rule 2 (Fix incorrect wildcard characters): NOT APPLICABLE
-- Rule 3 (Replace searching for concepts in Concept table with clinical data tables): APPLIED (see measurement/drug/condition logic)
-- Rule 4 (LOINC/RxNorm code handling): APPLIED (see measurement/drug logic)
-- Rule 5 (Free-text descriptive fields): NOT APPLICABLE
-- Rule 6 (OR -> UNION): APPLIED (see exclusion_dx)
-- Rule 7 (LEFT JOIN -> UNION): APPLIED (see exclusion_dx)
-- Rule 8 (Remove NLP/free-text logic): NOT APPLICABLE
-- Rule 9 (Mark missing/ambiguous concepts): NOT APPLICABLE
-- FIX: Replaced DATE '9999-12-31' with '9999-12-31' (string literal) for Databricks compatibility
-- FIX: Compute evidence_count in a subquery, then filter in the outer query
-- FIX: Use DATEDIFF for date difference in control_candidates
-- FIX: Remove trailing comma after last CTE
-- FIX: Use explicit JOIN syntax for USING

CREATE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex3_only_diagram_LLM1_T2DM AS 

WITH
  dx_t2dm AS (
      SELECT descendant_concept_id AS concept_id
      FROM victr_sd.sd_omop_prod.concept_ancestor
      WHERE ancestor_concept_id = 201826
  ),
  dx_t1dm AS (
      SELECT descendant_concept_id AS concept_id
      FROM victr_sd.sd_omop_prod.concept_ancestor
      WHERE ancestor_concept_id = 201254
  ),
  dx_gdm AS (
      SELECT descendant_concept_id AS concept_id
      FROM victr_sd.sd_omop_prod.concept_ancestor
      WHERE ancestor_concept_id = 4095647
  ),
  dx_sec_dm AS (
      SELECT descendant_concept_id AS concept_id
      FROM victr_sd.sd_omop_prod.concept_ancestor
      WHERE ancestor_concept_id = 195771
  ),
  rx_antidia AS (
      SELECT descendant_concept_id AS concept_id
      FROM victr_sd.sd_omop_prod.concept_ancestor
      WHERE ancestor_concept_id IN (
        SELECT concept_id
        FROM victr_sd.sd_omop_prod.concept
        WHERE vocabulary_id = 'ATC' AND concept_code = 'A10')
  ),
  lab_hba1c AS (
      SELECT descendant_concept_id AS concept_id
      FROM victr_sd.sd_omop_prod.concept_ancestor
      WHERE ancestor_concept_id IN (3004410, 3005673)
  ),
  lab_glucose AS (
      SELECT descendant_concept_id AS concept_id
      FROM victr_sd.sd_omop_prod.concept_ancestor
      WHERE ancestor_concept_id = 3004501
  ),
  dx_flag AS (
      SELECT co.person_id,
             MIN(co.condition_start_date) AS first_dx,
             SUM(CASE WHEN vo.visit_concept_id = 9202 THEN 1 ELSE 0 END) AS op_hits,
             SUM(CASE WHEN vo.visit_concept_id = 9201 THEN 1 ELSE 0 END) AS ip_hits
      FROM victr_sd.sd_omop_prod.condition_occurrence co
      JOIN dx_t2dm ON co.condition_concept_id = dx_t2dm.concept_id
      LEFT JOIN victr_sd.sd_omop_prod.visit_occurrence vo ON co.visit_occurrence_id = vo.visit_occurrence_id
      GROUP BY co.person_id
      HAVING (op_hits >= 2) OR (ip_hits >= 1)
  ),
  rx_flag AS (
      SELECT person_id,
             MIN(drug_exposure_start_date) AS first_rx
      FROM victr_sd.sd_omop_prod.drug_exposure
      WHERE drug_concept_id IN (SELECT concept_id FROM rx_antidia)
      GROUP BY person_id
  ),
  lab_flag AS (
      SELECT m.person_id,
             MIN(m.measurement_date) AS first_lab,
             COUNT(DISTINCT m.measurement_date) AS abn_dates
      FROM victr_sd.sd_omop_prod.measurement m
      WHERE (
               m.measurement_concept_id IN (SELECT concept_id FROM lab_hba1c)
               AND m.value_as_number >= 6.5
            )
         OR (
               m.measurement_concept_id IN (SELECT concept_id FROM lab_glucose)
               AND m.value_as_number >= 200
            )
      GROUP BY m.person_id
      HAVING abn_dates >= 2
  ),
  lab_normal AS (
      SELECT DISTINCT m.person_id
      FROM victr_sd.sd_omop_prod.measurement m
      WHERE (
               m.measurement_concept_id IN (SELECT concept_id FROM lab_hba1c)
               AND m.value_as_number < 5.7
            )
         OR (
               m.measurement_concept_id IN (SELECT concept_id FROM lab_glucose)
               AND m.value_as_number < 100
            )
  ),
  candidate_cases_raw AS (
      SELECT p.person_id,
             MIN(first_dx) AS first_dx,
             MIN(first_rx) AS first_rx,
             MIN(first_lab) AS first_lab
      FROM victr_sd.sd_omop_prod.person p
      LEFT JOIN dx_flag ON p.person_id = dx_flag.person_id
      LEFT JOIN rx_flag ON p.person_id = rx_flag.person_id
      LEFT JOIN lab_flag ON p.person_id = lab_flag.person_id
      WHERE YEAR(CURRENT_DATE) - YEAR(p.birth_datetime) >= 18
      GROUP BY p.person_id
  ),
  candidate_cases AS (
      SELECT person_id,
             LEAST(
                    COALESCE(first_dx, '9999-12-31'),
                    COALESCE(first_rx, '9999-12-31'),
                    COALESCE(first_lab, '9999-12-31')
                   ) AS index_date,
             (CASE WHEN first_dx IS NOT NULL THEN 1 ELSE 0 END +
              CASE WHEN first_rx IS NOT NULL THEN 1 ELSE 0 END +
              CASE WHEN first_lab IS NOT NULL THEN 1 ELSE 0 END) AS evidence_count
      FROM candidate_cases_raw
      WHERE (CASE WHEN first_dx IS NOT NULL THEN 1 ELSE 0 END +
             CASE WHEN first_rx IS NOT NULL THEN 1 ELSE 0 END +
             CASE WHEN first_lab IS NOT NULL THEN 1 ELSE 0 END) >= 2
  ),
  exclusion_dx AS (
      SELECT DISTINCT co.person_id
      FROM victr_sd.sd_omop_prod.condition_occurrence co
      WHERE co.condition_concept_id IN (
               SELECT concept_id FROM dx_t1dm
               UNION ALL
               SELECT concept_id FROM dx_gdm
               UNION ALL
               SELECT concept_id FROM dx_sec_dm )
  ),
  cases AS (
      SELECT person_id,
             index_date
      FROM candidate_cases
      WHERE person_id NOT IN (SELECT person_id FROM exclusion_dx)
  ),
  control_candidates AS (
      SELECT p.person_id
      FROM victr_sd.sd_omop_prod.person p
      JOIN victr_sd.sd_omop_prod.observation_period op ON op.person_id = p.person_id
      WHERE YEAR(CURRENT_DATE) - YEAR(p.birth_datetime) >= 18
        -- REVISED (was: (op.observation_period_end_date - op.observation_period_start_date) >= 365)
        AND DATEDIFF(op.observation_period_end_date, op.observation_period_start_date) >= 365
        AND p.person_id IN  (SELECT person_id FROM lab_normal)
        AND p.person_id NOT IN (SELECT person_id FROM dx_flag)
        AND p.person_id NOT IN (SELECT person_id FROM rx_flag)
        AND p.person_id NOT IN (SELECT person_id FROM lab_flag)
        AND p.person_id NOT IN (SELECT person_id FROM exclusion_dx)
  ),
  controls AS (
      SELECT cc.person_id,
             op.observation_period_end_date AS index_date
      FROM control_candidates cc
      JOIN victr_sd.sd_omop_prod.observation_period op ON op.person_id = cc.person_id
  )
SELECT person_id,
       index_date,
       'T2DM_case' AS cohort_name
FROM cases
UNION ALL
SELECT person_id,
       index_date,
       'T2DM_control' AS cohort_name
FROM controls