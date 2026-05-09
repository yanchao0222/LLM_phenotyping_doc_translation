/* ====================================================================
   Familial Hypercholesterolaemia (FH) – Mayo Clinic EHR Algorithm
   OMOP CDM‑compliant SQL
   --------------------------------------------------------------------
   OUTPUT
     person_id        -- unique patient identifier
     phenotype_label  -- 'FH_CASE' | 'FH_CONTROL' | 'FH_BORDERLINE'
     total_pts        -- summed Stage II score
   --------------------------------------------------------------------
   ADAPTATION NOTES
   • Replace @cdm with your CDM schema name (or drop if using default).
   • Uses OHDSI‑style functions:  DATEDIFF(day, date1, date2),
     YEAR(date) and DATEFROMPARTS(year,1,1) for cross‑dialect support.
   • SqlRender will translate these to PostgreSQL, SQL Server, Oracle,
     BigQuery, Redshift, Spark, DuckDB, etc.
   ==================================================================== */

WITH
/* --------------------------------------------------------------------
   0. Earliest exposure to any lipid‑lowering treatment (LLT)
   -------------------------------------------------------------------- */
first_llt AS (
  SELECT person_id,
         MIN(drug_exposure_start_date) AS first_llt_date
  FROM   @cdm.drug_exposure
  WHERE  drug_concept_id IN ( 153946 ,155129 ,154595 ,1530017,
                              155186 ,1580747,1597756,190594 )  -- statins ± ezetimibe
  GROUP  BY person_id
),

/* --------------------------------------------------------------------
   1. Triglyceride ≥ 400 mg/dL on any date  → used for same‑visit exclusion
   -------------------------------------------------------------------- */
tg_400 AS (
  SELECT person_id,
         measurement_date
  FROM   @cdm.measurement
  WHERE  measurement_concept_id = 3023103      -- triglycerides
    AND  value_as_number       >= 400
),

/* --------------------------------------------------------------------
   2. Untreated LDL‑C & Total‑cholesterol values with TG < 400 that day
   -------------------------------------------------------------------- */
untreated_lipids AS (
  SELECT m.person_id,
         m.measurement_date,
         m.measurement_concept_id,
         m.value_as_number
  FROM   @cdm.measurement  m
  LEFT   JOIN first_llt f
         ON f.person_id = m.person_id
  WHERE  m.measurement_concept_id IN (3019899,3027114)        -- LDL / TC
    AND (f.first_llt_date IS NULL OR m.measurement_date < f.first_llt_date)
    AND m.value_as_number IS NOT NULL
    AND NOT EXISTS (  -- exclude visit if TG ≥ 400 same date
        SELECT 1
        FROM   tg_400 t
        WHERE  t.person_id      = m.person_id
          AND  t.measurement_date = m.measurement_date
    )
),

/* --------------------------------------------------------------------
   3. Stage I – Primary hypercholesterolaemia eligibility
   -------------------------------------------------------------------- */
primary_hypercholesterolaemia AS (
  SELECT DISTINCT person_id
  FROM (
      /* A – ≥ 2 untreated LDL‑C ≥ 160 mg/dL on dates ≥ 30 days apart */
      SELECT person_id
      FROM   untreated_lipids
      WHERE  measurement_concept_id = 3019899         -- LDL‑C
        AND  value_as_number       >= 160
      GROUP  BY person_id
      HAVING SUM(1) >= 2
         AND DATEDIFF(
                day,
                MIN(measurement_date),
                MAX(measurement_date)
             ) >= 30

      UNION

      /* B – ≥ 2 untreated Total‑cholesterol ≥ 240 mg/dL on dates ≥ 30 days apart */
      SELECT person_id
      FROM   untreated_lipids
      WHERE  measurement_concept_id = 3027114         -- Total‑chol
        AND  value_as_number       >= 240
      GROUP  BY person_id
      HAVING SUM(1) >= 2
         AND DATEDIFF(
                day,
                MIN(measurement_date),
                MAX(measurement_date)
             ) >= 30

      UNION

      /* C – ≥ 1 untreated LDL‑C ≥ 130 mg/dL AND any LLT exposure */
      SELECT l.person_id
      FROM   untreated_lipids l
      JOIN   first_llt       f  ON f.person_id = l.person_id
      WHERE  l.measurement_concept_id = 3019899
        AND  l.value_as_number       >= 130
  ) candidates
),

/* --------------------------------------------------------------------
   4. Stage II – Component point assignments
   -------------------------------------------------------------------- */
-- 4.1 LDL‑C component (highest untreated LDL‑C)
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

-- 4.2 Premature ASCVD (< 55 y men, < 65 y women)
ascvd_pts AS (
  SELECT DISTINCT p.person_id,
         4 AS pts_ascvd
  FROM (
        -- MI & ischaemic stroke
        SELECT person_id, MIN(condition_start_date) AS event_date
        FROM   @cdm.condition_occurrence
        WHERE  condition_concept_id IN (4329847,381591)
        GROUP  BY person_id
        UNION ALL
        -- PCI & CABG
        SELECT person_id, MIN(procedure_date)
        FROM   @cdm.procedure_occurrence
        WHERE  procedure_concept_id IN (4245340,2005909)
        GROUP  BY person_id
       ) e
  JOIN   @cdm.person p ON p.person_id = e.person_id
  WHERE (
        (p.gender_concept_id = 8507   -- male
         AND YEAR(e.event_date) - p.year_of_birth < 55)
     OR (p.gender_concept_id = 8532   -- female
         AND YEAR(e.event_date) - p.year_of_birth < 65)
        )
),

-- 4.3 Physical findings: tendon xanthoma (6 pts) OR corneal arcus < 45 y (4 pts)
physical_pts AS (
  SELECT person_id,
         MAX(score) AS pts_physical
  FROM (
        SELECT person_id, 6 AS score
        FROM   @cdm.condition_occurrence
        WHERE  condition_concept_id = 4181627            -- tendon xanthoma

        UNION ALL

        SELECT c.person_id, 4 AS score
        FROM   @cdm.condition_occurrence c
        JOIN   @cdm.person p ON p.person_id = c.person_id
        WHERE  c.condition_concept_id = 4218731           -- corneal arcus
          AND  YEAR(c.condition_start_date) - p.year_of_birth < 45
       ) z
  GROUP  BY person_id
),

-- 4.4 Family history component
family_pts AS (
  SELECT person_id,
         MAX(CASE
               WHEN observation_concept_id = 4254193 THEN 2   -- 1st‑degree
               WHEN observation_concept_id = 4288807 THEN 1   -- 2nd‑degree
               ELSE 0
             END) AS pts_family
  FROM   @cdm.observation
  WHERE  observation_concept_id IN (4254193,4288807)
  GROUP  BY person_id
),

-- 4.5 Genetic testing component
genetic_pts AS (
  SELECT DISTINCT person_id,
         8 AS pts_genetic
  FROM   @cdm.observation
  WHERE  observation_concept_id = 40767802                 -- pathogenic LDLR/APOB/PCSK9
),

/* --------------------------------------------------------------------
   5. Total score & label
   -------------------------------------------------------------------- */
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

/* --------------------------------------------------------------------
   6. Final cohort
   -------------------------------------------------------------------- */
SELECT person_id,
       CASE
         WHEN total_pts >= 6 THEN 'FH_CASE'
         WHEN total_pts <= 2 THEN 'FH_CONTROL'
         ELSE 'FH_BORDERLINE'      -- score 3 – 5
       END   AS phenotype_label,
       total_pts
FROM   total_score;
