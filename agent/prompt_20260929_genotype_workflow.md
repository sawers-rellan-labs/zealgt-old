You are drafting the zealgt **genotype workflow** (`workflows/genotype.nf`, today a 13-line stub) on branch `genotype` in
/Users/fvrodriguez/repos/zealgt-genotype, and taking it up the testing ladder to Gate 1 on hazel. Another session owns the CRAM workflow
on `main` (/Users/fvrodriguez/repos/zealgt) and is running its Gate 2 on hazel right now; the CRAM store is the only contract between
the two workflows (docs/PLAN_pipeline.md §3).

## Where you work: branch `genotype`, its own checkouts (set up 2026-09-29)
- Laptop: the git worktree **/Users/fvrodriguez/repos/zealgt-genotype** (branch `genotype`, tracking origin/genotype). All your git
  commands use `git -C /Users/fvrodriguez/repos/zealgt-genotype …`. Never touch /Users/fvrodriguez/repos/zealgt (the CRAM session's
  `main` checkout) and never `git checkout` another branch in either directory. Wherever this prompt says /Users/fvrodriguez/repos/zealgt
  for your own files (agent/ scripts, commits, pushes), use the worktree path.
- hazel: the clone **/rsstu/users/r/rrellan/BZea/ZEAL/zealgt-genotype** (branch `genotype`, core.fileMode false). Pull there:
  `ssh hazel 'git -C /rsstu/users/r/rrellan/BZea/ZEAL/zealgt-genotype pull --ff-only'`. Never use ZEAL/zealgt (CRAM Gate 2 runs from
  it). Launch and work dirs under /share/maize/frodrig4/nf_work/genotype_<run>/ so nothing collides with CRAM runs.
- Push: `git -C /Users/fvrodriguez/repos/zealgt-genotype push origin genotype`. Bring CRAM fixes in regularly:
  `git -C /Users/fvrodriguez/repos/zealgt-genotype fetch origin`, then `git -C /Users/fvrodriguez/repos/zealgt-genotype merge origin/main`;
  resolve shared-file conflicts minimally; never hand-merge conf/env_prefixes.config — regenerate it with
  `bash scripts/build_envs.sh --write-config` and commit.
- Merge back: after Gate 1 passes and CodeRabbit is clean on the branch, open a PR `genotype` → `main` (`gh pr create`) and stop; the
  user approves and merges. Env prefixes are content-hashed, so both checkouts share /share/maize/frodrig4/conda/zealgt/ safely.

## How to work: you are a coordinator, subagents do the work
Your own context has to last the whole task. Do not read large files, run builds, write modules or debug on hazel yourself.
- Split the work into phases (below). Launch one subagent per phase with a self-contained prompt: what to read, what to build, the
  rules of this file, the files it may touch, and "write agent/handover_<YYYYMMDD_HHMMSS>_genotype_<phase>.md and return a SHORT
  report (≤ 15 lines)". Read only its short report; open its handover only for a specific fact.
- Run independent phases in parallel (e.g. read-only research next to an env build); never two agents writing the same files.
- Relay facts between agents with SendMessage (short, concrete). A stopped agent is not resumed: start a fresh one from its handover.
- Read-only questions (a spec detail, where a file lives on hazel, a small test of a hypothesis) also go to small subagents.
- Keep the user informed in a few lines per event: what finished, what was decided, what runs next, where to `tail -f`.

## Read first (the subagents read these in full; you skim what you need)
CLAUDE.md; `.claude/skills/nfcore-compliance/SKILL.md` (spec rules + pre-push checklist); `.claude/skills/hazel-debug-loop/SKILL.md`
(git-only transfer, Slurm, job environment, env builds, fix loop, testing-ladder lessons); `docs/PLAN_pipeline.md` §2 (principles,
hash hygiene), §3 genotype rows 2b–8 and stage 6 (two-step gap filling), §4 (known issues and their decisions), §6 (testing ladder),
§7 (open decisions → run-card parameters, never code choices); `docs/math_supplement.tex` (models of stages 3–6);
`docs/REQUIREMENTS.md` (inputs, measured resources); `meta/PROVENANCE.md` (read structures and kits; the batch-1 primer bases);
`agent/handover_20260927_213500_review_check.md` and `agent/handover_20260928_093000_adversarial_review.md` (fixes the genotype
workflow must include: step 2 carries the step-4 flags and treats x = 0 line reads as zero-class reads; step-4 tables keyed by module
version / run in the store; per-sample counts batched per donor × chromosome); `agent/handover_20260928_200000_refactor.md` and
`agent/handover_20260928_233000_gate01.md` (how the CRAM workflow is built: dispatcher, nf-schema sheets, env framework, Slurm
resource helper, stub guard, commands); `agent/20260928_163000_alt_by_read_position.md` (5'-end reference bias in existing CRAMs).
Algorithm code you may read for the maths only (rewrite as modules, do not port): zealbc1 `PHG/bin/*.py` at /Users/fvrodriguez/repos/zealbc1.

## What to build
- Entries per PLAN §3: sample_quality_control, variant_discovery, ancestry_inference, marker_union, donor_allele_calling,
  genotype_imputation (RASTERIZE; PHG optional, §7), reporting — selected by the existing `--workflow genotype` / `--entry` dispatcher.
  Inputs: the CRAM store + a sample sheet (nf-schema) + a run card (`-params-file`, every §7 open decision a schema param).
- One module per step, nf-core conventions (the nfcore-compliance skill): standard meta keys only, versions, meta.yml, stub, nf-test
  with snapshots, helper scripts as module templates or bin/ on PATH with verb_object names, nf-core modules where they exist
  (bcftools/mpileup etc.), changes to them only via `nf-core modules patch`.
- Environments: one pinned environment.yml per module (only the tools its script calls; versions from `envs/legacy_zealbc1/` where
  zealbc1 ran them); non-conda tools by a pinned-commit build.sh (CRISP = vibansal/crisp @ 1a9027e; nilHMM = sawers-rellan-labs/nilhmm
  @ 248e67e, RTIGER caller); registered with `bash scripts/build_envs.sh --write-config`; built on hazel by `scripts/build_envs.sbatch` (xfer) into
  /share/maize/frodrig4/conda/zealgt/ — never on /rsstu, never at task time. Push env ymls early as their own commit so the build runs in
  parallel with the module code.
- Resources from REQUIREMENTS §4 (variant_discovery donor × chr10: 8 cpu / 48 GB req., 8–17 min; RTIGER 4 cpu / 16 GB; counts batched);
  all genotype tasks on the short QOS.

## Rules (the user's; non-negotiable)
- Multi-line commands → `agent/<YYYYMMDD_HHMMSS>_<verb_object>.<ext>`, then run. Git and ssh as single plain commands:
  `git -C /Users/fvrodriguez/repos/zealgt push origin main`, `ssh hazel '…'`, `sbatch …` — never chained with cd / && / ; / pipes
  (chained commands are blocked by the permission rules).
- Stage explicitly (`git add <paths>`; agent/ files need -f); never stage `docs/math_supplement.tex` or files you did not write;
  commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. The CRAM session commits in the same repo: pull --rebase
  before push; do not edit the CRAM workflow's files (workflows/cram.nf, modules/local/{demux,demux_qc,align_markdup,markdup_import,
  provenance,registry}, the trimmomatic patch, conf entries of CRAM processes). Shared files (main.nf dispatcher, nextflow.config,
  nextflow_schema.json, conf/modules.config, conf/env_prefixes.config): minimal additive edits in their own commits.
- No deletions (no rm -r, no nextflow clean, never overwrite stored CRAMs or tables) without the user's explicit consent for that
  target; `ls` a path before any removal the user approves.
- CodeRabbit gate: `coderabbit review --committed --base-commit <last reviewed commit> --agent` must pass (real findings fixed,
  rejections recorded with reasons in agent/) on the exact commit before anything runs on real data, and again after every fix.
- Nothing heavy on the login node; all compute through Slurm, short QOS (`--account=maize_cpu --partition=compute_partners --qos=short`).
- nf-core template structure; no bundled envs; envs on /share only.
- When the plan leaves a decision open, make it a run-card parameter and list it in your handover; do not ask unless it blocks.

## Phases (suggested)
1. Design (read-only subagent): process list per entry with inputs/outputs, channel shape, per-module tools and pinned versions, the
   run-card parameters, and how each review-check finding is met → `agent/<ts>_genotype_design.md`. You check it against PLAN §3/§4.
2. Envs: ymls + build.sh committed and pushed first; a hazel subagent builds them (xfer) and smoke-tests them.
3. Modules + workflow wiring + nf-test + lint (pre-push checklist of the nfcore-compliance skill) + CodeRabbit → push.
4. Gate 0 on hazel: `-stub-run` of every genotype entry (short QOS).
5. Gate 1 on hazel: the smallest real unit — one donor (Zx.0540_P3) × a small region of chr10, from CRAMs in the store
   (the markdup-imported dev CRAMs of meta/dev_import.csv; ask the CRAM session's handovers where they are stored). The small run must
   go through the same code path as the full run. Compare with the zealbc1 pilot outputs for the same donor/region
   (results/bench_zx0540_chr10/) and report differences.
Stop after Gate 1. Gate 2 (two mexicana donors × chr10) needs the user's go.

## Output
`agent/handover_<YYYYMMDD_HHMMSS>_genotype_workflow.md`: layout, entries and params, env table, gate reached per entry with job ids
and Nextflow session ids, CodeRabbit results, measured resources (also in docs/REQUIREMENTS.md §4), every open decision, the exact
next command. Claims tied to file:line or a job id.
