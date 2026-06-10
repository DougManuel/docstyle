# =============================================================================
# STYLE MAP — build Pandoc ID -> template style ID mapping
# =============================================================================
#
# When a third-party template uses non-standard style IDs (e.g., MDPI, journal,
# institutional), Pandoc outputs its canonical IDs (Heading1, BodyText, etc.)
# which don't match the template. The style map enables post-render rewriting
# of Pandoc's IDs to the template's native ones.
#
# Resolution order (similar to style_resolver.R, but inverted direction and
# separated into distinct passes rather than a single combined loop):
#   1. Direct match (styleId == Pandoc target) -> skip (identity, no mapping)
#   2. outlineLvl 0-5 on the style itself -> Heading1-6
#      (levels 6-8 are body-outline, NOT headings)
#   3. basedOn chain walk: find the Pandoc target this style descends from
#      (also checks outlineLvl at each chain step)
#   4. Display name pattern: case-insensitive match against Pandoc display names
#
# Output: named list where names are Pandoc IDs, values are template IDs
# Only non-identity mappings are included.
# =============================================================================


# Pandoc paragraph style IDs that we try to map. Character and table styles are
# not mapped — the style swap operates on paragraph-level IDs only.
.PANDOC_STYLE_IDS <- c(
  paste0("Heading", 1:9),
  "Normal", "BodyText", "FirstParagraph", "Compact", "BlockText",
  "Title", "Subtitle", "Author", "Date",
  "Abstract", "AbstractTitle",
  "Caption", "TableCaption", "ImageCaption", "Figure", "CaptionedFigure",
  "Bibliography", "FootnoteText",
  "DefinitionTerm", "Definition",
  "TOCHeading"
)


# Map from Pandoc style IDs to their canonical display names (used for
# name-pattern fallback). Case-insensitive matching is applied.
.PANDOC_DISPLAY_NAMES <- list(
  Heading1        = "heading 1",
  Heading2        = "heading 2",
  Heading3        = "heading 3",
  Heading4        = "heading 4",
  Heading5        = "heading 5",
  Heading6        = "heading 6",
  Heading7        = "heading 7",
  Heading8        = "heading 8",
  Heading9        = "heading 9",
  Normal          = "normal",
  BodyText        = "body text",
  FirstParagraph  = "first paragraph",
  Compact         = "compact",
  BlockText       = "block text",
  Title           = "title",
  Subtitle        = "subtitle",
  Author          = "author",
  Date            = "date",
  Abstract        = "abstract",
  AbstractTitle   = "abstract title",
  Caption         = "caption",
  TableCaption    = "table caption",
  ImageCaption    = "image caption",
  Figure          = "figure",
  CaptionedFigure = "captioned figure",
  Bibliography    = "bibliography",
  FootnoteText    = "footnote text",
  DefinitionTerm  = "definition term",
  Definition      = "definition",
  TOCHeading      = "toc heading"
)


#' Build a Style Map from styles.xml Content
#'
#' Scans a Word template's styles.xml and builds a mapping from Pandoc's
#' expected style IDs to the template's native style IDs. Uses similar
#' resolution logic to `style_resolver.R` but in the opposite direction:
#' given a template style, determines which Pandoc target it replaces.
#'
#' Resolution order: (1) direct match (identity, skipped), (2) outlineLvl
#' for headings 1-6, (3) basedOn chain walk, (4) display name pattern match.
#' Only non-identity mappings appear in the output.
#'
#' @param styles_xml_str Character string of styles.xml content, or an xml2
#'   document object.
#' @return Named list where names are Pandoc style IDs and values are the
#'   template's native style IDs. Empty list if all styles use standard names.
#' @keywords internal
#' @export
build_style_map_from_xml <- function(styles_xml_str) {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  if (inherits(styles_xml_str, "xml_document") ||
      inherits(styles_xml_str, "xml_node")) {
    doc <- styles_xml_str
  } else {
    doc <- xml2::read_xml(styles_xml_str)
  }

  style_nodes <- xml2::xml_find_all(doc, "/w:styles/w:style", ns)

  # Build lookup: style_id -> list(name, based_on, outline_level, type)
  lookup <- list()
  for (node in style_nodes) {
    style_id <- xml2::xml_attr(node, "styleId")
    if (is.na(style_id)) next

    style_type <- xml2::xml_attr(node, "type")
    if (is.na(style_type)) style_type <- "paragraph"

    name_node <- xml2::xml_find_first(node, "w:name/@w:val", ns)
    name <- if (!inherits(name_node, "xml_missing")) {
      xml2::xml_text(name_node)
    } else {
      style_id
    }

    based_on_node <- xml2::xml_find_first(node, "w:basedOn/@w:val", ns)
    based_on <- if (!inherits(based_on_node, "xml_missing")) {
      xml2::xml_text(based_on_node)
    } else {
      NULL
    }

    outline_level <- .parse_outline_level_node(node, ns)

    lookup[[style_id]] <- list(
      name          = name,
      based_on      = based_on,
      outline_level = outline_level,
      type          = style_type
    )
  }

  # Build the map: Pandoc ID -> template ID
  style_map <- list()
  all_style_ids <- names(lookup)

  for (style_id in all_style_ids) {
    props <- lookup[[style_id]]

    # Skip character/table styles for paragraph-level mapping
    if (props$type != "paragraph") next

    # Skip if this IS a Pandoc standard ID (identity mapping)
    if (style_id %in% .PANDOC_STYLE_IDS) next

    # Resolution 1: outlineLvl (0-5 only)
    pandoc_target <- NULL
    ol <- props$outline_level
    if (!is.na(ol) && ol >= 0L && ol <= 5L) {
      pandoc_target <- paste0("Heading", ol + 1L)
    }

    # Resolution 2: basedOn chain walk
    if (is.null(pandoc_target)) {
      pandoc_target <- .resolve_based_on_chain(style_id, lookup)
    }

    # Resolution 3: display name pattern match
    if (is.null(pandoc_target)) {
      pandoc_target <- .resolve_display_name(style_id, lookup)
    }

    # Record non-identity mapping (first match wins for each Pandoc target)
    if (!is.null(pandoc_target) && is.null(style_map[[pandoc_target]])) {
      style_map[[pandoc_target]] <- style_id
    }
  }

  style_map
}


#' Parse outlineLvl from a style node
#'
#' @param node xml2 style node
#' @param ns XML namespace vector
#' @return Integer 0-8, or NA_integer_ if absent
#' @noRd
.parse_outline_level_node <- function(node, ns) {
  outline_node <- xml2::xml_find_first(node, "w:pPr/w:outlineLvl/@w:val", ns)
  if (inherits(outline_node, "xml_missing")) return(NA_integer_)

  raw_val <- xml2::xml_text(outline_node)
  if (grepl("^[0-9]+$", raw_val)) {
    as.integer(raw_val)
  } else {
    NA_integer_
  }
}


#' Walk basedOn chain to find a Pandoc target
#'
#' @param style_id Starting style ID
#' @param lookup Named list of style properties
#' @return Pandoc target ID, or NULL if not resolved
#' @noRd
.resolve_based_on_chain <- function(style_id, lookup) {
  seen <- style_id
  current_id <- lookup[[style_id]]$based_on

  while (!is.null(current_id) && nchar(current_id) > 0L &&
         !(current_id %in% seen)) {
    seen <- c(seen, current_id)

    # Reached a Pandoc standard style through the chain
    if (current_id %in% .PANDOC_STYLE_IDS) return(current_id)

    props <- lookup[[current_id]]
    if (is.null(props)) break

    # Check outlineLvl at this step
    ol <- props$outline_level
    if (!is.na(ol) && ol >= 0L && ol <= 5L) {
      return(paste0("Heading", ol + 1L))
    }

    current_id <- props$based_on
  }

  NULL
}


#' Match display name against Pandoc display names
#'
#' @param style_id Style ID to check
#' @param lookup Named list of style properties
#' @return Pandoc target ID, or NULL if no match
#' @noRd
.resolve_display_name <- function(style_id, lookup) {
  props <- lookup[[style_id]]
  if (is.null(props) || is.null(props$name)) return(NULL)

  name_lower <- tolower(props$name)

  for (pandoc_id in names(.PANDOC_DISPLAY_NAMES)) {
    if (name_lower == .PANDOC_DISPLAY_NAMES[[pandoc_id]]) {
      return(pandoc_id)
    }
  }

  NULL
}


#' Build a Style Map from a Template DOCX File
#'
#' File-based wrapper around `build_style_map_from_xml()`. Extracts
#' `word/styles.xml` from the template, builds the Pandoc-to-template
#' style mapping, and optionally writes it to `style-map.json`.
#'
#' @param template_path Path to the template .docx file.
#' @param sidecar_dir Optional path to the sidecar directory (e.g.,
#'   `_docstyle/`). If provided, writes `style-map.json` there.
#' @return Named list mapping Pandoc IDs to template style IDs.
#' @keywords internal
#' @export
build_style_map <- function(template_path, sidecar_dir = NULL) {
  if (!file.exists(template_path)) {
    stop("[style-map] Template not found: ", template_path)
  }

  style_map <- with_docx_temp(template_path, function(temp_dir) {
    styles_path <- file.path(temp_dir, "word", "styles.xml")
    if (!file.exists(styles_path)) {
      message("[style-map] No word/styles.xml in template; returning empty map")
      return(list())
    }

    styles_xml <- xml2::read_xml(styles_path)
    build_style_map_from_xml(styles_xml)
  }, files = c("word/styles.xml"))

  if (length(style_map) > 0L) {
    message("[style-map] ", length(style_map), " non-identity mapping(s) found")
    for (pandoc_id in names(style_map)) {
      message("[style-map]   ", pandoc_id, " -> ", style_map[[pandoc_id]])
    }
  } else {
    message("[style-map] Template uses standard Pandoc style IDs")
  }

  if (!is.null(sidecar_dir)) {
    if (!dir.exists(sidecar_dir)) {
      dir.create(sidecar_dir, recursive = TRUE)
    }
    json_path <- file.path(sidecar_dir, "style-map.json")
    jsonlite::write_json(style_map, json_path, auto_unbox = TRUE, pretty = TRUE)
    message("[style-map] Wrote ", json_path)
  }

  style_map
}


#' Get All Style IDs from a Template
#'
#' Returns a character vector of every `styleId` defined in the template's
#' `word/styles.xml`. Used downstream for cascade-skip decisions (styles
#' explicitly defined in the template should not be overwritten).
#'
#' @param template_path Path to the template .docx file.
#' @return Character vector of style IDs.
#' @keywords internal
#' @export
get_template_style_ids <- function(template_path) {
  if (!file.exists(template_path)) {
    stop("[style-map] Template not found: ", template_path)
  }

  with_docx_temp(template_path, function(temp_dir) {
    styles_path <- file.path(temp_dir, "word", "styles.xml")
    if (!file.exists(styles_path)) return(character(0))

    styles_xml <- xml2::read_xml(styles_path)
    get_template_style_ids_from_xml(styles_xml)
  }, files = c("word/styles.xml"))
}


#' Get All Style IDs from styles.xml Content
#'
#' XML-based variant of `get_template_style_ids()` for use in tests
#' and when the XML is already loaded.
#'
#' @param styles_xml_str Character string or xml2 document.
#' @return Character vector of style IDs.
#' @keywords internal
#' @export
get_template_style_ids_from_xml <- function(styles_xml_str) {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  if (inherits(styles_xml_str, "xml_document") ||
      inherits(styles_xml_str, "xml_node")) {
    doc <- styles_xml_str
  } else {
    doc <- xml2::read_xml(styles_xml_str)
  }

  style_nodes <- xml2::xml_find_all(doc, "/w:styles/w:style", ns)
  ids <- vapply(style_nodes, function(node) {
    xml2::xml_attr(node, "styleId")
  }, character(1))

  ids[!is.na(ids)]
}


# =============================================================================
# POST-RENDER STYLE SWAP — rewrite Pandoc IDs back to template-native IDs
# =============================================================================


#' Swap Style References in a Document XML
#'
#' Renames `w:pStyle`, `w:rStyle`, and `w:tblStyle` `val` attributes in a
#' parsed XML document according to the style map. Modifies the document
#' in place.
#'
#' @param doc_xml Parsed xml2 document (e.g., document.xml, footnotes.xml)
#' @param style_map Named list: Pandoc ID -> template ID
#' @param ns Named character vector of XML namespaces
#' @return Invisibly returns NULL (modifies in place)
#' @noRd
swap_document_styles <- function(doc_xml, style_map, ns) {
  pandoc_ids <- names(style_map)

  for (xpath in c("//w:pStyle", "//w:rStyle", "//w:tblStyle")) {
    nodes <- xml2::xml_find_all(doc_xml, xpath, ns)
    for (node in nodes) {
      val <- xml2::xml_attr(node, "val")
      if (!is.na(val) && val %in% pandoc_ids) {
        xml2::xml_set_attr(node, "w:val", style_map[[val]])
      }
    }
  }

  invisible(NULL)
}


#' Swap Style Definitions in styles.xml
#'
#' Renames `w:styleId` attributes and updates `w:basedOn`, `w:link`, and
#' `w:next` references in a parsed styles.xml document. Modifies in place.
#'
#' @param styles_xml Parsed xml2 document of styles.xml
#' @param style_map Named list: Pandoc ID -> template ID
#' @param ns Named character vector of XML namespaces
#' @return Invisibly returns NULL (modifies in place)
#' @noRd
swap_styles_xml <- function(styles_xml, style_map, ns) {
  pandoc_ids <- names(style_map)

  # Rename styleId attributes

  style_nodes <- xml2::xml_find_all(styles_xml, "//w:style", ns)
  for (node in style_nodes) {
    sid <- xml2::xml_attr(node, "styleId")
    if (!is.na(sid) && sid %in% pandoc_ids) {
      xml2::xml_set_attr(node, "w:styleId", style_map[[sid]])
    }
  }

  # Update basedOn, link, and next references
  for (xpath in c("//w:basedOn", "//w:link", "//w:next")) {
    nodes <- xml2::xml_find_all(styles_xml, xpath, ns)
    for (node in nodes) {
      val <- xml2::xml_attr(node, "val")
      if (!is.na(val) && val %in% pandoc_ids) {
        xml2::xml_set_attr(node, "w:val", style_map[[val]])
      }
    }
  }

  invisible(NULL)
}


#' Swap Pandoc Style IDs Back to Template-Native IDs
#'
#' Post-render entry point. Reads `style-map.json` from the sidecar directory,
#' then rewrites all Pandoc-emitted style IDs in the rendered DOCX back to the
#' template's native style IDs.
#'
#' @param docx_path Path to the rendered DOCX file
#' @param sidecar_dir Path to the `_docstyle/` sidecar directory
#' @return List with `swapped` (logical) and `n_mappings` (integer)
#' @keywords internal
#' @export
swap_style_ids <- function(docx_path, sidecar_dir) {
  json_path <- file.path(sidecar_dir, "style-map.json")

  if (!file.exists(json_path)) {
    message("[style-map] No style-map.json found, skipping swap")
    return(list(swapped = FALSE, n_mappings = 0L))
  }

  style_map <- jsonlite::fromJSON(json_path, simplifyVector = FALSE)
  if (length(style_map) == 0L) {
    message("[style-map] Empty style map, skipping swap")
    return(list(swapped = FALSE, n_mappings = 0L))
  }

  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  temp <- extract_docx_temp(docx_path)
  on.exit(temp$cleanup(), add = TRUE)

  word_dir <- file.path(temp$dir, "word")

  # Files to process: document.xml, styles.xml, footnotes.xml, endnotes.xml,
  # plus any header*.xml / footer*.xml
  doc_files <- c("document.xml", "styles.xml", "footnotes.xml", "endnotes.xml")
  hf_files <- list.files(word_dir, pattern = "^(header|footer)[0-9]*\\.xml$")
  all_targets <- c(doc_files, hf_files)

  for (filename in all_targets) {
    fpath <- file.path(word_dir, filename)
    if (!file.exists(fpath)) next

    doc_xml <- xml2::read_xml(fpath)

    if (filename == "styles.xml") {
      swap_styles_xml(doc_xml, style_map, ns)
    }
    # All files get document-level style reference swapping
    swap_document_styles(doc_xml, style_map, ns)

    xml2::write_xml(doc_xml, fpath)
  }

  message("[style-map] Swapped ", length(style_map), " style ID(s) in ",
          basename(docx_path))

  # Re-zip the DOCX in place (write to temp first, then atomically replace)
  docx_path_abs <- normalizePath(docx_path, mustWork = TRUE)
  old_wd <- getwd()
  on.exit(setwd(old_wd), add = TRUE)
  setwd(temp$dir)

  all_files <- list.files(".", recursive = TRUE, all.files = TRUE)
  zip_tmp <- paste0(docx_path_abs, ".tmp")
  result <- utils::zip(zip_tmp, files = all_files, flags = "-r9Xq")
  if (result != 0) {
    unlink(zip_tmp)
    stop("[style-map] Failed to re-zip DOCX: ", docx_path_abs)
  }
  file.remove(docx_path_abs)
  file.rename(zip_tmp, docx_path_abs)

  list(swapped = TRUE, n_mappings = length(style_map))
}
