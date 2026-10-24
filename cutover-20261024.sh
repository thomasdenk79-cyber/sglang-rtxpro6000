#!/usr/bin/env bash
# Einmaliger Cutover 2026-10-24: Alt-Engine (System-Unit, rootful) -> Pennyroyal-Owner
# (rootless, dieses Repo) + Test + Archivreife. Reihenfolge ist der Sicherheitsplan:
# alte Unit bleibt als Rollback deaktiviert erhalten, Archive sind reine Moves.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE=/srv/backup/archive/20261024
OLD_UNIT=local-blackwell-swift15.service

log() { printf '%s cutover: %s\n' "$(date '+%F %T %Z')" "$*"; }

log "1/6 alte Engine stoppen + deaktivieren (Rollback: systemctl start $OLD_UNIT)"
sudo -n systemctl stop "$OLD_UNIT"
sudo -n systemctl disable "$OLD_UNIT"

log "2/6 GPU-freie Fork-Tests"
"$HERE/pennyroyal.sh" test

log "3/6 neue Engine starten"
"$HERE/pennyroyal.sh" start

log "4/6 Router-Smoke (standard-balanced)"
KEY=$(cat /run/user/1000/litellm.key)
curl -fsS -m 120 -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  http://127.0.0.1:4000/v1/chat/completions \
  -d '{"model":"standard-balanced","messages":[{"role":"user","content":"Sag CUT-OVER-OK"}],"max_tokens":2000}' \
  | grep -q 'CUT-OVER-OK' && log "Smoke OK" || { log "Smoke FEHLER"; exit 1; }

log "5/6 User-Unit aktivieren (Restart-Cover)"
systemctl --user enable --now pennyroyal.service

log "6/6 Altlasten archivieren -> $ARCHIVE"
mkdir -p "$ARCHIVE"
mv /srv/work/sglang-rtxpro6000            "$ARCHIVE/"            && rmdir ~/work/sglang-rtxpro6000 2>/dev/null || true
mv /srv/luni/pennyroyal-dflash2           "$ARCHIVE/"
mv /srv/luni/luni-llmops-linux/vendor/qwen38-flashnext-nvfp4-kv "$ARCHIVE/qwen38-flashnext-nvfp4-kv-vendor"
git -C /srv/luni/luni-llmops-linux rm -q --cached vendor/qwen38-flashnext-nvfp4-kv
git -C /srv/luni/luni-llmops-linux commit -q -m "vendor: qwen38-flashnext-nvfp4-kv nach /srv/backup/archive/20261024 archiviert (Single-Owner ist /srv/luni/pennyroyal)"
mkdir -p /srv/luni/luni-llmops-linux/stacks/archive
git -C /srv/luni/luni-llmops-linux mv stacks/llm/orcarouter        stacks/archive/orcarouter
git -C /srv/luni/luni-llmops-linux mv stacks/llm/orcarouter-pennyroyal stacks/archive/orcarouter-pennyroyal
git -C /srv/luni/luni-llmops-linux commit -q -m "stacks: OrcaRouter 3.0.x + Pennyroyal 3.0.2 nach stacks/archive verlagert (deprecated, nicht starten)"
log "Cutover fertig."
