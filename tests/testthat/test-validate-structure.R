test_that("validate_docx_structure returns expected structure", {
  # Test with a minimal valid docx
  # For now, test error handling for missing file
  expect_error(
    validate_docx_structure("nonexistent.docx"),
    "File not found"
  )
})

test_that("validate_xml_wellformed catches malformed XML", {
  temp_dir <- tempfile("test_xml_")
  dir.create(temp_dir)
  dir.create(file.path(temp_dir, "word"))
  on.exit(unlink(temp_dir, recursive = TRUE))

  # Create malformed XML
  writeLines("<broken><unclosed>", file.path(temp_dir, "word", "document.xml"))

  result <- docstyle:::validate_xml_wellformed(temp_dir, verbose = FALSE)

  expect_false(result$valid)
  expect_length(result$errors, 1)
  expect_match(result$errors[1], "document.xml")
})

test_that("validate_xml_wellformed passes for valid XML", {
  temp_dir <- tempfile("test_xml_")
  dir.create(temp_dir)
  dir.create(file.path(temp_dir, "word"))
  on.exit(unlink(temp_dir, recursive = TRUE))

  # Create valid XML
  writeLines('<?xml version="1.0"?><root><child/></root>',
             file.path(temp_dir, "word", "document.xml"))

  result <- docstyle:::validate_xml_wellformed(temp_dir, verbose = FALSE)

  expect_true(result$valid)
  expect_length(result$errors, 0)
})

test_that("validate_whitespace_preservation catches missing xml:space", {
  temp_dir <- tempfile("test_ws_")
  dir.create(temp_dir)
  dir.create(file.path(temp_dir, "word"))
  on.exit(unlink(temp_dir, recursive = TRUE))

  # Create document with w:t containing leading whitespace but no xml:space
  doc_xml <- '<?xml version="1.0"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:r>
        <w:t> leading space</w:t>
      </w:r>
    </w:p>
  </w:body>
</w:document>'
  writeLines(doc_xml, file.path(temp_dir, "word", "document.xml"))

  result <- docstyle:::validate_whitespace_preservation(temp_dir, verbose = FALSE)

  expect_false(result$valid)
  expect_length(result$errors, 1)
  expect_match(result$errors[1], "xml:space")
})

test_that("validate_whitespace_preservation passes with xml:space='preserve'", {
  temp_dir <- tempfile("test_ws_")
  dir.create(temp_dir)
  dir.create(file.path(temp_dir, "word"))
  on.exit(unlink(temp_dir, recursive = TRUE))

  # Create document with proper xml:space attribute
  doc_xml <- '<?xml version="1.0"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
            xmlns:xml="http://www.w3.org/XML/1998/namespace">
  <w:body>
    <w:p>
      <w:r>
        <w:t xml:space="preserve"> leading space</w:t>
      </w:r>
    </w:p>
  </w:body>
</w:document>'
  writeLines(doc_xml, file.path(temp_dir, "word", "document.xml"))

  result <- docstyle:::validate_whitespace_preservation(temp_dir, verbose = FALSE)

  expect_true(result$valid)
  expect_length(result$errors, 0)
})

test_that("validate_deletions catches w:t inside w:del", {
  temp_dir <- tempfile("test_del_")
  dir.create(temp_dir)
  dir.create(file.path(temp_dir, "word"))
  on.exit(unlink(temp_dir, recursive = TRUE))

  # Create document with invalid w:t inside w:del
  doc_xml <- '<?xml version="1.0"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:del w:author="Test">
        <w:r>
          <w:t>This should be w:delText</w:t>
        </w:r>
      </w:del>
    </w:p>
  </w:body>
</w:document>'
  writeLines(doc_xml, file.path(temp_dir, "word", "document.xml"))

  result <- docstyle:::validate_deletions(temp_dir, verbose = FALSE)

  expect_false(result$valid)
  expect_length(result$errors, 1)
  expect_match(result$errors[1], "w:delText")
})

test_that("validate_deletions passes with proper w:delText", {
  temp_dir <- tempfile("test_del_")
  dir.create(temp_dir)
  dir.create(file.path(temp_dir, "word"))
  on.exit(unlink(temp_dir, recursive = TRUE))

  # Create document with proper w:delText inside w:del
  doc_xml <- '<?xml version="1.0"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:del w:author="Test">
        <w:r>
          <w:delText>Properly deleted text</w:delText>
        </w:r>
      </w:del>
    </w:p>
  </w:body>
</w:document>'
  writeLines(doc_xml, file.path(temp_dir, "word", "document.xml"))

  result <- docstyle:::validate_deletions(temp_dir, verbose = FALSE)

  expect_true(result$valid)
  expect_length(result$errors, 0)
})

test_that("validate_unique_ids catches duplicate comment IDs", {
  temp_dir <- tempfile("test_ids_")
  dir.create(temp_dir)
  dir.create(file.path(temp_dir, "word"))
  on.exit(unlink(temp_dir, recursive = TRUE))

  # Create document with duplicate comment range IDs
  doc_xml <- '<?xml version="1.0"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:commentRangeStart w:id="1"/>
      <w:r><w:t>Text</w:t></w:r>
      <w:commentRangeEnd w:id="1"/>
    </w:p>
    <w:p>
      <w:commentRangeStart w:id="1"/>
      <w:r><w:t>Duplicate ID</w:t></w:r>
      <w:commentRangeEnd w:id="1"/>
    </w:p>
  </w:body>
</w:document>'
  writeLines(doc_xml, file.path(temp_dir, "word", "document.xml"))

  result <- docstyle:::validate_unique_ids(temp_dir, verbose = FALSE)

  expect_false(result$valid)
  expect_true(any(grepl("Duplicate", result$errors)))
})

test_that("validate_content_types catches missing [Content_Types].xml", {
  temp_dir <- tempfile("test_ct_")
  dir.create(temp_dir)
  on.exit(unlink(temp_dir, recursive = TRUE))

  result <- docstyle:::validate_content_types(temp_dir, verbose = FALSE)

  expect_false(result$valid)
  expect_match(result$errors[1], "Content_Types")
})

# ---------------------------------------------------------------------------
# RSID validation (#11)
# ---------------------------------------------------------------------------

make_rsid_doc <- function(rsid_val, attr = "rsidR") {
  paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    sprintf('<w:p w:%s="%s"><w:r><w:t>Text</w:t></w:r></w:p>', attr, rsid_val),
    '<w:sectPr/>',
    '</w:body>',
    '</w:document>'
  )
}

setup_rsid_dir <- function(doc_xml) {
  td <- tempfile("test_rsid_")
  dir.create(file.path(td, "word"), recursive = TRUE)
  writeLines(doc_xml, file.path(td, "word", "document.xml"))
  td
}

test_that("validate_rsids passes for valid 8-digit hex RSIDs (#11)", {
  td <- setup_rsid_dir(make_rsid_doc("00A1B2C3"))
  on.exit(unlink(td, recursive = TRUE))

  result <- docstyle:::validate_rsids(td, verbose = FALSE)
  expect_true(result$valid)
  expect_length(result$errors, 0L)
})

test_that("validate_rsids passes for lowercase hex RSIDs (#11)", {
  td <- setup_rsid_dir(make_rsid_doc("00a1b2c3"))
  on.exit(unlink(td, recursive = TRUE))

  result <- docstyle:::validate_rsids(td, verbose = FALSE)
  expect_true(result$valid)
  expect_length(result$errors, 0L)
})

test_that("validate_rsids catches RSIDs that are too short (#11)", {
  td <- setup_rsid_dir(make_rsid_doc("12AB"))
  on.exit(unlink(td, recursive = TRUE))

  result <- docstyle:::validate_rsids(td, verbose = FALSE)
  expect_false(result$valid)
  expect_true(any(grepl("12AB", result$errors)))
})

test_that("validate_rsids catches RSIDs with non-hex characters (#11)", {
  td <- setup_rsid_dir(make_rsid_doc("GGGGGGGG"))
  on.exit(unlink(td, recursive = TRUE))

  result <- docstyle:::validate_rsids(td, verbose = FALSE)
  expect_false(result$valid)
  expect_true(any(grepl("GGGGGGGG", result$errors)))
})

test_that("validate_rsids catches invalid rsidRPr attribute (#11)", {
  td <- setup_rsid_dir(make_rsid_doc("ZZZZZZZZ", attr = "rsidRPr"))
  on.exit(unlink(td, recursive = TRUE))

  result <- docstyle:::validate_rsids(td, verbose = FALSE)
  expect_false(result$valid)
  expect_true(any(grepl("rsidRPr", result$errors)))
})

test_that("validate_rsids deduplicates repeated invalid values (#11)", {
  doc_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    '<w:p w:rsidR="ZZZZZZZZ"><w:r><w:t>One</w:t></w:r></w:p>',
    '<w:p w:rsidR="ZZZZZZZZ"><w:r><w:t>Two</w:t></w:r></w:p>',
    '<w:sectPr/>',
    '</w:body>',
    '</w:document>'
  )
  td <- setup_rsid_dir(doc_xml)
  on.exit(unlink(td, recursive = TRUE))

  result <- docstyle:::validate_rsids(td, verbose = FALSE)
  expect_false(result$valid)
  expect_equal(sum(grepl("ZZZZZZZZ", result$errors)), 1L)
})

test_that("validate_rsids returns valid when document.xml is absent (#11)", {
  td <- tempfile("test_rsid_nofile_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))

  result <- docstyle:::validate_rsids(td, verbose = FALSE)
  expect_true(result$valid)
  expect_length(result$errors, 0L)
})

test_that("validate_rsids handles malformed document.xml without crashing (#11)", {
  td <- tempfile("test_rsid_malformed_")
  dir.create(td)
  dir.create(file.path(td, "word"))
  on.exit(unlink(td, recursive = TRUE))

  writeLines("<broken><unclosed>", file.path(td, "word", "document.xml"))
  result <- docstyle:::validate_rsids(td, verbose = FALSE)
  expect_false(result$valid)
  expect_match(result$errors[1], "Failed to parse")
})

test_that("validate_docx_structure rsids check: valid=TRUE with warnings for bad RSIDs (#11)", {
  # Build a minimal DOCX zip with one paragraph carrying an invalid RSID
  td <- tempfile("test_rsid_integ_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))

  docx_dir <- file.path(td, "docx_parts")
  dir.create(file.path(docx_dir, "word"), recursive = TRUE)
  dir.create(file.path(docx_dir, "_rels"))
  dir.create(file.path(docx_dir, "word", "_rels"))

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n',
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
    '<Default Extension="rels" ',
    'ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
    '<Override PartName="/word/document.xml" ',
    'ContentType="application/vnd.openxmlformats-officedocument.',
    'wordprocessingml.document.main+xml"/>',
    '</Types>'
  ), file.path(docx_dir, "[Content_Types].xml"))

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/',
    'officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>',
    '</Relationships>'
  ), file.path(docx_dir, "_rels", ".rels"))

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>',
    '\n'
  ), file.path(docx_dir, "word", "_rels", "document.xml.rels"))

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    '<w:p w:rsidR="ZZZZZZZZ"><w:r><w:t>Bad RSID paragraph</w:t></w:r></w:p>',
    '<w:sectPr/>',
    '</w:body>',
    '</w:document>'
  ), file.path(docx_dir, "word", "document.xml"))

  docx_path <- file.path(td, "test.docx")
  old_wd <- getwd()
  setwd(docx_dir)
  on.exit(setwd(old_wd), add = TRUE)
  zip(docx_path, files = list.files(".", recursive = TRUE), flags = "-q")
  setwd(old_wd)

  result <- validate_docx_structure(docx_path,
                                    checks = c("rsids"),
                                    verbose = FALSE)
  expect_true(result$valid)
  expect_gt(length(result$warnings), 0L)
  expect_true(any(grepl("ZZZZZZZZ", result$warnings)))
})
