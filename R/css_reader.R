#' Read CSS File(s)
#'
#' Parses one or more CSS files into a structured list of styles.
#' When multiple files are provided, styles are merged in order (later files
#' override earlier ones, following CSS cascade rules).
#'
#' @param path Path to CSS file(s). Can be a single path or a character vector
#'   of paths for layered styles.
#' @return A named list where names are selectors and values are lists of properties.
#'   Also includes a `page` attribute containing parsed `@page` rules if present.
#' @export
#' @examples
#' \dontrun{
#' # Single file
#' styles <- read_css("base.css")
#'
#' # Layered styles (overrides applied in order)
#' styles <- read_css(c("base.css", "overrides.css"))
#'
#' # Access @page configuration
#' page_config <- attr(styles, "page")
#' }
read_css <- function(path) {
  # Handle multiple CSS files (layered styles)
  if (length(path) > 1) {
    merged_styles <- list()
    merged_page <- list()
    for (p in path) {
      if (!file.exists(p)) {
        warning("CSS file not found, skipping: ", p)
        next
      }
      css_content <- paste(readLines(p, warn = FALSE), collapse = "\n")
      file_styles <- parse_css_content(css_content)
      merged_styles <- merge_css_styles(merged_styles, file_styles)
      # Merge page config (later files override)
      file_page <- attr(file_styles, "page")
      if (!is.null(file_page)) {
        merged_page <- merge_page_config(merged_page, file_page)
      }
    }
    attr(merged_styles, "page") <- if (length(merged_page) > 0) merged_page else NULL
    return(merged_styles)
  }

  # Single file path
  if (!file.exists(path)) {
    stop("CSS file not found: ", path)
  }

  css_content <- paste(readLines(path, warn = FALSE), collapse = "\n")
  parse_css_content(css_content)
}


#' Merge CSS Style Lists
#'
#' Merges two parsed CSS style lists, with properties from the second list
#' overriding those in the first (following CSS cascade rules).
#'
#' @param base Base styles list.
#' @param overlay Overlay styles list (takes precedence).
#' @return Merged styles list.
#' @keywords internal
merge_css_styles <- function(base, overlay) {
  result <- base

for (selector in names(overlay)) {
    if (is.null(result[[selector]])) {
      # New selector, add it
      result[[selector]] <- overlay[[selector]]
    } else {
      # Existing selector, merge properties (overlay wins)
      for (prop in names(overlay[[selector]])) {
        result[[selector]][[prop]] <- overlay[[selector]][[prop]]
      }
    }
  }

  result
}

#' Parse CSS Content
#'
#' @param text Raw CSS string.
#' @return Named list of styles with a `page` attribute containing @page rules.
#' @keywords internal
parse_css_content <- function(text) {
  # 1. Remove comments /* ... */
  # Non-greedy match for content between /* and */
  text <- gsub("/\\*.*?\\*/", "", text, perl = TRUE) # multiline comments? perl=TRUE usually needed
  # Actually, standard regex for comments: /\*[\s\S]*?\*/
  # R's gsub with perl=TRUE handles \s\S or (?s) dot-all
  text <- gsub("(?s)/\\*.*?\\*/", "", text, perl = TRUE)

  # 2. Extract @page rules before parsing regular selectors
  page_config <- parse_page_rules(text)

  # Remove @page blocks from text so they don't interfere with selector parsing
  text <- gsub("@page\\s*(:?[a-zA-Z-]*)\\s*\\{[^}]*\\}", "", text, perl = TRUE)

  # 3. Find blocks: selector { content }
  # We will split by "}" to get blocks, then split by "{" to separate selector from props
  # This is a simple heuristic parser.

  blocks <- strsplit(text, "}")[[1]]

  styles <- list()

  for (block in blocks) {
    if (trimws(block) == "") next

    parts <- strsplit(block, "\\{")[[1]]
    if (length(parts) < 2) next # Invalid block?

    # Handle multiple selectors (comma separated)
    selector_str <- trimws(parts[1])
    # Clean newlines in selector
    selector_str <- gsub("\\s+", " ", selector_str)

    selectors <- trimws(strsplit(selector_str, ",")[[1]])

    # Parse properties
    prop_str <- parts[2]
    props <- parse_css_properties(prop_str)

    if (length(props) > 0) {
      for (sel in selectors) {
        # Store or merge?
        # CSS cascade rules say last one wins.
        # We will just overwrite for now.
        styles[[sel]] <- props
      }
    }
  }

  # Attach page config as attribute
  if (length(page_config) > 0) {
    attr(styles, "page") <- page_config
  }

  return(styles)
}

#' Parse CSS Properties Block
#'
#' @param text Content inside curly braces from a CSS rule.
#' @return Named list of properties.
#' @keywords internal
parse_css_properties <- function(text) {

  props <- list()

  # Split by semicolon
  items <- strsplit(text, ";")[[1]]

  for (item in items) {
    if (trimws(item) == "") next

    kv <- strsplit(item, ":")[[1]]
    if (length(kv) < 2) next

    key <- trimws(kv[1])
    val <- trimws(paste(kv[-1], collapse = ":")) # Handle values with colons (e.g. urls?)

    # CamelCase key for consistency? Or keep kebab-case?
    # Let's keep kebab-case as it matches CSS.
    props[[key]] <- val
  }

  return(props)
}


#' Parse @page Rules from CSS
#'
#' Extracts `@page` rules from CSS content and converts them to a page
#' configuration structure compatible with docstyle's page settings.
#'
#' @param text Raw CSS string.
#' @return List with page configuration (size, margins, orientation, line-numbers).
#'   Named page rules are stored in `$named` as a list keyed by name.
#' @keywords internal
#'
#' @details
#' Supports standard CSS Paged Media properties:
#' - `size`: letter | a4 | legal, optionally with orientation (e.g., "letter landscape")
#' - `margin`: shorthand or individual margin-top, margin-right, etc.
#'
#' Also supports docstyle extensions via CSS custom properties:
#' - `--docstyle-line-numbers`: "every 1" | "every 5" | "none"
#' - `--docstyle-line-numbers-restart`: "page" | "section" | "continuous"
#' - `--docstyle-line-numbers-distance`: CSS length (e.g., "0.25in")
#' - `--docstyle-suppress-top-spacing`: "true" | "false" (suppress before-spacing
#'   on the first content paragraph after a section break)
#'
#' Named page rules (e.g., `@page landscape { ... }`) are stored in `$named`:
#' ```r
#' page_config$named$landscape  # Properties for @page landscape
#' ```
#'
#' @examples
#' \dontrun{
#' css <- '@page { size: letter; margin: 1in; }
#'         @page landscape { size: letter landscape; margin: 0.5in; }'
#' page_config <- parse_page_rules(css)
#' # Returns: list(
#' #   size = "letter",
#' #   margins = list(top = "1in", ...),
#' #   named = list(landscape = list(size = "letter", orientation = "landscape", ...))
#' # )
#' }
parse_page_rules <- function(text) {
  page_config <- list()

  # Match @page rules: @page [name|:pseudo] { ... }
  # Regex captures: optional name/pseudo-selector, content inside braces
  # Names can be: empty, :first, :left, :right, or custom names like "landscape"
  page_pattern <- "@page\\s*(:?[a-zA-Z][a-zA-Z0-9-]*)?\\s*\\{([^}]*)\\}"

  matches <- gregexpr(page_pattern, text, perl = TRUE)
  if (matches[[1]][1] == -1) {
    return(page_config)
  }

  # Extract all matches
  match_data <- regmatches(text, matches)[[1]]

  for (match in match_data) {
    # Parse the name/pseudo-selector and properties
    parts <- regmatches(match, regexec(page_pattern, match, perl = TRUE))[[1]]
    if (length(parts) < 3) next

    selector <- trimws(parts[2])  # e.g., ":first", "landscape", or ""
    props_text <- parts[3]
    props <- parse_css_properties(props_text)

    # Parse standard CSS Paged Media properties
    page_props <- parse_page_properties(props)

    if (selector == "") {
      # Default @page rule
      page_config <- modifyList(page_config, page_props)
    } else if (selector == ":first") {
      # First-page pseudo-selector
      if (is.null(page_config$first_page)) {
        page_config$first_page <- list()
      }
      page_config$first_page <- modifyList(page_config$first_page, page_props)
    } else if (startsWith(selector, ":")) {
      # Other pseudo-selectors (:left, :right, :blank) - store but not used yet
      pseudo_name <- substring(selector, 2)  # Remove leading ":"
      if (is.null(page_config$pseudo)) {
        page_config$pseudo <- list()
      }
      if (is.null(page_config$pseudo[[pseudo_name]])) {
        page_config$pseudo[[pseudo_name]] <- list()
      }
      page_config$pseudo[[pseudo_name]] <- modifyList(
        page_config$pseudo[[pseudo_name]], page_props
      )
    } else {
      # Named page rule (e.g., @page landscape)
      if (is.null(page_config$named)) {
        page_config$named <- list()
      }
      if (is.null(page_config$named[[selector]])) {
        page_config$named[[selector]] <- list()
      }
      page_config$named[[selector]] <- modifyList(
        page_config$named[[selector]], page_props
      )
    }
  }

  page_config
}


#' Parse CSS @page Properties
#'
#' Converts CSS @page properties to docstyle page configuration format.
#'
#' @param props Named list of CSS properties from @page rule.
#' @return List with docstyle page configuration.
#' @keywords internal
parse_page_properties <- function(props) {
  config <- list()

 # Size property: "letter", "a4", "letter landscape", etc.
  if (!is.null(props[["size"]])) {
    size_parts <- strsplit(trimws(props[["size"]]), "\\s+")[[1]]

    # First part is size name
    size_name <- tolower(size_parts[1])
    # Map CSS size names to docstyle names
    size_map <- c(
      "letter" = "letter",
      "us-letter" = "letter",
      "a4" = "a4",
      "legal" = "legal",
      "us-legal" = "legal"
    )
    config$size <- if (size_name %in% names(size_map)) size_map[[size_name]] else size_name

    # Check for orientation in size value
    if (length(size_parts) > 1) {
      orient <- tolower(size_parts[2])
      if (orient %in% c("landscape", "portrait")) {
        config$orientation <- orient
      }
    }
  }

  # Margin shorthand
  if (!is.null(props[["margin"]])) {
    config$margins <- parse_margin_shorthand(props[["margin"]])
  }

  # Individual margins (override shorthand)
  if (!is.null(props[["margin-top"]])) {
    if (is.null(config$margins)) config$margins <- list()
    config$margins$top <- props[["margin-top"]]
  }
  if (!is.null(props[["margin-bottom"]])) {
    if (is.null(config$margins)) config$margins <- list()
    config$margins$bottom <- props[["margin-bottom"]]
  }
  if (!is.null(props[["margin-left"]])) {
    if (is.null(config$margins)) config$margins <- list()
    config$margins$left <- props[["margin-left"]]
  }
  if (!is.null(props[["margin-right"]])) {
    if (is.null(config$margins)) config$margins <- list()
    config$margins$right <- props[["margin-right"]]
  }

  # docstyle extensions: --docstyle-line-numbers
  if (!is.null(props[["--docstyle-line-numbers"]])) {
    ln_value <- trimws(props[["--docstyle-line-numbers"]])
    if (tolower(ln_value) == "none") {
      config$`line-numbers` <- list(enabled = FALSE)
    } else {
      # Parse "every N" format
      ln_match <- regexec("every\\s+(\\d+)", ln_value, ignore.case = TRUE)
      ln_parts <- regmatches(ln_value, ln_match)[[1]]
      if (length(ln_parts) >= 2) {
        config$`line-numbers` <- list(
          enabled = TRUE,
          `count-by` = as.integer(ln_parts[2])
        )
      } else {
        # Default to every line
        config$`line-numbers` <- list(enabled = TRUE, `count-by` = 1L)
      }
    }
  }

  # Line numbers restart
  if (!is.null(props[["--docstyle-line-numbers-restart"]])) {
    if (is.null(config$`line-numbers`)) config$`line-numbers` <- list(enabled = TRUE)
    config$`line-numbers`$restart <- tolower(trimws(props[["--docstyle-line-numbers-restart"]]))
  }

  # Line numbers distance
  if (!is.null(props[["--docstyle-line-numbers-distance"]])) {
    if (is.null(config$`line-numbers`)) config$`line-numbers` <- list(enabled = TRUE)
    config$`line-numbers`$distance <- trimws(props[["--docstyle-line-numbers-distance"]])
  }

  # Suppress top spacing on first paragraph after section break
  if (!is.null(props[["--docstyle-suppress-top-spacing"]])) {
    val <- tolower(trimws(props[["--docstyle-suppress-top-spacing"]]))
    config$`suppress-top-spacing` <- val %in% c("true", "yes", "1")
  }

  config
}


#' Parse CSS Margin Shorthand
#'
#' Converts CSS margin shorthand (1-4 values) to individual margins.
#'
#' @param margin_str CSS margin shorthand string.
#' @return List with top, right, bottom, left margins.
#' @keywords internal
parse_margin_shorthand <- function(margin_str) {
  parts <- strsplit(trimws(margin_str), "\\s+")[[1]]

  margins <- switch(as.character(length(parts)),
    "1" = list(top = parts[1], right = parts[1], bottom = parts[1], left = parts[1]),
    "2" = list(top = parts[1], right = parts[2], bottom = parts[1], left = parts[2]),
    "3" = list(top = parts[1], right = parts[2], bottom = parts[3], left = parts[2]),
    "4" = list(top = parts[1], right = parts[2], bottom = parts[3], left = parts[4]),
    list(top = parts[1], right = parts[1], bottom = parts[1], left = parts[1])
  )

  margins
}


#' Merge Page Configuration
#'
#' Merges two page configuration lists, with the overlay taking precedence.
#'
#' @param base Base page configuration.
#' @param overlay Overlay page configuration (takes precedence).
#' @return Merged page configuration.
#' @keywords internal
merge_page_config <- function(base, overlay) {
  if (length(base) == 0) return(overlay)
  if (length(overlay) == 0) return(base)

  result <- base

  for (key in names(overlay)) {
    if (is.list(overlay[[key]]) && is.list(result[[key]])) {
      # Recursively merge nested lists (e.g., margins, line-numbers)
      result[[key]] <- modifyList(result[[key]], overlay[[key]])
    } else {
      result[[key]] <- overlay[[key]]
    }
  }

  result
}

