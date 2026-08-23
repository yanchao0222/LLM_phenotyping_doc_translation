# Databricks notebook source
# MAGIC %md
# MAGIC # Acute Kidney Injury (AKI) — Phenotype 
# MAGIC
# MAGIC | | |
# MAGIC |---|---|
# MAGIC | **Phenotype** | Acute Kidney Injury (AKI) |
# MAGIC | **Source location** | [PheKB — Acute Kidney Injury (AKI)](https://phekb.org/phenotype/acute-kidney-injury-aki) |
# MAGIC | **Implemented by** | Srushti Gangireddy, Wu-Chen Su |
# MAGIC | **Created** | 2026-08-01 |
# MAGIC | **Last modified** | 2026-08-22 |
# MAGIC | **Data source** | VUMC Synthetic Derivative, OMOP CDM v5 (`victr_sd.sd_omop_prod`) |
# MAGIC | **Output schema** | `workspace_sdphenotypecore.phekb_aki` |
# MAGIC | **Platform** | Databricks SQL |
# MAGIC | **Prerequisite** | Run `00_AKI_setup` first |
# MAGIC
# MAGIC ## Purpose
# MAGIC
# MAGIC This is a manual implementation of the published AKI phenotype
# MAGIC algorithm. It serves as the **gold standard** against which LLM-generated
# MAGIC implementations of the same algorithm are compared — Claude Opus 4.1
# MAGIC and OpenAI o3.
# MAGIC
# MAGIC
# MAGIC ## Phenotype definition
# MAGIC
# MAGIC Acute kidney injury is a rapid decline in kidney function. The algorithm follows the
# MAGIC KDIGO classification, which defines AKI on temporal change in serum creatinine **or**
# MAGIC urine output. Because urine output is not recorded for most patients outside intensive
# MAGIC care, this algorithm — like the source document and the published electronic AKI
# MAGIC algorithms it cites — applies the simplified KDIGO definition based on serum creatinine
# MAGIC alone.
# MAGIC
# MAGIC ### Classification 
# MAGIC
# MAGIC Every patient is first screened for pre-existing end-stage renal disease. A kidney
# MAGIC transplant or dialysis diagnosis or procedure recorded before the presentation window
# MAGIC excludes the patient as **ESRD**; the remaining classes all require its absence.
# MAGIC
# MAGIC | Class | Definition |
# MAGIC |---|---|
# MAGIC | **Unknown** | No baseline SCr, **or** no SCr available during the presentation window |
# MAGIC | **No AKI** (control) | Baseline SCr available; **all** daily kidney excretory function during the window is normal |
# MAGIC | **AKI** (case) | Baseline SCr available; **at least one** daily kidney excretory function during the window is abnormal |
# MAGIC
# MAGIC A day is abnormal when SCr has risen ≥50% above baseline. Days with multiple
# MAGIC measurements use the average.
# MAGIC
# MAGIC **Baseline SCr** is established by an ordered priority rule:
# MAGIC
# MAGIC 1. Median SCr in the 7–365 days before presentation
# MAGIC 2. Minimum SCr in the 0–7 days before presentation
# MAGIC 3. Minimum SCr from the presentation to the SCr under consideration
# MAGIC
# MAGIC ### Characterization of AKI cases 
# MAGIC
# MAGIC - **AKI block** — consecutive days with SCr >50% baseline; the block is terminated on
# MAGIC   the day SCr returns below 50% baseline. A window may contain more than one block.
# MAGIC - **Recurrence** — another increase in SCr to 1.5× baseline more than two days after
# MAGIC   resolution of the previous block.
# MAGIC - **Severity** — AKIN stage from the ratio of the block's maximum SCr to baseline:
# MAGIC   stage 1 ≥1.5- to 2-fold, stage 2 2- to 3-fold, stage 3 >3-fold.
# MAGIC - **Subtype** — by duration (Stevens et al.): transient AKI (tAKI) lasting less than
# MAGIC   48 hours, sustained AKI (sAKI) lasting more than 48 hours. Sustained AKI is
# MAGIC   associated with worse clinical outcomes.
# MAGIC - **Overall** — the **first** block's severity and subtype characterize the window as
# MAGIC   a whole (4.4), even when a later block is more severe.
# MAGIC
# MAGIC ## Algorithm summary
# MAGIC
# MAGIC | Step | Table | What it does |
# MAGIC |---|---|---|
# MAGIC | 1 | `aki_anchor` | Identify potential AKI presentation windows (ED visit + 7 days) |
# MAGIC | 2 | `aki_esrd` | Exclude pre-existing dialysis or kidney transplant |
# MAGIC | 3 | `aki_scr` | Extract serum creatinine around each presentation |
# MAGIC | 4 | `aki_baseline` | Derive baseline creatinine by 3-line priority rule |
# MAGIC | 5 | `aki_daily` | Per-day creatinine ratio and normal/abnormal status |
# MAGIC | 6 | `aki_blocks` | Group abnormal days into episodes; stage, subtype, recurrence |
# MAGIC | 7 | `aki_result` | Final per-presentation classification |
# MAGIC
# MAGIC Final classification is one of **ESRD** (excluded), **Unknown** (insufficient
# MAGIC data), **No AKI**, or **AKI**.
# MAGIC
# MAGIC Each step writes a table rather than nesting into one query. Every intermediate
# MAGIC stays inspectable.
# MAGIC
# MAGIC ## Known deviations from the source document
# MAGIC
# MAGIC The document contradicts itself in several places. Each resolution below changes
# MAGIC results and is stated so a reader can disagree with the reading rather than
# MAGIC having to reverse-engineer it.
# MAGIC
# MAGIC | # | Issue | Resolution |
# MAGIC |---|---|---|
# MAGIC | 1 | Abnormal-day threshold given as both "higher than 50%" (`> 1.5`) and "≥50% increase" (`>= 1.5`), while AKIN stage 1 begins at `≥ 1.5` | **`>= 1.5`.** |
# MAGIC | 2 | AKIN stage 3 stated as "> 3-fold"; canonical AKIN is **≥** 3.0 | **Doc-literal `> 3`.** |
# MAGIC | 3 | Recurrence is "more than two days after **resolution**" — resolution being the recovery day, not the last abnormal day | Measured from `recovery_date`, the first normal day after a block ends |
# MAGIC | 4 | Baseline line 3 is a *running* minimum over the window, so any presentation with in-window creatinine technically has a baseline — emptying the document's "no baseline" Unknown class | Unknown = no in-window SCr, **or** no L1/L2 baseline and fewer than 2 in-window SCr days. Under L3 the first day is its own baseline and can never be abnormal, so a single value carries no information about a rise |
# MAGIC | 5 | Subtype is defined only as transient/sustained, with no category for an episode still elevated when observation ends | Third value `indeterminate`. Prevents an unresolved episode being silently called transient |
# MAGIC | 6 | Encounter type and window length are never specified | ED visits (`visit_concept_id = 9203`), 7-day window. Both are our site choices — see `AKI_setup` |
# MAGIC | 7 | Serum creatinine concept set: the document's LOINC list overlaps the usable local set at one concept | Local set derived by profiling — see `AKI_setup` |
# MAGIC
# MAGIC ## Output dictionary — `aki_result`
# MAGIC
# MAGIC | Column | Meaning |
# MAGIC |---|---|
# MAGIC | `presentation_id` | `visit_occurrence_id` of the anchoring ED visit |
# MAGIC | `presentation_date`, `window_end` | Observation window bounds |
# MAGIC | `esrd_flag` | Pre-existing dialysis or transplant |
# MAGIC | `baseline_scr`, `baseline_src` | Baseline value and which priority line supplied it |
# MAGIC | `aki_class` | `ESRD` / `Unknown` / `No AKI` / `AKI` |
# MAGIC | `n_blocks` | Distinct AKI episodes in the window |
# MAGIC | `n_recurrences` | Episodes qualifying as recurrence |
# MAGIC | `overall_stage` | AKIN 1–3, from the **first** block (document 4.4) |
# MAGIC | `overall_subtype` | `tAKI` / `sAKI` / `indeterminate`, from the first block |
# MAGIC
# MAGIC `baseline_src` reports `L1`, `L2` or `none`. It does not currently report `L3`:
# MAGIC the value is carried through from `aki_baseline`, which by construction cannot
# MAGIC know about the running minimum applied in Step 5. 
# MAGIC
# MAGIC
# MAGIC #### Citation
# MAGIC
# MAGIC > Shang N, Kiryluk K. *Acute Kidney Injury (AKI) Phenotype Algorithm Pseudo
# MAGIC > Code*, V1. Division of Nephrology, Department of Medicine, Vagelos College of
# MAGIC > Physicians and Surgeons, Columbia University, 2022. Available from PheKB:
# MAGIC > https://phekb.org/phenotype/acute-kidney-injury-aki

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE SCHEMA IF NOT EXISTS workspace_sdphenotypecore.phekb_aki;
# MAGIC USE CATALOG workspace_sdphenotypecore;
# MAGIC USE SCHEMA phekb_aki;

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 1 · Identify potential AKI presentation windows
# MAGIC
# MAGIC Each emergency department visit anchors one candidate window, running from the
# MAGIC visit date through seven days after it.
# MAGIC
# MAGIC The document requires a "potential AKI presentation time window" but never
# MAGIC defines the qualifying encounter, noting only that its reference implementation
# MAGIC targeted the emergency visit and that the algorithm "can be customized to
# MAGIC different event related AKI". The ED anchor and the 7-day window are site choices.
# MAGIC
# MAGIC **Output:** `aki_anchor` — one row per presentation.

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE aki_anchor AS
# MAGIC SELECT person_id,
# MAGIC        visit_occurrence_id            AS presentation_id,
# MAGIC        visit_start_date               AS presentation_date,
# MAGIC        date_add(visit_start_date, 7)  AS window_end          
# MAGIC FROM   victr_sd.sd_omop_prod.visit_occurrence
# MAGIC WHERE  visit_concept_id = 9203;

# COMMAND ----------

# MAGIC %md
# MAGIC **Validation.** Presentation and distinct-person counts. Presentations
# MAGIC exceed persons because a patient may have many ED visits, each anchoring its own
# MAGIC window.

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT COUNT(*) AS n_presentations, COUNT(DISTINCT person_id) AS n_persons
# MAGIC FROM aki_anchor;

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 2 · Exclude pre-existing ESRD
# MAGIC
# MAGIC Presentations from patients with a dialysis or kidney-transplant code recorded
# MAGIC ** before** the presentation date are excluded. 
# MAGIC
# MAGIC
# MAGIC **Output:** `aki_esrd` — presentations to exclude.

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE aki_esrd AS
# MAGIC WITH ev AS (
# MAGIC   SELECT c.person_id, c.condition_start_date AS ev_date
# MAGIC   FROM victr_sd.sd_omop_prod.condition_occurrence c
# MAGIC   JOIN aki_excl_concepts x
# MAGIC     ON (x.concept_id = c.condition_concept_id or x.concept_id = c.condition_source_concept_id) AND x.domain_id = 'Condition'
# MAGIC   UNION ALL
# MAGIC   SELECT p.person_id, p.procedure_date
# MAGIC   FROM victr_sd.sd_omop_prod.procedure_occurrence p
# MAGIC   JOIN aki_excl_concepts x
# MAGIC     ON (x.concept_id = p.procedure_concept_id or x.concept_id = p.procedure_source_concept_id) AND x.domain_id = 'Procedure'
# MAGIC   UNION ALL
# MAGIC   SELECT o.person_id, o.observation_date
# MAGIC   FROM victr_sd.sd_omop_prod.observation o
# MAGIC   JOIN aki_excl_concepts x
# MAGIC     ON (x.concept_id = o.observation_concept_id or x.concept_id = o.observation_source_concept_id) AND x.domain_id = 'Observation'
# MAGIC )
# MAGIC SELECT DISTINCT a.presentation_id
# MAGIC FROM aki_anchor a
# MAGIC JOIN ev ON ev.person_id = a.person_id
# MAGIC        AND ev.ev_date < a.presentation_date;   

# COMMAND ----------

# MAGIC %md
# MAGIC **Validation.** Count of excluded presentations.

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT COUNT(*) AS n_esrd_presentations FROM aki_esrd;

# COMMAND ----------

# MAGIC %md
# MAGIC
# MAGIC ## Step 3 · Extract serum creatinine
# MAGIC
# MAGIC All serum creatinine from 365 days before the presentation through the window
# MAGIC end. 
# MAGIC
# MAGIC Concept selection is discussed in `AKI_setup` .
# MAGIC
# MAGIC Two guards:
# MAGIC
# MAGIC - **Plausibility.** `0 < value < 30` mg/dL. Values outside this range are
# MAGIC   implausible for serum creatinine and typically indicate a unit or
# MAGIC   specimen-type problem.
# MAGIC - **De-duplication.** `DISTINCT (person_id, measurement_date, value_as_number)`
# MAGIC   collapses the double-counting produced when one physical result is stored
# MAGIC   against both a site-local concept and its OMOP standard mapping. This is
# MAGIC   value-based, so two genuinely distinct draws with identical values on the same
# MAGIC   day also collapse — acceptable, because the daily value is a mean and the
# MAGIC   alternative over-counts far more severely on this data model.
# MAGIC
# MAGIC **Output:** `aki_scr` — one row per presentation per creatinine result.

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE aki_scr AS
# MAGIC WITH scr_raw AS (
# MAGIC   SELECT DISTINCT person_id, measurement_date, value_as_number
# MAGIC   FROM victr_sd.sd_omop_prod.measurement
# MAGIC   WHERE (measurement_concept_id        IN (2004293111,3016723,3051825,2000323130,2001613121,2006080014)
# MAGIC       OR measurement_source_concept_id IN (2004293111,3016723,3051825,2000323130,2001613121,2006080014))
# MAGIC     AND value_as_number > 0 AND value_as_number < 30   
# MAGIC )
# MAGIC SELECT a.presentation_id, a.person_id, a.presentation_date, a.window_end,
# MAGIC        s.measurement_date  AS scr_date,
# MAGIC        s.value_as_number   AS scr
# MAGIC FROM scr_raw s
# MAGIC JOIN aki_anchor a
# MAGIC   ON a.person_id = s.person_id
# MAGIC  AND s.measurement_date >= date_sub(a.presentation_date, 365)  
# MAGIC  AND s.measurement_date <= a.window_end;

# COMMAND ----------

# MAGIC %md
# MAGIC **Validation.** Row count and how many presentations have any creatinine
# MAGIC at all. Presentations absent here become `Unknown` in Step 7.

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT COUNT(*) AS n_scr_rows, COUNT(DISTINCT presentation_id) AS n_pres_with_scr
# MAGIC FROM aki_scr;

# COMMAND ----------

# MAGIC %md
# MAGIC
# MAGIC ## Step 4 · Derive baseline serum creatinine
# MAGIC
# MAGIC | Line | Definition | Rationale |
# MAGIC |---|---|---|
# MAGIC | **L1** | Median SCr in the 7–365 days before presentation | Best estimate of the patient's true steady state |
# MAGIC | **L2** | Minimum SCr in the 7 days before presentation | Recent values may already be climbing if the injury has begun; the minimum sits closest to the pre-injury value |
# MAGIC | **L3** | Running minimum from presentation to the value under consideration | Last resort when no history exists; same reasoning as L2 |
# MAGIC
# MAGIC L3 depends on which day is being evaluated, so it cannot be a single
# MAGIC per-presentation value and is applied in Step 5 instead. **`baseline_scr` is
# MAGIC null here exactly when the presentation must fall back to L3.**
# MAGIC
# MAGIC Window boundaries: L1 is `[presentation − 365, presentation − 7]` inclusive; L2
# MAGIC is `(presentation − 7, presentation)`, exclusive at both ends. The two nominally
# MAGIC share day 7, and L1 takes it because it is tried first.
# MAGIC
# MAGIC **Output:** `aki_baseline` — the L1/L2 baseline and which line supplied it.
# MAGIC `baseline_src` is `L1`, `L2`, or `none`; `none` presentations are relabelled
# MAGIC `L3` in Step 5 once the running minimum is computed.

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE aki_baseline AS
# MAGIC SELECT presentation_id, person_id, presentation_date, window_end,
# MAGIC        COALESCE(l1_median, l2_min) AS baseline_scr,
# MAGIC        CASE WHEN l1_median IS NOT NULL THEN 'L1'
# MAGIC             WHEN l2_min    IS NOT NULL THEN 'L2'
# MAGIC             ELSE 'none' END          AS baseline_src
# MAGIC FROM (
# MAGIC   SELECT s.presentation_id, s.person_id, s.presentation_date, s.window_end,
# MAGIC     percentile(
# MAGIC       CASE WHEN d.scr_date BETWEEN date_sub(s.presentation_date, 365)
# MAGIC                                AND date_sub(s.presentation_date, 7)
# MAGIC            THEN d.scr_day END, 0.5)                                    AS l1_median,
# MAGIC     MIN(
# MAGIC       CASE WHEN d.scr_date >  date_sub(s.presentation_date, 7)
# MAGIC             AND d.scr_date <  s.presentation_date
# MAGIC            THEN d.scr_day END)                                         AS l2_min
# MAGIC   FROM (SELECT DISTINCT presentation_id, person_id, presentation_date, window_end
# MAGIC         FROM aki_scr) s
# MAGIC   JOIN (SELECT presentation_id, scr_date, AVG(scr)
# MAGIC    AS scr_day
# MAGIC         FROM aki_scr GROUP BY presentation_id, scr_date) d
# MAGIC     ON d.presentation_id = s.presentation_id
# MAGIC   GROUP BY s.presentation_id, s.person_id, s.presentation_date, s.window_end
# MAGIC );

# COMMAND ----------

# MAGIC %md
# MAGIC **Validation.** Distribution across baseline lines. `none` is the L3
# MAGIC fallback population — report this, since a large share means the cohort rests on
# MAGIC the weakest baseline definition.

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT baseline_src, COUNT(*) AS n
# MAGIC FROM aki_baseline
# MAGIC GROUP BY baseline_src ORDER BY baseline_src;

# COMMAND ----------

# MAGIC %md
# MAGIC
# MAGIC ## Step 5 · Daily kidney excretory function
# MAGIC
# MAGIC One row per presentation-day, carrying the daily creatinine, the effective
# MAGIC baseline, their ratio, and a normal/abnormal (`NO`/`YES`) status.
# MAGIC
# MAGIC **Output:** `aki_daily` — one row per presentation-day with an observed
# MAGIC creatinine. Days without a draw are simply absent; they are neither `YES` nor
# MAGIC `NO`, and Step 6 treats them accordingly.

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE aki_daily AS
# MAGIC WITH base AS (
# MAGIC   SELECT b.presentation_id, b.person_id, b.presentation_date, b.window_end,
# MAGIC          b.baseline_scr AS fixed_base, b.baseline_src
# MAGIC   FROM   aki_baseline b
# MAGIC   LEFT JOIN aki_esrd e USING (presentation_id)
# MAGIC   WHERE  e.presentation_id IS NULL
# MAGIC ),
# MAGIC inwin AS (
# MAGIC   SELECT presentation_id, scr_date, AVG(scr) AS scr_day
# MAGIC   FROM   aki_scr
# MAGIC   WHERE  scr_date BETWEEN presentation_date AND window_end
# MAGIC   GROUP  BY presentation_id, scr_date
# MAGIC ),
# MAGIC daily AS (
# MAGIC   SELECT b.presentation_id, b.person_id, b.presentation_date, b.window_end,
# MAGIC          b.fixed_base, b.baseline_src, i.scr_date, i.scr_day,
# MAGIC          MIN(i.scr_day) OVER (PARTITION BY i.presentation_id ORDER BY i.scr_date
# MAGIC                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS run_min
# MAGIC   FROM inwin i JOIN base b USING (presentation_id)
# MAGIC )
# MAGIC SELECT presentation_id, person_id, presentation_date, window_end,
# MAGIC        scr_date, scr_day,
# MAGIC        CASE WHEN fixed_base IS NOT NULL THEN baseline_src
# MAGIC             ELSE 'L3' END                         AS baseline_src,
# MAGIC        COALESCE(fixed_base, run_min)              AS eff_base,   
# MAGIC        scr_day / COALESCE(fixed_base, run_min)    AS ratio,
# MAGIC        CASE WHEN scr_day / COALESCE(fixed_base, run_min) >= 1.5
# MAGIC             THEN 'YES' ELSE 'NO' END              AS status
# MAGIC FROM daily;

# COMMAND ----------

# MAGIC %md
# MAGIC **Validation.** Status by baseline line. `baseline_src = 'none'` rows are
# MAGIC the L3 population; the `YES` rate among them should be lower than for L1/L2,
# MAGIC because day 1 can never be abnormal under L3.

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT status, baseline_src, COUNT(*) AS n_days
# MAGIC FROM aki_daily
# MAGIC GROUP BY status, baseline_src ORDER BY status, baseline_src;

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 6 · AKI blocks, staging, subtyping, recurrence
# MAGIC
# MAGIC An **AKI block** is a run of consecutive abnormal days — one AKI episode. A block
# MAGIC is terminated **only** by a normal day. Days with no creatinine drawn are absent
# MAGIC from `aki_daily` and never split a block, however many of them there are. 
# MAGIC
# MAGIC **AKIN staging**, from the block's maximum ratio (document 4.3.1):
# MAGIC
# MAGIC | Stage | Ratio to baseline |
# MAGIC |---|---|
# MAGIC | 1 | ≥ 1.5 to < 2-fold |
# MAGIC | 2 | ≥ 2 to ≤ 3-fold |
# MAGIC | 3 | > 3-fold |
# MAGIC
# MAGIC Stage 3 uses `>` per the document; canonical AKIN uses `≥ 3.0`.
# MAGIC
# MAGIC **Subtype**, from block duration:
# MAGIC
# MAGIC | Value | Condition |
# MAGIC |---|---|
# MAGIC | `sAKI` | Spans ≥ 2 days — sustained, > 48 hours |
# MAGIC | `tAKI` | Shorter, **and** a normal day was observed afterwards — transient, resolved |
# MAGIC | `indeterminate` | Shorter, but no recovery was ever observed (deviation 5) |
# MAGIC
# MAGIC `indeterminate` is a deliberate extension. The document's binary rule would call
# MAGIC an episode still elevated at the end of the window "transient" although nothing
# MAGIC was observed to resolve — a silent, one-directional misclassification. Its
# MAGIC prevalence is a useful QC signal: a high rate means the 7-day window is
# MAGIC truncating episodes.
# MAGIC
# MAGIC **Recovery.** `recovery_date` is the first normal day after a block ends and
# MAGIC before the next begins. It is the block's resolution, and the anchor for
# MAGIC recurrence.
# MAGIC
# MAGIC **Recurrence** requires a new block starting more than two days after the
# MAGIC *previous block's recovery* — not after its last abnormal day (deviation 3).
# MAGIC Measuring from the last abnormal day understates the required gap and over-calls
# MAGIC recurrence. Because only a normal day can now terminate a block, every non-first
# MAGIC block has a recovery date by construction, so this rule applies uniformly.
# MAGIC
# MAGIC **Output:** `aki_blocks` — one row per AKI episode.

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE aki_blocks AS
# MAGIC WITH d AS (
# MAGIC   SELECT *,
# MAGIC          SUM(CASE WHEN status='NO' THEN 1 ELSE 0 END)
# MAGIC            OVER (PARTITION BY presentation_id ORDER BY scr_date
# MAGIC                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS no_seen
# MAGIC   FROM aki_daily
# MAGIC ),
# MAGIC y AS (
# MAGIC   SELECT *,
# MAGIC          LAG(scr_date) OVER (PARTITION BY presentation_id ORDER BY scr_date) AS prev_yes,
# MAGIC          LAG(no_seen)  OVER (PARTITION BY presentation_id ORDER BY scr_date) AS prev_no_seen
# MAGIC   FROM d WHERE status='YES'
# MAGIC ),
# MAGIC y2 AS (
# MAGIC   SELECT *,
# MAGIC          CASE WHEN prev_yes IS NULL
# MAGIC                 OR no_seen > prev_no_seen
# MAGIC               THEN 1 ELSE 0 END AS new_block
# MAGIC   FROM y
# MAGIC ),
# MAGIC y3 AS (
# MAGIC   SELECT *,
# MAGIC          SUM(new_block) OVER (PARTITION BY presentation_id ORDER BY scr_date
# MAGIC                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS block_id
# MAGIC   FROM y2
# MAGIC ),
# MAGIC blk AS (
# MAGIC   SELECT presentation_id, person_id, block_id,
# MAGIC          MIN(scr_date) AS block_start, MAX(scr_date) AS block_end,
# MAGIC          COUNT(DISTINCT scr_date) AS n_days,          -- diagnostic only
# MAGIC          datediff(MAX(scr_date), MIN(scr_date)) AS span_days,
# MAGIC          MAX(ratio)    AS max_ratio
# MAGIC   FROM y3 GROUP BY presentation_id, person_id, block_id
# MAGIC ),
# MAGIC ranked AS (
# MAGIC   SELECT *,
# MAGIC          ROW_NUMBER() OVER (PARTITION BY presentation_id ORDER BY block_start) AS block_rank,
# MAGIC          LEAD(block_start) OVER (PARTITION BY presentation_id ORDER BY block_start) AS next_block_start
# MAGIC   FROM blk
# MAGIC ),
# MAGIC with_recovery AS (
# MAGIC   SELECT
# MAGIC       r.presentation_id, r.person_id, r.block_id, r.block_rank,
# MAGIC       r.block_start, r.block_end, r.n_days, r.span_days,
# MAGIC       r.max_ratio, r.next_block_start,
# MAGIC       MIN(d.scr_date) AS recovery_date
# MAGIC   FROM ranked r
# MAGIC   LEFT JOIN aki_daily d
# MAGIC     ON d.presentation_id = r.presentation_id
# MAGIC    AND d.status = 'NO'
# MAGIC    AND d.scr_date > r.block_end
# MAGIC    AND (r.next_block_start IS NULL OR d.scr_date < r.next_block_start)
# MAGIC   GROUP BY
# MAGIC       r.presentation_id, r.person_id, r.block_id, r.block_rank,
# MAGIC       r.block_start, r.block_end, r.n_days, r.span_days,
# MAGIC       r.max_ratio, r.next_block_start
# MAGIC ),
# MAGIC recurrence_ready AS (
# MAGIC   SELECT w.*,
# MAGIC          LAG(recovery_date) OVER (
# MAGIC            PARTITION BY presentation_id ORDER BY block_start
# MAGIC          ) AS prev_recovery_date
# MAGIC   FROM with_recovery w
# MAGIC )
# MAGIC
# MAGIC SELECT presentation_id, person_id, block_id, block_rank,
# MAGIC        block_start, block_end, n_days, span_days, max_ratio, recovery_date,
# MAGIC
# MAGIC        CASE WHEN max_ratio >  3   THEN 3
# MAGIC             WHEN max_ratio >= 2   THEN 2
# MAGIC             WHEN max_ratio >= 1.5 THEN 1
# MAGIC             ELSE NULL END                                     AS akin_stage,
# MAGIC
# MAGIC        CASE WHEN span_days >= 2 THEN 'sAKI' ELSE 'tAKI' END   AS subtype_doc,
# MAGIC
# MAGIC        CASE
# MAGIC          WHEN span_days >= 2 THEN 'sAKI'
# MAGIC          WHEN recovery_date IS NOT NULL THEN 'tAKI'
# MAGIC          ELSE 'indeterminate'
# MAGIC        END AS subtype,
# MAGIC
# MAGIC        CASE
# MAGIC           WHEN block_rank = 1 THEN 0
# MAGIC           WHEN prev_recovery_date IS NOT NULL
# MAGIC            AND block_start > date_add(prev_recovery_date, 2)
# MAGIC           THEN 1
# MAGIC           ELSE 0
# MAGIC        END AS is_recurrence
# MAGIC
# MAGIC FROM recurrence_ready;

# COMMAND ----------

# MAGIC %md
# MAGIC **Validation.** Blocks by stage and subtype. A large `indeterminate` share
# MAGIC indicates window truncation, not a data error.

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT akin_stage, subtype_doc, COUNT(*) AS n_blocks
# MAGIC FROM aki_blocks
# MAGIC GROUP BY akin_stage, subtype_doc
# MAGIC ORDER BY akin_stage, subtype_doc;

# COMMAND ----------

# MAGIC %md
# MAGIC ---
# MAGIC
# MAGIC ## Step 7 · Final classification
# MAGIC
# MAGIC One row per presentation, in the four classes the document defines:
# MAGIC
# MAGIC | Class | Condition |
# MAGIC |---|---|
# MAGIC | `ESRD` | Dialysis or transplant before the presentation |
# MAGIC | `Unknown` | No in-window creatinine, **or** no L1/L2 baseline and fewer than 2 in-window creatinine days |
# MAGIC | `No AKI` | Baseline available, every in-window day normal |
# MAGIC | `AKI` | Baseline available, at least one in-window day abnormal |
# MAGIC
# MAGIC
# MAGIC **Output:** `aki_result` — one row per presentation. Column meanings are in the
# MAGIC output dictionary at the top of this notebook.

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE aki_result AS
# MAGIC WITH inwin_any AS (
# MAGIC   SELECT
# MAGIC       presentation_id,
# MAGIC       COUNT(DISTINCT scr_date) AS n_inwindow_scr_days
# MAGIC   FROM aki_scr
# MAGIC   WHERE scr_date BETWEEN presentation_date AND window_end
# MAGIC   GROUP BY presentation_id
# MAGIC ),
# MAGIC eff_src AS (
# MAGIC   SELECT presentation_id, MAX(baseline_src) AS baseline_src_eff
# MAGIC   FROM aki_daily
# MAGIC   GROUP BY presentation_id
# MAGIC ),
# MAGIC blk_agg AS (
# MAGIC   
# MAGIC   SELECT presentation_id,
# MAGIC          COUNT(*)           AS n_blocks,
# MAGIC          SUM(is_recurrence) AS n_recurrences,
# MAGIC          MAX(CASE WHEN block_rank=1 THEN akin_stage  END) AS overall_stage,
# MAGIC          MAX(CASE WHEN block_rank=1 THEN subtype_doc END) AS overall_subtype_doc,
# MAGIC          MAX(CASE WHEN block_rank=1 THEN subtype     END) AS overall_subtype
# MAGIC   FROM aki_blocks
# MAGIC   GROUP BY presentation_id
# MAGIC )
# MAGIC SELECT a.presentation_id, a.person_id, a.presentation_date, a.window_end,
# MAGIC        (e.presentation_id IS NOT NULL)  AS esrd_flag,
# MAGIC        b.baseline_scr,
# MAGIC        COALESCE(f.baseline_src_eff, b.baseline_src, 'none') AS baseline_src,
# MAGIC        COALESCE(w.n_inwindow_scr_days, 0)                   AS n_inwindow_scr_days,
# MAGIC
# MAGIC        CASE
# MAGIC          WHEN e.presentation_id IS NOT NULL THEN 'ESRD'
# MAGIC          WHEN w.presentation_id IS NULL     THEN 'Unknown'
# MAGIC          WHEN b.baseline_scr IS NULL
# MAGIC           AND w.n_inwindow_scr_days < 2     THEN 'Unknown'
# MAGIC          WHEN COALESCE(g.n_blocks, 0) = 0   THEN 'No AKI'
# MAGIC          ELSE 'AKI'
# MAGIC        END AS aki_class,
# MAGIC
# MAGIC        CASE
# MAGIC          WHEN e.presentation_id IS NOT NULL THEN 'ESRD'
# MAGIC          WHEN w.presentation_id IS NULL     THEN 'Unknown'
# MAGIC          WHEN COALESCE(g.n_blocks, 0) = 0   THEN 'No AKI'
# MAGIC          ELSE 'AKI'
# MAGIC        END AS aki_class_doc,
# MAGIC
# MAGIC        COALESCE(g.n_blocks, 0)      AS n_blocks,
# MAGIC        COALESCE(g.n_recurrences, 0) AS n_recurrences,
# MAGIC        g.overall_stage,
# MAGIC        g.overall_subtype_doc,
# MAGIC        g.overall_subtype
# MAGIC FROM      aki_anchor    a
# MAGIC LEFT JOIN aki_esrd      e USING (presentation_id)
# MAGIC LEFT JOIN aki_baseline  b USING (presentation_id)
# MAGIC LEFT JOIN eff_src       f USING (presentation_id)
# MAGIC LEFT JOIN inwin_any     w USING (presentation_id)
# MAGIC LEFT JOIN blk_agg       g USING (presentation_id);

# COMMAND ----------

# MAGIC %md
# MAGIC
# MAGIC ## Results
# MAGIC
# MAGIC ### Classification distribution

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT aki_class, aki_class_doc, COUNT(*) AS n_presentations,
# MAGIC        COUNT(DISTINCT person_id) AS n_persons
# MAGIC FROM aki_result
# MAGIC GROUP BY aki_class, aki_class_doc ORDER BY n_presentations DESC;

# COMMAND ----------

# MAGIC %md
# MAGIC ### Stage and subtype among AKI presentations
# MAGIC
# MAGIC From the first block of each presentation.

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT overall_stage, overall_subtype_doc, COUNT(*) AS n
# MAGIC FROM aki_result
# MAGIC WHERE aki_class='AKI'
# MAGIC GROUP BY overall_stage, overall_subtype_doc
# MAGIC ORDER BY overall_stage, overall_subtype_doc;

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT n_blocks, SUM(n_recurrences) AS total_recurrences, COUNT(*) AS n_presentations
# MAGIC FROM aki_result
# MAGIC WHERE aki_class='AKI'
# MAGIC GROUP BY n_blocks ORDER BY n_blocks;

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT n_inwindow_scr_days, COUNT(*) AS n
# MAGIC FROM aki_result WHERE aki_class = 'AKI'
# MAGIC GROUP BY 1 ORDER BY 1;

# COMMAND ----------

# MAGIC %md
# MAGIC ### Blocks and recurrence

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT n_blocks, SUM(n_recurrences) AS total_recurrences, COUNT(*) AS n_presentations
# MAGIC FROM aki_result
# MAGIC WHERE aki_class='AKI'
# MAGIC GROUP BY n_blocks ORDER BY n_blocks;