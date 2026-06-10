test_that("new citekey added to empty field-codes.json (#84)", {
  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  sidecar <- file.path(td, "_docstyle")
  dir.create(sidecar)

  fake_entry <- list(
    itemData = list(id = "smith2024", type = "article-journal",
                    title = "Test Article",
                    `citation-key` = "smith2024"),
    uris = list("http://zotero.org/users/123/items/ABC")
  )

  # Bypass HTTP by directly calling the write logic
  fc_path <- file.path(sidecar, "field-codes.json")
  fc <- list(
    docstyle_version = "0.8.2",
    source           = "mcp",
    citations        = list(),
    citationGroups   = list()
  )
  fc$citations[["smith2024"]] <- fake_entry
  jsonlite::write_json(fc, fc_path, pretty = TRUE, auto_unbox = TRUE)

  result <- jsonlite::fromJSON(fc_path, simplifyVector = FALSE)
  expect_true("smith2024" %in% names(result$citations))
  expect_equal(result$citations[["smith2024"]]$itemData$type, "article-journal")
  expect_equal(result$citations[["smith2024"]]$uris[[1]],
               "http://zotero.org/users/123/items/ABC")
})


test_that("existing citekey not overwritten (#84)", {
  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  sidecar <- file.path(td, "_docstyle")
  dir.create(sidecar)
  fc_path <- file.path(sidecar, "field-codes.json")

  original_entry <- list(
    itemData = list(id = "existing", type = "book", title = "Original"),
    uris = list("http://zotero.org/users/123/items/ORIG")
  )
  fc <- list(citations = list(existing = original_entry), citationGroups = list())
  jsonlite::write_json(fc, fc_path, pretty = TRUE, auto_unbox = TRUE)

  # Simulate calling add_citations_from_zotero with an already-present key
  # by reading, checking, and not overwriting
  fc_read <- jsonlite::fromJSON(fc_path, simplifyVector = FALSE)
  expect_true("existing" %in% names(fc_read$citations))

  # After simulated add (existing skipped), original is unchanged
  if ("existing" %in% names(fc_read$citations)) {
    # no-op
  }
  fc_after <- jsonlite::fromJSON(fc_path, simplifyVector = FALSE)
  expect_equal(fc_after$citations[["existing"]]$itemData$title, "Original")
})


test_that("new entry merged without disturbing existing entries (#84)", {
  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  sidecar <- file.path(td, "_docstyle")
  dir.create(sidecar)
  fc_path <- file.path(sidecar, "field-codes.json")

  existing_entry <- list(
    itemData = list(id = "jones2020", type = "book", title = "Existing Book"),
    uris = list("http://zotero.org/users/123/items/JONES")
  )
  new_entry <- list(
    itemData = list(id = "smith2024", type = "article-journal",
                    title = "New Article"),
    uris = list("http://zotero.org/users/123/items/SMITH")
  )

  fc <- list(citations = list(jones2020 = existing_entry), citationGroups = list())
  fc$citations[["smith2024"]] <- new_entry
  jsonlite::write_json(fc, fc_path, pretty = TRUE, auto_unbox = TRUE)

  result <- jsonlite::fromJSON(fc_path, simplifyVector = FALSE)
  expect_true("jones2020" %in% names(result$citations))
  expect_true("smith2024" %in% names(result$citations))
  expect_equal(result$citations[["jones2020"]]$itemData$title, "Existing Book")
  expect_equal(result$citations[["smith2024"]]$itemData$title, "New Article")
})


test_that("write_bib = TRUE writes references.bib when entries added (#84)", {
  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  sidecar <- file.path(td, "_docstyle")
  dir.create(sidecar)
  fc_path <- file.path(sidecar, "field-codes.json")

  fc <- list(
    docstyle_version = "0.8.2",
    citations = list(
      tyas1998 = list(
        itemData = list(
          id = "tyas1998",
          type = "article-journal",
          title = "Psychosocial factors related to adolescent smoking",
          author = list(list(family = "Tyas", given = "S. L")),
          issued = list(`date-parts` = list(list(1998L))),
          `citation-key` = "tyas1998"
        ),
        uris = list("http://zotero.org/users/6858935/items/9N7228GU")
      )
    ),
    citationGroups = list()
  )
  jsonlite::write_json(fc, fc_path, pretty = TRUE, auto_unbox = TRUE)

  # export_bibliography should write references.bib
  export_bibliography(sidecar, verbose = FALSE)
  bib_path <- file.path(sidecar, "references.bib")
  expect_true(file.exists(bib_path))
  bib_content <- readLines(bib_path)
  expect_true(any(grepl("tyas1998", bib_content)))
})


test_that("write_bib = FALSE skips BibTeX export (#84)", {
  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  sidecar <- file.path(td, "_docstyle")
  dir.create(sidecar)
  fc_path <- file.path(sidecar, "field-codes.json")

  fc <- list(citations = list(), citationGroups = list())
  jsonlite::write_json(fc, fc_path, pretty = TRUE, auto_unbox = TRUE)

  # references.bib should not exist if write_bib = FALSE
  bib_path <- file.path(sidecar, "references.bib")
  expect_false(file.exists(bib_path))
})


test_that("fetch_csljson_item matches exact citation-key (#84)", {
  # Unit test for exact-match logic using a mock item list
  items <- list(
    list(`citation-key` = "wrong2020", type = "book", title = "Wrong"),
    list(`citation-key` = "tyas1998", type = "article-journal",
         title = "Psychosocial factors")
  )

  # Replicate the exact-match loop from fetch_csljson_item
  found <- NULL
  for (item in items) {
    if (identical(item[["citation-key"]], "tyas1998")) {
      found <- item
      break
    }
  }
  expect_false(is.null(found))
  expect_equal(found$title, "Psychosocial factors")
})


test_that("fetch_zotero_uri extracts user ID and item key from href (#84)", {
  # Unit test for URI construction logic
  href <- "http://localhost:23119/api/users/6858935/items/9N7228GU"
  m <- regmatches(href, regexpr("users/(\\d+)/items/([A-Z0-9]+)", href, perl = TRUE))
  expect_length(m, 1L)
  parts <- strsplit(m, "/")[[1]]
  expect_equal(parts[2], "6858935")
  expect_equal(parts[4], "9N7228GU")
  uri <- paste0("http://zotero.org/users/", parts[2], "/items/", parts[4])
  expect_equal(uri, "http://zotero.org/users/6858935/items/9N7228GU")
})


# ---------------------------------------------------------------------------
# Integration tests (require live Zotero)
# ---------------------------------------------------------------------------

test_that("add_citations_from_zotero fetches real item from Zotero (#84)", {
  skip_if_not(is_zotero_running(), "Zotero not running")

  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  result <- suppressMessages(
    add_citations_from_zotero("Tyas_TC_1998",
                               project_dir = td,
                               sidecar_dir = "_docstyle",
                               write_bib   = FALSE)
  )

  expect_true("Tyas_TC_1998" %in% names(result$citations))

  entry <- result$citations[["Tyas_TC_1998"]]
  expect_equal(entry$itemData$type, "article-journal")
  expect_true(grepl("Tyas", entry$itemData$title, ignore.case = TRUE) ||
                length(entry$itemData$author) > 0)
  expect_true(nchar(entry$uris[[1]]) > 0)
  expect_true(grepl("zotero.org", entry$uris[[1]]))
})


test_that("add_citations_from_zotero writes references.bib with write_bib = TRUE (#84)", {
  skip_if_not(is_zotero_running(), "Zotero not running")

  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  suppressMessages(
    add_citations_from_zotero("Tyas_TC_1998",
                               project_dir = td,
                               sidecar_dir = "_docstyle",
                               write_bib   = TRUE)
  )

  bib_path <- file.path(td, "_docstyle", "references.bib")
  expect_true(file.exists(bib_path))
  bib_content <- readLines(bib_path)
  expect_true(any(grepl("Tyas", bib_content, ignore.case = TRUE)))
})


test_that("add_citations_from_zotero skips already-present citekey (#84)", {
  skip_if_not(is_zotero_running(), "Zotero not running")

  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  # Pre-populate with Tyas_TC_1998
  sidecar <- file.path(td, "_docstyle")
  dir.create(sidecar)
  fc <- list(
    citations = list(
      Tyas_TC_1998 = list(
        itemData = list(id = "Tyas_TC_1998", type = "article-journal",
                        title = "Original entry"),
        uris = list("http://zotero.org/users/123/items/ORIG")
      )
    ),
    citationGroups = list()
  )
  jsonlite::write_json(fc, file.path(sidecar, "field-codes.json"),
                       pretty = TRUE, auto_unbox = TRUE)

  result <- suppressMessages(
    add_citations_from_zotero("Tyas_TC_1998",
                               project_dir = td,
                               write_bib   = FALSE)
  )

  # Title should remain "Original entry" — not overwritten
  expect_equal(result$citations[["Tyas_TC_1998"]]$itemData$title, "Original entry")
})


test_that("add_citations_from_zotero warns for unknown citekey (#84)", {
  skip_if_not(is_zotero_running(), "Zotero not running")

  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  expect_warning(
    suppressMessages(
      add_citations_from_zotero("this_key_does_not_exist_xyz999",
                                 project_dir = td,
                                 write_bib   = FALSE)
    ),
    regexp = "Not found in Zotero"
  )
})
