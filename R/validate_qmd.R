#' Validate QMD markup before rendering
#'
#' Checks comment markers, revision spans, and other docstyle-specific markup
#' in a QMD file before rendering. Catches issues that would cause Word
#' "unreadable content" errors.
#'
#' @param qmd_path Path to the QMD file to validate
#' @param comments_json Optional path to comments.json. If provided, validates
#'   that comment IDs in the QMD have corresponding entries in the JSON.
#' @param verbose Logical. Print detailed validation output. Default TRUE.
#'
#' @return A list with validation results:
#' \describe{
#'   \item{valid}{Logical. TRUE if all critical checks passed}
#'   \item{issues}{List with errors (critical) and warnings (non-critical)}
#'   \item{comments}{List of comment marker details}
#'   \item{revisions}{List of revision span details}
#' }
#'
#' @examples
#' \dontrun{
#' # Basic validation
#' result <- validate_qmd("document.qmd")
#'
#' # With comments.json validation
#' result <- validate_qmd("document.qmd", "_docstyle/comments.json")
#'
#' # Programmatic use
#' result <- validate_qmd("document.qmd", verbose = FALSE)
#' if (!result$valid) {
#'   stop("QMD validation failed")
#' }
#' }
#'
#' @export
validate_qmd <- function(qmd_path, comments_json = NULL, verbose = TRUE) {

  if (!file.exists(qmd_path)) {
    stop("QMD file not found: ", qmd_path)
  }

  # Read the QMD content line-by-line (lines needed for fence check) and collapsed
  lines   <- readLines(qmd_path, warn = FALSE)
  content <- paste(lines, collapse = "\n")

  # Initialize results
  result <- list(
    valid = TRUE,
    issues = list(
      errors = character(),
      warnings = character()
    ),
    comments = list(
      start_markers = character(),
      end_markers = character(),
      point_markers = character(),
      deprecated_spans = character(),
      orphan_starts = character(),
      orphan_ends = character(),
      all_ids = character()
    ),
    revisions = list(
      insertions = character(),
      deletions = character()
    )
  )

  print_section <- function(title) {
    if (verbose) cat(sprintf("\n-- %s --\n", title))
  }

  print_check <- function(pass, msg) {
    if (verbose) {
      symbol <- if (pass) "\u2713" else "\u2717"
      cat(sprintf("  %s %s\n", symbol, msg))
    }
  }

  print_warn <- function(msg) {
    if (verbose) cat(sprintf("  ! %s\n", msg))
  }

  # ============================================================================
  # 1. Check comment markers
  # ============================================================================
  print_section("Comment Markers")

  # Find range start markers: <!-- comment:start id="X" -->
  start_pattern <- '<!--\\s*comment:start\\s+id="([^"]+)"\\s*-->'
  start_matches <- gregexpr(start_pattern, content, perl = TRUE)
  start_ids <- character()
  if (start_matches[[1]][1] != -1) {
    starts <- regmatches(content, start_matches)[[1]]
    start_ids <- gsub(start_pattern, "\\1", starts, perl = TRUE)
  }
  result$comments$start_markers <- start_ids

  # Find range end markers: <!-- comment:end id="X" -->
  end_pattern <- '<!--\\s*comment:end\\s+id="([^"]+)"\\s*-->'
  end_matches <- gregexpr(end_pattern, content, perl = TRUE)
  end_ids <- character()
  if (end_matches[[1]][1] != -1) {
    ends <- regmatches(content, end_matches)[[1]]
    end_ids <- gsub(end_pattern, "\\1", ends, perl = TRUE)
  }
  result$comments$end_markers <- end_ids

  # Find point comment markers: <!-- comment id="X" -->
  point_pattern <- '<!--\\s*comment\\s+id="([^"]+)"\\s*-->'
  point_matches <- gregexpr(point_pattern, content, perl = TRUE)
  point_ids <- character()
  if (point_matches[[1]][1] != -1) {
    points <- regmatches(content, point_matches)[[1]]
    point_ids <- gsub(point_pattern, "\\1", points, perl = TRUE)
  }
  result$comments$point_markers <- point_ids

  # Find deprecated span-based comments: [text]{.comment id="X"} or {#X .comment}
  # These are no longer supported and should be converted
  span_pattern1 <- '\\{[^}]*\\.comment[^}]*id="([^"]+)"[^}]*\\}'
  span_pattern2 <- '\\{#([^\\s}]+)\\s+\\.comment[^}]*\\}'
  span_pattern3 <- '\\{#([^\\s}]+)[^}]*\\.comment[^}]*\\}'

  deprecated_ids <- character()
  for (pattern in c(span_pattern1, span_pattern2, span_pattern3)) {
    span_matches <- gregexpr(pattern, content, perl = TRUE)
    if (span_matches[[1]][1] != -1) {
      spans <- regmatches(content, span_matches)[[1]]
      ids <- gsub(pattern, "\\1", spans, perl = TRUE)
      deprecated_ids <- c(deprecated_ids, ids)
    }
  }
  deprecated_ids <- unique(deprecated_ids)
  result$comments$deprecated_spans <- deprecated_ids

  # All comment IDs (excluding deprecated)
  all_comment_ids <- unique(c(start_ids, end_ids, point_ids))
  result$comments$all_ids <- all_comment_ids

  # Check for orphaned range markers
  orphan_starts <- setdiff(start_ids, end_ids)
  orphan_ends <- setdiff(end_ids, start_ids)
  result$comments$orphan_starts <- orphan_starts
  result$comments$orphan_ends <- orphan_ends

  # Report findings
  total_comments <- length(start_ids) + length(point_ids)
  if (total_comments == 0 && length(deprecated_ids) == 0) {
    print_check(TRUE, "No comment markers found (OK)")
  } else {
    if (length(start_ids) > 0) {
      print_check(TRUE, sprintf("Found %d range comment(s)", length(start_ids)))
    }
    if (length(point_ids) > 0) {
      print_check(TRUE, sprintf("Found %d point comment(s)", length(point_ids)))
    }

    # Warn about deprecated span syntax
    if (length(deprecated_ids) > 0) {
      msg <- sprintf("Deprecated span-based comments found: %s. Convert to HTML format.",
                     paste(deprecated_ids, collapse = ", "))
      result$issues$errors <- c(result$issues$errors, msg)
      result$valid <- FALSE
      print_check(FALSE, msg)
    }

    # Check for orphan start markers (warning - will be auto-closed)
    if (length(orphan_starts) > 0) {
      msg <- sprintf("Orphan start markers (no matching end): %s - will be auto-closed",
                     paste(orphan_starts, collapse = ", "))
      print_warn(msg)
      result$issues$warnings <- c(result$issues$warnings, msg)
    } else if (length(start_ids) > 0) {
      print_check(TRUE, "All range comments properly closed")
    }

    # Orphan end markers are errors
    if (length(orphan_ends) > 0) {
      msg <- sprintf("Orphan end markers (no matching start): %s",
                     paste(orphan_ends, collapse = ", "))
      result$issues$errors <- c(result$issues$errors, msg)
      result$valid <- FALSE
      print_check(FALSE, msg)
    }

    # Check for duplicate IDs
    all_ids_with_dups <- c(start_ids, point_ids)
    if (length(all_ids_with_dups) != length(unique(all_ids_with_dups))) {
      dup_ids <- all_ids_with_dups[duplicated(all_ids_with_dups)]
      msg <- sprintf("Duplicate comment IDs: %s", paste(unique(dup_ids), collapse = ", "))
      result$issues$errors <- c(result$issues$errors, msg)
      result$valid <- FALSE
      print_check(FALSE, msg)
    }
  }

  # ============================================================================
  # 2. Validate against comments.json if provided
  # ============================================================================
  if (!is.null(comments_json)) {
    print_section("Comments JSON Validation")

    if (!file.exists(comments_json)) {
      msg <- sprintf("comments.json not found: %s", comments_json)
      result$issues$warnings <- c(result$issues$warnings, msg)
      print_warn(msg)
    } else {
      json_content <- tryCatch({
        jsonlite::fromJSON(comments_json, simplifyVector = FALSE)
      }, error = function(e) {
        msg <- sprintf("Failed to parse comments.json: %s", e$message)
        result$issues$errors <<- c(result$issues$errors, msg)
        result$valid <<- FALSE
        NULL
      })

      if (!is.null(json_content)) {
        json_ids <- names(json_content)
        print_check(TRUE, sprintf("comments.json has %d entries", length(json_ids)))

        # Check for IDs in QMD that aren't in JSON
        missing_in_json <- setdiff(all_comment_ids, json_ids)
        if (length(missing_in_json) > 0) {
          msg <- sprintf("Comment IDs in QMD not in comments.json: %s",
                         paste(missing_in_json, collapse = ", "))
          result$issues$errors <- c(result$issues$errors, msg)
          result$valid <- FALSE
          print_check(FALSE, msg)
        } else if (length(all_comment_ids) > 0) {
          print_check(TRUE, "All QMD comment IDs found in comments.json")
        }

        # Check for IDs in JSON that aren't in QMD (warning only)
        unused_in_json <- setdiff(json_ids, all_comment_ids)
        if (length(unused_in_json) > 0) {
          msg <- sprintf("Unused comments in comments.json: %d entries not referenced in QMD",
                         length(unused_in_json))
          result$issues$warnings <- c(result$issues$warnings, msg)
          print_warn(msg)
        }
      }
    }
  }

  # ============================================================================
  # 3. Check revision spans
  # ============================================================================
  print_section("Revision Markup")

  # Find insertions: [text]{.ins id="X"}
  ins_pattern <- '\\[([^\\]]+)\\]\\{[^}]*\\.ins[^}]*id="([^"]+)"[^}]*\\}'
  ins_matches <- gregexpr(ins_pattern, content, perl = TRUE)
  ins_ids <- character()
  if (ins_matches[[1]][1] != -1) {
    insertions <- regmatches(content, ins_matches)[[1]]
    ins_ids <- gsub(ins_pattern, "\\2", insertions, perl = TRUE)
  }
  result$revisions$insertions <- ins_ids

  # Find deletions: [~~text~~]{.del id="X"}
  del_pattern <- '\\[~~([^~]+)~~\\]\\{[^}]*\\.del[^}]*id="([^"]+)"[^}]*\\}'
  del_matches <- gregexpr(del_pattern, content, perl = TRUE)
  del_ids <- character()
  if (del_matches[[1]][1] != -1) {
    deletions <- regmatches(content, del_matches)[[1]]
    del_ids <- gsub(del_pattern, "\\2", deletions, perl = TRUE)
  }
  result$revisions$deletions <- del_ids

  if (length(ins_ids) == 0 && length(del_ids) == 0) {
    print_check(TRUE, "No revision markup found (OK)")
  } else {
    print_check(TRUE, sprintf("Found %d insertions", length(ins_ids)))
    print_check(TRUE, sprintf("Found %d deletions", length(del_ids)))

    # Check for duplicate revision IDs
    all_rev_ids <- c(ins_ids, del_ids)
    if (length(all_rev_ids) != length(unique(all_rev_ids))) {
      dup_ids <- all_rev_ids[duplicated(all_rev_ids)]
      msg <- sprintf("Duplicate revision IDs: %s", paste(dup_ids, collapse = ", "))
      result$issues$warnings <- c(result$issues$warnings, msg)
      print_warn(msg)
    }
  }

  # ============================================================================
  # 4. Check for malformed markup patterns
  # ============================================================================
  print_section("Markup Syntax")

  # Check for unclosed HTML comments
  open_comments <- gregexpr("<!--", content)[[1]]
  close_comments <- gregexpr("-->", content)[[1]]
  n_open <- if (open_comments[1] == -1) 0 else length(open_comments)
  n_close <- if (close_comments[1] == -1) 0 else length(close_comments)

  if (n_open != n_close) {
    msg <- sprintf("Mismatched HTML comments: %d open, %d close", n_open, n_close)
    result$issues$errors <- c(result$issues$errors, msg)
    result$valid <- FALSE
    print_check(FALSE, msg)
  } else {
    print_check(TRUE, sprintf("HTML comments balanced (%d pairs)", n_open))
  }

  # Check for broken span attributes (common typos)
  broken_patterns <- list(
    'id= "' = 'Space after = in id attribute',
    'id ="' = 'Space before = in id attribute',
    '\\.ins[^}]*[^"]id' = 'Missing quotes around id value in .ins',
    '\\.del[^}]*[^"]id' = 'Missing quotes around id value in .del'
  )

  for (pattern in names(broken_patterns)) {
    if (grepl(pattern, content, perl = TRUE)) {
      msg <- broken_patterns[[pattern]]
      result$issues$warnings <- c(result$issues$warnings, msg)
      print_warn(msg)
    }
  }

  # ============================================================================
  # 5. Check div fence balance (all :::...:::: blocks)
  # ============================================================================
  print_section("Section Fences")

  fence_result <- check_section_fences(lines)
  if (length(fence_result$errors) == 0) {
    print_check(TRUE, sprintf("Div fences balanced (%d opened, %d closed)",
                              fence_result$opened, fence_result$closed))
  } else {
    for (msg in fence_result$errors) {
      result$issues$errors <- c(result$issues$errors, msg)
      result$valid <- FALSE
      print_check(FALSE, msg)
    }
  }

  # Deferred: "no syntax issues" depends on fence check results
  if (length(result$issues$errors) == 0 && length(result$issues$warnings) == 0) {
    print_check(TRUE, "No syntax issues detected")
  }

  # ============================================================================
  # Summary
  # ============================================================================
  print_section("Summary")

  n_errors <- length(result$issues$errors)
  n_warnings <- length(result$issues$warnings)

  if (result$valid) {
    if (verbose) cat("  \u2713 QMD validation PASSED\n")
  } else {
    if (verbose) cat("  \u2717 QMD validation FAILED\n")
  }

  if (verbose) {
    cat(sprintf("  Errors: %d | Warnings: %d\n", n_errors, n_warnings))
  }

  invisible(result)
}


#' Quick validation check for pre-render hook
#'
#' Returns TRUE/FALSE for use in pre-render scripts. Fails fast on first error.
#'
#' @param qmd_path Path to QMD file
#' @param comments_json Optional path to comments.json
#' @return Logical TRUE if valid, FALSE if errors found
#' @export
validate_qmd_quick <- function(qmd_path, comments_json = NULL) {
  result <- validate_qmd(qmd_path, comments_json, verbose = FALSE)
  result$valid
}


#' Check div fence balance in QMD lines
#'
#' Stack-based algorithm: push openers, pop closers, report unmatched.
#' Skips lines inside fenced code blocks (triple backtick or tilde fences) to
#' avoid false positives from code examples.
#'
#' @param lines Character vector of QMD lines (from readLines)
#' @return List with `errors` (character), `opened` (integer), `closed` (integer)
#' @keywords internal
check_section_fences <- function(lines) {
  errors         <- character()
  stack          <- list()   # each entry: list(line = i, n = colon_count, attr = "attr string")
  code_fence_chr <- NULL     # delimiter character of the open code fence ("`" or "~")
  code_fence_len <- 0L       # minimum width of the opening code fence
  opened         <- 0L
  closed         <- 0L

  for (i in seq_along(lines)) {
    ln <- lines[[i]]

    # Detect code fence open/close: 3+ backticks or 3+ tildes at line start.
    # The closing fence must use the same character with >= the same width.
    code_m <- regmatches(ln, regexpr("^\\s*([`~]{3,})", ln, perl = TRUE))
    if (length(code_m) == 1L && nchar(code_m) > 0L) {
      chr <- substr(trimws(code_m, "left"), 1L, 1L)
      len <- nchar(regmatches(ln, regexpr("[`~]+", ln)))
      if (is.null(code_fence_chr)) {
        code_fence_chr <- chr
        code_fence_len <- len
      } else if (chr == code_fence_chr && len >= code_fence_len) {
        code_fence_chr <- NULL
        code_fence_len <- 0L
      }
      next
    }
    if (!is.null(code_fence_chr)) next

    # Opener: 3+ colons followed by attribute block or bare class name
    # e.g. ":::: {.section-body}" or "::: section-body"
    opener_m <- regmatches(ln, regexpr("^(:{3,})\\s*(\\{[^}]*\\}|[A-Za-z][^\\s]*)\\s*$", ln, perl = TRUE))
    if (length(opener_m) == 1L && nchar(opener_m) > 0L) {
      n_colons <- nchar(regmatches(ln, regexpr("^:{3,}", ln)))
      attr_str <- trimws(sub("^:{3,}\\s*", "", ln))
      stack    <- c(stack, list(list(line = i, n = n_colons, attr = attr_str)))
      opened   <- opened + 1L
      next
    }

    # Closer: 3+ colons alone on the line
    closer_m <- regmatches(ln, regexpr("^(:{3,})\\s*$", ln, perl = TRUE))
    if (length(closer_m) == 1L && nchar(closer_m) > 0L) {
      n_colons <- nchar(regmatches(ln, regexpr("^:{3,}", ln)))
      if (length(stack) == 0L) {
        errors <- c(errors, sprintf(
          "Orphan div close at line %d (no matching open)", i))
      } else {
        # Pop the most recent opener (LIFO)
        top   <- stack[[length(stack)]]
        stack <- stack[-length(stack)]
        if (top$n != n_colons) {
          errors <- c(errors, sprintf(
            "Mismatched fence depth: opened %d colons at line %d (%s), closed %d colons at line %d",
            top$n, top$line, top$attr, n_colons, i))
        }
      }
      closed <- closed + 1L
      next
    }
  }

  # Unclosed code block at end of file
  if (!is.null(code_fence_chr)) {
    errors <- c(errors, sprintf(
      "Unclosed code fence (started with %s)", strrep(code_fence_chr, code_fence_len)))
  }

  # Anything remaining on the stack is an unclosed div opener
  for (entry in stack) {
    errors <- c(errors, sprintf(
      "Unclosed div fence at line %d: %s", entry$line, entry$attr))
  }

  list(errors = errors, opened = opened, closed = closed)
}
