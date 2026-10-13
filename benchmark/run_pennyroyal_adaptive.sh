#!/usr/bin/env bash
# Pennyroyal's own adaptive-speculative benchmark, chained after the SGLang
# serving suite so the two never overlap on the shared endpoint.
# Workloads low/high/transition are the data needed to judge the steps 3/7
# oscillation of --speculative-adaptive-config adaptive-next.json.
set -uo pipefail
REPO=/home/z000g9hu/work/sglang-rtxpro6000
SUITE_PID=$1
OUT=$(ls -d "$REPO"/bench-results/c16-ladder-* | sort | tail -1)/pennyroyal-adaptive-run2
mkdir -p "$OUT"
echo "start: $(date -Is) (waiting for sglang suite pid $SUITE_PID)" > "$OUT/META.txt"

while kill -0 "$SUITE_PID" 2>/dev/null; do sleep 20; done
echo "sglang suite finished: $(date -Is)" >> "$OUT/META.txt"
sleep 60  # let the engine go idle / sleep-on-idle

run_bench() { # name args...
  local name=$1; shift
  echo "START $name $(date -Is)"
  if podman exec pennyroyal python3 /opt/pennyroyal/benchmark/bench_adaptive_speculative.py \
      --host 127.0.0.1 --port 8001 "$@" > "$OUT/${name}.log" 2>&1; then
    echo "DONE $name $(date -Is)"
  else
    echo "FAIL $name rc=$? $(date -Is)"
  fi
  sleep 15
}

for workload in low high transition; do
  run_bench "adaptive_${workload}_c1"  --workload "$workload" --requests 8 --concurrency 1 --max-tokens 512 --warmup 2
  run_bench "adaptive_${workload}_c8"  --workload "$workload" --requests 8 --concurrency 8 --max-tokens 512 --warmup 2
done
echo "ALL_DONE $(date -Is)" | tee -a "$OUT/META.txt"
