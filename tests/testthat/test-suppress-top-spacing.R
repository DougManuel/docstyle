# Tests for suppress_first_paragraph_spacing() and helpers

# --- Helpers (reuse patterns from test-section-assembly.R) ---

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

content_para <- function(text, before = NULL) {
  if (!is.null(before)) {
    paste0('<w:p><w:pPr><w:spacing w:before="', before, '"/></w:pPr>',
           '<w:r><w:t>', text, '</w:t></w:r></w:p>')
  } else {
    paste0('<w:p><w:r><w:t>', text, '</w:t></w:r></w:p>')
  }
}

heading_para <- function(text, level = 2, before = "240") {
  paste0('<w:p><w:pPr><w:pStyle w:val="Heading', level, '"/>',
         '<w:spacing w:before="', before, '"/></w:pPr>',
         '<w:r><w:t>', text, '</w:t></w:r></w:p>')
}

empty_para <- function() {
  '<w:p><w:pPr/></w:p>'
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

ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

default_page_config <- list(
  size = "letter",
  orientation = "portrait",
  margins = list(top = "1in", bottom = "1in", left = "1in", right = "1in")
)


# --- set_paragraph_before_spacing() ---

test_that("set_paragraph_before_spacing() creates spacing element when absent", {
  xml <- xml2::read_xml(build_section_body(content_para("Hello")))
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  para <- xml2::xml_find_first(body, "w:p", ns = ns)

  result <- set_paragraph_before_spacing(para, "0", ns)

  expect_true(result)
  spacing <- xml2::xml_find_first(para, "w:pPr/w:spacing", ns)
  expect_false(inherits(spacing, "xml_missing"))
  expect_equal(xml2::xml_attr(spacing, "before"), "0")
})

test_that("set_paragraph_before_spacing() modifies existing spacing", {
  xml <- xml2::read_xml(build_section_body(heading_para("Title", before = "240")))
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  para <- xml2::xml_find_first(body, "w:p", ns = ns)

  result <- set_paragraph_before_spacing(para, "0", ns)

  expect_true(result)
  spacing <- xml2::xml_find_first(para, "w:pPr/w:spacing", ns)
  expect_equal(xml2::xml_attr(spacing, "before"), "0")
})

test_that("set_paragraph_before_spacing() returns FALSE when already at target", {
  xml <- xml2::read_xml(build_section_body(content_para("Hello", before = "0")))
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  para <- xml2::xml_find_first(body, "w:p", ns = ns)

  result <- set_paragraph_before_spacing(para, "0", ns)

  expect_false(result)
})


# --- find_first_content_paragraph() ---

test_that("find_first_content_paragraph() finds first paragraph with text", {
  xml <- xml2::read_xml(build_section_body(
    content_para("First paragraph")
  ))
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- find_first_content_paragraph(body, ns)

  expect_false(is.null(result))
  expect_equal(trimws(xml2::xml_text(result)), "First paragraph")
})

test_that("find_first_content_paragraph() skips empty paragraphs", {
  xml <- xml2::read_xml(build_section_body(
    empty_para(),
    empty_para(),
    content_para("Actual content")
  ))
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- find_first_content_paragraph(body, ns)

  expect_false(is.null(result))
  expect_equal(trimws(xml2::xml_text(result)), "Actual content")
})

test_that("find_first_content_paragraph() returns NULL when first content is after sectPr", {
  # Paragraph with sectPr before any content paragraph
  xml_str <- build_section_body(
    '<w:p><w:pPr><w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr></w:pPr></w:p>',
    content_para("After section break")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- find_first_content_paragraph(body, ns)

  expect_null(result)
})


# --- find_first_content_successor() ---

test_that("find_first_content_successor() finds next content paragraph", {
  xml <- xml2::read_xml(build_section_body(
    content_para("Before"),
    content_para("After")
  ))
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  first <- xml2::xml_find_first(body, "w:p", ns = ns)

  result <- find_first_content_successor(first, ns)

  expect_false(is.null(result))
  expect_equal(trimws(xml2::xml_text(result)), "After")
})

test_that("find_first_content_successor() skips empty paragraphs", {
  xml <- xml2::read_xml(build_section_body(
    content_para("Before"),
    empty_para(),
    empty_para(),
    heading_para("Section Heading")
  ))
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  first <- xml2::xml_find_first(body, "w:p", ns = ns)

  result <- find_first_content_successor(first, ns)

  expect_false(is.null(result))
  expect_equal(trimws(xml2::xml_text(result)), "Section Heading")
})

test_that("find_first_content_successor() returns NULL at end of document", {
  xml <- xml2::read_xml(build_section_body(content_para("Last")))
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  para <- xml2::xml_find_first(body, "w:p", ns = ns)

  result <- find_first_content_successor(para, ns)

  # The only following sibling is the body sectPr, not a w:p
  expect_null(result)
})


# --- suppress_first_paragraph_spacing() ---

test_that("global CSS suppress-top-spacing applies to document first paragraph", {
  xml <- xml2::read_xml(build_section_body(
    heading_para("Introduction", before = "240")
  ))
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  config <- default_page_config
  config$`suppress-top-spacing` <- TRUE

  n <- suppress_first_paragraph_spacing(body, ns, config, list())

  expect_equal(n, 1L)
  spacing <- xml2::xml_find_first(body, "w:p/w:pPr/w:spacing", ns)
  expect_equal(xml2::xml_attr(spacing, "before"), "0")
})

test_that("no suppression when suppress-top-spacing is not set", {
  xml <- xml2::read_xml(build_section_body(
    heading_para("Introduction", before = "240")
  ))
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  n <- suppress_first_paragraph_spacing(body, ns, default_page_config, list())

  expect_equal(n, 0L)
  spacing <- xml2::xml_find_first(body, "w:p/w:pPr/w:spacing", ns)
  expect_equal(xml2::xml_attr(spacing, "before"), "240")
})

test_that("named @page suppress applies via section_sequence", {
  # Build a document with a section marker, then assemble it
  xml <- xml2::read_xml(build_section_body(
    content_para("Front matter"),
    section_marker("section-body", page_break = "true"),
    heading_para("Body heading", before = "240")
  ))
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  config <- default_page_config
  config$named <- list(body = list(`suppress-top-spacing` = TRUE))

  # Assemble first to establish section boundaries
  result <- assemble_section_breaks(body, ns, config)

  n <- suppress_first_paragraph_spacing(body, ns, config, result$section_sequence)

  expect_equal(n, 1L)
  # The heading paragraph should have w:before="0"
  heading <- xml2::xml_find_first(body,
    ".//w:p[w:pPr/w:pStyle[@w:val='Heading2']]", ns)
  spacing <- xml2::xml_find_first(heading, "w:pPr/w:spacing", ns)
  expect_equal(xml2::xml_attr(spacing, "before"), "0")
})

test_that("div attribute suppress-top-spacing overrides CSS false", {
  xml <- xml2::read_xml(build_section_body(
    content_para("Front matter"),
    section_marker("section-body", page_break = "true",
                   attrs = list(`suppress-top-spacing` = "true")),
    heading_para("Body heading", before = "240")
  ))
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  # CSS does NOT have suppress-top-spacing
  result <- assemble_section_breaks(body, ns, default_page_config)

  n <- suppress_first_paragraph_spacing(body, ns, default_page_config,
                                         result$section_sequence)

  expect_equal(n, 1L)
})

test_that("div attribute suppress-top-spacing=false overrides CSS true", {
  xml <- xml2::read_xml(build_section_body(
    content_para("Front matter"),
    section_marker("section-body", page_break = "true",
                   attrs = list(`suppress-top-spacing` = "false")),
    heading_para("Body heading", before = "240")
  ))
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  config <- default_page_config
  config$named <- list(body = list(`suppress-top-spacing` = TRUE))

  result <- assemble_section_breaks(body, ns, config)

  n <- suppress_first_paragraph_spacing(body, ns, config, result$section_sequence)

  # The div says false, so heading should keep its spacing
  expect_equal(n, 0L)
  heading <- xml2::xml_find_first(body,
    ".//w:p[w:pPr/w:pStyle[@w:val='Heading2']]", ns)
  spacing <- xml2::xml_find_first(heading, "w:pPr/w:spacing", ns)
  expect_equal(xml2::xml_attr(spacing, "before"), "240")
})

test_that("div attribute applies to document first paragraph when no predecessor", {
  # This mirrors the SynCo pattern: section div is the first thing in the doc,
  # so the opening marker has no predecessor and sectpr_para is NULL.
  # The heading is the document's first content paragraph inside the div.
  xml <- xml2::read_xml(build_section_body(
    section_marker("section-body", page_break = "true",
                   attrs = list(`suppress-top-spacing` = "true")),
    heading_para("Introduction", before = "240"),
    content_para("Body content")
  ))
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_section_breaks(body, ns, default_page_config)

  n <- suppress_first_paragraph_spacing(body, ns, default_page_config,
                                         result$section_sequence)

  # The div attribute applies via the no-predecessor path
  expect_equal(n, 1L)
  heading <- xml2::xml_find_first(body,
    ".//w:p[w:pPr/w:pStyle[@w:val='Heading2']]", ns)
  spacing <- xml2::xml_find_first(heading, "w:pPr/w:spacing", ns)
  expect_equal(xml2::xml_attr(spacing, "before"), "0")
})

test_that("structural paragraphs are skipped when finding first content", {
  xml <- xml2::read_xml(build_section_body(
    content_para("Front matter"),
    section_marker("section-body", page_break = "true"),
    empty_para(),
    empty_para(),
    heading_para("Body heading", before = "240")
  ))
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  config <- default_page_config
  config$named <- list(body = list(`suppress-top-spacing` = TRUE))

  result <- assemble_section_breaks(body, ns, config)

  n <- suppress_first_paragraph_spacing(body, ns, config, result$section_sequence)

  expect_equal(n, 1L)
  heading <- xml2::xml_find_first(body,
    ".//w:p[w:pPr/w:pStyle[@w:val='Heading2']]", ns)
  spacing <- xml2::xml_find_first(heading, "w:pPr/w:spacing", ns)
  expect_equal(xml2::xml_attr(spacing, "before"), "0")
})
