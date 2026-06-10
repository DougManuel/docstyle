#' Scaffold a methods-protocol Quarto project
#'
#' Creates a working Quarto project pre-configured for both Word editing
#' (`docstyle-docx` with Zotero field codes) and medRxiv-ready preprint
#' output (`docstyle-typst` with `medrxiv: true`). Drops in a PRISMA-ScR
#' or PRISMA-P scaffolded `protocol.qmd` with section headings and inline
#' prompts, a `references.bib` skeleton, a `supplements/` directory with
#' a README and starter stubs (`search-strategy.json`,
#' `data-charting-fields.csv` or `data-extraction-fields.csv`), a
#' project README with a submission checklist, and the bundled docstyle
#' extension.
#'
#' Removes the cold-start cost of starting a methods protocol — open the
#' rendered Word doc and start writing, or render the Typst PDF for
#' preprint review immediately.
#'
#' @param path Path to the directory in which to scaffold the project.
#'   Will be created if it does not exist. Defaults to current directory.
#' @param title Working title for the protocol. Substituted into
#'   `_quarto.yml` (running head, footer) and `protocol.qmd` (title
#'   field). Can be edited later. Must not be empty.
#' @param framework One of `"prisma-scr"` (scoping reviews; default) or
#'   `"prisma-p"` (systematic reviews). Selects the section scaffold
#'   in `protocol.qmd`.
#' @param overwrite Logical. If TRUE, overwrite existing template files
#'   at the target path AND replace the bundled docstyle extension at
#'   `_extensions/docstyle/`. If FALSE (default), refuse to overwrite
#'   any existing template file and abort. The `overwrite` flag is
#'   passed through to [use_docstyle()] for the extension copy.
#'
#' @return Invisibly, the absolute path to the scaffolded project.
#'
#' @examples
#' \dontrun{
#' # Scoping review protocol scaffold
#' use_methods_protocol(
#'   path = "popcorn-protocol",
#'   title = "POPCORN scoping review protocol",
#'   framework = "prisma-scr"
#' )
#'
#' # Systematic review protocol scaffold
#' use_methods_protocol(
#'   path = "rct-review",
#'   title = "Effect of X on Y in Z populations",
#'   framework = "prisma-p"
#' )
#' }
#' @export
use_methods_protocol <- function(path = ".",
                                 title = "Working title",
                                 framework = c("prisma-scr", "prisma-p"),
                                 overwrite = FALSE) {

  framework <- match.arg(framework)

  if (!nzchar(title)) {
    stop("`title` must be a non-empty string.", call. = FALSE)
  }

  # Locate the bundled template dir.
  template_src <- system.file("extdata", "methods-protocol",
                              package = "docstyle")
  if (!dir.exists(template_src)) {
    stop("methods-protocol template not found in package. ",
         "Reinstall docstyle.", call. = FALSE)
  }

  # Source files in the template, with framework-specific QMD selected.
  src <- list(
    qmd        = file.path(template_src,
                           paste0("protocol-", framework, ".qmd")),
    quarto_yml = file.path(template_src, "_quarto.yml"),
    bib        = file.path(template_src, "references.bib"),
    readme     = file.path(template_src, "README.md"),
    supp_readme = file.path(template_src, "supplements", "README.md"),
    supp_search = file.path(template_src, "supplements",
                            "search-strategy.json"),
    supp_charting = file.path(template_src, "supplements",
                              "data-charting-fields.csv"),
    supp_extraction = file.path(template_src, "supplements",
                                "data-extraction-fields.csv")
  )

  # Pre-flight: every source must exist. Catches damaged installs early
  # with a single consolidated error rather than a downstream
  # readLines/file.copy mystery.
  missing_src <- Filter(function(p) !file.exists(p), src)
  if (length(missing_src) > 0) {
    stop("[use-methods-protocol] Bundled template appears damaged. ",
         "Missing file(s):\n  ",
         paste(unlist(missing_src), collapse = "\n  "),
         "\nReinstall docstyle.", call. = FALSE)
  }

  # Ensure target dir exists. Check return — dir.create() returns FALSE
  # with a warning rather than throwing on permission denied, full disk,
  # or path-is-a-file.
  if (!dir.exists(path)) {
    if (!isTRUE(dir.create(path, recursive = TRUE))) {
      stop("[use-methods-protocol] Could not create directory: ", path,
           " (check permissions and disk space)", call. = FALSE)
    }
    message("[use-methods-protocol] Created directory: ", path)
  }
  path <- normalizePath(path, mustWork = TRUE)

  # Files we'll write at the destination.
  destinations <- list(
    qmd             = file.path(path, "protocol.qmd"),
    quarto_yml      = file.path(path, "_quarto.yml"),
    bib             = file.path(path, "references.bib"),
    readme          = file.path(path, "README.md"),
    supp_dir        = file.path(path, "supplements"),
    supp_readme     = file.path(path, "supplements", "README.md"),
    supp_search     = file.path(path, "supplements",
                                "search-strategy.json"),
    supp_charting   = file.path(path, "supplements",
                                "data-charting-fields.csv"),
    supp_extraction = file.path(path, "supplements",
                                "data-extraction-fields.csv")
  )

  # Pre-flight: refuse to overwrite unless caller said so. Note this does
  # not check `_extensions/docstyle/`; that's `use_docstyle()`'s concern.
  existing <- vapply(destinations, file.exists, logical(1))
  if (any(existing) && !overwrite) {
    stop("Refusing to overwrite existing file(s):\n  ",
         paste(unlist(destinations)[existing], collapse = "\n  "),
         "\nPass `overwrite = TRUE` to replace.", call. = FALSE)
  }

  current_date <- format(Sys.Date(), "%Y-%m-%d")
  written_so_far <- character()

  # Helper: read template, substitute placeholders, write destination.
  # Errors are caught with context so a half-scaffolded project doesn't
  # leave the user staring at "cannot open file" with no traceability.
  copy_with_substitutions <- function(from, to) {
    tryCatch({
      content <- readLines(from, warn = FALSE)
      content <- gsub("{{TITLE}}", title, content, fixed = TRUE)
      content <- gsub("{{DATE}}", current_date, content, fixed = TRUE)
      writeLines(content, to)
    }, error = function(e) {
      stop("[use-methods-protocol] Failed to write ", to,
           " (from template ", from, "): ", conditionMessage(e),
           call. = FALSE)
    })
    written_so_far <<- c(written_so_far, to)
  }

  # Helper: file.copy with explicit src/dst context on failure. The
  # default error message ("Failed to copy X") doesn't say WHERE the copy
  # was going or WHY it failed — both matter for diagnosis.
  safe_copy <- function(from, to) {
    ok <- file.copy(from, to, overwrite = overwrite)
    if (!isTRUE(ok)) {
      stop("[use-methods-protocol] Failed to copy ", from, " -> ", to,
           " (check destination is writable and has free space)",
           call. = FALSE)
    }
    written_so_far <<- c(written_so_far, to)
  }

  # If anything fails partway, roll back the templated files so the user
  # can retry without manually deleting a half-scaffolded project. We
  # don't roll back the extension dir; use_docstyle() runs last and has
  # its own error semantics.
  rollback_on_error <- function(expr) {
    tryCatch(expr, error = function(e) {
      for (f in written_so_far) {
        if (file.exists(f)) file.remove(f)
      }
      stop(conditionMessage(e), call. = FALSE)
    })
  }

  rollback_on_error({
    # Templated files (placeholders substituted).
    copy_with_substitutions(src$qmd, destinations$qmd)
    copy_with_substitutions(src$quarto_yml, destinations$quarto_yml)
    message("[use-methods-protocol] Wrote: protocol.qmd (", framework,
            "), _quarto.yml (with title substituted)")

    # Verbatim copies (no substitutions needed).
    safe_copy(src$bib, destinations$bib)
    safe_copy(src$readme, destinations$readme)

    # Supplements directory + stubs.
    if (!dir.exists(destinations$supp_dir)) {
      if (!isTRUE(dir.create(destinations$supp_dir, recursive = TRUE))) {
        stop("[use-methods-protocol] Could not create supplements dir: ",
             destinations$supp_dir, call. = FALSE)
      }
    }
    safe_copy(src$supp_readme, destinations$supp_readme)
    safe_copy(src$supp_search, destinations$supp_search)
    if (framework == "prisma-scr") {
      safe_copy(src$supp_charting, destinations$supp_charting)
    } else {
      safe_copy(src$supp_extraction, destinations$supp_extraction)
    }
    message("[use-methods-protocol] Wrote: references.bib, README.md, ",
            "supplements/")
  })

  # Install the docstyle extension into the project so it renders out
  # of the box. Re-uses the existing init helper. Failure here leaves
  # the templated files in place so the user can retry just the
  # extension install.
  use_docstyle(path = path, overwrite = overwrite)

  message("\n[use-methods-protocol] Scaffold complete: ", path)
  message("Next steps:")
  message("  1. Edit _quarto.yml to set real authors, affiliations, ORCIDs")
  message("  2. Edit protocol.qmd to replace placeholder content")
  message("  3. Populate supplements/search-strategy.json and field CSVs")
  message("  4. Render: quarto render protocol.qmd")

  invisible(path)
}
