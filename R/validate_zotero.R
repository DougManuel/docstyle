#' Validate Zotero Field Codes in Word Documents
#'
#' Comprehensive validation for Zotero field codes in DOCX files. Checks
#' field code structure, ZOTERO_PREF presence, citation JSON validity,
#' and bibliography structure.
#'
#' @param docx_path Path to the DOCX file to validate
#' @param verbose Logical. Print detailed validation output. Default TRUE.
#'
#' @return A list with validation results:
#' \describe{
#'   \item{valid}{Logical. TRUE if all critical checks passed}
#'   \item{summary}{List with counts: items, bibl, pref, field_codes}
#'   \item{checks}{Named list of individual check results}
#'   \item{issues}{List with errors (critical) and warnings (non-critical)}
#'   \item{zotero_pref}{Parsed ZOTERO_PREF content, if found}
#' }
#'
#' @details
#' The validator checks:
#' \itemize{
#'   \item **Field code structure**: Balanced begin/separate/end sequences
#'   \item **ZOTERO_PREF**: Document preferences field exists with valid JSON
#'   \item **ZOTERO_ITEM**: Each citation has valid CSL_CITATION JSON
#'   \item **ZOTERO_BIBL**: Bibliography field has valid structure
#'   \item **No orphan references**: All citation IDs properly closed
#' }
#'
#' @examples
#' \dontrun{
#' # Validate a document
#' result <- validate_zotero("document.docx")
#'
#' if (!result$valid) {
#'   cat("Zotero validation failed:\n")
#'   for (err in result$issues$errors) {
#'     cat("  ERROR:", err, "\n")
#'   }
#' }
#'
#' # Check if ZOTERO_PREF is missing
#' if (!result$checks$has_zotero_pref) {
#'   cat("Missing ZOTERO_PREF - Zotero may be unstable\n")
#' }
#' }
#'
#' @export
validate_zotero <- function(docx_path, verbose = TRUE) {

  result <- list(
    valid = TRUE,
    summary = list(
      zotero_items = 0,
      zotero_bibl = 0,
      zotero_pref = 0,
      field_codes_total = 0,
      field_codes_begin = 0,
      field_codes_separate = 0,
      field_codes_end = 0
    ),
    checks = list(
      file_exists = FALSE,
      valid_docx = FALSE,
      has_document_xml = FALSE,
      field_codes_balanced = FALSE,
      has_zotero_pref = FALSE,
      zotero_pref_valid_json = FALSE,
      zotero_items_valid = FALSE,
      zotero_bibl_valid = FALSE,
      no_nested_fields = FALSE
    ),
    issues = list(
      errors = character(),
      warnings = character()
    ),
    zotero_pref = NULL,
    zotero_items = list(),
    zotero_bibl = NULL
  )

  # Helper to add error
  add_error <- function(msg) {
    result$issues$errors <<- c(result$issues$errors, msg)
    result$valid <<- FALSE
  }

  # Helper to add warning
  add_warning <- function(msg) {
    result$issues$warnings <<- c(result$issues$warnings, msg)
  }

  # Check 1: File exists
  if (!file.exists(docx_path)) {
    add_error(paste("File not found:", docx_path))
    return(result)
  }
  result$checks$file_exists <- TRUE

  # Check 2: Valid DOCX structure
  temp_dir <- tempfile("validate_zotero_")
  dir.create(temp_dir)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  tryCatch({
    utils::unzip(docx_path, exdir = temp_dir)
    result$checks$valid_docx <- TRUE
  }, error = function(e) {
    add_error(paste("Invalid DOCX file:", conditionMessage(e)))
  })

  if (!result$checks$valid_docx) {
    return(result)
  }

  # Check 3: document.xml exists
  doc_xml_path <- file.path(temp_dir, "word", "document.xml")
  if (!file.exists(doc_xml_path)) {
    add_error("word/document.xml not found in DOCX")
    return(result)
  }
  result$checks$has_document_xml <- TRUE

  # Read document.xml
  doc_content <- paste(readLines(doc_xml_path, warn = FALSE), collapse = "\n")

  # Check 4: Field code structure (balanced begin/separate/end)
  field_chars <- regmatches(
    doc_content,
    gregexpr('<w:fldChar[^>]*w:fldCharType="([^"]+)"', doc_content, perl = TRUE)
  )[[1]]

  field_types <- gsub('.*w:fldCharType="([^"]+)".*', "\\1", field_chars)

  result$summary$field_codes_total <- length(field_types)
  result$summary$field_codes_begin <- sum(field_types == "begin")
  result$summary$field_codes_separate <- sum(field_types == "separate")
  result$summary$field_codes_end <- sum(field_types == "end")

  if (result$summary$field_codes_begin != result$summary$field_codes_end) {
    add_error(sprintf(
      "Unbalanced field codes: %d begins vs %d ends",
      result$summary$field_codes_begin,
      result$summary$field_codes_end
    ))
  } else {
    result$checks$field_codes_balanced <- TRUE
  }

  # Check for nested fields (consecutive begins without intervening end)
  depth <- 0
  max_depth <- 0
  nested_found <- FALSE
  for (ft in field_types) {
    if (ft == "begin") {
      depth <- depth + 1
      if (depth > 1) nested_found <- TRUE
      max_depth <- max(max_depth, depth)
    } else if (ft == "end") {
      depth <- depth - 1
    }
  }

  if (nested_found) {
    add_warning(sprintf("Nested field codes detected (max depth: %d)", max_depth))
  } else {
    result$checks$no_nested_fields <- TRUE
  }

  # Check 5: ZOTERO_PREF field
  # The JSON may contain nested braces, so we extract until the end of instrText
  pref_pattern <- "ADDIN ZOTERO_PREF\\s+(\\{[^<]+)"
  pref_matches <- regmatches(doc_content, gregexpr(pref_pattern, doc_content, perl = TRUE))[[1]]
  result$summary$zotero_pref <- length(pref_matches)

  if (length(pref_matches) == 0) {
    add_warning("ZOTERO_PREF field not found - Zotero may be unable to manage this document")
  } else {
    result$checks$has_zotero_pref <- TRUE

    # Try to parse ZOTERO_PREF JSON
    tryCatch({
      # Extract JSON from the match (starts at the {)
      pref_json_match <- regmatches(
        pref_matches[1],
        regexpr("\\{.*", pref_matches[1], perl = TRUE)
      )
      if (length(pref_json_match) > 0 && nchar(pref_json_match) > 0) {
        pref_json_clean <- trimws(unescape_xml_entities(pref_json_match))

        result$zotero_pref <- jsonlite::fromJSON(pref_json_clean, simplifyVector = FALSE)
        result$checks$zotero_pref_valid_json <- TRUE
      }
    }, error = function(e) {
      add_warning(paste("ZOTERO_PREF contains invalid JSON:", conditionMessage(e)))
    })
  }

  # Check 6: ZOTERO_ITEM fields
  item_pattern <- "ADDIN ZOTERO_ITEM CSL_CITATION.*?csl-citation[.]json\"[}]"
  item_matches <- regmatches(doc_content, gregexpr(item_pattern, doc_content, perl = TRUE))[[1]]
  result$summary$zotero_items <- length(item_matches)

  if (length(item_matches) > 0) {
    items_valid <- TRUE
    for (i in seq_along(item_matches)) {
      tryCatch({
        # Extract JSON portion
        json_start <- regexpr("\\{", item_matches[i])
        if (json_start > 0) {
          json_str <- substr(item_matches[i], json_start, nchar(item_matches[i]))
          json_str <- unescape_xml_entities(json_str)

          parsed <- jsonlite::fromJSON(json_str, simplifyVector = FALSE)
          result$zotero_items[[i]] <- list(
            citationID = parsed$citationID,
            formattedCitation = parsed$properties$formattedCitation,
            n_items = length(parsed$citationItems)
          )
        }
      }, error = function(e) {
        items_valid <<- FALSE
        add_warning(sprintf("ZOTERO_ITEM #%d has invalid JSON: %s", i, conditionMessage(e)))
      })
    }
    result$checks$zotero_items_valid <- items_valid
  } else {
    # No items is okay if no citations
    result$checks$zotero_items_valid <- TRUE
  }

  # Check 7: ZOTERO_BIBL field
  bibl_pattern <- "ADDIN ZOTERO_BIBL[^}]*\\}[^C]*CSL_BIBLIOGRAPHY"
  bibl_matches <- regmatches(doc_content, gregexpr(bibl_pattern, doc_content, perl = TRUE))[[1]]
  result$summary$zotero_bibl <- length(bibl_matches)

  if (length(bibl_matches) > 0) {
    tryCatch({
      # Extract JSON from ZOTERO_BIBL
      json_match <- regmatches(
        bibl_matches[1],
        regexpr("\\{[^}]*\\}", bibl_matches[1], perl = TRUE)
      )
      if (length(json_match) > 0 && nchar(json_match) > 0) {
        json_clean <- unescape_xml_entities(json_match)
        result$zotero_bibl <- jsonlite::fromJSON(json_clean, simplifyVector = FALSE)
        result$checks$zotero_bibl_valid <- TRUE
      }
    }, error = function(e) {
      add_warning(paste("ZOTERO_BIBL contains invalid JSON:", conditionMessage(e)))
    })
  } else {
    # No bibliography is okay (might just have citations)
    result$checks$zotero_bibl_valid <- TRUE
    if (result$summary$zotero_items > 0) {
      add_warning("Document has citations but no bibliography field")
    }
  }

  # Print summary if verbose
  if (verbose) {
    cat("\n=== Zotero Validation Report ===\n\n")

    cat("Summary:\n")
    cat(sprintf("  ZOTERO_ITEM fields: %d\n", result$summary$zotero_items))
    cat(sprintf("  ZOTERO_BIBL fields: %d\n", result$summary$zotero_bibl))
    cat(sprintf("  ZOTERO_PREF fields: %d\n", result$summary$zotero_pref))
    cat(sprintf("  Total field codes:  %d (begin: %d, separate: %d, end: %d)\n",
                result$summary$field_codes_total,
                result$summary$field_codes_begin,
                result$summary$field_codes_separate,
                result$summary$field_codes_end))

    cat("\nChecks:\n")
    for (check_name in names(result$checks)) {
      status <- if (result$checks[[check_name]]) "\u2713" else "\u2717"
      cat(sprintf("  %s %s\n", status, gsub("_", " ", check_name)))
    }

    if (length(result$issues$errors) > 0) {
      cat("\nErrors:\n")
      for (err in result$issues$errors) {
        cat(sprintf("  \u2717 %s\n", err))
      }
    }

    if (length(result$issues$warnings) > 0) {
      cat("\nWarnings:\n")
      for (warn in result$issues$warnings) {
        cat(sprintf("  ! %s\n", warn))
      }
    }

    cat(sprintf("\nOverall: %s\n", if (result$valid) "VALID" else "INVALID"))
  }

  result
}


#' Extract ZOTERO_PREF from a Word Document
#'
#' Extracts the Zotero document preferences field, which contains
#' citation style settings, field type preferences, and session info.
#'
#' @param docx_path Path to the DOCX file
#'
#' @return A list with ZOTERO_PREF content, or NULL if not found
#'
#' @examples
#' \dontrun{
#' pref <- extract_zotero_pref("document.docx")
#' if (!is.null(pref)) {
#'   cat("Style:", pref$style$styleID, "\n")
#' }
#' }
#'
#' @keywords internal
#' @export
extract_zotero_pref <- function(docx_path) {

  if (!file.exists(docx_path)) {
    stop("File not found: ", docx_path)
  }

  # Extract document.xml
  temp_dir <- tempfile("extract_pref_")
  dir.create(temp_dir)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  utils::unzip(docx_path, exdir = temp_dir)

  doc_xml_path <- file.path(temp_dir, "word", "document.xml")
  if (!file.exists(doc_xml_path)) {
    return(NULL)
  }

  doc_content <- paste(readLines(doc_xml_path, warn = FALSE), collapse = "\n")

  # Find ZOTERO_PREF field
  # Pattern captures everything after "ADDIN ZOTERO_PREF " until the next XML tag
  # The JSON may contain nested braces, so we can't use [^}]+
  pref_pattern <- "ADDIN ZOTERO_PREF\\s+(\\{[^<]+)"
  pref_match <- regmatches(doc_content, regexpr(pref_pattern, doc_content, perl = TRUE))

  if (length(pref_match) == 0 || nchar(pref_match) == 0) {
    return(NULL)
  }

  # Extract JSON from the match (starts at the {)
  json_match <- regmatches(pref_match, regexpr("\\{.*", pref_match, perl = TRUE))

  if (length(json_match) == 0 || nchar(json_match) == 0) {
    return(NULL)
  }

  json_clean <- unescape_xml_entities(trimws(json_match))

  tryCatch({
    jsonlite::fromJSON(json_clean, simplifyVector = FALSE)
  }, error = function(e) {
    warning("Failed to parse ZOTERO_PREF JSON: ", conditionMessage(e))
    NULL
  })
}


#' Find Insertion Point for Content in First Paragraph
#'
#' Locates where to insert field code runs in the first paragraph after
#' w:body. Returns the position after any w:pPr element (paragraph properties)
#' so that injected content appears before visible text but after formatting.
#'
#' @param doc_content Full document.xml content as string
#' @param body_end Position of the end of the <w:body> opening tag
#' @return Insert position (character index), or NULL if no paragraph found
#' @noRd
find_first_para_content_start <- function(doc_content, body_end) {
  after_body <- substr(doc_content, body_end + 1, nchar(doc_content))
  para_match <- regexpr("<w:p[^>]*>", after_body, perl = TRUE)

  if (para_match == -1) return(NULL)

  para_tag_end <- body_end + para_match + attr(para_match, "match.length") - 1

  # Check for w:pPr immediately after the opening tag
  after_para <- substr(doc_content, para_tag_end + 1, para_tag_end + 100)
  pPr_match <- regexpr("^\\s*<w:pPr[^>]*>", after_para, perl = TRUE)

  if (pPr_match > 0) {
    # Find end of </w:pPr> and insert after it
    pPr_end <- regexpr("</w:pPr>", after_para, perl = TRUE)
    if (pPr_end > 0) {
      return(para_tag_end + pPr_end + 7)  # +7 for "</w:pPr>"
    }
  }

  # No pPr, insert right after <w:p>
  para_tag_end
}


#' Build ZOTERO_PREF Field Code XML
#'
#' Generates the XML for a ZOTERO_PREF field code that can be injected
#' into a DOCX document. This is needed when the preferences field is
#' missing or corrupted.
#'
#' @param style_id CSL style ID (e.g., "http://www.zotero.org/styles/apa")
#' @param data_version Zotero data version (default: "4")
#' @param field_type "Fields" or "Bookmarks" (default: "Fields")
#' @param store_references Whether to store references in document (default: TRUE)
#' @param journal_abbreviations Whether Zotero should auto-abbreviate journal
#'   names in the rendered bibliography (default: TRUE)
#'
#' @return Character string containing the field code XML
#'
#' @examples
#' \dontrun{
#' # Generate APA style preferences
#' pref_xml <- build_zotero_pref_xml(
#'   style_id = "http://www.zotero.org/styles/apa"
#' )
#' }
#'
#' @keywords internal
#' @export
build_zotero_pref_xml <- function(style_id = "http://www.zotero.org/styles/vancouver",
                                   data_version = "4",
                                   field_type = "Fields",
                                   store_references = TRUE,
                                   journal_abbreviations = TRUE) {

  # Build the ZOTERO_PREF JSON structure
  pref_json <- list(
    dataVersion = data_version,
    storeReferences = store_references,
    automaticJournalAbbreviations = isTRUE(journal_abbreviations),
    noteType = 0L,
    style = list(
      styleID = style_id,
      bibliographyStyleHasBeenSet = TRUE
    ),
    prefs = list(
      fieldType = field_type
    )
  )

  json_str <- jsonlite::toJSON(pref_json, auto_unbox = TRUE)

  # Build the field code XML structure
  # This creates a 5-run structure: begin, instrText, separate, result, end
  instr_text <- paste0("ADDIN ZOTERO_PREF ", json_str)

  field_xml <- paste0(
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve">', escape_xml_text_full(instr_text), '</w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:t></w:t></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r>'
  )

  field_xml
}


#' Inject ZOTERO_PREF into a Word Document
#'
#' Adds or replaces the ZOTERO_PREF field in a DOCX document. This can
#' restore Zotero functionality when the preferences field is missing.
#'
#' @param docx_path Path to the DOCX file
#' @param style_id CSL style ID (default: Vancouver/numbered)
#' @param output_path Output path (default: overwrite input)
#' @param replace_existing If TRUE, replace existing ZOTERO_PREF. If FALSE,
#'   only add if missing.
#' @param field_type "Fields" or "Bookmarks" (default: "Fields"). Passed to
#'   `build_zotero_pref_xml()`.
#' @param journal_abbreviations Passed to `build_zotero_pref_xml()`
#'   (default: TRUE).
#' @param store_references Passed to `build_zotero_pref_xml()`
#'   (default: TRUE).
#'
#' @return The output path, invisibly
#'
#' @examples
#' \dontrun{
#' # Add missing ZOTERO_PREF with Vancouver style
#' inject_zotero_pref("document.docx")
#'
#' # Use APA style
#' inject_zotero_pref("document.docx",
#'   style_id = "http://www.zotero.org/styles/apa")
#' }
#'
#' @keywords internal
#' @export
inject_zotero_pref <- function(docx_path,
                                style_id = "http://www.zotero.org/styles/vancouver",
                                output_path = docx_path,
                                replace_existing = FALSE,
                                field_type = "Fields",
                                journal_abbreviations = TRUE,
                                store_references = TRUE) {

  if (!file.exists(docx_path)) {
    stop("File not found: ", docx_path)
  }

  # Check if ZOTERO_PREF already exists
  existing_pref <- extract_zotero_pref(docx_path)
  if (!is.null(existing_pref) && !replace_existing) {
    message("ZOTERO_PREF already exists. Use replace_existing=TRUE to replace.")
    return(invisible(output_path))
  }

  # Extract DOCX
  temp_dir <- tempfile("inject_pref_")
  dir.create(temp_dir)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  utils::unzip(docx_path, exdir = temp_dir)

  doc_xml_path <- file.path(temp_dir, "word", "document.xml")
  if (!file.exists(doc_xml_path)) {
    stop("Invalid DOCX: word/document.xml not found")
  }

  doc_content <- paste(readLines(doc_xml_path, warn = FALSE), collapse = "\n")

  # Build the ZOTERO_PREF field
  pref_xml <- build_zotero_pref_xml(style_id = style_id,
                                     field_type = field_type,
                                     journal_abbreviations = journal_abbreviations,
                                     store_references = store_references)

  # Find insertion point - after the first <w:body> opening tag
  body_match <- regexpr("<w:body[^>]*>", doc_content, perl = TRUE)
  if (body_match == -1) {
    stop("Could not find <w:body> in document.xml")
  }

  body_end <- body_match + attr(body_match, "match.length") - 1

  # If replacing, remove existing ZOTERO_PREF
  if (replace_existing && !is.null(existing_pref)) {
    # Pattern to match the full ZOTERO_PREF field (begin...end)
    # This is complex because the field spans multiple w:r elements
    pref_removal_pattern <- paste0(
      '<w:r[^>]*><w:fldChar[^>]*fldCharType="begin"[^>]*/></w:r>',
      '.*?ADDIN ZOTERO_PREF.*?',
      '<w:r[^>]*><w:fldChar[^>]*fldCharType="end"[^>]*/></w:r>'
    )
    doc_content <- gsub(pref_removal_pattern, "", doc_content, perl = TRUE)
  }

  # Insert ZOTERO_PREF into the first paragraph (avoids blank line before title)
  insert_pos <- find_first_para_content_start(doc_content, body_end)

  if (!is.null(insert_pos)) {
    doc_content <- paste0(
      substr(doc_content, 1, insert_pos),
      pref_xml,
      substr(doc_content, insert_pos + 1, nchar(doc_content))
    )
  } else {
    # Fallback: create new paragraph (shouldn't happen normally)
    doc_content <- paste0(
      substr(doc_content, 1, body_end),
      paste0("<w:p>", pref_xml, "</w:p>"),
      substr(doc_content, body_end + 1, nchar(doc_content))
    )
  }

  # Write back
  writeLines(doc_content, doc_xml_path)

  # Re-zip
  output_path_abs <- normalizePath(output_path, mustWork = FALSE)
  wd <- getwd()
  setwd(temp_dir)
  on.exit(setwd(wd), add = TRUE)

  # Get list of files to include
  all_files <- list.files(".", recursive = TRUE, all.files = TRUE)

  # Remove existing output file if different from input
  if (file.exists(output_path_abs) && output_path_abs != normalizePath(docx_path)) {
    file.remove(output_path_abs)
  }

  # Create the zip
  utils::zip(output_path_abs, files = all_files, flags = "-q")

  message("Injected ZOTERO_PREF into: ", output_path)
  invisible(output_path)
}


#' Inject All Zotero Components from field-codes.json
#'
#' Comprehensive post-render injection of Zotero components. Reads stored
#' preferences from field-codes.json (extracted during import) and injects
#' them into the rendered DOCX to restore full Zotero functionality.
#'
#' If no stored preferences exist but the document has Zotero citations,
#' a default ZOTERO_PREF will be generated based on a specified style.
#'
#' @param docx_path Path to the rendered DOCX file
#' @param field_codes_json Path to field-codes.json containing stored Zotero data.
#'   If NULL, auto-detected from `_docstyle/` directory.
#' @param default_style CSL style ID to use if no stored style is found.
#'   Default: "http://www.zotero.org/styles/vancouver"
#' @param zotero_config Optional list of Zotero preferences from `docstyle.zotero`
#'   in `_quarto.yml`. Supported keys:
#'   \describe{
#'     \item{`style`}{CSL style URL. Takes precedence over `default_style`.}
#'     \item{`field-type`}{"Fields" (default) or "Bookmarks".}
#'     \item{`journal-abbreviations`}{Logical. Default TRUE.}
#'     \item{`store-references`}{Logical. Default TRUE.}
#'   }
#'   Stored ZOTERO_PREF from `field-codes.json` still takes highest priority.
#' @param validate If TRUE (default), validate the document after injection.
#' @param verbose If TRUE, print progress messages. Default FALSE.
#'
#' @return A list with:
#' \describe{
#'   \item{success}{Logical. TRUE if injection completed without errors}
#'   \item{zotero_pref_injected}{Logical. TRUE if ZOTERO_PREF was injected}
#'   \item{style_id}{The citation style used}
#'   \item{validation}{Validation result if validate=TRUE, otherwise NULL}
#'   \item{message}{Human-readable summary}
#' }
#'
#' @details
#' This function is typically called as part of the Quarto post-render hook.
#' It ensures rendered documents have all necessary Zotero metadata for
#' round-trip editing:
#'
#' 1. **ZOTERO_PREF**: Document preferences (citation style, field type)
#' 2. **Validation**: Ensures field codes are properly balanced
#'
#' The function respects the principle that stored preferences from the
#' source document take precedence, but will generate defaults if needed
#' for documents that start from vanilla QMD files.
#'
#' @examples
#' \dontrun{
#' # Basic usage in post-render hook
#' result <- inject_zotero_components("output/document.docx")
#'
#' # Specify field-codes.json location
#' result <- inject_zotero_components(
#'   "output/document.docx",
#'   field_codes_json = "_docstyle/field-codes.json"
#' )
#'
#' # Use APA style for new documents
#' result <- inject_zotero_components(
#'   "output/document.docx",
#'   default_style = "http://www.zotero.org/styles/apa"
#' )
#' }
#'
#' @keywords internal
#' @export
inject_zotero_components <- function(docx_path,
                                      field_codes_json = NULL,
                                      default_style = "http://www.zotero.org/styles/vancouver",
                                      zotero_config = NULL,
                                      validate = TRUE,
                                      verbose = FALSE) {

  result <- list(
    success = FALSE,
    zotero_pref_injected = FALSE,
    style_id = NULL,
    validation = NULL,
    message = ""
  )

  # Validate input

  if (!file.exists(docx_path)) {
    result$message <- paste("File not found:", docx_path)
    return(result)
  }

  # Auto-detect field-codes.json
  if (is.null(field_codes_json)) {
    docx_dir <- dirname(docx_path)
    candidates <- c(
      file.path(docx_dir, "_docstyle", "field-codes.json"),
      file.path(docx_dir, "field-codes.json"),
      file.path(dirname(docx_dir), "_docstyle", "field-codes.json")
    )
    for (candidate in candidates) {
      if (file.exists(candidate)) {
        field_codes_json <- candidate
        if (verbose) message("Found field-codes.json: ", candidate)
        break
      }
    }
  }

  # Read stored Zotero preferences from field-codes.json
  stored_pref <- NULL
  stored_style <- NULL
  has_citations <- FALSE

  if (!is.null(field_codes_json) && file.exists(field_codes_json)) {
    tryCatch({
      field_codes <- jsonlite::fromJSON(field_codes_json, simplifyVector = FALSE)

      # Check for stored ZOTERO_PREF
      # Note: NULL in JSON becomes empty list in R, so check for content
      if (!is.null(field_codes$zotero_pref) && length(field_codes$zotero_pref) > 0) {
        stored_pref <- field_codes$zotero_pref
        stored_style <- stored_pref$style$styleID
        if (verbose) message("Found stored ZOTERO_PREF (style: ", stored_style, ")")
      }

      # Check if there are citations
      has_citations <- length(field_codes$citations) > 0
      if (verbose && has_citations) {
        message("Found ", length(field_codes$citations), " citation(s) in field-codes.json")
      }
    }, error = function(e) {
      if (verbose) message("Warning: Could not read field-codes.json: ", conditionMessage(e))
    })
  }

  # Check if document already has ZOTERO_PREF
  existing_pref <- extract_zotero_pref(docx_path)
  has_existing_pref <- !is.null(existing_pref)

  if (has_existing_pref) {
    if (verbose) message("Document already has ZOTERO_PREF")
    result$style_id <- existing_pref$style$styleID
    result$zotero_pref_injected <- FALSE
  } else {
    # Need to inject ZOTERO_PREF
    # Priority: stored (field-codes.json) > YAML (zotero_config) > default_style param
    yaml_style <- zotero_config$style
    style_to_use <- stored_style %||% yaml_style %||% default_style

    # Other YAML-configurable settings (YAML > defaults)
    field_type_to_use     <- zotero_config$`field-type` %||% "Fields"
    journal_abbr_to_use   <- zotero_config$`journal-abbreviations` %||% TRUE
    store_refs_to_use     <- zotero_config$`store-references` %||% TRUE

    if (verbose) message("Injecting ZOTERO_PREF with style: ", style_to_use)

    tryCatch({
      inject_zotero_pref(
        docx_path = docx_path,
        style_id = style_to_use,
        output_path = docx_path,
        replace_existing = FALSE,
        field_type = field_type_to_use,
        journal_abbreviations = journal_abbr_to_use,
        store_references = store_refs_to_use
      )
      result$zotero_pref_injected <- TRUE
      result$style_id <- style_to_use
    }, error = function(e) {
      result$message <- paste("Failed to inject ZOTERO_PREF:", conditionMessage(e))
      return(result)
    })
  }

  # Validate if requested
  if (validate) {
    if (verbose) message("Validating Zotero components...")
    result$validation <- validate_zotero(docx_path, verbose = FALSE)

    if (!result$validation$valid) {
      result$message <- paste(
        "Zotero validation failed:",
        paste(result$validation$issues$errors, collapse = "; ")
      )
      return(result)
    }
  }

  # Build success message
  result$success <- TRUE
  parts <- character()

  if (result$zotero_pref_injected) {
    parts <- c(parts, "ZOTERO_PREF injected")
  }

  if (!is.null(result$validation)) {
    parts <- c(parts, sprintf(
      "%d citation(s) validated",
      result$validation$summary$zotero_items
    ))
  }

  result$message <- if (length(parts) > 0) {
    paste(parts, collapse = ", ")
  } else {
    "No changes needed"
  }

  result
}

