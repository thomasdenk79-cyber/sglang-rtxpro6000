#!/usr/bin/env bash
set -euo pipefail
OUT=/home/z000g9hu/work/sglang-rtxpro6000/bench-results/turbo8
mkdir -p "$OUT"
for spec in short:256:256:16 medium:1024:256:16 long:8192:1024:8; do
  IFS=: read -r label inp out n <<< "$spec"
  for c in 1 2 4 8 16 32; do
    prompts=$((n > c ? n : c))
    name="qwen_${label}_c${c}"
    echo "START $name $(date -Is)"
    podman exec pennyroyal python3 -m sglang.benchmark.serving \
      --backend sglang --base-url http://127.0.0.1:8001 \
      --dataset-name random --random-input-len "$inp" --random-output-len "$out" \
      --random-range-ratio 1.0 --max-concurrency "$c" --num-prompts "$prompts" \
      --output-file "/tmp/${name}.json" \
      > "$OUT/${name}.log" 2>&1
    podman cp "pennyroyal:/tmp/${name}.json" "$OUT/${name}.json"
    echo "DONE $name $(date -Is)"
  done
done
