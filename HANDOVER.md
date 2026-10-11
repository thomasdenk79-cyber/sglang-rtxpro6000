# Pennyroyal handover — before eGPU reboot

Date: 2026-10-11
Repository: `/srv/github/pennyroyal`
Working branch: `tom-eval-pennyroyal-3.0-merged-directports-john-experimental`
Base branches: `pennyroyal-main-sm120-final` plus `hermes/pennyroyal-local-dev`

This is an experimental Tom evaluation branch. It combines the current
Penny Royal 3.0 main line with local deployment work and is not a production
release. OOM, GPU-driver and eGPU/PCIe stability issues remain open.

The working branch is local-only and has no upstream configured. Do not push
local development, deployment documentation, or host-specific commits to the
John branch. A private fork may be added later as a separate remote after an
explicit decision.

## Agent continuation rule

The operator will not execute the recovery or startup commands manually. The
next agent must read this handover, perform the checks and recovery steps itself,
and keep updating this repository after every material action. Do not merely
print commands for the operator. If a reboot or physical eGPU power-cycle is
required, state the exact blocker and wait for the operator to perform that
external action; after the session returns, resume verification automatically.

## Completed

- ZFS-backed `/srv` environment is mounted and used for models, caches, repos,
  and container data.
- Model checkout is complete:
  `/srv/ai/models/RadixArk-Qwen3.8-Flash-Next-NVFP4`
- Pennyroyal source is checked out at:
  `5d33142c1f3fd3df1548b9682f728fcdd8c7a710`
- Compile defaults were raised to eight jobs and committed in:
  `02f6b6532b498a36455f0d1a20367785033b137e`
- Image build completed successfully:
  `localhost/pennyroyal:john-repair-5d33142c1`
- Image ID:
  `1c0cedb4103b6a68292aa1be3df5131f8170e09843ada54b8ee46bee8713ac53`
- Image-side package, FlashInfer-SM120, NIXL, POSIX plugin, and runtime checks
  passed. The image's `gpu_tested=false` is expected because the image build is
  not a GPU runtime test.
- Validation repository is available at:
  `/srv/github/pennyroyal-validation`
- Validation venv is ready at:
  `/srv/github/pennyroyal-validation/.venv`
- Tracked operational files now include:
  - `deploy/pennyroyal.container`
  - `scripts/pennyroyal/install-quadlet.sh`
  - `scripts/pennyroyal/host-preflight.sh`
  - `scripts/pennyroyal/llmlogs`
  - `docs/local-deployment.md`

## Current blocker

The first Quadlet start was attempted and failed before model loading:

```text
CUDA initialization: CUDA unknown error
TP_SIZE=1 needs at least 1 visible CUDA device(s), but only 0 is visible
```

The target RTX PRO 6000 Blackwell is the external GPU:

- UUID: `GPU-780d3589-9811-40ec-db66-93a9146697f3`
- PCI address: `0000:4b:00.0`
- PCIe hotplug bridge path includes: `0000:4a:00.0`
- `reset_method`: `flr bus`
- PCI driver: `nvidia`
- NVIDIA driver: `615.78.08`

The host can see the PCI function and CDI UUID, but `nvidia-smi` reports:

```text
Unable to determine the device handle for GPU1: 0000:4B:00.0: Unknown Error
```

Kernel logs contain NVIDIA MMU/TLB/GSP failures and PCIe hotplug messages:

```text
pciehp: pcie_do_write_cmd: no response from device
```

This is a host eGPU/PCIe/device-driver state problem, not a Pennyroyal image
or Quadlet configuration problem.

## After reboot or eGPU power-cycle

Run these steps in order:

```bash
nvidia-smi -L
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
nvidia-ctk cdi list
cd /srv/github/pennyroyal
scripts/pennyroyal/host-preflight.sh
```

The preflight must report the selected Blackwell UUID as visible before starting
the service. If it passes:

```bash
scripts/pennyroyal/install-quadlet.sh
systemctl --user start pennyroyal.service
systemctl --user status pennyroyal.service --no-pager --full
llmlogs -u pennyroyal.service -f
```

In a second terminal, wait for model initialization and then check:

```bash
curl -fsS http://127.0.0.1:8001/health
curl -fsS http://127.0.0.1:8001/v1/models
```

Do not use `systemctl --user enable pennyroyal.service`; Quadlet generates this
unit. Use `systemctl --user start` after `daemon-reload`.

## If the GPU is still missing

Collect and preserve the output before changing more configuration:

```bash
nvidia-smi -L
nvidia-smi -i 1 -q
sudo dmesg -T | grep -Ei 'NVRM|nvidia|Xid|fallen|rm_init_adapter|pciehp|AER' | tail -200
lspci -vv -s 4b:00.0
nvidia-ctk cdi list
```

Do not repeatedly restart the Pennyroyal service while the GPU handle is broken.
A clean external-GPU power-cycle is preferred; a full host reboot is the safe
fallback when the NVIDIA GSP/MMU state cannot be reset.

## Benchmark plan after service readiness

Use `/srv/github/pennyroyal-validation` for quality and agent suites. Use the
SGLang serving harness plus an independent OpenAI-compatible load harness for
performance. Record every run's:

- image ID and source commit
- model path and served model name
- PLE mode (`ram` or `nvme`)
- HiCache size and NIXL configuration
- CPU platform profile/governor and GPU power state
- input/output lengths
- concurrency: C1, C4, C8, C16
- TTFT, TPOT/ITL, end-to-end latency, aggregate tok/s
- raw result path and journal path

The current Quadlet uses RAM PLE, 32 GB HiCache, TP1, four max running requests,
CPU media preprocessing, and local API port `127.0.0.1:8001`.

## Pre-restart state — 2026-10-11

- The eGPU recovered after the host restart: `nvidia-smi -L` sees the target
  Blackwell UUID and the NVIDIA driver is `610.57.04`.
- CDI and `scripts/pennyroyal/host-preflight.sh` pass.
- The six missing Git-LFS weight files were downloaded successfully. Their total
  size is `30,400,159,113` bytes and all Safetensors headers validate.
- Pennyroyal was started again and reached model initialization. The container
  was still `starting` while deriving the NIXL namespace; `/health` was not yet
  ready at the time of this handover.
- A host restart is now required. After boot, verify the GPU, regenerate CDI if
  needed, run the preflight, and then verify the service and API endpoints.

## Post-restart continuation — 2026-10-11

- The RTX PRO 6000 Blackwell is visible as GPU 1 with UUID
  `GPU-780d3589-9811-40ec-db66-93a9146697f3`, compute capability 12.0, and
  97,887 MiB total memory. The NVIDIA driver is `610.57.04`.
- CDI was stale after the driver change: `/etc/cdi/nvidia.yaml` referenced
  `615.78.08` libraries. It was regenerated successfully with
  `sudo -n nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`.
- Host preflight passes and the Quadlet now starts. Pennyroyal is active and
  has reached NIXL namespace derivation for the Flash-Next FR-Spec profile.
- Model loading and SM120 autotuning completed successfully. The container is
  healthy, `/health` returns successfully, `/v1/models` reports `pennyroyal`
  with `max_model_len=524288`, and a non-thinking chat completion returned
  `BLACKWELL_OK`.
- The Blackwell currently uses about 89,330 MiB of 97,887 MiB. The service is
  running with the original checkpoint, RAM PLE, 32 GB host HiCache, and the
  separate NIXL disk tier.
