#' Field Code Parsing and Handling
#'
#' Unified module for parsing Word field codes from XML. Provides:
#' - Core layer: XML extraction, entity handling, category detection
#' - docstyle layer: Schema validation and type-specific handlers
#'
#' Field code categories:
#' - Zotero: `ADDIN ZOTERO_*` (citations, bibliography, preferences)
#' - docstyle: `ADDIN DOCSTYLE` (QMD round-trip metadata)
#' - Word native: `TOC`, `PAGE`, `REF`, etc. (read-only)
#'
#' @name field_codes
#' @keywords internal
NULL


# ═══════════════════════════════════════════════════════════════════════════
# Core Layer: Category-Agnostic Functions
# ═══════════════════════════════════════════════════════════════════════════

#' Check if instruction text is a Zotero field code
#'
#' @param instr Instruction text from field code
#' @return TRUE if Zotero field code, FALSE otherwise
#' @noRd
is_zotero_field <- function(instr) {

  if (is.null(instr) || is.na(instr)) return(FALSE)
  grepl("ADDIN\\s+ZOTERO_", instr)
}

#' Check if instruction text is a docstyle field code
#'
#' @param instr Instruction text from field code
#' @return TRUE if docstyle field code, FALSE otherwise
#' @noRd
is_docstyle_field <- function(instr) {
  if (is.null(instr) || is.na(instr)) return(FALSE)
  grepl("ADDIN\\s+DOCSTYLE", instr)
}

#' Check if instruction text is a Word native field code
#'
#' @param instr Instruction text from field code
#' @return TRUE if Word native field code, FALSE otherwise
#' @noRd
is_word_native_field <- function(instr) {
  if (is.null(instr) || is.na(instr)) return(FALSE)
  # Common Word native field codes (not ADDIN)
  native_patterns <- c(
    "^\\s*TOC\\b",
    "^\\s*PAGE\\b",
    "^\\s*NUMPAGES\\b",
    "^\\s*SECTIONPAGES\\b",
    "^\\s*REF\\b",
    "^\\s*HYPERLINK\\b",
    "^\\s*SEQ\\b",
    "^\\s*STYLEREF\\b"
  )
  any(vapply(native_patterns, function(p) grepl(p, instr), logical(1)))
}

#' Parse instruction text into prefix and content
#'
#' Splits field code instruction into the command prefix and remaining content.
#' For ADDIN fields, extracts the ADDIN type and payload.
#'
#' @param instr Raw instruction text from field code
#' @return List with prefix (e.g., "ADDIN DOCSTYLE") and content (e.g., JSON)
#' @noRd
parse_instr_text <- function(instr) {
  if (is.null(instr) || is.na(instr)) {
    return(list(prefix = NULL, content = NULL))
  }

  instr <- trimws(instr)

  # Handle ADDIN fields
  if (grepl("^ADDIN\\s+", instr)) {
    # Extract ADDIN type (e.g., "ADDIN ZOTERO_ITEM", "ADDIN DOCSTYLE")
    match <- regmatches(instr, regexpr("^ADDIN\\s+\\S+", instr))
    if (length(match) > 0) {
      prefix <- match
      content <- trimws(sub("^ADDIN\\s+\\S+\\s*", "", instr))
      return(list(prefix = prefix, content = content))
    }
  }

  # Handle native Word fields
  match <- regmatches(instr, regexpr("^\\S+", instr))
  if (length(match) > 0) {
    prefix <- match
    content <- trimws(sub("^\\S+\\s*", "", instr))
    return(list(prefix = prefix, content = content))
  }

  list(prefix = instr, content = "")
}

#' Extract field code from fldSimple element
#'
#' Handles self-contained field codes with w:instr attribute.
#'
#' @param node xml2 node for w:fldSimple element
#' @param ns XML namespaces
#' @return List with instr, display_text, or NULL if not a field code
#' @noRd
extract_fld_simple <- function(node, ns) {
  # Get instruction from attribute (try namespaced first, then bare)
  instr <- xml2::xml_attr(node,
    "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}instr")
  if (is.na(instr)) {
    instr <- xml2::xml_attr(node, "instr")
  }
  if (is.na(instr)) return(NULL)


# Extract display text from runs
  runs <- xml2::xml_find_all(node, ".//w:r", ns)
  display_text <- ""
  for (run in runs) {
    t_nodes <- xml2::xml_find_all(run, ".//w:t", ns)
    display_text <- paste0(display_text,
      paste(xml2::xml_text(t_nodes), collapse = ""))
  }

  list(
    instr = instr,
    display_text = display_text
  )
}

#' Initialize field code state machine for fldChar processing
#'
#' Creates a state object for tracking complex field codes that span
#' multiple runs (fldChar begin/separate/end pattern).
#'
#' @return List with tracking state
#' @noRd
new_field_state <- function() {
  list(
    in_field = FALSE,
    instr_text = "",
    past_separate = FALSE,
    display_text = "",
    result = NULL
  )
}

#' Collect field instruction text from run
#'
#' Updates state machine as runs are processed. Call for each run in a
#' paragraph to accumulate field code instruction and detect boundaries.
#'
#' @param state Current state from new_field_state() or previous call
#' @param run Current w:r node
#' @param ns XML namespaces
#' @return Updated state
#' @noRd
collect_field_instr <- function(state, run, ns) {
  # Check for fldChar boundary marker
  fld_char <- xml2::xml_find_first(run, ".//w:fldChar", ns)
  if (!inherits(fld_char, "xml_missing")) {
    fld_type <- xml2::xml_attr(fld_char, "fldCharType")

    if (fld_type == "begin") {
      state$in_field <- TRUE
      state$instr_text <- ""
      state$past_separate <- FALSE
      state$display_text <- ""
      state$result <- NULL
      return(state)
    } else if (fld_type == "separate") {
      # Instruction collection complete; display text follows
      state$past_separate <- TRUE
      return(state)
    } else if (fld_type == "end") {
      # Field code complete
      state$result <- list(
        instr = state$instr_text,
        display_text = state$display_text
      )
      state$in_field <- FALSE
      state$past_separate <- FALSE
      return(state)
    }
  }

  # Collect instrText when between begin and separate
  if (state$in_field && !state$past_separate) {
    instr_nodes <- xml2::xml_find_all(run, ".//w:instrText", ns)
    state$instr_text <- paste0(state$instr_text,
      paste(xml2::xml_text(instr_nodes), collapse = ""))
  }

  # Collect display text when past separate
  if (state$in_field && state$past_separate) {
    t_nodes <- xml2::xml_find_all(run, ".//w:t", ns)
    state$display_text <- paste0(state$display_text,
      paste(xml2::xml_text(t_nodes), collapse = ""))
  }

  state
}


# ═══════════════════════════════════════════════════════════════════════════
# docstyle Layer: Schema Validation and Type Handlers
# ═══════════════════════════════════════════════════════════════════════════

#' docstyle field code schema definitions
#'
#' Defines required and optional fields for each docstyle field code type.
#' @noRd
docstyle_schemas <- list(
  char = list(
    required = c("type", "class", "source"),
    optional = c("version")
  ),
  div = list(
    required = c("type", "name"),
    optional = c("version")
  ),
  list = list(
    required = c("type", "class"),
    optional = c("version", "start")
  ),
  section = list(
    required = c("type", "class"),
    optional = c("version", "page-break", "line-numbers")
  ),
  table = list(
    required = c("type", "class"),
    optional = c("version", "widths", "width", "font-size",
                 "header-bold", "header-shading", "label")
  ),
  figure = list(
    required = c("type", "id"),
    optional = c("version", "docpr_id", "width", "align", "wrap", "original_path", "alt")
  ),
  float = list(
    required = c("type", "class"),
    optional = c("version", "vertical_anchor", "horizontal_anchor",
                 "position_y", "position_x", "float_width",
                 "wrap_style", "wrap_side", "wrap_distance", "adjacent")
  ),
  anchor = list(
    required = c("type", "class"),
    optional = c("version", "content_hint", "vertical_anchor", "horizontal_anchor",
                 "position_y", "position_x", "float_width",
                 "wrap_style", "wrap_side", "wrap_distance",
                 "z_layer", "adjacent", "content_mode",
                 "caption_y", "image_height")
  )
)

#' Current docstyle schema version
#' v2: R-First Assembly - Lua emits text markers, R builds sectPr
#' @noRd
DOCSTYLE_SCHEMA_VERSION <- 3L


# ═══════════════════════════════════════════════════════════════════════════
# Shared Schema: Single source of truth for field code definitions
# ═══════════════════════════════════════════════════════════════════════════

#' Load the shared field code schema
#'
#' Reads the JSON schema from inst/schema/docstyle-field-codes.json.
#' The schema is cached after first load for performance.
#'
#' @return Parsed schema as a list, or NULL if not found
#' @noRd
load_field_code_schema <- function() {

  # Check cache in package namespace

  if (!is.null(.docstyle_schema_cache$schema)) {
    return(.docstyle_schema_cache$schema)
  }

  # Try to find the schema file

  schema_path <- system.file(
    "schema", "docstyle-field-codes.json",
    package = "docstyle"
  )


  # Fallback for development (not installed)
  if (schema_path == "") {
    dev_path <- file.path(
      system.file(package = "docstyle"),
      "..", "..", "inst", "schema", "docstyle-field-codes.json"
    )
    if (file.exists(dev_path)) {
      schema_path <- dev_path
    }
  }

  # Development fallback: look relative to package root

  if (schema_path == "" || !file.exists(schema_path)) {
    # Try finding it relative to the R/ directory
    r_dir <- system.file("R", package = "docstyle")
    if (r_dir != "") {
      dev_path <- file.path(dirname(dirname(r_dir)), "inst", "schema",
                            "docstyle-field-codes.json")
      if (file.exists(dev_path)) {
        schema_path <- dev_path
      }
    }
  }

  if (schema_path == "" || !file.exists(schema_path)) {
    # Return NULL - callers should fall back to hardcoded defaults
    return(NULL)
  }

  tryCatch({
    schema <- jsonlite::fromJSON(schema_path, simplifyVector = FALSE)
    .docstyle_schema_cache$schema <- schema
    schema
  }, error = function(e) {
    warning("Failed to load field code schema: ", e$message, call. = FALSE)
    NULL
  })
}

# Package-level cache for schema (populated on first access)
.docstyle_schema_cache <- new.env(parent = emptyenv())


# ═══════════════════════════════════════════════════════════════════════════
# Semantic Registries: Fallback definitions if schema not available
# ═══════════════════════════════════════════════════════════════════════════

#' Fallback char class registry (used if schema file not found)
#' @noRd
.docstyle_char_fallback <- list(
  date = list(
    word_style = "Date",
    harvests_to = "version_summary.date"
  ),
  version = list(
    word_style = "Version",
    harvests_to = "version_summary.version"
  ),
  sc = list(word_style = "SmallCaps"),
  author = list(word_style = "Author"),
  affiliation = list(word_style = "Affiliation")
)

#' Fallback div registry (used if schema file not found)
#' @noRd
.docstyle_div_fallback <- list(
  toc = list(
    div_open = "::: toc",
    div_close = ":::"
  ),
  `version-history` = list(
    div_open = "::: version-history",
    div_close = ":::"
  ),
  `author-plate` = list(
    div_open = "::: author-plate",
    div_close = ":::"
  ),
  abstract = list(
    div_open = "::: docstyle-abstract",
    div_close = ":::"
  )
)

#' Fallback list class registry (used if schema file not found)
#' @noRd
.docstyle_list_fallback <- list(
  `list-alpha` = list(
    div_open = "::: {.list-alpha}",
    div_close = ":::"
  ),
  `list-roman` = list(
    div_open = "::: {.list-roman}",
    div_close = ":::"
  )
)

#' Fallback table class registry (used if schema file not found)
#' @noRd
.docstyle_table_fallback <- list(
  `table-formal` = list(
    div_open = "::: {.table-formal}",
    div_close = ":::"
  ),
  `table-grid` = list(
    div_open = "::: {.table-grid}",
    div_close = ":::"
  )
)


#' Get char class definition from schema or fallback
#'
#' @param class Character class name (e.g., "date", "sc")
#' @return List with word_style, harvests_to (if applicable), or NULL if unknown
#' @noRd
get_char_class_def <- function(class) {
  schema <- load_field_code_schema()
  if (!is.null(schema) && !is.null(schema$char_classes[[class]])) {
    return(schema$char_classes[[class]])
  }
  .docstyle_char_fallback[[class]]
}

#' Get div definition from schema or fallback
#'
#' @param name Div name (e.g., "toc", "version-history")
#' @return List with div_open, div_close, or NULL if unknown
#' @noRd
get_div_def <- function(name) {
  schema <- load_field_code_schema()
  if (!is.null(schema) && !is.null(schema$div_types[[name]])) {
    return(schema$div_types[[name]])
  }
  .docstyle_div_fallback[[name]]
}

#' Get list class definition from schema or fallback
#'
#' @param class List class name (e.g., "list-alpha", "list-roman")
#' @return List with div_open, div_close, or NULL if unknown
#' @noRd
get_list_class_def <- function(class) {
  schema <- load_field_code_schema()
  if (!is.null(schema) && !is.null(schema$list_classes[[class]])) {
    return(schema$list_classes[[class]])
  }
  .docstyle_list_fallback[[class]]
}

#' Get table class definition from schema or fallback
#'
#' @param class Table class name (e.g., "table-formal", "table-grid")
#' @return List with div_open, div_close, or NULL if unknown
#' @noRd
get_table_class_def <- function(class) {
  schema <- load_field_code_schema()
  if (!is.null(schema) && !is.null(schema$table_classes[[class]])) {
    return(schema$table_classes[[class]])
  }
  .docstyle_table_fallback[[class]]
}

#' Build nested metadata structure from dot-path
#'
#' Converts a dot-separated path like "version_summary.date" and a value
#' into a nested list structure suitable for YAML harvesting.
#'
#' @param path Dot-separated path (e.g., "version_summary.date")
#' @param value Value to store at the path
#' @return Nested list structure (e.g., list(version_summary = list(date = value)))
#' @noRd
build_harvest_path <- function(path, value) {
  parts <- strsplit(path, "\\.")[[1]]
  result <- value
  for (part in rev(parts)) {
    result <- setNames(list(result), part)
  }
  result
}


#' Parse docstyle field code payload
#'
#' Extracts and validates JSON payload from ADDIN DOCSTYLE instruction.
#' Handles XML entity unescaping before JSON parsing.
#'
#' @param instr Full instruction text (including "ADDIN DOCSTYLE" prefix)
#' @param strict If TRUE, return NULL for unknown schema versions (default TRUE)
#' @return Parsed and validated payload list, or NULL if invalid
#' @noRd
parse_docstyle_payload <- function(instr, strict = TRUE) {
  if (!is_docstyle_field(instr)) return(NULL)

  # Extract JSON portion after "ADDIN DOCSTYLE"
  json_str <- sub(".*ADDIN\\s+DOCSTYLE\\s*", "", trimws(instr))

  # Unescape XML entities (use existing utility from utils.R)
  json_str <- unescape_xml_entities(json_str)

  # Parse JSON
  payload <- tryCatch(
    jsonlite::fromJSON(json_str, simplifyVector = FALSE),
    error = function(e) NULL
  )

  if (is.null(payload)) return(NULL)

  # Validate against schema
  validate_docstyle_schema(payload, strict = strict)
}

#' Validate docstyle payload against schema
#'
#' Checks that payload has required fields for its type and compatible version.
#'
#' @param payload Parsed JSON list
#' @param strict If TRUE, return NULL for unknown versions
#' @return Validated payload, or NULL if invalid
#' @noRd
validate_docstyle_schema <- function(payload, strict = TRUE) {
  # Must have type field
  if (is.null(payload$type)) return(NULL)

  # Get schema for this type
  schema <- docstyle_schemas[[payload$type]]
  if (is.null(schema)) return(NULL)  # Unknown type

  # Check version compatibility
  version <- payload$version %||% 1L
  if (version > DOCSTYLE_SCHEMA_VERSION) {
    if (strict) {
      warning(sprintf(
        "Unknown docstyle schema version %s for type '%s'; skipping",
        version, payload$type
      ), call. = FALSE)
      return(NULL)
    }
  }

  # Check required fields
  for (field in schema$required) {
    if (is.null(payload[[field]])) return(NULL)
  }

  payload
}

#' Dispatch to docstyle type handler
#'
#' Routes parsed payload to appropriate handler based on type field.
#'
#' @param payload Validated docstyle payload
#' @param context Optional context (e.g., display_text for char type)
#' @return Handler result list, or NULL if no handler
#' @noRd
dispatch_docstyle_handler <- function(payload, context = list()) {
  if (is.null(payload) || is.null(payload$type)) return(NULL)

  handler <- switch(payload$type,
    "char"    = handle_docstyle_char,
    "div"     = handle_docstyle_div,
    "list"    = handle_docstyle_list,
    "section" = handle_docstyle_section,
    "table"   = handle_docstyle_table,
    "figure"  = handle_docstyle_figure,
    "anchor"  = handle_docstyle_anchor,
    "float"   = handle_docstyle_anchor,  # backward compat
    NULL
  )

  if (is.null(handler)) return(NULL)
  handler(payload, context)
}

#' Handle char-type docstyle field code
#'
#' Character-level field codes store original QMD source for round-trip
#' restoration (e.g., shortcodes, inline styles).
#'
#' Uses the char class registry to determine metadata harvesting behavior.
#' Classes with `harvests_to` defined will extract the display text to the
#' specified metadata path.
#'
#' @param payload Validated payload with type="char"
#' @param context List with optional display_text
#' @return List with type, qmd_source, class, skip_display, and optionally
#'   harvested_metadata (nested list structure for YAML)
#' @noRd
handle_docstyle_char <- function(payload, context = list()) {
  result <- list(
    type = "char",
    qmd_source = payload$source,
    class = payload$class,
    display_text = context$display_text,
    skip_display = TRUE  # Signal to emit source, skip display text
  )

  # Schema-driven metadata extraction using registry

  class_def <- get_char_class_def(payload$class)
  if (!is.null(class_def) && !is.null(class_def$harvests_to)) {
    result$harvested_metadata <- build_harvest_path(
      class_def$harvests_to,
      context$display_text
    )
  }

  result
}

#' Handle div-type docstyle field code
#'
#' Block-level field codes mark generated content (TOC, version-history,
#' author-plate) for placeholder replacement during harvest.
#'
#' Uses the div registry to determine the div fence format.
#'
#' @param payload Validated payload with type="div"
#' @param context Unused
#' @return List with type, name, div_open, div_close
#' @noRd
handle_docstyle_div <- function(payload, context = list()) {
  name <- payload$name

  # Use registry for known divs, fallback to default format
  div_def <- get_div_def(name)
  if (!is.null(div_def)) {
    div_open <- div_def$div_open
    div_close <- div_def$div_close
  } else {
    # Default format for unknown div names
    div_open <- paste0("::: ", name)
    div_close <- ":::"
  }

  list(
    type = "div",
    name = name,
    div_open = div_open,
    div_close = div_close
  )
}

#' Handle list-type docstyle field code
#'
#' List field codes wrap CSS-classed lists for round-trip styling
#' preservation (e.g., .list-alpha, .list-roman).
#'
#' @param payload Validated payload with type="list"
#' @param context Unused
#' @return List with type, class, start, div_open, div_close
#' @noRd
handle_docstyle_list <- function(payload, context = list()) {
  div_open <- paste0("::: {.", payload$class)

  # Add start attribute if not default (1)
  if (!is.null(payload$start) && payload$start != 1) {
    div_open <- paste0(div_open, ' start="', payload$start, '"')
  }
  div_open <- paste0(div_open, "}")

  list(
    type = "list",
    class = payload$class,
    start = payload$start,
    div_open = div_open,
    div_close = ":::"
  )
}

#' Append payload attributes to a div_open string
#'
#' Shared helper for building div-fence attribute strings from field code
#' payloads. Skips specified keys and appends remaining string-valued attributes.
#'
#' @param div_open Current div_open string (without closing brace)
#' @param payload Field code payload list
#' @param skip_keys Character vector of keys to skip
#' @return Updated div_open string (still without closing brace)
#' @noRd
append_payload_attrs <- function(div_open, payload, skip_keys) {
  for (key in names(payload)) {
    if (key %in% skip_keys) next
    val <- payload[[key]]
    # Coerce logical/numeric to character (JSON parsing may produce these)
    if (is.logical(val)) {
      val <- tolower(as.character(val))
    } else if (is.numeric(val)) {
      val <- as.character(val)
    }
    if (is.character(val) && nzchar(val)) {
      div_open <- paste0(div_open, sprintf(' %s="%s"', key, val))
    }
  }
  div_open
}

#' Handle section-type docstyle field code
#'
#' Section field codes wrap page/section breaks with metadata for
#' line numbering and page break settings.
#'
#' @param payload Validated payload with type="section"
#' @param context Unused
#' @return List with type, class, page_break, line_numbers, div_open, div_close
#' @noRd
handle_docstyle_section <- function(payload, context = list()) {
  div_open <- paste0("::: {.", payload$class)

  # Add page-break attribute if true
  if (isTRUE(payload[["page-break"]])) {
    div_open <- paste0(div_open, ' page-break="true"')
  }

  # Add line-numbers attribute if present
  if (!is.null(payload[["line-numbers"]])) {
    div_open <- paste0(div_open, ' line-numbers="', payload[["line-numbers"]], '"')
  }

  # Pass through all remaining payload attributes (footer-*, header-*,
  # page-start, etc.) so they round-trip through harvest → render
  div_open <- append_payload_attrs(div_open, payload,
    c("type", "version", "class", "page-break", "line-numbers"))

  div_open <- paste0(div_open, "}")

  list(
    type = "section",
    class = payload$class,
    page_break = isTRUE(payload[["page-break"]]),
    line_numbers = payload[["line-numbers"]],
    div_open = div_open,
    div_close = ":::"
  )
}

#' Handle table-type docstyle field code
#'
#' Table field codes wrap CSS-styled tables for round-trip preservation.
#' All payload attributes beyond type/version/class are passed through
#' as div-fence attributes, enabling forward compatibility with new
#' CSS properties.
#'
#' @param payload Validated payload with type="table"
#' @param context Unused
#' @return List with type, class, div_open, div_close
#' @noRd
handle_docstyle_table <- function(payload, context = list()) {
  div_open <- paste0("::: {.", payload$class)

  # Pass through ALL payload attributes (except type/version/class)
  # This makes the handler forward-compatible: new attributes added
  # on the Lua side don't require R changes
  div_open <- append_payload_attrs(div_open, payload,
    c("type", "version", "class"))

  div_open <- paste0(div_open, "}")

  list(
    type = "table",
    class = payload$class,
    div_open = div_open,
    div_close = ":::"
  )
}


#' Handle figure-type docstyle field code
#'
#' Figure field codes wrap image + caption pairs for round-trip preservation.
#' The payload carries the QMD figure id and optional attributes (width, align,
#' wrap, original_path). On re-harvest the id is restored from the payload
#' rather than auto-generated, preserving author-assigned cross-reference labels.
#'
#' @param payload Validated payload with type="figure"
#' @param context Unused
#' @return List with type, id, div_open, div_close
#' @noRd
handle_docstyle_figure <- function(payload, context = list()) {
  fig_id  <- payload$id %||% "fig-unknown"

  div_open <- paste0("::: {#", fig_id, " .figure")

  # Pass through optional attributes (width, align, wrap, original_path)
  div_open <- append_payload_attrs(div_open, payload,
    c("type", "version", "id", "docpr_id"))

  div_open <- paste0(div_open, "}")

  list(
    type          = "figure",
    id            = fig_id,
    docpr_id      = payload$docpr_id,
    original_path = payload$original_path,
    div_open      = div_open,
    div_close     = ":::"
  )
}


#' Handle anchor-type docstyle field code
#'
#' Reconstructs a fenced div from an anchor (or legacy float) field code
#' payload. Non-default positioning attributes are included as div-fence
#' attributes for round-trip fidelity.
#'
#' @param payload Validated payload with type="anchor" or type="float"
#' @param context Unused
#' @return List with type, class, div_open, div_close
#' @noRd
handle_docstyle_anchor <- function(payload, context = list()) {
  anchor_class <- payload$class %||% "column-margin"


  # Build div attributes from non-default positioning values
  div_attrs <- character(0)
  if (!is.null(payload$vertical_anchor) && payload$vertical_anchor != "text")
    div_attrs <- c(div_attrs, paste0('vertical-anchor="', payload$vertical_anchor, '"'))
  if (!is.null(payload$horizontal_anchor) && payload$horizontal_anchor != "margin")
    div_attrs <- c(div_attrs, paste0('horizontal-anchor="', payload$horizontal_anchor, '"'))
  if (!is.null(payload$position_y) && payload$position_y != "0")
    div_attrs <- c(div_attrs, paste0('position-y="', payload$position_y, '"'))
  if (!is.null(payload$position_x) && payload$position_x != "0")
    div_attrs <- c(div_attrs, paste0('position-x="', payload$position_x, '"'))
  if (!is.null(payload$float_width))
    div_attrs <- c(div_attrs, paste0('float-width="', payload$float_width, '"'))
  if (!is.null(payload$z_layer) && payload$z_layer != "front")
    div_attrs <- c(div_attrs, paste0('z-layer="', payload$z_layer, '"'))
  if (!is.null(payload$content_mode) && payload$content_mode != "auto")
    div_attrs <- c(div_attrs, paste0('content-mode="', payload$content_mode, '"'))
  if (!is.null(payload$adjacent))
    div_attrs <- c(div_attrs, paste0('adjacent="', payload$adjacent, '"'))

  if (length(div_attrs) > 0) {
    div_open <- paste0("::: {.", anchor_class, " ", paste(div_attrs, collapse = " "), "}")
  } else {
    div_open <- paste0("::: {.", anchor_class, "}")
  }

  list(
    type = "anchor",
    class = anchor_class,
    div_open = div_open,
    div_close = ":::"
  )
}

