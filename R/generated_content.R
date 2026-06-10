#' Generated Content Detection for Docx Harvesting
#'
#' Functions for detecting docstyle-generated content blocks in Word documents.
#' These include bookmark ranges, field code wrappers, native section breaks,
#' and footer content extraction.
#'
#' @name generated_content
#' @keywords internal
NULL


#' Mapping from _docstyle_* bookmark names to div placeholders
#' @noRd
bookmark_to_div <- list(
  `_docstyle_version_history` = c("::: version-history", ":::"),
  `_docstyle_author_plate` = c("::: author-plate", ":::"),
  `_docstyle_toc` = c("::: toc", ":::")
)


#' Detect _docstyle_* bookmarks in document body and build index ranges
#'
#' Returns a list of bookmark ranges, each with: name, start_idx, end_idx,
#' div_open, div_close. Indices refer to positions in the children node list.
#' @noRd
detect_docstyle_bookmarks <- function(body, children, ns) {
  # Find all _docstyle_* bookmark starts
  bk_starts <- xml2::xml_find_all(
    body,
    ".//w:bookmarkStart[starts-with(@w:name, '_docstyle_')]",
    ns
  )

  if (length(bk_starts) == 0) return(list())

  ranges <- list()
  n_children <- length(children)

  for (bk in bk_starts) {
    # Attributes are in the w: namespace in XPath but xml2::xml_attr uses local names
    bk_name <- xml2::xml_attr(bk, "name")
    bk_id <- xml2::xml_attr(bk, "id")

    if (is.na(bk_name) || is.na(bk_id)) next
    if (is.null(bookmark_to_div[[bk_name]])) next

    # Find matching bookmarkEnd by id
    bk_end <- xml2::xml_find_first(
      body,
      sprintf(".//w:bookmarkEnd[@w:id='%s']", bk_id),
      ns
    )
    if (length(bk_end) == 0) next

    # Find which body children contain these bookmarks
    # bookmarkStart/End may be direct children of body or nested in paragraphs
    bk_start_parent <- find_body_child_index(bk, body, children, n_children)
    bk_end_parent <- find_body_child_index(bk_end, body, children, n_children)

    if (is.na(bk_start_parent) || is.na(bk_end_parent)) next

    div_parts <- bookmark_to_div[[bk_name]]
    ranges[[length(ranges) + 1]] <- list(
      name      = bk_name,
      start_idx = bk_start_parent,
      end_idx   = bk_end_parent,
      type      = if (bk_name == "_docstyle_version_history") "version-history" else NULL,
      div_open  = div_parts[1],
      div_close = div_parts[2]
    )
  }

  ranges
}


#' Detect ADDIN DOCSTYLE block-level field codes in document body
#'
#' Pre-scans body children for paragraphs containing ``fldChar[begin]`` with
#' instrText matching "ADDIN DOCSTYLE" and a JSON payload with type="div".
#' Tracks the range from the begin paragraph to the end paragraph.
#'
#' Uses the unified field code parser from field_codes.R for payload extraction
#' and schema validation.
#'
#' Returns a list of ranges with the same structure as detect_docstyle_bookmarks():
#' name, start_idx, end_idx, div_open, div_close.
#'
#' @param body The w:body XML node
#' @param children XML node set (body children)
#' @param ns XML namespace
#' @return List of field code ranges
#' @noRd
detect_docstyle_field_codes <- function(body, children, ns) {
  n_children <- length(children)
  ranges <- list()

  # State machine: idle or tracking a block field code
  state <- "idle"
  current_handler_result <- NULL  # Result from dispatch_docstyle_handler()
  start_idx <- NULL
  nesting <- 0L

  for (i in seq_len(n_children)) {
    child <- children[[i]]

    # Find all fldChar elements in this child
    fld_chars <- xml2::xml_find_all(child, ".//w:fldChar", ns)
    if (length(fld_chars) == 0) next

    for (fc in fld_chars) {
      fc_type <- xml2::xml_attr(fc, "fldCharType")

      if (state == "idle" && fc_type == "begin") {
        # Look for instrText in the same body child (paragraph/table)
        instr_nodes <- xml2::xml_find_all(child, ".//w:instrText", ns)
        instr_text <- paste(xml2::xml_text(instr_nodes), collapse = "")

        # Use unified parser from field_codes.R
        payload <- parse_docstyle_payload(instr_text)

        if (!is.null(payload)) {
          # Only handle block-level types (div, list, section, table, figure) here
          # char type is handled inline in docx_to_qmd.R
          if (payload$type %in% c("div", "list", "section", "table", "figure", "float", "anchor")) {
            handler_result <- dispatch_docstyle_handler(payload)
            if (!is.null(handler_result)) {
              state <- "in_block"
              current_handler_result <- handler_result
              start_idx <- i
              nesting <- 1L
            }
          }
        } else if (grepl("ADDIN ZOTERO_BIBL", instr_text)) {
          # Zotero bibliography field code — treat as block-level div
          state <- "in_block"
          current_handler_result <- list(
            type = "div",
            name = "bibliography",
            div_open = "::: bibliography",
            div_close = ":::"
          )
          start_idx <- i
          nesting <- 1L
        }
      } else if (state == "in_block") {
        if (fc_type == "begin") {
          nesting <- nesting + 1L
        } else if (fc_type == "end") {
          nesting <- nesting - 1L
          if (nesting == 0L) {
            # Found the matching end - use handler result for div_open/close
            # All types now use registry-driven div_open/div_close from handlers
            hr <- current_handler_result
            range_name <- if (hr$type == "div") hr$name else (hr$class %||% hr$id %||% hr$type)
            ranges[[length(ranges) + 1]] <- list(
              name          = range_name,
              type          = hr$type,
              start_idx     = start_idx,
              end_idx       = i,
              div_open      = hr$div_open,
              div_close     = hr$div_close,
              id            = hr$id,
              docpr_id      = hr$docpr_id,
              original_path = hr$original_path
            )
            state <- "idle"
            current_handler_result <- NULL
            start_idx <- NULL
          }
        }
      }
    }
  }

  if (length(ranges) > 0) {
    message("  Detected ", length(ranges), " block field code(s)")
  }

  ranges
}


#' Extract footer references, page start, and titlePg from a sectPr node
#'
#' Shared extraction logic for both mid-document and body-level sectPr.
#'
#' @param sect_pr An xml2 node for a w:sectPr element
#' @param ns XML namespaces
#' @return List with footer_refs, page_start, has_title_pg
#' @noRd
extract_sectpr_footer_info <- function(sect_pr, ns) {
  w_ns <- "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

  # Footer references: w:footerReference with type + r:id
  footer_ref_nodes <- xml2::xml_find_all(sect_pr, "w:footerReference", ns)
  footer_refs <- list()
  for (fref in footer_ref_nodes) {
    ftype <- xml2::xml_attr(fref, paste0("{", w_ns, "}", "type"))
    if (is.na(ftype)) ftype <- xml2::xml_attr(fref, "type")
    r_ns <- "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    frid <- xml2::xml_attr(fref, paste0("{", r_ns, "}", "id"))
    if (is.na(frid)) frid <- xml2::xml_attr(fref, "r:id")
    if (is.na(frid)) frid <- xml2::xml_attr(fref, "id")
    if (!is.na(ftype) && !is.na(frid)) {
      if (tolower(ftype) == "even") {
        warning("Even-page footer reference found (rId: ", frid,
                "); even-page footers are not supported and will be ignored.",
                call. = FALSE)
      }
      footer_refs[[length(footer_refs) + 1]] <- list(
        type = tolower(ftype), r_id = frid
      )
    }
  }

  # Page number type: w:pgNumType w:start="N"
  pg_num_node <- xml2::xml_find_first(sect_pr, "w:pgNumType", ns)
  page_start <- if (!inherits(pg_num_node, "xml_missing")) {
    val <- xml2::xml_attr(pg_num_node, paste0("{", w_ns, "}", "start"))
    if (is.na(val)) val <- xml2::xml_attr(pg_num_node, "start")
    if (is.na(val)) NULL else val
  } else {
    NULL
  }

  # titlePg flag (enables first-page different header/footer)
  title_pg <- xml2::xml_find_first(sect_pr, "w:titlePg", ns)
  has_title_pg <- !inherits(title_pg, "xml_missing") && length(title_pg) > 0

  list(
    footer_refs = footer_refs,
    page_start = page_start,
    has_title_pg = has_title_pg
  )
}


#' Detect native Word section breaks in document body
#'
#' Pre-scans body children for paragraphs containing w:pPr/w:sectPr elements
#' (mid-document section breaks). These are native Word section breaks without
#' ADDIN DOCSTYLE field code wrappers. Only called when no section-type field
#' codes exist (first-time harvest from natively-authored documents).
#'
#' In OOXML, a w:sectPr inside w:pPr defines properties for the section that
#' ENDS at that paragraph.
#'
#' @param children XML node set (body children)
#' @param ns XML namespace
#' @return List of section boundary records
#' @noRd
detect_native_section_breaks <- function(children, ns) {
  w_ns <- "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
  n_children <- length(children)
  breaks <- list()

  for (i in seq_len(n_children)) {
    child <- children[[i]]
    if (xml2::xml_name(child) != "p") next

    # Look for sectPr inside pPr (mid-document section break)
    sect_pr <- xml2::xml_find_first(child, ".//w:pPr/w:sectPr", ns)
    if (inherits(sect_pr, "xml_missing") || length(sect_pr) == 0) next

    # Extract section break type
    # Use namespace-qualified then bare attribute (w:type w:val="...")
    w_ns <- "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    type_node <- xml2::xml_find_first(sect_pr, "w:type", ns)
    break_type <- if (!inherits(type_node, "xml_missing")) {
      val <- xml2::xml_attr(type_node, paste0("{", w_ns, "}", "val"))
      if (is.na(val)) val <- xml2::xml_attr(type_node, "val")
      val
    } else {
      "nextPage"
    }

    # Extract line numbering
    ln_num <- xml2::xml_find_first(sect_pr, "w:lnNumType", ns)
    has_ln <- !inherits(ln_num, "xml_missing") && length(ln_num) > 0
    ln_restart <- NULL
    ln_count_by <- NULL
    ln_start <- NULL
    ln_distance <- NULL
    if (has_ln) {
      val <- xml2::xml_attr(ln_num, paste0("{", w_ns, "}", "restart"))
      if (is.na(val)) val <- xml2::xml_attr(ln_num, "restart")
      ln_restart <- if (is.na(val)) NULL else val

      val <- xml2::xml_attr(ln_num, paste0("{", w_ns, "}", "countBy"))
      if (is.na(val)) val <- xml2::xml_attr(ln_num, "countBy")
      ln_count_by <- if (is.na(val)) NULL else val

      val <- xml2::xml_attr(ln_num, paste0("{", w_ns, "}", "start"))
      if (is.na(val)) val <- xml2::xml_attr(ln_num, "start")
      ln_start <- if (is.na(val)) NULL else val

      val <- xml2::xml_attr(ln_num, paste0("{", w_ns, "}", "distance"))
      if (is.na(val)) val <- xml2::xml_attr(ln_num, "distance")
      ln_distance <- if (is.na(val)) NULL else val
    }

    # Extract footer references, page start, and titlePg
    fi <- extract_sectpr_footer_info(sect_pr, ns)

    # Check if paragraph has visible text content
    text_nodes <- xml2::xml_find_all(child, ".//w:t", ns)
    para_text <- paste(xml2::xml_text(text_nodes), collapse = "")
    has_content <- nchar(trimws(para_text)) > 0

    # Detect explicit page breaks near the section break.
    # Source documents often use <w:br w:type="page"/> paragraphs alongside
    # continuous section breaks (rather than nextPage section type).
    # Check the section break paragraph itself and the one before it.
    has_page_break <- length(xml2::xml_find_all(
      child, ".//w:r/w:br[@w:type='page']", ns)) > 0
    if (!has_page_break && i > 1L) {
      prev <- children[[i - 1L]]
      if (xml2::xml_name(prev) == "p") {
        has_page_break <- length(xml2::xml_find_all(
          prev, ".//w:r/w:br[@w:type='page']", ns)) > 0
      }
    }

    breaks[[length(breaks) + 1]] <- list(
      idx = i,
      type = break_type,
      has_line_numbers = has_ln,
      line_numbers_restart = ln_restart,
      line_numbers_count_by = ln_count_by,
      line_numbers_start = ln_start,
      line_numbers_distance = ln_distance,
      footer_refs = fi$footer_refs,
      page_start = fi$page_start,
      has_title_pg = fi$has_title_pg,
      has_content = has_content,
      has_page_break = has_page_break
    )
  }

  if (length(breaks) > 0) {
    message("  Detected ", length(breaks), " native Word section break(s)")
  }

  breaks
}


#' Extract footer info from the body-level sectPr
#'
#' The body-level sectPr (direct child of w:body) defines properties for the
#' final section. Unlike mid-document sectPr (inside w:pPr), this one is not
#' found by detect_native_section_breaks(). Returns the same structure as
#' extract_sectpr_footer_info().
#'
#' @param body An xml2 node for the w:body element
#' @param ns XML namespaces
#' @return List with footer_refs, page_start, has_title_pg, or NULL if no body sectPr
#' @noRd
extract_body_sectpr_footer_info <- function(body, ns) {
  sect_pr <- xml2::xml_find_first(body, "w:sectPr", ns)
  if (inherits(sect_pr, "xml_missing") || length(sect_pr) == 0) {
    return(NULL)
  }
  extract_sectpr_footer_info(sect_pr, ns)
}


#' Convert native section boundaries to wrapping div ranges
#'
#' Takes section boundary records from detect_native_section_breaks() and
#' produces ranges suitable for the main paragraph loop. Sections with
#' special properties (line numbering, footers, page start) get wrapping divs.
#' Each qualifying section gets its own wrapper (adjacent sections are NOT merged).
#'
#' @param breaks List of section boundary records
#' @param n_children Total number of body children
#' @param footer_lookup Named list from get_footer_lookup() mapping rId to parsed
#'   footer content. NULL disables footer attribute generation.
#' Match a native section break to a CSS named @page rule
#'
#' Compares a section's properties (line numbers, restart mode) against the
#' named `@page` rules in the project CSS and returns the best-matching name.
#' Falls back to `"body"` when no CSS is provided or no match is found.
#'
#' Matching priority:
#' 1. Line-number restart mode matches (`continuous`, `page`, `section`)
#' 2. Line-number enabled/disabled state
#' 3. First CSS named page as tiebreaker
#'
#' @param brk A single section break record from `detect_native_section_breaks()`.
#' @param page_config Page configuration list with a `$named` sub-list of CSS
#'   named `@page` rules. NULL returns `"body"`.
#' @return A section name string without the `section-` prefix (e.g. `"body"`).
#' @noRd
match_css_section_name <- function(brk, page_config) {
  named <- page_config$named
  if (is.null(named) || length(named) == 0) return("body")

  # Normalize the section's own line-number restart to the CSS vocabulary
  brk_restart <- if (brk$has_line_numbers) {
    switch(brk$line_numbers_restart %||% "continuous",
      newSection  = "section",
      newPage     = "page",
      continuous  = "continuous",
      "continuous"
    )
  } else {
    NULL
  }

  # Score each named CSS page rule against this section's properties
  best_name  <- NULL
  best_score <- -1L

  for (css_name in names(named)) {
    css_ln <- named[[css_name]]$`line-numbers`
    css_has_ln <- isTRUE(css_ln$enabled)

    score <- 0L

    if (brk$has_line_numbers && css_has_ln) {
      score <- 1L  # both have line numbers
      # Bonus: restart mode matches
      css_restart <- css_ln$restart %||% "continuous"
      if (!is.null(brk_restart) && css_restart == brk_restart) {
        score <- 2L
      }
    } else if (!brk$has_line_numbers && !css_has_ln) {
      score <- 1L  # both have no line numbers
    }

    if (score > best_score) {
      best_score <- score
      best_name  <- css_name
    }
  }

  best_name %||% "body"
}


#' @param body_footer_info Footer info for the body-level sectPr (final section),
#'   from extract_body_sectpr_footer_info(). NULL if no body sectPr.
#' @param page_config Page configuration from `load_page_config()` or `parse_page_rules()`.
#'   Used to match native section properties against CSS named `@page` rules and
#'   emit the correct `::: {.section-*}` class (e.g. `.section-body` instead of
#'   the generic fallback). NULL disables CSS-aware naming.
#' @return List of ranges with: name, type, start_idx, end_idx, div_open, div_close
#' @noRd
section_breaks_to_ranges <- function(breaks, n_children,
                                     footer_lookup = NULL,
                                     body_footer_info = NULL,
                                     page_config = NULL) {
  if (length(breaks) == 0 && is.null(body_footer_info)) return(list())

  ranges <- list()

  # Build the full section list: mid-document breaks + body sectPr as final section
  all_sections <- breaks
  if (!is.null(body_footer_info)) {
    # The body sectPr defines the section from the last mid-document break
    # to the end of the document (minus the sectPr node itself)
    all_sections[[length(all_sections) + 1]] <- list(
      idx = n_children,  # body sectPr is the last child
      type = "final",
      has_line_numbers = FALSE,
      line_numbers_restart = NULL,
      footer_refs = body_footer_info$footer_refs,
      page_start = body_footer_info$page_start,
      has_title_pg = body_footer_info$has_title_pg,
      has_content = FALSE,
      has_page_break = FALSE,
      is_body_sectpr = TRUE
    )
  }

  # Resolve footer inheritance: maintain effective state across sections
  effective_default_footer <- NULL  # Current effective default footer rId
  effective_first_footer <- NULL    # Current effective first-page footer rId

  for (k in seq_along(all_sections)) {
    brk <- all_sections[[k]]

    # Resolve footer references for this section
    has_explicit_default <- FALSE
    has_explicit_first <- FALSE
    for (fref in brk$footer_refs) {
      if (fref$type == "default") {
        effective_default_footer <- fref$r_id
        has_explicit_default <- TRUE
      } else if (fref$type == "first") {
        effective_first_footer <- fref$r_id
        has_explicit_first <- TRUE
      }
      # "even" type already warned and is ignored for attribute generation
    }

    # Build footer attributes from the effective footer state
    footer_attrs <- build_footer_div_attrs(
      effective_default_footer, effective_first_footer,
      brk$has_title_pg, brk$page_start, footer_lookup
    )

    # Check if this section has any special properties worth wrapping
    has_special <- brk$has_line_numbers || nchar(footer_attrs) > 0

    if (!has_special) next

    # Section content start: paragraph after previous break (or 1 for first)
    content_start <- if (k == 1L) 1L else (all_sections[[k - 1L]]$idx + 1L)

    # Section content end
    if (isTRUE(brk$is_body_sectpr)) {
      # Body sectPr: wrap up to last content child (not the sectPr node itself)
      content_end <- n_children - 1L
    } else {
      content_end <- if (brk$has_content) brk$idx else (brk$idx - 1L)
    }

    if (content_start > content_end) next

    # Determine section class name: match CSS named @page rules by properties,
    # or fall back to "section-body"
    section_name <- match_css_section_name(brk, page_config)

    # Build div_open with attributes
    div_open <- paste0("::: {.section-", section_name)

    # Page break attribute
    prev_has_page_break <- if (k > 1L) isTRUE(all_sections[[k - 1L]]$has_page_break) else FALSE
    if (brk$type == "nextPage" || isTRUE(brk$has_page_break) || prev_has_page_break) {
      div_open <- paste0(div_open, ' page-break="true"')
    }

    # Line numbers attribute
    if (brk$has_line_numbers) {
      ln_attr <- if (!is.null(brk$line_numbers_restart)) {
        switch(brk$line_numbers_restart,
          newSection = "section",
          newPage = "page",
          "continuous"
        )
      } else {
        "continuous"
      }
      div_open <- paste0(div_open, ' line-numbers="', ln_attr, '"')

      # Extended line number attributes (only when non-default)
      if (!is.null(brk$line_numbers_count_by) && brk$line_numbers_count_by != "1") {
        div_open <- paste0(div_open, ' line-numbers-count-by="',
                           brk$line_numbers_count_by, '"')
      }
      if (!is.null(brk$line_numbers_start)) {
        div_open <- paste0(div_open, ' line-numbers-start="',
                           brk$line_numbers_start, '"')
      }
      if (!is.null(brk$line_numbers_distance) && brk$line_numbers_distance != "360") {
        # Convert twips to inches for readability (1440 twips = 1 inch)
        dist_in <- as.numeric(brk$line_numbers_distance) / 1440
        div_open <- paste0(div_open, ' line-numbers-distance="',
                           format(dist_in, nsmall = 2), 'in"')
      }
    }

    # Footer attributes
    div_open <- paste0(div_open, footer_attrs, "}")

    ranges[[length(ranges) + 1]] <- list(
      name = paste0("section-", section_name),
      type = "native-section",
      start_idx = content_start,
      end_idx = content_end,
      div_open = div_open,
      div_close = ":::"
    )
  }

  ranges
}


#' Build footer div attributes from effective footer state
#'
#' Given the current effective default and first-page footer rIds, looks up their
#' parsed content and generates QMD div attribute strings.
#'
#' @param default_rid rId for the effective default footer (or NULL)
#' @param first_rid rId for the effective first-page footer (or NULL)
#' @param has_title_pg Whether this section has titlePg enabled
#' @param page_start Page number restart value (character) or NULL
#' @param footer_lookup Parsed footer lookup from get_footer_lookup()
#' @return String of div attributes (e.g., ' footer-right="{page}" page-start="1"')
#' @noRd
build_footer_div_attrs <- function(default_rid, first_rid, has_title_pg,
                                   page_start, footer_lookup) {
  if (is.null(footer_lookup)) return("")

  attrs <- ""

  # Default footer → footer-left, footer-center, footer-right
  if (!is.null(default_rid) && default_rid %in% names(footer_lookup)) {
    ftr <- footer_lookup[[default_rid]]
    if (isTRUE(ftr$empty)) {
      attrs <- paste0(attrs, ' footer="false"')
    } else if (!is.null(ftr)) {
      for (pos in c("left", "center", "right")) {
        if (!is.null(ftr[[pos]])) {
          attrs <- paste0(attrs, ' footer-', pos, '="', ftr[[pos]], '"')
        }
      }
    }
  }

  # First-page footer handling (only when titlePg is enabled)
  if (has_title_pg && !is.null(first_rid) && first_rid %in% names(footer_lookup)) {
    ftr <- footer_lookup[[first_rid]]
    if (isTRUE(ftr$empty)) {
      attrs <- paste0(attrs, ' footer-first="false"')
    } else if (!is.null(ftr)) {
      # First-page has content — emit as footer-first-left/center/right
      for (pos in c("left", "center", "right")) {
        if (!is.null(ftr[[pos]])) {
          attrs <- paste0(attrs, ' footer-first-', pos, '="', ftr[[pos]], '"')
        }
      }
    }
  }

  # Page number restart
  if (!is.null(page_start)) {
    attrs <- paste0(attrs, ' page-start="', page_start, '"')
  }

  attrs
}


#' Find which body child index contains a given node
#'
#' Walks up from the node to find its ancestor that is a direct child of body.
#' Returns the 1-based index in the children list, or NA.
#' @noRd
find_body_child_index <- function(node, body, children, n_children) {
  # Walk up the tree until we find a direct child of body
  current <- node
  for (j in seq_len(20)) {  # Safety limit
    parent <- xml2::xml_parent(current)
    if (length(parent) == 0) return(NA_integer_)
    if (identical(parent, body)) {
      # current is a direct child of body - find its index
      for (k in seq_len(n_children)) {
        if (identical(children[[k]], current)) return(k)
      }
      return(NA_integer_)
    }
    current <- parent
  }
  NA_integer_
}


#' Check if a child index falls within a bookmark range
#'
#' Returns NULL if not in any range, or a list with is_first, div_open,
#' div_close if inside a range.
#' @noRd
check_bookmark_range <- function(idx, bookmark_ranges) {
  # Returns the innermost (most nested) matching range for idx.
  # Ranges are ordered outermost-first (document order), so the last match wins.
  result <- NULL
  for (rng in bookmark_ranges) {
    if (idx >= rng$start_idx && idx <= rng$end_idx) {
      result <- list(
        is_first      = (idx == rng$start_idx),
        is_last       = (idx == rng$end_idx),
        type          = if (!is.null(rng$type)) rng$type else "div",
        div_open      = rng$div_open,
        div_close     = rng$div_close,
        id            = rng$id,
        docpr_id      = rng$docpr_id,
        original_path = rng$original_path
      )
    }
  }
  result
}


#' Parse version history table from bookmarked XML content
#'
#' Extracts version/description/date entries from a w:tbl inside the
#' _docstyle_version_history bookmark range. Returns a list of entries
#' suitable for YAML version-history metadata, or NULL if no table found.
#'
#' @param children XML node set (body children)
#' @param rng Bookmark range list with start_idx, end_idx
#' @param ns XML namespace
#' @return List of lists with version, description, date fields, or NULL
#' @noRd
parse_version_history_table <- function(children, rng, ns) {
  # Find the table within the bookmark range
  range_children <- children[rng$start_idx:rng$end_idx]
  tbl <- NULL
  for (child in range_children) {
    if (xml2::xml_name(child) == "tbl") {
      tbl <- child
      break
    }
  }
  if (is.null(tbl)) return(NULL)

  rows <- xml2::xml_find_all(tbl, ".//w:tr", ns)
  if (length(rows) < 2) return(NULL)  # Need header + at least one data row

  # Skip header row (first row), parse data rows
  entries <- list()
  for (i in seq(2, length(rows))) {
    cells <- xml2::xml_find_all(rows[[i]], ".//w:tc", ns)
    if (length(cells) < 3) next

    cell_text <- vapply(cells[1:3], function(cell) {
      text_nodes <- xml2::xml_find_all(cell, ".//w:t", ns)
      trimws(paste(xml2::xml_text(text_nodes), collapse = " "))
    }, character(1))

    # Only include rows that have at least some content
    if (all(cell_text == "")) next

    entries[[length(entries) + 1]] <- list(
      version = cell_text[1],
      description = cell_text[2],
      date = cell_text[3]
    )
  }

  if (length(entries) == 0) return(NULL)
  entries
}


#' Extract abstract prose from an abstract field-code range (#149)
#'
#' Collects the text of `Abstract`-styled paragraphs within an `abstract`
#' div field-code range (skipping the `AbstractTitle` heading paragraph and
#' the fldChar marker paragraphs), joined as paragraphs, for restoration to
#' `abstract:` YAML on harvest. Mirrors `parse_version_history_table()`: the
#' content is captured to metadata while the generic div handler emits only
#' the empty `:::docstyle-abstract:::` placeholder at the range position.
#'
#' @param children XML node set (body children)
#' @param rng Field-code range list with start_idx, end_idx
#' @param ns XML namespace
#' @return Single string (multi-paragraph joined with "\\n\\n"), or NULL if
#'   the range contains no `Abstract`-styled paragraphs.
#' @noRd
parse_abstract_range <- function(children, rng, ns) {
  idxs <- seq.int(rng$start_idx, rng$end_idx)
  texts <- character(0)
  for (i in idxs) {
    node <- children[[i]]
    if (is.na(xml2::xml_name(node)) || xml2::xml_name(node) != "p") next
    style <- xml2::xml_text(
      xml2::xml_find_first(node, "./w:pPr/w:pStyle/@w:val", ns))
    if (identical(style, "AbstractTitle")) next   # skip the title label
    if (!identical(style, "Abstract")) next        # only Abstract paras
    t_nodes <- xml2::xml_find_all(node, ".//w:t", ns)
    if (length(t_nodes) == 0L) next
    texts <- c(texts, paste(xml2::xml_text(t_nodes), collapse = ""))
  }
  if (length(texts) == 0L) return(NULL)
  paste(texts, collapse = "\n\n")
}


#' Update YAML header lines with harvested version history entries
#'
#' Replaces the version-history block in an existing YAML header with
#' entries parsed from the Word document's version history table.
#'
#' @param header_lines Character vector of YAML header lines (including --- delimiters)
#' @param entries List of version history entries from parse_version_history_table
#' @return Updated header_lines character vector
#' @noRd
update_yaml_version_history <- function(header_lines, entries) {
  if (is.null(entries) || length(entries) == 0) return(header_lines)

  # Find the version-history block in the header
  vh_start <- grep("^version-history:", header_lines)
  if (length(vh_start) == 0) {
    # No existing version-history block; insert before closing ---
    closing <- max(grep("^---$", header_lines))
    new_lines <- format_version_history_yaml(entries)
    return(c(
      header_lines[seq_len(closing - 1)],
      new_lines,
      header_lines[closing:length(header_lines)]
    ))
  }

  vh_start <- vh_start[1]

  # Find the end of the version-history block (next top-level key or ---)
  vh_end <- vh_start
  for (j in seq(vh_start + 1, length(header_lines))) {
    line <- header_lines[j]
    # Stop at next top-level key (no leading whitespace) or closing ---
    if (grepl("^[^ \\-]", line) || grepl("^---$", line)) break
    vh_end <- j
  }

  new_lines <- format_version_history_yaml(entries)
  c(
    header_lines[seq_len(vh_start - 1)],
    new_lines,
    header_lines[seq(vh_end + 1, length(header_lines))]
  )
}


#' Format version history entries as YAML lines
#' @noRd
format_version_history_yaml <- function(entries) {
  lines <- "version-history:"
  for (entry in entries) {
    lines <- c(lines, sprintf("  - version: \"%s\"", entry$version))
    lines <- c(lines, sprintf("    date: \"%s\"", entry$date))
    lines <- c(lines, sprintf("    description: \"%s\"", entry$description))
  }
  lines
}


#' Format harvested abstract prose as YAML literal-block lines (#149)
#'
#' Emits `abstract: |` followed by the prose indented two spaces. A literal
#' block scalar preserves multi-paragraph structure (blank lines between
#' paragraphs) without quoting/escaping, matching how authored protocol
#' QMDs write `abstract:`. The input is the `\\n\\n`-joined string from
#' `parse_abstract_range()`.
#'
#' @param prose Single string; paragraphs separated by "\\n\\n".
#' @return Character vector of YAML lines, or NULL if prose is empty.
#' @noRd
format_abstract_yaml <- function(prose) {
  if (is.null(prose) || !nzchar(prose)) return(NULL)
  # Split on any newline so each physical line is indented; blank lines
  # (from \n\n paragraph separators) are preserved as empty indented lines.
  body <- strsplit(prose, "\n", fixed = TRUE)[[1]]
  c("abstract: |", paste0("  ", body))
}


#' Update YAML header with harvested version-summary values
#'
#' Inserts or updates the version-summary block in a preserved YAML header.
#' Called when field codes contain version-summary.date or version-summary.version.
#'
#' @param header_lines Character vector of existing header lines
#' @param values Named list with date and/or version values
#' @return Updated header_lines character vector
#' @noRd
update_yaml_version_summary <- function(header_lines, values) {
  if (is.null(values) || length(values) == 0) return(header_lines)

  # Find the version-summary block in the header
  vs_start <- grep("^version-summary:", header_lines)
  if (length(vs_start) == 0) {
    # No existing version-summary block; insert before closing ---
    closing <- max(grep("^---$", header_lines))
    new_lines <- format_version_summary_yaml(values)
    return(c(
      header_lines[seq_len(closing - 1)],
      new_lines,
      header_lines[closing:length(header_lines)]
    ))
  }

  vs_start <- vs_start[1]

  # Find the end of the version-summary block (next top-level key or ---)
  vs_end <- vs_start
  for (j in seq(vs_start + 1, length(header_lines))) {
    line <- header_lines[j]
    # Stop at next top-level key (no leading whitespace) or closing ---
    if (grepl("^[^ ]", line) || grepl("^---$", line)) break
    vs_end <- j
  }

  new_lines <- format_version_summary_yaml(values)
  c(
    header_lines[seq_len(vs_start - 1)],
    new_lines,
    header_lines[seq(vs_end + 1, length(header_lines))]
  )
}


#' Format version summary as YAML lines
#' @noRd
format_version_summary_yaml <- function(values) {
  lines <- "version-summary:"
  if (!is.null(values$date)) {
    lines <- c(lines, sprintf("  date: \"%s\"", values$date))
  }
  if (!is.null(values$version)) {
    lines <- c(lines, sprintf("  version: \"%s\"", values$version))
  }
  lines
}


#' Warn about tracked changes or comments inside bookmark ranges
#'
#' Warn about annotations inside generated content ranges
#'
#' Scans each range (field code or bookmark) for w:ins, w:del, and
#' w:commentRangeStart nodes. Emits a warning for each range that contains
#' annotations, since these will be discarded when replaced by a div placeholder.
#' @noRd
warn_annotations_in_generated_content <- function(bookmark_ranges, children, ns) {
  for (rng in bookmark_ranges) {
    rev_count <- 0L
    comment_count <- 0L
    range_children <- children[rng$start_idx:rng$end_idx]
    for (child in range_children) {
      rev_count <- rev_count + length(xml2::xml_find_all(child, ".//w:ins|.//w:del", ns))
      comment_count <- comment_count + length(xml2::xml_find_all(child, ".//w:commentRangeStart", ns))
    }
    block_label <- sub("^_docstyle_", "", rng$name)
    if (rev_count > 0L) {
      warning(
        sprintf("Discarding %d tracked change(s) inside generated content block '%s'. ",
                rev_count, block_label),
        "Tracked changes in generated content are not preserved during harvest.",
        call. = FALSE
      )
    }
    if (comment_count > 0L) {
      warning(
        sprintf("Discarding %d comment(s) inside generated content block '%s'. ",
                comment_count, block_label),
        "Comments on generated content are not preserved during harvest.",
        call. = FALSE
      )
    }
  }
}


# --- Footer Harvest Functions ------------------------------------------------

#' Parse a single footer XML file into structured content
#'
#' Reads a footer XML node (`<w:ftr>`) and extracts text content and field codes
#' organized by position (left, center, right). Handles SDT-wrapped content
#' (Word's built-in page number insertion) and multi-position footers using tab stops.
#'
#' @param ftr_node An xml2 node for the `<w:ftr>` element, or a path to a footer XML file
#' @param ns Named character vector of XML namespaces (must include "w")
#' @return List with components `left`, `center`, `right` (each a string or NULL).
#'   Field codes are mapped to placeholders: PAGE -> \{page\}, NUMPAGES -> \{pages\},
#'   SECTIONPAGES -> \{sectionpages\}. Returns NULL if footer is empty.
#' @noRd
parse_footer_xml <- function(ftr_node, ns = NULL) {
  # Read from file path if string provided
  if (is.character(ftr_node)) {
    if (!file.exists(ftr_node)) return(NULL)
    ftr_node <- xml2::read_xml(ftr_node)
  }

  if (is.null(ns)) {
    ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
            r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships")
  }

  # Check for table-based footer layout (Pattern 5)
  # Word Online and some manual footers use a table with cells for positioning.
  # We extract text but warn that positions may not be accurate.
  tables <- xml2::xml_find_all(ftr_node, "./w:tbl", ns)
  if (length(tables) > 0) {
    return(parse_table_footer(tables[[1]], ns))
  }

  # Find content paragraphs. Three cases:
  # 1. SDT-wrapped (Word built-in): <w:sdt><w:sdtContent><w:p>...</w:p></w:sdtContent></w:sdt>
  # 2. Direct paragraphs: <w:p>...</w:p>
  # 3. Table-based: handled above
  #
  # We look inside SDT first, then fall back to direct paragraphs.
  sdt_content <- xml2::xml_find_all(ftr_node, ".//w:sdt/w:sdtContent", ns)
  if (length(sdt_content) > 0) {
    # SDT-wrapped: get paragraphs from inside sdtContent
    paragraphs <- xml2::xml_find_all(sdt_content[[1]], ".//w:p", ns)
  } else {
    # Direct paragraphs
    paragraphs <- xml2::xml_find_all(ftr_node, "./w:p", ns)
  }

  if (length(paragraphs) == 0) return(NULL)

  # Find the first paragraph with content (runs containing text or field codes)
  content_para <- NULL
  content_para_idx <- 0L
  for (i in seq_along(paragraphs)) {
    p <- paragraphs[[i]]
    runs <- xml2::xml_find_all(p, ".//w:r", ns)
    for (r in runs) {
      has_text <- length(xml2::xml_find_all(r, "w:t", ns)) > 0
      has_field <- length(xml2::xml_find_all(r, "w:fldChar", ns)) > 0
      has_instr <- length(xml2::xml_find_all(r, "w:instrText", ns)) > 0
      if (has_text || has_field || has_instr) {
        content_para <- p
        content_para_idx <- i
        break
      }
    }
    if (!is.null(content_para)) break
  }

  # No content paragraph found — empty footer
  if (is.null(content_para)) return(NULL)

  # Warn if multiple content paragraphs
  if (content_para_idx < length(paragraphs)) {
    for (j in (content_para_idx + 1L):length(paragraphs)) {
      p <- paragraphs[[j]]
      runs <- xml2::xml_find_all(p, ".//w:r", ns)
      has_any_content <- FALSE
      for (r in runs) {
        if (length(xml2::xml_find_all(r, "w:t", ns)) > 0 ||
            length(xml2::xml_find_all(r, "w:fldChar", ns)) > 0) {
          has_any_content <- TRUE
          break
        }
      }
      if (has_any_content) {
        warning("Footer has multiple content paragraphs; using first only.",
                call. = FALSE)
        break
      }
    }
  }

  # Detect position layout from the content paragraph
  layout <- detect_footer_layout(content_para, ns)

  # Extract runs into text segments, splitting at tabs for multi-position
  segments <- extract_footer_segments(content_para, ns)

  # Map segments to positions based on layout
  result <- assign_segments_to_positions(segments, layout)

  # Clean up: trim whitespace, convert empty strings to NULL
  for (pos in c("left", "center", "right")) {
    if (!is.null(result[[pos]])) {
      result[[pos]] <- trimws(result[[pos]])
      if (nchar(result[[pos]]) == 0) result[[pos]] <- NULL
    }
  }

  # Return NULL if all positions are empty
  if (is.null(result$left) && is.null(result$center) && is.null(result$right)) {
    return(NULL)
  }

  result
}


#' Detect footer paragraph layout (position detection algorithm)
#'
#' Determines how content is positioned in a footer paragraph:
#' - framePr with xAlign: single position
#' - tab stops: multi-position (left/center/right split at tabs)
#' - jc (justification): single position
#' - default: left
#'
#' @param para An xml2 paragraph node
#' @param ns Namespaces
#' @return List with `type` ("single" or "tabbed") and `position` (for single)
#'   or `tab_positions` (for tabbed)
#' @noRd
detect_footer_layout <- function(para, ns) {
  w_ns <- "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
  pPr <- xml2::xml_find_first(para, "w:pPr", ns)

  # 1. Check framePr (used by Word's built-in page numbers)
  if (!inherits(pPr, "xml_missing")) {
    framePr <- xml2::xml_find_first(pPr, "w:framePr", ns)
    if (!inherits(framePr, "xml_missing")) {
      xAlign <- xml2::xml_attr(framePr, paste0("{", w_ns, "}", "xAlign"))
      if (is.na(xAlign)) xAlign <- xml2::xml_attr(framePr, "xAlign")
      if (!is.na(xAlign)) {
        return(list(type = "single", position = tolower(xAlign)))
      }
    }
  }

  # 2. Check tab stops (multi-position)
  if (!inherits(pPr, "xml_missing")) {
    tabs <- xml2::xml_find_all(pPr, "w:tabs/w:tab", ns)
    if (length(tabs) > 0) {
      tab_info <- lapply(tabs, function(tab) {
        pos <- xml2::xml_attr(tab, paste0("{", w_ns, "}", "pos"))
        if (is.na(pos)) pos <- xml2::xml_attr(tab, "pos")
        val <- xml2::xml_attr(tab, paste0("{", w_ns, "}", "val"))
        if (is.na(val)) val <- xml2::xml_attr(tab, "val")
        list(pos = as.integer(pos), val = val)
      })
      return(list(type = "tabbed", tab_info = tab_info))
    }
  }

  # 3. Check for absolute position tabs (w:ptab) in run content
  # Word's "Blank (Three Columns)" built-in footer uses ptab elements
  # instead of tab stops in pPr. The alignment attribute is self-describing.
  ptabs <- xml2::xml_find_all(para, ".//w:r/w:ptab", ns)
  if (length(ptabs) > 0) {
    tab_info <- lapply(ptabs, function(ptab) {
      align <- xml2::xml_attr(ptab, paste0("{", w_ns, "}", "alignment"))
      if (is.na(align)) align <- xml2::xml_attr(ptab, "alignment")
      list(pos = NA_integer_, val = if (!is.na(align)) tolower(align) else "left")
    })
    return(list(type = "tabbed", tab_info = tab_info))
  }

  # 4. Check paragraph justification
  if (!inherits(pPr, "xml_missing")) {
    jc <- xml2::xml_find_first(pPr, "w:jc", ns)
    if (!inherits(jc, "xml_missing")) {
      val <- xml2::xml_attr(jc, paste0("{", w_ns, "}", "val"))
      if (is.na(val)) val <- xml2::xml_attr(jc, "val")
      if (!is.na(val)) {
        return(list(type = "single", position = tolower(val)))
      }
    }
  }

  # 5. Default: left
  list(type = "single", position = "left")
}


#' Extract footer content as text segments split at tab characters
#'
#' Walks runs in a footer paragraph, building text strings from static text
#' and field codes. Splits into a new segment at each `<w:tab/>` element.
#'
#' @param para An xml2 paragraph node
#' @param ns Namespaces
#' @return Character vector of segments (one per tab-separated section)
#' @noRd
extract_footer_segments <- function(para, ns) {
  runs <- xml2::xml_find_all(para, ".//w:r", ns)
  if (length(runs) == 0) return(character())

  segments <- character()
  current_segment <- ""

  # Field code state machine
  in_field <- FALSE
  field_instr <- ""
  skip_until_end <- FALSE

  for (r in runs) {
    children <- xml2::xml_children(r)

    for (child in children) {
      child_name <- xml2::xml_name(child)

      if (child_name == "tab" || child_name == "ptab") {
        # Tab separator — start new segment
        # Both regular tabs (w:tab) and absolute position tabs (w:ptab)
        # act as segment separators for multi-position footers
        segments <- c(segments, current_segment)
        current_segment <- ""
        next
      }

      if (child_name == "fldChar") {
        # xml2 attribute access: try bare name first (works when namespace
        # is on element), then prefixed, then Clark notation
        fld_type <- xml2::xml_attr(child, "fldCharType")
        if (is.na(fld_type)) {
          fld_type <- xml2::xml_attr(child, "w:fldCharType")
        }
        if (is.na(fld_type)) {
          w_ns <- "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
          fld_type <- xml2::xml_attr(child, paste0("{", w_ns, "}", "fldCharType"))
        }

        if (!is.na(fld_type)) {
          if (fld_type == "begin") {
            in_field <- TRUE
            field_instr <- ""
          } else if (fld_type == "separate") {
            # Field instruction is complete; convert to placeholder
            placeholder <- field_instr_to_placeholder(field_instr)
            current_segment <- paste0(current_segment, placeholder)
            skip_until_end <- TRUE
            in_field <- FALSE
          } else if (fld_type == "end") {
            skip_until_end <- FALSE
            in_field <- FALSE
            field_instr <- ""
          }
        }
        next
      }

      if (child_name == "instrText" && in_field) {
        field_instr <- paste0(field_instr, xml2::xml_text(child))
        next
      }

      # Skip cached display value between separate and end
      if (skip_until_end) next

      if (child_name == "t") {
        current_segment <- paste0(current_segment, xml2::xml_text(child))
      }
    }
  }

  # Don't forget the last segment
  segments <- c(segments, current_segment)
  segments
}


#' Convert a field instruction string to a docstyle placeholder
#'
#' Maps Word field codes to docstyle placeholders, stripping formatting switches.
#' @param instr The raw instrText content (e.g., " PAGE \\* MERGEFORMAT ")
#' @return Placeholder string (e.g., "\{page\}") or the raw instruction if unrecognized
#' @noRd
field_instr_to_placeholder <- function(instr) {
  # Strip leading/trailing whitespace and formatting switches
  clean <- trimws(instr)
  # Remove switches like \* MERGEFORMAT, \* Arabic, etc.
  clean <- sub("\\s+\\\\\\*.*$", "", clean)
  clean <- trimws(clean)

  switch(toupper(clean),
    "PAGE" = "{page}",
    "NUMPAGES" = "{pages}",
    "SECTIONPAGES" = "{sectionpages}",
    # Unrecognized: return as-is wrapped in braces
    paste0("{", clean, "}")
  )
}


#' Assign content segments to positions based on layout
#'
#' @param segments Character vector of content segments (split at tabs)
#' @param layout Layout info from detect_footer_layout()
#' @return List with left, center, right (each a string or NULL)
#' @noRd
assign_segments_to_positions <- function(segments, layout) {
  result <- list(left = NULL, center = NULL, right = NULL)

  if (length(segments) == 0) return(result)

  if (layout$type == "single") {
    # Single position: all content goes to the detected position
    content <- paste(segments, collapse = "")
    result[[layout$position]] <- content
    return(result)
  }

  # Tabbed layout: map segments to positions based on tab types
  # Common patterns:
  # - 2 tabs (center + right): segments[1]=left, segments[2]=center, segments[3]=right
  # - 1 tab (right only): segments[1]=left, segments[2]=right
  if (layout$type == "tabbed") {
    tab_types <- vapply(layout$tab_info, function(t) t$val %||% "left", character(1))

    # Assign first segment to left
    if (length(segments) >= 1) {
      result$left <- segments[1]
    }

    # Assign remaining segments based on tab types
    for (i in seq_along(tab_types)) {
      seg_idx <- i + 1L  # segments are offset by 1 from tabs
      if (seg_idx > length(segments)) break

      tab_type <- tolower(tab_types[i])
      if (tab_type == "center") {
        result$center <- segments[seg_idx]
      } else if (tab_type == "right") {
        result$right <- segments[seg_idx]
      }
    }
  }

  result
}


#' Parse a table-based footer (Pattern 5) with best-effort position mapping
#'
#' Extracts text from table cells and maps to left/center/right based on cell
#' count and alignment. Emits a warning since table layouts may not map cleanly.
#'
#' @param tbl An xml2 node for the w:tbl element
#' @param ns Namespaces
#' @return List with left, center, right (same as parse_footer_xml output),
#'   or NULL if table has no text content
#' @noRd
parse_table_footer <- function(tbl, ns) {
  rows <- xml2::xml_find_all(tbl, ".//w:tr", ns)
  if (length(rows) == 0) return(NULL)

  # Use first row (footer tables are typically single-row)
  cells <- xml2::xml_find_all(rows[[1]], ".//w:tc", ns)
  if (length(cells) == 0) return(NULL)

  # Extract text from each cell (including field codes)
  cell_texts <- vapply(cells, function(cell) {
    paras <- xml2::xml_find_all(cell, ".//w:p", ns)
    if (length(paras) == 0) return("")
    # Use extract_footer_segments on the first paragraph to get field codes
    segments <- extract_footer_segments(paras[[1]], ns)
    trimws(paste(segments, collapse = ""))
  }, character(1))

  # Filter out empty cells
  non_empty <- nchar(cell_texts) > 0

  if (!any(non_empty)) return(NULL)

  result <- list(left = NULL, center = NULL, right = NULL)

  # Best-effort position mapping based on cell count
  if (length(cells) == 3) {
    # Standard 3-column: left, center, right
    if (non_empty[1]) result$left <- cell_texts[1]
    if (non_empty[2]) result$center <- cell_texts[2]
    if (non_empty[3]) result$right <- cell_texts[3]
  } else if (length(cells) == 2) {
    if (non_empty[1]) result$left <- cell_texts[1]
    if (non_empty[2]) result$right <- cell_texts[2]
  } else {
    # Unknown cell count: concatenate all text as left
    all_text <- paste(cell_texts[non_empty], collapse = " ")
    result$left <- all_text
  }

  warning(
    "Footer uses table layout; positions are best-effort and may need manual adjustment.",
    call. = FALSE
  )

  result
}


#' Build footer lookup from docx relationship file
#'
#' Reads `word/_rels/document.xml.rels` to find all footer relationships,
#' then reads and parses each referenced footer XML file. Returns a named list
#' keyed by relationship ID (e.g., "rId7") where each value is the parsed
#' footer content from `parse_footer_xml()`.
#'
#' Even-page footer references (w:type="even") are logged as a warning
#' but included in the lookup for completeness.
#'
#' @param docx_path Path to the `.docx` file
#' @return Named list where names are relationship IDs and values are parsed
#'   footer content (list with left/center/right) or NULL for empty footers.
#'   Also includes an attribute "files" mapping rId to filename.
#' @noRd
get_footer_lookup <- function(docx_path) {
  with_docx_temp(docx_path, function(temp_dir) {
    rels_path <- file.path(temp_dir, "word", "_rels", "document.xml.rels")
    if (!file.exists(rels_path)) {
      return(list())
    }

    rels_xml <- xml2::read_xml(rels_path)

    # Find all footer relationships
    footer_rels <- xml2::xml_find_all(
      rels_xml,
      "//d1:Relationship[@Type='http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer']",
      xml2::xml_ns(rels_xml)
    )

    if (length(footer_rels) == 0) {
      return(list())
    }

    result <- list()
    file_map <- character()

    for (rel in footer_rels) {
      rel_id <- xml2::xml_attr(rel, "Id")
      target <- xml2::xml_attr(rel, "Target")
      if (is.na(rel_id) || is.na(target)) next

      file_map[rel_id] <- target

      # Read and parse the footer XML file
      footer_path <- file.path(temp_dir, "word", target)
      if (!file.exists(footer_path)) {
        warning("Footer file referenced but not found: ", target, call. = FALSE)
        result[[rel_id]] <- list(empty = TRUE)
        next
      }

      parsed <- parse_footer_xml(footer_path)
      # Use empty sentinel since assigning NULL removes the list entry in R
      result[[rel_id]] <- if (is.null(parsed)) list(empty = TRUE) else parsed
    }

    attr(result, "files") <- file_map
    result
  })
}
