# Pennyroyal local deployment

This file is the operational record for the local RTX PRO 6000 deployment. Keep
host paths, image tags, service commands, failures, and recovery steps here when
the deployment changes. Do not place tokens or private keys in this repository.

## Current deployment

- Repository: `/home/z000g9hu/work/sglang-rtxpro6000`
- Working branch: `tom-eval-pennyroyal-3.0-merged-directports-john-experimental`
- Image: `ghcr.io/jpezzulli/sglang-rtxpro6000@sha256:fd26ba8d3ce001bb6e4b865236e1b69f7f790b94fb7fe1c32aa81799f4fe338c`
- Image ID: `f65e985400d9eb4a5c0e13f4e7b40de5038c9dcc9033f21453111f1fa2284189`
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

- The service has a one-hour start timeout because model loading and profiling are
  large. Do not start a second build or container while one is active.

## Historical host state — 2026-10-11

- The model checkout is present under `/srv/ai/models/RadixArk-Qwen3.8-Flash-Next-NVFP4` and occupies approximately 319 GB.
- `/srv/ai/cache/pennyroyal`, `/srv/ai/nixl/pennyroyal`, and `/srv/ai/pennyroyal/config/config` are present.
- The tracked Quadlet was installed from the `tom-eval-pennyroyal-3.0-merged-directports-john-experimental` branch and now uses the verified remote image digest above.
- The RTX PRO 6000 Blackwell UUID is not visible to `nvidia-smi`, and the CDI entry is unavailable. The service is stopped to avoid an auto-restart loop.
- The remaining Pennyroyal blocker is host/eGPU recovery, not model storage or the container image. Do not start the service until the preflight passes.

## OOM recovery — 2026-10-12

The user journal records a CUDA OOM at 13:03 CEST while prefilling a 31,169-token
prompt. SGLang requested 160 MiB with 136.88 MiB free and reported 94.71 GiB in
use; a Triton kernel was loaded after startup with 0.49 GiB free. PCIe/AER
messages occurred during eGPU enumeration, but the application log identifies
the CUDA allocation failure as the direct server error.

The scheduler failure was delivered as SIGQUIT. The current code path ends in
`sys.exit(0)` for PID 1, so systemd saw a successful exit and did not apply
`Restart=on-failure`. The active Quadlet now uses `Restart=always` with a
60-second delay.

At the operator's direction during the first recovery,
`--mem-fraction-static` was returned to `0.988` and `PREFILL_CHUNK_SIZE` set
to 4096. A follow-up tuning pass at 13:35 CEST restored the tracked
experimental `--mem-fraction-static 0.981` (adding roughly 0.7 GiB of runtime
headroom), returned `PREFILL_CHUNK_SIZE` to 8192, and enabled
`--cuda-graph-max-bs-decode 8` so decode graphs match the 8-request capacity
instead of the default 256 batch list. Automatic `max_total_tokens` sizing
and Torch compile settings were deliberately left unchanged. CUDA graph and
Torch compile settings were left as qualified otherwise.

The 13:38:24 CEST restart verified the new settings: `server_args` shows
`mem_fraction_static=0.981` and `chunked_prefill_size=8192`, decode graph
capture ran only for `bs=[1]` and `bs=[1..8]`,
`max_total_num_tokens=1159552` with `available_gpu_mem=2.85 GB` after
allocation (previously 1209728 tokens / 2.18 GB). `/health` returns HTTP 200
and a minimal chat completion succeeded. Triton lazy-load warnings continued
at runtime; those require an image-side preload fix and are tracked in
`HANDOVER.md`. A 31k-token prefill reproduction is still owed before this
configuration can be called OOM-validated.

The NIXL disk-tier namespace hashes `chunked_prefill_size`, so the chunk
change moved the FILE cache to a fresh empty namespace directory; the old
directory under `/srv/ai/nixl/pennyroyal` is now orphaned and can be pruned
once the new cache is populated.

The 13:09:38 recovery startup was still loading GPU memory pools at 13:13:22
and its final health probe failed; it was superseded by the verified 13:38:24
tuning restart above. The live operator config is
`/srv/ai/pennyroyal/config/config/start-flash-next-frspec.sh`; the tracked
recipe baseline is `configs/pennyroyal/serve-flash-next-frspec.sh`. Keep their
launch flags, memory sizing, chunk size and CUDA graph batch cap in step.

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

## Overload control and fallback routing — best practices (2026-10-12, not yet finalized)

Decisions here are deliberately deferred until the c16 concurrency-ladder
(`bench-results/c16-ladder-*`) identifies the sustainable `max_running_requests`
knee per workload tier; everything below documents the mechanism, not the final
numbers. The LiteLLM gateway changes were written to `~/.config/litellm/config.yaml`
(backup: `config.yaml.bak-20261012`) but are inert until a proxy reload, which is
also deferred.

### Memory model — what actually costs VRAM

* A **waiting** request (anything beyond `--max-running-requests`, capped by
  `--max-queued-requests`) lives in host RAM only: token ids + scheduler
  bookkeeping. Worst case ~0.5 GB host for a full 32-deep queue of 100k-token
  agent prompts. No GPU tensors are allocated for waiting requests.
* **Admitted** requests cost VRAM: recurrent-state slots are reserved around
  prefill admission (`extra_buffer_lazy` ≈ 4 slots/request, measured 58 MB/slot
  on this model), activation buffers scale with **prefill batch tokens**
  (`--max-prefill-tokens`, not the running cap), and KV grows per token
  (measured 12.4 KB/token incl. draft pool).
* The 2026-10-12 14:00 crash (`long_c32` on the c8 profile) was **not** "queue
  memory": an unbounded admission storm (no `--max-queued-requests` was set —
  the upstream default is unlimited) let ~32 in-flight admissions hold 25–28
  of 35 mamba slots, drove the most aggressive chunk+decode overlap
  (2×8192-token prefill beside 7 decodes), and fragmented the allocator
  (1.40 GiB reserved-unallocated at OOM). The queue cap plus c16 slot sizing
  removes both the slot pressure and the batch-shape outlier.
* A running request is **never** offloaded to make room for the next one: its
  KV and mamba state stay resident until it finishes. Slot turnover therefore
  costs one intrinsic prefill for the *new* request (identical at any
  concurrency), not a reload of the old one. HiCache (`write_through`) already
  keeps the finished session's copy warm in host RAM/SSD for its next turn.
* The real degradation path is **KV-pool occupancy**, observable as
  `full token usage` in the decode log: sustained > ~0.85 evicts other
  sessions' cached prefixes (next turn reloads from RAM/SSD or re-prefills),
  and exhaustion **retracts** running requests (`retraction_policy: length`),
  forcing a full re-prefill on re-admission. That, not queue depth, is the
  throughput/quality killer the operator intuition points at.

### Sizing rules

* Sustainable concurrency ≈ `pool_tokens × 0.7 ÷ E[session context]`, floored
  by the mamba-slot requirement (`requests × 4 + 3`) and graph-bucket cost.
  At the c16 profile (778,816-token pool): Ø15k sessions → 36 (running cap
  binds first), Ø40k → 14, Ø60k → 9. Expect the ladder to show the knee at
  high c on the xlong tier while short/medium scale cleanly.
* Queue depth is a **latency/burst knob, never a VRAM knob**. 2× running
  absorbs slot-turnover races so requests that would be served <1 s later are
  not 429'd into coarse client backoff (Claude Code retries at 1 s, 2 s, 4 s…).
  The binding constraint on queue depth is client timeout, not memory.
* 429 is the intended signal: SGLang answers "The request queue is full."
  immediately; queue depth is observable out-of-band via `/get_load`
  (num_running/num_waiting) and Prometheus (`enable_metrics: true` is live).

### Layered overload defense (target architecture)

1. **Engine envelope:** `--max-running-requests <ladder knee>`,
   `--max-queued-requests 2×`, mamba slots per requests×4+3, mem-fraction
   funding both plus ≥ ~2 GB post-graph headroom (this is what the 0.947
   c16 fraction buys: measured `available_gpu_mem` 5.10 GB at init vs 2.85 GB
   before, at the cost of a 33 % smaller KV pool).
2. **Gateway gate:** LiteLLM `max_parallel_requests` at the deployment, set at
   the engine running cap (draft: 18). Overflow gets a gateway 429 without
   ever reaching the server.
3. **Fallback + cooldown:** `num_retries: 0` makes a 429 fall through
   instantly; `allowed_fails: 3` + `cooldown_time: 20` (previously
   `disable_cooldowns: true` suppressed this) takes the deployment out of
   rotation during sustained overload so steady traffic rides the fallbacks
   undisturbed. This event-based scheme approximates queue-depth-aware routing
   (which LiteLLM cannot do natively) with zero custom components; a
   `/get_load`-polling watchdog is the escalation option if preemptive
   routing ever matters more than one wasted hop per transition.
4. **Client layer:** standard 429 exponential backoff (all agent SDKs have it).

### Fallback routing policy — draft for benchmark-time decision

Current `fallbacks: qwen → bonsai[, luna]` would route architect-level overflow
to bonsai-27b, which is the wrong quality trade: bonsai is a dense 27B fork at
~10–20 tok/s and roughly an order of magnitude below Flash-Next on the
intelligence index, so quality-sensitive overflow must prefer luna (cloud,
already covered by the flat ChatGPT subscription, more reliable than the local
stack, zero maintenance). Efficiency ledger at measured figures:
bonsai ≈ 130 W ÷ ~15 tok/s ≈ **~9 J/token**, pennyroyal ≈ 600 W ÷ ~600+ tok/s
≈ **~1 J/token**, i.e. pennyroyal is both ~9× cheaper per token and far
smarter; bonsai's throughput advantage over an idle cost never materializes
while its GPU draws 130 W under load.

Remaining rational roles for bonsai (to confirm after the ladder): emergency
fallback while pennyroyal restarts or is re-benchmarked, trivial mechanical
local tasks (formatting, small edits, "simple implementer" agent roles), and
**offline continuity** — luna requires internet and account availability,
bonsai does not. If none of those justify keeping a patched, tuned,
benchmarked second stack, retiring it is on the table; the decision belongs to
the same post-benchmark review as the gateway rollout.

### Measured ladder results — c16 profile (2026-10-12, `bench-results/c16-ladder-20261012-142032`)

31 runs (short/medium/long/xlong × c1–c16) + cold ramp 32k/65k/100k, all
DONE, service NRestarts=0, peak `full token usage` 0.74, zero retractions.
The previous crash trigger (cold 32k+ prefills) passes cleanly.

| c | ITL (avg) | tok/s per request | aggregate out t/s (med/long/xlong) | TTFT avg |
|---|-----------|-------------------|--------------------------------------|----------|
| 1 | 1.9–2.5 ms | ~400–520 | 256 / 267 / 258 | 0.13–1.5 s |
| 4 | 4.7 ms | ~130–175 | 494 / 585 / **706** (xlong peak) | 0.15–0.23 s |
| 8 | 8.4–8.5 ms | ~118 | 457 / 606 / 608 | 0.25–0.74 s |
| 12 | 11.4–12.1 ms | ~45–53 | 593 / 638 / 535 (xlong regresses) | 0.28–1.35 s |
| 16 | 13.0–13.4 ms | ~37–45 | 594 / **719** / 603 | 0.59–1.83 s |

Findings: no cliff up to c16 (near-linear ITL scaling); aggregate gains beyond
c8 are small (+15–20 %) while xlong output regresses at c12+ (prefill queueing
+ pool occupancy 0.74) and TTFT jitter doubles. The `short` tier runs at c3/c6
are contaminated by supervising-session traffic sharing the endpoint and
should not be over-read. Operating recommendation: engine `running=16`
stays as the measured safe envelope (VRAM pre-funded, validated by this
ladder); the quality *policy* rides the LiteLLM gate at 8–12 in-flight with
overflow falling through — interactive knee ~c8, throughput plateau c12–c16.
Follow-up owed: bonsai's 10–20 tok/s on the RTX 3500 Ada is anomalous for a
fully-resident 4–6 GB model (~60 tok/s bandwidth ceiling) and needs a
llama.cpp flag/quant/context audit before any keep-or-retire decision.
