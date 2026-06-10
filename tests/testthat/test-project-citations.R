# Tests for import_citations() (#95)

# Helper: write a minimal field-codes.json to a temp file
write_fc <- function(citations, path, extra = list()) {
  fc <- c(list(
    docstyle_version = "0.9.0",
    citations        = citations,
    citationGroups   = list()
  ), extra)
  writeLines(jsonlite::toJSON(fc, auto_unbox = TRUE, pretty = TRUE, null = "null"), path)
}

test_that("import_citations: adds new citekeys to empty destination (#95)", {
  td <- tempfile(); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  src  <- file.path(td, "source.json")
  dest <- file.path(td, "dest.json")

  write_fc(list(
    smith2020 = list(itemData = list(title = "Smith paper", type = "article-journal"))
  ), src)

  result <- import_citations(src, dest, verbose = FALSE)

  expect_equal(result$added,   "smith2020")
  expect_length(result$skipped, 0L)

  dest_fc <- jsonlite::fromJSON(dest, simplifyVector = FALSE)
  expect_true("smith2020" %in% names(dest_fc$citations))
})

test_that("import_citations: skips existing keys by default (#95)", {
  td <- tempfile(); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  src  <- file.path(td, "source.json")
  dest <- file.path(td, "dest.json")

  write_fc(list(smith2020 = list(itemData = list(title = "Updated"))), src)
  write_fc(list(smith2020 = list(itemData = list(title = "Original"))), dest)

  result <- import_citations(src, dest, verbose = FALSE)

  expect_equal(result$skipped, "smith2020")
  expect_length(result$added,  0L)

  # Original value preserved
  dest_fc <- jsonlite::fromJSON(dest, simplifyVector = FALSE)
  expect_equal(dest_fc$citations$smith2020$itemData$title, "Original")
})

test_that("import_citations: overwrites when overwrite=TRUE (#95)", {
  td <- tempfile(); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  src  <- file.path(td, "source.json")
  dest <- file.path(td, "dest.json")

  write_fc(list(smith2020 = list(itemData = list(title = "Updated"))), src)
  write_fc(list(smith2020 = list(itemData = list(title = "Original"))), dest)

  result <- import_citations(src, dest, overwrite = TRUE, verbose = FALSE)

  expect_equal(result$overwritten, "smith2020")
  dest_fc <- jsonlite::fromJSON(dest, simplifyVector = FALSE)
  expect_equal(dest_fc$citations$smith2020$itemData$title, "Updated")
})

test_that("import_citations: citekeys filter imports only requested keys (#95)", {
  td <- tempfile(); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  src  <- file.path(td, "source.json")
  dest <- file.path(td, "dest.json")

  write_fc(list(
    alpha = list(itemData = list(title = "Alpha")),
    beta  = list(itemData = list(title = "Beta"))
  ), src)

  result <- import_citations(src, dest, citekeys = "alpha", verbose = FALSE)

  expect_equal(result$added, "alpha")
  dest_fc <- jsonlite::fromJSON(dest, simplifyVector = FALSE)
  expect_true("alpha"  %in% names(dest_fc$citations))
  expect_false("beta" %in% names(dest_fc$citations))
})

test_that("import_citations: preserves zotero_pref in destination (#95)", {
  td <- tempfile(); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  src  <- file.path(td, "source.json")
  dest <- file.path(td, "dest.json")

  write_fc(list(new_ref = list(itemData = list(title = "New"))), src)
  write_fc(
    list(old_ref = list(itemData = list(title = "Old"))),
    dest,
    extra = list(zotero_pref = list(style = list(styleID = "apa")))
  )

  import_citations(src, dest, verbose = FALSE)

  dest_fc <- jsonlite::fromJSON(dest, simplifyVector = FALSE)
  expect_equal(dest_fc$zotero_pref$style$styleID, "apa")
})

test_that("import_citations: source not found stops with error (#95)", {
  td <- tempfile(); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  expect_error(
    import_citations(file.path(td, "nonexistent.json"), file.path(td, "dest.json"),
                     verbose = FALSE),
    "File not found"
  )
})

test_that("import_citations: creates destination directory if needed (#95)", {
  td <- tempfile(); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  src  <- file.path(td, "source.json")
  dest <- file.path(td, "newdir", "field-codes.json")

  write_fc(list(ref1 = list(itemData = list(title = "Ref"))), src)

  result <- import_citations(src, dest, verbose = FALSE)

  expect_true(file.exists(dest))
  expect_equal(result$added, "ref1")
})

test_that("import_citations: accepts directory path for source (#95)", {
  td  <- tempfile(); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  src_dir <- file.path(td, "source_proj", "_docstyle")
  dir.create(src_dir, recursive = TRUE)
  src_fc <- file.path(src_dir, "field-codes.json")
  dest   <- file.path(td, "dest.json")

  write_fc(list(ref1 = list(itemData = list(title = "Ref"))), src_fc)

  result <- import_citations(file.path(td, "source_proj"), dest, verbose = FALSE)
  expect_equal(result$added, "ref1")
})

test_that("import_citations: preserves zotero_bibl in destination (#95)", {
  td <- tempfile(); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  src  <- file.path(td, "source.json")
  dest <- file.path(td, "dest.json")

  write_fc(list(new_ref = list(itemData = list(title = "New"))), src)
  write_fc(
    list(old_ref = list(itemData = list(title = "Old"))),
    dest,
    extra = list(zotero_bibl = list(uncited = "omit"))
  )

  import_citations(src, dest, verbose = FALSE)

  dest_fc <- jsonlite::fromJSON(dest, simplifyVector = FALSE)
  expect_equal(dest_fc$zotero_bibl$uncited, "omit")
})

test_that("import_citations: warns for citekeys absent from source (#95)", {
  td <- tempfile(); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  src  <- file.path(td, "source.json")
  dest <- file.path(td, "dest.json")

  write_fc(list(real = list(itemData = list(title = "Real"))), src)

  expect_warning(
    result <- import_citations(src, dest, citekeys = c("real", "ghost"), verbose = FALSE),
    "ghost"
  )
  expect_equal(result$added, "real")
})

test_that("import_citations: malformed source JSON stops with error (#95)", {
  td   <- tempfile(); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  src  <- file.path(td, "bad.json")
  dest <- file.path(td, "dest.json")

  writeLines("{not valid json", src)

  expect_error(
    import_citations(src, dest, verbose = FALSE),
    "Failed to parse source"
  )
})

test_that("resolve_field_codes_path: must_exist=TRUE errors for missing file (#95)", {
  td <- tempfile(); dir.create(td); on.exit(unlink(td, recursive = TRUE))

  # Direct path that doesn't exist
  expect_error(
    resolve_field_codes_path(file.path(td, "nonexistent.json"), must_exist = TRUE),
    "File not found"
  )

  # Directory path where neither candidate exists
  sub_dir <- file.path(td, "proj")
  dir.create(sub_dir)
  expect_error(
    resolve_field_codes_path(sub_dir, must_exist = TRUE),
    "File not found"
  )
})

test_that("import_citations: no .tmp file left after successful write (#95)", {
  td <- tempfile(); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  src  <- file.path(td, "source.json")
  dest <- file.path(td, "dest.json")

  write_fc(list(ref1 = list(itemData = list(title = "Ref"))), src)
  import_citations(src, dest, verbose = FALSE)

  expect_false(file.exists(paste0(dest, ".tmp")))
  expect_true(file.exists(dest))
})
