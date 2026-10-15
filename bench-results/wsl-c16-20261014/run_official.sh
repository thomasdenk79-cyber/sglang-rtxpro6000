#!/usr/bin/env bash
# Official sglang bench_serving random 1k/256 at c1/c8/c16 against the running pennyroyal container.
set -uo pipefail
OUT="${1:?output dir}"
mkdir -p "$OUT"
for c in 1 8 16; do
  n=$((c * 4)); [ "$n" -lt 16 ] && n=16
  echo "START c$c n=$n $(date -Is)"
  if podman exec pennyroyal python3 -m sglang.bench_serving \
    --backend sglang --base-url http://127.0.0.1:8001 \
    --dataset-name random --random-input-len 1024 --random-output-len 256 \
    --random-range-ratio 1.0 --max-concurrency "$c" --num-prompts "$n" \
    --output-file "/tmp/bench_qwen_random_1k256_c${c}.json" > "$OUT/bench_c${c}.log" 2>&1; then
    podman cp "pennyroyal:/tmp/bench_qwen_random_1k256_c${c}.json" "$OUT/bench_qwen_random_1k256_c${c}.json"
    echo "DONE c$c $(date -Is)"
  else
    echo "FAIL c$c $(date -Is)"
  fi
  sleep 5
done
echo ALL_DONE
