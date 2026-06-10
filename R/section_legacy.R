#' Legacy Section Processing (v1 Field-Code Based)
#'
#' v1 field-code-based section marker detection and section break fixing.
#' These functions handle ADDIN DOCSTYLE field codes emitted by Pandoc's
#' Lua filters and are maintained for backward compatibility.
#'
#' @noRd
NULL


#' Find DOCSTYLE Section Markers in Document XML
#'
#' Scans document body for ADDIN DOCSTYLE field codes with type "section".
#' Parses JSON payload to extract section configuration.
#'
#' @param body xml2 node for w:body
#' @param ns Named character vector of XML namespaces
#' @return List of marker records, each with: para, class, page_break,
#'   line_numbers, marker_type ("start" or "end")
#' @noRd
find_section_markers <- function(body, ns) {
  markers <- list()

  # Find all instrText nodes containing "ADDIN DOCSTYLE"
  instrs <- xml2::xml_find_all(body,
    './/w:instrText[contains(., "ADDIN DOCSTYLE")]', ns)

  for (instr in instrs) {
    text <- trimws(xml2::xml_text(instr))

    # Parse JSON payload after "ADDIN DOCSTYLE"
    json_str <- sub('.*ADDIN DOCSTYLE\\s+', '', text)
    json_str <- trimws(json_str)

    # Skip non-JSON (e.g., just "ADDIN DOCSTYLE" with no payload)
    if (!grepl("^\\{", json_str)) next

    config <- tryCatch(
      jsonlite::fromJSON(json_str),
      error = function(e) NULL
    )
    if (is.null(config)) next
    if (!identical(config$type, "section")) next

    # Find containing paragraph: instrText -> r -> p
    marker_para <- xml2::xml_parent(xml2::xml_parent(instr))

    markers <- append(markers, list(list(
      para = marker_para,
      class = config$class %||% "section-body",
      page_break = isTRUE(config$`page-break`),
      line_numbers = config$`line-numbers`,
      page_start = config$`page-start`,
      field_code_payload = config,
      marker_type = "start"
    )))
  }

  # Find END markers (field code end paragraphs that follow START markers)
  # These are paragraphs with only w:fldChar[@w:fldCharType="end"]
  # We pair each START with the next END to identify wrapping vs empty divs
  for (i in seq_along(markers)) {
    marker <- markers[[i]]
    # Look at siblings after the marker paragraph
    next_sib <- xml2::xml_find_first(marker$para, "following-sibling::w:p[1]", ns)
    if (inherits(next_sib, "xml_missing")) next

    # Check if next sibling is a sectPr paragraph (opening break)
    has_sectPr <- !inherits(
      xml2::xml_find_first(next_sib, "w:pPr/w:sectPr", ns), "xml_missing")

    if (has_sectPr) {
      markers[[i]]$opening_sectPr_para <- next_sib

      # Check the paragraph after the sectPr for field code end
      after_sectPr <- xml2::xml_find_first(next_sib, "following-sibling::w:p[1]", ns)
      if (!inherits(after_sectPr, "xml_missing")) {
        end_char <- xml2::xml_find_first(after_sectPr,
          'w:r/w:fldChar[@w:fldCharType="end"]', ns)
        if (!inherits(end_char, "xml_missing")) {
          markers[[i]]$end_para <- after_sectPr
          # Check if this is a wrapping div (content between end and closing sectPr)
          markers[[i]]$is_wrapping <- has_wrapping_content(after_sectPr, ns)
        }
      }
    }
  }

  # For wrapping divs, find the closing sectPr
  for (i in seq_along(markers)) {
    if (!isTRUE(markers[[i]]$is_wrapping)) next

    # The closing sectPr is the next sectPr paragraph after the field code end
    # It should be the last sectPr before the next DOCSTYLE marker (or end of doc)
    end_para <- markers[[i]]$end_para
    if (is.null(end_para)) next

    # Walk forward from end_para to find closing sectPr
    closing <- find_closing_sectPr(end_para, ns, markers, i)
    if (!is.null(closing)) {
      markers[[i]]$closing_sectPr_para <- closing
    }
  }

  markers
}


#' Check if a field code end paragraph is followed by wrapping content
#'
#' Distinguishes between two section div patterns:
#'
#' **Empty marker div** (the common pattern):
#'   ::: {.section-body line-numbers="continuous"} :::
#'   # Content follows the div...
#'
#' Structure: field code start -> sectPr -> field code end -> CONTENT
#' The sectPr ends the PREVIOUS section. Content after belongs to the NEW
#' section, whose properties come from the reference doc's body sectPr.
#' There is NO closing sectPr for this marker.
#'
#' **Wrapping div** (for scoped properties):
#'   ::: {.section-landscape}
#'   | Wide | Table |
#'   :::
#'
#' Structure: field code start -> sectPr -> field code end -> CONTENT -> closing sectPr
#' The closing sectPr scopes the section properties (landscape, line numbers)
#' to just the wrapped content.
#'
#' Detection logic: Walk forward from field code end. If we find a sectPr
#' BEFORE hitting another DOCSTYLE marker, it's a wrapping div. If we hit
#' another marker first (or end of document without a sectPr), it's an empty
#' marker div.
#'
#' @param end_para The field code end paragraph
#' @param ns XML namespaces
#' @return TRUE if this is a wrapping div (has closing sectPr)
#' @noRd
has_wrapping_content <- function(end_para, ns) {
  sibling <- xml2::xml_find_first(end_para, "following-sibling::w:p[1]", ns)
  n_content <- 0L

 while (!inherits(sibling, "xml_missing")) {
    # Check for sectPr (potential closing break for wrapping div)
    has_sect <- !inherits(
      xml2::xml_find_first(sibling, "w:pPr/w:sectPr", ns), "xml_missing")

    # Check for another DOCSTYLE marker (start of different section)
    has_marker <- !inherits(
      xml2::xml_find_first(sibling,
        'w:r/w:instrText[contains(., "ADDIN DOCSTYLE")]', ns), "xml_missing")

    # Found sectPr before another marker = wrapping div
    if (has_sect && n_content > 0) return(TRUE)

    # Hit another DOCSTYLE marker = empty marker div (the sectPr we might
    # find later belongs to that OTHER section, not this one)
    if (has_marker) return(FALSE)

    n_content <- n_content + 1L

    # Safety limit: if we've walked 50+ paragraphs without finding sectPr
    # or marker, assume empty marker (body content continues to end)
    if (n_content > 50L) return(FALSE)

    sibling <- xml2::xml_find_first(sibling, "following-sibling::w:p[1]", ns)
  }

  # Reached end of document without finding sectPr = empty marker div
  # The body sectPr (direct child of w:body) defines the final section
  FALSE
}


#' Find Closing sectPr for a Wrapping Div
#'
#' Walks forward from the field code end paragraph to find the closing
#' sectPr that ends the wrapped section.
#'
#' @param end_para The field code end paragraph
#' @param ns XML namespaces
#' @param markers All markers (to know where next section starts)
#' @param current_idx Index of current marker
#' @return The closing sectPr paragraph, or NULL
#' @noRd
find_closing_sectPr <- function(end_para, ns, markers, current_idx) {
  # Find the next marker's paragraph (if any) as boundary
  next_marker_para <- NULL
  if (current_idx < length(markers)) {
    next_marker_para <- markers[[current_idx + 1]]$para
  }

  last_sectPr <- NULL
  sibling <- xml2::xml_find_first(end_para, "following-sibling::w:p[1]", ns)

  while (!inherits(sibling, "xml_missing")) {
    # Stop if we've reached the next marker
    if (!is.null(next_marker_para) &&
        identical(xml2::xml_path(sibling), xml2::xml_path(next_marker_para))) {
      break
    }

    # Check for sectPr
    has_sect <- !inherits(
      xml2::xml_find_first(sibling, "w:pPr/w:sectPr", ns), "xml_missing")
    if (has_sect) {
      last_sectPr <- sibling
      break  # The first sectPr after content is the closing one
    }

    sibling <- xml2::xml_find_first(sibling, "following-sibling::w:p[1]", ns)
  }

  last_sectPr
}


#' Fix Section Breaks Based on Markers
#'
#' Validates and fixes sectPr elements adjacent to DOCSTYLE section markers.
#' Uses Word's section model: sectPr defines properties for the section that
#' ENDS at that point (not begins). So marker N's opening sectPr closes
#' marker N-1's section.
#'
#' For empty marker divs:
#' - First marker: opening sectPr closes front matter (no line numbers)
#' - Subsequent markers: opening sectPr closes PREVIOUS section (inherit that
#'   section's line numbers)
#'
#' For wrapping divs:
#' - Opening sectPr: same as empty markers
#' - Closing sectPr: has THIS marker's line numbers (scopes content)
#'
#' @param markers List of marker records from find_section_markers()
#' @param body xml2 node for w:body
#' @param ns XML namespaces
#' @param verbose Print diagnostic messages
#' @return Number of sectPr elements fixed
#' @noRd
fix_section_breaks <- function(markers, body, ns, verbose = FALSE) {

  n_fixed <- 0L

  # Track previous marker's line_numbers to apply to next marker's opening sectPr.
  # Word section model: sectPr defines properties for the section that ENDS at that point.
  # So marker N's opening sectPr closes marker N-1's section and should have N-1's line numbers.
  prev_line_numbers <- NULL

  for (i in seq_along(markers)) {
    marker <- markers[[i]]
    is_first_marker <- (i == 1L)

    # Fix opening sectPr based on position:
    # - First marker: closes front matter, should NOT have line numbers
    # - Subsequent markers: closes previous section, should have PREVIOUS line numbers
    if (!is.null(marker$opening_sectPr_para)) {
      sectPr <- xml2::xml_find_first(
        marker$opening_sectPr_para, "w:pPr/w:sectPr", ns)
      if (!inherits(sectPr, "xml_missing")) {
        lnNum <- xml2::xml_find_first(sectPr, "w:lnNumType", ns)

        if (is_first_marker) {
          # First marker: remove any line numbers (closes front matter)
          if (!inherits(lnNum, "xml_missing")) {
            xml2::xml_remove(lnNum)
            n_fixed <- n_fixed + 1L
            if (verbose) {
              message("[finalize] Removed line numbers from first opening sectPr for ",
                      marker$class, " (closes front matter)")
            }
          }
        } else if (!is.null(prev_line_numbers)) {
          # Subsequent marker: ensure previous section's line numbers are present
          if (inherits(lnNum, "xml_missing")) {
            # Line numbers missing - add them
            pgMar <- xml2::xml_find_first(sectPr, "w:pgMar", ns)
            if (!inherits(pgMar, "xml_missing")) {
              lnNum <- xml2::xml_add_sibling(pgMar, "w:lnNumType",
                                             .where = "after")
            } else {
              lnNum <- xml2::xml_add_child(sectPr, "w:lnNumType")
            }
            set_line_number_attrs(lnNum, prev_line_numbers, ns)
            n_fixed <- n_fixed + 1L
            if (verbose) {
              message("[finalize] Added line numbers to opening sectPr for ",
                      marker$class, " (", prev_line_numbers, ", from previous section)")
            }
          }
          # If already present, leave as-is (Lua filter set it correctly)
        } else {
          # Subsequent marker but previous had no line numbers - remove any
          if (!inherits(lnNum, "xml_missing")) {
            xml2::xml_remove(lnNum)
            n_fixed <- n_fixed + 1L
            if (verbose) {
              message("[finalize] Removed line numbers from opening sectPr for ",
                      marker$class, " (previous section had none)")
            }
          }
        }
      }

      # Suppress line numbering on the sectPr paragraph itself.
      # This paragraph is structural (holds the section break) and should
      # never display a line number. Insert at position 0 so it stays before
      # sectPr (OOXML requires sectPr to be the last child of pPr).
      pPr <- xml2::xml_find_first(marker$opening_sectPr_para, "w:pPr", ns)
      if (!inherits(pPr, "xml_missing")) {
        existing <- xml2::xml_find_first(pPr, "w:suppressLineNumbers", ns)
        if (inherits(existing, "xml_missing")) {
          xml2::xml_add_child(pPr, "w:suppressLineNumbers", .where = 0)
        }
      }
    }

    # Update tracking for next iteration
    prev_line_numbers <- marker$line_numbers

    # Fix closing sectPr: should have marker's line numbers
    if (isTRUE(marker$is_wrapping) && !is.null(marker$closing_sectPr_para) &&
        !is.null(marker$line_numbers)) {
      sectPr <- xml2::xml_find_first(
        marker$closing_sectPr_para, "w:pPr/w:sectPr", ns)
      if (!inherits(sectPr, "xml_missing")) {
        # Verify line numbers are present and correct
        lnNum <- xml2::xml_find_first(sectPr, "w:lnNumType", ns)
        if (inherits(lnNum, "xml_missing")) {
          # Line numbers missing — add them
          # Insert after pgMar if present
          pgMar <- xml2::xml_find_first(sectPr, "w:pgMar", ns)
          if (!inherits(pgMar, "xml_missing")) {
            lnNum <- xml2::xml_add_sibling(pgMar, "w:lnNumType",
                                           .where = "after")
          } else {
            lnNum <- xml2::xml_add_child(sectPr, "w:lnNumType")
          }
          set_line_number_attrs(lnNum, marker$line_numbers, ns)
          n_fixed <- n_fixed + 1L
          if (verbose) {
            message("[finalize] Added line numbers to closing sectPr for ",
                    marker$class, " (", marker$line_numbers, ")")
          }
        }
        # If already present, verify the restart value is correct
        # (Lua filter should have set it, but validate)
      }

      # Suppress line numbering on the closing sectPr paragraph itself.
      # Insert at position 0 to stay before sectPr (must be last in pPr).
      pPr <- xml2::xml_find_first(marker$closing_sectPr_para, "w:pPr", ns)
      if (!inherits(pPr, "xml_missing")) {
        existing <- xml2::xml_find_first(pPr, "w:suppressLineNumbers", ns)
        if (inherits(existing, "xml_missing")) {
          xml2::xml_add_child(pPr, "w:suppressLineNumbers", .where = 0)
        }
      }
    }
  }

  n_fixed
}


#' Set Line Number Attributes on a lnNumType Node
#'
#' @param lnNum xml2 node for w:lnNumType
#' @param line_numbers Character: "continuous", "section", "page"
#' @param ns XML namespaces
#' @param count_by Integer: count by N (default 1)
#' @param distance Integer: distance from text in twips (default 360)
#' @param start_num Integer or NULL: starting line number
#' @noRd
set_line_number_attrs <- function(lnNum, line_numbers, ns,
                                  count_by = 1L, distance = 360L,
                                  start_num = NULL) {
  xml2::xml_set_attr(lnNum, "w:countBy", as.character(as.integer(count_by)))
  xml2::xml_set_attr(lnNum, "w:distance", as.character(as.integer(distance)))

  # Map QMD attribute values to Word restart values
  restart_val <- switch(line_numbers,
    "continuous" = "continuous",
    "section" = "newSection",
    "page" = "newPage",
    "continuous"  # default
  )
  xml2::xml_set_attr(lnNum, "w:restart", restart_val)
  if (!is.null(start_num)) {
    xml2::xml_set_attr(lnNum, "w:start", as.character(as.integer(start_num)))
  }
}


#' Fix Body-Level sectPr
#'
#' The body-level sectPr (direct child of w:body) defines the final section's
#' properties. When the Lua filter uses wrapping divs with closing sectPr,
#' the final section should be clean: no line numbers, no headers/footers.
#' These leak from the reference doc and should only be added explicitly
#' per-section when section header/footer support is implemented.
#'
#' @param body xml2 node for w:body
#' @param ns XML namespaces
#' @param markers List of markers (to check if any wrapping divs exist)
#' @param verbose Print diagnostic messages
#' @return TRUE if body sectPr was modified
#' @noRd
fix_body_sectPr <- function(body, ns, markers, verbose = FALSE) {
  body_sectPr <- xml2::xml_find_first(body, "w:sectPr", ns)
  if (inherits(body_sectPr, "xml_missing")) return(FALSE)

  modified <- FALSE

  # When section markers exist, line numbers on the body sectPr are leaked
  # from reference.docx and should be removed. Line numbers belong only on
  # sections explicitly controlled by markers. The body sectPr defines the
  # final section (after all marked sections) and should not inherit them.
  # When no markers exist, this is a no-op — we don't modify documents
  # that have no section management.
  if (length(markers) > 0) {
    lnNum <- xml2::xml_find_first(body_sectPr, "w:lnNumType", ns)
    if (!inherits(lnNum, "xml_missing")) {
      xml2::xml_remove(lnNum)
      if (verbose) message("[finalize] Removed leaked line numbers from body sectPr")
      modified <- TRUE
    }
  }

  # Remove leaked header/footer references and titlePg from reference doc.
  # When sections are in use, the body sectPr defines the final section
  # which should be clean for the finisher to populate. Per-section
  # headers/footers and titlePg are added explicitly by
  # inject_section_headers_footers().
  ns_r <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
            r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships")
  hdr_refs <- xml2::xml_find_all(body_sectPr, "w:headerReference", ns_r)
  ftr_refs <- xml2::xml_find_all(body_sectPr, "w:footerReference", ns_r)

  if (length(hdr_refs) > 0 || length(ftr_refs) > 0) {
    for (ref in c(hdr_refs, ftr_refs)) {
      xml2::xml_remove(ref)
    }
    if (verbose) {
      message("[finalize] Removed ", length(hdr_refs), " header + ",
              length(ftr_refs), " footer reference(s) from body sectPr")
    }
    modified <- TRUE
  }

  # Remove leaked titlePg — the finisher adds it only where needed
  # (§17.10.6: titlePg gates first-page footer/header behaviour)
  titlePg <- xml2::xml_find_first(body_sectPr, "w:titlePg", ns)
  if (!inherits(titlePg, "xml_missing")) {
    xml2::xml_remove(titlePg)
    if (verbose) message("[finalize] Removed leaked titlePg from body sectPr")
    modified <- TRUE
  }

  modified
}


#' Apply Page Number Restart to Section Markers
#'
#' For markers with `page-start`, applies `w:pgNumType` and `nextPage` to the
#' correct sectPr. Uses Word's backward-looking section model: the sectPr that
#' defines a section's properties is the one at the END of that section.
#'
#' For wrapping div pairs (e.g., section-appendix / section-appendix-end):
#' - The closing marker's preceding sectPr defines the wrapped section
#' - `pgNumType` and `nextPage` go on that closing sectPr
#' - The opening marker is skipped (its preceding sectPr ends the PREVIOUS section)
#'
#' For empty marker divs (no closing pair):
#' - The marker's preceding sectPr ends the previous section AND starts this one
#' - `pgNumType` and `nextPage` go there
#'
#' @param markers List of marker records from find_section_markers()
#' @param body xml2 node for w:body
#' @param ns XML namespaces
#' @param verbose Print diagnostic messages
#' @return Number of sections modified
#' @noRd
apply_page_start <- function(markers, body, ns, verbose = FALSE) {
  n_applied <- 0L

  # Identify opening/closing pairs: an opening marker (e.g., "section-appendix")

  # has a matching closing marker (e.g., "section-appendix-end").
  # Build a set of opening marker classes that have a closing partner.
  closing_classes <- vapply(markers, function(m) m$class, character(1))
  has_closing_pair <- character(0)
  for (cls in closing_classes) {
    if (grepl("-end$", cls)) {
      opening_cls <- sub("-end$", "", cls)
      has_closing_pair <- c(has_closing_pair, opening_cls)
    }
  }

  for (marker in markers) {
    if (is.null(marker$page_start) || !nzchar(marker$page_start)) next

    # Skip opening markers that have a closing pair — the closing marker
    # has the sectPr that defines the wrapped section.
    if (marker$class %in% has_closing_pair) {
      if (verbose) {
        message("[finalize] Skipping page-start for opening marker ",
                marker$class, " (closing pair handles it)")
      }
      next
    }

    # Find the sectPr paragraph preceding this marker
    sib <- xml2::xml_find_first(marker$para, "preceding-sibling::w:p[1]", ns)
    sectPr <- NULL
    sectPr_para <- NULL

    # Walk backward up to 5 paragraphs to find the sectPr
    for (j in seq_len(5)) {
      if (inherits(sib, "xml_missing")) break
      sp <- xml2::xml_find_first(sib, "w:pPr/w:sectPr", ns)
      if (!inherits(sp, "xml_missing")) {
        sectPr <- sp
        sectPr_para <- sib
        break
      }
      sib <- xml2::xml_find_first(sib, "preceding-sibling::w:p[1]", ns)
    }

    if (is.null(sectPr)) {
      if (verbose) {
        message("[finalize] No preceding sectPr found for ", marker$class,
                " with page-start=", marker$page_start)
      }
      next
    }

    # Change section type from continuous to nextPage
    type_node <- xml2::xml_find_first(sectPr, "w:type", ns)
    if (!inherits(type_node, "xml_missing")) {
      xml2::xml_set_attr(type_node, "w:val", "nextPage")
    }

    # Add pgNumType with start value
    existing_pgNum <- xml2::xml_find_first(sectPr, "w:pgNumType", ns)
    if (inherits(existing_pgNum, "xml_missing")) {
      # Insert after lnNumType if present, else after pgMar
      lnNum <- xml2::xml_find_first(sectPr, "w:lnNumType", ns)
      pgMar <- xml2::xml_find_first(sectPr, "w:pgMar", ns)
      if (!inherits(lnNum, "xml_missing")) {
        pgNum <- xml2::xml_add_sibling(lnNum, "w:pgNumType", .where = "after")
      } else if (!inherits(pgMar, "xml_missing")) {
        pgNum <- xml2::xml_add_sibling(pgMar, "w:pgNumType", .where = "after")
      } else {
        pgNum <- xml2::xml_add_child(sectPr, "w:pgNumType")
      }
      xml2::xml_set_attr(pgNum, "w:start", marker$page_start)
    } else {
      xml2::xml_set_attr(existing_pgNum, "w:start", marker$page_start)
    }

    # Remove the manual page break near this section — nextPage handles it.
    # For closing markers (-end), the page break is near the OPENING marker
    # (the start of the section). Find the opening marker's paragraph.
    opening_para <- marker$para
    if (grepl("-end$", marker$class)) {
      opening_cls <- sub("-end$", "", marker$class)
      for (m in markers) {
        if (identical(m$class, opening_cls)) {
          opening_para <- m$para
          break
        }
      }
    }

    # Search forward from the opening marker paragraph, then backward from sectPr
    removed_break <- FALSE
    for (direction in c("forward", "backward")) {
      if (removed_break) break
      start <- if (direction == "forward") {
        xml2::xml_find_first(opening_para, "following-sibling::w:p[1]", ns)
      } else {
        xml2::xml_find_first(sectPr_para, "preceding-sibling::w:p[1]", ns)
      }
      brk_sib <- start
      for (j in seq_len(3)) {
        if (inherits(brk_sib, "xml_missing")) break
        br <- xml2::xml_find_first(brk_sib, './/w:br[@w:type="page"]', ns)
        if (!inherits(br, "xml_missing")) {
          xml2::xml_remove(brk_sib)
          removed_break <- TRUE
          if (verbose) {
            message("[finalize] Removed manual page break near ",
                    marker$class, " (nextPage handles it)")
          }
          break
        }
        brk_sib <- if (direction == "forward") {
          xml2::xml_find_first(brk_sib, "following-sibling::w:p[1]", ns)
        } else {
          xml2::xml_find_first(brk_sib, "preceding-sibling::w:p[1]", ns)
        }
      }
    }

    n_applied <- n_applied + 1L
    if (verbose) {
      message("[finalize] Set nextPage + pgNumType start=",
              marker$page_start, " on sectPr for ", marker$class)
    }
  }

  n_applied
}
