/*======================================================================
  PHENOTYPE:  MAJOR ADVERSE CARDIAC EVENTS (MACE) WHILE ON STATINS
  TARGET CDM: OMOP v5.3 (or later)
  SCOPE   : Builds four case cohorts (AMI, AMI‑first, REVASC, REVASC‑first)
            plus a control cohort, WITHOUT creating any permanent tables.
            All logic is grounded in the validated phenotype algorithm.
======================================================================*/

WITH
/*----------------------------------------------------------------------
  A. CONCEPT SETS  – CODES ONLY
----------------------------------------------------------------------*/
statin_ing AS (  -- RxNorm ingredient_concept_id for oral statins
  SELECT unnest ( ARRAY [
      1539400,   -- Simvastatin
      1502766,   -- Fluvastatin
      1539476,   -- Atorvastatin
      1529331,   -- Pravastatin
      1503297,   -- Lovastatin
      1511002,   -- Cerivastatin
      1580747    -- Rosuvastatin
  ]) AS concept_id
),

ami_icd9 AS (    -- ICD‑9‑CM 410.*  & 411.*
  SELECT concept_id
  FROM   concept
  WHERE  vocabulary_id = 'ICD9CM'
    AND  ( concept_code LIKE '410%'  OR  concept_code LIKE '411%' )
),

old_mi_icd9 AS ( -- ICD‑9‑CM 412  (old MI)
  SELECT concept_id
  FROM   concept
  WHERE  vocabulary_id = 'ICD9CM'
    AND  concept_code = '412'
),

revasc_cpt AS (  -- CABG / PTCA / stent CPT‑4 + HCPCS
  SELECT concept_id
  FROM   concept
  WHERE  vocabulary_id = 'CPT4'
    AND  concept_code IN (
        '33510','33511','33512','33513','33514','33515','33516',
        '33517','33518','33519','33520','33521','33522','33523',
        '33533','33534','33535','33536',
        '92980','92981','92982','92984','92995','92996',
        'C1874','C1875','C1876','C1877'
    )
),

/* Measurement concept sets are derived dynamically so the final logic
   uses codes (measurement_concept_id) only. */
troponin_i_loinc AS (
  SELECT concept_id
  FROM   concept
  WHERE  vocabulary_id = 'LOINC'
    AND  LOWER(concept_name) LIKE '%troponin i%'
),
troponin_t_loinc AS (
  SELECT concept_id
  FROM   concept
  WHERE  vocabulary_id = 'LOINC'
    AND  LOWER(concept_name) LIKE '%troponin t%'
),
ckmb_ratio_loinc AS (
  SELECT concept_id
  FROM   concept
  WHERE  vocabulary_id = 'LOINC'
    AND  LOWER(concept_name) LIKE '%ck-mb%' AND LOWER(concept_name) LIKE '%ratio%'
),
ckmb_loinc AS (
  SELECT concept_id
  FROM   concept
  WHERE  vocabulary_id = 'LOINC'
    AND  LOWER(concept_name) LIKE '%ck-mb%' AND LOWER(concept_name) NOT LIKE '%ratio%'
),

/*----------------------------------------------------------------------
  B. STATIN EXPOSURE – AT LEAST ONE FILL  (ever)
----------------------------------------------------------------------*/
statin_user AS (
  SELECT DISTINCT de.person_id
  FROM   drug_exposure de
  WHERE  de.drug_concept_id IN (SELECT concept_id FROM statin_ing)
),

/*----------------------------------------------------------------------
  C. ACUTE MI EVENT LOGIC
----------------------------------------------------------------------*/
-- C‑1  Individual diagnosis rows
ami_dx AS (
  SELECT person_id,
         condition_start_date AS dx_date
  FROM   condition_occurrence
  WHERE  condition_concept_id IN (SELECT concept_id FROM ami_icd9)
),

-- C‑2  Diagnosis clusters (≥ 2 codes in ≤5 days)
ami_cluster AS (
  SELECT a1.person_id,
         a1.dx_date                    AS cluster_start,
         a1.dx_date + INTERVAL '4 day' AS cluster_end
  FROM   ami_dx a1
  JOIN   ami_dx a2
         ON  a1.person_id = a2.person_id
        AND a2.dx_date  BETWEEN a1.dx_date AND a1.dx_date + INTERVAL '4 day'
  GROUP  BY a1.person_id, a1.dx_date
  HAVING COUNT(*) >= 2
),

-- C‑3  Laboratory confirmation in same 5‑day window
ami_lab AS (
  SELECT DISTINCT m.person_id, m.measurement_date
  FROM   measurement m
  WHERE (
          /* Troponin I ≥ 0.10 ng/mL */
          m.measurement_concept_id IN (SELECT concept_id FROM troponin_i_loinc)
          AND m.value_as_number >= 0.10
        )
     OR (
          /* Troponin T ≥ 0.10 ng/mL */
          m.measurement_concept_id IN (SELECT concept_id FROM troponin_t_loinc)
          AND m.value_as_number >= 0.10
        )
     OR (
          /* CK‑MB ratio ≥ 3  AND  same‑day CK‑MB ≥ 10 ng/mL */
          m.measurement_concept_id IN (SELECT concept_id FROM ckmb_ratio_loinc)
          AND m.value_as_number >= 3.0
          AND EXISTS (
                SELECT 1
                FROM   measurement m2
                WHERE  m2.person_id            = m.person_id
                  AND  m2.measurement_date     = m.measurement_date
                  AND  m2.measurement_concept_id IN (SELECT concept_id FROM ckmb_loinc)
                  AND  m2.value_as_number      >= 10.0
              )
        )
),

-- C‑4  Confirmed AMI index events (Dx cluster AND Lab)
ami_event AS (
  SELECT c.person_id,
         c.cluster_start AS index_date
  FROM   ami_cluster c
  JOIN   ami_lab     l
         ON  l.person_id = c.person_id
        AND l.measurement_date BETWEEN c.cluster_start
                                   AND c.cluster_start + INTERVAL '4 day'
),

/*----------------------------------------------------------------------
  D. REVASCULARIZATION EVENTS
----------------------------------------------------------------------*/
revasc_event AS (
  SELECT person_id,
         procedure_date AS index_date
  FROM   procedure_occurrence
  WHERE  procedure_concept_id IN (SELECT concept_id FROM revasc_cpt)
),

/*----------------------------------------------------------------------
  E. HISTORICAL‑EVENT EXCLUSION (any prior MACE)
----------------------------------------------------------------------*/
hist_event AS (
  SELECT DISTINCT person_id
  FROM (
        /* Prior 410.*, 411.*, or 412 diagnosis */
        SELECT person_id
        FROM   condition_occurrence
        WHERE  condition_concept_id IN (
                 SELECT concept_id FROM ami_icd9
                 UNION ALL
                 SELECT concept_id FROM old_mi_icd9
               )

        UNION

        /* Prior revascularization procedure */
        SELECT person_id
        FROM   procedure_occurrence
        WHERE  procedure_concept_id IN (SELECT concept_id FROM revasc_cpt)

        UNION

        /* Problem‑list terms (NLP) suggesting past MACE */
        SELECT person_id
        FROM   note_nlp nn
        WHERE  LOWER(nn.lexical_variant) ~
              '\\y(ami|mi|acute myocardial infarction|myocardial infarction|cabg|coronary artery bypass|cypher|taxus|bms|des|stent)\\y'
  ) hx
),

/*----------------------------------------------------------------------
  F. COHORT ASSEMBLY
----------------------------------------------------------------------*/
-- F‑1  AMI on Statins  (case)
ami_on_statin AS (
  SELECT e.person_id, e.index_date
  FROM   ami_event e
  WHERE  EXISTS (  -- statin fill ≥ 180 days before index_date
          SELECT 1
          FROM   drug_exposure de
          WHERE  de.person_id              = e.person_id
            AND  de.drug_concept_id        IN (SELECT concept_id FROM statin_ing)
            AND  de.drug_exposure_start_date <= e.index_date - INTERVAL '180 day'
        )
),

-- F‑2  First AMI on Statins  (case‑first, no prior MACE)
first_ami_on_statin AS (
  SELECT *
  FROM   ami_on_statin
  WHERE  person_id NOT IN (SELECT person_id FROM hist_event)
),

-- F‑3  Revascularization on Statins  (case)
revasc_on_statin AS (
  SELECT p.person_id, p.index_date
  FROM   revasc_event p
  WHERE  EXISTS (
          SELECT 1
          FROM   drug_exposure de
          WHERE  de.person_id              = p.person_id
            AND  de.drug_concept_id        IN (SELECT concept_id FROM statin_ing)
            AND  de.drug_exposure_start_date <= p.index_date - INTERVAL '180 day'
        )
),

-- F‑4  First Revascularization on Statins  (case‑first)
first_revasc_on_statin AS (
  SELECT *
  FROM   revasc_on_statin
  WHERE  person_id NOT IN (SELECT person_id FROM hist_event)
),

-- F‑5  Control cohort  (statin users with NO MACE ever)
controls AS (
  SELECT DISTINCT su.person_id
  FROM   statin_user su
  WHERE  su.person_id NOT IN (
           SELECT person_id FROM ami_event
           UNION
           SELECT person_id FROM revasc_event
           UNION
           SELECT person_id FROM hist_event
         )
)

/*----------------------------------------------------------------------
  G. RESULT SETS  (UNION for convenience; run separately if preferred)
----------------------------------------------------------------------*/
SELECT 'AMI_case'          AS cohort, person_id, index_date FROM ami_on_statin
UNION ALL
SELECT 'AMI_first_case'    AS cohort, person_id, index_date FROM first_ami_on_statin
UNION ALL
SELECT 'Revasc_case'       AS cohort, person_id, index_date FROM revasc_on_statin
UNION ALL
SELECT 'Revasc_first_case' AS cohort, person_id, index_date FROM first_revasc_on_statin
UNION ALL
SELECT 'Control'           AS cohort, person_id, NULL::date AS index_date FROM controls;
