#!/usr/bin/env python3
"""Build meta/samples.csv — the single sample sheet of workflow 1 (read processing), one row per sequenced well/sample.

Sources (meta/sources/, copied 2026-09-24):
  bc1_well_map.csv, bc1_libraries.csv                 BC1 pools 1A–4H (zealbc1 meta/)
  bc2s3_batch2_well_map.csv, bc2s3_batch2_libraries.csv  BC2S3 batch 2, rows V21A–V24H (zealbc1 meta/; 4 sequenced plates)
  bc2s3_batch1_sample_sheet.csv                       BC2S3 batch 1 (CLY2023): CSV of sara/DNA_Sequencing_raw/BZea/BZea_Sample_ID.xlsx
  bc2s3_batch1_tar_members.tsv                        FASTQ members of NVS188B_Rellan_Alvarez_R{1,2}.tar (size, path)
  bc2s3_batch1_skim_nil_id.tsv                        batch-1 sample -> nil_id, pedigree (zealbc1 agent/skim_sample_nil_id.tsv)
Batch-1 exclusions (user, 2026-09-24): plate 1 and LANTEO* wells belong to another project.
Batch-1 joins (checked 2026-09-24): BZea<n> = plate n (plates 10–17 reuse TruSeq indexes 2–9 and sit on lanes 3–4);
sample_id = PN<plate>_SID<running number>. Batch-1 inline barcode = 8 bp on R1 only.

Usage: python3 meta/build_samples.py   (writes meta/samples.csv and prints the validation report; exits 1 on a failed check)"""
import csv, os, re, sys, collections

HERE = os.path.dirname(os.path.abspath(__file__)); SRC = os.path.join(HERE, 'sources')
BZEA = '/rsstu/users/r/rrellan/BZea'
RAW_BC1 = f'{BZEA}/BC1_dna_raw/01.RawData'
RAW_B2 = f'{BZEA}/BC2S3_batch_2_dna_raw/01.RawData'
RAW_B1 = '/rsstu/users/r/rrellan/sara/DNA_Sequencing_raw/BZea'
TAXON = {'Zd': 'diploperennis', 'Zx': 'mexicana', 'Zv': 'parviglumis', 'Zl': 'luxurians', 'Zh': 'huehuetenangensis'}
COLS = ['sample_id', 'source', 'role', 'library', 'library_index', 'raw_location', 'raw_r1', 'raw_r2',
        'barcode_r1', 'barcode_r2', 'barcode_layout', 'plate', 'well', 'donor', 'taxon', 'nil_id', 'pedigree', 'is_check',
        'rg_lb', 'rg_pl']

def rd(name, delim=','):
    with open(os.path.join(SRC, name), newline='') as f:
        return list(csv.DictReader(f, delimiter=delim))

def donor_of(ped):
    m = re.match(r'^(Z[a-z]\.\d+_P\d+)_', ped or ''); return m.group(1) if m else ''

rows = []
# --- BC1 pools -------------------------------------------------------------------------------------------------------
libdir = {r['pool']: r['raw_dir'] for r in rd('bc1_libraries.csv')}
for r in rd('bc1_well_map.csv'):
    rows.append(dict(sample_id=r['Sample_Id'], source='bc1', role='bc1_sample', library=r['pool'], library_index='',
                     raw_location=f"{RAW_BC1}/{libdir[r['pool']]}", raw_r1='', raw_r2='', barcode_r1=r['barcode'],
                     barcode_r2=r['barcode'], barcode_layout='symmetric', plate='', well=r['column'], donor=r['donor'],
                     taxon=r['taxon'], nil_id='', pedigree=r['BC1_line_id'], is_check='FALSE', rg_lb=r['pool'], rg_pl='ILLUMINA'))
# --- BC2S3 batch 2 ---------------------------------------------------------------------------------------------------
libdir = {r['pool']: r['raw_dir'] for r in rd('bc2s3_batch2_libraries.csv')}
for r in rd('bc2s3_batch2_well_map.csv'):
    cls = r['class']; chk = r['is_check'].upper() == 'TRUE' or cls in ('B73', 'NC358')
    role = 'empty' if cls == 'empty' else ('check' if chk else 'line')
    rows.append(dict(sample_id=r['Sample_Id'], source='bc2s3_batch2', role=role, library=r['pool'], library_index='',
                     raw_location=f"{RAW_B2}/{libdir[r['pool']]}", raw_r1='', raw_r2='', barcode_r1=r['barcode'],
                     barcode_r2=r['barcode'], barcode_layout='symmetric', plate=r['plate'], well=r['cell'], donor=r['donor'],
                     taxon=r['taxon'] if r['taxon'] not in ('NA',) else '', nil_id=r['nil_id'] if r['nil_id'] != 'NA' else '',
                     pedigree=r['pedigree'] if r['pedigree'] != 'NA' else '', is_check='TRUE' if chk else 'FALSE',
                     rg_lb=r['pool'], rg_pl='ILLUMINA'))
# --- BC2S3 batch 1 (CLY2023) -----------------------------------------------------------------------------------------
members = collections.defaultdict(lambda: {'R1': [], 'R2': []})
for line in open(os.path.join(SRC, 'bc2s3_batch1_tar_members.tsv')):
    size, path = line.rstrip('\n').split('\t'); m = re.search(r'/BZea(\d+)_S\d+_L\d+_(R[12])_001\.fastq\.gz$', path)
    members[int(m.group(1))][m.group(2)].append(path)
skim = {r['sample']: r for r in rd('bc2s3_batch1_skim_nil_id.tsv', '\t')}
excluded = collections.Counter()
for r in rd('bc2s3_batch1_sample_sheet.csv'):
    # Not ZEAL (user, 2026-09-24): plate 1 and the LANTEO* wells (another project sequenced in the same run).
    if r['Plate_Number'] == '1' or r['Genotype'].startswith('LANTEO'):
        excluded['plate 1' if r['Plate_Number'] == '1' else 'LANTEO* on plates 2-17'] += 1; continue
    plate = int(r['Plate_Number']); sid = f"PN{plate}_SID{r['Sample_ID']}"; g = r['Genotype']; s = skim.get(sid, {})
    ped = s.get('pedigree', ''); nil = s.get('nil_id', '')
    is_b73 = g.upper().startswith('B73') or nil == 'B73_check'
    is_purple = 'PURPLE' in g.upper()
    role = 'check' if (is_b73 or is_purple) else ('landrace_line' if re.search(r'_BC1S[0-9]', g) else 'line')
    d = donor_of(ped); tx = TAXON.get(d[:2], '') if d else ''
    rows.append(dict(sample_id=sid, source='bc2s3_batch1', role=role, library=f'BZea{plate}', library_index=r['Plate_barcode'],
                     raw_location=RAW_B1, raw_r1=';'.join(f'NVS188B_Rellan_Alvarez_R1.tar:{p}' for p in sorted(members[plate]['R1'])),
                     raw_r2=';'.join(f'NVS188B_Rellan_Alvarez_R2.tar:{p}' for p in sorted(members[plate]['R2'])),
                     barcode_r1=r['Sample_Barcode'], barcode_r2='', barcode_layout='r1_only', plate=str(plate), well=r['Sample_Id'],
                     donor=d, taxon=tx, nil_id='' if nil == 'B73_check' else nil, pedigree=ped or g, is_check='TRUE' if role == 'check' else 'FALSE',
                     rg_lb=f'BZea{plate}', rg_pl='ILLUMINA'))

# --- validation ------------------------------------------------------------------------------------------------------
fail = []
ids = collections.Counter(r['sample_id'] for r in rows)
dups = [k for k, v in ids.items() if v > 1]
if dups: fail.append(f'duplicate sample_id: {dups[:5]}')
for key, name in ((('library', 'barcode_r1', 'barcode_r2'), 'barcode within library'),):
    c = collections.Counter(tuple(r[k] for k in key) for r in rows)
    bad = [k for k, v in c.items() if v > 1]
    if bad: fail.append(f'duplicate {name}: {bad[:5]}')
# One DEMUX task per library reads these from the library's first row: every sample of a library must agree on them
# (the pipeline checks it again when it reads the library, zgDemuxInputs).
for k in ('source', 'barcode_layout', 'raw_location', 'raw_r1', 'raw_r2'):
    per_lib = collections.defaultdict(set)
    for r in rows: per_lib[r['library']].add(r[k])
    bad = sorted(lib for lib, v in per_lib.items() if len(v) > 1)
    if bad: fail.append(f'samples of a library disagree on {k}: {bad[:5]}')
for r in rows:
    if not r['raw_location'] or not r['barcode_r1']: fail.append(f"missing raw location or barcode: {r['sample_id']}")
    if r['source'] == 'bc2s3_batch1' and (not r['raw_r1'] or not r['raw_r2']): fail.append(f"no tar members: {r['sample_id']}")
with open(os.path.join(HERE, 'samples.csv'), 'w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=COLS); w.writeheader(); w.writerows(rows)
print(f'[build_samples] {len(rows)} rows -> meta/samples.csv')
for (src, role), n in sorted(collections.Counter((r['source'], r['role']) for r in rows).items()): print(f'  {src:14s} {role:14s} {n}')
lib = collections.Counter((r['source'], r['library']) for r in rows)
print('  libraries:', {s: sum(1 for (a, b) in lib if a == s) for s in ('bc1', 'bc2s3_batch1', 'bc2s3_batch2')})
b1 = [r for r in rows if r['source'] == 'bc2s3_batch1' and r['role'] == 'line']
print(f"  batch-1 lines with nil_id from the skim map: {sum(1 for r in b1 if r['nil_id'])} of {len(b1)}")
unmatched = [k for k in skim if k not in ids]
print(f'  batch-1 wells excluded (other project): {dict(excluded)}')
print(f'  skim-map samples not in the batch-1 sheet: {len(unmatched)} {unmatched[:14]}')
if fail:
    print('[build_samples] FAILED:'); [print('  ' + x) for x in fail[:20]]; sys.exit(1)
print('[build_samples] all checks passed')
