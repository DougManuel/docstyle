test_that("inject_zotero_citations replaces single marker with field code", {
  # Create a minimal docx with a DOCSTYLE_CITE marker
  doc <- officer::read_docx()
  doc <- officer::body_add_par(doc, "Text with DOCSTYLE_CITE::smith2024 embedded.")
  tmp_docx <- tempfile(fileext = ".docx")
  print(doc, target = tmp_docx)

  # Create mock field-codes.json with citationGroups schema
  tmp_dir <- tempfile()
  dir.create(tmp_dir)

  instr <- paste0(
    'ADDIN ZOTERO_ITEM CSL_CITATION {"citationID":"ABC123",',
    '"properties":{"formattedCitation":"(1)","plainCitation":"(1)","noteIndex":0},',
    '"citationItems":[{"id":100,"uris":["http://z/items/A"],',
    '"itemData":{"id":100,"type":"article-journal","title":"Smith Article"}}],',
    '"schema":"https://github.com/citation-style-language/schema/raw/master/csl-citation.json"}'
  )

  fc_obj <- list(
    docstyle_version = "0.4.5",
    references_hash = "test",
    extracted_from = "test.docx",
    extracted_at = "2026-01-01T00:00:00Z",
    citations = list(
      smith2024 = list(
        itemData = list(id = 100, type = "article-journal", title = "Smith Article"),
        uris = list("http://z/items/A")
      )
    ),
    citationGroups = list(
      grp_ABC123 = list(
        citationID = "ABC123",
        instrText = instr,
        properties = list(formattedCitation = "(1)", plainCitation = "(1)"),
        citekeys = list("smith2024")
      )
    )
  )

  fc_path <- file.path(tmp_dir, "field-codes.json")
  writeLines(jsonlite::toJSON(fc_obj, auto_unbox = TRUE, pretty = TRUE), fc_path)

  # Inject
  out_docx <- tempfile(fileext = ".docx")
  result <- inject_zotero_citations(tmp_docx, fc_path, output_path = out_docx)

  # Check result counts

  expect_equal(result$n_injected, 1L)
  expect_equal(result$n_fallback, 0L)

  # Verify XML
  verify_dir <- tempfile()
  unzip(out_docx, exdir = verify_dir)
  xml_str <- paste(readLines(file.path(verify_dir, "word/document.xml"),
                             warn = FALSE), collapse = "")

  # Marker should be gone
  expect_false(grepl("DOCSTYLE_CITE::", xml_str, fixed = TRUE))

  # Field code should be present
  expect_true(grepl("ADDIN ZOTERO_ITEM", xml_str, fixed = TRUE))
  expect_true(grepl("fldCharType", xml_str, fixed = TRUE))

  # Cleanup
  unlink(c(tmp_dir, verify_dir), recursive = TRUE)
})


test_that("inject_zotero_citations handles grouped marker", {
  doc <- officer::read_docx()
  doc <- officer::body_add_par(doc, "See DOCSTYLE_CITE::smith2024;jones2023 for details.")
  tmp_docx <- tempfile(fileext = ".docx")
  print(doc, target = tmp_docx)

  tmp_dir <- tempfile()
  dir.create(tmp_dir)

  instr <- paste0(
    'ADDIN ZOTERO_ITEM CSL_CITATION {"citationID":"GRP01",',
    '"properties":{"formattedCitation":"(1,2)","plainCitation":"(1,2)","noteIndex":0},',
    '"citationItems":[',
    '{"id":100,"uris":["http://z/items/A"],"itemData":{"id":100,"type":"article-journal","title":"A"}},',
    '{"id":200,"uris":["http://z/items/B"],"itemData":{"id":200,"type":"article-journal","title":"B"}}',
    '],"schema":"https://github.com/citation-style-language/schema/raw/master/csl-citation.json"}'
  )

  fc_obj <- list(
    docstyle_version = "0.4.5",
    citations = list(
      smith2024 = list(
        itemData = list(id = 100, type = "article-journal", title = "A"),
        uris = list("http://z/items/A")
      ),
      jones2023 = list(
        itemData = list(id = 200, type = "article-journal", title = "B"),
        uris = list("http://z/items/B")
      )
    ),
    citationGroups = list(
      grp_GRP01 = list(
        citationID = "GRP01",
        instrText = instr,
        properties = list(formattedCitation = "(1,2)", plainCitation = "(1,2)"),
        citekeys = list("jones2023", "smith2024")
      )
    )
  )

  fc_path <- file.path(tmp_dir, "field-codes.json")
  writeLines(jsonlite::toJSON(fc_obj, auto_unbox = TRUE, pretty = TRUE), fc_path)

  out_docx <- tempfile(fileext = ".docx")
  result <- inject_zotero_citations(tmp_docx, fc_path, output_path = out_docx)

  # Group lookup uses sorted keys, so jones2023;smith2024 should match
  expect_equal(result$n_injected, 1L)
  expect_equal(result$n_fallback, 0L)

  verify_dir <- tempfile()
  unzip(out_docx, exdir = verify_dir)
  xml_str <- paste(readLines(file.path(verify_dir, "word/document.xml"),
                             warn = FALSE), collapse = "")
  expect_false(grepl("DOCSTYLE_CITE::", xml_str, fixed = TRUE))
  expect_true(grepl("ADDIN ZOTERO_ITEM", xml_str, fixed = TRUE))

  unlink(c(tmp_dir, verify_dir), recursive = TRUE)
})


test_that("inject_zotero_citations falls back to synthetic instrText", {
  doc <- officer::read_docx()
  doc <- officer::body_add_par(doc, "New cite DOCSTYLE_CITE::newref2026 here.")
  tmp_docx <- tempfile(fileext = ".docx")
  print(doc, target = tmp_docx)

  tmp_dir <- tempfile()
  dir.create(tmp_dir)

  # Citation in catalog but no citationGroup (new citation added in QMD)
  fc_obj <- list(
    docstyle_version = "0.4.5",
    citations = list(
      newref2026 = list(
        itemData = list(id = 999, type = "article-journal", title = "New Ref"),
        uris = list("http://z/items/NEW")
      )
    ),
    citationGroups = list()
  )

  fc_path <- file.path(tmp_dir, "field-codes.json")
  writeLines(jsonlite::toJSON(fc_obj, auto_unbox = TRUE, pretty = TRUE), fc_path)

  out_docx <- tempfile(fileext = ".docx")
  result <- inject_zotero_citations(tmp_docx, fc_path, output_path = out_docx)

  expect_equal(result$n_injected, 1L)
  expect_equal(result$n_fallback, 1L)

  verify_dir <- tempfile()
  unzip(out_docx, exdir = verify_dir)
  xml_str <- paste(readLines(file.path(verify_dir, "word/document.xml"),
                             warn = FALSE), collapse = "")
  expect_true(grepl("ADDIN ZOTERO_ITEM", xml_str, fixed = TRUE))
  # Display text should be (REF) placeholder
  expect_true(grepl("\\(REF\\)", xml_str))

  unlink(c(tmp_dir, verify_dir), recursive = TRUE)
})


test_that("inject_zotero_citations replaces bibliography marker", {
  doc <- officer::read_docx()
  doc <- officer::body_add_par(doc, "DOCSTYLE_CITE_BIBL")
  tmp_docx <- tempfile(fileext = ".docx")
  print(doc, target = tmp_docx)

  tmp_dir <- tempfile()
  dir.create(tmp_dir)

  fc_obj <- list(
    docstyle_version = "0.4.5",
    citations = list(),
    citationGroups = list()
  )

  fc_path <- file.path(tmp_dir, "field-codes.json")
  writeLines(jsonlite::toJSON(fc_obj, auto_unbox = TRUE, pretty = TRUE), fc_path)

  out_docx <- tempfile(fileext = ".docx")
  result <- inject_zotero_citations(tmp_docx, fc_path, output_path = out_docx)

  expect_equal(result$n_bibl, 1L)

  verify_dir <- tempfile()
  unzip(out_docx, exdir = verify_dir)
  xml_str <- paste(readLines(file.path(verify_dir, "word/document.xml"),
                             warn = FALSE), collapse = "")
  expect_false(grepl("DOCSTYLE_CITE_BIBL", xml_str, fixed = TRUE))
  expect_true(grepl("ZOTERO_BIBL", xml_str, fixed = TRUE))

  unlink(c(tmp_dir, verify_dir), recursive = TRUE)
})
