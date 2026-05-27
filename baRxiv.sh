#!/usr/bin/env bash
#SBATCH --job-name=baRxiv
#SBATCH --output=baRxiv_%j.log
#SBATCH --error=baRxiv_%j.err
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G

# =============================================================================
# baRxiv.sh
#
# Archives outputs from BeeGees and skim2mito pipelines into a single archive
# per run per pipeline, preserving internal directory structure.
#
# Usage:
#   sbatch baRxiv.sh \
#       --beegees  <dir1> [dir2 ...] \
#       --skim2mito <dir1> [dir2 ...] \
#       --reads  <path/to/read_archive/> \
#       --output <path/to/main_archive/> \
#       [--skip-fastp] \
#       [--include-plot-tree] \
#       [--dry-run]
#
# Outputs per BeeGees run (run_name = basename of input dir):
#   --reads/{run_name}/
#       {run_name}_trimmed_reads.tar.gz        Full trimmed_data (incl. fastq.gz) for ENA upload
#       {run_name}_trimmed_reads.tar.gz.txt    Contents listing
#   --output/{run_name}/
#       {run_name}_beegees.tar.gz              All specified BeeGees outputs; trimmed_data
#                                              included but fastq.gz excluded
#       {run_name}_beegees.tar.gz.txt          Contents listing
#
# Outputs per skim2mito run:
#   --output/{run_name}/
#       {run_name}_skim2mito.tar.gz            All specified skim2mito outputs
#       {run_name}_skim2mito.tar.gz.txt        Contents listing
#
# Notes:
#   - Paths inside archives are relative to the run root directory
#   - If any target archive already exists the script aborts immediately
#   - Missing files/dirs are skipped with a warning and collected into a
#     summary printed at the end of the log
#   - 04_reference_filtered/ is included if present, skipped if absent
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Logging helpers
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

# Accumulates missing paths for end-of-run summary
MISSING_ITEMS=()

usage() {
    sed -n '/^# Usage/,/^# [^ ]/{ /^# [^ ]/!p }' "$0" | sed 's/^# \{0,1\}//'
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
[[ -z "$READS_DEST"  ]] && { log_err "--reads must be specified.";  (( errors++ )); }
[[ -z "$OUTPUT_DEST" ]] && { log_err "--output must be specified."; (( errors++ )); }
[[ $errors -gt 0 ]] && exit 1

$DRY_RUN && log_info "========== DRY RUN MODE — no files will be created =========="

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

get_run_name() { basename "${1%/}"; }

# Abort if target archive already exists
check_no_overwrite() {
    local target="$1"
    if [[ -e "$target" ]]; then
        log_err "Archive already exists (aborting to prevent overwrite): $target"
        exit 1
    fi
}

# Add a path to the tar include-list file if it exists under run_dir.
add_if_exists() {
    local list="$1"
    local run_dir="$2"
    local rel="$3"
    local full="${run_dir}/${rel}"
    if [[ -e "$full" ]]; then
        echo "$rel" >> "$list"
        return 0
    else
        log_warn "Not found, skipping: $full"
        MISSING_ITEMS+=("$full")
        return 1
    fi
}

# Add a glob pattern (single level) to the include list.
# Uses the first match; records miss if none found.
add_glob() {
    local list="$1"
    local run_dir="$2"
    local pattern="$3"
    local search_dir="${4:-.}"

    local full_search="${run_dir}/${search_dir}"
    local match
    match="$(find "$full_search" -maxdepth 1 -name "$pattern" 2>/dev/null | head -1 || true)"

    if [[ -n "$match" ]]; then
        local rel="${match#"${run_dir}/"}"
        rel="${rel#./}"   # strip leading ./ if find returned a relative path
        echo "$rel" >> "$list"
        return 0
    else
        log_warn "Glob matched nothing (pattern='${pattern}' in '${full_search}'), skipping."
        MISSING_ITEMS+=("${full_search}/${pattern}")
        return 1
    fi
}

# Create archive + listing from an include-list file.
create_archive_from_list() {
    local archive="$1"
    local listing="$2"
    local run_dir="$3"
    local list_file="$4"

    if [[ ! -s "$list_file" ]]; then
        log_warn "Include list is empty; no archive will be created: $archive"
        return
    fi

    check_no_overwrite "$archive"

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would create : $archive"
        log_info "[DRY-RUN] Would create : $listing"
        log_info "[DRY-RUN] Contents (relative to $run_dir):"
        while IFS= read -r line; do
            log_info "[DRY-RUN]   $line"
        done < "$list_file"
        return
    fi

    log_info "Creating archive : $archive"
    mkdir -p "$(dirname "$archive")"

    # --no-recursion is NOT set intentionally — listed directories are
    # archived in full (subject to any --exclude flags passed by the caller).
    tar -czf "$archive" -C "$run_dir" --files-from="$list_file"
    tar -tzf "$archive" > "$listing"
    log_info "Listing written  : $listing"
}

# Same as above but accepts additional tar flags (e.g. --exclude patterns).
create_archive_from_list_with_flags() {
    local archive="$1"
    local listing="$2"
    local run_dir="$3"
    local list_file="$4"
    shift 4
    local extra_flags=("$@")   # remaining args passed verbatim to tar

    if [[ ! -s "$list_file" ]]; then
        log_warn "Include list is empty; no archive will be created: $archive"
        return
    fi

    check_no_overwrite "$archive"

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would create : $archive"
        log_info "[DRY-RUN] Would create : $listing"
        log_info "[DRY-RUN] Extra tar flags: ${extra_flags[*]:-none}"
        log_info "[DRY-RUN] Contents (relative to $run_dir):"
        while IFS= read -r line; do
            log_info "[DRY-RUN]   $line"
        done < "$list_file"
        return
    fi

    log_info "Creating archive : $archive"
    mkdir -p "$(dirname "$archive")"

    tar -czf "$archive" -C "$run_dir" "${extra_flags[@]}" --files-from="$list_file"
    tar -tzf "$archive" > "$listing"
    log_info "Listing written  : $listing"
}

# -----------------------------------------------------------------------------
# BeeGees archiving
# -----------------------------------------------------------------------------
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

    # ----------------------------------------------------------------
    # Build include list for --reads archive (full trimmed_data)
    # ----------------------------------------------------------------
    local reads_list
    reads_list="$(mktemp)"

    add_if_exists "$reads_list" "$run_dir" \
        "01_preprocessing/concat_mode/trimmed_data" || true

    local reads_archive="${reads_run_dir}/${run_name}_trimmed_reads.tar.gz"
    local reads_listing="${reads_run_dir}/${run_name}_trimmed_reads.tar.gz.txt"

    if $DRY_RUN; then
        mkdir -p "$reads_run_dir" "$out_run_dir" 2>/dev/null || true
    else
        mkdir -p "$reads_run_dir" "$out_run_dir"
    fi

    create_archive_from_list \
        "$reads_archive" "$reads_listing" "$run_dir" "$reads_list"

    rm -f "$reads_list"

    # ----------------------------------------------------------------
    # Build include list for --output archive (everything except
    # fastq.gz files inside trimmed_data)
    # ----------------------------------------------------------------
    local out_list
    out_list="$(mktemp)"

    # 01_preprocessing — both modes, trimmed_data included but
    # fastq.gz files excluded via tar --exclude (applied at create time)
    for mode in concat_mode merge_mode; do
        add_if_exists "$out_list" "$run_dir" \
            "01_preprocessing/${mode}/trimmed_data" || true
        add_if_exists "$out_list" "$run_dir" \
            "01_preprocessing/${mode}/logs" || true
    done

    # 02_references
    add_if_exists "$out_list" "$run_dir" "02_references" || true

    # 03_barcode_recovery — per-mode items
    for mode in concat_mode merge_mode; do
        local mode_base="03_barcode_recovery/${mode}"

        add_if_exists "$out_list" "$run_dir" "${mode_base}/alignment" || true

        # fasta_cleaner: include 01_human_filtered dir and specific files
        # from the numbered subdirs; structure is preserved inside the archive
        add_if_exists "$out_list" "$run_dir" \
            "${mode_base}/fasta_cleaner/01_human_filtered" || true

        add_if_exists "$out_list" "$run_dir" \
            "${mode_base}/fasta_cleaner/02_at_filtered/at_filter_summary.csv" || true

        add_if_exists "$out_list" "$run_dir" \
            "${mode_base}/fasta_cleaner/03_outlier_filtered/outlier_filter_individual_metrics.csv" || true
        add_if_exists "$out_list" "$run_dir" \
            "${mode_base}/fasta_cleaner/03_outlier_filtered/outlier_filter_summary_metrics.csv" || true

        # 04_reference_filtered is optional (only present if reference filtering
        # was enabled for this run) — recorded in missing summary if absent
        add_if_exists "$out_list" "$run_dir" \
            "${mode_base}/fasta_cleaner/04_reference_filtered" || true

        # Mode-dependent filename suffix for cleaned_cons_metrics
        local cons_suffix
        [[ "$mode" == "concat_mode" ]] && cons_suffix="concat" || cons_suffix="merge"
        add_if_exists "$out_list" "$run_dir" \
            "${mode_base}/fasta_cleaner/05_cleaned_consensus/cleaned_cons_metrics-${cons_suffix}.csv" || true

        add_if_exists "$out_list" "$run_dir" \
            "${mode_base}/fasta_cleaner/cleaned_cons_combined.fasta" || true
        add_if_exists "$out_list" "$run_dir" \
            "${mode_base}/fasta_cleaner/combined_statistics.csv" || true

        # consensus combined FASTA (filename embeds run_name)
        add_glob "$out_list" "$run_dir" \
            "*_cons_combined-${cons_suffix}.fasta" "${mode_base}/consensus" || true
    done

    # 03_barcode_recovery top-level combined outputs
    add_glob "$out_list" "$run_dir" \
        "*_all_cons_combined.fasta" "03_barcode_recovery" || true
    add_glob "$out_list" "$run_dir" \
        "*_barcode_recovery_metrics.csv" "03_barcode_recovery" || true

    # 04_barcode_validation
    add_if_exists "$out_list" "$run_dir" "04_barcode_validation" || true

    # 05_barcoding_outcome
    add_if_exists "$out_list" "$run_dir" "05_barcoding_outcome" || true

    # Top-level run files
    add_glob "$out_list" "$run_dir" "*_final_metrics.csv"      "." || true
    add_glob "$out_list" "$run_dir" "*_validated_barcodes.fasta" "." || true
    add_if_exists "$out_list" "$run_dir" "multiqc_report.html" || true

    # Create the output archive, excluding fastq.gz from trimmed_data
    local out_archive="${out_run_dir}/${run_name}_beegees.tar.gz"
    local out_listing="${out_run_dir}/${run_name}_beegees.tar.gz.txt"

    create_archive_from_list_with_flags \
        "$out_archive" "$out_listing" "$run_dir" "$out_list" \
        --exclude="01_preprocessing/*/trimmed_data/*.fastq.gz" \
        --exclude="01_preprocessing/*/trimmed_data/*/*.fastq.gz" \
        --exclude="01_preprocessing/*/trimmed_data/*.fq.gz" \
        --exclude="01_preprocessing/*/trimmed_data/*/*.fq.gz"

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

    if ! $DRY_RUN; then
        mkdir -p "$out_run_dir"
    fi

    local out_list
    out_list="$(mktemp)"

    # Unconditional directories
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

    # Conditional: fastp (included by default, skipped with --skip-fastp)
    if ! $SKIP_FASTP; then
        dirs+=("fastp")
    else
        log_info "Skipping fastp/ for $run_name (--skip-fastp)"
    fi

    # Conditional: plot_tree (excluded by default, included with --include-plot-tree)
    if $INCLUDE_PLOT_TREE; then
        dirs+=("plot_tree")
    else
        log_info "Skipping plot_tree/ for $run_name (use --include-plot-tree to include)"
    fi

    for d in "${dirs[@]}"; do
        add_if_exists "$out_list" "$run_dir" "$d" || true
    done

    # Top-level file
    add_if_exists "$out_list" "$run_dir" "best_contigs_per_sample.tsv" || true

    local out_archive="${out_run_dir}/${run_name}_skim2mito.tar.gz"
    local out_listing="${out_run_dir}/${run_name}_skim2mito.tar.gz.txt"

    create_archive_from_list \
        "$out_archive" "$out_listing" "$run_dir" "$out_list"

    rm -f "$out_list"

    log_info "skim2mito archiving complete for: $run_name"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
log_info "Archive script started"
log_info "Reads destination  : $READS_DEST"
log_info "Output destination : $OUTPUT_DEST"
log_info "BeeGees runs       : ${BEEGEES_DIRS[*]:-none}"
log_info "skim2mito runs     : ${SKIM2MITO_DIRS[*]:-none}"
log_info "Skip fastp         : $SKIP_FASTP"
log_info "Include plot_tree  : $INCLUDE_PLOT_TREE"
log_info "Dry run            : $DRY_RUN"

for bg_dir in "${BEEGEES_DIRS[@]:-}"; do
    [[ -z "$bg_dir" ]] && continue
    if [[ ! -d "$bg_dir" ]]; then
        log_err "BeeGees directory not found: $bg_dir"
        exit 1
    fi
    archive_beegees "$bg_dir"
done

for s2m_dir in "${SKIM2MITO_DIRS[@]:-}"; do
    [[ -z "$s2m_dir" ]] && continue
    if [[ ! -d "$s2m_dir" ]]; then
        log_err "skim2mito directory not found: $s2m_dir"
        exit 1
    fi
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
