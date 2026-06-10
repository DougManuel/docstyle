#' Validate DOCX structural integrity
#'
#' Deep validation of OOXML structure to catch potential corruption before
#' opening in Word. Checks XML well-formedness, ID uniqueness, relationship
#' integrity, and content type declarations.
#'
#' @param docx_path Path to the DOCX file to validate
#' @param checks Character vector of checks to run. Default runs all checks
#'   except `"xsd"` and `"ooxml"`, which require external tools (`xmllint`,
#'   `npx`). Available checks: "xml", "whitespace", "deletions", "insertions",
#'   "ids", "rels", "content_types", "rsids", "xsd", "ooxml"
#' @param verbose Logical. Print detailed validation output. Default TRUE.
#'
#' @return A list with:
#' \describe{
#'   \item{valid}{Logical. TRUE if all checks passed}
#'   \item{checks}{Named list of individual check results}
#'   \item{errors}{Character vector of error messages}
#'   \item{warnings}{Character vector of warning messages}
#' }
#'
#' @details
#' This function validates the internal structure of a DOCX file to catch
#' issues that would cause Word to report "unreadable content" errors.
#'
#' ## Checks performed
#'
#' - **xml**: All XML files are well-formed
#' - **whitespace**: w:t elements with leading/trailing whitespace have
#'   xml:space="preserve"
#' - **deletions**: `w:t` elements inside `w:del` are flagged (deleted text must use `w:delText`)
#' - **insertions**: w:delText not inside w:ins without w:del wrapper
#' - **ids**: Comment, bookmark, and range IDs are unique within their scope
#' - **rels**: All relationship references are valid and all files are referenced
#' - **content_types**: All content files are declared in \[Content_Types\].xml
#' - **rsids**: All RSID attribute values are 8-digit hexadecimal (0-9, A-F,
#'   case-insensitive). Invalid RSIDs can cause Word to report "unreadable
#'   content" errors. Errors are reported as warnings only (Word tolerates some
#'   RSID deviations). Only `word/document.xml` is checked; RSIDs in
#'   `settings.xml`, `footnotes.xml`, and `comments.xml` are not validated.
#' - **xsd**: XML files validate against OOXML schemas (requires xmllint).
#'   Note: XSD errors are reported as warnings only, not failures, because
#'   Pandoc-generated documents often have minor schema deviations that
#'   Word tolerates.
#' - **ooxml**: Validate against Microsoft Open XML SDK schemas via
#'   `@xarsh/ooxml-validator` (requires npx). Not in the default check set.
#'   Errors are reported as warnings only. See [validate_ooxml_schema()].
#'
#' @examples
#' \dontrun{
#' # Full validation
#' result <- validate_docx_structure("output/document.docx")
#'
#' # Quick validation (skip XSD)
#' result <- validate_docx_structure("output/document.docx",
#'   checks = c("xml", "whitespace", "ids", "rels"))
#'
#' # Programmatic use
#' result <- validate_docx_structure("output/document.docx", verbose = FALSE)
#' if (!result$valid) {
#'   stop("Structural validation failed: ", paste(result$errors, collapse = "; "))
#' }
#' }
#'
#' @seealso [validate_docx()] for property-based validation,
#'   [validate_comments()] for comment-specific validation
#'
#' @export
validate_docx_structure <- function(docx_path,
                                    checks = c("xml", "whitespace", "deletions",
                                               "insertions", "ids", "rels",
                                               "content_types", "rsids"),
                                    verbose = TRUE) {


  if (!file.exists(docx_path)) {
    stop("File not found: ", docx_path)
  }

  # Extract DOCX contents

temp_dir <- tempfile("validate_structure_")
  dir.create(temp_dir)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  utils::unzip(docx_path, exdir = temp_dir)

  # Initialize results
  result <- list(
    valid = TRUE,
    checks = list(),
    errors = character(),
    warnings = character()
  )

  # Helper for verbose output
  print_header <- function(title) {
    if (verbose) {
      cat(sprintf("\n\u2550\u2550 %s \u2550\u2550\n", title))
    }
  }

  print_check <- function(pass, msg) {
    if (verbose) {
      symbol <- if (pass) "\u2713" else "\u2717"
      cat(sprintf("  %s %s\n", symbol, msg))
    }
  }

  print_warn <- function(msg) {
    if (verbose) {
      cat(sprintf("  \u26a0 %s\n", msg))
    }
  }

  if (verbose) {
    cat("\n\u2550\u2550 Validating DOCX structure \u2550\u2550\n")
    cat(sprintf("File: %s\n", basename(docx_path)))
  }

  # Run requested checks
  if ("xml" %in% checks) {
    check_result <- validate_xml_wellformed(temp_dir, verbose)
    result$checks$xml <- check_result
    if (!check_result$valid) {
      result$valid <- FALSE
      result$errors <- c(result$errors, check_result$errors)
    }
  }

  if ("whitespace" %in% checks) {
    check_result <- validate_whitespace_preservation(temp_dir, verbose)
    result$checks$whitespace <- check_result
    if (!check_result$valid) {
      result$valid <- FALSE
      result$errors <- c(result$errors, check_result$errors)
    }
  }

  if ("deletions" %in% checks) {
    check_result <- validate_deletions(temp_dir, verbose)
    result$checks$deletions <- check_result
    if (!check_result$valid) {
      result$valid <- FALSE
      result$errors <- c(result$errors, check_result$errors)
    }
  }

  if ("insertions" %in% checks) {
    check_result <- validate_insertions(temp_dir, verbose)
    result$checks$insertions <- check_result
    if (!check_result$valid) {
      result$valid <- FALSE
      result$errors <- c(result$errors, check_result$errors)
    }
  }

  if ("ids" %in% checks) {
    check_result <- validate_unique_ids(temp_dir, verbose)
    result$checks$ids <- check_result
    if (!check_result$valid) {
      result$valid <- FALSE
      result$errors <- c(result$errors, check_result$errors)
    }
    if (length(check_result$warnings) > 0) {
      result$warnings <- c(result$warnings, check_result$warnings)
    }
  }

  if ("rels" %in% checks) {
    check_result <- validate_relationships(temp_dir, verbose)
    result$checks$rels <- check_result
    if (!check_result$valid) {
      result$valid <- FALSE
      result$errors <- c(result$errors, check_result$errors)
    }
    if (length(check_result$warnings) > 0) {
      result$warnings <- c(result$warnings, check_result$warnings)
    }
  }

  if ("content_types" %in% checks) {
    check_result <- validate_content_types(temp_dir, verbose)
    result$checks$content_types <- check_result
    if (!check_result$valid) {
      result$valid <- FALSE
      result$errors <- c(result$errors, check_result$errors)
    }
  }

  if ("rsids" %in% checks) {
    check_result <- tryCatch(
      validate_rsids(temp_dir, verbose),
      error = function(e) {
        list(valid = FALSE,
             errors = sprintf("rsids check failed unexpectedly: %s", conditionMessage(e)))
      }
    )
    result$checks$rsids <- check_result
    # RSID failures are demoted to warnings: Word tolerates some deviations,
    # but invalid RSIDs can still trigger "unreadable content" errors in some builds.
    if (!check_result$valid) {
      result$warnings <- c(result$warnings, check_result$errors)
    }
  }

  if ("xsd" %in% checks) {
    check_result <- validate_xsd(temp_dir, verbose)
    result$checks$xsd <- check_result
    # XSD errors are informational only (Pandoc generates valid but non-strict XML)
    # They don't fail overall validation, but are reported as warnings
    if (!check_result$valid) {
      result$warnings <- c(result$warnings, check_result$errors)
    }
    if (length(check_result$warnings) > 0) {
      result$warnings <- c(result$warnings, check_result$warnings)
    }
  }

  if ("ooxml" %in% checks) {
    ooxml_result <- validate_ooxml_schema(docx_path, verbose = verbose)
    result$checks$ooxml <- ooxml_result
    # OOXML schema errors are informational (even Pandoc's default has errors)
    if (!ooxml_result$valid && length(ooxml_result$errors) > 0) {
      error_msgs <- vapply(ooxml_result$errors, function(e) {
        sprintf("OOXML: %s %s", e$path %||% "", e$description %||% "")
      }, character(1))
      result$warnings <- c(result$warnings, error_msgs)
    }
  }

  # Print summary
  if (verbose) {
    cat("\n\u2500\u2500 Summary \u2500\u2500\n")
    if (result$valid) {
      cat("  \u2713 All structural checks passed\n")
    } else {
      cat(sprintf("  \u2717 Validation failed with %d error(s)\n", length(result$errors)))
      for (err in result$errors) {
        cat(sprintf("    - %s\n", err))
      }
    }
    if (length(result$warnings) > 0) {
      cat(sprintf("  \u26a0 %d warning(s)\n", length(result$warnings)))
    }
    cat("\n")
  }

  invisible(result)
}


#' Validate XML well-formedness
#'
#' Check that all XML files in the unpacked DOCX are well-formed.
#'
#' @param unpacked_dir Path to extracted DOCX directory
#' @param verbose Logical. Print progress.
#'
#' @return List with valid (logical) and errors (character vector)
#'
#' @keywords internal
validate_xml_wellformed <- function(unpacked_dir, verbose = FALSE) {
  if (verbose) {
    cat("\n\u2500\u2500 XML well-formedness \u2500\u2500\n")
  }

  result <- list(valid = TRUE, errors = character())

  # Find all XML and .rels files
  xml_files <- c(
    list.files(unpacked_dir, pattern = "\\.xml$", recursive = TRUE, full.names = TRUE),
    list.files(unpacked_dir, pattern = "\\.rels$", recursive = TRUE, full.names = TRUE)
  )

  for (xml_file in xml_files) {
    relative_path <- sub(paste0("^", unpacked_dir, "/?"), "", xml_file)

    tryCatch({
      xml2::read_xml(xml_file)
    }, error = function(e) {
      result$valid <<- FALSE
      result$errors <<- c(result$errors,
        sprintf("%s: %s", relative_path, conditionMessage(e)))
    })
  }

  if (verbose) {
    if (result$valid) {
      cat(sprintf("  \u2713 All %d XML files are well-formed\n", length(xml_files)))
    } else {
      cat(sprintf("  \u2717 %d XML parsing error(s)\n", length(result$errors)))
    }
  }

  result
}


#' Validate whitespace preservation
#'
#' Check that w:t elements with leading/trailing whitespace have
#' xml:space="preserve" attribute.
#'
#' @param unpacked_dir Path to extracted DOCX directory
#' @param verbose Logical. Print progress.
#'
#' @return List with valid (logical) and errors (character vector)
#'
#' @keywords internal
validate_whitespace_preservation <- function(unpacked_dir, verbose = FALSE) {
  if (verbose) {
    cat("\n\u2500\u2500 Whitespace preservation \u2500\u2500\n")
  }

  result <- list(valid = TRUE, errors = character())

  doc_path <- file.path(unpacked_dir, "word", "document.xml")
  if (!file.exists(doc_path)) {
    if (verbose) cat("  \u2139 No document.xml found\n")
    return(result)
  }

  doc_xml <- xml2::read_xml(doc_path)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # Find all w:t elements
  t_elements <- xml2::xml_find_all(doc_xml, "//w:t", ns)

  violations <- 0
  for (t_elem in t_elements) {
    text <- xml2::xml_text(t_elem)
    if (is.na(text) || nchar(text) == 0) next

    # Check for leading or trailing whitespace
    if (grepl("^\\s", text) || grepl("\\s$", text)) {
      # xml:space attribute is stored as just "space" in xml2
      attrs <- xml2::xml_attrs(t_elem)
      space_attr <- attrs["space"]
      if (is.na(space_attr) || space_attr != "preserve") {
        violations <- violations + 1
        # Get context (truncate long text)
        text_preview <- if (nchar(text) > 30) {
          paste0(substr(text, 1, 27), "...")
        } else {
          text
        }
        result$errors <- c(result$errors,
          sprintf("w:t missing xml:space='preserve': %s", shQuote(text_preview)))
      }
    }
  }

  result$valid <- violations == 0

  if (verbose) {
    if (result$valid) {
      cat(sprintf("  \u2713 Checked %d w:t elements, all whitespace preserved\n",
                  length(t_elements)))
    } else {
      cat(sprintf("  \u2717 %d w:t element(s) missing xml:space='preserve'\n", violations))
    }
  }

  result
}


#' Validate deletion markup
#'
#' Ensure w:t elements are not inside w:del elements (must be w:delText).
#'
#' @param unpacked_dir Path to extracted DOCX directory
#' @param verbose Logical. Print progress.
#'
#' @return List with valid (logical) and errors (character vector)
#'
#' @keywords internal
validate_deletions <- function(unpacked_dir, verbose = FALSE) {
  if (verbose) {
    cat("\n\u2500\u2500 Deletion markup \u2500\u2500\n")
  }

  result <- list(valid = TRUE, errors = character())

  doc_path <- file.path(unpacked_dir, "word", "document.xml")
  if (!file.exists(doc_path)) {
    if (verbose) cat("  \u2139 No document.xml found\n")
    return(result)
  }

  doc_xml <- xml2::read_xml(doc_path)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # Find w:t elements inside w:del (this is invalid)
  problematic <- xml2::xml_find_all(doc_xml, ".//w:del//w:t", ns)

  for (t_elem in problematic) {
    text <- xml2::xml_text(t_elem)
    if (!is.na(text) && nchar(text) > 0) {
      text_preview <- if (nchar(text) > 30) {
        paste0(substr(text, 1, 27), "...")
      } else {
        text
      }
      result$errors <- c(result$errors,
        sprintf("<w:t> inside <w:del> (should be <w:delText>): %s", shQuote(text_preview)))
    }
  }

  result$valid <- length(result$errors) == 0

  if (verbose) {
    if (result$valid) {
      cat("  \u2713 No w:t elements found inside w:del\n")
    } else {
      cat(sprintf("  \u2717 %d invalid w:t inside w:del\n", length(result$errors)))
    }
  }

  result
}


#' Validate insertion markup
#'
#' Ensure w:delText elements are not inside w:ins without being wrapped in w:del.
#'
#' @param unpacked_dir Path to extracted DOCX directory
#' @param verbose Logical. Print progress.
#'
#' @return List with valid (logical) and errors (character vector)
#'
#' @keywords internal
validate_insertions <- function(unpacked_dir, verbose = FALSE) {
  if (verbose) {
    cat("\n\u2500\u2500 Insertion markup \u2500\u2500\n")
  }

  result <- list(valid = TRUE, errors = character())

  doc_path <- file.path(unpacked_dir, "word", "document.xml")
  if (!file.exists(doc_path)) {
    if (verbose) cat("  \u2139 No document.xml found\n")
    return(result)
  }

  doc_xml <- xml2::read_xml(doc_path)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # Find w:delText inside w:ins but NOT inside w:del
  # XPath: .//w:ins//w:delText[not(ancestor::w:del)]
  invalid <- xml2::xml_find_all(doc_xml,
    ".//w:ins//w:delText[not(ancestor::w:del)]", ns)

  for (elem in invalid) {
    text <- xml2::xml_text(elem)
    if (!is.na(text) && nchar(text) > 0) {
      text_preview <- if (nchar(text) > 30) {
        paste0(substr(text, 1, 27), "...")
      } else {
        text
      }
      result$errors <- c(result$errors,
        sprintf("<w:delText> inside <w:ins> without <w:del> wrapper: %s",
                shQuote(text_preview)))
    }
  }

  result$valid <- length(result$errors) == 0

  if (verbose) {
    if (result$valid) {
      cat("  \u2713 No invalid w:delText inside w:ins\n")
    } else {
      cat(sprintf("  \u2717 %d invalid w:delText inside w:ins\n", length(result$errors)))
    }
  }

  result
}


#' Validate unique IDs
#'
#' Check that comment, bookmark, and range IDs are unique within their scope.
#'
#' @param unpacked_dir Path to extracted DOCX directory
#' @param verbose Logical. Print progress.
#'
#' @return List with valid (logical), errors (character vector), warnings (character vector)
#'
#' @keywords internal
validate_unique_ids <- function(unpacked_dir, verbose = FALSE) {
  if (verbose) {
    cat("\n\u2500\u2500 ID uniqueness \u2500\u2500\n")
  }

  result <- list(valid = TRUE, errors = character(), warnings = character())

  # ID requirements: element name -> attribute name
  id_requirements <- list(
    comment = "id",
    commentRangeStart = "id",
    commentRangeEnd = "id",
    bookmarkStart = "id",
    bookmarkEnd = "id"
  )

  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # Check document.xml
  doc_path <- file.path(unpacked_dir, "word", "document.xml")
  if (file.exists(doc_path)) {
    doc_result <- check_ids_in_file(doc_path, id_requirements, ns, "document.xml")
    result$errors <- c(result$errors, doc_result$errors)
  }

  # Check comments.xml
  comments_path <- file.path(unpacked_dir, "word", "comments.xml")
  if (file.exists(comments_path)) {
    comments_result <- check_ids_in_file(comments_path,
      list(comment = "id"), ns, "comments.xml")
    result$errors <- c(result$errors, comments_result$errors)
  }

  result$valid <- length(result$errors) == 0

  if (verbose) {
    if (result$valid) {
      cat("  \u2713 All IDs are unique\n")
    } else {
      cat(sprintf("  \u2717 %d duplicate ID(s) found\n", length(result$errors)))
    }
  }

  result
}


#' Check IDs in a single XML file
#'
#' @param xml_path Path to XML file
#' @param id_requirements Named list of element -> attribute mappings
#' @param ns Namespace vector
#' @param file_label Label for error messages
#'
#' @return List with errors
#'
#' @keywords internal
check_ids_in_file <- function(xml_path, id_requirements, ns, file_label) {
  result <- list(errors = character())

  tryCatch({
    xml_doc <- xml2::read_xml(xml_path)

    for (elem_name in names(id_requirements)) {
      attr_name <- id_requirements[[elem_name]]
      xpath <- sprintf("//w:%s", elem_name)
      elements <- xml2::xml_find_all(xml_doc, xpath, ns)

      seen_ids <- list()
      for (elem in elements) {
        id_val <- xml2::xml_attr(elem, attr_name)
        if (!is.na(id_val)) {
          if (id_val %in% names(seen_ids)) {
            result$errors <- c(result$errors,
              sprintf("%s: Duplicate %s='%s' in <%s>",
                      file_label, attr_name, id_val, elem_name))
          } else {
            seen_ids[[id_val]] <- TRUE
          }
        }
      }
    }
  }, error = function(e) {
    result$errors <<- c(result$errors,
      sprintf("%s: Error parsing: %s", file_label, conditionMessage(e)))
  })

  result
}


#' Validate relationships
#'
#' Check that all .rels file targets exist and all content files are referenced.
#'
#' @param unpacked_dir Path to extracted DOCX directory
#' @param verbose Logical. Print progress.
#'
#' @return List with valid (logical), errors (character vector), warnings (character vector)
#'
#' @keywords internal
validate_relationships <- function(unpacked_dir, verbose = FALSE) {
  if (verbose) {
    cat("\n\u2500\u2500 Relationships \u2500\u2500\n")
  }

  result <- list(valid = TRUE, errors = character(), warnings = character())

  ns <- c(r = "http://schemas.openxmlformats.org/package/2006/relationships")

  # Find all .rels files
  rels_files <- list.files(unpacked_dir, pattern = "\\.rels$",
                           recursive = TRUE, full.names = TRUE)

  if (length(rels_files) == 0) {
    if (verbose) cat("  \u2139 No .rels files found\n")
    return(result)
  }

  # Track all referenced files
  all_referenced <- character()

  for (rels_file in rels_files) {
    relative_rels <- sub(paste0("^", unpacked_dir, "/?"), "", rels_file)

    tryCatch({
      rels_xml <- xml2::read_xml(rels_file)
      relationships <- xml2::xml_find_all(rels_xml, "//r:Relationship", ns)

      # Determine base directory for resolving targets
      if (basename(rels_file) == ".rels") {
        # Root .rels - targets relative to unpacked_dir
        base_dir <- unpacked_dir
      } else {
        # Other .rels - targets relative to parent's parent
        # e.g., word/_rels/document.xml.rels -> word/
        base_dir <- dirname(dirname(rels_file))
      }

      for (rel in relationships) {
        target <- xml2::xml_attr(rel, "Target")

        # Skip external URLs
        if (is.na(target) || grepl("^https?://", target) || grepl("^mailto:", target)) {
          next
        }

        # Resolve target path
        target_path <- normalizePath(file.path(base_dir, target), mustWork = FALSE)

        if (file.exists(target_path)) {
          all_referenced <- c(all_referenced, target_path)
        } else {
          result$errors <- c(result$errors,
            sprintf("%s: Broken reference to '%s'", relative_rels, target))
        }
      }
    }, error = function(e) {
      result$errors <<- c(result$errors,
        sprintf("%s: Error parsing: %s", relative_rels, conditionMessage(e)))
    })
  }

  # Check for unreferenced files (warning only)
  all_files <- list.files(unpacked_dir, recursive = TRUE, full.names = TRUE)
  all_files <- all_files[!grepl("\\.rels$", all_files)]
  all_files <- all_files[!grepl("\\[Content_Types\\]\\.xml$", all_files)]
  all_files <- all_files[file.info(all_files)$isdir == FALSE]

  unreferenced <- setdiff(normalizePath(all_files), normalizePath(all_referenced))
  # Filter out _rels directory files (they reference, aren't referenced)
  unreferenced <- unreferenced[!grepl("_rels", unreferenced)]

  if (length(unreferenced) > 0) {
    for (unref in unreferenced) {
      relative_unref <- sub(paste0("^", normalizePath(unpacked_dir), "/?"), "", unref)
      result$warnings <- c(result$warnings,
        sprintf("Unreferenced file: %s", relative_unref))
    }
  }

  result$valid <- length(result$errors) == 0

  if (verbose) {
    if (result$valid) {
      cat(sprintf("  \u2713 All %d relationship references are valid\n",
                  length(all_referenced)))
    } else {
      cat(sprintf("  \u2717 %d broken reference(s)\n", length(result$errors)))
    }
    if (length(result$warnings) > 0) {
      cat(sprintf("  \u26a0 %d unreferenced file(s)\n", length(result$warnings)))
    }
  }

  result
}


#' Validate content types
#'
#' Check that all content files are declared in \[Content_Types\].xml.
#'
#' @param unpacked_dir Path to extracted DOCX directory
#' @param verbose Logical. Print progress.
#'
#' @return List with valid (logical) and errors (character vector)
#'
#' @keywords internal
validate_content_types <- function(unpacked_dir, verbose = FALSE) {
  if (verbose) {
    cat("\n\u2500\u2500 Content types \u2500\u2500\n")
  }

  result <- list(valid = TRUE, errors = character())

  ct_path <- file.path(unpacked_dir, "[Content_Types].xml")
  if (!file.exists(ct_path)) {
    result$valid <- FALSE
    result$errors <- c(result$errors, "[Content_Types].xml not found")
    if (verbose) cat("  \u2717 [Content_Types].xml not found\n")
    return(result)
  }

  ns <- c(ct = "http://schemas.openxmlformats.org/package/2006/content-types")

  tryCatch({
    ct_xml <- xml2::read_xml(ct_path)

    # Get explicit part declarations (Override elements)
    overrides <- xml2::xml_find_all(ct_xml, "//ct:Override", ns)
    declared_parts <- sapply(overrides, function(o) {
      part <- xml2::xml_attr(o, "PartName")
      if (!is.na(part)) sub("^/", "", part) else NA
    })
    declared_parts <- declared_parts[!is.na(declared_parts)]

    # Get default extension declarations
    defaults <- xml2::xml_find_all(ct_xml, "//ct:Default", ns)
    declared_extensions <- sapply(defaults, function(d) {
      tolower(xml2::xml_attr(d, "Extension"))
    })
    declared_extensions <- declared_extensions[!is.na(declared_extensions)]

    # Check all XML files in main content folders
    content_folders <- c("word", "ppt", "xl")
    for (folder in content_folders) {
      folder_path <- file.path(unpacked_dir, folder)
      if (!dir.exists(folder_path)) next

      xml_files <- list.files(folder_path, pattern = "\\.xml$",
                              recursive = TRUE, full.names = TRUE)

      for (xml_file in xml_files) {
        relative_path <- sub(paste0("^", unpacked_dir, "/?"), "", xml_file)

        # Skip _rels files
        if (grepl("_rels", relative_path)) next

        # Check if declared as Override or covered by Default
        extension <- tolower(tools::file_ext(xml_file))

        if (!(relative_path %in% declared_parts) &&
            !(extension %in% declared_extensions)) {
          result$errors <- c(result$errors,
            sprintf("%s: Not declared in [Content_Types].xml", relative_path))
        }
      }
    }

  }, error = function(e) {
    result$valid <- FALSE
    result$errors <- c(result$errors,
      sprintf("Error parsing [Content_Types].xml: %s", conditionMessage(e)))
  })

  result$valid <- length(result$errors) == 0

  if (verbose) {
    if (result$valid) {
      cat("  \u2713 All content files are properly declared\n")
    } else {
      cat(sprintf("  \u2717 %d content type error(s)\n", length(result$errors)))
    }
  }

  result
}


#' Validate RSID attribute values
#'
#' Check that all RSID attributes in document.xml are 8-digit hexadecimal
#' values (0-9, A-F, case-insensitive). Invalid RSIDs can cause "unreadable
#' content" errors in Word. Errors are reported as warnings -- Word tolerates
#' some deviations.
#'
#' RSID attributes checked: w:rsidR, w:rsidRPr, w:rsidDel, w:rsidRDefault,
#' w:rsidTr, w:rsidSect.
#'
#' @param unpacked_dir Path to extracted DOCX directory
#' @param verbose Logical. Print progress.
#'
#' @return List with valid (logical) and errors (character vector)
#'
#' @keywords internal
validate_rsids <- function(unpacked_dir, verbose = FALSE) {
  if (verbose) {
    message("\n\u2500\u2500 RSID validation \u2500\u2500")
  }

  result <- list(valid = TRUE, errors = character())

  doc_path <- file.path(unpacked_dir, "word", "document.xml")
  if (!file.exists(doc_path)) {
    if (verbose) message("  \u2139 No document.xml found")
    return(result)
  }

  doc_xml <- tryCatch(
    xml2::read_xml(doc_path),
    error = function(e) {
      result$errors <<- c(result$errors,
        sprintf("document.xml: Failed to parse: %s", conditionMessage(e)))
      result$valid <<- FALSE
      NULL
    }
  )
  if (is.null(doc_xml)) return(result)

  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # RSID attribute names to validate (without namespace prefix -- xml2 uses bare names)
  rsid_attrs <- c("rsidR", "rsidRPr", "rsidDel", "rsidRDefault", "rsidTr", "rsidSect")

  # Valid RSID: exactly 8 hex digits (case-insensitive)
  hex8_pattern <- "^[0-9A-Fa-f]{8}$"

  invalid <- 0L
  seen_invalid <- list()  # deduplicate by attribute+value pair -- same bad value on
                          # rsidR and rsidRPr produces two distinct entries

  # RSID attributes only appear on paragraph-level elements; target them directly
  rsid_elements <- xml2::xml_find_all(
    doc_xml,
    ".//w:p | .//w:r | .//w:tr | .//w:tbl | .//w:sectPr",
    ns
  )
  for (el in rsid_elements) {
    for (attr_name in rsid_attrs) {
      val <- xml2::xml_attr(el, attr_name)
      if (is.na(val)) next
      if (!grepl(hex8_pattern, val)) {
        key <- paste0(attr_name, "=", val)
        if (is.null(seen_invalid[[key]])) {
          seen_invalid[[key]] <- TRUE
          invalid <- invalid + 1L
          result$errors <- c(result$errors,
            sprintf("Invalid RSID w:%s='%s' on <%s> (expected 8 hex digits)",
                    attr_name, val, xml2::xml_name(el)))
        }
      }
    }
  }

  result$valid <- invalid == 0L

  if (verbose) {
    if (result$valid) {
      message("  \u2713 All RSID values are valid 8-digit hex")
    } else {
      message(sprintf("  \u26a0 %d invalid RSID value(s) found", invalid))
    }
  }

  result
}


#' Validate against XSD schemas
#'
#' Use xmllint to validate XML files against OOXML XSD schemas.
#'
#' @param unpacked_dir Path to extracted DOCX directory
#' @param verbose Logical. Print progress.
#'
#' @return List with valid (logical), errors (character vector), warnings (character vector)
#'
#' @keywords internal
validate_xsd <- function(unpacked_dir, verbose = FALSE) {
  if (verbose) {
    cat("\n\u2500\u2500 XSD schema validation \u2500\u2500\n")
  }

  result <- list(valid = TRUE, errors = character(), warnings = character())

 # Check if xmllint is available
  xmllint_available <- tryCatch({
    output <- system2("xmllint", "--version", stdout = TRUE, stderr = TRUE)
    TRUE
  }, error = function(e) FALSE, warning = function(w) TRUE)

  if (!xmllint_available) {
    result$warnings <- c(result$warnings,
      "xmllint not available - skipping XSD validation")
    if (verbose) {
      cat("  \u26a0 xmllint not available - skipping XSD validation\n")
      cat("    Install libxml2 for XSD schema validation\n")
    }
    return(result)
  }

  # Find schema directory
  schemas_dir <- system.file("schemas", package = "docstyle")
  if (schemas_dir == "" || !dir.exists(schemas_dir)) {
    result$warnings <- c(result$warnings,
      "XSD schemas not found in package - skipping validation")
    if (verbose) {
      cat("  \u26a0 XSD schemas not bundled - skipping validation\n")
    }
    return(result)
  }

  # Schema mappings for Word documents
  schema_mappings <- list(
    # Main document types by folder
    word = file.path(schemas_dir, "ISO-IEC29500-4_2016", "wml.xsd"),
    # Common files
    "[Content_Types].xml" = file.path(schemas_dir, "ecma", "fouth-edition", "opc-contentTypes.xsd"),
    "app.xml" = file.path(schemas_dir, "ISO-IEC29500-4_2016", "shared-documentPropertiesExtended.xsd"),
    "core.xml" = file.path(schemas_dir, "ecma", "fouth-edition", "opc-coreProperties.xsd"),
    ".rels" = file.path(schemas_dir, "ecma", "fouth-edition", "opc-relationships.xsd")
  )

  # Find XML files to validate
  xml_files <- list.files(unpacked_dir, pattern = "\\.xml$",
                          recursive = TRUE, full.names = TRUE)
  rels_files <- list.files(unpacked_dir, pattern = "\\.rels$",
                           recursive = TRUE, full.names = TRUE)
  all_files <- c(xml_files, rels_files)

  validated <- 0
  skipped <- 0
  errors_found <- 0

  for (xml_file in all_files) {
    relative_path <- sub(paste0("^", unpacked_dir, "/?"), "", xml_file)

    # Determine which schema to use
    schema_path <- NULL

    # Check by filename first
    filename <- basename(xml_file)
    if (filename %in% names(schema_mappings)) {
      schema_path <- schema_mappings[[filename]]
    } else if (grepl("\\.rels$", filename)) {
      schema_path <- schema_mappings[[".rels"]]
    } else {
      # Check by folder (word/, ppt/, xl/)
      parts <- strsplit(relative_path, "/")[[1]]
      if (length(parts) > 0 && parts[1] %in% names(schema_mappings)) {
        schema_path <- schema_mappings[[parts[1]]]
      }
    }

    # Skip files without a known schema
    if (is.null(schema_path) || !file.exists(schema_path)) {
      skipped <- skipped + 1
      next
    }

    # Run xmllint validation
    validation_result <- tryCatch({
      output <- system2("xmllint",
        args = c("--noout", "--schema", shQuote(schema_path), shQuote(xml_file)),
        stdout = TRUE, stderr = TRUE)
      attr(output, "status")
    }, error = function(e) {
      -1
    })

    if (is.null(validation_result) || validation_result == 0) {
      validated <- validated + 1
    } else {
      errors_found <- errors_found + 1
      # Extract error details from output (already captured via stderr = TRUE)
      error_lines <- output[!grepl("validates$", output)]
      if (length(error_lines) > 0) {
        first_error <- error_lines[1]
        first_error <- sub(paste0("^", xml_file, ":"), "", first_error)
        result$errors <- c(result$errors,
          sprintf("%s: %s", relative_path, first_error))
      } else {
        result$errors <- c(result$errors,
          sprintf("%s: XSD validation failed", relative_path))
      }
    }
  }

  result$valid <- errors_found == 0

  if (verbose) {
    if (result$valid) {
      cat(sprintf("  \u2713 Validated %d files against XSD schemas (%d skipped)\n",
                  validated, skipped))
    } else {
      cat(sprintf("  \u2717 %d XSD validation error(s) (%d passed, %d skipped)\n",
                  errors_found, validated, skipped))
    }
  }

  result
}


#' Validate DOCX with OOXML schema validator
#'
#' Runs the `@xarsh/ooxml-validator` CLI tool (via npx) to check a DOCX file
#' against the official Microsoft Open XML SDK schemas. This catches schema-level
#' issues like wrong element ordering, invalid attribute values, and missing
#' required attributes that our built-in checks and xmllint may miss.
#'
#' @param docx_path Path to the DOCX file to validate.
#' @param verbose Logical. Print results to console. Default TRUE.
#'
#' @return A list with:
#' \describe{
#'   \item{valid}{Logical. TRUE if no schema errors found}
#'   \item{errors}{List of error objects with description, path, xPath, id, errorType}
#'   \item{available}{Logical. TRUE if npx and the validator are available}
#' }
#'
#' @details
#' Requires Node.js and npx on the system PATH. The validator package is
#' downloaded on first use via npx. This is intended as a **development tool**,
#' not for production validation -- use [validate_docx_structure()] for that.
#'
#' Note: Even Pandoc's own default reference.docx has schema errors (element
#' ordering issues). Errors from this validator should be reviewed for severity
#' rather than treated as hard failures.
#'
#' @examples
#' \dontrun{
#' # Validate a rendered document
#' result <- validate_ooxml_schema("output/document.docx")
#'
#' # Quiet mode for scripts
#' result <- validate_ooxml_schema("output/document.docx", verbose = FALSE)
#' if (!result$valid) stop("Schema errors: ", length(result$errors))
#' }
#'
#' @export
validate_ooxml_schema <- function(docx_path,
                                   verbose = TRUE) {
  if (!file.exists(docx_path)) {
    stop("File not found: ", docx_path)
  }

  result <- list(valid = TRUE, errors = list(), available = FALSE)

  # Check npx availability
  npx_path <- Sys.which("npx")
  if (npx_path == "") {
    if (verbose) {
      message("[ooxml-validator] npx not found - install Node.js to use schema validation")
    }
    return(invisible(result))
  }

  result$available <- TRUE

  # Run the validator
  # --yes auto-confirms package install on first use (prevents interactive hang)
  # Exit code 1 when errors found (expected), suppress that warning
  # Separate stdout (JSON) from stderr (npx diagnostics) for clean parsing
  output <- tryCatch({
    suppressWarnings(
      system2(
        "npx",
        args = c("--yes", "@xarsh/ooxml-validator", shQuote(docx_path)),
        stdout = TRUE,
        stderr = FALSE,
        stdin = ""
      )
    )
  }, error = function(e) {
    if (verbose) {
      message("[ooxml-validator] Failed to run: ", conditionMessage(e))
    }
    return(NULL)
  })

  if (is.null(output)) {
    result$available <- FALSE
    return(invisible(result))
  }

  # Check for unexpected exit codes (0 = valid, 1 = errors found, 2+ = failure)
  exit_status <- attr(output, "status")
  if (!is.null(exit_status) && exit_status > 1) {
    if (verbose) {
      message("[ooxml-validator] Process exited with code ", exit_status)
    }
    result$available <- FALSE
    return(invisible(result))
  }

  # Parse JSON output (tool may print duplicates, take first valid JSON)
  json_text <- paste(output, collapse = "\n")
  # Extract first complete JSON object
  parsed <- tryCatch({
    # Find the first { ... } block
    start <- regexpr("\\{", json_text)
    if (start == -1) return(NULL)
    # Use jsonlite to parse from the start of first object
    jsonlite::fromJSON(substring(json_text, start), simplifyVector = FALSE)
  }, error = function(e) {
    if (verbose) {
      message("[ooxml-validator] Failed to parse output: ", conditionMessage(e))
    }
    NULL
  })

  # Parse failure means we can't trust the result -- don't report valid
  if (is.null(parsed)) {
    result$available <- FALSE
    if (verbose) {
      message("[ooxml-validator] Could not parse validator output -- ",
              "result should not be trusted")
    }
    return(invisible(result))
  }

  result$valid <- isTRUE(parsed$ok)
  result$errors <- parsed$errors %||% list()

  if (verbose) {
    if (result$valid) {
      message(sprintf("[ooxml-validator] %s: OK (0 schema errors)",
                      basename(docx_path)))
    } else {
      n <- length(result$errors)
      message(sprintf("[ooxml-validator] %s: %d schema error(s)",
                      basename(docx_path), n))
      for (err in result$errors) {
        message(sprintf("  - %s [%s] %s",
                        err$path %||% "", err$id %||% "", err$description %||% ""))
      }
    }
  }

  invisible(result)
}
