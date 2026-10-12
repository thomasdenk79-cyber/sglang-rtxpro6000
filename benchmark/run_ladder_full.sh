#!/usr/bin/env bash
# Full concurrency ladder v2 for the c16 profile (running=16, queued=32).
# Fixes v1: num-prompts now scales with concurrency (>=2*c, min 12) so every
# level is genuinely saturated; adds c24/c32 (queue-limited region, must
# degrade to 429/queueing instead of crashing) and an xxlong 100k tier.
# Output JSON provides completed, duration, total/output throughput for
# sum-token and avg-tok/s tables.
set -uo pipefail
REPO=/home/z000g9hu/work/sglang-rtxpro6000
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=$REPO/bench-results/ladder-full-$STAMP
mkdir -p "$OUT"
{
  echo "start: $(date -Is)"
  echo "config: fraction=0.947 kv=fp8_e4m3 pool=778816 chunk=8192 running=16 queued=32 slots=67 graphcap=16"
  echo "prompts = max(2*c,12); xxlong prompts = max(c,8)"
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

for spec in short:256:256 medium:1024:256 long:8192:1024 xlong:32768:1024; do
  IFS=: read -r label inp out <<< "$spec"
  for c in 1 2 3 4 6 8 12 16 24 32; do
    prompts=$((2 * c)); [ "$prompts" -lt 12 ] && prompts=12
    run "qwen_${label}_c${c}" "$inp" "$out" "$prompts" "$c"
  done
done

# xxlong (crash-size) tier, coarse grid only — wall-time budget.
for c in 4 8 16 32; do
  prompts=$c; [ "$prompts" -lt 8 ] && prompts=8
  run "qwen_xxlong_c${c}" 100352 512 "$prompts" "$c"
done
echo "ALL_DONE $(date -Is)"
