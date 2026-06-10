# Tests for extract_citations() merge guard and regex hardening
# Regression tests for https://github.com/DougManuel/docstyle/issues/38

# Helper: create a minimal valid DOCX with no Zotero field codes
create_minimal_docx <- function(path) {
  temp_dir <- tempfile("docx_")
  dir.create(file.path(temp_dir, "word"), recursive = TRUE)

  # Minimal document.xml with no Zotero content
  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body><w:p><w:r><w:t>Hello world</w:t></w:r></w:p></w:body>',
    '</w:document>'
  ), file.path(temp_dir, "word", "document.xml"))

  # Minimal [Content_Types].xml
  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
    '<Default Extension="xml" ContentType="application/xml"/>',
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
    '<Override PartName="/word/document.xml" ',
    'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>',
    '</Types>'
  ), file.path(temp_dir, "[Content_Types].xml"))

  # Minimal _rels/.rels
  dir.create(file.path(temp_dir, "_rels"), recursive = TRUE)
  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>',
    '</Relationships>'
  ), file.path(temp_dir, "_rels", ".rels"))

  # Package as zip
  old_wd <- setwd(temp_dir)
  on.exit(setwd(old_wd), add = TRUE)
  zip(path, files = c("[Content_Types].xml", "_rels/.rels", "word/document.xml"),
      flags = "-q")
  unlink(temp_dir, recursive = TRUE)

  path
}


# Helper: create a field-codes.json with test citations
create_field_codes_json <- function(path, n_citations = 3) {
  citations <- list()
  groups <- list()

  for (i in seq_len(n_citations)) {
    key <- paste0("author", 2020 + i)
    citations[[key]] <- list(
      itemData = list(
        id = 10000 + i,
        type = "article-journal",
        title = paste("Test Article", i),
        author = list(list(family = paste0("Author", i), given = "Test")),
        issued = list(`date-parts` = list(list(2020 + i)))
      ),
      uris = list(paste0("http://zotero.org/users/123/items/ITEM", i))
    )

    gkey <- paste0("grp_cid", i)
    groups[[gkey]] <- list(
      citationID = paste0("cid", i),
      instrText = paste0("ADDIN ZOTERO_ITEM CSL_CITATION {\"citationID\":\"cid", i, "\"}"),
      properties = list(
        formattedCitation = paste0("(Author", i, ", ", 2020 + i, ")"),
        plainCitation = paste0("(Author", i, ", ", 2020 + i, ")")
      ),
      citekeys = list(key)
    )
  }

  obj <- list(
    docstyle_version = "0.7.5",
    references_hash = "abc123",
    extracted_from = "test-source.docx",
    extracted_at = "2026-01-01T00:00:00Z",
    zotero_pref = NULL,
    zotero_bibl = NULL,
    citations = citations,
    citationGroups = groups
  )

  writeLines(
    jsonlite::toJSON(obj, auto_unbox = TRUE, pretty = TRUE),
    path
  )
}


# --- Phase 1a: Merge guard tests ---

test_that("merge=TRUE preserves existing citations when 0 are extracted", {
  skip_on_cran()

  temp_dir <- tempfile("merge_test_")
  dir.create(temp_dir)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  # Create a field-codes.json with 3 citations
  fc_path <- file.path(temp_dir, "field-codes.json")
  create_field_codes_json(fc_path, n_citations = 3)

  # Create a minimal DOCX with no Zotero citations
  docx_path <- file.path(temp_dir, "no-zotero.docx")
  create_minimal_docx(docx_path)

  # Call extract_citations with merge=TRUE
  result <- extract_citations(
    docx_path = docx_path,
    output_dir = temp_dir,
    merge = TRUE,
    verbose = FALSE
  )

  # field-codes.json should still have 3 citations (not overwritten)
  fc <- jsonlite::fromJSON(fc_path, simplifyVector = FALSE)
  expect_equal(length(fc$citations), 3)
  expect_true("author2021" %in% names(fc$citations))
  expect_true("author2022" %in% names(fc$citations))
  expect_true("author2023" %in% names(fc$citations))
})


test_that("merge=FALSE overwrites even with existing citations (harvest path)", {
  skip_on_cran()

  temp_dir <- tempfile("merge_test_")
  dir.create(temp_dir)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  # Create a field-codes.json with 3 citations
  fc_path <- file.path(temp_dir, "field-codes.json")
  create_field_codes_json(fc_path, n_citations = 3)

  # Create a minimal DOCX with no Zotero citations
  docx_path <- file.path(temp_dir, "no-zotero.docx")
  create_minimal_docx(docx_path)

  # Call extract_citations with merge=FALSE (default harvest behaviour)
  result <- extract_citations(
    docx_path = docx_path,
    output_dir = temp_dir,
    merge = FALSE,
    verbose = FALSE
  )

  # With no ZOTERO_PREF in the doc, field-codes.json should not be written
  # (the 0-citation path only writes if zotero_pref is non-NULL)
  # But the existing file should be unchanged because the function returns
  # before writing when there are 0 citations and no zotero_pref
  expect_equal(result$citations, list())
})


test_that("merge=TRUE with corrupt existing JSON falls back gracefully", {
  skip_on_cran()

  temp_dir <- tempfile("merge_test_")
  dir.create(temp_dir)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  # Write corrupt JSON
  fc_path <- file.path(temp_dir, "field-codes.json")
  writeLines("{ this is not valid JSON !!!", fc_path)

  # Create a minimal DOCX with no Zotero citations
  docx_path <- file.path(temp_dir, "no-zotero.docx")
  create_minimal_docx(docx_path)

  # Should not error — falls through to normal 0-citation path
  result <- expect_no_error(extract_citations(
    docx_path = docx_path,
    output_dir = temp_dir,
    merge = TRUE,
    verbose = FALSE
  ))

  expect_equal(result$citations, list())
})


# --- Phase 1c: Regex hardening tests ---

test_that("extraction regex matches native Zotero field codes (literal quote)", {
  pattern <- "ADDIN ZOTERO_ITEM CSL_CITATION.*?csl-citation[.]json(\"|&quot;)[}]"

  native_field_code <- paste0(
    'ADDIN ZOTERO_ITEM CSL_CITATION {"citationID":"abc123",',
    '"citationItems":[{"id":12345}],',
    '"schema":"https://github.com/citation-style-language/schema/raw/master/csl-citation.json"}'
  )

  matches <- regmatches(native_field_code, gregexpr(pattern, native_field_code, perl = TRUE))[[1]]
  expect_length(matches, 1)
})


test_that("extraction regex matches XML-escaped field codes (&quot;)", {
  pattern <- "ADDIN ZOTERO_ITEM CSL_CITATION.*?csl-citation[.]json(\"|&quot;)[}]"

  escaped_field_code <- paste0(
    'ADDIN ZOTERO_ITEM CSL_CITATION {&quot;citationID&quot;:&quot;abc123&quot;,',
    '&quot;citationItems&quot;:[{&quot;id&quot;:12345}],',
    '&quot;schema&quot;:&quot;https://github.com/citation-style-language/schema/raw/master/csl-citation.json&quot;}'
  )

  matches <- regmatches(escaped_field_code, gregexpr(pattern, escaped_field_code, perl = TRUE))[[1]]
  expect_length(matches, 1)
})


test_that("extraction regex does not match unrelated ADDIN fields", {
  pattern <- "ADDIN ZOTERO_ITEM CSL_CITATION.*?csl-citation[.]json(\"|&quot;)[}]"

  # ZOTERO_PREF — should not match
  pref_field <- 'ADDIN ZOTERO_PREF {"style":{"styleID":"apa"}}'
  matches <- regmatches(pref_field, gregexpr(pattern, pref_field, perl = TRUE))[[1]]
  expect_length(matches, 0)

  # ZOTERO_BIBL — should not match
  bibl_field <- 'ADDIN ZOTERO_BIBL {"uncited":[]} CSL_BIBLIOGRAPHY'
  matches <- regmatches(bibl_field, gregexpr(pattern, bibl_field, perl = TRUE))[[1]]
  expect_length(matches, 0)
})


# --- Phase 1b: Post-render hook no longer calls extract_citations ---

test_that("update-field-codes.R does not call extract_citations", {
  # Read the post-render hook source and verify Step 4 is removed
  # Try multiple paths: installed package, development tree, testthat working dir
  hook_candidates <- c(
    "_extensions/docstyle/update-field-codes.R",
    "../../_extensions/docstyle/update-field-codes.R",
    file.path(testthat::test_path(), "..", "..", "_extensions", "docstyle", "update-field-codes.R")
  )

  hook_file <- NULL
  for (candidate in hook_candidates) {
    if (file.exists(candidate)) {
      hook_file <- candidate
      break
    }
  }

  skip_if(is.null(hook_file), "update-field-codes.R not found in development tree")

  hook_source <- readLines(hook_file, warn = FALSE)

  # Should NOT contain extract_citations call (Step 4 was removed)
  extract_lines <- grep("extract_citations", hook_source, value = TRUE)
  # Filter out comment lines
  code_lines <- grep("^\\s*#", extract_lines, value = TRUE, invert = TRUE)
  expect_length(code_lines, 0)
})


# --- Phase 2b: Schema metadata tests ---

test_that("harvest writes source=harvest to field-codes.json", {
  skip_on_cran()

  # Use the minimal-example fixture which has Zotero citations
  fixture_path <- system.file(
    "extdata", "minimal-example", "field-codes.json",
    package = "docstyle", mustWork = FALSE
  )
  skip_if(!file.exists(fixture_path), "minimal-example fixture not available")

  fc <- jsonlite::fromJSON(fixture_path, simplifyVector = FALSE)

  # The existing fixture may not have `source` yet, but new harvests should.
  # Test the function directly: extract from a doc with Zotero citations.
  # Since we don't have a Zotero doc fixture for extraction,
  # test that the schema builder includes `source`.
  temp_dir <- tempfile("schema_test_")
  dir.create(temp_dir)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  # Create a minimal DOCX with a Zotero field code
  docx_path <- file.path(temp_dir, "zotero-doc.docx")
  temp_build <- tempfile("docx_build_")
  dir.create(file.path(temp_build, "word"), recursive = TRUE)

  # Document with a valid Zotero citation field code
  zotero_json <- paste0(
    '{"citationID":"abc123","properties":{"formattedCitation":"(Smith, 2024)",',
    '"plainCitation":"(Smith, 2024)","noteIndex":0},',
    '"citationItems":[{"id":12345,"uris":["http://zotero.org/users/1/items/XYZ"],',
    '"itemData":{"id":12345,"type":"article-journal","title":"Test Article",',
    '"author":[{"family":"Smith","given":"John"}],',
    '"issued":{"date-parts":[[2024]]}}}],',
    '"schema":"https://github.com/citation-style-language/schema/raw/master/csl-citation.json"}'
  )

  doc_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body><w:p><w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText> ADDIN ZOTERO_ITEM CSL_CITATION ', zotero_json, ' </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:t>(Smith, 2024)</w:t></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p></w:body>',
    '</w:document>'
  )

  writeLines(doc_xml, file.path(temp_build, "word", "document.xml"))

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
    '<Default Extension="xml" ContentType="application/xml"/>',
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
    '<Override PartName="/word/document.xml" ',
    'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>',
    '</Types>'
  ), file.path(temp_build, "[Content_Types].xml"))

  dir.create(file.path(temp_build, "_rels"), recursive = TRUE)
  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>',
    '</Relationships>'
  ), file.path(temp_build, "_rels", ".rels"))

  old_wd <- setwd(temp_build)
  on.exit(setwd(old_wd), add = TRUE)
  zip(docx_path, files = c("[Content_Types].xml", "_rels/.rels", "word/document.xml"),
      flags = "-q")
  setwd(old_wd)

  # Run extraction
  result <- extract_citations(
    docx_path = docx_path,
    output_dir = temp_dir,
    merge = FALSE,
    verbose = FALSE
  )

  # Read back and verify schema
  fc_path <- file.path(temp_dir, "field-codes.json")
  expect_true(file.exists(fc_path))

  fc <- jsonlite::fromJSON(fc_path, simplifyVector = FALSE)
  expect_equal(fc$source, "harvest")
  expect_true(nchar(fc$extracted_from) > 0)
  expect_true(nchar(fc$extracted_at) > 0)
  expect_true(grepl("^\\d{4}-\\d{2}-\\d{2}T", fc$extracted_at))
})
