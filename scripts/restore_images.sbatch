#!/bin/bash
#SBATCH --job-name=zealgt_restore_images
#SBATCH --account=maize_cpu
#SBATCH --partition=xfer
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=04:00:00
#SBATCH --output=/share/maize/frodrig4/nf_work/restore_images_%j.log
#
# scripts/restore_images.sbatch — put back every container image and the Nextflow launcher the checkout needs on hazel.
#
# Why: /share is not backed up and deletes files not accessed for 30 days (https://hpc.ncsu.edu/Storage/Storage.php). The
# images in apptainer.cacheDir and the launcher env are on /share (docs/PLAN_containers.md; usrapps was rejected), so a month
# without a task reading an image (e.g. the CRAM images during genotype-only work) can remove it. Files are never touched to
# reset the clock; this job restores what is missing instead. The head job (scripts/submit_head_job.sbatch) runs the
# --check mode below before nextflow starts and stops with the command to run this job when anything is missing.
#
# What it does (xfer partition: the only nodes with internet), idempotent: with everything present it fetches nothing.
#   1. Images: from the checkout's own `container` lines (modules/*/main.nf, modules/*/*/main.nf): the https SIF URL of the
#      singularity/apptainer branch (Seqera Containers, Galaxy depot), or a plain image (GHCR, built from a module Dockerfile).
#      Each one missing from the cache is fetched under Nextflow's name (URL / image without scheme, ':' and '/' -> '-', + .img):
#      https -> curl; anything else -> `apptainer pull --disable-cache docker://<image>`. Written as <name>.part.<job>, checked to
#      be a SIF (its `run-singularity` header), then renamed. Images already present are only stat'ed (size > 0), never
#      read: a read would reset /share's access clock of every image (--check-all reads them all, by request).
#   2. Commands inside each fetched SIF (--check-all: every SIF): the commands each module using the image runs (parsed from
#      its main.nf, below; shell builtins and the CMD_IGNORE words left out), its templates' interpreter (python3 / Rscript)
#      and Nextflow's wrapper needs (bash cat ps touch). A missing one would fail the task: reported as MISSING (Seqera
#      SIFs have no gzip, cmp, find, ... unless the module's environment.yml declares them).
#   3. Launcher: the `nextflow` prefix of `scripts/build_envs.sh --list`; built (`build_envs.sh --only nextflow`) when the
#      prefix is absent, else checked (`nextflow -version`; launcher_files: the pinned nf-schema plugin's load files).
# One restore job at a time (flock on <cache>/.restore_images.lock; a second one exits 1 at once). Prints what it fetched.
# Never removes anything but its own partial download (<name>.part.<job> of a failed curl/pull): a bad cached file or a
# broken launcher prefix is reported (exit 1) and left; a partial file of an earlier job is reported and left
# for the user to remove. The per-job Apptainer temp/cache dirs are removed with rmdir only when empty.
#
# Submit on hazel from the checkout (after `git pull`), or name it with ZG_REPO:
#   cd /rsstu/users/r/rrellan/BZea/ZEAL/zealgt && sbatch scripts/restore_images.sbatch [--check-all]
# Check only (no job, no fetch, no file read: stat of each image and of the launcher; run by scripts/submit_head_job.sbatch
# before nextflow starts): ZG_REPO=<checkout> bash scripts/restore_images.sbatch --check   (exit 1 = run the restore job)
# Log: /share/maize/frodrig4/nf_work/restore_images_<jobid>.log. Exit 0 = all present and checked; 1 = something to fix.
# (no `set -u`: see the hazel-debug-loop skill)
set -eo pipefail

REPO="${ZG_REPO:-${SLURM_SUBMIT_DIR:?submit with sbatch from the zealgt checkout or set ZG_REPO}}"
[ -f "$REPO/scripts/build_envs.sh" ] || { echo "not a zealgt checkout: $REPO (cd into ZEAL/zealgt before sbatch)" >&2; exit 1; }
CHECK_ALL=false; CHECK_ONLY=false
case "$1" in --check-all) CHECK_ALL=true ;; --check) CHECK_ONLY=true ;; "") ;; *) echo "usage: sbatch scripts/restore_images.sbatch [--check-all] | bash scripts/restore_images.sbatch --check" >&2; exit 2 ;; esac

CACHE="${ZG_IMAGE_CACHE:-/share/maize/frodrig4/apptainer/cache}"   # apptainer.cacheDir of conf/hazel.config (override: tests only)
export PATH=/usr/local/apps/apptainer/1.4.2-1/bin:$PATH
JOB="${SLURM_JOB_ID:-$$}"
export APPTAINER_TMPDIR="$(dirname "$CACHE")/tmp_restore_$JOB" APPTAINER_CACHEDIR="$(dirname "$CACHE")/cachedir_restore_$JOB"
log() { echo "$(date '+%F %T') restore_images: $*"; }
# launcher_files <prefix>: stat only. Prints what is missing of what every head job reads: bin/nextflow, the build record,
# and the nf-schema plugin pinned in nextflow.config (its META-INF/MANIFEST.MF, extensions.idx and lib/*.jar; files a run
# never loads may age out of /share harmlessly, so they are not checked).
launcher_files() {
    local p="$1" v d j miss=""
    [ -x "$p/bin/nextflow" ] || miss="$miss bin/nextflow"
    [ -f "$p/.zg_env_info.tsv" ] || miss="$miss .zg_env_info.tsv"
    v="$(grep -oE "nf-schema@[0-9][0-9.]*" "$REPO/nextflow.config" | head -1)"
    d="$p/share/nextflow/plugins/${v/@/-}"
    if [ -z "$v" ]; then miss="$miss nf-schema-version-in-nextflow.config"
    else
        for j in classes/META-INF/MANIFEST.MF classes/META-INF/extensions.idx; do [ -s "$d/$j" ] || miss="$miss ${v/@/-}/$j"; done
        ls "$d"/lib/*.jar > /dev/null 2>&1 || miss="$miss ${v/@/-}/lib/*.jar"
    fi
    echo "$miss"
}

$CHECK_ONLY || log "job $JOB on $(hostname), repo $REPO at $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown), cache $CACHE"
$CHECK_ONLY || mkdir -p "$CACHE"

# An image set by config instead of a module line would be missed: no config file of the hazel profiles may set one (the
# template's conf/containers_*.config are not included by any profile).
over="$(grep -lE '^[^/]*\bcontainer[ \t]*=' "$REPO"/conf/*.config "$REPO"/nextflow.config 2>/dev/null | grep -v '/conf/containers_' || true)"
[ -z "$over" ] || { log "ERROR: a config sets a container (add it to this script): $over"; exit 1; }

# module dir <TAB> image, one row per module with a container line
mod_images() {
    local f
    for f in "$REPO"/modules/*/*/main.nf "$REPO"/modules/*/*/*/main.nf; do
        [ -f "$f" ] || continue
        awk -v mod="${f#"$REPO"/}" '
            BEGIN { q = "\047" }
            !blk && /^[ \t]*container[ \t]/ {
                if ($0 ~ /\$\{/) { blk = 1 }
                else { s = $0; sub(/^[ \t]*container[ \t]+["\047]/, "", s); sub(/["\047].*$/, "", s); img = s; exit }
            }
            blk && match($0, /https:\/\/[^\047"]+/) { img = substr($0, RSTART, RLENGTH); exit }
            blk && /\}"[ \t]*$/ { exit }
            END { if (blk || img != "") { sub(/\/main\.nf$/, "", mod); print mod "\t" img } }' "$f"
    done
}
sif_name() { local u="${1#https://}"; u="${u#docker://}"; echo "$(echo "$u" | tr '/:' '--').img"; }
is_sif() { case "$(head -c 40 "$1" 2>/dev/null | tr -d '\000')" in *run-singularity*) return 0 ;; *) return 1 ;; esac; }

ROWS="$(mod_images)"
bad_rows="$(printf '%s\n' "$ROWS" | awk -F'\t' '$2 == "" { print $1 }')"
[ -z "$bad_rows" ] || { log "ERROR: container line without an image this script can read: $bad_rows"; exit 1; }
IMAGES="$(printf '%s\n' "$ROWS" | cut -f2 | sort -u)"

# ---- --check: stat only, for the head job ----
if $CHECK_ONLY; then
    miss=""
    while read -r img; do [ -s "$CACHE/$(sif_name "$img")" ] || miss="$miss $(sif_name "$img")"; done <<< "$IMAGES"
    NXF_PREFIX="$(bash "$REPO/scripts/build_envs.sh" --list | awk -F'\t' '$1 == "nextflow" { print $5 }')"
    lmiss="$([ -n "$NXF_PREFIX" ] && launcher_files "$NXF_PREFIX")"
    [ -n "$NXF_PREFIX" ] && [ -z "$lmiss" ] || miss="$miss launcher:${NXF_PREFIX:-no-row}[${lmiss# }]"
    if [ -z "$miss" ]; then
        log "check: all $(printf '%s\n' "$IMAGES" | wc -l | tr -d ' ') images in $CACHE and the launcher present"
        exit 0
    fi
    log "check: MISSING (/share deletes files not read for 30 days):$miss"
    log "check: restore them first: cd $REPO && sbatch scripts/restore_images.sbatch"
    exit 1
fi
log "$(printf '%s\n' "$ROWS" | wc -l | tr -d ' ') modules, $(printf '%s\n' "$IMAGES" | wc -l | tr -d ' ') distinct images; cache files before: $(find "$CACHE" -maxdepth 1 -type f -name "*.img" | wc -l)"

exec 9> "$CACHE/.restore_images.lock"
if command -v flock > /dev/null; then flock -n 9 || { log "ERROR: another restore_images job holds $CACHE/.restore_images.lock; wait for it, then rerun"; exit 1; }; else log "WARN: no flock here (laptop test?): running unlocked"; fi

# ---- 1. images ----
fetched=""; failed=""; badcache=""; n=0; total="$(printf '%s\n' "$IMAGES" | wc -l | tr -d ' ')"
while read -r img; do
    n=$((n + 1)); name="$(sif_name "$img")"; dst="$CACHE/$name"
    if [ -s "$dst" ]; then
        if ! $CHECK_ALL || is_sif "$dst"; then log "[$n/$total] present  $name"; else log "[$n/$total] NOT A SIF (left in place) $dst"; badcache="$badcache $name"; fi
        continue
    fi
    part="$dst.part.$JOB"
    for old in "$dst".part*; do [ ! -e "$old" ] || log "[$n/$total] partial file of an earlier job left in place (remove it by hand): $old"; done
    t0=$(date +%s)
    case "$img" in
        https://*)
            log "[$n/$total] fetching $img (curl)"
            curl -fsSL --retry 3 -o "$part" "$img" < /dev/null || { rm -f "$part"; log "  curl failed: $img"; failed="$failed $name"; continue; } ;;
        *)
            log "[$n/$total] pulling  docker://$img (apptainer pull, its progress below)"
            mkdir -p "$APPTAINER_TMPDIR" "$APPTAINER_CACHEDIR"
            apptainer pull --disable-cache "$part" "docker://$img" 2>&1 < /dev/null || { rm -f "$part"; log "  pull failed: $img"; failed="$failed $name"; continue; } ;;
    esac
    is_sif "$part" || { log "  NOT A SIF (kept as $part): $img"; failed="$failed $name"; continue; }
    mv "$part" "$dst"
    log "  fetched  $name $(du -h "$dst" | cut -f1) in $(( $(date +%s) - t0 )) s"
    fetched="$fetched $name"
done <<< "$IMAGES"

# ---- 2. commands inside the fetched SIFs ----
# The commands a module runs in its image: words in command position (first word of a line, or after | ; & ( { ` $( and
# after then/do/else/if/while/!/time; not assignments) of
#   - the shell text of its script: / stub: blocks (inside """..."""), with comment lines, Groovy ${...}, $((...)) and quoted
#     text dropped (only the $(...) inside "..." kept);
#   - the string literals assigned to a name in the Groovy code there (commands spliced into the script, e.g. DEMUX's
#     `tar -xOf`);
#   - every `eval('...')` output (the versions commands, also run in the image).
# Names the module defines (def, process inputs, shell functions) are skipped. Words of messages and arguments
# (`samtools view`, "... file ...") are not commands: an all-words version flagged as, file, view, conda on the xfer host.
script_cmds() {
    perl -0777 -ne '
        my %skip;                                   # Groovy names (def, inputs) and shell functions of the module
        $skip{$_} = 1 for /\bdef\s+(\w+)/g, /\b(?:path|val|env)\(\s*(\w+)/g, /^\s*(\w+)\s*\(\)\s*\{/mg;
        for my $l (/\bdef\s*\(([^)]*)\)/g) { $skip{$_} = 1 for $l =~ /(\w+)/g }
        sub firsts { my ($t, $skip) = @_; for my $seg (split /\|\||&&|[|;&({`\n]|\$\(/, $t) {
            my @w = split " ", $seg;
            shift @w while @w && ($w[0] =~ /^(then|do|else|elif|if|while|until|!|time|exec)$/ || $w[0] =~ /^[A-Za-z_]\w*=/);
            print "$w[0]\n" if @w && $w[0] =~ /^[A-Za-z][A-Za-z0-9_+-]*$/ && !$skip->{$w[0]};
        } }
        while (/\beval\(\s*([\x27"])(.*?)\1\s*\)/gs) { firsts($2, \%skip) }
        my ($s) = /^\s*(?:script|stub|shell):\s*\n(.*)\z/ms or exit;
        $s =~ s/^\s*(\/\/|#).*$//mg;                # comment lines
        my @part = split /"""/, $s;                 # even: Groovy code, odd: the shell script text
        for my $i (0 .. $#part) {
            my $p = $part[$i];
            $p =~ s/(?<!\\)\$\{[^}]*\}//g;          # Groovy interpolations ${...} (not the escaped shell \${...})
            if ($i % 2 == 0) {                      # Groovy: only the string literals assigned to a name (spliced into the script)
                while ($p =~ /^\s*(?:def\s+)?\w+\s*[+]?=(.*)$/mg) {
                    my $r = $1;
                    while ($r =~ /"((?:\\.|[^"\\])*)"|\x27([^\x27]*)\x27/g) { firsts(defined $1 ? $1 : $2, \%skip) }
                }
                next;
            }
            $p =~ s/\$\(\(.*?\)\)/ /gs;             # shell arithmetic $(( ... ))
            $p =~ s/\\\s*\n/ /g;                    # line continuations
            $p =~ s/(^|\s)(#|\/\/)\s.*$//mg;        # trailing comments
            $p =~ s{"((?:\\.|[^"\\])*)"}{ " ; " . join(" ; ", $1 =~ /\$\(([^)]*)\)/g) . " ; " }ge;   # "..." -> its $(...) only, as commands
            $p =~ s/\x27[^\x27]*\x27/ /g;           # single-quoted text, also multi-line (awk programs)
            firsts($p, \%skip);
        }' "$1" | sort -u
}
# Words in command position that are not programs (Groovy, awk, heredoc words the parser cannot tell apart); everything
# else that is not a shell builtin/keyword is checked inside the image, so tools only in the image (samtools, minibwa,
# bcftools, CRISP) are checked too. A new false MISSING: add the word here.
CMD_IGNORE=" END_VERSIONS ZG_EOF bc1_sample csi tbi "
mod_cmds() {
    local d="$REPO/$1" w out="" t
    for w in $(script_cmds "$d/main.nf"); do
        case "$CMD_IGNORE" in *" $w "*) continue ;; esac
        case "$(type -t "$w")" in builtin|keyword) continue ;; esac
        out="$out $w"
    done
    for t in "$d"/templates/*; do
        [ -f "$t" ] || continue
        out="$out $(head -1 "$t" | awk '/^#!/ { print $NF }')"
    done
    echo "$out"
}
missing_any=""
to_check="$IMAGES"
$CHECK_ALL || to_check="$(printf '%s\n' "$ROWS" | while IFS=$'\t' read -r m i; do case " $fetched " in *" $(sif_name "$i") "*) echo "$i" ;; esac; done | sort -u)"
if [ -z "$to_check" ]; then
    log "commands: nothing fetched, nothing to check (--check-all checks every SIF)"
else
    log "commands inside each SIF (MISSING = a task of that module would fail)"
    while read -r img; do
        sif="$CACHE/$(sif_name "$img")"
        [ -s "$sif" ] || { log "  $(sif_name "$img"): not in the cache, not checked"; continue; }
        mods="$(printf '%s\n' "$ROWS" | awk -F'\t' -v i="$img" '$2 == i { sub(/^.*\//, "", $1); print $1 }' | tr '\n' ' ')"
        cmds="bash cat ps touch"
        for m in $(printf '%s\n' "$ROWS" | awk -F'\t' -v i="$img" '$2 == i { print $1 }'); do cmds="$cmds $(mod_cmds "$m")"; done
        cmds="$(echo $cmds | tr ' ' '\n' | sort -u | tr '\n' ' ')"
        miss="$(apptainer exec --no-home "$sif" sh -c "for c in $cmds; do command -v \$c >/dev/null 2>&1 || printf '%s ' \$c; done" 2>&1 < /dev/null)" \
            || miss="${miss:-} (apptainer exec failed)"
        log "  $(sif_name "$img") [$mods] checked: $cmds| missing: ${miss:-none}"
        [ -z "$miss" ] || missing_any="$missing_any $(sif_name "$img")"
    done <<< "$to_check"
fi

# ---- 3. launcher ----
NXF_PREFIX="$(bash "$REPO/scripts/build_envs.sh" --list | awk -F'\t' '$1 == "nextflow" { print $5 }')"
launcher="ok"
if [ -z "$NXF_PREFIX" ]; then
    log "ERROR: build_envs.sh --list has no nextflow row"; launcher="no row"
elif [ ! -e "$NXF_PREFIX" ]; then
    log "launcher prefix absent: $NXF_PREFIX -> building it (build_envs.sh --only nextflow)"
    if bash "$REPO/scripts/build_envs.sh" --only nextflow; then fetched="$fetched launcher:$(basename "$NXF_PREFIX")"; else launcher="build failed"; fi
fi
if [ "$launcher" = ok ]; then
    v="$(NXF_OFFLINE=true PATH="$NXF_PREFIX/bin:$PATH" nextflow -version 2>&1 < /dev/null | awk '/version/ { print; exit }')" || true
    lmiss="$(launcher_files "$NXF_PREFIX")"
    if [ -z "$lmiss" ] && [ -n "$v" ]; then
        log "launcher ok: $NXF_PREFIX |$v | plugin files present"
    else
        launcher="broken"
        log "ERROR: launcher prefix present but broken (version: '${v:-none}', missing:${lmiss:- none}): $NXF_PREFIX"
        log "  left in place; with the user's consent remove it, then rerun this job (it rebuilds an absent prefix)"
    fi
fi

for d in "$APPTAINER_TMPDIR" "$APPTAINER_CACHEDIR"; do
    [ ! -d "$d" ] || rmdir "$d" 2>/dev/null || log "not empty, left in place: $d"
done

log "summary: fetched:${fetched:- nothing}"
log "summary: failed:${failed:- none} | bad cached files:${badcache:- none} | SIFs with missing commands:${missing_any:- none} | launcher: $launcher"
log "cache files after: $(find "$CACHE" -maxdepth 1 -type f -name "*.img" | wc -l), $(du -sh "$CACHE" | cut -f1)"
[ -z "$failed$badcache$missing_any" ] && [ "$launcher" = ok ] || exit 1
log "done"
