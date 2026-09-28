#!/usr/bin/env python3
"""Build meta/genotype_dev.csv, the genotype sample sheet of the development CRAMs (--genotype_input, assets/schema_genotype.json).

Source: meta/dev_import.csv (all 96 rows, `include` kept as is: PN6_SID484 and PN8_SID736 are FALSE). After the CRAM workflow's
--entry markdup_import every included row lives flat in <cram_store>/cram_import/ (MARKDUP_IMPORT writes a CRAM also for the BAM
input B73_skim10), so every row gets store_dir = cram_import.

Read-start masks (mask_r1 / mask_r2 = 5' cycles set to Q0 by MASK_READ_STARTS; genotype design Decision 6 and §10 item 8). They
are INFERRED for these imports, not recorded by the pipeline that made them:
  bc2s3_batch1 lines   12 / 0  zealbc1 demux (sabre) cut the 8-bp barcode from both reads, so R1 still starts with the 12-nt
                               random primer (PROVENANCE.md "Batch-1 processing history", read structure 8B12S+T 8S+T); the
                               alt-by-read-position test (agent/20260928_163000_alt_by_read_position.md) shows R1 cycles 1-12
                               with errors up to 20 %.
  bc1 pools             2 /  2  zealbc1 demux removed only the 6-bp barcode, so both mates carry the 2-bp CT junction
                               (PROVENANCE.md "BC1 / batch 2 = FlexPrep UHT"; read structure 6B2S+T); cycles 1-2 45 % "other".
  B73_skim10           12 /  0  merge of 10 batch-1 B73 checks (made like the batch-1 lines).
  B73_ERR3288215        0 /  0  SRA reads, no inline barcode or randomer.
  (CRAMs demultiplexed by zealgt are cropped at demux and carry 0 / 0; they are not in this sheet.)
Biology from the registry (meta/PROVENANCE.md "Identifiers: one physical key, biology in the registry"): donor, role and taxon
come from meta/samples.csv joined on sample_id; dev_import.csv supplies only the import fields (source, include; masks by
source). Documented exception: the two B73 controls (B73_ERR3288215, B73_skim10) have no registry row; they keep role
b73_control from dev_import.csv and no donor / taxon. Any other row missing from the registry is refused.

Usage: python3 meta/build_genotype_sheet.py   (writes meta/genotype_dev.csv; exits 1 on a failed check)"""
import csv, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, 'dev_import.csv')
REGISTRY = os.path.join(HERE, 'samples.csv')
OUT = os.path.join(HERE, 'genotype_dev.csv')
ROLES = {'bc1_sample', 'line', 'b73_control'}
COLS = ['sample_id', 'role', 'donor', 'taxon', 'source', 'store_dir', 'mask_r1', 'mask_r2', 'include', 'mask_source']
MASK_BY_SOURCE = {
    'bc2s3_batch1': (12, 0, 'inferred: batch-1 R1 12-nt random primer left by zealbc1 demux'),
    'bc1': (2, 2, 'inferred: BC1 2-bp CT junction left by zealbc1 demux'),
}
MASK_BY_SAMPLE = {
    'B73_skim10': (12, 0, 'inferred: merge of 10 batch-1 B73 checks'),
    'B73_ERR3288215': (0, 0, 'SRA reads, no inline barcode or randomer'),
}
ID_RE = re.compile(r'^[A-Za-z0-9_-]+$')  # no dots: CRISP --sm 0 names a pool by the file basename cut at the first '.'


def build():
    with open(SRC, newline='') as f:
        rows = list(csv.DictReader(f))
    with open(REGISTRY, newline='') as f:
        registry = {g['sample_id']: g for g in csv.DictReader(f)}
    errors, out, seen = [], [], set()
    for r in rows:
        sid = r['sample_id']
        reg = registry.get(sid)
        if reg is not None:
            role, donor, taxon = reg['role'], reg['donor'], reg['taxon']
        elif r['role'] == 'b73_control':
            role, donor, taxon = 'b73_control', '', ''
        else:
            errors.append(f'{sid}: not in the registry {REGISTRY} (only the B73 controls may be missing)')
            continue
        if not ID_RE.match(sid):
            errors.append(f'{sid}: sample_id must match {ID_RE.pattern}')
        if sid in seen:
            errors.append(f'{sid}: duplicate sample_id')
        seen.add(sid)
        if role not in ROLES:
            errors.append(f'{sid}: role {role!r} not in {sorted(ROLES)}')
        if role != 'b73_control' and not donor:
            errors.append(f'{sid}: role {role} needs a donor')
        if sid in MASK_BY_SAMPLE:
            m1, m2, why = MASK_BY_SAMPLE[sid]
        elif r['source'] in MASK_BY_SOURCE:
            m1, m2, why = MASK_BY_SOURCE[r['source']]
        else:
            errors.append(f'{sid}: no read-start mask rule for source {r["source"]!r}')
            continue
        if donor and not taxon:
            errors.append(f'{sid}: registry has no taxon for donor {donor}')
        include = r['include'].strip().upper()
        if include not in ('TRUE', 'FALSE'):
            errors.append(f'{sid}: include {r["include"]!r} is not TRUE/FALSE')
        out.append({'sample_id': sid, 'role': role, 'donor': donor, 'taxon': taxon, 'source': r['source'],
                    'store_dir': 'cram_import', 'mask_r1': m1, 'mask_r2': m2, 'include': include, 'mask_source': why})
    return rows, out, errors


def main():
    rows, out, errors = build()
    if len(out) != len(rows):
        errors.append(f'{len(rows)} input rows but {len(out)} output rows')
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    with open(OUT, 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=COLS, lineterminator='\n')
        w.writeheader()
        w.writerows(out)
    inc = [o for o in out if o['include'] == 'TRUE']
    by = {}
    for o in inc:
        key = (o['donor'] or '-', o['role'])
        by[key] = by.get(key, 0) + 1
    print(f'wrote {OUT}: {len(out)} rows, {len(inc)} included')
    for (donor, role), n in sorted(by.items()):
        print(f'  {donor:12s} {role:12s} {n}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
