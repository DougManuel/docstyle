# Tests for footer harvest functions
#
# Unit tests for parse_footer_xml(), detect_footer_layout(),
# extract_footer_segments(), field_instr_to_placeholder(),
# assign_segments_to_positions(), and get_footer_lookup().
#
# Tests use constructed XML snippets per the spec test matrix.

# ── Helpers ──────────────────────────────────────────────────────────────────

#' Build a minimal footer XML string
#'
#' @param body_xml Inner XML content (paragraphs, SDTs, etc.)
#' @return Complete footer XML string with namespace declarations
make_footer_xml <- function(body_xml) {
  paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"',
    ' xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml">',
    body_xml,
    '</w:ftr>'
  )
}

#' Build a PAGE field code run sequence
make_page_field <- function() {
  paste0(
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:t>1</w:t></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r>'
  )
}

#' Build a NUMPAGES field code run sequence
make_numpages_field <- function() {
  paste0(
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> NUMPAGES </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:t>14</w:t></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r>'
  )
}

#' Build a SECTIONPAGES field code run sequence
make_sectionpages_field <- function() {
  paste0(
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> SECTIONPAGES </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:t>14</w:t></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r>'
  )
}

ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
        r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships")


# ══ field_instr_to_placeholder ═══════════════════════════════════════════════

test_that("field_instr_to_placeholder maps known field codes", {
  expect_equal(docstyle:::field_instr_to_placeholder(" PAGE "), "{page}")
  expect_equal(docstyle:::field_instr_to_placeholder("NUMPAGES"), "{pages}")
  expect_equal(docstyle:::field_instr_to_placeholder(" SECTIONPAGES "), "{sectionpages}")
})

test_that("field_instr_to_placeholder strips formatting switches", {
  expect_equal(
    docstyle:::field_instr_to_placeholder(" PAGE \\* MERGEFORMAT "),
    "{page}"
  )
  expect_equal(
    docstyle:::field_instr_to_placeholder(" NUMPAGES \\* Arabic "),
    "{pages}"
  )
})

test_that("field_instr_to_placeholder handles unrecognized fields", {
  result <- docstyle:::field_instr_to_placeholder(" DATE ")
  expect_equal(result, "{DATE}")
})


# ══ parse_footer_xml — empty footer ═════════════════════════════════════════

test_that("parse_footer_xml returns NULL for empty footer", {
  # Test matrix case 5: empty paragraph only
  xml_str <- make_footer_xml(
    '<w:p><w:pPr><w:pStyle w:val="Footer"/></w:pPr></w:p>'
  )
  ftr <- xml2::read_xml(xml_str)
  result <- docstyle:::parse_footer_xml(ftr, ns)
  expect_null(result)
})

test_that("parse_footer_xml returns NULL for footer with only bookmarks", {
  # Empty footer may contain bookmark markers
  xml_str <- make_footer_xml(
    '<w:p><w:pPr><w:pStyle w:val="Footer"/></w:pPr>
     <w:bookmarkStart w:id="0" w:name="_GoBack"/>
     <w:bookmarkEnd w:id="0"/></w:p>'
  )
  ftr <- xml2::read_xml(xml_str)
  result <- docstyle:::parse_footer_xml(ftr, ns)
  expect_null(result)
})


# ══ parse_footer_xml — simple page number (right) ═══════════════════════════

test_that("parse_footer_xml extracts right-aligned page number via framePr", {
  # Test matrix case 2: PAGE field, framePr xAlign="right"
  xml_str <- make_footer_xml(paste0(
    '<w:p><w:pPr>',
    '<w:pStyle w:val="Footer"/>',
    '<w:framePr w:wrap="none" w:vAnchor="text" w:hAnchor="margin" w:xAlign="right" w:y="1"/>',
    '</w:pPr>',
    make_page_field(),
    '</w:p>',
    '<w:p><w:pPr><w:pStyle w:val="Footer"/></w:pPr></w:p>'
  ))
  ftr <- xml2::read_xml(xml_str)
  result <- docstyle:::parse_footer_xml(ftr, ns)

  expect_null(result$left)
  expect_null(result$center)
  expect_equal(result$right, "{page}")
})


# ══ parse_footer_xml — Page X of Y ══════════════════════════════════════════

test_that("parse_footer_xml extracts 'Page X of Y' pattern", {
  # Test matrix case 3: text + PAGE + text + SECTIONPAGES
  xml_str <- make_footer_xml(paste0(
    '<w:p><w:pPr>',
    '<w:pStyle w:val="Footer"/>',
    '<w:framePr w:wrap="none" w:vAnchor="text" w:hAnchor="margin" w:xAlign="right" w:y="1"/>',
    '</w:pPr>',
    '<w:r><w:t xml:space="preserve">Page </w:t></w:r>',
    make_page_field(),
    '<w:r><w:t xml:space="preserve"> of </w:t></w:r>',
    make_sectionpages_field(),
    '</w:p>'
  ))
  ftr <- xml2::read_xml(xml_str)
  result <- docstyle:::parse_footer_xml(ftr, ns)

  expect_null(result$left)
  expect_null(result$center)
  expect_equal(result$right, "Page {page} of {sectionpages}")
})


# ══ parse_footer_xml — multi-position (tabbed) ══════════════════════════════

test_that("parse_footer_xml extracts multi-position footer via tabs", {
  # Test matrix case 4: left text + center tab + right tab + page number
  xml_str <- make_footer_xml(paste0(
    '<w:p><w:pPr>',
    '<w:pStyle w:val="Footer"/>',
    '<w:tabs>',
    '<w:tab w:val="center" w:pos="4680"/>',
    '<w:tab w:val="right" w:pos="9360"/>',
    '</w:tabs>',
    '</w:pPr>',
    '<w:r><w:t>Left Text</w:t></w:r>',
    '<w:r><w:tab/></w:r>',
    '<w:r><w:tab/></w:r>',
    make_page_field(),
    '</w:p>'
  ))
  ftr <- xml2::read_xml(xml_str)
  result <- docstyle:::parse_footer_xml(ftr, ns)

  expect_equal(result$left, "Left Text")
  expect_null(result$center)
  expect_equal(result$right, "{page}")
})

test_that("parse_footer_xml extracts left+center+right from tabbed footer", {
  # Full three-position footer
  xml_str <- make_footer_xml(paste0(
    '<w:p><w:pPr>',
    '<w:pStyle w:val="Footer"/>',
    '<w:tabs>',
    '<w:tab w:val="center" w:pos="4680"/>',
    '<w:tab w:val="right" w:pos="9360"/>',
    '</w:tabs>',
    '</w:pPr>',
    '<w:r><w:t>Left</w:t></w:r>',
    '<w:r><w:tab/></w:r>',
    '<w:r><w:t>Center</w:t></w:r>',
    '<w:r><w:tab/></w:r>',
    '<w:r><w:t>Right</w:t></w:r>',
    '</w:p>'
  ))
  ftr <- xml2::read_xml(xml_str)
  result <- docstyle:::parse_footer_xml(ftr, ns)

  expect_equal(result$left, "Left")
  expect_equal(result$center, "Center")
  expect_equal(result$right, "Right")
})


# ══ parse_footer_xml — SDT-wrapped ══════════════════════════════════════════

test_that("parse_footer_xml unwraps SDT to access page number", {
  # Test matrix case 8: Word built-in page number in SDT wrapper
  xml_str <- make_footer_xml(paste0(
    '<w:sdt>',
    '<w:sdtPr><w:id w:val="12345"/>',
    '<w:docPartObj><w:docPartGallery w:val="Page Numbers (Bottom of Page)"/></w:docPartObj>',
    '</w:sdtPr>',
    '<w:sdtContent>',
    '<w:p><w:pPr>',
    '<w:pStyle w:val="Footer"/>',
    '<w:framePr w:wrap="none" w:vAnchor="text" w:hAnchor="margin" w:xAlign="right" w:y="1"/>',
    '</w:pPr>',
    make_page_field(),
    '</w:p>',
    '</w:sdtContent>',
    '</w:sdt>',
    '<w:p><w:pPr><w:pStyle w:val="Footer"/></w:pPr></w:p>'
  ))
  ftr <- xml2::read_xml(xml_str)
  result <- docstyle:::parse_footer_xml(ftr, ns)

  expect_null(result$left)
  expect_null(result$center)
  expect_equal(result$right, "{page}")
})


# ══ parse_footer_xml — field codes with switches ════════════════════════════

test_that("parse_footer_xml strips MERGEFORMAT from field codes", {
  # Test matrix case 9: PAGE \* MERGEFORMAT
  xml_str <- make_footer_xml(paste0(
    '<w:p><w:pPr>',
    '<w:pStyle w:val="Footer"/>',
    '<w:framePr w:wrap="none" w:vAnchor="text" w:hAnchor="margin" w:xAlign="right" w:y="1"/>',
    '</w:pPr>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> PAGE \\* MERGEFORMAT </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:t>1</w:t></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r>',
    '</w:p>'
  ))
  ftr <- xml2::read_xml(xml_str)
  result <- docstyle:::parse_footer_xml(ftr, ns)

  expect_equal(result$right, "{page}")
})


# ══ parse_footer_xml — justification-based position ═════════════════════════

test_that("parse_footer_xml detects position from jc (center alignment)", {
  xml_str <- make_footer_xml(paste0(
    '<w:p><w:pPr>',
    '<w:pStyle w:val="Footer"/>',
    '<w:jc w:val="center"/>',
    '</w:pPr>',
    '<w:r><w:t>Centered Footer</w:t></w:r>',
    '</w:p>'
  ))
  ftr <- xml2::read_xml(xml_str)
  result <- docstyle:::parse_footer_xml(ftr, ns)

  expect_null(result$left)
  expect_equal(result$center, "Centered Footer")
  expect_null(result$right)
})


# ══ parse_footer_xml — default left position ════════════════════════════════

test_that("parse_footer_xml defaults to left position", {
  xml_str <- make_footer_xml(paste0(
    '<w:p><w:pPr><w:pStyle w:val="Footer"/></w:pPr>',
    '<w:r><w:t>Some Text</w:t></w:r>',
    '</w:p>'
  ))
  ftr <- xml2::read_xml(xml_str)
  result <- docstyle:::parse_footer_xml(ftr, ns)

  expect_equal(result$left, "Some Text")
  expect_null(result$center)
  expect_null(result$right)
})


# ══ parse_footer_xml — multi-paragraph warning ══════════════════════════════

test_that("parse_footer_xml warns on multiple content paragraphs", {
  xml_str <- make_footer_xml(paste0(
    '<w:p><w:pPr><w:pStyle w:val="Footer"/></w:pPr>',
    '<w:r><w:t>First</w:t></w:r>',
    '</w:p>',
    '<w:p><w:pPr><w:pStyle w:val="Footer"/></w:pPr>',
    '<w:r><w:t>Second</w:t></w:r>',
    '</w:p>'
  ))
  ftr <- xml2::read_xml(xml_str)

  expect_warning(
    result <- docstyle:::parse_footer_xml(ftr, ns),
    "multiple content paragraphs"
  )
  # Uses first paragraph only
  expect_equal(result$left, "First")
})


# ══ parse_footer_xml — file path input ══════════════════════════════════════

test_that("parse_footer_xml accepts file path as input", {
  xml_str <- make_footer_xml(paste0(
    '<w:p><w:pPr>',
    '<w:pStyle w:val="Footer"/>',
    '<w:framePr w:wrap="none" w:vAnchor="text" w:hAnchor="margin" w:xAlign="right" w:y="1"/>',
    '</w:pPr>',
    make_page_field(),
    '</w:p>'
  ))
  tmp <- tempfile(fileext = ".xml")
  on.exit(unlink(tmp))
  writeLines(xml_str, tmp)

  result <- docstyle:::parse_footer_xml(tmp, ns)
  expect_equal(result$right, "{page}")
})

test_that("parse_footer_xml returns NULL for missing file path", {
  result <- docstyle:::parse_footer_xml("/nonexistent/path.xml", ns)
  expect_null(result)
})


# ══ parse_footer_xml — POPCORN-style multi-position footer ══════════════════

test_that("parse_footer_xml handles POPCORN footer with left text and right page number", {
  # Real-world pattern from POPCORN: left text + tab (right) + "Page X of Y"
  xml_str <- make_footer_xml(paste0(
    '<w:p><w:pPr>',
    '<w:pStyle w:val="Footer"/>',
    '<w:tabs>',
    '<w:tab w:val="right" w:pos="9360"/>',
    '</w:tabs>',
    '</w:pPr>',
    '<w:r><w:t>POPCORN Scoping Review</w:t></w:r>',
    '<w:r><w:tab/></w:r>',
    '<w:r><w:t xml:space="preserve">Page </w:t></w:r>',
    make_page_field(),
    '<w:r><w:t xml:space="preserve"> of </w:t></w:r>',
    make_sectionpages_field(),
    '</w:p>'
  ))
  ftr <- xml2::read_xml(xml_str)
  result <- docstyle:::parse_footer_xml(ftr, ns)

  expect_equal(result$left, "POPCORN Scoping Review")
  expect_null(result$center)
  expect_equal(result$right, "Page {page} of {sectionpages}")
})


# ══ detect_footer_layout ════════════════════════════════════════════════════

test_that("detect_footer_layout identifies framePr position", {
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:pPr><w:framePr w:xAlign="center"/></w:pPr>',
    '<w:r><w:t>text</w:t></w:r></w:p>'
  )
  para <- xml2::read_xml(para_xml)
  layout <- docstyle:::detect_footer_layout(para, ns)

  expect_equal(layout$type, "single")
  expect_equal(layout$position, "center")
})

test_that("detect_footer_layout identifies tab-based layout", {
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:pPr><w:tabs>',
    '<w:tab w:val="center" w:pos="4680"/>',
    '<w:tab w:val="right" w:pos="9360"/>',
    '</w:tabs></w:pPr>',
    '<w:r><w:t>text</w:t></w:r></w:p>'
  )
  para <- xml2::read_xml(para_xml)
  layout <- docstyle:::detect_footer_layout(para, ns)

  expect_equal(layout$type, "tabbed")
  expect_length(layout$tab_info, 2)
})


# ══ extract_footer_segments ═════════════════════════════════════════════════

test_that("extract_footer_segments splits at tabs", {
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:r><w:t>Left</w:t></w:r>',
    '<w:r><w:tab/></w:r>',
    '<w:r><w:t>Right</w:t></w:r>',
    '</w:p>'
  )
  para <- xml2::read_xml(para_xml)
  segments <- docstyle:::extract_footer_segments(para, ns)

  expect_equal(segments, c("Left", "Right"))
})

test_that("extract_footer_segments extracts field codes as placeholders", {
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:r><w:t xml:space="preserve">Page </w:t></w:r>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:t>3</w:t></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r>',
    '</w:p>'
  )
  para <- xml2::read_xml(para_xml)
  segments <- docstyle:::extract_footer_segments(para, ns)

  expect_equal(segments, "Page {page}")
})

test_that("extract_footer_segments skips cached display value", {
  # The "3" between separate and end should not appear in output
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:t>999</w:t></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r>',
    '</w:p>'
  )
  para <- xml2::read_xml(para_xml)
  segments <- docstyle:::extract_footer_segments(para, ns)

  expect_equal(segments, "{page}")
  expect_false(grepl("999", segments))
})


# ══ assign_segments_to_positions ════════════════════════════════════════════

test_that("assign_segments_to_positions handles single position", {
  layout <- list(type = "single", position = "right")
  result <- docstyle:::assign_segments_to_positions(c("{page}"), layout)

  expect_null(result$left)
  expect_null(result$center)
  expect_equal(result$right, "{page}")
})

test_that("assign_segments_to_positions handles tabbed left+right", {
  layout <- list(
    type = "tabbed",
    tab_info = list(list(pos = 9360L, val = "right"))
  )
  result <- docstyle:::assign_segments_to_positions(c("Left", "Right"), layout)

  expect_equal(result$left, "Left")
  expect_null(result$center)
  expect_equal(result$right, "Right")
})

test_that("assign_segments_to_positions handles tabbed left+center+right", {
  layout <- list(
    type = "tabbed",
    tab_info = list(
      list(pos = 4680L, val = "center"),
      list(pos = 9360L, val = "right")
    )
  )
  result <- docstyle:::assign_segments_to_positions(c("L", "C", "R"), layout)

  expect_equal(result$left, "L")
  expect_equal(result$center, "C")
  expect_equal(result$right, "R")
})

test_that("assign_segments_to_positions returns all NULL for empty segments", {
  layout <- list(type = "single", position = "left")
  result <- docstyle:::assign_segments_to_positions(character(), layout)

  expect_null(result$left)
  expect_null(result$center)
  expect_null(result$right)
})


# ══ build_footer_div_attrs ══════════════════════════════════════════════════

test_that("build_footer_div_attrs returns empty string without lookup", {
  result <- docstyle:::build_footer_div_attrs(
    "rId1", "rId2", TRUE, "1", NULL
  )
  expect_equal(result, "")
})

test_that("build_footer_div_attrs generates content attributes", {
  lookup <- list(
    rId1 = list(left = "Text", center = NULL, right = "{page}"),
    rId2 = list(empty = TRUE)
  )
  result <- docstyle:::build_footer_div_attrs(
    "rId1", "rId2", TRUE, "1", lookup
  )
  expect_match(result, 'footer-left="Text"')
  expect_match(result, 'footer-right="\\{page\\}"')
  expect_match(result, 'footer-first="false"')
  expect_match(result, 'page-start="1"')
})

test_that("build_footer_div_attrs handles suppressed default footer", {
  lookup <- list(rId1 = list(empty = TRUE))
  result <- docstyle:::build_footer_div_attrs(
    "rId1", NULL, FALSE, NULL, lookup
  )
  expect_match(result, 'footer="false"')
})

test_that("build_footer_div_attrs skips first footer without titlePg", {
  lookup <- list(
    rId1 = list(left = "Text", center = NULL, right = NULL),
    rId2 = list(empty = TRUE)
  )
  # has_title_pg = FALSE means first footer is ignored
  result <- docstyle:::build_footer_div_attrs(
    "rId1", "rId2", FALSE, NULL, lookup
  )
  expect_match(result, 'footer-left="Text"')
  expect_no_match(result, "footer-first")
})


# ══ Integration: get_footer_lookup with page-number-test.docx ═══════════════

test_that("get_footer_lookup parses page-number-test.docx", {
  docx <- testthat::test_path("fixtures", "page-number-test.docx")
  skip_if_not(file.exists(docx), "page-number-test.docx not available")

  lookup <- docstyle:::get_footer_lookup(docx)

  # Should have entries for all footer relationships
  expect_true(length(lookup) > 0)

  # At least some entries should have right-aligned page numbers
  has_page <- any(vapply(lookup, function(f) {
    !isTRUE(f$empty) && identical(f$right, "{page}")
  }, logical(1)))
  expect_true(has_page)
})


# ══ Integration: full pipeline with page-number-test.docx ═══════════════════

test_that("section_breaks_to_ranges generates footer attributes for page-number-test", {
  docx <- testthat::test_path("fixtures", "page-number-test.docx")
  skip_if_not(file.exists(docx), "page-number-test.docx not available")

  footer_lookup <- docstyle:::get_footer_lookup(docx)

  ranges <- suppressWarnings(docstyle:::with_docx_temp(docx, function(temp_dir) {
    doc_xml <- xml2::read_xml(file.path(temp_dir, "word", "document.xml"))
    ns <- xml2::xml_ns(doc_xml)
    body <- xml2::xml_find_first(doc_xml, ".//w:body", ns)
    children <- xml2::xml_children(body)

    breaks <- docstyle:::detect_native_section_breaks(children, ns)
    body_info <- docstyle:::extract_body_sectpr_footer_info(body, ns)

    docstyle:::section_breaks_to_ranges(
      breaks, length(children),
      footer_lookup = footer_lookup,
      body_footer_info = body_info
    )
  }))

  # Should have 3 ranges (3 sections)
  expect_equal(length(ranges), 3)

  # All sections should have footer-right="{page}"
  for (r in ranges) {
    expect_match(r$div_open, 'footer-right="\\{page\\}"')
  }

  # Sections 2 and 3 should have page-start="1"
  expect_match(ranges[[2]]$div_open, 'page-start="1"')
  expect_match(ranges[[3]]$div_open, 'page-start="1"')

  # Section 1 should NOT have page-start
  expect_no_match(ranges[[1]]$div_open, "page-start")
})


# ══ Integration: POPCORN footer harvest ═════════════════════════════════════

test_that("section_breaks_to_ranges generates correct POPCORN footer attributes", {
  docx <- "/Users/dmanuel/github/popcorn-review/reports/scoping-review-protocol/source/POPCORN_scoping_protocol_wf.docx"
  skip_if_not(file.exists(docx), "POPCORN_scoping_protocol_wf.docx not available")

  footer_lookup <- docstyle:::get_footer_lookup(docx)

  ranges <- suppressWarnings(docstyle:::with_docx_temp(docx, function(temp_dir) {
    doc_xml <- xml2::read_xml(file.path(temp_dir, "word", "document.xml"))
    ns <- xml2::xml_ns(doc_xml)
    body <- xml2::xml_find_first(doc_xml, ".//w:body", ns)
    children <- xml2::xml_children(body)

    breaks <- docstyle:::detect_native_section_breaks(children, ns)
    body_info <- docstyle:::extract_body_sectpr_footer_info(body, ns)

    docstyle:::section_breaks_to_ranges(
      breaks, length(children),
      footer_lookup = footer_lookup,
      body_footer_info = body_info
    )
  }))

  # 5 sections
  expect_equal(length(ranges), 5)

  # Section 1 (title): footer suppressed
  expect_match(ranges[[1]]$div_open, 'footer="false"')

  # Section 2 (body): left text + right "Page {page} of {sectionpages}" + page-start="0"
  expect_match(ranges[[2]]$div_open, 'footer-left="POPCORN Scoping Review"')
  expect_match(ranges[[2]]$div_open, 'footer-right="Page \\{page\\} of \\{sectionpages\\}"')
  expect_match(ranges[[2]]$div_open, 'page-start="0"')
  expect_match(ranges[[2]]$div_open, 'footer-first="false"')

  # Section 3 (references): left text only, no right footer
  expect_match(ranges[[3]]$div_open, 'footer-left="POPCORN Scoping Review"')
  expect_no_match(ranges[[3]]$div_open, "footer-right")

  # Section 4 (appendix): left text + right page numbers + page-start="1"
  expect_match(ranges[[4]]$div_open, 'footer-left="POPCORN Scoping Review"')
  expect_match(ranges[[4]]$div_open, 'footer-right="Page \\{page\\} of \\{sectionpages\\}"')
  expect_match(ranges[[4]]$div_open, 'page-start="1"')

  # Section 5 (version history): left text only
  expect_match(ranges[[5]]$div_open, 'footer-left="POPCORN Scoping Review"')
  expect_no_match(ranges[[5]]$div_open, "footer-right")
})


# ══ ptab (absolute position tab) support ════════════════════════════════════

test_that("parse_footer_xml handles ptab-based three-column footer", {
  # Pattern 2: Word's "Blank (Three Columns)" built-in footer uses w:ptab
  xml_str <- make_footer_xml(paste0(
    '<w:p><w:pPr><w:pStyle w:val="Footer"/></w:pPr>',
    '<w:r><w:t>Left Text</w:t></w:r>',
    '<w:r><w:ptab w:alignment="center" w:relativeTo="margin" w:leader="none"/></w:r>',
    '<w:r><w:t>Center Text</w:t></w:r>',
    '<w:r><w:ptab w:alignment="right" w:relativeTo="margin" w:leader="none"/></w:r>',
    '<w:r><w:t>Right Text</w:t></w:r>',
    '</w:p>'
  ))
  ftr <- xml2::read_xml(xml_str)
  result <- docstyle:::parse_footer_xml(ftr, ns)

  expect_equal(result$left, "Left Text")
  expect_equal(result$center, "Center Text")
  expect_equal(result$right, "Right Text")
})

test_that("parse_footer_xml handles ptab with field codes", {
  xml_str <- make_footer_xml(paste0(
    '<w:p><w:pPr><w:pStyle w:val="Footer"/></w:pPr>',
    '<w:r><w:t>Document Title</w:t></w:r>',
    '<w:r><w:ptab w:alignment="center" w:relativeTo="margin" w:leader="none"/></w:r>',
    '<w:r><w:ptab w:alignment="right" w:relativeTo="margin" w:leader="none"/></w:r>',
    make_page_field(),
    '</w:p>'
  ))
  ftr <- xml2::read_xml(xml_str)
  result <- docstyle:::parse_footer_xml(ftr, ns)

  expect_equal(result$left, "Document Title")
  expect_null(result$center)
  expect_equal(result$right, "{page}")
})

test_that("detect_footer_layout identifies ptab-based layout", {
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:pPr><w:pStyle w:val="Footer"/></w:pPr>',
    '<w:r><w:t>L</w:t></w:r>',
    '<w:r><w:ptab w:alignment="center" w:relativeTo="margin" w:leader="none"/></w:r>',
    '<w:r><w:t>C</w:t></w:r>',
    '</w:p>'
  )
  para <- xml2::read_xml(para_xml)
  layout <- docstyle:::detect_footer_layout(para, ns)

  expect_equal(layout$type, "tabbed")
  expect_length(layout$tab_info, 1)
  expect_equal(layout$tab_info[[1]]$val, "center")
})

test_that("extract_footer_segments splits at ptab elements", {
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:r><w:t>A</w:t></w:r>',
    '<w:r><w:ptab w:alignment="center" w:relativeTo="margin" w:leader="none"/></w:r>',
    '<w:r><w:t>B</w:t></w:r>',
    '<w:r><w:ptab w:alignment="right" w:relativeTo="margin" w:leader="none"/></w:r>',
    '<w:r><w:t>C</w:t></w:r>',
    '</w:p>'
  )
  para <- xml2::read_xml(para_xml)
  segments <- docstyle:::extract_footer_segments(para, ns)

  expect_equal(segments, c("A", "B", "C"))
})


# ══ Table-based footer (Pattern 5) ══════════════════════════════════════════

test_that("parse_footer_xml handles 3-column table footer with warning", {
  xml_str <- make_footer_xml(paste0(
    '<w:tbl><w:tr>',
    '<w:tc><w:p><w:r><w:t>Left</w:t></w:r></w:p></w:tc>',
    '<w:tc><w:p><w:r><w:t>Center</w:t></w:r></w:p></w:tc>',
    '<w:tc><w:p><w:r><w:t>Right</w:t></w:r></w:p></w:tc>',
    '</w:tr></w:tbl>',
    '<w:p/>'
  ))
  ftr <- xml2::read_xml(xml_str)

  expect_warning(
    result <- docstyle:::parse_footer_xml(ftr, ns),
    "table layout"
  )

  expect_equal(result$left, "Left")
  expect_equal(result$center, "Center")
  expect_equal(result$right, "Right")
})

test_that("parse_footer_xml handles 2-column table footer", {
  xml_str <- make_footer_xml(paste0(
    '<w:tbl><w:tr>',
    '<w:tc><w:p><w:r><w:t>Title</w:t></w:r></w:p></w:tc>',
    '<w:tc><w:p>',
    make_page_field(),
    '</w:p></w:tc>',
    '</w:tr></w:tbl>',
    '<w:p/>'
  ))
  ftr <- xml2::read_xml(xml_str)

  expect_warning(
    result <- docstyle:::parse_footer_xml(ftr, ns),
    "table layout"
  )

  expect_equal(result$left, "Title")
  expect_equal(result$right, "{page}")
})

test_that("parse_footer_xml returns NULL for table with empty cells", {
  xml_str <- make_footer_xml(paste0(
    '<w:tbl><w:tr>',
    '<w:tc><w:p/></w:tc>',
    '<w:tc><w:p/></w:tc>',
    '</w:tr></w:tbl>',
    '<w:p/>'
  ))
  ftr <- xml2::read_xml(xml_str)
  result <- docstyle:::parse_footer_xml(ftr, ns)

  expect_null(result)
})
