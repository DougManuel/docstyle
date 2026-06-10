#' Validate full round-trip: harvest, render, and output validation
#'
#' Orchestrates the complete validation sequence: checks that the harvest
#' faithfully captured the source document, renders the QMD back to Word,
#' and validates the output DOCX structure. Establishes a clean baseline
#' so that post-edit failures are attributable to edits, not the pipeline.
#'
#' @param docx_path Path to the source .docx file
#' @param qmd_path Path to the harvested .qmd file
#' @param sidecar_dir Path to the _docstyle/ sidecar directory. If NULL,
#'   auto-detected from the QMD directory.
#' @param output_dir Directory for rendered output. Default: "output/" relative
#'   to the QMD file.
#' @param render Logical. If TRUE, runs `quarto render`. If FALSE, looks for
#'   an existing output docx.
#' @param structure_checks Character vector of checks for
#'   [validate_docx_structure()]. Default runs all standard checks.
#' @param verbose Logical. Print progress output. Default TRUE.
#'
#' @return A `docstyle_validation` object (list) with:
#' \describe{
#'   \item{valid}{Logical. TRUE if all stages passed}
#'   \item{stages}{Named list of per-stage results (harvest, render,
#'     structure, comments)}
#'   \item{issues}{List with aggregated errors and warnings}
#' }
#'
#' @examples
#' \dontrun{
#' # Full round-trip validation
#' result <- validate_round_trip("source/document.docx", "document.qmd")
#'
#' # Skip render, validate existing output
#' result <- validate_round_trip("source/document.docx", "document.qmd",
#'   render = FALSE)
#'
#' # Print detailed results
#' print(result, detail = "full")
#'
#' # Write report to file
#' report(result, file = "validation-report.md")
#' }
#'
#' @seealso [validate_harvest()] for harvest-only validation,
#'   [validate_docx_structure()] for output structural validation,
#'   [validate_comments()] for comment round-trip validation
#'
#' @export
validate_round_trip <- function(docx_path,
                                qmd_path,
                                sidecar_dir = NULL,
                                output_dir = NULL,
                                render = TRUE,
                                structure_checks = c("xml", "whitespace",
                                  "deletions", "insertions", "ids",
                                  "rels", "content_types"),
                                verbose = TRUE) {

  result <- list(
    valid = TRUE,
    stages = list(
      harvest = NULL,
      render = NULL,
      structure = NULL,
      comments = NULL
    ),
    issues = list(
      errors = character(),
      warnings = character()
    )
  )

  if (verbose) {
    cat(sprintf("\n\u2550\u2550 Round-trip validation \u2550\u2550\n"))
    cat(sprintf("File: %s\n", basename(docx_path)))
  }

  # ── Stage 1: Harvest validation ──────────────────────────────────────────
  if (verbose) cat(sprintf("\n\u2500\u2500 Harvest validation \u2500\u2500\n"))

  harvest_result <- validate_harvest(docx_path, qmd_path,
                                      sidecar_dir = sidecar_dir,
                                      verbose = verbose)
  result$stages$harvest <- harvest_result

  if (!harvest_result$valid) {
    result$valid <- FALSE
    result$issues$errors <- c(result$issues$errors, harvest_result$issues$errors)
  }
  result$issues$warnings <- c(result$issues$warnings,
                               harvest_result$issues$warnings)

  # ── Stage 2: Render ──────────────────────────────────────────────────────
  if (verbose) cat(sprintf("\n\u2500\u2500 Render \u2500\u2500\n"))

  # Determine output path
  if (is.null(output_dir)) {
    output_dir <- file.path(dirname(qmd_path), "output")
  }

  qmd_basename <- tools::file_path_sans_ext(basename(qmd_path))
  output_path <- file.path(output_dir, paste0(qmd_basename, ".docx"))

  render_stage <- list(
    success = FALSE,
    output_path = output_path,
    render_time = NA_real_
  )

  if (render) {
    if (!dir.exists(output_dir)) {
      dir.create(output_dir, recursive = TRUE)
    }

    start_time <- proc.time()
    render_ok <- tryCatch({
      # Use system2 for quarto render to capture output
      args <- c("render", qmd_path,
                "--output-dir", output_dir)
      exit_code <- system2("quarto", args, stdout = TRUE, stderr = TRUE)
      attr(exit_code, "status") %||% 0L == 0L
    }, error = function(e) {
      if (verbose) vh_check(verbose, FALSE,
                             paste("Render failed:", conditionMessage(e)))
      FALSE
    })
    elapsed <- (proc.time() - start_time)[["elapsed"]]
    render_stage$render_time <- round(elapsed, 1)

    if (render_ok && file.exists(output_path)) {
      render_stage$success <- TRUE
      vh_check(verbose, TRUE,
               sprintf("quarto render succeeded (%.1fs)", elapsed))
      vh_check(verbose, TRUE, sprintf("Output: %s", output_path))
    } else if (!file.exists(output_path)) {
      render_stage$success <- FALSE
      msg <- "Render completed but output file not found"
      vh_check(verbose, FALSE, msg)
      result$valid <- FALSE
      result$issues$errors <- c(result$issues$errors, msg)
    } else {
      render_stage$success <- FALSE
      msg <- "quarto render failed"
      vh_check(verbose, FALSE, msg)
      result$valid <- FALSE
      result$issues$errors <- c(result$issues$errors, msg)
    }
  } else {
    # render = FALSE: check for existing output
    if (file.exists(output_path)) {
      render_stage$success <- TRUE
      vh_check(verbose, TRUE, sprintf("Existing output: %s", output_path))
    } else {
      render_stage$success <- FALSE
      msg <- sprintf("No output found at %s (render = FALSE)", output_path)
      vh_check(verbose, FALSE, msg)
      result$valid <- FALSE
      result$issues$errors <- c(result$issues$errors, msg)
    }
  }

  result$stages$render <- render_stage

  # ── Stage 3: Output structural validation ────────────────────────────────
  if (render_stage$success) {
    if (verbose) cat(sprintf("\n\u2500\u2500 Output validation \u2500\u2500\n"))

    structure_result <- validate_docx_structure(output_path,
                                                 checks = structure_checks,
                                                 verbose = verbose)
    result$stages$structure <- structure_result

    if (!structure_result$valid) {
      result$valid <- FALSE
      result$issues$errors <- c(result$issues$errors, structure_result$errors)
    }
    if (length(structure_result$warnings) > 0) {
      result$issues$warnings <- c(result$issues$warnings,
                                   structure_result$warnings)
    }

    # ── Stage 4: Comment validation ──────────────────────────────────────
    # Only if comments.json exists
    if (is.null(sidecar_dir)) {
      sidecar_dir <- file.path(dirname(qmd_path), "_docstyle")
    }
    comments_json_path <- file.path(sidecar_dir, "comments.json")

    if (file.exists(comments_json_path)) {
      comments_result <- tryCatch(
        validate_comments(output_path,
                          comments_json = comments_json_path,
                          verbose = verbose),
        error = function(e) {
          if (verbose) vh_check(verbose, FALSE,
                                 paste("Comment validation error:",
                                       conditionMessage(e)))
          list(valid = FALSE,
               errors = conditionMessage(e),
               warnings = character())
        }
      )
      result$stages$comments <- comments_result

      if (!comments_result$valid) {
        result$valid <- FALSE
        if (!is.null(comments_result$errors)) {
          result$issues$errors <- c(result$issues$errors,
                                     comments_result$errors)
        }
      }
    } else {
      if (verbose) vh_info(verbose, "No comments.json; skipping comment validation")
    }
  } else {
    if (verbose) {
      vh_info(verbose, "Render not available; skipping output validation")
    }
  }

  # ── Final summary ──
  result <- new_docstyle_validation(result, type = "round_trip",
                                     source_file = docx_path)

  if (verbose) {
    cat(sprintf("\n\u2550\u2550 Result: %s \u2550\u2550\n",
                if (result$valid) "PASS" else "FAIL"))
    n_errors <- length(result$issues$errors)
    n_warnings <- length(result$issues$warnings)
    n_notes <- count_notes(result)
    cat(sprintf("  %d error(s) | %d warning(s) | %d note(s)\n",
                n_errors, n_warnings, n_notes))
  }

  invisible(result)
}


# ══ S3 class: docstyle_validation ═══════════════════════════════════════════

#' Create a docstyle_validation object
#'
#' @param x List with validation results
#' @param type Character. "harvest" or "round_trip"
#' @param source_file Character. Path to the source file
#' @return x with class "docstyle_validation" and metadata attributes
#' @noRd
new_docstyle_validation <- function(x, type = "harvest",
                                     source_file = NULL) {
  attr(x, "validation_type") <- type
  attr(x, "source_file") <- source_file
  attr(x, "timestamp") <- Sys.time()
  class(x) <- c("docstyle_validation", "list")
  x
}


#' Count informational notes in validation results
#'
#' Notes are expected losses and informational items that don't affect pass/fail.
#' @param x A docstyle_validation object
#' @return Integer count of notes
#' @noRd
count_notes <- function(x) {
  n <- 0L

  # Harvest stage notes
  harvest <- if (!is.null(x$stages)) x$stages$harvest else x

  # Expected revision loss
  rev_loss <- harvest$details$structure$revision_loss
  if (!is.null(rev_loss) && length(rev_loss$expected) > 0) {
    n <- n + 1L
  }

  # Expected comment loss
  com_loss <- harvest$details$structure$comment_loss
  if (!is.null(com_loss) && length(com_loss$expected) > 0) {
    n <- n + 1L
  }

  # Generated content exclusions
  gen <- harvest$details$text$generated_sections
  if (!is.null(gen) && length(gen) > 0) {
    n <- n + 1L
  }

  n
}


#' Print a docstyle validation result
#'
#' Displays validation results in devtools-style format with unicode symbols.
#'
#' @param x A `docstyle_validation` object
#' @param ... Additional arguments (ignored)
#' @param detail Character. "summary" (default) for compact output, "full"
#'   for per-ID details and expected loss breakdown.
#'
#' @export
print.docstyle_validation <- function(x, ..., detail = c("summary", "full")) {
  detail <- match.arg(detail)
  type <- attr(x, "validation_type") %||% "harvest"
  source_file <- attr(x, "source_file")

  if (type == "round_trip") {
    print_round_trip(x, detail, source_file)
  } else {
    print_harvest(x, detail, source_file)
  }

  invisible(x)
}


#' Print harvest check lines (shared by harvest and round-trip print)
#' @noRd
print_harvest_checks <- function(h) {
  print_check_line(isTRUE(h$checks$xml_wellformed),
                   "XML well-formed, body present")

  # Extraction
  if (!is.null(h$summary$extraction)) {
    ext <- h$summary$extraction
    parts <- character()
    if (!is.null(ext$citations)) {
      parts <- c(parts, sprintf("%d citations", ext$citations$source_field_codes))
    }
    if (!is.null(ext$comments)) {
      parts <- c(parts, sprintf("%d comments", ext$comments$source_count))
    }
    if (!is.null(ext$revisions)) {
      parts <- c(parts, sprintf("%d revisions", ext$revisions$source_count))
    }
    if (length(parts) > 0) {
      print_check_line(
        isTRUE(h$checks$citations_extracted) &&
          isTRUE(h$checks$comments_extracted) &&
          isTRUE(h$checks$revisions_extracted),
        sprintf("Extraction: %s", paste(parts, collapse = ", "))
      )
    }
  }

  # Text
  if (!is.null(h$summary$text)) {
    txt <- h$summary$text
    print_check_line(isTRUE(h$checks$text_fidelity),
                     sprintf("Text fidelity: %.1f%% word count difference",
                             txt$diff_pct))
  }

  # Structure
  if (!is.null(h$summary$structure)) {
    st <- h$summary$structure
    parts <- character()
    if (!is.null(st$headings)) {
      parts <- c(parts, sprintf("%d headings", st$headings$docx))
    }
    if (!is.null(st$tables)) {
      parts <- c(parts, sprintf("%d table(s)", st$tables$docx))
    }
    struct_pass <- isTRUE(h$checks$headings_match) &&
      isTRUE(h$checks$tables_match) &&
      isTRUE(h$checks$citations_placed) &&
      isTRUE(h$checks$revisions_placed) &&
      isTRUE(h$checks$comments_placed)
    print_check_line(struct_pass,
                     sprintf("Structure: %s", paste(parts, collapse = ", ")))
  }
}

#' Print harvest validation results
#' @noRd
print_harvest <- function(x, detail, source_file) {
  cat(sprintf("\n\u2550\u2550 Harvest validation \u2550\u2550\n"))
  if (!is.null(source_file)) {
    cat(sprintf("File: %s\n", basename(source_file)))
  }

  print_harvest_checks(x)

  # Notes for expected loss
  print_notes(x, detail)

  # Summary line
  print_summary_line(x)

  if (detail == "full") {
    print_full_detail(x)
  }
}


#' Print round-trip validation results
#' @noRd
print_round_trip <- function(x, detail, source_file) {
  cat(sprintf("\n\u2550\u2550 Round-trip validation \u2550\u2550\n"))
  if (!is.null(source_file)) {
    cat(sprintf("File: %s\n", basename(source_file)))
  }

  # Harvest stage
  if (!is.null(x$stages$harvest)) {
    cat(sprintf("\n\u2500\u2500 Harvest \u2500\u2500\n"))
    print_harvest_checks(x$stages$harvest)
    print_expected_loss_info(x$stages$harvest)
  }

  # Render stage
  if (!is.null(x$stages$render)) {
    cat(sprintf("\n\u2500\u2500 Render \u2500\u2500\n"))
    r <- x$stages$render
    if (r$success) {
      time_str <- if (!is.na(r$render_time)) {
        sprintf(" (%.1fs)", r$render_time)
      } else { "" }
      print_check_line(TRUE, sprintf("quarto render succeeded%s", time_str))
      print_check_line(TRUE, sprintf("Output: %s", basename(r$output_path)))
    } else {
      print_check_line(FALSE, "Render failed")
    }
  }

  # Structure stage
  if (!is.null(x$stages$structure)) {
    cat(sprintf("\n\u2500\u2500 Output validation \u2500\u2500\n"))
    s <- x$stages$structure
    if (s$valid) {
      n_checks <- length(s$checks)
      print_check_line(TRUE, sprintf("All %d structural checks passed",
                                     n_checks))
    } else {
      for (err in s$errors) {
        print_check_line(FALSE, err)
      }
    }
    for (w in s$warnings) {
      cat(sprintf("  \u26a0 %s\n", w))
    }
  }

  # Comments stage
  if (!is.null(x$stages$comments)) {
    c_result <- x$stages$comments
    if (isTRUE(c_result$valid)) {
      print_check_line(TRUE, "Comment round-trip validated")
    } else {
      print_check_line(FALSE, "Comment round-trip issues detected")
    }
  }

  # Notes
  print_notes(x, detail)

  # Summary
  print_summary_line(x)

  if (detail == "full") {
    print_full_detail_round_trip(x)
  }
}


# ── Print helpers ──────────────────────────────────────────────────────────

#' @noRd
print_check_line <- function(pass, msg) {
  symbol <- if (isTRUE(pass)) "\u2713" else "\u2717"
  cat(sprintf("  %s %s\n", symbol, msg))
}

#' @noRd
print_info_line <- function(msg) {
  cat(sprintf("  \u2139 %s\n", msg))
}

#' Print expected loss info lines
#' @noRd
print_expected_loss_info <- function(harvest) {
  rev_loss <- harvest$details$structure$revision_loss
  if (!is.null(rev_loss) && length(rev_loss$expected) > 0) {
    parts <- character()
    for (pname in names(rev_loss$by_pattern)) {
      n <- length(rev_loss$by_pattern[[pname]])
      if (n > 0) parts <- c(parts, sprintf("%d %s", n, pname))
    }
    print_info_line(sprintf("%d expected revision loss (%s)",
                            length(rev_loss$expected),
                            paste(parts, collapse = ", ")))
  }

  com_loss <- harvest$details$structure$comment_loss
  if (!is.null(com_loss) && length(com_loss$expected) > 0) {
    parts <- character()
    for (pname in names(com_loss$by_pattern)) {
      n <- length(com_loss$by_pattern[[pname]])
      if (n > 0) parts <- c(parts, sprintf("%d %s", n, pname))
    }
    print_info_line(sprintf("%d expected comment loss (%s)",
                            length(com_loss$expected),
                            paste(parts, collapse = ", ")))
  }
}

#' Print notes section
#' @noRd
print_notes <- function(x, detail) {
  harvest <- if (!is.null(x$stages)) x$stages$harvest else x
  if (is.null(harvest)) return(invisible(NULL))

  rev_loss <- harvest$details$structure$revision_loss
  com_loss <- harvest$details$structure$comment_loss
  gen <- harvest$details$text$generated_sections

  has_notes <- (!is.null(rev_loss) && length(rev_loss$expected) > 0) ||
    (!is.null(com_loss) && length(com_loss$expected) > 0) ||
    (!is.null(gen) && length(gen) > 0)

  if (!has_notes) return(invisible(NULL))

  # Notes are printed inline by print_expected_loss_info for round-trip
  # For harvest-only, print here
  if (is.null(x$stages)) {
    print_expected_loss_info(harvest)

    if (!is.null(gen) && length(gen) > 0) {
      for (name in names(gen)) {
        s <- gen[[name]]
        print_info_line(sprintf("Excluded %s (%d words, detected by %s)",
                                gsub("_", " ", name), s$word_count,
                                s$detected_by))
      }
    }
  }
}

#' Print summary line with error/warning/note counts
#' @noRd
print_summary_line <- function(x) {
  n_errors <- length(x$issues$errors)
  n_warnings <- length(x$issues$warnings)
  n_notes <- count_notes(x)

  cat(sprintf("\n\u2500\u2500 Summary \u2500\u2500\n"))
  status <- if (x$valid) {
    sprintf("  \u2713 %s",
            if (!is.null(x$stages)) "Round-trip PASSED" else "Harvest PASSED")
  } else {
    sprintf("  \u2717 %s",
            if (!is.null(x$stages)) "Round-trip FAILED" else "Harvest FAILED")
  }
  cat(status, "\n")
  cat(sprintf("  %d error(s) | %d warning(s) | %d note(s)\n",
              n_errors, n_warnings, n_notes))
}

#' Print full detail for harvest validation
#' @noRd
print_full_detail <- function(x) {
  cat(sprintf("\n\u2500\u2500 Detail \u2500\u2500\n"))

  # Extraction IDs
  ext <- x$details$extraction
  if (!is.null(ext)) {
    if (length(ext$comments$missing) > 0) {
      cat(sprintf("  Comments missing from sidecar: %s\n",
                  paste(ext$comments$missing, collapse = ", ")))
    }
    if (length(ext$revisions$missing) > 0) {
      cat(sprintf("  Revisions missing from sidecar: %s\n",
                  paste(head(ext$revisions$missing, 10), collapse = ", ")))
      if (length(ext$revisions$missing) > 10) {
        cat(sprintf("  ... and %d more\n",
                    length(ext$revisions$missing) - 10))
      }
    }
  }

  # Generated content
  gen <- x$details$text$generated_sections
  if (!is.null(gen) && length(gen) > 0) {
    cat("  Generated content excluded:\n")
    for (name in names(gen)) {
      s <- gen[[name]]
      cat(sprintf("    %s: %d words (detected by %s)\n",
                  gsub("_", " ", name), s$word_count, s$detected_by))
    }
  }

  # Revision loss detail
  rev_loss <- x$details$structure$revision_loss
  if (!is.null(rev_loss)) {
    if (length(rev_loss$expected) > 0) {
      cat("  Expected revision loss:\n")
      for (pname in names(rev_loss$by_pattern)) {
        ids <- rev_loss$by_pattern[[pname]]
        if (length(ids) > 0) {
          cat(sprintf("    %s: %s\n", pname,
                      paste(head(ids, 5), collapse = ", ")))
          if (length(ids) > 5) {
            cat(sprintf("    ... and %d more\n", length(ids) - 5))
          }
        }
      }
    }
    if (length(rev_loss$unexpected) > 0) {
      cat(sprintf("  UNEXPECTED revision loss: %s\n",
                  paste(head(rev_loss$unexpected, 10), collapse = ", ")))
    }
  }

  # Comment loss detail
  com_loss <- x$details$structure$comment_loss
  if (!is.null(com_loss)) {
    if (length(com_loss$expected) > 0) {
      cat("  Expected comment loss:\n")
      for (pname in names(com_loss$by_pattern)) {
        ids <- com_loss$by_pattern[[pname]]
        if (length(ids) > 0) {
          cat(sprintf("    %s: %s\n", pname,
                      paste(ids, collapse = ", ")))
        }
      }
    }
    if (length(com_loss$unexpected) > 0) {
      cat(sprintf("  UNEXPECTED comment loss: %s\n",
                  paste(com_loss$unexpected, collapse = ", ")))
    }
  }

  # Heading texts comparison
  if (!is.null(x$details$structure$docx_heading_texts) &&
      !is.null(x$details$structure$qmd_heading_texts)) {
    if (!isTRUE(x$checks$headings_match)) {
      cat("  Heading comparison:\n")
      cat(sprintf("    Source: %s\n",
                  paste(head(x$details$structure$docx_heading_texts, 5),
                        collapse = " | ")))
      cat(sprintf("    QMD:    %s\n",
                  paste(head(x$details$structure$qmd_heading_texts, 5),
                        collapse = " | ")))
    }
  }
}

#' Print full detail for round-trip validation
#' @noRd
print_full_detail_round_trip <- function(x) {
  cat(sprintf("\n\u2500\u2500 Detail \u2500\u2500\n"))

  if (!is.null(x$stages$harvest)) {
    print_full_detail(x$stages$harvest)
  }

  if (!is.null(x$stages$render) && !is.na(x$stages$render$render_time)) {
    cat(sprintf("  Render time: %.1fs\n", x$stages$render$render_time))
  }

  if (!is.null(x$stages$structure) && !x$stages$structure$valid) {
    cat("  Structure errors:\n")
    for (err in x$stages$structure$errors) {
      cat(sprintf("    \u2717 %s\n", err))
    }
  }
}


# ══ report() generic and method ═════════════════════════════════════════════

#' Generate a validation report
#'
#' Writes a structured report for archiving or sharing. Includes all detail
#' from the validation result.
#'
#' @param x A `docstyle_validation` object
#' @param ... Additional arguments passed to methods
#' @export
report <- function(x, ...) {
  UseMethod("report")
}


#' Generate a validation report for docstyle results
#'
#' @param x A `docstyle_validation` object
#' @param ... Additional arguments (ignored)
#' @param file Path to write the report. If NULL, returns the report as a
#'   character string.
#' @param format Character. "markdown" (default) or "text".
#'
#' @return If `file` is NULL, returns the report as a character string
#'   (invisibly). If `file` is specified, writes the report and returns
#'   the path (invisibly).
#'
#' @export
report.docstyle_validation <- function(x, ..., file = NULL,
                                        format = c("markdown", "text")) {
  format <- match.arg(format)
  type <- attr(x, "validation_type") %||% "harvest"
  source_file <- attr(x, "source_file")
  timestamp <- attr(x, "timestamp") %||% Sys.time()

  lines <- character()
  add <- function(...) lines <<- c(lines, sprintf(...))

  # Header
  if (format == "markdown") {
    if (type == "round_trip") {
      add("# Round-trip validation report")
    } else {
      add("# Harvest validation report")
    }
    add("")
    if (!is.null(source_file)) add("**Source:** %s", basename(source_file))
    add("**Generated:** %s", format(timestamp, "%Y-%m-%d %H:%M:%S"))
    add("**Result:** %s", if (x$valid) "PASS" else "FAIL")
    add("")
  } else {
    if (type == "round_trip") {
      add("Round-trip validation report")
    } else {
      add("Harvest validation report")
    }
    add("=" )
    if (!is.null(source_file)) add("Source: %s", basename(source_file))
    add("Generated: %s", format(timestamp, "%Y-%m-%d %H:%M:%S"))
    add("Result: %s", if (x$valid) "PASS" else "FAIL")
    add("")
  }

  # Get harvest data
  harvest <- if (!is.null(x$stages)) x$stages$harvest else x

  if (!is.null(harvest)) {
    if (format == "markdown") add("## Harvest validation")
    else add("Harvest validation")
    add("")

    # Summary table
    if (format == "markdown") {
      add("| Check | Status | Details |")
      add("|-------|--------|---------|")

      add_md_row <- function(name, pass, detail) {
        status <- if (isTRUE(pass)) "Pass" else if (isFALSE(pass)) "FAIL" else "N/A"
        add("| %s | %s | %s |", name, status, detail)
      }

      add_md_row("XML well-formed", harvest$checks$xml_wellformed, "")

      if (!is.null(harvest$summary$extraction)) {
        ext <- harvest$summary$extraction
        add_md_row("Citation extraction",
                   harvest$checks$citations_extracted,
                   sprintf("%s Zotero field codes",
                           ext$citations$source_field_codes %||% "?"))
        add_md_row("Comment extraction",
                   harvest$checks$comments_extracted,
                   sprintf("%d source, %d sidecar",
                           ext$comments$source_count %||% 0,
                           ext$comments$sidecar_count %||% 0))
        add_md_row("Revision extraction",
                   harvest$checks$revisions_extracted,
                   sprintf("%d source, %d sidecar",
                           ext$revisions$source_count %||% 0,
                           ext$revisions$sidecar_count %||% 0))
      }

      if (!is.null(harvest$summary$text)) {
        txt <- harvest$summary$text
        add_md_row("Text fidelity",
                   harvest$checks$text_fidelity,
                   sprintf("%.1f%% diff (source=%d, QMD=%d)",
                           txt$diff_pct, txt$docx_word_count,
                           txt$qmd_word_count))
      }

      if (!is.null(harvest$summary$structure)) {
        st <- harvest$summary$structure
        if (!is.null(st$headings)) {
          add_md_row("Headings",
                     harvest$checks$headings_match,
                     sprintf("source=%d, QMD=%d",
                             st$headings$docx, st$headings$qmd))
        }
        if (!is.null(st$tables)) {
          add_md_row("Tables",
                     harvest$checks$tables_match,
                     sprintf("source=%d, QMD=%d",
                             st$tables$docx, st$tables$qmd))
        }
        add_md_row("Citations placed",
                   harvest$checks$citations_placed, "")
        add_md_row("Revisions placed",
                   harvest$checks$revisions_placed, "")
        add_md_row("Comments placed",
                   harvest$checks$comments_placed, "")
      }
      add("")
    } else {
      # Text format
      report_check <- function(name, pass, detail) {
        status <- if (isTRUE(pass)) "[PASS]" else if (isFALSE(pass)) "[FAIL]" else "[N/A]"
        add("  %s %s %s", status, name, detail)
      }

      report_check("XML well-formed", harvest$checks$xml_wellformed, "")

      if (!is.null(harvest$summary$text)) {
        txt <- harvest$summary$text
        report_check("Text fidelity", harvest$checks$text_fidelity,
                     sprintf("(%.1f%% diff)", txt$diff_pct))
      }
      add("")
    }

    # Expected loss details
    rev_loss <- harvest$details$structure$revision_loss
    if (!is.null(rev_loss) && length(rev_loss$expected) > 0) {
      if (format == "markdown") add("### Expected revision loss")
      else add("Expected revision loss:")
      add("")
      for (pname in names(rev_loss$by_pattern)) {
        ids <- rev_loss$by_pattern[[pname]]
        if (length(ids) > 0) {
          add("- **%s**: %d revision(s)", pname, length(ids))
        }
      }
      add("")
    }

    com_loss <- harvest$details$structure$comment_loss
    if (!is.null(com_loss) && length(com_loss$expected) > 0) {
      if (format == "markdown") add("### Expected comment loss")
      else add("Expected comment loss:")
      add("")
      for (pname in names(com_loss$by_pattern)) {
        ids <- com_loss$by_pattern[[pname]]
        if (length(ids) > 0) {
          add("- **%s**: %d comment(s) (IDs: %s)", pname, length(ids),
              paste(ids, collapse = ", "))
        }
      }
      add("")
    }

    # Generated content
    gen <- harvest$details$text$generated_sections
    if (!is.null(gen) && length(gen) > 0) {
      if (format == "markdown") add("### Generated content excluded")
      else add("Generated content excluded:")
      add("")
      for (name in names(gen)) {
        s <- gen[[name]]
        add("- %s: %d words (detected by %s)",
            gsub("_", " ", name), s$word_count, s$detected_by)
      }
      add("")
    }
  }

  # Round-trip stages
  if (type == "round_trip" && !is.null(x$stages)) {
    # Render
    if (!is.null(x$stages$render)) {
      if (format == "markdown") add("## Render")
      else add("Render:")
      add("")
      r <- x$stages$render
      if (r$success) {
        add("- Output: %s", basename(r$output_path))
        if (!is.na(r$render_time)) {
          add("- Time: %.1fs", r$render_time)
        }
      } else {
        add("- **FAILED**")
      }
      add("")
    }

    # Structure
    if (!is.null(x$stages$structure)) {
      if (format == "markdown") add("## Output structure validation")
      else add("Output structure validation:")
      add("")
      s <- x$stages$structure
      if (s$valid) {
        add("- All checks passed")
      } else {
        for (err in s$errors) add("- FAIL: %s", err)
      }
      add("")
    }

    # Comments
    if (!is.null(x$stages$comments)) {
      if (format == "markdown") add("## Comment round-trip")
      else add("Comment round-trip:")
      add("")
      if (isTRUE(x$stages$comments$valid)) {
        add("- All comments validated")
      } else {
        add("- Issues detected")
      }
      add("")
    }
  }

  # Errors and warnings
  if (length(x$issues$errors) > 0) {
    if (format == "markdown") add("## Errors")
    else add("Errors:")
    add("")
    for (err in x$issues$errors) add("- %s", err)
    add("")
  }

  if (length(x$issues$warnings) > 0) {
    if (format == "markdown") add("## Warnings")
    else add("Warnings:")
    add("")
    for (w in x$issues$warnings) add("- %s", w)
    add("")
  }

  content <- paste(lines, collapse = "\n")

  if (!is.null(file)) {
    writeLines(content, file)
    invisible(file)
  } else {
    cat(content)
    invisible(content)
  }
}
