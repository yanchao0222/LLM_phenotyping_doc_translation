# Databricks notebook source
# MAGIC %md
# MAGIC # Type 2 Diabetes Mellitus (T2DM) — Setup and Concept Sets
# MAGIC
# MAGIC Creates the working schema and materializes the concept sets the phenotype
# MAGIC depends on. Run this notebook **once** before `T2DM_phenotype`.
# MAGIC
# MAGIC | | |
# MAGIC |---|---|
# MAGIC | **Phenotype** | Type 2 Diabetes Mellitus (T2DM) |
# MAGIC | **Source algorithm** | eMERGE / Northwestern University T2DM EMR algorithm |
# MAGIC | **Source location** | [PheKB — Type 2 Diabetes Mellitus](https://phekb.org/phenotype/type-2-diabetes-mellitus) |
# MAGIC | **Implemented by** | Srushti Gangireddy, Wu-Chen Su |
# MAGIC | **Created** | 2026-08-01 |
# MAGIC | **Last modified** | 2026-08-14 |
# MAGIC | **Data source** | VUMC Synthetic Derivative, OMOP CDM v5 (`victr_sd.sd_omop_prod`) |
# MAGIC | **Output schema** | `workspace_sdphenotypecore.phekb_t2dm_algo` |
# MAGIC | **Platform** | Databricks SQL |
# MAGIC
# MAGIC
# MAGIC The tables created here are inputs to `T2DM_phenotype`.

# COMMAND ----------

# MAGIC %md
# MAGIC ## 1 · Working schema
# MAGIC  
# MAGIC All phenotype tables are written to `workspace_sdphenotypecore.phekb_t2dm_algo`.
# MAGIC The source OMOP CDM is read-only and is always referenced by its
# MAGIC fully-qualified name.

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE SCHEMA IF NOT EXISTS workspace_sdphenotypecore.phekb_t2dm_algo;
# MAGIC USE CATALOG workspace_sdphenotypecore;
# MAGIC USE SCHEMA phekb_t2dm_algo;

# COMMAND ----------

# MAGIC %md
# MAGIC ## 2 · T1DM diagnosis codes Used in Algorithm 1
# MAGIC
# MAGIC | Description | ICD-9 code |
# MAGIC |---|---|
# MAGIC | Type 1 Diabetes | 250.x1, 250.x3 |

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE src_icd_t1dm AS
# MAGIC SELECT concept_id, concept_code, concept_name
# MAGIC FROM victr_sd.sd_omop_prod.concept
# MAGIC WHERE vocabulary_id = 'ICD9CM'
# MAGIC   AND (concept_code LIKE '250._1' OR concept_code LIKE '250._3');

# COMMAND ----------

# MAGIC %md
# MAGIC ## 3 · T2DM diagnosis codes Used in Algorithm 1
# MAGIC
# MAGIC | Description | ICD-9 code |
# MAGIC |---|---|
# MAGIC | Type 2 Diabetes |  250.x0, 250.x2 (excl. 250.10, 250.12) |

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE src_icd_t2dm AS
# MAGIC SELECT concept_id, concept_code, concept_name
# MAGIC FROM victr_sd.sd_omop_prod.concept
# MAGIC WHERE vocabulary_id = 'ICD9CM'
# MAGIC   AND (concept_code LIKE '250._0' OR concept_code LIKE '250._2')
# MAGIC   AND concept_code NOT IN ('250.10', '250.12');

# COMMAND ----------

# MAGIC %sql
# MAGIC -- Table 9: any DM-related diagnosis, used for the control exclusion only
# MAGIC CREATE OR REPLACE TABLE src_icd_dm AS
# MAGIC SELECT concept_id, concept_code, concept_name
# MAGIC FROM victr_sd.sd_omop_prod.concept
# MAGIC WHERE vocabulary_id = 'ICD9CM'
# MAGIC   AND ( concept_code = '250'
# MAGIC      OR concept_code LIKE '250.%'
# MAGIC      OR concept_code IN ('790.21','790.22','790.2','790.29','791.5','277.7','V18.0','V77.1')
# MAGIC      OR concept_code LIKE '648.8%'
# MAGIC      OR concept_code LIKE '648.0%' );
# MAGIC
# MAGIC

# COMMAND ----------

# MAGIC %md
# MAGIC ### Validation — wildcard expansion
# MAGIC  
# MAGIC Expected on a complete ICD9CM vocabulary: **20** T1DM codes (10 at `250._1`
# MAGIC plus 10 at `250._3`) and **18** T2DM codes (20 minus the two exclusions).
# MAGIC  
# MAGIC Record the DM-related count on first run. It is not a fixed number — it depends
# MAGIC on which four-digit parent codes the local vocabulary carries — but it should
# MAGIC not change afterwards unless the vocabulary is refreshed or the list is edited.
# MAGIC  
# MAGIC Inspect the code lists rather than only the counts. A silent `%`-for-`_`
# MAGIC substitution shows up as four-character codes in the output.

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT 't1dm' AS code_set, COUNT(*) AS n, sort_array(collect_set(concept_code)) AS codes FROM src_icd_t1dm
# MAGIC UNION ALL
# MAGIC SELECT 't2dm', COUNT(*), sort_array(collect_set(concept_code)) FROM src_icd_t2dm
# MAGIC UNION ALL
# MAGIC SELECT 'dm_related', COUNT(*), sort_array(collect_set(concept_code)) FROM src_icd_dm;

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE dd_dxT1dm AS
# MAGIC SELECT concept_id AS code FROM src_icd_t1dm
# MAGIC UNION
# MAGIC SELECT cr.concept_id_2 FROM victr_sd.sd_omop_prod.concept_relationship cr
# MAGIC   JOIN src_icd_t1dm s ON s.concept_id = cr.concept_id_1
# MAGIC  WHERE cr.relationship_id = 'Maps to';

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE dd_dxT2dm AS
# MAGIC SELECT concept_id AS code FROM src_icd_t2dm
# MAGIC UNION
# MAGIC SELECT cr.concept_id_2 FROM victr_sd.sd_omop_prod.concept_relationship cr
# MAGIC   JOIN src_icd_t2dm s ON s.concept_id = cr.concept_id_1
# MAGIC  WHERE cr.relationship_id = 'Maps to';

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE dd_dxDm AS
# MAGIC SELECT concept_id AS code FROM src_icd_dm
# MAGIC UNION
# MAGIC SELECT cr.concept_id_2 FROM victr_sd.sd_omop_prod.concept_relationship cr
# MAGIC   JOIN src_icd_dm s ON s.concept_id = cr.concept_id_1
# MAGIC  WHERE cr.relationship_id = 'Maps to';

# COMMAND ----------

# MAGIC %md
# MAGIC ### Validation — mapping coverage
# MAGIC  
# MAGIC Any source concept with no `Maps to` row contributes only itself, which means
# MAGIC its ICD-10-era equivalents are unreachable. A handful is normal; a large number
# MAGIC means the vocabulary tables are incomplete on this instance.
# MAGIC  

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT 't1dm' AS code_set, COUNT(*) AS n_unmapped FROM src_icd_t1dm s
# MAGIC  WHERE NOT EXISTS (SELECT 1 FROM victr_sd.sd_omop_prod.concept_relationship cr
# MAGIC                     WHERE cr.concept_id_1 = s.concept_id AND cr.relationship_id = 'Maps to')
# MAGIC UNION ALL
# MAGIC SELECT 't2dm', COUNT(*) FROM src_icd_t2dm s
# MAGIC  WHERE NOT EXISTS (SELECT 1 FROM victr_sd.sd_omop_prod.concept_relationship cr
# MAGIC                     WHERE cr.concept_id_1 = s.concept_id AND cr.relationship_id = 'Maps to')
# MAGIC UNION ALL
# MAGIC SELECT 'dm_related', COUNT(*) FROM src_icd_dm s
# MAGIC  WHERE NOT EXISTS (SELECT 1 FROM victr_sd.sd_omop_prod.concept_relationship cr
# MAGIC                     WHERE cr.concept_id_1 = s.concept_id AND cr.relationship_id = 'Maps to');

# COMMAND ----------

# MAGIC %md
# MAGIC ## 4 · T1DM medications. Used in Algorithm 1 and Algorithm 8.
# MAGIC
# MAGIC | Generic Name | Example Brand | RxNorm CUI (ingredient-level) |
# MAGIC |---|---|---|
# MAGIC | insulin | |  139825, 274783, 314684, 352385, 400008, 51428, 5856, 86009 |
# MAGIC |pramlintide | Symlin | 139953 |

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE src_rx_t1dm AS
# MAGIC SELECT concept_id, concept_code, concept_name
# MAGIC FROM victr_sd.sd_omop_prod.concept
# MAGIC WHERE vocabulary_id = 'RxNorm'
# MAGIC   AND concept_code IN ('139825','274783','314684','352385','400008',
# MAGIC                        '51428','5856','86009','139953');

# COMMAND ----------

# MAGIC %sql
# MAGIC -- Table 6: T2DM medications
# MAGIC CREATE OR REPLACE TABLE src_rx_t2dm AS
# MAGIC SELECT concept_id, concept_code, concept_name
# MAGIC FROM victr_sd.sd_omop_prod.concept
# MAGIC WHERE vocabulary_id = 'RxNorm'
# MAGIC   AND concept_code IN ('173','10633','2404','4821','217360','4815','25789',
# MAGIC                        '73044','274332','6809','84108','33738','72610',
# MAGIC                        '16681','30009','593411','60548');

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE dd_rxT1dm AS
# MAGIC SELECT concept_id AS code FROM src_rx_t1dm
# MAGIC UNION
# MAGIC SELECT ca.descendant_concept_id FROM victr_sd.sd_omop_prod.concept_ancestor ca
# MAGIC   JOIN src_rx_t1dm s ON s.concept_id = ca.ancestor_concept_id;

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE dd_rxT2dm AS
# MAGIC SELECT concept_id AS code FROM src_rx_t2dm
# MAGIC UNION
# MAGIC SELECT ca.descendant_concept_id FROM victr_sd.sd_omop_prod.concept_ancestor ca
# MAGIC   JOIN src_rx_t2dm s ON s.concept_id = ca.ancestor_concept_id;

# COMMAND ----------

# MAGIC %md
# MAGIC ### Validation — every listed CUI resolved
# MAGIC  

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT 't1dm_rx' AS code_set, COUNT(*) AS n_resolved, 9  AS n_expected FROM src_rx_t1dm
# MAGIC UNION ALL
# MAGIC SELECT 't2dm_rx', COUNT(*), 17 FROM src_rx_t2dm;

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT 't1dm_rx' AS code_set, concept_code, concept_name FROM src_rx_t1dm
# MAGIC UNION ALL
# MAGIC SELECT 't2dm_rx', concept_code, concept_name FROM src_rx_t2dm
# MAGIC ORDER BY code_set, concept_code;
# MAGIC  

# COMMAND ----------

# MAGIC %md
# MAGIC ## 5 · Diabetes supply concept set

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE src_rx_supply AS
# MAGIC SELECT concept_id, concept_code, concept_name, vocabulary_id
# MAGIC FROM victr_sd.sd_omop_prod.concept
# MAGIC WHERE (vocabulary_id = 'RxNorm' AND concept_code IN (
# MAGIC          '847187','847191','847197','847203','847207','847211','847230',
# MAGIC          '847239','847252','847256','847259','847263','847278','847416','847417'))
# MAGIC    OR (vocabulary_id = 'NDDF'   AND concept_code IN (
# MAGIC          '126958','412956','412959','637321','668291','668370','686655',
# MAGIC          '692383','748611','880998','881056','806905','806903','408119'))
# MAGIC    OR (vocabulary_id = 'VANDF'  AND concept_code IN ('751128'));

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE dd_rxSupply AS
# MAGIC SELECT concept_id AS code FROM src_rx_supply
# MAGIC UNION
# MAGIC SELECT ca.descendant_concept_id FROM victr_sd.sd_omop_prod.concept_ancestor ca
# MAGIC   JOIN src_rx_supply s ON s.concept_id = ca.ancestor_concept_id;

# COMMAND ----------

# MAGIC %md
# MAGIC ### Validation — supply resolution by vocabulary

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT vocabulary_id, COUNT(*) AS n_resolved
# MAGIC FROM src_rx_supply GROUP BY vocabulary_id ORDER BY vocabulary_id;

# COMMAND ----------

# MAGIC %md
# MAGIC ### Where do supplies appear on SD?

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT 'drug_exposure' AS src_table, COUNT(*) AS n_rows
# MAGIC FROM victr_sd.sd_omop_prod.drug_exposure
# MAGIC WHERE drug_concept_id        IN (SELECT code FROM dd_rxSupply)
# MAGIC    OR drug_source_concept_id IN (SELECT code FROM dd_rxSupply)
# MAGIC UNION ALL
# MAGIC SELECT 'device_exposure', COUNT(*)
# MAGIC FROM victr_sd.sd_omop_prod.device_exposure
# MAGIC WHERE device_concept_id        IN (SELECT code FROM dd_rxSupply)
# MAGIC    OR device_source_concept_id IN (SELECT code FROM dd_rxSupply);

# COMMAND ----------

# MAGIC %md
# MAGIC ## 6 · LOINC laboratory concept sets

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE src_loinc_fast AS
# MAGIC SELECT concept_id, concept_code, concept_name FROM victr_sd.sd_omop_prod.concept
# MAGIC WHERE vocabulary_id = 'LOINC' AND concept_code IN ('1558-6');

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE src_loinc_random AS
# MAGIC SELECT concept_id, concept_code, concept_name FROM victr_sd.sd_omop_prod.concept
# MAGIC WHERE vocabulary_id = 'LOINC' AND concept_code IN ('2339-0','2345-7');

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE src_loinc_a1c AS
# MAGIC SELECT concept_id, concept_code, concept_name FROM victr_sd.sd_omop_prod.concept
# MAGIC WHERE vocabulary_id = 'LOINC' AND concept_code IN ('4548-4','17856-6','4549-2','17855-8');

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE dd_fastGlucose AS
# MAGIC SELECT concept_id AS code FROM src_loinc_fast
# MAGIC UNION
# MAGIC SELECT cr.concept_id_2 FROM victr_sd.sd_omop_prod.concept_relationship cr
# MAGIC   JOIN src_loinc_fast s ON s.concept_id = cr.concept_id_1
# MAGIC  WHERE cr.relationship_id = 'Maps to';

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE dd_randomGlucose AS
# MAGIC SELECT concept_id AS code FROM src_loinc_random
# MAGIC UNION
# MAGIC SELECT cr.concept_id_2 FROM victr_sd.sd_omop_prod.concept_relationship cr
# MAGIC   JOIN src_loinc_random s ON s.concept_id = cr.concept_id_1
# MAGIC  WHERE cr.relationship_id = 'Maps to';

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE dd_hA1C AS
# MAGIC SELECT concept_id AS code FROM src_loinc_a1c
# MAGIC UNION
# MAGIC SELECT cr.concept_id_2 FROM victr_sd.sd_omop_prod.concept_relationship cr
# MAGIC   JOIN src_loinc_a1c s ON s.concept_id = cr.concept_id_1
# MAGIC  WHERE cr.relationship_id = 'Maps to';

# COMMAND ----------

# MAGIC %md
# MAGIC ### Units — the check the document does not specify and the algorithm needs

# COMMAND ----------

# MAGIC %sql
# MAGIC WITH lab AS (
# MAGIC   SELECT 'fasting_glucose' AS analyte, m.unit_concept_id, m.value_as_number
# MAGIC     FROM victr_sd.sd_omop_prod.measurement m
# MAGIC    WHERE m.measurement_concept_id IN (SELECT code FROM dd_fastGlucose)
# MAGIC       OR m.measurement_source_concept_id IN (SELECT code FROM dd_fastGlucose)
# MAGIC   UNION ALL
# MAGIC   SELECT 'random_glucose', m.unit_concept_id, m.value_as_number
# MAGIC     FROM victr_sd.sd_omop_prod.measurement m
# MAGIC    WHERE m.measurement_concept_id IN (SELECT code FROM dd_randomGlucose)
# MAGIC       OR m.measurement_source_concept_id IN (SELECT code FROM dd_randomGlucose)
# MAGIC   UNION ALL
# MAGIC   SELECT 'hba1c', m.unit_concept_id, m.value_as_number
# MAGIC     FROM victr_sd.sd_omop_prod.measurement m
# MAGIC    WHERE m.measurement_concept_id IN (SELECT code FROM dd_hA1C)
# MAGIC       OR m.measurement_source_concept_id IN (SELECT code FROM dd_hA1C)
# MAGIC )
# MAGIC SELECT lab.analyte,
# MAGIC        lab.unit_concept_id,
# MAGIC        c.concept_name AS unit_name,
# MAGIC        COUNT(*) AS n_rows,
# MAGIC        ROUND(percentile_approx(lab.value_as_number, 0.50), 2) AS p50,
# MAGIC        ROUND(percentile_approx(lab.value_as_number, 0.99), 2) AS p99,
# MAGIC        ROUND(100.0 * SUM(CASE WHEN lab.value_as_number IS NULL THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_null
# MAGIC FROM lab
# MAGIC LEFT JOIN victr_sd.sd_omop_prod.concept c ON c.concept_id = lab.unit_concept_id
# MAGIC GROUP BY lab.analyte, lab.unit_concept_id, c.concept_name
# MAGIC ORDER BY lab.analyte, n_rows DESC;

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE fam_hist_dm_terms AS
# MAGIC SELECT * FROM VALUES
# MAGIC   ('diabetes'),
# MAGIC   ('diabetes type i'),
# MAGIC   ('diabetes type ii')
# MAGIC AS t(hx_name_lower);