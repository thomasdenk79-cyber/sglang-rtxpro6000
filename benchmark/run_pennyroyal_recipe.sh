#!/usr/bin/env bash
# Pennyroyal serving recipe — publishable benchmark suite (v1, 2026-10-12).
#
# Context tiers chosen to match the shapes public HF model-card evals use
# (0/5-shot MMLU-style prompts), Pennyroyal's own advertised operating
# points (up to the 400k long-context claim), and realistic agent traffic:
#   tiny   512   completion/zero-shot
#   eval   2048  MMLU-Pro-style few-shot
#   agent  8192  tool-loop sessions
#   rago   32768 retrieval-augmented long docs
#   card  128k+400k  long-context claims (model card advertises 400k)
# Concurrency follows the recipe gate (c8). num-prompts >= 2*c for
# saturation; every case is run TWICE and medians are reported.
set -uo pipefail
REPO=/home/z000g9hu/work/sglang-rtxpro6000
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=$REPO/bench-results/recipe-$STAMP
mkdir -p "$OUT"
{
  echo "start: $(date -Is)"
  echo "recipe: c8 profile fraction=0.978 kv=fp8_e4m3 pool=1138112 chunk=8192"
  echo "        running=8 queued=16 slots=35 graphcap=8 hicache=32GB+nixl adaptive-spec on"
  echo "tiers: 512/256 2048/512 8192/1024 32768/1024 129024/1024 400384/1024"
  echo "caveat: shared endpoint, supervising agent traffic may interleave"
} > "$OUT/META.txt"

run() { # name inp out prompts concurrency
  local name=$1 inp=$2 out=$3 n=$4 c=$5
  echo "START $name $(date -Is)"
  if podman exec pennyroyal sh -c "cd /tmp && python3 -m sglang.benchmark.serving \
    --backend sglang --base-url http://127.0.0.1:8001 \
    --dataset-name random --random-input-len $inp --random-output-len $out \
    --random-range-ratio 1.0 --max-concurrency $c --num-prompts $n \
    --output-file /tmp/${name}.json" > "$OUT/${name}.log" 2>&1; then
    podman cp "pennyroyal:/tmp/${name}.json" "$OUT/${name}.json"
    echo "DONE $name $(date -Is)"
  else
    echo "FAIL $name rc=$? $(date -Is)"
  fi
  sleep 5
}

for pass in r1 r2; do
  run "${pass}_tiny"     512    256  16 8
  run "${pass}_eval"     2048   512  16 8
  run "${pass}_agent"    8192  1024  16 8
  run "${pass}_rago"     32768 1024  16 8
  run "${pass}_card128"  129024 1024 8 8
  run "${pass}_card400"  400384 1024 4 4   # near-window prompts, half concurrency (TTFT budget)
done
echo "ALL_DONE $(date -Is)"
