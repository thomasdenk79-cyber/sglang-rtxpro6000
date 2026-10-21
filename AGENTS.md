# Flash-Next experiments

This file is the continuation point for the Qwen3.8 Flash-Next work. Read it
before changing this worktree; verify the live Git state and GPU again.

## Current status

- The shared FR-Spec profile runs the qualified 524,288 context through the
  YaRN `factor 2.0` override, with an eight-request ceiling, automatic
  Mamba/KV sizing, and PLE on NVMe.
- Active worktree: `/srv/work/flashnext/worktrees/qsa`, branch
  `flashnext/qsa`, based on the finalized BF16 profile and handover commit
  `e6ffa5994`.
- This branch includes a manual port of SGLang PR #43135: chunked
  prefill cuts align to the Mamba checkpoint grid when extra-buffer caching is
  enabled. Focused CPU tests pass (8/8); syntax and diff checks pass.
- Upstream PRs #41173 and #41175 were reviewed but are not ported: neither
  patch applies cleanly to this Pennyroyal QSA/NEXTN implementation, and their
  graph-replay changes need a branch-specific port and GPU correctness checks.
- The launch profile is named `flashnext:qsa`. No image build, model start,
  inference, benchmark, or production change has occurred. The visible GPU is
  an RTX 3500 Ada, not the target RTX PRO 6000 Blackwell.
- Shared OCI metadata labels and the patch matrix are in
  `docker/pennyroyal/FLASHNEXT-VARIANTS.md`; the local NVFP4 model revision and
  BF16 PLE table digest have been verified there.

## Repository and branches

- No new Git repository was created. The source repository is the existing
  Pennyroyal/SGLang clone at `/srv/work/flashnext/pennyroyal`.
- The active Git worktree is `/srv/work/flashnext/worktrees/bf16`,
  branch `flashnext/bf16`. The naming update is commit
  `ff702d2cd2edc42da09b76ee778fd37678b085cf`, based on
  `ecf63dc72e24df52bb2dd522ab2b9baf2e1cf936`; later work is recorded in the
  current-status section above.
- Worktree Git metadata lives in
  `/srv/work/flashnext/pennyroyal/.git/worktrees/bf16`.
- Upstream remote `origin` is `jpezzulli/sglang-rtxpro6000`. The user-owned
  public fork is `thomasdenk79-cyber/sglang-rtxpro6000`; its
  `flashnext/bf16` ref contains this experiment. Push experiment commits
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

The operator clarified: use the latest NVFP4 main checkpoint together with
its original BF16 PLE table, roughly 100 GB; do not use the FP8-PLE transplant
as the common profile.

The prepared local target is
`/srv/ai/models/Swift-1.5-Qwen3.8-Flash-Next-BF16PLE`. Hub metadata and API
identify `ukisai/Swift-1.5-Qwen3.8-Flash-Next-NVFP4` revision
`3ff0520224f264a2d0ac4ab56ece8f2f13aadb38` as the current model snapshot. The
PLE stream manifest binds its source config/index hashes; its 102,400,491,520
byte BF16 table matches SHA-256
`f90a8563ba5939e5c0b0f6a57bd3a5f94c39126932f4f10eae98c3585e81434d`.

Tokenizer evidence from local artifacts:

- Swift BF16-PLE and RadixArk FP8-PLE tokenizers have exactly equal
  248044-entry vocab-to-ID maps, all 33 added-token records, and all 247587
  normalized BPE merge pairs.
- Serialized tokenizer hashes differ: Swift is
  `06b9509352d2af50381ab2247e083b80d32d5c0aba91c272ca9ff729b6a0e523`;
  the FR-Spec map manifest expects RadixArk
  `0997f410c57a1f4e53b09e4be8f4a172d90edd9564368fb0847030937229b9f3`.
- The tokenizer pre-tokenizer regex and byte-level offset/decoder metadata
  differ. The launchers retain an exact SHA allowlist for the reference and
  Swift files; 5,008 deterministic edge/random strings produced identical
  token IDs with `tokenizers==0.22.2` and Transformers 5.12.1. Do not broaden
  the allowlist without repeating compatibility checks.

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

## Implemented shared runtime profile

The native and prebuilt-container Flash-Next FR-Spec launch paths now use the
same settings and keep their argv/NIXL identity in sync:

- TP=1; ModelOpt NVFP4 weights; FP8 E4M3 KV.
- Selected Swift NVFP4 + original BF16 PLE checkpoint; NVMe PLE offload.
- Native context 262144 with no YaRN override.
- 32 GB HiCache; L2 enabled; NIXL + NVMe L3 enabled, `page_first`,
  `kernel`, `write_through`.
- Maximum 8 requests (a ceiling, not a target batch); preserve FR-Spec,
  adaptive NEXTN MTP policy, CUDA graph tiers, and SM120 kernels.
- Do not pass `--max-total-tokens` or `--max-mamba-cache-size` by default;
  both remain operator overrides, and the engine sizes the pools automatically.
- Keep PLE-on-NVMe and HiCache/NIXL-L3 as distinct storage configurations.
- Do not change model weights or KV dtype; no YaRN or experimental NVFP4-KV.
- Do not add experimental scheduler behavior to `bf16`.

The plain non-FR-Spec Flash-Next recipes intentionally retain their earlier
4-request/24-slot and 524,288-context behavior. The FR-Spec helper defaults to
8 requests and automatic Mamba sizing; explicit request counts above eight
are rejected. `server_args.py` defaults `max_mamba_cache_size` to `None`,
`kv_cache_configurator.py` computes it from the memory budget, and the PR #86
port supplies automatic KV sizing. Related launchers, container mounts,
examples, tests, and documentation have been updated together:

- `configs/pennyroyal/serve-flash-next-frspec.sh`
- `docker/pennyroyal/launch/config/start-flash-next-frspec.sh`
- `configs/pennyroyal/request-capacity.sh`
- `docker/pennyroyal/launch/run.sh` (`--checkpoint-root` and `--ple-root`
  same-path read-only mounts)
- compose/env examples and focused tests under
  `test/registered/unit/pennyroyal/`.

Do not edit or restart the production Pennyroyal container as part of this
experiment.

## Remaining work

1. Build `flashnext:bf16`, `flashnext:qsa`, and `flashnext:sm120` using the
  arguments documented in `docker/pennyroyal/FLASHNEXT-VARIANTS.md`; inspect
  the resulting OCI labels.
2. CUDA graph tests for deferred #41173/#41175 ports require a suitable CUDA
  host; do not port them speculatively.
3. Do not run benchmarks. GPU start, readiness, and inference checks remain
  blocked until the RTX PRO 6000 Blackwell is visible and its CDI mapping is
  verified.

## Live state

- `nvidia-smi` lists only the RTX 3500 Ada; the RTX PRO 6000 Blackwell remains
  absent. `pennyroyal.service` is inactive. No model start, restart, inference,
  or benchmark was run.
- This QSA branch and the shared metadata/matrix commit are pushed to the user
  fork. The prompt branch remains
  `e6fb2fa29340bcd3ab7310599e0ab6a67171863f`.
- The LiteLLM and observability containers are separate from this source
  change; do not alter them as part of the experiment.
