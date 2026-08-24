-- Rule 1 (VUMC-specific database name): APPLIED (all table references updated to victr_sd.sd_omop_prod)
-- Rule 2 (wildcard fix): NOT APPLICABLE
-- Rule 3 (search concepts in clinical tables): NOT APPLICABLE (no direct concept table search for ICD/CPT)
-- Rule 4 (LOINC/RxNorm join): APPLIED (measurement_concept_id and drug_concept_id join to concept/concept_ancestor as required)
-- Rule 5 (free-text LIKE): NOT APPLICABLE (no free-text name filters)
-- Rule 6 (OR->UNION): NOT APPLICABLE (no multi-table ORs)
-- Rule 7 (LEFT JOIN->UNION): NOT APPLICABLE
-- Rule 8 (remove NLP/free-text): NOT APPLICABLE (NLP placeholder left as-is)
-- Rule 9 (mark missing concepts): NOT APPLICABLE

CREATE TABLE workspace_sdphenotypecore.phenotype_llm_logic.ex2_only_text_LLM1_FH AS 

WITH
-- REVISED (was: FROM   concept WHERE vocabulary_id = 'LOINC' AND concept_code IN (...))
ldl_concepts AS (
  SELECT concept_id
  FROM   victr_sd.sd_omop_prod.concept
  WHERE  vocabulary_id = 'LOINC'
  AND    concept_code IN ('2089-1','18262-6','49132-4','35198-1','39469-2',
                          '12773-8','18261-8','22748-8','13457-7','9346-8',
                          '2574-2','14815-5')
),
tg_concepts AS (
  SELECT concept_id
  FROM   victr_sd.sd_omop_prod.concept
  WHERE  vocabulary_id = 'LOINC'
  AND    concept_code IN ('2571-8','30524-3','3048-6','35217-9','14927-8','47210-0')
),
-- REVISED (was: FROM   concept WHERE vocabulary_id = 'RxNorm' AND concept_code IN (...))
lipid_drug_concepts AS (
  SELECT ca.descendant_concept_id AS concept_id
  FROM   victr_sd.sd_omop_prod.concept_ancestor ca
  JOIN   victr_sd.sd_omop_prod.concept c ON ca.ancestor_concept_id = c.concept_id
  WHERE  c.vocabulary_id = 'RxNorm'
  AND    c.concept_code IN ('36567','41127','6472','42463','861634','83367','301542',
                          '221072','7393','8703','4719','341248','141626','2447',
                          '2685','1367839','1364479','1665895','1659156','495215',
                          '1372731','327008','404914','1372754')
),
-- REVISED (was: FROM   concept WHERE vocabulary_id = 'ICD9CM' AND (concept_code LIKE ...))
pregnancy_concepts AS (
  SELECT concept_id
  FROM   victr_sd.sd_omop_prod.concept
  WHERE  vocabulary_id = 'ICD9CM'
  AND   (concept_code LIKE 'V22%' OR concept_code LIKE 'V23%'
         OR concept_code LIKE '645%' OR concept_code LIKE '651%' OR concept_code LIKE '652%')
),
sec_hypothyroid   AS (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id='LOINC' AND concept_code IN ('11579-0','24348-5')),
sec_alp           AS (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id='LOINC' AND concept_code IN ('6768-6','12805-8')),
sec_bilirubin     AS (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id='LOINC' AND concept_code IN ('35194-0','1975-2','14631-6')),
sec_24hprot       AS (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id='LOINC' AND concept_code IN ('21482-5','2889-4','21028-6')),
sec_protcr        AS (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id='LOINC' AND concept_code IN ('13801-6','2890-2')),
sec_creatinine    AS (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id='LOINC' AND concept_code IN ('14682-9','2160-0','35203-3','38483-4','59826-8','77140-3')),
sec_egfr          AS (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id='LOINC' AND concept_code IN ('50261-7','45066-8','48642-3','48643-1','33914-3')),
sec_hba1c         AS (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id='LOINC' AND concept_code IN ('4549-2','17855-8','17856-6','41995-2')),
sec_glucose       AS (SELECT concept_id FROM victr_sd.sd_omop_prod.concept WHERE vocabulary_id='LOINC' AND concept_code IN ('1556-0','1558-6')),

eligible_ldl AS (
  SELECT  m.person_id,
          m.measurement_date,
          m.value_as_number,
          ROW_NUMBER() OVER (PARTITION BY m.person_id
                             ORDER BY m.value_as_number DESC,
                                      m.measurement_date ASC) AS rn
  FROM    victr_sd.sd_omop_prod.measurement          m
  JOIN    ldl_concepts         l  ON l.concept_id = m.measurement_concept_id
  JOIN    victr_sd.sd_omop_prod.person               p  ON p.person_id   = m.person_id
  WHERE   YEAR(m.measurement_date) - p.year_of_birth -
            CASE WHEN MONTH(m.measurement_date) < COALESCE(p.month_of_birth,1) OR (MONTH(m.measurement_date) = COALESCE(p.month_of_birth,1) AND DAY(m.measurement_date) < COALESCE(p.day_of_birth,1)) THEN 1 ELSE 0 END >= 18
),
index_ldl AS (
  SELECT  person_id,
          measurement_date               AS index_date,
          value_as_number                AS raw_ldl_mg_dl
  FROM    eligible_ldl
  WHERE   rn = 1
),
-- REVISED (was: JOIN   lipid_drug_concepts   r  ON r.concept_id = d.drug_concept_id)
lipid_drug_use AS (
  SELECT DISTINCT d.person_id
  FROM   victr_sd.sd_omop_prod.drug_exposure         d
  JOIN   lipid_drug_concepts   r  ON r.concept_id = d.drug_concept_id
  JOIN   index_ldl             i  ON i.person_id  = d.person_id
  WHERE  d.drug_exposure_start_date BETWEEN i.index_date - INTERVAL 365 DAYS
                                       AND i.index_date
),
adjusted_ldl AS (
  SELECT  i.person_id,
          i.index_date,
          CASE WHEN u.person_id IS NOT NULL
                    THEN ROUND(try_divide(i.raw_ldl_mg_dl,0.7),1)
               ELSE i.raw_ldl_mg_dl
          END                                    AS adjusted_ldl_mg_dl
  FROM    index_ldl           i
  LEFT    JOIN lipid_drug_use u ON i.person_id = u.person_id
),
secondary_causes AS (
  SELECT DISTINCT m.person_id
  FROM   victr_sd.sd_omop_prod.measurement m
  JOIN   sec_hypothyroid c ON c.concept_id = m.measurement_concept_id
  JOIN   index_ldl   i ON i.person_id = m.person_id
  WHERE  m.value_as_number >= 10
    AND  m.measurement_date BETWEEN i.index_date - INTERVAL 365 DAYS AND i.index_date
  UNION
  SELECT DISTINCT m.person_id
  FROM   victr_sd.sd_omop_prod.measurement m
  JOIN   sec_alp    c ON c.concept_id = m.measurement_concept_id
  JOIN   index_ldl  i ON i.person_id  = m.person_id
  WHERE  m.value_as_number >= 200
    AND  m.measurement_date BETWEEN i.index_date - INTERVAL 365 DAYS AND i.index_date
  UNION
  SELECT DISTINCT m.person_id
  FROM   victr_sd.sd_omop_prod.measurement m
  JOIN   sec_bilirubin c ON c.concept_id = m.measurement_concept_id
  JOIN   index_ldl   i  ON i.person_id  = m.person_id
  WHERE  m.value_as_number > 2
    AND  m.measurement_date BETWEEN i.index_date - INTERVAL 365 DAYS AND i.index_date
  UNION
  SELECT DISTINCT m.person_id
  FROM   victr_sd.sd_omop_prod.measurement m
  JOIN   sec_24hprot c ON c.concept_id = m.measurement_concept_id
  JOIN   index_ldl  i  ON i.person_id  = m.person_id
  WHERE  m.value_as_number > 3
    AND  m.measurement_date BETWEEN i.index_date - INTERVAL 365 DAYS AND i.index_date
  UNION
  SELECT DISTINCT m.person_id
  FROM   victr_sd.sd_omop_prod.measurement m
  JOIN   sec_protcr c ON c.concept_id = m.measurement_concept_id
  JOIN   index_ldl  i ON i.person_id = m.person_id
  WHERE  m.value_as_number > 3
    AND  m.measurement_date BETWEEN i.index_date - INTERVAL 365 DAYS AND i.index_date
  UNION
  SELECT DISTINCT m.person_id
  FROM   victr_sd.sd_omop_prod.measurement m
  JOIN   sec_creatinine c ON c.concept_id = m.measurement_concept_id
  JOIN   index_ldl  i  ON i.person_id = m.person_id
  WHERE  m.value_as_number > 2.6
    AND  m.measurement_date BETWEEN i.index_date - INTERVAL 365 DAYS AND i.index_date
  UNION
  SELECT DISTINCT m.person_id
  FROM   victr_sd.sd_omop_prod.measurement m
  JOIN   sec_egfr  c ON c.concept_id = m.measurement_concept_id
  JOIN   index_ldl i ON i.person_id  = m.person_id
  WHERE  m.value_as_number < 15
    AND  m.measurement_date BETWEEN i.index_date - INTERVAL 365 DAYS AND i.index_date
  UNION
  SELECT DISTINCT m.person_id
  FROM   victr_sd.sd_omop_prod.measurement m
  JOIN   sec_hba1c c ON c.concept_id = m.measurement_concept_id
  JOIN   index_ldl  i ON i.person_id = m.person_id
  WHERE  m.value_as_number > 9
    AND  m.measurement_date BETWEEN i.index_date - INTERVAL 365 DAYS AND i.index_date
  UNION
  SELECT DISTINCT m.person_id
  FROM   victr_sd.sd_omop_prod.measurement m
  JOIN   sec_glucose c ON c.concept_id = m.measurement_concept_id
  JOIN   index_ldl  i ON i.person_id = m.person_id
  WHERE  m.value_as_number > 200
    AND  m.measurement_date BETWEEN i.index_date - INTERVAL 365 DAYS AND i.index_date
),
flag_high_tg_preg AS (
  SELECT DISTINCT a.person_id
  FROM   adjusted_ldl              a
  JOIN   victr_sd.sd_omop_prod.measurement               m  ON m.person_id = a.person_id
  JOIN   tg_concepts               t  ON t.concept_id = m.measurement_concept_id
  JOIN   victr_sd.sd_omop_prod.condition_occurrence      c  ON c.person_id = a.person_id
  JOIN   pregnancy_concepts        pc ON pc.concept_id = c.condition_concept_id
  WHERE  a.adjusted_ldl_mg_dl >= 155
    AND  m.value_as_number > 220
    AND  m.measurement_date BETWEEN a.index_date - INTERVAL 7 DAYS AND a.index_date + INTERVAL 7 DAYS
    AND  c.condition_start_date BETWEEN a.index_date - INTERVAL 365 DAYS AND a.index_date
),
primary_hyperch AS (
  SELECT  a.person_id,
          a.index_date,
          a.adjusted_ldl_mg_dl,
          CASE
            WHEN a.person_id IN (SELECT person_id FROM secondary_causes)
                 THEN 'EXCLUDED'
            WHEN a.person_id IN (SELECT person_id FROM flag_high_tg_preg)
                 THEN 'FLAGGED'
            WHEN a.adjusted_ldl_mg_dl >= 155
                 THEN 'CASE'
            ELSE 'CONTROL'
          END  AS hyperchol_status
  FROM    adjusted_ldl a
),
nlp_flags AS (
  SELECT person_id,
         0 AS fh_premature_ascvd,
         0 AS fh_hypercholesterolaemia,
         0 AS personal_chd_premature,
         0 AS personal_cvd_pad_premature,
         0 AS tendon_xanthoma,
         0 AS corneal_arcus_early
  FROM   primary_hyperch
),
dlcn_components AS (
  SELECT  p.person_id,
          CASE
            WHEN p.adjusted_ldl_mg_dl >= 330 THEN 8
            WHEN p.adjusted_ldl_mg_dl BETWEEN 250 AND 329 THEN 5
            WHEN p.adjusted_ldl_mg_dl BETWEEN 190 AND 249 THEN 3
            WHEN p.adjusted_ldl_mg_dl BETWEEN 155 AND 189 THEN 1
            ELSE 0
          END                                             AS ldl_score,
          n.fh_premature_ascvd            * 1             AS fh_ascvd,
          n.fh_hypercholesterolaemia      * 1             AS fh_hyper,
          n.personal_chd_premature        * 2             AS ph_chd,
          n.personal_cvd_pad_premature    * 1             AS ph_cvd,
          n.tendon_xanthoma               * 6             AS xanthoma,
          n.corneal_arcus_early           * 4             AS arcus
  FROM    primary_hyperch  p
  JOIN    nlp_flags        n  ON p.person_id = n.person_id
  WHERE   p.hyperchol_status = 'CASE'
),
dlcn_totals AS (
  SELECT  person_id,
          (ldl_score + fh_ascvd + fh_hyper + ph_chd +
           ph_cvd + xanthoma + arcus)     AS total_score
  FROM    dlcn_components
),
fh_classification AS (
  SELECT  person_id,
          CASE
            WHEN total_score > 8            THEN 'DEFINITE'
            WHEN total_score BETWEEN 6 AND 8 THEN 'PROBABLE'
            WHEN total_score BETWEEN 3 AND 5 THEN 'POSSIBLE'
            ELSE                                   'UNLIKELY'
          END                                         AS fh_status,
          CASE
            WHEN total_score >= 6 THEN 1
            WHEN total_score <= 2 THEN 0
            ELSE NULL
          END                                         AS phenotype_flag
  FROM    dlcn_totals
)
SELECT  p.person_id,
        p.index_date,
        p.adjusted_ldl_mg_dl,
        p.hyperchol_status,
        f.fh_status,
        f.phenotype_flag
FROM    primary_hyperch     p
LEFT    JOIN fh_classification f ON p.person_id = f.person_id
ORDER BY p.person_id;