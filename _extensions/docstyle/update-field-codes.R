#!/usr/bin/env Rscript
# Post-render hook: Inject comments, Zotero components, and update field-codes.json
#
# This script is called by Quarto after rendering to:
# 1. Inject comments from comments.json into the rendered DOCX
# 2. Inject Zotero components (ZOTERO_PREF) for full round-trip support
# 3. Extract Zotero field codes and merge into field-codes.json (for caching)
# 4. Validate the rendered document (optional)
#
# The comment-inject.lua filter creates comment markers in document.xml,
# but the actual comments.xml must be built from the JSON sidecar file.
#
# Usage in _quarto.yml:
#   project:
#     post-render: _extensions/docstyle/update-field-codes.R
#
# Environment variables (set by Quarto):
#   QUARTO_PROJECT_OUTPUT_FILES - newline-separated list of output files
#
# Optional environment variables:
#   DOCSTYLE_VALIDATE=1          - Enable DOCX structure validation
#   DOCSTYLE_VALIDATE_COMMENTS=1 - Enable comment validation
#   DOCSTYLE_VALIDATE_ZOTERO=1   - Enable Zotero field code validation
#   DOCSTYLE_DEBUG=1             - Enable verbose debug output

# Get output files from Quarto
output_files_env <- Sys.getenv("QUARTO_PROJECT_OUTPUT_FILES", "")

if (nchar(output_files_env) == 0) {

  # Not running as Quarto hook, exit silently
  quit(save = "no", status = 0)
}

output_files <- strsplit(output_files_env, "\n")[[1]]
docx_files <- output_files[grepl("\\.docx$", output_files, ignore.case = TRUE)]

if (length(docx_files) == 0) {
  # No DOCX files rendered, nothing to do
  quit(save = "no", status = 0)
}

# Try to load docstyle (check installed package first, then try devtools::load_all)
docstyle_loaded <- FALSE

if (requireNamespace("docstyle", quietly = TRUE)) {
  docstyle_loaded <- TRUE
} else {
  # Try to find and load from development source
  # First, try relative to this script (follows symlinks to find package root)
  script_path <- tryCatch({
    args <- commandArgs(trailingOnly = FALSE)
    file_arg <- grep("^--file=", args, value = TRUE)
    if (length(file_arg) > 0) {
      normalizePath(sub("^--file=", "", file_arg), mustWork = FALSE)
    } else {
      NULL
    }
  }, error = function(e) NULL)

  # Build search paths: script location parents + project parents
  project_dir <- Sys.getenv("QUARTO_PROJECT_DIR", getwd())
  search_dirs <- c(
    project_dir,
    dirname(project_dir),
    dirname(dirname(project_dir)),
    dirname(dirname(dirname(project_dir)))
  )

  # Add script-relative paths (for symlinked extensions)
  if (!is.null(script_path) && file.exists(script_path)) {
    script_dir <- dirname(script_path)
    # Script is in _extensions/docstyle/, package root is 2 levels up
    search_dirs <- c(
      dirname(dirname(script_dir)),  # Package root (e.g., /path/to/docstyle)
      search_dirs
    )
  }

  search_dirs <- unique(search_dirs)

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
  message("[post-render] docstyle package not found, skipping comment injection")
  quit(save = "no", status = 0)
}

# Resolve project root — uses docstyle::find_project_root() which prefers
# QUARTO_PROJECT_DIR, then walks upward for _quarto.yml/project: or .git.
project_dir <- docstyle::find_project_root(getwd())

# Read _quarto.yml for docstyle.zotero config (used to set ZOTERO_PREF style)
quarto_yml_path <- file.path(project_dir, "_quarto.yml")
zotero_config <- NULL
ds <- NULL
if (file.exists(quarto_yml_path)) {
  cfg <- tryCatch(yaml::read_yaml(quarto_yml_path), error = function(e) NULL)
  ds <- cfg$docstyle
  if (!is.null(ds$zotero)) {
    zotero_config <- ds$zotero
  }
}

# Helper: resolve a docx path that may be relative to the document directory
# rather than the project root (happens when output-dir: ../_site/docs in a
# subdirectory _quarto.yml). QUARTO_PROJECT_OUTPUT_FILES is built by Quarto
# as relative3(projDir, outputFile) but when output-dir contains ".." the
# resolved path goes above projDir. QUARTO_DOCUMENT_PATH is always the
# document's directory — try that as a fallback base.
resolve_docx_path <- function(path, project_dir) {
  if (file.exists(path)) return(path)
  # Try relative to project root
  attempt <- normalizePath(file.path(project_dir, path), mustWork = FALSE)
  if (file.exists(attempt)) return(attempt)
  # Try relative to document directory (handles output-dir: ../_site/... in subdirs)
  doc_path <- Sys.getenv("QUARTO_DOCUMENT_PATH", "")
  if (nzchar(doc_path)) {
    attempt2 <- normalizePath(file.path(doc_path, path), mustWork = FALSE)
    if (file.exists(attempt2)) return(attempt2)
  }
  path  # return original; caller handles missing file
}

# Process each DOCX file
for (docx_path in docx_files) {
  docx_path <- resolve_docx_path(docx_path, project_dir)
  if (!file.exists(docx_path)) {
    next
  }

  # Determine output directory for field-codes.json
  # Use _docstyle/ in project root if it exists, otherwise same dir as DOCX
  docstyle_dir <- file.path(project_dir, "_docstyle")

  if (dir.exists(docstyle_dir)) {
    output_dir <- docstyle_dir
  } else {
    output_dir <- dirname(docx_path)
  }

  # Collect summary info
  n_comments <- 0
  zotero_pref_injected <- FALSE

  # Debug mode (used throughout)
  debug_mode <- Sys.getenv("DOCSTYLE_DEBUG", "0") == "1"

  # Step 1: Inject comments from comments.json (if present)
  comments_json <- file.path(output_dir, "comments.json")
  if (file.exists(comments_json)) {
    tryCatch({
      # Scan for comment IDs used in the rendered document
      used_ids <- docstyle::scan_used_comment_ids(docx_path)

      if (length(used_ids) > 0) {
        # Validate that used IDs exist in comments.json before injection
        # This prevents corrupt DOCX when QMD and JSON are out of sync
        comments <- docstyle::read_comments_json(comments_json)
        json_ids <- names(comments)
        missing_ids <- setdiff(used_ids, json_ids)

        if (length(missing_ids) > 0) {
          # Critical error: QMD references comments not in JSON
          message("[docstyle] ERROR: Comment ID mismatch detected!")
          message("  Document references ", length(missing_ids), " comment ID(s) not in comments.json:")
          message("    ", paste(missing_ids, collapse = ", "))
          message("  This would produce a corrupt DOCX file.")
          message("  To fix: Run docstyle::sync_comment_ids() to re-sync IDs from source DOCX")
          message("  Skipping comment injection to prevent corruption.")
          # Don't inject - leave document without comments rather than corrupt it
        } else {
          docstyle::inject_comments(
            docx_path = docx_path,
            comments_json = comments_json,
            used_ids = used_ids
          )
          n_comments <- length(used_ids)
        }
      }
    }, error = function(e) {
      message("[docstyle] Error injecting comments: ", conditionMessage(e))
    })
  }

  # Step 1b: Fix comment-deletion nesting
  # Comments attached to deleted text end up after the deletion due to Lua filter
  # limitations. This repositions them to span the deletion properly.
  if (n_comments > 0) {
    tryCatch({
      n_fixed <- docstyle::fix_comment_deletion_nesting(
        docx_path = docx_path,
        verbose = debug_mode
      )
      if (n_fixed > 0 && debug_mode) {
        message("[docstyle] Fixed ", n_fixed, " comment-deletion nesting issue(s)")
      }
    }, error = function(e) {
      message("[docstyle] Error fixing comment nesting: ", conditionMessage(e))
    })
  }

  # Step 1c: Inject Zotero citation field codes from markers
  # The Lua filter emits DOCSTYLE_CITE:: markers; this replaces them with
  # real Word field code XML using data from field-codes.json.
  n_citations_injected <- 0L
  field_codes_json <- file.path(output_dir, "field-codes.json")
  if (file.exists(field_codes_json)) {
    tryCatch({
      cite_result <- docstyle::inject_zotero_citations(
        docx_path = docx_path,
        field_codes_path = field_codes_json,
        verbose = debug_mode
      )
      n_citations_injected <- cite_result$n_injected
    }, error = function(e) {
      message("[docstyle] Error injecting Zotero citations: ", conditionMessage(e))
    })
  }

  # Step 2: Validate comments (if enabled via DOCSTYLE_VALIDATE_COMMENTS=1)
  validate_comments <- Sys.getenv("DOCSTYLE_VALIDATE_COMMENTS", "0")
  if (validate_comments == "1" && file.exists(comments_json)) {
    tryCatch({
      result <- docstyle::validate_comments(
        docx_path = docx_path,
        comments_json = comments_json,
        verbose = TRUE
      )
      if (!result$valid) {
        message("[docstyle] Comment validation failed")
      }
    }, error = function(e) {
      message("[docstyle] Error validating comments: ", conditionMessage(e))
    })
  }

  # Step 2b: Validate DOCX structure (if enabled via DOCSTYLE_VALIDATE=1)
  # Catches XML issues, malformed tracked changes, duplicate IDs, etc.
  validate_structure <- Sys.getenv("DOCSTYLE_VALIDATE", "0")
  if (debug_mode) {
    message("[docstyle] DOCSTYLE_VALIDATE=", validate_structure)
  }
  if (validate_structure == "1") {
    tryCatch({
      result <- docstyle::validate_docx_structure(
        docx_path = docx_path,
        verbose = debug_mode
      )
      if (!result$valid) {
        message("[docstyle] Structure validation: ", length(result$errors), " issue(s) found")
        for (err in result$errors) {
          message("  - ", err)
        }
      } else if (debug_mode) {
        message("[docstyle] Structure validation: passed all checks")
      }
    }, error = function(e) {
      message("[docstyle] Error validating structure: ", conditionMessage(e))
    })
  }

  # Step 3: Inject Zotero components (ZOTERO_PREF if missing)
  # This ensures rendered documents have full Zotero functionality for round-trip editing
  tryCatch({
    result <- docstyle::inject_zotero_components(
      docx_path = docx_path,
      field_codes_json = if (file.exists(field_codes_json)) field_codes_json else NULL,
      zotero_config = zotero_config,
      validate = FALSE,  # Will validate separately if enabled
      verbose = debug_mode
    )
    if (result$zotero_pref_injected) {
      zotero_pref_injected <- TRUE
      if (debug_mode) {
        message("[docstyle] Injected ZOTERO_PREF (style: ", result$style_id, ")")
      }
    }
  }, error = function(e) {
    if (debug_mode) {
      message("[docstyle] Error injecting Zotero components: ", conditionMessage(e))
    }
  })

  # Step 3b: Validate Zotero field codes (if enabled via DOCSTYLE_VALIDATE_ZOTERO=1)
  validate_zotero <- Sys.getenv("DOCSTYLE_VALIDATE_ZOTERO", "0")
  if (validate_zotero == "1") {
    tryCatch({
      result <- docstyle::validate_zotero(
        docx_path = docx_path,
        verbose = debug_mode
      )
      if (!result$valid) {
        message("[docstyle] Zotero validation: ", length(result$issues$errors), " error(s)")
        for (err in result$issues$errors) {
          message("  - ", err)
        }
      } else if (debug_mode) {
        message("[docstyle] Zotero validation: passed all checks")
      }
    }, error = function(e) {
      message("[docstyle] Error validating Zotero: ", conditionMessage(e))
    })
  }

  # Note: Step 4 (extract and merge field codes) was removed in v0.7.6.
  # The render pipeline is read-only with respect to field-codes.json.
  # New citations only enter via harvest (docx_to_qmd), not via render.
  # See: https://github.com/DougManuel/docstyle/issues/38

  # Step 5: Finalize section structure
  # Post-process sectPr elements: remove leaked line numbers from body sectPr,
  # validate opening/closing sectPr have correct properties
  n_sections_fixed <- 0L
  body_sectPr_fixed <- FALSE
  tryCatch({
    result <- docstyle::finalize_docx(
      docx_path = docx_path,
      sidecar_path = output_dir,
      verbose = debug_mode
    )
    n_sections_fixed <- result$fixed
    body_sectPr_fixed <- isTRUE(result$body_fixed)
  }, error = function(e) {
    message("[docstyle] Error finalizing sections: ", conditionMessage(e))
  })

  # Step 5b: Swap style IDs (template mode only)
  # Runs after finalize so that any style refs created by section assembly
  # are also rewritten to template-native IDs.
  n_styles_swapped <- 0L
  style_map_path <- file.path(output_dir, "style-map.json")
  if (file.exists(style_map_path)) {
    tryCatch({
      swap_result <- docstyle::swap_style_ids(
        docx_path = docx_path,
        sidecar_dir = output_dir
      )
      n_styles_swapped <- swap_result$n_mappings
    }, error = function(e) {
      message("[docstyle] Error swapping style IDs: ", conditionMessage(e))
    })
  }

  # Step 6: Prune unused styles (remove Pandoc bloat)
  # Resolve template path for pruning (preserve template styles)
  template_path_for_prune <- NULL
  if (!is.null(ds) && !is.null(ds[["base-doc"]]) && ds[["base-doc"]] != "pandoc") {
    template_path_for_prune <- ds[["base-doc"]]
    resolved <- file.path(project_dir, template_path_for_prune)
    if (file.exists(resolved)) template_path_for_prune <- resolved
  }
  n_styles_pruned <- 0L
  tryCatch({
    n_styles_pruned <- docstyle::prune_styles_file(
      docx_path = docx_path,
      sidecar_dir = output_dir,
      template_path = template_path_for_prune,
      verbose = debug_mode
    )
  }, error = function(e) {
    message("[docstyle] Error pruning styles: ", conditionMessage(e))
  })

  # Step 7: Scan for unresolved citations (always runs)
  # Any [@citekey] text remaining in the output means the citation could not
  # be resolved to a Zotero field code. This catches both Lua-filter misses
  # (citekey not in field-codes.json) and R-finisher fallbacks.
  unresolved_cites <- character()
  tryCatch({
    unresolved_cites <- docstyle::scan_unresolved_citations(docx_path)
  }, error = function(e) {
    if (debug_mode) {
      message("[docstyle] Error scanning for unresolved citations: ", conditionMessage(e))
    }
  })

  # Partition unresolved citations into staged vs unknown.
  # Staged: metadata exists in field-codes.json citations catalog but no citationGroup
  #   (added via add_citations_from_zotero() or QMD-first drafting — expected during drafting)
  # Unknown: no metadata at all — likely a typo or missing harvest
  staged_cites  <- character()
  unknown_cites <- character()
  if (length(unresolved_cites) > 0 && file.exists(field_codes_json)) {
    tryCatch({
      fc_obj       <- jsonlite::fromJSON(field_codes_json, simplifyVector = FALSE)
      known_keys   <- names(fc_obj$citations %||% list())
      staged_cites  <- unresolved_cites[unresolved_cites %in% known_keys]
      unknown_cites <- unresolved_cites[!unresolved_cites %in% known_keys]
    }, error = function(e) {
      unknown_cites <<- unresolved_cites
    })
  } else {
    unknown_cites <- unresolved_cites
  }

  # Print single summary line
  parts <- character()
  if (n_comments > 0) parts <- c(parts, sprintf("%d comment%s", n_comments, if (n_comments == 1) "" else "s"))
  if (n_citations_injected > 0) parts <- c(parts, sprintf("%d citation%s injected", n_citations_injected, if (n_citations_injected == 1) "" else "s"))
  if (zotero_pref_injected) parts <- c(parts, "ZOTERO_PREF injected")
  if (body_sectPr_fixed) parts <- c(parts, "section structure finalized")
  if (n_styles_swapped > 0L) parts <- c(parts, sprintf("%d style(s) swapped", n_styles_swapped))
  if (n_styles_pruned > 0) parts <- c(parts, sprintf("%d style%s pruned", n_styles_pruned, if (n_styles_pruned == 1) "" else "s"))
  if (length(parts) > 0) {
    message("[docstyle] Processed: ", paste(parts, collapse = ", "))
  }
  if (length(staged_cites) > 0) {
    message("[docstyle] Info: ", length(staged_cites),
            " staged citation(s) pending Zotero insertion in Word: ",
            paste(staged_cites, collapse = ", "))
  }
  if (length(unknown_cites) > 0) {
    message("[docstyle] Warning: ", length(unknown_cites),
            " unresolved citation(s) with no metadata — check citekeys or re-harvest: ",
            paste(unknown_cites, collapse = ", "))
  }
}

# Run post-render validators if configured (#145). Validators are opt-in
# via `docstyle.validators:` block in _quarto.yml — no-op when absent so
# this is a non-breaking addition. Errors in validators fail the render
# loudly with actionable messages; warnings print to stderr but
# complete. See validate_docstyle_output() docs for the full schema.
if (docstyle_loaded) {
  tryCatch(
    docstyle::validate_docstyle_output(output_files,
                                       project_dir = ".",
                                       verbose = TRUE),
    error = function(e) {
      # Validator-detected errors propagate here. Re-emit with the
      # docstyle prefix so it's clear the failure is a validation, not
      # a render bug.
      message("[docstyle] ", conditionMessage(e))
      quit(save = "no", status = 1)
    }
  )
}
