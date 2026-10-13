#!/usr/bin/env python3
"""Transparent comparison of round-2 A/B bench dirs (bench-results/ab2-*).

Usage: compare_ab2.py dirA [dirB ...]
Prints per tier a table: concurrency x {out tok/s, TTFT mean/med, TPOT med}
per run, plus delta column for the first two runs. Raw JSONs stay on disk.
"""
import json, os, sys, glob

def load(d):
    pts = {}
    for f in glob.glob(os.path.join(d, 'qwen_*.json')):
        j = json.load(open(f))
        n = os.path.basename(f)[5:-5]           # tier_cN
        tier, c = n.rsplit('_c', 1)
        pts[(tier, int(c))] = j
    return pts

runs = [(os.path.basename(d).replace('ab2-', '').split('-2026')[0], load(d)) for d in sys.argv[1:]]
tiers = ['short', 'medium', 'long', 'xlong']
def g(j, k, r=1):
    v = j.get(k)
    return round(v, r) if isinstance(v, (int, float)) else None

hdr = f"{'tier':7} {'c':>2} " + ' | '.join(f"{name[:9]:>9} {'TTFT':>6} {'TPOT':>6}" for name, _ in runs)
if len(runs) >= 2:
    hdr += ' |  out-delta'
print(hdr)
print('-' * len(hdr))
for t in tiers:
    for c in range(1, 9):
        cells, vals = [], []
        for name, pts in runs:
            j = pts.get((t, c))
            if j:
                o = g(j, 'output_throughput'); tt = g(j, 'mean_ttft_ms'); tp = g(j, 'median_tpot_ms')
                cells.append(f"{o:>9} {tt:>6} {tp:>6}"); vals.append(o)
            else:
                cells.append(f"{'--':>9} {'--':>6} {'--':>6}"); vals.append(None)
        delta = ''
        if len(vals) >= 2 and vals[0] and vals[1]:
            delta = f" | {(vals[1]/vals[0]-1)*100:+7.1f}%"
        print(f"{t:7} {c:>2} " + ' | '.join(cells) + delta)
