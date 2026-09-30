#!/usr/bin/env python3
"""Clip the lowcopy BED to one region (REGION_BED, genotype design section 2.2).

Nextflow module template (modules/local/region_bed/main.nf): the Groovy placeholders are filled in by Nextflow, so the task
hash covers this file's content, not its path. No backslashes or dollar signs outside the placeholders (the template engine
would read them); tab and newline are chr(9) / chr(10).

Region: 'chr' (the whole chromosome) or 'chr:start-end' (1-based, inclusive, samtools syntax).
BED input: chrom, start, end (0-based, half-open) plus any further columns (ignored); blank, '#', 'track' and 'browser'
lines are skipped. A malformed line (fewer than 3 fields, non-integer or negative coordinates, end <= start) stops the task.
Writes
  <prefix>.bed           the ranges of the region's chromosome intersected with the region, merged where they overlap or
                         abut, sorted; 3 columns, 0-based half-open
  <prefix>.regions.txt   the same ranges as 1-based 'chr:start-end', one per line
  <prefix>.region_bed.versions.yml
Options (ext.args): --allow-empty (write empty outputs instead of failing when no range falls in the region).
Standard library only.
"""
import argparse
import platform
import shlex
import sys
import logging
logging.basicConfig(stream=sys.stderr, level=logging.INFO, datefmt="%Y-%m-%d %H:%M:%S",
                    format="%(asctime)s %(levelname)s [%(name)s] %(message)s")
LOG = logging.getLogger("region_bed")

TAB = chr(9)
NL = chr(10)

PREFIX = "${task.ext.prefix ?: meta.id}"
PROCESS = "${task.process}"
BED = "${bed}"
REGION = "${region}"
EXT_ARGS = shlex.split('''${task.ext.args ?: ''}''')


def parse_region(region):
    """Return (chrom, start0, end0) with end0 = None for a whole chromosome."""
    if ":" not in region:
        return region, 0, None
    chrom, span = region.split(":", 1)
    first, last = span.split("-", 1)
    start, end = int(first), int(last)
    if start < 1 or end < start:
        sys.exit(f"REGION_BED: region {region!r}: need 1 <= start <= end")
    return chrom, start - 1, end


def read_ranges(path, chrom):
    ranges = []
    with open(path) as fh:
        for i, line in enumerate(fh, 1):
            line = line.rstrip(NL).rstrip(chr(13))
            if not line.strip() or line.startswith(("#", "track", "browser")):
                continue
            x = line.split(TAB)
            if len(x) < 3:
                x = line.split()
            if len(x) < 3:
                sys.exit(f"REGION_BED: {path}:{i}: fewer than 3 fields")
            try:
                s, e = int(x[1]), int(x[2])
            except ValueError:
                sys.exit(f"REGION_BED: {path}:{i}: non-integer coordinates {x[1]!r} {x[2]!r}")
            if s < 0 or e <= s:
                sys.exit(f"REGION_BED: {path}:{i}: need 0 <= start < end, got {s} {e}")
            if x[0] == chrom:
                ranges.append((s, e))
    return ranges


def clip_and_merge(ranges, start0, end0):
    out = []
    for s, e in sorted(ranges):
        s = max(s, start0)
        if end0 is not None:
            e = min(e, end0)
        if e <= s:
            continue
        if out and s <= out[-1][1]:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return out


def main():
    ap = argparse.ArgumentParser(prog="clip_bed_to_region.py")
    ap.add_argument("--allow-empty", action="store_true")
    a = ap.parse_args(EXT_ARGS)

    chrom, start0, end0 = parse_region(REGION)
    raw = read_ranges(BED, chrom)
    ranges = clip_and_merge(raw, start0, end0)
    if not ranges and not a.allow_empty:
        sys.exit(f"REGION_BED {PREFIX}: no range of {BED} falls in {REGION} (chromosome {chrom}: {len(raw)} ranges)")

    with open(f"{PREFIX}.bed", "w") as out:
        for s, e in ranges:
            out.write(f"{chrom}{TAB}{s}{TAB}{e}{NL}")
    with open(f"{PREFIX}.regions.txt", "w") as out:
        for s, e in ranges:
            out.write(f"{chrom}:{s + 1}-{e}{NL}")
    bases = sum(e - s for s, e in ranges)
    LOG.info(f"REGION_BED {PREFIX}: {REGION}: {len(raw)} ranges on {chrom} -> {len(ranges)} clipped/merged, {bases} bp")

    with open(f"{PREFIX}.region_bed.versions.yml", "w") as fh:
        fh.write(f'"{PROCESS}":{NL}    python: {platform.python_version()}{NL}')


if __name__ == "__main__":
    main()
