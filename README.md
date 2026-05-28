# Pipeline-archiving (baRxiv.sh)
This repository contains guidance on running the script `baRxiv.sh` to compress and archive valuable BeeGees and Skim2mito pipeline outputs.

## About
`baRxiv.sh` is a SLURM-compatible bash script for archiving outputs from the [BeeGees](https://github.com/bge-barcoding/BeeGees) barcode recovery pipeline and [skim2mito](https://github.com/SchistoDan/skim2mito) mitogenome assembly pipeline. Produces a single `.tar.gz` archive per run per pipeline, with an associated contents listing, and places trimmed reads into a separate archive for ENA upload.

> Archives preserve the internal directory structure of the pipeline output relative to the run root. Only the files and directories specified in [What gets archived](#what-gets-archived) are included — large intermediate files and working directories are excluded by design.

---

## Contents

- [Overview](#overview)
- [Requirements](#requirements)
- [Usage](#usage)
- [Arguments](#arguments)
- [Output structure](#output-structure)
- [What gets archived](#what-gets-archived)
  - [BeeGees](#beegees)
  - [skim2mito](#skim2mito)
- [Archive naming](#archive-naming)
- [Dry run](#dry-run)
- [Examples](#examples)

---


## Requirements
- `bash` ≥ 4.0
- `tar` with gzip support
- `find`
- SLURM (for `sbatch` submission; can also be run directly with `bash`)

---

## Usage
```bash
sbatch baRxiv.sh \
    --beegees  <beegees_dir1> [beegees_dir2 ...] \
    --skim2mito <skim2mito_dir1> [skim2mito_dir2 ...] \
    --reads  <path/to/read_archive/> \
    --output <path/to/main_archive/> \
    [--skip-fastp] \
    [--include-plot-tree] \
    [--dry-run]
```

Can also be run directly without SLURM:
```bash
bash baRxiv.sh --beegees /path/to/UK005 --reads /path/to/reads --output /path/to/archive
```

At least one of `--beegees` or `--skim2mito` must be provided. Both `--reads` and `--output` are always required.

---

## Arguments
| Argument | Required | Description |
|---|---|---|
| `--beegees <dir> [dir ...]` | One of `--beegees`/`--skim2mito` | One or more BeeGees run output directories |
| `--skim2mito <dir> [dir ...]` | One of `--beegees`/`--skim2mito` | One or more skim2mito run output directories |
| `--reads <path>` | Yes | Destination for trimmed reads archives (ENA upload staging) |
| `--output <path>` | Yes | Destination for all other archives (backup) |
| `--skip-fastp` | No | Exclude the `fastp/` directory from skim2mito archives |
| `--include-plot-tree` | No | Include the `plot_tree/` directory in skim2mito archives (excluded by default) |
| `--dry-run` | No | Print what would be done to log without creating any files |

---

## Output structure
Archives are written into per-run subdirectories under `--reads` and `--output`. The run name is inferred from the basename of the input directory (e.g. `/path/to/UK005` --> run name `UK005`).
```
--reads/
└── {run_name}/
    ├── {run_name}_trimmed_reads.tar.gz       # Archive containing concat_mode trimmed reads (ENA upload)
    └── {run_name}_trimmed_reads.tar.gz.txt   # Contents listing

--output/
└── {run_name}/
    ├── {run_name}_beegees.tar.gz             # Archive containing BeeGees outputs (trimmed_data fastq.gz excluded)
    ├── {run_name}_beegees.tar.gz.txt         # Contents listing
    ├── {run_name}_skim2mito.tar.gz           # Archive containing skim2mito outputs
    └── {run_name}_skim2mito.tar.gz.txt       # Contents listing
```
> Each `.tar.gz.txt` file is produced by `tar -tzf` and lists every file and directory inside the corresponding archive. Paths inside archives are relative to the run root directory.

---

## What gets archived
### BeeGees
Two archives are produced per BeeGees run:
#### `{run_name}_trimmed_reads.tar.gz` --> `--reads`

> For ENA upload. Contains the full `concat_mode` trimmed data directory including `.fastq.gz` read files, fastp reports, and Trim Galore reports.

```
01_preprocessing/concat_mode/trimmed_data/
└── {sample}/
    ├── {sample}_R1_trimmed.fastq.gz
    ├── {sample}_R2_trimmed.fastq.gz
    ├── {sample}_concat_trimmed.fq
    ├── {sample}_fastp_report.html
    ├── {sample}_fastp_report.json
    └── {sample}_concat.fastq_trimming_report.txt
```

#### `{run_name}_beegees.tar.gz` --> `--output`
For backup. Contains all key pipeline outputs listed below. The `trimmed_data` directories are included **with `.fastq.gz` files excluded** (reports only), since the full reads are already captured in the reads archive above.

| Path | Notes |
|---|---|
| `01_preprocessing/concat_mode/trimmed_data/` | Reports only; `.fastq.gz` excluded |
| `01_preprocessing/concat_mode/logs/` | |
| `01_preprocessing/merge_mode/trimmed_data/` | Reports only; `.fastq.gz` excluded |
| `01_preprocessing/merge_mode/logs/` | |
| `02_references/` | gene_fetch output; only present if `run_gene_fetch = true` |
| `03_barcode_recovery/concat_mode/alignment/` | |
| `03_barcode_recovery/concat_mode/fasta_cleaner/01_human_filtered/` | |
| `03_barcode_recovery/concat_mode/fasta_cleaner/02_at_filtered/at_filter_summary.csv` | |
| `03_barcode_recovery/concat_mode/fasta_cleaner/03_outlier_filtered/outlier_filter_individual_metrics.csv` | |
| `03_barcode_recovery/concat_mode/fasta_cleaner/03_outlier_filtered/outlier_filter_summary_metrics.csv` | |
| `03_barcode_recovery/concat_mode/fasta_cleaner/04_reference_filtered/` | Optional; included if present |
| `03_barcode_recovery/concat_mode/fasta_cleaner/05_cleaned_consensus/cleaned_cons_metrics-concat.csv` | |
| `03_barcode_recovery/concat_mode/fasta_cleaner/cleaned_cons_combined.fasta` | |
| `03_barcode_recovery/concat_mode/fasta_cleaner/combined_statistics.csv` | |
| `03_barcode_recovery/concat_mode/consensus/{run_name}_cons_combined-concat.fasta` | |
| `03_barcode_recovery/merge_mode/alignment/` | |
| `03_barcode_recovery/merge_mode/fasta_cleaner/01_human_filtered/` | |
| `03_barcode_recovery/merge_mode/fasta_cleaner/02_at_filtered/at_filter_summary.csv` | |
| `03_barcode_recovery/merge_mode/fasta_cleaner/03_outlier_filtered/outlier_filter_individual_metrics.csv` | |
| `03_barcode_recovery/merge_mode/fasta_cleaner/03_outlier_filtered/outlier_filter_summary_metrics.csv` | |
| `03_barcode_recovery/merge_mode/fasta_cleaner/04_reference_filtered/` | Optional; included if present |
| `03_barcode_recovery/merge_mode/fasta_cleaner/05_cleaned_consensus/cleaned_cons_metrics-merge.csv` | |
| `03_barcode_recovery/merge_mode/fasta_cleaner/cleaned_cons_combined.fasta` | |
| `03_barcode_recovery/merge_mode/fasta_cleaner/combined_statistics.csv` | |
| `03_barcode_recovery/merge_mode/consensus/{run_name}_cons_combined-merge.fasta` | |
| `03_barcode_recovery/{run_name}_all_cons_combined.fasta` | |
| `03_barcode_recovery/{run_name}_barcode_recovery_metrics.csv` | |
| `04_barcode_validation/` | |
| `05_barcoding_outcome/` | |
| `{run_name}_final_metrics.csv` | |
| `{run_name}_validated_barcodes.fasta` | |
| `multiqc_report.html` | Included if present at run root |

> The following are intentionally excluded: raw/intermediate `.fastq.gz` files in `trimmed_data`, MGE working files (`out/`, `err/`), and all other intermediate working directories.


### skim2mito
One archive is produced per skim2mito run:
#### `{run_name}_skim2mito.tar.gz` --> `--output`
| Path | Notes |
|---|---|
| `go_fetch/` | |
| `fastp/` | Excluded with `--skip-fastp` |
| `fastqc_qc/` | |
| `summary/` | |
| `multiqc/` | |
| `multiqc_data/` | |
| `annotated_genes/` | |
| `assembled_sequence/` | |
| `assess_assembly/` | |
| `extracted_genes/` | Produced by `filter_mitogenes.py` supplementary script |
| `blastn/` | |
| `plot_tree/` | Only included with `--include-plot-tree` |
| `best_contigs_per_sample.tsv` | Produced by `assess_mitogenomes.py` supplementary script |

> The following directories present in skim2mito output are intentionally excluded by default: `alignment_trim`, `annotations`, `blobtools`, `fastqc_raw`, `getorganelle`, `iqtree`, `mafft`, `mafft_filtered`, `minimap`, `seqkit`, `subset_contigs.log`.

---

## Archive naming
The run name is taken from the **basename of the input directory**, with no transformation applied:
| Input directory | Run name | Archive names |
|---|---|---|
| `/path/to/BeeGees_output/UK005` | `UK005` | `UK005_beegees.tar.gz`, `UK005_trimmed_reads.tar.gz` |
| `/path/to/skim2mito_output/UK005` | `UK005` | `UK005_skim2mito.tar.gz` |
| `/path/to/BeeGees_output/Eisenia_15-2024_UKBOL` | `Eisenia_15-2024_UKBOL` | `Eisenia_15-2024_UKBOL_beegees.tar.gz` |

> When processing BeeGees and skim2mito runs for the same sample, both should use the same run name (i.e. the same basename) so their archives land in the same per-run subdirectory under `--output`.

---

## Dry run
Use `--dry-run` to preview what the script would do without creating any files or directories:

```bash
bash baRxiv.sh \
    --beegees /path/to/UK005 \
    --skim2mito /path/to/UK005 \
    --reads /path/to/reads \
    --output /path/to/archive \
    --dry-run
```

---
## Examples

### Archive a single BeeGees and skim2mito run
```bash
sbatch baRxiv.sh \
    --beegees  /mnt/shared/scratch/museomix/UKBOL_accelerated/BeeGees_output/UK005 \
    --skim2mito /mnt/shared/scratch/museomix/UKBOL_accelerated/skim2mito_output/UK005 \
    --reads  /mnt/shared/projects/UKBOL_accelerated/reads_archive \
    --output /mnt/shared/projects/UKBOL_accelerated/main_archive
```

### Archive multiple runs at once
```bash
sbatch baRxiv.sh \
    --beegees \
        /mnt/shared/scratch/museomix/UKBOL_accelerated/BeeGees_output/UK001 \
        /mnt/shared/scratch/museomix/UKBOL_accelerated/BeeGees_output/UK002 \
        /mnt/shared/scratch/museomix/UKBOL_accelerated/BeeGees_output/UK005 \
    --skim2mito \
        /mnt/shared/scratch/museomix/UKBOL_accelerated/skim2mito_output/UK001 \
        /mnt/shared/scratch/museomix/UKBOL_accelerated/skim2mito_output/UK002 \
        /mnt/shared/scratch/museomix/UKBOL_accelerated/skim2mito_output/UK005 \
    --reads  /mnt/shared/projects/UKBOL_accelerated/reads_archive \
    --output /mnt/shared/projects/UKBOL_accelerated/main_archive
```

### Dry run before committing
```bash
bash baRxiv.sh \
    --beegees  /mnt/shared/scratch/museomix/UKBOL_accelerated/BeeGees_output/UK005 \
    --skim2mito /mnt/shared/scratch/museomix/UKBOL_accelerated/skim2mito_output/UK005 \
    --reads  /mnt/shared/projects/UKBOL_accelerated/reads_archive \
    --output /mnt/shared/projects/UKBOL_accelerated/main_archive \
    --dry-run
```

### skim2mito only, skipping fastp
```bash
sbatch baRxiv.sh \
    --skim2mito /mnt/shared/scratch/museomix/UKBOL_accelerated/skim2mito_output/UK005 \
    --reads  /mnt/shared/projects/UKBOL_accelerated/reads_archive \
    --output /mnt/shared/projects/UKBOL_accelerated/main_archive \
    --skip-fastp
```


> Created by Dan Parsons @NHMUK
