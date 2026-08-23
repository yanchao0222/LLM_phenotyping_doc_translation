# Databricks notebook source
# MAGIC %md
# MAGIC # Type 2 Diabetes Mellitus (T2DM) — Phenotype
# MAGIC  
# MAGIC Assigns case / control / neither for every person in the SD.
# MAGIC  
# MAGIC | | |
# MAGIC |---|---|
# MAGIC | **Phenotype** | Type 2 Diabetes Mellitus (T2DM) |
# MAGIC | **Source algorithm** | eMERGE / Northwestern University T2DM EMR algorithm |
# MAGIC | **Source location** | [PheKB — Type 2 Diabetes Mellitus](https://phekb.org/phenotype/type-2-diabetes-mellitus) |
# MAGIC | **Implemented by** | Srushti Gangireddy, Wu-Chen Su |
# MAGIC | **Created** | 2026-08-01 |
# MAGIC | **Last modified** | 2026-08-22 |
# MAGIC | **Data source** | VUMC Synthetic Derivative, OMOP CDM v5 (`victr_sd.sd_omop_prod`) |
# MAGIC | **Output schema** | `workspace_sdphenotypecore.phekb_t2dm_algo` |
# MAGIC | **Platform** | Databricks SQL |
# MAGIC  
# MAGIC ## Prerequisite
# MAGIC  
# MAGIC **`00_T2DM_setup` must have been run.** It creates the schema and materializes
# MAGIC every concept set this notebook reads: `dd_dxT1dm`, `dd_dxT2dm`, `dd_dxDm`,
# MAGIC `dd_rxT1dm`, `dd_rxT2dm`, `dd_rxSupply`, `dd_fastGlucose`, `dd_randomGlucose`,
# MAGIC `dd_hA1C` and `fam_hist_dm_terms`.
# MAGIC  
# MAGIC ## Source vocabularies
# MAGIC  
# MAGIC | | |
# MAGIC |---|---|
# MAGIC | Dx | ICD-9-CM (Tables 3, 4, 9), expanded through `Maps to` |
# MAGIC | Rx | RxNorm (Tables 5, 6, 8), ingredient-level expanded to descendants |
# MAGIC | Labs | LOINC (Table 7, 7 codes) |
# MAGIC  
# MAGIC ## Thresholds
# MAGIC  
# MAGIC Taken from the pseudocode (Algorithms 6 and 11):
# MAGIC  
# MAGIC | | Fasting glucose | Random glucose | HbA1c |
# MAGIC |---|---|---|---|
# MAGIC | Case | `>= 125` | `>= 200` | `>= 6.5` |
# MAGIC | Control | `>= 110` | `>= 110` | `>= 6.0` |
# MAGIC
# MAGIC ## Output
# MAGIC  
# MAGIC One row per person: `eMERGE_ID`, `Case_Control` — `1` = case, `2` = control,
# MAGIC `NO` = neither.
# MAGIC
# MAGIC ## Implementation limitations
# MAGIC
# MAGIC ### Physician-entered diagnoses (Algorithm 7)
# MAGIC
# MAGIC Algorithm 7 restricts the Path 5 diagnosis count to diagnoses *"derived from
# MAGIC encounter or problem list sources only (excludes billing codes)"*. In OMOP this
# MAGIC maps to `condition_type_concept_id`, whose populated values are a property of
# MAGIC the local ETL rather than a fixed vocabulary. We used 2 diagnoses check instead.
# MAGIC
# MAGIC ### In-person office encounters (Algorithm 12)
# MAGIC
# MAGIC Algorithm 12 requires two or more in-person office encounters. The
# MAGIC implementation uses `visit_concept_id = 9202` (Outpatient Visit) alone, inlined
# MAGIC rather than drawn from a configurable set.
# MAGIC
# MAGIC `9202` is the standard OMOP concept for outpatient care
# MAGIC  
# MAGIC ## Citation
# MAGIC
# MAGIC Jennifer Pacheco and Will Thompson. *Type 2 Diabetes Mellitus*. Northwestern University. PheKB; 2012. Available from: [https://phekb.org/phenotype/18](https://phekb.org/phenotype/18)

# COMMAND ----------

# MAGIC %sql
# MAGIC USE CATALOG workspace_sdphenotypecore;
# MAGIC USE SCHEMA phekb_t2dm_algo;

# COMMAND ----------

# MAGIC %md
# MAGIC ## 1 · Base population
# MAGIC  
# MAGIC Every person in the SD. The algorithm has no age, enrollment or observation-
# MAGIC period entry criterion, so the denominator is unrestricted.

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TEMPORARY VIEW cohort AS
# MAGIC SELECT DISTINCT person_id FROM victr_sd.sd_omop_prod.person;

# COMMAND ----------

# MAGIC %md
# MAGIC ## 2 · Algorithm variables

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TEMPORARY VIEW alg_var AS
# MAGIC SELECT
# MAGIC   p.person_id,
# MAGIC   coalesce(a2.t1dm_dx_dt_cnt, 0)         AS t1dm_dx_dt_cnt,
# MAGIC   coalesce(a3.t2dm_dx_dt_cnt, 0)         AS t2dm_dx_dt_cnt,
# MAGIC   a4.t2dm_rx_dt                          AS t2dm_rx_dt,
# MAGIC   a5.t1dm_rx_dt                          AS t1dm_rx_dt,
# MAGIC   coalesce(a6.abnormal_lab_case, false)  AS abnormal_lab_case,
# MAGIC   coalesce(a7.t2dm_physcn_dx_dt_cnt, 0)  AS t2dm_physcn_dx_dt_cnt,
# MAGIC   coalesce(a9.dm_dx_dt_cnt, 0)           AS dm_dx_dt_cnt,
# MAGIC   coalesce(a10.glucose_lab_exists,false) AS glucose_lab_exists,
# MAGIC   coalesce(a11.abnormal_lab_ctrl, false) AS abnormal_lab_ctrl,
# MAGIC   coalesce(a12.enctrs_dt_cnt, 0)         AS enctrs_dt_cnt,
# MAGIC   coalesce(a13.dm_meds_supplies_cnt, 0)  AS dm_meds_supplies_cnt,
# MAGIC   coalesce(a14.fam_hist_of_dm, false)    AS fam_hist_of_dm
# MAGIC FROM cohort p
# MAGIC
# MAGIC -- Distinct dates of T1DM dx (Table 3)
# MAGIC LEFT JOIN (
# MAGIC   SELECT person_id, COUNT(DISTINCT condition_start_date) AS t1dm_dx_dt_cnt
# MAGIC   FROM victr_sd.sd_omop_prod.condition_occurrence
# MAGIC   WHERE condition_concept_id IN (SELECT code FROM dd_dxT1dm)
# MAGIC      OR condition_source_concept_id IN (SELECT code FROM dd_dxT1dm)
# MAGIC   GROUP BY person_id
# MAGIC ) a2 ON a2.person_id = p.person_id
# MAGIC
# MAGIC -- Distinct dates of T2DM dx (Table 4)
# MAGIC LEFT JOIN (
# MAGIC   SELECT person_id, COUNT(DISTINCT condition_start_date) AS t2dm_dx_dt_cnt
# MAGIC   FROM victr_sd.sd_omop_prod.condition_occurrence
# MAGIC   WHERE condition_concept_id IN (SELECT code FROM dd_dxT2dm)
# MAGIC      OR condition_source_concept_id IN (SELECT code FROM dd_dxT2dm)
# MAGIC   GROUP BY person_id
# MAGIC ) a3 ON a3.person_id = p.person_id
# MAGIC
# MAGIC -- Earliest T2DM medication date (Table 6)
# MAGIC LEFT JOIN (
# MAGIC   SELECT person_id, MIN(drug_exposure_start_date) AS t2dm_rx_dt
# MAGIC   FROM victr_sd.sd_omop_prod.drug_exposure
# MAGIC   WHERE drug_concept_id IN (SELECT code FROM dd_rxT2dm)
# MAGIC      OR drug_source_concept_id IN (SELECT code FROM dd_rxT2dm)
# MAGIC   GROUP BY person_id
# MAGIC ) a4 ON a4.person_id = p.person_id
# MAGIC
# MAGIC -- Earliest T1DM medication date (Table 5)
# MAGIC LEFT JOIN (
# MAGIC   SELECT person_id, MIN(drug_exposure_start_date) AS t1dm_rx_dt
# MAGIC   FROM victr_sd.sd_omop_prod.drug_exposure
# MAGIC   WHERE drug_concept_id IN (SELECT code FROM dd_rxT1dm)
# MAGIC      OR drug_source_concept_id IN (SELECT code FROM dd_rxT1dm)
# MAGIC   GROUP BY person_id
# MAGIC ) a5 ON a5.person_id = p.person_id
# MAGIC
# MAGIC -- Abnormal lab, CASE thresholds (Algorithm 6)
# MAGIC LEFT JOIN (
# MAGIC   SELECT person_id, true AS abnormal_lab_case
# MAGIC   FROM victr_sd.sd_omop_prod.measurement
# MAGIC   WHERE value_as_number IS NOT NULL AND (
# MAGIC        ((measurement_concept_id IN (SELECT code FROM dd_fastGlucose)   OR measurement_source_concept_id IN (SELECT code FROM dd_fastGlucose))   AND value_as_number >= 125)
# MAGIC     OR ((measurement_concept_id IN (SELECT code FROM dd_randomGlucose) OR measurement_source_concept_id IN (SELECT code FROM dd_randomGlucose)) AND value_as_number >= 200)
# MAGIC     OR ((measurement_concept_id IN (SELECT code FROM dd_hA1C)          OR measurement_source_concept_id IN (SELECT code FROM dd_hA1C))          AND value_as_number >= 6.5)
# MAGIC   )
# MAGIC   GROUP BY person_id
# MAGIC ) a6 ON a6.person_id = p.person_id
# MAGIC
# MAGIC LEFT JOIN (
# MAGIC   SELECT person_id, COUNT(DISTINCT condition_start_date) AS t2dm_physcn_dx_dt_cnt
# MAGIC   FROM victr_sd.sd_omop_prod.condition_occurrence
# MAGIC   WHERE condition_concept_id IN (SELECT code FROM dd_dxT2dm)
# MAGIC      OR condition_source_concept_id IN (SELECT code FROM dd_dxT2dm)
# MAGIC   GROUP BY person_id
# MAGIC ) a7 ON a7.person_id = p.person_id
# MAGIC
# MAGIC -- Distinct dates of any DM-related dx (Table 9), control exclusion only
# MAGIC LEFT JOIN (
# MAGIC   SELECT person_id, COUNT(DISTINCT condition_start_date) AS dm_dx_dt_cnt
# MAGIC   FROM victr_sd.sd_omop_prod.condition_occurrence
# MAGIC   WHERE condition_concept_id IN (SELECT code FROM dd_dxDm)
# MAGIC      OR condition_source_concept_id IN (SELECT code FROM dd_dxDm)
# MAGIC   GROUP BY person_id
# MAGIC ) a9 ON a9.person_id = p.person_id
# MAGIC
# MAGIC -- Has at least one glucose measurement (control inclusion)
# MAGIC LEFT JOIN (
# MAGIC   SELECT person_id, true AS glucose_lab_exists
# MAGIC   FROM victr_sd.sd_omop_prod.measurement
# MAGIC   WHERE measurement_concept_id IN (SELECT code FROM dd_fastGlucose)
# MAGIC      OR measurement_source_concept_id IN (SELECT code FROM dd_fastGlucose)
# MAGIC      OR measurement_concept_id IN (SELECT code FROM dd_randomGlucose)
# MAGIC      OR measurement_source_concept_id IN (SELECT code FROM dd_randomGlucose)
# MAGIC   GROUP BY person_id
# MAGIC ) a10 ON a10.person_id = p.person_id
# MAGIC
# MAGIC -- Abnormal lab, CONTROL thresholds (Algorithm 11)
# MAGIC LEFT JOIN (
# MAGIC   SELECT person_id, true AS abnormal_lab_ctrl
# MAGIC   FROM victr_sd.sd_omop_prod.measurement
# MAGIC   WHERE value_as_number IS NOT NULL AND (
# MAGIC        ((measurement_concept_id IN (SELECT code FROM dd_fastGlucose)   OR measurement_source_concept_id IN (SELECT code FROM dd_fastGlucose))   AND value_as_number >= 110)
# MAGIC     OR ((measurement_concept_id IN (SELECT code FROM dd_randomGlucose) OR measurement_source_concept_id IN (SELECT code FROM dd_randomGlucose)) AND value_as_number >= 110)
# MAGIC     OR ((measurement_concept_id IN (SELECT code FROM dd_hA1C)          OR measurement_source_concept_id IN (SELECT code FROM dd_hA1C))          AND value_as_number >= 6.0)
# MAGIC   )
# MAGIC   GROUP BY person_id
# MAGIC ) a11 ON a11.person_id = p.person_id
# MAGIC
# MAGIC -- Distinct dates of in-person office encounters (Algorithm 12) 9202 = Outpatient Visit, inlined.
# MAGIC LEFT JOIN (
# MAGIC   SELECT person_id, COUNT(DISTINCT visit_start_date) AS enctrs_dt_cnt
# MAGIC   FROM victr_sd.sd_omop_prod.visit_occurrence
# MAGIC   WHERE visit_concept_id = 9202
# MAGIC   GROUP BY person_id
# MAGIC ) a12 ON a12.person_id = p.person_id
# MAGIC
# MAGIC -- Distinct dates of DM medications and supplies (Tables 5, 6, 8)
# MAGIC LEFT JOIN (
# MAGIC   SELECT person_id, COUNT(DISTINCT exposure_dt) AS dm_meds_supplies_cnt
# MAGIC   FROM (
# MAGIC     SELECT person_id, drug_exposure_start_date AS exposure_dt
# MAGIC     FROM victr_sd.sd_omop_prod.drug_exposure
# MAGIC     WHERE drug_concept_id IN (SELECT code FROM dd_rxT1dm)   OR drug_source_concept_id IN (SELECT code FROM dd_rxT1dm)
# MAGIC        OR drug_concept_id IN (SELECT code FROM dd_rxT2dm)   OR drug_source_concept_id IN (SELECT code FROM dd_rxT2dm)
# MAGIC        OR drug_concept_id IN (SELECT code FROM dd_rxSupply) OR drug_source_concept_id IN (SELECT code FROM dd_rxSupply)
# MAGIC     UNION ALL
# MAGIC     SELECT person_id, device_exposure_start_date
# MAGIC     FROM victr_sd.sd_omop_prod.device_exposure
# MAGIC     WHERE device_concept_id IN (SELECT code FROM dd_rxSupply)
# MAGIC        OR device_source_concept_id IN (SELECT code FROM dd_rxSupply)
# MAGIC   )
# MAGIC   GROUP BY person_id
# MAGIC ) a13 ON a13.person_id = p.person_id
# MAGIC
# MAGIC -- Family history of diabetes (Algorithm 14), VUMC-local x_family_history
# MAGIC LEFT JOIN (
# MAGIC   SELECT DISTINCT person_id, true AS fam_hist_of_dm
# MAGIC   FROM victr_sd.sd_omop_prod.x_family_history
# MAGIC   WHERE LOWER(medical_hx_name) IN (SELECT hx_name_lower FROM fam_hist_dm_terms)
# MAGIC ) a14 ON a14.person_id = p.person_id;

# COMMAND ----------

# MAGIC %md
# MAGIC ## 3 · Case and control assignment
# MAGIC  
# MAGIC **Cases — Figure 1.** Five paths, all requiring no T1DM diagnosis. Paths 1, 2, 3
# MAGIC and 5 additionally require a T2DM diagnosis and are distinguished by the
# MAGIC medication pattern; Path 4 is the no-diagnosis route, reached on T2DM
# MAGIC medication plus an abnormal lab.
# MAGIC  
# MAGIC | Path | T2DM dx | T1DM Rx | T2DM Rx | Additional |
# MAGIC |---|---|---|---|---|
# MAGIC | 1 | yes | yes | yes | T2DM Rx precedes T1DM Rx |
# MAGIC | 2 | yes | no | yes | — |
# MAGIC | 3 | yes | no | no | abnormal lab (case thresholds) |
# MAGIC | 4 | no | — | yes | abnormal lab (case thresholds) |
# MAGIC | 5 | yes | yes | no | ≥ 2 physician-entered T2DM dx dates |
# MAGIC  
# MAGIC **Controls — Algorithm 8.** A single path, six conjuncts, all required.
# MAGIC  

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TEMPORARY VIEW phenotype AS
# MAGIC SELECT
# MAGIC   person_id,
# MAGIC   CASE WHEN
# MAGIC         -- Path 1: T2DM dx, both med types, T2DM med first
# MAGIC         (t1dm_dx_dt_cnt = 0 AND t2dm_dx_dt_cnt > 0 AND t2dm_rx_dt IS NOT NULL AND t1dm_rx_dt IS NOT NULL AND t2dm_rx_dt < t1dm_rx_dt)
# MAGIC         -- Path 2: T2DM dx, T2DM meds only
# MAGIC      OR (t1dm_dx_dt_cnt = 0 AND t2dm_dx_dt_cnt > 0 AND t1dm_rx_dt IS NULL AND t2dm_rx_dt IS NOT NULL)
# MAGIC         -- Path 3: T2DM dx, no meds, abnormal lab
# MAGIC      OR (t1dm_dx_dt_cnt = 0 AND t2dm_dx_dt_cnt > 0 AND t1dm_rx_dt IS NULL AND t2dm_rx_dt IS NULL AND abnormal_lab_case)
# MAGIC         -- Path 4: no dx, T2DM meds, abnormal lab
# MAGIC      OR (t1dm_dx_dt_cnt = 0 AND t2dm_dx_dt_cnt = 0 AND t2dm_rx_dt IS NOT NULL AND abnormal_lab_case)
# MAGIC         -- Path 5: T2DM dx, T1DM meds only, >= 2 physician-entered dx dates
# MAGIC      OR (t1dm_dx_dt_cnt = 0 AND t2dm_dx_dt_cnt > 0 AND t1dm_rx_dt IS NOT NULL AND t2dm_rx_dt IS NULL AND t2dm_physcn_dx_dt_cnt >= 2)
# MAGIC        THEN 'YES' ELSE 'NO' END AS pCase,
# MAGIC   CASE WHEN
# MAGIC         -- Algorithm 8, single control path
# MAGIC         dm_dx_dt_cnt = 0
# MAGIC     AND glucose_lab_exists = true
# MAGIC     AND abnormal_lab_ctrl = false
# MAGIC     AND enctrs_dt_cnt >= 2
# MAGIC     AND dm_meds_supplies_cnt = 0
# MAGIC     AND fam_hist_of_dm = false
# MAGIC        THEN 'YES' ELSE 'NO' END AS pCtrl
# MAGIC FROM alg_var;
# MAGIC  

# COMMAND ----------

# MAGIC %md
# MAGIC ## 4 · Output

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE t2dm_phenotype AS
# MAGIC SELECT person_id AS eMERGE_ID,
# MAGIC        CASE WHEN pCase = 'YES' THEN '1'
# MAGIC             WHEN pCtrl = 'YES' THEN '2'
# MAGIC             ELSE 'NO' END AS Case_Control
# MAGIC FROM phenotype;

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT Case_Control, COUNT(*) AS n
# MAGIC FROM t2dm_phenotype
# MAGIC GROUP BY Case_Control
# MAGIC ORDER BY Case_Control;