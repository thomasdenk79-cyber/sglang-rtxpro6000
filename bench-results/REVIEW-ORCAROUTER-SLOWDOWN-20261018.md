# Review: why the OrcaRouter/NVFP4 container (luni stack) is slower than this repo's Oct-12 recipe

Date: 2026-10-18 (evening). Cross-repo analysis, no runs against this checkout.
Live subject: `qwen38-orcarouter-nvfp4` on 1x RTX PRO 6000, image `3.0.1-nvme-ple`
(Pennyroyal 3.0.1 base + the three Lesilva `qwen38-flashnext-nvfp4-kv` patch sets, all
11 overlay module hashes verified), checkpoint
`jpezzulli/OrcaRouter-Qwen3.8-Flash-Next-Uncensored-ModelOpt-NVFP4`.
Reference: our fast recipe in this repo — `deploy/runtime-config/start-flash-next-frspec.sh`
on branch `tom-eval-pennyroyal-3.0-merged-directports-john-experimental`, measured in
`bench-results/recipe-20261012-214118` (`r1_agent.json`, `r2_agent.json`).

## Headline numbers

| Setup | Workload | out tok/s | TPOT med | TTFT med | accept |
|---|---|---:|---:|---:|---:|
| Old recipe (fp8 KV, Swift-1.5 ckpt, this repo) | c8, 8192/1024, n16 | **579 / 627** | 10.0 / 10.1 ms | 0.42 / 0.46 s | **3.30** |
| Fair re-run on the new container, same shape | c8, 8192/1024, n16 | **346** | 14.2 ms | 0.60 s | 2.44 |
| Vendor reference (Lesilva results.md, OrcaRouter + NVFP4 KV, HiCache 32 GB+NIXL, running 16, chunk 2048, fixed MTP 3/4) | c8, 8192/1024 | **~704** | ~10.5 ms | — | 2.297 (FP8) / 2.315 (NVFP4) |
| New container, current parity profile (full-matrix run, stopped 19:29) | c8, 8192/256, n32 | 244 | 24.4 ms | 1.7 s | — |

So: NVFP4 KV costs ~1% per the vendor's own paired measurements. A 40% gap cannot be the
quantization. The gap sits in flags we turned off while chasing the Oct-17/18 crashes, plus
an inherent checkpoint acceptance difference.

## Root cause: the current launch does NOT carry the fast recipe's switches

From `start-flash-next-frspec.sh` (line numbers as of branch tip, this checkout):

1. **`SGLANG_OPT_MAMBA_SKIP_DECODE_LOCK=true`** — hard-set on the NVFP4-KV branch
   (lines 56, 140). We removed it on 2026-10-17 as a crash countermeasure; the later
   crashes had different stack traces (HiCache `backup_from_device_all_layer`, PLE
   SSD-stream graph replay), so removal was never the fix — it just removed decode-lock
   bypass. TPOT moved from ~10 ms (Oct-12) to 14–24 ms (rc2.2/23). Largest single suspect.
2. **`PENNY_PLE_BACKEND=nvme`** without `--ple-offload-embedding` (lines 30–31): current
   stack runs `ram` + offload-embedding. Our own Oct-14 A/B (`PLE-AB2-20261014.md`):
   nvme ≥ ram on this box. No downside to restoring.
3. **HiCache ON: 64 GB L2 + `qsa_compressed_hicache=true` + NIXL** (lines 26, 296, 311–313):
   current stack: HiCache completely OFF. Directly explains the collapse of long-context
   concurrency cells: cold re-prefill (~11–12k tok/s vendor-measured for this path) has to
   stream whole prompts each time; e.g. c2×458752 took 114 s wall for 4×~458k tokens.
4. **`SGLANG_FR_SPEC_PROPOSAL_HEAD_PRECISION=nvfp4`** (line 36): unset on the new stack
   (code path not yet proven in the overlay — needs verification before re-enabling).
5. **`MAX_MAMBA_CACHE_SIZE=51`** (line 49): current stack: 35.

Non-flag component: acceptance length. The Oct-12 runs served a different checkpoint
(Swift-1.5/RadixArk lineage) with accept 3.30; OrcaRouter measures 2.44–2.68 here and
~2.3 in the vendor's suite — a property of the uncensored weights on random-token prompts
(~20% fewer verified tokens/step). Part of the gap is therefore inherent to the checkpoint
we deliberately chose; the rest is flags.

## Evidence of current behavior (full-matrix run, stopped at 53/143 points)

Grid c = 1..20 × input 2048…458752, output 256, random-ids range 1.0, single resilient
driver, PL1 157 W (throttle window ended), health 200 throughout, zero errors.
Aggregate output tok/s (c1–c5; raw JSONs now in
`luni-llmops-linux/stacks/llm/bench/results/matrix-20261018-rc23/`):

| c \ input | 2048 | 8192 | 16384 | 32768 | 65536 | 131072 | 196608 | 262144 | 327680 | 393216 | 458752 |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 169 | 108 | 170 | 121 | 117 | 67 | 67 | 45 | 44 | 47 | 42 |
| 2 | 201 | 192 | 137 | 124 | 95 | 40 | 23 | 16 | 13 | 11 | 9.0 |
| 3 | 307 | 221 | 142 | 128 | 70 | 32 | 21 | 15 | 12 | 10 | 8.3 |
| 4 | 324 | 230 | 160 | 115 | 60 | 31 | 21 | 15 | 12 | 9.3 | 7.5 |
| 5 | 227 | 193 | 149 | 94 | 48 | 26 | 17 | 12 | 9.5 | — | — |

Reading notes: the 1M-token pool is NOT being outgrown at these points (4×196k ≈ 79% of
pool); the long cells are cold-prefill-bound because HiCache L2 is off, not eviction-bound.
Seed reuse across cells can warm later cells — treated as a documented caveat.

## Proposed single verification (pending operator decision)

Restore the five switches above in one start (nvme PLE, HiCache 64 GB + compressed hicache,
skip-lock true, FR-Spec head nvfp4, slots 51, adaptive NEXTN kept), then re-run exactly
c8/8192/1024/n16. Landing ≥ ~550 out tok/s closes the investigation as configuration
regression; a crash then reproduces at the right isolation point. Also record
`qsa_compressed_hicache` and `mamba_full_memory_ratio` from `/server_info` (upstream SGLang
cookbook warns the 0.9 default can silently cap concurrency on hybrid GDN models).
