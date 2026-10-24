#!/usr/bin/env bash
# Pennyroyal Engine — Start/Stopp/Build/Health im Rootless-Podman-Standardbetrieb.
# Einzige Konfiguration: config.env in diesem Verzeichnis.
# Launch-Profil: 1:1 upstream qwen38-flashnext-nvfp4-kv@2e05ec3 (Pennyroyal 3.1.2,
# NVFP4-KV + Ping-Pong-Fix + Split-K, NEXTN MTP) plus Metrik-/Logging-Parameter.
# KEIN NIXL, KEIN HiCache, KEIN CUDA_LAUNCH_BLOCKING, KEIN DFLASH2, KEIN OrcaRouter.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/config.env"
UPSTREAM="$HERE/upstream"
HEALTH_URL="http://${HOST_BIND}:${PORT}/health"

log() { printf '%s pennyroyal: %s\n' "$(date '+%F %T %Z')" "$*"; }
die() { log "FEHLER: $*"; exit 1; }

precheck() {
  podman image exists "$IMAGE" || die "Image $IMAGE fehlt. Zuerst: $0 build"
  [[ -r "$MODEL_DIR/config.json" ]] || die "Modell nicht lesbar: $MODEL_DIR"
  [[ -d /var/run/cdi ]] && ls /var/run/cdi/*.yaml >/dev/null 2>&1 || die "Kein CDI unter /var/run/cdi — GPU nicht erreichbar"
  mkdir -p "$CACHE_ROOT"/{tilelang,torchinductor,triton,huggingface,crash-dumps}
  [[ -w "$CACHE_ROOT" ]] || die "Cache-Root nicht schreibbar: $CACHE_ROOT"
  if podman ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    log "Hinweis: Container $CONTAINER laeuft bereits (start ersetzt ihn)."
  fi
}

start() {
  precheck
  podman run -d --replace --name "$CONTAINER" \
    --device "$GPU_CDI" --network host --ipc host --ulimit memlock=-1:-1 \
    --memory "$MEMORY_LIMIT" --stop-timeout "$STOP_TIMEOUT" \
    -e SGLANG_QSA_NVFP4_KV=1 \
    -e SGLANG_OPT_MAMBA_SKIP_DECODE_LOCK=true \
    -e SGLANG_MAMBA_CONV_DTYPE=bfloat16 \
    -e SGLANG_SM120_ONLINE_MXFP8=true \
    -e SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1 \
    -e PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
    -e FLASHINFER_GDN_FP16_ACCUM_MMA=1 \
    -e TILELANG_CACHE_DIR=/cache/tilelang \
    -e TORCHINDUCTOR_CACHE_DIR=/cache/torchinductor \
    -e TRITON_CACHE_DIR=/cache/triton \
    -e HF_HOME=/cache/huggingface \
    -e XDG_CACHE_HOME=/cache \
    -v "$MODEL_DIR":/models/nvfp4:ro \
    -v "$CACHE_ROOT":/cache:rw \
    --entrypoint /opt/pennyroyal/.venv/bin/python \
    "$IMAGE" -m sglang.launch_server \
    --model-path /models/nvfp4 --host "$HOST_BIND" --port "$PORT" \
    --quantization modelopt_fp4 --dtype bfloat16 \
    --kv-cache-dtype nvfp4 \
    --speculative-draft-kv-cache-dtype fp8_e4m3 \
    --max-total-tokens "$KV_TOKEN_CAP" \
    --mem-fraction-static "$MEM_FRACTION_STATIC" \
    --context-length "$CONTEXT_LENGTH" \
    --json-model-override-args '{"text_config":{"rope_parameters":{"mrope_interleaved":true,"mrope_section":[11,11,10],"rope_type":"yarn","rope_theta":10000000,"partial_rotary_factor":0.25,"factor":2.0,"original_max_position_embeddings":262144}}}' \
    --page-size 64 \
    --max-running-requests "$MAX_RUNNING_REQUESTS" \
    --max-queued-requests "$MAX_QUEUED_REQUESTS" \
    --chunked-prefill-size 2048 --prefill-decode-interval 1 \
    --mamba-radix-cache-strategy extra_buffer_lazy --mamba-ssm-dtype bfloat16 \
    --max-mamba-cache-size 48 --mamba-max-states-per-path 5 --mamba-track-interval 64 \
    --gdn-mtp-cache-mode none \
    --linear-attn-decode-backend flashinfer --linear-attn-prefill-backend flashinfer \
    --ple-offload-embedding \
    --speculative-algorithm NEXTN --speculative-num-steps 3 \
    --speculative-eagle-topk 1 --speculative-num-draft-tokens 4 \
    --speculative-draft-model-quantization unquant \
    --cuda-graph-bs-decode 1 2 3 4 5 6 8 12 16 \
    --reasoning-parser qwen3 --tool-call-parser qwen3_coder \
    --served-model-name "$SERVED_MODEL_NAME" \
    --enable-metrics --enable-mfu-metrics --enable-request-time-stats-logging \
    --enable-cache-report --decode-log-interval 100 \
    --crash-dump-folder /cache/crash-dumps \
    --uvicorn-access-log-exclude-prefixes /health /metrics \
    --log-requests --log-requests-level "$LOG_REQUESTS_LEVEL" --log-requests-format json \
    --bucket-time-to-first-token 0.5 1 2 5 10 30 60 120 300 600 \
    --bucket-inter-token-latency 0.01 0.02 0.05 0.1 0.25 0.5 1 2 5 \
    --bucket-e2e-request-latency 1 2 5 10 30 60 120 300 600 1800
  log "Container gestartet, warte auf Health (Lastphase dauert Minuten) …"
  local deadline=$((SECONDS + HEALTH_TIMEOUT))
  while (( SECONDS < deadline )); do
    local state; state="$(podman inspect "$CONTAINER" --format '{{.State.Status}}' 2>/dev/null || echo gone)"
    [[ "$state" == "exited" || "$state" == "gone" ]] && { podman logs --tail 80 "$CONTAINER" || true; die "Container ist gestorben (state=$state)"; }
    if curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then
      log "/health=200 — Engine bereit."
      health
      return 0
    fi
    sleep 5
  done
  podman logs --tail 80 "$CONTAINER" || true
  die "Health-Timeout nach ${HEALTH_TIMEOUT}s"
}

stop() {
  podman stop -t "$STOP_TIMEOUT" "$CONTAINER" 2>/dev/null && log "gestoppt." || log "nichts zu stoppen."
}

health() {
  curl -fsS --max-time 5 "$HEALTH_URL" >/dev/null && echo "health: OK" || echo "health: FEHLER"
  curl -s --max-time 5 "http://${HOST_BIND}:${PORT}/metrics" \
    | grep -E '^sglang:(token_usage|num_running_reqs|num_queue_reqs)' || true
}

status() {
  podman ps -a --format '{{.Names}} {{.State}} {{.Status}}' | grep -E "^$CONTAINER " || echo "$CONTAINER: absent"
  health
}

test() {
  # Fork-Verifikation auf freier GPU: NVFP4-KV-Unit-Tests + Split-K (waehrend Start-Phase: Engine stoppen)
  podman ps --format '{{.Names}}' | grep -qx "$CONTAINER" && die "Engine laeuft — fuer GPU-Tests zuerst: $0 stop"
  podman run --rm --device "$GPU_CDI" \
    -v "$MODEL_DIR":/models/nvfp4:ro -v "$CACHE_ROOT":/cache:rw \
    -v "$UPSTREAM/tests":/tests:ro -e PYTHONPATH=/opt/pennyroyal/python \
    -e TILELANG_CACHE_DIR=/cache/tilelang \
    --entrypoint /opt/pennyroyal/.venv/bin/python \
    "$IMAGE" /tests/test_nvfp4_kv.py /tmp/nvfp4-unit.json
  podman run --rm --device "$GPU_CDI" \
    -v "$MODEL_DIR":/models/nvfp4:ro -v "$CACHE_ROOT":/cache:rw \
    -v "$UPSTREAM/tests":/tests:ro -e PYTHONPATH=/opt/pennyroyal/python \
    -e TILELANG_CACHE_DIR=/cache/tilelang \
    --entrypoint /opt/pennyroyal/.venv/bin/python \
    "$IMAGE" /tests/test_qsa_mqa_splitk.py
  log "Fork-Tests bestanden."
}

logs() { podman logs -n 200 -f "$CONTAINER"; }

build() {
  [[ -d "$UPSTREAM/.git" ]] || die "upstream/ fehlt (git clone https://github.com/Lesilva/qwen38-flashnext-nvfp4-kv upstream && git -C upstream checkout 2e05ec3)"
  log "Build $IMAGE aus upstream@$(git -C "$UPSTREAM" rev-parse --short HEAD) (Pennyroyal 3.1.2 + alle Sets) …"
  podman build -t "$IMAGE" "$UPSTREAM"
  log "Build fertig."
}

case "${1:-}" in
  start)  start ;;
  stop)   stop ;;
  restart) stop; start ;;
  status) status ;;
  health) health ;;
  test)   test ;;
  logs)   logs ;;
  build)  build ;;
  precheck) precheck ;;
  *) echo "Nutzung: $0 {start|stop|restart|status|health|test|logs|build|precheck}"; exit 2 ;;
esac
