-- Rule 1 (VUMC-specific database name): APPLIED
-- Rule 4 (LOINC, RxNorm, ICD code handling): APPLIED
-- Rule 8 (NLP staging table logic): APPLIED
-- FIX: Replaced invalid date subtraction with DATEADD for Databricks compatibility (Rule 1/4)

CREATE or REPLACE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex1_all_content_LLM1_FH AS 

WITH params AS (
  SELECT
      365   AS lookback_days,
      220.0 AS tg_flag_mgdl,
      155.0 AS ldl_flag_mgdl,
      155.0 AS ldl_case_mgdl,
      0.70  AS ldl_adj_factor
),
ldl_candidates AS (
  SELECT  m.person_id,
          m.measurement_datetime AS ldl_dt,
          m.value_as_number AS ldl_val,
          ROW_NUMBER() OVER (
              PARTITION BY m.person_id
              ORDER BY m.value_as_number DESC, m.measurement_datetime ) AS rn
  -- REVISED (was: FROM measurement m JOIN concept c ON c.concept_id = m.measurement_concept_id)
  FROM victr_sd.sd_omop_prod.measurement m
  JOIN victr_sd.sd_omop_prod.concept c ON c.concept_id = m.measurement_concept_id
  JOIN victr_sd.sd_omop_prod.person p ON p.person_id = m.person_id
  WHERE c.vocabulary_id = 'LOINC'
    AND c.concept_code IN
       ('2089-1','18262-6','49132-4','35198-1','39469-2',
        '12773-8','18261-8','22748-8','13457-7','9346-8',
        '2574-2','14815-5')
    AND YEAR(m.measurement_datetime) - p.year_of_birth >= 18
),
index_ldl AS (
  SELECT person_id,
         ldl_dt AS index_dt,
         ldl_val AS raw_ldl,
         CASE
           WHEN EXISTS (
                SELECT 1
                FROM victr_sd.sd_omop_prod.drug_exposure dx
                -- REVISED (was: JOIN concept crx ON crx.concept_id = dx.drug_concept_id WHERE crx.vocabulary_id = 'RxNorm' AND crx.concept_code IN (...))
                JOIN victr_sd.sd_omop_prod.concept_ancestor ca ON ca.descendant_concept_id = dx.drug_concept_id
                JOIN victr_sd.sd_omop_prod.concept crx ON crx.concept_id = ca.ancestor_concept_id
                WHERE crx.vocabulary_id = 'RxNorm'
                  AND crx.concept_code IN (
                       '36567','41127','6472','42463','861634',
                       '83367','301542','221072','1152441',
                       '1665895','1659156',
                       '7393','8703','4719','341248','141626',
                       '2447','2685','1367839','1364479')
                  -- REVISED (was: dx.drug_exposure_start_date BETWEEN (ldl_dt - (SELECT lookback_days FROM params)) AND ldl_dt)
                  AND dx.drug_exposure_start_date BETWEEN DATEADD(day, -1 * (SELECT lookback_days FROM params), ldl_dt) AND ldl_dt
           )
           THEN try_divide(ldl_val,(SELECT ldl_adj_factor FROM params))
           ELSE ldl_val
         END AS adj_ldl
  FROM ldl_candidates
  WHERE rn = 1
),
sec_cause AS (
  SELECT il.person_id,
         CASE WHEN EXISTS (
                SELECT 1 FROM victr_sd.sd_omop_prod.measurement m
                JOIN victr_sd.sd_omop_prod.concept c ON c.concept_id = m.measurement_concept_id
                WHERE m.person_id = il.person_id
                  AND c.vocabulary_id = 'LOINC'
                  AND c.concept_code IN ('11579-0','24348-5')
                  AND m.value_as_number >= 10
                  -- REVISED (was: m.measurement_datetime BETWEEN (il.index_dt - (SELECT lookback_days FROM params)) AND il.index_dt)
                  AND m.measurement_datetime BETWEEN DATEADD(day, -1 * (SELECT lookback_days FROM params), il.index_dt) AND il.index_dt
              ) THEN 1 ELSE 0 END AS hypothyroid,
         CASE WHEN EXISTS (
                SELECT 1 FROM victr_sd.sd_omop_prod.measurement m
                JOIN victr_sd.sd_omop_prod.concept c ON c.concept_id = m.measurement_concept_id
                WHERE m.person_id = il.person_id
                  AND c.vocabulary_id = 'LOINC'
                  AND c.concept_code IN ('6768-6','12805-8')
                  AND m.value_as_number >= 200
                  -- REVISED (was: m.measurement_datetime BETWEEN (il.index_dt - (SELECT lookback_days FROM params)) AND il.index_dt)
                  AND m.measurement_datetime BETWEEN DATEADD(day, -1 * (SELECT lookback_days FROM params), il.index_dt) AND il.index_dt
              ) THEN 1 ELSE 0 END AS biliary_obstruction,
         CASE WHEN EXISTS (
                SELECT 1 FROM victr_sd.sd_omop_prod.measurement m
                JOIN victr_sd.sd_omop_prod.concept c ON c.concept_id = m.measurement_concept_id
                WHERE m.person_id = il.person_id
                  AND c.vocabulary_id = 'LOINC'
                  AND c.concept_code = '35194-0'
                  AND m.value_as_number > 2.0
                  -- REVISED (was: m.measurement_datetime BETWEEN (il.index_dt - (SELECT lookback_days FROM params)) AND il.index_dt)
                  AND m.measurement_datetime BETWEEN DATEADD(day, -1 * (SELECT lookback_days FROM params), il.index_dt) AND il.index_dt
              ) THEN 1 ELSE 0 END AS liver_disease,
         CASE WHEN EXISTS (
                SELECT 1 FROM victr_sd.sd_omop_prod.measurement m
                JOIN victr_sd.sd_omop_prod.concept c ON c.concept_id = m.measurement_concept_id
                WHERE m.person_id = il.person_id
                  AND c.vocabulary_id = 'LOINC'
                  AND c.concept_code = '13801-6'
                  AND m.value_as_number > 3
                  -- REVISED (was: m.measurement_datetime BETWEEN (il.index_dt - (SELECT lookback_days FROM params)) AND il.index_dt)
                  AND m.measurement_datetime BETWEEN DATEADD(day, -1 * (SELECT lookback_days FROM params), il.index_dt) AND il.index_dt
              ) THEN 1 ELSE 0 END AS nephrotic,
         CASE WHEN EXISTS (
                SELECT 1 FROM victr_sd.sd_omop_prod.measurement m
                JOIN victr_sd.sd_omop_prod.concept c ON c.concept_id = m.measurement_concept_id
                WHERE m.person_id = il.person_id
                  AND c.vocabulary_id = 'LOINC'
                  AND c.concept_code = '14682-9'
                  AND m.value_as_number > 2.6
                  -- REVISED (was: m.measurement_datetime BETWEEN (il.index_dt - (SELECT lookback_days FROM params)) AND il.index_dt)
                  AND m.measurement_datetime BETWEEN DATEADD(day, -1 * (SELECT lookback_days FROM params), il.index_dt) AND il.index_dt
              ) OR EXISTS (
                SELECT 1 FROM victr_sd.sd_omop_prod.measurement m
                JOIN victr_sd.sd_omop_prod.concept c ON c.concept_id = m.measurement_concept_id
                WHERE m.person_id = il.person_id
                  AND c.vocabulary_id = 'LOINC'
                  AND c.concept_code = '50261-7'
                  AND m.value_as_number < 15
                  -- REVISED (was: m.measurement_datetime BETWEEN (il.index_dt - (SELECT lookback_days FROM params)) AND il.index_dt)
                  AND m.measurement_datetime BETWEEN DATEADD(day, -1 * (SELECT lookback_days FROM params), il.index_dt) AND il.index_dt
              ) THEN 1 ELSE 0 END AS renal_failure,
         CASE WHEN EXISTS (
                SELECT 1 FROM victr_sd.sd_omop_prod.measurement m
                JOIN victr_sd.sd_omop_prod.concept c ON c.concept_id = m.measurement_concept_id
                WHERE m.person_id = il.person_id
                  AND c.vocabulary_id = 'LOINC'
                  AND c.concept_code = '4549-2'
                  AND m.value_as_number > 9
                  -- REVISED (was: m.measurement_datetime BETWEEN (il.index_dt - (SELECT lookback_days FROM params)) AND il.index_dt)
                  AND m.measurement_datetime BETWEEN DATEADD(day, -1 * (SELECT lookback_days FROM params), il.index_dt) AND il.index_dt
              ) OR EXISTS (
                SELECT 1 FROM victr_sd.sd_omop_prod.measurement m
                JOIN victr_sd.sd_omop_prod.concept c ON c.concept_id = m.measurement_concept_id
                WHERE m.person_id = il.person_id
                  AND c.vocabulary_id = 'LOINC'
                  AND c.concept_code = '1558-6'
                  AND m.value_as_number > 220
                  -- REVISED (was: m.measurement_datetime BETWEEN (il.index_dt - (SELECT lookback_days FROM params)) AND il.index_dt)
                  AND m.measurement_datetime BETWEEN DATEADD(day, -1 * (SELECT lookback_days FROM params), il.index_dt) AND il.index_dt
              ) OR EXISTS (
                SELECT 1 FROM victr_sd.sd_omop_prod.measurement m
                JOIN victr_sd.sd_omop_prod.concept c ON c.concept_id = m.measurement_concept_id
                WHERE m.person_id = il.person_id
                  AND c.vocabulary_id = 'LOINC'
                  AND c.concept_code = '1556-0'
                  AND m.value_as_number > 200
                  -- REVISED (was: m.measurement_datetime BETWEEN (il.index_dt - (SELECT lookback_days FROM params)) AND il.index_dt)
                  AND m.measurement_datetime BETWEEN DATEADD(day, -1 * (SELECT lookback_days FROM params), il.index_dt) AND il.index_dt
              ) THEN 1 ELSE 0 END AS diabetes,
         CASE WHEN EXISTS (
                SELECT 1 FROM victr_sd.sd_omop_prod.condition_occurrence co
                WHERE co.person_id = il.person_id
                  AND co.condition_source_value LIKE 'V22%'
                  -- REVISED (was: co.condition_start_date BETWEEN (il.index_dt - (SELECT lookback_days FROM params)) AND il.index_dt)
                  AND co.condition_start_date BETWEEN DATEADD(day, -1 * (SELECT lookback_days FROM params), il.index_dt) AND il.index_dt
              ) OR EXISTS (
                SELECT 1 FROM victr_sd.sd_omop_prod.condition_occurrence co
                WHERE co.person_id = il.person_id
                  AND co.condition_source_value LIKE 'V23%'
                  -- REVISED (was: co.condition_start_date BETWEEN (il.index_dt - (SELECT lookback_days FROM params)) AND il.index_dt)
                  AND co.condition_start_date BETWEEN DATEADD(day, -1 * (SELECT lookback_days FROM params), il.index_dt) AND il.index_dt
              ) OR EXISTS (
                SELECT 1 FROM victr_sd.sd_omop_prod.condition_occurrence co
                WHERE co.person_id = il.person_id
                  AND co.condition_source_value LIKE '645%'
                  -- REVISED (was: co.condition_start_date BETWEEN (il.index_dt - (SELECT lookback_days FROM params)) AND il.index_dt)
                  AND co.condition_start_date BETWEEN DATEADD(day, -1 * (SELECT lookback_days FROM params), il.index_dt) AND il.index_dt
              ) OR EXISTS (
                SELECT 1 FROM victr_sd.sd_omop_prod.condition_occurrence co
                WHERE co.person_id = il.person_id
                  AND co.condition_source_value LIKE '651%'
                  -- REVISED (was: co.condition_start_date BETWEEN (il.index_dt - (SELECT lookback_days FROM params)) AND il.index_dt)
                  AND co.condition_start_date BETWEEN DATEADD(day, -1 * (SELECT lookback_days FROM params), il.index_dt) AND il.index_dt
              ) OR EXISTS (
                SELECT 1 FROM victr_sd.sd_omop_prod.condition_occurrence co
                WHERE co.person_id = il.person_id
                  AND co.condition_source_value LIKE '652%'
                  -- REVISED (was: co.condition_start_date BETWEEN (il.index_dt - (SELECT lookback_days FROM params)) AND il.index_dt)
                  AND co.condition_start_date BETWEEN DATEADD(day, -1 * (SELECT lookback_days FROM params), il.index_dt) AND il.index_dt
              ) THEN 1 ELSE 0 END AS pregnancy
  FROM index_ldl il
),
stage1 AS (
  SELECT il.*, sc.hypothyroid, sc.biliary_obstruction, sc.liver_disease, sc.nephrotic, sc.renal_failure, sc.diabetes, sc.pregnancy,
         (sc.hypothyroid + sc.biliary_obstruction + sc.liver_disease + sc.nephrotic + sc.renal_failure + sc.diabetes) AS sec_sum,
         CASE WHEN il.adj_ldl >= (SELECT ldl_case_mgdl FROM params) THEN 1 ELSE 0 END AS primary_case,
         CASE WHEN il.adj_ldl >= (SELECT ldl_flag_mgdl FROM params)
                AND EXISTS (
                     SELECT 1
                     FROM victr_sd.sd_omop_prod.measurement m
                     JOIN victr_sd.sd_omop_prod.concept c ON c.concept_id = m.measurement_concept_id
                     WHERE m.person_id = il.person_id
                       AND c.vocabulary_id = 'LOINC'
                       AND c.concept_code = '2571-8'
                       AND m.value_as_number > (SELECT tg_flag_mgdl FROM params)
                       -- REVISED (was: m.measurement_datetime BETWEEN (il.index_dt - (SELECT lookback_days FROM params)) AND il.index_dt)
                       AND m.measurement_datetime BETWEEN DATEADD(day, -1 * (SELECT lookback_days FROM params), il.index_dt) AND il.index_dt
                )
              THEN 1 ELSE 0 END AS tg_flag
  FROM index_ldl il
  JOIN sec_cause sc ON il.person_id = sc.person_id
),
ldl_pts AS (
  SELECT person_id,
         CASE WHEN adj_ldl >= 330 THEN 8
              WHEN adj_ldl BETWEEN 250 AND 329.999 THEN 5
              WHEN adj_ldl BETWEEN 190 AND 249.999 THEN 3
              WHEN adj_ldl BETWEEN 155 AND 189.999 THEN 1
              ELSE 0 END AS pts
  FROM stage1
  WHERE primary_case = 1
    AND sec_sum = 0
),
dlcn AS (
  SELECT s.person_id,
         COALESCE(l.pts,0) AS total_pts
  FROM stage1 s
  LEFT JOIN ldl_pts l ON s.person_id = l.person_id
  WHERE s.primary_case = 1
    AND s.sec_sum = 0
),
final AS (
  SELECT s.person_id,
         s.adj_ldl,
         COALESCE(d.total_pts,0) AS total_pts,
         s.tg_flag,
         CASE
           WHEN COALESCE(d.total_pts,0) > 8 THEN 'DEF_FH'
           WHEN COALESCE(d.total_pts,0) BETWEEN 6 AND 8 THEN 'PROB_FH'
           WHEN COALESCE(d.total_pts,0) BETWEEN 3 AND 5 THEN 'POSS_FH'
           ELSE 'UNLIKELY_FH'
         END AS fh_category,
         CASE
           WHEN COALESCE(d.total_pts,0) > 8
             OR COALESCE(d.total_pts,0) BETWEEN 6 AND 8 THEN 'CASE'
           WHEN s.primary_case = 0
             OR COALESCE(d.total_pts,0) < 3 THEN 'CONTROL'
           ELSE 'UNKNOWN'
         END AS cohort_label
  FROM stage1 s
  LEFT JOIN dlcn d ON s.person_id = d.person_id
)
SELECT person_id,
       cohort_label AS case_control,
       fh_category,
       total_pts,
       adj_ldl,
       tg_flag
FROM final
WHERE cohort_label <> 'UNKNOWN'
ORDER BY case_control, person_id;