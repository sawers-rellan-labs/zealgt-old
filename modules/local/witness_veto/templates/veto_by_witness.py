#!/usr/bin/env python3
"""Witness veto on the in-range CRISP VCF (WITNESS_VETO, genotype design section 2.2).

Nextflow module template (modules/local/witness_veto/main.nf): the Groovy placeholders are filled in by Nextflow, so the task
hash covers this file's content, not its path. No backslashes or dollar signs outside the placeholders (the template engine
would read them); tab and newline are chr(9) / chr(10).

A record is kept when the witness pool's ALT reads, summed over CRISP's per-strand allele counts ADf, ADr and ADb and over
every ALT allele (entries 2.. of each 'ref,alt1,alt2,...' field), reach --min-alt-reads (default 1). A missing witness
column stops the task; a record without any of the three fields counts 0 ALT reads.
Writes
  <prefix>.vetoed.vcf.gz      the header and the kept records, BGZF-compressed (tabix-indexable)
  <prefix>.kept_sites.tsv     chrom, pos, ref, alt of the kept records (no header)
  <prefix>.veto_summary.tsv   one row: witness, min_alt_reads, records_in, kept, dropped, kept_share
  <prefix>.witness_veto.versions.yml
Options (ext.args): --min-alt-reads N.
Standard library only.
"""
import argparse
import gzip
import platform
import shlex
import struct
import sys
import zlib
import logging
logging.basicConfig(stream=sys.stderr, level=logging.INFO, datefmt="%Y-%m-%d %H:%M:%S",
                    format="%(asctime)s %(levelname)s [%(name)s] %(message)s")
LOG = logging.getLogger("witness_veto")

TAB = chr(9)
NL = chr(10)

PREFIX = "${task.ext.prefix ?: meta.id}"
PROCESS = "${task.process}"
VCF = "${vcf}"
WITNESS = "${witness}"
EXT_ARGS = shlex.split('''${task.ext.args ?: ''}''')

BGZF_EOF = bytes.fromhex("1f8b08040000000000ff0600424302001b0003000000000000000000")
BGZF_BLOCK = 65280


class BgzfWriter:
    """Minimal BGZF writer (SAM/BAM specification section 4.1): gzip members of <= 64 KiB with the BC extra field."""

    def __init__(self, path):
        self.fh = open(path, "wb")
        self.buf = bytearray()

    def write(self, text):
        self.buf += text.encode()
        while len(self.buf) >= BGZF_BLOCK:
            self._block(bytes(self.buf[:BGZF_BLOCK]))
            del self.buf[:BGZF_BLOCK]

    def _block(self, data):
        comp = zlib.compressobj(6, zlib.DEFLATED, -15)
        cdata = comp.compress(data) + comp.flush()
        bsize = 18 + len(cdata) + 8 - 1
        self.fh.write(struct.pack("<BBBBIBBHBBHH", 31, 139, 8, 4, 0, 0, 255, 6, 66, 67, 2, bsize))
        self.fh.write(cdata)
        self.fh.write(struct.pack("<II", zlib.crc32(data) & 0xFFFFFFFF, len(data)))

    def close(self):
        if self.buf:
            self._block(bytes(self.buf))
            self.buf = bytearray()
        self.fh.write(BGZF_EOF)
        self.fh.close()


def open_text(path):
    with open(path, "rb") as fh:
        magic = fh.read(2)
    return gzip.open(path, "rt") if magic == bytes([31, 139]) else open(path)


def alt_reads(fmt, sample):
    keys = fmt.split(":")
    vals = sample.split(":")
    total = 0
    for k in ("ADf", "ADr", "ADb"):
        if k not in keys:
            continue
        i = keys.index(k)
        if i >= len(vals):
            continue
        for v in vals[i].split(",")[1:]:
            if v not in (".", ""):
                total += int(v)
    return total


def main():
    ap = argparse.ArgumentParser(prog="veto_by_witness.py")
    ap.add_argument("--min-alt-reads", type=int, default=1)
    a = ap.parse_args(EXT_ARGS)
    if a.min_alt_reads < 0:
        sys.exit("WITNESS_VETO: --min-alt-reads must be >= 0")

    out = BgzfWriter(f"{PREFIX}.vetoed.vcf.gz")
    sites = open(f"{PREFIX}.kept_sites.tsv", "w")
    idx = None
    n_in = kept = 0
    with open_text(VCF) as fh:
        for line in fh:
            if line.startswith("##"):
                out.write(line)
                continue
            if line.startswith("#"):
                cols = line.rstrip(NL).split(TAB)
                if WITNESS not in cols[9:]:
                    sys.exit(f"WITNESS_VETO {PREFIX}: witness {WITNESS} not among the VCF samples {cols[9:]}")
                idx = cols.index(WITNESS)
                out.write(line)
                continue
            if idx is None:
                sys.exit(f"WITNESS_VETO {PREFIX}: record before the #CHROM line in {VCF}")
            x = line.rstrip(NL).split(TAB)
            n_in += 1
            if alt_reads(x[8], x[idx]) >= a.min_alt_reads:
                out.write(line if line.endswith(NL) else line + NL)
                sites.write(f"{x[0]}{TAB}{x[1]}{TAB}{x[3]}{TAB}{x[4]}{NL}")
                kept += 1
    if idx is None:
        sys.exit(f"WITNESS_VETO {PREFIX}: no #CHROM line in {VCF}")
    out.close()
    sites.close()

    with open(f"{PREFIX}.veto_summary.tsv", "w") as fh:
        fh.write(TAB.join(["witness", "min_alt_reads", "records_in", "kept", "dropped", "kept_share"]) + NL)
        share = f"{kept / n_in:.6f}" if n_in else "NA"
        fh.write(TAB.join([WITNESS, str(a.min_alt_reads), str(n_in), str(kept), str(n_in - kept), share]) + NL)
    LOG.info(f"WITNESS_VETO {PREFIX}: {kept} of {n_in} records kept (witness {WITNESS} ALT reads >= {a.min_alt_reads})")

    with open(f"{PREFIX}.witness_veto.versions.yml", "w") as fh:
        fh.write(f'"{PROCESS}":{NL}    python: {platform.python_version()}{NL}')


if __name__ == "__main__":
    main()
