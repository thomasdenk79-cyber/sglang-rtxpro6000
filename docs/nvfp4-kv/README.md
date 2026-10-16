# NVFP4 KV cache on Pennyroyal 3.0.1 (SM120)

Vendored patch set from https://github.com/Lesilva/qwen38-flashnext-nvfp4-kv
(Apache-2.0, NOTICE kept; sources and tests under `third_party/nvfp4-kv/`).
Applied as `patches/pennyroyal-3.0.1/0001..0003` in numeric order. All three
applied clean against this branch, and the nine touched files are byte-identical
to the release overlay of Pennyroyal 3.0.1 (verified with `cmp`).

Why we want it: the QSA layers store KV as packed E2M1 with one E4M3 scale per 16
values. The dequant happens inside the gather QSA performs anyway, so the
attention kernels, their CUDA graphs and the top-k selection are unchanged and no
full-pool dequant workspace is allocated. Reference on the same GPU: 1M-token pool
12.16 -> 7.15 GiB, decode geomean 0.989x, quality not measurably different
(24-window paired tail NLL, 8K-128K). Patch 0003 (indexer split-K) is
independent of the KV format and cuts long-context prefill: 1.6x at 8K, 8.5x at
480K single-launch, TTFT at 480K -18%, bit-identical logits.

## Serve flags

```
--kv-cache-dtype nvfp4
--speculative-draft-kv-cache-dtype fp8_e4m3
--max-total-tokens <N>        # required: the capacity planner budgets a
                              # dequant workspace this path never allocates
```
plus `SGLANG_QSA_NVFP4_KV=1` (set by our launcher when `PENNY_KV_DTYPE=nvfp4`).
Rollback: `--kv-cache-dtype fp8_e4m3`; the env var is then ignored.
With `--prefill-decode-interval` use patch 0002 and
`SGLANG_OPT_MAMBA_SKIP_DECODE_LOCK=true` (also set by the launcher).
Keep `TILELANG_CACHE_DIR` persistent: split-K JIT compiles per split value
(one-off ~2 s stall each).

## Verification status

* `git apply --check` clean for all three patches; `py_compile` clean.
* Module import inside our image resolves to the overlay files; `QSANVFP4KVCacheMethod`
  present; `sglang serve --help` lists `nvfp4` under `--kv-cache-dtype`.
* `third_party/nvfp4-kv/tests/test_nvfp4_kv.py` is a benchmark script with
  import-time allocations (1M-token pool). It must run on a free GPU, i.e. in the
  restart window, not next to a loaded engine.
