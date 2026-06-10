#' Extract Word Document to Quarto Markdown
#'
#' Converts a .docx file to .qmd format, preserving structure and styles.
#' Automatically extracts Zotero citations and converts them to Quarto format.
#'
#' @param docx_path Path to the input .docx file
#' @param output_path Path for the output .qmd file (default: same name with .qmd extension)
#' @param sidecar_dir Directory for sidecar files (field-codes.json, references.json).
#'   Default: "_docstyle" subdirectory in the output directory.
#' @param style Style name to use (e.g., "popcorn"). If provided, copies the reference
#'   document to the output directory and adds it to the YAML header.
#' @param extract_images Whether to extract embedded images (default: TRUE)
#' @param image_dir Directory for extracted images (default: "images")
#' @param validate_bib Optional path to a canonical BibTeX file to validate extracted citations against.
#' @param preserve_header If TRUE (default) and the output file already exists, preserves
#'   the existing YAML front matter. The old file is renamed to `*_old.qmd` as a backup.
#'   This allows re-harvesting from Word while keeping manually curated metadata (authors,
#'   affiliations, version info, etc.).
#' @param project Character. Controls project infrastructure setup:
#'   - `"none"` (default): Just QMD + sidecar files, no project setup
#'   - `"init"`: Create `_quarto.yml`, CSS, extension if missing; skip if exists
#'   - `"update"`: Create if missing; merge new settings/styles if exists (Stage 3)
#'   - `"overwrite"`: Always replace project config (destructive)
#' @param preset Character. Style preset to use when `project != "none"`. Can be:
#'   - A preset name: `"default"`, `"formal"`, or `"academic"`
#'   - A path to a custom preset folder containing `_quarto.yml` and `styles.css`
#' @param version_history Logical. If TRUE (default) and `project != "none"`, inserts
#'   a `::: version-history :::` placeholder and adds initial version entry to YAML.
#' @param extract_styles Logical. If TRUE and `project != "none"`, extracts font,
#'   colour, and page layout styles from the Word document and writes them to CSS.
#'   Default is FALSE. When TRUE, styles are appended to the project's CSS file.
#' @param validate Logical. If TRUE, runs \code{\link{validate_harvest}} after
#'   writing the QMD to check fidelity against the source. Also triggered by
#'   setting environment variable \code{DOCSTYLE_VALIDATE_HARVEST=1}.
#'
#' @return Invisibly returns the path to the created .qmd file
#' @export
docx_to_qmd <- function(docx_path,
                        output_path = NULL,
                        sidecar_dir = NULL,
                        style = NULL,
                        extract_images = TRUE,
                        image_dir = "images",
                        validate_bib = NULL,
                        preserve_header = TRUE,
                        project = c("none", "init", "update", "overwrite"),
                        preset = "default",
                        version_history = TRUE,
                        extract_styles = FALSE,
                        validate = FALSE) {

  if (!file.exists(docx_path)) {
    stop("File not found: ", docx_path)
  }

  # Validate project parameter

  project <- match.arg(project)

  # Default output path
  if (is.null(output_path)) {
    output_path <- sub("\\.docx$", ".qmd", docx_path, ignore.case = TRUE)
  }

  # Default sidecar directory (_docstyle/ in output directory)
  if (is.null(sidecar_dir)) {
    sidecar_dir <- file.path(dirname(output_path), "_docstyle")
  }

  # Handle header preservation for re-harvest workflow
  existing_header <- prepare_header_preservation(output_path, preserve_header)

  # Handle style reference document
  reference_doc <- NULL
  if (!is.null(style)) {
    reference_doc <- setup_reference_doc(style, dirname(output_path))
  }

  # Extract sidecar data (citations, comments, revisions)
  sidecar_result <- extract_sidecar_data(docx_path, sidecar_dir)

  # Validate citations against canonical bibliography if requested
  if (!is.null(validate_bib)) {
    validate_citations_against_bib(sidecar_result$citations, validate_bib)
  }

  # Read document using xml2 directly to avoid officer's docx_summary issues
  doc_xml <- extract_docx_content(docx_path)

  # Detect TOC in source document (Stage 2)
  has_toc <- detect_toc(doc_xml)

  # Convert to markdown, passing citation map for replacement
  # Bibliography path is relative from output file to _docstyle/references.json
  bib_rel_path <- if (length(sidecar_result$citations) > 0) {
    file.path("_docstyle", "references.json")
  } else {
    NULL
  }

  # Determine whether to add placeholders (only when setting up project)
  add_placeholders <- project != "none"

  qmd_content <- convert_to_qmd(
    doc_xml, docx_path, extract_images, image_dir,
    citation_map = sidecar_result$citation_map,
    citation_id_map = sidecar_result$citation_id_map,
    bib_path = bib_rel_path,
    reference_doc = reference_doc,
    existing_header = existing_header,
    insert_toc_placeholder = add_placeholders && has_toc,
    insert_version_history = add_placeholders && version_history,
    output_path = output_path
  )

  # Write output
  writeLines(qmd_content, output_path)
  message("Created: ", output_path)

  # Set up project infrastructure (Stage 1)
  if (project != "none") {
    setup_project_infrastructure(
      output_path = output_path,
      project = project,
      preset = preset
    )

    # Extract styles from Word document (Stage 4)
    if (extract_styles) {
      css_path <- file.path(dirname(output_path), "styles.css")
      write_extracted_styles(docx_path, css_path, append = TRUE)
    }
  }

  # Validate harvest fidelity if requested
  if (validate || Sys.getenv("DOCSTYLE_VALIDATE_HARVEST", "0") == "1") {
    tryCatch({
      validation <- validate_harvest(
        docx_path = docx_path,
        qmd_path = output_path,
        sidecar_dir = sidecar_dir
      )
      if (!validation$valid) {
        warning("Harvest validation found issues. Run validate_harvest() for details.")
      }
    }, error = function(e) {
      message("[docstyle] Error during harvest validation: ", conditionMessage(e))
    })
  }

  invisible(output_path)
}


#' Detect Table of Contents in Word Document
#'
#' Checks if a Word document contains a table of contents by looking for
#' TOC-related paragraph styles (TOCHeading, TOC1, TOC2, etc.).
#'
#' @param doc_xml The parsed document XML
#' @return Logical. TRUE if TOC detected, FALSE otherwise.
#' @noRd
detect_toc <- function(doc_xml) {
  ns <- xml2::xml_ns(doc_xml)

 # Check for TOCHeading style (most reliable indicator)
  toc_heading <- xml2::xml_find_first(
    doc_xml,
    "//w:p[.//w:pStyle[@w:val='TOCHeading']]",
    ns
  )
  if (!inherits(toc_heading, "xml_missing")) {
    return(TRUE)
  }

  # Check for TOC1/TOC2/TOC3 entries (indicates TOC was generated)
  toc_entries <- xml2::xml_find_all(
    doc_xml,
    "//w:p[.//w:pStyle[starts-with(@w:val, 'TOC')]]",
    ns
  )
  if (length(toc_entries) >= 3) {
    # At least 3 TOC entries suggests a real TOC
    return(TRUE)
  }

  FALSE
}


#' Set Up Project Infrastructure
#'
#' Creates or updates project files (_quarto.yml, styles.css, extension)
#' based on the project mode.
#'
#' @param output_path Path to the output QMD file
#' @param project Project mode: "init", "update", or "overwrite"
#' @param preset Preset name or path
#' @noRd
setup_project_infrastructure <- function(output_path, project, preset) {
  output_dir <- dirname(output_path)
  quarto_yml <- file.path(output_dir, "_quarto.yml")
  project_exists <- file.exists(quarto_yml)

  # Handle different project modes
  if (project == "init" && project_exists) {
    message("Project already configured (", basename(quarto_yml), " exists)")
    return(invisible(NULL))
  }

  if (project == "update" && project_exists) {
    # Update mode: merge preset config into existing project
    message("\n--- Updating docstyle project ---")
    update_project_config(output_dir, preset)
    return(invisible(TRUE))
  }

  # For init (new project) or overwrite: use full init()
  message("\n--- Setting up docstyle project ---")
  init(
    path = output_dir,
    preset = preset,
    overwrite = (project == "overwrite")
  )

  invisible(TRUE)
}


#' Update Existing Project Configuration
#'
#' Merges preset settings into an existing project without overwriting
#' user customisations. Adds missing docstyle settings and ensures
#' extension is installed.
#'
#' @param project_dir Path to the project directory
#' @param preset Preset name or path
#' @noRd
update_project_config <- function(project_dir, preset) {
  # Resolve preset path
  preset_path <- resolve_preset(preset)

  # Merge YAML config (preset fills gaps, project takes precedence)
  preset_yml <- file.path(preset_path, "_quarto.yml")
  project_yml <- file.path(project_dir, "_quarto.yml")

  if (file.exists(preset_yml) && file.exists(project_yml)) {
    merge_quarto_config(preset_yml, project_yml)
  }

  # Ensure CSS exists (don't overwrite if present)
  preset_css <- file.path(preset_path, "styles.css")
  project_css <- file.path(project_dir, "styles.css")
  if (file.exists(preset_css) && !file.exists(project_css)) {
    file.copy(preset_css, project_css)
    message("  Added: styles.css")
  }

  # Ensure extension is installed
  ext_dir <- file.path(project_dir, "_extensions", "docstyle")
  if (!dir.exists(ext_dir)) {
    use_docstyle(project_dir)
  }

  message("Project updated successfully")
}


#' Extract Styles from Word Document
#'
#' Extracts font, colour, and page layout information from a Word document's
#' styles.xml and document.xml files.
#'
#' @param docx_path Path to the Word document
#' @return List containing extracted style information
#' @noRd
extract_word_styles <- function(docx_path) {
  styles <- list(
    body_font = NULL,
    body_size = NULL,
    heading_font = NULL,
    title_font = NULL,
    title_size = NULL,
    title_colour = NULL,
    heading1_size = NULL,
    heading1_colour = NULL,
    page_width = NULL,
    page_height = NULL,
    margin_top = NULL,
    margin_bottom = NULL,
    margin_left = NULL,
    margin_right = NULL
  )

  with_docx_temp(docx_path, function(temp_dir) {
    # Extract from styles.xml
    styles_path <- file.path(temp_dir, "word", "styles.xml")
    if (file.exists(styles_path)) {
      styles_xml <- xml2::read_xml(styles_path)
      ns <- xml2::xml_ns(styles_xml)

      # Get Normal style (body text defaults)
      normal <- xml2::xml_find_first(
        styles_xml,
        "//w:style[@w:styleId='Normal']/w:rPr",
        ns
      )
      if (!inherits(normal, "xml_missing")) {
        # Font family
        font_node <- xml2::xml_find_first(normal, ".//w:rFonts/@w:ascii", ns)
        if (!inherits(font_node, "xml_missing")) {
          styles$body_font <<- xml2::xml_text(font_node)
        }
        # Font size (in half-points)
        sz_node <- xml2::xml_find_first(normal, ".//w:sz/@w:val", ns)
        if (!inherits(sz_node, "xml_missing")) {
          half_pts <- as.integer(xml2::xml_text(sz_node))
          styles$body_size <<- paste0(half_pts / 2, "pt")
        }
      }

      # Get Title style
      title <- xml2::xml_find_first(
        styles_xml,
        "//w:style[@w:styleId='Title']/w:rPr",
        ns
      )
      if (!inherits(title, "xml_missing")) {
        font_node <- xml2::xml_find_first(title, ".//w:rFonts/@w:ascii", ns)
        if (!inherits(font_node, "xml_missing")) {
          styles$title_font <<- xml2::xml_text(font_node)
        }
        sz_node <- xml2::xml_find_first(title, ".//w:sz/@w:val", ns)
        if (!inherits(sz_node, "xml_missing")) {
          half_pts <- as.integer(xml2::xml_text(sz_node))
          styles$title_size <<- paste0(half_pts / 2, "pt")
        }
        colour_node <- xml2::xml_find_first(title, ".//w:color/@w:val", ns)
        if (!inherits(colour_node, "xml_missing")) {
          styles$title_colour <<- paste0("#", xml2::xml_text(colour_node))
        }
      }

      # Get Heading 1 style
      h1 <- xml2::xml_find_first(
        styles_xml,
        "//w:style[@w:styleId='Heading1']/w:rPr",
        ns
      )
      if (!inherits(h1, "xml_missing")) {
        font_node <- xml2::xml_find_first(h1, ".//w:rFonts/@w:ascii", ns)
        if (!inherits(font_node, "xml_missing")) {
          styles$heading_font <<- xml2::xml_text(font_node)
        }
        sz_node <- xml2::xml_find_first(h1, ".//w:sz/@w:val", ns)
        if (!inherits(sz_node, "xml_missing")) {
          half_pts <- as.integer(xml2::xml_text(sz_node))
          styles$heading1_size <<- paste0(half_pts / 2, "pt")
        }
        colour_node <- xml2::xml_find_first(h1, ".//w:color/@w:val", ns)
        if (!inherits(colour_node, "xml_missing")) {
          styles$heading1_colour <<- paste0("#", xml2::xml_text(colour_node))
        }
      }
    }

    # Extract page layout from document.xml
    doc_path <- file.path(temp_dir, "word", "document.xml")
    if (file.exists(doc_path)) {
      doc_xml <- xml2::read_xml(doc_path)
      ns <- xml2::xml_ns(doc_xml)

      # Page size (in twips, 1440 twips = 1 inch)
      pg_sz <- xml2::xml_find_first(doc_xml, "//w:sectPr/w:pgSz", ns)
      if (!inherits(pg_sz, "xml_missing")) {
        w <- as.integer(xml2::xml_attr(pg_sz, "w"))
        h <- as.integer(xml2::xml_attr(pg_sz, "h"))
        if (!is.na(w)) styles$page_width <<- paste0(round(w / 1440, 2), "in")
        if (!is.na(h)) styles$page_height <<- paste0(round(h / 1440, 2), "in")
      }

      # Page margins (in twips)
      pg_mar <- xml2::xml_find_first(doc_xml, "//w:sectPr/w:pgMar", ns)
      if (!inherits(pg_mar, "xml_missing")) {
        top <- as.integer(xml2::xml_attr(pg_mar, "top"))
        bottom <- as.integer(xml2::xml_attr(pg_mar, "bottom"))
        left <- as.integer(xml2::xml_attr(pg_mar, "left"))
        right <- as.integer(xml2::xml_attr(pg_mar, "right"))
        if (!is.na(top)) styles$margin_top <<- paste0(round(top / 1440, 2), "in")
        if (!is.na(bottom)) styles$margin_bottom <<- paste0(round(bottom / 1440, 2), "in")
        if (!is.na(left)) styles$margin_left <<- paste0(round(left / 1440, 2), "in")
        if (!is.na(right)) styles$margin_right <<- paste0(round(right / 1440, 2), "in")
      }
    }
  })

  # Remove NULL entries
  styles[!sapply(styles, is.null)]
}


#' Generate CSS from Extracted Word Styles
#'
#' Creates CSS rules based on styles extracted from a Word document.
#'
#' @param styles List of extracted styles from extract_word_styles()
#' @return Character vector of CSS lines
#' @noRd
generate_css_from_styles <- function(styles) {
  css_lines <- c(
    "/* Generated from Word document styles */",
    ""
  )

  # Page layout
  if (!is.null(styles$page_width) || !is.null(styles$margin_top)) {
    css_lines <- c(css_lines, "@page {")
    if (!is.null(styles$page_width) && !is.null(styles$page_height)) {
      # Determine page size name
      w <- as.numeric(gsub("in", "", styles$page_width))
      h <- as.numeric(gsub("in", "", styles$page_height))
      if (abs(w - 8.5) < 0.1 && abs(h - 11) < 0.1) {
        css_lines <- c(css_lines, "  size: letter;")
      } else if (abs(w - 8.27) < 0.1 && abs(h - 11.69) < 0.1) {
        css_lines <- c(css_lines, "  size: A4;")
      } else {
        css_lines <- c(css_lines, sprintf("  size: %s %s;", styles$page_width, styles$page_height))
      }
    }
    if (!is.null(styles$margin_top)) {
      css_lines <- c(css_lines, sprintf("  margin-top: %s;", styles$margin_top))
    }
    if (!is.null(styles$margin_bottom)) {
      css_lines <- c(css_lines, sprintf("  margin-bottom: %s;", styles$margin_bottom))
    }
    if (!is.null(styles$margin_left)) {
      css_lines <- c(css_lines, sprintf("  margin-left: %s;", styles$margin_left))
    }
    if (!is.null(styles$margin_right)) {
      css_lines <- c(css_lines, sprintf("  margin-right: %s;", styles$margin_right))
    }
    css_lines <- c(css_lines, "}", "")
  }

  # Body text
  if (!is.null(styles$body_font) || !is.null(styles$body_size)) {
    css_lines <- c(css_lines, "body {")
    if (!is.null(styles$body_font)) {
      css_lines <- c(css_lines, sprintf("  font-family: '%s', sans-serif;", styles$body_font))
    }
    if (!is.null(styles$body_size)) {
      css_lines <- c(css_lines, sprintf("  font-size: %s;", styles$body_size))
    }
    css_lines <- c(css_lines, "}", "")
  }

  # Title
  if (!is.null(styles$title_font) || !is.null(styles$title_size) || !is.null(styles$title_colour)) {
    css_lines <- c(css_lines, ".title {")
    if (!is.null(styles$title_font)) {
      css_lines <- c(css_lines, sprintf("  font-family: '%s', sans-serif;", styles$title_font))
    }
    if (!is.null(styles$title_size)) {
      css_lines <- c(css_lines, sprintf("  font-size: %s;", styles$title_size))
    }
    if (!is.null(styles$title_colour)) {
      css_lines <- c(css_lines, sprintf("  color: %s;", styles$title_colour))
    }
    css_lines <- c(css_lines, "}", "")
  }

  # Heading 1
  if (!is.null(styles$heading_font) || !is.null(styles$heading1_size) || !is.null(styles$heading1_colour)) {
    css_lines <- c(css_lines, "h1 {")
    if (!is.null(styles$heading_font)) {
      css_lines <- c(css_lines, sprintf("  font-family: '%s', sans-serif;", styles$heading_font))
    }
    if (!is.null(styles$heading1_size)) {
      css_lines <- c(css_lines, sprintf("  font-size: %s;", styles$heading1_size))
    }
    if (!is.null(styles$heading1_colour)) {
      css_lines <- c(css_lines, sprintf("  color: %s;", styles$heading1_colour))
    }
    css_lines <- c(css_lines, "}", "")
  }

  css_lines
}


#' Write Extracted Styles to CSS File
#'
#' Extracts styles from a Word document and writes them to a CSS file.
#' If the CSS file exists, appends the extracted styles with a comment header.
#'
#' @param docx_path Path to the Word document
#' @param css_path Path to the CSS file to create/update
#' @param append If TRUE, appends to existing CSS; if FALSE, overwrites
#' @return Invisibly returns the CSS path
#' @noRd
write_extracted_styles <- function(docx_path, css_path, append = TRUE) {
  styles <- extract_word_styles(docx_path)

  if (length(styles) == 0) {
    message("No styles extracted from Word document")
    return(invisible(css_path))
  }

  css_lines <- generate_css_from_styles(styles)

  if (append && file.exists(css_path)) {
    existing <- readLines(css_path)
    css_lines <- c(existing, "", "/* === Styles extracted from Word === */", css_lines)
  }

  writeLines(css_lines, css_path)
  message("  Extracted styles to: ", basename(css_path))

  invisible(css_path)
}


#' Prepare header preservation for re-harvest workflow
#'
#' If preserve_header is TRUE and output file exists, extracts the YAML header
#' and creates a backup of the existing file.
#'
#' @param output_path Path to output QMD file
#' @param preserve_header Whether to preserve existing header
#' @return Character vector of YAML header lines, or NULL if not preserving
#' @noRd
prepare_header_preservation <- function(output_path, preserve_header) {
  if (!preserve_header || !file.exists(output_path)) {
    return(NULL)
  }

  message("Existing QMD found: ", basename(output_path))

  # Extract the existing YAML header before overwriting
  existing_header <- extract_yaml_header(output_path)
  if (!is.null(existing_header)) {
    message("  Preserving existing YAML header")
  }

  # Create backup as *_old.qmd
  old_path <- sub("\\.qmd$", "_old.qmd", output_path, ignore.case = TRUE)
  file.copy(output_path, old_path, overwrite = TRUE)
  message("  Backup created: ", basename(old_path))

  existing_header
}


#' Extract sidecar data from Word document
#'
#' Extracts citations, comments, and revisions from a Word document and
#' writes them to the sidecar directory.
#'
#' @param docx_path Path to the Word document
#' @param sidecar_dir Directory for sidecar files
#' @return List with citations, citation_map, and cite_keys from extract_citations
#' @noRd
extract_sidecar_data <- function(docx_path, sidecar_dir) {
  # Extract citations first (gets citation_map for text replacement)
  # Use merge=TRUE to preserve existing field-codes.json when the source
  # document has no Zotero citations (#51). This prevents a re-harvest of
  # a non-citation document from destroying citation data from other documents
  # or from a previous harvest of the same document before citations were added.
  citation_result <- extract_citations(docx_path, sidecar_dir, merge = TRUE)

  # Extract comments from source document
  # Always write sidecar to clear stale data when comments have been resolved (#27)
  comments <- extract_comments(docx_path)
  comments_path <- file.path(sidecar_dir, "comments.json")
  write_comments_json(comments, comments_path)
  if (length(comments) > 0) {
    message("[harvest] Extracted ", length(comments), " comments to ", basename(comments_path))
  }

  # Extract revisions from source document
  # Always write sidecar to clear stale data when revisions have been accepted (#27)
  revisions <- extract_revisions(docx_path)
  revisions_path <- file.path(sidecar_dir, "revisions.json")
  write_revisions_json(revisions, revisions_path)
  if (length(revisions) > 0) {
    message("[harvest] Extracted ", length(revisions), " revisions to ", basename(revisions_path))
  }

  # Extract style inventory from source document
  extract_style_inventory(docx_path, sidecar_dir)

  citation_result
}


#' Validate extracted citations against a canonical bibliography
#'
#' @param citations List of extracted citations
#' @param validate_bib Path to canonical BibTeX file
#' @noRd
validate_citations_against_bib <- function(citations, validate_bib) {
  if (length(citations) == 0) {
    return(invisible(NULL))
  }

  message("\n--- Validating Citations ---")

  if (!file.exists(validate_bib)) {
    warning("Canonical bibliography not found: ", validate_bib)
    return(invisible(NULL))
  }

  canonical_items <- read_bib_as_csl(validate_bib)

  # Run matching
  validation_report <- match_citations(citations, canonical_items)

  # Print Summary
  n_matched <- nrow(validation_report$matches)
  n_orphans <- nrow(validation_report$orphans)
  message(sprintf("Validated %d citations: %d matched, %d orphans",
                  length(citations), n_matched, n_orphans))

  if (n_orphans > 0) {
    message("Warning: Some citations in the document were not found in the canonical bibliography.")
  }

  invisible(validation_report)
}


#' Set up reference document for a style
#'
#' Copies the reference document from the package to the output directory.
#'
#' @param style Style name (e.g., "popcorn")
#' @param output_dir Directory where the reference doc should be copied
#' @return Basename of the reference document, or NULL if not found
#' @noRd
setup_reference_doc <- function(style, output_dir) {
  # Look for reference.docx in the style's extdata directory
  ref_path <- system.file(
    "extdata", style, "reference.docx",
    package = "docstyle"
  )

  if (ref_path == "" || !file.exists(ref_path)) {
    warning("Reference document not found for style: ", style)
    return(NULL)
  }

  # Copy to output directory
  dest_path <- file.path(output_dir, paste0(style, "-reference.docx"))
  file.copy(ref_path, dest_path, overwrite = TRUE)
  message("Copied reference document: ", basename(dest_path))

  basename(dest_path)
}


#' Extract YAML header from a QMD file
#'
#' Reads a QMD file and extracts the YAML front matter as a character vector.
#' The YAML is returned as raw lines (including the --- delimiters) so it can
#' be reused verbatim when preserving headers during re-harvest.
#'
#' @param qmd_path Path to the .qmd file
#' @return Character vector of YAML header lines (including --- delimiters),
#'   or NULL if no valid YAML header found
#' @noRd
extract_yaml_header <- function(qmd_path) {
  if (!file.exists(qmd_path)) {
    return(NULL)
  }

  lines <- readLines(qmd_path, warn = FALSE)
  if (length(lines) == 0) {
    return(NULL)
  }

  # Check for YAML start delimiter
  if (trimws(lines[1]) != "---") {
    return(NULL)
  }

 # Find the closing delimiter (second ---)
  end_idx <- NULL
  for (i in 2:length(lines)) {
    if (trimws(lines[i]) == "---") {
      end_idx <- i
      break
    }
  }

  if (is.null(end_idx)) {
    warning("No closing YAML delimiter found in: ", qmd_path)
    return(NULL)
  }

  # Return the full YAML block including delimiters
  lines[1:end_idx]
}


#' Extract content from docx XML
#' @noRd
extract_docx_content <- function(docx_path) {
  with_docx_temp(docx_path, function(temp_dir) {
    doc_path <- file.path(temp_dir, "word", "document.xml")
    if (!file.exists(doc_path)) {
      stop("Invalid docx: word/document.xml not found")
    }
    xml2::read_xml(doc_path)
  })
}


#' Extract embedded images from a DOCX file
#'
#' Reads image relationships from word/_rels/document.xml.rels, extracts
#' the corresponding media files from the DOCX zip, and copies them to
#' the output directory. Returns a map from relationship ID to local path.
#'
#' @param docx_path Path to the .docx file
#' @param image_dir Directory to write extracted images (created if needed)
#' @return Named list mapping rId values to relative file paths (e.g., rId7 = "images/image1.png")
#' @noRd
extract_docx_images <- function(docx_path, image_dir = "images") {
  if (is.null(docx_path) || !file.exists(docx_path)) return(list())

  with_docx_temp(docx_path, function(temp_dir) {
    rels_path <- file.path(temp_dir, "word", "_rels", "document.xml.rels")
    if (!file.exists(rels_path)) return(list())

    rels_xml <- xml2::read_xml(rels_path)
    image_rels <- xml2::xml_find_all(
      rels_xml,
      "//d1:Relationship[contains(@Type, '/image')]",
      xml2::xml_ns(rels_xml)
    )

    if (length(image_rels) == 0) return(list())

    dir.create(image_dir, recursive = TRUE, showWarnings = FALSE)
    result <- list()

    for (rel in image_rels) {
      rel_id <- xml2::xml_attr(rel, "Id")
      target <- xml2::xml_attr(rel, "Target")
      if (is.na(rel_id) || is.na(target)) next

      # Resolve path within DOCX zip (targets are relative to word/)
      source_path <- file.path(temp_dir, "word", target)
      if (!file.exists(source_path)) next

      filename <- basename(target)
      dest_path <- file.path(image_dir, filename)
      file.copy(source_path, dest_path, overwrite = TRUE)
      result[[rel_id]] <- dest_path
    }

    if (length(result) > 0) {
      message("  Extracted ", length(result), " image(s) to ", image_dir, "/")
    }
    result
  })
}


#' Extract hyperlink relationships from docx
#'
#' Reads word/_rels/document.xml.rels and returns a named list
#' mapping relationship IDs to their target URLs.
#'
#' @param docx_path Path to the docx file
#' @return Named list where names are rId values and values are URLs
#' @noRd
extract_hyperlink_rels <- function(docx_path) {
  with_docx_temp(docx_path, function(temp_dir) {
    rels_path <- file.path(temp_dir, "word", "_rels", "document.xml.rels")
    if (!file.exists(rels_path)) {
      return(list())
    }

    rels_xml <- xml2::read_xml(rels_path)

    # Find all hyperlink relationships
    # Namespace for relationships
    hyperlinks <- xml2::xml_find_all(
      rels_xml,
      "//d1:Relationship[@Type='http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink']",
      xml2::xml_ns(rels_xml)
    )

    result <- list()
    for (hl in hyperlinks) {
      rel_id <- xml2::xml_attr(hl, "Id")
      target <- xml2::xml_attr(hl, "Target")
      if (!is.na(rel_id) && !is.na(target)) {
        result[[rel_id]] <- target
      }
    }

    result
  })
}


#' Extract footnotes from docx
#'
#' Reads footnotes.xml from the unzipped docx and returns a named list
#' mapping footnote IDs to their text content.
#'
#' @param docx_path Path to the docx file
#' @return Named list where names are footnote IDs and values are text content
#' @noRd
extract_footnotes <- function(docx_path) {
  with_docx_temp(docx_path, function(temp_dir) {
    fn_path <- file.path(temp_dir, "word", "footnotes.xml")
    if (!file.exists(fn_path)) {
      return(list())
    }

    fn_xml <- xml2::read_xml(fn_path)
    ns <- xml2::xml_ns(fn_xml)

    # Find all footnote elements
    footnotes <- xml2::xml_find_all(fn_xml, "//w:footnote", ns)

    result <- list()
    for (fn in footnotes) {
      # Skip separator and continuationSeparator footnotes
      fn_type <- xml2::xml_attr(fn, "type")
      if (!is.na(fn_type)) next

      fn_id <- xml2::xml_attr(fn, "id")
      if (is.na(fn_id)) next

      # Extract all text from the footnote
      text_nodes <- xml2::xml_find_all(fn, ".//w:t", ns)
      fn_text <- paste(xml2::xml_text(text_nodes), collapse = "")
      fn_text <- trimws(fn_text)

      if (nchar(fn_text) > 0) {
        result[[fn_id]] <- fn_text
      }
    }

    result
  })
}


#' Extract content from a deletion element with comment handling
#'
#' Processes children of a w:del element, preserving comment markers
#' that appear within the deletion. This ensures comments attached to
#' deleted text are not lost during harvest.
#'
#' @param del_node The w:del XML node
#' @param ns XML namespaces
#' @param active_comments Character vector of currently active comment IDs
#' @return List with: text (formatted deletion content with comment markers),
#'         active_comments (updated stack of active comment IDs)
#' @noRd
extract_deletion_content <- function(del_node, ns, active_comments = character()) {
  children <- xml2::xml_children(del_node)
  text_parts <- character()
  current_comments <- active_comments

  for (child in children) {
    node_name <- xml2::xml_name(child)

    # Handle comment range start inside deletion
    if (node_name == "commentRangeStart") {
      comment_id <- xml2::xml_attr(child, "id")
      if (!is.na(comment_id)) {
        current_comments <- c(current_comments, comment_id)
        text_parts <- c(text_parts,
          paste0("`<!-- comment:start id=\"", comment_id, "\" -->`{=html}"))
      }
      next
    }

    # Handle comment range end inside deletion
    if (node_name == "commentRangeEnd") {
      comment_id <- xml2::xml_attr(child, "id")
      if (!is.na(comment_id) && comment_id %in% current_comments) {
        text_parts <- c(text_parts,
          paste0("`<!-- comment:end id=\"", comment_id, "\" -->`{=html}"))
        current_comments <- current_comments[current_comments != comment_id]
      }
      next
    }

    # Skip comment reference markers (handled separately)
    if (node_name == "commentReference") {
      next
    }

    # Handle runs containing delText
    if (node_name == "r") {
      # Check for line break elements (w:br) -- soft breaks within runs
      br_nodes <- xml2::xml_find_all(child, ".//w:br", ns)
      for (br in br_nodes) {
        br_type <- xml2::xml_attr(br, "type")
        if (is.na(br_type) || br_type == "textWrapping") {
          text_parts <- c(text_parts, "\\\n")
        }
      }

      del_text_nodes <- xml2::xml_find_all(child, ".//w:delText", ns)
      run_text <- paste(xml2::xml_text(del_text_nodes), collapse = "")
      if (nchar(run_text) > 0) {
        text_parts <- c(text_parts, run_text)
      }
      next
    }
  }

  list(
    text = paste(text_parts, collapse = ""),
    active_comments = current_comments
  )
}


#' Extract content from an insertion element with comment handling
#'
#' Processes children of a w:ins element, preserving comment markers
#' that appear within the insertion.
#'
#' @param ins_node The w:ins XML node
#' @param ns XML namespaces
#' @param active_comments Character vector of currently active comment IDs
#' @return List with: text (formatted insertion content with comment markers),
#'         active_comments (updated stack of active comment IDs)
#' @noRd
extract_insertion_content <- function(ins_node, ns, active_comments = character()) {
  children <- xml2::xml_children(ins_node)
  text_parts <- character()
  current_comments <- active_comments

  for (child in children) {
    node_name <- xml2::xml_name(child)

    # Handle comment range start inside insertion
    if (node_name == "commentRangeStart") {
      comment_id <- xml2::xml_attr(child, "id")
      if (!is.na(comment_id)) {
        current_comments <- c(current_comments, comment_id)
        text_parts <- c(text_parts,
          paste0("`<!-- comment:start id=\"", comment_id, "\" -->`{=html}"))
      }
      next
    }

    # Handle comment range end inside insertion
    if (node_name == "commentRangeEnd") {
      comment_id <- xml2::xml_attr(child, "id")
      if (!is.na(comment_id) && comment_id %in% current_comments) {
        text_parts <- c(text_parts,
          paste0("`<!-- comment:end id=\"", comment_id, "\" -->`{=html}"))
        current_comments <- current_comments[current_comments != comment_id]
      }
      next
    }

    # Skip comment reference markers
    if (node_name == "commentReference") {
      next
    }

    # Handle runs containing regular text (w:t, not w:delText)
    if (node_name == "r") {
      # Check for line break elements (w:br) -- soft breaks within runs
      br_nodes <- xml2::xml_find_all(child, ".//w:br", ns)
      for (br in br_nodes) {
        br_type <- xml2::xml_attr(br, "type")
        if (is.na(br_type) || br_type == "textWrapping") {
          text_parts <- c(text_parts, "\\\n")
        }
      }

      t_nodes <- xml2::xml_find_all(child, ".//w:t", ns)
      run_text <- paste(xml2::xml_text(t_nodes), collapse = "")
      if (nchar(run_text) > 0) {
        text_parts <- c(text_parts, run_text)
      }
      next
    }
  }

  list(
    text = paste(text_parts, collapse = ""),
    active_comments = current_comments
  )
}



#' Extract wp:docPr/@id from a drawing paragraph
#'
#' Returns the integer id attribute from the first wp:docPr node found inside
#' any w:drawing in the paragraph. This is Word's stable per-drawing identifier
#' that survives reordering. Returns NULL if no drawing or no id is found.
#'
#' @param p Paragraph XML node
#' @param ns XML namespaces (w: prefix)
#' @return Integer docPr id, or NULL
#' @noRd
extract_drawing_docpr_id <- function(p, ns) {
  drawing <- xml2::xml_find_first(p, ".//w:drawing", ns)
  if (inherits(drawing, "xml_missing")) return(NULL)
  wp_ns <- c(wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing")
  docpr <- xml2::xml_find_first(drawing, ".//wp:docPr", wp_ns)
  if (inherits(docpr, "xml_missing")) return(NULL)
  id_val <- xml2::xml_attr(docpr, "id")
  if (is.na(id_val)) return(NULL)
  as.integer(id_val)
}


#' Extract text from paragraph with inline formatting, footnotes, comments, and revisions
#'
#' Processes runs within a paragraph, detecting bold/italic formatting,
#' footnote references, comment ranges, track changes (insertions/deletions),
#' and hyperlinks.
#' Returns both the formatted text and footnote info.
#'
#' @param p Paragraph XML node
#' @param ns XML namespaces
#' @param footnotes Named list of footnote content (from extract_footnotes)
#' @param footnote_counter Current footnote counter for sequential numbering
#' @param active_comments Character vector of currently active comment IDs
#' @param hyperlink_rels Named list mapping rId to URL (from extract_hyperlink_rels)
#' @return List with: text (formatted paragraph), footnote_counter (updated),
#'         new_definitions (vector of footnote definition strings)
#' @noRd
extract_formatted_text <- function(p, ns, footnotes = list(), footnote_counter = 0,
                                   active_comments = character(), hyperlink_rels = list(),
                                   citation_id_map = list(),
                                   image_rels = list()) {
  # Get all child elements of the paragraph (runs, comment markers, revisions, etc.)
  children <- xml2::xml_children(p)
  if (length(children) == 0) {
    return(list(text = "", footnote_counter = footnote_counter, new_definitions = character()))
  }

  text_parts <- character()
  new_definitions <- character()
  current_comments <- active_comments  # Stack of active comment IDs

  # Field code state tracking for Zotero and DOCSTYLE field code detection
  # OOXML field codes: <w:fldChar begin> ... <w:instrText> ... <w:fldChar separate> ... display text ... <w:fldChar end>
  in_field_code <- FALSE
  field_instr_text <- ""
  field_citation_id <- NULL  # citationID extracted from instrText JSON
  skip_field_display <- FALSE  # TRUE when we should skip display text runs
  docstyle_source <- NULL  # QMD source from ADDIN DOCSTYLE field code payload

  # Collector for version-summary values extracted from field codes
  version_summary <- list()

  for (child in children) {
    node_name <- xml2::xml_name(child)

    # Handle comment range start - use raw HTML markers for robustness
    # Uses Pandoc's raw attribute syntax `...`{=html} to create RawInline elements
    # that the Lua filter can process. Plain HTML comments would be converted to
    # text with smart typography (-- becomes en-dash).
    if (node_name == "commentRangeStart") {
      comment_id <- xml2::xml_attr(child, "id")
      if (!is.na(comment_id)) {
        current_comments <- c(current_comments, comment_id)
        # Insert raw HTML marker using Pandoc's raw attribute syntax
        text_parts <- c(text_parts, paste0("`<!-- comment:start id=\"", comment_id, "\" -->`{=html}"))
      }
      next
    }

    # Handle comment range end
    if (node_name == "commentRangeEnd") {
      comment_id <- xml2::xml_attr(child, "id")
      if (!is.na(comment_id) && comment_id %in% current_comments) {
        # Insert raw HTML marker using Pandoc's raw attribute syntax
        text_parts <- c(text_parts, paste0("`<!-- comment:end id=\"", comment_id, "\" -->`{=html}"))
        current_comments <- current_comments[current_comments != comment_id]
      }
      next
    }

    # Handle insertions (w:ins) - preserve comments attached to inserted text
    if (node_name == "ins") {
      ins_id <- xml2::xml_attr(child, "id")
      if (is.na(ins_id)) ins_id <- "0"

      # Extract insertion content with comment markers preserved
      ins_result <- extract_insertion_content(child, ns, current_comments)
      ins_text <- ins_result$text
      current_comments <- ins_result$active_comments

      if (nchar(ins_text) > 0) {
        text_parts <- c(text_parts, paste0("[", ins_text, "]{.ins id=\"rev_", ins_id, "\"}"))
      }
      next
    }

    # Handle deletions (w:del) - preserve comments attached to deleted text
    if (node_name == "del") {
      del_id <- xml2::xml_attr(child, "id")
      if (is.na(del_id)) del_id <- "0"

      # Extract deletion content with comment markers preserved
      del_result <- extract_deletion_content(child, ns, current_comments)
      del_text <- del_result$text
      current_comments <- del_result$active_comments

      if (nchar(del_text) > 0) {
        text_parts <- c(text_parts, paste0("[~~", del_text, "~~]{.del id=\"rev_", del_id, "\"}"))
      }
      next
    }

    # Handle hyperlinks (w:hyperlink)
    if (node_name == "hyperlink") {
      # Internal anchor links use w:anchor; external links use r:id
      anchor <- xml2::xml_attr(child, "anchor")
      rel_id <- xml2::xml_attr(child, "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id")

      # Extract text from runs inside the hyperlink
      hl_runs <- xml2::xml_find_all(child, ".//w:r", ns)
      hl_text <- ""
      for (hl_run in hl_runs) {
        t_nodes <- xml2::xml_find_all(hl_run, ".//w:t", ns)
        hl_text <- paste0(hl_text, paste(xml2::xml_text(t_nodes), collapse = ""))
      }

      if (nchar(hl_text) > 0) {
        if (!is.na(anchor) && nchar(anchor) > 0) {
          # Internal anchor: [text](#anchor)
          text_parts <- c(text_parts, paste0("[", hl_text, "](#", anchor, ")"))
        } else {
          # Look up the URL from relationships
          url <- hyperlink_rels[[rel_id]]
          if (!is.null(url) && !is.na(url)) {
            # Create markdown link
            text_parts <- c(text_parts, paste0("[", hl_text, "](", url, ")"))
          } else {
            # No URL found, just output the text
            text_parts <- c(text_parts, hl_text)
          }
        }
      }
      next
    }

    # Handle simple field codes (w:fldSimple) - self-contained with w:instr attribute
    # Uses unified parser from field_codes.R
    if (node_name == "fldSimple") {
      fld_result <- extract_fld_simple(child, ns)

      if (!is.null(fld_result)) {
        # Check for docstyle field code
        payload <- parse_docstyle_payload(fld_result$instr)

        if (!is.null(payload) && payload$type == "char") {
          # Use dispatch_docstyle_handler for consistent handling
          handler_result <- dispatch_docstyle_handler(
            payload,
            list(display_text = fld_result$display_text)
          )

          if (!is.null(handler_result) && handler_result$skip_display) {
            # Harvest metadata if present in handler result (registry-driven)
            if (!is.null(handler_result$harvested_metadata)) {
              # harvested_metadata is nested: list(version_summary = list(date = "..."))
              # Merge into version_summary collector
              if (!is.null(handler_result$harvested_metadata$version_summary)) {
                for (nm in names(handler_result$harvested_metadata$version_summary)) {
                  version_summary[[nm]] <- handler_result$harvested_metadata$version_summary[[nm]]
                }
              }
            }
            # Emit the original QMD source instead of display text
            text_parts <- c(text_parts, handler_result$qmd_source)
            next
          }
        }
      }

      # Fallback: extract display text from fldSimple children
      fld_runs <- xml2::xml_find_all(child, ".//w:r", ns)
      fld_text <- ""
      for (fld_run in fld_runs) {
        t_nodes <- xml2::xml_find_all(fld_run, ".//w:t", ns)
        fld_text <- paste0(fld_text, paste(xml2::xml_text(t_nodes), collapse = ""))
      }
      if (nchar(fld_text) > 0) {
        text_parts <- c(text_parts, fld_text)
      }
      next
    }

    # Handle regular runs (w:r)
    if (node_name == "r") {
      run <- child

      # --- Field code boundary detection (for Zotero citations) ---
      # OOXML field codes use: <w:fldChar begin> ... <w:instrText> ... <w:fldChar separate> ... display ... <w:fldChar end>
      fld_char <- xml2::xml_find_first(run, ".//w:fldChar", ns)
      if (!inherits(fld_char, "xml_missing")) {
        fld_type <- xml2::xml_attr(fld_char, "fldCharType")
        if (!is.na(fld_type)) {
          if (fld_type == "begin") {
            in_field_code <- TRUE
            field_instr_text <- ""
            field_citation_id <- NULL
            skip_field_display <- FALSE
            next
          } else if (fld_type == "separate") {
            # instrText collection is done; check if this is a Zotero citation
            if (in_field_code && grepl("ZOTERO_ITEM", field_instr_text)) {
              # Extract citationID from the instrText JSON
              cid_match <- regmatches(field_instr_text,
                regexpr('"citationID"\\s*:\\s*"([^"]+)"', field_instr_text, perl = TRUE))
              if (length(cid_match) > 0 && nchar(cid_match) > 0) {
                # Parse out just the ID value
                field_citation_id <- sub('.*"citationID"\\s*:\\s*"([^"]+)".*', "\\1",
                                         cid_match, perl = TRUE)
              }
              # If we have a citation_id_map entry, skip display text and emit citation key
              if (!is.null(field_citation_id) && length(citation_id_map) > 0 &&
                  field_citation_id %in% names(citation_id_map)) {
                skip_field_display <- TRUE
                # Emit the Quarto citation syntax now
                text_parts <- c(text_parts, citation_id_map[[field_citation_id]])
              }
            } else if (in_field_code && is_docstyle_field(field_instr_text)) {
              # DOCSTYLE field code -- use unified parser from field_codes.R
              payload <- parse_docstyle_payload(field_instr_text)
              if (!is.null(payload) && payload$type == "char") {
                skip_field_display <- TRUE
                docstyle_source <- payload$source
              }
            }
            next
          } else if (fld_type == "end") {
            # Emit DOCSTYLE source if we were skipping display text for a docstyle field code
            if (!is.null(docstyle_source)) {
              text_parts <- c(text_parts, docstyle_source)
              docstyle_source <- NULL
            }
            in_field_code <- FALSE
            field_instr_text <- ""
            field_citation_id <- NULL
            skip_field_display <- FALSE
            next
          }
        }
      }

      # Collect instrText when inside a field code (between begin and separate)
      if (in_field_code && !skip_field_display) {
        instr_nodes <- xml2::xml_find_all(run, ".//w:instrText", ns)
        if (length(instr_nodes) > 0) {
          field_instr_text <- paste0(field_instr_text,
            paste(xml2::xml_text(instr_nodes), collapse = ""))
          next
        }
      }

      # Skip display text runs inside a field code that we've already handled
      if (skip_field_display) {
        next
      }

      # Check for footnote reference first
      fn_ref <- xml2::xml_find_first(run, ".//w:footnoteReference", ns)
      if (!inherits(fn_ref, "xml_missing")) {
        fn_id <- xml2::xml_attr(fn_ref, "id")
        if (!is.na(fn_id) && fn_id %in% names(footnotes)) {
          footnote_counter <- footnote_counter + 1
          text_parts <- c(text_parts, paste0("[^", footnote_counter, "]"))
          new_definitions <- c(new_definitions,
                               paste0("[^", footnote_counter, "]: ", footnotes[[fn_id]]))
        }
        next
      }

      # Skip comment reference markers (they don't contain text)
      comment_ref <- xml2::xml_find_first(run, ".//w:commentReference", ns)
      if (!inherits(comment_ref, "xml_missing")) {
        next
      }

      # Check for line break elements (w:br) -- soft breaks (Shift+Enter in Word)
      # These appear as <w:br/> inside a run and represent a line break within
      # the same paragraph. Emit as Markdown hard line break (backslash newline).
      br_nodes <- xml2::xml_find_all(run, ".//w:br", ns)
      if (length(br_nodes) > 0) {
        for (br in br_nodes) {
          # Check break type -- page/column breaks are different from line breaks
          br_type <- xml2::xml_attr(br, "type")
          if (is.na(br_type) || br_type == "textWrapping") {
            # Text line break: emit Markdown hard line break
            text_parts <- c(text_parts, "\\\n")
          }
          # page/column breaks are ignored (handled by page-section filter)
        }
      }

      # Check for embedded images (w:drawing) -- these have no w:t text.
      # Only handle wp:inline (truly inline); wp:anchor is a floating element
      # handled at the paragraph dispatch level. Nested wp:anchor elements
      # appear inside grouped-figure caption boxes (Word stores multiple
      # per-resolution copies there) and must be suppressed here.
      drawing_node <- xml2::xml_find_first(run, ".//w:drawing", ns)
      if (!inherits(drawing_node, "xml_missing")) {
        wp_ns <- c(wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing")
        if (inherits(xml2::xml_find_first(drawing_node, "wp:inline", wp_ns), "xml_missing")) {
          next  # floating anchor -- skip in run context
        }
        # Get alt text from wp:docPr
        doc_pr <- xml2::xml_find_first(drawing_node, ".//wp:docPr", wp_ns)
        alt_text <- if (!inherits(doc_pr, "xml_missing"))
          xml2::xml_attr(doc_pr, "descr") else ""
        if (is.na(alt_text)) alt_text <- ""

        # Try to resolve image path via a:blip relationship (#63)
        img_path <- NULL
        if (length(image_rels) > 0) {
          a_ns <- c(a = "http://schemas.openxmlformats.org/drawingml/2006/main")
          blip <- xml2::xml_find_first(drawing_node, ".//a:blip", a_ns)
          if (!inherits(blip, "xml_missing")) {
            embed_id <- xml2::xml_attr(blip, "embed")
            if (is.na(embed_id)) {
              # Try r:embed with namespace
              embed_id <- xml2::xml_attr(blip, "r:embed")
            }
            if (!is.na(embed_id)) {
              img_path <- image_rels[[embed_id]]
            }
          }
        }

        if (!is.null(img_path)) {
          text_parts <- c(text_parts, paste0("![", alt_text, "](", img_path, ")"))
        } else if (nchar(alt_text) > 0) {
          text_parts <- c(text_parts, paste0("<!-- IMAGE: ", alt_text, " -->"))
        } else {
          text_parts <- c(text_parts, "<!-- IMAGE -->")
        }
        next
      }

      # Get text from this run
      t_nodes <- xml2::xml_find_all(run, ".//w:t", ns)
      if (length(t_nodes) == 0) next

      run_text <- normalize_typographic_dashes(paste(xml2::xml_text(t_nodes), collapse = ""))
      if (nchar(run_text) == 0) next

      # Skip formatting on whitespace-only runs to avoid stray markers like "** **"
      is_whitespace_only <- nchar(trimws(run_text)) == 0

      # Check for formatting in run properties (rPr)
      rPr <- xml2::xml_find_first(run, ".//w:rPr", ns)

      is_bold <- FALSE
      is_italic <- FALSE
      is_strike <- FALSE
      is_underline <- FALSE
      is_subscript <- FALSE
      is_superscript <- FALSE

      if (!inherits(rPr, "xml_missing")) {
        # Check for bold
        b_node <- xml2::xml_find_first(rPr, ".//w:b", ns)
        if (!inherits(b_node, "xml_missing")) {
          # Check if bold is explicitly turned off (w:b w:val="0" or w:val="false")
          b_val <- xml2::xml_attr(b_node, "val")
          is_bold <- is.na(b_val) || !(b_val %in% c("0", "false"))
        }

        # Check for italic
        i_node <- xml2::xml_find_first(rPr, ".//w:i", ns)
        if (!inherits(i_node, "xml_missing")) {
          i_val <- xml2::xml_attr(i_node, "val")
          is_italic <- is.na(i_val) || !(i_val %in% c("0", "false"))
        }

        # Check for strikethrough (w:strike)
        strike_node <- xml2::xml_find_first(rPr, ".//w:strike", ns)
        if (!inherits(strike_node, "xml_missing")) {
          strike_val <- xml2::xml_attr(strike_node, "val")
          is_strike <- is.na(strike_val) || !(strike_val %in% c("0", "false"))
        }

        # Check for underline (w:u) - only single underline, not other styles
        u_node <- xml2::xml_find_first(rPr, ".//w:u", ns)
        if (!inherits(u_node, "xml_missing")) {
          u_val <- xml2::xml_attr(u_node, "val")
          # "single" is standard underline; "none" means no underline
          is_underline <- !is.na(u_val) && u_val != "none"
        }

        # Check for subscript/superscript (w:vertAlign)
        vert_node <- xml2::xml_find_first(rPr, ".//w:vertAlign", ns)
        if (!inherits(vert_node, "xml_missing")) {
          vert_val <- xml2::xml_attr(vert_node, "val")
          if (!is.na(vert_val)) {
            is_subscript <- vert_val == "subscript"
            is_superscript <- vert_val == "superscript"
          }
        }

      }

      # Apply markdown formatting (skip for whitespace-only runs)
      # Order matters: subscript/superscript wrap innermost, then strike, then bold/italic
      if (!is_whitespace_only) {
        # Subscript and superscript use HTML tags (Pandoc supports these)
        if (is_subscript) {
          run_text <- paste0("<sub>", run_text, "</sub>")
        } else if (is_superscript) {
          run_text <- paste0("<sup>", run_text, "</sup>")
        }

        # Strikethrough uses ~~ in Pandoc markdown
        if (is_strike) {
          run_text <- paste0("~~", run_text, "~~")
        }

        # Underline uses span with custom class (no native markdown)
        if (is_underline) {
          run_text <- paste0("[", run_text, "]{.underline}")
        }

        # Bold and italic (outermost) -- use _**...**_ for unambiguous nesting (#47)
        if (is_bold && is_italic) {
          run_text <- paste0("_**", run_text, "**_")
        } else if (is_bold) {
          run_text <- paste0("**", run_text, "**")
        } else if (is_italic) {
          run_text <- paste0("*", run_text, "*")
        }
      }

      text_parts <- c(text_parts, run_text)
    }
  }

  result <- paste(text_parts, collapse = "")

  # Clean redundant formatting artifacts from Word's run-level model (#46, #53)
  result <- clean_markdown_formatting(result)

  list(
    text = result,
    footnote_counter = footnote_counter,
    new_definitions = new_definitions,
    active_comments = current_comments,  # Return active comments for multi-paragraph tracking
    version_summary = version_summary  # Collected version-summary values from field codes
  )
}


#' Infer a heading level from a numbered-section paragraph (#125)
#'
#' Some journal/institutional Word templates apply a custom paragraph
#' style to a section heading that does not resolve to a canonical
#' `HeadingN` key (no `outlineLvl`, name doesn't match "heading N"), so
#' the heading would otherwise flatten to a plain paragraph on harvest.
#' When the paragraph text begins with a multi-segment section number
#' (e.g. "3.4.2 Title"), infer the heading depth from the count of
#' numeric segments, clamped to the resolver's H1–H6 range.
#'
#' Deliberately conservative to avoid false positives:
#' - Requires at least TWO numeric segments (`N.N`), so a list item like
#'   "1. item" or body text opening with a bare year ("2020 was…") does
#'   not match. (Single-level headings already carry real heading styles
#'   in practice; the failure mode #125 reported was numbered SUBsections.)
#' - Requires the number to be followed by whitespace then a letter, so
#'   an inline decimal in prose ("the ratio 3.4 was…") does not match —
#'   that pattern has no trailing word boundary of the heading form.
#'
#' @param text Plain paragraph text.
#' @return Integer heading level 2–6, or `NA_integer_` if no match.
#' @noRd
infer_numbered_heading_level <- function(text) {
  if (is.null(text) || length(text) != 1L || is.na(text)) {
    return(NA_integer_)
  }
  # Anchor: start, then a dotted number with >= 2 segments, then a
  # separating space and a letter (the heading title). Trailing dot
  # after the last segment is allowed ("3.4.2. Title").
  m <- regmatches(text,
    regexpr("^\\s*([0-9]+(?:\\.[0-9]+)+)\\.?\\s+[A-Za-z]", text, perl = TRUE))
  if (length(m) == 0L) return(NA_integer_)
  num <- regmatches(m, regexpr("[0-9]+(?:\\.[0-9]+)+", m, perl = TRUE))
  segments <- length(strsplit(num, ".", fixed = TRUE)[[1]])
  level <- min(segments, 6L)
  if (level < 2L) return(NA_integer_)
  level
}


#' Strip a leading literal figure label from a caption (#124)
#'
#' Word documents carry a manually-typed figure label ("Figure 1.",
#' "Fig. 2:", "Figure 3 —") at the start of the caption text, because Word
#' has no auto-numbering in this context. Quarto/Pandoc regenerate the
#' number and supplement word from the figure's crossref id, so the literal
#' label must be removed on harvest or the rendered output double-numbers
#' ("Figure 1. Figure 1. ..."). The figure number itself is discarded — the
#' caption keeps only its descriptive text.
#'
#' Conservative: only strips a leading `Fig`/`Figure` token followed by an
#' optional number and a separator (`.`/`:`/`—`/whitespace). Markdown
#' emphasis around the label (`**Figure 1.**`) is handled by stripping the
#' marker, the label, and re-balancing. Leaves the text unchanged if no
#' recognizable label prefix is present.
#'
#' @param caption Caption text (may contain leading markdown emphasis).
#' @return Caption text with any leading figure label removed.
#' @noRd
strip_figure_label <- function(caption) {
  if (is.null(caption) || length(caption) != 1L || is.na(caption)) {
    return(caption)
  }
  # Match optional leading bold/italic markers, then the Fig/Figure token,
  # then a figure NUMBER (digit-led, optionally letter-prefixed like "S1"),
  # then a separator, then optional trailing emphasis, then whitespace.
  #
  # The number is mandatory so a caption that merely begins with the word
  # "Figures"/"Figured" is not mistaken for a label. `Fig`/`Figure` must be
  # followed by whitespace or a dot before the number, so "Figures" (no
  # break) cannot match.
  pat <- paste0(
    "^\\s*",
    "(?:\\*\\*|\\*|_)?",                  # opening emphasis (optional)
    "\\s*[Ff]ig(?:ure)?\\.?",             # Fig / Figure / Fig.
    "(?:\\s+|(?=[0-9]))",                 # break before number (space, or dot already consumed)
    "[A-Za-z]?[0-9]+[A-Za-z]?",           # number: 1, 10, S1, 1a (digit required)
    "\\s*[.:–—\\)]?",                     # separator: . : en/em-dash )
    "\\s*(?:\\*\\*|\\*|_)?",              # closing emphasis (optional)
    "\\s+"                                # whitespace before caption body
  )
  stripped <- sub(pat, "", caption, perl = TRUE)
  # Only accept the strip if it actually removed a label (changed the
  # string and left non-empty content); otherwise return original.
  if (stripped != caption && nzchar(trimws(stripped))) stripped else caption
}


#' Convert XML content to QMD
#' @noRd
convert_to_qmd <- function(doc_xml, docx_path, extract_images, image_dir,
                           citation_map = list(), citation_id_map = list(),
                           bib_path = NULL,
                           reference_doc = NULL, existing_header = NULL,
                           insert_toc_placeholder = FALSE,
                           insert_version_history = FALSE,
                           output_path = NULL) {
  ns <- xml2::xml_ns(doc_xml)

  # Get document body
  body <- xml2::xml_find_first(doc_xml, ".//w:body", ns)

  # Extract footnotes, hyperlink relationships, and images from the document
  footnotes <- extract_footnotes(docx_path)
  hyperlink_rels <- extract_hyperlink_rels(docx_path)
  image_rels <- if (extract_images && !is.null(docx_path)) {
    extract_docx_images(docx_path, image_dir)
  } else {
    list()
  }

  # Build footer lookup from relationship file
  footer_lookup <- get_footer_lookup(docx_path)
  if (length(footer_lookup) > 0) {
    n_empty <- sum(vapply(footer_lookup, function(f) isTRUE(f$empty), logical(1)))
    n_content <- length(footer_lookup) - n_empty
    message("  Built footer lookup: ", n_content, " content + ", n_empty, " empty footer(s)")
  }

  # Build numbering format lookup for list style detection
  numbering_lookup <- build_numbering_lookup(docx_path)
  if (length(numbering_lookup) > 0) {
    message("  Built numbering lookup: ", length(numbering_lookup), " list definitions")
  }

  # Build style properties lookup for resolving custom heading styles
  # (e.g., "MDPI21heading1" -> "Heading1" via outlineLvl / basedOn chain)
  style_props <- build_style_props_lookup(docx_path)
  if (!is.null(docx_path) && length(style_props) == 0L) {
    message("[harvest] Style properties lookup is empty; custom heading styles ",
            "will not be resolved. Check that '", basename(docx_path),
            "' is readable.")
  }

  lines <- character()
  footnote_definitions <- character()
  footnote_counter <- 0
  active_comments <- character()  # Track comments spanning multiple paragraphs
  harvested_version_summary <- list()  # Collect version-summary values from field codes
  yaml_header <- list()
  yaml_header$bibliography <- bib_path
  yaml_header$reference_doc <- reference_doc

  # Harvest map: per-paragraph provenance tracking (para_index -> QMD lines)
  harvest_entries <- list()

  # Track whether we've inserted front matter placeholders
  placeholders_inserted <- FALSE

  # Process all child elements (paragraphs and tables)
  children <- xml2::xml_children(body)
  prev_was_list <- FALSE  # Track list transitions for blank line insertion
  pending_heading_id <- NULL  # Bookmark name from preceding bookmarkStart (#96)

  # List item position tracking for correct numbering
  # Word's numbering engine auto-increments items sharing the same numId,

  # but the XML only stores the definition start value (typically 1).
  # We track position within each (numId, ilvl) group to compute the
  # correct prefix character (a, b, c... or i, ii, iii...).
  list_item_counters <- list()  # Named list: "numId:ilvl" -> count
  prev_num_id <- NULL           # Previous list item's numId

  # Pre-scan for ADDIN DOCSTYLE field codes (v0.4+) and _docstyle_* bookmarks
  # (v0.3.1 compat). These mark generated content (version history, author plate,
  # TOC) that should be replaced with div placeholders during harvest.
  # Field codes take priority; bookmarks fill gaps for older documents.
  field_code_ranges <- detect_docstyle_field_codes(body, children, ns)
  bookmark_ranges <- detect_docstyle_bookmarks(body, children, ns)

  # Merge: field codes take priority, bookmarks fill gaps
  # Build a set of div names already covered by field codes
  fc_names <- vapply(field_code_ranges, function(r) r$name, character(1))
  # Map bookmark names to field code names for dedup
  bk_name_map <- c(
    `_docstyle_version_history` = "version-history",
    `_docstyle_author_plate` = "author-plate",
    `_docstyle_toc` = "toc"
  )
  # Keep bookmark ranges whose div name is not already covered by a field code

  bk_filtered <- Filter(function(r) {
    mapped <- bk_name_map[r$name]
    is.na(mapped) || !mapped %in% fc_names
  }, bookmark_ranges)
  all_ranges <- c(field_code_ranges, bk_filtered)

  # Detect native Word section breaks (only if no section field codes exist)
  # Native section breaks have w:sectPr in w:pPr -- these are from source documents
  # that haven't been through docstyle rendering yet.
  has_section_field_codes <- any(vapply(
    field_code_ranges,
    function(r) identical(r$type, "section"),
    logical(1)
  ))
  if (!has_section_field_codes) {
    # Try to load CSS page config for CSS-aware section naming (#19).
    # Output path gives us the project directory; load_page_config() reads
    # _quarto.yml + CSS -> page_config with $named sub-list of @page rules.
    harvest_page_config <- if (!is.null(output_path)) {
      tryCatch(
        load_page_config(dirname(output_path)),
        error = function(e) NULL
      )
    } else {
      NULL
    }

    native_breaks <- detect_native_section_breaks(children, ns)
    body_footer_info <- extract_body_sectpr_footer_info(body, ns)
    if (length(native_breaks) > 0 || !is.null(body_footer_info)) {
      native_section_ranges <- section_breaks_to_ranges(
        native_breaks, length(children),
        footer_lookup = footer_lookup,
        body_footer_info = body_footer_info,
        page_config = harvest_page_config
      )
      all_ranges <- c(all_ranges, native_section_ranges)
    }
  }

  # Warn about annotations inside marked ranges (they will be discarded)
  # Also harvest version history table back to YAML metadata
  harvested_version_history <- NULL
  # Abstract prose captured from an `abstract` div field-code range (#149).
  # The generic div handler emits the empty :::docstyle-abstract::: placeholder
  # at the right position but does not populate YAML; this captures the
  # relocated Abstract-styled paragraphs' text into `harvested_abstract`, which
  # is later serialised into the generated or preserved YAML via
  # `format_abstract_yaml()`.
  harvested_abstract <- NULL
  if (length(all_ranges) > 0) {
    warn_annotations_in_generated_content(all_ranges, children, ns)
    for (rng in all_ranges) {
      if (rng$name %in% c("_docstyle_version_history", "version-history")) {
        harvested_version_history <- parse_version_history_table(children, rng, ns)
        if (!is.null(harvested_version_history)) {
          message("  Harvested ", length(harvested_version_history),
                  " version history entries from Word table")
        }
        # Field code will emit div at correct position; disable Stage 2 placeholder
        insert_version_history <- FALSE
      }
      if (identical(rng$name, "abstract")) {
        harvested_abstract <- parse_abstract_range(children, rng, ns)
        if (!is.null(harvested_abstract)) {
          message("  Harvested abstract prose to YAML metadata")
        }
      }
    }
  }

  in_list_field_code <- FALSE  # Track if we're inside a list field code range
  deferred_div_close <- NULL   # For native-section ranges: close after content
  pending_table_range <- NULL  # For table ranges: deferred div_open pending width harvest
  pending_anchor_range <- NULL  # For anchor ranges: deferred div_open from field code

  # Figure state -- track image paragraphs to consolidate with following ImageCaption
  figure_meta      <- list()   # Accumulates entries for figures.json; keyed by docpr_id
  prev_was_image   <- FALSE    # Whether the previous paragraph contained a w:drawing
  prev_fig_id      <- NULL     # "#docstyle-fig-FIXME-N" for the most recent image
  prev_docpr_id    <- NULL     # Integer wp:docPr/@id for the most recent image
  in_figure_range              <- FALSE  # TRUE when inside a figure field code range (Phase 2)
  in_figure_range_id          <- NULL   # qmd_id from the field code payload
  in_figure_range_docpr       <- NULL   # docpr_id from the field code payload
  in_figure_range_orig_path   <- NULL   # original_path from the field code payload (may be NULL)

  for (i in seq_along(children)) {
    child <- children[[i]]

    # Check if inside a docstyle range (field code or bookmark)
    if (length(all_ranges) > 0) {
      range_hit <- check_bookmark_range(i, all_ranges)
      if (!is.null(range_hit)) {
        if (range_hit$type == "list") {
          # List ranges: emit wrapper, process content (don't skip)
          if (range_hit$is_first) {
            lines <- c(lines, "", range_hit$div_open)
            in_list_field_code <- TRUE
          }
          if (range_hit$is_last) {
            # Close the wrapper after processing remaining content below
            # (field code end paragraph has no text, just skip it)
            lines <- c(lines, range_hit$div_close)
            in_list_field_code <- FALSE
            harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
              para_index = i - 1L, type = "skipped"
            )
            next
          }
          # For start paragraph (field code begin), skip it (no text content)
          if (range_hit$is_first) {
            harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
              para_index = i - 1L, type = "skipped"
            )
            next
          }
          # Fall through to process list content paragraphs normally
        } else if (range_hit$type == "table") {
          # Table ranges: emit wrapper, process table content normally
          # Defer div_open until we find the w:tbl so we can harvest widths
          if (range_hit$is_first) {
            pending_table_range <- range_hit
            harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
              para_index = i - 1L, type = "skipped"
            )
            next  # Skip the field code start paragraph
          }
          if (range_hit$is_last) {
            # If we never found a table, emit the pending div_open now
            if (!is.null(pending_table_range)) {
              lines <- c(lines, "", pending_table_range$div_open)
              pending_table_range <- NULL
            }
            lines <- c(lines, range_hit$div_close)
            harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
              para_index = i - 1L, type = "skipped"
            )
            next  # Skip the field code end paragraph
          }
          # Fall through to process table content normally (w:tbl -> markdown)
        } else if (range_hit$type %in% c("anchor", "float")) {
          # Anchor ranges: defer div_open until we find the anchored content
          if (range_hit$is_first) {
            pending_anchor_range <- range_hit
            harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
              para_index = i - 1L, type = "skipped"
            )
            next  # Skip the field code start paragraph
          }
          if (range_hit$is_last) {
            # If we never found anchored content, emit the pending div now
            if (!is.null(pending_anchor_range)) {
              lines <- c(lines, "", pending_anchor_range$div_open,
                         pending_anchor_range$div_close)
              pending_anchor_range <- NULL
            }
            harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
              para_index = i - 1L, type = "skipped"
            )
            next  # Skip the field code end paragraph
          }
          # Fall through to process inner content normally
        } else if (range_hit$type == "native-section") {
          # Native section ranges: emit wrapper, process ALL content normally
          # (no field code marker paragraphs to skip)
          if (range_hit$is_first) {
            lines <- c(lines, "", range_hit$div_open)
          }
          if (range_hit$is_last) {
            deferred_div_close <- range_hit$div_close
          }
          # Fall through to process content normally
        } else if (range_hit$type == "section") {
          # Section field code ranges: emit wrapper, process content normally.
          # Start/end paragraphs contain only fldChar runs (no display text) -- skip them.
          if (range_hit$is_first) {
            lines <- c(lines, "", range_hit$div_open)
            harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
              para_index = i - 1L, type = "skipped"
            )
            next
          }
          if (range_hit$is_last) {
            lines <- c(lines, range_hit$div_close)
            harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
              para_index = i - 1L, type = "skipped"
            )
            next
          }
          # Fall through to process inner content paragraphs normally
        } else if (range_hit$type == "figure") {
          # Figure field code ranges: emit wrapper, process inner content normally.
          # Start/end paragraphs are fldChar markers -- skip them.
          # in_figure_range suppresses Phase 1 image+caption consolidation inside
          # the range -- the field code div_open/div_close is the authoritative wrapper.
          if (range_hit$is_first) {
            lines <- c(lines, "", range_hit$div_open)
            in_figure_range            <- TRUE
            in_figure_range_id        <- range_hit$id
            in_figure_range_docpr     <- range_hit$docpr_id
            in_figure_range_orig_path <- range_hit$original_path
            prev_was_image            <- FALSE
            harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
              para_index = i - 1L, type = "skipped"
            )
            next
          }
          if (range_hit$is_last) {
            in_figure_range            <- FALSE
            in_figure_range_orig_path <- NULL
            prev_was_image            <- FALSE
            prev_fig_id               <- NULL
            prev_docpr_id             <- NULL
            lines <- c(lines, range_hit$div_close)
            harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
              para_index = i - 1L, type = "skipped"
            )
            next
          }
          # Fall through to process inner content (image + caption) normally.
        } else if (range_hit$type == "version-history") {
          # Version-history content is harvested into YAML, not emitted as body div.
          # Silently skip the entire range -- no placeholder, no content.
          if (range_hit$is_first) {
            harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
              para_index = i - 1L, type = "range",
              range_name = range_hit$name, range_type = range_hit$type,
              para_span  = c(range_hit$start_idx - 1L, range_hit$end_idx - 1L)
            )
          }
          next
        } else {
          # Div ranges (bibliography, etc.): emit placeholder only, skip content
          if (range_hit$is_first) {
            line_start <- length(lines) + 1L
            lines <- c(lines, "", range_hit$div_open, range_hit$div_close)
            harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
              para_index   = i - 1L, type = "range",
              qmd_lines    = c(line_start, length(lines)),
              range_name   = range_hit$name, range_type = range_hit$type,
              para_span    = c(range_hit$start_idx - 1L, range_hit$end_idx - 1L),
              text_preview = range_hit$div_open
            )
          }
          next
        }
      }
    }

    node_name <- xml2::xml_name(child)

    # Skip bookmark elements themselves (they aren't paragraphs or tables).
    # bookmarkStart preceding a heading paragraph carries its cross-ref ID (#96).
    if (node_name %in% c("bookmarkStart", "bookmarkEnd")) {
      if (node_name == "bookmarkStart") {
        bm_name <- xml2::xml_attr(child, "name")
        if (!is.na(bm_name) && nchar(bm_name) > 0 &&
            !grepl("^(_docstyle_|_Toc|_Ref|_GoBack)", bm_name)) {
          pending_heading_id <- bm_name
        }
      }
      if (!is.null(deferred_div_close)) {
        lines <- c(lines, "", deferred_div_close)
        deferred_div_close <- NULL
      }
      harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
        para_index = i - 1L, type = "skipped"
      )
      next
    }

    if (node_name == "tbl") {
      # Check for floating table (w:tblpPr) BEFORE normal table handling
      if (is_floating_table(child, ns)) {
        float_props <- extract_float_properties(child, ns)
        # Determine class name from field code or default
        float_class <- "column-margin"  # Default for native floating tables
        if (!is.null(pending_anchor_range)) {
          float_class <- pending_anchor_range$class
          pending_anchor_range <- NULL
        }

        # Build div attributes from extracted positioning for round-trip fidelity
        div_attrs <- character(0)
        if (!is.null(float_props)) {
          if (!is.null(float_props$float_width))
            div_attrs <- c(div_attrs, paste0('float-width="', float_props$float_width, 'dxa"'))
          if (float_props$vertical_anchor != "text")
            div_attrs <- c(div_attrs, paste0('vertical-anchor="', float_props$vertical_anchor, '"'))
          if (float_props$horizontal_anchor != "margin")
            div_attrs <- c(div_attrs, paste0('horizontal-anchor="', float_props$horizontal_anchor, '"'))
          if (float_props$position_y != "0")
            div_attrs <- c(div_attrs, paste0('position-y="', float_props$position_y, 'dxa"'))
          if (float_props$position_x != "0")
            div_attrs <- c(div_attrs, paste0('position-x="', float_props$position_x, 'dxa"'))
        }

        if (length(div_attrs) > 0) {
          div_open <- paste0("::: {.", float_class, " ", paste(div_attrs, collapse = " "), "}")
        } else {
          div_open <- paste0("::: {.", float_class, "}")
        }

        lines <- c(lines, "", div_open)

        # Extract content from table cell(s)
        tc_nodes <- xml2::xml_find_all(child, ".//w:tc", ns = ns)
        for (tc in tc_nodes) {
          cell_paras <- xml2::xml_find_all(tc, "w:p", ns = ns)
          for (cp in cell_paras) {
            para_text <- tryCatch(
              extract_formatted_text(
                cp, ns, hyperlink_rels, citation_id_map, footnotes, footnote_counter
              ),
              error = function(e) {
                warning("[harvest] Failed to extract text from float table cell: ",
                        e$message, call. = FALSE)
                list(text = "", footnote_counter = footnote_counter)
              }
            )
            if (nchar(trimws(para_text$text)) > 0) {
              lines <- c(lines, para_text$text)
            }
            footnote_counter <- para_text$footnote_counter
          }
        }

        lines <- c(lines, ":::")
        harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
          para_index = i - 1L, type = "content",
          qmd_lines  = c(length(lines) - 1L, length(lines)),
          style      = "anchor-table"
        )
        next
      }

      # If inside a table field code range, harvest widths and emit div_open
      if (!is.null(pending_table_range)) {
        harvested_widths <- harvest_table_widths(child, ns)
        div_open <- pending_table_range$div_open
        if (!is.null(harvested_widths)) {
          # Replace or insert widths attribute in div_open
          if (grepl('widths="[^"]*"', div_open)) {
            div_open <- sub('widths="[^"]*"',
                           paste0('widths="', harvested_widths, '"'), div_open)
          } else {
            # Insert widths before closing }
            div_open <- sub("\\}$",
                           paste0(' widths="', harvested_widths, '"}'), div_open)
          }
        }
        lines <- c(lines, "", div_open)
        pending_table_range <- NULL
      }
      # Convert table to markdown (with inline formatting)
      table_result <- convert_table_to_md(child, ns, hyperlink_rels, citation_id_map,
                                           footnotes, footnote_counter)
      line_start <- length(lines) + 1L
      lines <- c(lines, "", table_result$lines, "")
      footnote_counter <- table_result$footnote_counter
      prev_was_list <- FALSE
      pending_heading_id <- NULL  # bookmarkStart before a table does not carry to next heading
      if (!is.null(deferred_div_close)) {
        lines <- c(lines, "", deferred_div_close)
        deferred_div_close <- NULL
      }
      harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
        para_index = i - 1L, type = "content",
        qmd_lines  = c(line_start, length(lines)),
        style      = "tbl"
      )
      next
    }

    if (node_name != "p") {
      if (!is.null(pending_table_range)) {
        # Non-paragraph, non-table node between field code and expected table;
        # discard the pending range to avoid attaching to a later table
        pending_table_range <- NULL
      }
      pending_heading_id <- NULL  # Non-content node does not carry bookmark to next heading
      if (!is.null(deferred_div_close)) {
        lines <- c(lines, "", deferred_div_close)
        deferred_div_close <- NULL
      }
      harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
        para_index = i - 1L, type = "skipped"
      )
      next
    }

    p <- child

    # Detect standalone page break paragraphs: <w:p><w:r><w:br w:type="page"/></w:r></w:p>
    # These are explicit page breaks in the source document (not section breaks).
    # Emit as ::: {.page-break} ::: div in QMD. Skip page breaks that are on or
    # adjacent to a section break paragraph -- those are handled by the section
    # div's page-break="true" attribute. Also skip if the next field code range
    # is a section with page-break="true" (the page break belongs to that div).
    page_br_nodes <- xml2::xml_find_all(p, ".//w:r/w:br[@w:type='page']", ns)
    if (length(page_br_nodes) > 0) {
      # Only treat as standalone page break if paragraph has no visible text
      text_nodes <- xml2::xml_find_all(p, ".//w:t", ns)
      para_text <- paste(xml2::xml_text(text_nodes), collapse = "")
      if (nchar(trimws(para_text)) == 0) {
        # Skip if this paragraph has a sectPr (page break is part of section break)
        has_sect <- !inherits(
          xml2::xml_find_first(p, ".//w:pPr/w:sectPr", ns), "xml_missing")
        # Skip if the next paragraph has a sectPr (page break precedes section break)
        next_has_sect <- FALSE
        if (i < length(children)) {
          next_child <- children[[i + 1L]]
          if (xml2::xml_name(next_child) == "p") {
            next_has_sect <- !inherits(
              xml2::xml_find_first(next_child, ".//w:pPr/w:sectPr", ns), "xml_missing")
          }
        }
        # Skip if next range is a section with page-break="true"
        # (the page break was emitted by the section div's page-break attribute)
        next_is_section_with_pb <- FALSE
        if (length(all_ranges) > 0) {
          for (rng in all_ranges) {
            if (identical(rng$type, "section") && rng$start_idx > i &&
                rng$start_idx <= i + 2L &&
                grepl('page-break="true"', rng$div_open, fixed = TRUE)) {
              next_is_section_with_pb <- TRUE
              break
            }
          }
        }
        if (!has_sect && !next_has_sect && !next_is_section_with_pb) {
          lines <- c(lines, "", "::: {.page-break}", ":::", "")
          if (!is.null(deferred_div_close)) {
            lines <- c(lines, deferred_div_close)
            deferred_div_close <- NULL
          }
        }
        pending_heading_id <- NULL  # Page-break paragraph does not carry bookmark to next heading
        harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
          para_index = i - 1L, type = "skipped", style = "page-break"
        )
        next
      }
    }

    # Check for grouped figure (wp:anchor with wpg:wgp containing pic:pic + wps:txbx)
    # Must run before is_text_box and is_anchored_image (most specific first)
    if (is_grouped_figure(p, ns)) {
      group_props <- extract_group_properties(p, ns)
      group_content <- extract_group_content(p, ns)

      # Determine class from pending anchor range or default
      anchor_class <- "column-margin"
      if (!is.null(pending_anchor_range)) {
        anchor_class <- pending_anchor_range$class
        pending_anchor_range <- NULL
      }

      # Build div attributes from positioning
      div_attrs <- character(0)
      if (!is.null(group_props)) {
        if (!is.null(group_props$float_width))
          div_attrs <- c(div_attrs, paste0('float-width="', group_props$float_width, 'dxa"'))
        if (!is.null(group_props$caption_y))
          div_attrs <- c(div_attrs, paste0('caption-y="', group_props$caption_y, 'dxa"'))
        if (!is.null(group_props$image_height))
          div_attrs <- c(div_attrs, paste0('image-height="', group_props$image_height, 'dxa"'))
        if (group_props$vertical_anchor != "text")
          div_attrs <- c(div_attrs, paste0('vertical-anchor="', group_props$vertical_anchor, '"'))
        if (group_props$horizontal_anchor != "margin")
          div_attrs <- c(div_attrs, paste0('horizontal-anchor="', group_props$horizontal_anchor, '"'))
        if (group_props$position_y != "0")
          div_attrs <- c(div_attrs, paste0('position-y="', group_props$position_y, 'dxa"'))
        if (group_props$position_x != "0")
          div_attrs <- c(div_attrs, paste0('position-x="', group_props$position_x, 'dxa"'))
        if (group_props$z_layer != "front")
          div_attrs <- c(div_attrs, paste0('z-layer="', group_props$z_layer, '"'))
      }

      if (length(div_attrs) > 0) {
        div_open <- paste0("::: {.", anchor_class, " ", paste(div_attrs, collapse = " "), "}")
      } else {
        div_open <- paste0("::: {.", anchor_class, "}")
      }

      lines <- c(lines, "", div_open)

      # Emit image using image relationship
      img_emitted <- FALSE
      if (!is.na(group_content$image_rel_id) &&
          !is.null(image_rels[[group_content$image_rel_id]])) {
        img_path <- image_rels[[group_content$image_rel_id]]
        lines <- c(lines, paste0("![](", img_path, ")"))
        img_emitted <- TRUE
      }

      if (!img_emitted) {
        warning("[harvest] Grouped figure at paragraph ", i,
                " skipped: image relationship not found (rel_id=",
                group_content$image_rel_id %||% "NA", ")", call. = FALSE)
        # Remove the div_open and blank line we added
        lines <- lines[seq_len(length(lines) - 2L)]
        harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
          para_index = i - 1L, type = "skipped", style = "grouped-figure-no-image"
        )
        next
      }

      # Emit blank line then caption paragraphs
      lines <- c(lines, "")
      if (length(group_content$caption_nodes) > 0) {
        for (cap_node in group_content$caption_nodes) {
          cap_result <- extract_formatted_text(cap_node, ns, image_rels = image_rels)
          if (nzchar(trimws(cap_result$text))) {
            lines <- c(lines, cap_result$text)
          }
        }
      }

      lines <- c(lines, ":::", "")

      harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
        para_index = i - 1L, type = "grouped-figure", style = "grouped-figure"
      )
      next
    }

    # Check for text box (wp:anchor with wps:txbx) before anchored image check
    if (is_text_box(p, ns)) {
      tb_props <- extract_text_box_properties(p, ns)
      tb_content <- extract_text_box_content(p, ns)

      # Determine class from pending anchor range or default
      tb_class <- "column-margin"
      if (!is.null(pending_anchor_range)) {
        tb_class <- pending_anchor_range$class
        pending_anchor_range <- NULL
      }

      # Build div attributes
      div_attrs <- character(0)
      div_attrs <- c(div_attrs, 'content-mode="textbox"')
      if (!is.null(tb_props)) {
        if (!is.null(tb_props$float_width))
          div_attrs <- c(div_attrs, paste0('float-width="', tb_props$float_width, 'dxa"'))
        if (tb_props$vertical_anchor != "text")
          div_attrs <- c(div_attrs, paste0('vertical-anchor="', tb_props$vertical_anchor, '"'))
        if (tb_props$horizontal_anchor != "margin")
          div_attrs <- c(div_attrs, paste0('horizontal-anchor="', tb_props$horizontal_anchor, '"'))
        if (tb_props$position_y != "0")
          div_attrs <- c(div_attrs, paste0('position-y="', tb_props$position_y, 'dxa"'))
        if (tb_props$position_x != "0")
          div_attrs <- c(div_attrs, paste0('position-x="', tb_props$position_x, 'dxa"'))
        if (tb_props$z_layer != "front")
          div_attrs <- c(div_attrs, paste0('z-layer="', tb_props$z_layer, '"'))
      }

      div_open <- paste0("::: {.", tb_class, " ", paste(div_attrs, collapse = " "), "}")
      lines <- c(lines, "", div_open)

      # Recursively convert content paragraphs to markdown
      for (cp in tb_content) {
        cp_result <- extract_formatted_text(cp, ns, image_rels = image_rels)
        if (nzchar(trimws(cp_result$text))) {
          lines <- c(lines, cp_result$text)
        }
      }

      lines <- c(lines, ":::")
      harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
        para_index = i - 1L, type = "content",
        qmd_lines  = c(length(lines) - 1L, length(lines)),
        style      = "anchor-textbox"
      )
      next
    }

    # Check for anchored image (wp:anchor with pic:pic) before general paragraph handling
    if (is_anchored_image(p, ns)) {
      anchor_props <- extract_anchor_image_properties(p, ns)

      # Determine class from pending anchor range or default
      anchor_class <- "column-margin"
      if (!is.null(pending_anchor_range)) {
        anchor_class <- pending_anchor_range$class
        pending_anchor_range <- NULL
      }

      # Build div attributes from positioning
      div_attrs <- character(0)
      if (!is.null(anchor_props)) {
        if (!is.null(anchor_props$float_width))
          div_attrs <- c(div_attrs, paste0('float-width="', anchor_props$float_width, 'dxa"'))
        if (anchor_props$vertical_anchor != "text")
          div_attrs <- c(div_attrs, paste0('vertical-anchor="', anchor_props$vertical_anchor, '"'))
        if (anchor_props$horizontal_anchor != "margin")
          div_attrs <- c(div_attrs, paste0('horizontal-anchor="', anchor_props$horizontal_anchor, '"'))
        if (anchor_props$position_y != "0")
          div_attrs <- c(div_attrs, paste0('position-y="', anchor_props$position_y, 'dxa"'))
        if (anchor_props$position_x != "0")
          div_attrs <- c(div_attrs, paste0('position-x="', anchor_props$position_x, 'dxa"'))
        if (anchor_props$z_layer != "front")
          div_attrs <- c(div_attrs, paste0('z-layer="', anchor_props$z_layer, '"'))
      }

      if (length(div_attrs) > 0) {
        div_open <- paste0("::: {.", anchor_class, " ", paste(div_attrs, collapse = " "), "}")
      } else {
        div_open <- paste0("::: {.", anchor_class, "}")
      }

      lines <- c(lines, "", div_open)

      # Extract image as markdown -- get blip relationship ID
      ns_img <- c(ns,
        wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
        a = "http://schemas.openxmlformats.org/drawingml/2006/main"
      )
      anchor_node <- xml2::xml_find_first(p, ".//wp:anchor", ns = ns_img)
      blip <- xml2::xml_find_first(anchor_node, ".//a:blip", ns = ns_img)
      img_emitted <- FALSE
      if (!inherits(blip, "xml_missing")) {
        # xml2::xml_attr returns NA (not NULL) for missing attributes
        embed_id <- xml2::xml_attr(blip, "embed")
        if (is.na(embed_id)) {
          # Fallback: try namespaced r:embed
          embed_id <- xml2::xml_attr(blip, "r:embed")
        }
        if (!is.na(embed_id) && !is.null(image_rels[[embed_id]])) {
          img_path <- image_rels[[embed_id]]
          lines <- c(lines, paste0("![](", img_path, ")"))
          img_emitted <- TRUE
        }
      }

      # If image extraction failed, remove the empty div we just opened
      if (!img_emitted) {
        warning("[harvest] Anchored image at paragraph ", i,
                " skipped: image relationship not found", call. = FALSE)
        # Remove the div_open and blank line we added
        lines <- lines[seq_len(length(lines) - 2L)]
        harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
          para_index = i - 1L, type = "skipped",
          qmd_lines  = c(NA_integer_, NA_integer_),
          style      = "anchor-image-failed"
        )
        next
      }

      lines <- c(lines, ":::")
      harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
        para_index = i - 1L, type = "content",
        qmd_lines  = c(length(lines) - 1L, length(lines)),
        style      = "anchor-image"
      )
      next
    }

    # Get paragraph style
    style <- xml2::xml_text(xml2::xml_find_first(p, ".//w:pStyle/@w:val", ns))
    if (is.na(style)) style <- "Normal"

    # Check for character styles (DateChar, VersionChar) for inline metadata
    # These are used when date/version are rendered as character styles via char-style.lua
    date_char_runs <- xml2::xml_find_all(p, ".//w:r[w:rPr/w:rStyle[@w:val='DateChar' or @w:val='Date']]", ns)
    if (length(date_char_runs) > 0) {
      date_text <- paste(sapply(date_char_runs, function(r) {
        xml2::xml_text(xml2::xml_find_first(r, ".//w:t", ns))
      }), collapse = "")
      if (nchar(trimws(date_text)) > 0 && is.null(yaml_header$date)) {
        yaml_header$date <- trimws(date_text)
      }
    }

    version_char_runs <- xml2::xml_find_all(p, ".//w:r[w:rPr/w:rStyle[@w:val='VersionChar' or @w:val='Version']]", ns)
    if (length(version_char_runs) > 0) {
      version_text <- paste(sapply(version_char_runs, function(r) {
        xml2::xml_text(xml2::xml_find_first(r, ".//w:t", ns))
      }), collapse = "")
      if (nchar(trimws(version_text)) > 0 && is.null(yaml_header$version)) {
        yaml_header$version <- trimws(version_text)
      }
    }

    # Check for list numbering (numPr indicates a list item)
    has_numpr <- length(xml2::xml_find_first(p, ".//w:numPr", ns)) > 0
    list_level <- xml2::xml_text(xml2::xml_find_first(p, ".//w:numPr/w:ilvl/@w:val", ns))
    if (is.na(list_level)) list_level <- "0"
    list_level <- as.integer(list_level)

    # Extract numId for numbering format lookup
    num_id <- xml2::xml_text(xml2::xml_find_first(p, ".//w:numPr/w:numId/@w:val", ns))
    if (is.na(num_id)) num_id <- NULL

    # Determine if this paragraph is a list item (by style or numPr)
    is_list_item <- has_numpr || style %in% c(
      "ListParagraph", "ListBullet", "ListBullet2", "ListBullet3",
      "ListNumber", "ListNumber2", "p1"
    )

    # Get text content with formatting (bold, italic, footnotes, comments, hyperlinks)
    # Pass citation_id_map for field-code-boundary-aware citation replacement
    text_result <- extract_formatted_text(p, ns, footnotes, footnote_counter, active_comments,
                                          hyperlink_rels, citation_id_map = citation_id_map,
                                          image_rels = image_rels)
    text <- text_result$text
    footnote_counter <- text_result$footnote_counter
    footnote_definitions <- c(footnote_definitions, text_result$new_definitions)
    active_comments <- text_result$active_comments  # Update for multi-paragraph comments

    # #124: strip the literal "Figure N." label Word stores in caption text.
    # Quarto regenerates the number + supplement from the figure crossref id,
    # so keeping the literal label would double-number the rendered figure.
    if (identical(style, "ImageCaption")) {
      text <- strip_figure_label(text)
    }
    # Accumulate version-summary values from field codes
    if (length(text_result$version_summary) > 0) {
      for (nm in names(text_result$version_summary)) {
        harvested_version_summary[[nm]] <- text_result$version_summary[[nm]]
      }
    }

    # Replace in-text citations with Quarto format
    # Only use text-based replacement when field-code-boundary detection is NOT
    # available. When citation_id_map is populated, all Zotero citations are
    # handled by extract_formatted_text() via XML field code boundaries.
    # Text-based replacement must be skipped because it pattern-matches
    # formatted citation strings like "(1)" against literal text, causing
    # misplacement when Vancouver-style numbers collide with list numbering.
    if (length(citation_id_map) == 0) {
      text <- replace_citations(text, citation_map)
    }

    # Escape parenthetical numbering at paragraph start to prevent Pandoc
    # from interpreting (1), (a), etc. as ordered list items (#64)
    if (!is_list_item) {
      text <- sub("^\\(([0-9]+|[a-zA-Z])\\) ", "\\\\(\\1) ", text)
    }

    # Restore original image path inside a figure field code range.
    # At render time, figure.lua embeds the original QMD image path in the
    # field code payload (original_path). On re-harvest, Word's embedded
    # image (images/rIdN.png) is replaced with the original source path so
    # the round-trip preserves the author's file reference.
    if (in_figure_range && grepl("^!\\[", text) &&
        !is.null(in_figure_range_orig_path) && nzchar(in_figure_range_orig_path)) {
      text <- sub("\\]\\([^)]+\\)$",
                  paste0("](", in_figure_range_orig_path, ")"), text)
    }

    # Case A: image paragraph -- open figure div, defer close until next iteration.
    # extract_formatted_text() returns "![alt](path)" for w:drawing paragraphs.
    # Suppressed inside a figure field code range (Phase 2) -- the field code
    # already provides the div wrapper; just emit the image line directly.
    if (grepl("^!\\[", text) && !in_figure_range) {
      docpr_id <- extract_drawing_docpr_id(p, ns)
      # Visible id must be a valid Quarto crossref target (fig- prefix) so the
      # figure numbers and cross-references in PDF/Typst output (#124). The
      # original Word docPr identity is preserved separately in the field-code
      # payload (docpr_id) and figures.json on re-render — not fused into the
      # visible id. Deterministic (fig-<docPrId>) for round-trip stability;
      # authors may rename to a meaningful slug.
      fig_id   <- if (!is.null(docpr_id)) paste0("fig-", docpr_id) else "fig-unknown"
      lines <- c(lines, "", paste0("::: {#", fig_id, " .figure}"), text)
      prev_was_image    <- TRUE
      prev_fig_id       <- fig_id
      prev_docpr_id     <- docpr_id
      prev_was_list     <- FALSE
      pending_heading_id <- NULL  # Image paragraph does not carry bookmark to next heading
      next
    }

    # Skip empty paragraphs (but preserve some spacing)
    if (nchar(trimws(text)) == 0) {
      # An empty paragraph breaks image->caption adjacency -- close any open figure div
      if (prev_was_image && !in_figure_range) {
        lines <- c(lines, ":::", "")
        prev_was_image <- FALSE
        prev_fig_id    <- NULL
        prev_docpr_id  <- NULL
      }
      if (length(lines) > 0 && lines[length(lines)] != "") {
        lines <- c(lines, "")
      }
      prev_was_list <- FALSE
      # Reset list counters if empty paragraph is not a list item
      if (!is_list_item) {
        list_item_counters <- list()
        prev_num_id <- NULL
      }
      # Emit deferred closing div if this was the last paragraph of a native section
      if (!is.null(deferred_div_close)) {
        lines <- c(lines, "", deferred_div_close)
        deferred_div_close <- NULL
      }
      pending_heading_id <- NULL  # Empty paragraph does not carry bookmark to next heading
      harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
        para_index = i - 1L, type = "skipped", style = style
      )
      next
    }

    # Determine indent for nested lists
    indent <- paste(rep("  ", list_level), collapse = "")

    # Track list item position for correct numbering (a, b, c... not a, a, a...)
    # Word uses different numIds for parent/child lists but they share a visual
    # sequence. We track counters per (numId, ilvl) pair and only reset all
    # counters when a non-list paragraph breaks the sequence.
    list_item_pos <- NULL
    if (is_list_item && !is.null(num_id)) {
      counter_key <- paste0(num_id, ":", list_level)
      current <- list_item_counters[[counter_key]]
      list_item_counters[[counter_key]] <- if (is.null(current)) 1L else current + 1L
      prev_num_id <- num_id
      list_item_pos <- list_item_counters[[counter_key]]
    } else if (!is_list_item) {
      # Non-list paragraph: reset all list tracking
      list_item_counters <- list()
      prev_num_id <- NULL
    }

    # Figure handling -- consolidate image paragraph + following ImageCaption into a div.
    # Cases B and C are suppressed inside figure field code ranges (Phase 2):
    # the ImageCaption paragraph is emitted normally as the last line before :::
    # Inside a figure range (Phase 2 re-harvest), capture the caption for figures.json.
    if (style == "ImageCaption" && in_figure_range && !is.null(in_figure_range_id)) {
      if (!is.null(in_figure_range_docpr)) {
        figure_meta[[as.character(in_figure_range_docpr)]] <- list(
          docpr_id      = in_figure_range_docpr,
          qmd_id        = in_figure_range_id,
          caption       = text,
          alt           = "",
          width         = NULL,
          align         = NULL,
          wrap          = NULL,
          original_path = NULL
        )
      }
      # Fall through -- caption emitted normally inside the field code div
    }
    # Case B: ImageCaption immediately following an image paragraph.
    if (style == "ImageCaption" && prev_was_image && !in_figure_range) {
      lines <- c(lines, "", text, ":::", "")
      if (!is.null(prev_docpr_id)) {
        figure_meta[[as.character(prev_docpr_id)]] <- list(
          docpr_id      = prev_docpr_id,
          qmd_id        = prev_fig_id,
          caption       = text,
          alt           = "",
          width         = NULL,
          align         = NULL,
          wrap          = NULL,
          original_path = NULL
        )
      }
      prev_was_image    <- FALSE
      prev_fig_id       <- NULL
      prev_docpr_id     <- NULL
      pending_heading_id <- NULL  # ImageCaption paragraph does not carry bookmark to next heading
      next
    }
    # Case C: any non-ImageCaption paragraph after an image -- close div without caption.
    if (prev_was_image && !in_figure_range) {
      lines <- c(lines, ":::", "")
      prev_was_image <- FALSE
      prev_fig_id    <- NULL
      prev_docpr_id  <- NULL
    }

    # Normalize style names for Version variants (Version0, Version1, etc.)
    # Word sometimes creates these when users apply styles manually
    if (grepl("^Version\\d*$", style, ignore.case = TRUE)) {
      style <- "Version"
    }

    # Resolve custom/journal style IDs to canonical dispatch keys.
    # E.g., "MDPI21heading1" (outlineLvl=0) -> "Heading1"; unknown -> unchanged.
    dispatch_style <- resolve_to_canonical(style, style_props)

    # Handle different styles
    line <- switch(dispatch_style,
      "Title" = {
        yaml_header$title <- text
        NULL
      },
      "Subtitle" = {
        yaml_header$subtitle <- text
        NULL
      },
      "Date" = {
        yaml_header$date <- text
        NULL
      },
      "Version" = {
        # Extract version number if prefixed with "Version "
        version_text <- text
        if (grepl("^Version\\s+", version_text, ignore.case = TRUE)) {
          version_text <- sub("^Version\\s+", "", version_text, ignore.case = TRUE)
        }
        yaml_header$version <- trimws(version_text)
        NULL
      },
      "Heading1" = paste0("\n# ", text),
      "Heading2" = paste0("\n## ", text),
      "Heading3" = paste0("\n### ", text),
      "Heading4" = paste0("\n#### ", text),
      "Heading5" = paste0("\n##### ", text),
      "Heading6" = paste0("\n###### ", text),
      "ListParagraph" = paste0(list_prefix(numbering_lookup, num_id, list_level, indent, list_item_pos), text),
      "ListBullet" = paste0(indent, "- ", text),
      "ListBullet2" = paste0("  - ", text),
      "ListBullet3" = paste0("    - ", text),
      "ListNumber" = paste0(indent, "1. ", text),
      "ListNumber2" = paste0("  1. ", text),
      "p1" = paste0(indent, "- ", text),  # Custom POPCORN list style
      "TOC1" = NULL,  # Skip TOC entries
      "TOC2" = NULL,
      "TOC3" = NULL,
      # Default: list numbering, then numbered-heading recovery, else text
      {
        if (has_numpr) {
          paste0(list_prefix(numbering_lookup, num_id, list_level, indent, list_item_pos), text)
        } else {
          # #125: a numbered subsection on a style that didn't resolve to
          # a heading would otherwise flatten to a plain paragraph. Recover
          # the heading at the depth implied by its section number. Warn so
          # the user knows a heading was inferred (the durable fix is to
          # apply a proper heading style in Word).
          inferred_level <- if (!is_list_item) {
            infer_numbered_heading_level(text)
          } else {
            NA_integer_
          }
          if (!is.na(inferred_level)) {
            message("[harvest] Recovered numbered heading (level ",
                    inferred_level, ") from unresolved style '", style,
                    "': ", substr(text, 1, 60))
            paste0("\n", strrep("#", inferred_level), " ", text)
          } else {
            text
          }
        }
      }
    )

    if (!is.null(line)) {
      # Determine if this is a "normal" body paragraph (not heading, not list).
      # A heading is either a resolved HeadingN style OR a recovered numbered
      # heading (#125), both of which render as a line beginning "\n#".
      is_heading <- grepl("^Heading[0-9]", dispatch_style) ||
        grepl("^\n#+ ", line)
      is_normal_para <- !is_list_item && !is_heading && !grepl("^\n#", line)

      # Insert TOC and version-history placeholders before first heading (Stage 2)
      if (is_heading && !placeholders_inserted) {
        if (insert_toc_placeholder) {
          lines <- c(lines, "", "::: toc", ":::")
        }
        if (insert_version_history) {
          lines <- c(lines, "", "::: version-history", ":::")
        }
        placeholders_inserted <- TRUE
      }

      # Add blank line before list starts (transition from non-list to list)
      # This is required for Pandoc to recognize the list properly
      if (is_list_item && !prev_was_list && length(lines) > 0 && lines[length(lines)] != "") {
        lines <- c(lines, "")
      }
      # Add blank line after list ends (transition from list to non-list)
      # This prevents the next paragraph from being merged with the last list item
      if (!is_list_item && prev_was_list && length(lines) > 0 && lines[length(lines)] != "") {
        lines <- c(lines, "")
      }
      # Add blank line between consecutive normal paragraphs
      # In Word, each <w:p> is a separate paragraph; in Markdown, paragraphs need blank line separation
      if (is_normal_para && !prev_was_list && length(lines) > 0 &&
          lines[length(lines)] != "" && !grepl("^#", lines[length(lines)])) {
        lines <- c(lines, "")
      }
      line_start <- length(lines) + 1L
      lines <- c(lines, line)
      # Append cross-ref ID from preceding bookmarkStart to heading (#96)
      if (is_heading && !is.null(pending_heading_id)) {
        lines[length(lines)] <- paste0(lines[length(lines)], " {#", pending_heading_id, "}")
      } else if (!is.null(pending_heading_id)) {
        message("[harvest] bookmark '", pending_heading_id, "' precedes a non-heading paragraph ('",
                style, "') -- cross-reference ID not emitted")
      }
      pending_heading_id <- NULL  # Consume -- only applies to immediate next heading
      # Harvest map: content paragraph
      harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
        para_index   = i - 1L,
        type         = "content",
        qmd_lines    = c(line_start, length(lines)),
        para_hash    = para_plain_text_hash(child, ns),
        style        = style,
        text_preview = trimws(line)
      )
    } else {
      # NULL line -- paragraph consumed into YAML header (Title, Date, etc.)
      pending_heading_id <- NULL  # Metadata paragraphs do not carry bookmark to next heading
      harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
        para_index = i - 1L,
        type       = "metadata",
        style      = style,
        para_hash  = para_plain_text_hash(child, ns)
      )
    }

    # Update list tracking (NULL lines like Title don't change state)
    if (!is.null(line)) {
      prev_was_list <- is_list_item
    }

    # Emit deferred closing div after processing last paragraph of native section
    if (!is.null(deferred_div_close)) {
      lines <- c(lines, "", deferred_div_close)
      deferred_div_close <- NULL
    }
  }

  # Write harvest-map.json sidecar (paragraph-level provenance for diff-and-patch)
  if (!is.null(output_path)) {
    # Compute section-level summaries for hierarchical change detection.
    # Wrapped in tryCatch: section summaries are non-critical enrichment, so a
    # digest or regex failure here must not abort a completed harvest.
    harvest_sections <- tryCatch(
      compute_section_summaries(harvest_entries, all_ranges, lines),
      error = function(e) {
        message("[harvest_map] WARNING: section summary computation failed: ",
                conditionMessage(e),
                " -- harvest map will be written without sections.")
        NULL
      }
    )
    write_harvest_map(
      entries        = harvest_entries,
      source_docx    = docx_path,
      para_count     = length(children),
      qmd_line_count = length(lines),
      sections       = harvest_sections,
      output_path    = output_path
    )
  }

  # Write figures.json sidecar if any figures were harvested
  if (length(figure_meta) > 0 && !is.null(output_path)) {
    figures_dir  <- file.path(dirname(normalizePath(output_path, mustWork = FALSE)), "_docstyle")
    dir.create(figures_dir, showWarnings = FALSE, recursive = TRUE)
    figures_path <- file.path(figures_dir, "figures.json")
    existing_figures <- if (file.exists(figures_path)) {
      jsonlite::read_json(figures_path, simplifyVector = FALSE)
    } else {
      list()
    }
    merged_figures <- modifyList(existing_figures, figure_meta)
    jsonlite::write_json(merged_figures, figures_path, pretty = TRUE, auto_unbox = TRUE)
    message("[harvest] wrote ", length(figure_meta), " figure(s) to figures.json")
  }

  # Build YAML header (use existing if preserving, otherwise generate new)
  if (!is.null(existing_header)) {
    # Use the preserved header, updating version-history if harvested from table
    if (!is.null(harvested_version_history)) {
      existing_header <- update_yaml_version_history(
        existing_header, harvested_version_history)
    }
    # Update version-summary if harvested from field codes
    if (length(harvested_version_summary) > 0) {
      existing_header <- update_yaml_version_summary(
        existing_header, harvested_version_summary)
    }
    # Restore abstract prose if captured from an abstract field-code range
    # and the preserved header does not already carry an abstract: key (#149).
    if (!is.null(harvested_abstract) &&
        !any(grepl("^abstract\\s*:", existing_header))) {
      abstract_yaml <- format_abstract_yaml(harvested_abstract)
      close_idx <- which(existing_header == "---")
      if (length(close_idx) >= 2) {
        # Insert before the closing delimiter (second "---").
        at <- close_idx[[2]]
        existing_header <- append(existing_header, abstract_yaml, after = at - 1L)
      } else {
        existing_header <- c(existing_header, abstract_yaml)
      }
    }
    yaml_lines <- c(existing_header, "")
  } else {
    # Generate new header from document content
    yaml_lines <- "---"
    if (!is.null(yaml_header$title)) {
      yaml_lines <- c(yaml_lines, paste0('title: "', escape_yaml(yaml_header$title), '"'))
    }
    if (!is.null(yaml_header$subtitle)) {
      yaml_lines <- c(yaml_lines, paste0('subtitle: "', escape_yaml(yaml_header$subtitle), '"'))
    }
    if (!is.null(yaml_header$date)) {
      yaml_lines <- c(yaml_lines, paste0('date: "', escape_yaml(yaml_header$date), '"'))
    }
    if (!is.null(yaml_header$version)) {
      yaml_lines <- c(yaml_lines, paste0('version: "', escape_yaml(yaml_header$version), '"'))
    }
    # Note: format: and bibliography: are intentionally omitted.
    # format is controlled by _quarto.yml (docstyle-docx); adding it here
    # bypasses Lua filters. bibliography/csl are handled by Zotero field codes.
    # Add version-history: harvested from Word table or initial placeholder
    if (!is.null(harvested_version_history)) {
      yaml_lines <- c(yaml_lines, format_version_history_yaml(harvested_version_history))
    } else if (insert_version_history) {
      yaml_lines <- c(yaml_lines,
        "version-history:",
        "  - version: \"0.1.0\"",
        paste0("    date: \"", Sys.Date(), "\""),
        "    description: \"Initial harvest from Word document\""
      )
    }
    # Add version-summary: harvested from field codes
    if (length(harvested_version_summary) > 0) {
      yaml_lines <- c(yaml_lines, format_version_summary_yaml(harvested_version_summary))
    }
    # Add abstract: harvested from an abstract field-code range (#149).
    # Restored to YAML (not body prose) so a subsequent render to any format
    # still finds the abstract in metadata where the relocation / Typst
    # template / JATS validator expect it.
    if (!is.null(harvested_abstract)) {
      yaml_lines <- c(yaml_lines, format_abstract_yaml(harvested_abstract))
    }
    yaml_lines <- c(yaml_lines, "---", "")
  }

  # Add footnote definitions at the end if any were found
  if (length(footnote_definitions) > 0) {
    lines <- c(lines, "", footnote_definitions)
  }

  # Combine and clean up multiple blank lines
  result <- c(yaml_lines, lines)
  result <- gsub("\n{3,}", "\n\n", paste(result, collapse = "\n"))
  strsplit(result, "\n")[[1]]
}


#' Escape special characters for YAML
#' @noRd
escape_yaml <- function(text) {
  gsub('"', '\\"', text)
}


#' Harvest column widths from a Word table
#'
#' Reads `w:gridCol` widths from the OOXML table grid and converts them
#' to percentage values. Used to capture user-adjusted column widths
#' during harvest so they flow back into the QMD div-fence attributes.
#'
#' @param tbl xml2 node for a `w:tbl` element
#' @param ns XML namespaces
#' @return Comma-separated percentage string (e.g., "30,70"), or NULL if
#'   no grid columns found
#' @noRd
harvest_table_widths <- function(tbl, ns) {
  grid_cols <- xml2::xml_find_all(tbl, "w:tblGrid/w:gridCol", ns)
  if (length(grid_cols) == 0) return(NULL)

  widths_raw <- xml2::xml_attr(grid_cols, "w")
  widths_twips <- as.numeric(widths_raw)

  # Skip if any values are NA

  if (any(is.na(widths_twips))) return(NULL)

  total <- sum(widths_twips)
  if (total == 0) return(NULL)

  pcts <- round(widths_twips / total * 100)

  # Adjust rounding to sum to exactly 100
  diff <- 100L - sum(pcts)
  if (diff != 0) {
    pcts[which.max(pcts)] <- pcts[which.max(pcts)] + diff
  }

  paste(pcts, collapse = ",")
}


#' Convert Word table to markdown
#'
#' Converts a Word table to markdown format. Detects merged cells (horizontal
#' and vertical) and emits a warning since markdown tables cannot represent
#' merged cells. Preserves inline formatting (bold, italic, comments, links)
#' when hyperlink_rels and citation_id_map are provided. Propagates
#' active_comments across paragraphs within each cell for correct comment
#' range handling.
#'
#' @return List with `lines` (character vector of markdown) and
#'   `footnote_counter` (updated counter for sequential numbering).
#' @noRd
convert_table_to_md <- function(tbl, ns, hyperlink_rels = list(),
                                citation_id_map = list(),
                                footnotes = list(),
                                footnote_counter = 0) {
  rows <- xml2::xml_find_all(tbl, ".//w:tr", ns)

  if (length(rows) == 0) return(list(lines = character(), footnote_counter = footnote_counter))

  # Check for merged cells and warn
  has_horizontal_merge <- FALSE
  has_vertical_merge <- FALSE

  for (row in rows) {
    cells <- xml2::xml_find_all(row, ".//w:tc", ns)
    for (cell in cells) {
      # Check for horizontal merge (gridSpan > 1)
      grid_span <- xml2::xml_find_first(cell, ".//w:tcPr/w:gridSpan", ns)
      if (!inherits(grid_span, "xml_missing")) {
        span_val <- xml2::xml_attr(grid_span, "val")
        if (!is.na(span_val) && as.integer(span_val) > 1) {
          has_horizontal_merge <- TRUE
        }
      }

      # Check for vertical merge (vMerge)
      v_merge <- xml2::xml_find_first(cell, ".//w:tcPr/w:vMerge", ns)
      if (!inherits(v_merge, "xml_missing")) {
        has_vertical_merge <- TRUE
      }
    }
  }

  if (has_horizontal_merge || has_vertical_merge) {
    merge_types <- c()
    if (has_horizontal_merge) merge_types <- c(merge_types, "horizontal")
    if (has_vertical_merge) merge_types <- c(merge_types, "vertical")
    warning("Table contains ", paste(merge_types, collapse = " and "),
            " merged cells. Markdown output may need manual correction.",
            call. = FALSE)
  }

  # Extract all cell contents with inline formatting preserved.
  # Thread active_comments and footnote_counter across paragraphs within
  # each cell so that comment ranges and footnote numbering stay correct.
  table_data <- lapply(rows, function(row) {
    cells <- xml2::xml_find_all(row, ".//w:tc", ns)
    sapply(cells, function(cell) {
      paras <- xml2::xml_find_all(cell, "w:p", ns)
      active_comments <- character()
      para_texts <- character(length(paras))
      for (i in seq_along(paras)) {
        result <- extract_formatted_text(
          paras[[i]], ns,
          footnotes = footnotes,
          footnote_counter = footnote_counter,
          active_comments = active_comments,
          hyperlink_rels = hyperlink_rels,
          citation_id_map = citation_id_map,
          image_rels = image_rels
        )
        para_texts[i] <- trimws(result$text)
        active_comments <- result$active_comments
        footnote_counter <<- result$footnote_counter
      }
      # Join paragraphs with space (markdown table cells are single-line)
      text <- paste(para_texts[nzchar(para_texts)], collapse = " ")
      # Clean up whitespace and escape pipes
      text <- gsub("\\s+", " ", trimws(text))
      gsub("\\|", "\\\\|", text)
    })
  })

  # Determine number of columns (max across all rows)
  n_cols <- max(sapply(table_data, length))

  # Pad rows to have consistent column count
  table_data <- lapply(table_data, function(row) {
    if (length(row) < n_cols) {
      c(row, rep("", n_cols - length(row)))
    } else {
      row
    }
  })

  # Build markdown table
  md_lines <- character()

  # Header row
  header <- paste(table_data[[1]], collapse = " | ")
  md_lines <- c(md_lines, paste0("| ", header, " |"))

  # Separator row
  separator <- paste(rep("---", n_cols), collapse = " | ")
  md_lines <- c(md_lines, paste0("| ", separator, " |"))

  # Data rows
  if (length(table_data) > 1) {
    for (i in 2:length(table_data)) {
      row_text <- paste(table_data[[i]], collapse = " | ")
      md_lines <- c(md_lines, paste0("| ", row_text, " |"))
    }
  }

  list(lines = md_lines, footnote_counter = footnote_counter)
}


#' Replace in-text citations with Quarto format
#'
#' Replaces formatted citation text (e.g., "(1-4)") with Quarto citation
#' syntax (e.g., `[@hsu2025; @saltelli2020; ...]`).
#'
#' Handles whitespace variations by normalizing both the search pattern
#' and target text (e.g., "(1, 2)" matches "(1,2)").
#'
#' @param text The text to process
#' @param citation_map Named list mapping formatted citations to Quarto syntax
#' @return Text with citations replaced
#' @noRd
replace_citations <- function(text, citation_map) {
  if (length(citation_map) == 0) return(text)

  # Normalize text dashes so lookups match citation_map keys
  # (keys are normalized in extract_citations via normalize_citation_text)
  text <- gsub("\u2013", "-", text)  # en-dash -> hyphen
  text <- gsub("\u2014", "-", text)  # em-dash -> hyphen

  # Sort by length (longest first) to avoid partial replacements
  formatted <- names(citation_map)
  formatted <- formatted[order(nchar(formatted), decreasing = TRUE)]

  for (fmt in formatted) {
    quarto <- citation_map[[fmt]]

    # First try fixed replacement (exact match)
    if (grepl(fmt, text, fixed = TRUE)) {
      text <- gsub(fmt, quarto, text, fixed = TRUE)
    } else {
      # Try flexible whitespace matching using single-pass pattern builder
      pattern <- build_citation_pattern(fmt)
      text <- gsub(pattern, quarto, text, perl = TRUE)
    }
  }

  text
}


#' Build a regex pattern from citation display text in a single pass
#'
#' Avoids the double-escaping problem of sequential gsub calls by building
#' the pattern character by character: escapes regex metacharacters, allows
#' flexible whitespace around punctuation, and matches any dash type.
#'
#' @param fmt Normalized citation display text (e.g., "(17-24)")
#' @return Regex pattern string
#' @noRd
build_citation_pattern <- function(fmt) {
  chars <- strsplit(fmt, "")[[1]]
  pattern_parts <- vapply(chars, function(ch) {
    if (ch %in% c("[", "]", "(", ")", "{", "}", "^", "$", ".", "*", "+", "?", "|", "\\")) {
      paste0("\\", ch)
    } else if (ch %in% c(",", ";")) {
      paste0(ch, "\\s*")
    } else if (ch == " ") {
      "\\s+"
    } else if (ch == "-") {
      "[-\u2013\u2014]\\s*"
    } else {
      ch
    }
  }, character(1))

  paste(pattern_parts, collapse = "")
}
