# Phenotype Algorithm Implementation Package

This directory contains Databricks implementations and workflow reports for **five phenotype algorithms**:

1. **FH** — Familial Hypercholesterolemia  
2. **MACE_While_On_Statin** — Major Adverse Cardiac Events while on statins  
3. **T2DM** — Type 2 Diabetes Mellitus  
4. **AID** — Autoimmune Disease  
5. **AKI** — Acute Kidney Injury  

## Directory Structure

```text
LLM_Logic_Paper_2026_08_22_final/
├── FH/
│   ├── FH_stage1_workflow_Report.html
│   ├── FH_stage1.py
│   └── FH_reference_codes.py
│
├── MACE_While_On_Statin/
│   ├── MACE_workflow_report.html
│   └── Mace_On_Statin.py
│
├── T2DM/
│   ├── T2DM_Phenotype_workflow_report.html
│   ├── T2DM_Phenotype.py
│   └── T2DM_setup.py
│
├── AID/
│   ├── AID_phenotype_workflow_report.html
│   ├── 01_aid_setup.py
│   ├── 02_aid_phenotype.py
│   └── image_1784926503122.png
│
└── AKI/
    ├── AKI_phenotype.py
    ├── AKI_phenotype_workflow_report.html
    └── AKI_setup.py
```

## File Types

### `.html` — Workflow Reports

The HTML files are exported Databricks workflow reports. They provide a human-readable view of the phenotype implementation and allow reviewers to inspect:

- algorithm steps,
- intermediate outputs,
- cohort counts,
- tables and results generated during execution, and
- the overall implementation workflow.

These files are intended primarily for **review, documentation, and validation** and can be opened directly in a web browser.

### `.py` — Databricks Source Code

The Python files contain Databricks notebook source code used to implement each phenotype algorithm.

Depending on the algorithm, the `.py` files may include:

- **Setup / reference-code creation**
  - creation of diagnosis, procedure, medication, laboratory, or other phenotype code sets;
  - creation of supporting lookup/reference tables; and
  - preparation of algorithm-specific resources.

- **Phenotype algorithm implementation**
  - application of the phenotype logic;
  - construction of case, control, or other algorithm-defined cohorts;
  - temporal and clinical eligibility rules; and
  - generation of intermediate and final phenotype outputs.

Some algorithms separate setup/reference-code generation from the main phenotype logic, while others contain the implementation in a single notebook.

### `.png` — Supporting Figure

Image files are supporting figures referenced by the corresponding Databricks notebook or workflow report.

## Recommended Review Order

For each phenotype:

1. Open the **workflow report (`.html`)** to review the algorithm steps and outputs.
2. Review the **setup/reference-code `.py` file**, when present, to understand how phenotype code sets and supporting tables are created.
3. Review the **phenotype `.py` file** for the executable Databricks implementation of the algorithm.

## Notes

- File names may differ slightly across phenotype folders because the original implementations were developed independently.
- `setup`, `reference_codes`, or similarly named files generally contain supporting code-set or reference-table construction.
- `phenotype`, `stage1`, or algorithm-named files generally contain the primary phenotype logic.
- The HTML reports are documentation artifacts and are not required to execute the algorithms.
