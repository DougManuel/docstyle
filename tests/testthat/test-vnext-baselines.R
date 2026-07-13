source(testthat::test_path(
  "../../dev/vnext/characterization/catalog.R"
))

allowed_expectation_statuses <- c(
  "observed", "known-bug", "approximated", "omitted", "unsupported"
)

read_fixture_expectations <- function(path) {
  value <- jsonlite::read_json(path, simplifyVector = FALSE)
  expect_identical(as.integer(value$schemaVersion), 1L)
  statuses <- vapply(
    value$expectations,
    function(x) as.character(x$status),
    character(1)
  )
  expect_true(all(statuses %in% allowed_expectation_statuses))
  expect_true(all(vapply(
    value$expectations,
    function(x) {
      nzchar(as.character(x$evidence)) &&
        nzchar(as.character(x$reference))
    },
    logical(1)
  )))
  value
}

test_that("every fixture has a complete frozen legacy manifest", {
  root <- testthat::test_path("../vnext/fixtures")
  catalog <- read_fixture_catalog(
    file.path(root, "catalog.json"),
    check_files = TRUE
  )

  for (fixture in catalog$fixtures) {
    fixture_id <- as.character(fixture$id)
    formats <- as.character(unlist(fixture$formats, use.names = FALSE))
    baseline <- file.path(
      root,
      fixture_id,
      "baseline",
      "legacy"
    )
    manifest_path <- file.path(baseline, "manifest.json")
    expect_true(file.exists(manifest_path), info = fixture_id)
    manifest <- jsonlite::read_json(
      manifest_path,
      simplifyVector = FALSE
    )

    expect_identical(as.integer(manifest$schemaVersion), 1L)
    expect_identical(as.character(manifest$fixture), fixture_id)
    expect_identical(
      as.character(manifest$characterizedRelease),
      "0.19.0"
    )
    artifact_formats <- vapply(
      manifest$artifacts,
      function(x) as.character(x$format),
      character(1)
    )
    expect_setequal(artifact_formats, formats)

    for (artifact in manifest$artifacts) {
      artifact_path <- file.path(baseline, artifact$file)
      inventory_path <- file.path(baseline, artifact$inventory)
      expect_true(file.exists(artifact_path), info = artifact_path)
      expect_gt(
        file.info(artifact_path)$size,
        0,
        label = artifact_path
      )
      expect_true(file.exists(inventory_path), info = inventory_path)
      inventory <- jsonlite::read_json(
        inventory_path,
        simplifyVector = FALSE
      )
      expect_identical(as.integer(inventory$schemaVersion), 1L)

      page_paths <- as.character(unlist(
        artifact$visualPages,
        use.names = FALSE
      ))
      if (identical(
        as.character(artifact$format),
        "docstyle-typst"
      )) {
        expect_length(
          page_paths,
          length(unlist(fixture$visualPages, use.names = FALSE))
        )
        for (page_path in page_paths) {
          png <- file.path(baseline, page_path)
          expect_true(file.exists(png), info = png)
          signature <- readBin(png, what = "raw", n = 8L)
          expect_identical(
            signature,
            as.raw(c(
              0x89, 0x50, 0x4e, 0x47,
              0x0d, 0x0a, 0x1a, 0x0a
            ))
          )
        }
      } else {
        expect_length(page_paths, 0L)
      }
    }

    expectations_path <- file.path(
      baseline,
      as.character(manifest$expectations)
    )
    expectations <- read_fixture_expectations(expectations_path)
    expect_identical(
      as.character(expectations$fixture),
      fixture_id
    )
    expect_true(file.exists(file.path(
      baseline,
      as.character(manifest$legacyContract)
    )))
  }
})

test_that("frozen characterization data is portable and bounded", {
  root <- testthat::test_path("../vnext/fixtures")
  files <- list.files(
    root,
    recursive = TRUE,
    full.names = TRUE,
    all.files = TRUE,
    no.. = TRUE
  )
  files <- files[!file.info(files)$isdir]
  expect_lt(sum(file.info(files)$size), 15 * 1024^2)

  fixture_directories <- file.path(root, c(
    "demport-protocol",
    "popcorn-protocol",
    "independent-manuscript"
  ))
  for (directory in fixture_directories) {
    fixture_files <- list.files(
      directory,
      recursive = TRUE,
      full.names = TRUE,
      all.files = TRUE,
      no.. = TRUE
    )
    fixture_files <- fixture_files[!file.info(fixture_files)$isdir]
    expect_lt(sum(file.info(fixture_files)$size), 5 * 1024^2)
  }

  json_files <- files[tools::file_ext(files) == "json"]
  json_text <- unlist(lapply(
    json_files,
    readLines,
    warn = FALSE,
    encoding = "UTF-8"
  ))
  machine_patterns <- c(
    "/Users/", "/home/", "/private/tmp/", "\\\\Users\\\\",
    "docstyle-characterization-docx-"
  )
  expect_false(any(vapply(
    machine_patterns,
    function(pattern) any(grepl(pattern, json_text, fixed = TRUE)),
    logical(1)
  )))
})
