#' Apply Formal List Styles to Rendered DOCX
#'
#' Post-processes a rendered Word document to apply formal list numbering.
#' Changes Pandoc's default all-decimal numbered lists to use hierarchical
#' formatting: 1. / a. / i. for levels 0/1/2.
#'
#' @param docx_path Path to the DOCX file to modify.
#' @param style Character. The list style to apply:
#'   - `"formal"`: 1. / a. / i. (decimal, lowerLetter, lowerRoman)
#'   - `"none"`: No modification (default)
#'
#' @return The path (invisibly), file is modified in place.
#'
#' @details
#' Pandoc generates all numbered lists with decimal format at every level.
#' This function modifies the `numbering.xml` inside the DOCX to use:
#'
#' - Level 0: `decimal` (1. 2. 3.)
#' - Level 1: `lowerLetter` (a. b. c.)
#' - Level 2: `lowerRoman` (i. ii. iii.)
#'
#' This is commonly used for formal documents like terms of reference,
#' procedures, and legal documents.
#'
#' @examples
#' \dontrun{
#' # After rendering with Quarto:
#' # quarto render document.qmd
#'
#' # Apply formal list style
#' apply_list_style("document.docx", style = "formal")
#' }
#'
#' @keywords internal
#' @export
apply_list_style <- function(docx_path, style = "none") {
  .Deprecated(
    msg = paste0(
      "apply_list_style() is deprecated. ",
      "Use CSS list classes (e.g., ::: {.list-formal}) in QMD instead. ",
      "The list-style.lua filter handles numbering format during rendering. ",
      "See dev/spec-list-style-roundtrip.md for migration details."
    )
  )

  if (style == "none") {
    return(invisible(docx_path))
  }

  if (!file.exists(docx_path)) {
    stop("File not found: ", docx_path)
  }

  if (style == "formal") {
    apply_formal_list_style(docx_path)
  } else {
    warning("Unknown list style '", style, "', no changes made")
  }

  invisible(docx_path)
}


#' Apply Formal List Style (Internal)
#'
#' Modifies numbering.xml to use 1./a./i. format for numbered lists.
#'
#' @param docx_path Path to the DOCX file
#' @return The path (invisibly)
#' @keywords internal
apply_formal_list_style <- function(docx_path) {
  # Extract the docx

  temp_dir <- tempfile("docx_list_")
  dir.create(temp_dir)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  utils::unzip(docx_path, exdir = temp_dir)

  # Read numbering.xml
  numbering_path <- file.path(temp_dir, "word", "numbering.xml")
  if (!file.exists(numbering_path)) {
    message("No numbering.xml found - document has no lists")
    return(invisible(docx_path))
  }

  numbering_xml <- xml2::read_xml(numbering_path)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # Find all abstract numbering definitions
  abstract_nums <- xml2::xml_find_all(numbering_xml, "//w:abstractNum", ns)

  modified <- FALSE
  for (abstract_num in abstract_nums) {
    abstract_id <- xml2::xml_attr(abstract_num, "abstractNumId")

    # Check if this is a numbered list (has decimal format at level 0)
    lvl0 <- xml2::xml_find_first(abstract_num, "w:lvl[@w:ilvl='0']", ns)
    if (inherits(lvl0, "xml_missing")) next

    numFmt0 <- xml2::xml_find_first(lvl0, "w:numFmt", ns)
    if (inherits(numFmt0, "xml_missing")) next

    if (xml2::xml_attr(numFmt0, "val") == "decimal") {
      # This is a numbered list - apply formal style

      # Level 1: lowerLetter
      lvl1 <- xml2::xml_find_first(abstract_num, "w:lvl[@w:ilvl='1']", ns)
      if (!inherits(lvl1, "xml_missing")) {
        numFmt1 <- xml2::xml_find_first(lvl1, "w:numFmt", ns)
        if (!inherits(numFmt1, "xml_missing")) {
          xml2::xml_set_attr(numFmt1, "w:val", "lowerLetter")
          modified <- TRUE
        }
      }

      # Level 2: lowerRoman
      lvl2 <- xml2::xml_find_first(abstract_num, "w:lvl[@w:ilvl='2']", ns)
      if (!inherits(lvl2, "xml_missing")) {
        numFmt2 <- xml2::xml_find_first(lvl2, "w:numFmt", ns)
        if (!inherits(numFmt2, "xml_missing")) {
          xml2::xml_set_attr(numFmt2, "w:val", "lowerRoman")
          modified <- TRUE
        }
      }
    }
  }

  if (modified) {
    # Write back the modified XML
    xml2::write_xml(numbering_xml, numbering_path)

    # Repackage the docx using zip command (more reliable for DOCX structure)
    docx_path_abs <- normalizePath(docx_path, mustWork = FALSE)
    file.remove(docx_path_abs)

    # Get all files including hidden ones, with proper relative paths
    old_wd <- getwd()
    setwd(temp_dir)

    # Use system zip for proper DOCX structure (no compression path issues)
    all_files <- list.files(".", recursive = TRUE, all.files = TRUE, no.. = TRUE)
    # Filter out any .DS_Store or other unwanted files
    all_files <- all_files[!grepl("^\\.DS_Store$|\\.DS_Store$", all_files)]

    result <- utils::zip(docx_path_abs, files = all_files, flags = "-q")
    setwd(old_wd)

    if (result != 0) {
      warning("zip command returned non-zero status: ", result)
    }

    message("Applied formal list style (1./a./i.) to: ", basename(docx_path))
  }

  invisible(docx_path)
}
