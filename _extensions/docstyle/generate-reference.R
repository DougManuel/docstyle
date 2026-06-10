#!/usr/bin/env Rscript
# Pre-render hook: Generate reference.docx from CSS
#
# This script is called by Quarto before rendering to generate a reference.docx
# from the docstyle CSS configuration. Uses hash-based caching to avoid
# regeneration when nothing has changed.
#
# Usage in _quarto.yml:
#   project:
#     pre-render: _extensions/docstyle/generate-reference.R
#
# Behaviour:
# - If user explicitly sets reference-doc in YAML, skip generation (use theirs)
# - Otherwise, generate reference.docx from docstyle.css configuration
# - Cache by hash: only regenerate when CSS or docstyle config changes
#
# Output:
# - _docstyle/reference.docx (cached reference document)
# - _docstyle/reference.docx.hash (hash of inputs for cache validation)

# Null coalesce helper (define early since used throughout)
`%||%` <- function(x, y) if (is.null(x)) y else x

# Resolve project root — prefers QUARTO_PROJECT_DIR, then walks upward
# looking for a _quarto.yml with project:/docstyle: or a .git anchor.
if (requireNamespace("docstyle", quietly = TRUE)) {
  project_dir <- docstyle::find_project_root(getwd())
} else {
  # Inline fallback for environments without the package installed
  env_dir <- Sys.getenv("QUARTO_PROJECT_DIR", "")
  project_dir <- if (nzchar(env_dir)) env_dir else getwd()
}

# Find _quarto.yml
quarto_yml <- file.path(project_dir, "_quarto.yml")
if (!file.exists(quarto_yml)) {
  message("[generate-reference] No _quarto.yml found, skipping reference generation")
  quit(save = "no", status = 0)
}

# Parse _quarto.yml
config <- tryCatch({
  yaml::read_yaml(quarto_yml)
}, error = function(e) {
  message("[generate-reference] Error reading _quarto.yml: ", e$message)
  quit(save = "no", status = 0)
})

# Render-time drift warning: check the vendored extension version
# against the installed docstyle R package. Emits a one-line warning
# at the top of every render when they differ. Catches the recurring
# "rendered with a stale extension and didn't notice" failure mode
# (e.g. POPCORN's protocol shipped with v0.1.0 vendored long after the
# package moved to v0.15+). Suppress with:
#   docstyle:
#     silence-version-warning: true
silence_drift_warning <- isTRUE(config$docstyle$`silence-version-warning`)
if (!silence_drift_warning &&
    requireNamespace("docstyle", quietly = TRUE) &&
    "check_extension_drift" %in% getNamespaceExports("docstyle")) {
  drift <- tryCatch(
    docstyle::check_extension_drift(project_dir),
    error = function(e) NULL)
  if (!is.null(drift) && !is.null(drift$message)) {
    message(drift$message)
  }
}

# Render preflight: block the render on the P0 footguns that otherwise
# produce silently broken output (bibliography:/csl:/reference-doc:/format:
# docx in a QMD header; plain format: docx in _quarto.yml). The full audit
# remains check_project(); this is the always-on minimal subset. Disable with:
#   docstyle:
#     preflight: false
preflight_enabled <- !isFALSE(config$docstyle$preflight)
if (preflight_enabled &&
    requireNamespace("docstyle", quietly = TRUE) &&
    "check_render_preconditions" %in% getNamespaceExports("docstyle")) {
  preflight <- tryCatch(
    docstyle::check_render_preconditions(project_dir, config = config),
    error = function(e) NULL)
  if (!is.null(preflight) && !preflight$ok) {
    message("[preflight] Render blocked by configuration errors:")
    for (err in preflight$errors) message("[preflight]   - ", err)
    message("[preflight] Fix the above, or disable with 'docstyle: preflight: false'.")
    quit(save = "no", status = 1)
  }
}

# Check if user explicitly set a custom reference-doc (not the generated one)
# If pointing to _docstyle/reference.docx, we still need to generate it
has_custom_reference_doc <- function(cfg, sidecar_dir) {
  generated_path <- file.path(sidecar_dir, "reference.docx")

  check_path <- function(path) {
    if (is.null(path)) return(FALSE)
    # Normalize paths for comparison
    norm_path <- normalizePath(path, mustWork = FALSE)
    norm_generated <- normalizePath(generated_path, mustWork = FALSE)
    # If it's the generated path, we should still generate
    if (norm_path == norm_generated) return(FALSE)
    # Also check relative path comparison
    if (path == generated_path) return(FALSE)
    if (basename(dirname(path)) == basename(sidecar_dir) &&
        basename(path) == "reference.docx") return(FALSE)
    TRUE
  }

  # Check format.docx.reference-doc
  if (check_path(cfg$format$docx$`reference-doc`)) return(TRUE)
  if (check_path(cfg$format$`docstyle-docx`$`reference-doc`)) return(TRUE)
  # Check top-level reference-doc
  if (check_path(cfg$`reference-doc`)) return(TRUE)
  FALSE
}

sidecar_dir_name <- config$docstyle$`sidecar-dir` %||% "_docstyle"
if (has_custom_reference_doc(config, sidecar_dir_name)) {
  message("[generate-reference] User specified custom reference-doc, skipping CSS generation")
  quit(save = "no", status = 0)
}

# Check if docstyle configuration exists
if (is.null(config$docstyle)) {
  message("[generate-reference] No docstyle: section found, skipping reference generation")
  quit(save = "no", status = 0)
}

# Resolve CSS path(s) - supports single path, array, or uses default
css_config <- config$docstyle$css

if (is.null(css_config)) {
  # No CSS specified - use default.css from extension
  # Find the extension directory (where this script lives)
  script_dir <- tryCatch({
    # When running as Rscript
    script_path <- commandArgs(trailingOnly = FALSE)
    file_arg <- grep("^--file=", script_path, value = TRUE)
    if (length(file_arg) > 0) {
      dirname(normalizePath(sub("^--file=", "", file_arg)))
    } else {
      # Fallback: look relative to project
      file.path(project_dir, "_extensions", "docstyle")
    }
  }, error = function(e) {
    file.path(project_dir, "_extensions", "docstyle")
  })

  default_css <- file.path(script_dir, "default.css")
  if (file.exists(default_css)) {
    css_paths <- default_css
    message("[generate-reference] Using default CIHR-compliant CSS")
  } else {
    message("[generate-reference] No docstyle.css specified and default.css not found")
    quit(save = "no", status = 0)
  }
} else {
  # User specified CSS - resolve paths
  css_paths <- vapply(css_config, function(p) {
    full_path <- file.path(project_dir, p)
    if (file.exists(full_path)) full_path else p
  }, character(1))

  # Check all CSS files exist
  missing_css <- css_paths[!file.exists(css_paths)]
  if (length(missing_css) > 0) {
    message("[generate-reference] CSS file(s) not found: ", paste(missing_css, collapse = ", "))
    quit(save = "no", status = 0)
  }
}

# Setup output paths
sidecar_dir <- config$docstyle$`sidecar-dir` %||% "_docstyle"
sidecar_path <- file.path(project_dir, sidecar_dir)
if (!dir.exists(sidecar_path)) {
  dir.create(sidecar_path, recursive = TRUE)
}

reference_path <- file.path(sidecar_path, "reference.docx")
hash_path <- file.path(sidecar_path, "reference.docx.hash")

# Compute hash of inputs (CSS content + relevant docstyle config)
compute_input_hash <- function(css_paths, docstyle_config) {
  # Read CSS content from all files
  css_contents <- vapply(css_paths, function(p) {
    paste(readLines(p, warn = FALSE), collapse = "\n")
  }, character(1))
  css_content <- paste(css_contents, collapse = "\n---CSS-SEPARATOR---\n")

  # Extract config elements that affect reference.docx
  # Note: page includes line-numbers sub-config
  relevant_config <- list(
    page = docstyle_config$page,
    header = docstyle_config$header,
    footer = docstyle_config$footer,
    sections = docstyle_config$sections,
    toc = docstyle_config$toc,
    `base-doc` = docstyle_config$`base-doc`
  )
  config_json <- jsonlite::toJSON(relevant_config, auto_unbox = TRUE)

  # Include template version so template changes trigger regeneration
  template_version <- ""
  if (requireNamespace("docstyle", quietly = TRUE)) {
    template_version <- as.character(utils::packageVersion("docstyle"))
  }

  # Include template file content hash if template mode
  template_file_hash <- ""
  base_doc <- docstyle_config[["base-doc"]]
  if (!is.null(base_doc) && base_doc != "pandoc") {
    # Try to find the template file
    template_path <- base_doc
    # Try project-relative path
    project_dir_env <- Sys.getenv("QUARTO_PROJECT_DIR", "")
    if (nzchar(project_dir_env)) {
      resolved <- file.path(project_dir_env, template_path)
      if (file.exists(resolved)) template_path <- resolved
    }
    if (file.exists(template_path)) {
      template_file_hash <- digest::digest(file = template_path, algo = "sha256")
    } else {
      message("[generate-reference] ERROR: Template file not found: ", base_doc)
      message("  Check the 'base-doc' path in your _quarto.yml docstyle: section")
      quit(save = "no", status = 1)
    }
  }

  # Combine and hash
  combined <- paste0(css_content, "\n---\n", config_json,
                     "\n---TEMPLATE---\n", template_version,
                     "\n---TEMPLATE-FILE---\n", template_file_hash)
  digest::digest(combined, algo = "sha256")
}

# Check if regeneration is needed
current_hash <- compute_input_hash(css_paths, config$docstyle)
cached_hash <- ""
if (file.exists(hash_path)) {
  cached_hash <- trimws(readLines(hash_path, n = 1, warn = FALSE))
}

if (current_hash == cached_hash && file.exists(reference_path)) {
  message("[generate-reference] Reference doc up to date (hash match)")
  quit(save = "no", status = 0)
}

message("[generate-reference] Generating reference.docx from CSS...")

# Try to load docstyle
docstyle_loaded <- FALSE

if (requireNamespace("docstyle", quietly = TRUE)) {
  docstyle_loaded <- TRUE
} else {
  # Try to find and load from development source
  search_dirs <- c(
    project_dir,
    dirname(project_dir),
    dirname(dirname(project_dir)),
    dirname(dirname(dirname(project_dir))),
    dirname(dirname(dirname(dirname(project_dir))))
  )

  for (dir in search_dirs) {
    desc_path <- file.path(dir, "DESCRIPTION")
    if (file.exists(desc_path)) {
      desc_content <- readLines(desc_path, n = 1, warn = FALSE)
      if (grepl("Package:\\s*docstyle", desc_content)) {
        if (requireNamespace("devtools", quietly = TRUE)) {
          tryCatch({
            devtools::load_all(dir, quiet = TRUE)
            docstyle_loaded <- TRUE
            break
          }, error = function(e) NULL)
        }
      }
    }
  }
}

if (!docstyle_loaded) {
  message("[generate-reference] docstyle package not found, skipping reference generation")
  quit(save = "no", status = 0)
}

# Generate reference.docx
tryCatch({
  docstyle::generate_reference_doc(
    config_path = quarto_yml,
    output_path = reference_path
  )

  # Write hash file
  writeLines(current_hash, hash_path)

  message("[generate-reference] Generated: ", reference_path)
  message("[generate-reference] Hash: ", substr(current_hash, 1, 12), "...")
}, error = function(e) {
  message("[generate-reference] Error generating reference.docx: ", e$message)
  quit(save = "no", status = 1)
})

# Generate style map if template mode
base_doc_config <- config$docstyle[["base-doc"]]
is_template_mode <- !is.null(base_doc_config) && base_doc_config != "pandoc"

if (is_template_mode) {
  tryCatch({
    # Resolve template path relative to project
    template_path <- base_doc_config
    resolved_template <- file.path(project_dir, template_path)
    if (file.exists(resolved_template)) template_path <- resolved_template

    # Only regenerate style-map.json if cache was invalidated
    # (cache hash includes template file content hash, so template changes trigger this)
    style_map_path <- file.path(sidecar_path, "style-map.json")
    if (!file.exists(style_map_path) || current_hash != cached_hash) {
      docstyle::build_style_map(template_path, sidecar_dir = sidecar_path)
    } else {
      message("[generate-reference] Using existing style-map.json (template unchanged)")
    }
  }, error = function(e) {
    message("[generate-reference] Warning: Could not build style map: ", e$message)
    message("[generate-reference] Template mode style swapping will be unavailable")
  })
}

# Generate page-config.json for Lua filters and R finisher
# Exports page layout, named sections, and header/footer config with pre-computed rPr_xml
tryCatch({
  page_config_path <- file.path(sidecar_path, "page-config.json")

  # Read CSS and extract page config
  css_styles <- docstyle::read_css(css_paths)
  page_config <- attr(css_styles, "page")

  if (is.null(page_config)) page_config <- list()

  # Helper: compute rPr_xml from a CSS style name
  resolve_rPr <- function(style_name) {
    if (is.null(style_name) || is.null(css_styles)) return("")
    selector <- paste0(".", style_name)
    if (!is.null(css_styles[[selector]])) {
      rPr <- docstyle::css_to_rPr(css_styles[[selector]])
      return(docstyle::build_rPr_xml(rPr))
    }
    ""
  }

  # Export footer config with pre-computed rPr_xml and default text
  ds <- config$docstyle
  if (!is.null(ds$footer) && isTRUE(ds$footer$enabled)) {
    page_config$footer <- list(
      enabled = TRUE,
      first_page = ds$footer$`first-page` %||% TRUE,
      style = ds$footer$style %||% NULL,
      rPr_xml = resolve_rPr(ds$footer$style),
      left = ds$footer$left %||% "",
      center = ds$footer$center %||% ds$footer$content %||% "",
      right = ds$footer$right %||% ""
    )
  }

  # Export header config with pre-computed rPr_xml and default text
  if (!is.null(ds$header) && isTRUE(ds$header$enabled)) {
    page_config$header <- list(
      enabled = TRUE,
      first_page = ds$header$`first-page` %||% TRUE,
      style = ds$header$style %||% NULL,
      rPr_xml = resolve_rPr(ds$header$style),
      left = ds$header$left %||% "",
      center = ds$header$center %||% ds$header$content %||% "",
      right = ds$header$right %||% ""
    )
  }

  # Export per-section style overrides with pre-computed rPr_xml
  if (!is.null(ds$sections)) {
    section_exports <- list()
    for (sec_name in names(ds$sections)) {
      sec <- ds$sections[[sec_name]]
      section_exports[[sec_name]] <- list(
        footer_style = sec$`footer-style` %||% NULL,
        footer_rPr_xml = resolve_rPr(sec$`footer-style`),
        header_style = sec$`header-style` %||% NULL,
        header_rPr_xml = resolve_rPr(sec$`header-style`)
      )
    }
    page_config$sections <- section_exports
  }

  # Extract table styles from CSS (e.g., .table-formal, .table-grid)
  table_styles <- docstyle::extract_table_styles(css_styles)
  if (length(table_styles) > 0) {
    page_config$table_styles <- table_styles
    message("[generate-reference] Table styles: ", paste(names(table_styles), collapse = ", "))
  }

  # Extract anchor styles from CSS (e.g., .column-margin, .journal-sidebar)
  anchor_styles <- docstyle::extract_anchor_styles(css_styles)
  if (length(anchor_styles) > 0) {
    page_config$anchor_styles <- anchor_styles
    message("[generate-reference] Anchor styles: ", paste(names(anchor_styles), collapse = ", "))
  }

  # Write page config as JSON
  jsonlite::write_json(
    page_config,
    page_config_path,
    auto_unbox = TRUE,
    pretty = TRUE
  )

  # Report available named page styles
  if (!is.null(page_config$named)) {
    named_styles <- names(page_config$named)
    if (length(named_styles) > 0) {
      message("[generate-reference] Named page styles: ", paste(named_styles, collapse = ", "))
    }
  }
}, error = function(e) {
  # Non-fatal: page-config.json is optional
  message("[generate-reference] Note: Could not generate page-config.json: ", e$message)
})
