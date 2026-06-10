# =============================================================================
# R-FIRST SECTION ASSEMBLY (v2)
# =============================================================================
#
# These functions implement "R-First Assembly" where Lua emits simple text
# markers instead of complex sectPr XML. R then:
# 1. Finds DOCSTYLE_SECTION:: markers
# 2. Builds sectPr XML using page-config.json
# 3. Attaches sectPr to the PRECEDING paragraph (correct OOXML model)
# 4. Collapses the marker paragraph to zero height (preserves field codes
#    for harvest round-trip, eliminates blank lines)
#
# This approach eliminates the empty container paragraphs that Pandoc creates
# when processing RawBlock elements containing sectPr XML.
# =============================================================================


#' Build sectPr XML from Page Configuration
#'
#' Constructs a complete `<w:sectPr>` element for Word section properties.
#' This mirrors the Lua `build_sect_pr()` function but runs in R where we
#' have direct DOM access.
#'
#' @param page_config List with size, orientation, margins (from page-config.json)
#' @param sect_type Section type: "continuous" or "nextPage"
#' @param line_numbers Line numbers mode: "continuous", "section", "page", or "none"
#' @return Character string of sectPr XML (without namespace declarations)
#' @noRd
build_sect_pr_xml <- function(page_config, sect_type = "continuous",
                              line_numbers = "none", page_start = NULL,
                              count_by = NULL, distance = NULL,
                              start_num = NULL) {
  # Get page dimensions from config
  dims <- get_page_dimensions(
    page_config$size %||% "letter",
    page_config$orientation %||% "portrait"
  )

  # Get margins (convert if needed)
  margins <- page_config$margins
  if (is.null(margins)) {
    margins <- list(top = 1440, bottom = 1440, left = 1440, right = 1440)
  }

  # Convert string margins to twips if needed
  convert_margin <- function(val) {
    if (is.numeric(val)) return(as.integer(val))
    if (is.character(val)) {
      if (grepl("in$", val)) return(as.integer(as.numeric(sub("in$", "", val)) * 1440))
      if (grepl("cm$", val)) return(as.integer(as.numeric(sub("cm$", "", val)) * 567))
      if (grepl("mm$", val)) return(as.integer(as.numeric(sub("mm$", "", val)) * 56.7))
      return(as.integer(val))
    }
    1440L  # Default 1 inch
  }

  top <- convert_margin(margins$top)
  bottom <- convert_margin(margins$bottom)
  left <- convert_margin(margins$left)
  right <- convert_margin(margins$right)
  header <- convert_margin(margins$header %||% "0.5in")
  footer <- convert_margin(margins$footer %||% "0.5in")

  # Build XML parts
  xml_parts <- c(
    sprintf('<w:sectPr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'),
    sprintf('  <w:type w:val="%s"/>', sect_type),
    sprintf('  <w:pgSz w:w="%d" w:h="%d"/>', dims$width, dims$height),
    sprintf('  <w:pgMar w:top="%d" w:right="%d" w:bottom="%d" w:left="%d" w:header="%d" w:footer="%d" w:gutter="0"/>',
            top, right, bottom, left, header, footer)
  )

  # Add line numbers if requested
  if (!is.null(line_numbers) && line_numbers != "none" && line_numbers != "false") {
    restart_val <- switch(line_numbers,
      "continuous" = "continuous",
      "section" = "newSection",
      "page" = "newPage",
      "continuous"
    )

    # Resolve count-by, distance, start from explicit params → page_config defaults
    ln_config <- page_config$`line-numbers`
    resolved_count_by <- count_by %||% ln_config$`count-by` %||% 1L
    resolved_distance <- distance %||%
      (if (!is.null(ln_config$distance)) css_to_twips(ln_config$distance) else 360L)
    resolved_start <- start_num %||% ln_config$start

    ln_attrs <- sprintf('w:countBy="%s" w:restart="%s" w:distance="%s"',
                        as.integer(resolved_count_by), restart_val,
                        as.integer(resolved_distance))
    if (!is.null(resolved_start)) {
      ln_attrs <- paste0(ln_attrs, sprintf(' w:start="%s"', as.integer(resolved_start)))
    }

    xml_parts <- c(xml_parts,
      sprintf('  <w:lnNumType %s/>', ln_attrs))
  }

  # Add page number restart if specified
  if (!is.null(page_start) && nzchar(page_start)) {
    xml_parts <- c(xml_parts,
      sprintf('  <w:pgNumType w:start="%s"/>', page_start))
  }

  xml_parts <- c(xml_parts,
    '  <w:cols w:space="720"/>',
    '  <w:docGrid w:linePitch="360"/>',
    '</w:sectPr>'
  )

  paste(xml_parts, collapse = "")
}


#' Load Page Configuration from _docstyle Directory
#'
#' Reads page-config.json from the document's _docstyle sidecar directory.
#' Falls back to sensible defaults if not found.
#'
#' @param doc_dir Directory containing the DOCX (looks for _docstyle/ subdirectory)
#' @return List with page configuration
#' @noRd
load_page_config <- function(doc_dir) {
  # Try common locations: docx directory, then parent (for output/ subdirs),
  # then working directory (project root)
  search_dirs <- unique(c(doc_dir, dirname(doc_dir), getwd()))
  config_paths <- character(0)
  for (d in search_dirs) {
    config_paths <- c(config_paths,
                      file.path(d, "_docstyle", "page-config.json"),
                      file.path(d, "page-config.json"))
  }

  for (path in config_paths) {
    if (file.exists(path)) {
      config <- jsonlite::fromJSON(path, simplifyVector = FALSE)
      return(config)
    }
  }

  # Default configuration
  list(
    size = "letter",
    orientation = "portrait",
    margins = list(top = "1in", bottom = "1in", left = "1in", right = "1in")
  )
}


#' Get Page Properties for Named Section
#'
#' Looks up section class in page-config.json named sections.
#' Falls back to default page properties if not found.
#'
#' @param section_class Section class name (e.g., "section-body", "section-landscape")
#' @param page_config Page configuration from load_page_config()
#' @return List with size, orientation, margins for this section
#' @noRd
get_section_page_props <- function(section_class, page_config) {
  # Extract section name from class (e.g., "section-body" -> "body")
  section_name <- sub("^section-", "", section_class)

  # Check named sections
  if (!is.null(page_config$named) && !is.null(page_config$named[[section_name]])) {
    props <- page_config$named[[section_name]]
  } else {
    # Fall back to default page properties
    props <- list(
      size = page_config$size %||% "letter",
      orientation = page_config$orientation %||% "portrait",
      margins = page_config$margins
    )
  }

  # Always carry line-numbers config from the root page_config so that
  # build_sect_pr_xml() can resolve count-by/distance/start defaults even
  # when section_props was extracted from page_config$named (which is a
  # stripped-down subset with no line-numbers key).
  if (is.null(props$`line-numbers`) && !is.null(page_config$`line-numbers`)) {
    props$`line-numbers` <- page_config$`line-numbers`
  }

  props
}


#' Find Content Predecessor Paragraph
#'
#' Walks backward from a marker paragraph to find the last paragraph
#' with actual text content. Skips field code structural elements,
#' other markers, and empty paragraphs.
#'
#' @param marker_para xml2 node of the marker paragraph
#' @param ns XML namespaces
#' @return xml2 node of the predecessor paragraph, or NULL if not found
#' @noRd
find_content_predecessor <- function(marker_para, ns) {
  sibling <- xml2::xml_find_first(marker_para, "preceding-sibling::w:p[1]", ns)

  for (i in seq_len(20)) {  # Safety limit
    if (inherits(sibling, "xml_missing")) return(NULL)

    # Get text content
    text_nodes <- xml2::xml_find_all(sibling, ".//w:t", ns)
    para_text <- trimws(paste(xml2::xml_text(text_nodes), collapse = ""))

    # Skip if it's another marker
    if (grepl("^DOCSTYLE_SECTION", para_text)) {
      sibling <- xml2::xml_find_first(sibling, "preceding-sibling::w:p[1]", ns)
      next
    }

    # Skip if it's a field code boundary only (fldChar but no text)
    fld_chars <- xml2::xml_find_all(sibling, ".//w:fldChar", ns)
    if (length(fld_chars) > 0 && nchar(para_text) == 0) {
      sibling <- xml2::xml_find_first(sibling, "preceding-sibling::w:p[1]", ns)
      next
    }

    # Skip if it's a page break only
    breaks <- xml2::xml_find_all(sibling, './/w:br[@w:type="page"]', ns)
    if (length(breaks) > 0 && nchar(para_text) == 0) {
      sibling <- xml2::xml_find_first(sibling, "preceding-sibling::w:p[1]", ns)
      next
    }

    # Found a content paragraph (has text or is non-structural)
    return(sibling)
  }

  NULL
}


#' Check Whether Real Content Exists Between Two Marker Paragraphs
#'
#' Walks forward from `open_para` through its following siblings, stopping
#' when `close_para` is reached. Returns TRUE if any intervening paragraph
#' has real text content (not a structural marker, empty paragraph, field
#' code boundary, or page-break-only paragraph).
#'
#' Used to detect empty wrapping divs (opening marker immediately followed
#' by closing marker) so their section breaks can be suppressed.
#'
#' @param open_para xml2 node of the opening marker paragraph
#' @param close_para xml2 node of the closing marker paragraph
#' @param ns XML namespaces
#' @return TRUE if real content exists between the two markers
#' @noRd
has_content_between <- function(open_para, close_para, ns) {
  sib <- xml2::xml_find_first(open_para, "following-sibling::w:p[1]", ns)
  for (i in seq_len(200)) {
    if (inherits(sib, "xml_missing")) return(FALSE)
    if (identical(sib, close_para)) return(FALSE)

    text_nodes <- xml2::xml_find_all(sib, ".//w:t", ns)
    para_text  <- trimws(paste(xml2::xml_text(text_nodes), collapse = ""))

    # Skip structural markers
    if (grepl("^DOCSTYLE_SECTION", para_text)) {
      sib <- xml2::xml_find_first(sib, "following-sibling::w:p[1]", ns)
      next
    }
    # Skip empty paragraphs (no text)
    if (!nzchar(para_text)) {
      sib <- xml2::xml_find_first(sib, "following-sibling::w:p[1]", ns)
      next
    }
    # A paragraph with real text — content exists
    return(TRUE)
  }
  # Reached iteration limit without finding close_para — content must be present
  TRUE
}


#' Find First Content Paragraph After a Section Boundary
#'
#' Walks forward from a section boundary paragraph to find the first
#' paragraph with actual text content. Skips empty paragraphs, field code
#' structural elements, and page break-only paragraphs.
#'
#' @param boundary_para xml2 node of the paragraph carrying sectPr
#' @param ns XML namespaces
#' @return xml2 node of the first content paragraph, or NULL if not found
#' @noRd
find_first_content_successor <- function(boundary_para, ns) {
  sibling <- xml2::xml_find_first(boundary_para, "following-sibling::w:p[1]", ns)

  max_skip <- 20L
  for (i in seq_len(max_skip)) {
    if (inherits(sibling, "xml_missing")) return(NULL)

    # Get text content
    text_nodes <- xml2::xml_find_all(sibling, ".//w:t", ns)
    para_text <- trimws(paste(xml2::xml_text(text_nodes), collapse = ""))

    # Skip if it's a field code boundary only (fldChar but no text)
    fld_chars <- xml2::xml_find_all(sibling, ".//w:fldChar", ns)
    if (length(fld_chars) > 0 && nchar(para_text) == 0) {
      sibling <- xml2::xml_find_first(sibling, "following-sibling::w:p[1]", ns)
      next
    }

    # Skip if it's a page break only
    breaks <- xml2::xml_find_all(sibling, './/w:br[@w:type="page"]', ns)
    if (length(breaks) > 0 && nchar(para_text) == 0) {
      sibling <- xml2::xml_find_first(sibling, "following-sibling::w:p[1]", ns)
      next
    }

    # Skip empty paragraphs (structural, Pandoc artifacts)
    if (nchar(para_text) == 0) {
      sibling <- xml2::xml_find_first(sibling, "following-sibling::w:p[1]", ns)
      next
    }

    # Found a content paragraph
    return(sibling)
  }

  warning("[assemble] find_first_content_successor: skipped ", max_skip,
          " paragraphs without finding content")
  NULL
}


#' Attach sectPr to Paragraph
#'
#' Inserts sectPr XML into a paragraph's pPr element.
#' Creates pPr if it doesn't exist. Replaces existing sectPr if present.
#'
#' @param para xml2 node of the target paragraph
#' @param sect_pr_xml Character string of sectPr XML
#' @param ns XML namespaces
#' @return TRUE if successful
#' @noRd
attach_sect_pr <- function(para, sect_pr_xml, ns) {
  pPr <- xml2::xml_find_first(para, "w:pPr", ns)

  if (inherits(pPr, "xml_missing")) {
    # Create pPr as first child of paragraph
    pPr <- xml2::xml_add_child(para, "w:pPr", .where = 0)
  }

  # Remove existing sectPr if present, but preserve pgNumType if the new
  # sectPr doesn't have one. This protects against adjacent closing + opening
  # markers targeting the same paragraph: the closing marker sets pgNumType,
  # then the opening marker overwrites — without this guard, pgNumType is lost.
  existing <- xml2::xml_find_first(pPr, "w:sectPr", ns)
  preserved_page_start <- NULL
  if (!inherits(existing, "xml_missing")) {
    existing_pgNum <- xml2::xml_find_first(existing, "w:pgNumType", ns)
    if (!inherits(existing_pgNum, "xml_missing") &&
        !grepl("pgNumType", sect_pr_xml, fixed = TRUE)) {
      preserved_page_start <- xml2::xml_attr(existing_pgNum, "start")
    }
    xml2::xml_remove(existing)
  }

  # Parse the sectPr XML and extract the node
  # We wrap in a dummy root with the namespace so xml2 can parse child elements
  # without adding xmlns to sectPr itself
  wrapper_xml <- paste0(
    '<root xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    gsub(' xmlns:w="[^"]*"', '', sect_pr_xml),  # Remove namespace from sectPr
    '</root>'
  )
  wrapper_doc <- xml2::read_xml(wrapper_xml)
  sect_pr_node <- xml2::xml_find_first(wrapper_doc, "//w:sectPr", ns)

  # Restore preserved pgNumType if needed
  if (!is.null(preserved_page_start) && nzchar(preserved_page_start)) {
    pgNum <- xml2::xml_add_child(sect_pr_node, "w:pgNumType")
    xml2::xml_set_attr(pgNum, "w:start", preserved_page_start)
  }

  # Add the sectPr to pPr
  xml2::xml_add_child(pPr, sect_pr_node)

  # Return whether this replaced an existing sectPr (from an earlier marker)
  !inherits(existing, "xml_missing")
}


#' Assemble Section Breaks from Text Markers
#'
#' Scans the document for DOCSTYLE_SECTION:: and DOCSTYLE_SECTION_END::
#' text markers, constructs sectPr XML, attaches it to the preceding
#' content paragraph, and collapses the marker paragraph to zero height
#' (preserving field code structure for harvest round-trip).
#'
#' This is the core of "R-First Assembly" that eliminates the 3-line gap
#' problem by building sectPr in R instead of emitting it from Lua.
#'
#' IMPORTANT: Word's section model is "backward-looking" - a sectPr defines
#' properties for the section that ENDS at that point. But our markers describe
#' what the NEW section (after the marker) should have. So we use a two-pass
#' approach:
#' 1. First pass: Collect all markers in document order with their line-numbers
#' 2. Second pass: For each marker, apply the PREVIOUS section's line-numbers
#'    (since sectPr ends the previous section, not starts the new one)
#'
#' Marker types:
#' - DOCSTYLE_SECTION:: - Opening marker (start of section)
#' - DOCSTYLE_SECTION_END:: - Closing marker (end of wrapping div)
#'
#' @param body xml2 node for w:body
#' @param ns XML namespaces
#' @param page_config Page configuration from load_page_config()
#' @param verbose Print diagnostic messages
#' @return List with:
#'   - n_assembled: number of sections assembled
#'   - closing_sectpr_paras: list of xml nodes that received closing-marker sectPr
#'   - section_sequence: list of (section_class, sectpr_para, is_closing, line_numbers,
#'     field_code_payload) in document order
#'   - final_section_name: section class of the last marker (defines body sectPr section)
#' @noRd
assemble_section_breaks <- function(body, ns, page_config, verbose = FALSE) {
  n_assembled <- 0L
  closing_sectpr_paras <- list()
  section_sequence <- list()

  # === PASS 1: Collect all markers in document order ===
  markers <- list()
  all_paras <- xml2::xml_find_all(body, ".//w:p", ns)

  for (para in all_paras) {
    text_nodes <- xml2::xml_find_all(para, ".//w:t", ns)
    para_text <- paste(xml2::xml_text(text_nodes), collapse = "")

    is_opening <- grepl("^DOCSTYLE_SECTION::", para_text)
    is_closing <- grepl("^DOCSTYLE_SECTION_END::", para_text)

    if (!is_opening && !is_closing) next

    # Parse marker: DOCSTYLE_SECTION[_END]::{class}::{page-break}::{line-numbers}
    parts <- strsplit(para_text, "::")[[1]]
    if (length(parts) < 4) {
      if (verbose) warning("Malformed section marker: ", para_text)
      next
    }

    # Extract field code JSON payload from instrText (for header/footer attributes)
    field_code_payload <- NULL
    instr_nodes <- xml2::xml_find_all(para, ".//w:instrText", ns)
    for (instr_node in instr_nodes) {
      instr_text <- xml2::xml_text(instr_node)
      json_match <- regmatches(instr_text, regexpr("\\{.*\\}", instr_text))
      if (length(json_match) == 1 && nzchar(json_match)) {
        field_code_payload <- tryCatch(
          jsonlite::fromJSON(json_match, simplifyVector = FALSE),
          error = function(e) NULL
        )
      }
    }

    markers <- c(markers, list(list(
      para = para,
      section_class = parts[2],
      page_break = parts[3] == "true",
      line_numbers = parts[4],  # What the NEW section should have
      is_closing = is_closing,
      field_code_payload = field_code_payload
    )))
  }

  if (length(markers) == 0) {
    return(list(
      n_assembled = 0L,
      closing_sectpr_paras = list(),
      section_sequence = list(),
      final_section_name = NULL
    ))
  }

  if (verbose) {
    message("[assemble] Found ", length(markers), " section marker(s)")
  }

  # === PRE-PASS: Tag opening markers that have a matching closing marker ===
  # For wrapping divs (opening + closing pair), pgNumType must go on the
  # closing marker's sectPr (which defines the div's section). For non-wrapping
  # markers (opening only), pgNumType goes on the opening marker's sectPr.
  #
  # Empty pairs (no real content between opening and closing) are tagged
  # skip_empty_pair = TRUE and suppressed in Pass 2 to avoid a spurious
  # blank page from back-to-back section breaks with no content.
  open_sections <- list()
  for (i in seq_along(markers)) {
    m <- markers[[i]]
    base_class <- sub("-end$", "", m$section_class)
    if (m$is_closing) {
      if (base_class %in% names(open_sections)) {
        open_idx <- open_sections[[base_class]]
        markers[[open_idx]]$has_closing_pair <- TRUE
        # Check if there is real content between the opening and closing marker
        if (!has_content_between(markers[[open_idx]]$para, m$para, ns)) {
          markers[[open_idx]]$skip_empty_pair <- TRUE
          markers[[i]]$skip_empty_pair <- TRUE
          if (verbose) {
            message("[assemble] Empty section div suppressed: ", m$section_class)
          }
        }
        open_sections[[base_class]] <- NULL
      }
    } else {
      open_sections[[base_class]] <- i
    }
  }

  # === PASS 2: Process markers with correct line-numbers assignment ===
  # The sectPr at position N ends the section that started at marker N-1.
  # So sectPr at marker N should use marker N-1's line-numbers (for the ending section).
  # First marker's sectPr ends the "implicit" first section (no line numbers by default).

  prev_line_numbers <- "none"  # First section (before any marker) has no line numbers
  prev_count_by <- NULL        # Per-section count-by (NULL = use page_config default)
  prev_distance <- NULL        # Per-section distance (NULL = use page_config default)
  prev_start_num <- NULL       # Per-section start number (NULL = use page_config default)
  # Scoped deferral: keyed by opening section class so that adjacent wrapping
  # divs don't fire each other's deferred values. Each entry is a list with
  # optional fields: page_start, sect_type.
  deferred_by_class <- list()

  for (i in seq_along(markers)) {
    m <- markers[[i]]
    para <- m$para

    # Empty wrapping divs (opening + closing with no content between) are
    # suppressed to prevent a spurious blank page from back-to-back section breaks.
    if (isTRUE(m$skip_empty_pair)) next

    marker_type <- if (m$is_closing) "closing" else "opening"

    if (verbose) {
      message("[assemble] Processing ", marker_type, " marker: ", m$section_class,
              " (ending section with line-numbers=", prev_line_numbers, ")")
    }

    # Find preceding content paragraph
    prev_para <- find_content_predecessor(para, ns)

    if (is.null(prev_para)) {
      if (verbose) message("[assemble] No predecessor found for: ", m$section_class)
      # Update prev_line_numbers for next iteration even if we can't attach
      prev_line_numbers <- m$line_numbers
      payload <- m$field_code_payload
      prev_count_by <- payload[["line-numbers-count-by"]]
      prev_distance <- if (!is.null(payload[["line-numbers-distance"]])) {
        css_to_twips(payload[["line-numbers-distance"]])
      }
      prev_start_num <- payload[["line-numbers-start"]]

      # Defer page-start and footer/header attributes to the closing marker.
      # When the opening marker is the first paragraph (no predecessor), it
      # can't create a sectPr, but its attributes must still reach the closing
      # marker's section. (#70)
      ps <- payload[["page-start"]]
      if (!is.null(ps) && nzchar(ps)) {
        deferred_by_class[[m$section_class]] <-
          utils::modifyList(deferred_by_class[[m$section_class]] %||% list(),
                            list(page_start = ps))
        if (verbose) message("[assemble] Deferred page-start=", ps,
                             " from predecessorless opening marker ", m$section_class)
      }

      # Record in section sequence so the payload shift in finalize_docx
      # can propagate footer/header attributes to the closing marker's entry.
      section_sequence <- c(section_sequence, list(list(
        section_class = m$section_class,
        sectpr_para = NULL,
        is_closing = m$is_closing,
        line_numbers = m$line_numbers,
        field_code_payload = m$field_code_payload
      )))

      next
    }

    # Get page properties for this section
    section_props <- get_section_page_props(m$section_class, page_config)

    # Build sectPr XML using PREVIOUS section's line-numbers
    # (because sectPr ends the previous section, not starts the new one).
    #
    # Word's backward-looking section model:
    #   - Opening marker's sectPr attaches to the paragraph BEFORE the div,
    #     so it defines the PREVIOUS section (e.g., the title page section).
    #   - Closing marker's sectPr attaches to the last paragraph OF the div,
    #     so it defines THIS section (the div's own section).
    #
    # pgNumType placement depends on wrapping vs non-wrapping:
    #   - Wrapping divs (opening + closing pair): pgNumType goes on the CLOSING
    #     marker's sectPr, because that sectPr defines the div's own section.
    #   - Non-wrapping markers (opening only): pgNumType goes on the opening
    #     marker's sectPr, because it's the only sectPr for that transition.
    #
    # Page breaks use explicit <w:br type="page"/> emitted by Lua, NOT the
    # nextPage section type. All sectPrs use "continuous". See page-section.lua
    # lines 43-47 for rationale (nextPage unreliable with Pandoc bookmarks).
    # base_class: the opening section class for this marker.
    # For closing markers (e.g. "section-appendix-end"), strip "-end" to get
    # the matching opening class ("section-appendix"). For opening markers,
    # base_class == section_class.
    base_class <- sub("-end$", "", m$section_class)

    current_page_start <- NULL
    ps <- m$field_code_payload[["page-start"]]
    if (!is.null(ps) && nzchar(ps)) {
      if (m$is_closing) {
        # Wrapping div: closing marker's sectPr defines this section's numbering
        current_page_start <- ps
        if (verbose) message("[assemble] Closing marker page-start=", ps,
                             " -> current_page_start=", current_page_start)
      } else if (!isTRUE(m$has_closing_pair)) {
        # Non-wrapping: opening marker's sectPr is the only one for this transition
        current_page_start <- ps
        if (verbose) message("[assemble] Non-wrapping marker page-start=", ps,
                             " -> current_page_start=", current_page_start)
      } else {
        # Opening marker WITH a closing pair: defer page-start to the closing marker
        # (Lua strips page-start from closing markers, so we carry it forward here)
        deferred_by_class[[m$section_class]] <-
          utils::modifyList(deferred_by_class[[m$section_class]] %||% list(),
                            list(page_start = ps))
        if (verbose) message("[assemble] Deferred page-start=", ps,
                             " from opening marker ", m$section_class,
                             " to closing pair")
      }
    } else if (m$is_closing && !is.null(deferred_by_class[[base_class]]$page_start)) {
      # Apply deferred page-start from the matching opening marker
      current_page_start <- deferred_by_class[[base_class]]$page_start
      if (verbose) message("[assemble] Applied deferred page-start=",
                           current_page_start,
                           " to closing marker ", m$section_class)
      deferred_by_class[[base_class]]$page_start <- NULL
    } else {
      if (verbose) message("[assemble] No page-start for marker ",
                           m$section_class, " (payload keys: ",
                           paste(names(m$field_code_payload), collapse=", "), ")")
    }

    # Determine section type.
    # OOXML: w:type on a sectPr defines how the section DEFINED BY that sectPr
    # starts (i.e., the type of break between the previous section and this one).
    #
    # For opening markers with page-break: use nextPage so this section starts
    # on a new page. The Lua filter also emits a manual <w:br type="page"/>
    # which we remove (nextPage sectPr handles the break).
    #
    # For closing markers: use continuous by default, or use a deferred nextPage
    # if the FOLLOWING opening marker had page-break (meaning the section defined
    # by this closing marker's sectPr should start on a new page).
    #
    # Deferred nextPage: when adjacent closing + opening markers share the same
    # predecessor paragraph, the opening marker can't create its own sectPr.
    # Its page-break requirement is deferred and applied to the next closing
    # marker's sectPr (which defines the section the opening marker starts).
    if (!m$is_closing && m$page_break) {
      sect_type <- "nextPage"
    } else if (m$is_closing && !is.null(deferred_by_class[[base_class]]$sect_type)) {
      sect_type <- deferred_by_class[[base_class]]$sect_type
      if (verbose) message("[assemble] Applied deferred sect_type=", sect_type,
                           " to closing marker ", m$section_class)
      deferred_by_class[[base_class]]$sect_type <- NULL
    } else {
      sect_type <- "continuous"
    }

    sect_pr_xml <- build_sect_pr_xml(section_props, sect_type,
                                     prev_line_numbers, current_page_start,
                                     count_by = prev_count_by,
                                     distance = prev_distance,
                                     start_num = prev_start_num)
    if (verbose) message("[assemble] Built sectPr: page_start=",
                         if (is.null(current_page_start)) "NULL" else current_page_start,
                         " sect_type=", sect_type)

    # Attach sectPr to predecessor's pPr
    replaced_existing <- attach_sect_pr(prev_para, sect_pr_xml, ns)

    # If an opening marker with nextPage replaced an existing sectPr (from a
    # closing marker), the nextPage type now applies to the WRONG section.
    # Defer the nextPage to the next closing marker so it applies to the section
    # the opening marker actually starts.
    if (replaced_existing && sect_type == "nextPage" && !m$is_closing) {
      deferred_by_class[[m$section_class]] <-
        utils::modifyList(deferred_by_class[[m$section_class]] %||% list(),
                          list(sect_type = "nextPage"))
      if (verbose) message("[assemble] Deferred nextPage from opening marker ",
                           m$section_class, " (shared predecessor)")
    }

    # When using nextPage, remove the manual page break paragraph that Lua emitted
    # before this marker. The nextPage sectPr handles the page break; the manual
    # break would cause a double page break (extra blank page).
    if (sect_type == "nextPage") {
      # Walk backward from marker to find the page break paragraph Lua emitted.
      # No fixed limit: Pandoc may insert bookmarks, comment anchors, or other
      # structural elements between the break and the marker paragraph. Stop only
      # when siblings run out or we hit a paragraph with text content (which
      # means we've passed into real document content and should not keep looking).
      sib <- xml2::xml_find_first(para, "preceding-sibling::w:p[1]", ns)
      while (!inherits(sib, "xml_missing")) {
        br <- xml2::xml_find_first(sib, './/w:br[@w:type="page"]', ns)
        if (!inherits(br, "xml_missing")) {
          xml2::xml_remove(sib)
          if (verbose) message("[assemble] Removed manual page break before ", m$section_class)
          break
        }
        # Stop if sibling has visible text — we've entered real content
        has_text <- !inherits(
          xml2::xml_find_first(sib, ".//w:t[normalize-space(.) != '']", ns),
          "xml_missing"
        )
        if (has_text) break
        sib <- xml2::xml_find_first(sib, "preceding-sibling::w:p[1]", ns)
      }
    }

    n_assembled <- n_assembled + 1L

    # Track closing-marker sectPr paragraphs for remove_trailing_sectPr guard
    if (m$is_closing) {
      closing_sectpr_paras <- c(closing_sectpr_paras, list(prev_para))
    }

    # Record in section sequence (for header/footer injection)
    section_sequence <- c(section_sequence, list(list(
      section_class = m$section_class,
      sectpr_para = prev_para,
      is_closing = m$is_closing,
      line_numbers = m$line_numbers,
      field_code_payload = m$field_code_payload
    )))

    # Update prev_line_numbers for the next marker
    # The current marker's line_numbers describes what THIS section should have,
    # which will be applied when the NEXT marker's sectPr ends this section
    prev_line_numbers <- m$line_numbers
    # Per-section overrides from div attrs (via field_code_payload)
    payload <- m$field_code_payload
    prev_count_by <- payload[["line-numbers-count-by"]]
    prev_distance <- if (!is.null(payload[["line-numbers-distance"]])) {
      css_to_twips(payload[["line-numbers-distance"]])
    }
    prev_start_num <- payload[["line-numbers-start"]]

    if (!is.null(current_page_start) && verbose) {
      message("[assemble] Applied page-start=", current_page_start,
              " to ", marker_type, " sectPr at ", m$section_class)
    }
  }

  # Clear marker text but preserve field code structure for harvest round-trip.
  # The paragraph contains: fldChar(begin) / instrText / fldChar(separate) / w:t(marker) / fldChar(end)
  # We need to keep the field code so harvest can reconstruct the section div.
  #
  # Strategy: merge field code runs into the adjacent content paragraph,
  # then remove the marker paragraph. This eliminates the blank line entirely
  # rather than trying to collapse it to zero height (#69).
  #
  # Word suppresses w:before spacing at the top of a page — but only when the
  # paragraph IS the first on the page. A collapsed-but-present marker
  # paragraph prevents this suppression, creating a visible gap between the
  # header and the first heading. Removing the paragraph and merging the
  # field codes into the neighbour avoids this.
  for (m in rev(markers)) {
    para <- m$para

    # Clear the marker text but keep field code structure
    text_nodes <- xml2::xml_find_all(para, ".//w:t", ns)
    for (t_node in text_nodes) {
      text_content <- xml2::xml_text(t_node)
      if (grepl("^DOCSTYLE_SECTION", text_content)) {
        xml2::xml_set_text(t_node, "")
      }
    }

    # Try to merge into an adjacent paragraph and remove.
    # Opening markers merge into the NEXT paragraph; closing markers merge
    # into the PREVIOUS paragraph. If no suitable neighbour exists, fall
    # back to collapsing the paragraph in place.
    next_para <- xml2::xml_find_first(para, "following-sibling::w:p[1]", ns)
    prev_para <- xml2::xml_find_first(para, "preceding-sibling::w:p[1]", ns)
    merge_target <- if (!m$is_closing && !inherits(next_para, "xml_missing")) {
      next_para
    } else if (m$is_closing && !inherits(prev_para, "xml_missing")) {
      prev_para
    } else if (!inherits(next_para, "xml_missing")) {
      next_para
    } else if (!inherits(prev_para, "xml_missing")) {
      prev_para
    } else {
      NULL
    }

    if (!is.null(merge_target)) {
      # Move all w:r (run) elements from marker para into merge target.
      # For opening markers (merge into next), prepend runs at position 0
      # (after any existing pPr). For closing markers (merge into prev),
      # append runs at the end.
      runs <- xml2::xml_find_all(para, "w:r", ns)

      if (identical(merge_target, next_para)) {
        # Prepend: insert after pPr (position 0 would be before pPr)
        target_pPr <- xml2::xml_find_first(merge_target, "w:pPr", ns)
        insert_pos <- if (!inherits(target_pPr, "xml_missing")) 1L else 0L
        for (j in seq_along(runs)) {
          xml2::xml_add_child(merge_target, runs[[j]], .where = insert_pos + j - 1L)
        }
      } else {
        # Append to end of merge target
        for (run in runs) {
          xml2::xml_add_child(merge_target, run)
        }
      }

      # Transfer any sectPr from marker's pPr to merge target's pPr
      marker_pPr <- xml2::xml_find_first(para, "w:pPr", ns)
      if (!inherits(marker_pPr, "xml_missing")) {
        marker_sectPr <- xml2::xml_find_first(marker_pPr, "w:sectPr", ns)
        if (!inherits(marker_sectPr, "xml_missing")) {
          target_pPr <- xml2::xml_find_first(merge_target, "w:pPr", ns)
          if (inherits(target_pPr, "xml_missing")) {
            target_pPr <- xml2::xml_add_child(merge_target, "w:pPr", .where = 0)
          }
          # Remove existing sectPr on target if present
          existing <- xml2::xml_find_first(target_pPr, "w:sectPr", ns)
          if (!inherits(existing, "xml_missing")) xml2::xml_remove(existing)
          xml2::xml_add_child(target_pPr, marker_sectPr)
        }
      }

      # Remove the now-empty marker paragraph
      xml2::xml_remove(para)

      if (verbose) message("[assemble] Merged marker ", m$section_class,
                           " into ", if (identical(merge_target, next_para)) "next" else "previous",
                           " paragraph and removed marker paragraph")
    } else {
      # Fallback: collapse paragraph to near-zero height.
      # Uses line="1" (1/20 pt) with lineRule="exact" — Word treats line="0"
      # as invalid and falls back to "At least", rendering a full-height line.
      if (verbose) message("[assemble] No merge target for marker ", m$section_class,
                           ", collapsing in place")
      pPr <- xml2::xml_find_first(para, "w:pPr", ns)
      if (inherits(pPr, "xml_missing")) {
        pPr <- xml2::xml_add_child(para, "w:pPr", .where = 0)
      }
      spacing <- xml2::xml_find_first(pPr, "w:spacing", ns)
      if (inherits(spacing, "xml_missing")) {
        spacing <- xml2::xml_add_child(pPr, "w:spacing")
      }
      xml2::xml_set_attr(spacing, "w:before", "0")
      xml2::xml_set_attr(spacing, "w:after", "0")
      xml2::xml_set_attr(spacing, "w:line", "1")
      xml2::xml_set_attr(spacing, "w:lineRule", "exact")
      rPr <- xml2::xml_find_first(pPr, "w:rPr", ns)
      if (inherits(rPr, "xml_missing")) {
        rPr <- xml2::xml_add_child(pPr, "w:rPr")
      }
      sz <- xml2::xml_find_first(rPr, "w:sz", ns)
      if (inherits(sz, "xml_missing")) {
        sz <- xml2::xml_add_child(rPr, "w:sz")
      }
      xml2::xml_set_attr(sz, "w:val", "2")
    }
  }

  # === PASS 3: Update body sectPr with the LAST marker's line-numbers ===
  # The body sectPr (direct child of w:body) defines the final section.
  # The last marker's line_numbers describes what the final section should have.
  if (length(markers) > 0) {
    last_line_numbers <- markers[[length(markers)]]$line_numbers
    body_sectPr <- xml2::xml_find_first(body, "w:sectPr", ns)

    if (!inherits(body_sectPr, "xml_missing")) {
      lnNum <- xml2::xml_find_first(body_sectPr, "w:lnNumType", ns)

      # Set body sectPr to continuous to prevent a trailing blank page.
      # The final section (after the last closing marker) typically has no
      # visible content — just marker paragraphs. Without continuous, the
      # default nextPage type creates an empty page at the end.
      body_type <- xml2::xml_find_first(body_sectPr, "w:type", ns)
      if (inherits(body_type, "xml_missing")) {
        # Insert type before pgSz (correct OOXML element order)
        pgSz <- xml2::xml_find_first(body_sectPr, "w:pgSz", ns)
        if (!inherits(pgSz, "xml_missing")) {
          body_type <- xml2::xml_add_sibling(pgSz, "w:type", .where = "before")
        } else {
          body_type <- xml2::xml_add_child(body_sectPr, "w:type")
        }
      }
      xml2::xml_set_attr(body_type, "w:val", "continuous")
      if (verbose) message("[assemble] Set body sectPr type to continuous")

      if (last_line_numbers == "none" || last_line_numbers == "false") {
        # Final section should have NO line numbers - remove if present
        if (!inherits(lnNum, "xml_missing")) {
          xml2::xml_remove(lnNum)
          if (verbose) message("[assemble] Removed line numbers from body sectPr")
        }
      } else {
        # Final section SHOULD have line numbers
        restart_val <- switch(last_line_numbers,
          "continuous" = "continuous",
          "section" = "newSection",
          "page" = "newPage",
          "continuous"
        )

        # Resolve count-by/distance/start from last marker's payload → page_config
        last_payload <- markers[[length(markers)]]$field_code_payload
        ln_config <- page_config$`line-numbers`
        last_cb <- last_payload[["line-numbers-count-by"]]
        last_dist <- last_payload[["line-numbers-distance"]]
        last_start <- last_payload[["line-numbers-start"]]

        resolved_count_by <- last_cb %||% ln_config$`count-by` %||% 1L
        resolved_distance <- if (!is.null(last_dist)) {
          css_to_twips(last_dist)
        } else if (!is.null(ln_config$distance)) {
          css_to_twips(ln_config$distance)
        } else {
          360L
        }
        resolved_start <- last_start %||% ln_config$start

        if (inherits(lnNum, "xml_missing")) {
          # Add lnNumType after pgMar (standard OOXML element order)
          pgMar <- xml2::xml_find_first(body_sectPr, "w:pgMar", ns)
          if (!inherits(pgMar, "xml_missing")) {
            lnNum <- xml2::xml_add_sibling(pgMar, "w:lnNumType", .where = "after")
          } else {
            lnNum <- xml2::xml_add_child(body_sectPr, "w:lnNumType")
          }
        }
        xml2::xml_set_attr(lnNum, "w:countBy", as.character(as.integer(resolved_count_by)))
        xml2::xml_set_attr(lnNum, "w:restart", restart_val)
        xml2::xml_set_attr(lnNum, "w:distance", as.character(as.integer(resolved_distance)))
        if (!is.null(resolved_start)) {
          xml2::xml_set_attr(lnNum, "w:start", as.character(as.integer(resolved_start)))
        }
        if (verbose) {
          message("[assemble] Set body sectPr line numbers to: ", last_line_numbers)
        }
      }
    }

  }

  if (verbose && n_assembled > 0L) {
    message("[assemble] Assembled ", n_assembled, " section break(s) from markers")
  }

  final_section_name <- if (length(markers) > 0) {
    markers[[length(markers)]]$section_class
  } else {
    NULL
  }

  list(
    n_assembled = n_assembled,
    closing_sectpr_paras = closing_sectpr_paras,
    section_sequence = section_sequence,
    final_section_name = final_section_name
  )
}
