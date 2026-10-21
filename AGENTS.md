# Flash-Next experiments

This file is the continuation point for the Qwen3.8 Flash-Next work. Read it
before changing this worktree; verify the live Git state and GPU again.

## Repository and branches

- No new Git repository was created. The source repository is the existing
  Pennyroyal/SGLang clone at `/srv/work/flashnext/pennyroyal`.
- The active Git worktree is `/srv/work/flashnext/worktrees/bf16`,
  branch `flashnext/bf16`. This handover's rename work started from
  `ecf63dc72e24df52bb2dd522ab2b9baf2e1cf936`.
- Worktree Git metadata lives in
  `/srv/work/flashnext/pennyroyal/.git/worktrees/bf16`.
- Upstream remote `origin` is `jpezzulli/sglang-rtxpro6000`. The user-owned
  public fork is `thomasdenk79-cyber/sglang-rtxpro6000`; its
  `flashnext/bf16` ref will contain this experiment. Push experiment commits
  to that fork, never to Pennyroyal upstream.
- The requested experiment prompt is saved in
  `/srv/luni/luni-llmops-linux`, branch `exp/pennyroyal-tuning`, at
  `e6fb2fa29340bcd3ab7310599e0ab6a67171863f`:
  `stacks/llm/orcarouter-pennyroyal/docs/EXPERIMENT-PROMPT.md`.
- The project repository was not extracted from the monorepo; the source
  worktree is a separate checkout used for the three SGLang variants.
- Short names are intentional: `flashnext/bf16` is the common base,
  `flashnext/qsa` covers upstream QSA/NEXTN work, and `flashnext/sm120`
  covers SM120 kernel experiments. Container tags use the same suffixes:
  `flashnext:bf16`, `flashnext:qsa`, and `flashnext:sm120`.

## Selected checkpoint direction

The operator clarified on 2026-10-21: use the fastest/current NVFP4 main
checkpoint together with its original BF16 PLE table, roughly 100 GB; do not
use the FP8-PLE transplant as the common profile.

The prepared local target is
`/srv/ai/models/Swift-1.5-Qwen3.8-Flash-Next-BF16PLE`. Its config reports
ModelOpt quantization, native 262144 positions, default BF16 PLE dtype, and
`ple_layer_ids=[2]`; its index contains 137 PLE tensors. Files occupy about
173.66 GiB (directory total from `du` about 150G). Treat this prepared
checkpoint as the intended target, but do not claim its complete Hub source
revision until the file-level provenance is verified.

Tokenizer evidence from local artifacts:

- Swift BF16-PLE and RadixArk FP8-PLE tokenizers have exactly equal
  248044-entry vocab-to-ID maps, all 33 added-token records, and all 247587
  normalized BPE merge pairs.
- Serialized tokenizer hashes differ: Swift is
  `06b9509352d2af50381ab2247e083b80d32d5c0aba91c272ca9ff729b6a0e523`;
  the FR-Spec map manifest expects RadixArk
  `0997f410c57a1f4e53b09e4be8f4a172d90edd9564368fb0847030937229b9f3`.
- The tokenizer pre-tokenizer regex and byte-level offset/decoder metadata
  also differ. Do not simply remove the launcher's SHA guard. Verify the exact
  FR-Spec map semantics and add a focused compatibility test before accepting
  the Swift tokenizer hash.

The FP8-PLE transplant utility and identity verifier from PR #76 were added in
commit `7b385d564`, but must not be used to replace the selected BF16-PLE
profile. No model files were modified by prior work.

## Source pins and existing commits

- Pennyroyal baseline: `pennyroyal-v3.0.2`,
  `6b501b800181756890561fe3107c2ed551c1d302`.
- SGLang comparison: tag `v0.5.22`,
  `baa9befa381511cd4d56f83980951e5a45fffc6d`; current upstream `main` was
  separately fetched at `c1c287a42928495166e14dbcef31b9e1f1dac199`.
- `flashnext/bf16` currently has:
  - `b9652e5e4`: targeted Pennyroyal PR #79 correctness/HiCache-fence port.
  - `99a354f1d`: PR #86 automatic FR-Spec KV sizing.
  - `7b385d564`: PR #76 FP8-PLE transplant/verifier tooling (keep the tooling,
    not that profile, unless later requested).
- Prior focused tests: PR #79 fence tests 2/2; PR #86 capacity tests 4/4;
  transplant tests 57 passed/6 skipped; identity tests 18 passed. Tests used
  an isolated container because host/runtime pytest was unavailable. A
  transplant dry-run validated inputs but did not write checkpoint files.

## Required shared runtime profile to implement

Update the native and prebuilt-container Flash-Next FR-Spec launch paths
together and keep their argv/NIXL identity in sync:

- TP=1; ModelOpt NVFP4 weights; FP8 E4M3 KV.
- Selected Swift NVFP4 + original BF16 PLE checkpoint; NVMe PLE offload.
- Native context 262144 with no YaRN override.
- 32 GB HiCache; L2 enabled; NIXL + NVMe L3 enabled, `page_first`,
  `kernel`, `write_through`.
- Maximum 8 requests; preserve current FR-Spec and adaptive NEXTN MTP policy,
  CUDA graph tiers, and SM120 kernels.
- Do not pass `--max-total-tokens` or `--max-mamba-cache-size`; verify both
  automatic sizing paths and log the effective Mamba capacity from runtime
  startup output.
- Keep PLE-on-NVMe and HiCache/NIXL-L3 as distinct storage configurations.
- Do not change model weights or KV dtype; no YaRN or experimental NVFP4-KV.
- Do not add experimental scheduler behavior to `bf16`.

At handover the recipes still use 524288 context, YaRN overrides, 4 requests,
and an explicit Mamba cache size of 24. `server_args.py` defaults
`max_mamba_cache_size` to `None`; `kv_cache_configurator.py` computes it from
the memory budget. Existing automatic KV sizing is provided by the PR #86
port. The recipe/test files that must be kept consistent include:

- `configs/pennyroyal/serve-flash-next-frspec.sh`
- `docker/pennyroyal/launch/config/start-flash-next-frspec.sh`
- `configs/pennyroyal/request-capacity.sh`
- compose/env examples and focused tests under
  `test/registered/unit/pennyroyal/`.

Do not edit or restart the production Pennyroyal container as part of this
experiment.

## Remaining work

1. Verify the prepared checkpoint's full provenance and FR-Spec tokenizer
   compatibility; preserve the exact tokenizer evidence above.
2. Implement the shared profile in `flashnext/bf16`; update targeted tests and
   build/start documentation, then commit and push to the user-owned fork.
3. Create `flashnext/qsa` and `flashnext/sm120` independently from
   the finalized base commit. Selectively review SGLang PRs #41173, #41175,
   and #43135 for variant 1; PR #35 and relevant AIUEO52 changes for variant 2.
   Record accepted/equivalent/incompatible/omitted changes and rationale.
4. Prepare reproducible Podman build profiles and OCI source labels; use the
   existing generic lifecycle tooling rather than a new manager.
5. Do not run benchmarks. GPU start, readiness, and inference checks are
   blocked until the RTX PRO 6000 Blackwell is visible and its CDI mapping is
   verified.

## Live state at handover

- `nvidia-smi` lists only the RTX 3500 Ada; the RTX PRO 6000 Blackwell remains
  absent. `pennyroyal.service` is inactive. No model start, restart, inference,
  or benchmark was run.
- The worktree was clean at `ecf63dc72` before the naming update; the prompt branch was clean at
  `e6fb2fa29340bcd3ab7310599e0ab6a67171863f`.
- The LiteLLM and observability containers are separate from this source
  change; do not alter them as part of the experiment.
