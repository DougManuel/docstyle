#' Word List/Numbering Processing
#'
#' Functions for parsing Word numbering.xml and converting list formats
#' to Markdown list syntax.
#'
#' @name list_processing
#' @keywords internal
NULL


#' Build a lookup table for Word numbering formats
#'
#' Parses numbering.xml from a docx and builds a lookup table mapping
#' numId + ilvl to the corresponding numFmt (decimal, lowerLetter, bullet, etc.)
#' and start values.
#'
#' @param docx_path Path to the docx file
#' @return List with $formats and $starts sublists, each mapping numId -> ilvl -> value.
#'   Returns empty list if numbering.xml doesn't exist.
#' @noRd
build_numbering_lookup <- function(docx_path) {
  with_docx_temp(docx_path, function(temp_dir) {
    numbering_path <- file.path(temp_dir, "word", "numbering.xml")
    if (!file.exists(numbering_path)) return(list())

    numbering_xml <- xml2::read_xml(numbering_path)
    ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
    w_ns <- "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    # xml2 sometimes needs the full namespace URI for attributes
    w_attr <- function(node, attr) {
      val <- xml2::xml_attr(node, paste0("{", w_ns, "}", attr))
      if (is.na(val)) val <- xml2::xml_attr(node, attr)
      val
    }

    # Extract numFmt from a w:lvl element, or NA
    lvl_fmt <- function(lvl_node, ns) {
      fmt_node <- xml2::xml_find_first(lvl_node, "w:numFmt", ns)
      if (inherits(fmt_node, "xml_missing")) return(NA_character_)
      w_attr(fmt_node, "val")
    }

    # Extract start value from a w:lvl element, or NA
    lvl_start <- function(lvl_node, ns) {
      start_node <- xml2::xml_find_first(lvl_node, "w:start", ns)
      if (inherits(start_node, "xml_missing")) return(NA_integer_)
      val <- w_attr(start_node, "val")
      if (is.na(val)) return(NA_integer_)
      as.integer(val)
    }

    # Step 1: abstractNum lookup: abstractNumId -> per-level numFmt and start
    abstract_fmt_map <- list()
    abstract_start_map <- list()
    for (abn in xml2::xml_find_all(numbering_xml, "//w:abstractNum", ns)) {
      abs_id <- xml2::xml_attr(abn, "abstractNumId")
      level_fmts <- list()
      level_starts <- list()
      for (lvl in xml2::xml_find_all(abn, "w:lvl", ns)) {
        ilvl <- w_attr(lvl, "ilvl")
        if (is.na(ilvl)) next
        fmt <- lvl_fmt(lvl, ns)
        if (!is.na(fmt)) level_fmts[[paste0("ilvl", ilvl)]] <- fmt
        start_val <- lvl_start(lvl, ns)
        if (!is.na(start_val)) level_starts[[paste0("ilvl", ilvl)]] <- start_val
      }
      abstract_fmt_map[[abs_id]] <- level_fmts
      abstract_start_map[[abs_id]] <- level_starts
    }

    # Step 2: num lookup: numId -> resolved formats and starts (abstract + overrides)
    num_map <- list()
    start_map <- list()
    for (num in xml2::xml_find_all(numbering_xml, "//w:num", ns)) {
      num_id <- w_attr(num, "numId")

      abs_id_node <- xml2::xml_find_first(num, "w:abstractNumId", ns)
      if (inherits(abs_id_node, "xml_missing")) next
      abs_id <- w_attr(abs_id_node, "val")

      fmts <- abstract_fmt_map[[abs_id]]
      if (is.null(fmts)) fmts <- list()
      starts <- abstract_start_map[[abs_id]]
      if (is.null(starts)) starts <- list()

      # Apply level overrides
      for (ovr in xml2::xml_find_all(num, "w:lvlOverride", ns)) {
        ilvl <- w_attr(ovr, "ilvl")
        if (is.na(ilvl)) next
        # Format override from w:lvl inside w:lvlOverride
        ovr_lvl <- xml2::xml_find_first(ovr, "w:lvl", ns)
        if (!inherits(ovr_lvl, "xml_missing")) {
          fmt <- lvl_fmt(ovr_lvl, ns)
          if (!is.na(fmt)) fmts[[paste0("ilvl", ilvl)]] <- fmt
          start_val <- lvl_start(ovr_lvl, ns)
          if (!is.na(start_val)) starts[[paste0("ilvl", ilvl)]] <- start_val
        }
        # Start override from w:startOverride (takes precedence)
        start_ovr <- xml2::xml_find_first(ovr, "w:startOverride", ns)
        if (!inherits(start_ovr, "xml_missing")) {
          val <- w_attr(start_ovr, "val")
          if (!is.na(val)) starts[[paste0("ilvl", ilvl)]] <- as.integer(val)
        }
      }

      num_map[[num_id]] <- fmts
      start_map[[num_id]] <- starts
    }

    list(formats = num_map, starts = start_map)
  })
}


#' Look up numFmt for a given numId and ilvl
#'
#' @param numbering_lookup Result of build_numbering_lookup()
#' @param num_id Character numId value
#' @param ilvl Character or integer ilvl value
#' @return numFmt string (e.g., "decimal", "lowerLetter") or NA
#' @noRd
lookup_num_fmt <- function(numbering_lookup, num_id, ilvl) {
  if (length(numbering_lookup) == 0) return(NA_character_)
  # Support both new structure (list with $formats) and legacy flat structure
  formats <- if (!is.null(numbering_lookup$formats)) numbering_lookup$formats
             else numbering_lookup
  fmts <- formats[[as.character(num_id)]]
  if (is.null(fmts)) return(NA_character_)
  fmt <- fmts[[paste0("ilvl", ilvl)]]
  if (is.null(fmt)) return(NA_character_)
  fmt
}


#' Look up start value for a given numId and ilvl
#'
#' @param numbering_lookup Result of build_numbering_lookup()
#' @param num_id Character numId value
#' @param ilvl Character or integer ilvl value
#' @return Integer start value, or 1L as default
#' @noRd
lookup_num_start <- function(numbering_lookup, num_id, ilvl) {
  starts <- numbering_lookup$starts
  if (is.null(starts) || length(starts) == 0) return(1L)
  level_starts <- starts[[as.character(num_id)]]
  if (is.null(level_starts)) return(1L)
  val <- level_starts[[paste0("ilvl", ilvl)]]
  if (is.null(val)) return(1L)
  val
}


#' Convert a start value to the prefix character for a given numFmt
#'
#' @param num_fmt Character numFmt (e.g., "decimal", "lowerLetter")
#' @param start Integer start value (1-based)
#' @return Character prefix (e.g., "5" for decimal/5, "e" for lowerLetter/5)
#' @noRd
start_to_prefix <- function(num_fmt, start) {
  if (is.na(start) || start < 1) start <- 1L
  switch(num_fmt,
    "decimal" = as.character(start),
    "lowerLetter" = if (start > 26) "a" else tolower(LETTERS[start]),
    "upperLetter" = if (start > 26) "A" else LETTERS[start],
    "lowerRoman" = tolower(as.character(utils::as.roman(start))),
    "upperRoman" = as.character(utils::as.roman(start)),
    # bullet and unknown: no start concept
    ""
  )
}


#' Convert numFmt to markdown list prefix
#'
#' Maps Word numbering format to the appropriate markdown list syntax.
#' Uses Pandoc fancy_lists for non-standard formats.
#'
#' @param num_fmt Character numFmt value from numbering.xml
#' @param indent Character indent string for nesting
#' @param start Integer start value (default 1L)
#' @return Markdown prefix string (e.g., "a. ", "  i. ", "5. ")
#' @noRd
numfmt_to_md_prefix <- function(num_fmt, indent = "", start = 1L) {
  if (num_fmt == "bullet") return(paste0(indent, "- "))
  prefix_char <- start_to_prefix(num_fmt, start)
  if (nchar(prefix_char) == 0) return(paste0(indent, "- "))
  paste0(indent, prefix_char, ". ")
}


#' Get list prefix using numbering lookup, with bullet fallback
#'
#' @param numbering_lookup Result of build_numbering_lookup()
#' @param num_id Character numId (or NULL)
#' @param list_level Integer indent level
#' @param indent Character indent string
#' @return Markdown prefix string
#' @noRd
list_prefix <- function(numbering_lookup, num_id, list_level, indent,
                        item_position = NULL) {
  if (!is.null(num_id) && length(numbering_lookup) > 0) {
    num_fmt <- lookup_num_fmt(numbering_lookup, num_id, list_level)
    if (!is.na(num_fmt)) {
      start <- lookup_num_start(numbering_lookup, num_id, list_level)
      # item_position overrides: effective start = definition start + position - 1
      if (!is.null(item_position) && item_position > 1) {
        start <- start + item_position - 1L
      }
      return(numfmt_to_md_prefix(num_fmt, indent, start))
    }
  }
  paste0(indent, "- ")
}
