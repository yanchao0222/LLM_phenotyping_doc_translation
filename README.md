# LLM Phenotyping Document Translation

A comparison study of two large language models — **OpenAI o3** (`LLM1`) and **Claude Opus 4.1** (`LLM2`) — on translating clinical phenotyping algorithm documents into executable OMOP CDM SQL queries.

Each model was given the same set of phenotyping documents under three input conditions, and the resulting SQL was independently scored by two human reviewers across seven quality dimensions.

## Study design

**Five phenotypes:**
- `ADs` — Autoimmune Diseases
- `AKI` — Acute Kidney Injury
- `FH` — Familial Hypercholesterolemia
- `MACE` — Major Adverse Cardiac Events (on statins)
- `T2DM` — Type 2 Diabetes Mellitus

**Three input settings** (see `phenotyping_algo/`):
- `ex1_all_content` — algorithm PDF + structured text/coding files (`ALL`)
- `ex2_only_text` — text/coding files only (`TEXT`)
- `ex3_only_diagram` — algorithm PDF/diagram only (`DIAG`)

**Two reviewers** (`AA`, `BB`) each scored every model output on a 0–4 scale across:
1. Logical & Boolean accuracy
2. Temporal constraint implementation
3. Value-set precision
4. OMOP schema
5. Coding efficiency
6. Human readability
7. Revision effort

## Repository layout

```
phenotyping_algo/        Source documents fed to the LLMs, plus the SQL each model produced
  ex1_all_content/       PDFs + text  →  LLM1/*.sql, LLM2/*.sql
  ex2_only_text/         Text only    →  LLM1/*.sql, LLM2/*.sql
  ex3_only_diagram/      PDFs only    →  LLM1/*.sql, LLM2/*.sql

LLM1/                    Reviewer scores for OpenAI o3
  <disease>_AA.csv       Reviewer AA scores (rows: ALL, TEXT, DIAG)
  <disease>_BB.csv       Reviewer BB scores
  figure_final.ipynb     Per-model figures
LLM2/                    Reviewer scores for Claude Opus 4.1 (same layout)

LLM_comparison_figure.ipynb   Cross-model comparison figures (radar + boxplots)
fig_comparison/               Output figures from the comparison notebook
```

## Reproducing the figures

Requirements: Python 3.10+, Jupyter, `pandas`, `numpy`, `matplotlib`.

```bash
pip install pandas numpy matplotlib jupyter
git clone https://github.com/yanchao0222/LLM_phenotyping_doc_translation.git
cd LLM_phenotyping_doc_translation
jupyter notebook
```

Then run, in order:
1. `LLM1/figure_final.ipynb` and `LLM2/figure_final.ipynb` — per-model summaries.
2. `LLM_comparison_figure.ipynb` — generates the head-to-head radar plots and boxplots into `fig_comparison/`.

## Reproducing the SQL outputs

The prompts are the contents of the PDFs / text files inside each `phenotyping_algo/exN_*` folder. To regenerate model outputs, submit each phenotype's documents to o3 and Claude Opus 4.1 with the instruction to produce executable OMOP CDM SQL, and place the resulting `.sql` files into `LLM1/` and `LLM2/` under the matching `exN_*` directory.
