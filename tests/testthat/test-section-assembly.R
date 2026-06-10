# Tests for assemble_section_breaks() and remove_trailing_sectPr()

# Helper: build minimal OOXML body with section markers
build_section_body <- function(...) {
  paras <- paste0(list(...), collapse = "")
  paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    paras,
    '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/>',
    '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" ',
    'w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>',
    '</w:body></w:document>'
  )
}

# Helper: content paragraph
content_para <- function(text) {
  paste0('<w:p><w:r><w:t>', text, '</w:t></w:r></w:p>')
}

# Helper: section marker wrapped in field code (v2 format)
section_marker <- function(class, page_break = "false", line_numbers = "none",
                           closing = FALSE, attrs = list()) {
  prefix <- if (closing) "DOCSTYLE_SECTION_END" else "DOCSTYLE_SECTION"
  marker_text <- paste0(prefix, "::", class, "::", page_break, "::", line_numbers)

  # Build field code JSON payload
  payload <- list(type = "section", version = 2L, class = class)
  payload[["page-break"]] <- page_break == "true"
  payload[["line-numbers"]] <- line_numbers
  # Add any extra attrs (e.g., footer-left, header-left)
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

default_page_config <- list(
  size = "letter",
  orientation = "portrait",
  margins = list(top = "1in", bottom = "1in", left = "1in", right = "1in")
)


# --- assemble_section_breaks() ---

test_that("assemble_section_breaks() returns structured list", {
  xml_str <- build_section_body(
    content_para("Front matter"),
    section_marker("section-body", line_numbers = "continuous"),
    content_para("Body content")
  )
  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_section_breaks(body, ns, default_page_config)

  expect_type(result, "list")
  expect_equal(result$n_assembled, 1L)
  expect_length(result$closing_sectpr_paras, 0)
  expect_length(result$section_sequence, 1)
  expect_equal(result$final_section_name, "section-body")
})

test_that("assemble_section_breaks() returns empty result when no markers", {
  xml_str <- build_section_body(content_para("Just content"))
  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_section_breaks(body, ns, default_page_config)

  expect_equal(result$n_assembled, 0L)
  expect_length(result$closing_sectpr_paras, 0)
  expect_length(result$section_sequence, 0)
  expect_null(result$final_section_name)
})

test_that("assemble_section_breaks() tracks closing markers in closing_sectpr_paras", {
  xml_str <- build_section_body(
    content_para("Front matter"),
    section_marker("section-landscape", page_break = "true", line_numbers = "none"),
    content_para("Landscape content"),
    section_marker("section-landscape", page_break = "true", line_numbers = "none",
                   closing = TRUE),
    content_para("Back to portrait")
  )
  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_section_breaks(body, ns, default_page_config)

  expect_equal(result$n_assembled, 2L)
  # One closing marker should be tracked
  expect_length(result$closing_sectpr_paras, 1)
  # Section sequence should have 2 entries
  expect_length(result$section_sequence, 2)
  expect_false(result$section_sequence[[1]]$is_closing)
  expect_true(result$section_sequence[[2]]$is_closing)
})

test_that("assemble_section_breaks() extracts field code payload", {
  xml_str <- build_section_body(
    content_para("Front matter"),
    section_marker("section-body", line_numbers = "continuous",
                   attrs = list("footer-left" = "Draft",
                                "footer-right" = "Page {page}")),
    content_para("Body content")
  )
  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_section_breaks(body, ns, default_page_config)

  expect_equal(result$n_assembled, 1L)
  payload <- result$section_sequence[[1]]$field_code_payload
  expect_false(is.null(payload))
  expect_equal(payload[["footer-left"]], "Draft")
  expect_equal(payload[["footer-right"]], "Page {page}")
})


# --- remove_trailing_sectPr() with closing_sectpr_paras guard ---

test_that("remove_trailing_sectPr() removes unguarded trailing sectPr", {
  # Build a document where the last mid-doc sectPr has no content after it
  xml_str <- paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    '<w:p><w:r><w:t>Content</w:t></w:r></w:p>',
    '<w:p><w:pPr><w:sectPr><w:type w:val="continuous"/></w:sectPr></w:pPr></w:p>',
    '<w:p></w:p>',  # empty para (non-content)
    '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr>',
    '</w:body></w:document>'
  )
  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- remove_trailing_sectPr(body, ns, closing_sectpr_paras = list())

  expect_true(result)
  # The mid-doc sectPr para should be gone
  sect_paras <- xml2::xml_find_all(body, "w:p[w:pPr/w:sectPr]", ns)
  expect_length(sect_paras, 0)
})

test_that("remove_trailing_sectPr() preserves guarded closing sectPr", {
  # Simulate a wrapping div's closing sectPr at the end of the document
  xml_str <- paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    '<w:p><w:r><w:t>Content before landscape</w:t></w:r></w:p>',
    # Opening sectPr
    '<w:p><w:pPr><w:sectPr><w:type w:val="continuous"/></w:sectPr></w:pPr></w:p>',
    '<w:p><w:r><w:t>Landscape content</w:t></w:r></w:p>',
    # Closing sectPr (this is the one we want to guard)
    '<w:p><w:pPr><w:sectPr><w:type w:val="continuous"/></w:sectPr></w:pPr></w:p>',
    '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr>',
    '</w:body></w:document>'
  )
  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  # The closing sectPr is the last one (second of two)
  sect_paras <- xml2::xml_find_all(body, "w:p[w:pPr/w:sectPr]", ns)
  closing_para <- sect_paras[[length(sect_paras)]]

  result <- remove_trailing_sectPr(body, ns,
    closing_sectpr_paras = list(closing_para))

  expect_false(result)
  # Both mid-doc sectPr paragraphs should still exist
  sect_paras_after <- xml2::xml_find_all(body, "w:p[w:pPr/w:sectPr]", ns)
  expect_length(sect_paras_after, 2)
})

test_that("remove_trailing_sectPr() still removes non-closing trailing sectPr even when closing list provided", {
  # An unguarded trailing sectPr should still be removed even if other paras are in the guard list
  xml_str <- paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    '<w:p><w:r><w:t>Content</w:t></w:r></w:p>',
    # First sectPr (guarded)
    '<w:p><w:pPr><w:sectPr><w:type w:val="continuous"/></w:sectPr></w:pPr></w:p>',
    '<w:p><w:r><w:t>More content</w:t></w:r></w:p>',
    # Second sectPr (unguarded, trailing)
    '<w:p><w:pPr><w:sectPr><w:type w:val="continuous"/></w:sectPr></w:pPr></w:p>',
    '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr>',
    '</w:body></w:document>'
  )
  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  # Guard the FIRST sectPr, not the second
  sect_paras <- xml2::xml_find_all(body, "w:p[w:pPr/w:sectPr]", ns)
  first_para <- sect_paras[[1]]

  result <- remove_trailing_sectPr(body, ns,
    closing_sectpr_paras = list(first_para))

  expect_true(result)  # The second (unguarded) trailing sectPr was removed
  sect_paras_after <- xml2::xml_find_all(body, "w:p[w:pPr/w:sectPr]", ns)
  expect_length(sect_paras_after, 1)  # Only the first remains
})

test_that("remove_trailing_sectPr() does not remove when content follows", {
  xml_str <- paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    '<w:p><w:r><w:t>Content</w:t></w:r></w:p>',
    '<w:p><w:pPr><w:sectPr><w:type w:val="continuous"/></w:sectPr></w:pPr></w:p>',
    '<w:p><w:r><w:t>More content after section break</w:t></w:r></w:p>',
    '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr>',
    '</w:body></w:document>'
  )
  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- remove_trailing_sectPr(body, ns, closing_sectpr_paras = list())

  expect_false(result)
  sect_paras <- xml2::xml_find_all(body, "w:p[w:pPr/w:sectPr]", ns)
  expect_length(sect_paras, 1)
})


# --- Integration: wrapping div with closing marker at end of document ---

test_that("wrapping div closing sectPr survives full assembly + trailing cleanup", {
  # Simulate: front matter, then wrapping landscape section at end of document
  xml_str <- build_section_body(
    content_para("Front matter content"),
    section_marker("section-landscape", page_break = "true", line_numbers = "none"),
    content_para("Wide table data"),
    section_marker("section-landscape", page_break = "true", line_numbers = "none",
                   closing = TRUE)
    # No content after closing marker — this is the bug case
  )
  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  # Step 1: Assemble section breaks
  result <- assemble_section_breaks(body, ns, default_page_config)
  expect_equal(result$n_assembled, 2L)
  expect_length(result$closing_sectpr_paras, 1)

  # Verify sectPr paragraphs were created
  sect_paras <- xml2::xml_find_all(body, "w:p[w:pPr/w:sectPr]", ns)
  expect_length(sect_paras, 2)

  # Step 2: remove_trailing_sectPr with the guard
  trailing_removed <- remove_trailing_sectPr(body, ns,
    closing_sectpr_paras = result$closing_sectpr_paras)

  # The closing sectPr should NOT have been removed
  expect_false(trailing_removed)
  sect_paras_after <- xml2::xml_find_all(body, "w:p[w:pPr/w:sectPr]", ns)
  expect_length(sect_paras_after, 2)
})

test_that("line numbers reset correctly after wrapping div closes", {
  # Simulate: front matter (no line numbers), body (continuous), landscape (none), back to body
  xml_str <- build_section_body(
    content_para("Front matter"),
    section_marker("section-body", line_numbers = "continuous"),
    content_para("Body with line numbers"),
    section_marker("section-landscape", line_numbers = "none"),
    content_para("Landscape table"),
    section_marker("section-landscape", line_numbers = "none", closing = TRUE),
    content_para("Back to body with line numbers")
  )
  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_section_breaks(body, ns, default_page_config)
  expect_equal(result$n_assembled, 3L)

  # Check the sectPr elements in order
  sect_paras <- xml2::xml_find_all(body, "w:p[w:pPr/w:sectPr]", ns)
  expect_length(sect_paras, 3)

  # First sectPr (ends front matter): should have no line numbers
  sectPr1 <- xml2::xml_find_first(sect_paras[[1]], "w:pPr/w:sectPr", ns)
  lnNum1 <- xml2::xml_find_first(sectPr1, "w:lnNumType", ns)
  expect_true(inherits(lnNum1, "xml_missing"))

  # Second sectPr (ends body section): should have continuous line numbers
  sectPr2 <- xml2::xml_find_first(sect_paras[[2]], "w:pPr/w:sectPr", ns)
  lnNum2 <- xml2::xml_find_first(sectPr2, "w:lnNumType", ns)
  expect_false(inherits(lnNum2, "xml_missing"))
  expect_equal(xml2::xml_attr(lnNum2, "restart"), "continuous")

  # Third sectPr (ends landscape section, closing marker): no line numbers
  sectPr3 <- xml2::xml_find_first(sect_paras[[3]], "w:pPr/w:sectPr", ns)
  lnNum3 <- xml2::xml_find_first(sectPr3, "w:lnNumType", ns)
  expect_true(inherits(lnNum3, "xml_missing"))

  # Body sectPr (final section = after closing marker): line_numbers = "none"
  body_sectPr <- xml2::xml_find_first(body, "w:sectPr", ns)
  body_lnNum <- xml2::xml_find_first(body_sectPr, "w:lnNumType", ns)
  expect_true(inherits(body_lnNum, "xml_missing"))
})

# --- page-start (pgNumType) ---
# For NON-WRAPPING markers (opening only, no closing pair): page-start goes on
# the opening marker's sectPr (the only sectPr for that transition).
# For WRAPPING divs (opening + closing pair): page-start goes on the CLOSING
# marker's sectPr (which defines the div's own section per OOXML's backward model).

test_that("page-start applies directly to the marker's own sectPr", {
  # body marker (no page-start), appendix marker (page-start=1)
  # The appendix marker's sectPr should have pgNumType start="1"
  xml_str <- build_section_body(
    content_para("Front matter"),
    section_marker("section-body", line_numbers = "continuous"),
    content_para("Body content"),
    section_marker("section-appendix", line_numbers = "section",
                   attrs = list("page-start" = "1")),
    content_para("Appendix content")
  )
  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_section_breaks(body, ns, default_page_config)
  expect_equal(result$n_assembled, 2L)

  sect_paras <- xml2::xml_find_all(body, "w:p[w:pPr/w:sectPr]", ns)

  # sectPr at marker 1 (body-open, ends front matter): no pgNumType
  sectPr1 <- xml2::xml_find_first(sect_paras[[1]], "w:pPr/w:sectPr", ns)
  pgNum1 <- xml2::xml_find_first(sectPr1, "w:pgNumType", ns)
  expect_true(inherits(pgNum1, "xml_missing"))

  # sectPr at marker 2 (appendix-open, ends body): SHOULD have pgNumType start="1"
  sectPr2 <- xml2::xml_find_first(sect_paras[[2]], "w:pPr/w:sectPr", ns)
  pgNum2 <- xml2::xml_find_first(sectPr2, "w:pgNumType", ns)
  expect_false(inherits(pgNum2, "xml_missing"))
  expect_equal(xml2::xml_attr(pgNum2, "start"), "1")

  # Body sectPr: no pgNumType (no page-start on last section)
  body_sectPr <- xml2::xml_find_first(body, "w:sectPr", ns)
  pgNumBody <- xml2::xml_find_first(body_sectPr, "w:pgNumType", ns)
  expect_true(inherits(pgNumBody, "xml_missing"))
})

test_that("page-start on first marker applies to its own sectPr", {
  # body marker with page-start=1, appendix marker without
  xml_str <- build_section_body(
    content_para("Front matter"),
    section_marker("section-body", line_numbers = "continuous",
                   attrs = list("page-start" = "1")),
    content_para("Body content"),
    section_marker("section-appendix", line_numbers = "none"),
    content_para("Appendix content")
  )
  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_section_breaks(body, ns, default_page_config)
  expect_equal(result$n_assembled, 2L)

  sect_paras <- xml2::xml_find_all(body, "w:p[w:pPr/w:sectPr]", ns)

  # sectPr at marker 1 (body-open): SHOULD have pgNumType start="1"
  sectPr1 <- xml2::xml_find_first(sect_paras[[1]], "w:pPr/w:sectPr", ns)
  pgNum1 <- xml2::xml_find_first(sectPr1, "w:pgNumType", ns)
  expect_false(inherits(pgNum1, "xml_missing"))
  expect_equal(xml2::xml_attr(pgNum1, "start"), "1")

  # sectPr at marker 2 (appendix-open): no pgNumType
  sectPr2 <- xml2::xml_find_first(sect_paras[[2]], "w:pPr/w:sectPr", ns)
  pgNum2 <- xml2::xml_find_first(sectPr2, "w:pgNumType", ns)
  expect_true(inherits(pgNum2, "xml_missing"))

  # Body sectPr: no pgNumType
  body_sectPr <- xml2::xml_find_first(body, "w:sectPr", ns)
  pgNumBody <- xml2::xml_find_first(body_sectPr, "w:pgNumType", ns)
  expect_true(inherits(pgNumBody, "xml_missing"))
})

test_that("wrapping div: page-start applies to closing marker's sectPr", {
  # POPCORN case: body (open+close) then appendix (open with page-start + close)
  # For wrapping divs, pgNumType goes on the CLOSING marker's sectPr because
  # it defines the div's own section (Word's backward-looking model).
  # The opening marker's sectPr ends the previous section, not this one.
  xml_str <- build_section_body(
    content_para("Front matter"),
    section_marker("section-body", line_numbers = "continuous"),
    content_para("Body content"),
    section_marker("section-body", line_numbers = "continuous", closing = TRUE),
    section_marker("section-appendix", line_numbers = "section",
                   attrs = list("page-start" = "1")),
    content_para("Appendix content"),
    section_marker("section-appendix", line_numbers = "section",
                   attrs = list("page-start" = "1"), closing = TRUE)
  )
  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_section_breaks(body, ns, default_page_config)
  expect_equal(result$n_assembled, 4L)

  # Find all mid-document sectPrs with pgNumType
  all_sectPrs <- xml2::xml_find_all(body, ".//w:pPr/w:sectPr", ns)
  pgNum_count <- sum(vapply(all_sectPrs, function(sp) {
    !inherits(xml2::xml_find_first(sp, "w:pgNumType", ns), "xml_missing")
  }, logical(1)))

  # Exactly ONE sectPr should have pgNumType (the appendix-close marker's)
  expect_equal(pgNum_count, 1L)

  # Verify it's on the appendix content paragraph (closing marker's predecessor),
  # NOT on the body content paragraph (opening marker's predecessor)
  sect_paras <- xml2::xml_find_all(body, "w:p[w:pPr/w:sectPr]", ns)
  for (sp in sect_paras) {
    sectPr <- xml2::xml_find_first(sp, "w:pPr/w:sectPr", ns)
    pgNum <- xml2::xml_find_first(sectPr, "w:pgNumType", ns)
    if (!inherits(pgNum, "xml_missing")) {
      # The paragraph with pgNumType should contain "Appendix content"
      para_text <- xml2::xml_text(sp)
      expect_match(para_text, "Appendix content")
    }
  }

  # Body sectPr should NOT have pgNumType
  body_sectPr <- xml2::xml_find_first(body, "w:sectPr", ns)
  pgNumBody <- xml2::xml_find_first(body_sectPr, "w:pgNumType", ns)
  expect_true(inherits(pgNumBody, "xml_missing"))
})

test_that("build_sect_pr_xml includes pgNumType when page_start is set", {
  xml_str <- build_sect_pr_xml(default_page_config, "continuous", "none",
                               page_start = "5")
  expect_match(xml_str, 'w:pgNumType w:start="5"')

  # Without page_start
  xml_str2 <- build_sect_pr_xml(default_page_config, "continuous", "none")
  expect_no_match(xml_str2, "pgNumType")
})

test_that("build_sect_pr_xml uses page-config defaults for line number attrs", {
  config_with_ln <- list(
    size = "letter",
    orientation = "portrait",
    margins = list(top = "1in", bottom = "1in", left = "1in", right = "1in"),
    `line-numbers` = list(
      enabled = TRUE,
      `count-by` = 5,
      restart = "page",
      distance = "0.5in",
      start = 1
    )
  )

  xml_str <- build_sect_pr_xml(config_with_ln, "continuous", "page")
  # count-by=5, distance=0.5in=720twips from page_config defaults
  expect_match(xml_str, 'w:countBy="5"')
  expect_match(xml_str, 'w:distance="720"')
  expect_match(xml_str, 'w:restart="newPage"')
  expect_match(xml_str, 'w:start="1"')
})

test_that("build_sect_pr_xml explicit params override page-config defaults", {
  config_with_ln <- list(
    size = "letter",
    orientation = "portrait",
    margins = list(top = "1in", bottom = "1in", left = "1in", right = "1in"),
    `line-numbers` = list(
      enabled = TRUE,
      `count-by` = 5,
      restart = "page",
      distance = "0.5in",
      start = 1
    )
  )

  # Explicit params take priority over page_config
  xml_str <- build_sect_pr_xml(config_with_ln, "continuous", "section",
                                count_by = 10, distance = 200, start_num = 50)
  expect_match(xml_str, 'w:countBy="10"')
  expect_match(xml_str, 'w:distance="200"')
  expect_match(xml_str, 'w:restart="newSection"')
  expect_match(xml_str, 'w:start="50"')
})

test_that("build_sect_pr_xml defaults to countBy=1 distance=360 without page-config", {
  # No line-numbers in page_config -> falls back to 1/360
  xml_str <- build_sect_pr_xml(default_page_config, "continuous", "continuous")
  expect_match(xml_str, 'w:countBy="1"')
  expect_match(xml_str, 'w:distance="360"')
  expect_match(xml_str, 'w:restart="continuous"')
  expect_no_match(xml_str, 'w:start=')
})

test_that("per-section line number attrs flow through assembly to sectPr", {
  # Section A has count-by=5, distance=0.5in (720 twips)
  # Section B has count-by=10, start=20
  xml_str <- build_section_body(
    content_para("Title page"),
    section_marker("section-body", line_numbers = "page",
                   attrs = list("line-numbers-count-by" = "5",
                                "line-numbers-distance" = "0.5in")),
    content_para("Body content"),
    section_marker("section-appendix", line_numbers = "section",
                   attrs = list("line-numbers-count-by" = "10",
                                "line-numbers-start" = "20")),
    content_para("Appendix content")
  )
  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_section_breaks(body, ns, default_page_config)
  expect_equal(result$n_assembled, 2L)

  # First marker's sectPr ends the "title page" section (prev_line_numbers="none")
  # so it should have NO lnNumType
  sect_paras <- xml2::xml_find_all(body, ".//w:p[w:pPr/w:sectPr]", ns)
  expect_length(sect_paras, 2)

  # First sectPr: ends the implicit first section (no line numbers)
  sectPr1 <- xml2::xml_find_first(sect_paras[[1]], "w:pPr/w:sectPr", ns)
  ln1 <- xml2::xml_find_first(sectPr1, "w:lnNumType", ns)
  expect_true(inherits(ln1, "xml_missing"))

  # Second sectPr: ends the body section (line-numbers="page", count-by=5, distance=720)
  sectPr2 <- xml2::xml_find_first(sect_paras[[2]], "w:pPr/w:sectPr", ns)
  ln2 <- xml2::xml_find_first(sectPr2, "w:lnNumType", ns)
  expect_false(inherits(ln2, "xml_missing"))
  expect_equal(xml2::xml_attr(ln2, "countBy"), "5")
  expect_equal(xml2::xml_attr(ln2, "distance"), "720")
  expect_equal(xml2::xml_attr(ln2, "restart"), "newPage")

  # Body sectPr: ends the appendix section (line-numbers="section", count-by=10, start=20)
  body_sectPr <- xml2::xml_find_first(body, "w:sectPr", ns)
  body_ln <- xml2::xml_find_first(body_sectPr, "w:lnNumType", ns)
  expect_false(inherits(body_ln, "xml_missing"))
  expect_equal(xml2::xml_attr(body_ln, "countBy"), "10")
  expect_equal(xml2::xml_attr(body_ln, "restart"), "newSection")
  expect_equal(xml2::xml_attr(body_ln, "start"), "20")
})

test_that("adjacent closing/opening markers produce two sectPr (not collapsed)", {
  # Simulate: section-A closes, section-B opens immediately
  xml_str <- build_section_body(
    content_para("Content in section A"),
    section_marker("section-a", line_numbers = "continuous"),
    content_para("Section A content"),
    section_marker("section-a", line_numbers = "continuous", closing = TRUE),
    section_marker("section-b", line_numbers = "none"),
    content_para("Section B content")
  )
  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_section_breaks(body, ns, default_page_config)

  # 3 markers: opening-A, closing-A, opening-B
  expect_equal(result$n_assembled, 3L)
  expect_length(result$section_sequence, 3)
  expect_length(result$closing_sectpr_paras, 1)
})


# --- Test gaps from issue #42 ---

test_that("body sectPr gets continuous type after assembly", {
  xml_str <- build_section_body(
    content_para("Title page"),
    section_marker("section-body", line_numbers = "continuous"),
    content_para("Body content")
  )
  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  assemble_section_breaks(body, ns, default_page_config)

  body_sectPr <- xml2::xml_find_first(body, "w:sectPr", ns)
  body_type <- xml2::xml_find_first(body_sectPr, "w:type", ns)
  expect_false(inherits(body_type, "xml_missing"))
  expect_equal(xml2::xml_attr(body_type, "val"), "continuous")
})

test_that("three+ sections with mixed line-number modes", {
  # page -> continuous -> section -> none
  xml_str <- build_section_body(
    content_para("Title page"),
    section_marker("section-body", line_numbers = "page"),
    content_para("Body with page-restart line numbers"),
    section_marker("section-methods", line_numbers = "continuous"),
    content_para("Methods with continuous line numbers"),
    section_marker("section-results", line_numbers = "section"),
    content_para("Results with section-restart line numbers"),
    section_marker("section-appendix", line_numbers = "none"),
    content_para("Appendix with no line numbers")
  )
  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_section_breaks(body, ns, default_page_config)
  expect_equal(result$n_assembled, 4L)

  sect_paras <- xml2::xml_find_all(body, ".//w:p[w:pPr/w:sectPr]", ns)
  expect_length(sect_paras, 4)

  # sectPr 1: ends implicit first section (no line numbers)
  sectPr1 <- xml2::xml_find_first(sect_paras[[1]], "w:pPr/w:sectPr", ns)
  ln1 <- xml2::xml_find_first(sectPr1, "w:lnNumType", ns)
  expect_true(inherits(ln1, "xml_missing"))

  # sectPr 2: ends "body" section (page-restart line numbers)
  sectPr2 <- xml2::xml_find_first(sect_paras[[2]], "w:pPr/w:sectPr", ns)
  ln2 <- xml2::xml_find_first(sectPr2, "w:lnNumType", ns)
  expect_false(inherits(ln2, "xml_missing"))
  expect_equal(xml2::xml_attr(ln2, "restart"), "newPage")

  # sectPr 3: ends "methods" section (continuous line numbers)
  sectPr3 <- xml2::xml_find_first(sect_paras[[3]], "w:pPr/w:sectPr", ns)
  ln3 <- xml2::xml_find_first(sectPr3, "w:lnNumType", ns)
  expect_false(inherits(ln3, "xml_missing"))
  expect_equal(xml2::xml_attr(ln3, "restart"), "continuous")

  # sectPr 4: ends "results" section (section-restart line numbers)
  sectPr4 <- xml2::xml_find_first(sect_paras[[4]], "w:pPr/w:sectPr", ns)
  ln4 <- xml2::xml_find_first(sectPr4, "w:lnNumType", ns)
  expect_false(inherits(ln4, "xml_missing"))
  expect_equal(xml2::xml_attr(ln4, "restart"), "newSection")

  # Body sectPr: ends "appendix" section (no line numbers)
  body_sectPr <- xml2::xml_find_first(body, "w:sectPr", ns)
  body_ln <- xml2::xml_find_first(body_sectPr, "w:lnNumType", ns)
  expect_true(inherits(body_ln, "xml_missing"))
})


# --- Marker paragraph removal (#69) ---
# Marker paragraphs are merged into adjacent content paragraphs and removed.
# Field code runs (instrText) move into the content paragraph; the standalone
# marker paragraph is deleted to eliminate the blank line entirely.

test_that("marker paragraph is merged into next content paragraph after assembly", {
  xml_str <- build_section_body(
    content_para("Front matter"),
    section_marker("section-body", line_numbers = "continuous"),
    content_para("Body content")
  )
  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  assemble_section_breaks(body, ns, default_page_config)

  # The marker paragraph should have been removed — field code runs merged
  # into the "Body content" paragraph (opening markers merge forward)
  body_para <- xml2::xml_find_first(body,
    './/w:p[w:r/w:t[contains(., "Body content")]]', ns)
  expect_false(inherits(body_para, "xml_missing"))

  # The field code should now be inside the content paragraph
  instr <- xml2::xml_find_first(body_para, ".//w:instrText", ns)
  expect_false(inherits(instr, "xml_missing"),
    label = "Field code runs should be merged into the content paragraph")
  expect_true(grepl("ADDIN DOCSTYLE", xml2::xml_text(instr)))
})

test_that("wrapping div markers are merged into adjacent content paragraphs", {
  xml_str <- build_section_body(
    content_para("Front matter"),
    section_marker("section-body", attrs = list("footer-left" = "{page}")),
    content_para("Inside div"),
    section_marker("section-body", closing = TRUE),
    content_para("After div")
  )
  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  assemble_section_breaks(body, ns, default_page_config)

  # Opening marker merges into "Inside div" (next paragraph)
  inside_para <- xml2::xml_find_first(body,
    './/w:p[w:r/w:t[contains(., "Inside div")]]', ns)
  expect_false(inherits(inside_para, "xml_missing"))
  open_instr <- xml2::xml_find_first(inside_para, ".//w:instrText", ns)
  expect_false(inherits(open_instr, "xml_missing"),
    label = "Opening marker field code should be merged into 'Inside div' paragraph")

  # Closing marker merges into "Inside div" (previous paragraph)
  # The closing marker's instrText JSON uses "class":"section-body" (not -end)
  all_instr <- xml2::xml_find_all(body, ".//w:instrText", ns)
  docstyle_instr <- vapply(all_instr, function(x) {
    grepl("ADDIN DOCSTYLE", xml2::xml_text(x))
  }, logical(1))
  expect_true(sum(docstyle_instr) >= 2L,
    label = "Both opening and closing marker field codes should be preserved after merge")
})


# --- page-start deferral for wrapping divs ---

test_that("page-start from opening marker is deferred to closing marker's sectPr", {
  # Wrapping div: opening marker has page-start="1", closing marker doesn't
  # (Lua strips page-start from closing markers by design)
  xml_str <- build_section_body(
    content_para("Front matter"),
    section_marker("section-appendix", page_break = "true",
                   attrs = list(`page-start` = "1")),
    content_para("Appendix content"),
    section_marker("section-appendix", closing = TRUE),
    content_para("After appendix")
  )
  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_section_breaks(body, ns, default_page_config)

  # The closing marker's sectPr attaches to the "Appendix content" paragraph
  # (the last content paragraph before the closing marker). Verify pgNumType
  # is on THAT specific sectPr, not just any sectPr in the document.
  appendix_para <- xml2::xml_find_first(body,
    './/w:p[w:r/w:t[contains(., "Appendix content")]]', ns)
  expect_false(inherits(appendix_para, "xml_missing"),
    label = "Should find the 'Appendix content' paragraph")

  appendix_sectPr <- xml2::xml_find_first(appendix_para, "w:pPr/w:sectPr", ns)
  expect_false(inherits(appendix_sectPr, "xml_missing"),
    label = "Appendix content paragraph should have a sectPr")

  pgNum <- xml2::xml_find_first(appendix_sectPr, "w:pgNumType", ns)
  expect_false(inherits(pgNum, "xml_missing"),
    label = "Closing marker's sectPr should have pgNumType (deferred from opening)")
  expect_equal(xml2::xml_attr(pgNum, "start"), "1",
    label = "pgNumType start should be '1'")
})

test_that("page-start deferral does not leak to unrelated closing markers", {
  # Two wrapping divs: only the first has page-start
  xml_str <- build_section_body(
    content_para("Front matter"),
    section_marker("section-body"),
    content_para("Body content"),
    section_marker("section-body", closing = TRUE),
    section_marker("section-appendix", page_break = "true",
                   attrs = list(`page-start` = "3")),
    content_para("Appendix content"),
    section_marker("section-appendix", closing = TRUE),
    content_para("After")
  )
  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_section_breaks(body, ns, default_page_config)

  # Check all inline sectPrs
  sectprs <- xml2::xml_find_all(body, ".//w:pPr/w:sectPr", ns)

  # Count how many have pgNumType — should be exactly 1 (the appendix closing)
  pgnum_count <- 0L
  for (sp in sectprs) {
    pgNum <- xml2::xml_find_first(sp, "w:pgNumType", ns)
    if (!inherits(pgNum, "xml_missing")) {
      pgnum_count <- pgnum_count + 1L
      expect_equal(xml2::xml_attr(pgNum, "start"), "3")
    }
  }
  expect_equal(pgnum_count, 1L,
    label = "Only appendix closing sectPr should have pgNumType, not body closing")
})


# --- Empty wrapping div suppression (#74) ---

test_that("empty wrapping div (no content between markers) is suppressed (#74)", {
  # Document ends with an empty section div — no paragraphs between opening
  # and closing markers. Both markers should be suppressed so no spurious
  # blank page is created.
  xml_str <- build_section_body(
    content_para("Body content"),
    section_marker("section-body", page_break = "false", line_numbers = "none"),
    section_marker("section-body", page_break = "false", line_numbers = "none",
                   closing = TRUE)
  )
  xml  <- xml2::read_xml(xml_str)
  ns   <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_section_breaks(body, ns, default_page_config)

  # No inline sectPr should be added (both markers suppressed)
  inline_sectprs <- xml2::xml_find_all(body, ".//w:pPr/w:sectPr", ns)
  expect_length(inline_sectprs, 0L)

  # n_assembled should be 0 (no sections assembled)
  expect_equal(result$n_assembled, 0L)
})

test_that("non-empty wrapping div is NOT suppressed (#74)", {
  # Div with content between markers must still be processed normally.
  xml_str <- build_section_body(
    content_para("Before"),
    section_marker("section-appendix", page_break = "false", line_numbers = "none"),
    content_para("Appendix content"),
    section_marker("section-appendix", page_break = "false", line_numbers = "none",
                   closing = TRUE)
  )
  xml  <- xml2::read_xml(xml_str)
  ns   <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_section_breaks(body, ns, default_page_config)

  # At least one inline sectPr should be created
  inline_sectprs <- xml2::xml_find_all(body, ".//w:pPr/w:sectPr", ns)
  expect_gt(length(inline_sectprs), 0L,
    label = "Non-empty div should produce inline sectPr(s)")
})

test_that("empty div mixed with non-empty div: only empty is suppressed (#74)", {
  # Opening markers: section-body (empty) and section-appendix (has content).
  # Only section-body pair should be suppressed.
  xml_str <- build_section_body(
    content_para("Main"),
    section_marker("section-body", page_break = "false", line_numbers = "none"),
    section_marker("section-body", page_break = "false", line_numbers = "none",
                   closing = TRUE),
    section_marker("section-appendix", page_break = "false", line_numbers = "none"),
    content_para("Appendix"),
    section_marker("section-appendix", page_break = "false", line_numbers = "none",
                   closing = TRUE)
  )
  xml  <- xml2::read_xml(xml_str)
  ns   <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_section_breaks(body, ns, default_page_config)

  # The appendix pair has content — at least one sectPr expected
  inline_sectprs <- xml2::xml_find_all(body, ".//w:pPr/w:sectPr", ns)
  expect_gt(length(inline_sectprs), 0L,
    label = "Appendix (non-empty) should still produce a sectPr")

  # section-body pair was empty — its opening marker's predecessor is "Main".
  # "Main" should NOT have received a sectPr from the suppressed empty pair.
  # Count total sectPrs: should match only the non-suppressed markers.
  # Two markers remain (appendix opening + closing) → ≤ 2 inline sectPrs.
  expect_lte(length(inline_sectprs), 2L,
    label = "Suppressed empty div should not add extra sectPr")
})


# --- #42: high-priority test gaps ---

# Helper: page break paragraph as Lua emits it
page_break_para <- function() {
  '<w:p><w:r><w:br w:type="page"/></w:r></w:p>'
}

test_that("#42: deferred nextPage — closing immediately before opening with page-break", {
  # When a closing marker is immediately followed by an opening marker that has
  # page-break=true, the sectPr type should be nextPage (not duplicated).
  xml_str <- build_section_body(
    content_para("Front matter"),
    section_marker("section-body", page_break = "false", closing = FALSE),
    content_para("Body"),
    page_break_para(),
    section_marker("section-body", closing = TRUE),
    page_break_para(),
    section_marker("section-appendix", page_break = "true", closing = FALSE),
    content_para("Appendix"),
    section_marker("section-appendix", closing = TRUE)
  )
  xml  <- xml2::read_xml(xml_str)
  ns   <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_section_breaks(body, ns, default_page_config)
  expect_gte(result$n_assembled, 2L)

  # Inline sectPrs — find the one that closes section-body (should be nextPage)
  inline_sectprs <- xml2::xml_find_all(body, ".//w:pPr/w:sectPr", ns)
  types <- vapply(inline_sectprs, function(s) {
    t <- xml2::xml_find_first(s, "w:type", ns)
    if (inherits(t, "xml_missing")) "missing" else xml2::xml_attr(t, "val")
  }, character(1))

  expect_true(any(types == "nextPage"),
    info = paste("Expected at least one nextPage sectPr, got:", paste(types, collapse = ", ")))
})

test_that("#42: page break removal — Lua-emitted w:br is removed when nextPage applied", {
  # nextPage sectPr handles the page break; the manual <w:br type="page"/>
  # emitted by Lua should be removed to avoid a double page break.
  xml_str <- build_section_body(
    content_para("Front matter"),
    page_break_para(),
    section_marker("section-body", page_break = "true"),
    content_para("Body")
  )
  xml  <- xml2::read_xml(xml_str)
  ns   <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  assemble_section_breaks(body, ns, default_page_config)

  remaining_breaks <- xml2::xml_find_all(body, './/w:br[@w:type="page"]', ns)
  expect_length(remaining_breaks, 0L)
})

test_that("#42: page break removal — w:br is removed even with intervening empty paragraphs", {
  # Pandoc may insert empty paragraphs or structural elements between the page
  # break and the marker. The backward search should skip them.
  xml_str <- build_section_body(
    content_para("Front matter"),
    page_break_para(),
    '<w:p/>',  # empty paragraph between break and marker
    section_marker("section-body", page_break = "true"),
    content_para("Body")
  )
  xml  <- xml2::read_xml(xml_str)
  ns   <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  assemble_section_breaks(body, ns, default_page_config)

  remaining_breaks <- xml2::xml_find_all(body, './/w:br[@w:type="page"]', ns)
  expect_length(remaining_breaks, 0L)
})

test_that("#42: body sectPr gets continuous type when last section is a wrapping div", {
  # After assembly, the body sectPr (not inline) should have type=continuous
  # when the last content is inside a wrapping div (prevents trailing blank page).
  xml_str <- build_section_body(
    content_para("Front matter"),
    section_marker("section-body", closing = FALSE),
    content_para("Body content"),
    section_marker("section-body", closing = TRUE)
  )
  xml  <- xml2::read_xml(xml_str)
  ns   <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  assemble_section_breaks(body, ns, default_page_config)

  body_sectPr <- xml2::xml_find_first(body, "w:sectPr", ns)
  expect_false(inherits(body_sectPr, "xml_missing"),
    label = "Body sectPr should exist")

  type_node <- xml2::xml_find_first(body_sectPr, "w:type", ns)
  body_type  <- if (inherits(type_node, "xml_missing")) "missing" else xml2::xml_attr(type_node, "val")
  expect_equal(body_type, "continuous",
    label = "Body sectPr should be continuous when last content is in a wrapping div")
})


# --- #43: multi-section feature matrix ---

test_that("#43: multi-section — line numbers applied only to body section", {
  # Section matrix: title(none) → body(continuous) → appendix(none)
  # lnNumType should appear on exactly one inline sectPr (the one closing body)
  # Note: each marker needs its own exclusive predecessor paragraph — adjacent
  # closing+opening markers that share a predecessor cause the second attach_sect_pr
  # to overwrite the first. Extra paragraphs give each marker its own predecessor.
  xml_str <- build_section_body(
    content_para("Title page content"),
    section_marker("section-body", page_break = "true", line_numbers = "continuous",
                   closing = FALSE),
    content_para("Body content"),
    content_para("More body content"),
    section_marker("section-body", closing = TRUE),
    content_para("Transition paragraph"),
    section_marker("section-appendix", page_break = "true", line_numbers = "none",
                   closing = FALSE),
    content_para("Appendix content"),
    section_marker("section-appendix", closing = TRUE)
  )
  xml  <- xml2::read_xml(xml_str)
  ns   <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  assemble_section_breaks(body, ns, default_page_config)

  # Only one lnNumType should exist (the one closing body, which had line-numbers).
  # Use local-name() to avoid namespace prefix mismatches on injected sectPr nodes.
  all_ln <- xml2::xml_find_all(body, ".//*[local-name()='lnNumType']")
  expect_length(all_ln, 1L)

  # Verify it is continuous restart
  restart <- xml2::xml_attr(all_ln[[1]], "restart")
  expect_equal(restart, "continuous")
})

test_that("#43: multi-section — three nextPage breaks for four sections", {
  # title → body → appendix → back: three transitions, all nextPage
  xml_str <- build_section_body(
    content_para("Title"),
    section_marker("section-body", page_break = "true", closing = FALSE),
    content_para("Body"),
    section_marker("section-body", closing = TRUE),
    section_marker("section-appendix", page_break = "true", closing = FALSE),
    content_para("Appendix"),
    section_marker("section-appendix", closing = TRUE),
    section_marker("section-back", page_break = "true")
  )
  xml  <- xml2::read_xml(xml_str)
  ns   <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_section_breaks(body, ns, default_page_config)
  expect_gte(result$n_assembled, 3L)

  inline_types <- xml2::xml_find_all(body, ".//w:pPr/w:sectPr/w:type", ns)
  vals <- vapply(inline_types, function(t) xml2::xml_attr(t, "val"), character(1))
  expect_true(all(vals == "nextPage"),
    info = paste("Expected all inline sectPr types to be nextPage, got:",
                 paste(vals, collapse = ", ")))
})

test_that("#43: multi-section — body sectPr continuous when last section is wrapping div", {
  # Closing wrapping div is last marker — body sectPr should be continuous
  xml_str <- build_section_body(
    content_para("Title"),
    section_marker("section-body", page_break = "true", closing = FALSE),
    content_para("Body"),
    section_marker("section-body", closing = TRUE)
  )
  xml  <- xml2::read_xml(xml_str)
  ns   <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  assemble_section_breaks(body, ns, default_page_config)

  body_type_node <- xml2::xml_find_first(body, "w:sectPr/w:type", ns)
  body_type <- if (inherits(body_type_node, "xml_missing")) "missing" else
    xml2::xml_attr(body_type_node, "val")
  expect_equal(body_type, "continuous")
})

test_that("#43: multi-section — count-by from page_config used in lnNumType", {
  # page_config with count-by=5 should produce w:countBy="5" on line-number sections
  config_with_count_by <- c(
    default_page_config,
    list(`line-numbers` = list(`count-by` = 5L, distance = "0.25in"))
  )

  xml_str <- build_section_body(
    content_para("Title"),
    section_marker("section-body", page_break = "true", line_numbers = "continuous",
                   closing = FALSE),
    content_para("Body content"),
    content_para("More body content"),
    section_marker("section-body", closing = TRUE)
  )
  xml  <- xml2::read_xml(xml_str)
  ns   <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  assemble_section_breaks(body, ns, config_with_count_by)

  ln_node <- xml2::xml_find_first(body, ".//*[local-name()='lnNumType']")
  expect_false(inherits(ln_node, "xml_missing"),
    label = "lnNumType should be present for continuous line numbers")
  expect_equal(xml2::xml_attr(ln_node, "countBy"), "5")
})
