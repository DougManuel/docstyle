characterization_required_fields <- c(
  "id", "description", "origin", "sourceDir", "document",
  "formats", "features", "visualPages"
)

characterization_formats <- c(
  "docstyle-docx", "docstyle-typst", "docstyle-jats"
)

validate_fixture_catalog <- function(catalog, root, check_files = TRUE) {
  if (!identical(as.integer(catalog$schemaVersion), 1L)) {
    stop("catalogue schemaVersion must be 1", call. = FALSE)
  }
  if (!is.list(catalog$fixtures) || length(catalog$fixtures) < 1L) {
    stop("catalogue fixtures must be a non-empty list", call. = FALSE)
  }

  ids <- vapply(catalog$fixtures, function(fixture) {
    missing <- setdiff(characterization_required_fields, names(fixture))
    if (length(missing) > 0L) {
      stop(
        "fixture is missing fields: ",
        paste(missing, collapse = ", "),
        call. = FALSE
      )
    }
    formats <- as.character(unlist(fixture$formats, use.names = FALSE))
    if (!all(formats %in% characterization_formats)) {
      stop(
        "fixture contains unsupported format: ",
        paste(
          setdiff(formats, characterization_formats),
          collapse = ", "
        ),
        call. = FALSE
      )
    }
    if (!all(c(
      "repository", "path", "sourceLicence", "fixtureLicence"
    ) %in% names(fixture$origin))) {
      stop("fixture origin is incomplete", call. = FALSE)
    }
    if (check_files) {
      source_dir <- file.path(root, fixture$sourceDir)
      if (!dir.exists(source_dir)) {
        stop(
          "source directory does not exist: ", fixture$sourceDir,
          call. = FALSE
        )
      }
      document <- file.path(source_dir, fixture$document)
      if (!file.exists(document)) {
        stop(
          "fixture document does not exist: ", fixture$document,
          call. = FALSE
        )
      }
    }
    as.character(fixture$id)
  }, character(1))

  if (anyDuplicated(ids)) {
    stop("fixture ids must be unique", call. = FALSE)
  }
  invisible(TRUE)
}

read_fixture_catalog <- function(
  path = "tests/vnext/fixtures/catalog.json",
  check_files = TRUE
) {
  if (!file.exists(path)) {
    stop("fixture catalogue does not exist: ", path, call. = FALSE)
  }
  catalog <- jsonlite::read_json(path, simplifyVector = FALSE)
  validate_fixture_catalog(
    catalog,
    root = dirname(path),
    check_files = check_files
  )
  catalog
}
