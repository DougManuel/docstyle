copy_characterization_tree <- function(from, to) {
  if (!dir.exists(from)) {
    stop("source tree does not exist: ", from, call. = FALSE)
  }
  dir.create(to, recursive = TRUE, showWarnings = FALSE)
  entries <- list.files(
    from,
    recursive = TRUE,
    all.files = TRUE,
    no.. = TRUE,
    include.dirs = TRUE
  )
  if (length(entries) == 0L) {
    return(invisible(to))
  }
  source_paths <- file.path(from, entries)
  info <- file.info(source_paths)

  directories <- entries[!is.na(info$isdir) & info$isdir]
  for (entry in directories) {
    dir.create(file.path(to, entry), recursive = TRUE, showWarnings = FALSE)
  }
  files <- entries[is.na(info$isdir) | !info$isdir]
  for (entry in files) {
    destination <- file.path(to, entry)
    dir.create(dirname(destination), recursive = TRUE, showWarnings = FALSE)
    if (!file.copy(file.path(from, entry), destination, overwrite = TRUE)) {
      stop("failed to copy fixture entry: ", entry, call. = FALSE)
    }
  }
  invisible(to)
}

legacy_output_extension <- function(format) {
  extensions <- c(
    "docstyle-docx" = "docx",
    "docstyle-typst" = "pdf",
    "docstyle-jats" = "xml"
  )
  if (!format %in% names(extensions)) {
    stop(
      "unsupported characterization format: ", format,
      call. = FALSE
    )
  }
  unname(extensions[[format]])
}

render_legacy_fixture <- function(
  fixture,
  format,
  catalog_root,
  repo_root,
  work_root,
  quarto_bin = "quarto"
) {
  extension <- legacy_output_extension(format)
  if (dir.exists(work_root)) {
    unlink(work_root, recursive = TRUE, force = TRUE)
  }
  dir.create(work_root, recursive = TRUE)

  staged_catalog <- file.path(work_root, "fixtures")
  copy_characterization_tree(catalog_root, staged_catalog)
  project_dir <- file.path(staged_catalog, fixture$sourceDir)
  extension_dir <- file.path(project_dir, "_extensions", "docstyle")
  copy_characterization_tree(
    file.path(repo_root, "_extensions", "docstyle"),
    extension_dir
  )

  log <- withr::with_dir(project_dir, {
    output <- system2(
      quarto_bin,
      c("render", fixture$document, "--to", format),
      stdout = TRUE,
      stderr = TRUE
    )
    status <- attr(output, "status")
    if (!is.null(status) && status != 0L) {
      stop(
        "legacy render failed for ", fixture$id, " (", format, "):\n",
        paste(output, collapse = "\n"),
        call. = FALSE
      )
    }
    output
  })

  candidates <- list.files(
    file.path(project_dir, "output"),
    pattern = paste0("\\.", extension, "$"),
    full.names = TRUE,
    recursive = TRUE
  )
  if (length(candidates) != 1L) {
    stop(
      "expected one ", extension, " output for ", fixture$id,
      "; found ", length(candidates),
      call. = FALSE
    )
  }
  list(
    path = normalizePath(candidates[[1]], mustWork = TRUE),
    format = format,
    log = unname(log)
  )
}
