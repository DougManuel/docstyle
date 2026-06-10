#' Validate harvest fidelity
#'
#' Compares a source Word document against its harvested QMD to detect
#' content loss, citation errors, and structural changes. Runs a layered
#' validation sequence: precondition gate, extraction fidelity, text fidelity,
#' and structural fidelity.
#'
#' @param docx_path Path to the source .docx file
#' @param qmd_path Path to the harvested .qmd file. If NULL, only Layer 1
#'   (extraction fidelity) runs.
#' @param sidecar_dir Path to the _docstyle/ sidecar directory. If NULL,
#'   auto-detected from the QMD directory.
#' @param checks Character vector of layers to run. Default runs all.
#'   Available: "extraction", "text", "structure". The precondition gate
#'   always runs regardless of this parameter.
#' @param verbose Logical. Print detailed output. Default TRUE.
#'
#' @return A list with:
#' \describe{
#'   \item{valid}{Logical. TRUE if all critical checks passed}
#'   \item{summary}{List with per-layer metrics}
#'   \item{checks}{Named list of individual check results (TRUE/FALSE)}
#'   \item{issues}{List with errors (critical) and warnings (non-critical)}
#'   \item{details}{List with per-layer detail data}
#' }
#'
#' @examples
#' \dontrun{
#' # Basic validation after harvest
#' result <- validate_harvest("source/document.docx", "document.qmd")
#'
#' # Extraction-only validation (no QMD needed)
#' result <- validate_harvest("source/document.docx", qmd_path = NULL,
#'   sidecar_dir = "_docstyle")
#'
#' # Specific layers only
#' result <- validate_harvest("source/document.docx", "document.qmd",
#'   checks = c("extraction", "text"))
#'
#' # Programmatic use
#' result <- validate_harvest("source/document.docx", "document.qmd",
#'   verbose = FALSE)
#' if (!result$valid) {
#'   stop("Harvest issues: ", paste(result$issues$errors, collapse = "; "))
#' }
#' }
#'
#' @export
validate_harvest <- function(docx_path,
                             qmd_path = NULL,
                             sidecar_dir = NULL,
                             checks = c("extraction", "text", "structure"),
                             verbose = TRUE) {

  checks <- match.arg(checks, several.ok = TRUE)

  # Initialize results structure
  result <- list(
    valid = TRUE,
    summary = list(),
    checks = list(
      xml_wellformed = FALSE,
      citations_extracted = NULL,
      comments_extracted = NULL,
      revisions_extracted = NULL,
      text_fidelity = NULL,
      headings_match = NULL,
      tables_match = NULL,
      citations_placed = NULL,
      revisions_placed = NULL,
      comments_placed = NULL
    ),
    issues = list(
      errors = character(),
      warnings = character()
    ),
    details = list()
  )

  if (verbose) {
    cat("\n\u2550\u2550 Validating harvest \u2550\u2550\n")
  }

  # ── Precondition gate ──────────────────────────────────────────────────────
  vh_section(verbose, "Precondition")

  if (!file.exists(docx_path)) {
    result$valid <- FALSE
    result$issues$errors <- c(result$issues$errors,
                              paste("Source DOCX not found:", docx_path))
    vh_check(verbose, FALSE, paste("Source DOCX:", docx_path))
    return(invisible(result))
  }
  vh_check(verbose, TRUE, paste("Source DOCX:", basename(docx_path)))

  precondition <- check_xml_precondition(docx_path, verbose)
  result$checks$xml_wellformed <- precondition$pass
  result$summary$precondition <- precondition$summary
  result$details$precondition <- precondition$details

  if (!precondition$pass) {
    result$valid <- FALSE
    result$issues$errors <- c(result$issues$errors, precondition$message)
    vh_result(verbose, result)
    return(invisible(result))
  }

  # Reuse parsed XML from precondition gate (avoids re-parsing)
  parsed <- precondition$parsed
  on.exit(unlink(parsed$temp_dir, recursive = TRUE), add = TRUE)
  doc_xml <- parsed$doc_xml
  ns <- parsed$ns

  # Warnings from precondition (e.g., orphaned markers)
  if (length(precondition$warnings) > 0) {
    result$issues$warnings <- c(result$issues$warnings, precondition$warnings)
  }

  # ── Resolve QMD and sidecar paths ──────────────────────────────────────────

  has_qmd <- !is.null(qmd_path) && file.exists(qmd_path)
  if (!is.null(qmd_path) && !has_qmd) {
    result$valid <- FALSE
    result$issues$errors <- c(result$issues$errors,
                              paste("QMD not found:", qmd_path))
    vh_check(verbose, FALSE, paste("QMD file:", qmd_path))
    vh_result(verbose, result)
    return(invisible(result))
  }
  if (has_qmd) {
    vh_check(verbose, TRUE, paste("QMD file:", basename(qmd_path)))
  }

  # Auto-detect sidecar dir
  if (is.null(sidecar_dir)) {
    search_dir <- if (has_qmd) dirname(qmd_path) else dirname(docx_path)
    candidates <- c(
      file.path(search_dir, "_docstyle"),
      file.path(dirname(search_dir), "_docstyle")
    )
    for (candidate in candidates) {
      if (dir.exists(candidate)) {
        sidecar_dir <- candidate
        break
      }
    }
  }

  has_sidecar <- !is.null(sidecar_dir) && dir.exists(sidecar_dir)
  if (has_sidecar) {
    vh_check(verbose, TRUE, paste("Sidecar dir:", basename(sidecar_dir)))
  } else {
    vh_warn(verbose, "No sidecar directory found; extraction checks limited")
  }

  # ── Layer 1: Extraction fidelity ───────────────────────────────────────────
  if ("extraction" %in% checks) {
    vh_section(verbose, "Layer 1: Extraction fidelity")
    extraction <- check_harvest_extraction(doc_xml, ns, parsed$comments_xml,
                                              sidecar_dir, verbose)
    result$summary$extraction <- extraction$summary
    result$details$extraction <- extraction$details

    result$checks$citations_extracted <- extraction$checks$citations
    result$checks$comments_extracted <- extraction$checks$comments
    result$checks$revisions_extracted <- extraction$checks$revisions

    if (length(extraction$errors) > 0) {
      result$valid <- FALSE
      result$issues$errors <- c(result$issues$errors, extraction$errors)
    }
    if (length(extraction$warnings) > 0) {
      result$issues$warnings <- c(result$issues$warnings, extraction$warnings)
    }
  }

  # ── Layers 2 and 3 require QMD ─────────────────────────────────────────────
  if (!has_qmd) {
    if (any(c("text", "structure") %in% checks)) {
      vh_info(verbose, "No QMD file provided; skipping text and structure layers")
    }
    vh_result(verbose, result)
    return(invisible(result))
  }

  qmd_lines <- readLines(qmd_path, warn = FALSE)
  qmd_body <- strip_yaml_header(qmd_lines)

  # ── Layer 2: Text fidelity ────────────────────────────────────────────────
  if ("text" %in% checks) {
    vh_section(verbose, "Layer 2: Text fidelity")
    docx_text <- extract_docx_plain_text(docx_path = docx_path,
                                           doc_xml = doc_xml, ns = ns)
    text_result <- check_harvest_text(docx_text, qmd_body, verbose)
    result$summary$text <- text_result$summary
    result$details$text <- text_result$details
    result$checks$text_fidelity <- text_result$pass

    if (!text_result$pass && text_result$severity == "error") {
      result$valid <- FALSE
      result$issues$errors <- c(result$issues$errors, text_result$message)
    } else if (!is.null(text_result$message)) {
      result$issues$warnings <- c(result$issues$warnings, text_result$message)
    }
  }

  # ── Layer 3: Structural fidelity ──────────────────────────────────────────
  if ("structure" %in% checks) {
    vh_section(verbose, "Layer 3: Structural fidelity")
    if (!exists("docx_text")) {
      docx_text <- extract_docx_plain_text(docx_path = docx_path,
                                           doc_xml = doc_xml, ns = ns)
    }
    # Pass generated_sections from text layer (if available) for heading adjustment
    generated_sections <- if (!is.null(result$details$text$generated_sections)) {
      result$details$text$generated_sections
    } else {
      # Text layer didn't run; compute independently
      strip_generated_content(qmd_body)$sections_stripped
    }
    structure_result <- check_harvest_structure(doc_xml, ns, docx_text, qmd_body,
                                                sidecar_dir, verbose,
                                                generated_sections = generated_sections)
    result$summary$structure <- structure_result$summary
    result$details$structure <- structure_result$details

    result$checks$headings_match <- structure_result$checks$headings
    result$checks$tables_match <- structure_result$checks$tables
    result$checks$citations_placed <- structure_result$checks$citations_placed
    result$checks$revisions_placed <- structure_result$checks$revisions_placed
    result$checks$comments_placed <- structure_result$checks$comments_placed

    if (length(structure_result$errors) > 0) {
      result$valid <- FALSE
      result$issues$errors <- c(result$issues$errors, structure_result$errors)
    }
    if (length(structure_result$warnings) > 0) {
      result$issues$warnings <- c(result$issues$warnings,
                                   structure_result$warnings)
    }
  }

  # ── Informational: ad-hoc list hints ──
  adhoc <- detect_adhoc_lists(docx_path, doc_xml, ns, verbose)
  if (length(adhoc) > 0) {
    result$details$adhoc_lists <- adhoc
  }

  # ── Summary ──
  vh_result(verbose, result)
  result <- new_docstyle_validation(result, type = "harvest",
                                     source_file = docx_path)
  invisible(result)
}


# ── Verbose output helpers ───────────────────────────────────────────────────

vh_check <- function(verbose, pass, msg) {
  if (verbose) {
    symbol <- if (pass) "\u2713" else "\u2717"
    cat(sprintf("  %s %s\n", symbol, msg))
  }
}

vh_info <- function(verbose, msg) {
  if (verbose) cat(sprintf("  \u2139 %s\n", msg))
}

vh_warn <- function(verbose, msg) {
  if (verbose) cat(sprintf("  \u26a0 %s\n", msg))
}

vh_section <- function(verbose, title) {
  if (verbose) cat(sprintf("\n\u2500\u2500 %s \u2500\u2500\n", title))
}

vh_result <- function(verbose, result) {
  if (!verbose) return(invisible(NULL))
  cat(sprintf("\n\u2550\u2550 Result: %s \u2550\u2550\n",
              if (result$valid) "PASS" else "FAIL"))
  if (length(result$issues$errors) > 0) {
    cat("Errors:\n")
    for (e in result$issues$errors) cat(sprintf("  \u2717 %s\n", e))
  }
  if (length(result$issues$warnings) > 0) {
    cat("Warnings:\n")
    for (w in result$issues$warnings) cat(sprintf("  \u26a0 %s\n", w))
  }
}


# ── Precondition gate ────────────────────────────────────────────────────────

#' Check that the source DOCX is well-formed XML
#'
#' Parses document.xml, checks for a body element, and identifies orphaned
#' comment markers (markers referencing non-existent comments). When called
#' from validate_harvest(), also returns the parsed XML for reuse by
#' subsequent layers.
#'
#' @param docx_path Path to .docx file
#' @param verbose Logical
#' @return List with pass, message, warnings, summary, details, and
#'   parsed (doc_xml, ns, comments_xml, temp_dir) when successful
#' @noRd
check_xml_precondition <- function(docx_path, verbose) {
  result <- list(
    pass = TRUE,
    message = NULL,
    warnings = character(),
    summary = list(xml_parsed = FALSE, has_body = FALSE),
    details = list(orphaned_comment_markers = character()),
    parsed = NULL
  )

  parsed <- tryCatch(
    parse_docx_xml(docx_path),
    error = function(e) {
      list(error = conditionMessage(e))
    }
  )

  if (!is.null(parsed$error)) {
    result$pass <- FALSE
    result$message <- paste("Failed to parse DOCX:", parsed$error)
    vh_check(verbose, FALSE, "XML: failed to parse")
    return(result)
  }

  doc_xml <- parsed$doc_xml
  ns <- parsed$ns
  result$summary$xml_parsed <- TRUE

  body <- xml2::xml_find_first(doc_xml, ".//w:body", ns)
  if (inherits(body, "xml_missing")) {
    result$pass <- FALSE
    result$message <- "document.xml has no w:body element"
    vh_check(verbose, FALSE, "XML: no body element")
    unlink(parsed$temp_dir, recursive = TRUE)
    return(result)
  }
  result$summary$has_body <- TRUE
  vh_check(verbose, TRUE, "XML well-formed, body present")

  # ── Structural check: orphaned comment markers ──
  if (!is.null(parsed$comments_xml)) {
    marker_ids <- xml2::xml_text(
      xml2::xml_find_all(doc_xml, "//w:commentRangeStart/@w:id", ns))
    comment_ids <- xml2::xml_text(
      xml2::xml_find_all(parsed$comments_xml, "//w:comment/@w:id",
                         xml2::xml_ns(parsed$comments_xml)))

    orphaned <- setdiff(marker_ids, comment_ids)
    if (length(orphaned) > 0) {
      result$details$orphaned_comment_markers <- orphaned
      msg <- sprintf("%d comment marker(s) reference non-existent comments",
                     length(orphaned))
      result$warnings <- c(result$warnings, msg)
      vh_warn(verbose, msg)
    }
  }

  # Return parsed XML for reuse by subsequent layers
  result$parsed <- parsed
  result
}


# ── Layer 1: Extraction fidelity ─────────────────────────────────────────────

#' Check extraction fidelity: source XML IDs vs sidecar file entries
#'
#' Uses independent XPath queries (not the extract_*() functions) to count
#' source elements, then compares against sidecar file contents using
#' set operations on IDs.
#'
#' @param doc_xml Parsed document.xml
#' @param ns XML namespace
#' @param comments_xml Parsed comments.xml (or NULL)
#' @param sidecar_dir Path to sidecar directory (may be NULL)
#' @param verbose Logical
#' @return List with checks, errors, warnings, summary, details
#' @noRd
check_harvest_extraction <- function(doc_xml, ns, comments_xml, sidecar_dir,
                                      verbose) {
  result <- list(
    checks = list(citations = NULL, comments = NULL, revisions = NULL),
    errors = character(),
    warnings = character(),
    summary = list(),
    details = list(
      citations = list(), comments = list(), revisions = list()
    )
  )

  has_sidecar <- !is.null(sidecar_dir) && dir.exists(sidecar_dir)

  # ── Citations ──
  instr_nodes <- xml2::xml_find_all(doc_xml, "//w:instrText", ns)
  all_instr_text <- xml2::xml_text(instr_nodes)
  zotero_mask <- grepl("ZOTERO_ITEM", all_instr_text)
  source_zotero_count <- sum(zotero_mask)

  # Non-Zotero field code breakdown (verbose only)
  if (verbose && length(all_instr_text) > 0) {
    non_zotero <- all_instr_text[!zotero_mask]
    if (length(non_zotero) > 0) {
      toc_n <- sum(grepl("^\\s*TOC\\b", non_zotero))
      ref_n <- sum(grepl("^\\s*REF\\b", non_zotero))
      page_n <- sum(grepl("^\\s*PAGE\\b", non_zotero))
      other_n <- length(non_zotero) - toc_n - ref_n - page_n
      parts <- character()
      if (toc_n > 0) parts <- c(parts, sprintf("%d TOC", toc_n))
      if (ref_n > 0) parts <- c(parts, sprintf("%d REF", ref_n))
      if (page_n > 0) parts <- c(parts, sprintf("%d PAGE", page_n))
      if (other_n > 0) parts <- c(parts, sprintf("%d other", other_n))
      vh_info(verbose, sprintf("Non-Zotero field codes: %s",
                               paste(parts, collapse = ", ")))
    }
  }

  sidecar_citation_count <- NA_integer_
  if (has_sidecar) {
    fc_path <- file.path(sidecar_dir, "field-codes.json")
    if (file.exists(fc_path)) {
      fc <- tryCatch(
        jsonlite::fromJSON(fc_path, simplifyVector = FALSE),
        error = function(e) {
          result$warnings <<- c(result$warnings,
            sprintf("Malformed JSON in %s: %s", basename(fc_path), conditionMessage(e)))
          NULL
        }
      )
      if (!is.null(fc)) sidecar_citation_count <- length(fc$citations)
    }
  }

  # Note: field-codes.json stores individual cited items (bibliography entries),
  # which may differ from field code count (some field codes cite multiple refs).
  # We report both but only compare field code count vs field code count.
  if (!is.na(sidecar_citation_count)) {
    vh_check(verbose, TRUE,
             sprintf("Citations: %d Zotero field codes in source, %d items in field-codes.json",
                     source_zotero_count, sidecar_citation_count))
    vh_info(verbose, "(Field code count and cited item count may differ for multi-ref citations)")
  } else {
    vh_check(verbose, TRUE,
             sprintf("Citations: %d Zotero field codes in source", source_zotero_count))
    if (has_sidecar) vh_info(verbose, "field-codes.json not found")
  }
  result$checks$citations <- TRUE
  result$summary$citations <- list(
    source_field_codes = source_zotero_count,
    sidecar_cited_items = sidecar_citation_count
  )
  result$details$citations <- list(source_count = source_zotero_count)

  # ── Comments ──
  source_comment_ids <- character()
  if (!is.null(comments_xml)) {
    source_comment_ids <- xml2::xml_text(
      xml2::xml_find_all(comments_xml, "//w:comment/@w:id",
                         xml2::xml_ns(comments_xml)))
  }

  sidecar_comment_ids <- character()
  if (has_sidecar) {
    comments_path <- file.path(sidecar_dir, "comments.json")
    if (file.exists(comments_path)) {
      sidecar_comments <- tryCatch(
        jsonlite::fromJSON(comments_path, simplifyVector = FALSE),
        error = function(e) {
          result$warnings <<- c(result$warnings,
            sprintf("Malformed JSON in %s: %s", basename(comments_path), conditionMessage(e)))
          NULL
        }
      )
      if (!is.null(sidecar_comments)) {
        sidecar_comment_ids <- vapply(sidecar_comments, function(c) {
          as.character(c$id %||% "")
        }, character(1))
      }
    }
  }

  comment_missing <- setdiff(source_comment_ids, sidecar_comment_ids)
  comment_extra <- setdiff(sidecar_comment_ids, source_comment_ids)
  comment_pass <- (length(comment_missing) == 0 && length(comment_extra) == 0)

  if (length(source_comment_ids) == 0 && length(sidecar_comment_ids) == 0) {
    comment_pass <- TRUE
    vh_check(verbose, TRUE, "Comments: none in source or sidecar")
  } else if (!has_sidecar || !file.exists(file.path(sidecar_dir, "comments.json"))) {
    comment_pass <- TRUE  # Can't validate without sidecar
    vh_check(verbose, TRUE,
             sprintf("Comments: %d in source (no sidecar to compare)",
                     length(source_comment_ids)))
  } else {
    vh_check(verbose, comment_pass,
             sprintf("Comments: %d in source, %d in sidecar",
                     length(source_comment_ids), length(sidecar_comment_ids)))
    if (length(comment_missing) > 0) {
      msg <- sprintf("%d comment(s) in source not found in sidecar",
                     length(comment_missing))
      result$errors <- c(result$errors, msg)
      vh_info(verbose, sprintf("Missing IDs: %s",
                               paste(head(comment_missing, 5), collapse = ", ")))
    }
  }
  result$checks$comments <- comment_pass
  result$summary$comments <- list(
    source_count = length(source_comment_ids),
    sidecar_count = length(sidecar_comment_ids)
  )
  result$details$comments <- list(
    source_ids = source_comment_ids,
    sidecar_ids = sidecar_comment_ids,
    missing = comment_missing,
    extra = comment_extra
  )

  # ── Revisions ──
  source_ins_ids <- xml2::xml_text(
    xml2::xml_find_all(doc_xml, "//w:ins/@w:id", ns))
  source_del_ids <- xml2::xml_text(
    xml2::xml_find_all(doc_xml, "//w:del/@w:id", ns))
  raw_ids <- c(source_ins_ids, source_del_ids)
  source_rev_ids <- if (length(raw_ids) > 0) paste0("rev_", raw_ids) else character()

  sidecar_rev_ids <- character()
  if (has_sidecar) {
    rev_path <- file.path(sidecar_dir, "revisions.json")
    if (file.exists(rev_path)) {
      sidecar_revisions <- tryCatch(
        jsonlite::fromJSON(rev_path, simplifyVector = FALSE),
        error = function(e) {
          result$warnings <<- c(result$warnings,
            sprintf("Malformed JSON in %s: %s", basename(rev_path), conditionMessage(e)))
          NULL
        }
      )
      if (!is.null(sidecar_revisions)) sidecar_rev_ids <- names(sidecar_revisions)
    }
  }

  rev_missing <- setdiff(source_rev_ids, sidecar_rev_ids)
  rev_extra <- setdiff(sidecar_rev_ids, source_rev_ids)
  rev_pass <- TRUE  # Revision extraction mismatches are warnings

  if (length(source_rev_ids) == 0 && length(sidecar_rev_ids) == 0) {
    vh_check(verbose, TRUE, "Revisions: none in source or sidecar")
  } else if (!has_sidecar || !file.exists(file.path(sidecar_dir, "revisions.json"))) {
    vh_check(verbose, TRUE,
             sprintf("Revisions: %d in source (no sidecar to compare)",
                     length(source_rev_ids)))
  } else {
    id_match <- (length(rev_missing) == 0 && length(rev_extra) == 0)
    vh_check(verbose, id_match,
             sprintf("Revisions: %d in source, %d in sidecar",
                     length(source_rev_ids), length(sidecar_rev_ids)))
    if (length(rev_missing) > 0) {
      msg <- sprintf("%d revision(s) in source not in sidecar (may be intentionally skipped)",
                     length(rev_missing))
      result$warnings <- c(result$warnings, msg)
    }
  }
  result$checks$revisions <- rev_pass
  result$summary$revisions <- list(
    source_count = length(source_rev_ids),
    sidecar_count = length(sidecar_rev_ids)
  )
  result$details$revisions <- list(
    source_ids = source_rev_ids,
    sidecar_ids = sidecar_rev_ids,
    missing = rev_missing,
    extra = rev_extra
  )

  result
}


# ── Layer 2: Text fidelity ───────────────────────────────────────────────────

#' Check text fidelity between source docx and harvested QMD
#'
#' Compares word counts after stripping generated content from the QMD
#' and Zotero field code JSON from the source.
#'
#' @param docx_text Output of extract_docx_plain_text()
#' @param qmd_body QMD body text (YAML stripped)
#' @param verbose Logical
#' @return List with pass, severity, message, summary, details
#' @noRd
check_harvest_text <- function(docx_text, qmd_body, verbose) {
  # Strip generated content from QMD before comparison
  stripped <- strip_generated_content(qmd_body)
  qmd_clean <- stripped$body

  # Strip markdown syntax for fairer comparison
  qmd_clean <- gsub("\\[([^]]+)\\]\\{[^}]*\\}", "\\1", qmd_clean)  # spans
  qmd_clean <- gsub("\\[@[^]]+\\]", "", qmd_clean)  # citations
  qmd_clean <- gsub("\\*\\*([^*]+)\\*\\*", "\\1", qmd_clean)  # bold
  qmd_clean <- gsub("\\*([^*]+)\\*", "\\1", qmd_clean)  # italic
  qmd_clean <- gsub("(?m)^#{1,6}\\s+", "", qmd_clean, perl = TRUE)  # headings
  qmd_clean <- gsub("(?m)^:::.*$", "", qmd_clean, perl = TRUE)  # div fences
  qmd_clean <- gsub("(?m)^\\|.*$", "", qmd_clean, perl = TRUE)  # table rows

  qmd_words <- strsplit(trimws(qmd_clean), "\\s+")[[1]]
  qmd_words <- qmd_words[nchar(qmd_words) > 0]
  qmd_word_count <- length(qmd_words)

  docx_word_count <- docx_text$word_count
  diff_pct <- if (docx_word_count > 0) {
    abs(qmd_word_count - docx_word_count) / docx_word_count * 100
  } else {
    0
  }

  pass <- TRUE
  severity <- "ok"
  message <- NULL

  if (diff_pct > 10) {
    pass <- FALSE
    severity <- "error"
    message <- sprintf("Word count differs by %.0f%% (source: %d, QMD: %d)",
                       diff_pct, docx_word_count, qmd_word_count)
  } else if (diff_pct > 5) {
    pass <- TRUE
    severity <- "warning"
    message <- sprintf("Word count differs by %.0f%% (source: %d, QMD: %d)",
                       diff_pct, docx_word_count, qmd_word_count)
  }

  vh_check(verbose, diff_pct <= 10,
           sprintf("Word count: source=%d, QMD=%d (%.1f%% diff)",
                   docx_word_count, qmd_word_count, diff_pct))

  # Report stripped sections
  if (length(stripped$sections_stripped) > 0) {
    for (section_name in names(stripped$sections_stripped)) {
      s <- stripped$sections_stripped[[section_name]]
      vh_info(verbose, sprintf("Excluded: %s (%d words, detected by %s)",
                               section_name, s$word_count, s$detected_by))
    }
  }

  list(
    pass = pass,
    severity = severity,
    message = message,
    summary = list(
      docx_word_count = docx_word_count,
      qmd_word_count = qmd_word_count,
      diff_pct = round(diff_pct, 1)
    ),
    details = list(
      generated_sections = stripped$sections_stripped
    )
  )
}


#' Strip generated content sections from QMD body
#'
#' Removes sections that are generated from YAML metadata during render
#' (version history, author plate, bibliography, ZOTERO_PREF). Reports
#' which sections were stripped and how they were detected.
#'
#' @param qmd_body Character. QMD body text (YAML already stripped).
#' @return List with body (stripped text) and sections_stripped (metadata)
#' @noRd
strip_generated_content <- function(qmd_body) {
  lines <- strsplit(qmd_body, "\n", fixed = TRUE)[[1]]
  sections_stripped <- list()
  exclude_mask <- rep(FALSE, length(lines))

  # ── Helper: strip a div section ──
  strip_div <- function(div_pattern, section_name) {
    for (i in seq_along(lines)) {
      if (grepl(div_pattern, lines[i])) {
        # Found div start; find matching close
        depth <- 1
        start <- i
        for (j in (i + 1):length(lines)) {
          if (j > length(lines)) break
          if (grepl("^:::", lines[j]) && !grepl("^:::\\s*\\{", lines[j])) {
            depth <- depth - 1
            if (depth == 0) {
              section_lines <- lines[start:j]
              section_text <- paste(section_lines, collapse = " ")
              words <- strsplit(trimws(section_text), "\\s+")[[1]]
              words <- words[nchar(words) > 0]
              sections_stripped[[section_name]] <<- list(
                detected_by = "div",
                word_count = length(words)
              )
              exclude_mask[start:j] <<- TRUE
              return(TRUE)
            }
          } else if (grepl("^:::\\s*\\{", lines[j])) {
            depth <- depth + 1
          }
        }
        # Inner loop ended without closing the div
        if (depth > 0) {
          warning(sprintf("Unclosed div '%s' starting at line %d", section_name, start),
                  call. = FALSE)
        }
      }
    }
    FALSE
  }

  # ── Helper: strip from heading to next heading of same or higher level ──
  strip_heading <- function(heading_pattern, section_name, level = 2) {
    heading_re <- sprintf("^#{%d}\\s+", level)
    for (i in seq_along(lines)) {
      if (grepl(heading_pattern, lines[i], ignore.case = TRUE)) {
        start <- i
        end_idx <- length(lines)
        for (j in (i + 1):length(lines)) {
          if (j > length(lines)) break
          if (grepl(heading_re, lines[j])) {
            end_idx <- j - 1
            break
          }
        }
        section_lines <- lines[start:end_idx]
        section_text <- paste(section_lines, collapse = " ")
        words <- strsplit(trimws(section_text), "\\s+")[[1]]
        words <- words[nchar(words) > 0]
        sections_stripped[[section_name]] <<- list(
          detected_by = "heading",
          word_count = length(words)
        )
        exclude_mask[start:end_idx] <<- TRUE
        return(TRUE)
      }
    }
    FALSE
  }

  # Version history: div first (class or ID syntax), then heading fallback
  if (!strip_div("^:::\\s*version-history", "version_history")) {
    if (!strip_div("^:::\\s*\\{\\s*\\.?#?version-history", "version_history")) {
      if (!strip_heading("^##\\s+Version\\s+history", "version_history", level = 2)) {
        strip_heading("^#\\s+Version\\s+history", "version_history", level = 1)
      }
    }
  }

  # Author plate: div first (class or ID syntax), then heading fallback
  if (!strip_div("^:::\\s*author-plate", "author_plate")) {
    if (!strip_div("^:::\\s*\\{\\s*\\.?#?author-plate", "author_plate")) {
      strip_heading("^##\\s+Authors", "author_plate")
    }
  }

  # Bibliography
  if (!strip_div("^:::\\s*\\{\\s*\\.?#?refs", "bibliography")) {
    strip_heading("^##?\\s+References", "bibliography")
  }

  # TOC: div first (class or ID syntax), then heading fallback
  if (!strip_div("^:::\\s*toc", "toc")) {
    if (!strip_div("^:::\\s*\\{\\s*\\.?#?toc\\s*\\}", "toc")) {
      strip_heading("^#\\s+Contents", "toc", level = 1)
    }
  }

  # ZOTERO_PREF lines
  zotero_pref_lines <- grepl("ZOTERO_PREF", lines)
  if (any(zotero_pref_lines)) {
    n <- sum(zotero_pref_lines)
    sections_stripped[["zotero_pref"]] <- list(
      detected_by = "line",
      word_count = 0
    )
    exclude_mask <- exclude_mask | zotero_pref_lines
  }

  remaining <- lines[!exclude_mask]
  list(
    body = paste(remaining, collapse = "\n"),
    sections_stripped = sections_stripped
  )
}


# ── Layer 3: Structural fidelity ─────────────────────────────────────────────

#' Check structural fidelity (headings, tables, placement of citations,
#' revisions, and comments in QMD)
#'
#' @param doc_xml Parsed document.xml
#' @param ns XML namespace
#' @param docx_text Output of extract_docx_plain_text()
#' @param qmd_body QMD body text (YAML stripped)
#' @param sidecar_dir Path to sidecar directory (may be NULL)
#' @param verbose Logical
#' @param generated_sections Named list from strip_generated_content()$sections_stripped.
#'   Used to adjust heading count for generated content headings in QMD.
#' @return List with checks, errors, warnings, summary, details
#' @noRd
check_harvest_structure <- function(doc_xml, ns, docx_text, qmd_body,
                                     sidecar_dir, verbose,
                                     generated_sections = list()) {
  result <- list(
    checks = list(headings = NULL, tables = NULL,
                  citations_placed = NULL, revisions_placed = NULL,
                  comments_placed = NULL),
    errors = character(),
    warnings = character(),
    summary = list(),
    details = list()
  )

  has_sidecar <- !is.null(sidecar_dir) && dir.exists(sidecar_dir)

  # ── Headings ──
  docx_headings <- docx_text$headings
  docx_heading_count <- nrow(docx_headings)

  qmd_heading_lines <- regmatches(qmd_body,
    gregexpr("(?m)^#{1,6}\\s+.+$", qmd_body, perl = TRUE))[[1]]
  qmd_heading_count <- length(qmd_heading_lines)

  # Generated content heading adjustment:
  # - Heading-detected sections (e.g. bibliography): heading exists in BOTH
  #   source DOCX and QMD, so no adjustment needed.
  # - Div-detected sections (e.g. version-history): heading exists in DOCX
  #   (inside field code/bookmark, excluded from source count) but NOT in QMD
  #   (QMD has ::: div syntax, not a markdown heading). No adjustment needed.
  # Therefore generated_heading_count is always 0 — both sides already balance.
  generated_heading_count <- 0L

  # Adjusted QMD count removes div-generated headings for fair comparison
  qmd_heading_adjusted <- qmd_heading_count - generated_heading_count

  heading_match <- (docx_heading_count == qmd_heading_adjusted)
  result$checks$headings <- heading_match

  if (generated_heading_count > 0) {
    vh_check(verbose, heading_match,
             sprintf("Headings: source=%d, QMD=%d (%d generated, %d from source)",
                     docx_heading_count, qmd_heading_count,
                     generated_heading_count, qmd_heading_adjusted))
  } else {
    vh_check(verbose, heading_match,
             sprintf("Headings: source=%d, QMD=%d",
                     docx_heading_count, qmd_heading_count))
  }
  if (!heading_match) {
    result$warnings <- c(result$warnings,
                          sprintf("Heading count mismatch: source=%d, QMD=%d (adjusted=%d, %d generated)",
                                  docx_heading_count, qmd_heading_count,
                                  qmd_heading_adjusted, generated_heading_count))
  }

  # ── Tables ──
  docx_table_count <- docx_text$table_count
  qmd_table_seps <- length(regmatches(qmd_body,
    gregexpr("(?m)^\\|[-:| ]+\\|$", qmd_body, perl = TRUE))[[1]])

  # Count generated content tables (sections that contain tables in the docx
  # but are restored as div placeholders in QMD, e.g. version_history)
  generated_table_names <- c("version_history")
  generated_table_count <- sum(names(generated_sections) %in% generated_table_names)

  table_match <- (docx_table_count == qmd_table_seps)
  result$checks$tables <- table_match

  if (generated_table_count > 0) {
    vh_check(verbose, table_match,
             sprintf("Tables: source=%d, QMD=%d (%d in generated content)",
                     docx_table_count, qmd_table_seps, generated_table_count))
  } else {
    vh_check(verbose, table_match,
             sprintf("Tables: source=%d, QMD=%d",
                     docx_table_count, qmd_table_seps))
  }
  if (!table_match) {
    result$warnings <- c(result$warnings,
                          sprintf("Table count mismatch: source=%d, QMD=%d",
                                  docx_table_count, qmd_table_seps))
  }

  result$summary$headings <- list(
    docx = docx_heading_count, qmd = qmd_heading_count,
    qmd_adjusted = qmd_heading_adjusted, generated = generated_heading_count)
  result$summary$tables <- list(
    docx = docx_table_count, qmd = qmd_table_seps,
    generated = generated_table_count)

  # ── Citation placement ──
  # Count [@citekey] in QMD vs Zotero field codes in source
  instr_nodes <- xml2::xml_find_all(doc_xml, "//w:instrText", ns)
  source_cite_count <- sum(grepl("ZOTERO_ITEM", xml2::xml_text(instr_nodes)))

  qmd_cites <- regmatches(qmd_body,
    gregexpr("\\[@[a-zA-Z][a-zA-Z0-9_:.-]*(?:;\\s*@[a-zA-Z][a-zA-Z0-9_:.-]*)*\\]",
             qmd_body, perl = TRUE))[[1]]
  qmd_cite_count <- length(qmd_cites)

  cite_placed <- (source_cite_count == qmd_cite_count)
  result$checks$citations_placed <- cite_placed
  vh_check(verbose, cite_placed,
           sprintf("Citation placement: source=%d, QMD=%d",
                   source_cite_count, qmd_cite_count))
  if (!cite_placed) {
    result$errors <- c(result$errors,
                        sprintf("Citation count mismatch: %d in source, %d in QMD",
                                source_cite_count, qmd_cite_count))
  }

  # ── Revision placement ──
  qmd_rev_ids <- regmatches(qmd_body,
    gregexpr('id="(rev_[0-9]+)"', qmd_body, perl = TRUE))[[1]]
  qmd_rev_ids <- unique(sub('id="(rev_[0-9]+)"', "\\1", qmd_rev_ids))

  sidecar_rev_ids <- character()
  if (has_sidecar) {
    rev_path <- file.path(sidecar_dir, "revisions.json")
    if (file.exists(rev_path)) {
      sidecar_revisions <- tryCatch(
        jsonlite::fromJSON(rev_path, simplifyVector = FALSE),
        error = function(e) {
          result$warnings <<- c(result$warnings,
            sprintf("Malformed JSON in %s: %s", basename(rev_path), conditionMessage(e)))
          NULL
        }
      )
      if (!is.null(sidecar_revisions)) sidecar_rev_ids <- names(sidecar_revisions)
    }
  }

  if (length(sidecar_rev_ids) > 0) {
    missing_from_qmd <- setdiff(sidecar_rev_ids, qmd_rev_ids)

    if (length(missing_from_qmd) > 0) {
      # Classify using expected loss registry
      loss <- classify_revision_loss(missing_from_qmd, doc_xml, ns)
      revision_placed <- (length(loss$unexpected) == 0)
      result$checks$revisions_placed <- revision_placed

      vh_check(verbose, revision_placed,
               sprintf("Revision placement: %d in QMD, %d expected loss, %d unexpected loss",
                       length(qmd_rev_ids), length(loss$expected),
                       length(loss$unexpected)))

      # Report expected loss patterns
      for (pattern_name in names(loss$by_pattern)) {
        ids <- loss$by_pattern[[pattern_name]]
        if (length(ids) > 0) {
          vh_info(verbose, sprintf("  %s: %d revision(s)", pattern_name, length(ids)))
        }
      }

      if (length(loss$unexpected) > 0) {
        result$errors <- c(result$errors,
                            sprintf("%d revision(s) with content missing from QMD",
                                    length(loss$unexpected)))
        for (uid in head(loss$unexpected, 5)) {
          vh_info(verbose, sprintf("  Unexpected: %s", uid))
        }
      }

      result$details$revision_loss <- loss
    } else {
      result$checks$revisions_placed <- TRUE
      vh_check(verbose, TRUE,
               sprintf("Revision placement: all %d sidecar revisions in QMD",
                       length(sidecar_rev_ids)))
      result$details$revision_loss <- list(
        expected = character(), unexpected = character(),
        by_pattern = list())
    }
  } else {
    result$checks$revisions_placed <- TRUE
    vh_check(verbose, TRUE, "Revision placement: no sidecar revisions to check")
    result$details$revision_loss <- list(
      expected = character(), unexpected = character(),
      by_pattern = list())
  }

  # ── Comment placement ──
  qmd_comment_ids <- regmatches(qmd_body,
    gregexpr('comment:start id="([^"]+)"', qmd_body, perl = TRUE))[[1]]
  qmd_comment_ids <- sub('comment:start id="([^"]+)"', "\\1", qmd_comment_ids)
  qmd_comment_count <- length(qmd_comment_ids)

  sidecar_comment_ids <- character()
  if (has_sidecar) {
    comments_path <- file.path(sidecar_dir, "comments.json")
    if (file.exists(comments_path)) {
      sc <- jsonlite::fromJSON(comments_path, simplifyVector = FALSE)
      sidecar_comment_ids <- vapply(sc, function(c) {
        as.character(c$id %||% "")
      }, character(1))
      sidecar_comment_ids <- sidecar_comment_ids[nchar(sidecar_comment_ids) > 0]
    }
  }
  sidecar_comment_count <- length(sidecar_comment_ids)

  if (sidecar_comment_count > 0) {
    missing_from_qmd <- setdiff(sidecar_comment_ids, qmd_comment_ids)

    if (length(missing_from_qmd) > 0) {
      # Classify missing comments using expected loss patterns
      comment_loss <- classify_comment_loss(missing_from_qmd, doc_xml, ns)
      comment_placed <- (length(comment_loss$unexpected) == 0)
      result$checks$comments_placed <- comment_placed

      vh_check(verbose, comment_placed,
               sprintf("Comment placement: %d in QMD, %d expected loss, %d unexpected loss",
                       qmd_comment_count, length(comment_loss$expected),
                       length(comment_loss$unexpected)))

      # Report expected loss patterns
      for (pattern_name in names(comment_loss$by_pattern)) {
        ids <- comment_loss$by_pattern[[pattern_name]]
        if (length(ids) > 0) {
          vh_info(verbose, sprintf("  %s: %d comment(s)", pattern_name, length(ids)))
        }
      }

      if (length(comment_loss$unexpected) > 0) {
        result$errors <- c(result$errors,
                            sprintf("%d comment(s) unexpectedly missing from QMD: %s",
                                    length(comment_loss$unexpected),
                                    paste(head(comment_loss$unexpected, 5), collapse = ", ")))
      }

      result$details$comment_loss <- comment_loss
    } else {
      result$checks$comments_placed <- TRUE
      vh_check(verbose, TRUE,
               sprintf("Comment placement: all %d sidecar comments in QMD",
                       sidecar_comment_count))
      result$details$comment_loss <- list(
        expected = character(), unexpected = character(),
        by_pattern = list())
    }
  } else {
    result$checks$comments_placed <- TRUE
    vh_check(verbose, TRUE, "Comment placement: no sidecar comments to check")
  }

  # ── Generated content round-trip ──
  body <- xml2::xml_find_first(doc_xml, ".//w:body", ns)
  children <- xml2::xml_children(body)
  bookmark_ranges <- detect_docstyle_bookmarks(body, children, ns)

  if (length(bookmark_ranges) > 0) {
    # Check each bookmark has a corresponding div placeholder in QMD
    missing_divs <- character()
    for (rng in bookmark_ranges) {
      div_pattern <- sprintf("^:::\\s*%s",
        sub("^_docstyle_", "", gsub("_", "-", rng$name)))
      if (!grepl(div_pattern, qmd_body, perl = TRUE)) {
        missing_divs <- c(missing_divs, rng$name)
      }
    }

    generated_ok <- (length(missing_divs) == 0)
    result$checks$generated_roundtrip <- generated_ok
    vh_check(verbose, generated_ok,
             sprintf("Generated content: %d bookmark(s) in source, %d div(s) restored",
                     length(bookmark_ranges),
                     length(bookmark_ranges) - length(missing_divs)))
    if (!generated_ok) {
      result$errors <- c(result$errors,
        sprintf("Generated content not restored: %s",
                paste(missing_divs, collapse = ", ")))
    }
  } else {
    result$checks$generated_roundtrip <- TRUE
    vh_check(verbose, TRUE, "Generated content: no docstyle bookmarks in source")
  }

  result$details$docx_heading_texts <- if (docx_heading_count > 0) {
    docx_headings$text
  } else {
    character()
  }
  result$details$qmd_heading_texts <- qmd_heading_lines

  result
}


# ── Expected loss registry ───────────────────────────────────────────────────

# Registry of expected revision loss patterns
#
# Each function takes (doc_xml, ns) and returns a character vector of
# revision IDs (e.g., "rev_120") expected to be missing from the harvest.
expected_loss_patterns <- list(

  # Revisions inside paragraph properties (w:pPr) -- formatting-only tracked
  # changes (e.g., numbering, style, spacing changes). These have no text
  # content and are not emitted as QMD markers. Ordered before
  # revisions_empty_content because pPr is a more specific classification
  # (all pPr revisions are also empty, but "in pPr" is more informative).
  revisions_in_pPr = function(doc_xml, ns) {
    ppr_ins <- xml2::xml_find_all(doc_xml, "//w:pPr//w:ins", ns)
    ppr_del <- xml2::xml_find_all(doc_xml, "//w:pPr//w:del", ns)
    ids <- c(xml2::xml_attr(ppr_ins, "id"), xml2::xml_attr(ppr_del, "id"))
    ids <- ids[!is.na(ids) & ids != ""]
    paste0("rev_", ids)
  },

  # Revisions inside tables -- Pandoc doesn't preserve tracked changes in tables
  revisions_in_tables = function(doc_xml, ns) {
    tbl_ins <- xml2::xml_find_all(doc_xml, "//w:tbl//w:ins", ns)
    tbl_del <- xml2::xml_find_all(doc_xml, "//w:tbl//w:del", ns)
    ids <- c(xml2::xml_attr(tbl_ins, "id"), xml2::xml_attr(tbl_del, "id"))
    ids <- ids[!is.na(ids) & ids != ""]
    paste0("rev_", ids)
  },

  # Empty revisions -- formatting-only changes with no text content
  # (catches run-level empty revisions not already classified by revisions_in_pPr)
  revisions_empty_content = function(doc_xml, ns) {
    empty_ins <- xml2::xml_find_all(
      doc_xml, "//w:ins[not(.//w:t)]", ns)
    empty_del <- xml2::xml_find_all(
      doc_xml, "//w:del[not(.//w:delText)]", ns)
    ids <- c(xml2::xml_attr(empty_ins, "id"), xml2::xml_attr(empty_del, "id"))
    ids <- ids[!is.na(ids) & ids != ""]
    paste0("rev_", ids)
  },

  # Revisions inside docstyle bookmark ranges (generated content blocks)
  # These are expected to be missing because the harvest skips bookmarked content
  revisions_in_bookmarks = function(doc_xml, ns) {
    ids <- find_annotations_in_bookmarks(doc_xml, ns, type = "revisions")
    paste0("rev_", ids)
  },

  # Revisions inside ADDIN DOCSTYLE field code ranges (generated content blocks)
  # These are expected to be missing because field code ranges are replaced by
  # div placeholders during harvest
  revisions_in_field_codes = function(doc_xml, ns) {
    ids <- find_annotations_in_field_codes(doc_xml, ns, type = "revisions")
    paste0("rev_", ids)
  }
)


# Convenience wrappers for backward compatibility in tests
classify_revision_loss <- function(missing_ids, doc_xml, ns) {
  classify_loss(missing_ids, doc_xml, ns, expected_loss_patterns)
}
classify_comment_loss <- function(missing_ids, doc_xml, ns) {
  classify_loss(missing_ids, doc_xml, ns, expected_comment_loss_patterns)
}


# ── Expected comment loss registry ────────────────────────────────────────────

# Registry of expected comment loss patterns
#
# Each function takes (doc_xml, ns) and returns a character vector of
# comment IDs expected to be missing from the QMD body.
expected_comment_loss_patterns <- list(

  # Comments anchored inside tables -- convert_table_to_md doesn't place
  # comment markers, only extracts text content
  comments_in_tables = function(doc_xml, ns) {
    tbl_markers <- xml2::xml_find_all(
      doc_xml, "//w:tbl//w:commentRangeStart", ns)
    ids <- xml2::xml_attr(tbl_markers, "id")
    ids[!is.na(ids) & ids != ""]
  },

  # Comments on metadata-extracted paragraphs (Title, Subtitle, Date, etc.)
  # These paragraphs are consumed into YAML header, not emitted as body text,
  # so comment markers placed by extract_formatted_text are discarded.
  # Uses case-insensitive prefix matching to handle style name variants
  # (e.g., Title, Title1, TitleMain, AuthorName, AbstractText).
  comments_on_metadata = function(doc_xml, ns) {
    metadata_prefixes <- c("title", "subtitle", "date", "version",
                           "author", "abstract")
    body <- xml2::xml_find_first(doc_xml, "//w:body", ns)
    if (inherits(body, "xml_missing")) return(character())
    paras <- xml2::xml_find_all(body, ".//w:p", ns)
    ids <- character()
    for (p in paras) {
      style <- xml2::xml_text(
        xml2::xml_find_first(p, ".//w:pStyle/@w:val", ns))
      if (!is.na(style)) {
        style_lower <- tolower(style)
        if (any(startsWith(style_lower, metadata_prefixes))) {
          markers <- xml2::xml_find_all(p, ".//w:commentRangeStart", ns)
          cids <- xml2::xml_attr(markers, "id")
          cids <- cids[!is.na(cids) & cids != ""]
          ids <- c(ids, cids)
        }
      }
    }
    ids
  },

  # Comments inside docstyle bookmark ranges (generated content blocks)
  # These are expected to be missing because the harvest skips bookmarked content
  comments_in_bookmarks = function(doc_xml, ns) {
    find_annotations_in_bookmarks(doc_xml, ns, type = "comments")
  },

  # Comments inside ADDIN DOCSTYLE field code ranges (generated content blocks)
  # These are expected to be missing because field code ranges are replaced by
  # div placeholders during harvest
  comments_in_field_codes = function(doc_xml, ns) {
    find_annotations_in_field_codes(doc_xml, ns, type = "comments")
  },

  # Comments whose range start is a direct child of w:body (not inside a
  # paragraph) -- the harvest loop skips non-paragraph body children
  comments_at_body_level = function(doc_xml, ns) {
    body <- xml2::xml_find_first(doc_xml, "//w:body", ns)
    if (inherits(body, "xml_missing")) return(character())
    body_children <- xml2::xml_children(body)
    ids <- character()
    for (child in body_children) {
      if (xml2::xml_name(child) == "commentRangeStart") {
        cid <- xml2::xml_attr(child, "id")
        if (!is.na(cid)) ids <- c(ids, cid)
      }
    }
    ids
  }
)




#' Parse a DOCX file into its XML components
#'
#' Unzips and parses document.xml (and optionally comments.xml) once.
#' Returns the parsed XML, namespace, and temp directory (caller is
#' responsible for cleanup via the returned on_exit handle).
#'
#' @param docx_path Path to .docx file
#' @return List with doc_xml, ns, comments_xml (or NULL), temp_dir
#' @noRd
parse_docx_xml <- function(docx_path) {
  temp_dir <- tempfile("validate_docx_")
  dir.create(temp_dir)

  utils::unzip(docx_path, exdir = temp_dir)
  doc_path <- file.path(temp_dir, "word", "document.xml")
  if (!file.exists(doc_path)) stop("document.xml not found in DOCX")

  doc_xml <- xml2::read_xml(doc_path)
  ns <- xml2::xml_ns(doc_xml)

  comments_xml <- NULL
  comments_path <- file.path(temp_dir, "word", "comments.xml")
  if (file.exists(comments_path)) {
    comments_xml <- tryCatch(xml2::read_xml(comments_path), error = function(e) NULL)
  }

  list(doc_xml = doc_xml, ns = ns, comments_xml = comments_xml,
       temp_dir = temp_dir)
}


#' Extract plain text from a Word document
#'
#' Walks the document.xml tree, extracting paragraph text. For Zotero field
#' codes, emits the display text (between fldChar separate and end) rather
#' than the instrText JSON.
#'
#' @param docx_path Path to .docx file. Used to build a style properties
#'   lookup so custom heading styles (e.g. `CVH1` basedOn `Heading1`) are
#'   classified the same way the harvest path classifies them. If NULL,
#'   heading detection falls back to exact-match on native style IDs.
#' @param doc_xml Pre-parsed document.xml (optional, avoids re-parsing)
#' @param ns XML namespace (required if doc_xml provided)
#' @param props_lookup Optional pre-built style properties lookup from
#'   `build_style_props_lookup(docx_path)`. Pass-through lets callers reuse a
#'   lookup across validation layers.
#' @return A list with paragraphs (character vector), headings (data.frame
#'   with level and text), table_count, word_count, char_count
#' @noRd
extract_docx_plain_text <- function(docx_path = NULL, doc_xml = NULL,
                                     ns = NULL, props_lookup = NULL) {
  if (is.null(doc_xml)) {
    parsed <- parse_docx_xml(docx_path)
    on.exit(unlink(parsed$temp_dir, recursive = TRUE), add = TRUE)
    doc_xml <- parsed$doc_xml
    ns <- parsed$ns
  }

  # Build the style resolver once per call. build_style_props_lookup() has its
  # own error handler and returns list() on unreadable styles.xml; no outer
  # tryCatch needed. When docx_path is absent we can't read styles.xml, so
  # classification falls back to exact-match — flag that, otherwise a silent
  # source=0 heading count would reproduce bug #126 without a diagnostic.
  if (is.null(props_lookup)) {
    if (!is.null(docx_path) && file.exists(docx_path)) {
      props_lookup <- build_style_props_lookup(docx_path)
    } else {
      props_lookup <- list()
      message("[validate-harvest] No docx_path supplied; custom heading ",
              "styles will not be resolved (exact-match only).")
    }
  }

  body <- xml2::xml_find_first(doc_xml, ".//w:body", ns)
  children <- xml2::xml_children(body)

  # Exclude generated content marked by ADDIN DOCSTYLE field codes or bookmarks
  field_code_ranges <- detect_docstyle_field_codes(body, children, ns)
  bookmark_ranges <- detect_docstyle_bookmarks(body, children, ns)
  all_ranges <- c(field_code_ranges, bookmark_ranges)

  paragraphs <- character()
  headings <- data.frame(level = integer(), text = character(),
                         stringsAsFactors = FALSE)
  table_count <- 0L

  for (i in seq_along(children)) {
    child <- children[[i]]

    # Skip nodes inside generated content ranges (field codes or bookmarks)
    if (length(all_ranges) > 0) {
      if (!is.null(check_bookmark_range(i, all_ranges))) next
    }

    node_name <- xml2::xml_name(child)

    if (node_name == "tbl") {
      table_count <- table_count + 1L
      next
    }

    if (node_name != "p") next

    style <- xml2::xml_text(
      xml2::xml_find_first(child, ".//w:pStyle/@w:val", ns))
    if (is.na(style)) style <- "Normal"

    para_text <- extract_paragraph_display_text(child, ns)

    if (nchar(para_text) > 0) {
      paragraphs <- c(paragraphs, para_text)

      # Resolve to canonical style before classification (see @param props_lookup).
      resolved_style <- resolve_to_canonical(style, props_lookup)
      heading_level <- detect_heading_level(resolved_style)
      if (!is.na(heading_level)) {
        headings <- rbind(headings, data.frame(
          level = heading_level, text = para_text,
          stringsAsFactors = FALSE))
      }
    }
  }

  all_text <- paste(paragraphs, collapse = " ")
  words <- strsplit(trimws(all_text), "\\s+")[[1]]

  list(
    paragraphs = paragraphs,
    headings = headings,
    table_count = table_count,
    word_count = length(words),
    char_count = nchar(all_text)
  )
}


#' Extract display text from a paragraph, handling field codes
#'
#' Walks w:r runs. For Zotero field codes (fldChar begin...separate...end),
#' emits the display text between separate and end, skipping instrText JSON.
#'
#' @param p XML paragraph node
#' @param ns XML namespace
#' @return Character string of display text
#' @noRd
extract_paragraph_display_text <- function(p, ns) {
  children <- xml2::xml_children(p)
  text_parts <- character()

  in_field_code <- FALSE
  past_separate <- FALSE

  for (child in children) {
    node_name <- xml2::xml_name(child)

    if (node_name == "ins") {
      runs <- xml2::xml_find_all(child, ".//w:r", ns)
      for (run in runs) {
        t_nodes <- xml2::xml_find_all(run, ".//w:t", ns)
        for (t in t_nodes) {
          text_parts <- c(text_parts, xml2::xml_text(t))
        }
      }
      next
    }

    if (node_name == "del") next
    if (node_name != "r") next

    run <- child

    fld_char <- xml2::xml_find_first(run, ".//w:fldChar", ns)
    if (!inherits(fld_char, "xml_missing")) {
      fld_type <- xml2::xml_attr(fld_char, "fldCharType")
      if (!is.na(fld_type)) {
        if (fld_type == "begin") {
          in_field_code <- TRUE
          past_separate <- FALSE
          next
        } else if (fld_type == "separate") {
          past_separate <- TRUE
          next
        } else if (fld_type == "end") {
          in_field_code <- FALSE
          past_separate <- FALSE
          next
        }
      }
    }

    if (in_field_code && !past_separate) next

    t_nodes <- xml2::xml_find_all(run, ".//w:t", ns)
    for (t in t_nodes) {
      text_parts <- c(text_parts, xml2::xml_text(t))
    }
  }

  paste(text_parts, collapse = "")
}


#' Detect heading level from a Word paragraph style name
#' @param style Character. Word paragraph style name.
#' @return Integer heading level (1-9) or NA if not a heading
#' @noRd
detect_heading_level <- function(style) {
  if (grepl("^Heading(\\d+)$", style)) {
    return(as.integer(sub("^Heading(\\d+)$", "\\1", style)))
  }
  if (grepl("^heading (\\d+)$", style, ignore.case = TRUE)) {
    return(as.integer(sub("^heading (\\d+)$", "\\1", style,
                          ignore.case = TRUE)))
  }
  NA_integer_
}


#' Strip YAML front matter from QMD lines
#' @param lines Character vector of QMD file lines
#' @return Character string of body text (after YAML)
#' @noRd
strip_yaml_header <- function(lines) {
  if (length(lines) == 0) return("")

  if (lines[1] == "---") {
    end_idx <- which(lines[-1] == "---")[1]
    if (!is.na(end_idx)) {
      end_idx <- end_idx + 1
      lines <- lines[(end_idx + 1):length(lines)]
    }
  }

  paste(lines, collapse = "\n")
}
