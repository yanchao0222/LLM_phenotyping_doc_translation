/****************************************************************************************
  Autoimmune Disease Phenotype
  -------------------------------------------------
  CASE  : ≥3 diagnosis dates for the *same* autoimmune disease, span ≥7 days,
          with an extra T1DM‑vs‑T2DM exclusion.
  CTRL  : Not a case AND no autoimmune/auto‑inflammatory diagnoses AND
          no positive antibody serology results.

  Concept‑set lookup objects expected (codes only):
      AID_CASE_CODES   (concept_id INT, disease_id TEXT)
      T1DM_CODES       (concept_id INT)
      T2DM_CODES       (concept_id INT)
      AAI_EXCLUDE_CODES(concept_id INT)
      SEROLOGY_CODES   (measurement_concept_id INT)
      POS_VALUE_CODES  (value_as_concept_id INT)
****************************************************************************************/

WITH
/* ---------------------------- CASE SECTION ---------------------------- */
dx AS (  -- Map each qualifying diagnosis to its disease group
    SELECT  co.person_id,
            cs.disease_id,
            co.condition_start_date
    FROM    condition_occurrence AS co
    JOIN    AID_CASE_CODES       AS cs
           ON cs.concept_id = co.condition_concept_id
),
dx_agg AS (   -- ≥3 distinct dates, first↔last ≥7 days
    SELECT  person_id,
            disease_id,
            COUNT(DISTINCT condition_start_date)                AS dx_cnt,
            MIN(condition_start_date)                           AS first_dt,
            MAX(condition_start_date)                           AS last_dt
    FROM    dx
    GROUP BY person_id, disease_id
    HAVING  dx_cnt >= 3
       AND  DATE_PART('day', last_dt - first_dt) >= 7    -- use DATEDIFF(day, first_dt, last_dt) in SQL‑Server
),
case_candidates AS (   -- T1DM must *not* have any T2DM code
    SELECT  d.person_id
    FROM    dx_agg AS d
    LEFT JOIN condition_occurrence t2
           ON t2.person_id = d.person_id
          AND t2.condition_concept_id IN (SELECT concept_id FROM T2DM_CODES)
    WHERE NOT (d.disease_id = 'T1DM' AND t2.person_id IS NOT NULL)
),
CASES AS (SELECT DISTINCT person_id FROM case_candidates),

/* -------------------------- CONTROL SECTION --------------------------- */
ctl_dx_excl AS (  -- any autoimmune / autoinflammatory diagnosis
    SELECT DISTINCT person_id
    FROM   condition_occurrence
    WHERE  condition_concept_id IN (SELECT concept_id FROM AAI_EXCLUDE_CODES)
),
ctl_serology_excl AS (  -- any positive antibody result
    SELECT DISTINCT m.person_id
    FROM   measurement AS m
    WHERE  m.measurement_concept_id IN (SELECT measurement_concept_id
                                        FROM SEROLOGY_CODES)
      AND (
           m.value_as_concept_id IN (SELECT value_as_concept_id
                                      FROM POS_VALUE_CODES)
        OR (m.value_as_number  IS NOT NULL
            AND m.range_high    IS NOT NULL
            AND m.value_as_number >= m.range_high)
          )
),
CONTROLS AS (  -- must fail none of the exclusion checks
    SELECT  p.person_id
    FROM    person               AS p
    LEFT JOIN CASES              AS c  ON c.person_id = p.person_id
    LEFT JOIN ctl_dx_excl        AS d  ON d.person_id = p.person_id
    LEFT JOIN ctl_serology_excl  AS s  ON s.person_id = p.person_id
    WHERE   c.person_id IS NULL   -- not a case
      AND   d.person_id IS NULL   -- no excluded diagnoses
      AND   s.person_id IS NULL   -- no positive serology
)

/* --------------------------- FINAL OUTPUT ----------------------------- */
SELECT 'CASE'    AS cohort_type, person_id FROM CASES
UNION ALL
SELECT 'CONTROL' AS cohort_type, person_id FROM CONTROLS;
