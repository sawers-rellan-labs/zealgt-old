#!/usr/bin/env python3
"""Fixture fix: tests/fixtures/raw/LIBX/*.fq.gz had every quality 'F' (Q37), which Trimmomatic 0.39 cannot auto-detect
(phred33 vs phred64 ambiguous) since -phred33 was dropped from trim_args (db3a9c5): the first real local run after the
refactor failed with 'Unable to detect quality encoding'. NovaSeq X bins qualities to Q2/12/23/37 ('#', '-', '8', 'F'), so
real reads always carry characters below 58 and detect as phred33. This rewrites the LAST base quality of every read to '-'
(Q12), leaving names and sequences unchanged, so the fixtures look like binned NovaSeq reads. Deterministic (gzip mtime 0)."""
import glob
import gzip
import os

D = '/Users/fvrodriguez/repos/zealgt/tests/fixtures/raw/LIBX'
for p in sorted(glob.glob(os.path.join(D, '*.fq.gz'))):
    with gzip.open(p, 'rt') as fh:
        lines = fh.read().split('\n')
    n = 0
    for i in range(3, len(lines), 4):
        q = lines[i]
        if q:
            lines[i] = q[:-1] + '-'
            n += 1
    with open(p, 'wb') as raw:
        with gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0) as gz:
            gz.write('\n'.join(lines).encode())
    print(os.path.basename(p), n, 'reads')
