#!/usr/bin/env bash
# Haelt die c1-c8-Performance-Serie sequentiell gegen die Produktions-Engine.
# Bedingungen (Power-Limit, Engine-State, Git-Head) wandern vorab in meta.txt.
set -uo pipefail
BASE=/srv/work/flashnext/worktrees/bf16
TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT="${OUT_DIR:-/srv/work/flashnext/logs/perf-bench-$TS}"
mkdir -p "$OUT"
{
  date -u '+utc=%FT%TZ'
  nvidia-smi -i 1 --query-gpu=name,power.draw,power.limit,enforced.power.limit,clocks.sm --format=csv,noheader
  podman inspect luni-llm-orcarouter --format 'engine={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{end}} restarts={{.RestartCount}}'
  git -C "$BASE" rev-parse HEAD
} > "$OUT/meta.txt"
python3 "$BASE/tools/perf-bench/bench.py" \
  --bank "$BASE/tools/perf-bench/bank.jsonl" --out "$OUT" "$@" 2>&1 | tee "$OUT/run.log"
rc=${PIPESTATUS[0]}
echo "BENCH_RC=$rc OUT=$OUT"
exit "$rc"
