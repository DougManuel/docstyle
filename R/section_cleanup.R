#' Document Invariant Enforcement
#'
#' Post-assembly cleanup functions that enforce global document invariants:
#' no consecutive page breaks, structural paragraphs never show line numbers,
#' no trailing empty sections, and no orphaned paragraphs.
#'
#' @noRd
NULL


#' Suppress Line Numbers on Empty Paragraphs Before Headings
#'
#' @description
#' **DEPRECATED**: Use `suppress_structural_paragraphs()` instead, which
#' enforces the broader invariant that all paragraphs without text content
#' should have line numbers suppressed.
#'
#' Pandoc requires a blank line before headings in Markdown. This blank line
#' becomes an empty paragraph in the DOCX output. When line numbering is
#' enabled for a section, Word numbers these empty paragraphs, creating
#' a visible gap in the line count before each heading.
#'
#' This function finds empty paragraphs that immediately precede a heading
#' (possibly separated by bookmarkStart/bookmarkEnd elements) and adds
#' w:suppressLineNumbers to their paragraph properties.
#'
#' @param body xml2 node for w:body
#' @param ns XML namespaces
#' @param verbose Print diagnostic messages
#' @return Number of paragraphs where line numbers were suppressed
#' @noRd
suppress_pre_heading_line_numbers <- function(body, ns, verbose = FALSE) {
  n_suppressed <- 0L

  # Find all heading paragraphs
  heading_paras <- xml2::xml_find_all(body,
    './/w:p[w:pPr/w:pStyle[starts-with(@w:val, "Heading")]]', ns)

  for (heading in heading_paras) {
    # Walk backward past bookmarkStart/bookmarkEnd elements
    prev <- xml2::xml_find_first(heading, "preceding-sibling::*[1]")
    while (!inherits(prev, "xml_missing")) {
      prev_name <- xml2::xml_name(prev)
      if (prev_name %in% c("bookmarkStart", "bookmarkEnd")) {
        prev <- xml2::xml_find_first(prev, "preceding-sibling::*[1]")
      } else {
        break
      }
    }

    if (inherits(prev, "xml_missing")) next
    if (xml2::xml_name(prev) != "p") next

    # Check if the paragraph is empty (no visible text)
    text <- xml2::xml_text(prev)
    if (nzchar(trimws(text))) next

    # Check it doesn't already have suppressLineNumbers
    existing <- xml2::xml_find_first(prev, "w:pPr/w:suppressLineNumbers", ns)
    if (!inherits(existing, "xml_missing")) next

    # Add suppressLineNumbers to pPr (create pPr if needed)
    pPr <- xml2::xml_find_first(prev, "w:pPr", ns)
    if (inherits(pPr, "xml_missing")) {
      pPr <- xml2::xml_add_child(prev, "w:pPr", .where = 0)
    }
    xml2::xml_add_child(pPr, "w:suppressLineNumbers", .where = 0)

    n_suppressed <- n_suppressed + 1L
  }

  if (verbose && n_suppressed > 0) {
    message("[finalize] Suppressed line numbers on ", n_suppressed,
            " empty paragraph(s) before headings")
  }

  n_suppressed
}


#' Suppress Line Numbers on Page Break Paragraphs
#'
#' @description
#' **DEPRECATED**: Use `suppress_structural_paragraphs()` instead, which
#' enforces the broader invariant that all paragraphs without text content
#' should have line numbers suppressed.
#'
#' Page break paragraphs (`<w:p><w:r><w:br w:type="page"/></w:r></w:p>`) are
#' structural elements that shouldn't display line numbers. When a line-numbered
#' section ends with a page break before a section marker, Word numbers the
#' page break paragraph, causing a stray line number (e.g., "399") to appear
#' on an otherwise blank page.
#'
#' This function finds all paragraphs containing only a page break and adds
#' `<w:suppressLineNumbers/>` to their paragraph properties.
#'
#' @param body xml2 node for w:body
#' @param ns XML namespaces
#' @param verbose Print diagnostic messages
#' @return Number of page break paragraphs where line numbers were suppressed
#' @noRd
suppress_pagebreak_line_numbers <- function(body, ns, verbose = FALSE) {
  n_suppressed <- 0L


  # Find all paragraphs containing a page break
  pagebreak_paras <- xml2::xml_find_all(body,
    './/w:p[w:r/w:br[@w:type="page"]]', ns)

  for (para in pagebreak_paras) {
    # Check if paragraph has only a page break (no text content)
    text <- xml2::xml_text(para)
    if (nzchar(trimws(text))) next

    # Check it doesn't already have suppressLineNumbers
    existing <- xml2::xml_find_first(para, "w:pPr/w:suppressLineNumbers", ns)
    if (!inherits(existing, "xml_missing")) next

    # Add suppressLineNumbers to pPr (create pPr if needed)
    pPr <- xml2::xml_find_first(para, "w:pPr", ns)
    if (inherits(pPr, "xml_missing")) {
      # Insert pPr as first child of paragraph
      pPr <- xml2::xml_add_child(para, "w:pPr", .where = 0)
    }
    xml2::xml_add_child(pPr, "w:suppressLineNumbers", .where = 0)

    n_suppressed <- n_suppressed + 1L
  }

  if (verbose && n_suppressed > 0) {
    message("[finalize] Suppressed line numbers on ", n_suppressed,
            " page break paragraph(s)")
  }

  n_suppressed
}


#' Deduplicate Consecutive Page Breaks
#'
#' Enforces the invariant: "No two consecutive page breaks without intervening
#' content." When Lua filters and Pandoc both emit page breaks (e.g., from
#' `.section-body page-break="true"` and `\newpage`), redundant breaks create
#' extra blank pages.
#'
#' This function scans for `<w:br w:type="page"/>` elements and removes any
#' that are "consecutive" - meaning no `<w:t>` (text) nodes appear between them.
#' Structural elements like bookmarks, field codes, and sectPr are ignored.
#'
#' @param body xml2 node for w:body
#' @param ns XML namespaces
#' @param verbose Print diagnostic messages
#' @return Number of redundant page breaks removed
#' @noRd
deduplicate_page_breaks <- function(body, ns, verbose = FALSE) {
  n_removed <- 0L


  # Find all page break elements

  breaks <- xml2::xml_find_all(body, './/w:br[@w:type="page"]', ns)
  if (length(breaks) < 2) return(0L)

  # Track which breaks to remove (can't modify while iterating)
  to_remove <- c()

  for (i in seq_len(length(breaks) - 1)) {
    current_break <- breaks[[i]]
    next_break <- breaks[[i + 1]]

    # Check if there's any text content between these two breaks
    # We need to walk the XML between them and look for <w:t> nodes
    if (has_text_between(current_break, next_break, ns)) {
      next
    }

    # No text between breaks - mark the second one for removal
    to_remove <- c(to_remove, i + 1)
  }

  # Remove marked breaks (in reverse order to preserve indices)
  for (idx in rev(to_remove)) {
    # Remove the entire paragraph containing the break if it's empty
    break_node <- breaks[[idx]]
    para <- xml2::xml_parent(xml2::xml_parent(break_node))  # br -> r -> p

    # Check if paragraph contains only the break
    text <- xml2::xml_text(para)
    if (!nzchar(trimws(text))) {
      xml2::xml_remove(para)
    } else {
      # Paragraph has other content, just remove the break
      xml2::xml_remove(break_node)
    }
    n_removed <- n_removed + 1L
  }

  if (verbose && n_removed > 0) {
    message("[finalize] Removed ", n_removed, " redundant page break(s)")
  }

  n_removed
}


#' Check if Text Exists Between Two XML Nodes
#'
#' Walks the document from `start` to `end` and returns TRUE if any `<w:t>`
#' (text) nodes are found. Used by deduplicate_page_breaks() to determine
#' if two breaks are "consecutive" (no content between them).
#'
#' @param start xml2 node (first break)
#' @param end xml2 node (second break)
#' @param ns XML namespaces
#' @return TRUE if text content exists between the nodes
#' @noRd
has_text_between <- function(start, end, ns) {
  # Get the containing paragraphs

  start_para <- xml2::xml_parent(xml2::xml_parent(start))  # br -> r -> p
  end_para <- xml2::xml_parent(xml2::xml_parent(end))      # br -> r -> p

  # If same paragraph, check for text between the breaks within that para

  if (identical(xml2::xml_path(start_para), xml2::xml_path(end_para))) {
    # Check for any <w:t> in runs between the two breaks
    # This is rare - usually breaks are in separate paragraphs
    return(FALSE)
  }

  # Walk siblings from start_para to end_para
  sibling <- xml2::xml_find_first(start_para, "following-sibling::*[1]")

  while (!inherits(sibling, "xml_missing")) {
    # Reached the end paragraph
    if (identical(xml2::xml_path(sibling), xml2::xml_path(end_para))) {
      break
    }

    # Check for text in this element
    text_nodes <- xml2::xml_find_all(sibling, ".//w:t", ns)
    for (t_node in text_nodes) {
      text <- xml2::xml_text(t_node)
      if (nzchar(trimws(text))) {
        return(TRUE)
      }
    }

    sibling <- xml2::xml_find_first(sibling, "following-sibling::*[1]")
  }

  FALSE
}


#' Set w:before Spacing on a Paragraph
#'
#' Gets or creates w:pPr and w:spacing, then sets the w:before attribute.
#'
#' @param para xml2 node of the target paragraph
#' @param value Character string for w:before value in twips (e.g., "0")
#' @param ns XML namespaces
#' @return TRUE if spacing was modified, FALSE if already at target value
#' @noRd
set_paragraph_before_spacing <- function(para, value, ns) {
  pPr <- xml2::xml_find_first(para, "w:pPr", ns)
  if (inherits(pPr, "xml_missing")) {
    pPr <- xml2::xml_add_child(para, "w:pPr", .where = 0)
  }

  spacing <- xml2::xml_find_first(pPr, "w:spacing", ns)
  if (inherits(spacing, "xml_missing")) {
    spacing <- xml2::xml_add_child(pPr, "w:spacing")
  }

  current <- xml2::xml_attr(spacing, "before")
  if (!is.na(current) && current == value) return(FALSE)

  xml2::xml_set_attr(spacing, "w:before", value)
  TRUE
}


#' Find Document's First Content Paragraph
#'
#' Walks from the beginning of the document body to find the first paragraph
#' with actual text content, stopping if a sectPr boundary is reached.
#'
#' @param body xml2 node for w:body
#' @param ns XML namespaces
#' @return xml2 node of the first content paragraph, or NULL
#' @noRd
find_first_content_paragraph <- function(body, ns) {
  all_paras <- xml2::xml_find_all(body, "w:p", ns)

  for (para in all_paras) {
    # Check for text content first — a paragraph with both text and sectPr
    # is still the first content paragraph (e.g., a heading that received a
    # section break during assembly)
    text_nodes <- xml2::xml_find_all(para, ".//w:t", ns)
    para_text <- trimws(paste(xml2::xml_text(text_nodes), collapse = ""))
    if (nchar(para_text) > 0) return(para)

    # Stop if we hit a sectPr-carrying paragraph without content
    # (reached first section boundary with no preceding content)
    sect_pr <- xml2::xml_find_first(para, "w:pPr/w:sectPr", ns)
    if (!inherits(sect_pr, "xml_missing")) return(NULL)
  }

  NULL
}


#' Suppress Top Spacing on First Paragraph After Section Breaks
#'
#' Sets w:before="0" on the first content paragraph after each section
#' boundary where suppress-top-spacing is enabled. This compensates for
#' Word not honouring suppressSpBfAfterPgBrk after section breaks.
#'
#' Resolution precedence: div attribute > named @page config > global @page.
#'
#' @param body xml2 node for w:body
#' @param ns XML namespaces
#' @param page_config Page configuration from CSS @page rules
#' @param section_sequence Assembly result section sequence (original, pre-shift)
#' @param verbose Print diagnostic messages
#' @return Number of paragraphs where top spacing was suppressed
#' @noRd
suppress_first_paragraph_spacing <- function(body, ns, page_config,
                                              section_sequence = list(),
                                              verbose = FALSE) {
  n_suppressed <- 0L
  global_suppress <- isTRUE(page_config$`suppress-top-spacing`)

  # --- Handle document first paragraph (before any section break) ---
  # When the first section div has no predecessor (sectpr_para = NULL), the
  # document's first content paragraph is inside that div. Use the div's
  # attribute or the named page config for that section; fall back to global.
  first_para_suppress <- global_suppress
  if (length(section_sequence) > 0 && is.null(section_sequence[[1]]$sectpr_para)) {
    entry <- section_sequence[[1]]
    payload <- entry$field_code_payload
    section_name <- sub("^section-", "", entry$section_class)
    named <- page_config$named[[section_name]]

    if (!is.null(payload[["suppress-top-spacing"]])) {
      val <- tolower(payload[["suppress-top-spacing"]])
      first_para_suppress <- val %in% c("true", "yes", "1")
    } else if (!is.null(named) && !is.null(named$`suppress-top-spacing`)) {
      first_para_suppress <- isTRUE(named$`suppress-top-spacing`)
    }
  }

  if (first_para_suppress) {
    first_para <- find_first_content_paragraph(body, ns)
    if (!is.null(first_para)) {
      if (set_paragraph_before_spacing(first_para, "0", ns)) {
        n_suppressed <- n_suppressed + 1L
        if (verbose) {
          text_sample <- substr(trimws(xml2::xml_text(first_para)), 1, 40)
          message("[finalize] Suppressed top spacing on first paragraph: ", text_sample)
        }
      }
    }
  }

  # --- Handle section boundaries ---
  for (entry in section_sequence) {
    if (is.null(entry$sectpr_para)) next

    payload <- entry$field_code_payload
    section_name <- sub("^section-", "", entry$section_class)
    named <- page_config$named[[section_name]]

    # Resolve: div attribute > named @page > global @page
    should_suppress <- global_suppress
    if (!is.null(named) && !is.null(named$`suppress-top-spacing`)) {
      should_suppress <- isTRUE(named$`suppress-top-spacing`)
    }
    if (!is.null(payload[["suppress-top-spacing"]])) {
      val <- tolower(payload[["suppress-top-spacing"]])
      should_suppress <- val %in% c("true", "yes", "1")
    }

    if (!should_suppress) next

    successor <- find_first_content_successor(entry$sectpr_para, ns)
    if (is.null(successor)) next

    if (set_paragraph_before_spacing(successor, "0", ns)) {
      n_suppressed <- n_suppressed + 1L
      if (verbose) {
        text_sample <- substr(trimws(xml2::xml_text(successor)), 1, 40)
        message("[finalize] Suppressed top spacing on: ", text_sample)
      }
    }
  }

  if (verbose && n_suppressed > 0) {
    message("[finalize] Suppressed top spacing on ", n_suppressed,
            " first paragraph(s)")
  }

  n_suppressed
}


#' Suppress Line Numbers on Structural Paragraphs
#'
#' Enforces the invariant: "Structural paragraphs never display line numbers."
#' A paragraph is "structural" if it contains no `<w:t>` (text) nodes,
#' regardless of whether it contains bookmarks, field codes, comments, or
#' other non-text elements.
#'
#' This replaces the more targeted `suppress_pre_heading_line_numbers()` and
#' `suppress_pagebreak_line_numbers()` with unified logic based on the
#' absence of text content.
#'
#' @param body xml2 node for w:body
#' @param ns XML namespaces
#' @param verbose Print diagnostic messages
#' @return Number of structural paragraphs where line numbers were suppressed
#' @noRd
suppress_structural_paragraphs <- function(body, ns, verbose = FALSE) {
  n_suppressed <- 0L

  # Find all paragraphs
  all_paras <- xml2::xml_find_all(body, ".//w:p", ns)

  for (para in all_paras) {
    # Check if paragraph has any text content
    text_nodes <- xml2::xml_find_all(para, ".//w:t", ns)
    has_text <- FALSE
    for (t_node in text_nodes) {
      if (nzchar(trimws(xml2::xml_text(t_node)))) {
        has_text <- TRUE
        break
      }
    }

    # Skip paragraphs with text content
    if (has_text) next

    # Skip if already has suppressLineNumbers
    existing <- xml2::xml_find_first(para, "w:pPr/w:suppressLineNumbers", ns)
    if (!inherits(existing, "xml_missing")) next

    # Add suppressLineNumbers to pPr (create pPr if needed)
    pPr <- xml2::xml_find_first(para, "w:pPr", ns)
    if (inherits(pPr, "xml_missing")) {
      pPr <- xml2::xml_add_child(para, "w:pPr", .where = 0)
    }
    xml2::xml_add_child(pPr, "w:suppressLineNumbers", .where = 0)

    n_suppressed <- n_suppressed + 1L
  }

  if (verbose && n_suppressed > 0) {
    message("[finalize] Suppressed line numbers on ", n_suppressed,
            " structural paragraph(s)")
  }

  n_suppressed
}


#' Remove Trailing Closing sectPr
#'
#' When the last wrapping div's closing sectPr is followed only by non-content
#' elements (bookmarkEnd, empty paragraphs) before the body sectPr, Word
#' renders an empty final section as a blank page. This function removes
#' that trailing sectPr, letting the body sectPr define the final section.
#'
#' @param body xml2 node for w:body
#' @param ns XML namespaces
#' @param verbose Print diagnostic messages
#' @return TRUE if a trailing sectPr was removed
#' @noRd
remove_trailing_sectPr <- function(body, ns, closing_sectpr_paras = list(),
                                   verbose = FALSE) {
  # Find the body-level sectPr (last child of body, direct child)
  body_sectPr <- xml2::xml_find_first(body, "w:sectPr", ns)
  if (inherits(body_sectPr, "xml_missing")) return(FALSE)

  # Find all mid-document sectPr paragraphs (sectPr inside pPr)
  sect_paras <- xml2::xml_find_all(body, "w:p[w:pPr/w:sectPr]", ns)
  if (length(sect_paras) == 0) return(FALSE)

  last_sect_para <- sect_paras[[length(sect_paras)]]

  # Guard: do not remove closing-marker sectPr paragraphs.
  # These are intentional closing section breaks from wrapping divs that must
  # be preserved to restore the parent section's properties.
  for (closing_para in closing_sectpr_paras) {
    if (identical(xml2::xml_path(last_sect_para), xml2::xml_path(closing_para))) {
      if (verbose) {
        message("[finalize] Kept trailing sectPr (intentional closing section break)")
      }
      return(FALSE)
    }
  }

  # Check if there's any content between this sectPr para and the body sectPr.
  # Walk forward from last_sect_para; if we only find bookmarkEnd, bookmarkStart,
  # or empty paragraphs, the sectPr is trailing and creates an empty section.
  sibling <- xml2::xml_find_first(last_sect_para, "following-sibling::*[1]")
  has_content <- FALSE

  while (!inherits(sibling, "xml_missing")) {
    name <- xml2::xml_name(sibling)

    # Body sectPr is the end boundary
    if (name == "sectPr") break

    # bookmarkStart/bookmarkEnd are non-content
    if (name %in% c("bookmarkStart", "bookmarkEnd")) {
      sibling <- xml2::xml_find_first(sibling, "following-sibling::*[1]")
      next
    }

    # Empty paragraph (no text) is non-content
    if (name == "p") {
      text <- xml2::xml_text(sibling)
      if (!nzchar(trimws(text))) {
        sibling <- xml2::xml_find_first(sibling, "following-sibling::*[1]")
        next
      }
    }

    # Any other element or non-empty paragraph means there's content
    has_content <- TRUE
    break
  }

  if (has_content) return(FALSE)

  # Remove the trailing sectPr paragraph
  xml2::xml_remove(last_sect_para)

  if (verbose) {
    message("[finalize] Removed trailing closing sectPr (prevented empty final section)")
  }

  TRUE
}


#' Clean Up Orphaned Empty Paragraphs
#'
#' Removes empty paragraphs that the Lua filter may leave behind as artifacts
#' of page break hacks. An orphaned paragraph is one that:
#' - Has no text content
#' - Has no runs (or only runs with breaks)
#' - Is immediately adjacent to a sectPr paragraph
#'
#' @param body xml2 node for w:body
#' @param ns XML namespaces
#' @param verbose Print diagnostic messages
#' @return Number of paragraphs removed
#' @noRd
clean_orphaned_paragraphs <- function(body, ns, verbose = FALSE) {
  # For now, this is a no-op. Orphaned paragraph cleanup is deferred
  # until we have more confidence about which paragraphs are truly
  # orphaned vs intentional spacing.
  0L
}


#' Strip Redundant Namespace Declarations from sectPr Elements
#'
#' xml2 adds xmlns:w to every sectPr when they're parsed/added independently,
#' but the document already has this namespace at the root level. Word's parser
#' can fail when it sees duplicate namespace declarations on nested elements.
#'
#' @param xml_path Path to the XML file to clean
#' @param verbose Print diagnostic messages
#' @return Number of namespace declarations removed
#' @noRd
strip_redundant_sectpr_namespaces <- function(xml_path, verbose = FALSE) {
  xml_content <- readLines(xml_path, warn = FALSE)
  n_redundant <- sum(grepl('sectPr xmlns:w=', xml_content))

  if (n_redundant > 0) {
    xml_content <- gsub(
      '<w:sectPr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
      '<w:sectPr>',
      xml_content
    )
    writeLines(xml_content, xml_path)
    if (verbose) {
      message("[finalize] Removed ", n_redundant, " redundant xmlns:w declaration(s) from sectPr")
    }
  }

  n_redundant
}


#' Enable Automatic Field Updates on Document Open
#'
#' Adds `<w:updateFields w:val="true"/>` to word/settings.xml so that
#' Word recalculates PAGE, NUMPAGES, and other field codes when the
#' document is opened. Without this, field codes show stale cached values.
#'
#' @param temp_dir Path to unzipped DOCX directory
#' @param verbose Print diagnostic messages
#' @return TRUE if settings were modified, FALSE otherwise
#' @noRd
enable_field_updates <- function(temp_dir, verbose = FALSE) {
  settings_path <- file.path(temp_dir, "word", "settings.xml")
  if (!file.exists(settings_path)) return(FALSE)

  xml <- xml2::read_xml(settings_path)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # Check if already present
  existing <- xml2::xml_find_first(xml, "//w:updateFields", ns)
  if (!inherits(existing, "xml_missing")) return(FALSE)

  # Add as first child of w:settings
  update_node <- xml2::xml_add_child(xml, "w:updateFields", .where = 0)
  xml2::xml_set_attr(update_node, "w:val", "true")

  xml2::write_xml(xml, settings_path)

  if (verbose) {
    message("[finalize] Added updateFields to settings.xml")
  }

  TRUE
}


#' Clean Up Orphaned Footer/Header Files
#'
#' Removes footer/header XML files that exist in the DOCX but are not
#' referenced by any sectPr element. This happens when the pre-render
#' phase writes footer1.xml into reference.docx, but the post-render
#' finisher writes new footer files and points sectPr references to them,
#' leaving the original files orphaned.
#'
#' @param doc_xml_path Path to document.xml
#' @param temp_dir Path to unzipped DOCX directory
#' @param verbose Print diagnostic messages
#' @return Number of orphaned files removed
#' @noRd
cleanup_orphaned_hf_files <- function(doc_xml_path, temp_dir, verbose = FALSE) {
  # 1. Collect all referenced rIds from sectPr elements in document.xml
  doc <- xml2::read_xml(doc_xml_path)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
          r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships")

  # Find all footerReference and headerReference elements (in any sectPr)
  refs <- xml2::xml_find_all(doc, "//w:footerReference | //w:headerReference", ns)
  referenced_rids <- vapply(refs, function(r) {
    rid <- xml2::xml_attr(r, "id")
    if (is.na(rid)) rid <- xml2::xml_attr(r, "r:id")
    rid
  }, character(1))
  referenced_rids <- unique(referenced_rids[!is.na(referenced_rids)])

  # 2. Scan document.xml.rels for footer/header relationships
  rels_path <- file.path(temp_dir, "word", "_rels", "document.xml.rels")
  if (!file.exists(rels_path)) return(0L)

  rels_xml <- xml2::read_xml(rels_path)
  rels_ns <- c(d1 = "http://schemas.openxmlformats.org/package/2006/relationships")

  footer_type <- "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer"
  header_type <- "http://schemas.openxmlformats.org/officeDocument/2006/relationships/header"

  all_hf_rels <- xml2::xml_find_all(rels_xml, sprintf(
    './/d1:Relationship[@Type="%s" or @Type="%s"]', footer_type, header_type
  ), rels_ns)

  if (length(all_hf_rels) == 0) return(0L)

  # 3. Read content types once before the loop
  ct_path <- file.path(temp_dir, "[Content_Types].xml")
  ct_xml <- if (file.exists(ct_path)) xml2::read_xml(ct_path) else NULL
  ct_ns <- c(ct = "http://schemas.openxmlformats.org/package/2006/content-types")

  # 4. Identify and remove orphaned entries
  n_removed <- 0L
  for (rel in all_hf_rels) {
    rid <- xml2::xml_attr(rel, "Id")
    target <- xml2::xml_attr(rel, "Target")

    if (rid %in% referenced_rids) next

    # Orphaned — remove the XML file
    file_path <- file.path(temp_dir, "word", target)
    if (file.exists(file_path)) {
      file.remove(file_path)
    }

    # Remove the relationship entry
    xml2::xml_remove(rel)

    # Remove content type override
    if (!is.null(ct_xml)) {
      part_name <- paste0("/word/", target)
      override <- xml2::xml_find_first(ct_xml,
        sprintf('.//ct:Override[@PartName="%s"]', part_name), ct_ns)
      if (!inherits(override, "xml_missing")) {
        xml2::xml_remove(override)
      }
    }

    n_removed <- n_removed + 1L
    if (verbose) {
      message("[finalize] Removed orphaned ", target, " (", rid, ")")
    }
  }

  # Write updated files if we removed anything
  if (n_removed > 0) {
    xml2::write_xml(rels_xml, rels_path)
    if (!is.null(ct_xml)) xml2::write_xml(ct_xml, ct_path)
  }

  n_removed
}
