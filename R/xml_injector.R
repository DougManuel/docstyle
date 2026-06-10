#' Get Styles XML from Docx
#'
#' Accesses the internal `word/styles.xml` of an `officer` document object.
#'
#' @param doc An `officer::read_docx` object.
#' @return An `xml2` document object representing the styles.
#' @keywords internal
#' @export
get_styles_xml <- function(doc) {
  path <- file.path(doc$package_dir, "word/styles.xml")
  if (!file.exists(path)) {
    stop("styles.xml not found in document package directory.")
  }
  xml2::read_xml(path)
}

#' Write Styles XML to Docx
#'
#' Writes the modified styles XML back to the `officer` document object's temp directory.
#'
#' @param doc An `officer::read_docx` object.
#' @param xml An `xml2` document object to write.
#' @keywords internal
#' @export
write_styles_xml <- function(doc, xml) {
  path <- file.path(doc$package_dir, "word/styles.xml")
  xml2::write_xml(xml, path)
}

#' Create Style Node
#'
#' Constructs a `<w:style>` XML node from a list of properties.
#'
#' @param style_props A list containing style definition:
#'   \itemize{
#'     \item \code{id}: Style ID (required)
#'     \item \code{name}: Style Name (required)
#'     \item \code{type}: Style type (default: "paragraph")
#'     \item \code{based_on}: ID of parent style (optional)
#'     \item \code{next_style}: ID of next style (optional)
#'     \item \code{pPr}: List of paragraph properties (optional)
#'     \item \code{rPr}: List of run/character properties (optional)
#'   }
#' @return An `xml_node` object.
#' @keywords internal
#' @export
create_style_node <- function(style_props) {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  
  style_node <- xml2::xml_new_root("w:style", 
                                   "w:type" = ifelse(is.null(style_props$type), "paragraph", style_props$type),
                                   "w:styleId" = style_props$id,
                                   "xmlns:w" = ns["w"])
  
  # Basic Metadata
  xml2::xml_add_child(style_node, "w:name", "w:val" = style_props$name)
  
  if (!is.null(style_props$based_on)) {
    xml2::xml_add_child(style_node, "w:basedOn", "w:val" = style_props$based_on)
  }
  
  if (!is.null(style_props$next_style)) {
    xml2::xml_add_child(style_node, "w:next", "w:val" = style_props$next_style)
  }
  
  # Paragraph Properties (pPr)
  if (!is.null(style_props$pPr) && length(style_props$pPr) > 0) {
    pPr_node <- xml2::xml_add_child(style_node, "w:pPr")
    
    for (prop_name in names(style_props$pPr)) {
      prop_val <- style_props$pPr[[prop_name]]
      
      # Handle nested properties (like spacing, ind, borders)
      if (is.list(prop_val)) {
        child <- xml2::xml_add_child(pPr_node, paste0("w:", prop_name))
        for (attr_name in names(prop_val)) {
          xml2::xml_set_attr(child, paste0("w:", attr_name), prop_val[[attr_name]])
        }
      } else {
        # Simple property
        # e.g. w:jc w:val="center"
        xml2::xml_add_child(pPr_node, paste0("w:", prop_name), "w:val" = prop_val)
      }
    }
  }
  
  # Run Properties (rPr)
  if (!is.null(style_props$rPr) && length(style_props$rPr) > 0) {
    rPr_node <- xml2::xml_add_child(style_node, "w:rPr")
    
    for (prop_name in names(style_props$rPr)) {
      prop_val <- style_props$rPr[[prop_name]]
      
      if (is.list(prop_val)) {
        child <- xml2::xml_add_child(rPr_node, paste0("w:", prop_name))
        for (attr_name in names(prop_val)) {
          xml2::xml_set_attr(child, paste0("w:", attr_name), prop_val[[attr_name]])
        }
      } else {
        xml2::xml_add_child(rPr_node, paste0("w:", prop_name), "w:val" = prop_val)
      }
    }
  }
  
  return(style_node)
}

#' Inject Style into XML
#'
#' Adds or updates a style node in the styles XML document.
#'
#' @param styles_xml The xml document (from `get_styles_xml`).
#' @param style_node The new style node (from `create_style_node`).
#' @keywords internal
#' @export
inject_style_node <- function(styles_xml, style_node) {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  
  style_id <- xml2::xml_attr(style_node, "w:styleId")
  if (is.na(style_id)) style_id <- xml2::xml_attr(style_node, "styleId")
  
  if (is.na(style_id)) {
    warning("Could not determine styleId from node. Skipping injection.")
    return(invisible(styles_xml))
  }
  
  # Check if style exists
  # xpath: //w:style[@w:styleId='Heading1']
  xpath <- sprintf("//w:style[@w:styleId='%s']", style_id)
  existing <- xml2::xml_find_first(styles_xml, xpath, ns = ns)
  
  if (!inherits(existing, "xml_missing")) {
    # Replace
    xml2::xml_replace(existing, style_node)
  } else {
    # Append to <w:styles> root
    xml2::xml_add_child(styles_xml, style_node)
  }
  
  return(invisible(styles_xml))
}
