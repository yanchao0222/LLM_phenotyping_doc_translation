# Databricks notebook source
# MAGIC %md
# MAGIC # Major Adverse Cardiac Events (MACE) While on Statins
# MAGIC
# MAGIC **Phenotype:** Major Adverse Cardiac Events while on statins (https://phekb.org/phenotype/statins-and-mace) 
# MAGIC
# MAGIC **Phenotype authors:** Wei-Qi Wei, Joshua Denny (Vanderbilt University Medical Center)  
# MAGIC
# MAGIC **Implementation document:** https://phekb.org/sites/phenotype/files/AMI_ALGORITHMS_20130926.docx
# MAGIC
# MAGIC **Developer(s):** Srushti Gangireddy, Wu-Chen Su  
# MAGIC
# MAGIC **Date Created:** 2026-07-28  
# MAGIC
# MAGIC **Last Modified:** 2026-08-22
# MAGIC
# MAGIC **Output:** `workspace_sdphenotypecore.mace_on_statin_07_30.statinmace_phenotype`  
# MAGIC
# MAGIC
# MAGIC ## Summary
# MAGIC
# MAGIC Five cohorts are defined by the source document:
# MAGIC
# MAGIC - **AMI on statin**
# MAGIC   - ≥2 AMI ICD-9 codes in a 5-day window
# MAGIC   - A confirming lab in that window
# MAGIC   - First statin ≥180 days earlier
# MAGIC
# MAGIC - **1st AMI on statin**
# MAGIC   - Meets the AMI-on-statin criteria above
# MAGIC   - No prior AMI/IHD/old-MI code
# MAGIC   - No prior revascularization CPT
# MAGIC   - No prior MACE on the problem list
# MAGIC
# MAGIC - **Revascularization on statin**
# MAGIC   - ≥1 revascularization CPT
# MAGIC   - First statin ≥180 days before the procedure
# MAGIC
# MAGIC - **1st Revascularization on statin**
# MAGIC   - Meets the revascularization-on-statin criteria above
# MAGIC   - Plus the same three "assigned previously" screens
# MAGIC
# MAGIC - **Control**
# MAGIC   - Statin prescribed
# MAGIC   - None of the three screens ever fires
# MAGIC
# MAGIC ## Citation
# MAGIC
# MAGIC Wei-Qi Wei. *Statins and MACE*. Vanderbilt University. PheKB; 2013. Available from: [https://phekb.org/phenotype/170](https://phekb.org/phenotype/170)  

# COMMAND ----------

# MAGIC %md
# MAGIC ## 1. Target Schema

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE SCHEMA IF NOT EXISTS workspace_sdphenotypecore.mace_on_statin_07_30;
# MAGIC USE CATALOG workspace_sdphenotypecore;
# MAGIC USE SCHEMA mace_on_statin_07_30;

# COMMAND ----------

# MAGIC %md
# MAGIC ## 2. Building phenotype

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE workspace_sdphenotypecore.mace_on_statin_07_30.statinmace_phenotype AS
# MAGIC WITH
# MAGIC statin_concepts AS (
# MAGIC     SELECT DISTINCT ca.descendant_concept_id AS concept_id
# MAGIC     FROM   victr_sd.sd_omop_prod.concept_ancestor ca
# MAGIC     JOIN   victr_sd.sd_omop_prod.concept c
# MAGIC            ON c.concept_id = ca.ancestor_concept_id
# MAGIC     WHERE  c.vocabulary_id    = 'RxNorm'
# MAGIC       AND  c.concept_class_id = 'Ingredient'
# MAGIC       AND  c.standard_concept = 'S'
# MAGIC       AND  lower(c.concept_name) IN (
# MAGIC              'simvastatin','fluvastatin','atorvastatin','pravastatin',
# MAGIC              'lovastatin','cerivastatin','rosuvastatin')
# MAGIC ),
# MAGIC statin_person AS (
# MAGIC     SELECT de.person_id,
# MAGIC            min(coalesce(de.drug_exposure_start_date, de.drug_exposure_end_date)) AS first_statin_date
# MAGIC     FROM   victr_sd.sd_omop_prod.drug_exposure de
# MAGIC     JOIN   statin_concepts sc
# MAGIC            ON  sc.concept_id = de.drug_concept_id
# MAGIC            OR  sc.concept_id = de.drug_source_concept_id
# MAGIC     WHERE  coalesce(de.drug_exposure_start_date, de.drug_exposure_end_date) IS NOT NULL
# MAGIC     GROUP  BY de.person_id
# MAGIC ),
# MAGIC dx_ami_concepts AS (
# MAGIC     SELECT concept_id
# MAGIC     FROM   victr_sd.sd_omop_prod.concept
# MAGIC     WHERE  vocabulary_id = 'ICD9CM'
# MAGIC       AND  concept_code RLIKE '^41[01](\\.|$)'
# MAGIC ),
# MAGIC  
# MAGIC dx_excl_concepts AS (
# MAGIC     SELECT concept_id
# MAGIC     FROM   victr_sd.sd_omop_prod.concept
# MAGIC     WHERE  vocabulary_id = 'ICD9CM'
# MAGIC       AND (concept_code RLIKE '^41[01](\\.|$)' OR concept_code = '412')
# MAGIC ),
# MAGIC dx_ami_events AS (
# MAGIC     SELECT DISTINCT
# MAGIC            co.person_id,
# MAGIC            co.condition_start_date         AS dx_date,
# MAGIC            co.condition_source_concept_id  AS code_id
# MAGIC     FROM   victr_sd.sd_omop_prod.condition_occurrence co
# MAGIC     WHERE  co.condition_start_date IS NOT NULL
# MAGIC       AND  co.condition_source_concept_id IN (SELECT concept_id FROM dx_ami_concepts)
# MAGIC ),
# MAGIC excl_person AS (
# MAGIC     SELECT co.person_id, min(co.condition_start_date) AS first_excl_date
# MAGIC     FROM   victr_sd.sd_omop_prod.condition_occurrence co
# MAGIC     WHERE  co.condition_start_date IS NOT NULL
# MAGIC       AND  co.condition_source_concept_id IN (SELECT concept_id FROM dx_excl_concepts)
# MAGIC     GROUP  BY co.person_id
# MAGIC ),
# MAGIC ami_windows AS (
# MAGIC     SELECT DISTINCT
# MAGIC            a.person_id,
# MAGIC            a.dx_date              AS win_start,
# MAGIC            date_add(a.dx_date, 5) AS win_end        -- 5-day window
# MAGIC     FROM   dx_ami_events a
# MAGIC     JOIN   dx_ami_events b
# MAGIC            ON  b.person_id = a.person_id
# MAGIC            AND b.dx_date  >= a.dx_date
# MAGIC            AND b.dx_date  <= date_add(a.dx_date, 5)
# MAGIC            AND (b.dx_date > a.dx_date OR b.code_id <> a.code_id)
# MAGIC ),
# MAGIC lab_daily AS (
# MAGIC     SELECT person_id, lab_date, lab_role, max(value_ngml) AS value_ngml
# MAGIC     FROM (
# MAGIC         SELECT m.person_id,
# MAGIC                m.measurement_date AS lab_date,
# MAGIC                CASE
# MAGIC                  WHEN m.measurement_concept_id IN (3021337, 3033745)  THEN 'TNI'
# MAGIC                  WHEN m.measurement_concept_id IN (3019800, 40769783) THEN 'TNT'
# MAGIC                  WHEN m.measurement_concept_id  = 3005785             THEN 'CKMB'
# MAGIC                  WHEN m.measurement_concept_id IN (3016311, 3007150)  THEN 'RATIO'
# MAGIC                  WHEN m.measurement_concept_id = 0
# MAGIC                   AND upper(m.measurement_source_value) RLIKE 'TROPONIN[^A-Z0-9]+T([^A-Z0-9]|$)'
# MAGIC                   --AND upper(m.measurement_source_value) RLIKE 'TROPONIN.*T'          
# MAGIC                   THEN 'TNT'
# MAGIC                   
# MAGIC                   --fix case: TROPONIN_POINT_OF_CARE
# MAGIC                  WHEN m.measurement_concept_id = 0
# MAGIC                   AND upper(m.measurement_source_value) RLIKE 'TROPONIN|POC_TROPONIN' THEN 'TNI'
# MAGIC                  WHEN m.measurement_concept_id = 0
# MAGIC                   AND upper(m.measurement_source_value) RLIKE '^CKMB|CK_MB'          THEN 'CKMB'
# MAGIC                END AS lab_role,
# MAGIC                CASE
# MAGIC                  WHEN m.measurement_concept_id IN (3016311, 3007150)
# MAGIC                       THEN m.value_as_number                              
# MAGIC                  WHEN lower(trim(m.unit_source_value)) IN ('ng/l','pg/ml')
# MAGIC                       THEN m.value_as_number / 1000.0
# MAGIC                  WHEN lower(trim(m.unit_source_value)) = 'ng/dl'
# MAGIC                       THEN m.value_as_number / 100.0
# MAGIC                  ELSE m.value_as_number                                   
# MAGIC                END AS value_ngml
# MAGIC         FROM   victr_sd.sd_omop_prod.measurement m
# MAGIC         WHERE  m.value_as_number  IS NOT NULL
# MAGIC           AND  m.measurement_date IS NOT NULL
# MAGIC           AND  m.measurement_concept_id NOT IN (2212605, 2212290, 4017058, 4042917)
# MAGIC           AND (m.measurement_concept_id IN (3021337,3033745,3019800,40769783,3005785,3016311,3007150)
# MAGIC             OR (m.measurement_concept_id = 0
# MAGIC                 AND upper(m.measurement_source_value) RLIKE 'TROPONIN|POC_TROPONIN|^CKMB|CK_MB'))
# MAGIC     ) x
# MAGIC     WHERE lab_role IS NOT NULL
# MAGIC     GROUP BY person_id, lab_date, lab_role
# MAGIC ),
# MAGIC ami_confirmed AS (
# MAGIC     SELECT w.person_id, w.win_start
# MAGIC     FROM   ami_windows w
# MAGIC     JOIN   lab_daily   l
# MAGIC            ON  l.person_id = w.person_id
# MAGIC            AND l.lab_date BETWEEN w.win_start AND w.win_end
# MAGIC     GROUP  BY w.person_id, w.win_start
# MAGIC     HAVING max(CASE WHEN l.lab_role = 'TNI'   AND l.value_ngml >= 0.10 THEN 1 ELSE 0 END) = 1
# MAGIC         OR max(CASE WHEN l.lab_role = 'TNT'   AND l.value_ngml >= 0.10 THEN 1 ELSE 0 END) = 1
# MAGIC         OR (max(CASE WHEN l.lab_role = 'RATIO' AND l.value_ngml >= 3.0  THEN 1 ELSE 0 END) = 1
# MAGIC         AND max(CASE WHEN l.lab_role = 'CKMB'  AND l.value_ngml >= 10.0 THEN 1 ELSE 0 END) = 1)
# MAGIC ),
# MAGIC ami_case AS (
# MAGIC     SELECT c.person_id, min(c.win_start) AS ami_index_date
# MAGIC     FROM   ami_confirmed c
# MAGIC     JOIN   statin_person sp ON sp.person_id = c.person_id
# MAGIC     WHERE  sp.first_statin_date <= date_sub(c.win_start, 180)
# MAGIC     GROUP  BY c.person_id
# MAGIC ),
# MAGIC revasc_concepts AS (
# MAGIC     SELECT concept_id
# MAGIC     FROM   victr_sd.sd_omop_prod.concept
# MAGIC     WHERE  vocabulary_id IN ('CPT4','HCPCS')
# MAGIC       AND  concept_code IN (
# MAGIC              '33533','33534','33535','33536',
# MAGIC              '33510','33511','33512','33513','33514','33515','33516',
# MAGIC              '33517','33518','33519','33520','33521','33522','33523',
# MAGIC              '92980','92981','92982','92984','92995','92996',
# MAGIC              'C1874','C1875','C1876','C1877')
# MAGIC ),
# MAGIC  
# MAGIC revasc_events AS (
# MAGIC     SELECT DISTINCT po.person_id, po.procedure_date AS proc_date
# MAGIC     FROM   victr_sd.sd_omop_prod.procedure_occurrence po
# MAGIC     WHERE  po.procedure_date IS NOT NULL
# MAGIC       AND (po.procedure_concept_id        IN (SELECT concept_id FROM revasc_concepts)
# MAGIC         OR po.procedure_source_concept_id IN (SELECT concept_id FROM revasc_concepts))
# MAGIC ),
# MAGIC  
# MAGIC revasc_person AS (
# MAGIC     SELECT person_id, min(proc_date) AS first_revasc_date
# MAGIC     FROM   revasc_events
# MAGIC     GROUP  BY person_id
# MAGIC ),
# MAGIC revasc_case AS (
# MAGIC     SELECT r.person_id, min(r.proc_date) AS revasc_index_date
# MAGIC     FROM   revasc_events r
# MAGIC     JOIN   statin_person sp ON sp.person_id = r.person_id
# MAGIC     WHERE  sp.first_statin_date <= date_sub(r.proc_date, 180)
# MAGIC     GROUP  BY r.person_id
# MAGIC ),
# MAGIC nlp_person AS (
# MAGIC     SELECT n.person_id, min(n.note_date) AS first_mace_note_date
# MAGIC     FROM   victr_sd.sd_omop_prod.note n
# MAGIC     WHERE  n.x_doc_type = 'PL'
# MAGIC       AND  n.note_text IS NOT NULL
# MAGIC       AND  n.note_date IS NOT NULL
# MAGIC       AND (n.note_text RLIKE '\\b(AMI|MI|CABG|BMS|DES)\\b'
# MAGIC         OR n.note_text RLIKE '(?i)\\b(acute myocardial infarction|myocardial infarction|coronary artery bypass|cypher|taxus|stent)\\b')
# MAGIC     GROUP  BY n.person_id
# MAGIC ),
# MAGIC first_ami_case AS (
# MAGIC     SELECT a.person_id, a.ami_index_date AS first_ami_index_date
# MAGIC     FROM   ami_case a
# MAGIC     LEFT   JOIN excl_person   e ON e.person_id = a.person_id
# MAGIC     LEFT   JOIN revasc_person r ON r.person_id = a.person_id
# MAGIC     LEFT   JOIN nlp_person    n ON n.person_id = a.person_id
# MAGIC     WHERE  (e.first_excl_date       IS NULL OR e.first_excl_date       >= a.ami_index_date)
# MAGIC       AND  (r.first_revasc_date     IS NULL OR r.first_revasc_date     >= a.ami_index_date)
# MAGIC       AND  (n.first_mace_note_date  IS NULL OR n.first_mace_note_date  >= a.ami_index_date)
# MAGIC ),
# MAGIC  
# MAGIC first_revasc_case AS (
# MAGIC     SELECT v.person_id, v.revasc_index_date AS first_revasc_index_date
# MAGIC     FROM   revasc_case v
# MAGIC     LEFT   JOIN excl_person   e ON e.person_id = v.person_id
# MAGIC     LEFT   JOIN revasc_person r ON r.person_id = v.person_id
# MAGIC     LEFT   JOIN nlp_person    n ON n.person_id = v.person_id
# MAGIC     WHERE  (e.first_excl_date       IS NULL OR e.first_excl_date       >= v.revasc_index_date)
# MAGIC       AND  (r.first_revasc_date     IS NULL OR r.first_revasc_date     >= v.revasc_index_date)
# MAGIC       AND  (n.first_mace_note_date  IS NULL OR n.first_mace_note_date  >= v.revasc_index_date)
# MAGIC ),
# MAGIC control AS (
# MAGIC     SELECT sp.person_id
# MAGIC     FROM   statin_person sp
# MAGIC     LEFT   JOIN excl_person   e ON e.person_id = sp.person_id
# MAGIC     LEFT   JOIN revasc_person r ON r.person_id = sp.person_id
# MAGIC     LEFT   JOIN nlp_person    n ON n.person_id = sp.person_id
# MAGIC     WHERE  e.person_id IS NULL AND r.person_id IS NULL AND n.person_id IS NULL
# MAGIC ),
# MAGIC mortality AS (
# MAGIC     SELECT person_id,
# MAGIC            1 AS deceased,
# MAGIC            min(death_date) AS death_date,
# MAGIC            array_sort(collect_set(death_type_concept_id)) AS death_sources
# MAGIC     FROM   victr_sd.sd_omop_prod.death
# MAGIC     GROUP  BY person_id
# MAGIC )
# MAGIC SELECT
# MAGIC     p.person_id,
# MAGIC  
# MAGIC     CASE
# MAGIC       WHEN fa.person_id IS NOT NULL OR fv.person_id IS NOT NULL THEN 'FIRST_MACE'
# MAGIC       WHEN am.person_id IS NOT NULL OR rv.person_id IS NOT NULL THEN 'MACE'
# MAGIC       WHEN ct.person_id IS NOT NULL                             THEN 'CONTROL'
# MAGIC       WHEN sp.person_id IS NOT NULL                             THEN 'EXCLUDED_ON_STATIN'
# MAGIC       ELSE                                                           'NOT_ON_STATIN'
# MAGIC     END AS PhenotypeLabel,
# MAGIC  
# MAGIC     CASE
# MAGIC       WHEN am.person_id IS NOT NULL AND rv.person_id IS NOT NULL THEN 'BOTH'
# MAGIC       WHEN am.person_id IS NOT NULL                              THEN 'AMI'
# MAGIC       WHEN rv.person_id IS NOT NULL                              THEN 'REVASC'
# MAGIC     END AS MaceType,
# MAGIC  
# MAGIC     CASE WHEN am.person_id IS NOT NULL THEN 1 ELSE 0 END AS AmiStatinCase,
# MAGIC     CASE WHEN fa.person_id IS NOT NULL THEN 1 ELSE 0 END AS FstAmiStatinCase,
# MAGIC     CASE WHEN rv.person_id IS NOT NULL THEN 1 ELSE 0 END AS RevascStatinCase,
# MAGIC     CASE WHEN fv.person_id IS NOT NULL THEN 1 ELSE 0 END AS FstRevascStatinCase,
# MAGIC     CASE WHEN ct.person_id IS NOT NULL THEN 1 ELSE 0 END AS MaceStatinControl,
# MAGIC  
# MAGIC     am.ami_index_date          AS AmiIndexDate,
# MAGIC     fa.first_ami_index_date    AS FstAmiIndexDate,
# MAGIC     rv.revasc_index_date       AS RevascIndexDate,
# MAGIC     fv.first_revasc_index_date AS FstRevascIndexDate,
# MAGIC     CASE WHEN am.person_id IS NOT NULL OR rv.person_id IS NOT NULL
# MAGIC          THEN least(coalesce(am.ami_index_date,    DATE'9999-12-31'),
# MAGIC                     coalesce(rv.revasc_index_date, DATE'9999-12-31'))
# MAGIC     END AS MaceIndexDate,
# MAGIC     sp.first_statin_date AS FirstStatinDate,
# MAGIC     CASE WHEN am.person_id IS NOT NULL OR rv.person_id IS NOT NULL
# MAGIC          THEN datediff(least(coalesce(am.ami_index_date,    DATE'9999-12-31'),
# MAGIC                              coalesce(rv.revasc_index_date, DATE'9999-12-31')),
# MAGIC                        sp.first_statin_date)
# MAGIC     END AS StatinExposureDays,
# MAGIC  
# MAGIC     coalesce(d.deceased, 0)   AS Deceased,
# MAGIC     d.death_date              AS DeathDate,
# MAGIC     CASE WHEN d.death_date IS NULL THEN 0 ELSE 1 END AS DeathDateKnown,
# MAGIC     d.death_sources           AS DeathSources
# MAGIC  
# MAGIC FROM      victr_sd.sd_omop_prod.person p
# MAGIC LEFT JOIN statin_person     sp ON sp.person_id = p.person_id
# MAGIC LEFT JOIN ami_case          am ON am.person_id = p.person_id
# MAGIC LEFT JOIN first_ami_case    fa ON fa.person_id = p.person_id
# MAGIC LEFT JOIN revasc_case       rv ON rv.person_id = p.person_id
# MAGIC LEFT JOIN first_revasc_case fv ON fv.person_id = p.person_id
# MAGIC LEFT JOIN control           ct ON ct.person_id = p.person_id
# MAGIC LEFT JOIN mortality         d  ON d.person_id  = p.person_id;

# COMMAND ----------

# MAGIC %md
# MAGIC ## 3. QC counts check

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT PhenotypeLabel, MaceType, count(*) AS n_persons
# MAGIC FROM   workspace_sdphenotypecore.mace_on_statin_07_30.statinmace_phenotype
# MAGIC GROUP  BY PhenotypeLabel, MaceType
# MAGIC ORDER  BY PhenotypeLabel, MaceType;

# COMMAND ----------

# MAGIC %sql
# MAGIC select *
# MAGIC from  workspace_sdphenotypecore.mace_on_statin_07_30.statinmace_phenotype
# MAGIC limit 5

# COMMAND ----------

# DBTITLE 1,Output Schema Description
# MAGIC %md
# MAGIC ## `statinmace_phenotype` Output Schema
# MAGIC
# MAGIC | # | Column | Type | Description |
# MAGIC |---|--------|------|-------------|
# MAGIC | 1 | `person_id` | bigint | Unique patient identifier from the OMOP `person` table |
# MAGIC | 2 | `PhenotypeLabel` | string | Cohort assignment: **FIRST_MACE** (first qualifying event, no prior history), **MACE** (event with prior history), **CONTROL** (on statin, no MACE/exclusions), **EXCLUDED_ON_STATIN** (on statin but has exclusion criteria), **NOT_ON_STATIN** (no statin exposure) |
# MAGIC | 3 | `MaceType` | string | Type of MACE event: **AMI** (AMI only), **REVASC** (revascularization only), **BOTH** (AMI and revascularization), or NULL (no MACE) |
# MAGIC | 4 | `AmiStatinCase` | int (0/1) | 1 if patient had any AMI while on statin (≥180 days after first statin) |
# MAGIC | 5 | `FstAmiStatinCase` | int (0/1) | 1 if patient's AMI qualifies as a first event (no prior MI/revasc/NLP history) |
# MAGIC | 6 | `RevascStatinCase` | int (0/1) | 1 if patient had any revascularization while on statin (≥180 days after first statin) |
# MAGIC | 7 | `FstRevascStatinCase` | int (0/1) | 1 if patient's revascularization qualifies as a first event (no prior history) |
# MAGIC | 8 | `MaceStatinControl` | int (0/1) | 1 if patient is on statin with no MACE, no exclusion diagnoses, no revasc, and no NLP-identified events |
# MAGIC | 9 | `AmiIndexDate` | date | Date of the first qualifying AMI event on statin; NULL if no AMI |
# MAGIC | 10 | `FstAmiIndexDate` | date | Date of the first AMI with no prior cardiovascular history; NULL if not a first-event case |
# MAGIC | 11 | `RevascIndexDate` | date | Date of the first qualifying revascularization on statin; NULL if no revasc |
# MAGIC | 12 | `FstRevascIndexDate` | date | Date of the first revascularization with no prior history; NULL if not a first-event case |
# MAGIC | 13 | `MaceIndexDate` | date | Earliest of `AmiIndexDate` and `RevascIndexDate`; NULL for non-MACE patients |
# MAGIC | 14 | `FirstStatinDate` | date | Date of the patient's earliest statin prescription; NULL if never on statin |
# MAGIC | 15 | `StatinExposureDays` | int | Days between `FirstStatinDate` and `MaceIndexDate`; NULL for non-MACE patients |
# MAGIC | 16 | `Deceased` | int (0/1) | 1 if a death record exists in the OMOP `death` table |
# MAGIC | 17 | `DeathDate` | date | Date of death from the `death` table; NULL if alive or date unknown |
# MAGIC | 18 | `DeathDateKnown` | int (0/1) | 1 if `DeathDate` is non-null; 0 otherwise |
# MAGIC | 19 | `DeathSources` | array&lt;bigint&gt; | Sorted distinct `death_type_concept_id` values indicating the source(s) of the death record (e.g., EHR, registry) |