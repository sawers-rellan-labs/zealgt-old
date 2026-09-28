#!/usr/bin/env Rscript
# Ancestry inference of stage 4 (RTIGER, design §2.3; PLAN §3 row 4, §4 #10; the maths of zealbc1 PHG/bin/rtiger_poolseq.R).
#
# Nextflow module template (modules/local/rtiger/main.nf): the Groovy placeholders are filled in by Nextflow, so the task hash
# covers this file's content, not its path. No backslashes or dollar signs outside the placeholders (R list access uses [[ ]]).
#
# Per donor x region: the LINE_MARKER_QC counts of the lines that passed the coverage floor (SAMPLE CONTIG POSITION REF_COUNT
# ALT_COUNT REF_NUCLEOTIDE ALT_NUCLEOTIDE) -> nilHMM::call_ancestry(caller = "rtiger", rigidity) (nilHMM 0.3.0, the Julia-free
# RTIGER port; no design prior enters, RTIGER learns its transition and emission parameters from the data, PLAN §4 #10) ->
# <prefix>.segments.csv: source, donor, name, chr, start_bp, end_bp, state (0 / 1 / 2 = copies of the donor segment, x).
# chr is the integer chromosome (chrom_int input; nilHMM needs an integer chr). Observations with 0 reads are dropped, as
# zealbc1 did (nilHMM min_reads = 1). When no line passed LINE_MARKER_QC the CSV has the header only and a warning is written
# (exit 0): the region has no ancestry, which every later stage sees as "ancestry unknown".
# Threads: ZG_CPUS from bin/export_slurm_resources.sh (run through bash here, since this is an R template), passed to nilHMM
# (threads = parallel chains, identical results to 1 thread). RcppParallel gets 1 thread (RCPP_PARALLEL_NUM_THREADS, set
# before the package loads): nilHMM threads > 1 together with RcppParallel threads > 1 crashed R on hazel ('C stack usage
# too close to the limit', segfault; Gate 1, job 974346), while either one alone ran and gave identical segments. Options (ext.args): --seed N (nilHMM rtiger's randomised init, default 1 = the nilHMM default).
# The versions of R, nilHMM and data.table go into <prefix>.rtiger.versions.yml (the process uses storeDir).

prefix <- "${task.ext.prefix ?: meta.id}"
proc <- "${task.process}"
counts_f <- "${counts}"
rigidity <- as.integer("${rigidity}")
chr_int <- as.integer("${chrom_int}")
donor_label <- "${donor}"
ext_args <- strsplit(trimws("${task.ext.args ?: ''}"), "[[:space:]]+")[[1]]

opt <- function(name, default) {
  i <- match(name, ext_args)
  if (is.na(i)) return(default)
  if (i == length(ext_args)) stop(sprintf("%s: option %s needs a value", proc, name))
  ext_args[[i + 1L]]
}
seed <- as.integer(opt("--seed", "1"))
if (is.na(rigidity) || rigidity < 1L) stop(sprintf("%s: rigidity must be an integer >= 1", proc))
if (is.na(chr_int)) stop(sprintf("%s: chrom_int must be an integer chromosome number", proc))

# resources from the shared helper (Slurm allocation, or the explicit local override); it stops the task when neither is set
res <- suppressWarnings(system2("bash", c("-c", shQuote("source export_slurm_resources.sh && printenv ZG_CPUS")),
                                stdout = TRUE))
status <- attr(res, "status")
if (!is.null(status) && status != 0L) stop(sprintf("%s: export_slurm_resources.sh failed (status %d)", proc, status))
threads <- as.integer(utils::tail(res, 1L))
if (length(threads) != 1L || is.na(threads) || threads < 1L) stop(sprintf("%s: could not read ZG_CPUS", proc))
Sys.setenv(RCPP_PARALLEL_NUM_THREADS = "1")

suppressPackageStartupMessages({
  library(data.table)
  library(nilHMM)
})

cols <- c("source", "donor", "name", "chr", "start_bp", "end_bp", "state")
out_f <- paste0(prefix, ".segments.csv")
ct <- fread(counts_f, sep = intToUtf8(9L), header = TRUE, colClasses = list(character = c(1L, 2L, 6L, 7L)))
if (ncol(ct) != 7L) stop(sprintf("%s: %s has %d columns, expected 7", proc, counts_f, ncol(ct)))
setnames(ct, c("SAMPLE", "CONTIG", "POSITION", "REF_COUNT", "ALT_COUNT", "REF_NUCLEOTIDE", "ALT_NUCLEOTIDE"))
if (uniqueN(ct[["CONTIG"]]) > 1L) stop(sprintf("%s: counts span %d contigs; one region = one chromosome", proc,
                                               uniqueN(ct[["CONTIG"]])))
obs <- ct[REF_COUNT + ALT_COUNT > 0,
          list(name = SAMPLE, chr = chr_int, pos = as.integer(POSITION), n_ref = as.integer(REF_COUNT),
               n_alt = as.integer(ALT_COUNT))]

if (nrow(obs) == 0L) {
  message(sprintf("WARN %s %s: no line passed LINE_MARKER_QC (0 observations); writing an empty segments table", proc,
                  prefix))
  seg_out <- data.table(source = character(), donor = character(), name = character(), chr = integer(),
                        start_bp = integer(), end_bp = integer(), state = integer())
} else {
  message(sprintf("%s %s: %d lines, %d markers, %d observations, rigidity %d, threads %d, seed %d", proc, prefix,
                  uniqueN(obs[["name"]]), uniqueN(obs[["pos"]]), nrow(obs), rigidity, threads, seed))
  t0 <- Sys.time()
  seg <- as.data.table(call_ancestry(as.data.frame(obs), caller = "rtiger", rigidity = rigidity, threads = threads,
                                     seed = seed))
  message(sprintf("%s %s: %d segments in %.1f min", proc, prefix, nrow(seg),
                  as.numeric(difftime(Sys.time(), t0, units = "mins"))))
  seg_out <- seg[, list(source = "RTIGER_poolseq", donor = donor_label, name, chr = chr_int, start_bp, end_bp, state)]
  missing_lines <- setdiff(unique(obs[["name"]]), unique(seg_out[["name"]]))
  if (length(missing_lines)) stop(sprintf("%s: RTIGER returned no segments for %s", proc,
                                          paste(missing_lines, collapse = ", ")))
  print(seg_out[, list(Mb = sum(end_bp - start_bp) / 1e6, segments = .N), by = state][order(state)])
}
setcolorder(seg_out, cols)
fwrite(seg_out, out_f)

rver <- paste0(R.version[["major"]], ".", R.version[["minor"]])
writeLines(c(paste0('"', proc, '":'),
             paste0("    r-base: ", rver),
             paste0("    nilhmm: ", as.character(packageVersion("nilHMM"))),
             paste0("    r-data.table: ", as.character(packageVersion("data.table")))),
           paste0(prefix, ".rtiger.versions.yml"))
