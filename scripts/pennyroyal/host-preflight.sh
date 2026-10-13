#!/usr/bin/env bash
set -euo pipefail

GPU_UUID=${PENNYROYAL_GPU_UUID:-GPU-780d3589-9811-40ec-db66-93a9146697f3}
GPU_CHECK_ONLY=${PENNYROYAL_GPU_CHECK_ONLY:-0}
if [[ "$GPU_CHECK_ONLY" == 1 ]]; then
  # Keep the periodic probe cheap: no container, model, or CDI setup is touched.
  gpu_inventory=$(nvidia-smi --query-gpu=name,uuid --format=csv,noheader 2>/dev/null) || {
    echo "[FAIL] Could not query NVIDIA GPU inventory; prerequisites unavailable." >&2
    exit 1
  }
  if ! selected_gpu=$(printf '%s\n' "$gpu_inventory" | awk -F, -v uuid="$GPU_UUID" '
    {
      name=$1; id=$2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
    }
    id == uuid { print name; found=1 }
    END { if (!found) exit 1 }
  '); then
    printf '[FAIL] Required RTX PRO 6000 Blackwell (%s) is not healthy/visible; waiting for next retry.\n' "$GPU_UUID" >&2
    exit 1
  fi
  case "$selected_gpu" in *"RTX PRO 6000"*Blackwell*) ;;
    *) printf '[FAIL] GPU UUID %s resolved to unexpected device: %s\n' "$GPU_UUID" "$selected_gpu" >&2; exit 1 ;;
  esac
  printf '[OK] Required GPU visible and queryable: %s (%s)\n' "$selected_gpu" "$GPU_UUID"
  exit 0
fi

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
IMAGE=${PENNYROYAL_IMAGE:-ghcr.io/jpezzulli/sglang-rtxpro6000@sha256:fd26ba8d3ce001bb6e4b865236e1b69f7f790b94fb7fe1c32aa81799f4fe338c}
MODEL=${PENNYROYAL_MODEL:-/srv/ai/models/RadixArk-Qwen3.8-Flash-Next-NVFP4}
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
check 'NVIDIA driver is loaded' test -e /dev/nvidiactl

gpu_inventory=$(nvidia-smi --query-gpu=name,uuid --format=csv,noheader 2>/dev/null) || {
  echo "[FAIL] Could not query NVIDIA GPU inventory; refusing startup." >&2
  exit 1
}
if ! selected_gpu=$(printf '%s\n' "$gpu_inventory" | awk -F, -v uuid="$GPU_UUID" '
  {
    name=$1; id=$2
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
  }
  id == uuid { print name; found=1 }
  END { if (!found) exit 1 }
'); then
  printf '[FAIL] Required RTX PRO 6000 Blackwell (%s) is not healthy/visible; refusing startup before model loading.\n' "$GPU_UUID" >&2
  exit 1
fi
printf '[OK]   Required GPU visible and queryable: %s (%s)\n' "$selected_gpu" "$GPU_UUID"

printf '\nCurrent service state:\n'
systemctl --user show "$UNIT" -p LoadState -p ActiveState -p SubState -p Result 2>/dev/null || true

if (( failures )); then
  printf '\nPreflight failed: %d check(s). See docs/local-deployment.md for recovery notes.\n' "$failures" >&2
  exit 1
fi
printf '\nPreflight passed.\n'
