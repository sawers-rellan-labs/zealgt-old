#!/usr/bin/env python3
"""Line coverage floor and RTIGER input of stage 4 (LINE_MARKER_QC, design §2.3; PLAN §4 #13 decided 2026-09-24; zealbc1
PHG/bin/ad_to_counts.py and the invariant-site filter of rtiger_ancestry_inference.sbatch).

Nextflow module template (modules/local/line_marker_qc/main.nf): the Groovy placeholders are filled in by Nextflow, so the
task hash covers this file's content, not its path. No backslashes or dollar signs outside the placeholders; tab and newline
are chr(9) / chr(10).

Inputs: the LINE_ALLELE_COUNTS table of the donor's lines (ALLELE_COUNTS: `bcftools query -H -f '%CHROM %POS %REF %ALT [%AD]'`,
one column per line named by its SM) and the donor's tier-A marker list (RTIGER_MARKERS: chrom pos ref alt, no header).
Per marker and line: REF reads = AD[0], ALT reads = AD of the marker's ALT allele (0 when mpileup did not list it); records at
non-marker positions, with another REF, or indels are skipped; a repeated position keeps its first record.
1. Invariant markers (0 ALT reads over every line of the table) are dropped when --drop-invariant true (default; as zealbc1,
   params.rtiger_drop_invariant_sites).
2. Covered marker = a kept marker with >= 1 read in the line, the markers RTIGER sees (nilHMM drops 0-read observations,
   min_reads = 1). A line with any contig below the floor is EXCLUDED (PLAN §4 #13: excluded from every caller; the
   downstream stages read line_qc.tsv). floor = ceil(min_markers_factor x rigidity), raised to 2 x rigidity if lower, since
   nilHMM's RTIGER stops on any chain below 2 x rigidity covered markers (R/rtiger.R .rtiger_check_coverage).
   rigidity here is the EFFECTIVE rigidity (user rule 2026-09-29: rigidity follows marker density): with
   rigidity_ref_markers > 0, rigidity is the value at rigidity_ref_markers markers per chromosome, scaled to the unit's kept
   markers per chromosome: max(1, round(rigidity x kept x (chromosome length / region length) / rigidity_ref_markers)),
   chromosome length from the reference .fai. A whole-chromosome region has factor 1; a window is scaled to its
   full-chromosome density, so it runs at the value the whole chromosome would. rigidity_ref_markers 0 = rigidity as given.
Outputs:
  <prefix>.counts.tsv   RTIGER input, only lines that pass and observations with reads:
                        SAMPLE CONTIG POSITION REF_COUNT ALT_COUNT REF_NUCLEOTIDE ALT_NUCLEOTIDE (zealbc1 layout)
  <prefix>.line_qc.tsv  one row per line x contig: sample contig markers markers_kept covered reads mean_depth floor
                        contig_pass line_pass reason (below_marker_floor | no_markers | .)
  <prefix>.rigidity.txt the effective rigidity (one integer), RTIGER's rigidity for this unit
Standard library only.
"""
import argparse
import gzip
import math
import platform
import shlex
import sys
import logging
logging.basicConfig(stream=sys.stderr, level=logging.INFO, datefmt="%Y-%m-%d %H:%M:%S",
                    format="%(asctime)s %(levelname)s [%(name)s] %(message)s")
LOG = logging.getLogger("line_marker_qc")

TAB = chr(9)
NL = chr(10)

PREFIX = "${task.ext.prefix ?: meta.id}"
PROCESS = "${task.process}"
COUNTS = "${counts}"
SITES = "${sites}"
RIGIDITY = int("${rigidity}")
RIGIDITY_REF_MARKERS = int("${rigidity_ref_markers}")
MIN_MARKERS_FACTOR = float("${min_markers_factor}")
FAI = "${fai}"
REGION = "${region}"
EXT_ARGS = shlex.split('''${task.ext.args ?: ''}''')


def region_span(region, chrom_len):
    """'chr10' -> (chr10, chromosome length); 'chr10:1-20000000' -> (chr10, 20000000), end clipped to the chromosome."""
    if ":" not in region:
        return region, chrom_len[region]
    chrom, span = region.rsplit(":", 1)
    start, end = (int(t) for t in span.replace(",", "").split("-"))
    if start < 1 or end < start:
        sys.exit(f"{PROCESS}: bad region {region}")
    return chrom, min(end, chrom_len[chrom]) - start + 1


def effective_rigidity(n_kept, region, chrom_len):
    """rigidity at RIGIDITY_REF_MARKERS markers per chromosome, scaled to the unit's kept markers per chromosome."""
    if RIGIDITY_REF_MARKERS == 0:
        return RIGIDITY, "rigidity_ref_markers 0: rigidity as given"
    chrom = region.split(":", 1)[0]
    if chrom not in chrom_len:
        sys.exit(f"{PROCESS}: chromosome {chrom} of region {region} is not in {FAI}")
    _, span = region_span(region, chrom_len)
    per_chrom = n_kept * chrom_len[chrom] / span
    r = max(1, round(RIGIDITY * per_chrom / RIGIDITY_REF_MARKERS))
    return r, (f"rigidity {RIGIDITY} at {RIGIDITY_REF_MARKERS} markers per chromosome; {n_kept} kept markers in {span} bp of "
               f"{chrom} ({chrom_len[chrom]} bp) = {per_chrom:.0f} per chromosome -> rigidity {r}")


def sample_of(token):
    """bcftools query -H column '[5]S1:AD' -> 'S1'."""
    t = token.strip()
    if t.startswith("#"):
        t = t[1:].strip()
    if t.startswith("[") and "]" in t:
        t = t.split("]", 1)[1]
    if t.endswith(":AD"):
        t = t[:-3]
    return t


def truthy(text):
    t = text.strip().lower()
    if t in ("true", "1", "yes"):
        return True
    if t in ("false", "0", "no"):
        return False
    sys.exit(f"{PROCESS}: expected true/false, got {text}")


def main():
    ap = argparse.ArgumentParser(description="LINE_MARKER_QC options (task.ext.args)")
    ap.add_argument("--drop-invariant", default="true")
    a = ap.parse_args(EXT_ARGS)
    drop_invariant = truthy(a.drop_invariant)
    if RIGIDITY < 1:
        sys.exit(f"{PROCESS}: rigidity must be >= 1, got {RIGIDITY}")
    if RIGIDITY_REF_MARKERS < 0:
        sys.exit(f"{PROCESS}: rigidity_ref_markers must be >= 0 (0 = no scaling), got {RIGIDITY_REF_MARKERS}")
    chrom_len = {}
    with open(FAI) as fh:
        for ln in fh:
            x = ln.split(TAB)
            if len(x) >= 2:
                chrom_len[x[0]] = int(x[1])

    markers = {}
    contigs = []
    with open(SITES) as fh:
        for ln in fh:
            x = ln.rstrip(NL).split(TAB)
            if len(x) < 4 or ln.startswith("#"):
                continue
            key = (x[0], int(x[1]))
            if key in markers:
                sys.exit(f"{PROCESS}: marker {key} is listed twice in {SITES}")
            markers[key] = (x[2].upper(), x[3].upper())
            if x[0] not in contigs:
                contigs.append(x[0])

    lines = None
    obs = {}  # (chrom, pos) -> [(ref_reads, alt_reads) per line]
    skipped = {"not_marker": 0, "ref_mismatch": 0, "indel": 0, "repeat": 0}
    opener = gzip.open if COUNTS.endswith(".gz") else open
    with opener(COUNTS, "rt") as fh:
        for ln in fh:
            x = ln.rstrip(NL).split(TAB)
            if ln.startswith("#"):
                lines = [sample_of(t) for t in x[4:]]
                if len(set(lines)) != len(lines):
                    sys.exit(f"{PROCESS}: duplicate sample columns in {COUNTS}")
                continue
            if lines is None:
                sys.exit(f"{PROCESS}: {COUNTS} has no bcftools query -H header line")
            if len(x) != 4 + len(lines):
                sys.exit(f"{PROCESS}: {COUNTS}: {len(x) - 4} AD columns vs {len(lines)} samples")
            key = (x[0], int(x[1]))
            if key not in markers:
                skipped["not_marker"] += 1
                continue
            if len(x[2]) != 1:
                skipped["indel"] += 1
                continue
            ref, alt = markers[key]
            if x[2].upper() != ref:
                skipped["ref_mismatch"] += 1
                continue
            if key in obs:
                skipped["repeat"] += 1
                continue
            alts = [] if x[3] == "." else x[3].upper().split(",")
            ai = alts.index(alt) + 1 if alt in alts else None
            row = []
            for ad in x[4:]:
                if ad in (".", ""):
                    row.append((0, 0))
                    continue
                v = [int(t) if t not in (".", "") else 0 for t in ad.split(",")]
                row.append((v[0], v[ai] if ai is not None and ai < len(v) else 0))
            obs[key] = row
    if lines is None:
        sys.exit(f"{PROCESS}: {COUNTS} is empty (no header line)")

    kept = sorted((k for k in obs if not drop_invariant or any(ac > 0 for _, ac in obs[k])),
                  key=lambda k: (contigs.index(k[0]), k[1]))
    n_markers = {c: 0 for c in contigs}
    for c, _ in markers:
        n_markers[c] += 1
    n_kept = {c: 0 for c in contigs}
    for c, _ in kept:
        n_kept[c] += 1
    rigidity, why = effective_rigidity(len(kept), REGION, chrom_len)
    LOG.info(f"line_marker_qc {PREFIX}: {why}")
    floor = math.ceil(MIN_MARKERS_FACTOR * rigidity)
    if floor < 2 * rigidity:
        LOG.warning(f"{PROCESS}: floor {floor} (min_markers_factor {MIN_MARKERS_FACTOR} x rigidity {rigidity}) is below "
              f"RTIGER's 2 x rigidity = {2 * rigidity}; using {2 * rigidity}")
        floor = 2 * rigidity
    with open(f"{PREFIX}.rigidity.txt", "w") as out:
        out.write(f"{rigidity}{NL}")
    covered = {}
    reads = {}
    for key in kept:
        for i, (rc, ac) in enumerate(obs[key]):
            if rc + ac > 0:
                covered[(i, key[0])] = covered.get((i, key[0]), 0) + 1
                reads[(i, key[0])] = reads.get((i, key[0]), 0) + rc + ac
    # no marker at all: no line can pass (all() over no contigs would be True)
    line_pass = [bool(contigs) and all(covered.get((i, c), 0) >= floor for c in contigs) for i in range(len(lines))]

    with open(f"{PREFIX}.line_qc.tsv", "w") as out:
        out.write(TAB.join(["sample", "contig", "markers", "markers_kept", "covered", "reads", "mean_depth", "floor",
                            "contig_pass", "line_pass", "reason"]) + NL)
        for i, s in enumerate(lines):
            if not contigs:
                out.write(TAB.join([s, ".", "0", "0", "0", "0", "NA", str(floor), "false", "false", "no_markers"]) + NL)
            for c in contigs:
                k = covered.get((i, c), 0)
                d = reads.get((i, c), 0)
                ok = k >= floor
                out.write(TAB.join([s, c, str(n_markers[c]), str(n_kept[c]), str(k), str(d),
                                    f"{d / k:.4f}" if k else "NA", str(floor), str(ok).lower(),
                                    str(line_pass[i]).lower(), "." if ok else "below_marker_floor"]) + NL)
    n_obs = 0
    with open(f"{PREFIX}.counts.tsv", "w") as out:
        out.write(TAB.join(["SAMPLE", "CONTIG", "POSITION", "REF_COUNT", "ALT_COUNT", "REF_NUCLEOTIDE",
                            "ALT_NUCLEOTIDE"]) + NL)
        for i, s in enumerate(lines):
            if not line_pass[i]:
                continue
            for key in kept:
                rc, ac = obs[key][i]
                if rc + ac > 0:
                    ref, alt = markers[key]
                    out.write(TAB.join([s, key[0], str(key[1]), str(rc), str(ac), ref, alt]) + NL)
                    n_obs += 1
    n_pass = sum(line_pass)
    LOG.info(f"line_marker_qc {PREFIX}: {len(markers)} markers, {len(obs)} counted, {len(kept)} kept "
          f"(drop_invariant {str(drop_invariant).lower()}), floor {floor}; {n_pass} of {len(lines)} lines pass; "
          f"{n_obs} observations; skipped records {skipped}")
    excluded = [s for i, s in enumerate(lines) if not line_pass[i]]
    if excluded:
        LOG.warning(f"{PROCESS} {PREFIX}: {len(excluded)} lines below {floor} covered markers, excluded: {excluded}")
    with open(f"{PREFIX}.line_marker_qc.versions.yml", "w") as fh:
        fh.write(f'"{PROCESS}":{NL}    python: {platform.python_version()}{NL}')


if __name__ == "__main__":
    main()
