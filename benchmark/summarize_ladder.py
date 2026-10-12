#!/usr/bin/env python3
"""Render bench-results ladder JSON as sum-token / throughput tables.

Rows = context tier, columns = concurrency. Metrics:
  tokens  : sum tokens in+out actually processed (server-reported totals)
  out     : aggregate output tok/s (generated tokens only)
  perreq  : out tok/s / concurrency (what one active agent feels)
  total   : total tok/s incl. prefill
  ttft    : mean time-to-first-token ms
  itl     : median inter-token latency ms
"""
import argparse
import glob
import json
import os
import statistics


def load(paths):
    data = {}
    for d in paths:
        for f in sorted(glob.glob(os.path.join(d, 'qwen_*.json'))):
            name = os.path.basename(f)[:-5]
            try:
                with open(f) as fh:
                    runs = json.loads(fh.readline())
            except Exception:
                continue
            if isinstance(runs, dict):
                runs = [runs]
            for r in runs:
                if not r.get('completed'):
                    continue
                data.setdefault(name, []).append(r)
    return data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dirs', nargs='+')
    ap.add_argument('--metric', default='both',
                    choices=['both', 'tokens', 'out', 'perreq', 'total', 'ttft', 'itl', 'accept'])
    args = ap.parse_args()
    data = load(args.dirs)

    tiers, cs = [], set()
    for key in data:
        tier, c = key.replace('qwen_', '').rsplit('_c', 1)
        tiers.append(tier)
        cs.add(int(c))
    order = ['short', 'medium', 'long', 'xlong', 'xxlong']
    tiers = sorted(set(tiers), key=lambda t: order.index(t) if t in order else 99)

    def med(key, fn):
        return statistics.median(fn(r) for r in data[key])

    def cell(tier, c, m):
        key = f'qwen_{tier}_c{c}'
        if key not in data:
            return '—'
        if m == 'tokens':
            return f'{med(key, lambda r: r["total_input_tokens"] + r["total_output_tokens"])/1000:.0f}k'
        if m == 'out':
            return f'{med(key, lambda r: r["output_throughput"]):.0f}'
        if m == 'perreq':
            return f'{med(key, lambda r: r["output_throughput"])/c:.0f}'
        if m == 'total':
            return f'{med(key, lambda r: r["total_throughput"]):.0f}'
        if m == 'ttft':
            return f'{med(key, lambda r: r["mean_ttft_ms"]):.0f}'
        if m == 'itl':
            return f'{med(key, lambda r: r["median_itl_ms"]):.1f}'
        if m == 'accept':
            return f'{med(key, lambda r: r["accept_length"]):.2f}'

    labels = {'tokens': 'sum tokens in+out processed',
              'out': 'aggregate output tok/s',
              'perreq': 'output tok/s per active request',
              'total': 'total tok/s (in+out)',
              'ttft': 'TTFT ms (mean)',
              'itl': 'ITL ms (median)',
              'accept': 'spec accept length (draft tokens)'}
    metrics = ['tokens', 'out', 'perreq', 'ttft'] if args.metric == 'both' else [args.metric]
    for m in metrics:
        print(f'\n== {labels[m]} ==')
        print(f"{'tier':>8} | " + ' | '.join(f'{"c"+str(c):>4}' for c in sorted(cs)))
        for t in tiers:
            print(f'{t:>8} | ' + ' | '.join(f'{cell(t, c, m):>4}' for c in sorted(cs)))


if __name__ == '__main__':
    main()
