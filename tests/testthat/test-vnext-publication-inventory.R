source(testthat::test_path(
  "../../dev/vnext/characterization/inspect-publication.R"
))

test_that("pdfinfo parser retains only stable publication properties", {
  parsed <- parse_characterization_pdfinfo(c(
    "Title:           Fixture title",
    "Pages:           12",
    "Page size:       612 x 792 pts (letter)",
    "Tagged:          yes",
    "Encrypted:       no",
    "PDF version:     1.7",
    "CreationDate:    Mon Jul 13 10:00:00 2026"
  ))

  expect_equal(parsed$title, "Fixture title")
  expect_identical(parsed$pages, 12L)
  expect_true(parsed$tagged)
  expect_false(parsed$encrypted)
  expect_equal(parsed$pageSize, "612 x 792 pts (letter)")
  expect_equal(parsed$pdfVersion, "1.7")
  expect_false("creationDate" %in% names(parsed))
})

test_that("JATS inventory records native scholarly structures", {
  path <- tempfile(fileext = ".xml")
  writeLines(c(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<article article-type="protocol">',
    '  <front><article-meta>',
    '    <title-group><article-title>Fixture</article-title></title-group>',
    '    <abstract><p>A structured abstract.</p></abstract>',
    '  </article-meta></front>',
    '  <body><sec id="s1"><title>Methods</title><p>Text.</p>',
    '    <table-wrap id="t1"><table><tbody><tr><td>A</td></tr></tbody></table></table-wrap>',
    '    <fig id="f1"><caption><p>Workflow.</p></caption></fig>',
    '  </sec></body>',
    '  <back><ref-list><ref id="r1"><mixed-citation>Reference.</mixed-citation></ref></ref-list></back>',
    '</article>'
  ), path)

  inventory <- inspect_legacy_jats(path)

  expect_identical(inventory$schemaVersion, 1L)
  expect_identical(inventory$counts$sections, 1L)
  expect_identical(inventory$counts$tables, 1L)
  expect_identical(inventory$counts$figures, 1L)
  expect_identical(inventory$counts$references, 1L)
  expect_match(inventory$abstractHash, "^sha256:[0-9a-f]{64}$")
  expect_match(inventory$textHash, "^sha256:[0-9a-f]{64}$")
})

make_fake_pdftoppm <- function(path) {
  writeLines(c(
    "#!/bin/sh",
    "prefix=''",
    "for argument in \"$@\"; do prefix=\"$argument\"; done",
    "printf '\\211PNG\\r\\n\\032\\n' > \"$prefix.png\""
  ), path)
  Sys.chmod(path, mode = "0755")
  path
}

test_that("PDF rasterizer creates deterministically named selected pages", {
  root <- tempfile("publication-pages-")
  dir.create(root)
  pdf <- file.path(root, "fixture.pdf")
  file.create(pdf)
  fake_pdftoppm <- make_fake_pdftoppm(file.path(root, "pdftoppm"))

  pages <- rasterize_pdf_pages(
    path = pdf,
    pages = c(1L, 3L),
    output_dir = file.path(root, "pages"),
    prefix = "docstyle-typst",
    pdftoppm_bin = fake_pdftoppm
  )

  expect_equal(
    basename(pages),
    c("docstyle-typst-page-001.png", "docstyle-typst-page-003.png")
  )
  expect_true(all(file.exists(pages)))
})
