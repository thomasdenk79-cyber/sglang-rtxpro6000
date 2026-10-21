# Flash-Next variants

Three independent branches share the BF16-PLE Flash-Next profile. Each variant
uses its own `docker/pennyroyal/launch/config/start-flash-next-frspec.sh`,
which selects the matching image tag.

| Variant | Branch | Purpose | Variant implementation commit |
|---|---|---|---|
| BF16 | `flashnext/bf16` | Shared baseline | `e6ffa59942fc886d10aefa3d8396995806569dac` |
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

All variants use TP=1, ModelOpt NVFP4 weights, FP8 E4M3 KV, native 262,144
context without YaRN, an eight-request ceiling, and the existing FR-Spec,
adaptive NEXTN, and CUDA Graph policies. KV and Mamba capacities stay automatic.
The selected local checkpoint is the Swift NVFP4 model with its original
approximately 100-GB BF16 PLE table, streamed from NVMe. HiCache is 32 GiB;
NIXL L3 uses `page_first`, `kernel`, and `write_through`. PLE NVMe and NIXL
remain separate storage paths.

The local checkpoint's exact Hub revision and the BF16 PLE end-checkpoint byte
provenance are not yet verified. Do not substitute the FP8-PLE transplant or
claim a verified checkpoint revision until that evidence is recorded.

## Image builds and launch

The Dockerfile accepts OCI build metadata as arguments. Build from the matching
branch and repository root, passing the exact branch `SOURCE_REVISION`, a UTC
`BUILD_TIMESTAMP`, and verified values for `PENNYROYAL_BASE`,
`SGLANG_UPSTREAM_REFERENCE`, `INTEGRATED_PATCHES`, and `CHECKPOINT_REVISION`.
The checkpoint argument must not be guessed. Example shape:

```bash
 : "${CHECKPOINT_REVISION:?Set the verified checkpoint revision first}"
SOURCE_REVISION="$(git rev-parse HEAD)"
BUILD_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
podman build -f docker/pennyroyal/Dockerfile -t flashnext:bf16 \
  --build-arg SOURCE_REVISION="$SOURCE_REVISION" \
  --build-arg SOURCE_REPOSITORY=https://github.com/thomasdenk79-cyber/sglang-rtxpro6000.git \
  --build-arg PENNYROYAL_BASE=pennyroyal-v3.0.2@6b501b800181756890561fe3107c2ed551c1d302 \
  --build-arg SGLANG_UPSTREAM_REFERENCE=v0.5.22@baa9befa381511cd4d56f83980951e5a45fffc6d \
  --build-arg INTEGRATED_PATCHES="Pennyroyal #79,#86; profile; PR #76 tooling" \
  --build-arg CHECKPOINT_REVISION="$CHECKPOINT_REVISION" \
  --build-arg BUILD_TIMESTAMP="$BUILD_TIMESTAMP" \
  --build-arg FLASHNEXT_VARIANT=bf16 .
```

For the other tags, build on their branches with `flashnext:qsa` or
`flashnext:sm120`, and set the variant and integrated-patches arguments to
match the matrix. These images have not been built. Existing launch profiles
are under `docker/pennyroyal/launch/config/`; they require the RTX PRO 6000
Blackwell and verified CDI mapping for runtime validation. Do not benchmark or
change the production container.
