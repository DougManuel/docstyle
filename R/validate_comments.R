#' Validate comments in rendered Word documents
#'
#' Comprehensive validation for comment round-trip workflows. Checks JSON structure,
#' XML generation, DOCX packaging, and ID synchronization between source and output.
#'
#' @param docx_path Path to the rendered DOCX file to validate
#' @param comments_json Path to comments.json sidecar file. If NULL, auto-detected
#'   from `_docstyle/` directory or same directory as DOCX.
#' @param qmd_path Optional path to source QMD for additional validation
#' @param verbose Logical. Print detailed validation output. Default TRUE.
#'
#' @return A list with validation results:
#' \describe{
#'   \item{valid}{Logical. TRUE if all critical checks passed}
#'   \item{summary}{List with counts: comments_in_json, comments_in_docx, orphaned, missing}
#'   \item{checks}{Named list of individual check results (TRUE/FALSE)}
#'   \item{issues}{List with errors (critical) and warnings (non-critical)}
#' }
#'
#' @examples
#' \dontrun{
#' # Basic validation
#' result <- validate_comments("output/document.docx")
#'
#' # With explicit paths
#' result <- validate_comments(
#'   docx_path = "output/document.docx",
#'   comments_json = "_docstyle/comments.json",
#'   qmd_path = "document.qmd"
#' )
#'
#' # Programmatic use (quiet mode)
#' result <- validate_comments("output/document.docx", verbose = FALSE)
#' if (!result$valid) {
#'   stop("Comment validation failed: ", paste(result$issues$errors, collapse = "; "))
#' }
#' }
#'
#' @export
validate_comments <- function(docx_path,
                              comments_json = NULL,
                              qmd_path = NULL,
                              verbose = TRUE) {

  # Initialize results structure
  result <- list(
    valid = TRUE,
    summary = list(
      comments_in_json = 0,
      comments_in_docx = 0,
      orphaned = 0,
      missing = 0
    ),
    checks = list(
      docx_exists = FALSE,
      json_exists = FALSE,
      json_valid = FALSE,
      comments_xml_exists = FALSE,
      content_types_ok = FALSE,
      rels_ok = FALSE,
      all_ids_matched = FALSE
    ),
    issues = list(
      errors = character(),
      warnings = character()
    ),
    details = list(
      json_ids = character(),
      docx_ids = character(),
      orphaned_ids = character(),
      missing_ids = character()
    )
  )

  # Helper for verbose output
  print_check <- function(pass, msg) {
    if (verbose) {
      symbol <- if (pass) "\u2713" else "\u2717"
      cat(sprintf("  %s %s\n", symbol, msg))
    }
  }

  print_info <- function(msg) {
    if (verbose) {
      cat(sprintf("  \u2139 %s\n", msg))
    }
  }

  print_warn <- function(msg) {
    if (verbose) {
      cat(sprintf("  \u26a0 %s\n", msg))
    }
  }

  print_section <- function(title) {
    if (verbose) {
      cat(sprintf("\n\u2500\u2500 %s \u2500\u2500\n", title))
    }
  }

  # ── Check 1: DOCX exists ──
  if (verbose) {
    cat("\n\u2550\u2550 Validating comments \u2550\u2550\n")
  }


  result$checks$docx_exists <- file.exists(docx_path)
  if (!result$checks$docx_exists) {
    result$valid <- FALSE
    result$issues$errors <- c(result$issues$errors, paste("DOCX not found:", docx_path))
    print_check(FALSE, paste("DOCX file:", docx_path))
    return(invisible(result))
  }
  print_check(TRUE, paste("DOCX file:", basename(docx_path)))

  # ── Auto-detect comments.json if not provided ──
  if (is.null(comments_json)) {
    docx_dir <- dirname(docx_path)
    candidates <- c(
      file.path(docx_dir, "_docstyle", "comments.json"),
      file.path(docx_dir, "comments.json"),
      file.path(dirname(docx_dir), "_docstyle", "comments.json")
    )
    for (candidate in candidates) {
      if (file.exists(candidate)) {
        comments_json <- candidate
        break
      }
    }
  }

  # ── Check 2: JSON exists ──
  if (is.null(comments_json) || !file.exists(comments_json)) {
    result$checks$json_exists <- FALSE
    print_info("No comments.json found - skipping comment validation")
    if (verbose) {
      cat("\n\u2500\u2500 Summary \u2500\u2500\n")
      cat("  No comments configured for this document\n\n")
    }
    return(invisible(result))
  }

  result$checks$json_exists <- TRUE
  print_check(TRUE, paste("Comments JSON:", basename(comments_json)))

  # ── Check 3: JSON is valid ──
  print_section("JSON structure")

  comments <- tryCatch({
    jsonlite::fromJSON(comments_json, simplifyVector = FALSE)
  }, error = function(e) {
    result$valid <<- FALSE
    result$issues$errors <<- c(result$issues$errors,
                                paste("Invalid JSON:", conditionMessage(e)))
    NULL
  })

  if (is.null(comments)) {
    result$checks$json_valid <- FALSE
    print_check(FALSE, "JSON parsing failed")
    return(invisible(result))
  }

  result$checks$json_valid <- TRUE
  result$summary$comments_in_json <- length(comments)
  result$details$json_ids <- names(comments)
  print_info(sprintf("Found %d comments in JSON", length(comments)))

  # Validate required fields
  missing_fields <- character()
  for (id in names(comments)) {
    comment <- comments[[id]]
    if (is.null(comment$id)) missing_fields <- c(missing_fields, paste(id, ": missing 'id'"))
    if (is.null(comment$author)) missing_fields <- c(missing_fields, paste(id, ": missing 'author'"))
    if (is.null(comment$content)) missing_fields <- c(missing_fields, paste(id, ": missing 'content'"))
  }

  if (length(missing_fields) > 0) {
    result$issues$warnings <- c(result$issues$warnings, missing_fields)
    print_warn(sprintf("%d comments have missing fields", length(missing_fields)))
  } else {
    print_check(TRUE, "All comments have required fields")
  }

  # ── Check 4: DOCX packaging ──
  print_section("DOCX packaging")

  temp_dir <- tempfile("validate_comments_")
  dir.create(temp_dir)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  utils::unzip(docx_path, exdir = temp_dir)

  # Check comments.xml exists
  comments_xml_path <- file.path(temp_dir, "word", "comments.xml")
  result$checks$comments_xml_exists <- file.exists(comments_xml_path)

  if (result$checks$comments_xml_exists) {
    print_check(TRUE, "word/comments.xml present")

    # Parse and count comments in DOCX
    tryCatch({
      comments_xml <- xml2::read_xml(comments_xml_path)
      ns <- xml2::xml_ns(comments_xml)
      comment_nodes <- xml2::xml_find_all(comments_xml, "//w:comment", ns)
      docx_comment_ids <- xml2::xml_attr(comment_nodes, "id")
      result$summary$comments_in_docx <- length(docx_comment_ids)
      result$details$docx_ids <- docx_comment_ids
      print_info(sprintf("%d comments in comments.xml", length(docx_comment_ids)))
    }, error = function(e) {
      result$issues$warnings <<- c(result$issues$warnings,
                                    paste("Could not parse comments.xml:", conditionMessage(e)))
    })
  } else {
    print_check(FALSE, "word/comments.xml missing")
  }

  # Check Content_Types.xml
  ct_path <- file.path(temp_dir, "[Content_Types].xml")
  if (file.exists(ct_path)) {
    ct_xml <- xml2::read_xml(ct_path)
    ct_override <- xml2::xml_find_first(
      ct_xml,
      "//ct:Override[@PartName='/word/comments.xml']",
      c(ct = "http://schemas.openxmlformats.org/package/2006/content-types")
    )
    result$checks$content_types_ok <- !inherits(ct_override, "xml_missing") && !is.na(ct_override)
    print_check(result$checks$content_types_ok, "[Content_Types].xml has comments override")
  }

  # Check document.xml.rels
  rels_path <- file.path(temp_dir, "word", "_rels", "document.xml.rels")
  if (file.exists(rels_path)) {
    rels_xml <- xml2::read_xml(rels_path)
    rels_entry <- xml2::xml_find_first(
      rels_xml,
      "//r:Relationship[@Type='http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments']",
      c(r = "http://schemas.openxmlformats.org/package/2006/relationships")
    )
    result$checks$rels_ok <- !inherits(rels_entry, "xml_missing") && !is.na(rels_entry)
    print_check(result$checks$rels_ok, "document.xml.rels has comments relationship")
  }

  # ── Check 5: ID synchronization ──
  print_section("ID synchronization")

  # Get IDs referenced in document.xml (commentRangeStart elements)
  doc_path <- file.path(temp_dir, "word", "document.xml")
  referenced_ids <- character()

  if (file.exists(doc_path)) {
    doc_xml <- xml2::read_xml(doc_path)
    ns <- xml2::xml_ns(doc_xml)
    range_starts <- xml2::xml_find_all(doc_xml, "//w:commentRangeStart", ns)
    referenced_ids <- unique(xml2::xml_attr(range_starts, "id"))
  }

  print_info(sprintf("Document references %d comment IDs", length(referenced_ids)))

  if (length(referenced_ids) > 0) {
    print_info(sprintf("Referenced IDs: %s", paste(referenced_ids, collapse = ", ")))
  }

  # Calculate orphaned and missing
  json_ids <- result$details$json_ids
  docx_ids <- result$details$docx_ids

  # Orphaned = in JSON but not referenced in document
  orphaned_ids <- setdiff(json_ids, referenced_ids)
  result$summary$orphaned <- length(orphaned_ids)
  result$details$orphaned_ids <- orphaned_ids

  # Missing = referenced in document but not in JSON
  missing_ids <- setdiff(referenced_ids, json_ids)
  result$summary$missing <- length(missing_ids)
  result$details$missing_ids <- missing_ids

  if (length(orphaned_ids) > 0) {
    result$issues$warnings <- c(result$issues$warnings,
                                 sprintf("%d comments in JSON not referenced in document", length(orphaned_ids)))
    print_warn(sprintf("%d orphaned comments (in JSON, not in document)", length(orphaned_ids)))
    if (verbose && length(orphaned_ids) <= 10) {
      cat(sprintf("    IDs: %s\n", paste(orphaned_ids, collapse = ", ")))
    }
  }

  if (length(missing_ids) > 0) {
    result$valid <- FALSE
    result$issues$errors <- c(result$issues$errors,
                               sprintf("%d comments referenced but not in JSON: %s",
                                       length(missing_ids), paste(missing_ids, collapse = ", ")))
    print_check(FALSE, sprintf("%d missing comments (in document, not in JSON)", length(missing_ids)))
    if (verbose) {
      cat(sprintf("    IDs: %s\n", paste(missing_ids, collapse = ", ")))
    }
  }

  # All IDs matched if no missing (orphaned is just a warning)
  result$checks$all_ids_matched <- length(missing_ids) == 0
  if (result$checks$all_ids_matched && length(orphaned_ids) == 0) {
    print_check(TRUE, "All comment IDs synchronized")
  }

  # ── Optional: QMD validation ──
  if (!is.null(qmd_path) && file.exists(qmd_path)) {
    print_section("QMD source validation")

    qmd_content <- readLines(qmd_path, warn = FALSE)
    qmd_text <- paste(qmd_content, collapse = "\n")

    # Find .comment spans with IDs
    # Pattern matches {#ID .comment} or {.comment id="ID"}
    pattern1 <- "\\{#([0-9]+)\\s+\\.comment\\}"
    pattern2 <- "\\{\\.comment\\s+id=[\"']([0-9]+)[\"']\\}"

    matches1 <- regmatches(qmd_text, gregexpr(pattern1, qmd_text, perl = TRUE))[[1]]
    matches2 <- regmatches(qmd_text, gregexpr(pattern2, qmd_text, perl = TRUE))[[1]]

    qmd_ids <- c(
      gsub(pattern1, "\\1", matches1, perl = TRUE),
      gsub(pattern2, "\\1", matches2, perl = TRUE)
    )
    qmd_ids <- unique(qmd_ids)

    print_info(sprintf("Found %d comment markers in QMD", length(qmd_ids)))

    # Check for IDs in QMD not in JSON
    qmd_not_in_json <- setdiff(qmd_ids, json_ids)
    if (length(qmd_not_in_json) > 0) {
      result$issues$errors <- c(result$issues$errors,
                                 sprintf("QMD references comment IDs not in JSON: %s",
                                         paste(qmd_not_in_json, collapse = ", ")))
      result$valid <- FALSE
      print_check(FALSE, sprintf("%d QMD comment IDs missing from JSON", length(qmd_not_in_json)))
    } else {
      print_check(TRUE, "All QMD comment IDs found in JSON")
    }
  }

  # ── Summary ──
  print_section("Summary")

  if (result$valid) {
    injected <- min(result$summary$comments_in_docx, length(referenced_ids))
    if (verbose) {
      cat(sprintf("  \u2713 Comments valid (%d injected", injected))
      if (result$summary$orphaned > 0) {
        cat(sprintf(", %d orphaned", result$summary$orphaned))
      }
      cat(")\n\n")
    }
  } else {
    if (verbose) {
      cat("  \u2717 Comment validation FAILED\n")
      if (length(result$issues$errors) > 0) {
        cat("  Errors:\n")
        for (err in result$issues$errors) {
          cat(sprintf("    - %s\n", err))
        }
      }
      cat("\n")
    }
  }

  invisible(result)
}


#' Quick comment validation during render
#'
#' Lightweight validation suitable for post-render hooks. Returns TRUE/FALSE
#' and prints warnings/errors to stderr.
#'
#' @param docx_path Path to rendered DOCX file
#' @param comments_json Path to comments.json file
#'
#' @return Logical. TRUE if comments are valid, FALSE otherwise.
#'
#' @examples
#' \dontrun{
#' # In post-render script
#' if (!check_comments("output/doc.docx", "_docstyle/comments.json")) {
#'   warning("Comment validation failed")
#' }
#' }
#'
#' @export
check_comments <- function(docx_path, comments_json) {
  result <- validate_comments(
    docx_path = docx_path,
    comments_json = comments_json,
    verbose = FALSE
  )

  if (!result$valid) {
    for (err in result$issues$errors) {
      message("[check_comments] ERROR: ", err)
    }
  }

  for (warn in result$issues$warnings) {
    message("[check_comments] WARNING: ", warn)
  }

  result$valid
}


#' Generate comment validation report
#'
#' Creates a detailed validation report in text, HTML, or JSON format.
#'
#' @param docx_path Path to rendered DOCX file
#' @param comments_json Path to comments.json (auto-detected if NULL)
#' @param qmd_path Optional path to source QMD
#' @param output_format Output format: "text", "html", or "json"
#' @param output_file Path to write report. If NULL, returns as string.
#'
#' @return Character string containing the report (invisibly if output_file specified)
#'
#' @examples
#' \dontrun{
#' # Print text report
#' cat(comment_report("output/document.docx"))
#'
#' # Save HTML report
#' comment_report("output/document.docx", output_format = "html",
#'                output_file = "comment-report.html")
#'
#' # Get JSON for programmatic use
#' report_json <- comment_report("output/document.docx", output_format = "json")
#' }
#'
#' @export
comment_report <- function(docx_path,
                           comments_json = NULL,
                           qmd_path = NULL,
                           output_format = "text",
                           output_file = NULL) {

  output_format <- match.arg(output_format, c("text", "html", "json"))

  # Run validation
  result <- validate_comments(
    docx_path = docx_path,
    comments_json = comments_json,
    qmd_path = qmd_path,
    verbose = FALSE
  )

  # Generate report based on format
  report <- switch(output_format,
    "json" = jsonlite::toJSON(result, pretty = TRUE, auto_unbox = TRUE),
    "html" = generate_html_report(result, docx_path),
    "text" = generate_text_report(result, docx_path)
  )

  if (!is.null(output_file)) {
    writeLines(report, output_file)
    message("Report written to: ", output_file)
    return(invisible(report))
  }

  report
}


#' Generate text report (internal)
#' @keywords internal
generate_text_report <- function(result, docx_path) {
  lines <- c(
    "Comment Validation Report",
    paste(rep("=", 50), collapse = ""),
    "",
    sprintf("Document: %s", basename(docx_path)),
    sprintf("Status: %s", if (result$valid) "PASSED" else "FAILED"),
    "",
    "Summary",
    paste(rep("-", 30), collapse = ""),
    sprintf("  Comments in JSON: %d", result$summary$comments_in_json),
    sprintf("  Comments in DOCX: %d", result$summary$comments_in_docx),
    sprintf("  Orphaned: %d", result$summary$orphaned),
    sprintf("  Missing: %d", result$summary$missing),
    "",
    "Checks",
    paste(rep("-", 30), collapse = "")
  )

  for (check_name in names(result$checks)) {
    status <- if (result$checks[[check_name]]) "[PASS]" else "[FAIL]"
    lines <- c(lines, sprintf("  %s %s", status, check_name))
  }

  if (length(result$issues$errors) > 0) {
    lines <- c(lines, "", "Errors", paste(rep("-", 30), collapse = ""))
    for (err in result$issues$errors) {
      lines <- c(lines, sprintf("  ! %s", err))
    }
  }

  if (length(result$issues$warnings) > 0) {
    lines <- c(lines, "", "Warnings", paste(rep("-", 30), collapse = ""))
    for (warn in result$issues$warnings) {
      lines <- c(lines, sprintf("  ~ %s", warn))
    }
  }

  if (length(result$details$orphaned_ids) > 0) {
    lines <- c(lines, "", "Orphaned Comment IDs",
               paste(rep("-", 30), collapse = ""),
               sprintf("  %s", paste(result$details$orphaned_ids, collapse = ", ")))
  }

  paste(lines, collapse = "\n")
}


#' Generate HTML report (internal)
#' @keywords internal
generate_html_report <- function(result, docx_path) {
  status_class <- if (result$valid) "passed" else "failed"
  status_text <- if (result$valid) "PASSED" else "FAILED"

  checks_html <- sapply(names(result$checks), function(name) {
    status <- if (result$checks[[name]]) "pass" else "fail"
    icon <- if (result$checks[[name]]) "&#x2713;" else "&#x2717;"
    sprintf('<tr class="%s"><td>%s</td><td>%s</td></tr>', status, icon, name)
  })

  errors_html <- if (length(result$issues$errors) > 0) {
    error_items <- sapply(result$issues$errors, function(e) sprintf("<li>%s</li>", e))
    sprintf('<div class="errors"><h3>Errors</h3><ul>%s</ul></div>',
            paste(error_items, collapse = ""))
  } else ""

  warnings_html <- if (length(result$issues$warnings) > 0) {
    warn_items <- sapply(result$issues$warnings, function(w) sprintf("<li>%s</li>", w))
    sprintf('<div class="warnings"><h3>Warnings</h3><ul>%s</ul></div>',
            paste(warn_items, collapse = ""))
  } else ""

  sprintf('<!DOCTYPE html>
<html>
<head>
<title>Comment Validation Report</title>
<style>
body { font-family: system-ui, sans-serif; max-width: 800px; margin: 2rem auto; padding: 1rem; }
h1 { border-bottom: 2px solid #333; padding-bottom: 0.5rem; }
.status { font-size: 1.2rem; padding: 0.5rem 1rem; border-radius: 4px; display: inline-block; }
.status.passed { background: #d4edda; color: #155724; }
.status.failed { background: #f8d7da; color: #721c24; }
table { border-collapse: collapse; width: 100%%; margin: 1rem 0; }
th, td { padding: 0.5rem; text-align: left; border-bottom: 1px solid #ddd; }
tr.pass td:first-child { color: #28a745; }
tr.fail td:first-child { color: #dc3545; }
.summary { display: grid; grid-template-columns: repeat(4, 1fr); gap: 1rem; margin: 1rem 0; }
.summary-item { background: #f8f9fa; padding: 1rem; border-radius: 4px; text-align: center; }
.summary-item .value { font-size: 2rem; font-weight: bold; }
.errors { background: #f8d7da; padding: 1rem; border-radius: 4px; margin: 1rem 0; }
.warnings { background: #fff3cd; padding: 1rem; border-radius: 4px; margin: 1rem 0; }
</style>
</head>
<body>
<h1>Comment Validation Report</h1>
<p><strong>Document:</strong> %s</p>
<p class="status %s">%s</p>

<h2>Summary</h2>
<div class="summary">
  <div class="summary-item"><div class="value">%d</div>In JSON</div>
  <div class="summary-item"><div class="value">%d</div>In DOCX</div>
  <div class="summary-item"><div class="value">%d</div>Orphaned</div>
  <div class="summary-item"><div class="value">%d</div>Missing</div>
</div>

%s
%s

<h2>Checks</h2>
<table>
<tr><th>Status</th><th>Check</th></tr>
%s
</table>

</body>
</html>',
    basename(docx_path),
    status_class,
    status_text,
    result$summary$comments_in_json,
    result$summary$comments_in_docx,
    result$summary$orphaned,
    result$summary$missing,
    errors_html,
    warnings_html,
    paste(checks_html, collapse = "\n")
  )
}


#' Validate comment IDs before injection (pre-render check)
#'
#' Checks that comment IDs in the QMD file match those in comments.json.
#' This catches ID mismatch errors before they result in corrupt DOCX files.
#'
#' The round-trip workflow is fragile because Word renumbers comment IDs when
#' the source document is edited. This function provides early warning when
#' the QMD markers and comments.json have diverged.
#'
#' @param qmd_path Path to the source .qmd file
#' @param comments_json Path to comments.json sidecar file. If NULL, auto-detected
#'   from `_docstyle/` directory.
#' @param strict If TRUE (default), return FALSE for any ID mismatch.
#'   If FALSE, only return FALSE when QMD has IDs not in JSON (missing comments).
#'
#' @return A list with:
#' \describe{
#'   \item{valid}{Logical. TRUE if IDs are synchronized}
#'   \item{qmd_ids}{Character vector of comment IDs found in QMD}
#'   \item{json_ids}{Character vector of comment IDs in comments.json}
#'   \item{missing}{IDs in QMD but not in JSON (will cause corrupt DOCX)}
#'   \item{orphaned}{IDs in JSON but not in QMD (harmless but wasteful)}
#'   \item{message}{Human-readable summary of the validation result}
#' }
#'
#' @examples
#' \dontrun{
#' # Check before rendering
#' result <- validate_comment_ids("document.qmd", "_docstyle/comments.json")
#' if (!result$valid) {
#'   stop(result$message)
#' }
#'
#' # Use in pre-render hook
#' result <- validate_comment_ids("document.qmd")
#' if (length(result$missing) > 0) {
#'   message("Run sync_comment_ids() to fix: ", paste(result$missing, collapse = ", "))
#' }
#' }
#'
#' @keywords internal
#' @export
validate_comment_ids <- function(qmd_path, comments_json = NULL, strict = TRUE) {

  result <- list(
    valid = TRUE,
    qmd_ids = character(),
    json_ids = character(),
    missing = character(),
    orphaned = character(),
    message = ""
  )

  # Check QMD exists

  if (!file.exists(qmd_path)) {
    result$valid <- FALSE
    result$message <- paste("QMD file not found:", qmd_path)
    return(result)
  }

  # Auto-detect comments.json
  if (is.null(comments_json)) {
    qmd_dir <- dirname(qmd_path)
    candidates <- c(
      file.path(qmd_dir, "_docstyle", "comments.json"),
      file.path(qmd_dir, "comments.json")
    )
    for (candidate in candidates) {
      if (file.exists(candidate)) {
        comments_json <- candidate
        break
      }
    }
  }

  # No comments.json = nothing to validate

if (is.null(comments_json) || !file.exists(comments_json)) {
    result$message <- "No comments.json found - skipping validation"
    return(result)
  }

  # Extract comment IDs from QMD
  qmd_content <- readLines(qmd_path, warn = FALSE)
  qmd_text <- paste(qmd_content, collapse = "\n")

  # Match HTML comment markers: <!-- comment:start id="123" --> or <!-- comment id="123" -->
  start_pattern <- 'comment:start\\s+id="([^"]+)"'
  point_pattern <- 'comment\\s+id="([^"]+)"'

  start_matches <- regmatches(qmd_text, gregexpr(start_pattern, qmd_text, perl = TRUE))[[1]]
  point_matches <- regmatches(qmd_text, gregexpr(point_pattern, qmd_text, perl = TRUE))[[1]]

  # Filter out the point matches that are actually start matches
  point_matches <- point_matches[!grepl("comment:start", point_matches)]

  start_ids <- gsub(start_pattern, "\\1", start_matches, perl = TRUE)
  point_ids <- gsub(point_pattern, "\\1", point_matches, perl = TRUE)

  result$qmd_ids <- unique(c(start_ids, point_ids))

  # Read comments.json
  tryCatch({
    comments <- jsonlite::fromJSON(comments_json, simplifyVector = FALSE)
    result$json_ids <- names(comments)
  }, error = function(e) {
    result$valid <<- FALSE
    result$message <<- paste("Failed to parse comments.json:", conditionMessage(e))
  })

  if (!result$valid) {
    return(result)
  }

  # Calculate mismatches
  result$missing <- setdiff(result$qmd_ids, result$json_ids)
  result$orphaned <- setdiff(result$json_ids, result$qmd_ids)

  # Determine validity
  if (length(result$missing) > 0) {
    # Critical: QMD references comments not in JSON -> corrupt DOCX
    result$valid <- FALSE
    result$message <- sprintf(
      "CRITICAL: QMD has %d comment ID(s) not in comments.json: %s\n" %+%
      "This will produce a corrupt DOCX. Run sync_comment_ids() to fix.",
      length(result$missing),
      paste(result$missing, collapse = ", ")
    )
  } else if (strict && length(result$orphaned) > 0) {
    # Strict mode: orphaned comments are also invalid
    result$valid <- FALSE
    result$message <- sprintf(
      "WARNING: comments.json has %d comment ID(s) not used in QMD: %s\n" %+%
      "These comments will not appear in the output.",
      length(result$orphaned),
      paste(result$orphaned, collapse = ", ")
    )
  } else if (length(result$orphaned) > 0) {
    # Non-strict: orphaned is a warning but valid
    result$message <- sprintf(
      "OK with warnings: %d comment(s) in JSON not used in QMD",
      length(result$orphaned)
    )
  } else {
    result$message <- sprintf(
      "OK: %d comment ID(s) synchronized",
      length(result$qmd_ids)
    )
  }

  result
}


#' String concatenation operator
#' @noRd
`%+%` <- function(a, b) paste0(a, b)


#' Synchronize comment IDs from source DOCX to QMD
#'
#' Updates comment markers in a QMD file to match the IDs in a source DOCX.
#' This is needed when the source DOCX has been edited in Word and Word has
#' renumbered the comment IDs.
#'
#' The function uses content-based matching to find corresponding comments:
#' 1. Extracts comments from source DOCX with their new IDs
#' 2. Reads existing comments.json for old content
#' 3. Matches comments by content similarity
#' 4. Updates QMD markers with new IDs
#' 5. Regenerates comments.json with new IDs
#'
#' @param qmd_path Path to the .qmd file to update
#' @param source_docx Path to the source .docx file with current comment IDs
#' @param comments_json Path to comments.json (default: auto-detect from _docstyle/)
#' @param backup If TRUE (default), creates a backup of the QMD before modifying
#' @param dry_run If TRUE, report what would change without modifying files
#'
#' @return A list with:
#' \describe{
#'   \item{success}{Logical. TRUE if sync completed successfully}
#'   \item{changes}{Data frame of ID mappings (old_id, new_id, matched_by)}
#'   \item{unmapped_qmd}{IDs in QMD that couldn't be mapped to source DOCX}
#'   \item{unmapped_docx}{IDs in source DOCX not referenced in QMD}
#'   \item{message}{Human-readable summary}
#' }
#'
#' @examples
#' \dontrun{
#' # Sync after Word editing
#' result <- sync_comment_ids(
#'   qmd_path = "document.qmd",
#'   source_docx = "source/document.docx"
#' )
#'
#' # Preview changes without modifying
#' result <- sync_comment_ids(
#'   qmd_path = "document.qmd",
#'   source_docx = "source/document.docx",
#'   dry_run = TRUE
#' )
#' print(result$changes)
#' }
#'
#' @keywords internal
#' @export
sync_comment_ids <- function(qmd_path,
                              source_docx,
                              comments_json = NULL,
                              backup = TRUE,
                              dry_run = FALSE) {

  result <- list(
    success = FALSE,
    changes = data.frame(
      old_id = character(),
      new_id = character(),
      matched_by = character(),
      stringsAsFactors = FALSE
    ),
    unmapped_qmd = character(),
    unmapped_docx = character(),
    message = ""
  )

  # Validate inputs
  if (!file.exists(qmd_path)) {
    result$message <- paste("QMD file not found:", qmd_path)
    return(result)
  }

  if (!file.exists(source_docx)) {
    result$message <- paste("Source DOCX not found:", source_docx)
    return(result)
  }

  # Auto-detect comments.json
  if (is.null(comments_json)) {
    qmd_dir <- dirname(qmd_path)
    candidates <- c(
      file.path(qmd_dir, "_docstyle", "comments.json"),
      file.path(qmd_dir, "comments.json")
    )
    for (candidate in candidates) {
      if (file.exists(candidate)) {
        comments_json <- candidate
        break
      }
    }
  }

  # Extract new comments from source DOCX
  new_comments <- extract_comments(source_docx)
  if (length(new_comments) == 0) {
    result$message <- "No comments found in source DOCX"
    return(result)
  }

  # Read old comments.json (if exists) for content matching
  old_comments <- list()
  if (!is.null(comments_json) && file.exists(comments_json)) {
    tryCatch({
      old_comments <- jsonlite::fromJSON(comments_json, simplifyVector = FALSE)
    }, error = function(e) {
      message("Warning: Could not read old comments.json: ", conditionMessage(e))
    })
  }

  # Read QMD content
  qmd_content <- readLines(qmd_path, warn = FALSE)
  qmd_text <- paste(qmd_content, collapse = "\n")

  # Extract old IDs from QMD
  start_pattern <- 'comment:start\\s+id="([^"]+)"'
  end_pattern <- 'comment:end\\s+id="([^"]+)"'
  point_pattern <- '<!--\\s*comment\\s+id="([^"]+)"\\s*-->'

  old_ids_in_qmd <- unique(c(
    gsub(start_pattern, "\\1", regmatches(qmd_text, gregexpr(start_pattern, qmd_text, perl = TRUE))[[1]], perl = TRUE),
    gsub(end_pattern, "\\1", regmatches(qmd_text, gregexpr(end_pattern, qmd_text, perl = TRUE))[[1]], perl = TRUE),
    gsub(point_pattern, "\\1", regmatches(qmd_text, gregexpr(point_pattern, qmd_text, perl = TRUE))[[1]], perl = TRUE)
  ))

  # Build mapping: old ID -> new ID using content matching
  id_mapping <- list()
  matched_new_ids <- character()

  for (old_id in old_ids_in_qmd) {
    # Try to find matching comment in new DOCX by content
    old_content <- ""
    if (old_id %in% names(old_comments)) {
      old_content <- old_comments[[old_id]]$content
    }

    best_match <- NULL
    best_score <- 0
    matched_by <- "none"

    for (new_id in names(new_comments)) {
      if (new_id %in% matched_new_ids) next  # Already matched

      new_content <- new_comments[[new_id]]$content

      # Calculate similarity score
      score <- content_similarity(old_content, new_content)

      if (score > best_score && score > 0.7) {  # Threshold: 70% similarity
        best_score <- score
        best_match <- new_id
        matched_by <- sprintf("content (%.0f%%)", score * 100)
      }
    }

    if (!is.null(best_match)) {
      id_mapping[[old_id]] <- best_match
      matched_new_ids <- c(matched_new_ids, best_match)
      result$changes <- rbind(result$changes, data.frame(
        old_id = old_id,
        new_id = best_match,
        matched_by = matched_by,
        stringsAsFactors = FALSE
      ))
    } else {
      result$unmapped_qmd <- c(result$unmapped_qmd, old_id)
    }
  }

  # Find new DOCX comments not matched to QMD
  result$unmapped_docx <- setdiff(names(new_comments), matched_new_ids)

  # Check if we have unmapped QMD IDs (problematic)
  if (length(result$unmapped_qmd) > 0) {
    result$message <- sprintf(
      "Could not match %d QMD comment(s) to source DOCX: %s\n" %+%
      "These comments may have been deleted from the source document.",
      length(result$unmapped_qmd),
      paste(result$unmapped_qmd, collapse = ", ")
    )
    # Still proceed with partial sync if there are mappings
    if (nrow(result$changes) == 0) {
      return(result)
    }
  }

  # Dry run: report changes without modifying
  if (dry_run) {
    result$success <- TRUE
    n_changes <- nrow(result$changes)
    result$message <- sprintf(
      "DRY RUN: Would update %d comment ID(s) in QMD and regenerate comments.json\n" %+%
      "Run with dry_run=FALSE to apply changes.",
      n_changes
    )
    return(result)
  }

  # Create backup if requested
  if (backup) {
    backup_path <- paste0(qmd_path, ".bak")
    file.copy(qmd_path, backup_path, overwrite = TRUE)
    message("Backup created: ", backup_path)
  }

  # Apply ID replacements to QMD
  updated_text <- qmd_text
  for (old_id in names(id_mapping)) {
    new_id <- id_mapping[[old_id]]

    # Replace in start markers
    updated_text <- gsub(
      sprintf('comment:start\\s+id="%s"', old_id),
      sprintf('comment:start id="%s"', new_id),
      updated_text,
      perl = TRUE
    )

    # Replace in end markers
    updated_text <- gsub(
      sprintf('comment:end\\s+id="%s"', old_id),
      sprintf('comment:end id="%s"', new_id),
      updated_text,
      perl = TRUE
    )

    # Replace in point markers
    updated_text <- gsub(
      sprintf('<!--\\s*comment\\s+id="%s"\\s*-->', old_id),
      sprintf('<!-- comment id="%s" -->', new_id),
      updated_text,
      perl = TRUE
    )
  }

  # Write updated QMD
  writeLines(strsplit(updated_text, "\n")[[1]], qmd_path)
  message("Updated QMD: ", qmd_path)

  # Regenerate comments.json with new IDs (filtered to used comments)
  if (!is.null(comments_json)) {
    used_new_ids <- unlist(id_mapping)
    used_comments <- new_comments[names(new_comments) %in% used_new_ids]

    # Also include any new comments in DOCX that weren't in QMD
    # (user may have added new comments in Word)
    for (new_id in result$unmapped_docx) {
      # Only add if there's content (not a deleted comment)
      if (!is.null(new_comments[[new_id]]$content) &&
          nchar(new_comments[[new_id]]$content) > 0) {
        used_comments[[new_id]] <- new_comments[[new_id]]
        message("Note: New comment ID ", new_id, " found in DOCX (not in QMD)")
      }
    }

    write_comments_json(used_comments, comments_json)
    message("Regenerated comments.json: ", comments_json)
  }

  result$success <- TRUE
  result$message <- sprintf(
    "Successfully synced %d comment ID(s)",
    nrow(result$changes)
  )

  result
}


#' Calculate content similarity between two strings
#'
#' Uses Jaccard similarity on word tokens for fuzzy matching.
#'
#' @param a First string
#' @param b Second string
#' @return Numeric similarity score between 0 and 1
#' @noRd
content_similarity <- function(a, b) {
  if (is.null(a) || is.null(b)) return(0)
  if (nchar(a) == 0 || nchar(b) == 0) return(0)

  # Normalize: lowercase, remove punctuation, split into words
  normalize <- function(s) {
    s <- tolower(s)
    s <- gsub("[^a-z0-9\\s]", " ", s)
    s <- gsub("\\s+", " ", trimws(s))
    unique(strsplit(s, " ")[[1]])
  }

  words_a <- normalize(a)
  words_b <- normalize(b)

  if (length(words_a) == 0 || length(words_b) == 0) return(0)

  # Jaccard similarity: intersection / union
  intersection <- length(intersect(words_a, words_b))
  union <- length(union(words_a, words_b))

  if (union == 0) return(0)
  intersection / union
}
