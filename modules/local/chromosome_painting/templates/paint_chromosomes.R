#!/usr/bin/env Rscript
# Chromosome painting of one donor x region (CHROMOSOME_PAINTING, stage 8; PLAN §3 row 8; design §2.7).
#
# Nextflow module template (modules/local/chromosome_painting/main.nf): the Groovy placeholders are filled in by Nextflow,
# so the task hash covers this file's content. No dollar signs or backslashes outside the placeholders (columns are read
# with [[ ]]).
#
# One bar per line: the RTIGER segments coloured by the dosage x (0 = B73, 1 = HET, 2 = donor). Positions outside every
# segment (before the first marker, inside a breakpoint interval) stay white: a no-call is drawn as a no-call, never filled
# from the flanks (PLAN §3 row 8). Lines excluded by LINE_MARKER_QC are drawn as a grey "excluded" bar.
# Outputs <prefix>.painting.png, <prefix>.painting.pdf and <prefix>.chromosome_painting.versions.yml (R, data.table,
# ggplot2). ext.args: --width <in> --height <in> (height default: by the number of lines).
suppressPackageStartupMessages({
    library(data.table)
    library(ggplot2)
})

opt_path <- function(s) {
    s <- trimws(s)
    if (s %in% c("", "[]")) "" else s
}

read_table <- function(path) {
    if (path == "" || !file.exists(path) || file.info(path)[["size"]] == 0) return(NULL)
    d <- fread(path)
    if (nrow(d) == 0) NULL else d
}

# LINE_MARKER_QC's line_qc.tsv: columns sample and line_pass (true|false), one row per contig.
line_qc_table <- function(path) {
    d <- read_table(path)
    if (is.null(d)) return(data.table(line = character(), pass = logical()))
    if (!all(c("sample", "line_pass") %in% names(d))) {
        stop("CHROMOSOME_PAINTING: line_qc needs the LINE_MARKER_QC columns sample and line_pass, has ",
             paste(names(d), collapse = ","))
    }
    v <- tolower(trimws(as.character(d[["line_pass"]])))
    if (!all(v %in% c("true", "false"))) stop("CHROMOSOME_PAINTING: line_pass values must be true or false")
    q <- unique(data.table(line = as.character(d[["sample"]]), pass = v == "true"))
    if (anyDuplicated(q[["line"]])) stop("CHROMOSOME_PAINTING: line_pass of a line differs between its contig rows")
    q
}

parse_opts <- function(s) {
    tok <- strsplit(trimws(s), "[[:space:]]+")[[1]]
    tok <- tok[tok != ""]
    out <- list(width = 10, height = NA_real_)
    i <- 1
    while (i <= length(tok)) {
        key <- sub("^--", "", tok[i])
        if (!(key %in% c("width", "height")) || i == length(tok)) stop(paste("CHROMOSOME_PAINTING: bad option", tok[i]))
        out[[key]] <- as.numeric(tok[i + 1])
        i <- i + 2
    }
    out
}

paint <- function(seg, qc, title) {
    states <- c("0" = "B73 (x = 0)", "1" = "HET (x = 1)", "2" = "donor (x = 2)", "excluded" = "excluded (line QC)")
    cols <- c("B73 (x = 0)" = "#d9d9d9", "HET (x = 1)" = "#f4a261", "donor (x = 2)" = "#9b2226",
              "excluded (line QC)" = "#6c757d")
    seg_lines <- if (is.null(seg)) character() else unique(as.character(seg[["name"]]))
    lines <- sort(unique(c(seg_lines, qc[["line"]])))
    if (length(lines) == 0) {
        return(ggplot() + annotate("text", x = 0, y = 0, label = "no RTIGER segments and no lines") + theme_void() +
               ggtitle(title))
    }
    excluded <- qc[["line"]][!qc[["pass"]]]
    y <- setNames(seq_along(lines), rev(lines))
    xr <- if (is.null(seg)) c(0, 1) else range(c(seg[["start_bp"]], seg[["end_bp"]])) / 1e6
    frame <- data.table(line = lines, xmin = xr[1], xmax = xr[2])
    frame[["y"]] <- y[frame[["line"]]]
    rects <- data.table(line = character(), xmin = numeric(), xmax = numeric(), fill = character())
    if (!is.null(seg)) {
        s <- seg[!(as.character(seg[["name"]]) %in% excluded)]
        rects <- data.table(line = as.character(s[["name"]]), xmin = s[["start_bp"]] / 1e6, xmax = s[["end_bp"]] / 1e6,
                            fill = unname(states[as.character(s[["state"]])]))
    }
    if (length(excluded)) {
        rects <- rbind(rects, data.table(line = excluded, xmin = xr[1], xmax = xr[2], fill = states[["excluded"]]))
    }
    rects[["y"]] <- y[rects[["line"]]]
    ggplot() +
        geom_rect(data = frame, aes(xmin = xmin, xmax = xmax, ymin = y - 0.4, ymax = y + 0.4), fill = "white",
                  colour = "grey70", linewidth = 0.2) +
        geom_rect(data = rects, aes(xmin = xmin, xmax = xmax, ymin = y - 0.4, ymax = y + 0.4, fill = fill)) +
        scale_fill_manual(values = cols, drop = FALSE, name = NULL) +
        scale_y_continuous(breaks = unname(y), labels = names(y), expand = c(0.01, 0.01)) +
        labs(x = "position (Mb)", y = NULL, title = title,
             subtitle = "RTIGER segments; white = no call (outside every segment)") +
        theme_minimal(base_size = 9) +
        theme(panel.grid.major.y = element_blank(), legend.position = "bottom")
}

main <- function() {
    prefix <- "${task.ext.prefix ?: meta.id}"
    process <- "${task.process}"
    segments <- opt_path("${segments}")
    line_qc <- opt_path("${line_qc}")
    opts <- parse_opts("${task.ext.args ?: ''}")

    seg <- read_table(segments)
    if (!is.null(seg)) {
        need <- c("name", "chr", "start_bp", "end_bp", "state")
        miss <- setdiff(need, names(seg))
        if (length(miss)) stop(paste("CHROMOSOME_PAINTING: segments lack columns", paste(miss, collapse = ", ")))
    }
    qc <- line_qc_table(line_qc)
    p <- paint(seg, qc, prefix)
    n <- length(unique(c(if (is.null(seg)) character() else as.character(seg[["name"]]), qc[["line"]])))
    h <- if (is.na(opts[["height"]])) max(3, 0.16 * n + 1.6) else opts[["height"]]
    if (capabilities("cairo")) {
        ggsave(paste0(prefix, ".painting.png"), p, width = opts[["width"]], height = h, dpi = 150, type = "cairo")
    } else {
        ggsave(paste0(prefix, ".painting.png"), p, width = opts[["width"]], height = h, dpi = 150)
    }
    ggsave(paste0(prefix, ".painting.pdf"), p, width = opts[["width"]], height = h)
    message(sprintf("[chromosome_painting] %s: %d lines (%d excluded), %d segments", prefix, n, sum(!qc[["pass"]]),
                    if (is.null(seg)) 0L else nrow(seg)))
    writeLines(c(paste0('"', process, '":'),
                 paste0("    r-base: ", format(getRversion())),
                 paste0("    r-data.table: ", format(packageVersion("data.table"))),
                 paste0("    r-ggplot2: ", format(packageVersion("ggplot2")))),
               paste0(prefix, ".chromosome_painting.versions.yml"))
}

main()
