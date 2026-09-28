#!/usr/bin/env python3
"""Fix round (batch-1 audit G8): a tiny batch-1 fixture library LIBB1 and the fixture registry.

Writes (deterministic: seeded RNG, gzip mtime 0, tar mtime 0 / uid 0, ustar):
  tests/fixtures/raw/LIBB1/R1.tar, R2.tar   one plate pool as the NCSU GSL delivered batch 1: one tar per read, 2 lane members each
                                            LIBB1_R1/LIBB1_S1_L00{1,2}_R1_001.fastq.gz (R2 likewise), 2 x 100 bp
  tests/fixtures/samples_test.csv           + the LIBB1 rows (bc2s3_batch1, r1_only, 8-bp R1 barcodes, tar-member raw_r1/raw_r2,
                                            rg_pu) and the new rg_pu column (empty for LIBX)
  tests/fixtures/registry_test.csv          the fixture registry (meta/registry.csv columns, meta/build_samples.py COLS)

Read structure (Twist 96-Plex): R1 = 8-bp well barcode + 12 random bases + genome, R2 = 8 random bases + genome (reverse strand);
DEMUX must give R1 = raw R1[20:], R2 = raw R2[8:] (both then exact substrings of tests/fixtures/ref/tiny.fa chrA, R2 reverse-complemented).
Per lane: PB1_SID1 30 pairs, PB1_SID2 20, PB1_SID3 10, PB1_SID4 0 (an empty well: TRIMMOMATIC must pass it, audit G1), plus 8 pairs
with a barcode of no well (unassigned). Read names @A00600:1:TESTFCB1:<lane>:1101:<x>:<y>, quality 'F' with a binned '-' last base.
"""
import csv
import gzip
import io
import os
import random
import tarfile

R = '/Users/fvrodriguez/repos/zealgt-simplify'
FX = f'{R}/tests/fixtures'
OUT = f'{FX}/raw/LIBB1'
LEN = 100
WELLS = [('PB1_SID1', 'A01', 'CGTACGTA', 30), ('PB1_SID2', 'B01', 'AGGAACGT', 20), ('PB1_SID3', 'C01', 'CTAGCTAG', 10),
         ('PB1_SID4', 'D01', 'CTCTCAGT', 0)]
UNASSIGNED = ('GGGGCCCC', 8)
COMP = str.maketrans('ACGT', 'TGCA')

rng = random.Random(20260928)
seq = ''.join(l.strip() for l in open(f'{FX}/ref/tiny.fa').read().split('>chrB')[0].splitlines()[1:])


def rnd(n):
    return ''.join(rng.choice('ACGT') for _ in range(n))


def lane_fastq(lane):
    r1, r2 = [], []
    k = 0
    for _sid, _well, bc, n in WELLS + [('unassigned', '', UNASSIGNED[0], UNASSIGNED[1])]:
        for _ in range(n):
            k += 1
            frag_len = rng.randint(220, 300)
            pos = rng.randint(0, len(seq) - frag_len)
            frag = seq[pos:pos + frag_len]
            name = f'A00600:1:TESTFCB1:{lane}:1101:{1000 + k}:{2000 + k}'
            s1 = bc + rnd(12) + frag[:LEN - 20]
            s2 = rnd(8) + frag.translate(COMP)[::-1][:LEN - 8]
            q = 'F' * (LEN - 1) + '-'
            r1.append(f'@{name} 1:N:0:GCCAAT\n{s1}\n+\n{q}\n')
            r2.append(f'@{name} 2:N:0:GCCAAT\n{s2}\n+\n{q}\n')
    return ''.join(r1), ''.join(r2)


def gz(text):
    b = io.BytesIO()
    with gzip.GzipFile(filename='', mode='wb', fileobj=b, mtime=0) as g:
        g.write(text.encode())
    return b.getvalue()


def add(tar, name, data):
    ti = tarfile.TarInfo(name)
    ti.size, ti.mtime, ti.uid, ti.gid, ti.uname, ti.gname, ti.mode = len(data), 0, 0, 0, '', '', 0o644
    tar.addfile(ti, io.BytesIO(data))


os.makedirs(OUT, exist_ok=True)
lanes = {lane: lane_fastq(lane) for lane in (1, 2)}
for read in ('R1', 'R2'):
    with tarfile.open(f'{OUT}/{read}.tar', 'w', format=tarfile.USTAR_FORMAT) as tar:
        d = tarfile.TarInfo(f'LIBB1_{read}')
        d.type, d.mtime, d.mode, d.uname, d.gname = tarfile.DIRTYPE, 0, 0o755, '', ''
        tar.addfile(d)
        for lane in (1, 2):
            add(tar, f'LIBB1_{read}/LIBB1_S1_L00{lane}_{read}_001.fastq.gz', gz(lanes[lane][0 if read == 'R1' else 1]))

raw = {rd: ';'.join(f'{rd}.tar:LIBB1_{rd}/LIBB1_S1_L00{ln}_{rd}_001.fastq.gz' for ln in (1, 2)) for rd in ('R1', 'R2')}

# samples_test.csv: the workflow-1 columns (meta/build_samples.py WF_COLS) incl. rg_pu
WF = ['sample_id', 'source', 'role', 'library', 'library_index', 'raw_location', 'raw_r1', 'raw_r2', 'barcode_r1', 'barcode_r2',
      'barcode_layout', 'plate', 'well', 'donor', 'taxon', 'nil_id', 'pedigree', 'is_check', 'rg_lb', 'rg_pl', 'rg_pu']
LIBX = [dict(sample_id=f'LX_{i}', source='bc1', role='bc1_sample', library='LIBX', raw_location='tests/fixtures/raw/LIBX',
             barcode_r1=bc, barcode_r2=bc, barcode_layout='symmetric', well=str(i), donor='Zx.TEST_P1', taxon='mexicana',
             pedigree=f'Zx.TEST_P1_P{i}', is_check='FALSE', rg_lb='LIBX', rg_pl='ILLUMINA')
        for i, bc in ((1, 'GCCATA'), (2, 'TCTGGT'), (3, 'TGGCTT'))]
B1 = []
for sid, well, bc, _n in WELLS:
    check = sid == 'PB1_SID4'
    B1.append(dict(sample_id=sid, source='bc2s3_batch1', role='check' if check else 'line', library='LIBB1', library_index='GCCAAT',
                   raw_location='tests/fixtures/raw/LIBB1', raw_r1=raw['R1'], raw_r2=raw['R2'], barcode_r1=bc, barcode_layout='r1_only',
                   plate='1', well=well, donor='' if check else 'Zx.TEST_P2', taxon='' if check else 'mexicana',
                   nil_id='' if check else f'Zx900021{sid[-1]}1', pedigree='B73' if check else f'Zx.TEST_P2_P1_P{sid[-1]}.1.1.1',
                   is_check='TRUE' if check else 'FALSE', rg_lb='LIBB1', rg_pl='ILLUMINA', rg_pu='TESTFCB1.1,TESTFCB1.2'))


def write(path, cols, rows):
    with open(path, 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=cols, lineterminator='\n')
        w.writeheader()
        w.writerows([{c: r.get(c, '') for c in cols} for r in rows])


write(f'{FX}/samples_test.csv', WF, LIBX + B1)

# registry_test.csv: every registry column; identity extras so the snapshot has something to record; PB1_SID3 carries a
# correction (resolved values differ from the raw ones), as C0001 does for PN17_SID1574 in meta/registry.csv
src = open(f'{R}/meta/build_samples.py').read()
cols_src = src[src.index('COLS = ['):src.index(']', src.index("'flags'")) + 1]
ns = {}
exec(cols_src, ns)
COLS = ns['COLS']
reg = []
for r in LIBX:
    reg.append(dict(r, delivered_name=r['pedigree'], accession='Zx.TEST', taxa_code='Test', line_id=r['pedigree'], gen='BC1',
                    F1='P1', BC1=f"P{r['well']}", j2teo_batch='A', pedigree_resolved=r['pedigree'], donor_resolved=r['donor'],
                    exclude='FALSE'))
for r in B1:
    check = r['role'] == 'check'
    d = dict(r, lab_seq_id='', delivered_name='B73' if check else f"TEST-{r['sample_id']}_P2_P1-bulk",
             accession='' if check else 'Zx.TEST', taxa_code='' if check else 'Test',
             line_id='' if check else r['pedigree'] + '.B', gen='' if check else 'BC2S3-B', F1='' if check else 'P2',
             BC1='' if check else 'P1', BC2='' if check else f"P{r['sample_id'][-1]}", S1='' if check else '1',
             S2='' if check else '1', S3='' if check else '1', blk='' if check else 'B', j2teo_batch='' if check else 'A',
             field='PV23', field_plot=f"PV23-{9000 + int(r['sample_id'][-1])}", seed_packet=f"PV23-{100 + int(r['sample_id'][-1])}",
             mother_plant='' if check else 'CLY22-TEST-1', nil_id_in_register='' if check else 'TRUE',
             pedigree_resolved=r['pedigree'], nil_id_resolved=r['nil_id'], donor_resolved=r['donor'], exclude='FALSE')
    if r['sample_id'] == 'PB1_SID3':
        d.update(pedigree_resolved='Zx.TEST_P3_P1_P3.1.1.1', nil_id_resolved='Zx90003131', donor_resolved='Zx.TEST_P3',
                 correction_ids='C9001;C9002', flags='tissue_plot_j2teo_rows=2;pedigree_from_seed_packet')
    reg.append(d)
write(f'{FX}/registry_test.csv', COLS, reg)
print('LIBB1 tars:', sorted(os.listdir(OUT)), '| samples_test rows', len(LIBX + B1), '| registry_test rows', len(reg), 'cols', len(COLS))
