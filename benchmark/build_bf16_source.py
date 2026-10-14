#!/usr/bin/env python3
"""Build hybrid prepare-source for BF16 PLE round C.

Combines the local RadixArk NVFP4 body (symlinks) with the downloaded
Qwen BF16 PLE shards and rewrites model.safetensors.index.json so body
tensors point at the NVFP4 layer-shards and ple tensors point at the
Qwen model-*.safetensors shards. prepare_ple_nvme.py extracts PLE purely
from what the index maps, so the served body stays FP4.

Usage: build_bf16_source.py <qwen-src-dir> <radix-ckpt-dir> <out-dir>
"""
import json, os, sys, pathlib, shutil

qwen, radix, out = (pathlib.Path(p) for p in sys.argv[1:4])
out.mkdir(parents=True, exist_ok=True)

radix_index = json.load(open(radix / 'model.safetensors.index.json'))
qwen_index = json.load(open(qwen / 'model.safetensors.index.json'))

merged = {}
ple_count = 0
for name, shard in radix_index['weight_map'].items():
    if '.ple.' in name or name.startswith('ple.'):
        continue  # replaced by BF16 originals
    merged[name] = shard
for name, shard in qwen_index['weight_map'].items():
    if '.ple.' in name or name.startswith('ple.'):
        assert not shard.startswith('layer-'), f'{name} unexpectedly a radix shard'
        merged[name] = shard
        ple_count += 1
print(f'body entries: {len(merged)-ple_count}, ple entries: {ple_count}')

# symlink every shard referenced by the merged map
missing = []
for shard in sorted(set(merged.values())):
    dst = out / shard
    if dst.exists() or dst.is_symlink():
        continue
    src = (qwen / shard) if shard in set(qwen_index['weight_map'].values()) else (radix / shard)
    if not src.exists():
        missing.append(shard)
        continue
    dst.symlink_to(src)
if missing:
    print('MISSING SHARDS:', missing[:5], f'({len(missing)} total)'); sys.exit(1)

# config: keep the served FP4 config; the PLE dtype claim must MATCH the
# real tensor dtype (bfloat16). Removing the key is NOT an option: the
# qwen4_exp loader treats a missing key as "build bf16 embedding via the
# wrong wrapper" and dies at tokenizer init (madlabs-documented failure).
cfg = json.load(open(radix / 'config.json'))
if 'text_config' in cfg:
    cfg['text_config']['ple_embedding_dtype'] = 'bfloat16'
json.dump(cfg, open(out / 'config.json', 'w'), indent=2)

index = {'metadata': radix_index.get('metadata', {}), 'weight_map': merged}
json.dump(index, open(out / 'model.safetensors.index.json', 'w'))
# tokenizer + template files come from the served ckpt; link via the
# /models mount path so they resolve identically inside the service container
RADIX_CKPT = '/models/RadixArk-Qwen3.8-Flash-Next-NVFP4'
for f in ('tokenizer.json', 'tokenizer_config.json', 'chat_template.jinja',
          'generation_config.json', 'hf_quant_config.json', 'vocab.json', 'merges.txt'):
    s = radix / f
    d = out / f
    if s.exists():
        if d.is_symlink() and str(d.resolve(strict=False)).startswith(str(radix)):
            d.unlink()
        if not d.exists() and not d.is_symlink():
            d.symlink_to(f'{RADIX_CKPT}/{f}')
print('hybrid source ready at', out)
