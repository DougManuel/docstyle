test_that("export_bibliography reads field-codes.json and writes BibTeX", {
  tmp_dir <- withr::local_tempdir()

  # Create a minimal field-codes.json
  fc <- list(
    citations = list(
      smith2020 = list(
        itemData = list(
          type = "article-journal",
          title = "A test article",
          author = list(
            list(family = "Smith", given = "Jane")
          ),
          issued = list(`date-parts` = list(list(2020))),
          `container-title` = "Test Journal",
          volume = "10",
          page = "1-5",
          DOI = "10.1234/test"
        )
      ),
      jones2019 = list(
        itemData = list(
          type = "book",
          title = "A test book",
          author = list(
            list(family = "Jones", given = "Bob")
          ),
          issued = list(`date-parts` = list(list(2019)))
        )
      )
    )
  )
  writeLines(
    jsonlite::toJSON(fc, auto_unbox = TRUE, pretty = TRUE),
    file.path(tmp_dir, "field-codes.json")
  )

  bib_path <- file.path(tmp_dir, "references.bib")
  result <- export_bibliography(tmp_dir, output = bib_path, verbose = FALSE)

  expect_equal(result, bib_path)
  expect_true(file.exists(bib_path))

  bib_content <- readLines(bib_path)
  bib_text <- paste(bib_content, collapse = "\n")

  # Both entries present
  expect_match(bib_text, "@article\\{smith2020,")
  expect_match(bib_text, "@book\\{jones2019,")

  # Fields preserved
  expect_match(bib_text, "title = \\{\\{A test article\\}\\}")
  expect_match(bib_text, "journal = \\{Test Journal\\}")
  expect_match(bib_text, "doi = \\{10.1234/test\\}")
  expect_match(bib_text, "year = \\{2020\\}")
  expect_match(bib_text, "pages = \\{1--5\\}")
})


test_that("export_bibliography falls back to references.json", {
  tmp_dir <- withr::local_tempdir()

  # Create references.json (CSL JSON array) without field-codes.json
  refs <- list(
    list(
      id = "lee2021",
      type = "article-journal",
      title = "Fallback article",
      author = list(list(family = "Lee", given = "Chris")),
      issued = list(`date-parts` = list(list(2021)))
    )
  )
  writeLines(
    jsonlite::toJSON(refs, auto_unbox = TRUE, pretty = TRUE),
    file.path(tmp_dir, "references.json")
  )

  bib_path <- file.path(tmp_dir, "references.bib")
  result <- export_bibliography(tmp_dir, output = bib_path, verbose = FALSE)

  bib_text <- paste(readLines(bib_path), collapse = "\n")
  expect_match(bib_text, "@article\\{lee2021,")
  expect_match(bib_text, "title = \\{\\{Fallback article\\}\\}")
})


test_that("export_bibliography defaults output to sidecar_dir/references.bib", {
  tmp_dir <- withr::local_tempdir()

  fc <- list(
    citations = list(
      test2020 = list(
        itemData = list(
          type = "misc",
          title = "Test item",
          author = list(list(family = "Test", given = "A")),
          issued = list(`date-parts` = list(list(2020)))
        )
      )
    )
  )
  writeLines(
    jsonlite::toJSON(fc, auto_unbox = TRUE, pretty = TRUE),
    file.path(tmp_dir, "field-codes.json")
  )

  result <- export_bibliography(tmp_dir, verbose = FALSE)

  expect_equal(result, file.path(tmp_dir, "references.bib"))
  expect_true(file.exists(file.path(tmp_dir, "references.bib")))
})


test_that("export_bibliography handles missing sidecar directory", {
  expect_error(
    export_bibliography("/nonexistent/path", verbose = FALSE),
    "Sidecar directory not found"
  )
})


test_that("export_bibliography returns path when no citations found", {
  tmp_dir <- withr::local_tempdir()
  bib_path <- file.path(tmp_dir, "references.bib")

  result <- export_bibliography(tmp_dir, output = bib_path, verbose = FALSE)
  expect_equal(result, bib_path)
  # No file written when no citations
  expect_false(file.exists(bib_path))
})


test_that("export_bibliography prefers field-codes.json over references.json", {
  tmp_dir <- withr::local_tempdir()

  # Both files present with different data
  fc <- list(
    citations = list(
      fc_key = list(
        itemData = list(
          type = "article-journal",
          title = "From field codes",
          author = list(list(family = "Alpha", given = "A")),
          issued = list(`date-parts` = list(list(2020)))
        )
      )
    )
  )
  refs <- list(
    list(
      id = "ref_key",
      type = "article-journal",
      title = "From references",
      author = list(list(family = "Beta", given = "B")),
      issued = list(`date-parts` = list(list(2021)))
    )
  )
  writeLines(
    jsonlite::toJSON(fc, auto_unbox = TRUE, pretty = TRUE),
    file.path(tmp_dir, "field-codes.json")
  )
  writeLines(
    jsonlite::toJSON(refs, auto_unbox = TRUE, pretty = TRUE),
    file.path(tmp_dir, "references.json")
  )

  bib_path <- file.path(tmp_dir, "references.bib")
  export_bibliography(tmp_dir, output = bib_path, verbose = FALSE)

  bib_text <- paste(readLines(bib_path), collapse = "\n")
  # Should contain field-codes entry, not references.json entry
  expect_match(bib_text, "fc_key")
  expect_no_match(bib_text, "ref_key")
})
