#' Style Management for Docstyle
#'
#' Functions for cataloguing, validating, and pruning Word document styles.
#' Implements the "Harvest-Validate-Prune" pipeline to control style bloat
#' while preserving user-defined and organizational styles.
#'
#' @name style_manager
#' @keywords internal
NULL


# =============================================================================
# Phase 0: Harvest-Time Style Cataloguing
# =============================================================================

#' Extract Style Inventory from Word Document
#'
#' Scans a Word document and creates a comprehensive inventory of all styles,
#' including their usage status, inheritance hierarchy, and linked pairs.
#' This inventory is saved to `_docstyle/styles.json` and used during pruning
#' to preserve styles that were present in the source document.
#'
#' @param docx_path Path to the Word document
#' @param output_dir Directory to write styles.json (defaults to `_docstyle/`
#'   sibling to the docx file). If NULL, returns inventory without writing.
#' @return Invisibly returns the style inventory list
#'
#' @details
#' The inventory captures:
#' - **All defined styles** in `word/styles.xml` (excluding latentStyles)
#' - **Usage tracking** via scanning document.xml, headers, footers, footnotes
#' - **basedOn hierarchy** for safe pruning that respects inheritance
#' - **Linked style pairs** (paragraph <-> character companions)
#'
#' @examples
#' \dontrun{
#' # During harvest
#' extract_style_inventory("source.docx", "_docstyle")
#'
#' # Just get inventory without writing
#' inv <- extract_style_inventory("source.docx", output_dir = NULL)
#' names(inv$styles)
#' }
#'
#' @keywords internal
#' @export
extract_style_inventory <- function(docx_path, output_dir = NULL) {
  if (!file.exists(docx_path)) {
    stop("File not found: ", docx_path)
  }


  inventory <- with_docx_temp(docx_path, function(temp_dir) {
    ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

    # --- 1. Get all defined styles from styles.xml ---
    styles_path <- file.path(temp_dir, "word", "styles.xml")
    if (!file.exists(styles_path)) {
      warning("No styles.xml found in document")
      return(list(styles = list(), hierarchy = list(), linked_pairs = list()))
    }

    styles_xml <- xml2::read_xml(styles_path)

    # Find all explicit style definitions (not latentStyles)
    style_nodes <- xml2::xml_find_all(styles_xml, "/w:styles/w:style", ns)

    styles <- list()
    linked_pairs <- list()

    for (node in style_nodes) {
      style_id <- xml2::xml_attr(node, "styleId")
      if (is.na(style_id)) next

      style_type <- xml2::xml_attr(node, "type")
      if (is.na(style_type)) style_type <- "paragraph"

      # Get style name
      name_node <- xml2::xml_find_first(node, "w:name/@w:val", ns)
      style_name <- if (!inherits(name_node, "xml_missing")) {
        xml2::xml_text(name_node)
      } else {
        style_id
      }

      # Get basedOn parent
      based_on_node <- xml2::xml_find_first(node, "w:basedOn/@w:val", ns)
      based_on <- if (!inherits(based_on_node, "xml_missing")) {
        xml2::xml_text(based_on_node)
      } else {
        NULL
      }

      # Get linked style
      link_node <- xml2::xml_find_first(node, "w:link/@w:val", ns)
      linked <- if (!inherits(link_node, "xml_missing")) {
        xml2::xml_text(link_node)
      } else {
        NULL
      }

      # Check if it's a custom style (not built-in)
      custom_val <- xml2::xml_attr(node, "customStyle")
      is_custom <- !is.na(custom_val) && custom_val == "1"

      # Get outline level (0=Heading1 … 8=Heading9); NA if absent
      outline_node <- xml2::xml_find_first(node, "w:pPr/w:outlineLvl/@w:val", ns)
      outline_level <- if (!inherits(outline_node, "xml_missing")) {
        raw_val <- xml2::xml_text(outline_node)
        if (grepl("^[0-9]+$", raw_val)) as.integer(raw_val) else NA_integer_
      } else {
        NA_integer_
      }

      styles[[style_id]] <- list(
        name = style_name,
        type = style_type,
        basedOn = based_on,
        link = linked,
        custom = is_custom,
        outline_level = outline_level,
        used = FALSE  # Will be updated by usage scan
      )

      # Track linked pairs
      if (!is.null(linked)) {
        linked_pairs <- c(linked_pairs, list(c(style_id, linked)))
      }
    }

    # --- 2. Scan for used styles ---
    used_styles <- scan_used_styles(temp_dir, ns)

    # Mark used styles
    for (style_id in used_styles) {
      if (style_id %in% names(styles)) {
        styles[[style_id]]$used <- TRUE
      }
    }

    # --- 3. Build hierarchy map ---
    hierarchy <- build_style_hierarchy(styles)

    list(
      styles = styles,
      hierarchy = hierarchy,
      linked_pairs = unique(linked_pairs)
    )
  })

  # Add metadata
  inventory$docstyle_version <- as.character(utils::packageVersion("docstyle"))
  inventory$source_file <- basename(docx_path)
  inventory$extracted_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

  # Write to file if output_dir specified

  if (!is.null(output_dir)) {
    if (!dir.exists(output_dir)) {
      dir.create(output_dir, recursive = TRUE)
    }
    json_path <- file.path(output_dir, "styles.json")
    jsonlite::write_json(inventory, json_path, pretty = TRUE, auto_unbox = TRUE)
    n_used <- sum(vapply(inventory$styles, function(s) isTRUE(s$used), logical(1)))
    message("  Style inventory: ", basename(json_path),
            " (", length(inventory$styles), " styles, ", n_used, " used)")
  }

  invisible(inventory)
}


#' Scan Document for Used Styles
#'
#' Searches document.xml, headers, footers, and footnotes for style references.
#'
#' @param temp_dir Path to extracted DOCX temp directory
#' @param ns XML namespace
#' @return Character vector of unique style IDs that are used
#' @noRd
scan_used_styles <- function(temp_dir, ns) {
  used <- character(0)

  # Files to scan for style usage
  files_to_scan <- c(
    file.path(temp_dir, "word", "document.xml"),
    file.path(temp_dir, "word", "footnotes.xml"),
    file.path(temp_dir, "word", "endnotes.xml"),
    file.path(temp_dir, "word", "comments.xml")
  )


  # Add headers and footers
  word_dir <- file.path(temp_dir, "word")
  if (dir.exists(word_dir)) {
    headers <- list.files(word_dir, pattern = "^header[0-9]*\\.xml$", full.names = TRUE)
    footers <- list.files(word_dir, pattern = "^footer[0-9]*\\.xml$", full.names = TRUE)
    files_to_scan <- c(files_to_scan, headers, footers)
  }

  for (file_path in files_to_scan) {
    if (!file.exists(file_path)) next

    tryCatch({
      xml <- xml2::read_xml(file_path)

      # Paragraph styles
      pstyle_nodes <- xml2::xml_find_all(xml, "//w:pStyle/@w:val", ns)
      used <- c(used, xml2::xml_text(pstyle_nodes))

      # Run/character styles
      rstyle_nodes <- xml2::xml_find_all(xml, "//w:rStyle/@w:val", ns)
      used <- c(used, xml2::xml_text(rstyle_nodes))

      # Table styles
      tblstyle_nodes <- xml2::xml_find_all(xml, "//w:tblStyle/@w:val", ns)
      used <- c(used, xml2::xml_text(tblstyle_nodes))

    }, error = function(e) {
      message("[style-manager] Could not parse '", basename(file_path),
              "': ", conditionMessage(e), " (skipping)")
    })
  }

  unique(used)
}


#' Build Style Hierarchy Map
#'
#' Creates a map of parent -> children relationships for style inheritance.
#'
#' @param styles List of style definitions
#' @return Named list where names are parent style IDs and values are
#'   vectors of child style IDs
#' @noRd
build_style_hierarchy <- function(styles) {
  hierarchy <- list()

  for (style_id in names(styles)) {
    parent <- styles[[style_id]]$basedOn
    if (!is.null(parent)) {
      if (is.null(hierarchy[[parent]])) {
        hierarchy[[parent]] <- character(0)
      }
      hierarchy[[parent]] <- c(hierarchy[[parent]], style_id)
    }
  }

  hierarchy
}


# =============================================================================
# Phase 1: Inventory Logic (Rendered Document Scanning)
# =============================================================================

#' Get Used Styles from Document
#'
#' Scans a Word document (or its XML) to find all styles currently in use.
#' This is used during the finisher phase to determine which styles should
#' be kept even if they weren't in the original source.
#'
#' @param doc Officer document object, or path to DOCX file
#' @return List with:
#'   - `paragraph`: Vector of paragraph style IDs
#'   - `character`: Vector of character/run style IDs
#'   - `table`: Vector of table style IDs
#'   - `all`: Combined unique vector of all style IDs
#'
#' @examples
#' \dontrun{
#' doc <- officer::read_docx("output.docx")
#' used <- get_used_styles(doc)
#' used$all
#' }
#'
#' @keywords internal
#' @export
get_used_styles <- function(doc) {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # Handle both officer doc and file path

  if (is.character(doc)) {
    return(with_docx_temp(doc, function(temp_dir) {
      scan_used_styles_result(temp_dir, ns)
    }))
  }

  # Officer document - use package directory
  pkg_dir <- doc$package_dir
  scan_used_styles_result(pkg_dir, ns)
}


#' Scan for Used Styles with Categorized Results
#'
#' @param pkg_dir Path to extracted DOCX directory
#' @param ns XML namespace
#' @return List with paragraph, character, table, and all vectors
#' @noRd
scan_used_styles_result <- function(pkg_dir, ns) {
  paragraph <- character(0)
  character_styles <- character(0)
  table <- character(0)

  # Files to scan
  files_to_scan <- c(
    file.path(pkg_dir, "word", "document.xml"),
    file.path(pkg_dir, "word", "footnotes.xml"),
    file.path(pkg_dir, "word", "endnotes.xml"),
    file.path(pkg_dir, "word", "comments.xml")
  )

  # Add headers and footers
  word_dir <- file.path(pkg_dir, "word")
  if (dir.exists(word_dir)) {
    headers <- list.files(word_dir, pattern = "^header[0-9]*\\.xml$", full.names = TRUE)
    footers <- list.files(word_dir, pattern = "^footer[0-9]*\\.xml$", full.names = TRUE)
    files_to_scan <- c(files_to_scan, headers, footers)
  }

  for (file_path in files_to_scan) {
    if (!file.exists(file_path)) next

    tryCatch({
      xml <- xml2::read_xml(file_path)

      # Paragraph styles
      pstyle_nodes <- xml2::xml_find_all(xml, "//w:pStyle/@w:val", ns)
      paragraph <- c(paragraph, xml2::xml_text(pstyle_nodes))

      # Run/character styles
      rstyle_nodes <- xml2::xml_find_all(xml, "//w:rStyle/@w:val", ns)
      character_styles <- c(character_styles, xml2::xml_text(rstyle_nodes))

      # Table styles
      tblstyle_nodes <- xml2::xml_find_all(xml, "//w:tblStyle/@w:val", ns)
      table <- c(table, xml2::xml_text(tblstyle_nodes))

    }, error = function(e) {
      message("[style-manager] Could not parse '", basename(file_path),
              "': ", conditionMessage(e), " (skipping)")
    })
  }

  list(
    paragraph = unique(paragraph),
    character = unique(character_styles),
    table = unique(table),
    all = unique(c(paragraph, character_styles, table))
  )
}


# =============================================================================
# Phase 2: Pruning Logic
# =============================================================================

#' Get Allowed Styles
#'
#' Builds the complete list of styles that should be preserved, combining:
#' 1. Styles from CSS/YAML configuration
#' 2. Styles from the harvested source document (if `styles.json` exists)
#' 3. Mandatory structural styles
#'
#' @param config Docstyle configuration list (parsed from _quarto.yml)
#' @param sidecar_dir Path to `_docstyle/` directory containing `styles.json`
#' @param template_path Path to a template DOCX file whose styles should all
#'   be preserved (optional). Used in template mode to keep the publisher's
#'   full style palette.
#' @return Character vector of allowed style IDs
#'
#' @keywords internal
#' @export
get_allowed_styles <- function(config = NULL, sidecar_dir = NULL,
                               template_path = NULL) {
  allowed <- character(0)

  # 1. Styles from CSS/YAML config
  if (!is.null(config)) {
    css_styles <- map_config_to_styles(config)
    allowed <- c(allowed, css_styles)
  }

  # 2. Styles from harvested source (if available)
  if (!is.null(sidecar_dir)) {
    styles_json <- file.path(sidecar_dir, "styles.json")
    if (file.exists(styles_json)) {
      inventory <- jsonlite::read_json(styles_json)
      # Include ALL styles from source (not just used ones)
      # This preserves the template's full style palette
      source_styles <- names(inventory$styles)
      allowed <- c(allowed, source_styles)
    }
  }

  # 2b. Styles from reference.docx (CSS-generated custom styles only)
  # Only keep custom styles (customStyle="1") — these are CSS-generated.
  # Pandoc's built-in styles (AlertTok, SourceCode, etc.) are not custom
  # and should be pruned unless actually used in the document.
  if (!is.null(sidecar_dir)) {
    ref_docx <- file.path(sidecar_dir, "reference.docx")
    if (file.exists(ref_docx)) {
      ref_inventory <- extract_style_inventory(ref_docx, output_dir = NULL)
      ref_custom <- names(Filter(function(s) isTRUE(s$custom), ref_inventory$styles))
      allowed <- c(allowed, ref_custom)
    }
  }

  # 2c. All styles from template (if template mode)
  if (!is.null(template_path) && file.exists(template_path)) {
    template_inventory <- extract_style_inventory(template_path, output_dir = NULL)
    template_styles <- names(template_inventory$styles)
    allowed <- c(allowed, template_styles)
  }

  # 3. Mandatory structural styles
  mandatory <- get_mandatory_styles()
  allowed <- c(allowed, mandatory)

  unique(allowed)
}


#' Get Mandatory Styles
#'
#' Returns the list of styles that must never be pruned, regardless of usage.
#' These are structural styles required by Word, Pandoc, or docstyle.
#'
#' @return Character vector of mandatory style IDs
#' @keywords internal
#' @export
get_mandatory_styles <- function() {
  c(
    # Core document defaults
    "Normal", "DefaultParagraphFont", "TableNormal", "NoList",

    # Headings (Pandoc uses these)
    paste0("Heading", 1:9),

    # Table of Contents
    paste0("TOC", 1:9), "TOCHeading",

    # Hyperlinks
    "Hyperlink", "FollowedHyperlink", "UnresolvedMention",

    # Comments and annotations
    "CommentReference", "CommentText", "AnnotationText",
    "AnnotationReference", "CommentSubject",

    # Footnotes and endnotes
    "FootnoteText", "FootnoteReference",
    "EndnoteText", "EndnoteReference",

    # Lists
    "ListParagraph", "ListBullet", "ListNumber",

    # Tables
    "TableGrid", "TableCaption", "Caption",

    # Pandoc-specific
    "FirstParagraph", "BodyText", "Compact",
    "SourceCode", "VerbatimChar",

    # Docstyle-specific
    "ZoteroBibliography", "ZoteroBibliographyChar",
    "Abstract", "AbstractTitle",
    "Title", "Subtitle", "Author", "Date", "Affiliation"
  )
}


#' Map Configuration to Word Style IDs
#'
#' Extracts style IDs from docstyle configuration (CSS selectors, YAML settings).
#'
#' @param config Docstyle configuration list
#' @return Character vector of style IDs
#' @noRd
map_config_to_styles <- function(config) {
  styles <- character(0)

  # Map from CSS selectors (reuse existing function if available)
  if (!is.null(config$css_selectors)) {
    for (selector in names(config$css_selectors)) {
      word_style <- map_selector_to_word_style(selector)
      if (!is.null(word_style)) {
        styles <- c(styles, word_style$id)
      }
    }
  }

  # Add any explicitly declared styles
  if (!is.null(config$styles)) {
    styles <- c(styles, config$styles)
  }

  unique(styles)
}


#' Core Style Pruning Logic (XML-only)
#'
#' Pure XML manipulation function that removes unused styles from a parsed
#' styles.xml document. Separated from I/O for testability.
#'
#' @param styles_xml Parsed xml2 document for styles.xml
#' @param used Character vector of style IDs used in the document
#' @param allowed Character vector of allowed style IDs
#' @param verbose Logical. If TRUE, reports each removed style.
#' @return Number of styles removed
#' @noRd
prune_styles_xml <- function(styles_xml, used, allowed, verbose = FALSE) {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  keep <- unique(c(used, allowed))
  keep <- expand_style_hierarchy_keep(keep, styles_xml, ns)
  keep <- expand_linked_styles(keep, styles_xml, ns)

  if (verbose) message("Style pruning: keeping ", length(keep), " styles")

  style_nodes <- xml2::xml_find_all(styles_xml, "/w:styles/w:style", ns)
  removed_count <- 0L

  for (node in style_nodes) {
    style_id <- xml2::xml_attr(node, "styleId")
    if (!is.na(style_id) && !(style_id %in% keep)) {
      xml2::xml_remove(node)
      removed_count <- removed_count + 1L
      if (verbose) message("  Removed: ", style_id)
    }
  }

  if (removed_count > 0) {
    message("Style pruning: removed ", removed_count, " unused style(s)")
  }

  removed_count
}


#' Prune Unused Styles
#'
#' Removes styles from `styles.xml` that are neither used in the document
#' nor in the allowed list. Respects inheritance hierarchy and linked pairs.
#' Delegates to `prune_styles_xml()` for the core XML manipulation.
#'
#' @param doc Officer document object
#' @param config Docstyle configuration (optional)
#' @param sidecar_dir Path to `_docstyle/` directory (optional)
#' @param template_path Path to a template DOCX whose styles should all be
#'   preserved (optional)
#' @param verbose Logical. If TRUE, reports pruning actions.
#' @return Modified officer document with `"styles_pruned"` attribute set
#'
#' @details
#' The keep list is constructed as:
#' `Keep = Used + Allowed + Mandatory + basedOn_parents + Linked_pairs`
#'
#' Only explicit `<w:style>` nodes are removed; `<w:latentStyles>` is untouched.
#'
#' @keywords internal
#' @export
prune_styles <- function(doc, config = NULL, sidecar_dir = NULL,
                         template_path = NULL, verbose = FALSE) {
  pkg_dir <- doc$package_dir
  styles_path <- file.path(pkg_dir, "word", "styles.xml")

  if (!file.exists(styles_path)) {
    if (verbose) message("No styles.xml found, skipping prune")
    return(doc)
  }

  styles_xml <- xml2::read_xml(styles_path)
  used <- get_used_styles(doc)$all
  allowed <- get_allowed_styles(config, sidecar_dir, template_path)

  n_removed <- prune_styles_xml(styles_xml, used, allowed, verbose)
  if (n_removed > 0) xml2::write_xml(styles_xml, styles_path)

  attr(doc, "styles_pruned") <- n_removed
  doc
}


#' Prune Unused Styles from a DOCX File
#'
#' File-based wrapper that extracts a DOCX, prunes unused styles from
#' `styles.xml`, and re-zips the result. Uses direct zip manipulation
#' (not officer) for reliable in-place updates in post-render hooks.
#'
#' @param docx_path Path to the DOCX file to prune
#' @param config Docstyle configuration (optional)
#' @param sidecar_dir Path to `_docstyle/` directory (optional)
#' @param template_path Path to a template DOCX whose styles should all be
#'   preserved (optional)
#' @param verbose Logical. If TRUE, reports pruning actions.
#' @return Invisibly returns the number of styles removed
#'
#' @keywords internal
#' @export
prune_styles_file <- function(docx_path, config = NULL, sidecar_dir = NULL,
                              template_path = NULL, verbose = FALSE) {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # Extract DOCX to temp directory
  temp <- extract_docx_temp(docx_path)
  on.exit(temp$cleanup(), add = TRUE)

  styles_path <- file.path(temp$dir, "word", "styles.xml")
  if (!file.exists(styles_path)) {
    if (verbose) message("No styles.xml found, skipping prune")
    return(invisible(0L))
  }

  # Scan used styles from extracted document
  used <- scan_used_styles(temp$dir, ns)

  # Get allowed styles
  allowed <- get_allowed_styles(config, sidecar_dir, template_path)

  # Prune
  styles_xml <- xml2::read_xml(styles_path)
  n_removed <- prune_styles_xml(styles_xml, used, allowed, verbose)

  if (n_removed > 0L) {
    # Write modified styles.xml back
    xml2::write_xml(styles_xml, styles_path)

    # Re-zip the DOCX
    docx_path_abs <- normalizePath(docx_path, mustWork = TRUE)
    old_wd <- getwd()
    on.exit(setwd(old_wd), add = TRUE)
    setwd(temp$dir)

    all_files <- list.files(".", recursive = TRUE, all.files = TRUE)
    file.remove(docx_path_abs)
    result <- utils::zip(docx_path_abs, files = all_files, flags = "-r9Xq")
    if (result != 0) stop("Failed to re-zip DOCX: ", docx_path_abs)
  }

  invisible(n_removed)
}


#' Expand Keep List with basedOn Parents
#'
#' Recursively adds parent styles to the keep list to prevent orphaning.
#'
#' @param keep Current keep list
#' @param styles_xml Parsed styles.xml
#' @param ns XML namespace
#' @return Expanded keep list
#' @noRd
expand_style_hierarchy_keep <- function(keep, styles_xml, ns) {
  expanded <- keep

  repeat {
    # Find basedOn parents for all styles in expanded list
    parents <- character(0)
    for (style_id in expanded) {
      xpath <- sprintf("//w:style[@w:styleId='%s']/w:basedOn/@w:val", style_id)
      parent_nodes <- xml2::xml_find_all(styles_xml, xpath, ns)
      parents <- c(parents, xml2::xml_text(parent_nodes))
    }

    new_parents <- setdiff(unique(parents), expanded)
    if (length(new_parents) == 0) break

    expanded <- c(expanded, new_parents)
  }

  unique(expanded)
}


#' Expand Keep List with Linked Styles
#'
#' Adds companion character styles for kept paragraph styles (and vice versa).
#'
#' @param keep Current keep list
#' @param styles_xml Parsed styles.xml
#' @param ns XML namespace
#' @return Expanded keep list
#' @noRd
expand_linked_styles <- function(keep, styles_xml, ns) {
  expanded <- keep

  for (style_id in keep) {
    # Find linked style
    xpath <- sprintf("//w:style[@w:styleId='%s']/w:link/@w:val", style_id)
    link_nodes <- xml2::xml_find_all(styles_xml, xpath, ns)
    linked <- xml2::xml_text(link_nodes)

    if (length(linked) > 0) {
      expanded <- c(expanded, linked)
    }
  }

  # Also add common *Char pattern companions
  char_companions <- paste0(keep, "Char")
  # Only add if they actually exist
  for (char_style in char_companions) {
    xpath <- sprintf("//w:style[@w:styleId='%s']", char_style)
    if (length(xml2::xml_find_all(styles_xml, xpath, ns)) > 0) {
      expanded <- c(expanded, char_style)
    }
  }

  unique(expanded)
}
