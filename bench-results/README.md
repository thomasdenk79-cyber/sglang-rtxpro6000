# Benchmark results — Qwen3.8-Flash-Next NVFP4 on 1× RTX PRO 6000 Blackwell (Pennyroyal fork)

All measurements from October 2026 on a single RTX PRO 6000 Blackwell (96 GB),
host: 188 GB RAM, SN850X-class Gen4 NVMe, Linux, rootless Podman.
Stack: Pennyroyal/SGLang v3.0.1 (digest `25400f56`), model
RadixArk/Qwen3.8-Flash-Next-NVFP4, context 524288 (YaRN), FP8 KV cache,
native NEXTN/MTP speculative decoding, HiCache 32 GB + NIXL host tier,
FR-Spec chunk 8192, `MAX_RUNNING_REQUESTS=8`.

**TL;DR of everything below:**

- PLE from NVMe (page cache) is at least as fast as pinned-RAM PLE on this box
  and frees ~47 GB of host RAM. We kept NVMe as the production backend.
- With a healthy 188 GB host the PLE table is 100 % page-cached anyway
  (hit rate ≈ 99.99 % in warm operation), so "NVMe PLE" effectively behaves
  like a RAM read after boot — the win is memory headroom, not bandwidth.
- The v3.0.1 image reader hardcodes a 16 MiB staging budget that is too small
  for the 131072-row chunk-8192 lookup; the fix is a drop-in override
  (`deploy/ple-nvme-override/`) — see pitfalls in `PLE-AB-20261014.md`.

## Reports

| File | Content |
|------|---------|
| `PLE-AB-20261014.md` | Round 1 A/B (mixed concurrency incl. c16/c32 ladder, contamination caveats, decision + rollback note) |
| `PLE-AB2-20261014.md` | Round 2 A/B, clean protocol: 32 points, tiers × c1–c8, both backends, full table + findings |
| `PLE-CACHE-ANALYSE-20261014.md` | Cold-boot vs warm measurement (DBA-style: drop_caches + service restart), hit-rate via block-layer counters, residency via fincore, why ZFS ARC/pin-offer nothing |

## Raw data directories

| Directory | Content |
|-----------|---------|
| `ab2-nvme-20261014-013654/` | Round 2 NVMe backend, 32 `qwen_<tier>_c<n>.json` + logs + `META.txt` (fincore residency before/after) |
| `ab2-ram-20261014-020128/` | Round 2 RAM backend, same layout/protocol |
| `recipe-20261012-214118/` | FR-Spec recipe confirmation runs (post-tuning) |
| `tuned-0981-8192-20261012-*/` | mem-fraction 0.978 / chunk 8192 tuning suite |
| `ladder-full-*`, `c16-ladder-*`, `ladder-merged/` | concurrency ladders incl. c16/c32 (Round 1 era) |
| `stress-c8-20261012-2051/` | c8 sustained stress soak |
| `turbo8/` | early high-concurrency probes |
| `bench_qwen_random_1k256_c{1,8,32}.json` | first single-point smoke benches |
| `bf16_ple_shards.txt` | file list of the 33 original BF16 PLE shards (104.3 GB, Round C prep) |

JSONs are `sglang.bench_serving` output (random dataset, range-ratio 1.0,
temperature 0, 8 prompts per point unless stated otherwise).

## Reproducing

1. Runner: `benchmark/run_ab_matrix.sh <backend-tag>` — boots fresh, warms up
   each tier with a *sequential single request*, waits 60 s, then runs the
   4-tier × c1–c8 matrix with retries; records fincore + MemAvailable around
   every pass. Override tiers with `TIER_SPEC="short:256:256,xlong:32768:1024"`.
2. Compare tables: `python3 benchmark/compare_ab2.py <nvme-dir> <ram-dir>`.
3. Cold/warm PLE: see `PLE-CACHE-ANALYSE-20261014.md` — the boot checksum in
   `prepare_ple_nvme.py` output plus Pennyroyal startup verification reads the
   whole table, so true cold state is unreachable in production; measure with
   `fincore` + `/sys/block/nvme*/stat` deltas, not wall-clock.

## Measured envelope (Round 2, warm, exclusive)

- Aggregate output throughput scales 220 → 806 tok/s from c1 to c8 (xlong tier).
- TTFT stays ≤ ~500 ms up to c8 at all tiers except xlong c1/c2 (page-in path).
- Accept length 3.0–3.2 stable across both backends.
- No OOM at any point; at c32/long only the RAM backend OOM'd in Round 1
  (pinned 48 GB + KV pressure), NVMe survived comfortably — reason to prefer
  NVMe beyond the RAM headroom.

## Known limits

- c > 8 is not accepted (`MAX_RUNNING_REQUESTS=8` by design on 96 GB).
- Round 1 numbers are contaminated by concurrent agent traffic (documented
  in that report); trust Round 2 tables for A/B statements.
- The `xlong` c1 advantage of NVMe (+44 %) is a code-path effect (async
  io_uring gather vs synchronous PCIe copy), not a memory-pressure effect —
  see correction note in `PLE-AB2-20261014.md`.
