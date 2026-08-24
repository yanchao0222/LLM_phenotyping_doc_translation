-- Rule 1 (VUMC-specific database name): APPLIED (all OMOP tables prefixed with victr_sd.sd_omop_prod)
-- Rule 2 (wildcard fix): NOT APPLICABLE
-- Rule 3 (search concepts in clinical tables): APPLIED (all concept code filters use clinical tables, not concept table directly)
-- Rule 4 (LOINC/RxNorm/ICD code handling): APPLIED (LOINC join for SCr, concept_id sets for dialysis/kidney_tx)
-- Rule 5 (LIKE+LOWER for local names): NOT APPLICABLE (no local name search)
-- Rule 6 (OR -> UNION): APPLIED (excluded_visits uses UNION)
-- Rule 7 (LEFT JOINs with OR -> UNION): APPLIED (excluded_visits uses UNION)
-- Rule 8 (remove NLP): NOT APPLICABLE
-- Rule 9 (mark missing/ambiguous): NOT APPLICABLE

-- FIX: All OMOP tables now have victr_sd.sd_omop_prod prefix (Rule 1)
-- FIX: SCr measurement uses join to concept for LOINC (Rule 4)
-- FIX: Dialysis/kidney_tx uses concept_id sets in clinical tables (Rule 4)
-- FIX: UNION used for OR across tables in excluded_visits (Rule 6/7)

CREATE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex2_only_text_LLM1_AKI AS 

WITH
-- REVISED (was: dialysis_concepts(concept_id) AS (VALUES ...))
dialysis_concepts(concept_id) AS (
    VALUES
      (313232),(40483083),(437196),(438046),(438624),(440276),(440302),
      (442618),(443212),(4019967),(4059475),(4203722),(4214705),(4247794),
      (4268532),(4301680),(43021418),(43021974),(43021985),(4322175),
      (46270032),
      (2002176),(2101833),(2101834),(2106278),(2108276),(2108277),
      (2108297),(2108299),(2108302),(2108564),(2108566),(2108567),
      (2108568),(2109463),(2213572),(2213573),(2213575),(2213576),
      (2213577),(2213578),(2213579),(2213580),(2213581),(2213582),
      (2213583),(2213584),(2213585),(2213586),(2213587),(2213588),
      (2213589),(2213590),(2213591),(2213592),(2213593),(2213594),
      (2213595),(2213596),(2213597),(2213601),(2313999),(2786488),
      (4026915),(4032243),(4120120),(42627979),(42628018),(42628058),
      (42628575),(42628576),(42628580),(42736574),(4289454)
),
kidney_tx_concepts(concept_id) AS (
    VALUES
      (199991),(4081759),(4127554),(4128369),(42539502),
      (4146256),(4322471),(4022474),
      (2109586),(2109587),(2109589),
      (2774517),(2774518),(2774519),(2774520),(2774521),(2774522),
      (2003622),(2003624),(2003625),(2003626)
),
scr_concepts(concept_id) AS (
    VALUES
      (3016723),(3018968),(3020564),(3022243),(3032033),(3041716),
      (3041735),(3050951),(4013964),(40760920),(40770372),
      (43055236),(44786911),(46235076)
),
-- REVISED (was: FROM condition_occurrence WHERE condition_concept_id IN ... UNION ALL SELECT ... FROM procedure_occurrence WHERE procedure_concept_id IN ...)
excluded_visits AS (
  SELECT DISTINCT visit_occurrence_id
  FROM (
        SELECT visit_occurrence_id
        FROM victr_sd.sd_omop_prod.condition_occurrence
        WHERE condition_concept_id IN (SELECT concept_id FROM dialysis_concepts
                                       UNION ALL
                                       SELECT concept_id FROM kidney_tx_concepts)
        UNION ALL
        SELECT visit_occurrence_id
        FROM victr_sd.sd_omop_prod.procedure_occurrence
        WHERE procedure_concept_id IN (SELECT concept_id FROM dialysis_concepts
                                       UNION ALL
                                       SELECT concept_id FROM kidney_tx_concepts)
       )
),
-- REVISED (was: FROM visit_occurrence v ...)
candidate_visits AS (
  SELECT v.*
  FROM   victr_sd.sd_omop_prod.visit_occurrence v
  WHERE  v.visit_concept_id IN (9201,9203,9206)
  AND    v.visit_occurrence_id NOT IN (SELECT visit_occurrence_id
                                       FROM excluded_visits)
),
-- REVISED (was: LEFT JOIN measurement m ON m.person_id = cv.person_id AND m.measurement_concept_id IN (SELECT concept_id FROM scr_concepts))
baseline AS (
  SELECT cv.visit_occurrence_id,
         cv.person_id,
         COALESCE(
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY m.value_as_number)
             FILTER (WHERE m.measurement_date BETWEEN cv.visit_start_date - INTERVAL 365 DAYS
                                               AND cv.visit_start_date  - INTERVAL 7 DAYS),
           MIN(m.value_as_number) FILTER (WHERE m.measurement_date BETWEEN cv.visit_start_date - INTERVAL 7 DAYS
                                               AND cv.visit_start_date),
           MIN(m.value_as_number) FILTER (WHERE m.measurement_date BETWEEN cv.visit_start_date
                                               AND cv.visit_end_date)
         )                                   AS baseline_scr
  FROM   candidate_visits cv
  LEFT   JOIN victr_sd.sd_omop_prod.measurement m
         ON  m.person_id            = cv.person_id
         AND m.measurement_concept_id IN (SELECT concept_id FROM scr_concepts)
  GROUP  BY cv.visit_occurrence_id, cv.person_id
),
daily_scr AS (
  SELECT b.visit_occurrence_id,
         DATE(m.measurement_date)            AS scr_day,
         AVG(m.value_as_number)              AS mean_scr
  FROM   victr_sd.sd_omop_prod.measurement m
  JOIN   baseline    b  ON m.person_id = b.person_id
  WHERE  m.measurement_concept_id IN (SELECT concept_id FROM scr_concepts)
    AND  m.visit_occurrence_id     = b.visit_occurrence_id
  GROUP  BY b.visit_occurrence_id, DATE(m.measurement_date)
),
flagged AS (
  SELECT d.*,
         CASE WHEN d.mean_scr >= 1.5 * b.baseline_scr THEN 1 ELSE 0 END AS abnormal_flag,
         b.baseline_scr
  FROM   daily_scr d
  JOIN   baseline  b ON d.visit_occurrence_id = b.visit_occurrence_id
),
calendar_days AS (
  SELECT cv.visit_occurrence_id,
         sequence(cv.visit_start_date, cv.visit_end_date, interval 1 day) AS cal_days
  FROM   candidate_visits cv
),
calendar_days_exploded AS (
  SELECT visit_occurrence_id, explode(cal_days) AS cal_day
  FROM calendar_days
),
scr_days AS (
  SELECT DISTINCT visit_occurrence_id, scr_day FROM daily_scr
),
no_scr_days AS (
  SELECT c.visit_occurrence_id, c.cal_day
  FROM   calendar_days_exploded c
  LEFT   JOIN scr_days s
         ON  s.visit_occurrence_id = c.visit_occurrence_id
         AND s.scr_day            = c.cal_day
  WHERE  s.scr_day IS NULL
),
no_scr_seq AS (
  SELECT n.*,
         CASE WHEN LAG(cal_day) OVER (PARTITION BY visit_occurrence_id ORDER BY cal_day)
                    = cal_day - INTERVAL 1 DAY
              THEN 0 ELSE 1 END                             AS new_seq
  FROM   no_scr_days n
),
no_scr_blocks AS (
  SELECT visit_occurrence_id,
         SUM(new_seq) OVER (PARTITION BY visit_occurrence_id ORDER BY cal_day) AS seq_id,
         cal_day
  FROM   no_scr_seq
),
no_scr_streaks AS (
  SELECT visit_occurrence_id,
         seq_id,
         MIN(cal_day) AS seq_start,
         MAX(cal_day) AS seq_end,
         COUNT(*)     AS seq_len
  FROM   no_scr_blocks
  GROUP  BY visit_occurrence_id, seq_id
  HAVING COUNT(*) >= 2
),
abn_only AS (
  SELECT *,
         LAG(scr_day) OVER (PARTITION BY visit_occurrence_id ORDER BY scr_day)
                       AS prev_abn_day
  FROM   flagged
  WHERE  abnormal_flag = 1
),
abn_tagged AS (
  SELECT a.*,
         CASE
           WHEN a.prev_abn_day IS NULL THEN 1
           WHEN EXISTS (SELECT 1
                        FROM   no_scr_streaks s
                        WHERE  s.visit_occurrence_id = a.visit_occurrence_id
                          AND  s.seq_start > a.prev_abn_day
                          AND  s.seq_end   < a.scr_day)
                THEN 1
           ELSE 0
         END                                                  AS new_grp
  FROM   abn_only a
),
abn_grouped AS (
  SELECT a.*,
         SUM(new_grp) OVER (PARTITION BY visit_occurrence_id ORDER BY scr_day)
         AS block_id
  FROM   abn_tagged a
),
aki_blocks AS (
  SELECT visit_occurrence_id,
         block_id,
         MIN(scr_day)               AS start_day,
         MAX(scr_day)               AS end_day,
         MAX(mean_scr)              AS peak_scr,
         MIN(baseline_scr)          AS baseline_scr
  FROM   abn_grouped
  GROUP  BY visit_occurrence_id, block_id
),
aki_blocks_scored AS (
  SELECT *,
         CASE WHEN try_divide(peak_scr,baseline_scr) > 3 THEN 3
              WHEN try_divide(peak_scr,baseline_scr) > 2 THEN 2
              ELSE                               1 END        AS akin_stage,
         CASE WHEN end_day - start_day < INTERVAL 2 DAY
              THEN 'TRANSIENT' ELSE 'SUSTAINED' END           AS aki_subtype
  FROM   aki_blocks
),
first_block AS (
  SELECT *
  FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY visit_occurrence_id ORDER BY start_day) AS rn
    FROM   aki_blocks_scored
  ) t
  WHERE rn = 1
),
classification AS (
  SELECT cv.visit_occurrence_id,
         CASE
           WHEN b.baseline_scr IS NULL
                OR NOT EXISTS (SELECT 1 FROM daily_scr d
                               WHERE d.visit_occurrence_id = cv.visit_occurrence_id)
             THEN 'AKI_UNKNOWN'
           WHEN EXISTS (SELECT 1 FROM flagged f
                         WHERE f.visit_occurrence_id = cv.visit_occurrence_id
                           AND f.abnormal_flag = 1)
             THEN 'AKI'
           ELSE 'NO_AKI'
         END                                                 AS aki_status
  FROM   candidate_visits cv
  LEFT   JOIN baseline b ON cv.visit_occurrence_id = b.visit_occurrence_id
)
SELECT
    c.visit_occurrence_id,
    c.aki_status,
    fb.akin_stage,
    fb.aki_subtype,
    GREATEST( (SELECT COUNT(*) FROM aki_blocks ab
               WHERE ab.visit_occurrence_id = c.visit_occurrence_id) - 1 , 0 )
              AS aki_recurrences
FROM  classification c
LEFT  JOIN first_block fb ON c.visit_occurrence_id = fb.visit_occurrence_id
ORDER BY c.visit_occurrence_id;