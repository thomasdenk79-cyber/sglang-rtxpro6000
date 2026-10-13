#!/usr/bin/env bash
# pennyroyal watchdog: restarts the sglang container when the API stops
# answering. Only meaningful while no real model fallback exists yet.
set -u
STATE=/run/user/1000/pennyroyal-watchdog.last
# Startup-Gnade: sglang braucht gemessen ~450s bis "ready to roll", die Quadlet
# HealthStartPeriod ist der Massstab. In dem Fenster ist der Port zu, aber der
# Server haengt nicht -- ein Restart wuerde den eigenen Boot abwuergehn.
GRACE=900
started=$(podman inspect pennyroyal --format '{{.State.StartedAt}}' 2>/dev/null | cut -d. -f1)
if [ -n "$started" ]; then
  start_epoch=$(date -d "$started" +%s 2>/dev/null || echo 0)
  if [ "${start_epoch:-0}" -gt 0 ] && [ $(( $(date +%s) - start_epoch )) -lt "$GRACE" ]; then
    exit 0
  fi
fi
# Bewusst gestoppt (Wartung) -> nur mit Marker-Datei bleibt der Watchdog still.
# Ohne Marker gilt: Pennyroyal soll laufen; ein toter Dienst (z.B. SGLang
# Exit-0 nach Scheduler-OOM) wird wie ein Haengefall behandelt.
if ! systemctl --user is-active --quiet pennyroyal.service; then
  if [ -f "${STATE}.maintenance" ]; then
    exit 0
  fi
fi
THRESHOLD=3
fails=0
for i in 1 2 3; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 http://127.0.0.1:8001/health || echo 000)
  [ "$code" = "200" ] && exit 0
  fails=$((fails+1)); sleep 5
done
# rate-limit: never restart more than once per 10 min
now=$(date +%s); last=$(cat "$STATE" 2>/dev/null || echo 0)
if (( now - last < 600 )); then
  logger -t pennyroyal-watchdog "unhealthy ($fails/3 fails) but restart rate-limited"
  exit 0
fi
echo "$now" > "$STATE"
logger -t pennyroyal-watchdog "unhealthy ($fails/3 fails) -> systemctl --user restart pennyroyal.service"
systemctl --user restart pennyroyal.service
