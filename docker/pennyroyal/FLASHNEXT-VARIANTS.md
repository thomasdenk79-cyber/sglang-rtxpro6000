# Flash-Next variants

Three independent branches share the BF16-PLE Flash-Next profile. Each variant
uses its own `docker/pennyroyal/launch/config/start-flash-next-frspec.sh`,
which selects the matching image tag.

| Variant | Branch | Purpose | Variant implementation commit |
|---|---|---|---|
| BF16 | `flashnext/bf16` | Shared baseline | `889268c66` |
| QSA | `flashnext/qsa` | Mamba checkpoint-grid prefill alignment | `afb6e9d0a14d449e2b0e8075a0f6b92595cd0822` |
| SM120 | `flashnext/sm120` | Optional fused FP8 KV writer | `78a05b2113ebaea3bb7f971f59c42a6d27df2820` |

## Patch matrix

| Change | BF16 | QSA | SM120 | Notes |
|---|---|---|---|---|
| Pennyroyal #79, including HiCache fence | Included | Inherited | Inherited | Targeted port on the common base |
| Pennyroyal #86, automatic KV sizing | Included | Inherited | Inherited | No explicit `--max-total-tokens` |
| Pennyroyal #76 FP8-PLE transplant tooling | Included, unused by profile | Inherited | Inherited | The selected profile uses the original BF16 PLE table |
| SGLang #41173, QSA metadata fusion | Deferred | Deferred | Deferred | Patch was not a safe fit for this fork's metadata path; GPU graph verification is unavailable |
| SGLang #41175, NEXTN draft/verify fusion | Deferred | Deferred | Deferred | API drift prevents a clean port; GPU correctness verification is unavailable |
| SGLang #43135, Mamba chunk alignment | Not included | Adapted | Not included | Aligns chunked-prefill cuts to the Mamba checkpoint grid |
| Pennyroyal #35, fused FP8 KV writer | Not included | Not included | Included, off by default | Enable only with `SGLANG_KV_FP8_FUSED_STORE=1`; CUDA parity and graph tests remain unverified |
| AIUEO52 DG1 draft-MoE GEMV | Already present | Inherited | Inherited | Present in shared source history; not duplicated |
| AIUEO52 DT1 draft-tail patch | Deferred | Deferred | Deferred | Speculative API mismatch |
| Cache-aware session residency/hysteresis | Not added | Not added | Not added | Existing HiCache supports async prefetch; no new scheduler policy was introduced |

## Shared runtime profile

All variants use TP=1, ModelOpt NVFP4 weights, FP8 E4M3 KV, 524,288 context
through the qualified YaRN `factor 2.0` override over the checkpoint's native
262,144 positions, an eight-request ceiling, chunked prefill of 8192 tokens
with a prefill-decode interval of 8, and the existing FR-Spec,
adaptive NEXTN, and CUDA Graph policies. KV and Mamba capacities stay automatic.
The selected local checkpoint is the Swift NVFP4 model with its original
approximately 100-GB BF16 PLE table, streamed from NVMe. HiCache is 32 GiB;
NIXL L3 uses `page_first`, `kernel`, and `write_through`. PLE NVMe and NIXL
remain separate storage paths.

Hugging Face metadata for the local model files and the model API confirm that
`ukisai/Swift-1.5-Qwen3.8-Flash-Next-NVFP4` is at revision
`3ff0520224f264a2d0ac4ab56ece8f2f13aadb38`, which is also the current Hub
head. The prepared PLE stream manifest binds its source config and tensor index
by SHA-256 and records a 102,400,491,520-byte BF16 table; its declared table
digest, `f90a8563ba5939e5c0b0f6a57bd3a5f94c39126932f4f10eae98c3585e81434d`,
matches the file. Carry both the Hub revision and PLE digest into image labels.
Do not substitute the FP8-PLE transplant.

## Image builds and launch

The Dockerfile accepts OCI build metadata as arguments. Build from the matching
branch and repository root, passing the exact branch `SOURCE_REVISION`, a UTC
`BUILD_TIMESTAMP`, and verified values for `PENNYROYAL_BASE`,
`SGLANG_UPSTREAM_REFERENCE`, `INTEGRATED_PATCHES`, and `CHECKPOINT_REVISION`.
The checkpoint argument must not be guessed. Example shape:

```bash
CHECKPOINT_REVISION='ukisai/Swift-1.5-Qwen3.8-Flash-Next-NVFP4@3ff0520224f264a2d0ac4ab56ece8f2f13aadb38'
SOURCE_REVISION="$(git rev-parse HEAD)"
BUILD_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
podman build -f docker/pennyroyal/Dockerfile -t flashnext:bf16 \
  --build-arg SOURCE_REVISION="$SOURCE_REVISION" \
  --build-arg SOURCE_REPOSITORY=https://github.com/thomasdenk79-cyber/sglang-rtxpro6000.git \
  --build-arg PENNYROYAL_BASE=pennyroyal-v3.0.2@6b501b800181756890561fe3107c2ed551c1d302 \
  --build-arg SGLANG_UPSTREAM_REFERENCE=v0.5.22@baa9befa381511cd4d56f83980951e5a45fffc6d \
  --build-arg INTEGRATED_PATCHES="Pennyroyal #79,#86; profile; PR #76 tooling" \
  --build-arg CHECKPOINT_REVISION="$CHECKPOINT_REVISION" \
  --build-arg PLE_TABLE_SHA256=f90a8563ba5939e5c0b0f6a57bd3a5f94c39126932f4f10eae98c3585e81434d \
  --build-arg BUILD_TIMESTAMP="$BUILD_TIMESTAMP" \
  --build-arg FLASHNEXT_VARIANT=bf16 .
```

For the other tags, build on their branches with `flashnext:qsa` or
`flashnext:sm120`, and set the variant and integrated-patches arguments to
match the matrix. Existing launch profiles are under
`docker/pennyroyal/launch/config/`; they require the RTX PRO 6000 Blackwell and
verified CDI mapping for runtime validation. Do not benchmark or change the
production container.

## Technical test run 2026-10-21 (BF16, operator-authorized window)

The operator authorized a start-and-fix window on the Blackwell: stop
production, get the BF16 image running, run small smoke tests and small
benchmarks, then restore production from its declared profile. Nothing here runs
the reviewer benchmark set.

| Stage | Measured result | Source |
|---|---|---|
| Image build | `flashnext:bf16` = `5f8194628a76`, revision label `8e7739f9d28053347fbb33361f384b9542a7ba45` = branch tip, provenance guard passed | `logs/build-final-summary.txt`, `logs/build-bf16-20261021T071013Z.log` |
| QSA / SM120 builds | `DISK_ABORT` with 32 GiB free, no image written | `logs/build-final-summary.txt` |
| Capacity tests | 24 passed, 1 warning in 7.68 s | host pytest run of `test/registered/unit/pennyroyal/` |
| Test engine start | `Application startup complete`, Uvicorn on 8001, `/health` 200, restart 0, OOM false; `max_total_num_tokens=711680`, prefill 8192, requests 8, context 524288, 2.66 GB GPU left | container log of `logs/frspec-test.sh` |
| Smoke | health 200; model `pennyroyal`, `max_model_len` 524288; chat 128 completion tokens with a real answer; streaming 35 chunks; 4/4 parallel at concurrency 4, 64 tokens each, 7.8 s wall | `logs/frspec-smoke-20261021T080324Z.txt` |
| NIXL host-tier warm repeat | cold cached 0; warm cached 2944/2973 = 99.02 %, 5.48 s to 0.85 s; verdict PASS | `logs/frspec-nixl-warm-20261021T080543Z.txt` |
| Production restore | `/health` 200 and pod health `healthy`, restart 0, OOM false; `max_total_num_tokens=1100864`, prefill 4096, requests 10, context 262144, host KV pool 1,918,528 tokens / 25.54 GB; Blackwell 96,531 MiB of 97,887 MiB | `podman inspect`, container log, `nvidia-smi` at 08:14-08:16 UTC |
| Agent route | LiteLLM alias `pennyroyal` answers through `:4000` (failover `gpt-6-luna` intact) | `/v1/chat/completions`, 8 completion tokens |

Two findings to keep.

1. The NIXL probe reports an empty `text_out` on a PASS verdict. That is the
   probe, not the engine: the FR-Spec template defaults to
   `enable_thinking=true`, so a probe that parses only `message.content` and
   caps `max_tokens` sees everything land in `reasoning_content`. A
   production 8-token request reproduced it exactly (`content_len=0`,
   `reasoning_len=32`, `finish_reason=length`), while the smoke test's 128-token
   chat returned text. The probe asserts the cache hit, so its verdict stands;
   a future probe version should read `reasoning_content` as well.
2. The test wrapper's NIXL skip check looks at the wrong variable, so the smoke
   run skipped the warm stage while NIXL was demonstrably live in the same
   runtime log. The stage ran manually and passed. The runner scripts and reports
   live under `/srv/work/flashnext/logs/` (test-only NIXL directory
   `/srv/ai/nixl/flashnext-frspec-test`, production NIXL never mounted).
