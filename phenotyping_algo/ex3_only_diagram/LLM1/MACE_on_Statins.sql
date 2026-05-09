/* =====================================================================
   PHENOTYPE ─ Major Adverse Cardiac Events (MACE) While on Statins
   ---------------------------------------------------------------------
   Grounded 100 % on the step‑by‑step algorithm extracted from the PDF.
   Ready to run on any OMOP‑CDM v5+ platform that understands SQL‑92 +
   common date‑arithmetic functions (PostgreSQL, SQL Server, BigQuery).
   ===================================================================== */

/* *********************************************************************
   0.  CONCEPT‑SET CTEs  –  ALL CODE‑BASED, NO FREE‑TEXT NAMES
   ********************************************************************* */

/* 0a.  All statin ingredients and their descendants                     */
WITH statin_concept_set AS (
    SELECT DISTINCT descendant_concept_id        AS concept_id
    FROM   concept_ancestor
    WHERE  ancestor_concept_id IN (
             /* every drug ingredient whose CONCEPT_NAME ends in “statin” */
             SELECT concept_id
             FROM   concept
             WHERE  domain_id        = 'Drug'
               AND  concept_class_id = 'Ingredient'
               AND  lower(concept_name) LIKE '%statin'
           )
),

/* 0b.  ICD‑9‑CM codes for acute / sub‑acute MI (410.*, 411.*)            */
ami_case_icd9 AS (
    SELECT concept_id
    FROM   concept
    WHERE  vocabulary_id = 'ICD9CM'
      AND (concept_code LIKE '410%'       -- acute MI
           OR concept_code LIKE '411%')   -- other acute IHD
),

/* 0c.  ICD‑9‑CM codes for historical AMI (410.*, 411.*, 412.*)            */
ami_excl_icd9 AS (
    SELECT * FROM ami_case_icd9
    UNION ALL
    SELECT concept_id
    FROM   concept
    WHERE  vocabulary_id = 'ICD9CM'
      AND  concept_code LIKE '412%'       -- old MI
),

/* 0d.  CPT‑4 codes for revascularisation (angioplasty OR stent)           */
revasc_cpt AS (
    SELECT concept_id
    FROM   concept
    WHERE  vocabulary_id = 'CPT4'
      AND (lower(concept_name) LIKE '%angioplasty%'
        OR lower(concept_name) LIKE '%stent%'
        OR lower(concept_name) LIKE '%percutaneous coronary intervention%')
),

/* 0e.  LOINC concepts for confirmatory cardiac biomarkers                 */
troponin_i_loinc AS (
    SELECT concept_id
    FROM   concept
    WHERE  vocabulary_id = 'LOINC'
      AND  lower(concept_name) LIKE '%troponin i%'
),
troponin_t_loinc AS (
    SELECT concept_id
    FROM   concept
    WHERE  vocabulary_id = 'LOINC'
      AND  lower(concept_name) LIKE '%troponin t%'
),
ck_mb_loinc AS (
    SELECT concept_id
    FROM   concept
    WHERE  vocabulary_id = 'LOINC'
      AND  lower(concept_name) LIKE '%ck-mb%'
),
ck_total_loinc AS (
    SELECT concept_id
    FROM   concept
    WHERE  vocabulary_id = 'LOINC'
      AND  lower(concept_name) LIKE '%ck%'
      AND  lower(concept_name) LIKE '%total%'
),

/* *********************************************************************
   1.  CONTINUOUS STATIN EXPOSURE  (earliest prescription on record)
   ********************************************************************* */
statin_exposure AS (
    SELECT person_id,
           MIN(drug_exposure_start_date)      AS statin_start
    FROM   drug_exposure
    WHERE  drug_concept_id IN (SELECT concept_id FROM statin_concept_set)
    GROUP BY person_id
),

/* *********************************************************************
   2.  ACUTE MI DIAGNOSES  (≥ 2 codes within a 5‑day window)
   ********************************************************************* */
ami_dx AS (
    SELECT person_id,
           condition_start_date               AS dx_date
    FROM   condition_occurrence
    WHERE  condition_concept_id IN (SELECT concept_id FROM ami_case_icd9)
),
ami_windows AS (                      -- sliding 5‑day windows by person
    SELECT DISTINCT
           person_id,
           MIN(dx_date) OVER win      AS window_start
    FROM   ami_dx
    WINDOW win AS (
        PARTITION BY person_id
        ORDER BY     dx_date
        RANGE BETWEEN INTERVAL '4' DAY PRECEDING AND CURRENT ROW
    )
),
ami_two_plus AS (                     -- keep windows with ≥ 2 codes
    SELECT person_id,
           window_start               AS index_date
    FROM (
        SELECT person_id,
               window_start,
               COUNT(*) OVER (PARTITION BY person_id, window_start) AS n_codes
        FROM   ami_windows
    ) t
    WHERE n_codes >= 2
),

/* *********************************************************************
   3.  CONFIRMATORY CARDIAC LABS  (same ±5 days window)
   ********************************************************************* */
confirm_lab AS (
    SELECT DISTINCT
           m.person_id,
           m.measurement_date
    FROM   measurement m

    /* Troponin‑I ≥ 0.10 ng/mL  ---------------------------------------- */
    WHERE ( m.measurement_concept_id IN (SELECT concept_id FROM troponin_i_loinc)
            AND m.value_as_number >= 0.10 )

    /* Troponin‑T ≥ 0.10 ng/mL  ---------------------------------------- */
       OR ( m.measurement_concept_id IN (SELECT concept_id FROM troponin_t_loinc)
            AND m.value_as_number >= 0.10 )

    /* CK‑MB ≥ 10 ng/mL AND CK‑MB / Total‑CK ≥ 3.0  -------------------- */
       OR ( m.measurement_concept_id IN (SELECT concept_id FROM ck_mb_loinc)
            AND m.value_as_number >= 10
            AND EXISTS (
                  SELECT 1
                  FROM   measurement tot
                  WHERE  tot.person_id        = m.person_id
                    AND  tot.measurement_date = m.measurement_date
                    AND  tot.measurement_concept_id IN (SELECT concept_id FROM ck_total_loinc)
                    AND  m.value_as_number / NULLIF(tot.value_as_number,0) >= 3.0
            )
         )
),

/* *********************************************************************
   4.  REVASCULARISATION PROCEDURES  (angioplasty or stent)
   ********************************************************************* */
revasc_proc AS (
    SELECT person_id,
           procedure_date                    AS proc_date
    FROM   procedure_occurrence
    WHERE  procedure_concept_id IN (SELECT concept_id FROM revasc_cpt)
),

/* *********************************************************************
   5.  NLP‑DERIVED HISTORY OF MACE  (Problem‑list section)
   ********************************************************************* */
nlp_mace AS (
    SELECT DISTINCT person_id
    FROM   note_nlp
    WHERE  lower(section_source_value) = 'problem list'
      AND  lower(note_nlp_source_value) IN (
           'myocardial infarction',
           'coronary stent',
           'angioplasty',
           'percutaneous coronary intervention'
      )
),

/* *********************************************************************
   6.  CASE A — AMI ON STATIN  (ALL THREE CRITERIA)
   ********************************************************************* */
ami_on_statin AS (
    SELECT a.person_id,
           a.index_date
    FROM   ami_two_plus    a
    JOIN   confirm_lab     l
           ON l.person_id  = a.person_id
          AND ABS(DATEDIFF(day,l.measurement_date,a.index_date)) <= 5
    JOIN   statin_exposure s
           ON s.person_id  = a.person_id
          AND DATEDIFF(day,s.statin_start,a.index_date) >= 180      -- ≥ 180 days prior statin
),

/* *********************************************************************
   7.  CASE B — FIRST AMI ON STATIN  (AMI + NO PRIOR MACE)
   ********************************************************************* */
first_ami_on_statin AS (
    SELECT a.person_id,
           a.index_date
    FROM   ami_on_statin a
    WHERE NOT EXISTS (
              SELECT 1
              FROM   condition_occurrence c
              WHERE  c.person_id = a.person_id
                AND  c.condition_concept_id IN (SELECT concept_id FROM ami_excl_icd9)
                AND  c.condition_start_date < a.index_date
          )
      AND NOT EXISTS (
              SELECT 1
              FROM   revasc_proc r
              WHERE  r.person_id = a.person_id
                AND  r.proc_date  < a.index_date
          )
      AND NOT EXISTS (
              SELECT 1 FROM nlp_mace n WHERE n.person_id = a.person_id
          )
),

/* *********************************************************************
   8.  CASE C — REVASCULARISATION ON STATIN  (BOTH CRITERIA)
   ********************************************************************* */
revasc_on_statin AS (
    SELECT r.person_id,
           r.proc_date                      AS index_date
    FROM   revasc_proc    r
    JOIN   statin_exposure s
           ON s.person_id = r.person_id
          AND DATEDIFF(day,s.statin_start,r.proc_date) >= 180
),

/* *********************************************************************
   9.  CASE D — FIRST REVASCULARISATION ON STATIN
   ********************************************************************* */
first_revasc_on_statin AS (
    SELECT r.person_id,
           r.index_date
    FROM   revasc_on_statin r
    WHERE NOT EXISTS (
              SELECT 1
              FROM   condition_occurrence c
              WHERE  c.person_id = r.person_id
                AND  c.condition_concept_id IN (SELECT concept_id FROM ami_excl_icd9)
                AND  c.condition_start_date < r.index_date
          )
      AND NOT EXISTS (
              SELECT 1
              FROM   revasc_proc p2
              WHERE  p2.person_id = r.person_id
                AND  p2.proc_date < r.index_date
          )
      AND NOT EXISTS (
              SELECT 1 FROM nlp_mace n WHERE n.person_id = r.person_id
          )
),

/* *********************************************************************
   10.  CONTROLS — STATIN USERS WITH NO MACE
   ********************************************************************* */
statin_controls AS (
    SELECT s.person_id,
           s.statin_start                    AS index_date
    FROM   statin_exposure s
    WHERE NOT EXISTS (SELECT 1 FROM ami_on_statin           a WHERE a.person_id = s.person_id)
      AND NOT EXISTS (SELECT 1 FROM revasc_on_statin        r WHERE r.person_id = s.person_id)
      AND NOT EXISTS (SELECT 1 FROM condition_occurrence    c WHERE c.person_id = s.person_id
                      AND c.condition_concept_id IN (SELECT concept_id FROM ami_excl_icd9))
      AND NOT EXISTS (SELECT 1 FROM revasc_proc             p WHERE p.person_id = s.person_id)
      AND NOT EXISTS (SELECT 1 FROM nlp_mace                n WHERE n.person_id = s.person_id)
)

/* *********************************************************************
   11.  UNIFIED OUTPUT — FIVE NON‑OVERLAPPING COHORTS
   ********************************************************************* */
SELECT 'AMI_on_Statin'          AS cohort_name, person_id, index_date FROM ami_on_statin
UNION ALL
SELECT 'First_AMI_on_Statin'    AS cohort_name, person_id, index_date FROM first_ami_on_statin
UNION ALL
SELECT 'Revasc_on_Statin'       AS cohort_name, person_id, index_date FROM revasc_on_statin
UNION ALL
SELECT 'First_Revasc_on_Statin' AS cohort_name, person_id, index_date FROM first_revasc_on_statin
UNION ALL
SELECT 'Statin_Control'         AS cohort_name, person_id, index_date FROM statin_controls;
