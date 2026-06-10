#' Inject Title Page Metadata into Rendered DOCX
#'
#' Reads author, date, and version metadata from YAML front matter and injects
#' styled paragraphs into the rendered Word document after the Title/Subtitle.
#' This enables round-trip workflows where rich metadata (ORCID, affiliations)
#' survives as styled display text in Word.
#'
#' @param docx_path Path to the rendered .docx file to modify.
#' @param yaml_metadata Named list containing author, affiliations, date, version.
#'   Usually extracted from QMD YAML front matter.
#' @param author_format Format for author display. One of:
#'   - "name_degrees" (default): "Jane Smith, PhD MPH"
#'   - "name_only": "Jane Smith"
#'   - "name_affiliation": "Jane Smith (University of Ottawa)"
#'
#' @return Invisibly returns the docx_path.
#'
#' @details
#' The metadata is injected using custom Word styles (Author, Affiliation, Date,
#' Version) that should be defined in the reference.docx via CSS. The function
#' inserts paragraphs in this order after Title/Subtitle:
#'
#' 1. Date (if present)
#' 2. Version (if present, formatted as "Version X.Y.Z")
#' 3. Each author (with affiliations if present)
#'
#' ## YAML metadata schema
#'
#' The function expects Quarto-compatible author metadata:
#'
#' ```yaml
#' author:
#'   - name: "Jane Smith"
#'     degrees: [PhD, MPH]
#'     affiliation:
#'       - ref: uottawa
#' affiliations:
#'   - id: uottawa
#'     name: "University of Ottawa"
#' date: "2025-01-15"
#' version: "1.0.0"
#' ```
#'
#' @examples
#' \dontrun{
#' # Read YAML from QMD
#' yaml_meta <- yaml::yaml.load_file("paper.qmd")
#'
#' # Inject into rendered document
#' inject_title_page_metadata("output/paper.docx", yaml_meta)
#' }
#'
#' @seealso [inject_version_history_table()] for version history at document end
#' @keywords internal
#' @export
inject_title_page_metadata <- function(docx_path,
                                       yaml_metadata,
                                       author_format = c("name_degrees", "name_only", "name_affiliation")) {

  author_format <- match.arg(author_format)

  if (!file.exists(docx_path)) {
    stop("DOCX file not found: ", docx_path)
  }


  # Extract metadata - check both top-level and docstyle section

  # docstyle section takes priority to avoid Pandoc's native title block rendering
  docstyle <- yaml_metadata$docstyle

  # Authors: Skip if they're in docstyle.authors (handled by author-plate Lua filter)
  # Only inject if using simple top-level author: format
  authors <- if (is.null(docstyle$authors)) yaml_metadata$author else NULL
  affiliations <- if (is.null(docstyle$affiliations)) yaml_metadata$affiliations else NULL

  # Date: prefer docstyle.date over date
  doc_date <- docstyle$date %||% yaml_metadata$date

  # Version: prefer docstyle.version over version
  doc_version <- docstyle$version %||% yaml_metadata$version

  # Check if there's anything to inject
  if (is.null(authors) && is.null(doc_date) && is.null(doc_version)) {
    message("No metadata to inject (no author, date, or version found)")
    return(invisible(docx_path))
  }

  # Extract DOCX
  temp_dir <- tempfile("inject_metadata_")
  dir.create(temp_dir)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  utils::unzip(docx_path, exdir = temp_dir)

  # Read document.xml
  doc_xml_path <- file.path(temp_dir, "word", "document.xml")
  if (!file.exists(doc_xml_path)) {
    stop("Invalid DOCX structure: word/document.xml not found")
  }

  doc_xml <- xml2::read_xml(doc_xml_path)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # Find the Title or Subtitle paragraph to insert after
  # Look for paragraphs with Title or Subtitle style
  insert_after <- NULL

  # First try Subtitle
  subtitle_paras <- xml2::xml_find_all(
    doc_xml,
    "//w:p[w:pPr/w:pStyle[@w:val='Subtitle']]",
    ns
  )
  if (length(subtitle_paras) > 0) {
    insert_after <- subtitle_paras[[length(subtitle_paras)]]  # Use last subtitle
  }

  # If no subtitle, try Title
  if (is.null(insert_after)) {
    title_paras <- xml2::xml_find_all(
      doc_xml,
      "//w:p[w:pPr/w:pStyle[@w:val='Title']]",
      ns
    )
    if (length(title_paras) > 0) {
      insert_after <- title_paras[[length(title_paras)]]
    }
  }

  # If neither found, insert at beginning of body
  if (is.null(insert_after)) {
    body <- xml2::xml_find_first(doc_xml, "//w:body", ns)
    first_para <- xml2::xml_find_first(body, "w:p", ns)
    if (!inherits(first_para, "xml_missing")) {
      # Insert before the first paragraph
      insert_after <- NULL
      insert_before <- first_para
    } else {
      message("No paragraphs found in document body")
      return(invisible(docx_path))
    }
  }

  # Build paragraphs to insert (in reverse order since we're inserting after)
  paragraphs_to_insert <- list()

  # Build author paragraphs
  if (!is.null(authors)) {
    # Build affiliations lookup
    aff_lookup <- list()
    if (!is.null(affiliations)) {
      for (aff in affiliations) {
        if (!is.null(aff$id)) {
          aff_lookup[[aff$id]] <- aff
        }
      }
    }

    # Handle both single author and list of authors
    if (!is.list(authors) || !is.null(authors$name)) {
      # Single author object
      authors <- list(authors)
    }

    for (author in rev(authors)) {
      # Format author name based on format preference
      author_text <- format_author_display(author, aff_lookup, author_format)

      # Add author paragraph
      paragraphs_to_insert <- c(paragraphs_to_insert, list(
        build_styled_paragraph(author_text, "Author")
      ))

      # Add affiliations if using separate affiliation lines
      if (author_format != "name_affiliation" && !is.null(author$affiliation)) {
        aff_refs <- author$affiliation
        if (!is.list(aff_refs)) aff_refs <- list(aff_refs)

        for (aff_ref in rev(aff_refs)) {
          aff_id <- if (is.list(aff_ref)) aff_ref$ref else aff_ref
          if (!is.null(aff_id) && !is.null(aff_lookup[[aff_id]])) {
            aff_data <- aff_lookup[[aff_id]]
            aff_text <- format_affiliation_display(aff_data)
            paragraphs_to_insert <- c(paragraphs_to_insert, list(
              build_styled_paragraph(aff_text, "Affiliation")
            ))
          }
        }
      }
    }
  }

  # Build version paragraph
  if (!is.null(doc_version)) {
    version_text <- paste("Version", doc_version)
    paragraphs_to_insert <- c(paragraphs_to_insert, list(
      build_styled_paragraph(version_text, "Version")
    ))
  }

  # Build date paragraph
  if (!is.null(doc_date)) {
    paragraphs_to_insert <- c(paragraphs_to_insert, list(
      build_styled_paragraph(as.character(doc_date), "Date")
    ))
  }

  # Insert paragraphs
  if (length(paragraphs_to_insert) > 0) {
    for (para_xml_str in paragraphs_to_insert) {
      para_node <- xml2::read_xml(para_xml_str)

      if (!is.null(insert_after)) {
        xml2::xml_add_sibling(insert_after, para_node, .where = "after")
      } else if (exists("insert_before") && !is.null(insert_before)) {
        xml2::xml_add_sibling(insert_before, para_node, .where = "before")
      }
    }
  }

  # Write back document.xml
  xml2::write_xml(doc_xml, doc_xml_path)

  # Repack DOCX
  repack_docx(temp_dir, docx_path)

  n_items <- length(paragraphs_to_insert)
  message(sprintf("Injected %d metadata paragraph(s) into %s", n_items, basename(docx_path)))

  invisible(docx_path)
}


#' Build a Styled Paragraph XML String
#'
#' Creates OpenXML for a paragraph with a specific Word style.
#'
#' @param text Text content of the paragraph.
#' @param style_id Word style ID (e.g., "Author", "Date", "Version").
#'
#' @return Character string containing the paragraph XML.
#' @keywords internal
build_styled_paragraph <- function(text, style_id) {
  sprintf(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:pPr>
    <w:pStyle w:val="%s"/>
  </w:pPr>
  <w:r>
    <w:t>%s</w:t>
  </w:r>
</w:p>',
    xml_escape_attr(style_id),
    xml_escape(text)
  )
}


#' Format Author Display Text
#'
#' Formats an author object for display based on the specified format.
#'
#' @param author Author object with name, degrees, etc.
#' @param aff_lookup Named list of affiliations keyed by ID.
#' @param format One of "name_degrees", "name_only", "name_affiliation".
#'
#' @return Formatted author display string.
#' @keywords internal
format_author_display <- function(author, aff_lookup, format) {
  # Get name
  name <- if (is.list(author)) {
    author$name %||% "Unknown"
  } else {
    as.character(author)
  }

  if (format == "name_only") {
    return(name)
  }

  if (format == "name_degrees") {
    degrees <- author$degrees
    if (!is.null(degrees)) {
      if (is.list(degrees)) degrees <- unlist(degrees)
      return(paste(name, paste(degrees, collapse = ", "), sep = ", "))
    }
    return(name)
  }

  if (format == "name_affiliation") {
    aff_refs <- author$affiliation
    if (!is.null(aff_refs)) {
      if (!is.list(aff_refs)) aff_refs <- list(aff_refs)
      aff_names <- character()
      for (aff_ref in aff_refs) {
        aff_id <- if (is.list(aff_ref)) aff_ref$ref else aff_ref
        if (!is.null(aff_id) && !is.null(aff_lookup[[aff_id]])) {
          aff_names <- c(aff_names, aff_lookup[[aff_id]]$name %||% "")
        }
      }
      if (length(aff_names) > 0) {
        return(paste0(name, " (", paste(aff_names, collapse = "; "), ")"))
      }
    }
    return(name)
  }

  name
}


#' Format Affiliation Display Text
#'
#' Formats an affiliation object for display.
#'
#' @param aff Affiliation object with name, department, city, country.
#'
#' @return Formatted affiliation display string.
#' @keywords internal
format_affiliation_display <- function(aff) {
  parts <- character()

  if (!is.null(aff$department)) {
    parts <- c(parts, aff$department)
  }

  if (!is.null(aff$name)) {
    parts <- c(parts, aff$name)
  }

  if (!is.null(aff$city)) {
    parts <- c(parts, aff$city)
  }

  if (!is.null(aff$country)) {
    parts <- c(parts, aff$country)
  }

  paste(parts, collapse = ", ")
}


#' Inject Version History Table into Rendered DOCX
#'
#' Reads version-history metadata from YAML front matter and injects a
#' formatted table at the end of the rendered Word document.
#'
#' @param docx_path Path to the rendered .docx file to modify.
#' @param version_history List of version history entries from YAML.
#'   Each entry should have version, date, and description fields.
#' @param table_style Style for the table. Default is "table-grid" which
#'   provides full borders.
#'
#' @return Invisibly returns the docx_path.
#'
#' @details
#' The version history table has three columns: Version, Description, Date.
#' Entries are displayed in the order provided (typically newest first).
#'
#' ## YAML metadata schema
#'
#' ```yaml
#' version-history:
#'   - version: "1.0.0"
#'     date: "2025-01-15"
#'     description: "Final release"
#'   - version: "0.9.0"
#'     date: "2025-01-01"
#'     description: "Initial draft"
#' ```
#'
#' @examples
#' \dontrun{
#' # Read YAML from QMD
#' yaml_meta <- yaml::yaml.load_file("paper.qmd")
#'
#' # Inject version history table
#' inject_version_history_table(
#'   "output/paper.docx",
#'   yaml_meta$`version-history`
#' )
#' }
#'
#' @seealso [inject_title_page_metadata()] for title page metadata
#' @keywords internal
#' @export
inject_version_history_table <- function(docx_path,
                                         version_history,
                                         table_style = "table-grid") {

  if (!file.exists(docx_path)) {
    stop("DOCX file not found: ", docx_path)
  }

  if (is.null(version_history) || length(version_history) == 0) {
    message("No version history to inject")
    return(invisible(docx_path))
  }

  # Extract DOCX
  temp_dir <- tempfile("inject_version_history_")
  dir.create(temp_dir)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  utils::unzip(docx_path, exdir = temp_dir)

  # Read document.xml
  doc_xml_path <- file.path(temp_dir, "word", "document.xml")
  if (!file.exists(doc_xml_path)) {
    stop("Invalid DOCX structure: word/document.xml not found")
  }

  doc_xml <- xml2::read_xml(doc_xml_path)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # Find the body element

  body <- xml2::xml_find_first(doc_xml, "//w:body", ns)
  if (inherits(body, "xml_missing")) {
    stop("No body element found in document")
  }

  # Build the version history table
  table_xml_str <- build_version_history_table_xml(version_history)
  table_node <- xml2::read_xml(table_xml_str)

  # Add a heading paragraph before the table
  heading_xml <- build_styled_paragraph("Version history", "Heading1")
  heading_node <- xml2::read_xml(heading_xml)

  # Find the last element before sectPr (section properties)
  sect_pr <- xml2::xml_find_first(body, "w:sectPr", ns)

  if (!inherits(sect_pr, "xml_missing")) {
    # Insert before sectPr
    xml2::xml_add_sibling(sect_pr, heading_node, .where = "before")
    xml2::xml_add_sibling(sect_pr, table_node, .where = "before")
  } else {
    # Append to end of body
    xml2::xml_add_child(body, heading_node)
    xml2::xml_add_child(body, table_node)
  }

  # Write back document.xml
  xml2::write_xml(doc_xml, doc_xml_path)

  # Repack DOCX
  repack_docx(temp_dir, docx_path)

  message(sprintf(
    "Injected version history table (%d entries) into %s",
    length(version_history),
    basename(docx_path)
  ))

  invisible(docx_path)
}


#' Build Version History Table XML
#'
#' Creates OpenXML for a version history table with Version, Description, Date columns.
#'
#' @param version_history List of version history entries.
#'
#' @return Character string containing the table XML.
#' @keywords internal
build_version_history_table_xml <- function(version_history) {
  # Table header row
  header_cells <- c(
    build_table_cell("Version", bold = TRUE),
    build_table_cell("Description", bold = TRUE),
    build_table_cell("Date", bold = TRUE)
  )
  header_row <- sprintf("<w:tr>%s</w:tr>", paste(header_cells, collapse = "\n"))

  # Data rows
  data_rows <- character()
  for (entry in version_history) {
    version <- entry$version %||% ""
    description <- entry$description %||% ""
    date <- if (!is.null(entry$date)) as.character(entry$date) else ""

    cells <- c(
      build_table_cell(version),
      build_table_cell(description),
      build_table_cell(date)
    )
    data_rows <- c(data_rows, sprintf("<w:tr>%s</w:tr>", paste(cells, collapse = "\n")))
  }

  # Complete table with borders
  sprintf(
    '<w:tbl xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:tblPr>
    <w:tblBorders>
      <w:top w:val="single" w:sz="4" w:space="0" w:color="000000"/>
      <w:left w:val="single" w:sz="4" w:space="0" w:color="000000"/>
      <w:bottom w:val="single" w:sz="4" w:space="0" w:color="000000"/>
      <w:right w:val="single" w:sz="4" w:space="0" w:color="000000"/>
      <w:insideH w:val="single" w:sz="4" w:space="0" w:color="000000"/>
      <w:insideV w:val="single" w:sz="4" w:space="0" w:color="000000"/>
    </w:tblBorders>
  </w:tblPr>
  %s
  %s
</w:tbl>',
    header_row,
    paste(data_rows, collapse = "\n")
  )
}


#' Build a Table Cell XML
#'
#' @param text Cell text content.
#' @param bold Whether to make the text bold.
#'
#' @return Character string containing the cell XML.
#' @keywords internal
build_table_cell <- function(text, bold = FALSE) {
  rPr <- if (bold) "<w:rPr><w:b/></w:rPr>" else ""

  sprintf(
    '<w:tc>
  <w:p>
    <w:r>
      %s
      <w:t>%s</w:t>
    </w:r>
  </w:p>
</w:tc>',
    rPr,
    xml_escape(text)
  )
}


#' Null-coalescing operator
#'
