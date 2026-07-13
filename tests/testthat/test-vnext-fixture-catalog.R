source(testthat::test_path(
  "../../dev/vnext/characterization/catalog.R"
))

valid_catalog <- function() {
  list(
    schemaVersion = 1L,
    fixtures = list(list(
      id = "example-fixture",
      description = "A compact example.",
      origin = list(
        repository = "https://example.org/repository",
        path = "paper/protocol.qmd",
        sourceLicence = "CC BY 4.0",
        fixtureLicence = "CC BY 4.0"
      ),
      sourceDir = "example-fixture/source",
      document = "protocol.qmd",
      formats = c("docstyle-docx", "docstyle-typst"),
      features = c("abstract", "table"),
      visualPages = c(1L)
    ))
  )
}

test_that("fixture catalogue accepts the version 1 contract", {
  expect_true(validate_fixture_catalog(
    valid_catalog(),
    root = tempdir(),
    check_files = FALSE
  ))
})

test_that("fixture catalogue rejects duplicate fixture identifiers", {
  catalog <- valid_catalog()
  catalog$fixtures[[2]] <- catalog$fixtures[[1]]
  expect_error(
    validate_fixture_catalog(catalog, tempdir(), check_files = FALSE),
    "fixture ids must be unique"
  )
})

test_that("fixture catalogue rejects unsupported formats", {
  catalog <- valid_catalog()
  catalog$fixtures[[1]]$formats <- "html"
  expect_error(
    validate_fixture_catalog(catalog, tempdir(), check_files = FALSE),
    "unsupported format"
  )
})

test_that("fixture catalogue checks source files when requested", {
  expect_error(
    validate_fixture_catalog(valid_catalog(), tempdir(), check_files = TRUE),
    "source directory does not exist"
  )
})
