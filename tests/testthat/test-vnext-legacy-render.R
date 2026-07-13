source(testthat::test_path(
  "../../dev/vnext/characterization/render-legacy.R"
))

make_fake_quarto <- function(path) {
  writeLines(c(
    "#!/bin/sh",
    "format=''",
    "while [ \"$#\" -gt 0 ]; do",
    "  if [ \"$1\" = '--to' ]; then format=\"$2\"; shift 2; else shift; fi",
    "done",
    "case \"$format\" in",
    "  docstyle-docx) extension='docx' ;;",
    "  docstyle-typst) extension='pdf' ;;",
    "  docstyle-jats) extension='xml' ;;",
    "  *) exit 64 ;;",
    "esac",
    "mkdir -p output",
    ": > output/protocol.$extension",
    "printf '%s\\n' \"$format\""
  ), path)
  Sys.chmod(path, mode = "0755")
  path
}

test_that("legacy renderer stages the fixture and selected format", {
  root <- tempfile("render-root-")
  dir.create(
    file.path(root, "fixtures", "example", "source"),
    recursive = TRUE
  )
  dir.create(
    file.path(root, "repo", "_extensions", "docstyle"),
    recursive = TRUE
  )
  writeLines("# fixture", file.path(
    root, "fixtures", "example", "source", "protocol.qmd"
  ))
  writeLines("title: extension", file.path(
    root, "repo", "_extensions", "docstyle", "_extension.yml"
  ))
  fake_quarto <- make_fake_quarto(file.path(root, "quarto"))

  fixture <- list(
    id = "example",
    sourceDir = "example/source",
    document = "protocol.qmd"
  )
  result <- render_legacy_fixture(
    fixture = fixture,
    format = "docstyle-docx",
    catalog_root = file.path(root, "fixtures"),
    repo_root = file.path(root, "repo"),
    work_root = file.path(root, "work"),
    quarto_bin = fake_quarto
  )

  expect_true(file.exists(result$path))
  expect_equal(tools::file_ext(result$path), "docx")
  expect_equal(result$format, "docstyle-docx")
  expect_match(paste(result$log, collapse = "\n"), "docstyle-docx")
})

test_that("legacy renderer rejects undeclared formats", {
  expect_error(
    legacy_output_extension("html"),
    "unsupported characterization format"
  )
})
