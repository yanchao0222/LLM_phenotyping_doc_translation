/*======================================================================
  Familial Hypercholesterolaemia (FH) Phenotype  —  OMOP CDM SQL
  ----------------------------------------------------------------------
  RETURNS
    • CASE     → Definite / Probable FH
    • CONTROL  → Unlikely FH  OR  LDL‑C < 190 mg/dL
  ----------------------------------------------------------------------
  DEPENDENCIES
    • PostgreSQL 9.6+ (window functions, INTERVAL syntax, DISTINCT supported)
    • Standard OMOP v5.4 tables: person, measurement, drug_exposure,
      condition_occurrence, concept
    • `nlp_results` staging table holding free‑text features with integer `code`
      values (6 = xanthoma, 4 = arcus, 2 = premature CHD, 1 = CVD/PAD or FH‑FHx)
======================================================================*/

WITH /* ---------- Tuning parameters ---------- */
params AS (
  SELECT
      365   ::INT   AS lookback_days,
      220.0 ::FLOAT AS tg_flag_mgdl,
      155.0 ::FLOAT AS ldl_flag_mgdl,
      190.0 ::FLOAT AS ldl_case_mgdl,
      0.70  ::FLOAT AS ldl_adj_factor
),

/* ---------- 1. Adult LDL‑C results & index value ---------- */
ldl_candidates AS (
  SELECT  m.person_id,
          m.measurement_datetime          AS ldl_dt,
          m.value_as_number               AS ldl_val,
          ROW_NUMBER() OVER (
              PARTITION BY m.person_id
              ORDER BY m.value_as_number DESC, m.measurement_datetime ) AS rn
  FROM    measurement m
  JOIN    concept c  ON c.concept_id = m.measurement_concept_id
  JOIN    person  p  ON p.person_id  = m.person_id
  WHERE   c.vocabulary_id = 'LOINC'
    AND   c.concept_code IN
           ('2089-1','18262-6','49132-4','35198-1','39469-2',
            '12773-8','18261-8','22748-8','13457-7','9346-8',
            '2574-2','14815-5')
    AND   date_part('year', age(m.measurement_datetime, p.birth_datetime)) >= 18
),
index_ldl AS (
  SELECT person_id,
         ldl_dt            AS index_dt,
         ldl_val           AS raw_ldl,
         /* therapy adjustment: divide by 0.70 if Rx in look‑back window */
         CASE
           WHEN EXISTS (
                SELECT 1
                FROM   drug_exposure dx
                JOIN   concept crx ON crx.concept_id = dx.drug_concept_id
                WHERE  crx.vocabulary_id = 'RxNorm'
                  AND  crx.concept_code IN (
                       '36567','41127','6472','42463','861634',
                       '83367','301542','221072','1152441',
                       '1665895','1659156',
                       '7393','8703','4719','341248','141626',
                       '2447','2685','1367839','1364479')
                  AND  dx.drug_exposure_start_date BETWEEN
                       (ldl_dt - (SELECT lookback_days FROM params) * INTERVAL '1 day')
                       AND ldl_dt
           )
           THEN ldl_val / (SELECT ldl_adj_factor FROM params)
           ELSE ldl_val
         END               AS adj_ldl
  FROM   ldl_candidates
  WHERE  rn = 1                               -- highest LDL per person
),

/* ---------- 2. Secondary‑cause exclusion flags ---------- */
sec_cause AS (
  SELECT il.person_id,
         /* every flag is 1 = present, 0 = absent */
         CASE WHEN EXISTS (
                SELECT 1 FROM measurement m
                JOIN   concept c ON c.concept_id = m.measurement_concept_id
                WHERE  m.person_id = il.person_id
                  AND  c.vocabulary_id = 'LOINC'
                  AND  c.concept_code IN ('11579-0','24348-5') /* TSH */
                  AND  m.value_as_number >= 10
                  AND  m.measurement_datetime BETWEEN
                       (il.index_dt - (SELECT lookback_days FROM params) * INTERVAL '1 day')
                       AND il.index_dt
              ) THEN 1 ELSE 0 END              AS hypothyroid,

         CASE WHEN EXISTS (
                SELECT 1 FROM measurement m
                JOIN   concept c ON c.concept_id = m.measurement_concept_id
                WHERE  m.person_id = il.person_id
                  AND  c.vocabulary_id = 'LOINC'
                  AND  c.concept_code IN ('6768-6','12805-8')     /* ALP */
                  AND  m.value_as_number >= 200
                  AND  m.measurement_datetime BETWEEN
                       (il.index_dt - (SELECT lookback_days FROM params) * INTERVAL '1 day')
                       AND il.index_dt
              ) THEN 1 ELSE 0 END              AS biliary_obstruction,

         CASE WHEN EXISTS (
                SELECT 1 FROM measurement m
                JOIN   concept c ON c.concept_id = m.measurement_concept_id
                WHERE  m.person_id = il.person_id
                  AND  c.vocabulary_id = 'LOINC'
                  AND  c.concept_code = '35194-0'                 /* bilirubin */
                  AND  m.value_as_number > 2.0
                  AND  m.measurement_datetime BETWEEN
                       (il.index_dt - (SELECT lookback_days FROM params) * INTERVAL '1 day')
                       AND il.index_dt
              ) THEN 1 ELSE 0 END              AS liver_disease,

         CASE WHEN EXISTS (
                SELECT 1 FROM measurement m
                JOIN   concept c ON c.concept_id = m.measurement_concept_id
                WHERE  m.person_id = il.person_id
                  AND  c.vocabulary_id = 'LOINC'
                  AND  c.concept_code = '13801-6'                 /* Prot/Cr */
                  AND  m.value_as_number > 3
                  AND  m.measurement_datetime BETWEEN
                       (il.index_dt - (SELECT lookback_days FROM params) * INTERVAL '1 day')
                       AND il.index_dt
              ) THEN 1 ELSE 0 END              AS nephrotic,

         CASE WHEN EXISTS (
                /* creatinine > 2.6 mg/dL */
                SELECT 1 FROM measurement m
                JOIN   concept c ON c.concept_id = m.measurement_concept_id
                WHERE  m.person_id = il.person_id
                  AND  c.vocabulary_id = 'LOINC'
                  AND  c.concept_code = '14682-9'
                  AND  m.value_as_number > 2.6
                  AND  m.measurement_datetime BETWEEN
                       (il.index_dt - (SELECT lookback_days FROM params) * INTERVAL '1 day')
                       AND il.index_dt
              ) OR EXISTS (
                /* eGFR < 15 mL/min */
                SELECT 1 FROM measurement m
                JOIN   concept c ON c.concept_id = m.measurement_concept_id
                WHERE  m.person_id = il.person_id
                  AND  c.vocabulary_id = 'LOINC'
                  AND  c.concept_code = '50261-7'
                  AND  m.value_as_number < 15
                  AND  m.measurement_datetime BETWEEN
                       (il.index_dt - (SELECT lookback_days FROM params) * INTERVAL '1 day')
                       AND il.index_dt
              ) THEN 1 ELSE 0 END              AS renal_failure,

         CASE WHEN EXISTS (
                /* HbA1c > 9 % */
                SELECT 1 FROM measurement m
                JOIN   concept c ON c.concept_id = m.measurement_concept_id
                WHERE  m.person_id = il.person_id
                  AND  c.vocabulary_id = 'LOINC'
                  AND  c.concept_code = '4549-2'
                  AND  m.value_as_number > 9
                  AND  m.measurement_datetime BETWEEN
                       (il.index_dt - (SELECT lookback_days FROM params) * INTERVAL '1 day')
                       AND il.index_dt
              ) OR EXISTS (
                /* serum glucose > 220 mg/dL */
                SELECT 1 FROM measurement m
                JOIN   concept c ON c.concept_id = m.measurement_concept_id
                WHERE  m.person_id = il.person_id
                  AND  c.vocabulary_id = 'LOINC'
                  AND  c.concept_code = '1558-6'
                  AND  m.value_as_number > 220
                  AND  m.measurement_datetime BETWEEN
                       (il.index_dt - (SELECT lookback_days FROM params) * INTERVAL '1 day')
                       AND il.index_dt
              ) OR EXISTS (
                /* capillary glucose > 200 mg/dL */
                SELECT 1 FROM measurement m
                JOIN   concept c ON c.concept_id = m.measurement_concept_id
                WHERE  m.person_id = il.person_id
                  AND  c.vocabulary_id = 'LOINC'
                  AND  c.concept_code = '1556-0'
                  AND  m.value_as_number > 200
                  AND  m.measurement_datetime BETWEEN
                       (il.index_dt - (SELECT lookback_days FROM params) * INTERVAL '1 day')
                       AND il.index_dt
              ) THEN 1 ELSE 0 END              AS diabetes,

         CASE WHEN EXISTS (
                SELECT 1 FROM condition_occurrence co
                JOIN   concept c ON c.concept_id = co.condition_concept_id
                WHERE  co.person_id = il.person_id
                  AND  c.vocabulary_id = 'ICD9CM'
                  AND (c.concept_code LIKE 'V22%' OR
                       c.concept_code LIKE 'V23%' OR
                       c.concept_code LIKE '645%' OR
                       c.concept_code LIKE '651%' OR
                       c.concept_code LIKE '652%')
                  AND  co.condition_start_date BETWEEN
                       (il.index_dt - (SELECT lookback_days FROM params) * INTERVAL '1 day')
                       AND il.index_dt
              ) THEN 1 ELSE 0 END              AS pregnancy
  FROM   index_ldl il
),

/* ---------- 3. Stage‑1 assessment (primary hyper‑chol.) ---------- */
stage1 AS (
  SELECT il.*,
         (hypothyroid + biliary_obstruction + liver_disease +
          nephrotic + renal_failure + diabetes)          AS sec_sum,
         /* primary hyper‑chol. flag */
         CASE WHEN il.adj_ldl >= (SELECT ldl_case_mgdl FROM params)
              THEN 1 ELSE 0 END                          AS primary_case,
         /* high TG flag */
         CASE WHEN il.adj_ldl >= (SELECT ldl_flag_mgdl FROM params)
                AND EXISTS (
                     SELECT 1
                     FROM   measurement m
                     JOIN   concept c ON c.concept_id = m.measurement_concept_id
                     WHERE  m.person_id = il.person_id
                       AND  c.vocabulary_id = 'LOINC'
                       AND  c.concept_code = '2571-8'          /* TG */
                       AND  m.value_as_number >
                            (SELECT tg_flag_mgdl FROM params)
                       AND  m.measurement_datetime BETWEEN
                            (il.index_dt - (SELECT lookback_days FROM params) * INTERVAL '1 day')
                            AND il.index_dt
                )
              THEN 1 ELSE 0 END                          AS tg_flag
  FROM   index_ldl il
  JOIN   sec_cause sc USING (person_id)
),

/* ---------- 4. LDL point contribution (DLCN) ---------- */
ldl_pts AS (
  SELECT person_id,
         CASE WHEN adj_ldl >= 330 THEN 8
              WHEN adj_ldl BETWEEN 250 AND 329.999 THEN 5
              WHEN adj_ldl BETWEEN 190 AND 249.999 THEN 3
              WHEN adj_ldl BETWEEN 155 AND 189.999 THEN 1
              ELSE 0 END AS pts
  FROM   stage1
  WHERE  primary_case = 1
    AND  sec_sum = 0
),

/* ---------- 5. NLP‑derived point contribution ---------- */
nlp_pts AS (
  SELECT person_id, 6 AS pts FROM nlp_results WHERE code = 6
  UNION ALL
  SELECT person_id, 4 FROM nlp_results WHERE code = 4
  UNION ALL
  SELECT person_id, 2 FROM nlp_results WHERE code = 2
  UNION ALL
  SELECT person_id, 1 FROM nlp_results WHERE code = 1
),

/* ---------- 6. DLCN total score ---------- */
dlcn AS (
  SELECT s.person_id,
         COALESCE(l.pts,0) +
         COALESCE( (SELECT SUM(pts) FROM nlp_pts np WHERE np.person_id = s.person_id), 0)
         AS total_pts
  FROM   stage1 s
  LEFT   JOIN ldl_pts l USING (person_id)
  WHERE  s.primary_case = 1
    AND  s.sec_sum = 0
),

/* ---------- 7. Final classification ---------- */
final AS (
  SELECT s.person_id,
         s.adj_ldl,
         COALESCE(d.total_pts,0)                   AS total_pts,
         s.tg_flag,
         CASE
           WHEN COALESCE(d.total_pts,0) > 8              THEN 'DEF_FH'
           WHEN COALESCE(d.total_pts,0) BETWEEN 6 AND 8  THEN 'PROB_FH'
           WHEN COALESCE(d.total_pts,0) BETWEEN 3 AND 5  THEN 'POSS_FH'
           ELSE 'UNLIKELY_FH'
         END                                         AS fh_category,
         CASE
           WHEN COALESCE(d.total_pts,0) > 8
             OR COALESCE(d.total_pts,0) BETWEEN 6 AND 8 THEN 'CASE'
           WHEN s.primary_case = 0
             OR COALESCE(d.total_pts,0) < 3              THEN 'CONTROL'
           ELSE 'UNKNOWN'
         END                                         AS cohort_label
  FROM   stage1 s
  LEFT   JOIN dlcn d USING (person_id)
)

/* ---------- 8. Output: CASES and CONTROLS only ---------- */
SELECT person_id,
       cohort_label AS case_control,
       fh_category,
       total_pts,
       adj_ldl,
       tg_flag
FROM   final
WHERE  cohort_label <> 'UNKNOWN'          -- Possible FH suppressed
ORDER  BY case_control, person_id;
