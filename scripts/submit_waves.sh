#!/usr/bin/env bash
# scripts/submit_waves.sh — submit a chain of CRAM-workflow waves in one go, unattended (user, 2026-10-01; docs/PLAN_pipeline.md
# §6 Gate 2 TODO 8). Run on hazel from the checkout (submits only; nothing heavy on the login node):
#
#   cd /rsstu/users/r/rrellan/BZea/ZEAL/zealgt && bash scripts/submit_waves.sh docs/runs/<wave1>.yml docs/runs/<wave2>.yml ...
#
# Each run card becomes one head job (scripts/submit_head_job.sbatch; run_id = the card's file name without .yml) on
# QOS normal with the 4-day maximum. Wave k+1 waits with --dependency=afterok:<wave k>: it starts only when wave k's head job
# ended with exit 0 (Nextflow success; with the production profile its work/ is then cleaned and its verified checkpoints
# removed). If a wave fails, the later ones never start (Slurm: DependencyNeverSatisfied; cancel them with scancel <id>) and the
# failed wave keeps its work/ for debugging. No job holds the chain, so the whole chain may run longer than 4 days.
#
# Profile: ZG_WAVE_PROFILE (default hazel,normal,production). Gate 2 waves keep their checkpoints until genotype Gate 2
# (user, 2026-09-29): their cards set `remove_verified_checkpoints: false` (a params file overrides the profile).
# Before submitting: every card exists and names an outdir; the images and the launcher are present (restore_images --check).
set -eo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${ZG_WAVE_PROFILE:-hazel,normal,production}"
[ $# -ge 1 ] || { echo "usage: bash scripts/submit_waves.sh <run card .yml> [<run card .yml> ...]" >&2; exit 2; }
for c in "$@"; do
    [ -f "$c" ] || { echo "submit_waves: no such run card: $c" >&2; exit 1; }
    grep -qE '^outdir:' "$c" || { echo "submit_waves: $c sets no outdir:" >&2; exit 1; }
done
ZG_REPO="$REPO" bash "$REPO/scripts/restore_images.sbatch" --check
prev=""
echo "submit_waves: $# wave(s), profile $PROFILE, repo $REPO at $(git -C "$REPO" rev-parse --short HEAD)"
for c in "$@"; do
    card="$(cd "$(dirname "$c")" && pwd)/$(basename "$c")"
    run_id="$(basename "$c" .yml)"
    dep=(); [ -z "$prev" ] || dep=(--dependency="afterok:$prev" --kill-on-invalid-dep=no)
    jid=$(sbatch --parsable --qos=normal --partition=compute --time=4-00:00:00 "${dep[@]}" --export=ALL,ZG_REPO="$REPO" \
        "$REPO/scripts/submit_head_job.sbatch" "$run_id" -profile "$PROFILE" -params-file "$card")
    echo "  wave $run_id: head job $jid${prev:+ (after $prev succeeds)}; log /share/maize/frodrig4/nf_work/zealgt_head_$jid.log"
    prev="$jid"
done
echo "submit_waves: chain submitted. A failed wave stops the chain; its later waves wait as DependencyNeverSatisfied (scancel them)."
