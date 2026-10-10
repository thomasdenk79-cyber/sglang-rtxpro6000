#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
IMAGE=${PENNYROYAL_IMAGE:-localhost/pennyroyal:john-repair-5d33142c1}
MODEL=${PENNYROYAL_MODEL:-/srv/ai/models/RadixArk-Qwen3.8-Flash-Next-NVFP4}
GPU_UUID=${PENNYROYAL_GPU_UUID:-GPU-780d3589-9811-40ec-db66-93a9146697f3}
UNIT=${PENNYROYAL_UNIT:-pennyroyal.service}
QUADLET=${PENNYROYAL_QUADLET:-$HOME/.config/containers/systemd/pennyroyal.container}

failures=0
check() {
  local label=$1
  shift
  if "$@"; then
    printf '[OK]   %s\n' "$label"
  else
    printf '[FAIL] %s\n' "$label" >&2
    failures=$((failures + 1))
  fi
}

printf 'Pennyroyal host preflight\n'
printf '  repo:  %s\n' "$ROOT"
printf '  image: %s\n' "$IMAGE"
printf '  model: %s\n' "$MODEL"
printf '  gpu:   %s\n\n' "$GPU_UUID"

check 'model config exists' test -f "$MODEL/config.json"
check 'container image exists' podman image exists "$IMAGE"
check 'Quadlet exists' test -f "$QUADLET"
check 'Quadlet references the selected image' grep -Fq "Image=$IMAGE" "$QUADLET"
check 'Quadlet references the selected GPU UUID' grep -Fq "AddDevice=nvidia.com/gpu=$GPU_UUID" "$QUADLET"
check 'CDI UUID entry exists' bash -c "nvidia-ctk cdi list 2>/dev/null | grep -Fq 'nvidia.com/gpu=$GPU_UUID'"
check 'host sees the selected GPU' bash -c "nvidia-smi -L 2>/dev/null | grep -Fq '$GPU_UUID'"
check 'NVIDIA driver is loaded' test -e /dev/nvidiactl

printf '\nCurrent service state:\n'
systemctl --user show "$UNIT" -p LoadState -p ActiveState -p SubState -p Result 2>/dev/null || true

if (( failures )); then
  printf '\nPreflight failed: %d check(s). See docs/local-deployment.md for recovery notes.\n' "$failures" >&2
  exit 1
fi
printf '\nPreflight passed.\n'
