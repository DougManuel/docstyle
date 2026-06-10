# Tests for per-section headers/footers, "same as previous" cascade,
# and raw-XML write helpers

# --- Helper: create a minimal unzipped DOCX directory ---
create_mock_docx_dir <- function() {
  temp_dir <- tempfile("docx_test_")
  dir.create(file.path(temp_dir, "word", "_rels"), recursive = TRUE)

  # Minimal document.xml.rels
  rels_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>',
    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/fontTable" Target="fontTable.xml"/>',
    '</Relationships>'
  )
  writeLines(rels_xml, file.path(temp_dir, "word", "_rels", "document.xml.rels"))

  # Minimal [Content_Types].xml
  ct_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
    '<Default Extension="xml" ContentType="application/xml"/>',
    '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>',
    '</Types>'
  )
  writeLines(ct_xml, file.path(temp_dir, "[Content_Types].xml"))

  temp_dir
}

# Reuse section_marker helper from test-section-assembly.R
build_section_body <- function(...) {
  paras <- paste0(list(...), collapse = "")
  paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:body>',
    paras,
    '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/>',
    '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" ',
    'w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>',
    '</w:body></w:document>'
  )
}

content_para <- function(text) {
  paste0('<w:p><w:r><w:t>', text, '</w:t></w:r></w:p>')
}

section_marker <- function(class, page_break = "false", line_numbers = "none",
                           closing = FALSE, attrs = list()) {
  prefix <- if (closing) "DOCSTYLE_SECTION_END" else "DOCSTYLE_SECTION"
  marker_text <- paste0(prefix, "::", class, "::", page_break, "::", line_numbers)

  payload <- list(type = "section", version = 2L, class = class)
  payload[["page-break"]] <- page_break == "true"
  payload[["line-numbers"]] <- line_numbers
  for (name in names(attrs)) {
    payload[[name]] <- attrs[[name]]
  }
  json <- jsonlite::toJSON(payload, auto_unbox = TRUE)

  paste0(
    '<w:p><w:pPr><w:suppressLineNumbers/></w:pPr>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE ', json, ' </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:t>', marker_text, '</w:t></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r>',
    '</w:p>'
  )
}

ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
        r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships")


# ==========================================================================
# Raw-XML write helpers
# ==========================================================================

test_that("add_raw_relationship() adds relationship with next rId", {
  temp_dir <- create_mock_docx_dir()
  on.exit(unlink(temp_dir, recursive = TRUE))

  rid <- add_raw_relationship(temp_dir, "footer3.xml",
    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer")

  expect_equal(rid, "rId3")  # max existing is rId2

  # Verify the relationship was written
  rels <- xml2::read_xml(file.path(temp_dir, "word", "_rels", "document.xml.rels"))
  rels_ns <- c(d1 = "http://schemas.openxmlformats.org/package/2006/relationships")
  new_rel <- xml2::xml_find_first(rels, ".//d1:Relationship[@Id='rId3']", ns = rels_ns)
  expect_false(inherits(new_rel, "xml_missing"))
  expect_equal(xml2::xml_attr(new_rel, "Target"), "footer3.xml")
})

test_that("add_raw_relationship() increments correctly with multiple calls", {
  temp_dir <- create_mock_docx_dir()
  on.exit(unlink(temp_dir, recursive = TRUE))

  rid1 <- add_raw_relationship(temp_dir, "footer3.xml",
    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer")
  rid2 <- add_raw_relationship(temp_dir, "header3.xml",
    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/header")

  expect_equal(rid1, "rId3")
  expect_equal(rid2, "rId4")
})

test_that("add_raw_content_type() adds Override element", {
  temp_dir <- create_mock_docx_dir()
  on.exit(unlink(temp_dir, recursive = TRUE))

  add_raw_content_type(temp_dir, "/word/footer3.xml",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml")

  ct <- xml2::read_xml(file.path(temp_dir, "[Content_Types].xml"))
  ct_ns <- c(ct = "http://schemas.openxmlformats.org/package/2006/content-types")
  override <- xml2::xml_find_first(ct,
    ".//ct:Override[@PartName='/word/footer3.xml']", ns = ct_ns)
  expect_false(inherits(override, "xml_missing"))
})

test_that("add_raw_content_type() does not duplicate existing overrides", {
  temp_dir <- create_mock_docx_dir()
  on.exit(unlink(temp_dir, recursive = TRUE))

  add_raw_content_type(temp_dir, "/word/footer3.xml",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml")
  add_raw_content_type(temp_dir, "/word/footer3.xml",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml")

  ct <- xml2::read_xml(file.path(temp_dir, "[Content_Types].xml"))
  ct_ns <- c(ct = "http://schemas.openxmlformats.org/package/2006/content-types")
  overrides <- xml2::xml_find_all(ct,
    ".//ct:Override[@PartName='/word/footer3.xml']", ns = ct_ns)
  expect_length(overrides, 1)
})

test_that("write_footer_to_docx() writes file and returns rId", {
  temp_dir <- create_mock_docx_dir()
  on.exit(unlink(temp_dir, recursive = TRUE))

  footer_xml <- build_footer_xml("Page 1", "center", "")
  rid <- write_footer_to_docx(temp_dir, footer_xml, "footer3.xml")

  expect_true(grepl("^rId", rid))
  expect_true(file.exists(file.path(temp_dir, "word", "footer3.xml")))
})

test_that("write_header_to_docx() writes file and returns rId", {
  temp_dir <- create_mock_docx_dir()
  on.exit(unlink(temp_dir, recursive = TRUE))

  header_xml <- build_header_xml("Title", "center", "")
  rid <- write_header_to_docx(temp_dir, header_xml, "header3.xml")

  expect_true(grepl("^rId", rid))
  expect_true(file.exists(file.path(temp_dir, "word", "header3.xml")))
})


# ==========================================================================
# Header/footer XML builders
# ==========================================================================

test_that("build_header_xml() creates valid XML with content", {
  xml_str <- build_header_xml("Test Header", "center", "")
  xml <- xml2::read_xml(xml_str)

  hdr_ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  text <- xml2::xml_text(xml2::xml_find_first(xml, ".//w:t", hdr_ns))
  expect_equal(text, "Test Header")
})

test_that("build_header_xml() creates valid empty header", {
  xml_str <- build_header_xml("", "center", "")
  xml <- xml2::read_xml(xml_str)

  hdr_ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  # Should still have a paragraph but no w:t text
  p <- xml2::xml_find_first(xml, ".//w:p", hdr_ns)
  expect_false(inherits(p, "xml_missing"))
})

test_that("build_multi_position_header_xml_raw() creates left/center/right content", {
  config <- list(left = "Author", center = "", right = "Page {page}")
  xml_str <- build_multi_position_header_xml_raw(config, "")
  xml <- xml2::read_xml(xml_str)

  hdr_ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  # Should have tab stops
  tabs <- xml2::xml_find_all(xml, ".//w:tab", hdr_ns)
  expect_true(length(tabs) >= 1)

  # Should contain "Author" text
  all_text <- paste(xml2::xml_text(xml2::xml_find_all(xml, ".//w:t", hdr_ns)),
                    collapse = "")
  expect_true(grepl("Author", all_text))
})

test_that("build_multi_position_footer_xml_raw() creates footer with rPr", {
  config <- list(left = "Draft", center = "", right = "Page {page}")
  rPr <- '<w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial"/><w:sz w:val="16"/></w:rPr>'
  xml_str <- build_multi_position_footer_xml_raw(config, rPr)
  xml <- xml2::read_xml(xml_str)

  ftr_ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  # Should have rPr with font info
  fonts <- xml2::xml_find_first(xml, ".//w:rFonts", ftr_ns)
  expect_false(inherits(fonts, "xml_missing"))
  expect_equal(xml2::xml_attr(fonts, "ascii"), "Arial")
})


# ==========================================================================
# inject_section_headers_footers() — "same as previous" cascade
# ==========================================================================

test_that("inject_section_headers_footers() returns 0 when footer/header disabled", {
  xml_str <- build_section_body(
    content_para("Content"),
    section_marker("section-body", attrs = list("footer-left" = "Draft")),
    content_para("More")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  temp_dir <- create_mock_docx_dir()
  on.exit(unlink(temp_dir, recursive = TRUE))

  page_config <- list(size = "letter")  # No footer or header config
  assembly_result <- assemble_section_breaks(body, ns, page_config)

  n <- inject_section_headers_footers(body, ns, temp_dir, page_config,
                                      assembly_result)
  expect_equal(n, 0L)
})

test_that("inject_section_headers_footers() injects into body sectPr when no section markers", {
  xml_str <- build_section_body(content_para("Just content"))
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  temp_dir <- create_mock_docx_dir()
  on.exit(unlink(temp_dir, recursive = TRUE))

  page_config <- list(
    footer = list(enabled = TRUE, left = "Draft", right = "Page {page}")
  )
  assembly_result <- assemble_section_breaks(body, ns, page_config)

  n <- inject_section_headers_footers(body, ns, temp_dir, page_config,
                                      assembly_result)
  # With no section markers, the simple path injects directly into body sectPr
  expect_equal(n, 1L)

  # Verify footerReference was added to body sectPr
  ns_r <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
            r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships")
  body_sectPr <- xml2::xml_find_first(body, "w:sectPr", ns)
  ftr_refs <- xml2::xml_find_all(body_sectPr, "w:footerReference", ns_r)
  expect_true(length(ftr_refs) > 0)
})

test_that("inject_section_headers_footers() injects footer into section with explicit text", {
  xml_str <- build_section_body(
    content_para("Front"),
    section_marker("section-body", attrs = list(
      "footer-left" = "Draft",
      "footer-right" = "Page {page}"
    )),
    content_para("Body")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  temp_dir <- create_mock_docx_dir()
  on.exit(unlink(temp_dir, recursive = TRUE))

  page_config <- list(
    footer = list(enabled = TRUE, left = "", right = "", rPr_xml = ""),
    size = "letter"
  )
  assembly_result <- assemble_section_breaks(body, ns, page_config)

  n <- inject_section_headers_footers(body, ns, temp_dir, page_config,
                                      assembly_result)

  # Should inject into both the mid-doc sectPr and body sectPr
  expect_true(n > 0)

  # Check that footerReference was added to body sectPr
  body_sectPr <- xml2::xml_find_first(body, "w:sectPr", ns)
  ftr_refs <- xml2::xml_find_all(body_sectPr, "w:footerReference", ns)
  expect_true(length(ftr_refs) > 0)

  # Verify footer file was created
  footer_files <- list.files(file.path(temp_dir, "word"), pattern = "^footer\\d+\\.xml$")
  expect_true(length(footer_files) > 0)
})

test_that("inject_section_headers_footers() applies 'same as previous' cascade", {
  # Two sections: first has explicit footer, second inherits
  xml_str <- build_section_body(
    content_para("Front"),
    section_marker("section-body", attrs = list(
      "footer-left" = "Draft",
      "footer-right" = "Page {page}"
    )),
    content_para("Body"),
    section_marker("section-appendix"),  # No footer attrs — inherits
    content_para("Appendix")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  temp_dir <- create_mock_docx_dir()
  on.exit(unlink(temp_dir, recursive = TRUE))

  page_config <- list(
    footer = list(enabled = TRUE, left = "", right = "", rPr_xml = ""),
    size = "letter"
  )
  assembly_result <- assemble_section_breaks(body, ns, page_config)

  n <- inject_section_headers_footers(body, ns, temp_dir, page_config,
                                      assembly_result)

  # Both sections should get footers (second inherits from first)
  expect_true(n >= 2)

  # Both mid-doc sectPr paras should have footerReference
  sect_paras <- xml2::xml_find_all(body, "w:p[w:pPr/w:sectPr]", ns)
  for (sp in sect_paras) {
    sectPr <- xml2::xml_find_first(sp, "w:pPr/w:sectPr", ns)
    ftr_ref <- xml2::xml_find_first(sectPr, "w:footerReference", ns)
    expect_false(inherits(ftr_ref, "xml_missing"),
      info = "Each section's sectPr should have a footerReference")
  }
})

test_that("inject_section_headers_footers() suppresses footer when footer='false'", {
  xml_str <- build_section_body(
    content_para("Front"),
    section_marker("section-body", attrs = list(
      "footer-left" = "Draft"
    )),
    content_para("Body"),
    section_marker("section-back-matter", attrs = list(
      "footer" = "false"
    )),
    content_para("Back matter")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  temp_dir <- create_mock_docx_dir()
  on.exit(unlink(temp_dir, recursive = TRUE))

  page_config <- list(
    footer = list(enabled = TRUE, left = "", right = "", rPr_xml = ""),
    size = "letter"
  )
  assembly_result <- assemble_section_breaks(body, ns, page_config)

  n <- inject_section_headers_footers(body, ns, temp_dir, page_config,
                                      assembly_result)

  # First section should have footer, second should not
  sect_paras <- xml2::xml_find_all(body, "w:p[w:pPr/w:sectPr]", ns)
  expect_length(sect_paras, 2)

  # First sectPr: should have footerReference
  sectPr1 <- xml2::xml_find_first(sect_paras[[1]], "w:pPr/w:sectPr", ns)
  ftr_ref1 <- xml2::xml_find_first(sectPr1, "w:footerReference", ns)
  expect_false(inherits(ftr_ref1, "xml_missing"))

  # Second sectPr: should have footerReference pointing to empty footer.

  # In Word, a MISSING footerReference means "inherit from previous section",
  # not "no footer". To suppress, we must reference an empty footer file.
  sectPr2 <- xml2::xml_find_first(sect_paras[[2]], "w:pPr/w:sectPr", ns)
  ftr_ref2 <- xml2::xml_find_first(sectPr2, "w:footerReference", ns)
  expect_false(inherits(ftr_ref2, "xml_missing"),
    info = "Suppressed footer must have footerReference to empty file, not be missing")

  # The empty footer file should exist and contain no text
  ns_r <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
            r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships")
  rid2 <- xml2::xml_attr(ftr_ref2, "id")
  rels_path <- file.path(temp_dir, "word", "_rels", "document.xml.rels")
  rels_xml <- xml2::read_xml(rels_path)
  rels_ns <- c(d1 = "http://schemas.openxmlformats.org/package/2006/relationships")
  rel_node <- xml2::xml_find_first(rels_xml,
    sprintf('.//d1:Relationship[@Id="%s"]', rid2), ns = rels_ns)
  footer_file <- xml2::xml_attr(rel_node, "Target")
  footer_xml <- xml2::read_xml(file.path(temp_dir, "word", footer_file))
  text_nodes <- xml2::xml_find_all(footer_xml, ".//w:t", ns)
  expect_length(text_nodes, 0)
})

test_that("inject_section_headers_footers() deduplicates identical footer configs", {
  # Two sections with same footer text should share a single footer file
  xml_str <- build_section_body(
    content_para("Front"),
    section_marker("section-body", attrs = list(
      "footer-left" = "Draft"
    )),
    content_para("Body"),
    section_marker("section-appendix", attrs = list(
      "footer-left" = "Draft"  # Same text
    )),
    content_para("Appendix")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  temp_dir <- create_mock_docx_dir()
  on.exit(unlink(temp_dir, recursive = TRUE))

  page_config <- list(
    footer = list(enabled = TRUE, left = "", right = "", rPr_xml = ""),
    size = "letter"
  )
  assembly_result <- assemble_section_breaks(body, ns, page_config)

  inject_section_headers_footers(body, ns, temp_dir, page_config,
                                 assembly_result)

  # Both sectPrs should reference the same rId
  sect_paras <- xml2::xml_find_all(body, "w:p[w:pPr/w:sectPr]", ns)
  rids <- vapply(sect_paras, function(sp) {
    sectPr <- xml2::xml_find_first(sp, "w:pPr/w:sectPr", ns)
    ftr_ref <- xml2::xml_find_first(sectPr, "w:footerReference[@w:type='default']", ns)
    if (inherits(ftr_ref, "xml_missing")) return(NA_character_)
    xml2::xml_attr(ftr_ref, "id")
  }, character(1))

  expect_equal(rids[[1]], rids[[2]])
})

test_that("inject_section_headers_footers() handles first-page suppression", {
  xml_str <- build_section_body(
    content_para("Front"),
    section_marker("section-body", attrs = list(
      "footer-left" = "Draft"
    )),
    content_para("Body")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  temp_dir <- create_mock_docx_dir()
  on.exit(unlink(temp_dir, recursive = TRUE))

  page_config <- list(
    footer = list(
      enabled = TRUE, left = "", right = "", rPr_xml = "",
      first_page = FALSE  # Suppress footer on first page
    ),
    size = "letter"
  )
  assembly_result <- assemble_section_breaks(body, ns, page_config)

  inject_section_headers_footers(body, ns, temp_dir, page_config,
                                 assembly_result)

  # Should have both default and first footerReference
  sect_paras <- xml2::xml_find_all(body, "w:p[w:pPr/w:sectPr]", ns)
  sectPr <- xml2::xml_find_first(sect_paras[[1]], "w:pPr/w:sectPr", ns)
  ftr_refs <- xml2::xml_find_all(sectPr, "w:footerReference", ns)
  types <- vapply(ftr_refs, function(r) xml2::xml_attr(r, "type"), character(1))
  expect_true("default" %in% types)
  expect_true("first" %in% types)

  # Should have titlePg element
  titlePg <- xml2::xml_find_first(sectPr, "w:titlePg", ns)
  expect_false(inherits(titlePg, "xml_missing"))
})

test_that("inject_section_headers_footers() injects both header and footer", {
  xml_str <- build_section_body(
    content_para("Front"),
    section_marker("section-body", attrs = list(
      "footer-left" = "Draft",
      "header-left" = "Author Name"
    )),
    content_para("Body")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  temp_dir <- create_mock_docx_dir()
  on.exit(unlink(temp_dir, recursive = TRUE))

  page_config <- list(
    footer = list(enabled = TRUE, left = "", right = "", rPr_xml = ""),
    header = list(enabled = TRUE, left = "", right = "", rPr_xml = ""),
    size = "letter"
  )
  assembly_result <- assemble_section_breaks(body, ns, page_config)

  n <- inject_section_headers_footers(body, ns, temp_dir, page_config,
                                      assembly_result)

  expect_true(n > 0)

  # Body sectPr should have both header and footer references
  body_sectPr <- xml2::xml_find_first(body, "w:sectPr", ns)
  ftr_refs <- xml2::xml_find_all(body_sectPr, "w:footerReference", ns)
  hdr_refs <- xml2::xml_find_all(body_sectPr, "w:headerReference", ns)
  expect_true(length(ftr_refs) > 0)
  expect_true(length(hdr_refs) > 0)

  # Check files were created
  footer_files <- list.files(file.path(temp_dir, "word"), pattern = "^footer\\d+\\.xml$")
  header_files <- list.files(file.path(temp_dir, "word"), pattern = "^header\\d+\\.xml$")
  expect_true(length(footer_files) > 0)
  expect_true(length(header_files) > 0)
})

test_that("inject_section_headers_footers() uses YAML defaults for first section without attrs", {
  # Section marker with no footer attrs — should use YAML defaults
  xml_str <- build_section_body(
    content_para("Front"),
    section_marker("section-body"),  # No footer/header attrs
    content_para("Body")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  temp_dir <- create_mock_docx_dir()
  on.exit(unlink(temp_dir, recursive = TRUE))

  page_config <- list(
    footer = list(
      enabled = TRUE,
      left = "Default Footer",
      right = "Page {page}",
      rPr_xml = ""
    ),
    size = "letter"
  )
  assembly_result <- assemble_section_breaks(body, ns, page_config)

  n <- inject_section_headers_footers(body, ns, temp_dir, page_config,
                                      assembly_result)

  expect_true(n > 0)

  # Verify footer was created with default text
  footer_files <- list.files(file.path(temp_dir, "word"), pattern = "^footer\\d+\\.xml$")
  expect_true(length(footer_files) > 0)

  # Read the footer and check for default text
  ftr_path <- file.path(temp_dir, "word", footer_files[[1]])
  ftr_xml <- xml2::read_xml(ftr_path)
  ftr_ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  all_text <- paste(xml2::xml_text(xml2::xml_find_all(ftr_xml, ".//w:t", ftr_ns)),
                    collapse = "")
  expect_true(grepl("Default Footer", all_text))
})

test_that("inject_section_headers_footers() applies section-specific style override", {
  xml_str <- build_section_body(
    content_para("Front"),
    section_marker("section-appendix", attrs = list(
      "footer-left" = "Appendix"
    )),
    content_para("Appendix content")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  temp_dir <- create_mock_docx_dir()
  on.exit(unlink(temp_dir, recursive = TRUE))

  # Section "appendix" has a custom rPr_xml
  custom_rPr <- '<w:rPr><w:rFonts w:ascii="Courier" w:hAnsi="Courier"/></w:rPr>'
  page_config <- list(
    footer = list(enabled = TRUE, left = "", right = "", rPr_xml = ""),
    sections = list(
      appendix = list(footer_rPr_xml = custom_rPr)
    ),
    size = "letter"
  )
  assembly_result <- assemble_section_breaks(body, ns, page_config)

  inject_section_headers_footers(body, ns, temp_dir, page_config,
                                 assembly_result)

  # Verify the footer file uses custom font
  footer_files <- list.files(file.path(temp_dir, "word"), pattern = "^footer\\d+\\.xml$")
  expect_true(length(footer_files) > 0)

  ftr_path <- file.path(temp_dir, "word", footer_files[[1]])
  ftr_xml <- xml2::read_xml(ftr_path)
  ftr_ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  fonts <- xml2::xml_find_first(ftr_xml, ".//w:rFonts", ftr_ns)
  expect_false(inherits(fonts, "xml_missing"))
  expect_equal(xml2::xml_attr(fonts, "ascii"), "Courier")
})


# ==========================================================================
# Header-specific injection tests
# ==========================================================================

test_that("inject_section_headers_footers() suppresses header with header='false'", {
  xml_str <- build_section_body(
    content_para("Front"),
    section_marker("section-body", attrs = list(
      "header-left" = "Title"
    )),
    content_para("Body"),
    section_marker("section-appendix", attrs = list(
      "header" = "false"
    )),
    content_para("Appendix")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  temp_dir <- create_mock_docx_dir()
  on.exit(unlink(temp_dir, recursive = TRUE))

  page_config <- list(
    header = list(enabled = TRUE, left = "", right = "", rPr_xml = ""),
    size = "letter"
  )
  assembly_result <- assemble_section_breaks(body, ns, page_config)

  inject_section_headers_footers(body, ns, temp_dir, page_config,
                                 assembly_result)

  sect_paras <- xml2::xml_find_all(body, "w:p[w:pPr/w:sectPr]", ns)
  expect_length(sect_paras, 2)

  # First: should have headerReference
  sectPr1 <- xml2::xml_find_first(sect_paras[[1]], "w:pPr/w:sectPr", ns)
  hdr_ref1 <- xml2::xml_find_first(sectPr1, "w:headerReference", ns)
  expect_false(inherits(hdr_ref1, "xml_missing"))

  # Second: should have headerReference pointing to empty header file
  sectPr2 <- xml2::xml_find_first(sect_paras[[2]], "w:pPr/w:sectPr", ns)
  hdr_ref2 <- xml2::xml_find_first(sectPr2, "w:headerReference", ns)
  expect_false(inherits(hdr_ref2, "xml_missing"),
    info = "Suppressed header must have headerReference to empty file, not be missing")
})


# ==========================================================================
# OOXML element order
# ==========================================================================

test_that("headerReference/footerReference appear before pgSz in sectPr", {
  xml_str <- build_section_body(
    content_para("Front"),
    section_marker("section-body", attrs = list(
      "footer-left" = "Draft",
      "header-left" = "Title"
    )),
    content_para("Body")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  temp_dir <- create_mock_docx_dir()
  on.exit(unlink(temp_dir, recursive = TRUE))

  page_config <- list(
    footer = list(enabled = TRUE, left = "", right = "", rPr_xml = ""),
    header = list(enabled = TRUE, left = "", right = "", rPr_xml = ""),
    size = "letter"
  )
  assembly_result <- assemble_section_breaks(body, ns, page_config)

  inject_section_headers_footers(body, ns, temp_dir, page_config,
                                 assembly_result)

  # Check body sectPr element order
  body_sectPr <- xml2::xml_find_first(body, "w:sectPr", ns)
  children <- xml2::xml_children(body_sectPr)
  child_names <- xml2::xml_name(children)

  # References should come before pgSz
  ref_positions <- which(child_names %in% c("headerReference", "footerReference"))
  pgsz_position <- which(child_names == "pgSz")

  if (length(ref_positions) > 0 && length(pgsz_position) > 0) {
    expect_true(all(ref_positions < pgsz_position),
      info = "headerReference/footerReference must appear before pgSz in sectPr")
  }
})

# --- parse_footer_content placeholder tests ---

test_that("parse_footer_content resolves {sectionpages} to SECTIONPAGES field", {
  result <- parse_footer_content("Page {page} of {sectionpages}")
  xml <- paste(result, collapse = "")
  expect_match(xml, "PAGE", fixed = TRUE)
  expect_match(xml, "SECTIONPAGES", fixed = TRUE)
  expect_no_match(xml, "NUMPAGES")
})

test_that("parse_footer_content resolves {pages} to NUMPAGES field", {
  result <- parse_footer_content("Page {page} of {pages}")
  xml <- paste(result, collapse = "")
  expect_match(xml, "PAGE", fixed = TRUE)
  expect_match(xml, "NUMPAGES", fixed = TRUE)
  expect_no_match(xml, "SECTIONPAGES")
})


# ==========================================================================
# Dynamic tab stop computation (#41)
# ==========================================================================

test_that("compute_hf_tab_stops returns letter defaults with no config", {
  stops <- compute_hf_tab_stops()
  expect_equal(stops$center, 4680L)
  expect_equal(stops$right, 9360L)
})

test_that("compute_hf_tab_stops returns letter defaults for letter + 1in margins", {
  config <- list(size = "letter", orientation = "portrait",
                 margins = list(left = "1in", right = "1in"))
  stops <- compute_hf_tab_stops(config)
  expect_equal(stops$center, 4680L)
  expect_equal(stops$right, 9360L)
})

test_that("compute_hf_tab_stops returns different values for A4", {
  config <- list(size = "a4", orientation = "portrait",
                 margins = list(left = "1in", right = "1in"))
  stops <- compute_hf_tab_stops(config)

  # A4 width = 11906 twips; usable = 11906 - 1440 - 1440 = 9026
  expect_equal(stops$right, 9026L)
  expect_equal(stops$center, 4513L)

  # Confirm they differ from letter defaults
  expect_false(stops$right == 9360L)
})

test_that("compute_hf_tab_stops handles landscape orientation", {
  config <- list(size = "letter", orientation = "landscape",
                 margins = list(left = "1in", right = "1in"))
  stops <- compute_hf_tab_stops(config)

  # Landscape letter: width = 15840 (swapped); usable = 15840 - 1440 - 1440 = 12960
  expect_equal(stops$right, 12960L)
  expect_equal(stops$center, 6480L)

  # Wider than portrait
  expect_true(stops$right > 9360L)
})

test_that("compute_hf_tab_stops handles custom margins", {
  config <- list(size = "letter", orientation = "portrait",
                 margins = list(left = "1.5in", right = "1.5in"))
  stops <- compute_hf_tab_stops(config)

  # Usable = 12240 - 2160 - 2160 = 7920
  expect_equal(stops$right, 7920L)
  expect_equal(stops$center, 3960L)
})

test_that("compute_hf_tab_stops uses section-specific page props", {
  config <- list(
    size = "letter",
    orientation = "portrait",
    margins = list(left = "1in", right = "1in"),
    named = list(
      landscape = list(
        size = "letter",
        orientation = "landscape",
        margins = list(left = "1in", right = "1in")
      )
    )
  )
  # Default section
  default_stops <- compute_hf_tab_stops(config)
  expect_equal(default_stops$right, 9360L)

  # Named landscape section
  landscape_stops <- compute_hf_tab_stops(config, "section-landscape")
  expect_equal(landscape_stops$right, 12960L)
})

test_that("wrap_multi_position_xml uses custom tab stops", {
  xml_str <- wrap_multi_position_xml("<w:r><w:t>test</w:t></w:r>", "footer",
                                      tab_stop_center = 5000L,
                                      tab_stop_right = 10000L)
  xml <- xml2::read_xml(xml_str)
  ftr_ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  tabs <- xml2::xml_find_all(xml, ".//w:tabs/w:tab", ftr_ns)
  expect_length(tabs, 2)

  center_tab <- tabs[[1]]
  expect_equal(xml2::xml_attr(center_tab, "val"), "center")
  expect_equal(xml2::xml_attr(center_tab, "pos"), "5000")

  right_tab <- tabs[[2]]
  expect_equal(xml2::xml_attr(right_tab, "val"), "right")
  expect_equal(xml2::xml_attr(right_tab, "pos"), "10000")
})

test_that("wrap_multi_position_xml defaults to letter tab stops", {
  xml_str <- wrap_multi_position_xml("<w:r><w:t>test</w:t></w:r>", "footer")
  xml <- xml2::read_xml(xml_str)
  ftr_ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  tabs <- xml2::xml_find_all(xml, ".//w:tabs/w:tab", ftr_ns)
  center_pos <- xml2::xml_attr(tabs[[1]], "pos")
  right_pos <- xml2::xml_attr(tabs[[2]], "pos")

  expect_equal(center_pos, "4680")
  expect_equal(right_pos, "9360")
})

test_that("build_multi_position_hf_xml_raw passes tab stops through", {
  config <- list(left = "Draft", center = "", right = "Page {page}")
  tab_stops <- list(center = 5000L, right = 10000L)
  xml_str <- build_multi_position_hf_xml_raw(config, "", "footer", tab_stops)
  xml <- xml2::read_xml(xml_str)
  ftr_ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  tabs <- xml2::xml_find_all(xml, ".//w:tabs/w:tab", ftr_ns)
  right_pos <- xml2::xml_attr(tabs[[2]], "pos")
  expect_equal(right_pos, "10000")
})


# ==========================================================================
# Orphaned footer/header cleanup (#44)
# ==========================================================================

test_that("cleanup_orphaned_hf_files removes unreferenced footer", {
  temp_dir <- create_mock_docx_dir()
  on.exit(unlink(temp_dir, recursive = TRUE))

  # Write a document.xml with one sectPr referencing footer3.xml (rId10)
  doc_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:body>',
    '<w:p><w:r><w:t>Content</w:t></w:r></w:p>',
    '<w:sectPr>',
    '<w:footerReference w:type="default" r:id="rId10"/>',
    '</w:sectPr>',
    '</w:body></w:document>'
  )
  doc_xml_path <- file.path(temp_dir, "word", "document.xml")
  writeLines(doc_xml, doc_xml_path)

  # Add both footer1.xml (orphaned, rId9) and footer3.xml (referenced, rId10)
  footer_xml <- '<w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p/></w:ftr>'
  writeLines(footer_xml, file.path(temp_dir, "word", "footer1.xml"))
  writeLines(footer_xml, file.path(temp_dir, "word", "footer3.xml"))

  # Add relationships for both
  rels_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>',
    '<Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>',
    '<Relationship Id="rId10" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer3.xml"/>',
    '</Relationships>'
  )
  writeLines(rels_xml, file.path(temp_dir, "word", "_rels", "document.xml.rels"))

  # Add content type overrides for both
  ct_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
    '<Default Extension="xml" ContentType="application/xml"/>',
    '<Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>',
    '<Override PartName="/word/footer3.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>',
    '</Types>'
  )
  writeLines(ct_xml, file.path(temp_dir, "[Content_Types].xml"))

  # Run cleanup
  n <- cleanup_orphaned_hf_files(doc_xml_path, temp_dir)

  # Should remove 1 orphaned file
  expect_equal(n, 1L)

  # footer1.xml should be removed
  expect_false(file.exists(file.path(temp_dir, "word", "footer1.xml")))

  # footer3.xml should still exist
  expect_true(file.exists(file.path(temp_dir, "word", "footer3.xml")))

  # rId9 should be removed from rels
  rels <- xml2::read_xml(file.path(temp_dir, "word", "_rels", "document.xml.rels"))
  rels_ns <- c(d1 = "http://schemas.openxmlformats.org/package/2006/relationships")
  orphaned_rel <- xml2::xml_find_first(rels, ".//d1:Relationship[@Id='rId9']", rels_ns)
  expect_true(inherits(orphaned_rel, "xml_missing"))

  # rId10 should still exist
  kept_rel <- xml2::xml_find_first(rels, ".//d1:Relationship[@Id='rId10']", rels_ns)
  expect_false(inherits(kept_rel, "xml_missing"))

  # Content type for footer1.xml should be removed
  ct <- xml2::read_xml(file.path(temp_dir, "[Content_Types].xml"))
  ct_ns <- c(ct = "http://schemas.openxmlformats.org/package/2006/content-types")
  orphaned_ct <- xml2::xml_find_first(ct,
    './/ct:Override[@PartName="/word/footer1.xml"]', ct_ns)
  expect_true(inherits(orphaned_ct, "xml_missing"))
})

test_that("cleanup_orphaned_hf_files returns 0 when all files are referenced", {
  temp_dir <- create_mock_docx_dir()
  on.exit(unlink(temp_dir, recursive = TRUE))

  doc_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:body>',
    '<w:sectPr>',
    '<w:footerReference w:type="default" r:id="rId3"/>',
    '</w:sectPr>',
    '</w:body></w:document>'
  )
  doc_xml_path <- file.path(temp_dir, "word", "document.xml")
  writeLines(doc_xml, doc_xml_path)

  footer_xml <- '<w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p/></w:ftr>'
  writeLines(footer_xml, file.path(temp_dir, "word", "footer3.xml"))

  rels_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>',
    '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer3.xml"/>',
    '</Relationships>'
  )
  writeLines(rels_xml, file.path(temp_dir, "word", "_rels", "document.xml.rels"))

  n <- cleanup_orphaned_hf_files(doc_xml_path, temp_dir)
  expect_equal(n, 0L)
})


# ==========================================================================
# Issue #70: Footer payload pipeline diagnostic
# ==========================================================================

test_that("wrapping div footer-left={page} survives payload shift and cascade", {
  # Reproduce issue #70 scenario: two wrapping divs with footer-left="{page}",
  # YAML config has footer enabled but no footer positions.

  # Build: content -> open section-body (footer-left="{page}") -> content
  #        -> close section-body-end -> open section-body (footer-left="{page}")
  #        -> content -> close section-body-end
  xml_str <- build_section_body(
    content_para("Front matter"),
    section_marker("section-body", attrs = list(
      "footer-left" = "{page}",
      "page-start" = "1"
    )),
    content_para("Introduction content"),
    section_marker("section-body", closing = TRUE),
    section_marker("section-body", attrs = list(
      "footer-left" = "{page}"
    )),
    content_para("SGBA+ content"),
    section_marker("section-body", closing = TRUE)
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  temp_dir <- create_mock_docx_dir()
  on.exit(unlink(temp_dir, recursive = TRUE))

  page_config <- list(
    footer = list(enabled = TRUE),  # Enabled but no positions (like the bug report)
    header = list(
      enabled = TRUE,
      left = "Research Proposal",
      right = "Doug Manuel"
    ),
    size = "letter"
  )

  # Step 1: Assemble section breaks
  assembly_result <- assemble_section_breaks(body, ns, page_config)
  seq <- assembly_result$section_sequence

  # Should have 4 markers: open, close, open, close
  expect_equal(length(seq), 4,
    info = "Should have 4 markers (2 wrapping divs)")

  # Verify opening markers have footer-left in their field_code_payload
  expect_equal(seq[[1]]$field_code_payload[["footer-left"]], "{page}",
    info = "Opening marker 1 should have footer-left={page}")
  expect_equal(seq[[3]]$field_code_payload[["footer-left"]], "{page}",
    info = "Opening marker 2 should have footer-left={page}")

  # Verify closing markers do NOT have footer-left (stripped by Lua design)
  expect_null(seq[[2]]$field_code_payload[["footer-left"]],
    info = "Closing marker 1 should not have footer-left")
  expect_null(seq[[4]]$field_code_payload[["footer-left"]],
    info = "Closing marker 2 should not have footer-left")

  # Step 2: Apply payload shift (same logic as finalize_docx.R payload_shift_sections())
  if (length(seq) > 1) {
    original_payloads <- lapply(seq, function(s) s$field_code_payload)
    seq[[1]]$field_code_payload <- list()
    for (i in 2:length(seq)) {
      seq[[i]]$field_code_payload <- original_payloads[[i - 1]]
    }
    last_payload <- original_payloads[[length(original_payloads)]]
    seq <- c(seq, list(list(
      section_class = "final-cascade",
      sectpr_para = NULL,
      is_closing = TRUE,
      field_code_payload = last_payload
    )))
    assembly_result$section_sequence <- seq
  }

  # After shift:
  # seq[1] = empty (YAML defaults for section before first wrapping div)
  # seq[2] = opening1's payload (footer-left="{page}", page-start="1")
  # seq[3] = closing1's payload (empty — no footer attrs)
  # seq[4] = opening2's payload (footer-left="{page}")
  # seq[5] = closing2's payload (empty — final-cascade)

  expect_equal(length(seq[[1]]$field_code_payload), 0,
    info = "First sectPr gets empty payload after shift")
  expect_equal(seq[[2]]$field_code_payload[["footer-left"]], "{page}",
    info = "Second sectPr (closing1) gets opening1's payload with footer-left")
  expect_null(seq[[3]]$field_code_payload[["footer-left"]],
    info = "Third sectPr (opening2) gets closing1's empty payload")
  expect_equal(seq[[4]]$field_code_payload[["footer-left"]], "{page}",
    info = "Fourth sectPr (closing2) gets opening2's payload with footer-left")

  # Step 3: Resolve cascade
  footer_config <- page_config$footer
  header_config <- page_config$header
  section_styles <- page_config$sections %||% list()
  footer_enabled <- isTRUE(footer_config$enabled)
  header_enabled <- isTRUE(header_config$enabled)

  resolved <- resolve_all_sections(seq, footer_config, header_config,
                                   section_styles, footer_enabled, header_enabled)

  # The closing markers' resolved footers should have left = "{page}"
  expect_equal(resolved[[2]]$footer$left, "{page}",
    info = "Closing marker 1's resolved footer should have left={page}")

  # Opening marker 2 inherits from closing marker 1 (cascade)
  expect_equal(resolved[[3]]$footer$left, "{page}",
    info = "Opening marker 2 should inherit footer-left from cascade")

  expect_equal(resolved[[4]]$footer$left, "{page}",
    info = "Closing marker 2's resolved footer should have left={page}")

  # Body sectPr (final-cascade) should also inherit
  expect_equal(resolved[[5]]$footer$left, "{page}",
    info = "Body sectPr should inherit footer-left from cascade")

  # Step 4: Inject and verify footer XML file contains PAGE field code
  n <- inject_section_headers_footers(body, ns, temp_dir, page_config,
                                      assembly_result)
  expect_true(n > 0, info = "Should inject at least one footer")

  # Read the generated footer file(s) and check for PAGE field code
  footer_files <- list.files(file.path(temp_dir, "word"),
                             pattern = "^footer\\d+\\.xml$")
  expect_true(length(footer_files) > 0,
    info = "At least one footer XML file should be created")

  # Check that at least one footer contains PAGE instrText
  has_page_field <- FALSE
  for (ff in footer_files) {
    ftr_xml <- xml2::read_xml(file.path(temp_dir, "word", ff))
    ftr_ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
    instr_texts <- xml2::xml_text(xml2::xml_find_all(ftr_xml, ".//w:instrText", ftr_ns))
    if (any(grepl("PAGE", instr_texts))) {
      has_page_field <- TRUE
      break
    }
  }
  expect_true(has_page_field,
    info = "Footer XML must contain PAGE field code for {page} placeholder")
})

test_that("finalize_docx() end-to-end: footer-left={page} in wrapping divs", {
  # End-to-end test: create a real DOCX with section markers, write
  # page-config.json, run finalize_docx(), and verify the output has
  # footer with PAGE field code.

  temp_dir <- tempfile("e2e_footer_test_")
  dir.create(temp_dir)
  on.exit(unlink(temp_dir, recursive = TRUE))

  # Write page-config.json matching the issue #70 scenario
  sidecar_dir <- file.path(temp_dir, "_docstyle")
  dir.create(sidecar_dir)
  page_config <- list(
    footer = list(enabled = TRUE, left = "", center = "", right = "",
                  rPr_xml = "", first_page = TRUE),
    header = list(enabled = TRUE, left = "Research Proposal",
                  right = "Doug Manuel", center = "",
                  rPr_xml = "", first_page = TRUE),
    size = "letter",
    orientation = "portrait",
    margins = list(top = "1in", bottom = "1in", left = "1in", right = "1in")
  )
  jsonlite::write_json(page_config, file.path(sidecar_dir, "page-config.json"),
                       auto_unbox = TRUE, pretty = TRUE)

  # Build document XML with two wrapping section divs with footer-left="{page}"
  xml_str <- build_section_body(
    content_para("Front matter"),
    section_marker("section-body", attrs = list(
      "footer-left" = "{page}",
      "page-start" = "1"
    )),
    content_para("Introduction content"),
    section_marker("section-body", closing = TRUE),
    section_marker("section-body", attrs = list(
      "footer-left" = "{page}"
    )),
    content_para("SGBA content"),
    section_marker("section-body", closing = TRUE)
  )

  # Create minimal DOCX structure
  word_dir <- file.path(temp_dir, "word")
  dir.create(file.path(word_dir, "_rels"), recursive = TRUE)
  writeLines(xml_str, file.path(word_dir, "document.xml"))

  # Minimal styles.xml
  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:style w:type="paragraph" w:default="1" w:styleId="Normal">',
    '<w:name w:val="Normal"/></w:style></w:styles>'
  ), file.path(word_dir, "styles.xml"))

  # Minimal settings.xml
  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>'),
    file.path(word_dir, "settings.xml"))

  # Relationships
  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>',
    '</Relationships>'
  ), file.path(word_dir, "_rels", "document.xml.rels"))

  # Content types
  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
    '<Default Extension="xml" ContentType="application/xml"/>',
    '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>',
    '</Types>'
  ), file.path(temp_dir, "[Content_Types].xml"))

  # Package .rels
  dir.create(file.path(temp_dir, "_rels"))
  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>',
    '</Relationships>'
  ), file.path(temp_dir, "_rels", ".rels"))

  # Zip into DOCX
  docx_path <- file.path(temp_dir, "test.docx")
  withr::with_dir(temp_dir, {
    files <- c("[Content_Types].xml", "_rels/.rels",
               "word/document.xml", "word/styles.xml", "word/settings.xml",
               "word/_rels/document.xml.rels")
    utils::zip(docx_path, files, flags = "-q")
  })

  # Run finalize_docx()
  result <- finalize_docx(docx_path, verbose = TRUE)

  # Unzip and inspect the output
  out_dir <- tempfile("finalized_")
  dir.create(out_dir)
  utils::unzip(docx_path, exdir = out_dir)

  # Check footer files exist
  footer_files <- list.files(file.path(out_dir, "word"),
                             pattern = "^footer\\d+\\.xml$")
  expect_true(length(footer_files) > 0,
    info = "Finalized DOCX must contain footer XML file(s)")

  # Check at least one footer has PAGE field code
  has_page_field <- FALSE
  for (ff in footer_files) {
    ftr_xml <- xml2::read_xml(file.path(out_dir, "word", ff))
    ftr_ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
    instr_texts <- xml2::xml_text(xml2::xml_find_all(ftr_xml, ".//w:instrText", ftr_ns))
    if (any(grepl("PAGE", instr_texts))) {
      has_page_field <- TRUE
      break
    }
  }
  expect_true(has_page_field,
    info = "Finalized DOCX footer must contain PAGE field code")

  # Check body sectPr has footerReference
  doc_xml <- xml2::read_xml(file.path(out_dir, "word", "document.xml"))
  body <- xml2::xml_find_first(doc_xml, "//w:body", ns)
  body_sectPr <- xml2::xml_find_first(body, "w:sectPr", ns)
  ftr_refs <- xml2::xml_find_all(body_sectPr, "w:footerReference", ns)
  expect_true(length(ftr_refs) > 0,
    info = "Body sectPr must have footerReference after finalize_docx()")

  # Check that header also works (issue #70 notes headers work correctly)
  header_files <- list.files(file.path(out_dir, "word"),
                             pattern = "^header\\d+\\.xml$")
  expect_true(length(header_files) > 0,
    info = "Finalized DOCX must also contain header XML file(s)")

  unlink(out_dir, recursive = TRUE)
})


# ==========================================================================
# Issue #71: Per-section header overrides from div attributes
# ==========================================================================

test_that("per-section header-left override replaces YAML default", {
  # YAML: header left="Default", right="Author"
  # Section div: header-left="Appendix A" (right should inherit)
  xml_str <- build_section_body(
    content_para("Front matter"),
    section_marker("section-appendix", page_break = "true",
                   attrs = list("header-left" = "Appendix A")),
    content_para("Appendix content"),
    section_marker("section-appendix", closing = TRUE)
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  temp_dir <- create_mock_docx_dir()
  on.exit(unlink(temp_dir, recursive = TRUE))

  page_config <- list(
    header = list(enabled = TRUE, left = "Default", right = "Author"),
    footer = list(enabled = TRUE, left = "Footer", right = "Page {page}"),
    size = "letter"
  )

  # Assemble + payload shift + inject
  assembly_result <- assemble_section_breaks(body, ns, page_config)
  seq <- assembly_result$section_sequence

  # Payload shift
  original_payloads <- lapply(seq, function(s) s$field_code_payload)
  seq[[1]]$field_code_payload <- list()
  for (i in 2:length(seq)) {
    seq[[i]]$field_code_payload <- original_payloads[[i - 1]]
  }
  last_payload <- original_payloads[[length(original_payloads)]]
  seq <- c(seq, list(list(
    section_class = "final-cascade",
    sectpr_para = NULL,
    is_closing = TRUE,
    field_code_payload = last_payload
  )))
  assembly_result$section_sequence <- seq

  # Resolve all sections
  footer_config <- page_config$footer
  header_config <- page_config$header
  section_styles <- page_config$sections %||% list()
  footer_enabled <- isTRUE(footer_config$enabled)
  header_enabled <- isTRUE(header_config$enabled)

  resolved <- resolve_all_sections(seq, footer_config, header_config,
                                   section_styles, footer_enabled, header_enabled)

  # Section 1 (opening marker, gets empty payload -> YAML defaults)
  expect_equal(resolved[[1]]$header$left, "Default",
    info = "First section header-left should use YAML default")
  expect_equal(resolved[[1]]$header$right, "Author",
    info = "First section header-right should use YAML default")

  # Section 2 (closing marker, gets opening marker's payload with header-left override)
  expect_equal(resolved[[2]]$header$left, "Appendix A",
    info = "Appendix section header-left should be overridden by div attribute")
  expect_equal(resolved[[2]]$header$right, "Author",
    info = "Appendix section header-right should inherit YAML default")
})

test_that("per-section header-right='' suppresses right position", {
  # Explicitly setting header-right="" should produce empty right position
  xml_str <- build_section_body(
    content_para("Front matter"),
    section_marker("section-appendix", page_break = "true",
                   attrs = list("header-left" = "Appendix", "header-right" = "")),
    content_para("Appendix content"),
    section_marker("section-appendix", closing = TRUE)
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  temp_dir <- create_mock_docx_dir()
  on.exit(unlink(temp_dir, recursive = TRUE))

  page_config <- list(
    header = list(enabled = TRUE, left = "Default Left", right = "Default Right"),
    footer = list(enabled = TRUE),
    size = "letter"
  )

  assembly_result <- assemble_section_breaks(body, ns, page_config)
  seq <- assembly_result$section_sequence

  # Payload shift
  original_payloads <- lapply(seq, function(s) s$field_code_payload)
  seq[[1]]$field_code_payload <- list()
  for (i in 2:length(seq)) {
    seq[[i]]$field_code_payload <- original_payloads[[i - 1]]
  }
  last_payload <- original_payloads[[length(original_payloads)]]
  seq <- c(seq, list(list(
    section_class = "final-cascade",
    sectpr_para = NULL,
    is_closing = TRUE,
    field_code_payload = last_payload
  )))
  assembly_result$section_sequence <- seq

  footer_config <- page_config$footer
  header_config <- page_config$header
  section_styles <- page_config$sections %||% list()
  footer_enabled <- isTRUE(footer_config$enabled)
  header_enabled <- isTRUE(header_config$enabled)

  resolved <- resolve_all_sections(seq, footer_config, header_config,
                                   section_styles, footer_enabled, header_enabled)

  # Section 2 (appendix): header-left="Appendix", header-right="" (empty)
  expect_equal(resolved[[2]]$header$left, "Appendix",
    info = "Appendix header-left should be 'Appendix'")
  expect_equal(resolved[[2]]$header$right, "",
    info = "Appendix header-right should be empty (explicitly suppressed)")
})


# --- #42: footer suppression test ---

test_that("#42: footer suppression — footer=false resolves to suppressed=TRUE", {
  # When a section div has footer="false", resolve_hf_for_section() should
  # return list(suppressed = TRUE), not inherit the previous section's footer.
  global_footer <- list(
    enabled = TRUE,
    left = "Doc Title",
    center = "",
    right = "Page {page}",
    rPr_xml = "",
    first_page = TRUE,
    suppressed = FALSE
  )

  prev_footer <- list(
    left = "Doc Title",
    center = "",
    right = "Page {page}",
    rPr_xml = "",
    first_page = TRUE,
    suppressed = FALSE
  )

  # Payload with footer="false"
  payload <- list(footer = "false", type = "section", class = "section-no-footer")

  result <- resolve_hf_for_section(
    payload      = payload,
    prev         = prev_footer,
    section_name = "section-no-footer",
    section_styles = list(),
    global_config  = global_footer,
    hf_type        = "footer"
  )

  expect_true(isTRUE(result$suppressed),
    label = "footer='false' in payload should resolve to suppressed=TRUE")
  expect_null(result$left,
    label = "Suppressed footer should not carry forward position text")
})
