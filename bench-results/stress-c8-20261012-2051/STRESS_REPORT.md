# Pennyroyal stress test — c8 profile @ mem_fraction 0.978

**Date:** 2026-10-12 20:51–21:24 CEST (runner wall time 32 min 10 s)
**Dir:** `bench-results/stress-c8-20261012-2051/`
**Repo/branch:** `sglang-rtxpro6000` @ `46e1d50e2`, branch `tom-eval-pennyroyal-3.0-merged-directports-john-experimental` (no commits/pushes)

## Config under test (live, verified at start via /health + unit state)

| item | value |
|---|---|
| mem_fraction_static | 0.978 (post-init free VRAM 3.14 GB; nvidia-smi 97,015/97,887 MiB) |
| max_running_requests | 8 |
| max_queued_requests | 16 |
| max_mamba_cache_size | 35 device slots (host tier: 68) |
| cuda_graph_max_bs_decode | 8 |
| chunked_prefill_size | 8192 |
| KV pool | 1,138,112 tokens, fp8_e4m3, context 524,288 |
| cache hierarchy | HiCache + NIXL storage (32 GB host tier) |
| unit | `pennyroyal.service`, **NRestarts = 0 for the entire test window** |

34 benchmark cases run strictly sequentially (`run_stress.sh`, `RUN.log`: 34× DONE, 0× FAIL, ALL_DONE).
Per-case safety gate (NRestarts + journal grep `CUDA out of memory|OutOfMemory|SIGQUIT`): never tripped;
full-window journal grep returns **0** hits. No retraction lines anywhere (`grep -ci retract` = 0 over the
whole window). Engine healthy at end. Short-tier numbers slightly contaminated by concurrent live agent
sessions on the same endpoint (expected, documented in META.txt).

## Operating-envelope ladder (N = max(2C,12))

Full tables in `TABLES.txt` (summarize_ladder.py: out, perreq, ttft, itl, accept, tokens). Excerpt —
aggregate output tok/s / mean TTFT ms / median ITL ms:

| tier | c1 | c2 | c4 | c6 | c8 |
|---|---|---|---|---|---|
| short 256:256 | 255 / 135 / 2.5 | 309 / 267 / 3.5 | 455 / 186 / 4.8 | 457 / 220 / 7.5 | 563 / 225 / 8.3 |
| medium 1024:256 | 251 / 171 / 2.5 | 369 / 146 / 3.3 | 485 / 162 / 4.7 | 482 / 232 / 7.4 | 550 / 310 / 8.4 |
| long 8192:1024 | 312 / 196 / 2.4 | 418 / 161 / 3.4 | 564 / 201 / 4.8 | 571 / 218 / 7.5 | 637 / 347 / 8.6 |
| xlong 32768:1024 | 401 / 285 / 1.8 | 500 / 186 / 3.4 | 730 / 247 / 4.8 | 648 / 310 / 7.5 | **780** / 480 / 8.4 |

- ITL is flat ≤ 8.6 ms everywhere up to c8; per-request throughput 70–97 tok/s at c8 (spec accept length
  steady 3.19–3.36 draft tokens).
- xlong peak at c8 (780 out tok/s) — consistent with the 20:12 smoke (744); the c6 dip (648) is
  live-traffic contamination, same tier ordering as before.
- Bottleneck is **mamba device slots, not KV**: during xlong/soak at full load KV token usage peaks at
  only 0.24 while mamba usage peaks at 0.83 (≈29/35 slots). At xxlong, token usage reaches 0.62.

## OVERFLOW GUARD VERDICT: clean fast reject (HTTP 503), no hangs, no crash — with one design-critical caveat

### Phase B — paced overload (bench tool, C = 12/16/24/32, N = max(2C,16))

**Zero client-side errors on all 8 guard cases** (all N completed, no `#Error` lines, no tracebacks).
The bench tool's concurrency semaphore paces arrivals, so the 8+16 admission window never overflowed
instantaneously: journal shows `#queue-req` pinned at exactly **16** (= cap) at C=24/32, running pinned
at ≤ 8, and degradation manifested **purely as TTFT inflation**, not rejection:

| case | completed/N | mean TTFT | out tok/s | journal peaks |
|---|---|---|---|---|
| long c12 (N24) | 24/24 | 5.7 s | 566 | running≤8 queue≤8 |
| long c16 (N32) | 32/32 | 10.8 s | 584 | running≤8 queue≤13 |
| long c24 (N48) | 48/48 | 19.8 s | 605 | running≤8 **queue≤16** |
| long c32 (N64) | 64/64 | 5.6 s* | 1511* | running≤8 **queue≤16** |
| xlong c12 (N24) | 24/24 | 6.9 s | 511 | running≤8 queue≤5 |
| xlong c16 (N32) | 32/32 | 14.5 s | 459 | running≤8 queue≤9 |
| xlong c24 (N48) | 48/48 | **30.8 s** | 413 | running≤8 **queue≤16** |
| xlong c32 (N64) | 64/64 | 7.2 s* | 1168* | running≤8 **queue≤16** |

\* c32 ran after c24 with the identical random prompts → HiCache/NIXL host-tier hits
(journal: `input_len=8192, cached_input_len=8128`) inflate aggregate throughput and shrink TTFT;
not a capacity jump. Real cost of overload is the queue-saturated rows (c24: TTFT 20–31 s, throughput held
or gently regressed — no collapse).

### The true reject path (un-paced 64-request simultaneous burst probe)

Because the ladder never forced a rejection, one extra probe was run: 64 concurrent `POST /generate`
(~300-token prompt, 8 new tokens) fired simultaneously, no pacing — log: `overflow_burst_probe.log`.

- Result in **0.7 s**: **17× HTTP 200 accepted** (≈ running 8 + queue 16, admitted mid-transition),
  **47× HTTP 503 rejected with median reject latency 0.14 s**.
- Exact rejection body (verbatim):
  `{"object":"error","message":"The request queue is full.","type":"503","param":null,"code":503}`
- Engine journal, same second (21:24:26): 47× `INFO: 127.0.0.1:332xx - "POST /generate HTTP/1.1" 503 Service Unavailable`
  (excerpt in `journal-overflow_burst_probe.log`). Accepted requests completed in 0.29–0.73 s.
- Post-probe: NRestarts still 0, no OOM/SIGQUIT/retract lines, /health OK.

**Verdict: graceful degradation holds.** Overflow beyond 8 running + 16 queued is a **clean, stateless,
sub-200 ms fast reject**; sustained overload is queueing + latency, never a hang, never a crash.
**Caveat for the gateway: the reject code is 503, NOT 429.** A LiteLLM fallback rule keyed only on 429
will never fire — it must match 503 (message "The request queue is full.") in addition to 429.

## Memory observations (0.978 is the ceiling — margin was hit, without failure)

- **2× Triton lazy device-load warnings at 0.32 GiB free** — new low, below the previously seen 0.65 GiB:
  - `20:51:54 Triton kernel '_sparse_gqa_prefill' device-loaded after serving started (free device mem: 0.32 GiB). Pre-load it during engine init to avoid CUDA OOM.`
  - `20:53:42 Triton kernel 'alloc_extend_kernel' device-loaded after serving started (free device mem: 0.32 GiB). ...`
  Both loaded successfully (early short-tier cases); nothing OOM'd afterwards in 32 min of maximal load.
  This is the only systemic risk of the profile: any further lazy allocation could fail. Recommend
  pre-loading these kernels at init (the log line itself suggests it) or accepting the risk.
- **0 retraction lines** in the whole window (journal-wide `grep -ci retract` = 0).
- Host-tier pressure handled cleanly: 109× `mamba host reclaim kind=leaf` during the soak (host mamba pool
  `used=68 total=68`, leaf eviction working), 43× `HiCache prefetch success` — the NIXL storage tier does
  real work, which is also why guard reruns are cache-warm.
- No CUDA OOM, no OutOfMemory, no SIGQUIT anywhere; unit NRestarts = 0 from before start to after end.

## Sustained soak — xlong C=8, 48 prompts (6 waves)

48/48 completed in 79.9 s (≈13.3 s/wave, steady), 615 out tok/s, mean TTFT 1.0 s, median ITL 8.5 ms,
accept length 3.36. Journal during soak: running ≤ 8, queue ≤ 3, token usage ≤ 0.24, mamba usage ≤ 0.83,
reclaims only at host tier. No drift, no retraction, no kernel warnings in this phase. **Endurance: pass.**

## Burst probe (long C=16 ×2, interactive check between)

- burst a: 32/32 done, 564 out tok/s, TTFT 11.5 s; burst b: 32/32, 599 out tok/s, TTFT 10.9 s.
- c1 interactive check (256:256) run *between* the bursts: **TTFT 131 ms, ITL 1.8 ms, 329 tok/s** —
  full single-request interactive quality immediately after a 32-request burst drained.
- Harness caveat: the runner is strictly sequential, so the probe measures immediate post-burst recovery,
  not in-flight starvation; in-flight behavior is visible in the c16 rows (ITL stays 8.6 ms, so decode
  latency of running requests is not starved; only fresh admits wait in queue).

## xxlong reality check — 100,352 in / 512 out

- c6 (N=6): 6/6 completed, TTFT mean 13.1 s (six simultaneous 100k prefills serialized through 8k chunks
  — expected prefill-dominated latency), ITL 7.6 ms, token usage peak 0.53.
- c8 (N=8): 8/8 completed, TTFT mean 5.4 s (same prompts warm in host cache), ITL 8.0 ms, running peak 7,
  token usage peak 0.62 — no pool failure, no retraction.
- The pool holds ~11 concurrent 100k sessions; at 8 running it survives as predicted. **Pass** —
  slow-but-correct; do not route 100k contexts through an interactive lane.

## Bottom line — gateway gate fit

**Fit for `max_parallel_requests = 8` with overload-fallback routing: YES**, with one amendment:

1. Fallback must trigger on **503 "The request queue is full."** (that is what SGLang emits), plus 429 for
   LiteLLM's own queueing. A 429-only rule is dead code against this engine.
2. At gate=8 the engine never queues for benchmark traffic (queue ≤ 3 observed at c8 incl. soak); the
   16-slot queue is exactly the headroom for bursts between gateway and engine, absorbing up to ~24
   overlapping requests before any reject.
3. Interactive quality inside the envelope is uniform: ITL ≤ 8.6 ms across all tiers at c8, TTFT ≤ 0.5 s
   up to xlong, 70–97 tok/s per request. xlong is the tier where c8 also *peaks* throughput (780 tok/s).
4. Residual risks: (a) lazy Triton loads at 0.32 GiB free — mitigate by kernel pre-loading; (b) KV pool
   is not the constraint, mamba slots are — raising running requests further without slots would regress
   decode latency, not capacity; (c) short-tier absolute numbers contaminated by shared live traffic.

**Artifacts:** `RUN.log` (34× DONE + probe window), `META.txt`, `run_stress.sh`, `TABLES.txt`,
`qwen_*.json|.log` (34 cases), `journal-qwen_*.log` (per-case journal snapshots),
`journal-overflow_burst_probe.log`, `overflow_burst_probe.log`, `pre-test-snapshot.txt`, `runner-stdout.log`.
