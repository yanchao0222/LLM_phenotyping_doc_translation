# Databricks notebook source
# MAGIC %md
# MAGIC # Familial Hypercholesterolemia — Reference Code Tables
# MAGIC
# MAGIC Builds the four reference tables the Stage I pipeline depends on. Run this notebook
# MAGIC **once** before `FH_stage1`.
# MAGIC
# MAGIC | | |
# MAGIC |---|---|
# MAGIC | **Phenotype** | Familial Hypercholesterolemia — Stage I |
# MAGIC | **Source algorithm** | [Electronic Health Record-based Phenotyping Algorithm for Familial Hypercholesterolemia](https://phekb.org/phenotype/electronic-health-record-based-phenotyping-algorithm-familial-hypercholesterolemia) |
# MAGIC | **Implemented by** | Srushti Gangireddy, Wu-Chen Su |
# MAGIC | **Created** | 2026-08-01 |
# MAGIC | **Last modified** | 2026-08-05 |
# MAGIC | **Output schema** | `workspace_sdphenotypecore.fh` |
# MAGIC | **Platform** | Databricks SQL |
# MAGIC
# MAGIC ## What this notebook builds
# MAGIC
# MAGIC | Table | Rows | Source | Used by |
# MAGIC |---|---|---|---|
# MAGIC | `fh_ref_dx_codes` | 160 | Table 4 (ASCVD), Table 3B (apheresis) | **Stage II only** |
# MAGIC | `fh_ref_loinc` | 60 | Table 1 (lipids), Table 2A (secondary causes) | Stage I |
# MAGIC | `fh_ref_rxnorm` | 35 | Table 3A (lipid-lowering drugs) | Stage I |
# MAGIC | `fh_ref_pregnancy` | 5 | Table 2B (pregnancy ICD-9) | Stage I |
# MAGIC
# MAGIC ## Reload → rebuild dependency
# MAGIC
# MAGIC ```
# MAGIC fh_ref_loinc      ──▶ fh_loinc_concepts ──▶ everything in Stage I
# MAGIC fh_ref_rxnorm     ──▶ fh_llt_concepts   ──▶ fh_step7_llt ──▶ fh_stage1
# MAGIC fh_ref_pregnancy  ──▶ fh_pregnancy      ──▶ fh_stage1
# MAGIC fh_ref_dx_codes   ──▶ (Stage II only)
# MAGIC ```

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
# MAGIC ## 2 · ASCVD and apheresis codes — `fh_ref_dx_codes`
# MAGIC
# MAGIC **Source:** Table 4 (events and procedures defining ASCVD cases) and Table 3B
# MAGIC (extracorporeal lipid-lowering procedures). **160 rows.**
# MAGIC
# MAGIC Premature ASCVD case status requires **two or more** pertinent diagnosis and/or procedure
# MAGIC codes before age 56 in men and 66 in women. Codes are evaluated at discharge from each
# MAGIC encounter during the surveillance period.
# MAGIC
# MAGIC | `group` | `code_type` | n | Meaning |
# MAGIC |---|---|---|---|
# MAGIC | `CHD` | ICD9CM | 44 | Angina, MI, coronary atherosclerosis |
# MAGIC | | CPT4 | 37 | PCI (21) and CABG (16) |
# MAGIC | | ICD9Proc | 20 | PCI (9) and CABG (11) |
# MAGIC | `CVD` | ICD9CM | 26 | Stroke, TIA, carotid disease |
# MAGIC | | ICD9Proc | 5 | Endarterectomy, angioplasty, stent, bypass |
# MAGIC | | CPT4 | 3 | Carotid procedures |
# MAGIC | `PAD` | ICD9CM | 6 | Atherosclerosis of native extremity arteries |
# MAGIC | `PAD_Exclude` | ICD9CM | 16 | Non-atherosclerotic causes — Table 4 excludes these with ≥2 occurrences |
# MAGIC | `LLT_PROC` | CPT4 / ICD9Proc | 3 | Table 3B apheresis |
# MAGIC
# MAGIC Two things to know before joining this table:
# MAGIC
# MAGIC - **`code_type` distinguishes `ICD9CM` from `ICD9Proc`.** Any downstream join that assumed
# MAGIC   all ICD-9 codes are `ICD9CM` will miss all 25 procedure codes.
# MAGIC - **`36.18` will not resolve** against the vocabulary. It is included for literal fidelity
# MAGIC   to Table 4's stated range `36.10 – 36.19`, but is not an assigned ICD-9 procedure code.
# MAGIC   Expect exactly one row from the unresolved-code check.

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE workspace_sdphenotypecore.fh.fh_ref_dx_codes AS
# MAGIC SELECT * FROM VALUES
# MAGIC   -- ===== CORONARY HEART DISEASE =====
# MAGIC   -- Angina (ICD-9-CM)
# MAGIC   ('ICD9CM','CHD','413.0'),
# MAGIC   ('ICD9CM','CHD','413.1'),
# MAGIC   ('ICD9CM','CHD','413.9'),
# MAGIC   -- Acute myocardial infarction, all sites and episodes of care
# MAGIC   ('ICD9CM','CHD','410.00'),
# MAGIC   ('ICD9CM','CHD','410.01'),
# MAGIC   ('ICD9CM','CHD','410.02'),
# MAGIC   ('ICD9CM','CHD','410.10'),
# MAGIC   ('ICD9CM','CHD','410.11'),
# MAGIC   ('ICD9CM','CHD','410.12'),
# MAGIC   ('ICD9CM','CHD','410.20'),
# MAGIC   ('ICD9CM','CHD','410.21'),
# MAGIC   ('ICD9CM','CHD','410.22'),
# MAGIC   ('ICD9CM','CHD','410.30'),
# MAGIC   ('ICD9CM','CHD','410.31'),
# MAGIC   ('ICD9CM','CHD','410.32'),
# MAGIC   ('ICD9CM','CHD','410.40'),
# MAGIC   ('ICD9CM','CHD','410.41'),
# MAGIC   ('ICD9CM','CHD','410.42'),
# MAGIC   ('ICD9CM','CHD','410.50'),
# MAGIC   ('ICD9CM','CHD','410.51'),
# MAGIC   ('ICD9CM','CHD','410.52'),
# MAGIC   ('ICD9CM','CHD','410.60'),
# MAGIC   ('ICD9CM','CHD','410.61'),
# MAGIC   ('ICD9CM','CHD','410.62'),
# MAGIC   ('ICD9CM','CHD','410.70'),
# MAGIC   ('ICD9CM','CHD','410.71'),
# MAGIC   ('ICD9CM','CHD','410.72'),
# MAGIC   ('ICD9CM','CHD','410.80'),
# MAGIC   ('ICD9CM','CHD','410.81'),
# MAGIC   ('ICD9CM','CHD','410.82'),
# MAGIC   ('ICD9CM','CHD','410.90'),
# MAGIC   ('ICD9CM','CHD','410.91'),
# MAGIC   ('ICD9CM','CHD','410.92'),
# MAGIC   ('ICD9CM','CHD','412'),                    -- old myocardial infarction
# MAGIC   ('ICD9CM','CHD','429.71'),                 -- sequelae of MI: septal defect
# MAGIC   ('ICD9CM','CHD','429.79'),                 -- sequelae of MI: other
# MAGIC   -- Coronary atherosclerosis / chronic ischemic heart disease
# MAGIC   ('ICD9CM','CHD','414.00'),
# MAGIC   ('ICD9CM','CHD','414.01'),
# MAGIC   ('ICD9CM','CHD','414.02'),
# MAGIC   ('ICD9CM','CHD','414.03'),
# MAGIC   ('ICD9CM','CHD','414.04'),
# MAGIC   ('ICD9CM','CHD','414.05'),
# MAGIC   ('ICD9CM','CHD','414.06'),
# MAGIC   ('ICD9CM','CHD','414.07'),
# MAGIC   -- Percutaneous coronary revascularization (CPT-4)
# MAGIC   ('CPT4','CHD','92920'),
# MAGIC   ('CPT4','CHD','92921'),
# MAGIC   ('CPT4','CHD','92924'),
# MAGIC   ('CPT4','CHD','92925'),
# MAGIC   ('CPT4','CHD','92928'),
# MAGIC   ('CPT4','CHD','92929'),
# MAGIC   ('CPT4','CHD','92933'),
# MAGIC   ('CPT4','CHD','92934'),
# MAGIC   ('CPT4','CHD','92937'),
# MAGIC   ('CPT4','CHD','92938'),
# MAGIC   ('CPT4','CHD','92941'),
# MAGIC   ('CPT4','CHD','92943'),
# MAGIC   ('CPT4','CHD','92944'),
# MAGIC   ('CPT4','CHD','92973'),
# MAGIC   ('CPT4','CHD','92974'),
# MAGIC   ('CPT4','CHD','92980'),
# MAGIC   ('CPT4','CHD','92981'),
# MAGIC   ('CPT4','CHD','92982'),
# MAGIC   ('CPT4','CHD','92984'),
# MAGIC   ('CPT4','CHD','92995'),
# MAGIC   ('CPT4','CHD','92996'),
# MAGIC   -- Percutaneous coronary revascularization (ICD-9 procedure), range 36.01-36.07, 36.09
# MAGIC   ('ICD9Proc','CHD','36.01'),
# MAGIC   ('ICD9Proc','CHD','36.02'),
# MAGIC   ('ICD9Proc','CHD','36.03'),
# MAGIC   ('ICD9Proc','CHD','36.04'),
# MAGIC   ('ICD9Proc','CHD','36.05'),
# MAGIC   ('ICD9Proc','CHD','36.06'),
# MAGIC   ('ICD9Proc','CHD','36.07'),
# MAGIC   ('ICD9Proc','CHD','36.09'),
# MAGIC   ('ICD9Proc','CHD','00.66'),                -- leading zeros preserved deliberately
# MAGIC   -- Coronary bypass surgery (CPT-4)
# MAGIC   ('CPT4','CHD','33510'),
# MAGIC   ('CPT4','CHD','33511'),
# MAGIC   ('CPT4','CHD','33512'),
# MAGIC   ('CPT4','CHD','33513'),
# MAGIC   ('CPT4','CHD','33514'),
# MAGIC   ('CPT4','CHD','33516'),
# MAGIC   ('CPT4','CHD','33517'),
# MAGIC   ('CPT4','CHD','33518'),
# MAGIC   ('CPT4','CHD','33519'),
# MAGIC   ('CPT4','CHD','33521'),
# MAGIC   ('CPT4','CHD','33522'),
# MAGIC   ('CPT4','CHD','33523'),
# MAGIC   ('CPT4','CHD','33533'),
# MAGIC   ('CPT4','CHD','33534'),
# MAGIC   ('CPT4','CHD','33535'),
# MAGIC   ('CPT4','CHD','33536'),
# MAGIC   -- Coronary bypass surgery (ICD-9 procedure), range 36.10-36.19, 36.2
# MAGIC   ('ICD9Proc','CHD','36.10'),
# MAGIC   ('ICD9Proc','CHD','36.11'),
# MAGIC   ('ICD9Proc','CHD','36.12'),
# MAGIC   ('ICD9Proc','CHD','36.13'),
# MAGIC   ('ICD9Proc','CHD','36.14'),
# MAGIC   ('ICD9Proc','CHD','36.15'),
# MAGIC   ('ICD9Proc','CHD','36.16'),
# MAGIC   ('ICD9Proc','CHD','36.17'),
# MAGIC   ('ICD9Proc','CHD','36.18'),                -- not an assigned code; kept for range fidelity
# MAGIC   ('ICD9Proc','CHD','36.19'),
# MAGIC   ('ICD9Proc','CHD','36.2'),
# MAGIC
# MAGIC   -- ===== CEREBROVASCULAR DISEASE =====
# MAGIC   -- Stroke: occlusion of cerebral arteries
# MAGIC   ('ICD9CM','CVD','434.00'),
# MAGIC   ('ICD9CM','CVD','434.01'),
# MAGIC   ('ICD9CM','CVD','434.10'),
# MAGIC   ('ICD9CM','CVD','434.11'),
# MAGIC   ('ICD9CM','CVD','434.90'),
# MAGIC   ('ICD9CM','CVD','434.91'),
# MAGIC   ('ICD9CM','CVD','437.0'),                  -- cerebral atherosclerosis
# MAGIC   ('ICD9CM','CVD','437.1'),                  -- other generalized ischemic CVD
# MAGIC   -- Transient ischemic attack
# MAGIC   ('ICD9CM','CVD','435.0'),
# MAGIC   ('ICD9CM','CVD','435.1'),
# MAGIC   ('ICD9CM','CVD','435.2'),
# MAGIC   ('ICD9CM','CVD','435.3'),
# MAGIC   ('ICD9CM','CVD','435.8'),
# MAGIC   ('ICD9CM','CVD','435.9'),
# MAGIC   -- Carotid artery disease: occlusion/stenosis of precerebral arteries
# MAGIC   ('ICD9CM','CVD','433.00'),
# MAGIC   ('ICD9CM','CVD','433.01'),
# MAGIC   ('ICD9CM','CVD','433.10'),
# MAGIC   ('ICD9CM','CVD','433.11'),
# MAGIC   ('ICD9CM','CVD','433.20'),
# MAGIC   ('ICD9CM','CVD','433.21'),
# MAGIC   ('ICD9CM','CVD','433.30'),
# MAGIC   ('ICD9CM','CVD','433.31'),
# MAGIC   ('ICD9CM','CVD','433.80'),
# MAGIC   ('ICD9CM','CVD','433.81'),
# MAGIC   ('ICD9CM','CVD','433.90'),
# MAGIC   ('ICD9CM','CVD','433.91'),
# MAGIC   -- Cerebrovascular procedures (ICD-9 procedure)
# MAGIC   ('ICD9Proc','CVD','38.11'),                -- endarterectomy, intracranial
# MAGIC   ('ICD9Proc','CVD','38.12'),                -- endarterectomy, head/neck
# MAGIC   ('ICD9Proc','CVD','00.61'),                -- extracranial percutaneous angioplasty
# MAGIC   ('ICD9Proc','CVD','00.63'),                -- carotid artery stent
# MAGIC   ('ICD9Proc','CVD','39.28'),                -- extracranial-intracranial bypass
# MAGIC   -- Cerebrovascular procedures (CPT-4)
# MAGIC   ('CPT4','CVD','35301'),
# MAGIC   ('CPT4','CVD','37215'),
# MAGIC   ('CPT4','CVD','37216'),
# MAGIC
# MAGIC   -- ===== PERIPHERAL ARTERIAL DISEASE =====
# MAGIC   ('ICD9CM','PAD','440.20'),
# MAGIC   ('ICD9CM','PAD','440.21'),
# MAGIC   ('ICD9CM','PAD','440.22'),
# MAGIC   ('ICD9CM','PAD','440.23'),
# MAGIC   ('ICD9CM','PAD','440.24'),
# MAGIC   ('ICD9CM','PAD','440.29'),
# MAGIC
# MAGIC   -- PAD exclusions: non-atherosclerotic vascular disease. Table 4 excludes a
# MAGIC   -- patient when >= 2 occurrences of these appear.
# MAGIC   ('ICD9CM','PAD_Exclude','237.70'),         -- neurofibromatosis
# MAGIC   ('ICD9CM','PAD_Exclude','237.71'),
# MAGIC   ('ICD9CM','PAD_Exclude','237.72'),
# MAGIC   ('ICD9CM','PAD_Exclude','237.73'),
# MAGIC   ('ICD9CM','PAD_Exclude','237.79'),
# MAGIC   ('ICD9CM','PAD_Exclude','443.1'),          -- thromboangiitis obliterans
# MAGIC   ('ICD9CM','PAD_Exclude','446.0'),          -- polyarteritis nodosa
# MAGIC   ('ICD9CM','PAD_Exclude','446.4'),          -- Wegener's granulomatosis
# MAGIC   ('ICD9CM','PAD_Exclude','446.5'),          -- giant cell arteritis
# MAGIC   ('ICD9CM','PAD_Exclude','446.6'),          -- thrombotic microangiopathy
# MAGIC   ('ICD9CM','PAD_Exclude','446.7'),          -- Takayasu's disease
# MAGIC   ('ICD9CM','PAD_Exclude','710.1'),          -- systemic sclerosis
# MAGIC   ('ICD9CM','PAD_Exclude','747.10'),         -- coarctation of aorta
# MAGIC   ('ICD9CM','PAD_Exclude','747.11'),
# MAGIC   ('ICD9CM','PAD_Exclude','747.22'),
# MAGIC   ('ICD9CM','PAD_Exclude','747.64'),
# MAGIC
# MAGIC   -- ===== TABLE 3B: EXTRACORPOREAL LIPID-LOWERING PROCEDURES =====
# MAGIC   -- Present in the reference set but NOT joined anywhere in Stage I.
# MAGIC   -- See Stage I deviation 5.
# MAGIC   ('CPT4','LLT_PROC','36515'),               -- immunoadsorption + plasma reinfusion
# MAGIC   ('CPT4','LLT_PROC','36516'),               -- selective adsorption/filtration
# MAGIC   ('ICD9Proc','LLT_PROC','99.76')            -- Table 3B; an earlier version had 99.71
# MAGIC AS t(code_type, `group`, code);

# COMMAND ----------

# MAGIC %md
# MAGIC ## 3 · Lipid and secondary-cause LOINC codes — `fh_ref_loinc`
# MAGIC
# MAGIC **Source:** Table 1 (lipid panel) and Table 2A (secondary causes). **60 rows.**
# MAGIC
# MAGIC | `role` | `test_key` | n |
# MAGIC |---|---|---|
# MAGIC | `LIPID` | `TC` | 4 |
# MAGIC | | `LDL` | 12 |
# MAGIC | | `HDL` | 8 |
# MAGIC | | `TG` | 7 |
# MAGIC | `SECONDARY` | `TSH` | 2 |
# MAGIC | | `ALP` | 2 |
# MAGIC | | `TBIL` | 3 |
# MAGIC | | `URINE_PROT_24H` | 3 |
# MAGIC | | `UPCR` | 2 |
# MAGIC | | `CREAT` | 6 |
# MAGIC | | `EGFR` | 5 |
# MAGIC | | `HBA1C` | 4 |
# MAGIC | | `GLUCOSE_CAP` | 1 |
# MAGIC | | `GLUCOSE_VEN` | 1 |
# MAGIC

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE workspace_sdphenotypecore.fh.fh_ref_loinc AS
# MAGIC SELECT * FROM VALUES
# MAGIC   -- ===== TABLE 1: LIPID PANEL =====
# MAGIC   -- Total cholesterol (4)
# MAGIC   ('LIPID','TC','2093-3'),
# MAGIC   ('LIPID','TC','48620-9'),
# MAGIC   ('LIPID','TC','35200-5'),
# MAGIC   ('LIPID','TC','14647-2'),
# MAGIC   -- LDL-C (12) -- block ENDS at 14815-5
# MAGIC   ('LIPID','LDL','2089-1'),
# MAGIC   ('LIPID','LDL','18262-6'),
# MAGIC   ('LIPID','LDL','49132-4'),
# MAGIC   ('LIPID','LDL','35198-1'),
# MAGIC   ('LIPID','LDL','39469-2'),
# MAGIC   ('LIPID','LDL','12773-8'),
# MAGIC   ('LIPID','LDL','18261-8'),
# MAGIC   ('LIPID','LDL','22748-8'),
# MAGIC   ('LIPID','LDL','13457-7'),
# MAGIC   ('LIPID','LDL','9346-8'),
# MAGIC   ('LIPID','LDL','2574-2'),
# MAGIC   ('LIPID','LDL','14815-5'),                 -- resolves as "Lipoprotein.beta"; beta-LP is LDL
# MAGIC   -- HDL-C (8) -- block BEGINS at 2085-9
# MAGIC   ('LIPID','HDL','2085-9'),
# MAGIC   ('LIPID','HDL','49130-8'),
# MAGIC   ('LIPID','HDL','35197-3'),
# MAGIC   ('LIPID','HDL','12771-2'),
# MAGIC   ('LIPID','HDL','12772-0'),
# MAGIC   ('LIPID','HDL','18263-4'),
# MAGIC   ('LIPID','HDL','27340-9'),
# MAGIC   ('LIPID','HDL','14646-4'),
# MAGIC   -- Triglycerides (7) -- block BEGINS at 2571-8, the highest-volume lipid concept here
# MAGIC   ('LIPID','TG','2571-8'),
# MAGIC   ('LIPID','TG','30524-3'),
# MAGIC   ('LIPID','TG','3048-6'),
# MAGIC   ('LIPID','TG','35217-9'),
# MAGIC   ('LIPID','TG','28554-4'),
# MAGIC   ('LIPID','TG','14927-8'),
# MAGIC   ('LIPID','TG','47210-0'),
# MAGIC
# MAGIC   -- ===== TABLE 2A: SECONDARY CAUSES =====
# MAGIC   -- Hypothyroidism: TSH >= 10 mIU/L
# MAGIC   ('SECONDARY','TSH','11579-0'),
# MAGIC   ('SECONDARY','TSH','24348-5'),
# MAGIC   ('SECONDARY','TSH','3016-3'),
# MAGIC   -- Biliary obstruction: alkaline phosphatase >= 200 IU/L
# MAGIC   ('SECONDARY','ALP','6768-6'),
# MAGIC   ('SECONDARY','ALP','12805-8'),
# MAGIC   -- Liver disease: total bilirubin > 2.0 mg/dL
# MAGIC   ('SECONDARY','TBIL','35194-0'),
# MAGIC   ('SECONDARY','TBIL','1975-2'),
# MAGIC   ('SECONDARY','TBIL','14631-6'),
# MAGIC   -- Nephrotic syndrome: 24h urine protein > 3 g
# MAGIC   ('SECONDARY','URINE_PROT_24H','21482-5'),
# MAGIC   ('SECONDARY','URINE_PROT_24H','2889-4'),
# MAGIC   ('SECONDARY','URINE_PROT_24H','21028-6'),  -- Table 2A places this here, not under UPCR
# MAGIC   -- Nephrotic syndrome: urine protein/creatinine ratio > 3.0
# MAGIC   ('SECONDARY','UPCR','13801-6'),
# MAGIC   ('SECONDARY','UPCR','2890-2'),
# MAGIC   -- Renal failure: creatinine > 2.6 mg/dL
# MAGIC   ('SECONDARY','CREAT','14682-9'),
# MAGIC   ('SECONDARY','CREAT','2160-0'),
# MAGIC   ('SECONDARY','CREAT','35203-9'),
# MAGIC   ('SECONDARY','CREAT','38483-4'),
# MAGIC   ('SECONDARY','CREAT','59826-8'),
# MAGIC   ('SECONDARY','CREAT','77140-2'),
# MAGIC   -- Renal failure: eGFR < 15 mL/min/BSA
# MAGIC   ('SECONDARY','EGFR','50261-7'),
# MAGIC   ('SECONDARY','EGFR','45066-8'),
# MAGIC   ('SECONDARY','EGFR','48642-3'),
# MAGIC   ('SECONDARY','EGFR','48643-1'),
# MAGIC   ('SECONDARY','EGFR','33914-3'),
# MAGIC   -- Diabetes: HbA1c > 9%
# MAGIC   ('SECONDARY','HBA1C','4549-2'),
# MAGIC   ('SECONDARY','HBA1C','17855-8'),
# MAGIC   ('SECONDARY','HBA1C','17856-6'),
# MAGIC   ('SECONDARY','HBA1C','41995-2'),
# MAGIC   -- Diabetes: FASTING glucose. 1556-0 is capillary (> 200 mg/dL),
# MAGIC   -- 1558-6 is serum/plasma (> 220 mg/dL). Both are fasting-specific codes.
# MAGIC   ('SECONDARY','GLUCOSE_CAP','1556-0'),
# MAGIC   ('SECONDARY','GLUCOSE_VEN','1558-6')
# MAGIC AS t(role, test_key, loinc);

# COMMAND ----------

# MAGIC %md
# MAGIC ## 4 · Lipid-lowering drugs — `fh_ref_rxnorm`
# MAGIC
# MAGIC **Source:** Table 3A. **35 rows**, one per RxNorm code listed.
# MAGIC
# MAGIC The counts are per *code*, not per compound: cerivastatin has two codes, evolocumab four
# MAGIC and alirocumab eight. The compound each code represents is annotated inline so the code
# MAGIC list can be checked against Table 3A without leaving the notebook — provenance that a
# MAGIC methods section will need.
# MAGIC
# MAGIC These are **ingredient-level** codes. `fh_llt_concepts` expands them down the
# MAGIC `concept_ancestor` hierarchy to reach actual drug products, and unions the seeds back in so
# MAGIC that brand and source-vocabulary concepts with no descendants are not lost.
# MAGIC
# MAGIC Table 3B's apheresis procedures live in `fh_ref_dx_codes` under `group = 'LLT_PROC'`, not
# MAGIC here.

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE workspace_sdphenotypecore.fh.fh_ref_rxnorm AS
# MAGIC SELECT * FROM VALUES
# MAGIC   -- Statins
# MAGIC   ('LLT','36567'),      -- simvastatin       (Zocor, Lipex)
# MAGIC   ('LLT','41127'),      -- fluvastatin       (Lescol)
# MAGIC   ('LLT','6472'),       -- lovastatin        (Mevacor, Altoprev)
# MAGIC   ('LLT','42463'),      -- pravastatin       (Pravachol, Lipostat)
# MAGIC   ('LLT','861634'),     -- pitavastatin      (Livalo, Pitava)
# MAGIC   ('LLT','83367'),      -- atorvastatin      (Lipitor, Torvast)
# MAGIC   ('LLT','301542'),     -- rosuvastatin      (Crestor)
# MAGIC   ('LLT','221072'),     -- cerivastatin      (Lipobay, Baycol)
# MAGIC   ('LLT','1152441'),    -- cerivastatin      (second code)
# MAGIC   -- Niacin and fibrates
# MAGIC   ('LLT','7393'),       -- niacin            (Niaspan, Niacor)
# MAGIC   ('LLT','8703'),       -- fenofibrate       (Tricor, Trilipix)
# MAGIC   ('LLT','4719'),       -- gemfibrozil       (Lopid)
# MAGIC   -- Absorption inhibitors and bile acid sequestrants
# MAGIC   ('LLT','341248'),     -- ezetimibe         (Zetia, Ezetrol)
# MAGIC   ('LLT','141626'),     -- colesevelam       (Welchol)
# MAGIC   ('LLT','2447'),       -- cholestyramine    (Questran, Prevalite)
# MAGIC   ('LLT','2685'),       -- colestipol        (Colestid)
# MAGIC   -- Homozygous-FH agents
# MAGIC   ('LLT','1367839'),    -- mipomersen        (Kynamro)
# MAGIC   ('LLT','1364479'),    -- lomitapide        (Juxtapid)
# MAGIC   -- PCSK9 inhibitors -- evolocumab (Repatha), 4 codes
# MAGIC   ('LLT','1665895'),
# MAGIC   ('LLT','1665900'),
# MAGIC   ('LLT','1665904'),
# MAGIC   ('LLT','1665906'),
# MAGIC   -- PCSK9 inhibitors -- alirocumab (Praluent), 8 codes
# MAGIC   ('LLT','1659156'),
# MAGIC   ('LLT','1659161'),
# MAGIC   ('LLT','1659165'),
# MAGIC   ('LLT','1659167'),
# MAGIC   ('LLT','1659177'),
# MAGIC   ('LLT','1659179'),
# MAGIC   ('LLT','1659182'),
# MAGIC   ('LLT','1659183'),
# MAGIC   -- Combination products
# MAGIC   ('LLT','495215'),     -- ezetimibe/simvastatin      (Vytorin)
# MAGIC   ('LLT','1372731'),    -- niacin/simvastatin         (Simcor)
# MAGIC   ('LLT','327008'),     -- niacin/lovastatin          (Advicor)
# MAGIC   ('LLT','404914'),     -- amlodipine/atorvastatin    (Caduet)
# MAGIC   ('LLT','1372754')     -- sitagliptin/simvastatin    (Juvisync)
# MAGIC AS t(role, rxnorm);

# COMMAND ----------

# MAGIC %md
# MAGIC ## 4 · Pregnancy ICD-9 prefixes — `fh_ref_pregnancy`
# MAGIC
# MAGIC **Source:** Table 2B. **5 rows.**
# MAGIC
# MAGIC These are **prefixes**, matched with `LIKE prefix || '%'`, so `645` catches `645.1`, `645.2`
# MAGIC and so on. ICD-9-CM codes are numeric-dotted, so the prefix cannot stray outside its
# MAGIC intended family.
# MAGIC
# MAGIC Ascertainment is ICD-9 only, which is what Table 2B specifies. Pregnancies coded in ICD-10
# MAGIC (O00–O9A, Z33–Z34) are invisible to this criterion — see Stage I deviation 3.

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE workspace_sdphenotypecore.fh.fh_ref_pregnancy AS
# MAGIC SELECT * FROM VALUES
# MAGIC   ('PREGNANCY','V22'),   -- normal pregnancy
# MAGIC   ('PREGNANCY','V23'),   -- supervision of high-risk pregnancy
# MAGIC   ('PREGNANCY','645'),   -- late pregnancy
# MAGIC   ('PREGNANCY','651'),   -- multiple gestation
# MAGIC   ('PREGNANCY','652')    -- malposition and malpresentation of fetus
# MAGIC AS t(role, icd9_prefix);

# COMMAND ----------

# MAGIC %md
# MAGIC ## Verification
# MAGIC
# MAGIC **Expected:** 160 / 60 / 35 / 5, with `n` equal to `n_distinct` on every row. A mismatch
# MAGIC between the two columns means partial duplication, which a bare row count would hide.

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT 'fh_ref_dx_codes'  AS tbl, count(*) AS n, count(DISTINCT code_type, `group`, code) AS n_distinct, 160 AS expected
# MAGIC FROM workspace_sdphenotypecore.fh.fh_ref_dx_codes
# MAGIC UNION ALL
# MAGIC SELECT 'fh_ref_loinc',  count(*), count(DISTINCT role, test_key, loinc), 60
# MAGIC FROM workspace_sdphenotypecore.fh.fh_ref_loinc
# MAGIC UNION ALL
# MAGIC SELECT 'fh_ref_rxnorm', count(*), count(DISTINCT role, rxnorm), 35
# MAGIC FROM workspace_sdphenotypecore.fh.fh_ref_rxnorm
# MAGIC UNION ALL
# MAGIC SELECT 'fh_ref_pregnancy', count(*), count(DISTINCT role, icd9_prefix), 5
# MAGIC FROM workspace_sdphenotypecore.fh.fh_ref_pregnancy;