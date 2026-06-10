#' Validate rendered DOCX properties
#'
#' Property-based validation for rendered Word documents. Checks key formatting
#' properties to catch regressions during development.
#'
#' @param docx_path Path to the DOCX file to validate
#' @param expected Named list of expected properties. See Details for available
#'   properties.
#' @param verbose Logical. Print detailed validation results. Default TRUE.
#'
#' @details
#' Available properties to check:
#' \describe{
#'   \item{has_toc}{Logical. Document contains a table of contents field}
#'   \item{has_footnotes}{Logical. Document contains footnote definitions}
#'   \item{footnote_count}{Integer. Expected number of footnotes}
#'   \item{title_font}{Character. Font family for Title style}
#'   \item{body_font}{Character. Font family for Normal/body style}
#'   \item{heading1_font}{Character. Font family for Heading 1}
#'   \item{has_footer}{Logical. Document has footer content}
#'   \item{has_header}{Logical. Document has header content}
#'   \item{has_bold}{Logical. Document contains bold formatting}
#'   \item{has_italic}{Logical. Document contains italic formatting}
#'   \item{has_bullet_lists}{Logical. Document contains bullet lists}
#'   \item{has_numbered_lists}{Logical. Document contains numbered lists}
#'   \item{has_formal_lists}{Logical. Document has formal 1./a./i. list formatting}
#' }
#'
#' @return A list with:
#' \describe{
#'   \item{valid}{Logical. TRUE if all checks passed}
#'   \item{results}{Named list of check results (pass/fail/value)}
#'   \item{errors}{Character vector of failed check messages}
#' }
#'
#' @examples
#' \dontrun{
#' # Basic validation
#' validate_docx("output/TOR-current.docx", expected = list(
#'   has_toc = TRUE,
#'   has_footnotes = TRUE
#' ))
#'
#' # Full validation
#' validate_docx("output/TOR-current.docx", expected = list(
#'   has_toc = TRUE,
#'   has_footnotes = TRUE,
#'   footnote_count = 2,
#'   title_font = "Libre Baskerville",
#'   body_font = "Hanken Grotesk",
#'   has_footer = TRUE
#' ))
#' }
#'
#' @export
validate_docx <- function(docx_path, expected = list(), verbose = TRUE) {
  if (!file.exists(docx_path)) {
    stop("File not found: ", docx_path)
  }

  # Extract DOCX contents
  temp_dir <- tempfile("validate_docx_")
  dir.create(temp_dir)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)


  utils::unzip(docx_path, exdir = temp_dir)

  # Parse XML files
  doc_xml <- NULL
  styles_xml <- NULL
  footnotes_xml <- NULL
  numbering_xml <- NULL
  footer_files <- list()

  doc_path <- file.path(temp_dir, "word", "document.xml")
  if (file.exists(doc_path)) {
    doc_xml <- xml2::read_xml(doc_path)
  }

  styles_path <- file.path(temp_dir, "word", "styles.xml")
  if (file.exists(styles_path)) {
    styles_xml <- xml2::read_xml(styles_path)
  }

  fn_path <- file.path(temp_dir, "word", "footnotes.xml")
  if (file.exists(fn_path)) {
    footnotes_xml <- xml2::read_xml(fn_path)
  }

  numbering_path <- file.path(temp_dir, "word", "numbering.xml")
  if (file.exists(numbering_path)) {
    numbering_xml <- xml2::read_xml(numbering_path)
  }

  # Find footer files
  footer_pattern <- file.path(temp_dir, "word", "footer*.xml")
  footer_paths <- Sys.glob(footer_pattern)
  for (fp in footer_paths) {
    footer_files[[basename(fp)]] <- xml2::read_xml(fp)
  }

  # Collect actual properties
  actual <- list()

  # Check TOC
  if (!is.null(doc_xml)) {
    ns <- xml2::xml_ns(doc_xml)
    toc_fields <- xml2::xml_find_all(doc_xml, "//w:instrText[contains(text(), 'TOC')]", ns)
    actual$has_toc <- length(toc_fields) > 0
  }

  # Check footnotes
  if (!is.null(footnotes_xml)) {
    ns <- xml2::xml_ns(footnotes_xml)
    # Footnotes with type="separator" or type="continuationSeparator" are system footnotes
    all_footnotes <- xml2::xml_find_all(footnotes_xml, "//w:footnote", ns)
    user_footnotes <- 0
    for (fn in all_footnotes) {
      fn_type <- xml2::xml_attr(fn, "type")
      if (is.na(fn_type)) {
        user_footnotes <- user_footnotes + 1
      }
    }
    actual$has_footnotes <- user_footnotes > 0
    actual$footnote_count <- user_footnotes
  } else {
    actual$has_footnotes <- FALSE
    actual$footnote_count <- 0
  }

  # Check styles for fonts
 if (!is.null(styles_xml)) {
    ns <- xml2::xml_ns(styles_xml)

    # Title style font
    title_style <- xml2::xml_find_first(styles_xml, "//w:style[@w:styleId='Title']", ns)
    if (!is.na(title_style)) {
      title_font <- xml2::xml_find_first(title_style, ".//w:rFonts/@w:ascii", ns)
      if (!is.na(title_font)) {
        actual$title_font <- xml2::xml_text(title_font)
      }
    }

    # Normal/body style font
    normal_style <- xml2::xml_find_first(styles_xml, "//w:style[@w:styleId='Normal']", ns)
    if (!is.na(normal_style)) {
      body_font <- xml2::xml_find_first(normal_style, ".//w:rFonts/@w:ascii", ns)
      if (!is.na(body_font)) {
        actual$body_font <- xml2::xml_text(body_font)
      }
    }

    # Heading 1 style font
    h1_style <- xml2::xml_find_first(styles_xml, "//w:style[@w:styleId='Heading1']", ns)
    if (!is.na(h1_style)) {
      h1_font <- xml2::xml_find_first(h1_style, ".//w:rFonts/@w:ascii", ns)
      if (!is.na(h1_font)) {
        actual$heading1_font <- xml2::xml_text(h1_font)
      }
    }
  }

  # Check footer
  actual$has_footer <- length(footer_files) > 0 && any(sapply(footer_files, function(f) {
    ns <- xml2::xml_ns(f)
    text_nodes <- xml2::xml_find_all(f, "//w:t", ns)
    length(text_nodes) > 0
  }))

  # Check header
  header_pattern <- file.path(temp_dir, "word", "header*.xml")
  header_paths <- Sys.glob(header_pattern)
  actual$has_header <- length(header_paths) > 0

  # Check bold/italic in document
  if (!is.null(doc_xml)) {
    ns <- xml2::xml_ns(doc_xml)
    bold_nodes <- xml2::xml_find_all(doc_xml, "//w:b[not(@w:val='false') and not(@w:val='0')]", ns)
    italic_nodes <- xml2::xml_find_all(doc_xml, "//w:i[not(@w:val='false') and not(@w:val='0')]", ns)
    actual$has_bold <- length(bold_nodes) > 0
    actual$has_italic <- length(italic_nodes) > 0
  }

  # Check lists in numbering.xml
  actual$has_bullet_lists <- FALSE
  actual$has_numbered_lists <- FALSE
  actual$has_formal_lists <- FALSE

  if (!is.null(numbering_xml)) {
    ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

    # Find all abstract numbering definitions
    abstract_nums <- xml2::xml_find_all(numbering_xml, "//w:abstractNum", ns)

    for (abstract_num in abstract_nums) {
      # Check level 0 format to determine list type
      lvl0 <- xml2::xml_find_first(abstract_num, "w:lvl[@w:ilvl='0']", ns)
      if (inherits(lvl0, "xml_missing")) next

      numFmt0 <- xml2::xml_find_first(lvl0, "w:numFmt", ns)
      if (inherits(numFmt0, "xml_missing")) next

      fmt0_val <- xml2::xml_attr(numFmt0, "val")

      if (fmt0_val == "bullet") {
        actual$has_bullet_lists <- TRUE
      } else if (fmt0_val == "decimal") {
        actual$has_numbered_lists <- TRUE

        # Check for formal 1./a./i. pattern
        lvl1 <- xml2::xml_find_first(abstract_num, "w:lvl[@w:ilvl='1']", ns)
        lvl2 <- xml2::xml_find_first(abstract_num, "w:lvl[@w:ilvl='2']", ns)

        if (!inherits(lvl1, "xml_missing") && !inherits(lvl2, "xml_missing")) {
          numFmt1 <- xml2::xml_find_first(lvl1, "w:numFmt", ns)
          numFmt2 <- xml2::xml_find_first(lvl2, "w:numFmt", ns)

          if (!inherits(numFmt1, "xml_missing") && !inherits(numFmt2, "xml_missing")) {
            fmt1_val <- xml2::xml_attr(numFmt1, "val")
            fmt2_val <- xml2::xml_attr(numFmt2, "val")

            # Formal pattern: decimal (1.) -> lowerLetter (a.) -> lowerRoman (i.)
            if (fmt1_val == "lowerLetter" && fmt2_val == "lowerRoman") {
              actual$has_formal_lists <- TRUE
            }
          }
        }
      }
    }
  }

  # Compare expected vs actual
  results <- list()
  errors <- character()

  for (prop in names(expected)) {
    exp_val <- expected[[prop]]
    act_val <- actual[[prop]]

    if (is.null(act_val)) {
      results[[prop]] <- list(
        expected = exp_val,
        actual = NA,
        pass = FALSE
      )
      errors <- c(errors, sprintf("%s: property not found in document", prop))
    } else if (is.logical(exp_val)) {
      pass <- isTRUE(act_val) == isTRUE(exp_val)
      results[[prop]] <- list(
        expected = exp_val,
        actual = act_val,
        pass = pass
      )
      if (!pass) {
        errors <- c(errors, sprintf("%s: expected %s, got %s", prop, exp_val, act_val))
      }
    } else if (is.numeric(exp_val)) {
      pass <- isTRUE(all.equal(act_val, exp_val))
      results[[prop]] <- list(
        expected = exp_val,
        actual = act_val,
        pass = pass
      )
      if (!pass) {
        errors <- c(errors, sprintf("%s: expected %s, got %s", prop, exp_val, act_val))
      }
    } else if (is.character(exp_val)) {
      pass <- isTRUE(grepl(exp_val, act_val, ignore.case = TRUE))
      results[[prop]] <- list(
        expected = exp_val,
        actual = act_val,
        pass = pass
      )
      if (!pass) {
        errors <- c(errors, sprintf("%s: expected '%s', got '%s'", prop, exp_val, act_val))
      }
    }
  }

  valid <- length(errors) == 0

  if (verbose) {
    cat("\n=== DOCX Validation Results ===\n")
    cat("File:", docx_path, "\n")
    cat("File size:", file.size(docx_path), "bytes\n\n")

    if (length(expected) == 0) {
      cat("No expectations provided. Actual properties:\n")
      for (prop in names(actual)) {
        cat(sprintf("  %s: %s\n", prop, actual[[prop]]))
      }
    } else {
      for (prop in names(results)) {
        r <- results[[prop]]
        status <- if (r$pass) "\u2713" else "\u2717"
        cat(sprintf("  %s %s: expected=%s, actual=%s\n",
                    status, prop, r$expected, r$actual))
      }
    }

    cat("\n")
    if (valid) {
      cat("Result: ALL CHECKS PASSED\n")
    } else {
      cat("Result: VALIDATION FAILED\n")
      cat("Errors:\n")
      for (err in errors) {
        cat("  -", err, "\n")
      }
    }
    cat("\n")
  }

  invisible(list(
    valid = valid,
    results = results,
    actual = actual,
    errors = errors
  ))
}


#' Get DOCX properties without validation
#'
#' Extracts all detectable properties from a DOCX file without comparing
#' against expected values. Useful for inspecting a document's current state.
#'
#' @param docx_path Path to the DOCX file
#'
#' @return Named list of detected properties
#'
#' @examples
#' \dontrun{
#' props <- inspect_docx("output/TOR-current.docx")
#' props$has_toc
#' props$footnote_count
#' }
#'
#' @export
inspect_docx <- function(docx_path) {
  result <- validate_docx(docx_path, expected = list(), verbose = FALSE)
  result$actual
}
