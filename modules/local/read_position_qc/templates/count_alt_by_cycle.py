#!/usr/bin/env python3
"""REF / ALT / other bases at known sites by read cycle, one role group of samples (READ_POSITION_QC, stage 8; design §2.7).
The standing form of the 5'-bias check agent/20260928_163000_alt_by_read_position.md (array 969611): after MASK_READ_STARTS
the masked cycles (Q0) drop out, so running it on the raw CRAMs (label raw) and on the masked BAMs (label masked) shows the
mask's effect and the residue it cannot remove (the aligner's end-clipping reference bias).

Nextflow module template (modules/local/read_position_qc/main.nf): no backslashes or dollar signs outside the placeholders;
tab / newline are chr(9) / chr(10). Every placeholder is read inside main(), so the functions are importable by the unit
tests (tests/test_count_alt_by_cycle.py). Standard library only; samtools is run as a subprocess.

Per sample: `samtools view <ext.args> --reference <fasta> -M -L <sites in the region>.bed <aln>` (ext.args default
`-q 20 -F 0xF04`), then for every aligned base at a site with base quality >= --min-bq (20): the cycle = 1-based position in
the read from its 5' end in sequencing orientation (reverse reads flipped), counting soft- and hard-clipped bases; class REF,
ALT (the site's alleles) or other; deletions at the site are not observed. Overlapping mates are counted twice (as the note).
Output <prefix>.read_position_qc.tsv: label sample mate cycle_bin n ref alt other alt_frac other_frac alt_ref_alt, per sample
and for ALL samples, over --bins (default 1-2,3-4,5-8,9-12,13-20,21-40,41-80,81-). Samples run in parallel (ZG_CPUS).
Versions (samtools, python) go into <prefix>.read_position_qc.versions.yml (no `eval` outputs for a python script).
"""
import argparse
import json
import multiprocessing
import os
import platform
import shlex
import subprocess
import sys

TAB = chr(9)
NL = chr(10)
NA = "NA"
DEFAULT_BINS = "1-2,3-4,5-8,9-12,13-20,21-40,41-80,81-"


def log(msg):
    sys.stderr.write("[read_position_qc] " + msg + NL)


def parse_args(argv):
    ap = argparse.ArgumentParser(prog="count_alt_by_cycle.py")
    ap.add_argument("--min-bq", type=int, default=20)
    ap.add_argument("--bins", default=DEFAULT_BINS)
    return ap.parse_args(argv)


def parse_bins(s):
    out = []
    for b in s.split(","):
        lo, hi = b.split("-")
        out.append((int(lo), int(hi) if hi else None, b))
    return out


def bin_of(cycle, bins):
    for lo, hi, name in bins:
        if cycle >= lo and (hi is None or cycle <= hi):
            return name
    return None


def parse_region(region):
    if ":" not in region:
        return region, 1, None
    chrom, span = region.rsplit(":", 1)
    s, e = span.replace(",", "").split("-")
    return chrom, int(s), int(e)


def read_sites(path, region):
    """{pos: (ref, alt)} of the biallelic SNV sites on the region (chrom pos ref alt; a header line is skipped)."""
    chrom, s, e = parse_region(region)
    out = {}
    with open(path) as fh:
        for line in fh:
            x = line.rstrip(NL).split(TAB)
            if len(x) < 4 or not x[1].isdigit():
                continue
            p = int(x[1])
            if x[0] == chrom and p >= s and (e is None or p <= e) and len(x[2]) == 1 and len(x[3]) == 1:
                out[p] = (x[2], x[3])
    return chrom, out


def parse_cigar(cig):
    ops, num = [], ""
    for ch in cig:
        if ch.isdigit():
            num += ch
        else:
            ops.append((int(num), ch))
            num = ""
    return ops


def record_bases(flag, start, cigar, seq, qual, sites, min_bq):
    """[(mate, cycle, class)] of one SAM record at the sites; class 1 = REF, 2 = ALT, 3 = other."""
    if cigar == "*" or seq == "*":
        return []
    ops = parse_cigar(cigar)
    mate = 2 if flag & 0x80 else 1
    rev = flag & 0x10
    lead_h = ops[0][0] if ops[0][1] == "H" else 0
    tail_h = ops[-1][0] if len(ops) > 1 and ops[-1][1] == "H" else 0
    length = lead_h + len(seq) + tail_h
    out = []
    rpos, qpos = start, 0
    for n, op in ops:
        if op in "M=X":
            for k in range(n):
                p = rpos + k
                if p in sites:
                    qi = qpos + k
                    if qual == "*" or ord(qual[qi]) - 33 >= min_bq:
                        idx = lead_h + qi
                        cycle = (length - idx) if rev else (idx + 1)
                        b = seq[qi].upper()
                        ref, alt = sites[p]
                        out.append((mate, cycle, 1 if b == ref else 2 if b == alt else 3))
            rpos += n
            qpos += n
        elif op in "DN":
            rpos += n
        elif op in "IS":
            qpos += n
    return out


def count_sample(job):
    sample, aln, fasta, bed, samtools_args, sites, min_bq, bins = job
    cmd = ["samtools", "view"] + samtools_args + ["--reference", fasta, "-M", "-L", bed, aln]
    counts = {}
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, text=True)
    nrec = 0
    for line in proc.stdout:
        t = line.rstrip(NL).split(TAB, 11)
        if len(t) < 11:
            # not a SAM record (e.g. a samtools wrapper that printed something else): fail with the line, not an IndexError
            proc.kill()
            raise RuntimeError(f"READ_POSITION_QC: samtools view gave a line that is not a SAM record for {sample}: {line[:200]!r}")
        nrec += 1
        for mate, cycle, cls in record_bases(int(t[1]), int(t[3]), t[5], t[9], t[10], sites, min_bq):
            b = bin_of(cycle, bins)
            if b is None:
                continue
            c = counts.setdefault((mate, b), [0, 0, 0, 0])
            c[0] += 1
            c[cls] += 1
    if proc.wait() != 0:
        # an Exception (not SystemExit) so that pool.map hands it back to the parent
        raise RuntimeError(f"READ_POSITION_QC: samtools view failed for {sample} (status {proc.returncode})")
    return sample, counts, nrec


def rows_of(label, sample, counts, bins):
    out = []
    for mate in (1, 2):
        for _lo, _hi, b in bins:
            n, r, a, o = counts.get((mate, b), [0, 0, 0, 0])
            out.append([label, sample, str(mate), b, str(n), str(r), str(a), str(o),
                        f"{a / n:.6f}" if n else NA, f"{o / n:.6f}" if n else NA, f"{a / (r + a):.6f}" if r + a else NA])
    return out


def zg_cpus():
    """ZG_CPUS from bin/export_slurm_resources.sh (sourced by name from PATH, as every module script)."""
    r = subprocess.run(["bash", "-c", "source export_slurm_resources.sh 1>&2 && printenv ZG_CPUS"], capture_output=True, text=True)
    sys.stderr.write(r.stderr)
    if r.returncode != 0:
        raise SystemExit("READ_POSITION_QC: export_slurm_resources.sh failed")
    return int(r.stdout.strip())


def find_alignment(sample, d="aln"):
    for ext in (".bam", ".cram"):
        p = os.path.join(d, sample + ext)
        if os.path.exists(p):
            return p
    raise SystemExit(f"READ_POSITION_QC: no {d}/{sample}.bam or .cram")


def main():
    prefix = "${task.ext.prefix ?: meta.id}"
    process = "${task.process}"
    samples =json.loads('''${groovy.json.JsonOutput.toJson(sample_ids)}''')
    sites_path = "${sites}"
    fasta = "${fasta}"
    region = "${region}"
    label = "${label}"
    samtools_args = shlex.split('''${task.ext.args ?: ''}''')
    a = parse_args(shlex.split('''${task.ext.args2 ?: ''}'''))

    bins = parse_bins(a.bins)
    chrom, sites = read_sites(sites_path, region)
    bed = f"{prefix}.sites.bed"
    with open(bed, "w") as o:
        for p in sorted(sites):
            o.write(f"{chrom}{TAB}{p - 1}{TAB}{p}{NL}")
    jobs = [(s, find_alignment(s), fasta, bed, samtools_args, sites, a.min_bq, bins) for s in samples]
    ncpu = max(1, min(zg_cpus(), len(jobs)))
    if sites and jobs:
        try:
            with multiprocessing.Pool(ncpu) as pool:
                results = pool.map(count_sample, jobs)
        except RuntimeError as e:
            sys.exit(str(e))
    else:
        results = [(s, {}, 0) for s in samples]
    total = {}
    with open(f"{prefix}.read_position_qc.tsv", "w") as o:
        o.write(TAB.join(["label", "sample", "mate", "cycle_bin", "n", "ref", "alt", "other", "alt_frac", "other_frac",
                          "alt_ref_alt"]) + NL)
        for sample, counts, nrec in results:
            log(f"{sample}: {nrec} records at {len(sites)} sites")
            for k, v in counts.items():
                t = total.setdefault(k, [0, 0, 0, 0])
                for i in range(4):
                    t[i] += v[i]
            for r in rows_of(label, sample, counts, bins):
                o.write(TAB.join(r) + NL)
        for r in rows_of(label, "ALL", total, bins):
            o.write(TAB.join(r) + NL)
    os.remove(bed)
    st = subprocess.run(["samtools", "version"], capture_output=True, text=True, check=True).stdout.split(NL)[0].split()[-1]
    with open(f"{prefix}.read_position_qc.versions.yml", "w") as fh:
        fh.write(f'"{process}":{NL}    samtools: {st}{NL}    python: {platform.python_version()}{NL}')


if __name__ == "__main__":
    main()
