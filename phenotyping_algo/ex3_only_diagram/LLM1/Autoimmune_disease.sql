/*======================================================================
  Autoimmune Disease Phenotype
  ----------------------------------------------------------------------
  CASE  = ≥1 autoimmune disease diagnosis
       OR ≥1 auto‑antibody laboratory test

  CONTROL = NOT CASE
  ----------------------------------------------------------------------
  This script:
    1.  Builds concept sets directly from the OMOP vocabulary
        via concept‑name matching (diagnoses, labs).
    2.  Collects evidence records from condition_occurrence
        and measurement tables.
    3.  Creates CASE and CONTROL cohorts.
    4.  Outputs one cohort at a time (uncomment as needed).

  No additional thresholds, time windows, or result filters are applied,
  because none are present in the source document.
======================================================================*/

WITH
/*----------------------------------------------------------------------
  1.  Concept sets
----------------------------------------------------------------------*/
autoimmune_condition_concepts AS (          -- 50 autoimmune diseases
  SELECT concept_id
  FROM   concept
  WHERE  standard_concept = 'S'
    AND  domain_id = 'Condition'
    AND  LOWER(concept_name) IN (
           'ankylosing spondylitis',
           'juvenile rheumatoid arthritis',
           'psoriatic arthritis',
           'reactive arthritis',
           'rheumatoid arthritis',
           'behcet''s disease',
           'polymyositis',
           'dermatomyositis',
           'mixed connective tissue disease',
           'relapsing polychondritis',
           'sjogren''s syndrome',
           'systemic lupus erythematosus',
           'systemic sclerosis',
           'addison disease',
           'graves disease',
           'hashimoto thyroiditis',
           'type 1 diabetes mellitus',
           'autoimmune hypophysitis',
           'premature ovarian failure',
           'autoimmune gastritis',
           'celiac disease',
           'crohn''s disease',
           'pernicious anemia',
           'primary biliary cholangitis',
           'primary sclerosing cholangitis',
           'ulcerative colitis',
           'autoimmune hemolytic anemia',
           'evans syndrome',
           'idiopathic thrombocytopenic purpura',
           'paroxysmal nocturnal hemoglobinuria',
           'antiphospholipid syndrome',
           'myasthenia gravis',
           'lambert eaton myasthenic syndrome',
           'autoimmune encephalitis',
           'guillain barre syndrome',
           'multiple sclerosis',
           'neuromyelitis optica',
           'transverse myelitis',
           'chronic inflammatory demyelinating polyradiculoneuropathy',
           'alopecia areata',
           'bullous pemphigoid',
           'dermatitis herpetiformis',
           'pemphigus vulgaris',
           'psoriasis',
           'vitiligo',
           'giant cell arteritis',
           'granulomatosis with polyangiitis',
           'microscopic polyangiitis',
           'polyarteritis nodosa',
           'takayasu arteritis'
         )
),

autoantibody_measurement_concepts AS (      -- 10 antibody groups + sub‑tests
  SELECT concept_id
  FROM   concept
  WHERE  standard_concept = 'S'
    AND  domain_id = 'Measurement'
    AND (
          LOWER(concept_name) LIKE 'antinuclear antibody%'                                -- ANA
       OR LOWER(concept_name) LIKE '%neutrophil cytoplasmic antibody%'                    -- ANCA (c/p)
       OR LOWER(concept_name) LIKE 'double stranded dna antibody%'                        -- dsDNA
       OR LOWER(concept_name) LIKE 'cyclic citrullinated peptide antibody%'               -- CCP
       OR LOWER(concept_name) LIKE 'rheumatoid factor%'                                   -- RF
       OR LOWER(concept_name) LIKE '%beta%2%glycoprotein i antibody%'                     -- β‑2‑GPI
       OR LOWER(concept_name) LIKE 'rna polymerase iii antibody%'                         -- RNAP III
       OR LOWER(concept_name) LIKE 'cardiolipin igg antibody%'                            -- aCL IgG
       OR LOWER(concept_name) LIKE 'cardiolipin igm antibody%'                            -- aCL IgM
       OR LOWER(concept_name) LIKE 'centromere antibody%'                                 -- Centromere
       OR LOWER(concept_name) LIKE 'extractable nuclear antigen jo-1 antibody%'           -- ENA Jo‑1
       OR LOWER(concept_name) LIKE 'extractable nuclear antigen u1rnp antibody%'          -- ENA U1RNP
       OR LOWER(concept_name) LIKE 'extractable nuclear antigen scl-70 antibody%'         -- ENA Scl‑70
       OR LOWER(concept_name) LIKE 'extractable nuclear antigen sm antibody%'             -- ENA Sm
       OR LOWER(concept_name) LIKE 'extractable nuclear antigen ss-a antibody%'           -- ENA SS‑A
       OR LOWER(concept_name) LIKE 'extractable nuclear antigen ss-b antibody%'           -- ENA SS‑B
       )
),

/*----------------------------------------------------------------------
  2.  Evidence records
----------------------------------------------------------------------*/
autoimmune_dx AS (                          -- Diagnosis evidence
  SELECT person_id,
         condition_start_date AS event_date
  FROM   condition_occurrence
  WHERE  condition_concept_id IN (
           SELECT concept_id
           FROM   autoimmune_condition_concepts
         )
),

autoantibody_lab AS (                       -- Laboratory evidence
  SELECT person_id,
         measurement_date AS event_date
  FROM   measurement
  WHERE  measurement_concept_id IN (
           SELECT concept_id
           FROM   autoantibody_measurement_concepts
         )
),

/*----------------------------------------------------------------------
  3.  Case cohort
----------------------------------------------------------------------*/
autoimmune_cases AS (
  SELECT DISTINCT
         person_id,
         MIN(event_date) AS index_date      -- first qualifying event
  FROM (
        SELECT * FROM autoimmune_dx
        UNION ALL
        SELECT * FROM autoantibody_lab
       ) AS evidence
  GROUP BY person_id
),

/*----------------------------------------------------------------------
  4.  Control cohort
----------------------------------------------------------------------*/
autoimmune_controls AS (
  SELECT p.person_id
  FROM   person AS p
  LEFT   JOIN autoimmune_cases AS c
         ON c.person_id = p.person_id
  WHERE  c.person_id IS NULL                -- not a CASE
)

/*----------------------------------------------------------------------
  5.  Output
      -- Uncomment ONE block to materialize the desired cohort
----------------------------------------------------------------------*/

-- =====================  CASES  =====================
SELECT *
FROM   autoimmune_cases
ORDER  BY person_id;

-- ====================  CONTROLS  ====================
-- SELECT *
-- FROM   autoimmune_controls
-- ORDER  BY person_id;
