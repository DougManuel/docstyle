#' Read Quarto Project Configuration
#'
#' Reads the `_quarto.yml` file from the project root.
#'
#' @param project_root Path to the project root directory. Defaults to current directory.
#' @return A list containing the project configuration.
#' @export
read_quarto_config <- function(project_root = ".") {
  path <- file.path(project_root, "_quarto.yml")
  if (!file.exists(path)) {
    warning("_quarto.yml not found at: ", suppressWarnings(normalizePath(path, mustWork = FALSE)))
    return(NULL)
  }
  yaml::read_yaml(path)
}

#' Get Docstyle Configuration
#'
#' Extracts the `docstyle` block from the Quarto configuration.
#'
#' @param quarto_config List from `read_quarto_config`.
#' @return List containing docstyle configuration or NULL.
#' @keywords internal
#' @export
get_docstyle_config <- function(quarto_config) {
  if (is.null(quarto_config)) return(NULL)
  quarto_config$docstyle
}


#' Resolve Docstyle Paths from Configuration
#'
#' Resolves output, sidecar, and source paths from docstyle configuration.
#' This function handles the new project structure conventions:
#' - `output-dir`: Where rendered files go (default: same as input)
#' - `output-name`: Base filename for rendered output (default: input filename)
#' - `sidecar-dir`: Where JSON metadata files live (default: same as input)
#'
#' @param input_path Path to the input .qmd file.
#' @param config_path Path to `_quarto.yml`. If NULL, looks in input directory.
#' @param docstyle_config Optional pre-loaded docstyle config list. If provided,
#'   `config_path` is only used for resolving relative paths.
#'
#' @return A list with resolved paths:
#'   - `output_path`: Full path for rendered .docx

#'   - `output_dir`: Directory for rendered files
#'   - `sidecar_dir`: Directory containing JSON sidecar files
#'   - `field_codes_path`: Path to field-codes.json (or NULL if not found)
#'   - `references_path`: Path to references.json (or NULL if not found
#'   - `comments_path`: Path to comments.json (or NULL if not found)
#'   - `revisions_path`: Path to revisions.json (or NULL if not found)
#'   - `source_docx`: Original source document path (or NULL)
#'
#' @keywords internal
#' @export
resolve_docstyle_paths <- function(input_path,
                                    config_path = NULL,
                                    docstyle_config = NULL) {

  input_dir <- dirname(input_path)
  input_basename <- tools::file_path_sans_ext(basename(input_path))


  # Load config if not provided
  if (is.null(docstyle_config)) {
    if (is.null(config_path)) {
      config_path <- file.path(input_dir, "_quarto.yml")
    }
    if (file.exists(config_path)) {
      full_config <- yaml::read_yaml(config_path)
      docstyle_config <- full_config$docstyle
    }
  }

  # Determine base directory for relative paths (where _quarto.yml lives)
  if (!is.null(config_path) && file.exists(config_path)) {
    base_dir <- dirname(config_path)
  } else {
    base_dir <- input_dir
  }

  # Extract config values with defaults
  output_name <- docstyle_config$`output-name` %||% input_basename
  output_dir_rel <- docstyle_config$`output-dir` %||% "."
  sidecar_dir_rel <- docstyle_config$`sidecar-dir` %||% "."
  source_docx_rel <- docstyle_config$`source-docx`

  # Resolve to absolute paths
  output_dir <- normalizePath(file.path(base_dir, output_dir_rel), mustWork = FALSE)
  sidecar_dir <- normalizePath(file.path(base_dir, sidecar_dir_rel), mustWork = FALSE)

  # Build output path
  output_path <- file.path(output_dir, paste0(output_name, ".docx"))

  # Build sidecar file paths
  field_codes_path <- file.path(sidecar_dir, "field-codes.json")
  references_path <- file.path(sidecar_dir, "references.json")
  comments_path <- file.path(sidecar_dir, "comments.json")
  revisions_path <- file.path(sidecar_dir, "revisions.json")

  # Check existence
  if (!file.exists(field_codes_path)) field_codes_path <- NULL
  if (!file.exists(references_path)) references_path <- NULL
  if (!file.exists(comments_path)) comments_path <- NULL
  if (!file.exists(revisions_path)) revisions_path <- NULL

  # Resolve source docx if specified
  source_docx <- NULL
  if (!is.null(source_docx_rel)) {
    source_docx <- normalizePath(file.path(base_dir, source_docx_rel), mustWork = FALSE)
    if (!file.exists(source_docx)) source_docx <- NULL
  }

  list(
    output_path = output_path,
    output_dir = output_dir,
    sidecar_dir = sidecar_dir,
    field_codes_path = field_codes_path,
    references_path = references_path,
    comments_path = comments_path,
    revisions_path = revisions_path,
    source_docx = source_docx,
    output_name = output_name
  )
}


