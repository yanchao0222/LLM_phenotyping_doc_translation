/* =======================================================================
   PHENOTYPE  :  Major Adverse Cardiac Events (MACE) While on Statins
   CDM        :  OMOP v5+ (PostgreSQL‑compatible SQL)
   VERSION    :  2025‑07‑28
   -----------------------------------------------------------------------
   COHORT OVERVIEW
   -----------------------------------------------------------------------
   • AMI_ON_STATIN          → Statin ≥180 d  +  ≥2 ICD‑9 410./411. in 5 d  +  lab confirmation
   • FIRST_AMI_ON_STATIN    → AMI_ON_STATIN  AND  NO prior AMI / Revasc / MACE‑NLP
   • REVASC_ON_STATIN       → Statin ≥180 d  +  qualifying revascularization procedure
   • FIRST_REVASC_ON_STATIN → REVASC_ON_STATIN  AND  NO prior AMI / Revasc / MACE‑NLP
   • MACE_ON_STATIN         → AMI_ON_STATIN  OR  REVASC_ON_STATIN
   • FIRST_MACE_ON_STATIN   → FIRST_AMI_ON_STATIN  OR  FIRST_REVASC_ON_STATIN
   • STATIN_CONTROL         → Statin ≥180 d  AND  NO AMI / Revasc / MACE‑NLP ever
   ====================================================================== */

WITH
/* -----------------------------------------------------------------------
   0.  CONCEPT SETS
   -------------------------------------------------------------------- */
ami_case_dx AS (          -- ICD‑9‑CM 410.*, 411.*  (case codes)
    SELECT concept_id
    FROM   concept
    WHERE  vocabulary_id = 'ICD9CM'
      AND  (concept_code LIKE '410%' OR concept_code LIKE '411%')
),
ami_excl_dx AS (          -- ICD‑9‑CM 410.*, 411.*, 412.*  (exclusion history)
    SELECT concept_id
    FROM   concept
    WHERE  vocabulary_id = 'ICD9CM'
      AND  (concept_code LIKE '410%' OR concept_code LIKE '411%' OR concept_code LIKE '412%')
),
revasc_proc AS (          -- CPT4 & HCPCS coronary revascularization
    SELECT concept_id
    FROM   concept
    WHERE (vocabulary_id = 'CPT4'  AND (
             (concept_code BETWEEN '33510' AND '33523') OR
             (concept_code BETWEEN '33533' AND '33536') OR
             concept_code IN ('92980','92981','92982','92984','92995','92996')
           ))
       OR (vocabulary_id = 'HCPCS' AND concept_code IN ('C1874','C1875','C1876','C1877'))
),
statin_drugs AS (         -- RxNorm ingredients containing any statin name
    SELECT concept_id
    FROM   concept
    WHERE  vocabulary_id = 'RxNorm'
      AND  LOWER(concept_name) SIMILAR TO
           '%(simvastatin|fluvastatin|atorvastatin|pravastatin|lovastatin|cerivastatin|rosuvastatin)%'
),
troponin_i_labs AS (
    SELECT concept_id
    FROM   concept
    WHERE  vocabulary_id = 'LOINC'
      AND  LOWER(concept_name) LIKE '%troponin i%'
),
troponin_t_labs AS (
    SELECT concept_id
    FROM   concept
    WHERE  vocabulary_id = 'LOINC'
      AND  LOWER(concept_name) LIKE '%troponin t%'
),
ckmb_ratio_labs AS (
    SELECT concept_id
    FROM   concept
    WHERE  vocabulary_id = 'LOINC'
      AND  LOWER(concept_name) LIKE '%ck-mb ratio%'
),
ckmb_labs AS (            -- exclude CK‑MB ratio to avoid double‑count
    SELECT concept_id
    FROM   concept
    WHERE  vocabulary_id = 'LOINC'
      AND  LOWER(concept_name) LIKE '%ck-mb%'
      AND  LOWER(concept_name) NOT LIKE '%ratio%'
),

/* -----------------------------------------------------------------------
   1.  CONTINUOUS STATIN ERA ≥180 D BEFORE POTENTIAL INDEX
   -------------------------------------------------------------------- */
statin_era AS (
    SELECT person_id,
           drug_era_start_date,
           drug_era_end_date
    FROM   drug_era
    WHERE  drug_concept_id IN (SELECT concept_id FROM statin_drugs)
),

/* -----------------------------------------------------------------------
   2.  CANDIDATE ACUTE MYOCARDIAL INFARCTION EVENTS
   -------------------------------------------------------------------- */
candidate_ami AS (
    SELECT  idx.person_id,
            idx.condition_start_date AS index_date
    FROM    condition_occurrence idx
            JOIN ami_case_dx d ON idx.condition_concept_id = d.concept_id
    WHERE  (       /* ≥2 AMI codes within 5 days */
            SELECT COUNT(*)
            FROM   condition_occurrence c2
                   JOIN ami_case_dx d2 ON c2.condition_concept_id = d2.concept_id
            WHERE  c2.person_id          = idx.person_id
              AND  c2.condition_start_date
                      BETWEEN idx.condition_start_date
                          AND idx.condition_start_date + INTERVAL '5 day'
           ) >= 2
      AND (         /* LAB CONFIRMATION (ANY OF THE 3 LOGIC BLOCKS) */
            /* Troponin I ≥0.10 ng/mL */
            EXISTS (
                SELECT 1
                FROM   measurement m
                WHERE  m.person_id                = idx.person_id
                  AND  m.measurement_concept_id  IN (SELECT concept_id FROM troponin_i_labs)
                  AND  m.measurement_date
                         BETWEEN idx.condition_start_date
                             AND idx.condition_start_date + INTERVAL '5 day'
                  AND  m.value_as_number          >= 0.10
            )
            OR
            /* Troponin T ≥0.10 ng/mL */
            EXISTS (
                SELECT 1
                FROM   measurement m
                WHERE  m.person_id                = idx.person_id
                  AND  m.measurement_concept_id  IN (SELECT concept_id FROM troponin_t_labs)
                  AND  m.measurement_date
                         BETWEEN idx.condition_start_date
                             AND idx.condition_start_date + INTERVAL '5 day'
                  AND  m.value_as_number          >= 0.10
            )
            OR
            /* CK‑MB ratio ≥3.0  AND  CK‑MB ≥10 ng/mL (both within 5 d) */
            (
              EXISTS (
                  SELECT 1
                  FROM   measurement m
                  WHERE  m.person_id                = idx.person_id
                    AND  m.measurement_concept_id  IN (SELECT concept_id FROM ckmb_ratio_labs)
                    AND  m.measurement_date
                           BETWEEN idx.condition_start_date
                               AND idx.condition_start_date + INTERVAL '5 day'
                    AND  m.value_as_number          >= 3.0
              )
              AND
              EXISTS (
                  SELECT 1
                  FROM   measurement m
                  WHERE  m.person_id                = idx.person_id
                    AND  m.measurement_concept_id  IN (SELECT concept_id FROM ckmb_labs)
                    AND  m.measurement_date
                           BETWEEN idx.condition_start_date
                               AND idx.condition_start_date + INTERVAL '5 day'
                    AND  m.value_as_number          >= 10.0
              )
            )
          )
      AND EXISTS (  /* Statin exposure continuously covering previous 180 d */
            SELECT 1
            FROM   statin_era se
            WHERE  se.person_id            = idx.person_id
              AND  se.drug_era_start_date <= idx.condition_start_date - INTERVAL '180 day'
              AND  se.drug_era_end_date   >= idx.condition_start_date - INTERVAL '1 day'
          )
),

/* -----------------------------------------------------------------------
   3.  CANDIDATE CORONARY REVASCULARIZATION EVENTS
   -------------------------------------------------------------------- */
candidate_revasc AS (
    SELECT  p.person_id,
            p.procedure_date AS index_date
    FROM    procedure_occurrence p
            JOIN revasc_proc r ON p.procedure_concept_id = r.concept_id
    WHERE EXISTS (  /* Statin exposure continuously covering previous 180 d */
            SELECT 1
            FROM   statin_era se
            WHERE  se.person_id            = p.person_id
              AND  se.drug_era_start_date <= p.procedure_date - INTERVAL '180 day'
              AND  se.drug_era_end_date   >= p.procedure_date - INTERVAL '1 day'
          )
),

/* -----------------------------------------------------------------------
   4.  PRIOR‑EVENT EXCLUSIONS (HISTORY BEFORE INDEX)
   -------------------------------------------------------------------- */
prior_mace_dx AS (
    SELECT DISTINCT person_id
    FROM   condition_occurrence
           JOIN ami_excl_dx e ON condition_concept_id = e.concept_id
),
prior_revasc AS (
    SELECT DISTINCT person_id
    FROM   procedure_occurrence
           JOIN revasc_proc r ON procedure_concept_id = r.concept_id
),
prior_mace_nlp AS (       -- text‑derived evidence stored as observation rows
    SELECT DISTINCT person_id
    FROM   observation
    WHERE  LOWER(observation_source_value) IN (
             'ami','mi','acute myocardial infarction','myocardial infarction',
             'cabg','stent','bms','des','coronary artery bypass','cypher','taxus'
           )
),

/* -----------------------------------------------------------------------
   5.  COHORT BUILDING
   -------------------------------------------------------------------- */
ami_on_statin AS (
    SELECT * FROM candidate_ami
),
first_ami_on_statin AS (
    SELECT a.*
    FROM   candidate_ami a
    WHERE NOT EXISTS (SELECT 1 FROM prior_mace_dx  d WHERE d.person_id = a.person_id)
      AND NOT EXISTS (SELECT 1 FROM prior_revasc   r WHERE r.person_id = a.person_id)
      AND NOT EXISTS (SELECT 1 FROM prior_mace_nlp n WHERE n.person_id = a.person_id)
),
revasc_on_statin AS (
    SELECT * FROM candidate_revasc
),
first_revasc_on_statin AS (
    SELECT r.*
    FROM   candidate_revasc r
    WHERE NOT EXISTS (SELECT 1 FROM prior_mace_dx  d WHERE d.person_id = r.person_id)
      AND NOT EXISTS (SELECT 1 FROM prior_revasc   pr WHERE pr.person_id = r.person_id)
      AND NOT EXISTS (SELECT 1 FROM prior_mace_nlp n WHERE n.person_id = r.person_id)
),
mace_on_statin AS (
    SELECT * FROM ami_on_statin
    UNION ALL
    SELECT * FROM revasc_on_statin
),
first_mace_on_statin AS (
    SELECT * FROM first_ami_on_statin
    UNION ALL
    SELECT * FROM first_revasc_on_statin
),
statin_controls AS (
    SELECT DISTINCT se.person_id
    FROM   statin_era se
    WHERE  NOT EXISTS (SELECT 1 FROM prior_mace_dx  d WHERE d.person_id = se.person_id)
      AND  NOT EXISTS (SELECT 1 FROM prior_revasc   r WHERE r.person_id = se.person_id)
      AND  NOT EXISTS (SELECT 1 FROM prior_mace_nlp n WHERE n.person_id = se.person_id)
)

/* -----------------------------------------------------------------------
   6.  FINAL OUTPUT (3 COHORT ROWSETS)
   -------------------------------------------------------------------- */
SELECT 'MACE_CASE'       AS cohort_type,
       person_id,
       index_date
FROM   mace_on_statin

UNION ALL

SELECT 'FIRST_MACE_CASE' AS cohort_type,
       person_id,
       index_date
FROM   first_mace_on_statin

UNION ALL

SELECT 'STATIN_CONTROL'  AS cohort_type,
       person_id,
       NULL              AS index_date
FROM   statin_controls
;
