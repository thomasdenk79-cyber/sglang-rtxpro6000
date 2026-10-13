#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  exec sudo -n "$0" "$@"
fi

VERSION='580.178.04-0ubuntu0.24.04.1'
export DEBIAN_FRONTEND=noninteractive
apt-get install -y \
  "nvidia-driver-580-open=$VERSION"
update-initramfs -u -k all
printf '%s\n' 'NVIDIA 580 rollback packages restored.'
printf '%s\n' 'Reboot the host, then verify with: nvidia-smi -L'
