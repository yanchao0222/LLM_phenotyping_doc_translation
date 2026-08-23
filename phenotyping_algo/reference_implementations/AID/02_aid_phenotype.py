# Databricks notebook source
# MAGIC %md
# MAGIC ## AID Phenotype — Case, Control, and Unknown Cohorts
# MAGIC
# MAGIC | | |
# MAGIC |---|---|
# MAGIC | **Phenotype** | Autoimmune Disease (AID) |
# MAGIC | **Source algorithm** | eMERGE Autoimmune Disease Algorithm V4.0 (July 2017) |
# MAGIC | **Source location** | https://phekb.org/phenotype/755 |
# MAGIC | **Source authors** | Tong, Kiryluk, Petukhova, Wang, Lebwohl, Gharavi, Weng, Hripcsak (Columbia University) |
# MAGIC | **Developer(s)** | Srushti Gangireddy, Wu-Chen Su |
# MAGIC | **Date Created** | 2026-07-28 |
# MAGIC | **Last Modified** | 2026-08-22 |
# MAGIC | **Platform** | Databricks SQL / OMOP CDM |
# MAGIC | **Prerequisite** | Run `01_aid_setup` first |
# MAGIC | **Output** | `workspace_sdphenotypecore.aid.aid_phenotype` |
# MAGIC
# MAGIC ## Algorithm
# MAGIC
# MAGIC A phenotype over 51 autoimmune diseases in 9 organ-system
# MAGIC groups. A person is evaluated **once per disease**, then rolled up.
# MAGIC
# MAGIC **CASE** — qualifies for at least one of the 51 diseases. A disease
# MAGIC qualifies when the person has:
# MAGIC
# MAGIC 1. `>= 3` diagnosis codes for that disease on **distinct days**, and
# MAGIC 2. first and last of those codes `>= 7` days apart.
# MAGIC
# MAGIC Type 1 diabetes (subphenotype 15) carries one extra condition: the
# MAGIC person must have **no** T2DM code. This is scoped to T1D alone — it
# MAGIC does not affect the person's other diseases.
# MAGIC
# MAGIC **CONTROL** — not a case for any disease, **and** carries no code from
# MAGIC the auto-inflammatory/autoimmune exclusion list, **and** has no positive
# MAGIC serology.
# MAGIC
# MAGIC **UNKNOWN** — everyone else. In practice: people who carry exclusion
# MAGIC codes or positive serology without meeting a case definition, i.e. the
# MAGIC "cannot confidently call either way" band.
# MAGIC
# MAGIC The three gates are evaluated in that order, so case status wins over
# MAGIC any exclusion.
# MAGIC
# MAGIC ## Mapping to the source document
# MAGIC
# MAGIC | Source | Implemented as |
# MAGIC |---|---|
# MAGIC | Case Cohort Condition A (§III.i) | `disease_qual` — 3 codes, distinct days, 7-day span |
# MAGIC | T1DM extra criterion (§III.i) | `subphenotype` — anti-join scoped to subphenotype 15 |
# MAGIC | Control Cohort Condition A (§III.ii) | `control_dx` |
# MAGIC | Control Cohort Condition B (§III.ii) | `serology_pos` |
# MAGIC | `Case_Control_Unknown_Status` (§V) | output column of the same name |
# MAGIC
# MAGIC ## Limitation
# MAGIC
# MAGIC **Serology positivity** — Control Cohort Condition B defers to
# MAGIC    institutional and assay recommendations and supplies no cutoffs.
# MAGIC    Implemented as: coded
# MAGIC    positive result, or positive/reactive free text, or a numeric value
# MAGIC    above the measurement's own `range_high`
# MAGIC
# MAGIC ## Citation
# MAGIC
# MAGIC Maurine Tong, Krzysztof Kiryluk, Lynn Petukhova, Runsheng (Bridget) Wang, Benjamin Lebwohl, Ali G. Gharavi, Chunhua Weng, and George M. Hripcsak. *Autoimmune Disease Phenotype*. Columbia University. PheKB; 2017. Available from: [https://phekb.org/phenotype/755](https://phekb.org/phenotype/755)

# COMMAND ----------

# MAGIC %md
# MAGIC #### Algorithm Workflow:
# MAGIC
# MAGIC ![image_1784926503122.png](./image_1784926503122.png "image_1784926503122.png")
# MAGIC
# MAGIC **Source:** [PheKB Autoimmune Disease Algorithm, Version 4.0](https://phekb.org/sites/phenotype/files/AutoimmuneDiseaseAlgorithm_V4_0.pdf)

# COMMAND ----------

# MAGIC %md
# MAGIC ## 1. Target schema
# MAGIC
# MAGIC Site-specific. Must match notebook 01.

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE SCHEMA IF NOT EXISTS workspace_sdphenotypecore.aid;
# MAGIC USE workspace_sdphenotypecore.aid;

# COMMAND ----------

# MAGIC %md
# MAGIC ## 2. Build `aid_phenotype`
# MAGIC

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE workspace_sdphenotypecore.aid.aid_phenotype AS
# MAGIC WITH
# MAGIC concepts AS (
# MAGIC   SELECT DISTINCT code_role, variable_name, subphenotype_num, group_name, disease_name, concept_id
# MAGIC   FROM workspace_sdphenotypecore.aid.aid_code_dict
# MAGIC   WHERE concept_id IS NOT NULL AND concept_id != 0
# MAGIC     AND code_role IN ('CASE_DISEASE','T2DM','CONTROL_DX')
# MAGIC ),
# MAGIC dx AS (
# MAGIC   SELECT DISTINCT
# MAGIC          co.person_id,
# MAGIC          co.condition_start_date AS dx_date,
# MAGIC          cs.code_role, cs.subphenotype_num, cs.group_name,
# MAGIC          cs.disease_name, cs.variable_name
# MAGIC   FROM victr_sd.sd_omop_prod.condition_occurrence co
# MAGIC   JOIN concepts cs
# MAGIC     ON cs.concept_id = co.condition_concept_id
# MAGIC     OR cs.concept_id = co.condition_source_concept_id
# MAGIC   WHERE co.condition_start_date IS NOT NULL
# MAGIC ),
# MAGIC disease_qual AS (
# MAGIC   SELECT person_id, subphenotype_num, group_name, disease_name, variable_name
# MAGIC   FROM dx
# MAGIC   WHERE code_role = 'CASE_DISEASE'
# MAGIC   GROUP BY 1,2,3,4,5
# MAGIC   HAVING count(DISTINCT dx_date) >= 3
# MAGIC      AND datediff(max(dx_date), min(dx_date)) >= 7
# MAGIC ),
# MAGIC
# MAGIC t2dm AS (
# MAGIC   SELECT DISTINCT person_id FROM dx WHERE code_role = 'T2DM'
# MAGIC ),
# MAGIC subphenotype AS (
# MAGIC   SELECT q.*
# MAGIC   FROM disease_qual q
# MAGIC   LEFT ANTI JOIN t2dm t
# MAGIC     ON t.person_id = q.person_id
# MAGIC    AND q.subphenotype_num = 15
# MAGIC ),
# MAGIC cases AS (
# MAGIC   SELECT person_id,
# MAGIC          count(*)                               AS n_subphenotypes,
# MAGIC          array_sort(collect_set(variable_name))  AS subphenotypes,
# MAGIC          array_sort(collect_set(group_name))     AS groups
# MAGIC   FROM subphenotype
# MAGIC   GROUP BY person_id
# MAGIC ),
# MAGIC
# MAGIC control_dx AS (
# MAGIC   SELECT DISTINCT person_id FROM dx WHERE code_role = 'CONTROL_DX'
# MAGIC ),
# MAGIC serology_pos AS (
# MAGIC   SELECT DISTINCT m.person_id
# MAGIC   FROM victr_sd.sd_omop_prod.measurement m
# MAGIC   JOIN workspace_sdphenotypecore.aid.aid_code_dict cs
# MAGIC     ON (cs.concept_id = m.measurement_concept_id
# MAGIC      OR cs.concept_id = m.measurement_source_concept_id)
# MAGIC    AND cs.code_role = 'SEROLOGY' AND cs.concept_id <> 0
# MAGIC   LEFT JOIN workspace_sdphenotypecore.aid.aid_serology_thresholds th
# MAGIC     ON th.test_key = cs.test_key
# MAGIC    AND (th.unit_source IS NULL OR th.unit_source = m.unit_source_value)
# MAGIC   WHERE m.value_as_concept_id IN (9191, 4126681, 4181412, 45884084, 4155142)
# MAGIC      OR ( lower(coalesce(m.value_source_value,'')) rlike '(^|[^a-z])(pos|positive|reactive|detected)([^a-z]|$)'
# MAGIC       AND NOT lower(coalesce(m.value_source_value,'')) rlike '(^|[^a-z])(neg|negative|nonreactive|non-reactive|not detected|indeterminate|equivocal)([^a-z]|$)' )
# MAGIC      OR ( m.value_as_number IS NOT NULL
# MAGIC           AND m.range_high IS NOT NULL
# MAGIC           AND m.value_as_number > m.range_high )
# MAGIC      OR ( m.value_as_number IS NOT NULL
# MAGIC           AND m.range_high IS NULL
# MAGIC           AND th.pos_min_value IS NOT NULL
# MAGIC           AND m.value_as_number >= th.pos_min_value )
# MAGIC )
# MAGIC SELECT p.person_id,
# MAGIC        CASE WHEN c.person_id  IS NOT NULL THEN 'CASE'
# MAGIC             WHEN cd.person_id IS NOT NULL THEN 'UNKNOWN'
# MAGIC             WHEN sp.person_id IS NOT NULL THEN 'UNKNOWN'
# MAGIC             ELSE 'CONTROL' END             AS case_control_unknown_status,
# MAGIC        coalesce(c.n_subphenotypes, 0)      AS n_subphenotypes,
# MAGIC        c.subphenotypes,
# MAGIC        c.groups
# MAGIC FROM victr_sd.sd_omop_prod.person p
# MAGIC LEFT JOIN cases        c  ON c.person_id  = p.person_id
# MAGIC LEFT JOIN control_dx   cd ON cd.person_id = p.person_id
# MAGIC LEFT JOIN serology_pos sp ON sp.person_id = p.person_id;

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT case_control_unknown_status AS status, count(*) AS n
# MAGIC FROM workspace_sdphenotypecore.aid.aid_phenotype
# MAGIC GROUP BY 1 ORDER BY 1;