/*======================================================================
  Executable SQL  |  Phenotyping Cohorts for Type 2 Diabetes Mellitus
  --------------------------------------------------------------------
  • Target schema : OMOP Common Data Model v5+
  • Output        : person_id | index_date | cohort_name
                    (where cohort_name ∈ {'T2DM_case','T2DM_control'})
  • Methodology   : All logic mirrors the previously‑agreed algorithm:
                      – CASES need ≥2 of 3 evidence classes (Dx / Rx / Lab);
                      – CONTROLS must have normal glycaemia and zero evidence;
                      – Shared exclusions remove Type 1, gestational, secondary DM.
                    Every clinical element is expressed via OMOP standard
                    concept IDs.  No permanent tables are created.
  • Dialect       : PostgreSQL‑compatible SQL
======================================================================*/

WITH
/*--------------------------------------------------------------------
  0. Concept sets  – descendants of each standard ancestor concept
--------------------------------------------------------------------*/
  dx_t2dm AS (
      SELECT descendant_concept_id AS concept_id
      FROM   concept_ancestor
      WHERE  ancestor_concept_id = 201826          -- Type 2 DM
  ),

  dx_t1dm AS (
      SELECT descendant_concept_id AS concept_id
      FROM   concept_ancestor
      WHERE  ancestor_concept_id = 201254          -- Type 1 DM (exclusion)
  ),

  dx_gdm AS (
      SELECT descendant_concept_id AS concept_id
      FROM   concept_ancestor
      WHERE  ancestor_concept_id = 4095647         -- Gestational DM (exclusion)
  ),

  dx_sec_dm AS (
      SELECT descendant_concept_id AS concept_id
      FROM   concept_ancestor
      WHERE  ancestor_concept_id = 195771          -- Secondary DM (exclusion)
  ),

  rx_antidia AS (
      SELECT descendant_concept_id AS concept_id
      FROM   concept_ancestor
      WHERE  ancestor_concept_id IN (
               /* ATC class A10 = drugs used in diabetes */
               SELECT concept_id
               FROM   concept
               WHERE  vocabulary_id = 'ATC'
                 AND  concept_code   = 'A10')
  ),

  lab_hba1c AS (
      SELECT descendant_concept_id AS concept_id
      FROM   concept_ancestor
      WHERE  ancestor_concept_id IN (3004410, 3005673)     -- HbA1c
  ),

  lab_glucose AS (
      SELECT descendant_concept_id AS concept_id
      FROM   concept_ancestor
      WHERE  ancestor_concept_id = 3004501                 -- Plasma glucose
  ),

/*--------------------------------------------------------------------
  1‑A. Diagnosis evidence  (≥2 outpatient dates OR ≥1 inpatient date)
--------------------------------------------------------------------*/
  dx_flag AS (
      SELECT co.person_id,
             MIN(co.condition_start_date)                              AS first_dx,
             SUM(CASE WHEN vo.visit_concept_id = 9202 THEN 1 ELSE 0 END) AS op_hits,
             SUM(CASE WHEN vo.visit_concept_id = 9201 THEN 1 ELSE 0 END) AS ip_hits
      FROM   condition_occurrence      co
      JOIN   dx_t2dm                   ON  co.condition_concept_id = dx_t2dm.concept_id
      LEFT   JOIN visit_occurrence  vo ON  co.visit_occurrence_id  = vo.visit_occurrence_id
      GROUP  BY co.person_id
      HAVING (op_hits >= 2) OR (ip_hits >= 1)
  ),

/*--------------------------------------------------------------------
  1‑B. Medication evidence  (≥1 anti‑diabetic drug exposure)
--------------------------------------------------------------------*/
  rx_flag AS (
      SELECT person_id,
             MIN(drug_exposure_start_date) AS first_rx
      FROM   drug_exposure
      WHERE  drug_concept_id IN (SELECT concept_id FROM rx_antidia)
      GROUP  BY person_id
  ),

/*--------------------------------------------------------------------
  1‑C. Laboratory evidence  (≥2 abnormal measurement dates)
--------------------------------------------------------------------*/
  lab_flag AS (
      SELECT person_id,
             MIN(measurement_date)              AS first_lab,
             COUNT(DISTINCT measurement_date)   AS abn_dates
      FROM   measurement
      WHERE (
               measurement_concept_id IN (SELECT concept_id FROM lab_hba1c)
               AND value_as_number >= 6.5                              -- HbA1c %
            )
         OR (
               measurement_concept_id IN (SELECT concept_id FROM lab_glucose)
               AND value_as_number >= 200                              -- Glucose mg/dL
            )
      GROUP  BY person_id
      HAVING abn_dates >= 2
  ),

/*--------------------------------------------------------------------
  1‑D. Normal glycaemia evidence  (required *only* for controls)
--------------------------------------------------------------------*/
  lab_normal AS (
      SELECT DISTINCT person_id
      FROM   measurement
      WHERE (
               measurement_concept_id IN (SELECT concept_id FROM lab_hba1c)
               AND value_as_number < 5.7                               -- HbA1c %
            )
         OR (
               measurement_concept_id IN (SELECT concept_id FROM lab_glucose)
               AND value_as_number < 100                               -- Glucose mg/dL
            )
  ),

/*--------------------------------------------------------------------
  2. Candidate cases  (adults & ≥2 evidence classes)
--------------------------------------------------------------------*/
  candidate_cases AS (
      SELECT  p.person_id,
              LEAST(
                    COALESCE(first_dx , DATE '9999‑12‑31'),
                    COALESCE(first_rx , DATE '9999‑12‑31'),
                    COALESCE(first_lab, DATE '9999‑12‑31')
                   )                                   AS index_date,
              -- evidence class count
              ( CASE WHEN first_dx  IS NOT NULL THEN 1 ELSE 0 END +
                CASE WHEN first_rx  IS NOT NULL THEN 1 ELSE 0 END +
                CASE WHEN first_lab IS NOT NULL THEN 1 ELSE 0 END )    AS evidence_count
      FROM    person           p
      LEFT    JOIN dx_flag  USING (person_id)
      LEFT    JOIN rx_flag  USING (person_id)
      LEFT    JOIN lab_flag USING (person_id)
      WHERE   EXTRACT(YEAR FROM AGE(CURRENT_DATE, p.birth_datetime)) >= 18
        AND   evidence_count >= 2
  ),

/*--------------------------------------------------------------------
  3. Shared exclusion diagnoses
--------------------------------------------------------------------*/
  exclusion_dx AS (
      SELECT DISTINCT person_id
      FROM   condition_occurrence
      WHERE  condition_concept_id IN (
               SELECT concept_id FROM dx_t1dm
               UNION ALL
               SELECT concept_id FROM dx_gdm
               UNION ALL
               SELECT concept_id FROM dx_sec_dm )
  ),

/*--------------------------------------------------------------------
  4. Final T2DM case cohort
--------------------------------------------------------------------*/
  cases AS (
      SELECT person_id,
             index_date
      FROM   candidate_cases
      WHERE  person_id NOT IN (SELECT person_id FROM exclusion_dx)
  ),

/*--------------------------------------------------------------------
  5. Control candidates  (adults, ≥1 year observed, normal labs,
                          and *no* Dx / Rx / Lab evidence)
--------------------------------------------------------------------*/
  control_candidates AS (
      SELECT p.person_id
      FROM   person p
      JOIN   observation_period op
             ON op.person_id = p.person_id
      WHERE  EXTRACT(YEAR FROM AGE(CURRENT_DATE, p.birth_datetime)) >= 18
        AND  (op.observation_period_end_date - op.observation_period_start_date) >= 365
        AND  p.person_id IN  (SELECT person_id FROM lab_normal)
        AND  p.person_id NOT IN (SELECT person_id FROM dx_flag)
        AND  p.person_id NOT IN (SELECT person_id FROM rx_flag)
        AND  p.person_id NOT IN (SELECT person_id FROM lab_flag)
        AND  p.person_id NOT IN (SELECT person_id FROM exclusion_dx)
  ),

/*--------------------------------------------------------------------
  6. Final T2DM control cohort
--------------------------------------------------------------------*/
  controls AS (
      SELECT cc.person_id,
             op.observation_period_end_date AS index_date
      FROM   control_candidates cc
      JOIN   observation_period op
             ON op.person_id = cc.person_id
  )

/*--------------------------------------------------------------------
  7. Deliver combined resultset
--------------------------------------------------------------------*/
SELECT person_id,
       index_date,
       'T2DM_case'    AS cohort_name
FROM   cases

UNION ALL

SELECT person_id,
       index_date,
       'T2DM_control' AS cohort_name
FROM   controls;
