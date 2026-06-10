#' Generate Reference Document from docstyle Configuration
#'
#' Creates a Word reference document by reading the `docstyle:` section from
#' a Quarto YAML configuration. This enables "style-as-code" workflows where
#' the reference.docx is generated programmatically rather than manually edited.
#'
#' @param config_path Path to `_quarto.yml` or a QMD file with YAML header.
#'   Can also be a list containing the docstyle configuration directly.
#' @param output_path Where to save the generated reference.docx. If NULL,
#'   saves to a temp file and returns the path.
#' @param base_doc Path to a base reference.docx to start from. If NULL,
#'   uses Pandoc's default reference document.
#'
#' @return Path to the generated reference.docx (invisibly).
#'
#' @details
#' ## Configuration
#'
#' The `docstyle:` section supports:
#'
#' ```yaml
#' docstyle:
#'   css: styles.css       # CSS file for typography styles
#'   page:
#'     size: letter        # letter | a4 | legal
#'     orientation: portrait
#'     margins:
#'       top: 1in
#'       bottom: 1in
#'       left: 1in
#'       right: 1in
#'   footer:
#'     enabled: true
#'     content: "Page {page}"
#'     align: center
#'     # Or multi-position:
#'     left: "Document Title"
#'     right: "Page {page} of {pages}"
#' ```
#'
#' ## CSS Properties
#'
#' The following CSS properties are mapped to Word styles:
#' - `font-family` → `w:rFonts`
#' - `font-size` → `w:sz` (converted to half-points)
#' - `font-weight` → `w:b` (600+ = bold)
#' - `font-style` → `w:i` (italic)
#' - `color` → `w:color`
#' - `font` shorthand → expands to above
#'
#' @examples
#' \dontrun{
#' # Generate from _quarto.yml
#' generate_reference_doc("_quarto.yml", "reference.docx")
#'
#' # Generate from inline config
#' config <- list(
#'   docstyle = list(
#'     css = "styles.css",
#'     page = list(size = "letter", margins = list(top = "1in")),
#'     footer = list(enabled = TRUE, content = "Page {page}")
#'   )
#' )
#' generate_reference_doc(config)
#' }
#'
#' @export
generate_reference_doc <- function(config_path,
                                   output_path = NULL,
                                   base_doc = NULL) {

  # 1. Parse configuration
  config <- parse_docstyle_config(config_path)

  if (is.null(config$docstyle)) {
    stop("No 'docstyle:' section found in configuration")
  }

  ds <- config$docstyle

  # 2. Get base document
  # Priority: function arg > config base-doc > docstyle minimal template
  if (is.null(base_doc) && !is.null(ds$`base-doc`)) {
    base_doc <- ds$`base-doc`
  }

  if (!is.null(base_doc) && base_doc == "pandoc") {
    # Explicit opt-in to Pandoc's default reference
    base_doc <- get_pandoc_reference_doc()
    message("[generate-reference] Using Pandoc default reference.docx")
  } else if (!is.null(base_doc)) {
    # Resolve relative path for file-based base-doc
    if (!is.list(config_path) && file.exists(config_path)) {
      resolved <- file.path(dirname(config_path), base_doc)
      if (file.exists(resolved)) base_doc <- resolved
    }
    if (!file.exists(base_doc)) {
      stop("Base reference document not found: ", base_doc)
    }
    message("[generate-reference] Template mode: using ", basename(base_doc))
  } else {
    # Default: build minimal reference from docstyle templates
    base_doc <- build_minimal_reference()
  }

  # 3. Copy to output location
  if (is.null(output_path)) {
    output_path <- tempfile(fileext = ".docx")
  }

  file.copy(base_doc, output_path, overwrite = TRUE)

  # 4. Modify the document
  doc <- officer::read_docx(output_path)

  # Load CSS styles if specified
  # Supports single path or array of paths for layered styles
  css_styles <- NULL
  css_page_config <- NULL
  if (!is.null(ds$css)) {
    css_paths <- ds$css
    # Resolve relative paths if config_path is a file
    if (!is.list(config_path) && file.exists(config_path)) {
      config_dir <- dirname(config_path)
      css_paths <- vapply(css_paths, function(p) {
        if (file.exists(p)) p else file.path(config_dir, p)
      }, character(1))
    }
    # read_css handles both single path and vector of paths
    css_styles <- read_css(css_paths)
    # Extract @page configuration from CSS
    css_page_config <- attr(css_styles, "page")
  }

  # Inject CSS styles into Word styles.xml
  if (!is.null(css_styles)) {
    # In template mode, collect template style IDs to skip cascade
    template_style_ids <- NULL
    if (!is.null(ds$`base-doc`) && ds$`base-doc` != "pandoc") {
      template_style_ids <- get_template_style_ids(base_doc)
    }
    doc <- inject_css_styles(doc, css_styles, toc_config = ds$toc,
                             template_styles = template_style_ids)
  }

  # Determine page configuration: CSS @page takes precedence over YAML
  page_config <- NULL
  if (!is.null(css_page_config)) {
    page_config <- css_page_config
    if (!is.null(ds$page)) {
      message("[generate-reference] Using @page rules from CSS (YAML page: config is deprecated)")
    }
  } else if (!is.null(ds$page)) {
    page_config <- ds$page
  }

  # Apply page settings
  if (!is.null(page_config)) {
    doc <- apply_page_settings(doc, page_config)

    # Apply line numbers to the reference doc's final sectPr.
    # The reference doc's sectPr becomes Pandoc's final body sectPr, which
    # defines properties for the LAST section. When using section breaks
    # (e.g., front matter → body), the last section is typically a named
    # section like "body". Use its line numbers if the default page doesn't
    # specify any, so that the Lua filter doesn't need to inject a separate
    # sectPr paragraph (which breaks page breaks in Word).
    #
    # NOTE: When wrapping divs are used (non-empty section divs with closing
    # sectPr), the finisher (finalize_docx) removes these line numbers from
    # the body sectPr post-render. This is correct because the wrapping div's
    # closing sectPr scopes line numbers to the wrapped content only.
    ln_config <- page_config$`line-numbers`

    # If default page has no line numbers, check named sections
    if (is.null(ln_config) || identical(ln_config$enabled, FALSE)) {
      # Look for a named section with line numbers (prefer "body" if it exists)
      named <- page_config$named
      if (!is.null(named)) {
        body_ln <- named$body$`line-numbers`
        if (!is.null(body_ln) && isTRUE(body_ln$enabled)) {
          ln_config <- body_ln
        }
      }
    }

    if (!is.null(ln_config)) {
      doc <- apply_line_numbers(doc, ln_config)
    }
  }

  # Compute tab stops from page config for footer/header alignment
  hf_tab_stops <- compute_hf_tab_stops(page_config)

  # Apply footer
  if (!is.null(ds$footer) && isTRUE(ds$footer$enabled)) {
    doc <- apply_footer(doc, ds$footer, css_styles, tab_stops = hf_tab_stops)
  }

  # Apply header
  if (!is.null(ds$header) && isTRUE(ds$header$enabled)) {
    doc <- apply_header(doc, ds$header, css_styles, tab_stops = hf_tab_stops)
  }

  # 5. Save
  print(doc, target = output_path)

  message("Generated reference document: ", output_path)
  invisible(output_path)
}


#' @rdname generate_reference_doc
#' @keywords internal
#' @export
generate_reference_doc_v2 <- function(config_path,
                                       output_path = NULL,
                                       base_doc = NULL) {
 .Deprecated("generate_reference_doc")
  generate_reference_doc(config_path, output_path, base_doc)
}


#' Parse docstyle Configuration
#'
#' @param config_path Path to YAML file or a list
#' @return Parsed configuration list
#' @keywords internal
parse_docstyle_config <- function(config_path) {
  if (is.list(config_path)) {
    return(config_path)
  }

  if (!file.exists(config_path)) {
    stop("Configuration file not found: ", config_path)
  }

  # Check if it's a QMD file (need to extract YAML header)
  if (grepl("\\.qmd$", config_path, ignore.case = TRUE)) {
    lines <- readLines(config_path, warn = FALSE)
    # Find YAML delimiters
    yaml_start <- which(lines == "---")[1]
    yaml_end <- which(lines == "---")[2]
    if (is.na(yaml_start) || is.na(yaml_end)) {
      stop("Could not find YAML header in QMD file")
    }
    yaml_content <- paste(lines[(yaml_start + 1):(yaml_end - 1)], collapse = "\n")
    return(yaml::yaml.load(yaml_content))
  }

  # Regular YAML file
  yaml::read_yaml(config_path)
}


#' Get Pandoc's Default Reference Document
#'
#' Extracts Pandoc's built-in reference.docx to a temp location.
#'
#' @return Path to the extracted reference.docx
#' @keywords internal
get_pandoc_reference_doc <- function() {
  cache_dir <- file.path(tempdir(), "docstyle_cache")
  if (!dir.exists(cache_dir)) {
    dir.create(cache_dir, recursive = TRUE)
  }

  ref_path <- file.path(cache_dir, "pandoc_reference.docx")

  if (!file.exists(ref_path)) {
    result <- system2(
      "pandoc",
      c("--print-default-data-file", "reference.docx"),
      stdout = ref_path,
      stderr = FALSE
    )
    if (result != 0 || !file.exists(ref_path)) {
      stop("Failed to extract Pandoc reference.docx")
    }
  }

  ref_path
}


#' Build Minimal Reference Document from docstyle Templates
#'
#' Assembles a reference.docx from the OOXML template files shipped with
#' the docstyle package. All styles have empty pPr/rPr so CSS is the sole
#' source of truth for formatting.
#'
#' @return Path to the generated reference.docx
#' @keywords internal
build_minimal_reference <- function() {
  cache_dir <- file.path(tempdir(), "docstyle_cache")
  if (!dir.exists(cache_dir)) {
    dir.create(cache_dir, recursive = TRUE)
  }

  ref_path <- file.path(cache_dir, "docstyle_reference.docx")

  # Cache: templates are static within a package version / R session
  if (file.exists(ref_path)) {
    return(ref_path)
  }

  # Locate template directory
  template_dir <- system.file("templates/reference", package = "docstyle")
  if (template_dir == "" || !dir.exists(template_dir)) {
    # Development mode: try inst/ directly
    dev_path <- file.path(getwd(), "inst/templates/reference")
    if (dir.exists(dev_path)) {
      template_dir <- dev_path
    } else {
      stop("docstyle reference templates not found. ",
           "Install the docstyle package or run from the package root.")
    }
  }

  # Build zip from template files
  # Include dotfiles (e.g., _rels/.rels) but exclude .DS_Store
  old_wd <- getwd()
  on.exit(setwd(old_wd), add = TRUE)
  setwd(template_dir)

  # Collect all files including those starting with dots
  all_files <- list.files(".", recursive = TRUE, all.files = TRUE,
                          no.. = TRUE)
  # Exclude .DS_Store
  all_files <- all_files[!grepl("\\.DS_Store$", all_files)]

  # Validate required OOXML parts exist before zipping
  required_parts <- c("[Content_Types].xml", "word/document.xml",
                      "word/styles.xml", "_rels/.rels")
  missing <- setdiff(required_parts, all_files)
  if (length(missing) > 0) {
    stop("Template directory is missing required files: ",
         paste(missing, collapse = ", "),
         ". The docstyle installation may be incomplete.")
  }

  result <- utils::zip(ref_path, files = all_files, flags = "-q")

  if (result != 0 || !file.exists(ref_path)) {
    stop("Failed to build minimal reference.docx from templates")
  }

  message("[generate-reference] Built minimal reference.docx from docstyle templates")
  ref_path
}


#' Apply Page Settings to Document
#'
#' Sets page size, orientation, and margins.
#'
#' @param doc officer document
#' @param page_config Page configuration list
#' @return Modified document
#' @keywords internal
apply_page_settings <- function(doc, page_config) {
  # Access document XML
  xml <- doc$doc_obj$get()
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  sectPr <- xml2::xml_find_first(body, "w:sectPr", ns = ns)

  if (inherits(sectPr, "xml_missing")) {
    sectPr <- xml2::xml_add_child(body, "w:sectPr")
  }

  # Page size
  size <- page_config$size %||% "letter"
  orientation <- page_config$orientation %||% "portrait"

  dims <- get_page_dimensions(size, orientation)

  pgSz <- xml2::xml_find_first(sectPr, "w:pgSz", ns = ns)
  if (inherits(pgSz, "xml_missing")) {
    pgSz <- xml2::xml_add_child(sectPr, "w:pgSz", .where = 0)
  }
  xml2::xml_set_attr(pgSz, "w:w", dims$width)
  xml2::xml_set_attr(pgSz, "w:h", dims$height)
  if (orientation == "landscape") {
    xml2::xml_set_attr(pgSz, "w:orient", "landscape")
  }

  # Margins
  if (!is.null(page_config$margins)) {
    m <- page_config$margins
    pgMar <- xml2::xml_find_first(sectPr, "w:pgMar", ns = ns)
    if (inherits(pgMar, "xml_missing")) {
      pgMar <- xml2::xml_add_child(sectPr, "w:pgMar")
    }

    if (!is.null(m$top)) xml2::xml_set_attr(pgMar, "w:top", css_to_twips(m$top))
    if (!is.null(m$bottom)) xml2::xml_set_attr(pgMar, "w:bottom", css_to_twips(m$bottom))
    if (!is.null(m$left)) xml2::xml_set_attr(pgMar, "w:left", css_to_twips(m$left))
    if (!is.null(m$right)) xml2::xml_set_attr(pgMar, "w:right", css_to_twips(m$right))
    if (!is.null(m$gutter)) xml2::xml_set_attr(pgMar, "w:gutter", css_to_twips(m$gutter))

    # Header/footer distance defaults
    xml2::xml_set_attr(pgMar, "w:header", css_to_twips("0.5in"))
    xml2::xml_set_attr(pgMar, "w:footer", css_to_twips("0.5in"))
  }

  doc
}


#' Get Page Dimensions in Twips
#'
#' @param size Page size name (letter, a4, legal)
#' @param orientation portrait or landscape
#' @return List with width and height in twips
#' @keywords internal
get_page_dimensions <- function(size, orientation = "portrait") {
  # Standard sizes in twips (1 inch = 1440 twips)
  sizes <- list(
    letter = list(width = 12240, height = 15840),  # 8.5 x 11 in
    a4 = list(width = 11906, height = 16838),       # 210 x 297 mm
    legal = list(width = 12240, height = 20160)     # 8.5 x 14 in
  )

  dims <- sizes[[tolower(size)]]
  if (is.null(dims)) {
    warning("Unknown page size '", size, "', using letter")
    dims <- sizes$letter
  }

  # Swap for landscape
 if (tolower(orientation) == "landscape") {
    dims <- list(width = dims$height, height = dims$width)
  }

  dims
}


#' Apply Line Numbers to Document
#'
#' Configures line numbering for the document by adding `<w:lnNumType>`
#' element to the section properties.
#'
#' @param doc officer document
#' @param line_numbers_config Line numbers configuration list with:
#'   - `enabled`: TRUE to enable line numbering
#'   - `restart`: When to restart numbering: "page", "section", or "continuous"
#'   - `count-by`: Number interval (1 = every line, 5 = every 5th line)
#'   - `distance`: Distance from text edge (CSS units like "0.25in")
#'   - `start`: Starting line number (default 1)
#' @return Modified document
#' @keywords internal
#'
#' @details
#' Word uses the `<w:lnNumType>` element within `<w:sectPr>` to configure
#' line numbering. Attributes:
#' - `w:countBy`: Line number interval (default 1)
#' - `w:start`: Starting number (default 1)
#' - `w:distance`: Distance from text in twips
#' - `w:restart`: "newPage", "newSection", or "continuous"
#'
#' Example YAML configuration:
#' ```yaml
#' docstyle:
#'   page:
#'     line-numbers:
#'       enabled: true
#'       restart: page      # page | section | continuous
#'       count-by: 1        # every line (or 5 for every 5th)
#'       distance: 0.25in   # from text edge
#' ```
apply_line_numbers <- function(doc, line_numbers_config) {
  if (!isTRUE(line_numbers_config$enabled)) {
    return(doc)
  }

  # Access document XML
  xml <- doc$doc_obj$get()
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  sectPr <- xml2::xml_find_first(body, "w:sectPr", ns = ns)

  if (inherits(sectPr, "xml_missing")) {
    sectPr <- xml2::xml_add_child(body, "w:sectPr")
  }

  # Find or create lnNumType element
  lnNumType <- xml2::xml_find_first(sectPr, "w:lnNumType", ns = ns)
  if (inherits(lnNumType, "xml_missing")) {
    # Insert after pgMar if present, otherwise at end
    pgMar <- xml2::xml_find_first(sectPr, "w:pgMar", ns = ns)
    if (!inherits(pgMar, "xml_missing")) {
      lnNumType <- xml2::xml_add_sibling(pgMar, "w:lnNumType", .where = "after")
    } else {
      lnNumType <- xml2::xml_add_child(sectPr, "w:lnNumType")
    }
  }

  # Set count-by (interval) - default is 1 (every line)
  count_by <- line_numbers_config$`count-by` %||% 1
  xml2::xml_set_attr(lnNumType, "w:countBy", as.character(count_by))

  # Set start number - default is 1
 start_num <- line_numbers_config$start %||% 1
  xml2::xml_set_attr(lnNumType, "w:start", as.character(start_num))

  # Set restart behaviour
  # YAML values: "page", "section", "continuous"
  # Word values: "newPage", "newSection", "continuous"
  restart <- tolower(line_numbers_config$restart %||% "page")
  restart_val <- switch(restart,
    "page" = "newPage",
    "section" = "newSection",
    "continuous" = "continuous",
    "newPage"  # default
 )
  xml2::xml_set_attr(lnNumType, "w:restart", restart_val)

  # Set distance from text (in twips)
  if (!is.null(line_numbers_config$distance)) {
    distance_twips <- css_to_twips(line_numbers_config$distance)
    xml2::xml_set_attr(lnNumType, "w:distance", as.character(distance_twips))
  }

  doc
}


# xml_escape() and xml_escape_attr() live in utils.R
