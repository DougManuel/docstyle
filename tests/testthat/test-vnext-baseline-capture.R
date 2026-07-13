source(testthat::test_path(
  "../../dev/vnext/characterization/capture-baselines.R"
))

fake_renderer <- function(
  fixture,
  format,
  catalog_root,
  repo_root,
  work_root,
  quarto_bin
) {
  extension <- legacy_output_extension(format)
  dir.create(work_root, recursive = TRUE, showWarnings = FALSE)
  path <- file.path(work_root, paste0(fixture$id, ".", extension))
  writeLines(paste(fixture$id, format), path)
  list(path = path, format = format, log = "fake render")
}

fake_rasterizer <- function(
  path,
  pages,
  output_dir,
  prefix,
  pdftoppm_bin,
  resolution
) {
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  vapply(pages, function(page) {
    output <- file.path(
      output_dir,
      sprintf("%s-page-%03d.png", prefix, as.integer(page))
    )
    writeBin(as.raw(c(0x89, 0x50, 0x4e, 0x47)), output)
    output
  }, character(1))
}

test_that("capture writes artifacts, inventories, visual pages and manifest", {
  root <- tempfile("baseline-capture-")
  dir.create(root)
  fixture <- list(
    id = "example",
    sourceDir = "example/source",
    document = "protocol.qmd",
    formats = c("docstyle-docx", "docstyle-typst", "docstyle-jats"),
    visualPages = c(1L, 2L)
  )

  manifest <- capture_fixture_baseline(
    fixture = fixture,
    catalog_root = root,
    repo_root = root,
    output_root = root,
    characterized_release = "0.19.0",
    renderer = fake_renderer,
    docx_inspector = function(path) {
      list(schemaVersion = 1L, artifact = "docx")
    },
    pdf_inspector = function(path, pdfinfo_bin, pdftotext_bin) {
      list(schemaVersion = 1L, artifact = "pdf")
    },
    jats_inspector = function(path) {
      list(schemaVersion = 1L, artifact = "jats")
    },
    rasterizer = fake_rasterizer
  )

  baseline <- file.path(root, "example", "baseline", "legacy")
  expect_true(file.exists(file.path(baseline, "docstyle-docx.docx")))
  expect_true(file.exists(file.path(baseline, "docstyle-typst.pdf")))
  expect_true(file.exists(file.path(baseline, "docstyle-jats.xml")))
  expect_true(file.exists(file.path(
    baseline,
    "docstyle-docx-inventory.json"
  )))
  expect_true(file.exists(file.path(
    baseline,
    "pages",
    "docstyle-typst-page-001.png"
  )))
  expect_true(file.exists(file.path(baseline, "manifest.json")))
  expect_identical(manifest$fixture, "example")
  expect_length(manifest$artifacts, 3L)
  expect_false(any(grepl(
    tempdir(),
    unlist(manifest, use.names = FALSE),
    fixed = TRUE
  )))
})

test_that("capture CLI rejects unknown options", {
  expect_error(
    parse_capture_arguments("--unknown=value"),
    "unknown capture option"
  )
})
