"""Minimal read-only .xlsx reader (Python standard library only), used by meta/build_samples.py.

Reads the cell values of one worksheet as a list of rows (lists of strings), exactly as stored: shared and inline strings as text,
numbers as their stored text ("12" or "12.5"; integral floats like "12.0" are shown as "12"), booleans as TRUE/FALSE, formulas as
their cached value. No styles, no date conversion (identifier columns are text or integers). Empty cells are "".
"""
import re, zipfile, xml.etree.ElementTree as ET

NS = {'m': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main',
      'r': 'http://schemas.openxmlformats.org/officeDocument/2006/relationships',
      'p': 'http://schemas.openxmlformats.org/package/2006/relationships'}
_RID = '{%s}id' % NS['r']


def _col_index(ref):
    n = 0
    for ch in re.match(r'[A-Z]+', ref).group(0):
        n = n * 26 + ord(ch) - 64
    return n - 1


def _text(si):
    # a shared/inline string: its <t>, or the concatenated <t> of its rich-text runs <r> (phonetic runs <rPh> excluded)
    t = si.find('m:t', NS)
    if t is not None:
        return t.text or ''
    return ''.join((r.find('m:t', NS).text or '') for r in si.findall('m:r', NS) if r.find('m:t', NS) is not None)


class Workbook:
    def __init__(self, path):
        self.path = path
        self.z = zipfile.ZipFile(path)
        wb = ET.fromstring(self.z.read('xl/workbook.xml'))
        rels = ET.fromstring(self.z.read('xl/_rels/workbook.xml.rels'))
        target = {r.get('Id'): r.get('Target') for r in rels.findall('p:Relationship', NS)}
        self.sheets = {}
        for s in wb.find('m:sheets', NS).findall('m:sheet', NS):
            t = target[s.get(_RID)].lstrip('/')
            self.sheets[s.get('name')] = t if t.startswith('xl/') else 'xl/' + t
        self.shared = []
        if 'xl/sharedStrings.xml' in self.z.namelist():
            sst = ET.fromstring(self.z.read('xl/sharedStrings.xml'))
            self.shared = [_text(si) for si in sst.findall('m:si', NS)]

    def rows(self, sheet):
        """All rows of `sheet` as lists of strings (ragged rows padded to the widest row)."""
        root = ET.fromstring(self.z.read(self.sheets[sheet]))
        out = {}
        width = 0
        for row in root.iter('{%s}row' % NS['m']):
            vals = {}
            for c in row.findall('m:c', NS):
                ref, t = c.get('r'), c.get('t')
                v = c.find('m:v', NS)
                if t == 's':
                    val = self.shared[int(v.text)] if v is not None else ''
                elif t == 'inlineStr':
                    is_ = c.find('m:is', NS)
                    val = _text(is_) if is_ is not None else ''
                elif t == 'b':
                    val = 'TRUE' if v is not None and v.text == '1' else 'FALSE'
                else:
                    val = v.text if v is not None and v.text is not None else ''
                    if t not in ('str', 'e') and re.fullmatch(r'-?\d+\.0+', val):
                        val = val.split('.')[0]
                vals[_col_index(ref)] = val
            if vals:
                width = max(width, max(vals) + 1)
            out[int(row.get('r')) - 1] = vals
        n = (max(out) + 1) if out else 0
        return [[out.get(i, {}).get(j, '') for j in range(width)] for i in range(n)]

    def records(self, sheet, header_row=0):
        """Rows after `header_row` as dicts keyed by the header (first occurrence wins for repeated names)."""
        rows = self.rows(sheet)
        hdr = [h.strip() for h in rows[header_row]]
        recs = []
        for r in rows[header_row + 1:]:
            if not any(x.strip() for x in r):
                continue
            d = {}
            for h, v in zip(hdr, r):
                if h and h not in d:
                    d[h] = v.strip()
            recs.append(d)
        return hdr, recs
