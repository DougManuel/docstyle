#' Package a rendered LaTeX document for arXiv submission
#'
#' Takes a rendered `.tex` file (typically from `quarto render` with
#' `keep-tex: true`) and produces a submission-ready archive:
#' - copies figures referenced by `\includegraphics{...}` into the staging
#'   directory, optionally flattening subdirectory paths;
#' - copies `.sty`/`.cls` files from the `.tex` directory that are actually
#'   `\usepackage`'d or `\documentclass`'d by the document;
#' - rewrites `\includegraphics` paths to match the flattened layout;
#' - runs a pre-flight check (every figure resolves, no parent-directory
#'   references, no basename collisions);
#' - assembles a `.tar.gz` or `.zip` archive.
#'
#' The function is format-agnostic -- it takes a `.tex` path as input, so any
#' LaTeX-producing Quarto format works (e.g. `arxiv-pdf`,
#' `mikemahoney218/quarto-arxiv`, or a future `docstyle-arxiv`).
#'
#' @param tex_path Path to the rendered `.tex` file.
#' @param output_path Optional output archive path. Defaults to
#'   `<tex_stem>-arxiv.<ext>` in the same directory as `tex_path`, where
#'   `<ext>` matches `archive_format` (`.tar.gz` or `.zip`).
#' @param style_files Optional character vector of `.sty`/`.cls` paths to
#'   bundle. If NULL, auto-discovers files in the `.tex` directory whose
#'   stem is `\usepackage{...}`'d or `\documentclass{...}`'d by the tex.
#' @param bib_path Optional path to a `.bib` file. If NULL and the `.tex`
#'   contains `\bibliography{...}`, auto-detects the first entry. A `.bbl`
#'   sibling of the `.tex` (biber/bibtex output) is auto-included
#'   independently. For citeproc-inlined bibliographies, no file is needed.
#' @param extra_files Optional character vector of additional files to
#'   include in the archive (e.g. a README, cover letter).
#' @param flatten Logical. If TRUE (default), subdirectory references like
#'   `\includegraphics{images/fig1.png}` are flattened to
#'   `\includegraphics{fig1.png}` and figures copied to the archive root.
#'   arXiv's submission guidance recommends a flat directory layout;
#'   flattening is the safest default.
#' @param archive_format One of `"tar.gz"` (arXiv's documented preference) or
#'   `"zip"` (also accepted).
#' @param verbose Logical. Print progress messages.
#' @return Invisibly, a list with:
#'   - `archive_path`: path to the created archive
#'   - `manifest`: character vector of files included
#'   - `rewrites`: named character vector of `old_path = new_path` for
#'     figures that were flattened
#'   - `warnings`: character vector of non-fatal issues
#' @export
package_arxiv <- function(tex_path,
                          output_path = NULL,
                          style_files = NULL,
                          bib_path = NULL,
                          extra_files = NULL,
                          flatten = TRUE,
                          archive_format = c("tar.gz", "zip"),
                          verbose = TRUE) {

  archive_format <- match.arg(archive_format)

  if (!file.exists(tex_path)) {
    stop("TeX file not found: ", tex_path, call. = FALSE)
  }

  tex_path   <- normalizePath(tex_path)
  source_dir <- dirname(tex_path)
  tex_stem   <- tools::file_path_sans_ext(basename(tex_path))

  if (is.null(output_path)) {
    ext <- if (archive_format == "tar.gz") ".tar.gz" else ".zip"
    output_path <- file.path(source_dir, paste0(tex_stem, "-arxiv", ext))
  }
  output_path <- normalizePath(output_path, mustWork = FALSE)

  # Fail early if the output directory doesn't exist -- utils::tar() would
  # otherwise produce a cryptic "cannot open" error downstream.
  if (!dir.exists(dirname(output_path))) {
    stop("Output directory does not exist: ", dirname(output_path),
         call. = FALSE)
  }

  vmsg <- function(...) if (verbose) message("[package-arxiv] ", ...)
  warnings_out <- character()

  tex_lines <- readLines(tex_path, warn = FALSE)
  tex_text  <- paste(tex_lines, collapse = "\n")

  # -- 1. Discover figure references -----------------------------------------
  figure_refs <- find_includegraphics(tex_text)
  vmsg("Found ", length(figure_refs), " \\includegraphics reference(s)")

  figure_paths <- resolve_figure_paths(figure_refs, source_dir)
  missing_figs <- figure_paths$path[is.na(figure_paths$resolved)]
  if (length(missing_figs) > 0) {
    stop("Figure(s) not found relative to ", source_dir, ":\n  ",
         paste(missing_figs, collapse = "\n  "),
         "\nCheck \\includegraphics paths in the .tex file.", call. = FALSE)
  }

  # Warn on casing drift (macOS/Windows case-insensitive filesystems vs
  # arXiv's Linux case-sensitive AutoTeX). If the queried casing doesn't
  # match the on-disk casing, the staged tex will reference a name the
  # Linux build can't find.
  casing_drifts <- detect_casing_drift(figure_paths, source_dir)
  if (length(casing_drifts) > 0) {
    warnings_out <- c(warnings_out,
      paste("Figure path casing differs from disk (case-sensitive arXiv build",
            "may fail):", paste(casing_drifts, collapse = ", ")))
  }

  parent_refs <- figure_paths$path[grepl("\\.\\./", figure_paths$path)]
  if (length(parent_refs) > 0 && flatten) {
    warnings_out <- c(warnings_out,
      paste("Figure path(s) use '../' -- these may fail on arXiv AutoTeX: ",
            paste(parent_refs, collapse = ", ")))
  }

  target_names <- if (flatten) {
    basename(figure_paths$resolved)
  } else {
    figure_paths$path
  }
  dup_targets <- target_names[duplicated(target_names)]
  if (length(dup_targets) > 0) {
    warnings_out <- c(warnings_out,
      paste("Figure basename collision after flatten:",
            paste(unique(dup_targets), collapse = ", "),
            "-- later copies will overwrite earlier ones. Rename sources ",
            "or call with flatten = FALSE."))
  }

  figure_paths$target <- target_names

  # -- 2. Discover bibliography ----------------------------------------------
  if (is.null(bib_path)) {
    bib_match <- regmatches(tex_text,
                            regexpr("\\\\bibliography\\{([^}]+)\\}", tex_text))
    if (length(bib_match) > 0) {
      bib_stems <- sub("\\\\bibliography\\{([^}]+)\\}", "\\1", bib_match)
      bib_stems <- trimws(strsplit(bib_stems, ",")[[1]])
      # Only the first entry is auto-detected; warn if more were requested
      # so the user knows to pass bib_path = c(...) explicitly.
      if (length(bib_stems) > 1L) {
        warnings_out <- c(warnings_out,
          paste("\\bibliography{} lists multiple entries (",
                paste(bib_stems, collapse = ", "),
                "); auto-detect only picked the first.",
                "Pass extras via bib_path= to include them."))
      }
      candidate <- file.path(source_dir, paste0(bib_stems[1L], ".bib"))
      if (file.exists(candidate)) {
        bib_path <- candidate
      } else {
        warnings_out <- c(warnings_out,
          paste0("\\bibliography{", bib_stems[1L], "} found in tex but ",
                 basename(candidate), " does not exist in ", source_dir))
      }
    }
  }
  # A .bbl alongside the .tex ships if present (biber/bibtex output). arXiv
  # requires this file because it doesn't run bibtex itself.
  bbl_candidate <- file.path(source_dir, paste0(tex_stem, ".bbl"))
  bbl_path <- if (file.exists(bbl_candidate)) bbl_candidate else NULL

  # -- 3. Discover style files -----------------------------------------------
  if (is.null(style_files)) {
    style_files <- discover_style_files(tex_text, source_dir)
  }
  vmsg("Style files: ",
       if (length(style_files)) paste(basename(style_files), collapse = ", ")
       else "(none)")

  # -- 4. Stage everything in a temp dir -------------------------------------
  # Order matters: restore cwd BEFORE unlinking staging so we don't linger in
  # a deleted directory on interrupt or error.
  old_wd <- getwd()
  staging <- tempfile("arxiv_pkg_")
  dir.create(staging)
  on.exit(setwd(old_wd), add = TRUE, after = FALSE)
  on.exit(unlink(staging, recursive = TRUE), add = TRUE)

  manifest <- character()

  staged_tex <- file.path(staging, basename(tex_path))
  if (flatten && nrow(figure_paths) > 0) {
    rewritten <- rewrite_includegraphics(tex_text, figure_paths)
    tryCatch(
      writeLines(strsplit(rewritten, "\n", fixed = TRUE)[[1]], staged_tex),
      error = function(e) stop("Failed to write staged .tex: ",
                               conditionMessage(e), call. = FALSE))
  } else {
    safe_copy(tex_path, staged_tex)
  }
  manifest <- c(manifest, basename(tex_path))

  if (nrow(figure_paths) > 0) {
    for (i in seq_len(nrow(figure_paths))) {
      target <- file.path(staging, figure_paths$target[i])
      if (!flatten) dir.create(dirname(target), showWarnings = FALSE,
                               recursive = TRUE)
      safe_copy(figure_paths$resolved[i], target, overwrite = TRUE)
      manifest <- c(manifest, figure_paths$target[i])
    }
  }

  for (sf in style_files) {
    safe_copy(sf, file.path(staging, basename(sf)))
    manifest <- c(manifest, basename(sf))
  }

  if (!is.null(bib_path) && file.exists(bib_path)) {
    safe_copy(bib_path, file.path(staging, basename(bib_path)))
    manifest <- c(manifest, basename(bib_path))
  }
  if (!is.null(bbl_path)) {
    safe_copy(bbl_path, file.path(staging, basename(bbl_path)))
    manifest <- c(manifest, basename(bbl_path))
  }

  for (ef in extra_files) {
    if (!file.exists(ef)) {
      warnings_out <- c(warnings_out,
                        paste("Extra file not found, skipped:", ef))
      next
    }
    safe_copy(ef, file.path(staging, basename(ef)))
    manifest <- c(manifest, basename(ef))
  }

  # -- 5. Create archive -----------------------------------------------------
  setwd(staging)

  files_to_archive <- list.files(".", recursive = TRUE)
  if (archive_format == "tar.gz") {
    # tar = "internal" avoids shelling out to system tar, which on macOS can
    # embed AppleDouble ._* metadata files that arXiv's AutoTeX rejects.
    # COPYFILE_DISABLE=1 belt-and-braces for any residual extended attrs.
    old_cfd <- Sys.getenv("COPYFILE_DISABLE", unset = NA)
    Sys.setenv(COPYFILE_DISABLE = "1")
    on.exit({
      if (is.na(old_cfd)) Sys.unsetenv("COPYFILE_DISABLE")
      else Sys.setenv(COPYFILE_DISABLE = old_cfd)
    }, add = TRUE)

    status <- utils::tar(output_path, files = files_to_archive,
                         compression = "gzip", tar = "internal")
  } else {
    status <- utils::zip(output_path, files = files_to_archive, flags = "-q")
  }

  if (!isTRUE(status == 0L) || !file.exists(output_path) ||
      file.size(output_path) == 0L) {
    stop("Archive creation failed (status=", status, "): ", output_path,
         call. = FALSE)
  }

  vmsg("Created: ", output_path, " (", length(manifest), " files)")
  if (length(warnings_out) > 0) {
    for (w in warnings_out) vmsg("WARNING: ", w)
  }

  invisible(list(
    archive_path = output_path,
    manifest     = manifest,
    rewrites     = if (flatten) setNames(figure_paths$target,
                                         figure_paths$path) else character(),
    warnings     = warnings_out
  ))
}


#' Copy a file or abort with context
#'
#' `file.copy()` returns FALSE with a warning on failure rather than
#' throwing. Silent-archive-with-missing-file is a common failure mode;
#' this helper converts it to a hard error.
#' @noRd
safe_copy <- function(src, dst, overwrite = FALSE) {
  ok <- file.copy(src, dst, overwrite = overwrite)
  if (!isTRUE(ok)) {
    stop("Failed to copy ", src, " -> ", dst, call. = FALSE)
  }
  invisible(TRUE)
}


#' Parse \\includegraphics{...} and \\includegraphics*{...} references
#'
#' Handles the optional starred form (not common but legal LaTeX) and the
#' optional `[options]` block. `[^}]+` captures the inner argument; this is
#' safe because LaTeX paths can't contain literal `}`.
#' @noRd
find_includegraphics <- function(tex_text) {
  m <- gregexpr("\\\\includegraphics\\*?(?:\\[[^\\]]*\\])?\\{([^}]+)\\}",
                tex_text, perl = TRUE)
  matches <- regmatches(tex_text, m)[[1]]
  if (length(matches) == 0) return(character())
  sub("\\\\includegraphics\\*?(?:\\[[^\\]]*\\])?\\{([^}]+)\\}", "\\1",
      matches, perl = TRUE)
}


#' Resolve figure paths relative to the .tex source directory
#' LaTeX allows \\includegraphics{fig1} (no extension); we probe common ones.
#' @noRd
resolve_figure_paths <- function(paths, source_dir) {
  exts <- c("", ".png", ".pdf", ".jpg", ".jpeg", ".eps", ".svg")
  resolve_one <- function(p) {
    for (ext in exts) {
      candidate <- file.path(source_dir, paste0(p, ext))
      if (file.exists(candidate)) return(normalizePath(candidate))
    }
    NA_character_
  }
  data.frame(
    path     = paths,
    resolved = vapply(paths, resolve_one, character(1)),
    stringsAsFactors = FALSE
  )
}


#' Detect case differences between queried paths and actual disk filenames
#'
#' On case-insensitive filesystems (macOS APFS/HFS+ default, Windows NTFS
#' default), `file.exists("Fig1.png")` returns TRUE when the disk has
#' `fig1.png`. arXiv's Linux AutoTeX is case-sensitive and will fail to find
#' the figure. Returns the queried paths whose basename doesn't match the
#' actual on-disk basename.
#' @noRd
detect_casing_drift <- function(figure_paths, source_dir) {
  drifts <- character()
  for (i in seq_len(nrow(figure_paths))) {
    resolved <- figure_paths$resolved[i]
    if (is.na(resolved)) next
    actual_name <- basename(resolved)
    # What the tex asked for (possibly with subdir prefix). Compare basename
    # to actual basename of the resolved file.
    queried_basename <- basename(figure_paths$path[i])
    # resolve_figure_paths may have added an extension; strip any probed ext
    # and compare stems case-sensitively against the actual file's stem.
    if (tools::file_ext(queried_basename) == "") {
      queried_basename <- paste0(queried_basename,
                                 ".", tools::file_ext(actual_name))
    }
    if (queried_basename != actual_name) {
      drifts <- c(drifts,
                  paste0(figure_paths$path[i], " (disk: ", actual_name, ")"))
    }
  }
  drifts
}


#' Discover style/class files actually used by the document
#'
#' The permissive `list.files(pattern = "\\.(sty|cls)$")` approach picked up
#' every style file in the directory, including stale experiments. Instead,
#' parse `\usepackage{...}` and `\documentclass{...}` and only include files
#' whose stem matches a package or class actually loaded by the tex.
#' @noRd
discover_style_files <- function(tex_text, source_dir) {
  # \usepackage[opts]{pkg1,pkg2} -- one match per occurrence, comma-separated
  pkg_matches <- regmatches(tex_text,
    gregexpr("\\\\usepackage(?:\\[[^\\]]*\\])?\\{([^}]+)\\}",
             tex_text, perl = TRUE))[[1]]
  cls_matches <- regmatches(tex_text,
    gregexpr("\\\\documentclass(?:\\[[^\\]]*\\])?\\{([^}]+)\\}",
             tex_text, perl = TRUE))[[1]]

  stems <- c()
  for (m in pkg_matches) {
    inner <- sub("\\\\usepackage(?:\\[[^\\]]*\\])?\\{([^}]+)\\}", "\\1",
                 m, perl = TRUE)
    stems <- c(stems, trimws(strsplit(inner, ",")[[1]]))
  }
  for (m in cls_matches) {
    inner <- sub("\\\\documentclass(?:\\[[^\\]]*\\])?\\{([^}]+)\\}", "\\1",
                 m, perl = TRUE)
    stems <- c(stems, trimws(strsplit(inner, ",")[[1]]))
  }

  # Intersect requested stems with files actually present in source_dir.
  available <- list.files(source_dir, pattern = "\\.(sty|cls)$",
                          full.names = TRUE)
  avail_stems <- tools::file_path_sans_ext(basename(available))
  available[avail_stems %in% stems]
}


#' Rewrite \\includegraphics path arguments to flat basenames
#' @noRd
rewrite_includegraphics <- function(tex_text, figure_paths) {
  for (i in seq_len(nrow(figure_paths))) {
    old <- figure_paths$path[i]
    new <- figure_paths$target[i]
    if (old == new) next
    old_rx <- gsub("([][\\\\.+*?(){}^$|])", "\\\\\\1", old, perl = TRUE)
    pattern <- paste0("(\\\\includegraphics\\*?(?:\\[[^\\]]*\\])?\\{)",
                      old_rx, "(\\})")
    tex_text <- gsub(pattern, paste0("\\1", new, "\\2"),
                     tex_text, perl = TRUE)
  }
  tex_text
}
