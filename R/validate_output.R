#' Run post-render output validators
#'
#' Reads the `docstyle.validators:` block from a `_quarto.yml` (if present)
#' and runs the configured validators against the rendered output files.
#' Each validator is independent and reports either success, a `warn`
#' message (printed to stderr but doesn't fail the render), or an
#' `error` (fails the render with a clear, actionable message).
#'
#' This is the post-render counterpart to docstyle's pre-render
#' configuration validation — its job is to catch silent failures that
#' would otherwise ship to a preprint server.
#'
#' Available validators (configure under `docstyle.validators.<format>`
#' in `_quarto.yml`; each value is `error`, `warn`, or `false`/off):
#'
#' \describe{
#'   \item{`docx.no-docstyle-cite-markers`}{Error if `DOCSTYLE_CITE::`
#'     markers leak into the rendered docx because the post-render Zotero
#'     injection silently skipped (renv shadowing, missing extension).}
#'   \item{`jats.well-formed`}{Error if the rendered JATS XML does not
#'     parse (malformed output is rejected by every downstream consumer).}
#'   \item{`jats.abstract-present`}{Error if no `<abstract>` element is
#'     present — catches the case where a `# Abstract` body heading
#'     produces a `<sec>` in `<body>` instead of `abstract:` YAML, which
#'     PMC silently drops.}
#'   \item{`pdf.tagged`}{Error if the PDF carries no structure tree
#'     (`Tagged: yes`). Bare-minimum PDF/UA precondition; full UA-1
#'     conformance needs veraPDF and is out of scope.}
#' }
#'
#' @param output_files Character vector of paths to rendered output
#'   files. Typically populated from `QUARTO_PROJECT_OUTPUT_FILES`.
#' @param config Optional list of validator settings. If NULL, attempts
#'   to read from `_quarto.yml` in the project directory.
#' @param project_dir Project directory to look for `_quarto.yml`.
#'   Defaults to current working directory.
#' @param verbose Logical. Print per-validator status messages.
#' @return Invisibly, a list with `errors` (character vector of
#'   error-level failures) and `warnings` (character vector of
#'   warn-level diagnostics).
#' @export
validate_docstyle_output <- function(output_files,
                                     config = NULL,
                                     project_dir = ".",
                                     verbose = TRUE) {

  if (length(output_files) == 0) {
    return(invisible(list(errors = character(), warnings = character())))
  }

  if (is.null(config)) {
    config <- read_validators_config(project_dir)
  }
  if (is.null(config) || length(config) == 0) {
    # No validators configured — silent no-op, matching the existing
    # opt-in pattern. Users explicitly enable validators via _quarto.yml.
    return(invisible(list(errors = character(), warnings = character())))
  }

  vmsg <- function(...) if (verbose) message("[validate-output] ", ...)
  errors <- character()
  warnings <- character()

  # Group output files by format so each file dispatches to its
  # format-specific validators.
  for (out in output_files) {
    if (!file.exists(out)) {
      vmsg("Skipping missing output: ", out)
      next
    }
    fmt <- detect_output_format(out)
    fmt_config <- config[[fmt]]
    if (is.null(fmt_config) || length(fmt_config) == 0) next

    vmsg("Validating ", fmt, " output: ", basename(out))
    for (validator_name in names(fmt_config)) {
      severity <- fmt_config[[validator_name]]
      if (isFALSE(severity) || identical(severity, "off")) next
      severity <- if (isTRUE(severity)) "error" else as.character(severity)

      result <- run_validator(fmt, validator_name, out)
      if (is.null(result) || isTRUE(result$pass)) {
        vmsg("  ✓ ", validator_name)
      } else {
        msg <- paste0("[", fmt, ":", validator_name, "] ",
                      result$message %||% "validation failed",
                      " (file: ", basename(out), ")")
        if (severity == "error") {
          errors <- c(errors, msg)
          vmsg("  ✗ ERROR: ", msg)
        } else {
          warnings <- c(warnings, msg)
          vmsg("  ! WARN: ", msg)
        }
      }
    }
  }

  if (length(errors) > 0) {
    stop("docstyle output validation failed:\n  ",
         paste(errors, collapse = "\n  "), call. = FALSE)
  }

  invisible(list(errors = errors, warnings = warnings))
}


# Internal: read `docstyle.validators` block from _quarto.yml.
# Returns a list keyed by output format (docx, pdf, jats), each
# containing a name->severity map.
read_validators_config <- function(project_dir) {
  yml_path <- file.path(project_dir, "_quarto.yml")
  if (!file.exists(yml_path)) return(NULL)
  cfg <- tryCatch(yaml::read_yaml(yml_path),
                  error = function(e) NULL)
  if (is.null(cfg) || is.null(cfg$docstyle) ||
      is.null(cfg$docstyle$validators)) return(NULL)
  cfg$docstyle$validators
}


# Internal: detect which validator group an output file belongs to.
detect_output_format <- function(path) {
  ext <- tolower(tools::file_ext(path))
  switch(ext,
         docx = "docx",
         pdf  = "pdf",
         xml  = "jats",
         tools::file_ext(path))
}


# Internal: dispatch to the named validator. Returns
# list(pass = TRUE/FALSE, message = optional reason string).
run_validator <- function(fmt, name, path) {
  key <- paste0(fmt, "_", gsub("-", "_", name, fixed = TRUE))
  fn <- VALIDATORS[[key]]
  if (is.null(fn)) {
    return(list(pass = FALSE,
                message = paste0("Unknown validator '", name,
                                 "' for format '", fmt, "'")))
  }
  tryCatch(fn(path), error = function(e) {
    list(pass = FALSE,
         message = paste0("Validator threw error: ", conditionMessage(e)))
  })
}


# ── Validators ──────────────────────────────────────────────────────────────
#
# Each validator: list(pass = TRUE/FALSE, message = optional string).
# Registered in VALIDATORS at module load time. To add a new validator:
#   1. Write the function below
#   2. Add it to the VALIDATORS list
#   3. Document the YAML key in `validate_docstyle_output()`'s docstring


# docx: detect DOCSTYLE_CITE:: markers leaking through to the rendered
# document. These markers are emitted by zotero-inject.lua and replaced
# in the post-render R hook with proper Word field codes. If the hook
# silently skipped (e.g. renv shadowing, missing docstyle install), the
# markers appear as literal text in the docx body. This is the highest-
# signal validator: high cost (broken citations in submitted preprint),
# low false-positive rate (the marker pattern is unique).
docx_no_docstyle_cite_markers <- function(docx_path) {
  if (!file.exists(docx_path)) {
    return(list(pass = FALSE, message = "DOCX not found"))
  }

  tmp <- tempfile()
  on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
  dir.create(tmp)
  result <- tryCatch(
    utils::unzip(docx_path, files = "word/document.xml", exdir = tmp),
    error = function(e) NULL
  )
  doc_xml_path <- file.path(tmp, "word", "document.xml")
  if (is.null(result) || !file.exists(doc_xml_path)) {
    return(list(pass = FALSE,
                message = "Could not extract word/document.xml"))
  }

  doc_xml <- paste(readLines(doc_xml_path, warn = FALSE), collapse = "\n")
  if (grepl("DOCSTYLE_CITE::", doc_xml, fixed = TRUE)) {
    return(list(pass = FALSE,
                message = paste0("DOCSTYLE_CITE:: markers found in ",
                                 "rendered docx — Zotero field-code ",
                                 "injection silently skipped. Check ",
                                 "post-render hook ran successfully ",
                                 "(see issue #142 for renv-shadowing ",
                                 "diagnosis).")))
  }
  list(pass = TRUE)
}


# jats: confirm the rendered XML is well-formed. The simplest, highest-
# value JATS check — a malformed file is rejected outright by every
# downstream consumer (PMC, ar5iv). Uses xml2 (a core dep) rather than
# shelling out to xmllint, so it runs anywhere without extra tooling.
jats_well_formed <- function(xml_path) {
  if (!file.exists(xml_path)) {
    return(list(pass = FALSE, message = "JATS file not found"))
  }
  parsed <- tryCatch(xml2::read_xml(xml_path),
                     error = function(e) e)
  if (inherits(parsed, "error")) {
    return(list(pass = FALSE,
                message = paste0("JATS not well-formed: ",
                                 conditionMessage(parsed))))
  }
  list(pass = TRUE)
}


# jats: confirm an <abstract> element is present. Catches the failure
# #145 names directly — a `# Abstract` body heading in the QMD produces
# a <sec> inside <body>, NOT an <abstract> in <front>, so a JATS-aware
# consumer like PMC silently drops the abstract. The local-name() XPath
# is namespace-agnostic (JATS Archiving DTD content is typically
# unprefixed, but a consumer may add a default namespace).
jats_abstract_present <- function(xml_path) {
  if (!file.exists(xml_path)) {
    return(list(pass = FALSE, message = "JATS file not found"))
  }
  parsed <- tryCatch(xml2::read_xml(xml_path),
                     error = function(e) e)
  if (inherits(parsed, "error")) {
    return(list(pass = FALSE,
                message = paste0("JATS not well-formed: ",
                                 conditionMessage(parsed))))
  }
  abstracts <- xml2::xml_find_all(parsed, "//*[local-name()='abstract']")
  if (length(abstracts) == 0) {
    return(list(pass = FALSE,
                message = paste0("No <abstract> element found. A ",
                                 "`# Abstract` body heading produces a ",
                                 "<sec> in <body>, not an <abstract> in ",
                                 "<front>. Use `abstract:` in the QMD ",
                                 "YAML so JATS consumers (PMC) ingest it.")))
  }
  list(pass = TRUE)
}


# pdf: confirm the rendered PDF carries a structure tree (Tagged: yes).
# This is the bare-minimum tagging precondition for PDF/UA accessibility;
# full UA-1 conformance needs veraPDF and is out of scope. Greps pdfinfo
# output. If pdfinfo is unavailable, the validator cannot run — it
# returns a warn-style pass-through rather than a false failure.
pdf_tagged <- function(pdf_path) {
  if (!file.exists(pdf_path)) {
    return(list(pass = FALSE, message = "PDF not found"))
  }
  if (!nzchar(Sys.which("pdfinfo"))) {
    return(list(pass = TRUE,
                message = paste0("pdfinfo not available — skipped tagging ",
                                 "check (install poppler to enable)")))
  }
  info <- tryCatch(
    suppressWarnings(system2("pdfinfo", pdf_path,
                             stdout = TRUE, stderr = TRUE)),
    error = function(e) character()
  )
  if (any(grepl("^Tagged:\\s*yes", info, ignore.case = TRUE))) {
    return(list(pass = TRUE))
  }
  list(pass = FALSE,
       message = paste0("PDF is not tagged (no structure tree). ",
                        "Set `pdf-standard: ua-1` and verify content ",
                        "passes UA-1 conformance (veraPDF)."))
}


# Registry of available validators. Keyed by "<format>_<name_with_underscores>".
VALIDATORS <- list(
  docx_no_docstyle_cite_markers = docx_no_docstyle_cite_markers,
  jats_well_formed              = jats_well_formed,
  jats_abstract_present         = jats_abstract_present,
  pdf_tagged                    = pdf_tagged
)
