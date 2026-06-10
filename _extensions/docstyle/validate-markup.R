#!/usr/bin/env Rscript
# Pre-render hook: Validate QMD markup before rendering
#
# This script validates comment markers, revision spans, and other
# docstyle-specific markup before Quarto renders the document.
# It catches issues that would cause Word "unreadable content" errors.
#
# Usage in _quarto.yml:
#   project:
#     pre-render:
#       - _extensions/docstyle/validate-markup.R
#       - _extensions/docstyle/generate-reference.R
#
# Environment variables (set by Quarto):
#   QUARTO_PROJECT_DIR - project root directory
#   QUARTO_PROJECT_INPUT_FILES - files being rendered
#
# Exit codes:
#   0 - Validation passed (or skipped)
#   1 - Validation failed (stops render)

# Get input files from Quarto
input_files_env <- Sys.getenv("QUARTO_PROJECT_INPUT_FILES", "")
project_dir <- Sys.getenv("QUARTO_PROJECT_DIR", getwd())

if (nchar(input_files_env) == 0) {
  # Not running as Quarto hook, exit silently
  quit(save = "no", status = 0)
}

# Parse input files (newline-separated)
input_files <- strsplit(input_files_env, "\n")[[1]]
qmd_files <- input_files[grepl("\\.qmd$", input_files, ignore.case = TRUE)]

if (length(qmd_files) == 0) {
  # No QMD files being rendered, nothing to validate
  quit(save = "no", status = 0)
}

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
  message("[validate-markup] docstyle package not found, skipping validation")
  quit(save = "no", status = 0)
}

# Find sidecar directory for comments.json
sidecar_dir <- file.path(project_dir, "_docstyle")
if (!dir.exists(sidecar_dir)) {
  # Try relative to first QMD file
  sidecar_dir <- file.path(dirname(qmd_files[1]), "_docstyle")
}

comments_json <- if (dir.exists(sidecar_dir)) {
  json_path <- file.path(sidecar_dir, "comments.json")
  if (file.exists(json_path)) json_path else NULL
} else {
  NULL
}

# Validate each QMD file
all_valid <- TRUE
total_errors <- 0
total_warnings <- 0

cat("\n")
cat("=== docstyle Markup Validation ===\n")

for (qmd_path in qmd_files) {
  # Make path absolute if needed
  if (!startsWith(qmd_path, "/")) {
    qmd_path <- file.path(project_dir, qmd_path)
  }

  if (!file.exists(qmd_path)) {
    next
  }

  cat(sprintf("\nValidating: %s\n", basename(qmd_path)))

  result <- tryCatch({
    docstyle::validate_qmd(
      qmd_path = qmd_path,
      comments_json = comments_json,
      verbose = TRUE
    )
  }, error = function(e) {
    message("[validate-markup] Error: ", conditionMessage(e))
    list(valid = FALSE, issues = list(errors = conditionMessage(e), warnings = character()))
  })

  if (!result$valid) {
    all_valid <- FALSE
  }
  total_errors <- total_errors + length(result$issues$errors)
  total_warnings <- total_warnings + length(result$issues$warnings)
}

cat("\n")
cat("=== Validation Summary ===\n")
cat(sprintf("Files: %d | Errors: %d | Warnings: %d\n",
            length(qmd_files), total_errors, total_warnings))

if (!all_valid) {
  cat("\n")
  cat("ERROR: Validation failed. Fix errors before rendering.\n")
  cat("Hint: Convert deprecated [text]{.comment id=\"X\"} to:\n")
  cat("  - Range: <!-- comment:start id=\"X\" -->text<!-- comment:end id=\"X\" -->\n")
  cat("  - Point: <!-- comment id=\"X\" -->\n")
  cat("\n")
  quit(save = "no", status = 1)
}

cat("\n")
