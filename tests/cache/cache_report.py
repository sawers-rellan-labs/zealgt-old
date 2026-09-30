#!/usr/bin/env python3
"""scripts/test_cache.sh report: assertions from the traces + hash evidence from the -dump-hashes json dumps.

    python3 tests/cache/cache_report.py <scratch dir>        (writes <scratch dir>/summary.txt; exit 1 on a failed assertion)

Inputs (made by scripts/test_cache.sh): traces/{r1,preflight,r2,r3,r4}.txt (tab trace: task_id,hash,process,tag,name,
status,exit,attempt,cpus,memory,time,queue), logs/<run>.nextflow.log (dumps: "[<process> (<n>)] cache hash: <h>; mode:
<m>; entries: [json]"), logs/<run>.exit.

A dump carries the task index, not the tag, and its cache hash is not the work-dir hash of the trace, so tasks are
matched across runs by (process, meta.id): meta is the first input of every zealgt process. Dump entries are labelled:
0 session, 1 process name, 2 script source, then (input name, value) pairs, `$` (stub flag), `eval_outputs`, a conda
prefix (a String starting with '/'), and the task.ext entry set.
Python >= 3.6 (hazel's /usr/bin/python3 is 3.9).
"""
import difflib
import json
import os
import re
import sys

STAGE1 = ['DEMUX', 'MERGE_LANES', 'DEMUX_QC', 'CUTADAPT', 'FASTQC']
RUNS = ['r1', 'r2', 'r3']
DUMP_RE = re.compile(r'TaskHasher - \[(.+?) \((\d+)\)\] cache hash: ([0-9a-f]+); mode: (\w+); entries: (\[\n.*?\n\])\n', re.S)
ID_RE = re.compile(r'\bid:([^,\]]+)')

S = os.path.abspath(sys.argv[1])
out_lines = []
failures = []


def out(line=''):
    out_lines.append(line)
    print(line)


def check(ok, what):
    out(('PASS  ' if ok else 'FAIL  ') + what)
    if not ok:
        failures.append(what)
    return ok


def short(process):
    return process.split(':')[-1]


def read_trace(run):
    path = os.path.join(S, 'traces', run + '.txt')
    if not os.path.exists(path):
        return None
    rows = []
    with open(path) as fh:
        header = fh.readline().rstrip('\n').split('\t')
        for line in fh:
            f = dict(zip(header, line.rstrip('\n').split('\t')))
            f['proc'] = short(f['process'])
            rows.append(f)
    return rows


def run_exit(run):
    path = os.path.join(S, 'logs', run + '.exit')
    return open(path).read().strip() if os.path.exists(path) else 'not run'


def run_name(run):
    path = os.path.join(S, 'logs', run + '.nextflow.log')
    if not os.path.exists(path):
        return None
    m = re.search(r'Session - Run name: (\S+)', open(path).read())
    return m.group(1) if m else None


def label_entries(entries):
    labelled = [('session', entries[0]), ('process', entries[1]), ('script', entries[2])]
    i = 3
    while i < len(entries):
        e = entries[i]
        if e['type'] == 'java.lang.String' and e['value'].startswith('/'):
            labelled.append(('conda/env', e))
            i += 1
        elif e['type'] == 'java.lang.String' and i + 1 < len(entries):
            labelled.append(('input ' + e['value'] if e['value'] not in ('$', 'eval_outputs') else e['value'], entries[i + 1]))
            i += 2
        else:
            labelled.append(('task.ext' if 'EntrySet' in e['type'] else e['type'], e))
            i += 1
    return labelled


def read_dumps(run):
    path = os.path.join(S, 'logs', run + '.nextflow.log')
    dumps = {}
    if not os.path.exists(path):
        return dumps
    for m in DUMP_RE.finditer(open(path).read()):
        entries = label_entries(json.loads(m.group(5)))
        meta = dict(entries).get('input meta')
        mid = ID_RE.search(meta['value']).group(1) if meta and ID_RE.search(meta['value']) else '#' + m.group(2)
        key = (short(m.group(1)), mid)
        if key in dumps:
            out('note  %s: second dump for %s %s (kept the first)' % (run, key[0], key[1]))
            continue
        dumps[key] = {'hash': m.group(3), 'entries': entries}
    return dumps


def diff_components(a, b):
    """labels of the entries that differ between two dumps (by position and label)"""
    changed = []
    la, lb = a['entries'], b['entries']
    for i in range(max(len(la), len(lb))):
        ea = la[i] if i < len(la) else (None, None)
        eb = lb[i] if i < len(lb) else (None, None)
        if ea[0] != eb[0] or ea[1] is None or eb[1] is None or ea[1]['hash'] != eb[1]['hash']:
            changed.append((eb[0] or ea[0], ea[1], eb[1]))
    return changed


def to_mb(s):
    m = re.match(r'([\d.]+)\s*([KMGT]?B)', s or '')
    if not m:
        return None
    return float(m.group(1)) * {'B': 1.0 / 2 ** 20, 'KB': 1.0 / 1024, 'MB': 1, 'GB': 1024, 'TB': 2 ** 20}[m.group(2)]


def to_min(s):
    parts = re.findall(r'([\d.]+)(ms|s|m|h|d)', s or '')
    if not parts:
        return None
    return sum(float(v) * {'ms': 1 / 60000.0, 's': 1 / 60.0, 'm': 1, 'h': 60, 'd': 1440}[u] for v, u in parts)


traces = {r: read_trace(r) for r in ['r1', 'preflight', 'r2', 'r3', 'r4']}
dumps = {r: read_dumps(r) for r in RUNS}
names = {r: run_name(r) for r in ['r1', 'r2', 'r3', 'r4']}

out('test_cache summary: %s' % S)
for r in ['r1', 'preflight', 'r2', 'r3', 'r4']:
    t = traces[r]
    out('  %-9s exit %-7s run name %-22s tasks %s' % (r, run_exit(r), names.get(r) or '-', len(t) if t is not None else '-'))
out()

# ---- status per process per run
procs = []
for r in ['r1', 'r2', 'r3', 'r4']:
    for row in traces[r] or []:
        if row['proc'] not in procs:
            procs.append(row['proc'])
out('Status per process (trace): C = CACHED, X = executed (COMPLETED), F = other')
out('  %-26s %-10s %-10s %-10s %-10s' % ('process', 'R1', 'R2', 'R3', 'R4'))
for p in procs:
    cells = []
    for r in ['r1', 'r2', 'r3', 'r4']:
        rows = [x for x in traces[r] or [] if x['proc'] == p]
        c = sum(x['status'] == 'CACHED' for x in rows)
        x_ = sum(x['status'] == 'COMPLETED' for x in rows)
        f = len(rows) - c - x_
        cells.append(('%dC %dX' % (c, x_) + (' %dF' % f if f else '')) if rows else '-')
    out('  %-26s %-10s %-10s %-10s %-10s' % tuple([p] + cells))
out()


def tasks(run, pred=lambda row: True):
    return [x for x in traces[run] or [] if pred(x)]


# ---- R1
out('R1  chained read_demultiplexing (baseline, -dump-hashes json)')
r1 = traces['r1'] or []
check(run_exit('r1') == '0' and bool(r1), 'R1 finished (exit 0) with %d tasks' % len(r1))
check(all(x['status'] == 'COMPLETED' for x in r1), 'R1: every task executed (COMPLETED)')
missing = [p for p in STAGE1 + ['ALIGN_MARKDUP'] if not tasks('r1', lambda x, p=p: x['proc'] == p)]
check(not missing, 'R1: ran every stage-1 process and ALIGN_MARKDUP' + (' (missing %s)' % missing if missing else ''))
n_align = len(tasks('r1', lambda x: x['proc'] == 'ALIGN_MARKDUP'))
n_stage1 = len(tasks('r1', lambda x: x['proc'] in STAGE1))
out()

# ---- preflight: are R2's resources really higher for every process?
out('Preflight  -stub run with R2 profiles + raise config: resources R2 requests vs R1 (per process: R1 max -> R2 min)')
pf = traces['preflight'] or []
check(run_exit('preflight') == '0' and bool(pf), 'preflight finished (exit 0) with %d tasks' % len(pf))
for p in [q for q in procs if tasks('r1', lambda x, q=q: x['proc'] == q)]:
    a = tasks('r1', lambda x, p=p: x['proc'] == p)
    b = [x for x in pf if x['proc'] == p]
    if not b:
        check(False, 'preflight: %s did not run' % p)
        continue
    parts, ok = [], True
    for field, conv in (('cpus', float), ('memory', to_mb), ('time', to_min)):
        va = [conv(x[field]) for x in a]
        vb = [conv(x[field]) for x in b]
        good = None not in va and None not in vb and min(vb) > max(va)
        ok = ok and good
        parts.append('%s %s -> %s' % (field, max(a, key=lambda x: conv(x[field]) or 0)[field],
                                      min(b, key=lambda x: conv(x[field]) or 0)[field]))
    check(ok, 'raised  %-26s %s' % (p, ', '.join(parts)))
out()

# ---- R2
out('R2  -resume <R1 session> + raised cpus/memory/time for every process -> every task CACHED')
r2 = traces['r2'] or []
check(run_exit('r2') == '0', 'R2 finished (exit 0)')
k1 = sorted((x['proc'], x['tag']) for x in r1)
k2 = sorted((x['proc'], x['tag']) for x in r2)
check(k1 == k2, 'R2: the same %d tasks as R1 (process, tag)' % len(k1))
# strict: no exception (the provenance record no longer carries the run name, so nothing may differ per launch)
for x in r2:
    if x['status'] == 'CACHED':
        continue
    key = (x['proc'], x['tag'])
    a, b = dumps['r1'].get(key), dumps['r2'].get(key)
    comps = [c[0] for c in diff_components(a, b)] if a and b else 'no hash dump'
    check(False, 'R2: %s %s re-executed; changed hash components %s' % (key[0], key[1], comps))
n_cached = sum(x['status'] == 'CACHED' for x in r2)
check(n_cached == len(r2) and len(r2) > 0, 'R2: every task CACHED (%d of %d)' % (n_cached, len(r2)))
for p in STAGE1 + ['ALIGN_MARKDUP', 'SAMTOOLS_STATS', 'PICARD_COLLECTWGSMETRICS']:
    rows = tasks('r2', lambda x, p=p: x['proc'] == p)
    if rows:
        check(all(x['status'] == 'CACHED' for x in rows), 'R2: every %s task CACHED (%d)' % (p, len(rows)))
out()

# ---- R3
out('R3  -resume <R1 session> after an edit of ALIGN_MARKDUP script: (clone), fresh store')
check(run_exit('r3') == '0', 'R3 finished (exit 0)')
s1 = tasks('r3', lambda x: x['proc'] in STAGE1)
check(len(s1) == n_stage1 and all(x['status'] == 'CACHED' for x in s1),
      'R3: every stage-1 task CACHED (%d of %d; %s)' % (sum(x['status'] == 'CACHED' for x in s1), n_stage1, ', '.join(STAGE1)))
al = tasks('r3', lambda x: x['proc'] == 'ALIGN_MARKDUP')
check(len(al) == n_align and all(x['status'] == 'COMPLETED' for x in al),
      'R3: every ALIGN_MARKDUP task re-executed (%d of %d COMPLETED)' % (sum(x['status'] == 'COMPLETED' for x in al), n_align))
align_diffs = {}
for key in sorted(k for k in dumps['r3'] if k[0] == 'ALIGN_MARKDUP'):
    a, b = dumps['r1'].get(key), dumps['r3'][key]
    if a:
        align_diffs[key] = diff_components(a, b)
check(len(align_diffs) == n_align and all([c[0] for c in d] == ['script'] for d in align_diffs.values()),
      'R3: for every ALIGN_MARKDUP task the only changed hash component is the script source (%d dumps compared)' % len(align_diffs))
out()

# ---- R4
out('R4  --entry read_alignment on R1 FASTQ checkpoint, fresh store, new session -> only stage-2 tasks')
r4 = traces['r4'] or []
check(run_exit('r4') == '0' and bool(r4), 'R4 finished (exit 0) with %d tasks' % len(r4))
bad = sorted(set(x['proc'] for x in r4 if x['proc'] in STAGE1))
check(not bad, 'R4: no stage-1 task' + (' (found %s)' % bad if bad else ''))
al4 = tasks('r4', lambda x: x['proc'] == 'ALIGN_MARKDUP')
check(len(al4) == n_align and all(x['status'] == 'COMPLETED' for x in al4),
      'R4: every ALIGN_MARKDUP task executed from the checkpoint (%d of %d)' % (len(al4), n_align))
out()

# ---- hash evidence
out('Hash evidence: cache hash (first 8 hex) per task in R1 / R2 / R3 (= same as R1), and the changed components')
out('  %-26s %-24s %-9s %-9s %-9s %s' % ('process', 'task (meta.id)', 'R1', 'R2', 'R3', 'changed vs R1'))
keys = []
for r in RUNS:
    for k in dumps[r]:
        if k not in keys:
            keys.append(k)
order = {p: i for i, p in enumerate(procs)}
for key in sorted(keys, key=lambda k: (order.get(k[0], 99), k[1])):
    h = [dumps[r].get(key) for r in RUNS]
    cells = [h[0]['hash'][:8] if h[0] else '-']
    notes = []
    for i, r in enumerate(RUNS[1:], 1):
        if not h[i]:
            cells.append('-')
        elif h[0] and h[i]['hash'] == h[0]['hash']:
            cells.append('=')
        else:
            cells.append(h[i]['hash'][:8])
            if h[0]:
                notes.append('%s: %s' % (r.upper(), ','.join(c[0] for c in diff_components(h[0], h[i]))))
    out('  %-26s %-24s %-9s %-9s %-9s %s' % (key[0], key[1][:24], cells[0], cells[1], cells[2], '; '.join(notes)))
out()
if align_diffs:
    key = sorted(align_diffs)[0]
    out('ALIGN_MARKDUP %s, R1 -> R3: changed hash components' % key[1])
    for label, ea, eb in align_diffs[key]:
        out('  %-12s entry hash %s -> %s' % (label, ea['hash'] if ea else '-', eb['hash'] if eb else '-'))
        if label == 'script' and ea and eb:
            for line in difflib.unified_diff(ea['value'].splitlines(), eb['value'].splitlines(), 'R1 script', 'R3 script', n=0, lineterm=''):
                out('    ' + line)
    out()

out('RESULT: %s' % ('PASSED' if not failures else 'FAILED: %d assertion(s), the FAIL lines above' % len(failures)))
with open(os.path.join(S, 'summary.txt'), 'w') as fh:
    fh.write('\n'.join(out_lines) + '\n')
sys.exit(1 if failures else 0)
