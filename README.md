# Pennyroyal Engine — der einzige Serving-Owner (seit 2026-10-24)

Rootless-Podman-Betrieb des Qwen3.8-Flash-Next NVFP4-KV Servers auf Port 30000.
Alles Frühere (OrcaRouter 3.0.x, DFLASH2-Prod 31, `sglang-rtxpro6000`-Repos) ist
archiviert und wird nicht gestartet. NIXL und HiCache sind nicht Teil dieses
Rezepts.

## Bestandteile

- `config.env` — zentrale Laufzeit-Parameter (einzige Wahrheit fuer Ports, Caps, GPU, Pfade).
- `pennyroyal.sh` — `start|stop|restart|status|health|test|logs|build|precheck`.
- `pennyroyal.service` — systemd-**User**-Unit (Autostart + Restart bei Crash); Container-Leben
  fuehrt immer `pennyroyal.sh`, die Unit haengt sich per `podman start -a` an.
- `upstream/` — gepinnte Quelle: `Lesilva/qwen38-flashnext-nvfp4-kv@2e05ec3`
  (Pennyroyal 3.1.2, NVFP4-KV + Mamba-Ping-Pong-Fix + QSA-Split-K, MTP-NEXTN).
  Nicht committen (`.gitignore`).

## Launch-Profil

1:1 gegen das Upstream-Rezept (`examples/run-tested-config.sh`), plus:
- `--max-queued-requests 32`, `--served-model-name local-blackwell-swift15` (Router-Kompatibilitaet),
- Metriken: `--enable-metrics --enable-mfu-metrics --enable-request-time-stats-logging
  --enable-cache-report` + TTFT/ITL/E2E-Buckets + `--decode-log-interval 100`,
- Debug-Prompt-Logging: `--log-requests --log-requests-level 2 --log-requests-format json`
  (Level in `config.env`; 2 = vollstaendige Payloads ins Engine-Log),
- Caches nach `/cache` (TileLang, TorchInductor, Triton, HF, XDG) — F-08 behoben,
- Ping-Pong-Fix aktiv (`SGLANG_OPT_MAMBA_SKIP_DECODE_LOCK=true` + `--prefill-decode-interval 1`) — F-09.

## Betrieb

```bash
./pennyroyal.sh build     # Image aus upstream/ bauen (Pennyroyal 3.1.2-Basis via ghcr)
./pennyroyal.sh test      # GPU-Unit-Tests des Forks (Engine muss gestoppt sein)
./pennyroyal.sh start     # ersetzt den Container, wartet auf /health
./pennyroyal.sh status    # Container-Zustand + running/queue/KV-Auslastung
systemctl --user enable --now pennyroyal.service   # Autostart/Restart-Cover
```

Der LiteLLM-Router (`luni-llmops-linux/stacks/router/litellm`) zeigt mit allen
`standard-*`-Profilen auf diesen Endpoint; das Router-Rezept lebt dort, nicht hier.
