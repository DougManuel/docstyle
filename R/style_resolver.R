# =============================================================================
# STYLE RESOLVER — map custom Word style IDs to canonical dispatch keys
# =============================================================================
#
# Word templates (MDPI, journal, institutional) define heading styles with
# non-standard names (e.g., "MDPI21heading1", "APA-Heading-1"). The harvest
# loop needs to know whether a paragraph is a heading—and which level—regardless
# of the style ID used.
#
# Resolution order:
#   1. Already canonical? → return as-is
#   2. outlineLvl attribute on the style definition (0=H1 … 5=H6) → Heading{n}
#   3. Walk basedOn chain: at each parent, try outlineLvl, then canonical match
#   4. Name-pattern fallback on the original style's display name
#   5. Return original style_id unchanged (body text / unknown)
#
# This is deliberately conservative: only heading levels 1–6 are resolved.
# outlineLvl 6–8 ("body outline" levels used in some templates) are left alone.
# =============================================================================


# Styles that the harvest switch already handles explicitly. These pass through
# resolve_to_canonical() unchanged.
.CANONICAL_DISPATCH_STYLES <- c(
  "Title", "Subtitle", "Date", "Version",
  paste0("Heading", 1:6),
  "ListParagraph", "ListBullet", "ListBullet2", "ListBullet3",
  "ListNumber", "ListNumber2",
  "p1",
  paste0("TOC", 1:9), "TOCHeading"
)


#' Build Style Properties Lookup from a DOCX File
#'
#' Reads `word/styles.xml` from the docx and returns a named list of style
#' properties keyed by `styleId`. Each entry contains `name`, `based_on`, and
#' `outline_level` — the minimum needed for canonical resolution.
#'
#' Called once at the start of `convert_to_qmd()`. Returns an empty list on
#' any error (e.g., missing file) so the harvest loop always gets a valid
#' lookup.
#'
#' @param docx_path Path to the source docx, or NULL.
#' @return Named list; each element is `list(name, based_on, outline_level)`.
#' @noRd
build_style_props_lookup <- function(docx_path) {
  if (is.null(docx_path) || !file.exists(docx_path)) return(list())

  tryCatch(
    with_docx_temp(docx_path, function(temp_dir) {
      styles_path <- file.path(temp_dir, "word", "styles.xml")
      if (!file.exists(styles_path)) return(list())

      ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
      styles_xml  <- xml2::read_xml(styles_path)
      style_nodes <- xml2::xml_find_all(styles_xml, "/w:styles/w:style", ns)

      result <- list()
      for (node in style_nodes) {
        style_id <- xml2::xml_attr(node, "styleId")
        if (is.na(style_id)) next

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

        outline_level <- parse_outline_level(node, style_id, ns)

        result[[style_id]] <- list(
          name          = name,
          based_on      = based_on,
          outline_level = outline_level
        )
      }
      result
    }),
    error = function(e) {
      message("[style-resolver] Failed to read style properties from '",
              basename(docx_path), "': ", conditionMessage(e),
              "\n  Custom heading styles will not be resolved.")
      list()
    }
  )
}


#' Parse outlineLvl attribute from a style node
#'
#' Converts the raw string value of `w:outlineLvl/@w:val` to integer, emitting
#' a message if the value is present but non-numeric (malformed template).
#'
#' @param node xml2 style node
#' @param style_id Style ID string (for diagnostic messages)
#' @param ns XML namespace
#' @return Integer 0-8, or NA_integer_ if absent or malformed
#' @noRd
parse_outline_level <- function(node, style_id, ns) {
  outline_node <- xml2::xml_find_first(node, "w:pPr/w:outlineLvl/@w:val", ns)
  if (inherits(outline_node, "xml_missing")) return(NA_integer_)

  raw_val <- xml2::xml_text(outline_node)
  if (grepl("^[0-9]+$", raw_val)) {
    as.integer(raw_val)
  } else {
    if (nzchar(raw_val)) {
      message("[style-resolver] Unexpected outlineLvl value '", raw_val,
              "' for style '", style_id, "'; treating as absent.")
    }
    NA_integer_
  }
}


#' Resolve a Word Style ID to Its Canonical Dispatch Key
#'
#' Maps a (potentially custom) Word paragraph style ID to the canonical key
#' used by the harvest switch statement. Enables non-standard templates
#' (MDPI, journal, institutional) to produce correct heading structure without
#' any template-specific configuration.
#'
#' @param style_id Character style ID from `w:pStyle/@w:val`.
#' @param props_lookup Named list from `build_style_props_lookup()`.
#' @return Character canonical key, or `style_id` unchanged if not resolved.
#' @noRd
resolve_to_canonical <- function(style_id, props_lookup) {
  # Guard: NA, NULL, or zero-length inputs pass through unchanged
  if (is.null(style_id) || length(style_id) != 1L || is.na(style_id)) {
    return(style_id)
  }

  # Fast path: already a canonical dispatch key
  if (style_id %in% .CANONICAL_DISPATCH_STYLES) return(style_id)

  # Walk the basedOn chain; at each node try outlineLvl then canonical match
  seen       <- character(0)
  current_id <- style_id

  while (!is.null(current_id) && nchar(current_id) > 0L &&
         !(current_id %in% seen)) {
    seen <- c(seen, current_id)

    # Reached a canonical style through the chain
    if (current_id %in% .CANONICAL_DISPATCH_STYLES) return(current_id)

    props <- props_lookup[[current_id]]
    if (is.null(props)) break

    # outlineLvl: 0=H1 … 5=H6; levels 6-8 are body-outline, not headings
    ol <- props$outline_level
    if (!is.na(ol) && ol >= 0L && ol <= 5L) {
      return(paste0("Heading", ol + 1L))
    }

    current_id <- props$based_on
  }

  # Name-pattern fallback on the original style's display name
  orig_props <- props_lookup[[style_id]]
  if (!is.null(orig_props) && !is.null(orig_props$name)) {
    name <- orig_props$name

    # "Heading 1", "heading2", "Heading  3" etc.
    h_match <- regmatches(name,
      regexpr("(?i)heading\\s*([1-6])", name, perl = TRUE))
    if (length(h_match) > 0L) {
      lvl <- regmatches(h_match, regexpr("[1-6]", h_match))
      if (length(lvl) > 0L) return(paste0("Heading", lvl))
    }

    # "TOC 1", "toc2" etc.
    t_match <- regmatches(name,
      regexpr("(?i)^toc\\s*([1-9])", name, perl = TRUE))
    if (length(t_match) > 0L) {
      lvl <- regmatches(t_match, regexpr("[1-9]", t_match))
      if (length(lvl) > 0L) return(paste0("TOC", lvl))
    }
  }

  style_id  # No resolution found — return unchanged
}
