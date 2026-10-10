# Pennyroyal local deployment

This file is the operational record for the local RTX PRO 6000 deployment. Keep
host paths, image tags, service commands, failures, and recovery steps here when
the deployment changes. Do not place tokens or private keys in this repository.

## Current deployment

- Repository: `/srv/github/pennyroyal`
- Working branch: `hermes/pennyroyal-local-dev` (local-only)
- Base branch: `john/pennyroyal-container-v3.0-repair`
- Source commit: `5d33142c1f3fd3df1548b9682f728fcdd8c7a710`
- Compile checkpoint commit: `02f6b6532b498a36455f0d1a20367785033b137e`
- Image: `localhost/pennyroyal:john-repair-5d33142c1`
- Image ID: `1c0cedb4103b6a68292aa1be3df5131f8170e09843ada54b8ee46bee8713ac53`
- Model: `/srv/ai/models/RadixArk-Qwen3.8-Flash-Next-NVFP4`
- Model mount: `/models/RadixArk-Qwen3.8-Flash-Next-NVFP4`
- Quadlet: `/home/z000g9hu/.config/containers/systemd/pennyroyal.container`
- API: `127.0.0.1:8001`
- GPU target: `GPU-780d3589-9811-40ec-db66-93a9146697f3`
- PLE: RAM-backed by default
- HiCache: 32 GB
- TP: 1

The model checkout is complete and the image build completed successfully.

## Rebuild

Run from the repository root. The build uses the locally reviewed source commit
and the eight-job compile budget:

```bash
cd /srv/github/pennyroyal
REV=$(git rev-parse HEAD)
podman build --pull=always --format docker \
  --build-arg SOURCE_REVISION="$REV" \
  --build-arg FLASHINFER_BUILD_JOBS=8 \
  -f docker/pennyroyal/Dockerfile \
  -t localhost/pennyroyal:john-repair-5d33142c1 .
```

The image must pass the image-side `pennyroyal --check` before it is started.

## Start and verify

The tracked Quadlet source is `deploy/pennyroyal.container`. Install it with:

```bash
scripts/pennyroyal/install-quadlet.sh
```

Quadlet units are generated and must not be enabled with `systemctl enable`.
Reload and start the generated user unit directly:

```bash
systemctl --user daemon-reload
systemctl --user start pennyroyal.service
systemctl --user status pennyroyal.service --no-pager --full
```

Verification after GPU recovery:

```bash
podman ps -a --filter name=pennyroyal
curl -fsS http://127.0.0.1:8001/health
curl -fsS http://127.0.0.1:8001/v1/models
```

The service has a one-hour start timeout because model loading and profiling are
large. Do not start a second build or container while one is active.

## Logs

The tracked copy of the log helper is `scripts/pennyroyal/llmlogs`. Install it
from this repository when needed:

```bash
sudo install -m 0755 scripts/pennyroyal/llmlogs /usr/local/bin/llmlogs
llmlogs -u pennyroyal.service -n 200
llmlogs -u pennyroyal.service -f
```

## Host preflight

Run the tracked preflight before starting the service:

```bash
scripts/pennyroyal/host-preflight.sh
```

It checks the model, image, CDI entries, GPU UUID, driver visibility, Quadlet,
and service state without changing host state.

## Known failure: GPU1 driver state

On 2026-10-11 the first container start failed before model loading:

```text
CUDA initialization: CUDA unknown error
TP_SIZE=1 needs at least 1 visible CUDA device(s), but only 0 is visible
```

The host checks showed:

- GPU 0 (RTX 3500 Ada) is visible to `nvidia-smi`.
- GPU 1 (RTX PRO 6000 Blackwell, PCI `0000:4b:00.0`) is bound to `nvidia` but
  `nvidia-smi` reports `Unknown Error` and no device handle.
- CDI contains the intended UUID entry.
- Kernel logs contain GPU1 MMU/TLB/GSP failures and `NV_ERR_INSUFFICIENT_RESOURCES`.
- This is a host NVIDIA driver/GPU state failure, not a Pennyroyal image or
  CUDA_VISIBLE_DEVICES configuration failure.

The Blackwell is an external PCIe GPU and is hotplug-capable in the device tree:

- GPU BDF: `0000:4b:00.0`
- PCI path includes the hotplug bridge at `0000:4a:00.0`
- `reset_method`: `flr bus`
- PCI device is enabled and runtime-active

A later check still showed the same failure. Kernel logs additionally reported
`pciehp ... no response from device` on the upstream hotplug ports. This points
to an eGPU link/device state problem in addition to the NVIDIA MMU/GSP errors.
A clean eGPU power-cycle or host reboot is therefore preferred over repeatedly
restarting the container. After the device returns, rerun `nvidia-smi -L`,
regenerate CDI if the UUID changed, and run the preflight before starting the
service.

Do not repeatedly restart Pennyroyal while GPU1 is in this state. First collect:

```bash
nvidia-smi -L
nvidia-smi -i 1 -q
sudo dmesg -T | grep -Ei 'NVRM|nvidia|Xid|fallen|rm_init_adapter' | tail -200
nvidia-ctk cdi list
```

If the GPU remains unavailable, stop applications using NVIDIA devices, then
attempt a PCI function-level reset only if the desktop/session can tolerate the
GPU reset. A full reboot is the safe recovery when the kernel NVIDIA state cannot
be reset cleanly. After recovery, regenerate CDI and rerun the preflight:

```bash
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
scripts/pennyroyal/host-preflight.sh
```

## Benchmark repositories

Quality and agent validation:

```text
/srv/github/pennyroyal-validation
```

Its venv is `/srv/github/pennyroyal-validation/.venv`. It contains the frozen
reasoning/tool suites and the reusable 64K/490K plus 1x/4x OpenAI benchmark.

For serving-load comparisons, add the SGLang `bench_serving` harness and an
independent OpenAI-compatible load harness later. Keep quality results and load
results in separate output directories and record model, image, source commit,
PLE mode, HiCache size, concurrency, input/output lengths, and CPU/GPU power
profile for every run.

## Performance profile used during build

The host was switched temporarily to:

```text
ACPI platform profile: performance
CPU frequency governor: performance
Intel turbo: enabled (intel_pstate/no_turbo=0)
```

These settings may be reset by reboot or power-management software. They are
not part of the container image and should be recorded with benchmark results.
