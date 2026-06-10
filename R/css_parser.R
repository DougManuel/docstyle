#' Parse and Convert CSS Units
#'
#' Parses CSS unit strings (e.g., "12px", "1.5in") and converts them to
#' specific units required by Office Open XML (OOXML).
#'
#' @param val_str A string containing a numeric value and a CSS unit (e.g., "12px").
#'   If numeric, it is assumed to be in points.
#' @param base_font_size_pt Numeric. The base font size in points to use for relative
#'   units like "em" or "rem". Default is 12.
#'
#' @return A numeric value in points (intermediate conversion).
#' @keywords internal
parse_css_unit <- function(val_str, base_font_size_pt = 12) {
  if (is.numeric(val_str)) return(val_str)
  if (is.null(val_str) || is.na(val_str) || val_str == "") return(0)

  # Strip whitespace
  val_str <- trimws(val_str)

  # Extract numeric part and unit

  # Regex matches optional negative, digits, optional decimal, optional digits
  # Note: Does not handle scientific notation (e.g., 1.2e-3) which is rare in CSS
  matches <- regexpr("^-?[0-9]*\\.?[0-9]+([eE][+-]?[0-9]+)?", val_str)
  if (matches == -1) {
    warning(sprintf("Could not parse numeric value from '%s'. Returning 0.", val_str))
    return(0)
  }
  
  num_part <- as.numeric(regmatches(val_str, matches))
  unit_part <- substring(val_str, matches + attr(matches, "match.length"))
  unit_part <- trimws(tolower(unit_part))

  # Standard CSS DPI: 1in = 96px = 72pt
  # 1px = 0.75pt
  
  if (unit_part == "") {
    return(num_part)
  }

  points <- switch(unit_part,
    "pt" = num_part,
    "px" = num_part * 0.75,
    "in" = num_part * 72,
    "cm" = num_part * (72 / 2.54),
    "mm" = num_part * (72 / 25.4),
    "pc" = num_part * 12, # picas
    "em" = num_part * base_font_size_pt,
    "rem" = num_part * base_font_size_pt, # Treating rem same as em for now
    "%" = (num_part / 100) * base_font_size_pt, # Heuristic: % of base font
    {
      warning(sprintf("Unknown unit '%s' in '%s'. Assuming points.", unit_part, val_str))
      num_part
    }
  )

  return(points)
}

#' Convert CSS Value to Twips
#'
#' OOXML often uses twips (1/20 of a point) for measurements like margins,
#' indentation, and page size.
#'
#' @param val_str String. CSS value (e.g., "0.5in").
#' @return Integer. Value in twips.
#' @keywords internal
#' @export
css_to_twips <- function(val_str) {
  pts <- parse_css_unit(val_str)
  return(as.integer(round(pts * 20)))
}

#' Convert CSS Value to Half-Points
#'
#' OOXML uses half-points (1/2 of a point) for font sizes (`w:sz`).
#'
#' @param val_str String. CSS value (e.g., "12pt", "16px").
#' @return Integer. Value in half-points.
#' @keywords internal
#' @export
css_to_half_points <- function(val_str) {
  pts <- parse_css_unit(val_str)
  return(as.integer(round(pts * 2)))
}

#' Convert CSS Value to Eighth-Points
#'
#' OOXML uses eighth-points (1/8 of a point) for borders (`w:sz` in `w:top`, etc.).
#'
#' @param val_str String. CSS value (e.g., "1px", "2pt").
#' @return Integer. Value in eighth-points.
#' @keywords internal
#' @export
css_to_eighth_points <- function(val_str) {
  pts <- parse_css_unit(val_str)
  return(as.integer(round(pts * 8)))
}

#' Convert CSS Value to EMU (English Metric Units)
#'
#' DrawingML uses EMUs for measurements in `wp:anchor`, `wp:extent`, etc.
#' 1 inch = 914400 EMU, 1 pt = 12700 EMU, 1 cm = 360000 EMU,
#' 1 twip (DXA) = 635 EMU.
#'
#' Values with a "dxa" suffix are treated as twips (DXA). Plain integers
#' are also treated as DXA for backward compatibility with field code payloads.
#'
#' @param val_str String. CSS value (e.g., "250pt", "1in", "5000dxa") or
#'   plain integer string.
#' @return Integer. Value in EMU.
#' @keywords internal
#' @export
css_to_emu <- function(val_str) {
  if (is.null(val_str) || is.na(val_str) || !nzchar(val_str)) return(0L)
  val_str <- trimws(val_str)

  # DXA suffix: strip and convert (1 DXA = 635 EMU)
  if (grepl("dxa$", val_str)) {
    dxa <- as.numeric(sub("dxa$", "", val_str))
    if (is.na(dxa)) return(0L)
    return(as.integer(round(dxa * 635)))
  }

  # Plain integer: treat as DXA
  if (grepl("^-?[0-9]+$", val_str)) {
    dxa <- as.numeric(val_str)
    if (is.na(dxa)) return(0L)
    return(as.integer(round(dxa * 635)))
  }

  # CSS unit: parse to points, then convert (1 pt = 12700 EMU)
  pts <- parse_css_unit(val_str)
  as.integer(round(pts * 12700))
}

#' Clean CSS Color to OOXML Hex
#'
#' OOXML expects hex colors without the leading hash (e.g., "FFFFFF"), or "auto".
#' Handles generic names by mapping to basic hexes or passing through.
#'
#' @param color_str String. CSS color (e.g., "#FFFFFF", "red", "rgb(0,0,0)").
#' @return String. Hex code without hash (e.g., "FF0000").
#' @keywords internal
#' @export
css_to_ooxml_color <- function(color_str) {
  if (is.null(color_str) || is.na(color_str) || color_str == "") return("auto")
  
  color_str <- trimws(color_str)
  
  # Handle hex codes
  if (grepl("^#", color_str)) {
    # Remove hash
    hex <- substring(color_str, 2)
    if (nchar(hex) == 3) {
      # Expand #RGB to #RRGGBB
      parts <- strsplit(hex, "")[[1]]
      hex <- paste0(parts[1], parts[1], parts[2], parts[2], parts[3], parts[3])
    }
    return(toupper(hex))
  }
  
  # Handle "transparent" or "none"
  if (tolower(color_str) %in% c("transparent", "none")) {
    return("auto") # Or specific code depending on context, often 'auto' or omission
  }

  # Basic named colors fallback (R's col2rgb can handle standard names)
  # We use tryCatch because col2rgb fails on unknown names
  rgb_val <- tryCatch(
    grDevices::col2rgb(color_str),
    error = function(e) NULL
  )

  if (!is.null(rgb_val)) {
    hex <- sprintf("%02X%02X%02X", rgb_val[1], rgb_val[2], rgb_val[3])
    return(hex)
  }

  # If all else fails, return as is (might be a theme color or unknown)
  warning(sprintf("Could not convert color '%s'. Returning 'auto'.", color_str))
  return("auto")
}


#' Convert CSS Properties to OOXML Run Properties (rPr)
#'
#' Takes a list of CSS properties (from `parse_css_properties`) and converts
#' them to the OOXML `<w:rPr>` structure for inline text styling.
#'
#' @param css_props Named list of CSS properties (e.g., from `read_css()`).
#' @return A list suitable for building `<w:rPr>` XML elements.
#' @keywords internal
#' @export
#'
#' @examples
#' \dontrun{
#' css <- list(
#'   "font-family" = '"Hanken Grotesk", Arial, sans-serif',
#'   "font-size" = "9pt",
#'   "color" = "#666666"
#' )
#' rPr <- css_to_rPr(css)
#' }
css_to_rPr <- function(css_props) {
  if (is.null(css_props) || length(css_props) == 0) {
    return(list())
  }

  rPr <- list()

  # Font family -> w:rFonts
  if (!is.null(css_props[["font-family"]])) {
    font <- extract_primary_font(css_props[["font-family"]])
    if (!is.null(font)) {
      rPr$rFonts <- list(ascii = font, hAnsi = font, cs = font)
    }
  }

  # Font size -> w:sz (half-points)
  if (!is.null(css_props[["font-size"]])) {
    sz <- css_to_half_points(css_props[["font-size"]])
    rPr$sz <- list(val = as.character(sz))
    rPr$szCs <- list(val = as.character(sz))  # Complex script size
  }

  # Color -> w:color
  if (!is.null(css_props[["color"]])) {
    color <- css_to_ooxml_color(css_props[["color"]])
    if (color != "auto") {
      rPr$color <- list(val = color)
    }
  }

  # Font weight -> w:b (bold)
  if (!is.null(css_props[["font-weight"]])) {
    weight <- tolower(css_props[["font-weight"]])
    if (weight %in% c("bold", "700", "800", "900")) {
      rPr$b <- list()  # Empty element means "on"
    } else if (weight %in% c("normal", "400")) {
      rPr$b <- list(val = "0")  # Explicitly off
    }
  }

  # Font style -> w:i (italic)
  if (!is.null(css_props[["font-style"]])) {
    style <- tolower(css_props[["font-style"]])
    if (style == "italic") {
      rPr$i <- list()
    } else if (style == "normal") {
      rPr$i <- list(val = "0")
    }
  }

  # Text decoration -> w:u (underline), w:strike

  if (!is.null(css_props[["text-decoration"]])) {
    deco <- tolower(css_props[["text-decoration"]])
    if (grepl("underline", deco)) {
      rPr$u <- list(val = "single")
    }
    if (grepl("line-through", deco)) {
      rPr$strike <- list()
    }
  }

  rPr
}


#' Extract Primary Font from CSS Font-Family
#'
#' Parses a CSS font-family string and returns the first (primary) font name.
#'
#' @param font_family CSS font-family string (e.g., '"Arial", sans-serif').
#' @return The primary font name without quotes, or NULL if parsing fails.
#' @keywords internal
extract_primary_font <- function(font_family) {
  if (is.null(font_family) || font_family == "") return(NULL)

  # Split by comma and take first
  fonts <- trimws(strsplit(font_family, ",")[[1]])
  if (length(fonts) == 0) return(NULL)

  primary <- fonts[1]

  # Remove surrounding quotes (single or double)
  primary <- gsub('^["\']|["\']$', "", primary)

  # Skip generic font families
  generics <- c("serif", "sans-serif", "monospace", "cursive", "fantasy",
                "system-ui", "ui-serif", "ui-sans-serif", "ui-monospace")
  if (tolower(primary) %in% generics) {
    # Try next font if available
    if (length(fonts) > 1) {
      return(extract_primary_font(paste(fonts[-1], collapse = ",")))
    }
    return(NULL)
  }

  primary
}


#' Build rPr XML String
#'
#' Converts an rPr list (from `css_to_rPr`) to an XML string for embedding
#' in Word document runs.
#'
#' @param rPr List of run properties from `css_to_rPr()`.
#' @return XML string for `<w:rPr>` element, or empty string if no properties.
#' @keywords internal
#' @export
build_rPr_xml <- function(rPr) {
  if (is.null(rPr) || length(rPr) == 0) {
    return("")
  }

  children <- character(0)

  for (prop_name in names(rPr)) {
    prop_val <- rPr[[prop_name]]

    if (length(prop_val) == 0) {
      # Empty element (e.g., <w:b/>)
      children <- c(children, sprintf("<w:%s/>", prop_name))
    } else {
      # Element with attributes
      attrs <- sapply(names(prop_val), function(attr_name) {
        sprintf('w:%s="%s"', attr_name, xml_escape_attr(prop_val[[attr_name]]))
      })
      children <- c(children, sprintf("<w:%s %s/>", prop_name, paste(attrs, collapse = " ")))
    }
  }

  if (length(children) == 0) {
    return("")
  }

  sprintf("<w:rPr>%s</w:rPr>", paste(children, collapse = ""))
}


#' Parse CSS Border Shorthand
#'
#' Parses a CSS border shorthand value (e.g., "1pt solid #000000") into
#' OOXML-compatible components.
#'
#' @param border_str CSS border string (e.g., "1pt solid #7F7F7F", "none").
#' @return List with `val` (OOXML border style), `sz` (eighth-points string),
#'   and `color` (hex without hash), or NULL if "none" or empty.
#' @keywords internal
#' @export
parse_css_border <- function(border_str) {
  if (is.null(border_str) || is.na(border_str) || border_str == "") return(NULL)

  border_str <- trimws(border_str)

  # Handle "none" keyword
  if (tolower(border_str) == "none") return(NULL)


  # Split into parts: width style color
  parts <- strsplit(border_str, "\\s+")[[1]]
  if (length(parts) < 2) return(NULL)

  # Parse width (first part)
  sz <- as.character(css_to_eighth_points(parts[1]))

  # Parse style (second part) — map CSS to OOXML
  css_style <- tolower(parts[2])
  val <- switch(css_style,
    "solid"  = "single",
    "dashed" = "dashed",
    "dotted" = "dotted",
    "double" = "double",
    "none"   = return(NULL),
    "single"  # default fallback
  )

  # Parse color (third part, optional)
  color <- if (length(parts) >= 3) {
    css_to_ooxml_color(parts[3])
  } else {
    "auto"
  }

  list(val = val, sz = sz, color = color)
}


#' Extract Table Style from CSS Properties
#'
#' Converts parsed CSS properties for a table class (e.g., `.table-formal`)
#' and its `th`/`td` sub-selectors into a structured table style definition
#' suitable for OOXML rendering.
#'
#' @param table_props CSS properties for the table selector (e.g., `.table-formal`).
#' @param th_props CSS properties for the `th` sub-selector (e.g., `.table-formal th`).
#' @param td_props CSS properties for the `td` sub-selector (e.g., `.table-formal td`).
#' @return A list with `borders`, `header_shading`, `header_bold`, and
#'   optionally `font_size_half_pts`.
#' @keywords internal
#' @export
css_to_table_style <- function(table_props, th_props = NULL, td_props = NULL) {
  style <- list()

  # Table-level borders
  if (!is.null(table_props)) {
    borders <- list()

    # Individual border sides
    for (side in c("top", "bottom", "left", "right")) {
      prop_name <- paste0("border-", side)
      if (!is.null(table_props[[prop_name]])) {
        borders[[side]] <- parse_css_border(table_props[[prop_name]])
      }
    }

    # Shorthand border (applies to all sides not already set)
    if (!is.null(table_props[["border"]])) {
      shorthand <- parse_css_border(table_props[["border"]])
      if (!is.null(shorthand)) {
        for (side in c("top", "bottom", "left", "right")) {
          if (is.null(borders[[side]])) borders[[side]] <- shorthand
        }
      }
    }

    style$borders <- if (length(borders) > 0) borders else NULL
  }

  # Cell borders from th/td selectors (used for insideH/insideV)
  # If th/td have explicit borders, they define inside borders
  cell_border <- NULL
  if (!is.null(th_props) && !is.null(th_props[["border"]])) {
    cell_border <- parse_css_border(th_props[["border"]])
  } else if (!is.null(td_props) && !is.null(td_props[["border"]])) {
    cell_border <- parse_css_border(td_props[["border"]])
  }
  if (!is.null(cell_border)) {
    if (is.null(style$borders)) style$borders <- list()
    if (is.null(style$borders$insideH)) style$borders$insideH <- cell_border
    if (is.null(style$borders$insideV)) style$borders$insideV <- cell_border
  }

  # Header shading from th background-color
  if (!is.null(th_props) && !is.null(th_props[["background-color"]])) {
    color <- css_to_ooxml_color(th_props[["background-color"]])
    if (color != "auto") {
      style$header_shading <- color
    }
  }

  # Header bold from th font-weight
  if (!is.null(th_props) && !is.null(th_props[["font-weight"]])) {
    weight <- tolower(th_props[["font-weight"]])
    style$header_bold <- weight %in% c("bold", "700", "800", "900")
  }

  # Font size from table-level (used as default; div attribute overrides)
  if (!is.null(table_props) && !is.null(table_props[["font-size"]])) {
    style$font_size_half_pts <- css_to_half_points(table_props[["font-size"]])
  }

  style
}


#' Extract All Table Styles from Parsed CSS
#'
#' Scans parsed CSS for `.table-*` class selectors and extracts table style
#' configurations for each one.
#'
#' @param css_styles Parsed CSS list from `read_css()`.
#' @return Named list of table style configurations keyed by class name
#'   (e.g., `"table-formal"`, `"table-grid"`).
#' @keywords internal
#' @export
extract_table_styles <- function(css_styles) {
  if (is.null(css_styles)) return(list())

  # Find all .table-* selectors
  selectors <- names(css_styles)
  table_selectors <- selectors[grepl("^\\.table-[a-zA-Z-]+$", selectors)]

  table_styles <- list()
  for (sel in table_selectors) {
    class_name <- sub("^\\.", "", sel)
    th_sel <- paste0(sel, " th")
    td_sel <- paste0(sel, " td")

    table_props <- css_styles[[sel]]
    th_props <- css_styles[[th_sel]]
    td_props <- css_styles[[td_sel]]

    # Also check combined "th, td" selectors (e.g., ".table-grid th, .table-grid td")
    # Match by pattern to handle any whitespace variation
    combined_pattern <- paste0("^\\Q", sel, "\\E\\s+th[,\\s]+\\Q", sel, "\\E\\s+td$")
    combined_match <- grep(combined_pattern, selectors, value = TRUE, perl = TRUE)
    combined <- if (length(combined_match) > 0) css_styles[[combined_match[1]]] else NULL
    if (!is.null(combined)) {
      if (is.null(th_props)) th_props <- combined
      if (is.null(td_props)) td_props <- combined
    }

    table_styles[[class_name]] <- css_to_table_style(table_props, th_props, td_props)
  }

  table_styles
}


#' Extract anchor positioning properties from CSS
#'
#' Extracts anchor positioning properties from a parsed CSS property list.
#' Returns NULL if no anchor-triggering properties are present.
#'
#' @param props Named list of CSS properties for a single selector.
#' @return Named list of anchor style properties, or NULL if not an anchor.
#' @keywords internal
#' @export
css_to_anchor_style <- function(props) {
  if (is.null(props)) return(NULL)

  # Detection: must have at least one anchor property
  v_anchor <- props[["vertical-anchor"]]
  h_anchor <- props[["horizontal-anchor"]]
  if (is.null(v_anchor) && is.null(h_anchor)) return(NULL)

  style <- list(
    vertical_anchor  = v_anchor %||% "text",
    horizontal_anchor = h_anchor %||% "margin",
    position_y       = props[["position-y"]] %||% "0",
    position_x       = props[["position-x"]] %||% "0",
    float_width      = props[["float-width"]],
    wrap_style       = props[["wrap-style"]] %||% "square",
    wrap_side        = props[["wrap-side"]] %||% "both",
    wrap_distance    = props[["wrap-distance"]] %||% "0 198dxa 0 198dxa",
    z_layer          = props[["z-layer"]] %||% "front"
  )

  # Optional content_mode — only include if explicitly set
  cm <- props[["content-mode"]]
  if (!is.null(cm) && cm != "auto") {
    style$content_mode <- cm
  }

  style
}


#' Extract all anchor styles from parsed CSS
#'
#' Scans parsed CSS for class selectors that contain anchor positioning
#' properties (`vertical-anchor` or `horizontal-anchor`). Any class selector
#' with these properties becomes an anchor-eligible class.
#'
#' @param css_styles Parsed CSS list from `read_css()`.
#' @return Named list of anchor style configurations keyed by class name.
#' @keywords internal
#' @export
extract_anchor_styles <- function(css_styles) {
  if (is.null(css_styles)) return(list())

  anchor_styles <- list()
  for (sel in names(css_styles)) {
    if (!grepl("^\\.[a-zA-Z]", sel)) next
    if (grepl("\\s", sel)) next

    style <- css_to_anchor_style(css_styles[[sel]])
    if (!is.null(style)) {
      class_name <- sub("^\\.", "", sel)
      anchor_styles[[class_name]] <- style
    }
  }

  anchor_styles
}


# xml_escape_attr() lives in utils.R
