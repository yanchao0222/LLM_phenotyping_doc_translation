-- Rule 1 (VUMC-specific database name): APPLIED
-- Rule 2 (wildcard fix): NOT APPLICABLE
-- Rule 3 (search concepts in clinical tables): APPLIED
-- Rule 4 (LOINC/RxNorm join): APPLIED (see below)
-- Rule 5 (free-text LIKE): NOT APPLICABLE
-- Rule 6 (OR->UNION): APPLIED (see ascvd_pts)
-- Rule 7 (LEFT JOIN->UNION): NOT APPLICABLE
-- Rule 8 (remove NLP): NOT APPLICABLE
-- Rule 9 (missing concept): NOT APPLICABLE
-- FIX: Removed trailing comma after the last CTE and ensured the final SELECT is outside the CTE block for Databricks SQL compatibility

CREATE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex3_only_diagram_LLM1_FH AS 

WITH
first_llt AS (
  SELECT person_id,
         MIN(drug_exposure_start_date) AS first_llt_date
  FROM   victr_sd.sd_omop_prod.drug_exposure
  WHERE  drug_concept_id IN (153946,155129,154595,1530017,155186,1580747,1597756,190594)
  GROUP  BY person_id
),

tg_400 AS (
  SELECT person_id,
         measurement_date
  FROM   victr_sd.sd_omop_prod.measurement
  WHERE  measurement_concept_id = 3023103
    AND  value_as_number >= 400
),

untreated_lipids AS (
  SELECT m.person_id,
         m.measurement_date,
         m.measurement_concept_id,
         m.value_as_number
  FROM   victr_sd.sd_omop_prod.measurement m
  WHERE m.measurement_concept_id IN (3019899,3027114)
    AND m.value_as_number IS NOT NULL
    AND NOT EXISTS (
        SELECT 1
        FROM   tg_400 t
        WHERE  t.person_id = m.person_id
          AND  t.measurement_date = m.measurement_date
    )
    AND (
      NOT EXISTS (
        SELECT 1 FROM first_llt f WHERE f.person_id = m.person_id
      )
      OR m.measurement_date < (
        SELECT MIN(f2.first_llt_date) FROM first_llt f2 WHERE f2.person_id = m.person_id
      )
    )
),

primary_hypercholesterolaemia AS (
  SELECT DISTINCT person_id
  FROM (
      SELECT person_id
      FROM   untreated_lipids
      WHERE  measurement_concept_id = 3019899         -- LDL‑C
        AND  value_as_number       >= 160
      GROUP  BY person_id
      HAVING COUNT(1) >= 2
         AND DATEDIFF(
                day,
                MIN(measurement_date),
                MAX(measurement_date)
             ) >= 30

      UNION

      SELECT person_id
      FROM   untreated_lipids
      WHERE  measurement_concept_id = 3027114         -- Total‑chol
        AND  value_as_number       >= 240
      GROUP  BY person_id
      HAVING COUNT(1) >= 2
         AND DATEDIFF(
                day,
                MIN(measurement_date),
                MAX(measurement_date)
             ) >= 30

      UNION

      SELECT l.person_id
      FROM   untreated_lipids l
      JOIN   first_llt       f  ON f.person_id = l.person_id
      WHERE  l.measurement_concept_id = 3019899
        AND  l.value_as_number       >= 130
  ) candidates
),

ldl_pts AS (
  SELECT person_id,
         CASE
           WHEN MAX(value_as_number) >= 330 THEN 8
           WHEN MAX(value_as_number) BETWEEN 255 AND 329 THEN 5
           WHEN MAX(value_as_number) BETWEEN 190 AND 254 THEN 3
           ELSE 0
         END AS pts_ldl
  FROM   untreated_lipids
  WHERE  measurement_concept_id = 3019899
  GROUP  BY person_id
),

ascvd_pts AS (
  SELECT DISTINCT p.person_id,
         4 AS pts_ascvd
  FROM (
        SELECT co.person_id, MIN(co.condition_start_date) AS event_date
        FROM   victr_sd.sd_omop_prod.condition_occurrence co
        WHERE  co.condition_concept_id IN (4329847,381591)
        GROUP  BY co.person_id
        UNION ALL
        SELECT po.person_id, MIN(po.procedure_date) AS event_date
        FROM   victr_sd.sd_omop_prod.procedure_occurrence po
        WHERE  po.procedure_concept_id IN (4245340,2005909)
        GROUP  BY po.person_id
       ) e
  JOIN   victr_sd.sd_omop_prod.person p ON p.person_id = e.person_id
  WHERE (
        (p.gender_concept_id = 8507   -- male
         AND YEAR(e.event_date) - p.year_of_birth < 55)
     OR (p.gender_concept_id = 8532   -- female
         AND YEAR(e.event_date) - p.year_of_birth < 65)
        )
),

physical_pts AS (
  SELECT person_id,
         MAX(score) AS pts_physical
  FROM (
        SELECT co.person_id, 6 AS score
        FROM   victr_sd.sd_omop_prod.condition_occurrence co
        WHERE  co.condition_concept_id = 4181627            -- tendon xanthoma

        UNION ALL

        SELECT c.person_id, 4 AS score
        FROM   victr_sd.sd_omop_prod.condition_occurrence c
        JOIN   victr_sd.sd_omop_prod.person p ON p.person_id = c.person_id
        WHERE  c.condition_concept_id = 4218731           -- corneal arcus
          AND  YEAR(c.condition_start_date) - p.year_of_birth < 45
       ) z
  GROUP  BY person_id
),

family_pts AS (
  SELECT person_id,
         MAX(CASE
               WHEN observation_concept_id = 4254193 THEN 2   -- 1st‑degree
               WHEN observation_concept_id = 4288807 THEN 1   -- 2nd‑degree
               ELSE 0
             END) AS pts_family
  FROM   victr_sd.sd_omop_prod.observation
  WHERE  observation_concept_id IN (4254193,4288807)
  GROUP  BY person_id
),

genetic_pts AS (
  SELECT DISTINCT person_id,
         8 AS pts_genetic
  FROM   victr_sd.sd_omop_prod.observation
  WHERE  observation_concept_id = 40767802                 -- pathogenic LDLR/APOB/PCSK9
),

total_score AS (
  SELECT ph.person_id,
         COALESCE(l.pts_ldl,0)      +
         COALESCE(a.pts_ascvd,0)    +
         COALESCE(p.pts_physical,0) +
         COALESCE(f.pts_family,0)   +
         COALESCE(g.pts_genetic,0)  AS total_pts
  FROM   primary_hypercholesterolaemia ph
  LEFT   JOIN ldl_pts      l ON l.person_id = ph.person_id
  LEFT   JOIN ascvd_pts    a ON a.person_id = ph.person_id
  LEFT   JOIN physical_pts p ON p.person_id = ph.person_id
  LEFT   JOIN family_pts   f ON f.person_id = ph.person_id
  LEFT   JOIN genetic_pts  g ON g.person_id = ph.person_id
)

SELECT person_id,
       CASE
         WHEN total_pts >= 6 THEN 'FH_CASE'
         WHEN total_pts <= 2 THEN 'FH_CONTROL'
         ELSE 'FH_BORDERLINE'
       END AS phenotype_label,
       total_pts
FROM   total_score;