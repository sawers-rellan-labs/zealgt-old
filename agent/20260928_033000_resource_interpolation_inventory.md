# Resource interpolation inventory (Phase B, 2026-09-28)

`grep -n -E "task\.(cpus|memory|attempt)" modules/nf-core/*/main.nf modules/nf-core/*/*/main.nf conf/modules.config`
after installing trimmomatic, samtools/stats, picard/collectwgsmetrics (fastqc, multiqc installed in Phase A). nf-core/modules
git_sha per module: see modules.json.

| module | line (upstream) | interpolation | purpose | action |
|---|---|---|---|---|
| fastqc | main.nf:31-33, 46 | `task.memory.toUnit('MB') / task.cpus` -> `--memory`; `--threads ${task.cpus}` | memory arg (JVM heap per thread), thread arg | **patched**: `--threads ${ZG_CPUS}`, `--memory $(( ZG_JAVA_MEM_MB / ZG_CPUS ))` clamped to FastQC's 100-10000 range in bash |
| trimmomatic | main.nf:35 | `-threads $task.cpus` | thread arg | **patched**: `-threads ${ZG_CPUS}`; plus `-Xmx${ZG_JAVA_MEM_MB}m` (the bioconda wrapper otherwise runs with its default `-Xmx1g`, a resource value, not a computation change) |
| samtools/stats | main.nf:29 | `--threads ${task.cpus}` | thread arg | **patched**: `--threads ${ZG_CPUS}` |
| picard/collectwgsmetrics | main.nf:28-32 | `task.memory.mega * 0.8` -> `-Xmx` | JVM heap | **patched**: `-Xmx${ZG_JAVA_MEM_MB}M` (helper: ZG_MEM_MB - 2048 MB headroom) |
| multiqc | — | none | — | unpatched (no task.* in the script) |
| conf/modules.config | — | none (ext.args closures use params only) | — | — |

Every patched script sources `${projectDir}/bin/slurm_resources.sh` as its first line; the patch comment above each `script:` block
says why. The patches change only resource values: inputs, outputs, labels, emitted channels and every computed argument are upstream.
Local modules (DEMUX, DEMUX_QC, ALIGN_MARKDUP, MARKDUP_IMPORT, PROVENANCE, REGISTRY) never read task.cpus / task.memory / task.attempt in
their scripts; they source the same helper.

`task.attempt` appears only in config (memory escalation `24.GB * task.attempt` for ALIGN_MARKDUP, base.config labels), never in a
script, so a retry at a higher memory does not change the task hash (to be confirmed by the Gate 1 cache check, tests A/C/D).
