characterization_script_names <- c(
  "catalog.R",
  "render-legacy.R",
  "inspect-docx.R",
  "inspect-publication.R",
  "legacy-contract.R"
)

load_characterization_scripts <- function(repo_root) {
  directory <- file.path(repo_root, "dev", "vnext", "characterization")
  for (name in characterization_script_names) {
    source(file.path(directory, name), local = .GlobalEnv)
  }
  invisible(TRUE)
}

write_characterization_json <- function(value, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(
    value,
    path,
    pretty = TRUE,
    auto_unbox = TRUE,
    null = "null"
  )
  invisible(path)
}

baseline_artifact_filename <- function(format) {
  paste0(format, ".", legacy_output_extension(format))
}

capture_fixture_baseline <- function(
  fixture,
  catalog_root,
  repo_root,
  output_root,
  characterized_release,
  quarto_bin = "quarto",
  pdfinfo_bin = "pdfinfo",
  pdftotext_bin = "pdftotext",
  pdftoppm_bin = "pdftoppm",
  renderer = render_legacy_fixture,
  docx_inspector = inspect_legacy_docx,
  pdf_inspector = inspect_legacy_pdf,
  jats_inspector = inspect_legacy_jats,
  rasterizer = rasterize_pdf_pages
) {
  fixture_id <- as.character(fixture$id)
  formats <- as.character(unlist(fixture$formats, use.names = FALSE))
  visual_pages <- as.integer(unlist(
    fixture$visualPages,
    use.names = FALSE
  ))
  baseline_parent <- file.path(output_root, fixture_id, "baseline")
  baseline <- file.path(baseline_parent, "legacy")
  dir.create(baseline_parent, recursive = TRUE, showWarnings = FALSE)
  staging <- tempfile("legacy-staging-", tmpdir = baseline_parent)
  dir.create(staging)
  on.exit(
    unlink(staging, recursive = TRUE, force = TRUE),
    add = TRUE
  )

  artifacts <- lapply(formats, function(format) {
    work_root <- tempfile(
      paste0("docstyle-", fixture_id, "-", format, "-")
    )
    on.exit(
      unlink(work_root, recursive = TRUE, force = TRUE),
      add = TRUE
    )
    rendered <- renderer(
      fixture = fixture,
      format = format,
      catalog_root = catalog_root,
      repo_root = repo_root,
      work_root = work_root,
      quarto_bin = quarto_bin
    )
    artifact_name <- baseline_artifact_filename(format)
    artifact_path <- file.path(staging, artifact_name)
    if (!file.copy(rendered$path, artifact_path, overwrite = TRUE)) {
      stop("failed to freeze artifact: ", artifact_name, call. = FALSE)
    }

    inventory <- switch(
      format,
      "docstyle-docx" = docx_inspector(artifact_path),
      "docstyle-typst" = pdf_inspector(
        artifact_path,
        pdfinfo_bin = pdfinfo_bin,
        pdftotext_bin = pdftotext_bin
      ),
      "docstyle-jats" = jats_inspector(artifact_path),
      stop(
        "unsupported characterization format: ", format,
        call. = FALSE
      )
    )
    inventory_name <- paste0(format, "-inventory.json")
    write_characterization_json(
      inventory,
      file.path(staging, inventory_name)
    )

    page_paths <- character()
    if (identical(format, "docstyle-typst")) {
      page_paths <- rasterizer(
        path = artifact_path,
        pages = visual_pages,
        output_dir = file.path(staging, "pages"),
        prefix = format,
        pdftoppm_bin = pdftoppm_bin,
        resolution = 110L
      )
    }

    list(
      format = format,
      file = artifact_name,
      inventory = inventory_name,
      visualPages = as.list(file.path(
        "pages",
        basename(page_paths)
      ))
    )
  })

  manifest <- list(
    schemaVersion = 1L,
    fixture = fixture_id,
    characterizedRelease = characterized_release,
    expectations = "../../expectations.json",
    legacyContract = "../../../legacy-contract.json",
    artifacts = artifacts
  )
  write_characterization_json(
    manifest,
    file.path(staging, "manifest.json")
  )
  if (dir.exists(baseline)) {
    unlink(baseline, recursive = TRUE, force = TRUE)
  }
  if (!file.rename(staging, baseline)) {
    stop(
      "failed to atomically replace baseline: ", baseline,
      call. = FALSE
    )
  }
  manifest
}

capture_legacy_baselines <- function(
  repo_root,
  catalog_path,
  output_root,
  quarto_bin = "quarto",
  pdfinfo_bin = "pdfinfo",
  pdftotext_bin = "pdftotext",
  pdftoppm_bin = "pdftoppm"
) {
  catalog <- read_fixture_catalog(catalog_path, check_files = TRUE)
  contract <- characterize_legacy_contract(repo_root)
  manifests <- lapply(catalog$fixtures, function(fixture) {
    capture_fixture_baseline(
      fixture = fixture,
      catalog_root = dirname(catalog_path),
      repo_root = repo_root,
      output_root = output_root,
      characterized_release = contract$characterizedRelease,
      quarto_bin = quarto_bin,
      pdfinfo_bin = pdfinfo_bin,
      pdftotext_bin = pdftotext_bin,
      pdftoppm_bin = pdftoppm_bin
    )
  })
  invisible(manifests)
}

parse_capture_arguments <- function(arguments) {
  defaults <- list(
    repo_root = ".",
    catalog = "tests/vnext/fixtures/catalog.json",
    output_root = "tests/vnext/fixtures",
    quarto = "quarto",
    pdfinfo = "pdfinfo",
    pdftotext = "pdftotext",
    pdftoppm = "pdftoppm"
  )
  keys <- names(defaults)
  for (argument in arguments) {
    match <- regexec("^--([^=]+)=(.*)$", argument)
    parts <- regmatches(argument, match)[[1]]
    if (length(parts) != 3L) {
      stop("capture options must use --key=value", call. = FALSE)
    }
    key <- gsub("-", "_", parts[[2]], fixed = TRUE)
    if (!key %in% keys) {
      stop("unknown capture option: ", parts[[2]], call. = FALSE)
    }
    defaults[[key]] <- parts[[3]]
  }
  defaults
}

capture_baselines_main <- function(
  arguments = commandArgs(trailingOnly = TRUE)
) {
  options <- parse_capture_arguments(arguments)
  repo_root <- normalizePath(options$repo_root, mustWork = TRUE)
  load_characterization_scripts(repo_root)
  catalog_path <- file.path(repo_root, options$catalog)
  output_root <- file.path(repo_root, options$output_root)
  capture_legacy_baselines(
    repo_root = repo_root,
    catalog_path = catalog_path,
    output_root = output_root,
    quarto_bin = options$quarto,
    pdfinfo_bin = options$pdfinfo,
    pdftotext_bin = options$pdftotext,
    pdftoppm_bin = options$pdftoppm
  )
}

if (sys.nframe() == 0L) {
  capture_baselines_main()
}
