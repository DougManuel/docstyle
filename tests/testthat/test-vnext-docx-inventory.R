source(testthat::test_path(
  "../../dev/vnext/characterization/inspect-docx.R"
))

test_that("DOCX inventory describes package and semantic structures", {
  path <- testthat::test_path(
    "../../inst/extdata/minimal-example/minimal-example.docx"
  )
  inventory <- inspect_legacy_docx(path)

  expect_identical(inventory$schemaVersion, 1L)
  expect_true("word/document.xml" %in% inventory$packageParts)
  expect_gt(inventory$counts$paragraphs, 10L)
  expect_gt(inventory$counts$tables, 0L)
  expect_gt(inventory$counts$sections, 0L)
  expect_gt(inventory$fields$total, 0L)
  expect_match(inventory$textHash, "^sha256:[0-9a-f]{64}$")
  expect_false(any(grepl(tempdir(), unlist(inventory), fixed = TRUE)))
})

test_that("field classifier distinguishes Zotero and DOCSTYLE fields", {
  expect_equal(
    classify_docx_field("ADDIN ZOTERO_ITEM CSL_CITATION {}"),
    "zotero-citation"
  )
  expect_equal(
    classify_docx_field('ADDIN DOCSTYLE {"type":"div"}'),
    "docstyle"
  )
  expect_equal(
    classify_docx_field("ADDIN ZOTERO_PREF {}"),
    "zotero-preferences"
  )
  expect_equal(classify_docx_field("PAGE"), "page")
})

test_that("DOCX inventory records comments and tracked revisions", {
  path <- testthat::test_path(
    "../../inst/extdata/minimal-example/comments-revisions-test-roundtrip.docx"
  )
  inventory <- inspect_legacy_docx(path)

  expect_gt(inventory$counts$comments, 0L)
  expect_gt(inventory$counts$insertions, 0L)
  expect_gt(inventory$counts$deletions, 0L)
  expect_true("word/comments.xml" %in% inventory$packageParts)
})
