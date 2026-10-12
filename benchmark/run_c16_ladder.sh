#!/usr/bin/env bash
# Concurrency ladder for the c16 profile (2026-10-12 afternoon):
# max_running_requests=16, mamba slots=67, mem-fraction=0.947, graph cap=16,
# max-queued-requests=32, chunked prefill=8192. Goal: the sweet-spot curve
# (per-request tok/s, aggregate tok/s, TTFT) across intermediate concurrencies
# instead of only powers of two, plus the cold long-context ramp. The old c32
# tier is dropped on purpose: it exceeds the operating envelope and was the
# crash trigger; overflow is now a 429 at the queue cap.
set -uo pipefail
REPO=/home/z000g9hu/work/sglang-rtxpro6000
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=$REPO/bench-results/c16-ladder-$STAMP
mkdir -p "$OUT"
{
  echo "start: $(date -Is)"
  echo "config: mem_fraction_static=0.947 chunked_prefill_size=8192 cuda_graph_max_bs_decode=16 max_running_requests=16 max_mamba_cache_size=67 max_queued_requests=32 kv_pool=778816 hicache=32GB+nixl"
  echo "caveat: shared endpoint; LiteLLM agent traffic (incl. the supervising session) may interleave"
} > "$OUT/META.txt"

run() { # label input output prompts concurrency
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

# Ladder: 1,2,3,4,6,8,12,16; prompts scale with concurrency (min 8) so every
# level measures a steady window rather than a startup transient.
for spec in short:256:256 medium:1024:256 long:8192:1024 xlong:32768:1024; do
  IFS=: read -r label inp out <<< "$spec"
  for c in 1 2 3 4 6 8 12 16; do
    prompts=$((2 * c)); [ "$prompts" -lt 8 ] && prompts=8
    run "qwen_${label}_c${c}" "$inp" "$out" "$prompts" "$c"
  done
done

# Cold long-context ramp on the crash path (must now survive at c16 sizing).
for inp in 32768 65536 100352; do
  run "ramp_${inp}" "$inp" 128 2 1
  sleep 10
done
echo "ALL_DONE $(date -Is)"
