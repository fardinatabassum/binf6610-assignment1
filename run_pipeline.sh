#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# run_pipeline.sh — germline variant-calling pipeline (BINF6610 Assignment 1)
#-----------------------------------------------------------------------------
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export RUN_STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

REF=${REF:-/courses/BINF6610.202710/data/refs/grch38-1000g/GRCh38_full_analysis_set_plus_decoy_hla.fa}
REGION=${REGION:-chr20:1-10000000}
THREADS=${THREADS:-4}

SHEET="${1:?usage: run_pipeline.sh <samplesheet.csv> <outdir> [last-stage]}"
OUT="${2:?usage: run_pipeline.sh <samplesheet.csv> <outdir> [last-stage]}"
LAST="${3:-publish}"

QC="${OUT}/qc_raw"
TRIM="${OUT}/trim"
ALN="${OUT}/align"
POST="${OUT}/postprocess"
VAR="${OUT}/variants"
RES="${OUT}/results"
LOG="${OUT}/logs"

mkdir -p "$QC" "$TRIM" "$ALN" "$POST" "$VAR" "$RES" "$LOG"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 65; }

#=============================================================================
# 0 · validate — check samplesheet and every input file before computing
#=============================================================================
stage_validate() {
    local id cond rep lt r1 r2 problems=0 n1 n2 r1_ok r2_ok

    [[ -s "$SHEET" ]] || die "samplesheet missing or empty: $SHEET"

    while IFS=, read -r id cond rep lt r1 r2; do
        [[ -n "$id" ]] || { log "a row has no sample_id"; problems=$(( problems + 1 )); continue; }

        # Verify files exist and are not empty
        [[ -s "$r1" ]] || { log "$id: R1 missing or empty: $r1"; problems=$(( problems + 1 )); }
        if [[ "$lt" == paired ]]; then
            [[ -s "$r2" ]] || { log "$id: declared paired but R2 is missing"; problems=$(( problems + 1 )); }
        fi

        # Check declared layout against r2 column
        if [[ -z "$r2" && "$lt" == paired ]]; then
            log "$id: r2_fastq is empty but library_type says paired"
            problems=$(( problems + 1 ))
        fi

        # Gzip stream integrity
        r1_ok=0; r2_ok=0
        if [[ -s "$r1" ]]; then
            if gzip -t "$r1" 2>/dev/null; then r1_ok=1
            else log "$id: R1 is not a valid gzip file"; problems=$(( problems + 1 )); fi
        fi
        if [[ "$lt" == paired && -s "$r2" ]]; then
            if gzip -t "$r2" 2>/dev/null; then r2_ok=1
            else log "$id: R2 is not a valid gzip file"; problems=$(( problems + 1 )); fi
        fi

        # Whole records & mate line counts
        if (( r1_ok )); then
            n1=$(gzip -dc "$r1" | wc -l)
            (( n1 % 4 == 0 )) || { log "$id: R1 has $n1 lines, not a whole number of records"
                                   problems=$(( problems + 1 )); }
            if (( r2_ok )); then
                n2=$(gzip -dc "$r2" | wc -l)
                (( n1 == n2 )) || { log "$id: R1 has $(( n1 / 4 )) reads, R2 has $(( n2 / 4 ))"
                                    problems=$(( problems + 1 )); }
            fi
        fi
    done < <(tail -n +2 "$SHEET")

    # Reject duplicate sample IDs
    local dupes
    dupes=$(awk -F, 'NR>1 { print $1 }' "$SHEET" | sort | uniq -d)
    [[ -z "$dupes" ]] || { log "duplicate sample_id: $dupes"; problems=$(( problems + 1 )); }

    # Validate reference file exists
    [[ -s "$REF" ]] || { log "reference missing or empty: $REF"; problems=$(( problems + 1 )); }

    (( problems == 0 )) || die "validation failed with ${problems} problem(s)"
    log "validation passed"
}

#=============================================================================
# 1 · qc_raw — FastQC on raw reads
#=============================================================================
stage_qc_raw() {
    local id cond rep lt r1 r2 base
    while IFS=, read -r id cond rep lt r1 r2; do
        fastqc -q -o "$QC" "$r1" > "${LOG}/${id}.fastqc.log" 2>&1
        [[ "$lt" != paired ]] || fastqc -q -o "$QC" "$r2" >> "${LOG}/${id}.fastqc.log" 2>&1

        base=$(basename "$r1" .fastq.gz)
        [[ -s "${QC}/${base}_fastqc.zip" ]] || die "$id: fastqc produced no report"
        log "$id: raw qc done"
    done < <(tail -n +2 "$SHEET")
}

#=============================================================================
# 2 · trim — fastp trimming
#=============================================================================
stage_trim() {
    local id cond rep lt r1 r2 n
    while IFS=, read -r id cond rep lt r1 r2; do
        if [[ "$lt" == paired ]]; then
            fastp -i "$r1" -I "$r2" \
                  -o "${TRIM}/${id}_R1.fastq.gz" -O "${TRIM}/${id}_R2.fastq.gz" \
                  -j "${LOG}/${id}.fastp.json" -h "${LOG}/${id}.fastp.html" \
                  2> "${LOG}/${id}.fastp.log"
        else
            fastp -i "$r1" -o "${TRIM}/${id}_R1.fastq.gz" \
                  -j "${LOG}/${id}.fastp.json" -h "${LOG}/${id}.fastp.html" \
                  2> "${LOG}/${id}.fastp.log"
        fi

        n=$(gzip -dc "${TRIM}/${id}_R1.fastq.gz" | wc -l)
        (( n > 0 )) || die "$id: nothing survived trimming"
        log "$id: trimmed to $(( n / 4 )) reads"
    done < <(tail -n +2 "$SHEET")
}

#=============================================================================
# 3 · align — BWA-MEM with read group matching sample ID
#=============================================================================
stage_align() {
    local id cond rep lt r1 r2
    while IFS=, read -r id cond rep lt r1 r2; do
        if [[ "$lt" == paired ]]; then
            bwa mem -t "$THREADS" -R "@RG\tID:${id}\tSM:${id}" "$REF" \
                "${TRIM}/${id}_R1.fastq.gz" "${TRIM}/${id}_R2.fastq.gz" \
                2> "${LOG}/${id}.bwa.log" | samtools sort -@ 2 -o "${ALN}/${id}.bam"
        else
            bwa mem -t "$THREADS" -R "@RG\tID:${id}\tSM:${id}" "$REF" \
                "${TRIM}/${id}_R1.fastq.gz" \
                2> "${LOG}/${id}.bwa.log" | samtools sort -@ 2 -o "${ALN}/${id}.bam"
        fi
        samtools index "${ALN}/${id}.bam"
        [[ -s "${ALN}/${id}.bam" ]] || die "$id: bwa mem produced no BAM"
        log "$id: aligned and indexed"
    done < <(tail -n +2 "$SHEET")
}

#=============================================================================
# 4 · postprocess — MarkDuplicates and index
#=============================================================================
stage_postprocess() {
    local id cond rep lt r1 r2
    while IFS=, read -r id cond rep lt r1 r2; do
        gatk MarkDuplicates \
            -I "${ALN}/${id}.bam" \
            -O "${POST}/${id}.md.bam" \
            -M "${LOG}/${id}.metrics.txt" \
            --CREATE_INDEX true \
            2> "${LOG}/${id}.markdup.log"

        [[ -s "${POST}/${id}.md.bam" ]] || die "$id: MarkDuplicates produced no BAM"
        log "$id: mark duplicates finished"
    done < <(tail -n +2 "$SHEET")
}

#=============================================================================
# 5 · quantify — HaplotypeCaller in -ERC GVCF mode
#=============================================================================
stage_quantify() {
    local id cond rep lt r1 r2
    while IFS=, read -r id cond rep lt r1 r2; do
        gatk HaplotypeCaller \
            -R "$REF" \
            -I "${POST}/${id}.md.bam" \
            -O "${VAR}/${id}.g.vcf.gz" \
            -L "$REGION" \
            -ERC GVCF \
            2> "${LOG}/${id}.haplotypecaller.log"

        [[ -s "${VAR}/${id}.g.vcf.gz" ]] || die "$id: HaplotypeCaller produced no GVCF"
        log "$id: gvcf generated"
    done < <(tail -n +2 "$SHEET")
}

#=============================================================================
# 6 · merge — CombineGVCFs and GenotypeGVCFs
#=============================================================================
stage_merge() {
    local id cond rep lt r1 r2 gvcf_args=()
    while IFS=, read -r id cond rep lt r1 r2; do
        gvcf_args+=(-V "${VAR}/${id}.g.vcf.gz")
    done < <(tail -n +2 "$SHEET")

    gatk CombineGVCFs \
        -R "$REF" \
        "${gvcf_args[@]}" \
        -O "${VAR}/cohort.g.vcf.gz" \
        2> "${LOG}/combine_gvcfs.log"

    gatk GenotypeGVCFs \
        -R "$REF" \
        -V "${VAR}/cohort.g.vcf.gz" \
        -O "${VAR}/cohort.raw.vcf.gz" \
        -L "$REGION" \
        2> "${LOG}/genotype_gvcfs.log"

    [[ -s "${VAR}/cohort.raw.vcf.gz" ]] || die "joint genotyping produced no raw VCF"
    log "cohort raw VCF generated"
}

#=============================================================================
# 7 · analyze — hard filtering with VariantFiltration
#=============================================================================
stage_analyze() {
    gatk VariantFiltration \
        -R "$REF" \
        -V "${VAR}/cohort.raw.vcf.gz" \
        -O "${RES}/cohort.filtered.vcf.gz" \
        --filter-name "LowQual" \
        --filter-expression "QUAL < 30.0" \
        2> "${LOG}/variant_filtration.log"

    [[ -s "${RES}/cohort.filtered.vcf.gz" ]] || die "VariantFiltration produced no filtered VCF"
    log "cohort variants filtered"
}

#=============================================================================
# 8 · qc_report — MultiQC report
#=============================================================================
stage_qc_report() {
    multiqc -q -o "$RES" "$QC" "$LOG" 2> "${LOG}/multiqc.log"
    [[ -s "${RES}/multiqc_report.html" ]] || die "multiqc produced no report"
    log "MultiQC report created"
}

#=============================================================================
# 9 · publish — write manifest receipt
#=============================================================================
stage_publish() {
    PIPELINE_NAME=variant-calling \
        bash "${HERE}/lib/write_manifest.sh" "${RES}" "${SHEET}" "${REF}" "${REGION}"

    [[ -s "${RES}/manifest.json" ]] || die "write_manifest.sh produced no manifest.json"
    log "manifest written to ${RES}/manifest.json"
}

#=============================================================================
# Driver Loop
#=============================================================================
STAGES=(validate qc_raw trim align postprocess quantify merge analyze qc_report publish)

n=0
for stage in "${STAGES[@]}"; do
    log "===== stage ${n} : ${stage} ====="
    "stage_${stage}"
    [[ "$stage" == "$LAST" ]] && break
    n=$(( n + 1 ))
done
log "done"
