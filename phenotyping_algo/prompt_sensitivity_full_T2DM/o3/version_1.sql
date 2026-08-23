/* ===========================================================
   Northwestern T2DM phenotype — OMOP CDM v5.x implementation
   Read-only query returning person_id, phenotype_group, index_date
   =========================================================== */

WITH
/* -----------------------------------------------------------
   1.  SOURCE CODE LIST  (exact values from PDF, pp. 21-23)
   ----------------------------------------------------------- */
source_codes(code, vocabulary_id, set_name) AS (
    VALUES
      /* T1DM diagnoses (Table 3) */
      ('250.x1','ICD9CM','T1DM_DX'),
      ('250.x3','ICD9CM','T1DM_DX'),

      /* T2DM diagnoses (Table 4) — exclude 250.10, 250.12 */
      ('250.x0','ICD9CM','T2DM_DX'),
      ('250.x2','ICD9CM','T2DM_DX'),

      /* DM-related diagnoses (Table 9) for controls */
      ('250.xx','ICD9CM','DM_RELATED_DX'),
      ('790.21','ICD9CM','DM_RELATED_DX'),
      ('790.22','ICD9CM','DM_RELATED_DX'),
      ('790.2','ICD9CM','DM_RELATED_DX'),
      ('790.29','ICD9CM','DM_RELATED_DX'),
      ('648.8x','ICD9CM','DM_RELATED_DX'),
      ('648.0x','ICD9CM','DM_RELATED_DX'),
      ('791.5','ICD9CM','DM_RELATED_DX'),
      ('277.7','ICD9CM','DM_RELATED_DX'),
      ('V18.0','ICD9CM','DM_RELATED_DX'),
      ('V77.1','ICD9CM','DM_RELATED_DX'),

      /* T1DM medications (Table 5) */
      ('139825','RxNorm','T1DM_RX'), ('274783','RxNorm','T1DM_RX'),
      ('314684','RxNorm','T1DM_RX'), ('352385','RxNorm','T1DM_RX'),
      ('400008','RxNorm','T1DM_RX'), ('51428','RxNorm','T1DM_RX'),
      ('5856','RxNorm','T1DM_RX'),  ('86009','RxNorm','T1DM_RX'),
      ('139953','RxNorm','T1DM_RX'),

      /* T2DM medications (Table 6) */
      ('173','RxNorm','T2DM_RX'),  ('10633','RxNorm','T2DM_RX'),
      ('2404','RxNorm','T2DM_RX'), ('4821','RxNorm','T2DM_RX'),
      ('217360','RxNorm','T2DM_RX'),('4815','RxNorm','T2DM_RX'),
      ('25789','RxNorm','T2DM_RX'), ('73044','RxNorm','T2DM_RX'),
      ('274332','RxNorm','T2DM_RX'),('6809','RxNorm','T2DM_RX'),
      ('84108','RxNorm','T2DM_RX'), ('33738','RxNorm','T2DM_RX'),
      ('72610','RxNorm','T2DM_RX'), ('16681','RxNorm','T2DM_RX'),
      ('30009','RxNorm','T2DM_RX'), ('593411','RxNorm','T2DM_RX'),
      ('60548','RxNorm','T2DM_RX'),

      /* Diabetes supplies (Table 8) — RxNorm, NDDF, VANDF */
      ('847187','RxNorm','DM_SUPPLY'),('847191','RxNorm','DM_SUPPLY'),
      ('847197','RxNorm','DM_SUPPLY'),('847203','RxNorm','DM_SUPPLY'),
      ('847207','RxNorm','DM_SUPPLY'),('847211','RxNorm','DM_SUPPLY'),
      ('847230','RxNorm','DM_SUPPLY'),('847239','RxNorm','DM_SUPPLY'),
      ('847252','RxNorm','DM_SUPPLY'),('847256','RxNorm','DM_SUPPLY'),
      ('847259','RxNorm','DM_SUPPLY'),('847263','RxNorm','DM_SUPPLY'),
      ('847278','RxNorm','DM_SUPPLY'),('847416','RxNorm','DM_SUPPLY'),
      ('847417','RxNorm','DM_SUPPLY'),
      ('126958','NDDF','DM_SUPPLY'),('412956','NDDF','DM_SUPPLY'),
      ('412959','NDDF','DM_SUPPLY'),('637321','NDDF','DM_SUPPLY'),
      ('668291','NDDF','DM_SUPPLY'),('668370','NDDF','DM_SUPPLY'),
      ('686655','NDDF','DM_SUPPLY'),('692383','NDDF','DM_SUPPLY'),
      ('748611','NDDF','DM_SUPPLY'),('880998','NDDF','DM_SUPPLY'),
      ('881056','NDDF','DM_SUPPLY'),('806905','NDDF','DM_SUPPLY'),
      ('806903','NDDF','DM_SUPPLY'),('408119','NDDF','DM_SUPPLY'),
      ('751128','VANDF','DM_SUPPLY'),

      /* Laboratory LOINC codes (Table 7) */
      ('2339-0','LOINC','RANDOM_GLU'),
      ('2345-7','LOINC','RANDOM_GLU'),
      ('1558-6','LOINC','FAST_GLU'),
      ('4548-4','LOINC','HBA1C'),
      ('17856-6','LOINC','HBA1C'),
      ('4549-2','LOINC','HBA1C'),
      ('17855-8','LOINC','HBA1C')
),

/* -----------------------------------------------------------
   2.  CONCEPT RESOLUTION (exact match, no descendants)
   ----------------------------------------------------------- */
concept_set AS (
  SELECT c.concept_id,
         sc.set_name
  FROM source_codes sc
  JOIN concept c
    ON c.vocabulary_id = sc.vocabulary_id
   AND c.concept_code  = sc.code
),
unresolved_codes AS (
  SELECT *
  FROM source_codes sc
  WHERE NOT EXISTS (
        SELECT 1 FROM concept c
        WHERE c.vocabulary_id = sc.vocabulary_id
          AND c.concept_code  = sc.code)
),

/* -----------------------------------------------------------
   3.  BASE POPULATION
   ----------------------------------------------------------- */
base_pop AS (SELECT person_id FROM person),

/* -----------------------------------------------------------
   4.  EVENT CTEs  (all predicates from PDF)
   ----------------------------------------------------------- */
/* Diagnoses -------------------------------------------------- */
t1dm_dx AS (
  SELECT person_id, condition_start_date AS event_dt
  FROM condition_occurrence
  WHERE condition_source_concept_id IN (
        SELECT concept_id FROM concept_set WHERE set_name='T1DM_DX')
),
t2dm_dx AS (
  SELECT person_id, condition_start_date AS event_dt
  FROM condition_occurrence
  WHERE condition_source_concept_id IN (
        SELECT concept_id FROM concept_set WHERE set_name='T2DM_DX')
),
phys_t2dm_dx AS (
  /* NOTE: OMOP lacks a universal field to flag encounter/problem-list;
           therefore this counts ALL T2DM source diagnoses. */
  SELECT person_id, condition_start_date AS event_dt
  FROM condition_occurrence
  WHERE condition_source_concept_id IN (
        SELECT concept_id FROM concept_set WHERE set_name='T2DM_DX')
),
dm_related_dx AS (
  SELECT person_id, condition_start_date AS event_dt
  FROM condition_occurrence
  WHERE condition_source_concept_id IN (
        SELECT concept_id FROM concept_set WHERE set_name='DM_RELATED_DX')
),

/* Medications & supplies ------------------------------------ */
t1dm_rx AS (
  SELECT person_id, drug_exposure_start_date AS rx_dt
  FROM drug_exposure
  WHERE drug_source_concept_id IN (
        SELECT concept_id FROM concept_set WHERE set_name='T1DM_RX')
),
t2dm_rx AS (
  SELECT person_id, drug_exposure_start_date AS rx_dt
  FROM drug_exposure
  WHERE drug_source_concept_id IN (
        SELECT concept_id FROM concept_set WHERE set_name='T2DM_RX')
),
dm_supply_rx AS (
  /* combines drug and device supplies (Table 8) */
  SELECT person_id, drug_exposure_start_date AS rx_dt
  FROM drug_exposure
  WHERE drug_source_concept_id IN (
        SELECT concept_id FROM concept_set WHERE set_name='DM_SUPPLY')
  UNION ALL
  SELECT person_id, device_exposure_start_date
  FROM device_exposure
  WHERE device_source_concept_id IN (
        SELECT concept_id FROM concept_set WHERE set_name='DM_SUPPLY')
),

/* Laboratory measurements (Tables 7, definitions pp. 2 & 8) --*/
measurement_all AS (
  SELECT person_id,
         measurement_date,
         value_as_number,
         measurement_source_concept_id
  FROM measurement
  WHERE measurement_source_concept_id IN (
        SELECT concept_id FROM concept_set
        WHERE set_name IN ('RANDOM_GLU','FAST_GLU','HBA1C'))
),
abn_lab_case AS (
  SELECT DISTINCT m.person_id
  FROM measurement_all m
  JOIN concept_set cs ON cs.concept_id = m.measurement_source_concept_id
  WHERE (cs.set_name = 'RANDOM_GLU' AND m.value_as_number > 200)
     OR (cs.set_name = 'FAST_GLU'   AND m.value_as_number >= 125)
     OR (cs.set_name = 'HBA1C'      AND m.value_as_number >= 6.5)
),
abn_lab_ctrl AS (
  SELECT DISTINCT m.person_id
  FROM measurement_all m
  JOIN concept_set cs ON cs.concept_id = m.measurement_source_concept_id
  WHERE (cs.set_name = 'RANDOM_GLU' AND m.value_as_number > 110)
     OR (cs.set_name = 'FAST_GLU'   AND m.value_as_number >= 110)
     OR (cs.set_name = 'HBA1C'      AND m.value_as_number >= 6.0)
),
glucose_lab_exists AS (
  SELECT DISTINCT person_id
  FROM measurement_all
  WHERE measurement_source_concept_id IN (
        SELECT concept_id FROM concept_set
        WHERE set_name IN ('RANDOM_GLU','FAST_GLU'))
),

/* Visits (Algorithm 12) ------------------------------------- */
office_visits AS (
  /* NOTE: site must map visit_concept_id or visit_type_concept_id
           values that represent face-to-face office encounters.     */
  SELECT person_id, visit_start_date
  FROM visit_occurrence
),

/* Family history (Algorithm 14) ------------------------------ */
fam_hist_dm AS (
  /* NOTE: family-history concepts are site-specific; this CTE
           returns zero rows unless mapped locally.                */
  SELECT person_id
  FROM observation
  WHERE 1=0   -- placeholder
),

/* -----------------------------------------------------------
   5.  AGGREGATED FLAGS & COUNTS
   ----------------------------------------------------------- */
agg AS (
SELECT
    p.person_id,

    /* Dx counts */
    (SELECT COUNT(DISTINCT event_dt) FROM t1dm_dx  WHERE person_id=p.person_id) AS cnt_t1dx,
    (SELECT COUNT(DISTINCT event_dt) FROM t2dm_dx  WHERE person_id=p.person_id) AS cnt_t2dx,
    (SELECT COUNT(DISTINCT event_dt) FROM phys_t2dm_dx WHERE person_id=p.person_id) AS cnt_phys_t2dx,
    (SELECT COUNT(DISTINCT event_dt) FROM dm_related_dx WHERE person_id=p.person_id) AS cnt_dmrel_dx,

    /* Rx earliest dates & counts */
    (SELECT MIN(rx_dt) FROM t1dm_rx WHERE person_id=p.person_id) AS first_t1rx_dt,
    (SELECT MIN(rx_dt) FROM t2dm_rx WHERE person_id=p.person_id) AS first_t2rx_dt,
    (SELECT COUNT(DISTINCT rx_dt) FROM t1dm_rx WHERE person_id=p.person_id) AS cnt_t1rx_dt,
    (SELECT COUNT(DISTINCT rx_dt) FROM t2dm_rx WHERE person_id=p.person_id) AS cnt_t2rx_dt,
    (SELECT COUNT(DISTINCT rx_dt) FROM dm_supply_rx WHERE person_id=p.person_id)  AS cnt_supply_dt,

    /* Visit count */
    (SELECT COUNT(DISTINCT visit_start_date) FROM office_visits
      WHERE person_id=p.person_id) AS cnt_office,

    /* Lab flags */
    EXISTS (SELECT 1 FROM abn_lab_case  WHERE person_id=p.person_id) AS flag_abn_case,
    EXISTS (SELECT 1 FROM abn_lab_ctrl WHERE person_id=p.person_id) AS flag_abn_ctrl,
    EXISTS (SELECT 1 FROM glucose_lab_exists WHERE person_id=p.person_id) AS flag_glu_exists,

    /* Family history flag */
    EXISTS (SELECT 1 FROM fam_hist_dm WHERE person_id=p.person_id) AS flag_famhist
FROM base_pop p
),

/* -----------------------------------------------------------
   6.  CASE CLASSIFICATION  (PDF Fig. 1 & Algorithm 1)
   ----------------------------------------------------------- */
cases AS (
SELECT person_id,
       'CASE'  AS phenotype_group,
       NULL::date AS index_date   -- no index-date rule specified
FROM agg
WHERE
      /* Path 1 */
      ( cnt_t1dx = 0
        AND cnt_t2dx > 0
        AND first_t2rx_dt IS NOT NULL
        AND first_t1rx_dt IS NOT NULL
        AND first_t2rx_dt < first_t1rx_dt )
   OR /* Path 2 */
      ( cnt_t1dx = 0
        AND cnt_t2dx > 0
        AND first_t1rx_dt IS NULL
        AND first_t2rx_dt IS NOT NULL )
   OR /* Path 3 */
      ( cnt_t1dx = 0
        AND cnt_t2dx > 0
        AND first_t1rx_dt IS NULL
        AND first_t2rx_dt IS NULL
        AND flag_abn_case )
   OR /* Path 4 */
      ( cnt_t1dx = 0
        AND cnt_t2dx = 0
        AND first_t2rx_dt IS NOT NULL
        AND flag_abn_case )
   OR /* Path 5 */
      ( cnt_t1dx = 0
        AND cnt_t2dx > 0
        AND first_t1rx_dt IS NOT NULL
        AND first_t2rx_dt IS NULL
        AND cnt_phys_t2dx >= 2 )
),

/* -----------------------------------------------------------
   7.  CONTROL CLASSIFICATION  (PDF Fig. 2 & Algorithm 8)
   ----------------------------------------------------------- */
controls AS (
SELECT person_id,
       'CONTROL' AS phenotype_group,
       NULL::date AS index_date
FROM agg a
WHERE
      cnt_dmrel_dx = 0
  AND flag_glu_exists
  AND NOT flag_abn_ctrl
  AND cnt_office >= 2
  AND (cnt_t1rx_dt + cnt_t2rx_dt + cnt_supply_dt) = 0
  AND NOT flag_famhist
  /* precedence rule – cannot already be a case */
  AND NOT EXISTS (SELECT 1 FROM cases c WHERE c.person_id=a.person_id)
)

/* -----------------------------------------------------------
   8.  FINAL RESULT SET
   ----------------------------------------------------------- */
SELECT person_id, phenotype_group, index_date
FROM cases
UNION ALL
SELECT person_id, phenotype_group, index_date
FROM controls
;

/* -----------------------------------------------------------
   9.  OPTIONAL QA: list any source codes that failed to resolve
   -----------------------------------------------------------
   SELECT * FROM unresolved_codes;
   ----------------------------------------------------------- */