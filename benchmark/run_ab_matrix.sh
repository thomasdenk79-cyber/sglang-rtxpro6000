#!/usr/bin/env bash
# PLE backend comparison, round 2 (2026-10-14). Concurrency c1..c8 only
# (c16+ has no operational meaning with MAX_RUNNING_REQUESTS=8), tiers
# short/medium/long/xlong, EXPLICIT warmup before any measured point.
# Usage: run_ab_matrix.sh <label>   (label e.g. ram|nvme|nvme-bf16)
set -uo pipefail
LABEL="${1:?usage: run_ab_matrix.sh <label>}"
REPO=/home/z000g9hu/work/sglang-rtxpro6000
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$REPO/bench-results/ab2-$LABEL-$STAMP"
mkdir -p "$OUT"

health() { curl -m 10 -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8001/health || true; }

{
  echo "start: $(date -Is)"
  echo "label: $LABEL"
  echo "config: v3.0.1 mem_fraction=0.978 max_running=8 mamba=35 queued=16 chunk=8192 graph_bs=8 hicache=32GB+nixl"
  echo "warmup: sequential single-request prime per tier, PLE page-cache residency check, then sleep 60"
  echo "note: no c16+; endpoint exclusive; fincore of PLE overlay before/after"
} > "$OUT/META.txt"

ple_resident() {
  fincore /srv/ai/ple/flash-next-ple/ple/layer-0.bin 2>/dev/null | tail -1 | awk '{print "ple_pagecache="$1" of="$3}'
}

run() { # label inp out n c  (one retry after service auto-restart)
  local name=$1 inp=$2 out=$3 n=$4 c=$5 attempt rc
  for attempt in 1 2; do
    echo "START $name attempt=$attempt $(date -Is)"
    if podman exec pennyroyal python3 -m sglang.benchmark.serving \
      --backend sglang --base-url http://127.0.0.1:8001 \
      --dataset-name random --random-input-len "$inp" --random-output-len "$out" \
      --random-range-ratio 1.0 --max-concurrency "$c" --num-prompts "$n" \
      --output-file "/tmp/${name}.json" > "$OUT/${name}.log" 2>&1; then
      podman cp "pennyroyal:/tmp/${name}.json" "$OUT/${name}.json"
      echo "DONE $name $(date -Is)"
      sleep 5
      return 0
    fi
    rc=$?
    echo "FAIL $name attempt=$attempt rc=$rc $(date -Is)"
    # service may have OOM-crashed; wait for auto-restart before retry
    if [ "$attempt" = 1 ]; then
      echo "waiting up to 600s for health before retry"
      for _ in $(seq 1 60); do
        [ "$(health)" = "200" ] && break
        sleep 10
      done
      sleep 30
    fi
  done
  return 1
}

# ---- warmup: sequential single-request cache prime per tier (not concurrency load) ----
echo "WARMUP start $(date -Is)"; ple_resident >> "$OUT/META.txt"
for spec in "short:256:256" "medium:1024:256" "long:8192:1024" "xlong:32768:1024"; do
  IFS=: read -r tier inp out <<< "$spec"
  run "warm_${tier}" "$inp" "$out" 1 1 || echo "WARMUP_SKIP warm_${tier}"
done
echo "warmup done $(date -Is), settling 60s"; sleep 60; ple_resident >> "$OUT/META.txt"
free -g | awk 'NR==2{print "MemAvailable_GB="$7 >> "'"$OUT"'/META.txt"}'

# ---- measured matrix ----
for spec in short:256:256 medium:1024:256 long:8192:1024 xlong:32768:1024; do
  IFS=: read -r t inp out <<< "$spec"
  for c in 1 2 3 4 5 6 7 8; do
    run "qwen_${t}_c${c}" "$inp" "$out" 8 "$c" || { echo "MATRIX_FAIL $t c$c"; exit 1; }
  done
done
ple_resident >> "$OUT/META.txt"
echo "ALL_DONE $(date -Is)"
