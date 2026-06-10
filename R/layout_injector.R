#' Apply Page Layout to Document
#'
#' Applies margins, header/footer geometry, and static content to an Officer document
#' via direct XML injection into `word/document.xml`.
#'
#' @param doc An `officer::read_docx` object.
#' @param layout A resolved page layout list.
#' @param config Global configuration (for asset lookup).
#' @return Modified doc object.
#' @keywords internal
#' @export
apply_page_layout <- function(doc, layout, config) {
  # Access the internal XML document from officer
  # This ensures we modify the in-memory representation that officer will write on print()
  xml <- doc$doc_obj$get()
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  
  # Find Body
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  
  # Find Final Section Properties (last child of body)
  sectPr <- xml2::xml_find_first(body, "w:sectPr", ns = ns)
  if (inherits(sectPr, "xml_missing")) {
    # Should generally exist, but if not, add it
    sectPr <- xml2::xml_add_child(body, "w:sectPr")
  }
  
  # 1. Set Margins (w:pgMar)
  if (!is.null(layout$margins)) {
    pgMar <- xml2::xml_find_first(sectPr, "w:pgMar", ns = ns)
    if (inherits(pgMar, "xml_missing")) {
      pgMar <- xml2::xml_add_child(sectPr, "w:pgMar")
    }
    
    # Convert to Twips
    top <- css_to_twips(layout$margins$top)
    bottom <- css_to_twips(layout$margins$bottom)
    left <- css_to_twips(layout$margins$left)
    right <- css_to_twips(layout$margins$right)
    gutter <- if(!is.null(layout$margins$gutter)) css_to_twips(layout$margins$gutter) else 0
    header_dist <- css_to_twips(layout$header$height %||% "0.5in")
    footer_dist <- css_to_twips(layout$footer$height %||% "0.5in")
    
    xml2::xml_set_attr(pgMar, "w:top", top)
    xml2::xml_set_attr(pgMar, "w:bottom", bottom)
    xml2::xml_set_attr(pgMar, "w:left", left)
    xml2::xml_set_attr(pgMar, "w:right", right)
    xml2::xml_set_attr(pgMar, "w:gutter", gutter)
    xml2::xml_set_attr(pgMar, "w:header", header_dist)
    xml2::xml_set_attr(pgMar, "w:footer", footer_dist)
  }
  
  # 2. Page Size (w:pgSz) - Optional, default Letter/A4
  # If we wanted to control orientation, we'd do it here.
  
  # No need to write_xml explicitly, as we modified the pointer held by doc$doc_obj
  
  return(doc)
}

#' CSS to Inches
#'
#' @param val_str CSS string (e.g. "1in").
#' @return Numeric inches.
#' @keywords internal
css_to_inches <- function(val_str) {
  if (is.null(val_str)) return(0)
  pts <- parse_css_unit(val_str)
  return(pts / 72)
}
