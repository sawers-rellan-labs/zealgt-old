#!/usr/bin/env python3
"""Fit wall time (h) = base + k * input_GiB per process from Gate 2 (gate2_3A) completed tasks, and check the adopted
formulas (Gate 3 projection, main checkout agent/20260928_145500_gate3_projection.md) against the same tasks.

Inputs:
  agent/20260928_230000_measure_input_sizes.txt   (hazel, read-only: realtime + dereferenced input sizes per task)
  main checkout agent/20260929_gate3_traces/     (SAMTOOLS_STATS realtimes; its input is the sample's CRAM)
  3A per-sample read pairs (store/demux_qc/3A.tsv, copied below)
FASTQC runs on the trimmed pair (subworkflows/local/read_trimming): its size is ALIGN_MARKDUP's input of the same sample.
Own-fit margin = max(1.3, p95 of observed / fitted).
"""
import glob
import math
import re

SRC = 'agent/20260928_230000_measure_input_sizes.txt'
TRACES = '/Users/fvrodriguez/repos/zealgt/agent/20260929_gate3_traces/execution_trace_*.txt'
GIB = 2 ** 30
PAIRS = {'S_3A_1': 93236923, 'S_3A_2': 18794244, 'S_3A_3': 50711960, 'S_3A_4': 41033044, 'S_3A_5': 45680436,
         'S_3A_6': 90184225, 'S_3A_7': 82198222, 'S_3A_8': 113780970, 'S_3A_9': 91420675, 'S_3A_10': 99793093,
         'S_3A_11': 84228658, 'S_3A_12': 105382580}
# adopted (conf/hazel.config): hours = a + b x GiB, x task.attempt, floor 15 min
ADOPTED = {'TRIMMOMATIC': (0.1, 0.105), 'FASTQC': (0.1, 0.032), 'ALIGN_MARKDUP': (0.25, 0.323),
           'SAMTOOLS_STATS': (0.1, 0.06), 'PICARD_COLLECTWGSMETRICS': (0.21, 0.174)}
FLOOR_H = 0.25
SHORT_MAX_H = 1.75


def hours(s):
    h = 0.0
    for v, u in re.findall(r'([\d.]+)(ms|h|m|s)', s):
        h += float(v) * {'h': 1, 'm': 1 / 60, 's': 1 / 3600, 'ms': 1 / 3.6e6}[u]
    return h


rows = []
for line in open(SRC):
    f = line.rstrip('\n').split('\t')
    if f[0] == 'process':
        continue
    size = sum(int(x.split('=')[1]) for x in f[7].split() if '=' in x)
    rows.append(dict(proc=f[0], tag=f[1], attempt=int(f[2]), mem=f[3], h=hours(f[4]), bytes=size))
trimmed = {r['tag']: r['bytes'] for r in rows if r['proc'] == 'ALIGN_MARKDUP'}
cram = {r['tag']: r['bytes'] for r in rows if r['proc'] == 'PICARD_COLLECTWGSMETRICS'}
for r in rows:
    if r['proc'] == 'FASTQC':
        r['bytes'] = trimmed[r['tag']]
for t in sorted(glob.glob(TRACES)):
    hdr = None
    for line in open(t):
        f = line.rstrip('\n').split('\t')
        if hdr is None:
            hdr = {k: i for i, k in enumerate(f)}
            continue
        if f[hdr['process']].endswith(':SAMTOOLS_STATS') and f[hdr['status']] == 'COMPLETED':
            tag = f[hdr['tag']]
            rows.append(dict(proc='SAMTOOLS_STATS', tag=tag, attempt=int(f[hdr['attempt']]), mem=f[hdr['memory']],
                             h=hours(f[hdr['realtime']]), bytes=cram[tag]))


def fit(xs, ys):
    n = len(xs)
    mx, my = sum(xs) / n, sum(ys) / n
    k = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sum((x - mx) ** 2 for x in xs)
    return my - k * mx, k


def p95(v):
    v = sorted(v)
    i = 0.95 * (len(v) - 1)
    lo = math.floor(i)
    return v[lo] + (v[min(lo + 1, len(v) - 1)] - v[lo]) * (i - lo)


def adopted(proc, gib, attempt=1):
    a, b = ADOPTED[proc]
    return max(FLOOR_H, a + b * gib) * attempt


# GiB per M pairs (for the M-pair table): raw pair (TRIMMOMATIC input), trimmed pair, CRAM
gpm = {}
for proc in ('TRIMMOMATIC', 'ALIGN_MARKDUP', 'PICARD_COLLECTWGSMETRICS'):
    sel = [r for r in rows if r['proc'] == proc]
    gpm[proc] = sum(r['bytes'] for r in sel) / GIB / (sum(PAIRS[r['tag']] for r in sel) / 1e6)
gpm['FASTQC'] = gpm['ALIGN_MARKDUP']
gpm['SAMTOOLS_STATS'] = gpm['PICARD_COLLECTWGSMETRICS']

for proc, keep in (('TRIMMOMATIC', lambda r: True),
                   ('FASTQC', lambda r: True),
                   ('ALIGN_MARKDUP', lambda r: r['mem'] == '48 GB'),
                   ('SAMTOOLS_STATS', lambda r: True),
                   ('PICARD_COLLECTWGSMETRICS', lambda r: True)):
    sel = sorted((r for r in rows if r['proc'] == proc and keep(r)), key=lambda r: r['bytes'])
    xs = [r['bytes'] / GIB for r in sel]
    ys = [r['h'] for r in sel]
    a, k = fit(xs, ys)
    ratios = [y / (a + k * x) for x, y in zip(xs, ys)]
    m = max(1.3, p95(ratios))
    head = [r for r in sel]
    worst = min(adopted(proc, x) / y for x, y in zip(xs, ys))
    print(f'== {proc}: n={len(sel)}  own fit h = {a:.3f} + {k:.4f} x GiB  p95(obs/fit) = {p95(ratios):.3f}  margin {m:.2f}'
          f'  | adopted {ADOPTED[proc][0]} + {ADOPTED[proc][1]} x GiB, min(request/observed) = {worst:.2f}'
          f'  | {gpm[proc]:.4f} GiB per M pairs')
    for r, x, y, q in zip(head, xs, ys, ratios):
        print(f'   {r["tag"]:8s} {r["mem"]:6s} {PAIRS[r["tag"]] / 1e6:6.1f} M  {x:7.3f} GiB  obs {y:5.2f} h  own fit {a + k * x:5.2f}'
              f' (obs/fit {q:4.2f}, own req {(a + k * x) * m:5.2f})  adopted req {adopted(proc, x):5.2f} h'
              f' (x{adopted(proc, x) / y:4.2f})')
    for r in (r for r in rows if r['proc'] == proc and not keep(r)):
        x = r['bytes'] / GIB
        print(f'   (not fitted) {r["tag"]} {r["mem"]} {x:.3f} GiB obs {r["h"]:.2f} h own fit {a + k * x:.2f} h')
    for mp in (50, 100, 200, 310):
        gib = mp * gpm[proc]
        t = [adopted(proc, gib, n) for n in (1, 2, 3)]
        q = ['short' if v <= SHORT_MAX_H else 'normal' for v in t]
        print(f'   {mp:3d} M pairs ~ {gib:6.2f} GiB -> adopted attempt 1/2/3: '
              + ', '.join(f'{min(24, v):5.2f} h {qq}' for v, qq in zip(t, q))
              + f'   (own fit x margin: {max(FLOOR_H, (a + k * gib) * m):5.2f} h)')
