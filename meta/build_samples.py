#!/usr/bin/env python3
"""Build the zealgt sample-identity registry from the pinned master documents in meta/sources/.

Outputs (all rebuilt together, never hand-edited):
  meta/registry.csv    one row per sequenced sample of every experiment (BC1, BC2S3 batch 1 incl. the wells of the other project,
                       BC2S3 batch 2, BRB-seq), key sample_id
  meta/samples.csv     the sample sheet of workflow 1 (read processing): the registry rows of bc1 / bc2s3_batch1 / bc2s3_batch2
                       that are not excluded, with the first 21 registry columns (up to rg_pu) (assets/schema_input.json validates it)
  meta/accessions.csv  donor passport data (J2Teo metadata), with the resolved longitude

Rules (meta/PROVENANCE.md "Sources" and "Joins"):
  - Reads only files listed in meta/sources/SOURCES.tsv and verifies each sha256 first (refuses on mismatch).
  - Only joins and the documented pedigree -> nil_id rule (meta/sources/NIL_ID_README.md); the rule's result is checked against the
    register copy (meta/sources/register_bc2s3.csv) and mismatches are reported, never overridden.
  - meta/corrections.csv (append-only) is applied only to the *_resolved columns; the raw columns stay as the sources give them.
  - sample_id values are those already in the CRAMs (BC1 S_<pool>_<col>, batch 2 P<plot>, batch 1 PN<plate>_SID<n>); BRB-seq wells
    are BRB_<Seq_ID> because their lab ids (PN<plate>_SID<n>) reuse the batch-1 names for other plants.

Usage: python3 meta/build_samples.py           print the report and write the three tables (on a failed check: exit 1, nothing written)
       python3 meta/build_samples.py --check   rebuild in memory and diff against the committed tables (exit 1 on any difference)
"""
import csv, os, re, sys, io, hashlib, collections
HERE = os.path.dirname(os.path.abspath(__file__)); SRC = os.path.join(HERE, 'sources')
sys.path.insert(0, HERE)
from xlsx_read import Workbook

CHECK = '--check' in sys.argv[1:]
BZEA = '/rsstu/users/r/rrellan/BZea'
RAW_BC1 = f'{BZEA}/BC1_dna_raw/01.RawData'
RAW_B2 = f'{BZEA}/BC2S3_batch_2_dna_raw/01.RawData'
RAW_B1 = '/rsstu/users/r/rrellan/sara/DNA_Sequencing_raw/BZea'
# rg_pu = the read group's PU (flowcell.lane[,flowcell.lane]). Batch 1: the tar member names carry the lane (_L00n_) but not
# the flowcell; every read header read on hazel is @A00600:293:H7HYFDSX7:<lane>:... (plates 8 L2, 10 L4, 14 L3/L4, i.e. all four lanes;
# batch-1 audit 2026-09-28, G3), one flowcell for the whole NVS188B delivery. BC1 / batch 2: empty, the pipeline derives PU
# from the Novogene lane file names (<...>_<flowcell>_L<lane>_1.fq.gz, zgPlatformUnit).
FLOWCELL_B1 = 'H7HYFDSX7'
TAXON = {'Zd': 'diploperennis', 'Zx': 'mexicana', 'Zv': 'parviglumis', 'Zl': 'luxurians', 'Zh': 'huehuetenangensis'}
WF_SOURCES = ('bc1', 'bc2s3_batch1', 'bc2s3_batch2')
COLS = ['sample_id', 'source', 'role', 'library', 'library_index', 'raw_location', 'raw_r1', 'raw_r2',
        'barcode_r1', 'barcode_r2', 'barcode_layout', 'plate', 'well', 'donor', 'taxon', 'nil_id', 'pedigree', 'is_check',
        'rg_lb', 'rg_pl', 'rg_pu',
        # identity (raw, from the sources)
        'lab_seq_id', 'delivered_name', 'accession', 'taxa_code', 'line_id', 'old_line_id', 'gen', 'F1', 'BC1', 'BC2',
        'S1', 'S2', 'S3', 'S4', 'blk', 'TC', 'j2teo_batch', 'j2teo_seed_origin', 'field', 'field_plot', 'seed_packet',
        'mother_plant', 'replicate_of', 'nil_id_in_register',
        # corrections applied (meta/corrections.csv)
        'pedigree_resolved', 'nil_id_resolved', 'donor_resolved', 'correction_ids',
        'exclude', 'exclude_reason', 'flags']
WF_COLS = COLS[:COLS.index('rg_pu') + 1]    # samples.csv keeps the workflow-1 columns (assets/schema_input.json); the rest is in registry.csv

# --- sources: SOURCES.tsv + sha256 ------------------------------------------------------------------------------------
fail, warn = [], []
listed = {}
with open(os.path.join(SRC, 'SOURCES.tsv'), newline='') as f:
    for r in csv.DictReader(f, delimiter='\t'):
        if r['file']:
            listed[r['file']] = r['sha256']          # a re-export appends a row: the last row of a file wins
for name, sha in listed.items():
    with open(os.path.join(SRC, name), 'rb') as fh:
        got = hashlib.sha256(fh.read()).hexdigest()
    if got != sha:
        sys.exit(f'[build_samples] REFUSED: sha256 of meta/sources/{name} is {got}, SOURCES.tsv says {sha}')

def src(name):
    if name not in listed: sys.exit(f'[build_samples] REFUSED: meta/sources/{name} is not listed in SOURCES.tsv')
    return os.path.join(SRC, name)

def rd(name, delim=','):
    with open(src(name), newline='') as f: return list(csv.DictReader(f, delimiter=delim))

_wb = {}
def sheet(name, tab):
    if name not in _wb: _wb[name] = Workbook(src(name))
    return _wb[name].rows(tab)

def records(rows, header_row=0):
    hdr = [h.strip() for h in rows[header_row]]; out = []
    for r in rows[header_row + 1:]:
        if not any(x.strip() for x in r): continue
        d = {}
        for h, v in zip(hdr, r):
            if h and h not in d: d[h] = v.strip()
        out.append(d)
    return out

# --- pedigree helpers and the nil_id rule (NIL_ID_README.md) -----------------------------------------------------------
def canon(x):                        # line pedigree: drop the bulk marks (.B, -blk, -bulk), as the register does
    x = (x or '').strip(); x = re.sub(r'\.B$', '', x); return re.sub(r'-(blk|bulk)$', '', x, flags=re.I).strip()

def donor_of(ped):
    # donor = <accession>_P<F1 plant> (J2Teo naming_convention). Batch C lines "use Q instead of P" and NIL_ID_README also lists _X,
    # but the convention does not say whether <acc>_Q<n> / _X<n> is its own donor or the F1 plant <acc>_P<n>: '' here, and the
    # derived-column check below fails the build for any line pedigree left without a donor (no current pedigree has _Q / _X).
    m = re.match(r'^(Z[a-z]\.\d+_P\d+)_', ped or ''); return m.group(1) if m else ''

def accession_of(ped):
    m = re.match(r'^(Z[a-z]\.\d{4})(_|$)', ped or ''); return m.group(1) if m else ''

B36 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'
PED = re.compile(r'^(Z[vxldh])\.(\d+)((?:_[A-Za-z]\d+){3})((?:\.\d+){3,})$')
def nil_id_of(ped):
    """taxon(2) + donor(4, decimal) + base36(P1 P2 P3 S1); BC2S3 and later (>= 3 selfing dots, S2.. = 1); '' otherwise."""
    m = PED.match(canon(ped))
    if not m: return ''
    P = [int(x) for x in re.findall(r'_[A-Za-z](\d+)', m.group(3))]; S = [int(x) for x in m.group(4).split('.')[1:]]
    if any(s != 1 for s in S[1:]) or max(P + S[:1]) > 35 or min(P + S[:1]) < 1: return ''
    return f'{m.group(1)}{int(m.group(2)):04d}' + ''.join(B36[v] for v in P + S[:1])

def s3_pedigree(ped):                # BC2S4 line -> its BC2S3 pedigree (the register holds BC2S3 lines)
    m = PED.match(canon(ped)); return f'{m.group(1)}.{m.group(2)}{m.group(3)}' + ''.join('.' + x for x in m.group(4).split('.')[1:4]) if m else ''

reg = rd('register_bc2s3.csv')
reg_by_ped = {r['pedigree']: r['nil_id'] for r in reg}; reg_by_nil = {r['nil_id']: r['pedigree'] for r in reg}
rule_mismatch = [(r['pedigree'], r['nil_id'], nil_id_of(r['pedigree'])) for r in reg if nil_id_of(r['pedigree']) != r['nil_id']]

# --- J2Teo_Final_DB (master pedigree database) ------------------------------------------------------------------------
J2 = 'drive/j2teo_final_db.xlsx'
j2all = records(sheet(J2, 'All'))
all_by_so = collections.defaultdict(list)
for r in j2all:
    if r.get('seed_origin'): all_by_so[r['seed_origin']].append(r)
j2bc1 = collections.defaultdict(list)
for r in records(sheet(J2, 'BC1')): j2bc1[r['line_id']].append(r)
GEN = ('gen', 'F1', 'BC1', 'BC2', 'S1', 'S2', 'S3', 'S4', 'blk', 'TC')
def j2cols(r):
    if not r: return {}
    d = {k: r.get(k, '') for k in GEN}
    d.update(line_id=r.get('line_id', ''), old_line_id=r.get('old_line_id', ''), taxa_code=r.get('taxa_code', ''),
             j2teo_batch=r.get('batch', ''), j2teo_seed_origin=r.get('seed_origin', ''))
    return d

# --- seed / crossing records -------------------------------------------------------------------------------------------
s12 = {}                                                   # RR-23-Fields Sheet12: PV23 packet -> female parent plant
for r in sheet('drive/rr_23_fields.xlsx', 'Sheet12')[1:]:
    if r[0].strip(): s12.setdefault('PV23-' + r[0].strip(), r[4].strip())
N24 = 'drive/24_ncs_psu_langebio_fields.xlsx'
pv24 = {}                                                  # PV24-block1: PV24 packet -> female parent plant
for r in sheet(N24, 'PV24-block1')[1:]:
    if r[0].strip(): pv24.setdefault('PV24-' + r[0].strip(), r[4].strip())
c8a = {}                                                   # CLY24-C8A: plot -> packet, instructions
for r in sheet(N24, 'CLY24-C8A')[1:]:
    if r[0].strip(): c8a[r[0].strip()] = (r[3].strip(), r[8].strip())

# --- corrections -------------------------------------------------------------------------------------------------------
with open(os.path.join(HERE, 'corrections.csv'), newline='') as f: corr = list(csv.DictReader(f))
corr_by_sid = collections.defaultdict(list)
for c in corr:
    if c['sample_id']: corr_by_sid[c['sample_id']].append(c)

rows = []
def base(**kw):
    d = {k: '' for k in COLS}; d.update(kw); return d

# --- BC1 pools -------------------------------------------------------------------------------------------------------
libdir = {r['pool']: r['raw_dir'] for r in rd('bc1_libraries.csv')}
bc1_miss = []
for r in rd('bc1_well_map.csv'):
    j = j2bc1.get(r['BC1_line_id'], [])
    if not j: bc1_miss.append(r['BC1_line_id'])
    d = base(sample_id=r['Sample_Id'], source='bc1', role='bc1_sample', library=r['pool'], raw_location=f"{RAW_BC1}/{libdir[r['pool']]}",
             barcode_r1=r['barcode'], barcode_r2=r['barcode'], barcode_layout='symmetric', well=r['column'], donor=r['donor'],
             taxon=r['taxon'], pedigree=r['BC1_line_id'], is_check='FALSE', rg_lb=r['pool'], rg_pl='ILLUMINA',
             delivered_name=r['BC1_line_id'], seed_packet=j[0]['seed_origin'] if len(j) == 1 else '',
             flags='' if len(j) == 1 else ('not_in_j2teo_BC1' if not j else 'j2teo_BC1_rows=%d' % len(j)))
    d.update(j2cols(j[0] if len(j) == 1 else None))
    if donor_of(r['BC1_line_id'] + '_') != r['donor']: fail.append(f"BC1 donor disagrees with line: {r['Sample_Id']}")
    rows.append(d)

# --- BC2S3 batch 2 (ZeaLV2 manifest; field CLY24-C8A) -------------------------------------------------------------------
libdir = {r['pool']: r['raw_dir'] for r in rd('bc2s3_batch2_libraries.csv')}
SEQ_PLATES = ('BZeaV2_1', 'BZeaV2_2', 'BZeaV2_3', 'BZeaV2_4')      # BZeaV2_5 was never sequenced (decision 2026-09-23)
man = [m for m in records(sheet('drive/zealv2.xlsx', 'ZeaL-V2_manifest')) if m.get('Plate_name') in SEQ_PLATES]
man.sort(key=lambda m: (m['Library_pool'], int(m['Cell_col'])))     # library order: pool (plate row), then barcode column
by_packet = collections.defaultdict(list)
for m in man:
    ped = m['Pedigree']
    if re.match(r'^Z[a-z]\.', ped): by_packet[m['Origin']].append('P' + m['Plot_id'])
for m in man:
    ped = m['Pedigree']; sid = 'P' + m['Plot_id']; fl = []
    role = 'empty' if ped in ('NA', '') else ('check' if ped in ('B73', 'NC358') else 'line')
    j = all_by_so.get(m['Origin'], []) if role == 'line' else []
    jr = j[0] if len(j) == 1 else None
    if role == 'line' and not jr: fl.append('j2teo_rows=%d' % len(j))
    if jr and canon(jr['line_id']) != canon(ped): fl.append('manifest_pedigree_differs_from_j2teo')
    pk, instr = c8a.get(m['Plot_id'], ('', ''))
    if pk != m['Origin']: fl.append('cly24_c8a_packet=' + pk)
    reps = [x for x in by_packet.get(m['Origin'], []) if x != sid] if role == 'line' else []
    if reps: fl.append('replicate_plots:' + instr)
    pedigree = canon(jr['line_id']) if jr else ('' if role == 'empty' else ped)
    d = base(sample_id=sid, source='bc2s3_batch2', role=role, library=m['Library_pool'], raw_location=f"{RAW_B2}/{libdir[m['Library_pool']]}",
             barcode_r1=m['inline_barcode'], barcode_r2=m['inline_barcode'], barcode_layout='symmetric', plate=m['Plate_name'],
             well=m['Cell'], pedigree=pedigree, is_check='TRUE' if role == 'check' else 'FALSE', rg_lb=m['Library_pool'], rg_pl='ILLUMINA',
             delivered_name=ped, field='CLY24-C8A', field_plot=m['Plot_id'], seed_packet=m['Origin'],
             mother_plant=pv24.get(m['Origin'], ''), replicate_of=';'.join(reps), flags=';'.join(fl))
    d.update(j2cols(jr)); rows.append(d)

# --- BC2S3 batch 1 (CLY2023 skim; delivery sheet + Hannah's prep sheet) -------------------------------------------------
members = collections.defaultdict(lambda: {'R1': [], 'R2': []})
with open(src('bc2s3_batch1_tar_members.tsv')) as f:
    for line in f:
        size, path = line.rstrip('\n').split('\t'); m = re.search(r'/BZea(\d+)_S\d+_L\d+_(R[12])_001\.fastq\.gz$', path)
        members[int(m.group(1))][m.group(2)].append(path)
prep = {}
for r in sheet('drive/bzea_library_prep_sheet_code.xlsx', 'Sheet1')[1:]:     # two columns are named Sample_ID: read by position
    if r[0].strip(): prep[(r[4].strip(), r[6].strip())] = dict(well=r[0].strip(), barcode=r[2].strip(), plate_index=r[5].strip(),
                                                              name=r[7].strip(), tissue=r[8].strip(), seed=r[9].strip())
slist = {r['Seq_Full_ID']: r for r in records(sheet('drive/bzea_sample_list.xlsx', 'Sample List')) if r.get('Seq_Full_ID')}
for r in rd('bc2s3_batch1_sample_sheet.csv'):
    plate = int(r['Plate_Number']); sid = f"PN{plate}_SID{r['Sample_ID']}"; g = r['Genotype']; fl = []
    p = prep.get((r['Plate_Number'], r['Sample_ID']))
    if not p or (p['well'], p['barcode'], p['plate_index']) != (r['Sample_Id'], r['Sample_Barcode'], r['Plate_barcode']):
        fail.append(f'prep sheet disagrees with the delivery sheet on well/barcode/plate index: {sid}'); p = p or {}
    excl = 'plate 1: another project (user 2026-09-24)' if plate == 1 else (
           'LANTEO*: another project (user 2026-09-24)' if g.startswith('LANTEO') else '')
    is_b73 = g.upper().startswith('B73'); is_purple = 'PURPLE' in g.upper()
    role = 'check' if (is_b73 or is_purple) else ('landrace_line' if re.search(r'_BC1S[0-9]', g) else 'line')
    jr = None
    if role != 'check':                        # well -> tissue plot -> J2Teo All; a plot with 2 rows is decided by its seed packet
        jt, js = all_by_so.get(p.get('tissue', ''), []), all_by_so.get(p.get('seed', ''), [])
        if len(jt) == 1: jr = jt[0]
        elif len(js) == 1: jr = js[0]; fl.append(f"tissue_plot_j2teo_rows={len(jt)};pedigree_from_seed_packet")
        elif jt or js: fl.append(f'j2teo_rows_tissue={len(jt)}_seed={len(js)}')
        if jr and js and len(js) == 1 and canon(js[0]['line_id']) != canon(jr['line_id']): fl.append('seed_packet_line_differs')
        if not jr and not excl: fl.append('no_j2teo_row')
    sl = slist.get(sid)
    if sl and sl.get('Sample_Origin', '') != p.get('tissue', ''): fl.append('sample_list_origin=' + sl.get('Sample_Origin', ''))
    ped = canon(jr['line_id']) if jr else g
    d = base(sample_id=sid, source='bc2s3_batch1', role=role, library=f'BZea{plate}', library_index=r['Plate_barcode'], raw_location=RAW_B1,
             raw_r1=';'.join(f'NVS188B_Rellan_Alvarez_R1.tar:{x}' for x in sorted(members[plate]['R1'])),
             raw_r2=';'.join(f'NVS188B_Rellan_Alvarez_R2.tar:{x}' for x in sorted(members[plate]['R2'])),
             barcode_r1=r['Sample_Barcode'], barcode_layout='r1_only', plate=str(plate), well=r['Sample_Id'], pedigree=ped,
             is_check='TRUE' if role == 'check' else 'FALSE', rg_lb=f'BZea{plate}', rg_pl='ILLUMINA',
             rg_pu=','.join(f'{FLOWCELL_B1}.{int(ln)}' for ln in sorted({re.search(r'_L(\d+)_R1_001\.fastq\.gz$', x).group(1) for x in members[plate]['R1']})),
             delivered_name=g,
             field='PV23', field_plot=p.get('tissue', ''), seed_packet=p.get('seed', ''), mother_plant=s12.get(p.get('seed', ''), ''),
             exclude='TRUE' if excl else 'FALSE', exclude_reason=excl, flags=';'.join(fl))
    d.update(j2cols(jr)); rows.append(d)
pn18 = sorted(k for k in slist if k.startswith('PN18_'))

# --- PV23 nursery book (23_NCS_PSU_LANGEBIO_FIELDS): check only, never a value source -----------------------------------
N23 = 'drive/23_ncs_psu_langebio_fields.xlsx'
pv23 = {r[0].strip(): r for r in sheet(N23, 'PV23-BZea')[1:] if r and r[0].strip()}   # = RR-23-Fields Sheet12 (packet -> female)
pv23_mdiff = [k for k, v in s12.items() if (pv23.get(k[5:]) or [''] * 5)[4].strip() != v]
if pv23_mdiff: fail.append(f'PV23-BZea female parent differs from RR-23-Fields Sheet12: {pv23_mdiff[:5]}')
b4 = {r[0].strip(): r for r in sheet(N23, 'PV23-block4-BZea-Bulk')[1:] if r and r[0].strip()}   # batch-1 tissue plots
b4_line_bad, b4_check_diff = [], []
for d in rows:
    if d['source'] != 'bc2s3_batch1': continue
    r = b4.get(d['field_plot'][5:])
    ok = bool(r) and r[3].strip() == d['seed_packet'] and canon(r[2]) == canon(d['delivered_name'])
    if not ok: (b4_check_diff if d['role'] == 'check' else b4_line_bad).append(d['sample_id'])
if b4_line_bad: fail.append(f'PV23-block4 plot disagrees with the prep sheet (packet or name): {b4_line_bad[:5]}')

# --- BRB-seq (summer 2023, CLY23-D4 rep 3; RNA) -------------------------------------------------------------------------
BRBP = 'drive/bzeabrb_library_prep_sheet_code.xlsx'
brb_plot = {}
for r in records(sheet('drive/bzeabrb_manifest.xlsx', 'Plate_manifest')):
    w = r.get('Well', ''); m = re.match(r'^([A-H])(\d+)$', w)
    if m: brb_plot[(r['Plate'], f'{m.group(1)}{int(m.group(2)):02d}')] = r.get('Plot', '')
with open(src('drive/bzeabrb_trimmed_read_statistics.txt')) as f:
    brb_reads = {l.split('\t')[0].strip() for l in f.read().lstrip('﻿').splitlines()[1:] if l.strip()}
for r in sheet(BRBP, 'library_prep_sheet_code')[1:]:
    seq = r[0].strip()
    # sequenced: pool BZeaRP1 (plates 1-4; the reads and counts on Drive cover only these); pools 2-4 were prepped, not sequenced
    if not seq or r[4].strip() != '1': continue
    well, bc, lib, plate, i7, i5f, g, origin = r[1].strip(), r[3].strip(), r[4].strip(), r[5].strip(), r[6].strip(), r[7].strip(), r[11].strip(), r[12].strip()
    fl = []; chk = g.upper().startswith('B73') or 'PURPLE' in g.upper()
    j = [] if chk else all_by_so.get(origin, []); jr = j[0] if len(j) == 1 else None
    if not chk and not jr: fl.append('j2teo_rows=%d' % len(j))
    if jr and canon(jr['line_id']) != canon(g): fl.append('sheet_genotype_differs_from_j2teo')
    if seq not in brb_reads: fl.append('no_trimmed_reads')
    d = base(sample_id='BRB_' + seq, source='brbseq', role='check' if chk else 'line', library=f'BZeaRP{lib}', library_index=i7,
             barcode_r1=bc, plate=plate, well=well, pedigree=canon(jr['line_id']) if jr else g, is_check='TRUE' if chk else 'FALSE',
             lab_seq_id=seq, delivered_name=g, field='CLY23-D4', field_plot=brb_plot.get((plate, well), ''), seed_packet=origin,
             mother_plant=s12.get(origin, ''), exclude='FALSE', flags=';'.join(fl))
    d.update(j2cols(jr)); rows.append(d)

# --- derived identity columns, register check, corrections ------------------------------------------------------------
reg_mis, not_in_reg = [], collections.Counter()
for d in rows:
    ped = d['pedigree']
    if d['source'] != 'bc1':
        d['donor'] = donor_of(ped); d['taxon'] = TAXON.get(d['donor'][:2], '') if d['donor'] else ''
    d['accession'] = accession_of(ped)
    d['nil_id'] = nil_id_of(ped) if d['role'] not in ('check', 'empty') else ''
    if d['nil_id']:
        rp = s3_pedigree(ped)
        if rp in reg_by_ped:
            d['nil_id_in_register'] = 'TRUE'
            if reg_by_ped[rp] != d['nil_id']: reg_mis.append((d['sample_id'], ped, d['nil_id'], reg_by_ped[rp]))
        elif d['nil_id'] in reg_by_nil:
            d['nil_id_in_register'] = 'TRUE'; reg_mis.append((d['sample_id'], ped, d['nil_id'], 'register pedigree ' + reg_by_nil[d['nil_id']]))
        else:
            d['nil_id_in_register'] = 'FALSE'; not_in_reg[d['source']] += 1
    ids = []; rped = ped
    for c in corr_by_sid.get(d['sample_id'], []):
        ids.append(c['correction_id'])
        if c['applies_to'] == 'resolved' and c['field'] == 'pedigree':
            if c['old_value'] != ped: fail.append(f"{c['correction_id']}: old_value {c['old_value']} != current pedigree {ped} of {d['sample_id']}")
            rped = c['new_value']
    d['correction_ids'] = ';'.join(ids); d['pedigree_resolved'] = rped
    d['nil_id_resolved'] = nil_id_of(rped) if d['nil_id'] or rped != ped else ''
    d['donor_resolved'] = donor_of(rped) if d['source'] != 'bc1' else d['donor']
no_donor = sorted({(k, d[k]) for d in rows for k in ('pedigree', 'pedigree_resolved')
                   if re.match(r'^Z[a-z]\.\d+_[A-Za-z]\d+_', d[k]) and not donor_of(d[k])})
if no_donor: fail.append(f'line pedigree with no donor (first selection not _P: donor undefined by the J2Teo naming_convention): {no_donor[:5]}')
unknown = [c['sample_id'] for c in corr if c['sample_id'] and c['sample_id'] not in {d['sample_id'] for d in rows}]
if unknown: fail.append(f'corrections for unknown sample_id: {unknown}')

# --- comparison with the superseded derived tables --------------------------------------------------------------------
by_id = {d['sample_id']: d for d in rows}
skim = {r['sample']: r for r in rd('bc2s3_batch1_skim_nil_id.tsv', '\t')}
skim_cmp = collections.Counter(); skim_diff = []
for k, s in skim.items():
    d = by_id.get(k)
    if not d: skim_cmp['not in registry'] += 1; continue
    nil = '' if s['nil_id'] == 'B73_check' else s['nil_id']
    if nil == d['nil_id'] and canon(s['pedigree']) == canon(d['pedigree']): skim_cmp['same'] += 1
    else: skim_cmp['differs'] += 1; skim_diff.append((k, s['pedigree'], s['nil_id'], d['pedigree'], d['nil_id']))
wm2 = {r['Sample_Id']: r for r in rd('bc2s3_batch2_well_map.csv')}
b2 = [d for d in rows if d['source'] == 'bc2s3_batch2']
if {d['sample_id'] for d in b2} != set(wm2): fail.append('batch-2 sample_ids differ from bc2s3_batch2_well_map.csv')
wm_diff = [(d['sample_id'], wm2[d['sample_id']]['nil_id'], d['nil_id']) for d in b2 if d['sample_id'] in wm2 and
           (wm2[d['sample_id']]['pool'], wm2[d['sample_id']]['barcode']) != (d['library'], d['barcode_r1'])]
if wm_diff: fail.append(f'batch-2 pool/barcode differ from the well map: {wm_diff[:5]}')
wm_nil = [(d['sample_id'], wm2[d['sample_id']]['nil_id'], d['nil_id']) for d in b2 if d['sample_id'] in wm2 and
          (wm2[d['sample_id']]['nil_id'] if wm2[d['sample_id']]['nil_id'] != 'NA' else '') != d['nil_id']]

# --- accessions (J2Teo metadata; longitude corrections) ---------------------------------------------------------------
acc_rows = records(sheet(J2, 'metadata'))
lon_fix = {c['entity']: c for c in corr if c['field'] == 'accession.longitude' and c['applies_to'] == 'resolved'}
ACOLS = ['accession', 'location', 'collection_date', 'old_accession_id_1', 'old_accession_id_2', 'teo_plot', 'race', 'taxa_code',
         'species', 'elevation', 'latitude', 'longitude', 'longitude_resolved', 'country', 'state', 'county', 'correction_ids']
accs = []
for r in acc_rows:
    a = r.get('accession-id', '')
    if not a: continue
    c = lon_fix.get(a)
    if c and c['old_value'] != r.get('longitude', ''): fail.append(f"{c['correction_id']}: old longitude {c['old_value']} != {r.get('longitude')}")
    accs.append(dict(accession=a, location=r.get('location', ''), collection_date=r.get('collection_date', ''),
                     old_accession_id_1=r.get('old-accession-id-1', ''), old_accession_id_2=r.get('old-accession-id-2', ''),
                     teo_plot=r.get('teo_plot', ''), race=r.get('race', ''), taxa_code=r.get('taxa_code', ''), species=r.get('species', ''),
                     elevation=r.get('elevation', ''), latitude=r.get('latitude', ''), longitude=r.get('longitude', ''),
                     longitude_resolved=c['new_value'] if c else r.get('longitude', ''), country=r.get('country', ''),
                     state=r.get('state', ''), county=r.get('county', ''), correction_ids=c['correction_id'] if c else ''))
acc_set = {a['accession'] for a in accs}
acc_missing = sorted({d['accession'] for d in rows if d['accession'] and d['accession'] not in acc_set})

# --- validation (workflow-1 sheet) -------------------------------------------------------------------------------------
ids = collections.Counter(d['sample_id'] for d in rows)
dups = [k for k, v in ids.items() if v > 1]
if dups: fail.append(f'duplicate sample_id: {dups[:5]}')
wf = [d for d in rows if d['source'] in WF_SOURCES and d['exclude'] != 'TRUE']
c = collections.Counter((d['library'], d['barcode_r1'], d['barcode_r2']) for d in wf)
bad = [k for k, v in c.items() if v > 1]
if bad: fail.append(f'duplicate barcode within library: {bad[:5]}')
for k in ('source', 'barcode_layout', 'raw_location', 'raw_r1', 'raw_r2', 'rg_pu'):
    per_lib = collections.defaultdict(set)
    for d in wf: per_lib[d['library']].add(d[k])
    bad = sorted(lib for lib, v in per_lib.items() if len(v) > 1)
    if bad: fail.append(f'samples of a library disagree on {k}: {bad[:5]}')
for d in wf:
    if not d['raw_location'] or not d['barcode_r1']: fail.append(f"missing raw location or barcode: {d['sample_id']}")
    if d['source'] == 'bc2s3_batch1' and (not d['raw_r1'] or not d['raw_r2']): fail.append(f"no tar members: {d['sample_id']}")

# --- write / check -----------------------------------------------------------------------------------------------------
def render(cols, recs):
    b = io.StringIO(); w = csv.DictWriter(b, fieldnames=cols, lineterminator='\r\n'); w.writeheader(); w.writerows(recs); return b.getvalue()
outs = {'registry.csv': render(COLS, rows), 'samples.csv': render(WF_COLS, [{k: d[k] for k in WF_COLS} for d in wf]),
        'accessions.csv': render(ACOLS, accs)}
if CHECK:
    diff = []
    for name, text in outs.items():
        p = os.path.join(HERE, name)
        old = open(p, newline='').read() if os.path.exists(p) else None
        if old != text: diff.append(name)
    if diff or fail:
        print(f'[build_samples --check] FAILED: rebuilt tables differ from the committed ones: {diff}' if diff else '', *fail[:10], sep='\n  ')
        sys.exit(1)
    print(f'[build_samples --check] {len(listed)} sources verified; registry.csv, samples.csv, accessions.csv reproduce exactly'); sys.exit(0)

print(f'[build_samples] {len(listed)} sources verified (sha256); {len(rows)} registry rows -> meta/registry.csv, '
      f'{len(wf)} -> meta/samples.csv, {len(accs)} accessions -> meta/accessions.csv')
for (s, r, e), n in sorted(collections.Counter((d['source'], d['role'], d['exclude'] or 'FALSE') for d in rows).items()):
    print(f'  {s:14s} {r:14s} exclude={e:5s} {n}')
print(f'  nil_id rule vs register: {len(reg) - len(rule_mismatch)}/{len(reg)} register rows reproduce; mismatches {rule_mismatch[:5]}')
print(f'  registry nil_ids vs register: {len(reg_mis)} mismatches {reg_mis[:5]}; not in register: {dict(not_in_reg)}')
print(f'  corrections: {len(corr)} ({collections.Counter(c["applies_to"] for c in corr)}); resolved pedigree differs for',
      [d['sample_id'] for d in rows if d['pedigree_resolved'] != d['pedigree']])
print(f"  BC1 lines not in J2Teo BC1 tab: {len(bc1_miss)} {bc1_miss[:6]}")
fc = collections.Counter(x.split('=')[0].split(':')[0] for d in rows for x in d['flags'].split(';') if x and d['exclude'] != 'TRUE')
print(f'  flags (non-excluded rows): {dict(fc)}')
print(f'  batch-1 vs superseded skim map: {dict(skim_cmp)}; differing: {skim_diff[:6]}')
print(f'  batch-2 nil_id vs superseded well map: {len(wm_nil)} differ {wm_nil[:6]}')
print(f'  replicate plots (batch 2): {sorted({tuple(sorted([d["sample_id"]] + d["replicate_of"].split(";"))) for d in b2 if d["replicate_of"]})}')
print(f'  PV23 nursery book: PV23-BZea = Sheet12 female parent for {len(s12) - len(pv23_mdiff)}/{len(s12)} packets; '
      f'PV23-block4 plot -> packet + name = prep sheet for all batch-1 lines, differs for {len(b4_check_diff)} checks {b4_check_diff[:4]}; '
      f'block4 PV23-8396 = {(b4.get("8396") or ["", "", ""])[2]!r}')
print(f'  PN18 wells in the Sample List (plated, no sequencing record, not in the registry): {len(pn18)}')
print(f'  accessions used by samples but missing from J2Teo metadata: {acc_missing}')
if fail:
    print('[build_samples] FAILED (nothing written):'); [print('  ' + x) for x in fail[:20]]; sys.exit(1)
# write only after every check passed: each table goes to a temp file first, then all are renamed into place
tmp = {name: os.path.join(HERE, f'.{name}.tmp') for name in outs}
for name, text in outs.items():
    with open(tmp[name], 'w', newline='') as f: f.write(text)
for name in outs: os.replace(tmp[name], os.path.join(HERE, name))
print('[build_samples] all checks passed; tables written')
