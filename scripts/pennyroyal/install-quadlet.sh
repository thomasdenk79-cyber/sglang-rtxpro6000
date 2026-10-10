#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SOURCE=${PENNYROYAL_QUADLET_SOURCE:-$ROOT/deploy/pennyroyal.container}
TARGET_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd
TARGET=$TARGET_DIR/pennyroyal.container

[[ -f "$SOURCE" ]] || { echo "Missing Quadlet source: $SOURCE" >&2; exit 1; }
install -D -m 0644 "$SOURCE" "$TARGET"
systemctl --user daemon-reload
printf 'Installed %s\n' "$TARGET"
printf 'Start with: systemctl --user start pennyroyal.service\n'
