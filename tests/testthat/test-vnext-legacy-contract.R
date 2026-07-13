source(testthat::test_path(
  "../../dev/vnext/characterization/legacy-contract.R"
))

test_that("legacy contract records field-code reader and writer versions", {
  repo_root <- normalizePath(testthat::test_path("../.."))
  contract <- characterize_legacy_contract(repo_root)

  expect_identical(contract$schemaVersion, 1L)
  expect_identical(contract$characterizedRelease, "0.19.0")
  expect_identical(contract$fieldCodes$writerVersion, 3L)
  expect_identical(
    unlist(contract$fieldCodes$readerVersions, use.names = FALSE),
    1:3
  )
  expect_setequal(
    unlist(contract$fieldCodes$payloadTypes, use.names = FALSE),
    c(
      "char", "div", "list", "section", "table", "figure",
      "float", "anchor"
    )
  )
})

test_that("legacy contract classifies every known JSON sidecar", {
  contract <- characterize_legacy_contract(
    normalizePath(testthat::test_path("../.."))
  )
  names <- vapply(contract$sidecars, function(x) x$name, character(1))

  expect_setequal(names, c(
    "field-codes.json", "comments.json", "revisions.json",
    "references.json", "page-config.json", "style-map.json",
    "section-map.json", "harvest-map.json", "figures.json",
    "styles.json"
  ))
  expect_true(all(vapply(
    contract$sidecars,
    function(x) identical(x$versioning, "unversioned"),
    logical(1)
  )))
  expect_true(validate_legacy_contract(contract))
})

test_that("committed legacy contract matches the characterized release", {
  path <- testthat::test_path("../vnext/fixtures/legacy-contract.json")
  expect_true(file.exists(path))
  committed <- jsonlite::read_json(path, simplifyVector = FALSE)
  current <- characterize_legacy_contract(
    normalizePath(testthat::test_path("../.."))
  )

  expect_identical(committed, current)
})
