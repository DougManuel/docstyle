# Render preflight: fast P0 checks run automatically by the pre-render hook.
#
# These guard against the documented footguns that produce broken output
# without an error message (CLAUDE.md "Common mistakes to avoid"). The full
# 9-point audit lives in check_project(); this is the minimal subset that
# should block a render outright.

#' Check render preconditions (P0 footguns)
#'
#' Runs the small set of configuration checks that, when violated, produce
#' silently broken `docstyle-docx` output: `bibliography:`, `csl:`,
#' `reference-doc:`, or a `format: docx` override in a QMD header, and a
#' plain `format: docx` in `_quarto.yml`. Called automatically by the
#' pre-render hook when the project renders `docstyle-docx`; disable with
#' `docstyle: preflight: false` in `_quarto.yml`.
#'
#' Unlike [check_project()], which is a full project audit, this function
#' is deliberately minimal so it can run on every render without noise.
#'
#' @param project_dir Project root containing `_quarto.yml`.
#' @param config Optional pre-parsed `_quarto.yml` as a list. Read from
#'   `project_dir` when `NULL`.
#' @param qmd_files Optional character vector of QMD paths to check.
#'   Defaults to non-recursive `.qmd` files in `project_dir`.
#' @return A list with `ok` (logical) and `errors` (character vector of
#'   actionable messages; empty when `ok`).
#' @export
check_render_preconditions <- function(project_dir = ".",
                                       config = NULL,
                                       qmd_files = NULL) {
  errors <- character(0)

  if (is.null(config)) {
    quarto_yml <- file.path(project_dir, "_quarto.yml")
    if (!file.exists(quarto_yml)) {
      return(list(ok = TRUE, errors = errors))
    }
    config <- tryCatch(yaml::read_yaml(quarto_yml), error = function(e) NULL)
    if (is.null(config)) {
      return(list(ok = TRUE, errors = errors))
    }
  }

  # These checks only matter when the project renders docstyle-docx.
  # bibliography:/csl: are legitimate for Typst-only projects.
  format_keys <- names(config$format)
  if (!"docstyle-docx" %in% format_keys) {
    if ("docx" %in% format_keys) {
      errors <- c(errors,
                  "_quarto.yml: 'format: docx' bypasses docstyle Lua filters; use 'docstyle-docx'")
    }
    return(list(ok = length(errors) == 0, errors = errors))
  }

  if (is.null(qmd_files)) {
    qmd_files <- list.files(project_dir, pattern = "\\.qmd$",
                            full.names = TRUE, recursive = FALSE)
  }

  for (qmd in qmd_files) {
    qmd_name <- basename(qmd)
    yaml_data <- suppressWarnings(tryCatch(extract_qmd_yaml(qmd),
                                           error = function(e) NULL))
    if (is.null(yaml_data)) next

    if (!is.null(yaml_data$bibliography)) {
      errors <- c(errors, paste0(
        qmd_name, ": has 'bibliography:' (causes duplicate citation processing; ",
        "docstyle-docx citations are handled by Zotero field codes)"))
    }
    if (!is.null(yaml_data$csl)) {
      errors <- c(errors, paste0(
        qmd_name, ": has 'csl:' (citations are handled by Zotero field codes)"))
    }
    if (!is.null(yaml_data$`reference-doc`)) {
      errors <- c(errors, paste0(
        qmd_name, ": has 'reference-doc:' (bypasses CSS-driven style generation)"))
    }
    if (!is.null(yaml_data$format)) {
      has_qmd_docx <-
        (is.character(yaml_data$format) && "docx" %in% yaml_data$format) ||
        (is.list(yaml_data$format) && "docx" %in% names(yaml_data$format))
      if (has_qmd_docx) {
        errors <- c(errors, paste0(
          qmd_name, ": has 'format: docx' (set the format in _quarto.yml as docstyle-docx)"))
      }
    }
  }

  list(ok = length(errors) == 0, errors = errors)
}
