#!/usr/bin/env bash
# Full serving benchmark + long-context OOM ramp for the tuned 2026-10-12
# configuration (mem-fraction 0.981, chunked prefill 8192, decode graph cap 8,
# max 8 requests). Replaces the aborted turbo8 baseline. Each run records
# DONE/FAIL; a service restart mid-run surfaces as FAIL + health gap.
set -uo pipefail
REPO=/home/z000g9hu/work/sglang-rtxpro6000
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=$REPO/bench-results/tuned-0981-8192-$STAMP
mkdir -p "$OUT"
{
  echo "start: $(date -Is)"
  echo "config: mem_fraction_static=0.981 chunked_prefill_size=8192 cuda_graph_max_bs_decode=8 max_running_requests=8 hicache=32GB+nixl"
  echo "caveat: shared endpoint; LiteLLM agent traffic (incl. the supervising session) may interleave"
} > "$OUT/META.txt"

bname=()
run() { # label input output prompts concurrency filebase
  local name=$1 inp=$2 out=$3 n=$4 c=$5
  echo "START $name $(date -Is)"
  if podman exec pennyroyal python3 -m sglang.benchmark.serving \
    --backend sglang --base-url http://127.0.0.1:8001 \
    --dataset-name random --random-input-len "$inp" --random-output-len "$out" \
    --random-range-ratio 1.0 --max-concurrency "$c" --num-prompts "$n" \
    --output-file "/tmp/${name}.json" > "$OUT/${name}.log" 2>&1; then
    podman cp "pennyroyal:/tmp/${name}.json" "$OUT/${name}.json"
    echo "DONE $name $(date -Is)"
  else
    echo "FAIL $name rc=$? $(date -Is)"
  fi
  sleep 5
}

# Main matrix, same shapes as the old turbo8 baseline plus a 32k tier.
for spec in short:256:256:16 medium:1024:256:16 long:8192:1024:8 xlong:32768:1024:4; do
  IFS=: read -r label inp out n <<< "$spec"
  for c in 1 2 4 8 16 32; do
    prompts=$((n > c ? n : c))
    run "qwen_${label}_c${c}" "$inp" "$out" "$prompts" "$c"
  done
done

# Long-context ramp on the crash path: cold, serialized, crash-size samples.
for inp in 32768 65536 100352; do
  run "ramp_${inp}" "$inp" 128 2 1
  sleep 10
done
echo "ALL_DONE $(date -Is)"
