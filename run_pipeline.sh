#!/usr/bin/env bash
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export RUN_STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

REF=${REF:-/courses/BINF6610.202710/data/refs/grch38-1000g/GRCh38_full_analysis_set_plus_decoy_hla.fa}
REGION=${REGION:-chr20:1-10000000}

SHEET="${1:-}"
OUTDIR="${2:-results}"
UP_TO="${3:-publish}"

if [[ -z "$SHEET" ]]; then
  echo "Usage: $0 <samplesheet.csv> <outdir> [last_stage]" >&2
  exit 1
fi

echo "Pipeline initialized successfully." >&2
