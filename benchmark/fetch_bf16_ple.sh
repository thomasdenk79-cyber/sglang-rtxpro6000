#!/usr/bin/env bash
# Round C prep: fetch the 33 BF16 PLE shards (104.3 GB) of the ORIGINAL
# Qwen/Qwen3.8-Flash-Next checkpoint into /srv/ai/models/qwen-bf16-ple-src.
# Run ONLY when no benchmark round is in flight (page-cache/IO pollution).
set -euo pipefail
SRC=/srv/ai/models/qwen-bf16-ple-src
mkdir -p "$SRC"
REPO_DIR=/home/z000g9hu/work/sglang-rtxpro6000
hf download Qwen/Qwen3.8-Flash-Next \
  $(cat "$REPO_DIR/bench-results/bf16_ple_shards.txt") \
  config.json model.safetensors.index.json \
  --repo-type model --local-dir "$SRC"
echo "DOWNLOAD_DONE $(date -Is)"
