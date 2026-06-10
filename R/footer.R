#' Footer and Header Infrastructure for Word Documents
#'
#' Functions for creating and injecting footer/header XML into Word documents.
#' Internally, footers and headers share identical XML structure differing only
#' in the wrapper tag (`w:ftr`/`w:hdr`), relationship type URI, and content
#' type string. The unified helpers below are parameterised by `hf_type`
#' ("footer" or "header") to avoid duplication.
#'
#' @name footer
#' @keywords internal
NULL


# ============================================================================
# OOXML constants keyed by "footer" / "header"
# ============================================================================

hf_wrapper_tag <- c(footer = "w:ftr", header = "w:hdr")

hf_rel_type <- c(
  footer = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer",
  header = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/header"
)

hf_content_type <- c(
  footer = "application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml",
  header = "application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"
)

hf_reference_element <- c(
  footer = "w:footerReference",
  header = "w:headerReference"
)


# ============================================================================
# Unified apply_hf — links an officer document to a footer or header
# ============================================================================

#' Apply Footer to Document
#'
#' Creates footer XML and links it to the document's sectPr.
#'
#' Supports two configuration formats:
#' - Single-content with `content` and optional `align`
#' - Multi-position with left/center/right keys
#' - Different first page via `first-page: false`
#'
#' @param doc officer document
#' @param footer_config Footer configuration list
#' @param css_styles Optional parsed CSS styles (from `read_css()`) for styling
#' @param tab_stops Optional list with `center` and `right` tab stop positions
#'   in twips. If NULL, uses defaults (4680/9360 for US Letter + 1" margins).
#' @return Modified document
#' @keywords internal
apply_footer <- function(doc, footer_config, css_styles = NULL,
                         tab_stops = NULL) {
  apply_hf(doc, footer_config, css_styles, hf_type = "footer",
           default_content = "Page {page}", tab_stops = tab_stops)
}


#' Apply Header to Document
#'
#' Creates header XML and links it to the document's sectPr.
#' Mirrors apply_footer() for headers.
#'
#' @param doc officer document
#' @param header_config Header configuration list
#' @param css_styles Optional parsed CSS styles
#' @param tab_stops Optional list with `center` and `right` tab stop positions
#' @return Modified document
#' @keywords internal
apply_header <- function(doc, header_config, css_styles = NULL,
                         tab_stops = NULL) {
  apply_hf(doc, header_config, css_styles, hf_type = "header",
           default_content = "", tab_stops = tab_stops)
}


#' Apply Footer or Header to Document
#'
#' Shared implementation for apply_footer() and apply_header().
#'
#' @param doc officer document
#' @param config Configuration list (footer or header)
#' @param css_styles Optional parsed CSS styles
#' @param hf_type "footer" or "header"
#' @param default_content Fallback content for legacy single-content format
#' @return Modified document
#' @keywords internal
apply_hf <- function(doc, config, css_styles, hf_type, default_content = "",
                     tab_stops = NULL) {
  first_page <- config$`first-page` %||% TRUE
  has_positions <- any(c("left", "center", "right") %in% names(config))

  if (has_positions) {
    hf_xml <- build_multi_position_hf_xml(config, css_styles, hf_type,
                                           tab_stops = tab_stops)
  } else {
    content <- config$content %||% default_content
    align <- config$align %||% "center"

    rPr_xml <- ""
    if (!is.null(config$style) && !is.null(css_styles)) {
      style_selector <- paste0(".", config$style)
      if (!is.null(css_styles[[style_selector]])) {
        rPr <- css_to_rPr(css_styles[[style_selector]])
        rPr_xml <- build_rPr_xml(rPr)
      }
    }

    hf_xml <- build_hf_xml(content, align, rPr_xml, hf_type)
  }

  pkg_dir <- doc$package_dir
  filename1 <- paste0(hf_type, "1.xml")
  writeLines(hf_xml, file.path(pkg_dir, "word", filename1))

  rid_default <- add_hf_relationship(doc, filename1, hf_type)

  if (!isTRUE(first_page)) {
    empty_xml <- build_hf_xml("", "center", "", hf_type)
    filename2 <- paste0(hf_type, "2.xml")
    writeLines(empty_xml, file.path(pkg_dir, "word", filename2))

    rid_first <- add_hf_relationship(doc, filename2, hf_type)

    add_hf_reference(doc, rid_default, type = "default", hf_type = hf_type)
    add_hf_reference(doc, rid_first, type = "first", hf_type = hf_type)
    add_title_page_setting(doc)

    add_hf_content_type(doc, filename1, hf_type)
    add_hf_content_type(doc, filename2, hf_type)
  } else {
    add_hf_reference(doc, rid_default, type = "default", hf_type = hf_type)
    add_hf_content_type(doc, filename1, hf_type)
  }

  doc
}


# ============================================================================
# Unified XML builders
# ============================================================================

#' Build Footer or Header XML (Single-Content)
#'
#' @param content Content string with placeholders
#' @param align Alignment (left, center, right)
#' @param rPr_xml Optional run properties XML string for styling
#' @param hf_type "footer" or "header"
#' @return Complete footer/header XML string
#' @keywords internal
build_hf_xml <- function(content, align, rPr_xml = "", hf_type = "footer") {
  jc_val <- switch(tolower(align),
    left = "left",
    right = "right",
    "center"
  )

  runs <- parse_footer_content(content, rPr_xml)
  runs_xml <- paste(runs, collapse = "")

  tag <- hf_wrapper_tag[[hf_type]]
  sprintf(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<%s xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
       xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <w:p>
    <w:pPr>
      <w:jc w:val="%s"/>
    </w:pPr>
    %s
  </w:p>
</%s>',
    tag, jc_val, runs_xml, tag
  )
}

#' Build Footer XML
#'
#' @param content Footer content string with placeholders
#' @param align Alignment (left, center, right)
#' @param rPr_xml Optional run properties XML string for styling
#' @return Complete footer XML string
#' @keywords internal
build_footer_xml <- function(content, align, rPr_xml = "") {
  build_hf_xml(content, align, rPr_xml, hf_type = "footer")
}

#' Build Header XML
#'
#' @param content Header content string with placeholders
#' @param align Alignment (left, center, right)
#' @param rPr_xml Optional run properties XML string for styling
#' @return Complete header XML string
#' @keywords internal
build_header_xml <- function(content, align, rPr_xml = "") {
  build_hf_xml(content, align, rPr_xml, hf_type = "header")
}


#' Build Multi-Position Footer or Header XML
#'
#' Creates footer/header with left/center/right positions using tab stops.
#' Word footers use tab stops at center and right margin for positioning.
#'
#' @param config Configuration with left/center/right keys
#' @param css_styles Optional parsed CSS styles
#' @param hf_type "footer" or "header"
#' @param tab_stops Optional list with `center` and `right` tab stop positions
#' @return Complete footer/header XML string
#' @keywords internal
build_multi_position_hf_xml <- function(config, css_styles = NULL,
                                        hf_type = "footer",
                                        tab_stops = NULL) {
  get_rPr_for_position <- function(pos_config, css_styles) {
    if (is.null(pos_config)) return("")

    if (is.character(pos_config)) {
      style_name <- config$style
    } else if (is.list(pos_config)) {
      style_name <- pos_config$style %||% config$style
    } else {
      return("")
    }

    if (!is.null(style_name) && !is.null(css_styles)) {
      style_selector <- paste0(".", style_name)
      if (!is.null(css_styles[[style_selector]])) {
        rPr <- css_to_rPr(css_styles[[style_selector]])
        return(build_rPr_xml(rPr))
      }
    }
    ""
  }

  get_content <- function(pos_config) {
    if (is.null(pos_config)) return("")
    if (is.character(pos_config)) return(pos_config)
    if (is.list(pos_config)) return(pos_config$content %||% "")
    ""
  }

  left_content <- get_content(config$left)
  center_content <- get_content(config$center)
  right_content <- get_content(config$right)

  left_rPr <- get_rPr_for_position(config$left, css_styles)
  center_rPr <- get_rPr_for_position(config$center, css_styles)
  right_rPr <- get_rPr_for_position(config$right, css_styles)

  runs_xml <- build_multi_position_runs(
    left_content, center_content, right_content,
    left_rPr, center_rPr, right_rPr
  )

  wrap_multi_position_xml(runs_xml, hf_type,
                          tab_stops$center %||% 4680L,
                          tab_stops$right %||% 9360L)
}

#' Build Multi-Position Footer XML
#'
#' @param footer_config Footer configuration with left/center/right keys
#' @param css_styles Optional parsed CSS styles
#' @return Complete footer XML string
#' @keywords internal
build_multi_position_footer_xml <- function(footer_config, css_styles = NULL) {
  build_multi_position_hf_xml(footer_config, css_styles, hf_type = "footer")
}

#' Build Multi-Position Header XML
#'
#' @param header_config Header configuration with left/center/right keys
#' @param css_styles Optional parsed CSS styles
#' @return Complete header XML string
#' @keywords internal
build_multi_position_header_xml <- function(header_config, css_styles = NULL) {
  build_multi_position_hf_xml(header_config, css_styles, hf_type = "header")
}


#' Build Multi-Position Runs XML
#'
#' Assembles left/center/right content into tab-separated runs.
#' Shared by both CSS-aware and raw multi-position builders.
#'
#' @param left_content Left position text
#' @param center_content Centre position text
#' @param right_content Right position text
#' @param left_rPr Run properties for left position
#' @param center_rPr Run properties for centre position
#' @param right_rPr Run properties for right position
#' @return Concatenated runs XML string
#' @keywords internal
build_multi_position_runs <- function(left_content, center_content, right_content,
                                      left_rPr = "", center_rPr = "",
                                      right_rPr = "") {
  runs <- character(0)

  if (nchar(left_content) > 0) {
    runs <- c(runs, parse_footer_content(left_content, left_rPr))
  }

  if (nchar(center_content) > 0 || nchar(right_content) > 0) {
    runs <- c(runs, "<w:r><w:tab/></w:r>")
  }

  if (nchar(center_content) > 0) {
    runs <- c(runs, parse_footer_content(center_content, center_rPr))
  }

  if (nchar(right_content) > 0) {
    runs <- c(runs, "<w:r><w:tab/></w:r>")
  }

  if (nchar(right_content) > 0) {
    runs <- c(runs, parse_footer_content(right_content, right_rPr))
  }

  paste(unlist(runs), collapse = "")
}


#' Compute Footer/Header Tab Stop Positions
#'
#' Computes center and right tab stop positions in twips based on the
#' page size and margins. Tab stops position the left/center/right content
#' in multi-position footers and headers.
#'
#' @param page_config Page configuration from page-config.json or CSS @page
#' @param section_class Optional section class name for per-section overrides
#' @return List with `center` and `right` tab stop positions in twips
#' @keywords internal
compute_hf_tab_stops <- function(page_config = NULL, section_class = NULL) {
  # Defaults: US Letter (8.5") with 1" margins = 6.5" usable = 9360 twips
  default_center <- 4680L
  default_right <- 9360L

  if (is.null(page_config)) {
    return(list(center = default_center, right = default_right))
  }

  # Get section-specific or default page properties
  props <- if (!is.null(section_class)) {
    get_section_page_props(section_class, page_config)
  } else {
    list(
      size = page_config$size %||% "letter",
      orientation = page_config$orientation %||% "portrait",
      margins = page_config$margins
    )
  }

  size <- props$size %||% "letter"
  orientation <- props$orientation %||% "portrait"
  dims <- get_page_dimensions(size, orientation)

  # Convert margins from CSS units to twips
  margins <- props$margins
  if (is.null(margins)) {
    return(list(center = default_center, right = default_right))
  }

  left_margin <- tryCatch(
    css_to_twips(margins$left %||% "1in"),
    error = function(e) {
      message("[compute-hf-tab-stops] Could not parse left margin '",
              margins$left, "': ", conditionMessage(e), ". Using 1in default.")
      1440L
    }
  )
  right_margin <- tryCatch(
    css_to_twips(margins$right %||% "1in"),
    error = function(e) {
      message("[compute-hf-tab-stops] Could not parse right margin '",
              margins$right, "': ", conditionMessage(e), ". Using 1in default.")
      1440L
    }
  )

  usable_width <- dims$width - left_margin - right_margin
  list(
    center = as.integer(round(usable_width / 2)),
    right = as.integer(usable_width)
  )
}


#' Wrap Multi-Position Runs in Footer/Header XML Envelope
#'
#' @param runs_xml Concatenated runs XML from build_multi_position_runs()
#' @param hf_type "footer" or "header"
#' @param tab_stop_center Center tab stop position in twips (default 4680)
#' @param tab_stop_right Right tab stop position in twips (default 9360)
#' @return Complete footer/header XML document string
#' @keywords internal
wrap_multi_position_xml <- function(runs_xml, hf_type,
                                    tab_stop_center = 4680L,
                                    tab_stop_right = 9360L) {
  tag <- hf_wrapper_tag[[hf_type]]
  sprintf(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<%s xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
       xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <w:p>
    <w:pPr>
      <w:tabs>
        <w:tab w:val="center" w:pos="%d"/>
        <w:tab w:val="right" w:pos="%d"/>
      </w:tabs>
    </w:pPr>
    %s
  </w:p>
</%s>',
    tag, tab_stop_center, tab_stop_right, runs_xml, tag
  )
}


# ============================================================================
# Content parsing and field code helpers (shared by footers and headers)
# ============================================================================

#' Parse Footer Content into Runs
#'
#' Converts content string with `\{page\}`, `\{pages\}` placeholders into Word runs.
#'
#' @param content Content string
#' @param rPr_xml Optional run properties XML string for styling
#' @return Vector of XML run strings
#' @keywords internal
parse_footer_content <- function(content, rPr_xml = "") {
  runs <- character(0)

  # Split by placeholders while keeping them
  # {page} -> PAGE, {pages} -> NUMPAGES (total doc),
  # {sectionpages} or {section-pages} -> SECTIONPAGES
  placeholder_re <- "(\\{page\\}|\\{section-?pages\\}|\\{pages\\})"
  parts <- strsplit(content, placeholder_re, perl = TRUE)[[1]]
  placeholders <- regmatches(content, gregexpr(placeholder_re, content))[[1]]

  for (i in seq_along(parts)) {
    # Add text part
    if (nchar(parts[i]) > 0) {
      if (nchar(rPr_xml) > 0) {
        runs <- c(runs, sprintf('<w:r>%s<w:t xml:space="preserve">%s</w:t></w:r>',
                                rPr_xml, xml_escape(parts[i])))
      } else {
        runs <- c(runs, sprintf('<w:r><w:t xml:space="preserve">%s</w:t></w:r>',
                                xml_escape(parts[i])))
      }
    }

    # Add placeholder field if there's one after this part
    if (i <= length(placeholders)) {
      field_code <- switch(placeholders[i],
        "{page}" = "PAGE",
        "{sectionpages}" = "SECTIONPAGES",
        "{section-pages}" = "SECTIONPAGES",
        "NUMPAGES"  # default for {pages}
      )
      runs <- c(runs, build_field_code_run(field_code, rPr_xml))
    }
  }

  runs
}


#' Build Field Code Run
#'
#' Creates the XML for a Word field code (PAGE, NUMPAGES, etc.)
#' Includes `<w:noProof/>` to preserve formatting when Word updates field values.
#' The cached display value is set to "#" (not a real number) so that stale
#' values are visually obvious if updateFields fails to trigger. Word replaces
#' this with the computed value when fields are updated on open.
#'
#' @param field_code The field code (e.g., "PAGE")
#' @param rPr_xml Optional run properties XML string for styling
#' @return XML string for the field
#' @keywords internal
build_field_code_run <- function(field_code, rPr_xml = "") {
  # Add noProof to rPr to preserve formatting when field is updated
  if (nchar(rPr_xml) > 0) {
    # Insert noProof into existing rPr (before closing </w:rPr>)
    rPr_with_noProof <- sub("</w:rPr>", "<w:noProof/></w:rPr>", rPr_xml)
    sprintf(
      '<w:r>%s<w:fldChar w:fldCharType="begin"/></w:r>
       <w:r>%s<w:instrText> %s </w:instrText></w:r>
       <w:r>%s<w:fldChar w:fldCharType="separate"/></w:r>
       <w:r>%s<w:t>#</w:t></w:r>
       <w:r>%s<w:fldChar w:fldCharType="end"/></w:r>',
      rPr_with_noProof, rPr_xml, field_code, rPr_with_noProof, rPr_with_noProof, rPr_with_noProof
    )
  } else {
    # Minimal rPr with just noProof
    sprintf(
      '<w:r><w:rPr><w:noProof/></w:rPr><w:fldChar w:fldCharType="begin"/></w:r>
       <w:r><w:instrText> %s </w:instrText></w:r>
       <w:r><w:rPr><w:noProof/></w:rPr><w:fldChar w:fldCharType="separate"/></w:r>
       <w:r><w:rPr><w:noProof/></w:rPr><w:t>#</w:t></w:r>
       <w:r><w:rPr><w:noProof/></w:rPr><w:fldChar w:fldCharType="end"/></w:r>',
      field_code
    )
  }
}


# ============================================================================
# Officer integration helpers (pre-render: relationship, reference, content type)
# ============================================================================

#' Add Footer or Header Relationship
#'
#' Adds a relationship to officer's internal relationship object.
#'
#' @param doc officer document
#' @param target Filename (e.g., "footer1.xml", "header1.xml")
#' @param hf_type "footer" or "header"
#' @return The relationship ID (e.g., "rId31")
#' @keywords internal
add_hf_relationship <- function(doc, target, hf_type) {
  rels <- doc$doc_obj$relationship()
  next_id <- rels$get_next_id()
  rid <- paste0("rId", next_id)
  rels$add(id = rid, type = hf_rel_type[[hf_type]], target = target)
  rid
}

#' @keywords internal
add_footer_relationship <- function(doc, target = "footer1.xml") {
  add_hf_relationship(doc, target, "footer")
}

#' @keywords internal
add_header_relationship <- function(doc, target = "header1.xml") {
  add_hf_relationship(doc, target, "header")
}


#' Add Footer or Header Reference to sectPr
#'
#' @param doc officer document
#' @param rid The relationship ID
#' @param type "default", "first", or "even"
#' @param hf_type "footer" or "header"
#' @keywords internal
add_hf_reference <- function(doc, rid, type = "default", hf_type = "footer") {
  xml <- doc$doc_obj$get()
  ns <- c(
    w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
    r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  )

  sectPr <- xml2::xml_find_first(xml, "//w:body/w:sectPr", ns = ns)

  ref_elem <- hf_reference_element[[hf_type]]
  xpath <- sprintf("%s[@w:type='%s']", ref_elem, type)
  existing <- xml2::xml_find_first(sectPr, xpath, ns = ns)

  if (inherits(existing, "xml_missing")) {
    ref <- xml2::xml_add_child(sectPr, ref_elem, .where = 0)
    xml2::xml_set_attr(ref, "w:type", type)
    xml2::xml_set_attr(ref, "r:id", rid)
  }
}

#' @keywords internal
add_footer_reference <- function(doc, rid, type = "default") {
  add_hf_reference(doc, rid, type, hf_type = "footer")
}

#' @keywords internal
add_header_reference <- function(doc, rid, type = "default") {
  add_hf_reference(doc, rid, type, hf_type = "header")
}


#' Add Footer or Header Content Type
#'
#' @param doc officer document
#' @param filename Filename (e.g., "footer1.xml", "header1.xml")
#' @param hf_type "footer" or "header"
#' @keywords internal
add_hf_content_type <- function(doc, filename, hf_type) {
  part_name <- paste0("/word/", filename)
  doc$content_type$add_override(
    stats::setNames(hf_content_type[[hf_type]], part_name)
  )
}

#' @keywords internal
add_footer_content_type <- function(doc, filename = "footer1.xml") {
  add_hf_content_type(doc, filename, "footer")
}

#' @keywords internal
add_header_content_type <- function(doc, filename = "header1.xml") {
  add_hf_content_type(doc, filename, "header")
}


#' Add Title Page Setting
#'
#' Adds `<w:titlePg/>` element to sectPr to enable different first page
#' headers/footers.
#'
#' @param doc officer document
#' @keywords internal
add_title_page_setting <- function(doc) {
  xml <- doc$doc_obj$get()
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  sectPr <- xml2::xml_find_first(xml, "//w:body/w:sectPr", ns = ns)

  existing <- xml2::xml_find_first(sectPr, "w:titlePg", ns = ns)

  if (inherits(existing, "xml_missing")) {
    xml2::xml_add_child(sectPr, "w:titlePg")
  }
}


# ============================================================================
# Raw-XML write helpers for the post-render finisher
# These operate on the unzipped DOCX directory, not officer R6 objects.
# Used by inject_section_headers_footers() in section_headers.R.
# ============================================================================

#' Write Footer or Header XML to Unzipped DOCX
#'
#' Writes the XML file, adds a relationship in document.xml.rels,
#' and adds a content type override. Returns the rId.
#'
#' @param temp_dir Path to unzipped DOCX directory
#' @param xml_content Complete footer/header XML string
#' @param filename Filename (e.g., "footer3.xml", "header3.xml")
#' @param hf_type "footer" or "header"
#' @return The relationship ID (e.g., "rId15")
#' @keywords internal
write_hf_to_docx <- function(temp_dir, xml_content, filename, hf_type) {
  writeLines(xml_content, file.path(temp_dir, "word", filename))

  rid <- add_raw_relationship(temp_dir, filename, hf_rel_type[[hf_type]])
  add_raw_content_type(temp_dir, paste0("/word/", filename),
                       hf_content_type[[hf_type]])
  rid
}

#' @keywords internal
write_footer_to_docx <- function(temp_dir, footer_xml, filename) {
  write_hf_to_docx(temp_dir, footer_xml, filename, "footer")
}

#' @keywords internal
write_header_to_docx <- function(temp_dir, header_xml, filename) {
  write_hf_to_docx(temp_dir, header_xml, filename, "header")
}


#' Add Relationship to document.xml.rels
#'
#' Scans for the next available rId and adds a Relationship element.
#'
#' @param temp_dir Path to unzipped DOCX directory
#' @param target Target filename (e.g., "footer3.xml")
#' @param type Relationship type URI
#' @return The relationship ID (e.g., "rId15")
#' @keywords internal
add_raw_relationship <- function(temp_dir, target, type) {
  rels_path <- file.path(temp_dir, "word", "_rels", "document.xml.rels")
  rels_xml <- xml2::read_xml(rels_path)

  # Find max existing rId
  rels <- xml2::xml_find_all(rels_xml, ".//d1:Relationship",
    ns = c(d1 = "http://schemas.openxmlformats.org/package/2006/relationships"))

  max_id <- 0L
  for (rel in rels) {
    id_str <- xml2::xml_attr(rel, "Id")
    id_num <- as.integer(sub("rId", "", id_str))
    if (!is.na(id_num) && id_num > max_id) max_id <- id_num
  }

  new_id <- paste0("rId", max_id + 1L)

  new_rel <- xml2::xml_add_child(rels_xml, "Relationship")
  xml2::xml_set_attr(new_rel, "Id", new_id)
  xml2::xml_set_attr(new_rel, "Type", type)
  xml2::xml_set_attr(new_rel, "Target", target)

  xml2::write_xml(rels_xml, rels_path)
  new_id
}


#' Add Content Type Override
#'
#' Adds an Override element to ``[Content_Types].xml`` if not already present.
#'
#' @param temp_dir Path to unzipped DOCX directory
#' @param part_name Part name (e.g., "/word/footer3.xml")
#' @param content_type Content type string
#' @keywords internal
add_raw_content_type <- function(temp_dir, part_name, content_type) {
  ct_path <- file.path(temp_dir, "[Content_Types].xml")
  ct_xml <- xml2::read_xml(ct_path)

  ct_ns <- c(ct = "http://schemas.openxmlformats.org/package/2006/content-types")

  xpath <- sprintf(".//ct:Override[@PartName='%s']", part_name)
  existing <- xml2::xml_find_first(ct_xml, xpath, ns = ct_ns)

  if (inherits(existing, "xml_missing")) {
    new_override <- xml2::xml_add_child(ct_xml, "Override")
    xml2::xml_set_attr(new_override, "PartName", part_name)
    xml2::xml_set_attr(new_override, "ContentType", content_type)
    xml2::write_xml(ct_xml, ct_path)
  }
}
