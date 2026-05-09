/*======================================================================
  AUTOIMMUNE DISEASE (AID) PHENOTYPE – FINAL EXECUTABLE SQL
  ---------------------------------------------------------------------
  • Source files:  Autoimmune_Disease_Algorithm.pdf & Autoimmune_disease_coding_file.txt
  • Key logic (file‑grounded):
        −  CASE  : ≥3 autoimmune‑DX on ≥3 distinct days, span ≥7 days
                   (T1DM episode is valid only if NO T2DM DX ever)  :contentReference[oaicite:4]{index=4}
        −  CONTROL: NO autoimmune / autoinflammatory DX AND NO positive serology
                   (10 antibody families)                           :contentReference[oaicite:5]{index=5}
  • All predicates use numeric OMOP concept_id values only.
  • Read‑only: every object is a CTE – **no permanent tables created**.
======================================================================*/

WITH
/*--------------------------------------------------------------------
  1. CODE‑SET MATERIALISATION
  ------------------------------------------------------------------*/
coding_dictionary AS (          -- imported copy of Autoimmune_disease_coding_file.txt
    SELECT  variable_name,                     -- e.g. 'dx.autoimmune.subphenotype15'
            concept_id        ::INTEGER
    FROM    staging.aid_coding_dictionary      -- <<< change to your load schema
),

/* Auto‑immune disease DX codes plus a numeric disease_id extracted
   from the “subphenotype##” suffix in the variable name. */
autoimmune_dx AS (
    SELECT  concept_id,
            CAST(REGEXP_REPLACE(variable_name,
                                 '.*subphenotype', '') AS INTEGER) AS disease_id
    FROM    coding_dictionary
    WHERE   variable_name ILIKE 'dx.autoimmune.subphenotype%'
        OR  variable_name ILIKE 'autoimmune.subphenotype%'
),

/* Auto‑inflammatory + autoimmune combo codes used ONLY for control exclusion. */
autoinflammatory_dx AS (
    SELECT  concept_id
    FROM    coding_dictionary
    WHERE   variable_name ILIKE '%dx.autoinflammatoryautoimmune%'
),

/* Type 2 diabetes mellitus (T2DM) DX codes – exclusion for T1DM episodes. */
t2dm_dx AS (
    SELECT  concept_id
    FROM    coding_dictionary
    WHERE   variable_name ILIKE '%dx.t2dm%'
),

/* Serology measurement concept_ids – ten systemic antibody families. */
serology_tests AS (
    SELECT  concept_id
    FROM    coding_dictionary
    WHERE   variable_name ILIKE 'lab.serology.%'
),

/*--------------------------------------------------------------------
  2. PATIENT‑LEVEL DERIVED FLAGS
  ------------------------------------------------------------------*/

/* ---------- Autoimmune episode: ≥3 DX, ≥7‑day span -------------- */
autoimmune_episode AS (
    SELECT  co.person_id,
            ad.disease_id,
            COUNT(DISTINCT co.condition_start_date)          AS dx_days,
            MIN(co.condition_start_date)                     AS first_day,
            MAX(co.condition_start_date)                     AS last_day
    FROM    condition_occurrence      co
    JOIN    autoimmune_dx             ad
           ON ad.concept_id = co.condition_concept_id
    GROUP BY co.person_id, ad.disease_id
    HAVING  COUNT(DISTINCT co.condition_start_date) >= 3
       AND  DATE_PART('day', MAX(co.condition_start_date)
                              - MIN(co.condition_start_date)) >= 7
),

/* ---------- Flag: any T2DM diagnosis ever ------------------------ */
t2dm_flag AS (
    SELECT  DISTINCT person_id
    FROM    condition_occurrence
    WHERE   condition_concept_id IN (SELECT concept_id FROM t2dm_dx)
),

/* ---------- Flag: any autoimmune OR autoinflammatory DX ever ----- */
any_auto_dx AS (
    SELECT DISTINCT person_id
    FROM   condition_occurrence
    WHERE  condition_concept_id IN (
              SELECT concept_id FROM autoimmune_dx
              UNION
              SELECT concept_id FROM autoinflammatory_dx
          )
),

/* ---------- Flag: positive systemic antibody result -------------- */
positive_serology AS (
    SELECT DISTINCT m.person_id
    FROM   measurement m
    WHERE  m.measurement_concept_id IN (SELECT concept_id FROM serology_tests)
      AND  (
             m.value_as_concept_id = 45877985         -- 'Positive' (standard) 
             OR m.value_as_number  > COALESCE(m.range_low,0)
           )
),

/*--------------------------------------------------------------------
  3. COHORT ASSIGNMENT
  ------------------------------------------------------------------*/

/* ---------- CASES ------------------------------------------------- */
case_cohort AS (
    SELECT DISTINCT ae.person_id
    FROM   autoimmune_episode ae
    LEFT   JOIN t2dm_flag     t2  ON t2.person_id = ae.person_id
    /* disease_id 15 = sub‑phenotype “Type 1 Diabetes” in coding file → must NOT
       coexist with any T2DM code                                     */
    WHERE NOT (
                ae.disease_id = 15                -- T1DM  :contentReference[oaicite:6]{index=6}
                AND t2.person_id IS NOT NULL
              )
),

/* ---------- CONTROLS --------------------------------------------- */
control_cohort AS (
    SELECT  p.person_id
    FROM    person               p
    LEFT    JOIN any_auto_dx      ad ON ad.person_id = p.person_id
    LEFT    JOIN positive_serology ps ON ps.person_id = p.person_id
    WHERE   ad.person_id IS NULL        -- no autoimmune / autoinflammatory DX
      AND   ps.person_id IS NULL        -- no positive serology
      AND   p.person_id NOT IN (SELECT person_id FROM case_cohort)  -- disjoint
)

/*--------------------------------------------------------------------
  4. FINAL RESULTSET
  ------------------------------------------------------------------*/
SELECT 'CASE'    AS cohort_type, person_id FROM case_cohort
UNION ALL
SELECT 'CONTROL' AS cohort_type, person_id FROM control_cohort;
