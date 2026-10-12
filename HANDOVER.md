# Pennyroyal handover — before eGPU reboot

Date: 2026-10-11
Repository: `/srv/github/pennyroyal`
Working branch: `tom-eval-pennyroyal-3.0-merged-directports-john-experimental`
Base branches: `pennyroyal-main-sm120-final` plus `hermes/pennyroyal-local-dev`

This is an experimental Tom evaluation branch. It combines the current
Penny Royal 3.0 main line with local deployment work and is not a production
release. OOM, GPU-driver and eGPU/PCIe stability issues remain open.

## Current incident — 2026-10-12

At 13:03 CEST the 12:57 startup failed during a 31,169-token prompt prefill:
SGLang logged `torch.OutOfMemoryError` requesting 160 MiB with 136.88 MiB free
and 94.71 GiB already in use. A Triton kernel was first loaded after server
startup with 0.49 GiB free. The log also contains PCIe/AER reports during
Blackwell enumeration, but the direct SGLang failure was CUDA OOM.

SGLang's `running_phase_sigquit_handler` routes a child failure to
`kill_process_tree(os.getpid())`; `python/sglang/srt/utils/common.py` calls
`sys.exit(0)` when PID 1 kills itself. systemd therefore recorded exit status 0
and `Restart=on-failure` did not restart the unit (`NRestarts=0`).

At the operator's direction, the serving configuration was tuned while
preserving `--mem-fraction-static 0.981` (the existing tracked experimental
setting) and leaving automatic `max_total_tokens` sizing unchanged. The active
launcher now uses `PREFILL_CHUNK_SIZE=8192` and caps decode CUDA graph capture
at batch size 8, matching `MAX_RUNNING_REQUESTS=8`. Torch compile settings
remain unchanged. The Quadlet recovery policy is `Restart=always` with a
60-second delay; this is a service-level workaround, not a correction to
SGLang's zero exit status.

The 13:38 CEST restart loaded the model and allocated KV pools using the new
settings (`max_total_num_tokens=1,159,552`, `chunked_prefill_size=8192`,
`available_gpu_mem=2.85 GB` after allocation). The API was still initializing
at 13:41:54, so readiness and a small completion remain to be verified. Do not
run a long-prompt OOM reproduction or performance benchmark without a separate
operator-approved test window.

Observed warnings and their disposition:

- Triton kernels are still being loaded lazily after startup with less than
  1 GiB free. The log recommends preloading them; this is an image/runtime
  startup-coverage issue, not fixed by host config. Keep monitoring for OOM;
  do not suppress the warning.
- The checkpoint supplies no FP8 KV scaling factors, so SGLang defaults to
  1.0 and warns about possible accuracy loss. This needs checkpoint/runtime
  qualification, not a speculative local override.
- SGLang reports derived context length 262,144 versus configured 524,288.
  The deployment intentionally uses a YaRN override; long-context correctness
  still needs a validated test.
- NIXL's `/nonexistent-nixl-probe` open failure is part of the startup
  capability probe. The Mamba pool is not OS-page-aligned and falls back to
  bounce buffers; only the QSA compressed pool reports zero-copy. These are
  performance/implementation observations, not user-configurable errors.
- Adaptive speculative decoding repeatedly switches between 3 and 7 steps.
  Do not change the approved policy based only on decode logs; first compare
  latency and acceptance under a controlled workload.
- `podman stats` showed about 107% CPU for Pennyroyal while its cgroup had
  `cpu.max=max 100000`, no CPU quota, and access to CPUs 0-31 (32 online).
  This is approximately 1.07 cores; desktop container views may normalize
  utilization per core and display >100%. No CPU cap was found or changed.

## Test hardware

The primary test host is a **Lenovo ThinkPad P16 Gen 2** (`21FBSELM00`, BIOS
`N3TET64W (2.00)`) with a 13th Gen Intel Core i9-13950HX (24 cores / 32
threads) and 188 GiB RAM. The host runs Ubuntu 26.04.1 with kernel
`7.0.0-30-generic`.

The internal graphics devices are Intel Raptor Lake UHD (`00:02.0`, `i915`)
and NVIDIA RTX 3500 Ada Laptop GPU (`01:00.0`, currently `nouveau`). The
Samsung external monitor is connected as `DP-2` through the internal NVIDIA
GPU; the internal laptop panel is `eDP-1` on Intel. This multi-GPU Wayland
path is part of the stability investigation.

The intended external accelerator is a separate **NVIDIA RTX PRO 6000
Blackwell eGPU**. It is currently disconnected and was not present in the
latest PCI inventory. No Blackwell result should be treated as a completed
test until the eGPU is physically connected and the PCIe/driver state is
verified.

Storage in the test host consists of two Kingston 4-TB NVMe drives. The active
Ubuntu system is on the second drive's encrypted Btrfs volume; the first drive
contains BitLocker partitions. These storage facts are recorded for
reproducibility and are not a request to modify either drive.

The working branch has its own remote tracking branch with the same name.
Keep local development, deployment documentation and host-specific commits on
this Tom evaluation branch; do not push them to John's main or repair branch.

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

## Historical verification — 2026-10-11

- The current host session does not see the external Blackwell: `nvidia-smi -L`
  reports only the internal RTX 3500 Ada.
- The CDI UUID entry for `GPU-780d3589-9811-40ec-db66-93a9146697f3` is absent,
  so starting Pennyroyal fails during Podman device setup with exit status 126.
- The model checkout remains present at `/srv/ai/models/RadixArk-Qwen3.8-Flash-Next-NVFP4` and is approximately 319 GB.
- The service was stopped after verification to prevent repeated restart attempts.
- The tracked deployment source is the Tom branch in
  `/home/z000g9hu/work/sglang-rtxpro6000`; its Quadlet now references the
  verified remote image digest. Re-run the recovery sequence above after the
  eGPU is connected or the host has been rebooted.

## Afternoon follow-up — 2026-10-12 (post-ladder)

- c16 profile deployed and validated: queue cap 32, slots 67, fraction 0.947,
  graph cap 16. Full concurrency ladder + cold ramps passed with NRestarts=0,
  zero retractions, peak pool occupancy 0.74. Numbers, operating-envelope
  recommendation (engine 16 / gateway policy 8–12) and the fallback-routing
  best practices live in `docs/local-deployment.md`; commits `feafb6329`,
  `b47d7dc5e`, `453e86d44`. Not pushed.
- LiteLLM gateway edits (gate 18, cooldowns, fallback order) are written but
  inert until a proxy reload — operator decision pending, reload must avoid
  killing live agent traffic (this workstation routes its own agents through
  it).

## Ladder v2 addendum (evening)

Saturated grid c1–c32 incl. 100k tier (prompt counts scale with c — v1's
fixed counts under-saturated high-c long/xlong rows). Result tree
`bench-results/ladder-merged`; full tables + sweet-spot analysis in
`docs/local-deployment.md`. Headline: aggregate plateaus c8–c12, xlong
regresses −29 % beyond the cap (TTFT 12–23 s), per-request 67–95 tok/s @c8
vs 17–22 @c32, xxlong-100k survives c32 (NRestarts=0 — queue cap + pool
admission convert the flood into 7-wide concurrency). Spec accept length
flat across c (adaptive-spec v2 verified). Gateway policy recommendation:
admit ≤8 interactive / ≤12 batch, queue the rest, MTP stays on.
