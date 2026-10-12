# Pennyroyal serving recipe (Qwen3.8 Flash-Next / NVFP4 on one RTX PRO 6000)

Reproducible serving + benchmark recipe for running Qwen3.8 Flash-Next
(`RadixArk-Qwen3.8-Flash-Next-NVFP4`) on a single 96 GB Blackwell card with
SGLang, as operated on this workstation (2026-10-12). This page documents
**what we changed versus stock upstream defaults and why**, plus the test
protocol to verify those claims.

## Engine launch (c8 profile)

| Flag | Value | Upstream default | Why |
|---|---|---|---|
| `--mem-fraction-static` | 0.978 | auto (~0.88) | measured ceiling for this stack: at 0.981 lazy Triton post-loads show only 0.24 GiB free (June OOM precursor); 0.978 keeps 3.14 GB free and the 0.65 GiB post-load margin |
| `--max-running-requests` | 8 | unlimited | ladder v2: aggregate throughput plateaus c8–c12, −29 % regression past the cap, per-request 2–3× faster at c8; KV ≈ 142 k/session |
| `--max-queued-requests` | 16 | unlimited | crash root cause was an unbounded queue holding mamba slots; explicit cap converts floods into fast 503s |
| `--max-mamba-cache-size` | 35 | auto | exactly `running×4+3`; each surplus slot costs 58 MB of KV |
| `--cuda-graph-max-bs-decode` | 8 | 256-ish | graphs cost ~2.2 GB at bs16; sized to the actual cap |
| `--chunked-prefill-size` | 8192 | 8192 | kept |
| `--kv-cache-dtype` | fp8_e4m3 | auto | halved KV bytes vs bf16 at no measured speed cost; NVFP4 KV is unavailable on flashinfer (KV4 requires triton/flex/trtllm backends) |
| `--attention-backend` | flashinfer | auto | qualified vendor config (SM120 cutlass MoE) |
| hicache | host 32 GB + NIXL file storage | off | 490 k warm rehydrate in ~2.4 s vs ~35 s cold prefill; enables >window multi-turn sessions (observed: 1.05 M-token session, 99.99 % cache-hit) |
| adaptive spec (NEXTN) | on, policy `adaptive-next.json` | off | W8↔W4 width control; accept length rises with context (2.45→3.26), flat across concurrency |
| `--forward-unknown-tools` | true | false | tool-name passthrough for agent harnesses |

Overflow contract: engine rejects beyond `running+queued` with
**503 "The request queue is full."** (not 429 — a fallback router keying on
429 alone will never fire). Gateway gate `max_parallel_requests: 8` mirrors
the engine cap; overload routes to fallbacks instantly (`num_retries: 0`).

## Benchmark protocol

`benchmark/run_pennyroyal_recipe.sh` — tiers chosen to mirror public
model-card eval shapes and advertised context claims:

| tier | in/out | represents |
|---|---|---|
| tiny | 512/256 | zero-shot completions |
| eval | 2048/512 | MMLU-Pro-style few-shot |
| agent | 8192/1024 | tool-loop sessions |
| rago | 32768/1024 | RAG-over-docs |
| card128 | 129024/1024 | long-context evals |
| card400 | 400384/1024 | the 400 k model-card operating point |

Rules: `sglang.benchmark.serving` with `--random-range-ratio 1.0`
(exact sizes), num-prompts ≥ 2·concurrency (saturation), every tier twice,
medians reported, shared-endpoint contamination noted, NRestarts checked
after every case. Tables via `benchmark/summarize_ladder.py`.

## Measured (this card, c8 @ 0.978, 2026-10-12)

| metric | value |
|---|---|
| KV pool | 1 138 112 tokens |
| post-init free VRAM | 3.14 GB (lazy-kernel low-water 0.65 GiB) |
| tiny 512/256 @c8 | 506 out tok/s, ITL 8.5 ms, TTFT 490 ms |
| eval 2048/512 @c8 | 562 out tok/s, ITL 8.5 ms, TTFT 586 ms |
| agent 8192/1024 @c8 | 603 out tok/s, ITL 8.5 ms, TTFT 623 ms |
| rago 32768/1024 @c8 | 635 out tok/s, ITL 8.5 ms, TTFT p90 2.5 s |
| card128 @c8 | 435 out tok/s, ITL 8.8 ms, TTFT p90 6.6 s |
| card400 @c4 | 172 out tok/s, ITL 3.8 ms, TTFT p90 25 s (pre-bound) |
| single-stream c1 | 226–311 out tok/s depending on tier |
| 2×490 k parallel | both complete, pool 0.91, no retraction, NRestarts 0 |
| 490 k warm rehydrate | TTFT 2.4 s (cold: ~19–35 s) |
| overflow @ c32 | clean 503s at queue cap, zero errors among admitted, engine stable |
| multi-turn grow (2 sessions) | at 163 k tokens/session: 99.8 % cache-hit via HiCache, device pool only 0.14 used (prefix lives in host tier); TTFT grows ~11→19 s as rehydrate-bound |

## Deviations from upstream defaults that matter for reproduction

1. `mem-fraction-static 0.978` is card-/stack-specific; re-measure
   `available_gpu_mem` and lazy-kernel warnings on other hardware.
2. `max_queued_requests` must be set explicitly — the upstream default is
   unbounded and was the 14:00 OOM flood hole.
3. Mamba slot sizing follows `running×4+3` (hybrid GDN models only).
4. Overflow is signalled as 503 + text body, not 429; routers must match both.
5. HiCache storage roots are namespaced by KV dtype — never share cache
   roots across different `--kv-cache-dtype` values.
