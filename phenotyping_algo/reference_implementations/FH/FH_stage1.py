# Databricks notebook source
# MAGIC %md
# MAGIC # Familial Hypercholesterolemia (FH) — Stage I Phenotype
# MAGIC
# MAGIC | | |
# MAGIC |---|---|
# MAGIC | **Phenotype** | Familial Hypercholesterolemia — Stage I (primary hypercholesterolemia) |
# MAGIC | **Source location** | [Electronic Health Record-based Phenotyping Algorithm for Familial Hypercholesterolemia](https://phekb.org/phenotype/electronic-health-record-based-phenotyping-algorithm-familial-hypercholesterolemia) |
# MAGIC | **Algorithm workflow** | [View source documentation](https://phekb.org/sites/phenotype/files/FH_eAlgorithm_Flowcharts_2016_0.pdf) |
# MAGIC | **Implemented by** | Srushti Gangireddy, Wu-Chen Su |
# MAGIC | **Created** | 2026-08-01 |
# MAGIC | **Last modified** | 2026-08-22 |
# MAGIC | **Data source** | VUMC Synthetic Derivative, OMOP CDM v5 (`victr_sd.sd_omop_prod`) |
# MAGIC | **Output schema** | `workspace_sdphenotypecore.fh` |
# MAGIC | **Platform** | Databricks SQL |
# MAGIC | **Prerequisite** | Run `FH_reference_codes` first |
# MAGIC
# MAGIC ## Scope
# MAGIC
# MAGIC This notebook implements **Stage I only**, which assigns a case/control status for
# MAGIC **primary hypercholesterolemia**. That is one input to an FH determination, **not an FH
# MAGIC determination**. Any results table must say "primary hypercholesterolemia," not "FH."
# MAGIC
# MAGIC Stage II (Figure 3) scores the modified DLCN criteria. Two of its four groups are buildable
# MAGIC from structured data alone: **Group I** (LDL-C) and **Group II** (personal history of
# MAGIC premature ASCVD, via the Table 4 codes already loaded in `fh_ref_dx_codes`). **Group III**
# MAGIC (family history) and **Group IV** (physical examination — tendon xanthomas, early corneal
# MAGIC arcus) require the MedTagger Java NLP system ([ohnlp.org](http://ohnlp.org)).
# MAGIC
# MAGIC ## Phenotype definition
# MAGIC
# MAGIC Familial hypercholesterolemia is the most common Mendelian disorder, causing lifelong
# MAGIC elevation of LDL-C and sharply increased risk of premature atherosclerotic cardiovascular
# MAGIC disease. Fewer than 20% of cases are diagnosed in most countries. This algorithm exists to
# MAGIC identify candidates for genetic testing from routinely collected EHR data.
# MAGIC
# MAGIC ### Stage I logic (Figure 2)
# MAGIC
# MAGIC | Box | Action |
# MAGIC |---|---|
# MAGIC | 1 | Identify individuals ≥18 years old with a lipid profile |
# MAGIC | 2 | Extract all LDL-C and TG measurements |
# MAGIC | 3 | TG ≥500 mg/dL on ≥2 occurrences → **exclude** |
# MAGIC | 4 | Identify the date of the highest LDL-C — the **index date** |
# MAGIC | 5 | Extract associated age, gender, race, lipid profile |
# MAGIC | 6 | Secondary causes of hypercholesterolemia within 1 year prior to index → **exclude** |
# MAGIC | 7 | Extract lipid-lowering treatment 1 year to 6 weeks prior to index |
# MAGIC | 8 | If on treatment, pre-treatment LDL-C = index LDL-C ÷ 0.7 |
# MAGIC
# MAGIC ### Classification
# MAGIC
# MAGIC | Status | Evaluated LDL-C |
# MAGIC |---|---|
# MAGIC | **Case** | ≥ 155 mg/dL |
# MAGIC | **Control** | ≤ 130 mg/dL |
# MAGIC | **Unknown** | 131–154 mg/dL |
# MAGIC
# MAGIC ### Secondary causes (Table 2A)
# MAGIC
# MAGIC A condition is active when the abnormal value appears within 1 year before the index date.
# MAGIC
# MAGIC | Condition | Test | Threshold | Note |
# MAGIC |---|---|---|---|
# MAGIC | Hypothyroidism | TSH | ≥10 mIU/L | |
# MAGIC | Biliary obstruction | Alkaline phosphatase | ≥200 IU/L | |
# MAGIC | Liver disease | Total bilirubin | >2.0 mg/dL | |
# MAGIC | Nephrotic syndrome | 24-h urine protein | >3 g | |
# MAGIC | | Urine protein/creatinine ratio | >3.0 | |
# MAGIC | Renal failure | Creatinine | >2.6 mg/dL | |
# MAGIC | | eGFR | <15 mL/min/BSA | ⚠️ **zero rows — dead code** |
# MAGIC | Diabetes | HbA1c | >9% | |
# MAGIC | | Fasting glucose, capillary | >200 mg/dL | |
# MAGIC | | Fasting glucose, serum/plasma | >220 mg/dL | |
# MAGIC
# MAGIC ### Flags, not exclusions
# MAGIC
# MAGIC Page 3 introduces flagging "to increase flexibility of the system." Two criteria are
# MAGIC flagged rather than excluded: TG >220 mg/dL, and pregnancy with LDL-C ≥155 mg/dL.
# MAGIC
# MAGIC ## Pipeline
# MAGIC
# MAGIC | Step | Table | What it does |
# MAGIC |---|---|---|
# MAGIC | 0a | `fh_loinc_concepts` | Resolve Tables 1 and 2A LOINC codes to OMOP concepts |
# MAGIC | 0b | `fh_llt_concepts` | Resolve Table 3A RxNorm codes, expand the drug hierarchy |
# MAGIC | 0c | `fh_person` | Demographics with a date-of-birth fallback |
# MAGIC | 1 | `fh_step1_cohort` | Adults with a lipid profile |
# MAGIC | 2 | `fh_step2_measurements` | All lipid measurements for the cohort |
# MAGIC | 3 | `fh_excl_tg`, `fh_step3_eligible`, `fh_flag_tg220` | TG ≥500 ×2 exclusion; TG >220 flag |
# MAGIC | 4 | `fh_step4_index` | Index date = highest LDL-C |
# MAGIC | 5 | `fh_step5_profile` | Demographics and index lipid panel |
# MAGIC | 6a | `fh_secondary_labs` | Laboratory secondary causes |
# MAGIC | 6b | `fh_pregnancy` | Pregnancy flag |
# MAGIC | 6c | `fh_step6_eligible` | Apply the secondary-cause exclusion |
# MAGIC | 7 | `fh_step7_llt` | Lipid-lowering treatment window |
# MAGIC | 8 | `fh_stage1` | Pre-treatment LDL-C and classification |
# MAGIC
# MAGIC Each step writes a table rather than nesting into one query. Spark does not materialize a
# MAGIC multiply-referenced CTE — it recomputes it — and `fh_step2_measurements` is read by boxes 3,
# MAGIC 4 and 5. The intermediates are materialization points, and they also make a disagreement
# MAGIC between two implementations diagnosable rather than merely visible.
# MAGIC
# MAGIC **Prerequisite.** `FH_reference_codes` must have run: `fh_ref_loinc` (60 rows),
# MAGIC `fh_ref_rxnorm` (35), `fh_ref_dx_codes` (160), `fh_ref_pregnancy` (5), all verified.
# MAGIC Reloading any of them invalidates every table below — re-run the whole chain.
# MAGIC
# MAGIC ## Known deviations from the source document
# MAGIC
# MAGIC | # | Issue | Resolution |
# MAGIC |---|---|---|
# MAGIC | 1 | **Pregnancy: flag or exclude?** p.3 says pregnant patients with LDL-C ≥155 "need to be flagged"; p.8 and Figure 2 group pregnancy under secondary causes → exclude | **Flag.** p.3 states the intent explicitly. Pregnancy reaches `fh_stage1` as `flag_pregnancy` |
# MAGIC | 2 | **Pregnancy: how many codes?** PDF requires ICD-9 codes with no count; the Content spreadsheet requires ≥2 on different days | **≥1**, per the PDF. `n_preg_days` is carried through so the stricter reading is a `WHERE` clause, not a rerun |
# MAGIC | 3 | **Pregnancy is ICD-9 only** (Table 2B) | As specified. Post-2015 ICD-10-coded pregnancies are invisible; since the index date is the highest LDL-C and this database runs to the present, the criterion is largely inert on recent records |
# MAGIC | 4 | **`fh_secondary_labs` omits patients with no qualifying lab** | Correct table shape — absence of evidence is not evidence of a secondary cause. Consumers must `LEFT JOIN` and coalesce |
# MAGIC
# MAGIC ## Output dictionary — `fh_stage1`
# MAGIC
# MAGIC | Column | Meaning |
# MAGIC |---|---|
# MAGIC | `person_id` | OMOP person identifier |
# MAGIC | `index_date`, `index_age` | Date of the highest LDL-C, and age then |
# MAGIC | `gender`, `race`, `ethnicity` | Demographics (Figure 2 box 5) |
# MAGIC | `index_ldl`, `index_tc`, `index_hdl`, `index_tg` | Lipid panel on the index date |
# MAGIC | `on_llt` | Lipid-lowering treatment in the window |
# MAGIC | `date_llt_prescribed`, `time_delta_months` | Most recent LLT date and its distance from index |
# MAGIC | `eval_ldl` | `index_ldl ÷ 0.7` if on treatment, else `index_ldl`. Never 0 |
# MAGIC | `flag_pregnancy` | Pregnant with LDL-C ≥155 (deviation 1) |
# MAGIC | `n_preg_days` | Distinct coded pregnancy days (deviation 2) |
# MAGIC | `flag_tg_gt220` | TG >220 mg/dL at any point |
# MAGIC | `case_control_pchl` | `CASE` / `CONTROL` / `UNKNOWN` |
# MAGIC
# MAGIC Excluded patients are **absent**, not labelled.
# MAGIC
# MAGIC ## Limitations
# MAGIC
# MAGIC - **Stage I is not FH.** See Scope.
# MAGIC
# MAGIC ## Citation
# MAGIC
# MAGIC PheKB's suggested citation:
# MAGIC
# MAGIC > Safarova MS, Liu H, Arruda-Olson A, Rastegar M, Smith C, Cheng Y, Fan X, Balachandran P,
# MAGIC > Sohn S, Kullo IJ. Mayo Clinic. Electronic Health Record-based Phenotyping Algorithm for
# MAGIC > Familial Hypercholesterolemia. PheKB; 2016. Available from:
# MAGIC > https://phekb.org/phenotype/602

# COMMAND ----------

# MAGIC %md
# MAGIC ## 1 · Working schema
# MAGIC
# MAGIC All phenotype tables are written to `workspace_sdphenotypecore.fh`. The
# MAGIC source OMOP CDM is read-only and is always referenced by its fully-qualified
# MAGIC name.

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE SCHEMA IF NOT EXISTS workspace_sdphenotypecore.fh;
# MAGIC USE workspace_sdphenotypecore.fh;

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 0a · Lipid and secondary-cause measurement concepts
# MAGIC
# MAGIC Resolves each LOINC code in `fh_ref_loinc` to (a) its own `concept_id` and (b) the target of
# MAGIC any valid `Maps to` relationship, so non-standard LOINC concepts still reach their standard
# MAGIC equivalent.
# MAGIC
# MAGIC **Output:** `fh_loinc_concepts` (role, test_key, concept_id)

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE workspace_sdphenotypecore.fh.fh_loinc_concepts AS
# MAGIC
# MAGIC SELECT DISTINCT r.role, r.test_key, c.concept_id
# MAGIC FROM workspace_sdphenotypecore.fh.fh_ref_loinc r
# MAGIC JOIN victr_sd.sd_omop_prod.concept c
# MAGIC   ON c.vocabulary_id = 'LOINC' AND c.concept_code = r.loinc
# MAGIC
# MAGIC UNION
# MAGIC
# MAGIC SELECT DISTINCT r.role, r.test_key, cr.concept_id_2
# MAGIC FROM workspace_sdphenotypecore.fh.fh_ref_loinc r
# MAGIC JOIN victr_sd.sd_omop_prod.concept c
# MAGIC   ON c.vocabulary_id = 'LOINC' AND c.concept_code = r.loinc
# MAGIC JOIN victr_sd.sd_omop_prod.concept_relationship cr
# MAGIC   ON cr.concept_id_1 = c.concept_id AND cr.relationship_id = 'Maps to'
# MAGIC  AND cr.invalid_reason IS NULL;   

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 0b · Lipid-lowering treatment concepts
# MAGIC
# MAGIC Expands the Table 3A RxNorm ingredient codes down the `concept_ancestor` hierarchy to every
# MAGIC drug product, then unions the seeds back in.
# MAGIC

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE workspace_sdphenotypecore.fh.fh_llt_concepts AS
# MAGIC
# MAGIC WITH seeds AS (
# MAGIC     SELECT DISTINCT
# MAGIC         c.concept_id
# MAGIC     FROM workspace_sdphenotypecore.fh.fh_ref_rxnorm r
# MAGIC     JOIN victr_sd.sd_omop_prod.concept c
# MAGIC       ON c.vocabulary_id = 'RxNorm'
# MAGIC      AND c.concept_code = r.rxnorm
# MAGIC     WHERE r.role = 'LLT'
# MAGIC ),
# MAGIC
# MAGIC expanded AS (
# MAGIC     SELECT concept_id
# MAGIC     FROM seeds
# MAGIC
# MAGIC     UNION
# MAGIC
# MAGIC     SELECT ca.descendant_concept_id AS concept_id
# MAGIC     FROM seeds s
# MAGIC     JOIN victr_sd.sd_omop_prod.concept_ancestor ca
# MAGIC       ON ca.ancestor_concept_id = s.concept_id
# MAGIC )
# MAGIC
# MAGIC SELECT DISTINCT concept_id
# MAGIC FROM expanded;

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 0c · Demographics
# MAGIC
# MAGIC Figure 2 box 1 assesses everyone aged 18 or over; box 5 requires gender, race and ethnicity
# MAGIC in the extracted profile.
# MAGIC

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE workspace_sdphenotypecore.fh.fh_person AS
# MAGIC SELECT
# MAGIC   p.person_id,
# MAGIC   coalesce(to_date(p.birth_datetime),
# MAGIC            make_date(p.year_of_birth, coalesce(p.month_of_birth, 7),
# MAGIC                                       coalesce(p.day_of_birth, 1))) AS dob,
# MAGIC   g.concept_name AS gender,
# MAGIC   r.concept_name AS race,
# MAGIC   e.concept_name AS ethnicity
# MAGIC FROM victr_sd.sd_omop_prod.person p
# MAGIC LEFT JOIN victr_sd.sd_omop_prod.concept g ON g.concept_id = p.gender_concept_id
# MAGIC LEFT JOIN victr_sd.sd_omop_prod.concept r ON r.concept_id = p.race_concept_id
# MAGIC LEFT JOIN victr_sd.sd_omop_prod.concept e ON e.concept_id = p.ethnicity_concept_id;

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 1 · Individuals ≥18 with a lipid profile (Figure 2, box 1)
# MAGIC
# MAGIC Age is evaluated at the date of each measurement, not at a fixed reference date: a person
# MAGIC qualifies if they had **any** lipid result on or after their 18th birthday.
# MAGIC
# MAGIC **Output:** `fh_step1_cohort` (person_id)

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE workspace_sdphenotypecore.fh.fh_step1_cohort AS
# MAGIC SELECT DISTINCT m.person_id
# MAGIC FROM victr_sd.sd_omop_prod.measurement m
# MAGIC JOIN workspace_sdphenotypecore.fh.fh_loinc_concepts lc
# MAGIC   ON (lc.concept_id = m.measurement_concept_id OR lc.concept_id = m.measurement_source_concept_id)
# MAGIC  AND lc.role = 'LIPID'
# MAGIC JOIN workspace_sdphenotypecore.fh.fh_person p ON p.person_id = m.person_id
# MAGIC WHERE m.value_as_number IS NOT NULL
# MAGIC   AND p.dob IS NOT NULL
# MAGIC   AND datediff(m.measurement_date, p.dob) / 365.25 >= 18;

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 2 · All lipid measurements (Figure 2, box 2)

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE workspace_sdphenotypecore.fh.fh_step2_measurements AS
# MAGIC SELECT DISTINCT
# MAGIC   m.person_id, m.measurement_date, lc.test_key,
# MAGIC   m.value_as_number, m.unit_source_value,
# MAGIC   floor(datediff(m.measurement_date, p.dob) / 365.25) AS age_at_meas
# MAGIC FROM victr_sd.sd_omop_prod.measurement m
# MAGIC JOIN workspace_sdphenotypecore.fh.fh_step1_cohort ch ON ch.person_id = m.person_id
# MAGIC JOIN workspace_sdphenotypecore.fh.fh_loinc_concepts lc
# MAGIC   ON (lc.concept_id = m.measurement_concept_id OR lc.concept_id = m.measurement_source_concept_id)
# MAGIC  AND lc.role = 'LIPID'
# MAGIC JOIN workspace_sdphenotypecore.fh.fh_person p ON p.person_id = m.person_id
# MAGIC WHERE m.value_as_number IS NOT NULL
# MAGIC   AND datediff(m.measurement_date, p.dob) / 365.25 >= 18;

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 3 · Triglyceride exclusion and flag (Figure 2, box 3)
# MAGIC
# MAGIC **Exclusion:** TG ≥500 mg/dL on two or more occasions. Occasions are counted as distinct
# MAGIC measurement *dates*, so two results on the same day are one occasion.
# MAGIC
# MAGIC **Flag:** TG >220 mg/dL (p.3). These patients remain in Stage I and are classified normally.
# MAGIC The document gives no time window, so this looks across the patient's entire measurement.
# MAGIC

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE workspace_sdphenotypecore.fh.fh_excl_tg AS
# MAGIC SELECT person_id
# MAGIC FROM workspace_sdphenotypecore.fh.fh_step2_measurements
# MAGIC WHERE test_key = 'TG' AND value_as_number >= 500
# MAGIC GROUP BY person_id
# MAGIC HAVING count(DISTINCT measurement_date) >= 2;

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE workspace_sdphenotypecore.fh.fh_step3_eligible AS
# MAGIC SELECT ch.person_id
# MAGIC FROM workspace_sdphenotypecore.fh.fh_step1_cohort ch
# MAGIC LEFT JOIN workspace_sdphenotypecore.fh.fh_excl_tg x ON x.person_id = ch.person_id
# MAGIC WHERE x.person_id IS NULL;

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE workspace_sdphenotypecore.fh.fh_flag_tg220 AS
# MAGIC SELECT DISTINCT person_id
# MAGIC FROM workspace_sdphenotypecore.fh.fh_step2_measurements
# MAGIC WHERE test_key = 'TG' AND value_as_number > 220;

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 4 · Index date (Figure 2, box 4)
# MAGIC
# MAGIC The index date is the date of the **highest** LDL-C. Ties on value are broken by the earliest
# MAGIC date.
# MAGIC
# MAGIC Patients who reach box 3 with lipid results but no LDL result specifically drop out here and
# MAGIC receive no index date

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE workspace_sdphenotypecore.fh.fh_step4_index AS
# MAGIC WITH ranked AS (
# MAGIC   SELECT m.person_id, m.measurement_date AS index_date,
# MAGIC          m.value_as_number AS index_ldl, m.age_at_meas AS index_age,
# MAGIC          row_number() OVER (PARTITION BY m.person_id
# MAGIC                             ORDER BY m.value_as_number DESC, m.measurement_date ASC) AS rn
# MAGIC   FROM workspace_sdphenotypecore.fh.fh_step2_measurements m
# MAGIC   JOIN workspace_sdphenotypecore.fh.fh_step3_eligible e ON e.person_id = m.person_id
# MAGIC   WHERE m.test_key = 'LDL'
# MAGIC )
# MAGIC SELECT person_id, index_date, index_ldl, index_age
# MAGIC FROM ranked WHERE rn = 1;

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 5 · Demographics and index lipid panel (Figure 2, box 5)
# MAGIC
# MAGIC TC, HDL and TG are taken from the **same day** as the index LDL-C, via a `LEFT JOIN` so a
# MAGIC patient with an isolated LDL result still appears, with nulls in the other three columns.

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE workspace_sdphenotypecore.fh.fh_step5_profile AS
# MAGIC SELECT
# MAGIC   i.person_id, i.index_date, i.index_age,
# MAGIC   p.gender, p.race, p.ethnicity,
# MAGIC   i.index_ldl,
# MAGIC   max(CASE WHEN m.test_key = 'TC'  THEN m.value_as_number END) AS index_tc,
# MAGIC   max(CASE WHEN m.test_key = 'HDL' THEN m.value_as_number END) AS index_hdl,
# MAGIC   max(CASE WHEN m.test_key = 'TG'  THEN m.value_as_number END) AS index_tg
# MAGIC FROM workspace_sdphenotypecore.fh.fh_step4_index i
# MAGIC JOIN workspace_sdphenotypecore.fh.fh_person p ON p.person_id = i.person_id
# MAGIC LEFT JOIN workspace_sdphenotypecore.fh.fh_step2_measurements m
# MAGIC   ON m.person_id = i.person_id AND m.measurement_date = i.index_date
# MAGIC  AND m.test_key IN ('TC','HDL','TG')
# MAGIC GROUP BY 1,2,3,4,5,6,7;

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 6a · Laboratory secondary causes (Figure 2, box 6)
# MAGIC
# MAGIC Flags each laboratory-ascertainable secondary cause present in the year before the index
# MAGIC date. Thresholds are Table 2A, reproduced exactly — including the mix of `>=` and `>`, which
# MAGIC is the document's and not a transcription slip.
# MAGIC
# MAGIC > **Output shape:** one row per patient **with at least one qualifying lab**. Patients with
# MAGIC > none are **absent, not zero**; consumers must `LEFT JOIN` and coalesce (deviation 10).
# MAGIC
# MAGIC ### Unit handling
# MAGIC
# MAGIC | `test_key` | Accepted `unit_source_value` (lowercased, trimmed) | Conversion |
# MAGIC |---|---|---|
# MAGIC | `ALP` | (any) — justified, see below | none |
# MAGIC | `CREAT` | `mg/dl` | none |
# MAGIC | | `umol/l` | ÷ 88.4 |
# MAGIC | `GLUCOSE_VEN` / `GLUCOSE_CAP` | `mg/dl` | none |
# MAGIC | `HBA1C` | `%` | none |
# MAGIC | `TBIL` | `mg/dl` | none |
# MAGIC | | `umol/l` | ÷ 17.1 |
# MAGIC | `UPCR` | `g/g` | none |
# MAGIC | | `mg/g cr`, `mg/g creat` | ÷ 1000 |
# MAGIC | `URINE_PROT_24H` | `mg/day` | ÷ 1000 |
# MAGIC | `TSH` | `uiu/ml`, `miu/l` | none |
# MAGIC | `EGFR` | (any) — moot, no rows exist | none |
# MAGIC
# MAGIC ### Two verified points
# MAGIC
# MAGIC **ALP needs no unit filter.** Confirmed 2026-08-05: a single concept (3035995, total ALP)
# MAGIC carries all 8,683,450 rows with p50 = 84, consistent with U/L. The Table 2A isoenzyme code
# MAGIC `12805-8` has zero rows, so the scale-mismatch risk does not arise.
# MAGIC
# MAGIC **`CREAT` code `14682-9` is molar, not mass.** It resolves as Creatinine [Moles/volume] —
# MAGIC µmol/L — although Table 2A describes it as "Mass/volume." The source document mislabels it.
# MAGIC The `umol/l` branch handles it where units are populated; a blank unit on a molar result
# MAGIC falls to NULL and under-excludes.

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE workspace_sdphenotypecore.fh.fh_secondary_labs AS
# MAGIC
# MAGIC WITH labs_raw AS (
# MAGIC     SELECT DISTINCT
# MAGIC         i.person_id,
# MAGIC         m.measurement_id,
# MAGIC         m.measurement_date,
# MAGIC         lc.test_key,
# MAGIC         m.value_as_number AS raw_value,
# MAGIC         m.unit_source_value,
# MAGIC         m.unit_concept_id,                                    
# MAGIC         lower(trim(coalesce(m.unit_source_value, ''))) AS unit_norm
# MAGIC
# MAGIC     FROM workspace_sdphenotypecore.fh.fh_step4_index i
# MAGIC
# MAGIC     JOIN victr_sd.sd_omop_prod.measurement m
# MAGIC         ON m.person_id = i.person_id
# MAGIC
# MAGIC     JOIN workspace_sdphenotypecore.fh.fh_loinc_concepts lc
# MAGIC         ON (
# MAGIC                lc.concept_id = m.measurement_concept_id
# MAGIC             OR lc.concept_id = m.measurement_source_concept_id
# MAGIC            )
# MAGIC        AND lc.role = 'SECONDARY'
# MAGIC
# MAGIC     WHERE m.value_as_number IS NOT NULL
# MAGIC       AND m.measurement_date
# MAGIC           BETWEEN add_months(i.index_date, -12)
# MAGIC               AND i.index_date
# MAGIC ),
# MAGIC labs AS (
# MAGIC     SELECT
# MAGIC         person_id,
# MAGIC         measurement_id,
# MAGIC         measurement_date,
# MAGIC         test_key,
# MAGIC         raw_value,
# MAGIC         unit_source_value,
# MAGIC         unit_concept_id,
# MAGIC
# MAGIC         CASE
# MAGIC             WHEN test_key = 'ALP'
# MAGIC             THEN raw_value
# MAGIC
# MAGIC             WHEN test_key = 'CREAT'
# MAGIC              AND unit_norm = 'mg/dl'
# MAGIC             THEN raw_value
# MAGIC
# MAGIC             WHEN test_key = 'CREAT'
# MAGIC              AND unit_norm = 'umol/l'
# MAGIC             THEN raw_value / 88.4
# MAGIC
# MAGIC             WHEN test_key IN ('GLUCOSE_VEN', 'GLUCOSE_CAP')
# MAGIC              AND unit_norm = 'mg/dl'
# MAGIC             THEN raw_value
# MAGIC
# MAGIC             WHEN test_key = 'HBA1C'
# MAGIC              AND unit_norm = '%'
# MAGIC             THEN raw_value
# MAGIC
# MAGIC             WHEN test_key = 'TBIL'
# MAGIC              AND unit_norm = 'mg/dl'
# MAGIC             THEN raw_value
# MAGIC
# MAGIC             WHEN test_key = 'TBIL'
# MAGIC              AND unit_norm = 'umol/l'
# MAGIC             THEN raw_value / 17.1
# MAGIC
# MAGIC             WHEN test_key = 'UPCR'
# MAGIC              AND unit_norm = 'g/g'
# MAGIC             THEN raw_value
# MAGIC
# MAGIC             WHEN test_key = 'UPCR'
# MAGIC              AND unit_norm IN (
# MAGIC                     'mg/g cr',
# MAGIC                     'mg/g creat'
# MAGIC                  )
# MAGIC             THEN raw_value / 1000.0
# MAGIC
# MAGIC             WHEN test_key = 'URINE_PROT_24H'
# MAGIC              AND unit_norm = 'mg/day'
# MAGIC             THEN raw_value / 1000.0
# MAGIC
# MAGIC             WHEN test_key = 'TSH'
# MAGIC             THEN raw_value
# MAGIC
# MAGIC             WHEN test_key = 'EGFR'
# MAGIC             THEN raw_value
# MAGIC
# MAGIC             ELSE NULL
# MAGIC         END AS val
# MAGIC
# MAGIC     FROM labs_raw
# MAGIC )
# MAGIC
# MAGIC SELECT
# MAGIC     person_id,
# MAGIC
# MAGIC     max(
# MAGIC         CASE
# MAGIC             WHEN test_key = 'TSH'
# MAGIC              AND val >= 10
# MAGIC             THEN 1 ELSE 0
# MAGIC         END
# MAGIC     ) AS hypothyroidism,
# MAGIC
# MAGIC     max(
# MAGIC         CASE
# MAGIC             WHEN test_key = 'ALP'
# MAGIC              AND val >= 200
# MAGIC             THEN 1 ELSE 0
# MAGIC         END
# MAGIC     ) AS biliary_obstruction,
# MAGIC
# MAGIC     max(
# MAGIC         CASE
# MAGIC             WHEN test_key = 'TBIL'
# MAGIC              AND val > 2.0
# MAGIC             THEN 1 ELSE 0
# MAGIC         END
# MAGIC     ) AS liver_disease,
# MAGIC
# MAGIC     max(
# MAGIC         CASE
# MAGIC             WHEN test_key = 'URINE_PROT_24H'
# MAGIC              AND val > 3.0
# MAGIC             THEN 1
# MAGIC
# MAGIC             WHEN test_key = 'UPCR'
# MAGIC              AND val > 3.0
# MAGIC             THEN 1
# MAGIC
# MAGIC             ELSE 0
# MAGIC         END
# MAGIC     ) AS nephrotic_syndrome,
# MAGIC
# MAGIC     max(
# MAGIC         CASE
# MAGIC             WHEN test_key = 'CREAT'
# MAGIC              AND val > 2.6
# MAGIC             THEN 1
# MAGIC
# MAGIC             WHEN test_key = 'EGFR'
# MAGIC              AND val < 15
# MAGIC             THEN 1
# MAGIC
# MAGIC             ELSE 0
# MAGIC         END
# MAGIC     ) AS renal_failure,
# MAGIC
# MAGIC     max(
# MAGIC         CASE
# MAGIC             WHEN test_key = 'HBA1C'
# MAGIC              AND val > 9
# MAGIC             THEN 1
# MAGIC
# MAGIC             WHEN test_key = 'GLUCOSE_CAP'
# MAGIC              AND val > 200
# MAGIC             THEN 1
# MAGIC
# MAGIC             WHEN test_key = 'GLUCOSE_VEN'
# MAGIC              AND val > 220
# MAGIC             THEN 1
# MAGIC
# MAGIC             ELSE 0
# MAGIC         END
# MAGIC     ) AS diabetes
# MAGIC
# MAGIC FROM labs
# MAGIC GROUP BY person_id;

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 6b · Pregnancy (Table 2B)
# MAGIC
# MAGIC Produces a **count** of distinct coded days rather than a boolean, so both readings stay
# MAGIC derivable from one build:
# MAGIC
# MAGIC | Reading | Rule | Source |
# MAGIC |---|---|---|
# MAGIC | Implemented | ≥1 code | PDF |
# MAGIC | Alternative | ≥2 codes on different days | Content spreadsheet |
# MAGIC

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE workspace_sdphenotypecore.fh.fh_pregnancy AS
# MAGIC SELECT i.person_id, count(DISTINCT co.condition_start_date) AS n_preg_days
# MAGIC FROM workspace_sdphenotypecore.fh.fh_step4_index i
# MAGIC JOIN victr_sd.sd_omop_prod.condition_occurrence co ON co.person_id = i.person_id
# MAGIC JOIN victr_sd.sd_omop_prod.concept c
# MAGIC   ON c.concept_id = co.condition_source_concept_id AND c.vocabulary_id = 'ICD9CM'
# MAGIC JOIN workspace_sdphenotypecore.fh.fh_ref_pregnancy pg
# MAGIC   ON c.concept_code LIKE concat(pg.icd9_prefix, '%')
# MAGIC WHERE co.condition_start_date BETWEEN add_months(i.index_date, -12) AND i.index_date
# MAGIC GROUP BY i.person_id;

# COMMAND ----------

# MAGIC %md
# MAGIC  ## Step 6c · Apply the secondary-cause exclusion
# MAGIC
# MAGIC The `LEFT JOIN` with `coalesce(…, 0)` is the correct contract for `fh_secondary_labs`, which
# MAGIC holds a row only for patients who had at least one qualifying lab. 
# MAGIC
# MAGIC Pregnancy is *not* applied as an exclusion — it is a flag carried into `fh_stage1`
# MAGIC (deviation 1).

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE workspace_sdphenotypecore.fh.fh_step6_eligible AS
# MAGIC SELECT i.person_id
# MAGIC FROM workspace_sdphenotypecore.fh.fh_step4_index i
# MAGIC LEFT JOIN workspace_sdphenotypecore.fh.fh_secondary_labs s ON s.person_id = i.person_id
# MAGIC WHERE coalesce(s.hypothyroidism,0) + coalesce(s.biliary_obstruction,0) + coalesce(s.liver_disease,0)
# MAGIC     + coalesce(s.nephrotic_syndrome,0) + coalesce(s.renal_failure,0) + coalesce(s.diabetes,0) = 0;

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 7 · Lipid-lowering treatment (Figure 2, box 7)
# MAGIC
# MAGIC Window: `[index_date − 366 days, index_date − 42 days]`. The six-week lead-in excludes
# MAGIC treatment started too recently to have affected the index LDL-C. 
# MAGIC
# MAGIC The concept join matches `drug_concept_id` **or** `drug_source_concept_id`.

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE workspace_sdphenotypecore.fh.fh_step7_llt AS
# MAGIC SELECT i.person_id,
# MAGIC        max(de.drug_exposure_start_date) AS date_llt_prescribed,
# MAGIC        months_between(i.index_date, max(de.drug_exposure_start_date)) AS time_delta_months
# MAGIC FROM workspace_sdphenotypecore.fh.fh_step4_index i
# MAGIC JOIN workspace_sdphenotypecore.fh.fh_step6_eligible e ON e.person_id = i.person_id
# MAGIC JOIN victr_sd.sd_omop_prod.drug_exposure de ON de.person_id = i.person_id
# MAGIC JOIN workspace_sdphenotypecore.fh.fh_llt_concepts lc
# MAGIC   ON (lc.concept_id = de.drug_concept_id OR lc.concept_id = de.drug_source_concept_id)
# MAGIC WHERE de.drug_exposure_start_date BETWEEN date_add(i.index_date, -366) AND date_add(i.index_date, -42)
# MAGIC GROUP BY i.person_id, i.index_date;

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 8 · Pre-treatment LDL-C and classification (Figure 2, box 8)
# MAGIC
# MAGIC If the patient was on lipid-lowering treatment, the index LDL-C is divided by 0.7 to estimate
# MAGIC the untreated value — the document expects a 30% reduction as the therapy effect (p.3). A
# MAGIC PheKB author clarification adds that the recalculated LDL must never be 0, and that the
# MAGIC uncorrected level is used when the patient is not on treatment. Both hold here.
# MAGIC
# MAGIC | Status | `eval_ldl` |
# MAGIC |---|---|
# MAGIC | `CASE` | ≥ 155 mg/dL |
# MAGIC | `CONTROL` | ≤ 130 mg/dL |
# MAGIC | `UNKNOWN` | 131–154 mg/dL |

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE workspace_sdphenotypecore.fh.fh_stage1 AS
# MAGIC WITH j AS (
# MAGIC   SELECT
# MAGIC     pr.person_id, pr.index_date, pr.index_age,
# MAGIC     pr.gender, pr.race, pr.ethnicity,
# MAGIC     pr.index_ldl, pr.index_tc, pr.index_hdl, pr.index_tg,
# MAGIC     (llt.person_id IS NOT NULL) AS on_llt,
# MAGIC     llt.date_llt_prescribed, llt.time_delta_months,
# MAGIC
# MAGIC     CASE WHEN llt.person_id IS NOT NULL THEN pr.index_ldl / 0.7
# MAGIC          ELSE pr.index_ldl END AS eval_ldl,
# MAGIC
# MAGIC     CASE WHEN pg.person_id IS NOT NULL
# MAGIC               AND pr.index_ldl >= 155
# MAGIC          THEN 1 ELSE 0 END AS flag_pregnancy,
# MAGIC
# MAGIC
# MAGIC     coalesce(pg.n_preg_days, 0)                            AS n_preg_days,
# MAGIC
# MAGIC     CASE WHEN f220.person_id IS NOT NULL THEN 1 ELSE 0 END AS flag_tg_gt220
# MAGIC
# MAGIC   FROM workspace_sdphenotypecore.fh.fh_step5_profile pr
# MAGIC   JOIN      workspace_sdphenotypecore.fh.fh_step6_eligible e    ON e.person_id    = pr.person_id
# MAGIC   LEFT JOIN workspace_sdphenotypecore.fh.fh_step7_llt      llt  ON llt.person_id  = pr.person_id
# MAGIC   LEFT JOIN workspace_sdphenotypecore.fh.fh_pregnancy      pg   ON pg.person_id   = pr.person_id
# MAGIC   LEFT JOIN workspace_sdphenotypecore.fh.fh_flag_tg220     f220 ON f220.person_id = pr.person_id
# MAGIC )
# MAGIC SELECT j.*,
# MAGIC   -- Figure 2: Cases >= 155, Controls <= 130, Unknown 131-154
# MAGIC   CASE
# MAGIC     WHEN eval_ldl >= 155 THEN 'CASE'
# MAGIC     WHEN eval_ldl <= 130 THEN 'CONTROL'
# MAGIC     ELSE 'UNKNOWN'
# MAGIC   END AS case_control_pchl
# MAGIC FROM j;

# COMMAND ----------

# MAGIC %md
# MAGIC ## Results 

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT case_control_pchl AS status, count(*) AS n
# MAGIC FROM workspace_sdphenotypecore.fh.fh_stage1
# MAGIC GROUP BY 1 ORDER BY 1;