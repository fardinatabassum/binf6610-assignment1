# BINF6610 Assignment 1: Troubleshooting and Debugging Report

### 1: MultiQC Blocked by Untrusted Homebrew Tap
- **Error:** `brew install multiqc` failed with `Error: Refusing to load formula brewsci/bio/multiqc from untrusted tap brewsci/bio`.
- **Evidence:** Terminal output said to run `brew trust brewsci/bio` before formulas could be evaluated or pulled from that repository.
- **Cause:** Homebrew requires explicit user approval before allowing formula downloads and builds from third-party.
- **Fix:** Ran `brew trust brewsci/bio` followed by `brew install multiqc`, allowing the installation to proceed and pass the environment check for Stage 8.

### 2: Pipeline Driver Termination Under `set -e`
- **Error:** Pipeline exited with status 1 immediately after Stage 0 printed `validation passed`, halting before Stage 1 (`qc_raw`) without logging any tool errors.
- **Evidence:** Running the pipeline in debug trace mode (`bash -x run_pipeline.sh samplesheet.csv ~/smoke-out`) showed execution stopped directly on the loop increment statement `(( n++ ))` right after evaluating `[[ "$stage" == "$LAST" ]]`.
- **Cause:** The script runs under strict mode (`set -euo pipefail`). In Bash arithmetic evaluation (`(( ... ))`), an expression that evaluates to `0` returns an exit status of 1 (falsy). Because `n` was initialized to `0`, the post-increment operator `(( n++ ))` returned `0` to the shell before incrementing, triggering `set -e` and killing the script.
- **Fix:** Replaced `(( n++ ))` with explicit variable assignment `n=$(( n + 1 ))`, which always returns exit code 0 regardless of the value and allows the driver loop to advance through all 10 stages.

### 3: Stage 7 VCF Deliverable Excluded by Git Wildcard
- **Error:** Acceptance Test 9 failed with `FAIL the whole pipeline ran on the smoke dataset: no smoke-run/cohort.filtered.vcf.gz in your repository`.
- **Evidence:** Checking `~/smoke-out/results/` confirmed `cohort.filtered.vcf.gz` was generated and copied to `smoke-run/`, but `git status` showed the working tree clean without detecting the new file. Running `git check-ignore -v smoke-run/cohort.filtered.vcf.gz` reported `.gitignore:16:*.vcf.gz`.
- **Cause:** The repository `.gitignore` included a broad wildcard rule `*.vcf.gz` to avoid tracking intermediate per-sample VCFs, which unintentionally blocked Git from tracking the final submission deliverable in `smoke-run/`.
- **Fix:** Added the exception rule `!smoke-run/cohort.filtered.vcf.gz` to `.gitignore` and staged the file using `git add -f smoke-run/cohort.filtered.vcf.gz`, resolving the test failure and verifying variant recoveries of 100%, 99%, and 92%.
