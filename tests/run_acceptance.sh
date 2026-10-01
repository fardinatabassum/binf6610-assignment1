#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# run_acceptance.sh — the tests that grade Assignment 2.
#
#   bash tests/run_acceptance.sh /path/to/your-repo
#   bash tests/run_acceptance.sh /path/to/your-repo afterok   # one test
#
# RUNS ON YOUR LAPTOP. Not on the cluster, and it submits nothing.
#
# That is deliberate, and it is also a limitation worth understanding. Everything
# here is read out of your scripts: whether the array size is derived, whether the
# dependency is `afterok`, whether threads come from Slurm. A test that actually
# submitted jobs would queue for an unknown time, cost real compute, and fail for
# reasons that have nothing to do with your code.
#
# So nine of these check that you wrote the right thing. The tenth reads what
# the cluster produced when you ran it -- the cohort VCF and manifest you commit
# in cluster-run/ -- so a suite passed without ever submitting a job now fails
# the test worth the most.
#-----------------------------------------------------------------------------
set -uo pipefail

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    printf 'error: bash >= 4.3 required, found %s\n' "${BASH_VERSION}" >&2; exit 70
fi

REPO=${1:-.}
FILTER=${2:-}
REPO=$(cd -- "${REPO}" && pwd) || { printf 'error: no such directory\n' >&2; exit 66; }
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

pass=0 fail=0
declare -a FAILURES=()
if [[ -t 1 ]]; then C_OK=$'\033[0;32m'; C_BAD=$'\033[0;31m'; C_DIM=$'\033[0;90m'; C_RST=$'\033[0m'
else C_OK='' C_BAD='' C_DIM='' C_RST=''; fi

want() { [[ -z "${FILTER}" ]] || [[ "$1" == *"${FILTER}"* ]]; }
ok()   { pass=$(( pass + 1 )); printf '  %sPASS%s  %s\n' "${C_OK}" "${C_RST}" "$1"; }
no()   { fail=$(( fail + 1 )); FAILURES+=( "$1" )
         printf '  %sFAIL%s  %s\n' "${C_BAD}" "${C_RST}" "$1"
         [[ -n "${2:-}" ]] && printf '        %s%s%s\n' "${C_DIM}" "$2" "${C_RST}"; }
note() { printf '        %s%s%s\n' "${C_DIM}" "$1" "${C_RST}"; }

SL="${REPO}/slurm"
printf '\n%sBINF6610 Assignment 2 — acceptance tests%s\n%srepo: %s%s\n\n' \
    "${C_DIM}" "${C_RST}" "${C_DIM}" "${REPO}" "${C_RST}"

[[ -d "${SL}" ]] || { printf '  %sFAIL%s  no slurm/ directory in %s\n\n' "${C_BAD}" "${C_RST}" "${REPO}"; exit 1; }

# All sbatch scripts plus the submitter, as one searchable blob. Which file a
# thing is in is your design decision; that it is somewhere is the requirement.
mapfile -t SLFILES < <(find "${SL}" -type f \( -name '*.sbatch' -o -name '*.sh' -o -name '*.env' \) | sort)
BLOB=$(cat "${SLFILES[@]}" 2>/dev/null)

#-- 1 · the orchestration contains no biology  (5 pts) -----------------------
# What the week claims is narrow and checkable: the new files are about
# SCHEDULING, and the analysis stayed where it was. So look for tool names in
# slurm/. If bwa or gatk appears there, the boundary has moved.
#
# An earlier version of this suite hashed lib/ and stages/ against a baseline
# and demanded they be byte-identical to assignment 1. That was unfair and
# impossible -- the baseline was the reference solution's code, not yours -- and
# it punished anyone who improved their week-1 pipeline. Improving it is fine.
if want "no bioinformatics"; then
    LEAKED=$(grep -oE '\b(bwa|gatk|samtools|bcftools|fastqc|fastp|hisat2|featureCounts|multiqc)\b' \
             <<< "${BLOB}" | sort -u | tr '\n' ' ')
    if [[ -z "${LEAKED}" ]]; then
        ok "slurm/ contains no bioinformatics tool calls"
        note "the new files orchestrate; the analysis stayed in stages/"
    else
        no "slurm/ contains no bioinformatics tool calls" \
           "found: ${LEAKED}- a batch script that runs a tool has started doing the analysis.
        Call your pipeline from the batch script and let it call the tools."
    fi
fi

#-- 2 · a per-sample entry point  (5 pts) ------------------------------------
# Stages 6-9 need every sample, and one array task cannot know whether the
# others finished. So the pipeline needs a second way in, and it should decline
# the cohort stages rather than silently building a cohort from one sample.
if want "per-sample entry point"; then
    ENTRY=$(grep -ohE '[A-Za-z0-9_./${}"-]*run_sample[A-Za-z0-9_.-]*\.sh' <<< "${BLOB}" | head -1)
    ENTRY_FILE=$(find "${REPO}" -maxdepth 2 -name 'run_sample*.sh' -o -maxdepth 2 -name '*per_sample*.sh' 2>/dev/null | head -1)
    if [[ -z "${ENTRY}" && -z "${ENTRY_FILE}" ]]; then
        no "the pipeline has a per-sample entry point" \
           "nothing in slurm/ calls a per-sample script, and there is no run_sample.sh.
        An array task runs ONE sample; run_pipeline.sh runs all of them. Both call the
        same stages, which is why the stages moved into their own files."
    elif [[ -n "${ENTRY_FILE}" ]] && grep -qE 'merge|analyze|qc_report|publish|cohort' "${ENTRY_FILE}" \
         && grep -qE 'die|exit|refus|stops at' "${ENTRY_FILE}"; then
        ok "the pipeline has a per-sample entry point, and it declines the cohort stages"
    else
        no "the pipeline has a per-sample entry point, and it declines the cohort stages" \
           "it exists, but it does not visibly refuse stages 6-9. A task that runs merge on
        one sample produces a cohort result built from one sample, eight times over."
    fi
fi

#-- 3 · the array index selects the right row  (15 pts) ----------------------
# Two separate things, and the second is the one people miss.
#   - the header has to be skipped, or every sample is processed under its
#     neighbour's name and you get a complete, plausible, entirely wrong result
#   - an array wider than the sheet hands a task an EMPTY sample name, and a
#     pipeline given no sample succeeds at every stage and exits 0
if want "array index"; then
    IDX_OK=0; SKIP_OK=0; EMPTY_OK=0
    grep -q 'SLURM_ARRAY_TASK_ID' <<< "${BLOB}" && IDX_OK=1
    grep -qE 'NR *== *[A-Za-z_${}"]*n[A-Za-z_${}"]* *\+ *1|NR *> *1|tail -n \+2|NR *== *\$?\{?SLURM_ARRAY_TASK_ID\}? *\+ *1|\+ *1 *\{ *print|sed -n .*\+ *1' <<< "${BLOB}" && SKIP_OK=1
    grep -qE '\[\[ *-n *"?\$\{?SAMPLE|\[\[ *-z *"?\$\{?SAMPLE|-n *"\$\{SAMPLE\}"' <<< "${BLOB}" && EMPTY_OK=1
    if (( IDX_OK && SKIP_OK && EMPTY_OK )); then
        ok "the array index selects the right row, and an out-of-range task is refused"
    elif (( IDX_OK && SKIP_OK )); then
        ok "the array index selects the right row"
        note "nothing checks that the row EXISTS. --array=1-9 against an eight-row sheet
        gives task 9 an empty sample name, and the pipeline then runs every stage over
        nothing, succeeds at each, and exits 0. Nine COMPLETED, eight results."
    elif (( IDX_OK )); then
        no "the array index selects the right row" \
           "\$SLURM_ARRAY_TASK_ID is used but nothing skips the header line. Task 1 would
        read the header as a sample."
    else
        no "the array index selects the right row" \
           "\$SLURM_ARRAY_TASK_ID appears nowhere. It is the only thing that differs
        between the tasks of an array."
    fi
fi

#-- 4 · afterok, and the cohort job must not linger  (15 pts) ----------------
# Anchored on --dependency rather than on the bare word, because a good script
# EXPLAINS the choice in a comment -- "afterok, not afterany" -- and an earlier
# version of this test read that comment and failed the reference solution for
# using afterany. Grepping source for intent matches the prose about the intent.
if want "afterok"; then
    if grep -qE -- '--dependency[=[:space:]]*["'"'"']?afterok' <<< "${BLOB}"; then
        if grep -q 'kill-on-invalid-dep' <<< "${BLOB}"; then
            ok "the cohort job depends on array SUCCESS, and will not linger if it fails"
        else
            ok "the cohort job depends on array SUCCESS (afterok)"
            note "no --kill-on-invalid-dep. Explorer happens to cancel an unsatisfiable
        dependency for you; a cluster that does not leaves the job PENDING forever. One
        flag makes the script right on a machine whose defaults you did not check."
        fi
    elif grep -qE -- '--dependency[=[:space:]]*["'"'"']?afterany' <<< "${BLOB}"; then
        no "the cohort job depends on array SUCCESS (afterok)" \
           "found 'afterany'. That starts the cohort job when the array FINISHES, however it
        went. One failed sample then gets you a cohort result over seven samples, with the
        right shape and the wrong experiment, and nothing says so."
    else
        no "the cohort job depends on array SUCCESS (afterok)" \
           "no --dependency anywhere. Your eight tasks are on eight machines and nothing
        orders them; the barrier has to be declared."
    fi
fi

#-- 5 · the threads you use are the threads you were given  (10 pts) --------
if want "threads"; then
    if grep -q 'SLURM_CPUS_PER_TASK' <<< "${BLOB}"; then
        if grep -qE 'THREADS *= *"?\$\{?SLURM_CPUS_PER_TASK' <<< "${BLOB}"; then
            ok "the thread count comes from SLURM_CPUS_PER_TASK"
        else
            ok "SLURM_CPUS_PER_TASK is used"
            note "make sure it reaches the tools. A request reserves cores; it does not tell
        your program anything, and almost every tool defaults to one thread."
        fi
    else
        no "the thread count comes from SLURM_CPUS_PER_TASK" \
           "not found. --cpus-per-task reserves cores and nothing more. If the number is
        typed twice you will change one of them one day, and the tool will quietly run on
        the old count while you hold the new one."
    fi
fi

#-- 6 · temp space on the node, and a trap that removes it  (5 pts) ---------
if want "temp space"; then
    HAS_TMP=0; HAS_TRAP=0
    grep -qE 'TMPDIR|/tmp/\$\{?SLURM_JOB_ID|SLURM_TMPDIR' <<< "${BLOB}" && HAS_TMP=1
    grep -qE 'trap .*(EXIT|SIGTERM)' <<< "${BLOB}" && HAS_TRAP=1
    if (( HAS_TMP && HAS_TRAP )); then
        ok "temp space is on the node, and a trap removes it"
    elif (( HAS_TMP )); then
        no "temp space is on the node, and a trap removes it" \
           "the temp space is on the node, but no 'trap ... EXIT' removes it. A rm at the bottom
        of the script does not run when the job is cancelled or hits its time limit, and /tmp
        on a compute node is shared with every other job on it."
    else
        no "temp space is on the node, and a trap removes it" \
           "no TMPDIR. samtools sort spills to temporary files beside the output, which is
        shared storage, and eight tasks write and delete them there for nothing. Point them
        at /tmp/\$SLURM_JOB_ID and trap it."
    fi
fi

#-- 7 · the job does not depend on your shell or your directory  (5 pts) ----
# Three separate mistakes with the same shape: the job worked because of
# something outside the job.
if want "does not depend"; then
    CLEAN=0; SUBMITDIR=0; LOGDIR=0
    grep -qE 'export=NONE|--export=NONE|module purge' <<< "${BLOB}" && CLEAN=1
    grep -q 'SLURM_SUBMIT_DIR' <<< "${BLOB}" && SUBMITDIR=1
    grep -qE 'mkdir -p +"?\$?\{?[A-Za-z_]*log' <<< "${BLOB}" && LOGDIR=1
    SCORE=$(( CLEAN + SUBMITDIR + LOGDIR ))
    if (( SCORE == 3 )); then
        ok "the job brings its own environment, finds its own config, and has somewhere to log"
    elif (( SCORE >= 1 )); then
        no "the job does not depend on your shell or your directory" \
           "${SCORE} of the 3 are there; all three are needed."
        (( CLEAN ))     || note "no --export=NONE (or module purge): the job inherits whatever your
        login shell had, so it works for you and fails for your labmate."
        (( SUBMITDIR )) || note "no \$SLURM_SUBMIT_DIR: sbatch runs a COPY of your script from
        /var/spool/slurmd, so \$(dirname \"\$0\") is not your directory and conf/ is not there."
        (( LOGDIR ))    || note "no 'mkdir -p logs': Slurm will not create the output directory,
        and a job that cannot open its log fails with nowhere to write why."
    else
        no "the job does not depend on your shell or your directory" \
           "none of --export=NONE, \$SLURM_SUBMIT_DIR, or 'mkdir -p logs'. Each of these is a
        way the job can work on your account and nowhere else."
    fi
fi

#-- 8 · RESOURCES.md — measured, with a decision  (10 pts) ------------------
if want "RESOURCES"; then
    RES=""
    for f in RESOURCES.md BENCHMARK.md; do [[ -f "${REPO}/$f" ]] && RES="${REPO}/$f" && break; done
    if [[ -z "${RES}" ]]; then
        no "RESOURCES.md reports what you measured and what you changed" \
           "not found. One table and two sentences: what you asked for, what seff said it used,
        and what you set it to."
    else
        HAS_NUM=$(grep -coE '[0-9]+(\.[0-9]+)? *(%|GB|G\b|MB|M\b|:[0-9]{2})' "${RES}")
        HAS_TOOL=0; HAS_CHANGE=0
        grep -qiE 'seff|sacct|MaxRSS|memory.peak|CPU Eff' "${RES}" && HAS_TOOL=1
        grep -qiE 'chang|reduc|cut|rais|lower|instead of|down from|so I|therefore' "${RES}" && HAS_CHANGE=1
        if (( HAS_NUM >= 4 && HAS_TOOL && HAS_CHANGE )); then
            ok "RESOURCES.md reports what you measured and what you changed"
        elif (( HAS_NUM >= 2 && HAS_TOOL )); then
            ok "RESOURCES.md reports measurements"
            note "it does not say what you CHANGED because of them. The measurement is half the
        mark; the decision it led to is the other half."
        else
            no "RESOURCES.md reports what you measured and what you changed" \
           "found ${HAS_NUM} numbers and no seff/sacct output. Paste the real output, then say
        what you set --cpus-per-task, --mem and --time to and why."
        fi
    fi
fi

#-- 9 · the four deliberate failures  (10 pts) ------------------------------
# The data is small enough that nothing goes wrong by itself, so the assignment
# requires you to break it. This test can only check that you wrote the four up;
# the grader reads whether you diagnosed them.
if want "deliberate"; then
    TB=""
    for f in TROUBLESHOOTING.md FAILURES.md; do [[ -f "${REPO}/$f" ]] && TB="${REPO}/$f" && break; done
    if [[ -z "${TB}" ]]; then
        no "TROUBLESHOOTING.md documents the four deliberate failures" \
           "not found. Four breakages, each a sacct line and two sentences: a --time that is
        too short, a task that exits 1 under afterok, --array=1-9 on an eight-row sheet, and
        a scancel mid-write followed by a rerun."
    else
        FOUND=0; MISSING=()
        grep -qiE 'TIMEOUT|--time' "${TB}"                        && FOUND=$(( FOUND+1 )) || MISSING+=("the TIMEOUT")
        grep -qiE 'afterok|dependency|CANCELLED' "${TB}"           && FOUND=$(( FOUND+1 )) || MISSING+=("the failed task under afterok")
        # Match the SHAPE, not one cohort's numbers: the demo sheet has 12 rows and
        # the assignment's has 8, so 'array=1-9' is specific to one of them.
        grep -qiE 'out.of.range|wider than|no row|no such row|empty sample|exit 64' "${TB}" && FOUND=$(( FOUND+1 )) || MISSING+=("the out-of-range task")
        grep -qiE 'scancel|partial|truncat|half-writ|gzip -t' "${TB}"  && FOUND=$(( FOUND+1 )) || MISSING+=("the partial file")
        if (( FOUND == 4 )); then
            ok "TROUBLESHOOTING.md documents all four deliberate failures"
        elif (( FOUND >= 2 )); then
            ok "TROUBLESHOOTING.md documents ${FOUND} of the four deliberate failures"
            note "missing: ${MISSING[*]}"
        else
            no "TROUBLESHOOTING.md documents the four deliberate failures" \
               "found ${FOUND} of 4. Missing: ${MISSING[*]}"
        fi
    fi
fi

#-- 10 · the whole cohort ran on Explorer  (20 pts) --------------------------
# Every other test reads your scripts. This one reads what your array and your
# cohort job produced: the cohort's filtered VCF and the manifest, copied into
# cluster-run/ and committed.
#
# Measured with the course's reference solution on Explorer on 2026-09-22 (array
# 10535731 and cohort 10535739, about 23 minutes end to end): 36,853 records, all
# in chr20:1-10 Mb, and 17,518 to 18,782 non-reference genotypes per sample. The
# bar is 10,000 per sample -- far enough below that for different filtering, far
# enough above zero to catch a sample that never reached the cohort.
#
# A file can be copied, so provenance is part of the check: the manifest must name
# the Explorer reference, and the commit it records must be in THIS repository's
# history. The paths GATK wrote into the VCF header are printed for the grader,
# because they carry the username of whoever ran the jobs.
COHORT_IDS=(NA12878 NA12891 NA12892 NA07357 NA12003 NA10851 NA12813 NA12873)
MIN_NONREF=10000
if want "cluster"; then
    CVCF=""
    for cand in cluster-run/cohort.filtered.vcf.gz cluster-run/cohort.filtered.vcf; do
        [[ -s "${REPO}/${cand}" ]] && { CVCF="${REPO}/${cand}"; break; }
    done
    CMAN="${REPO}/cluster-run/manifest.json"
    vcat() { if [[ "${CVCF}" == *.gz ]]; then gzip -dc "${CVCF}"; else cat "${CVCF}"; fi; }

    if [[ -z "${CVCF}" ]]; then
        no "the whole cohort ran on Explorer" \
           "no cluster-run/cohort.filtered.vcf.gz in your repository. Run the array and the cohort
        job, copy the cohort job's filtered VCF and its manifest into cluster-run/, and commit both."
    else
        counts=$(vcat 2>/dev/null | awk -F'\t' '
            /^##/     { next }
            /^#CHROM/ { for (i = 10; i <= NF; i++) { name[i] = $i; print "COL " $i }; next }
            {   total++
                if ($1 == "chr20" && $2 + 0 >= 1 && $2 + 0 <= 10000000) inwin++
                n = split($9, fmt, ":"); g = 0
                for (k = 1; k <= n; k++) if (fmt[k] == "GT") g = k
                if (!g) next
                for (i = 10; i <= NF; i++) { split($i, f, ":"); if (f[g] ~ /[1-9]/) nonref[name[i]]++ }
            }
            END { for (s in nonref) print "NONREF " s " " nonref[s]
                  print "TOTAL " total + 0; print "INWIN " inwin + 0 }')
        problems=() found=()
        for s in "${COHORT_IDS[@]}"; do
            if ! grep -qx "COL ${s}" <<< "${counts}"; then problems+=( "no column for ${s}" ); continue; fi
            nr=$(awk -v s="${s}" '$1 == "NONREF" && $2 == s { print $3 }' <<< "${counts}")
            found+=( "${s} ${nr:-0}" )
            (( ${nr:-0} >= MIN_NONREF )) || problems+=( "${s} has ${nr:-0} non-reference calls" )
        done
        total=$(awk '$1 == "TOTAL" { print $2 }' <<< "${counts}")
        inwin=$(awk '$1 == "INWIN" { print $2 }' <<< "${counts}")
        (( ${inwin:-0} > 0 )) || problems+=( "no variants in chr20:1-10000000" )

        if [[ ! -s "${CMAN}" ]]; then
            problems+=( "no cluster-run/manifest.json" )
        else
            grep -q 'grch38-1000g' "${CMAN}" || problems+=( "the manifest does not name the Explorer reference" )
            sha=$(grep -oE '"git_(sha|commit)"[[:space:]]*:[[:space:]]*"[0-9a-f]{7,40}' "${CMAN}" \
                  | grep -oE '[0-9a-f]{7,40}$' | head -1)
            if [[ -z "${sha}" ]]; then
                problems+=( "the manifest records no git commit (run after your first commit, from your clone)" )
            elif ! git -C "${REPO}" cat-file -e "${sha}^{commit}" 2>/dev/null; then
                problems+=( "the manifest's commit ${sha} is not in this repository's history" )
            fi
        fi

        if (( ${#problems[@]} == 0 )); then
            ok "the whole cohort ran on Explorer"
            note "${total} records, ${inwin} in chr20:1-10 Mb; non-reference calls: ${found[*]}"
        else
            no "the whole cohort ran on Explorer" \
               "a VCF is there, so the run finished: partial credit. Still wrong: $(IFS=';'; printf '%s' "${problems[*]}")."
        fi
        users=$(vcat 2>/dev/null | grep '^##' | grep -oE '/(scratch|home)/[^/ ,"]+' | sort -u | tr '\n' ' ')
        [[ -n "${users}" ]] && note "paths in the VCF header, for the grader: ${users}"
    fi
fi

#-- summary ------------------------------------------------------------------
printf '\n  %s%d passed%s, %s%d failed%s\n' \
    "${C_OK}" "${pass}" "${C_RST}" "$( (( fail )) && printf '%s' "${C_BAD}" )" "${fail}" "${C_RST}"
if (( fail )); then
    printf '\n  failing:\n'
    for f in "${FAILURES[@]}"; do printf '    - %s\n' "$f"; done
    printf '\n'
    exit 1
fi
printf '\n  All ten, including the cohort your cluster run produced.\n\n'
