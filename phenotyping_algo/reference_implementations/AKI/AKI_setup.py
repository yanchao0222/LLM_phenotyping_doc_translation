# Databricks notebook source
# MAGIC %md
# MAGIC # Acute Kidney Injury (AKI) — Setup and Concept Sets
# MAGIC
# MAGIC Creates the working schema and materializes the concept sets the phenotype
# MAGIC depends on. Run this notebook **once** before `AKI_phenotype`.
# MAGIC
# MAGIC | | |
# MAGIC |---|---|
# MAGIC | **Phenotype** | Acute Kidney Injury (AKI) |
# MAGIC | **Source location** | [PheKB — Acute Kidney Injury (AKI)](https://phekb.org/phenotype/acute-kidney-injury-aki) |
# MAGIC | **Implemented by** | Srushti Gangireddy, Wu-Chen Su |
# MAGIC | **Created** | 2026-08-01 |
# MAGIC | **Last modified** | 2026-08-04 |
# MAGIC | **Data source** | VUMC Synthetic Derivative, OMOP CDM v5 (`victr_sd.sd_omop_prod`) |
# MAGIC | **Output schema** | `workspace_sdphenotypecore.phekb_aki` |
# MAGIC | **Platform** | Databricks SQL |
# MAGIC
# MAGIC ## Why this is a separate notebook
# MAGIC
# MAGIC The exclusion concept set is 94 literal rows. Inlining it in the pipeline
# MAGIC notebook buries the algorithm under a wall of identifiers and makes the
# MAGIC pipeline unreadable at a glance. Splitting it also means the concept sets can be
# MAGIC reviewed, diffed, and re-derived independently of the logic that consumes them —
# MAGIC which is what a reviewer will actually want to check.
# MAGIC
# MAGIC Both tables created here are inputs to `AKI_phenotype`.

# COMMAND ----------

# MAGIC %md
# MAGIC ## 1 · Working schema
# MAGIC
# MAGIC All phenotype tables are written to `workspace_sdphenotypecore.phekb_aki`. The
# MAGIC source OMOP CDM is read-only and is always referenced by its fully-qualified
# MAGIC name.

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE SCHEMA IF NOT EXISTS workspace_sdphenotypecore.phekb_aki;
# MAGIC USE CATALOG workspace_sdphenotypecore;
# MAGIC USE SCHEMA phekb_aki;

# COMMAND ----------

# MAGIC %md
# MAGIC ## 2 · ESRD exclusion concept set
# MAGIC
# MAGIC Patients with pre-existing end-stage renal disease are excluded before AKI is
# MAGIC assessed: a chronically elevated creatinine is not an acute injury, and dialysis
# MAGIC makes serum creatinine uninterpretable as a marker of native kidney function.
# MAGIC
# MAGIC **Source:** Table 1 of the algorithm document, variables
# MAGIC `dx.CkdEsrd_Dialysis`, `proc.CkdEsrd_Dialysis`, `dx.CkdEsrd_kidneyTransplant`,
# MAGIC `proc.CkdEsrd_kidneyTransplant`, as distributed in
# MAGIC `AKIalgorithm_V1_coding.txt`. The 94 distinct standard concepts below are the
# MAGIC `standard_concept_id` values from that file, deduplicated.
# MAGIC
# MAGIC **Domain routing.** Although the document describes these as diagnoses and
# MAGIC procedures, their OMOP standard domains span three tables:
# MAGIC
# MAGIC | Domain | Concepts | Queried in |
# MAGIC |---|---|---|
# MAGIC | Condition | 14 | `condition_occurrence` |
# MAGIC | Procedure | 42 | `procedure_occurrence` |
# MAGIC | Observation | 38 | `observation` |
# MAGIC
# MAGIC The 38 Observation-domain concepts are the reason `domain_id` is carried
# MAGIC alongside `concept_id` rather than being dropped. They include some of the
# MAGIC strongest ESRD indicators — dependence on renal dialysis, history of renal
# MAGIC dialysis — and querying only the two tables the document names would silently
# MAGIC discard 40% of the exclusion set.

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE aki_excl_concepts AS
# MAGIC SELECT CAST(concept_id AS BIGINT) AS concept_id, domain_id
# MAGIC FROM VALUES
# MAGIC   -- Condition (14)
# MAGIC   (199991,'Condition'),
# MAGIC   (438624,'Condition'),
# MAGIC   (440276,'Condition'),
# MAGIC   (440302,'Condition'),
# MAGIC   (442618,'Condition'),
# MAGIC   (443212,'Condition'),
# MAGIC   (4126451,'Condition'),
# MAGIC   (4127554,'Condition'),
# MAGIC   (4128369,'Condition'),
# MAGIC   (4322175,'Condition'),
# MAGIC   (42539502,'Condition'),
# MAGIC   (43021418,'Condition'),
# MAGIC   (43021974,'Condition'),
# MAGIC   (43021985,'Condition'),
# MAGIC   -- Procedure (42)
# MAGIC   (2003626,'Procedure'),
# MAGIC   (2108276,'Procedure'),
# MAGIC   (2108277,'Procedure'),
# MAGIC   (2108297,'Procedure'),
# MAGIC   (2108299,'Procedure'),
# MAGIC   (2108302,'Procedure'),
# MAGIC   (2109463,'Procedure'),
# MAGIC   (2109586,'Procedure'),
# MAGIC   (2109587,'Procedure'),
# MAGIC   (2109589,'Procedure'),
# MAGIC   (2213572,'Procedure'),
# MAGIC   (2213573,'Procedure'),
# MAGIC   (2213575,'Procedure'),
# MAGIC   (2213576,'Procedure'),
# MAGIC   (2213577,'Procedure'),
# MAGIC   (2213601,'Procedure'),
# MAGIC   (2313999,'Procedure'),
# MAGIC   (2774517,'Procedure'),
# MAGIC   (2774518,'Procedure'),
# MAGIC   (2774519,'Procedure'),
# MAGIC   (2774520,'Procedure'),
# MAGIC   (2774521,'Procedure'),
# MAGIC   (2774522,'Procedure'),
# MAGIC   (2786488,'Procedure'),
# MAGIC   (4022474,'Procedure'),
# MAGIC   (4026915,'Procedure'),
# MAGIC   (4032243,'Procedure'),
# MAGIC   (4120120,'Procedure'),
# MAGIC   (4146256,'Procedure'),
# MAGIC   (4197217,'Procedure'),
# MAGIC   (4214705,'Procedure'),
# MAGIC   (4247794,'Procedure'),
# MAGIC   (4289454,'Procedure'),
# MAGIC   (4322471,'Procedure'),
# MAGIC   (4324124,'Procedure'),
# MAGIC   (42627979,'Procedure'),
# MAGIC   (42628018,'Procedure'),
# MAGIC   (42628058,'Procedure'),
# MAGIC   (42628575,'Procedure'),
# MAGIC   (42628576,'Procedure'),
# MAGIC   (42628580,'Procedure'),
# MAGIC   (42736574,'Procedure'),
# MAGIC   -- Observation (38)
# MAGIC   (313232,'Observation'),
# MAGIC   (437196,'Observation'),
# MAGIC   (438046,'Observation'),
# MAGIC   (2101833,'Observation'),
# MAGIC   (2101834,'Observation'),
# MAGIC   (2106278,'Observation'),
# MAGIC   (2108564,'Observation'),
# MAGIC   (2108566,'Observation'),
# MAGIC   (2108567,'Observation'),
# MAGIC   (2108568,'Observation'),
# MAGIC   (2213578,'Observation'),
# MAGIC   (2213579,'Observation'),
# MAGIC   (2213580,'Observation'),
# MAGIC   (2213581,'Observation'),
# MAGIC   (2213582,'Observation'),
# MAGIC   (2213583,'Observation'),
# MAGIC   (2213584,'Observation'),
# MAGIC   (2213585,'Observation'),
# MAGIC   (2213586,'Observation'),
# MAGIC   (2213587,'Observation'),
# MAGIC   (2213588,'Observation'),
# MAGIC   (2213589,'Observation'),
# MAGIC   (2213590,'Observation'),
# MAGIC   (2213591,'Observation'),
# MAGIC   (2213592,'Observation'),
# MAGIC   (2213593,'Observation'),
# MAGIC   (2213594,'Observation'),
# MAGIC   (2213595,'Observation'),
# MAGIC   (2213596,'Observation'),
# MAGIC   (2213597,'Observation'),
# MAGIC   (4019967,'Observation'),
# MAGIC   (4059475,'Observation'),
# MAGIC   (4081759,'Observation'),
# MAGIC   (4203722,'Observation'),
# MAGIC   (4268532,'Observation'),
# MAGIC   (4301680,'Observation'),
# MAGIC   (40483083,'Observation'),
# MAGIC   (46270032,'Observation')
# MAGIC AS t(concept_id, domain_id);

# COMMAND ----------

# MAGIC %md
# MAGIC ### Validation — domain distribution
# MAGIC
# MAGIC Expected: Condition 14, Observation 38, Procedure 42; 94 total. A mismatch means
# MAGIC the concept list was edited and the counts above are stale.

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT domain_id, COUNT(*) AS n_concepts
# MAGIC FROM aki_excl_concepts
# MAGIC GROUP BY domain_id ORDER BY domain_id;

# COMMAND ----------

# MAGIC %md
# MAGIC ## 3 · Serum creatinine concept set
# MAGIC
# MAGIC Serum creatinine is the only laboratory input to the algorithm. The concept set
# MAGIC is applied inline in `01_AKI_phenotype` (Step 3) rather than materialized here,
# MAGIC because it is six identifiers rather than ninety-four.
# MAGIC
# MAGIC | `concept_id` | Source | Notes |
# MAGIC |---|---|---|
# MAGIC | 2004293111 | VUMC-local | Largest single SCr source on SD (~16.25M rows). Not reachable by name-matching the standard concept table — found only by profiling `measurement_concept_id` frequencies directly |
# MAGIC | 3016723 | LOINC | Creatinine [Mass/volume] in Serum or Plasma. The only concept shared with the source document's LOINC set |
# MAGIC | 3051825 | LOINC | Creatinine [Mass/volume] in Blood. Not in the source set; high-volume and unit-consistent locally |
# MAGIC | 2000323130 | VUMC-local | ED point-of-care creatinine — directly relevant given the ED anchor |
# MAGIC | 2001613121 | VUMC-local | Point-of-care creatinine |
# MAGIC | 2006080014 | VUMC-local | Small local source, consistent mg/dL distribution |
# MAGIC
# MAGIC **Deliberately excluded:** concept 2003553149 ("CREATININE"). A large fraction of
# MAGIC its values have median 8.98 mg/dL and p99 20.12 with 44% nulls, consistent with
# MAGIC urine or other non-serum specimens. Including it corrupts the L1 median
# MAGIC baseline. eGFR and body-fluid creatinine concepts are excluded for the same
# MAGIC class of reason — they are not serum creatinine.
# MAGIC
# MAGIC **Portability note.** This concept set is the least transferable part of the
# MAGIC implementation. The document's own LOINC list overlaps the final local set at
# MAGIC exactly one concept. Any site porting this algorithm must repeat the profiling
# MAGIC rather than reuse these identifiers.

# COMMAND ----------

# MAGIC %md
# MAGIC ## 4 · Visit vocabulary check
# MAGIC
# MAGIC The presentation anchor in `01_AKI_phenotype` selects `visit_concept_id = 9203`
# MAGIC (Emergency Room Visit). This query documents which visit concepts this instance
# MAGIC actually populates.
# MAGIC
# MAGIC **What to look for:** concept `262` (Emergency Room and Inpatient Visit). If it
# MAGIC is present, ED presentations that convert to admission carry `262` rather than
# MAGIC `9203` and the anchor under-captures them. On this instance `262` is absent, so
# MAGIC `9203` alone is sufficient — but that is a property of this database, not of the
# MAGIC algorithm, and it must be re-checked at any other site.

# COMMAND ----------

# MAGIC %sql
# MAGIC select distinct visit_concept_id from victr_sd.sd_omop_prod.visit_occurrence;