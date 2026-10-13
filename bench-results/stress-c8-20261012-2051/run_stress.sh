#!/usr/bin/env bash
# Sequential stress ladder for the c8@0.978 profile (Pennyroyal).
# SAFETY: after every case check NRestarts==0 and journal for OOM/SIGQUIT;
# on any hit: write INCIDENT.txt + journal excerpt and stop (exit 9).
# Never restarts the engine. One benchmark at a time.
set -uo pipefail
OUT="${1:?usage: run_stress.sh OUTDIR}"
BASE=http://127.0.0.1:8001
BASE_URL=$BASE
RUNLOG="$OUT/RUN.log"
journal_since() { journalctl --user -u pennyroyal.service -b --since "$1" --no-pager; }

abort_incident() { # name, case-start, reason
  local name=$1 st=$2 reason=$3
  echo "INCIDENT $name reason=$reason $(date -Is)" | tee -a "$RUNLOG"
  {
    echo "INCIDENT: $name — $reason"
    echo "time: $(date -Is)"
    echo "NRestarts: $(systemctl --user show pennyroyal.service -p NRestarts --value)"
    echo "--- journal since case start ($st) matching CUDA out of memory|OutOfMemory|SIGQUIT ---"
    journal_since "$st" | grep -E 'CUDA out of memory|OutOfMemory|SIGQUIT'
    echo "--- journal tail (last 200 lines at incident time) ---"
    journalctl --user -u pennyroyal.service -b --no-pager | tail -200
  } > "$OUT/INCIDENT.txt" 2>&1
  echo "INCIDENT written to $OUT/INCIDENT.txt"
  exit 9
}

safety() { # name, case-start
  local name=$1 st=$2 nr
  nr=$(systemctl --user show pennyroyal.service -p NRestarts --value)
  if [ "$nr" != "0" ]; then abort_incident "$name" "$st" "NRestarts=$nr"; fi
  if journal_since "$st" | grep -qE 'CUDA out of memory|OutOfMemory|SIGQUIT'; then
    abort_incident "$name" "$st" "journal OOM/SIGQUIT match"
  fi
}

health_wait() { # phase-label
  local i
  for i in 1 2 3 4; do
    if curl -sf -m 10 "$BASE/health" >/dev/null 2>&1; then return 0; fi
    echo "HEALTH_FAIL attempt=$i $(date -Is)" | tee -a "$RUNLOG"
    [ $i -lt 4 ] && sleep 120
  done
  echo "ENGINE_DECLARED_DOWN $(date -Is)" | tee -a "$RUNLOG"
  return 1
}

run() { # name input output prompts concurrency
  local name=$1 inp=$2 out=$3 n=$4 c=$5 rc st
  st=$(date '+%F %T')
  echo "START $name in=$inp out=$out N=$n C=$c $st" | tee -a "$RUNLOG"
  podman exec pennyroyal rm -f "/tmp/${name}.json" >/dev/null 2>&1
  podman exec pennyroyal python3 -m sglang.benchmark.serving \
    --backend sglang --base-url "$BASE" \
    --dataset-name random --random-input-len "$inp" --random-output-len "$out" \
    --random-range-ratio 1.0 --max-concurrency "$c" --num-prompts "$n" \
    --output-file "/tmp/${name}.json" > "$OUT/${name}.log" 2>&1
  rc=$?
  podman cp "pennyroyal:/tmp/${name}.json" "$OUT/${name}.json" >/dev/null 2>&1 \
    || echo "  (no output-file for $name rc=$rc)" >> "$OUT/${name}.log"
  if [ $rc -eq 0 ]; then
    echo "DONE $name $(date -Is)" | tee -a "$RUNLOG"
  else
    echo "FAIL $name rc=$rc $(date -Is)" | tee -a "$RUNLOG"
  fi
  safety "$name" "$st"          # exits 9 on incident
  journal_since "$st" > "$OUT/journal-${name}.log" 2>/dev/null
  health_wait "$name" || abort_incident "$name" "$st" "health endpoint down after case"
  sleep 5
}

echo "==== stress-c8 ladder started $(date -Is) ====" | tee -a "$RUNLOG"

# ---- Phase A: operating-envelope ladder ----
for spec in short:256:256 medium:1024:256 long:8192:1024 xlong:32768:1024; do
  IFS=: read -r label inp out <<< "$spec"
  for c in 1 2 4 6 8; do
    n=$((2 * c)); [ "$n" -lt 12 ] && n=12
    run "qwen_${label}_c${c}" "$inp" "$out" "$n" "$c"
  done
done

# ---- Phase B: overflow guards (graceful degradation) ----
for spec in long:8192:1024 xlong:32768:1024; do
  IFS=: read -r label inp out <<< "$spec"
  for c in 12 16 24 32; do
    n=$((2 * c)); [ "$n" -lt 16 ] && n=16
    run "qwen_${label}_c${c}" "$inp" "$out" "$n" "$c"
  done
done

# ---- Phase C: sustained soak (xlong C=8, 48 prompts = 6 waves) ----
run qwen_soak_c8 32768 1024 48 8

# ---- Phase D: burst probe (long c16 x2, c1 latency check in between) ----
run qwen_bursta_c16 8192 1024 32 16
run qwen_c1check_c1 256 256 1 1
run qwen_burstb_c16 8192 1024 32 16

# ---- Phase E: xxlong reality check (100k) ----
run qwen_xxlong_c6 100352 512 6 6
run qwen_xxlong_c8 100352 512 8 8

echo "==== ALL_DONE $(date -Is) ====" | tee -a "$RUNLOG"
