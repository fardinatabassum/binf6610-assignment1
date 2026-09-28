# Assignment 1: Troubleshooting Log

## Issue 1: MultiQC Blocked by Untrusted Homebrew Tap
- **Symptom:** `brew install multiqc` failed with `Error: Refusing to load formula brewsci/bio/multiqc from untrusted tap brewsci/bio`.
- **Evidence:** Terminal output instructed to run `brew trust brewsci/bio`.
- **Cause:** Homebrew requires explicit user approval before allowing formula downloads from third-party taps.
- **Fix:** Ran `brew trust brewsci/bio` followed by `brew install multiqc`, allowing the installation to proceed and pass the environment check.
