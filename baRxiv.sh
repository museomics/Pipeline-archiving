#!/usr/bin/env bash
#SBATCH --job-name=baRxiv
#SBATCH --output=baRxiv_%j.log
#SBATCH --error=baRxiv_%j.err
#SBATCH --cpus-per-task=8
#SBATCH --mem=16G

# =============================================================================
# baRxiv.sh
#
# Archives outputs from BeeGees and skim2mito pipelines into a single archive
# per run per pipeline, preserving internal directory structure.
#
# Usage:
#   sbatch baRxiv.sh \
#       --beegees   <dir1> [dir2 ...] \
#       --skim2mito <dir1> [dir2 ...] \
#       --reads     <path/to/read_archive/> \
#       --output    <path/to/main_archive/> \
#       [--skip-fastp] \
#       [--include-plot-tree] \
#       [--dry-run]
#
# Outputs per BeeGees run (run_name = basename of input dir):
#   --reads/{run_name}/
#       {run_name}_trimmed_reads.tar.gz      concat_mode trimmed reads for ENA upload
#       {run_name}_trimmed_reads.tar.gz.txt  Contents listing
#   --output/{run_name}/
#       {run_name}_beegees.tar.gz            All specified BeeGees outputs;
#                                            read files excluded from trimmed_data
#       {run_name}_beegees.tar.gz.txt        Contents listing
#
# Outputs per skim2mito run:
#   --output/{run_name}/
#       {run_name}_skim2mito.tar.gz          All specified skim2mito outputs
#       {run_name}_skim2mito.tar.gz.txt      Contents listing
#
# Notes:
#   - Paths inside archives are relative to the run root directory
#   - If any target archive already exists the script aborts immediately
#   - Missing required files/dirs are warned and collected into a summary
#     printed at the end of the log
#   - Missing optional files/dirs (04_reference_filtered) are silently skipped
#   - --reads is only required when --beegees is provided
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log()      { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_info() { log "INFO  $*"; }
log_warn() { log "WARN  $*"; }
log_err()  { log "ERROR $*" >&2; }

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
BEEGEES_DIRS=()
SKIM2MITO_DIRS=()
READS_DEST=""
OUTPUT_DEST=""
DRY_RUN=false
SKIP_FASTP=false
INCLUDE_PLOT_TREE=false
MISSING_ITEMS=()   # accumulates missing required paths for end-of-run summary

usage() {
    cat >&2 << EOF
Usage:
  sbatch baRxiv.sh \\
      --beegees   <dir1> [dir2 ...] \\
      --skim2mito <dir1> [dir2 ...] \\
      --reads     <path/to/read_archive/> \\
      --output    <path/to/main_archive/> \\
      [--skip-fastp] \\
      [--include-plot-tree] \\
      [--dry-run]

Options:
  --beegees        One or more BeeGees run output directories
  --skim2mito      One or more skim2mito run output directories
  --reads          Destination for trimmed reads archives (required with --beegees)
  --output         Destination for all other archives
  --skip-fastp     Exclude fastp/ from skim2mito archives
  --include-plot-tree  Include plot_tree/ in skim2mito archives (excluded by default)
  --dry-run        Print what would be done without creating any files
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --beegees)
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                BEEGEES_DIRS+=("$1"); shift
            done ;;
        --skim2mito)
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                SKIM2MITO_DIRS+=("$1"); shift
            done ;;
        --reads)   READS_DEST="$2";  shift 2 ;;
        --output)  OUTPUT_DEST="$2"; shift 2 ;;
        --skip-fastp)        SKIP_FASTP=true;        shift ;;
        --include-plot-tree) INCLUDE_PLOT_TREE=true; shift ;;
        --dry-run)           DRY_RUN=true;           shift ;;
        -h|--help) usage ;;
        *) log_err "Unknown argument: $1"; usage ;;
    esac
done

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------
errors=0
[[ ${#BEEGEES_DIRS[@]} -eq 0 && ${#SKIM2MITO_DIRS[@]} -eq 0 ]] && {
    log_err "At least one of --beegees or --skim2mito must be provided."; (( errors++ )); }
[[ -z "$OUTPUT_DEST" ]] && {
    log_err "--output must be specified."; (( errors++ )); }
[[ ${#BEEGEES_DIRS[@]} -gt 0 && -z "$READS_DEST" ]] && {
    log_err "--reads must be specified when --beegees is provided."; (( errors++ )); }
[[ $errors -gt 0 ]] && exit 1

$DRY_RUN && log_info "========== DRY RUN MODE — no files will be created =========="

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

get_run_name() { basename "${1%/}"; }

# Abort if target archive already exists
check_no_overwrite() {
    if [[ -e "$1" ]]; then
        log_err "Archive already exists (aborting to prevent overwrite): $1"
        exit 1
    fi
}

# Add a relative path to the include list if it exists under run_dir.
# Missing paths are warned and recorded in MISSING_ITEMS.
add_if_exists() {
    local full="${2}/${3}"
    if [[ -e "$full" ]]; then
        echo "$3" >> "$1"
    else
        log_warn "Not found, skipping: $full"
        MISSING_ITEMS+=("$full")
    fi
}

# Like add_if_exists but silently skips if absent — for truly optional outputs.
add_if_exists_optional() {
    local full="${2}/${3}"
    [[ -e "$full" ]] && echo "$3" >> "$1" || true
}

# Add the first glob match under a subdir to the include list.
# Missing matches are warned and recorded in MISSING_ITEMS.
add_glob() {
    local list="$1" run_dir="$2" pattern="$3" search_dir="${4:-.}"
    local full_search="${run_dir}/${search_dir}"
    local match
    match="$(find "$full_search" -maxdepth 1 -name "$pattern" 2>/dev/null | head -1 || true)"
    if [[ -n "$match" ]]; then
        local rel="${match#"${run_dir}/"}"; rel="${rel#./}"
        echo "$rel" >> "$list"
    else
        log_warn "Glob matched nothing (pattern='${pattern}' in '${full_search}'), skipping."
        MISSING_ITEMS+=("${full_search}/${pattern}")
    fi
}

# Create a tar.gz archive and companion .txt listing from an include-list file.
# Any arguments after the first four are passed directly to tar (e.g. --exclude).
create_archive() {
    local archive="$1" listing="$2" run_dir="$3" list_file="$4"
    shift 4
    local extra_flags=("$@")

    if [[ ! -s "$list_file" ]]; then
        log_warn "Include list is empty; no archive will be created: $archive"
        return
    fi

    check_no_overwrite "$archive"

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would create : $archive"
        log_info "[DRY-RUN] Would create : $listing"
        [[ ${#extra_flags[@]} -gt 0 ]] && \
            log_info "[DRY-RUN] Extra tar flags: ${extra_flags[*]}"
        log_info "[DRY-RUN] Contents (relative to $run_dir):"
        while IFS= read -r line; do
            log_info "[DRY-RUN]   $line"
        done < "$list_file"
        return
    fi

    log_info "Creating archive : $archive"
    mkdir -p "$(dirname "$archive")"
    # Directories in the include list are archived in full (--no-recursion not set).
    tar -czf "$archive" -C "$run_dir" "${extra_flags[@]}" --files-from="$list_file"
    tar -tzf "$archive" > "$listing"
    log_info "Listing written  : $listing"
}

# -----------------------------------------------------------------------------
# BeeGees archiving
# -----------------------------------------------------------------------------

# Exclude patterns applied to both BeeGees archives where read files are present.
# concat_mode: paired .fastq.gz and _concat_trimmed.fq
# merge_mode:  merged .fq and _merged_clean.fq (uncompressed, potentially large)
BEEGEES_READ_EXCLUDES=(
    --exclude="01_preprocessing/concat_mode/trimmed_data/*/*_concat_trimmed.fq"
    --exclude="01_preprocessing/concat_mode/trimmed_data/*/*.fastq.gz"
    --exclude="01_preprocessing/concat_mode/trimmed_data/*/*.fq.gz"
    --exclude="01_preprocessing/merge_mode/trimmed_data/*_merged.fq"
    --exclude="01_preprocessing/merge_mode/trimmed_data/*_merged_clean.fq"
    --exclude="01_preprocessing/merge_mode/trimmed_data/*/*.fq"
    --exclude="01_preprocessing/merge_mode/trimmed_data/*/*.fq.gz"
)

archive_beegees() {
    local run_dir="${1%/}"
    local run_name
    run_name="$(get_run_name "$run_dir")"

    log_info "========================================================"
    log_info "BeeGees run : $run_name"
    log_info "Source      : $run_dir"
    log_info "========================================================"

    local reads_run_dir="${READS_DEST%/}/${run_name}"
    local out_run_dir="${OUTPUT_DEST%/}/${run_name}"

    if $DRY_RUN; then
        mkdir -p "$reads_run_dir" "$out_run_dir" 2>/dev/null || true
    else
        mkdir -p "$reads_run_dir" "$out_run_dir"
    fi

    # ----------------------------------------------------------------
    # Reads archive -> --reads  (concat_mode trimmed_data, ENA upload)
    # _concat_trimmed.fq excluded; paired .fastq.gz reads retained
    # ----------------------------------------------------------------
    local reads_list
    reads_list="$(mktemp)"

    add_if_exists "$reads_list" "$run_dir" \
        "01_preprocessing/concat_mode/trimmed_data"

    create_archive \
        "${reads_run_dir}/${run_name}_trimmed_reads.tar.gz" \
        "${reads_run_dir}/${run_name}_trimmed_reads.tar.gz.txt" \
        "$run_dir" "$reads_list" \
        --exclude="01_preprocessing/concat_mode/trimmed_data/*/*_concat_trimmed.fq"

    rm -f "$reads_list"

    # ----------------------------------------------------------------
    # Backup archive -> --output  (all key outputs; read files excluded)
    # ----------------------------------------------------------------
    local out_list
    out_list="$(mktemp)"

    # 01_preprocessing — both modes (read files excluded at archive creation)
    for mode in concat_mode merge_mode; do
        add_if_exists "$out_list" "$run_dir" "01_preprocessing/${mode}/trimmed_data"
        add_if_exists "$out_list" "$run_dir" "01_preprocessing/${mode}/logs"
    done

    # 02_references (gene_fetch output; absent if run_gene_fetch = false)
    add_if_exists "$out_list" "$run_dir" "02_references"

    # 03_barcode_recovery — per-mode items
    for mode in concat_mode merge_mode; do
        local mode_base="03_barcode_recovery/${mode}"
        local cons_suffix; [[ "$mode" == "concat_mode" ]] && cons_suffix="concat" || cons_suffix="merge"

        add_if_exists "$out_list" "$run_dir" "${mode_base}/alignment"
        add_if_exists "$out_list" "$run_dir" "${mode_base}/fasta_cleaner/01_human_filtered"
        add_if_exists "$out_list" "$run_dir" "${mode_base}/fasta_cleaner/02_at_filtered/at_filter_summary.csv"
        add_if_exists "$out_list" "$run_dir" "${mode_base}/fasta_cleaner/03_outlier_filtered/outlier_filter_individual_metrics.csv"
        add_if_exists "$out_list" "$run_dir" "${mode_base}/fasta_cleaner/03_outlier_filtered/outlier_filter_summary_metrics.csv"
        add_if_exists_optional "$out_list" "$run_dir" "${mode_base}/fasta_cleaner/04_reference_filtered"
        add_if_exists "$out_list" "$run_dir" "${mode_base}/fasta_cleaner/05_cleaned_consensus/cleaned_cons_metrics-${cons_suffix}.csv"
        add_if_exists "$out_list" "$run_dir" "${mode_base}/fasta_cleaner/cleaned_cons_combined.fasta"
        add_if_exists "$out_list" "$run_dir" "${mode_base}/fasta_cleaner/combined_statistics.csv"
        add_glob      "$out_list" "$run_dir" "*_cons_combined-${cons_suffix}.fasta" "${mode_base}/consensus"
    done

    # 03_barcode_recovery top-level combined outputs
    add_glob "$out_list" "$run_dir" "*_all_cons_combined.fasta"       "03_barcode_recovery"
    add_glob "$out_list" "$run_dir" "*_barcode_recovery_metrics.csv"  "03_barcode_recovery"

    add_if_exists "$out_list" "$run_dir" "04_barcode_validation"
    add_if_exists "$out_list" "$run_dir" "05_barcoding_outcome"

    # Top-level run files
    add_glob      "$out_list" "$run_dir" "*_final_metrics.csv"
    add_glob      "$out_list" "$run_dir" "*_validated_barcodes.fasta"
    add_if_exists "$out_list" "$run_dir" "multiqc_report.html"

    create_archive \
        "${out_run_dir}/${run_name}_beegees.tar.gz" \
        "${out_run_dir}/${run_name}_beegees.tar.gz.txt" \
        "$run_dir" "$out_list" \
        "${BEEGEES_READ_EXCLUDES[@]}"

    rm -f "$out_list"

    log_info "BeeGees archiving complete for: $run_name"
}

# -----------------------------------------------------------------------------
# skim2mito archiving
# -----------------------------------------------------------------------------
archive_skim2mito() {
    local run_dir="${1%/}"
    local run_name
    run_name="$(get_run_name "$run_dir")"

    log_info "========================================================"
    log_info "skim2mito run : $run_name"
    log_info "Source        : $run_dir"
    log_info "========================================================"

    local out_run_dir="${OUTPUT_DEST%/}/${run_name}"
    $DRY_RUN || mkdir -p "$out_run_dir"

    local out_list
    out_list="$(mktemp)"

    local dirs=(
        "go_fetch"
        "fastqc_qc"
        "summary"
        "multiqc"
        "multiqc_data"
        "annotated_genes"
        "assembled_sequence"
        "assess_assembly"
        "extracted_genes"
        "blastn"
    )

    if $SKIP_FASTP; then
        log_info "Skipping fastp/ for $run_name (--skip-fastp)"
    else
        dirs+=("fastp")
    fi

    if $INCLUDE_PLOT_TREE; then
        dirs+=("plot_tree")
    else
        log_info "Skipping plot_tree/ for $run_name (use --include-plot-tree to include)"
    fi

    for d in "${dirs[@]}"; do
        add_if_exists "$out_list" "$run_dir" "$d"
    done

    add_if_exists "$out_list" "$run_dir" "best_contigs_per_sample.tsv"

    create_archive \
        "${out_run_dir}/${run_name}_skim2mito.tar.gz" \
        "${out_run_dir}/${run_name}_skim2mito.tar.gz.txt" \
        "$run_dir" "$out_list"

    rm -f "$out_list"

    log_info "skim2mito archiving complete for: $run_name"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
log_info "Archive script started"
log_info "Output destination : $OUTPUT_DEST"
log_info "Reads destination  : ${READS_DEST:-n/a}"
log_info "BeeGees runs       : ${BEEGEES_DIRS[*]:-none}"
log_info "skim2mito runs     : ${SKIM2MITO_DIRS[*]:-none}"
log_info "Skip fastp         : $SKIP_FASTP"
log_info "Include plot_tree  : $INCLUDE_PLOT_TREE"
log_info "Dry run            : $DRY_RUN"

for bg_dir in "${BEEGEES_DIRS[@]:-}"; do
    [[ -z "$bg_dir" ]] && continue
    [[ -d "$bg_dir" ]] || { log_err "BeeGees directory not found: $bg_dir"; exit 1; }
    archive_beegees "$bg_dir"
done

for s2m_dir in "${SKIM2MITO_DIRS[@]:-}"; do
    [[ -z "$s2m_dir" ]] && continue
    [[ -d "$s2m_dir" ]] || { log_err "skim2mito directory not found: $s2m_dir"; exit 1; }
    archive_skim2mito "$s2m_dir"
done

log_info "All archiving complete."

# -----------------------------------------------------------------------------
# Missing files/dirs summary
# -----------------------------------------------------------------------------
if [[ ${#MISSING_ITEMS[@]} -gt 0 ]]; then
    log_info "========================================================"
    log_info "MISSING FILES/DIRS SUMMARY (${#MISSING_ITEMS[@]} item(s) not found):"
    for item in "${MISSING_ITEMS[@]}"; do
        log_info "  MISSING: $item"
    done
    log_info "========================================================"
else
    log_info "All expected files and directories were found."
fi
