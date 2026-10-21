# Flash-Next experiments

This file is the continuation point for the Qwen3.8 Flash-Next work. Read it
before changing this worktree; verify the live Git state and GPU again.

## Current status

- Active worktree: `/srv/work/flashnext/worktrees/bf16`, branch
  `flashnext/bf16`; profile and OCI metadata are pushed to the user fork.
- The shared FR-Spec profile is implemented:
  native 262,144 context, eight-request ceiling, automatic Mamba/KV sizing,
  NVMe BF16 PLE, and aligned native/container launchers.
- `flashnext/qsa` and `flashnext/sm120` now exist as independent branches,
  both based on this profile. Their implementation and test status is recorded
  in `docker/pennyroyal/FLASHNEXT-VARIANTS.md`.
- CPU suite in the built `flashnext:bf16` image, reader plugin on
  `PYTHONPATH`: 172 passed, 3 failed. `test_source_guard_matches_every_hooked_
  publication_module` passes: commit `1d3b74e78` re-audited the manifest with
  `tools/ple_nvme/refresh-source-guard.py`, and the earlier "unmodified QSA
  module" diagnosis was wrong, the PR #79 port had changed three guarded
  modules. The same audit cured two `test_prepare_ple_nvme` preflight failures
  that read the source string. Of the three remaining failures,
  `test_recipes_source_and_run_the_tp_guard` is a real defect: it asserts
  `device_ids: ["0", "1"]` inside `docker/pennyroyal/README.md`, which carries
  no such text. `test_the_image_check_refuses_an_unpackaged_flashinfer` and
  `test_launcher_refuses_missing_or_unreadable_inputs` are image-context
  dependent checks, not diagnosed in this pass. Shell syntax and
  `git diff --check` pass.
- QSA's Mamba alignment port passed 8 focused CPU tests; Python compilation,
  shell syntax, and diff checks passed. SM120's fused-writer tests passed
  (55 passed, 29 CUDA-only skipped); GPU byte-parity and graph-replay checks
  remain unverified.
- Image builds: `flashnext:bf16` is built from the pushed branch head with the
  documented OCI arguments (`6582043efe9b`, revision label
  `b9e3370def8392680ef15e137d054eb375c9fcd0`, `created` populated, 16 GiB). QSA
  and SM120 builds follow on their re-audited heads. No model start, inference,
  benchmark, or production change has been performed. Both GPUs are visible in
  NVML (Blackwell at PCI `4b:00.0`, driver 615.78.08); the CDI
  `~/.config/cdi/nvidia.com-gpu-blackwell.json` exposes only the Blackwell, and
  `podman run --device nvidia.com/gpu=1 ... nvidia-smi -L` confirms it.
  Checkpoint revision and PLE table digest are verified and documented.

## Repository and branches

- No new Git repository was created. The source repository is the existing
  Pennyroyal/SGLang clone at `/srv/work/flashnext/pennyroyal`.
- The active Git worktree is `/srv/work/flashnext/worktrees/bf16`,
  branch `flashnext/bf16`. The naming update is commit
  `ff702d2cd2edc42da09b76ee778fd37678b085cf`, based on
  `ecf63dc72e24df52bb2dd522ab2b9baf2e1cf936`; later work is recorded in the
  current-status section above.
- Current variant branches, each pushed to the user fork and verified with
  `git cat-file -t` after the previous two SHAs were found to be transcribed
  rather than copied: `flashnext/bf16` at
  `1d3b74e78069ae3ea78f98573025a0dcd24f452e`, `flashnext/qsa` at
  `3407d5d84be123823106982541d7dbe4dcc0b549`, and `flashnext/sm120` at
  `403f1da19d5d7247678f2dcda401ae78b447f88c`. The last commit on each branch is
  the source-guard audit; the base profile/metadata implementation is
  `760b2d6198e2104f8d7d6e7ee1d6448d1d253325`.
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
`/srv/ai/models/Swift-1.5-Qwen3.8-Flash-Next-BF16PLE`. Its config reports
ModelOpt quantization, native 262144 positions, default BF16 PLE dtype, and
`ple_layer_ids=[2]`; its index contains 137 PLE tensors. Files occupy about
173.66 GiB (directory total from `du` about 150G). Treat this prepared
checkpoint as the intended target. Hugging Face cache metadata and the model
API identify `ukisai/Swift-1.5-Qwen3.8-Flash-Next-NVFP4` at current revision
`3ff0520224f264a2d0ac4ab56ece8f2f13aadb38`. The local BF16 PLE stream is
102,400,491,520 bytes; its measured SHA-256 matches the manifest:
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
4-request/24-slot and 524,288-context defaults. The eight-request ceiling lives
in the shared `configs/pennyroyal/request-capacity.sh`, which the plain recipes
also source, so an override such as `MAX_RUNNING_REQUESTS=16` that was legal in
v3.0.2 now exits with an error on every Flash-Next recipe, not only on FR-Spec.
The FR-Spec helper defaults to 8 requests and automatic Mamba sizing. `server_args.py` defaults `max_mamba_cache_size` to `None`,
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

1. Build `flashnext:qsa` and `flashnext:sm120` from their re-audited pushed
   heads using the documented OCI arguments, then inspect labels. BF16 is done
   (`6582043efe9b`); the images must be rebuilt again after any further guarded
   module change, because the reader guard is source-hashed.
2. CUDA byte-parity/graph tests for the optional SM120 writer and runtime
   correctness checks require the RTX PRO 6000 Blackwell and verified CDI.
3. Do not run benchmarks or change production. GPU start, readiness, and
   inference checks are blocked until the target GPU and CDI are available.

## Live state

- `nvidia-smi` lists the RTX 3500 Ada and the RTX PRO 6000 Blackwell; the
  production `luni-llm-orcarouter` container is up on the Blackwell and was not
  touched. No model start, restart, inference, or benchmark was run for this
  experiment.
- The base-profile changes and both variant branches are committed and pushed.
  The prompt branch remains
  `e6fb2fa29340bcd3ab7310599e0ab6a67171863f`.
- The LiteLLM and observability containers are separate from this source
  change; do not alter them as part of the experiment.
