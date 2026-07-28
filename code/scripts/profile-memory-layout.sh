#!/usr/bin/env bash
set -euo pipefail

kernel="${1:-t2}"
m="${2:-4096}"
n="${3:-4096}"

case "$kernel" in
  t0) symbol=transpose_t0_copy ;;
  t1) symbol=transpose_t1_naive ;;
  t2) symbol=transpose_t2_shared ;;
  t3) symbol=transpose_t3_padded ;;
  t4) symbol=transpose_t4_xor ;;
  *)
    echo "unknown memory-layout kernel: $kernel" >&2
    exit 2
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
binary="${MEMORY_LAYOUT_BINARY:-$repo_root/build/bank_conflict_demo}"
ncu="${NCU_BIN:-ncu}"
report_dir="${REPORT_DIR:-$repo_root/reports}"
report="$report_dir/memory-layout-${kernel}-${m}x${n}"

mkdir -p "$report_dir"

"$ncu" \
  --force-overwrite \
  --export "$report" \
  --kernel-name-base function \
  --kernel-name "regex:^${symbol}$" \
  --launch-count 1 \
  --section SpeedOfLight \
  --section MemoryWorkloadAnalysis \
  --section SourceCounters \
  "$binary" --kernel "$kernel" --m "$m" --n "$n" \
  --profile --no-verify

echo "wrote ${report}.ncu-rep"
