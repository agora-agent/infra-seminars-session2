#!/usr/bin/env bash
set -euo pipefail

kernel="${1:-v06}"
m="${2:-4096}"
n="${3:-4096}"
k="${4:-4096}"

case "$kernel" in
  v00) symbol=gemm_v00_naive ;;
  v01) symbol=gemm_v01_bad_mapping ;;
  v02) symbol=gemm_v02_shared_32 ;;
  v03) symbol=gemm_v03_register_1d ;;
  v04) symbol=gemm_v04_register_2d ;;
  v05) symbol=gemm_v05_vectorized ;;
  v05b) symbol=gemm_v05b_bank_aware_scalar ;;
  v06) symbol=gemm_v06_bank_aware ;;
  *)
    echo "unknown GEMM kernel: $kernel" >&2
    exit 2
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
binary="${GEMM_BINARY:-$repo_root/build/gemm_bench}"
ncu="${NCU_BIN:-ncu}"
report_dir="${REPORT_DIR:-$repo_root/reports}"
report="$report_dir/gemm-${kernel}-${m}x${n}x${k}"

mkdir -p "$report_dir"

"$ncu" \
  --force-overwrite \
  --export "$report" \
  --kernel-name-base function \
  --kernel-name "regex:^${symbol}$" \
  --launch-count 1 \
  --section SpeedOfLight \
  --section MemoryWorkloadAnalysis \
  --section ComputeWorkloadAnalysis \
  --section SchedulerStats \
  --section WarpStateStats \
  --section Occupancy \
  --section LaunchStats \
  "$binary" --kernel "$kernel" --m "$m" --n "$n" --k "$k" \
  --profile --no-verify

echo "wrote ${report}.ncu-rep"
