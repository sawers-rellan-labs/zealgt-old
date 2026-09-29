# ZEAL NIL id (`nil_id`) — specification

Authoritative id scheme for ZEAL/BZea NIL lines. Built and verified by the
scripts in this folder (see Provenance). Register: `out/register_bc2s3.csv`.

> Supersedes the earlier gap-serial scheme (`out/nil_registry.csv`,
> `REGISTRY_README.md`, `Zx######`), which is abandoned.

## The id at a glance

    Zx 0010 4 1 1 2
    │  │    │ │ │ └ S1  first selfing-ear selection      (base 36)
    │  │    │ │ └── P3  BC2 plant selection              (base 36)
    │  │    │ └──── P2  BC1 plant selection              (base 36)
    │  │    └────── P1  F1  plant selection              (base 36)
    │  └─────────── donor accession number, 4-digit decimal
    └────────────── taxon (Zx Zv Zl Zd Zh)

Fixed width, 10 characters: **taxon(2) + donor(4) + P1 P2 P3 S1 (4 base-36 chars)**.
No separators are needed because every field is fixed width.

Example: `Zx00104112` = *Zea mexicana* (Zx), donor accession 0010, backcross
selections P1=4, P2=1, P3=1, first selfing ear S1=2.

## Field definitions

| field | meaning | source in the pedigree string | width | current range |
|---|---|---|---|---|
| taxon | primary teosinte taxon | `Zx.`/`Zv.`/`Zl.`/`Zd.`/`Zh.` | 2 | 5 taxa |
| donor | teosinte founder accession | the accession number (`Zx.0010`) | 4 decimal | 0010–0580 |
| P1 | F1 plant selection | 1st `_P`/`_Q`/`_X` segment | 1 base-36 | 1–4 |
| P2 | BC1 plant selection | 2nd `_P…` segment | 1 base-36 | 1–6 |
| P3 | BC2 plant selection | 3rd `_P…` segment | 1 base-36 | 1–7 |
| S1 | first selfing ear | 1st `.` (dot) segment | 1 base-36 | 1–8 |

**base-36 alphabet:** `0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ`; value `v` → the
`v`-th character (0→`0`, 9→`9`, 10→`A`, …, 35→`Z`). One character therefore holds
selections up to 35, so every current position (max 8) has generous headroom.

## Why only P1 P2 P3 S1 (and why the register drops the rest)

Established from the data this session:

- **S2, S3 are always `1`** across all 2,624 BC2S3 lines — single-seed descent
  after S1, so they carry no information. The line's identity is fixed at S1.
  (`24_bc2s3_positions.R`)
- **The donor's leading and trailing digits are always `0`** (accessions are
  multiples of 10, all < 1000). The 4-digit form is kept only for human
  recognizability of the accession. (`25_donor_digits.R`)
- `(taxon, donor, P1, P2, P3, S1)` is therefore a **unique key** for a BC2S3
  line — no collisions. (`26_build_bc2s3_register.R`)

## Encoding earlier (and later) generations: `0` = "stage not reached"

Because selection numbers are 1-based, `0` is a free sentinel for a stage not yet
reached, so the *same* fixed id encodes every generation:

| generation | positions filled | example nil_id |
|---|---|---|
| F1 | P1 · 0 · 0 · 0 | `Zx00104000` |
| BC1 | P1 · P2 · 0 · 0 | `Zx00104100` |
| BC2 (pre-self) | P1 · P2 · P3 · 0 | `Zx00104130` |
| BC2S1 / S2 / S3 … | P1 · P2 · P3 · S1 | `Zx00104131` |

Because S2/S3+ are dropped, **BC2S1, BC2S2, BC2S3 (and BC2S4…) of one line all
collapse to the same `nil_id`** — the id is stable across selfing generations
(line identity), and an ancestor's id always sorts immediately before its
descendants. Verified: 16,402 nodes → 8,193 distinct ids, **0 unwanted
collisions**, ancestor-id ≤ descendant-id everywhere. (`27_encode_all_generations.R`)

## Verified properties

- **Deterministic from the pedigree string** — parse donor + P1 P2 P3 S1, encode;
  no registry lookup needed to mint an id.
- **Bijective** with a line (per generation-collapsed lineage); no collisions.
- **`sort(nil_id)` == depth-first tree order** — related lines are numerically
  adjacent; you read relatedness off the leading fields and tell lines apart on
  the short tail.

## `generation` is NOT stored

It is redundant with the pedigree string: `generation = BC2S<number of selfing
dots>` (given the 3 `_P`). Store `pedigree`; derive generation on demand.

## Register schema (`out/register_bc2s3.csv`)

    nil_id, taxon, donor_accession, P1, P2, P3, S1, pedigree, eval_CLY23, eval_CLY25

`pedigree` = the full original pedigree string (single stored source of truth).
`eval_*` = whether that line was phenotyped in the trial. 2,624 BC2S3 lines
(Zx 1198, Zv 783, Zd 387, Zl 173, Zh 83).

## Adding or advancing a line

- **New line:** parse its pedigree string → `taxon, donor, P1, P2, P3, S1` →
  encode. Deterministic; add a row with its `pedigree`.
- **Advance a generation** (BC2S3 → BC2S4 by single-seed descent): `S1` is
  unchanged, so the **`nil_id` stays the same**; just update the `pedigree`
  string. Generation re-derives automatically.

## Caveats (honest)

- The scheme assumes **S2/S3 remain single-seed descent** (true for all current
  lines). If a line ever kept multiple ears past S1, an extra position would be
  needed to keep it unique.
- Each selection position is **one base-36 char (max 35)**. If any position ever
  exceeds 35, widen that field.
- The donor accession number is **per-taxon** (`Zx.0410` ≠ `Zv.0410`); the taxon
  prefix disambiguates.

## Not covered by this register (separate items)

- **77 BC2S4 catalog-only lines** — listed in the CLY23 workbook `REF-all` tab,
  **not evaluated** in CLY23, CLY25, or GDL (`28_bc2s4_source.R`). They receive
  valid nil_ids with all `eval_*` = FALSE; benign.
- **CLY25 earlier-generation evaluations** (BC2S1/BC2S2) — these self-map to the
  same `nil_id` as their BC2S3 line, so they attach automatically.
- **GDL (Mexico) flowering → nil_id** — resolvable for the lines whose selfing
  path matches Clayton; the remainder (~37%) needs the origin→line_id "threeway"
  crosswalk (see `PROVENANCE.md`, `FINDINGS.md`).

## Provenance (scripts, all in `agent/gdl_flowering/`)

- `24_bc2s3_positions.R` — showed S2/S3 constant, P1..S1 informative.
- `25_donor_digits.R` — showed donor leading/trailing digits constant.
- `26_build_bc2s3_register.R` — **builds `register_bc2s3.csv`**; verifies SSD
  assumption, uniqueness, tree-order on every run.
- `27_encode_all_generations.R` — verified the `0`-sentinel all-generation encoding.
- `28_bc2s4_source.R` — traced the 77 BC2S4 to the CLY23 REF-all catalog, unevaluated.
