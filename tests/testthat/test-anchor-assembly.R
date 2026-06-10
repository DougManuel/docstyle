# Tests for assemble_anchors()

# Helper: build minimal OOXML body with anchor markers
build_anchor_body <- function(...) {
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

# Helper: content table (for anchor assembly tests — detected as "table" content type)
content_table <- function(text) {
  paste0(
    '<w:tbl><w:tblPr><w:tblW w:w="5000" w:type="dxa"/></w:tblPr>',
    '<w:tblGrid><w:gridCol w:w="5000"/></w:tblGrid>',
    '<w:tr><w:tc><w:tcPr><w:tcW w:w="5000" w:type="dxa"/></w:tcPr>',
    '<w:p><w:r><w:t>', text, '</w:t></w:r></w:p></w:tc></w:tr></w:tbl>'
  )
}

# Helper: anchor marker (opening) — field code wrapped, matching Lua output
anchor_marker <- function(class, adjacent = "") {
  payload <- list(
    type = "anchor", version = 3L, class = class,
    vertical_anchor = "text", horizontal_anchor = "margin",
    position_y = "0", position_x = "0",
    float_width = "5000dxa",
    wrap_style = "square", wrap_side = "both",
    wrap_distance = "0 198dxa 0 198dxa"
  )
  json <- jsonlite::toJSON(payload, auto_unbox = TRUE)
  marker_text <- paste0("DOCSTYLE_ANCHOR::", class, "::", adjacent)
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

# Helper: anchor end marker
anchor_end_marker <- function(class) {
  marker_text <- paste0("DOCSTYLE_ANCHOR_END::", class)
  paste0(
    '<w:p><w:pPr><w:suppressLineNumbers/></w:pPr>',
    '<w:r><w:t>', marker_text, '</w:t></w:r>',
    '</w:p>'
  )
}

# Helper: legacy float marker (opening) for backward compat tests
legacy_float_marker <- function(class, adjacent = "") {
  payload <- list(
    type = "float", version = 2L, class = class,
    vertical_anchor = "text", horizontal_anchor = "margin",
    position_y = "0", position_x = "0",
    float_width = "5000dxa",
    wrap_style = "square", wrap_side = "both",
    wrap_distance = "0 198dxa 0 198dxa"
  )
  json <- jsonlite::toJSON(payload, auto_unbox = TRUE)
  marker_text <- paste0("DOCSTYLE_FLOAT::", class, "::", adjacent)
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

# Helper: legacy float end marker
legacy_float_end_marker <- function(class) {
  marker_text <- paste0("DOCSTYLE_FLOAT_END::", class)
  paste0(
    '<w:p><w:pPr><w:suppressLineNumbers/></w:pPr>',
    '<w:r><w:t>', marker_text, '</w:t></w:r>',
    '</w:p>'
  )
}

# Helper: content image paragraph (for group assembly tests)
content_image_para <- function(embed_id = "rId5") {
  paste0(
    '<w:p xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><w:drawing><wp:inline>',
    '<wp:extent cx="5943600" cy="3962400"/>',
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="img1.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="', embed_id, '"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="5943600" cy="3962400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>',
    '</pic:pic></a:graphicData></a:graphic>',
    '</wp:inline></w:drawing></w:r></w:p>'
  )
}

ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

test_anchor_config <- list(
  anchor_styles = list(
    `column-margin` = list(
      vertical_anchor = "text",
      horizontal_anchor = "margin",
      position_y = "0",
      position_x = "0",
      float_width = "5000dxa",
      wrap_style = "square",
      wrap_side = "both",
      wrap_distance = "0 198dxa 0 198dxa"
    )
  )
)


test_that("assemble_anchors() detects anchor markers", {
  xml_str <- build_anchor_body(
    content_para("Before anchor"),
    anchor_marker("column-margin"),
    content_table("Anchor content"),
    anchor_end_marker("column-margin"),
    content_para("After anchor")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_anchors(body, ns, test_anchor_config)

  expect_equal(result$n_assembled, 1L)
})

test_that("assemble_anchors() creates w:tbl with w:tblpPr", {
  xml_str <- build_anchor_body(
    content_para("Before anchor"),
    anchor_marker("column-margin"),
    content_table("Anchor content"),
    anchor_end_marker("column-margin"),
    content_para("After anchor")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  assemble_anchors(body, ns, test_anchor_config)

  # Should have a wrapper w:tbl with w:tblpPr
  tbl <- xml2::xml_find_first(body, ".//w:tbl[w:tblPr/w:tblpPr]", ns = ns)
  expect_false(inherits(tbl, "xml_missing"))

  tblpPr <- xml2::xml_find_first(tbl, "w:tblPr/w:tblpPr", ns = ns)
  expect_false(inherits(tblpPr, "xml_missing"))

  # Check positioning attributes
  expect_equal(xml2::xml_attr(tblpPr, "vertAnchor"), "text")
  expect_equal(xml2::xml_attr(tblpPr, "horzAnchor"), "margin")
})

test_that("assemble_anchors() wraps content in table cell", {
  xml_str <- build_anchor_body(
    content_para("Before anchor"),
    anchor_marker("column-margin"),
    content_table("Anchor table 1"),
    content_table("Anchor table 2"),
    anchor_end_marker("column-margin"),
    content_para("After anchor")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  assemble_anchors(body, ns, test_anchor_config)

  # Content tables should be inside the wrapper table cell
  # The wrapper table has w:tblpPr; content tables are nested inside it
  wrapper_tbl <- xml2::xml_find_first(body, ".//w:tbl[w:tblPr/w:tblpPr]", ns = ns)
  expect_false(inherits(wrapper_tbl, "xml_missing"))

  nested_tbls <- xml2::xml_find_all(wrapper_tbl, ".//w:tc/w:tbl", ns = ns)
  expect_equal(length(nested_tbls), 2)
})

test_that("assemble_anchors() removes marker paragraphs", {
  xml_str <- build_anchor_body(
    content_para("Before anchor"),
    anchor_marker("column-margin"),
    content_table("Anchor content"),
    anchor_end_marker("column-margin"),
    content_para("After anchor")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  assemble_anchors(body, ns, test_anchor_config)

  # Marker text should not appear in document
  all_text <- xml2::xml_text(xml2::xml_find_all(body, ".//w:t", ns = ns))
  marker_hits <- grep("DOCSTYLE_ANCHOR", all_text)
  expect_length(marker_hits, 0)
})

test_that("assemble_anchors() handles zero borders", {
  xml_str <- build_anchor_body(
    content_para("Before"),
    anchor_marker("column-margin"),
    content_table("Content"),
    anchor_end_marker("column-margin")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  assemble_anchors(body, ns, test_anchor_config)

  # Wrapper table should have no visible borders
  wrapper_tbl <- xml2::xml_find_first(body, ".//w:tbl[w:tblPr/w:tblpPr]", ns = ns)
  borders <- xml2::xml_find_first(wrapper_tbl, "w:tblPr/w:tblBorders", ns = ns)
  if (!inherits(borders, "xml_missing")) {
    top_val <- xml2::xml_attr(xml2::xml_find_first(borders, "w:top", ns = ns), "val")
    expect_equal(top_val, "none")
  }
})

test_that("assemble_anchors() returns zero when no markers", {
  xml_str <- build_anchor_body(content_para("Just content"))
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_anchors(body, ns, test_anchor_config)
  expect_equal(result$n_assembled, 0L)
})

test_that("assemble_anchors() handles multiple anchor ranges", {
  xml_str <- build_anchor_body(
    content_para("Before"),
    anchor_marker("column-margin"),
    content_table("Anchor 1 content"),
    anchor_end_marker("column-margin"),
    content_para("Between"),
    anchor_marker("column-margin"),
    content_table("Anchor 2 content"),
    anchor_end_marker("column-margin"),
    content_para("After")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_anchors(body, ns, test_anchor_config)

  expect_equal(result$n_assembled, 2L)

  # Both wrapper tables (with w:tblpPr) should exist
  tbls <- xml2::xml_find_all(body, ".//w:tbl[w:tblPr/w:tblpPr]", ns = ns)
  expect_equal(length(tbls), 2)
})

test_that("assemble_anchors() preserves surrounding content", {
  xml_str <- build_anchor_body(
    content_para("Before anchor"),
    anchor_marker("column-margin"),
    content_table("Anchor content"),
    anchor_end_marker("column-margin"),
    content_para("After anchor")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  assemble_anchors(body, ns, test_anchor_config)

  # "Before anchor" and "After anchor" should still exist as body-level paragraphs
  body_paras <- xml2::xml_find_all(body, "w:p", ns = ns)
  body_texts <- vapply(body_paras, function(p) {
    paste0(xml2::xml_text(xml2::xml_find_all(p, ".//w:t", ns = ns)), collapse = "")
  }, character(1))
  expect_true("Before anchor" %in% body_texts)
  expect_true("After anchor" %in% body_texts)
})

test_that("assemble_anchors() uses payload from instrText", {
  # Build a marker with custom position values in the payload
  payload <- list(
    type = "anchor", version = 3L, class = "custom-anchor",
    vertical_anchor = "page", horizontal_anchor = "page",
    position_y = "720", position_x = "360",
    float_width = "3000dxa",
    wrap_style = "square", wrap_side = "both",
    wrap_distance = "100dxa 200dxa 100dxa 200dxa"
  )
  json <- jsonlite::toJSON(payload, auto_unbox = TRUE)
  marker_text <- "DOCSTYLE_ANCHOR::custom-anchor::"
  custom_marker <- paste0(
    '<w:p><w:pPr><w:suppressLineNumbers/></w:pPr>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE ', json, ' </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:t>', marker_text, '</w:t></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r>',
    '</w:p>'
  )

  xml_str <- build_anchor_body(
    content_para("Before"),
    custom_marker,
    content_table("Custom anchor"),
    anchor_end_marker("custom-anchor"),
    content_para("After")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_anchors(body, ns, list())

  expect_equal(result$n_assembled, 1L)

  # Verify the wrapper table used payload values
  wrapper_tbl <- xml2::xml_find_first(body, ".//w:tbl[w:tblPr/w:tblpPr]", ns = ns)
  tblpPr <- xml2::xml_find_first(wrapper_tbl, "w:tblPr/w:tblpPr", ns = ns)
  expect_equal(xml2::xml_attr(tblpPr, "vertAnchor"), "page")
  expect_equal(xml2::xml_attr(tblpPr, "horzAnchor"), "page")
  expect_equal(xml2::xml_attr(tblpPr, "tblpY"), "720")
  expect_equal(xml2::xml_attr(tblpPr, "tblpX"), "360")

  # Check wrapper table width from payload
  tblW <- xml2::xml_find_first(wrapper_tbl, "w:tblPr/w:tblW", ns = ns)
  expect_equal(xml2::xml_attr(tblW, "w"), "3000")
})

test_that("assemble_anchors() handles legacy DOCSTYLE_FLOAT:: markers", {
  xml_str <- build_anchor_body(
    content_para("Before"),
    legacy_float_marker("column-margin"),
    content_table("Legacy float content"),
    legacy_float_end_marker("column-margin"),
    content_para("After")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_anchors(body, ns, test_anchor_config)

  expect_equal(result$n_assembled, 1L)

  # Verify wrapper table was created
  wrapper_tbl <- xml2::xml_find_first(body, ".//w:tbl[w:tblPr/w:tblpPr]", ns = ns)
  expect_false(inherits(wrapper_tbl, "xml_missing"))

  # Content table should be nested inside the wrapper table cell
  nested_tbl <- xml2::xml_find_first(wrapper_tbl, ".//w:tc/w:tbl", ns = ns)
  expect_false(inherits(nested_tbl, "xml_missing"))
})


# --- parse_wrap_distance shorthand tests ---

test_that("parse_wrap_distance handles 1-value shorthand", {
  result <- parse_wrap_distance("100dxa")
  expect_equal(result, list(top = 100L, right = 100L, bottom = 100L, left = 100L))
})

test_that("parse_wrap_distance handles 2-value shorthand", {
  result <- parse_wrap_distance("50dxa 200dxa")
  expect_equal(result, list(top = 50L, right = 200L, bottom = 50L, left = 200L))
})

test_that("parse_wrap_distance handles 3-value shorthand", {
  result <- parse_wrap_distance("10dxa 20dxa 30dxa")
  expect_equal(result, list(top = 10L, right = 20L, bottom = 30L, left = 20L))
})

test_that("parse_wrap_distance handles 4-value shorthand", {
  result <- parse_wrap_distance("10dxa 20dxa 30dxa 40dxa")
  expect_equal(result, list(top = 10L, right = 20L, bottom = 30L, left = 40L))
})

test_that("parse_wrap_distance returns defaults for NULL or empty", {
  expect_equal(parse_wrap_distance(NULL), list(top = 0L, right = 198L, bottom = 0L, left = 198L))
  expect_equal(parse_wrap_distance(""), list(top = 0L, right = 198L, bottom = 0L, left = 198L))
})

test_that("parse_wrap_distance warns on >4 values and returns defaults", {
  expect_warning(
    result <- parse_wrap_distance("1dxa 2dxa 3dxa 4dxa 5dxa"),
    "Expected 1-4 values"
  )
  expect_equal(result, list(top = 0L, right = 198L, bottom = 0L, left = 198L))
})


# --- Content detection tests ---

test_that("detect_anchor_content() classifies table-only content", {
  xml_str <- paste0(
    '<?xml version="1.0"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    '<w:tbl><w:tblPr><w:tblW w:w="5000" w:type="dxa"/></w:tblPr>',
    '<w:tblGrid><w:gridCol w:w="5000"/></w:tblGrid>',
    '<w:tr><w:tc><w:tcPr><w:tcW w:w="5000" w:type="dxa"/></w:tcPr>',
    '<w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>',
    '</w:body></w:document>'
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  children <- xml2::xml_children(body)

  expect_equal(detect_anchor_content(children, ns), "table")
})

test_that("detect_anchor_content() classifies image content", {
  xml_str <- paste0(
    '<?xml version="1.0"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:body>',
    '<w:p><w:r><w:drawing>',
    '<wp:inline distT="0" distB="0" distL="0" distR="0">',
    '<wp:extent cx="3175000" cy="2381250"/>',
    '<wp:docPr id="1" name="Picture 1"/>',
    '<wp:cNvGraphicFramePr/>',
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="img.png"/>',
    '<pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="3175000" cy="2381250"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>',
    '</pic:pic></a:graphicData></a:graphic>',
    '</wp:inline></w:drawing></w:r></w:p>',
    '</w:body></w:document>'
  )
  xml <- xml2::read_xml(xml_str)
  ns_full <- c(
    w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture"
  )
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns_full)
  children <- xml2::xml_children(body)

  expect_equal(detect_anchor_content(children, ns_full), "image")
})

test_that("detect_anchor_content() classifies text-only content", {
  xml_str <- paste0(
    '<?xml version="1.0"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    '<w:p><w:r><w:t>Just text</w:t></w:r></w:p>',
    '<w:p><w:r><w:t>More text</w:t></w:r></w:p>',
    '</w:body></w:document>'
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  children <- xml2::xml_children(body)

  expect_equal(detect_anchor_content(children, ns), "text")
})

test_that("detect_anchor_content() returns 'group' for image + text", {
  xml_str <- paste0(
    '<?xml version="1.0"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:body>',
    '<w:p><w:r><w:drawing>',
    '<wp:inline distT="0" distB="0" distL="0" distR="0">',
    '<wp:extent cx="914400" cy="685800"/>',
    '<wp:docPr id="1" name="Picture 1"/>',
    '<wp:cNvGraphicFramePr/>',
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="img1.png"/>',
    '<pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="685800"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>',
    '</pic:pic></a:graphicData></a:graphic>',
    '</wp:inline></w:drawing></w:r></w:p>',
    '<w:p><w:r><w:t>Figure 1. Caption text</w:t></w:r></w:p>',
    '</w:body></w:document>'
  )
  xml <- xml2::read_xml(xml_str)
  ns_full <- c(
    w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture"
  )
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns_full)
  children <- xml2::xml_children(body)

  expect_equal(detect_anchor_content(children, ns_full), "group")
})

test_that("detect_anchor_content() returns 'mixed' for table + text (not group)", {
  xml_str <- paste0(
    '<?xml version="1.0"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    '<w:tbl><w:tblPr><w:tblW w:w="5000" w:type="dxa"/></w:tblPr>',
    '<w:tblGrid><w:gridCol w:w="5000"/></w:tblGrid>',
    '<w:tr><w:tc><w:tcPr><w:tcW w:w="5000" w:type="dxa"/></w:tcPr>',
    '<w:p><w:r><w:t>Table cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>',
    '<w:p><w:r><w:t>Text paragraph</w:t></w:r></w:p>',
    '</w:body></w:document>'
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  children <- xml2::xml_children(body)

  expect_equal(detect_anchor_content(children, ns), "mixed")
})

test_that("detect_anchor_content() returns 'mixed' for table + image", {
  xml_str <- paste0(
    '<?xml version="1.0"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:body>',
    '<w:tbl><w:tblPr><w:tblW w:w="5000" w:type="dxa"/></w:tblPr>',
    '<w:tblGrid><w:gridCol w:w="5000"/></w:tblGrid>',
    '<w:tr><w:tc><w:tcPr><w:tcW w:w="5000" w:type="dxa"/></w:tcPr>',
    '<w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>',
    '<w:p><w:r><w:drawing>',
    '<wp:inline distT="0" distB="0" distL="0" distR="0">',
    '<wp:extent cx="914400" cy="685800"/>',
    '<wp:docPr id="1" name="Picture 1"/>',
    '<wp:cNvGraphicFramePr/>',
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="img"/>',
    '<pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="685800"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>',
    '</pic:pic></a:graphicData></a:graphic>',
    '</wp:inline></w:drawing></w:r></w:p>',
    '</w:body></w:document>'
  )
  xml <- xml2::read_xml(xml_str)
  ns_full <- c(
    w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture"
  )
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns_full)
  children <- xml2::xml_children(body)

  expect_equal(detect_anchor_content(children, ns_full), "mixed")
})


# --- Image anchor assembly tests ---

# Extended namespace for DrawingML
ns_drawingml <- c(
  w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
  wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
  a = "http://schemas.openxmlformats.org/drawingml/2006/main",
  pic = "http://schemas.openxmlformats.org/drawingml/2006/picture",
  r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
)

# Helper: build a paragraph containing wp:inline image
build_inline_image_para <- function(embed_id = "rId5", cx = "3175000", cy = "2381250") {
  paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><w:drawing>',
    '<wp:inline distT="0" distB="0" distL="0" distR="0">',
    '<wp:extent cx="', cx, '" cy="', cy, '"/>',
    '<wp:effectExtent l="0" t="0" r="0" b="0"/>',
    '<wp:docPr id="1" name="Picture 1"/>',
    '<wp:cNvGraphicFramePr/>',
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="img.png"/>',
    '<pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="', embed_id, '"/>',
    '<a:stretch><a:fillRect/></a:stretch></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="', cx, '" cy="', cy, '"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>',
    '</pic:pic></a:graphicData></a:graphic>',
    '</wp:inline></w:drawing></w:r></w:p>'
  )
}

test_that("build_image_anchor() produces wp:anchor with correct positioning", {
  para <- xml2::read_xml(build_inline_image_para())
  payload <- list(
    vertical_anchor = "text",
    horizontal_anchor = "margin",
    position_y = "0",
    position_x = "0",
    float_width = "250pt",
    z_layer = "front",
    wrap_style = "square",
    wrap_side = "both",
    wrap_distance = "0 198dxa 0 198dxa"
  )

  result <- build_image_anchor(para, payload, ns_drawingml, next_docpr_id = 100L)

  expect_true(result$success)

  # The paragraph should now contain wp:anchor instead of wp:inline
  anchor <- xml2::xml_find_first(para, ".//wp:anchor", ns = ns_drawingml)
  expect_false(inherits(anchor, "xml_missing"))

  inline <- xml2::xml_find_first(para, ".//wp:inline", ns = ns_drawingml)
  expect_true(inherits(inline, "xml_missing"))

  # Check positioning
  posH <- xml2::xml_find_first(anchor, "wp:positionH", ns = ns_drawingml)
  expect_equal(xml2::xml_attr(posH, "relativeFrom"), "margin")

  posV <- xml2::xml_find_first(anchor, "wp:positionV", ns = ns_drawingml)
  expect_equal(xml2::xml_attr(posV, "relativeFrom"), "paragraph")
})

test_that("build_image_anchor() sets behindDoc from z_layer", {
  para <- xml2::read_xml(build_inline_image_para())
  payload <- list(
    vertical_anchor = "page", horizontal_anchor = "page",
    position_y = "0", position_x = "0",
    z_layer = "behind",
    wrap_style = "none",
    wrap_distance = "0 0 0 0"
  )

  build_image_anchor(para, payload, ns_drawingml, next_docpr_id = 101L)

  anchor <- xml2::xml_find_first(para, ".//wp:anchor", ns = ns_drawingml)
  expect_equal(xml2::xml_attr(anchor, "behindDoc"), "1")
})

test_that("build_image_anchor() scales width and preserves aspect ratio", {
  # Original: 3175000 EMU wide x 2381250 EMU tall (250pt x 187.5pt = 4:3)
  para <- xml2::read_xml(build_inline_image_para(cx = "3175000", cy = "2381250"))
  payload <- list(
    vertical_anchor = "text", horizontal_anchor = "margin",
    position_y = "0", position_x = "0",
    float_width = "125pt",  # Half the original width
    z_layer = "front",
    wrap_style = "square",
    wrap_distance = "0 198dxa 0 198dxa"
  )

  build_image_anchor(para, payload, ns_drawingml, next_docpr_id = 102L)

  anchor <- xml2::xml_find_first(para, ".//wp:anchor", ns = ns_drawingml)
  extent <- xml2::xml_find_first(anchor, "wp:extent", ns = ns_drawingml)
  new_cx <- as.integer(xml2::xml_attr(extent, "cx"))
  new_cy <- as.integer(xml2::xml_attr(extent, "cy"))

  # 125pt = 1587500 EMU
  expect_equal(new_cx, 1587500L)
  # Height should scale proportionally: 1587500 * (2381250 / 3175000) = 1190625
  expect_equal(new_cy, 1190625L)
})

test_that("build_image_anchor() generates correct wrap element", {
  para <- xml2::read_xml(build_inline_image_para())
  payload <- list(
    vertical_anchor = "text", horizontal_anchor = "margin",
    position_y = "0", position_x = "0",
    z_layer = "front",
    wrap_style = "top-and-bottom",
    wrap_distance = "100dxa 0 100dxa 0"
  )

  build_image_anchor(para, payload, ns_drawingml, next_docpr_id = 103L)

  anchor <- xml2::xml_find_first(para, ".//wp:anchor", ns = ns_drawingml)
  wrap <- xml2::xml_find_first(anchor, "wp:wrapTopAndBottom", ns = ns_drawingml)
  expect_false(inherits(wrap, "xml_missing"))
})

# --- End-to-end image assembly test ---

# Helper: anchor marker for image with custom payload
anchor_image_marker <- function(class, payload_overrides = list()) {
  payload <- list(
    type = "anchor", version = 3L, class = class,
    vertical_anchor = "text", horizontal_anchor = "margin",
    position_y = "0", position_x = "0",
    float_width = "250pt",
    wrap_style = "square", wrap_side = "both",
    wrap_distance = "0 198dxa 0 198dxa",
    z_layer = "front"
  )
  for (nm in names(payload_overrides)) {
    payload[[nm]] <- payload_overrides[[nm]]
  }
  json <- jsonlite::toJSON(payload, auto_unbox = TRUE)
  marker_text <- paste0("DOCSTYLE_ANCHOR::", class, "::")
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

# Helper: inline image paragraph for body context (no standalone namespace decls)
inline_image_para <- function(embed_id = "rId5", cx = "3175000", cy = "2381250") {
  paste0(
    '<w:p><w:r><w:drawing>',
    '<wp:inline distT="0" distB="0" distL="0" distR="0">',
    '<wp:extent cx="', cx, '" cy="', cy, '"/>',
    '<wp:effectExtent l="0" t="0" r="0" b="0"/>',
    '<wp:docPr id="1" name="Picture 1"/>',
    '<wp:cNvGraphicFramePr/>',
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="img.png"/>',
    '<pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="', embed_id, '"/>',
    '<a:stretch><a:fillRect/></a:stretch></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="', cx, '" cy="', cy, '"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>',
    '</pic:pic></a:graphicData></a:graphic>',
    '</wp:inline></w:drawing></w:r></w:p>'
  )
}

# Helper: build body XML with DrawingML namespaces
build_image_anchor_body <- function(...) {
  paras <- paste0(list(...), collapse = "")
  paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:body>',
    paras,
    '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/>',
    '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" ',
    'w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>',
    '</w:body></w:document>'
  )
}

test_that("assemble_anchors() handles image content end-to-end", {
  xml_str <- build_image_anchor_body(
    content_para("Before image"),
    anchor_image_marker("float-right"),
    inline_image_para(),
    anchor_end_marker("float-right"),
    content_para("After image")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_anchors(body, ns, list())

  expect_equal(result$n_assembled, 1L)

  # wp:anchor should exist in output
  anchor <- xml2::xml_find_first(body, ".//wp:anchor", ns = ns_drawingml)
  expect_false(inherits(anchor, "xml_missing"))

  # wp:inline should be gone
  inline <- xml2::xml_find_first(body, ".//wp:inline", ns = ns_drawingml)
  expect_true(inherits(inline, "xml_missing"))

  # Marker paragraphs should be removed
  all_text <- xml2::xml_text(xml2::xml_find_all(body, ".//w:t", ns = ns))
  marker_hits <- grep("DOCSTYLE_ANCHOR", all_text)
  expect_length(marker_hits, 0)
})


# --- Text/mixed content via floating table tests ---

test_that("assemble_anchors() handles text content via floating table", {
  xml_str <- build_anchor_body(
    content_para("Before"),
    anchor_marker("column-margin"),
    content_para("Margin note text"),
    content_para("Second paragraph"),
    anchor_end_marker("column-margin"),
    content_para("After")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_anchors(body, ns, page_config = list(), verbose = FALSE)
  expect_equal(result$n_assembled, 1L)

  # Should have built a floating table with tblpPr
  tbl <- xml2::xml_find_first(body, ".//w:tbl", ns)
  expect_false(inherits(tbl, "xml_missing"))

  tblpPr <- xml2::xml_find_first(tbl, ".//w:tblpPr", ns)
  expect_false(inherits(tblpPr, "xml_missing"))

  # Content should be in the table cell
  tc_paras <- xml2::xml_find_all(tbl, ".//w:tc/w:p", ns)
  tc_texts <- sapply(tc_paras, function(p) {
    paste(xml2::xml_text(xml2::xml_find_all(p, ".//w:t", ns)), collapse = "")
  })
  expect_true("Margin note text" %in% tc_texts)
  expect_true("Second paragraph" %in% tc_texts)

  # Marker paragraphs should be removed
  all_texts <- sapply(xml2::xml_children(body), function(ch) {
    paste(xml2::xml_text(xml2::xml_find_all(ch, ".//w:t", ns)), collapse = "")
  })
  expect_false(any(grepl("DOCSTYLE_ANCHOR", all_texts)))
})

test_that("assemble_anchors() handles image+text as group (not mixed floating table)", {
  # Since detect_anchor_content classifies image+text as "group",
  # this should produce a wpg:wgp group anchor, not a floating table
  xml_str <- build_image_anchor_body(
    content_para("Before"),
    anchor_image_marker("column-margin"),
    inline_image_para(),
    content_para("Caption text"),
    anchor_end_marker("column-margin"),
    content_para("After")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_anchors(body, ns, page_config = list(), verbose = FALSE)
  expect_equal(result$n_assembled, 1L)

  # Should produce a wpg:wgp group element (image+text → group dispatch)
  ns_ext <- c(ns,
    wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"
  )
  wgp <- xml2::xml_find_first(body, ".//wpg:wgp", ns = ns_ext)
  expect_false(inherits(wgp, "xml_missing"))

  # Marker paragraphs should be removed
  all_texts <- sapply(xml2::xml_children(body), function(ch) {
    paste(xml2::xml_text(xml2::xml_find_all(ch, ".//w:t", ns)), collapse = "")
  })
  expect_false(any(grepl("DOCSTYLE_ANCHOR", all_texts)))
})

# --- Text box anchor assembly tests ---

test_that("build_text_box_anchor() creates wp:anchor with wps:txbx", {
  ns <- c(
    w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    a = "http://schemas.openxmlformats.org/drawingml/2006/main",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  )

  # Create content paragraphs
  content_xml <- paste0(
    '<w:body xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:p><w:r><w:t>First paragraph</w:t></w:r></w:p>',
    '<w:p><w:r><w:t>Second paragraph</w:t></w:r></w:p>',
    '</w:body>'
  )
  doc <- xml2::read_xml(content_xml)
  ns_w <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  content_paras <- xml2::xml_children(doc)

  payload <- list(
    vertical_anchor = "text",
    horizontal_anchor = "margin",
    position_y = "0",
    position_x = "0",
    float_width = "2in",
    wrap_style = "square",
    wrap_side = "both",
    wrap_distance = "0 198dxa 0 198dxa",
    z_layer = "front"
  )

  result <- build_text_box_anchor(content_paras, payload, ns, next_docpr_id = 5L)
  expect_true(result$success)
  expect_equal(result$docpr_id, 5L)

  # Result should be a w:p containing w:drawing > wp:anchor
  result_para <- result$para
  expect_false(is.null(result_para))

  anchor <- xml2::xml_find_first(result_para, ".//wp:anchor", ns)
  expect_false(inherits(anchor, "xml_missing"))

  # Should contain wps:txbx with w:txbxContent
  txbx <- xml2::xml_find_first(anchor, ".//wps:txbx", ns)
  expect_false(inherits(txbx, "xml_missing"))

  txbx_content <- xml2::xml_find_first(txbx, "w:txbxContent", ns)
  expect_false(inherits(txbx_content, "xml_missing"))

  # Content paragraphs should be inside
  inner_paras <- xml2::xml_find_all(txbx_content, "w:p", ns)
  expect_gte(length(inner_paras), 2L)

  # Check docPr ID
  docpr <- xml2::xml_find_first(anchor, ".//wp:docPr", ns)
  expect_equal(xml2::xml_attr(docpr, "id"), "5")

  # Check behindDoc
  expect_equal(xml2::xml_attr(anchor, "behindDoc"), "0")
})

test_that("build_text_box_anchor() applies z_layer behind", {
  ns <- c(
    w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    a = "http://schemas.openxmlformats.org/drawingml/2006/main",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  )

  content_xml <- paste0(
    '<w:body xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:p><w:r><w:t>Content</w:t></w:r></w:p>',
    '</w:body>'
  )
  doc <- xml2::read_xml(content_xml)
  content_paras <- xml2::xml_children(doc)

  payload <- list(
    vertical_anchor = "text",
    horizontal_anchor = "margin",
    float_width = "3000dxa",
    wrap_distance = "0 0 0 0",
    z_layer = "behind"
  )

  result <- build_text_box_anchor(content_paras, payload, ns, next_docpr_id = 1L)
  expect_true(result$success)

  anchor <- xml2::xml_find_first(result$para, ".//wp:anchor", ns)
  expect_equal(xml2::xml_attr(anchor, "behindDoc"), "1")
})

test_that("build_text_box_anchor() returns failure for empty content", {
  ns <- c(
    w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    a = "http://schemas.openxmlformats.org/drawingml/2006/main",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  )

  result <- build_text_box_anchor(list(), list(float_width = "2in"), ns, next_docpr_id = 1L)
  expect_false(result$success)
})


# --- find_bookmark_paragraph tests ---

test_that("find_bookmark_paragraph() finds bookmark by ID", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  body_xml <- paste0(
    '<w:body xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:p><w:bookmarkStart w:id="1" w:name="methods"/><w:r><w:t>Methods heading</w:t></w:r><w:bookmarkEnd w:id="1"/></w:p>',
    '<w:p><w:r><w:t>Methods content</w:t></w:r></w:p>',
    '</w:body>'
  )
  doc <- xml2::read_xml(body_xml)
  body <- xml2::xml_find_first(doc, "//w:body", ns)

  result <- find_bookmark_paragraph(body, "methods", ns)
  expect_false(is.null(result))
  text <- paste(xml2::xml_text(xml2::xml_find_all(result, ".//w:t", ns)), collapse = "")
  expect_equal(text, "Methods heading")
})

test_that("find_bookmark_paragraph() finds _docstyle_ prefixed bookmarks", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  body_xml <- paste0(
    '<w:body xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:p><w:bookmarkStart w:id="1" w:name="_docstyle_results"/><w:r><w:t>Results</w:t></w:r><w:bookmarkEnd w:id="1"/></w:p>',
    '</w:body>'
  )
  doc <- xml2::read_xml(body_xml)
  body <- xml2::xml_find_first(doc, "//w:body", ns)

  result <- find_bookmark_paragraph(body, "results", ns)
  expect_false(is.null(result))
})

test_that("find_bookmark_paragraph() strips # prefix", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  body_xml <- paste0(
    '<w:body xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:p><w:bookmarkStart w:id="1" w:name="intro"/><w:r><w:t>Intro</w:t></w:r><w:bookmarkEnd w:id="1"/></w:p>',
    '</w:body>'
  )
  doc <- xml2::read_xml(body_xml)
  body <- xml2::xml_find_first(doc, "//w:body", ns)

  result <- find_bookmark_paragraph(body, "#intro", ns)
  expect_false(is.null(result))
})

test_that("find_bookmark_paragraph() returns NULL for missing bookmark", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  body_xml <- paste0(
    '<w:body xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:p><w:r><w:t>No bookmarks</w:t></w:r></w:p>',
    '</w:body>'
  )
  doc <- xml2::read_xml(body_xml)
  body <- xml2::xml_find_first(doc, "//w:body", ns)

  result <- find_bookmark_paragraph(body, "nonexistent", ns)
  expect_null(result)
})


# --- Adjacency relocation tests ---

test_that("assemble_anchors() relocates floating table to adjacent bookmark", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  body_xml <- paste0(
    '<w:body xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    # Target paragraph with bookmark
    '<w:p><w:bookmarkStart w:id="1" w:name="methods"/><w:r><w:t>Methods</w:t></w:r><w:bookmarkEnd w:id="1"/></w:p>',
    '<w:p><w:r><w:t>Methods content</w:t></w:r></w:p>',
    # Anchor div far from target, with adjacent attribute
    '<w:p><w:r><w:t>Results section</w:t></w:r></w:p>',
    '<w:p><w:pPr><w:suppressLineNumbers/></w:pPr>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE {"type":"anchor","class":"column-margin","adjacent":"#methods","vertical_anchor":"text","horizontal_anchor":"margin","position_y":"0","position_x":"0","float_width":"3000dxa","wrap_distance":"0 198dxa 0 198dxa"} </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:t>DOCSTYLE_ANCHOR::column-margin::#methods</w:t></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>',
    '<w:p><w:r><w:t>Margin note for methods</w:t></w:r></w:p>',
    '<w:p><w:r><w:t>DOCSTYLE_ANCHOR_END::column-margin</w:t></w:r></w:p>',
    '</w:body>'
  )

  doc <- xml2::read_xml(body_xml)
  body <- xml2::xml_find_first(doc, "//w:body", ns)

  result <- assemble_anchors(body, ns, page_config = list(), verbose = FALSE)
  expect_equal(result$n_assembled, 1L)

  # The floating table should be positioned before the "Methods" paragraph
  children <- xml2::xml_children(body)
  child_names <- sapply(children, xml2::xml_name)

  # Find body-level tables (direct children)
  tbl_indices <- which(child_names == "tbl")
  # There should be exactly one body-level floating table
  expect_gte(length(tbl_indices), 1L)

  # Find the "Methods" paragraph (contains bookmark)
  methods_idx <- NULL
  for (i in seq_along(children)) {
    bm <- xml2::xml_find_first(children[[i]], ".//w:bookmarkStart[@w:name='methods']", ns)
    if (!inherits(bm, "xml_missing")) {
      methods_idx <- i
      break
    }
  }

  # The floating table should be immediately before the methods paragraph
  expect_true(any(tbl_indices == methods_idx - 1L))
})

test_that("assemble_anchors() falls back to source position on missing bookmark", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  body_xml <- paste0(
    '<w:body xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:p><w:r><w:t>Before</w:t></w:r></w:p>',
    '<w:p><w:pPr><w:suppressLineNumbers/></w:pPr>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE {"type":"anchor","class":"column-margin","adjacent":"#nonexistent","vertical_anchor":"text","horizontal_anchor":"margin","position_y":"0","position_x":"0","float_width":"3000dxa","wrap_distance":"0 198dxa 0 198dxa"} </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:t>DOCSTYLE_ANCHOR::column-margin::#nonexistent</w:t></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>',
    '<w:p><w:r><w:t>Margin text</w:t></w:r></w:p>',
    '<w:p><w:r><w:t>DOCSTYLE_ANCHOR_END::column-margin</w:t></w:r></w:p>',
    '<w:p><w:r><w:t>After</w:t></w:r></w:p>',
    '</w:body>'
  )

  doc <- xml2::read_xml(body_xml)
  body <- xml2::xml_find_first(doc, "//w:body", ns)

  # Should warn but still assemble
  expect_warning(
    result <- assemble_anchors(body, ns, page_config = list(), verbose = FALSE),
    "Bookmark.*nonexistent.*not found"
  )
  expect_equal(result$n_assembled, 1L)
})


test_that("assemble_anchors() uses text box when content_mode is textbox", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  body_xml <- paste0(
    '<w:body xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:p><w:r><w:t>Before</w:t></w:r></w:p>',
    '<w:p><w:pPr><w:suppressLineNumbers/></w:pPr>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE {"type":"anchor","class":"sidebar","content_mode":"textbox","vertical_anchor":"text","horizontal_anchor":"margin","position_y":"0","position_x":"0","float_width":"2in","wrap_distance":"0 198dxa 0 198dxa"} </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:t>DOCSTYLE_ANCHOR::sidebar::</w:t></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>',
    '<w:p><w:r><w:t>Sidebar text</w:t></w:r></w:p>',
    '<w:p><w:r><w:t>DOCSTYLE_ANCHOR_END::sidebar</w:t></w:r></w:p>',
    '<w:p><w:r><w:t>After</w:t></w:r></w:p>',
    '</w:body>'
  )

  doc <- xml2::read_xml(body_xml)
  body <- xml2::xml_find_first(doc, "//w:body", ns)

  result <- assemble_anchors(body, ns, page_config = list(), verbose = FALSE)
  expect_equal(result$n_assembled, 1L)

  # Should NOT have a floating table (tblpPr)
  tblpPr <- xml2::xml_find_first(body, ".//w:tblpPr", ns)
  expect_true(inherits(tblpPr, "xml_missing"))

  # Should have wp:anchor with wps:txbx
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
  )
  anchor <- xml2::xml_find_first(body, ".//wp:anchor", ns_ext)
  expect_false(inherits(anchor, "xml_missing"))

  txbx <- xml2::xml_find_first(anchor, ".//wps:txbx", ns_ext)
  expect_false(inherits(txbx, "xml_missing"))
})

test_that("build_group_anchor() produces wpg:wgp with pic:pic and wps:wsp", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    a = "http://schemas.openxmlformats.org/drawingml/2006/main",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup",
    r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  )

  wrapper_xml <- paste0(
    '<wrapper xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:p><w:r><w:drawing><wp:inline>',
    '<wp:extent cx="5943600" cy="3962400"/>',
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="img1.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="5943600" cy="3962400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>',
    '</pic:pic></a:graphicData></a:graphic>',
    '</wp:inline></w:drawing></w:r></w:p>',
    '<w:p><w:r><w:t>Figure 1. Caption text</w:t></w:r></w:p>',
    '</wrapper>'
  )
  content_nodes <- xml2::xml_find_all(xml2::read_xml(wrapper_xml), "./*")

  payload <- list(
    vertical_anchor = "text",
    horizontal_anchor = "margin",
    position_y = "0",
    position_x = "0",
    float_width = "9348dxa",
    wrap_style = "square",
    wrap_side = "both",
    wrap_distance = "0 198dxa 0 198dxa"
  )

  result <- build_group_anchor(content_nodes, payload, ns_ext, next_docpr_id = 10L)

  expect_true(result$success)
  expect_equal(result$docpr_id, 10L)

  doc <- result$para
  wgp <- xml2::xml_find_first(doc, ".//wpg:wgp", ns = ns_ext)
  expect_false(inherits(wgp, "xml_missing"))

  pic <- xml2::xml_find_first(wgp, ".//pic:pic", ns = ns_ext)
  expect_false(inherits(pic, "xml_missing"))

  wsp <- xml2::xml_find_first(wgp, ".//wps:wsp", ns = ns_ext)
  expect_false(inherits(wsp, "xml_missing"))

  txbx <- xml2::xml_find_first(wsp, ".//wps:txbx", ns = ns_ext)
  expect_false(inherits(txbx, "xml_missing"))

  blip <- xml2::xml_find_first(pic, ".//a:blip", ns = ns_ext)
  expect_false(inherits(blip, "xml_missing"))
})

test_that("build_group_anchor() uses caption_y and image_height from payload", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    a = "http://schemas.openxmlformats.org/drawingml/2006/main",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup",
    r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  )

  wrapper_xml <- paste0(
    '<wrapper xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:p><w:r><w:drawing><wp:inline>',
    '<wp:extent cx="5943600" cy="3962400"/>',
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="img1.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="5943600" cy="3962400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>',
    '</pic:pic></a:graphicData></a:graphic>',
    '</wp:inline></w:drawing></w:r></w:p>',
    '<w:p><w:r><w:t>Caption</w:t></w:r></w:p>',
    '</wrapper>'
  )
  content_nodes <- xml2::xml_find_all(xml2::read_xml(wrapper_xml), "./*")

  # caption_y = 4978dxa -> 4978 * 635 = 3161030 EMU
  # image_height = 3200dxa -> 3200 * 635 = 2032000 EMU
  payload <- list(
    float_width = "9348dxa",
    caption_y = "4978dxa",
    image_height = "3200dxa",
    wrap_distance = "0 198dxa 0 198dxa"
  )

  result <- build_group_anchor(content_nodes, payload, ns_ext, next_docpr_id = 5L)
  expect_true(result$success)

  # Check caption wps:wsp offset y matches caption_y in EMU
  wsp_off <- xml2::xml_find_first(result$para,
    ".//wps:wsp/wps:spPr/a:xfrm/a:off", ns = ns_ext)
  expect_false(inherits(wsp_off, "xml_missing"))
  expect_equal(xml2::xml_attr(wsp_off, "y"), "3161030")
})

test_that("build_group_anchor() computes defaults when caption_y absent", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    a = "http://schemas.openxmlformats.org/drawingml/2006/main",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup",
    r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  )

  wrapper_xml <- paste0(
    '<wrapper xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:p><w:r><w:drawing><wp:inline>',
    '<wp:extent cx="5943600" cy="3962400"/>',
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="img1.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="5943600" cy="3962400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>',
    '</pic:pic></a:graphicData></a:graphic>',
    '</wp:inline></w:drawing></w:r></w:p>',
    '<w:p><w:r><w:t>Caption</w:t></w:r></w:p>',
    '</wrapper>'
  )
  content_nodes <- xml2::xml_find_all(xml2::read_xml(wrapper_xml), "./*")

  # float_width = 9348dxa -> 9348 * 635 = 5935980 EMU
  # Image original: cx=5943600 cy=3962400
  # Scaled height: 5935980 * (3962400/5943600) = 3957326 (rounded)
  # caption_y = 3957326 + 91440 = 4048766
  payload <- list(
    float_width = "9348dxa",
    wrap_distance = "0 198dxa 0 198dxa"
  )

  result <- build_group_anchor(content_nodes, payload, ns_ext, next_docpr_id = 1L)
  expect_true(result$success)

  # Caption y should be image_height + 91440 (0.1 inch gap)
  wsp_off <- xml2::xml_find_first(result$para,
    ".//wps:wsp/wps:spPr/a:xfrm/a:off", ns = ns_ext)
  caption_y <- as.numeric(xml2::xml_attr(wsp_off, "y"))
  # Verify it's in the right ballpark: scaled_height + 91440
  # 9348 * 635 = 5935980 EMU width
  # 5935980 * (3962400/5943600) = 3957319.67... -> round -> 3957320
  # 3957320 + 91440 = 4048760
  expect_equal(caption_y, 4048760)
})

test_that("build_group_anchor() succeeds with image only (empty caption)", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    a = "http://schemas.openxmlformats.org/drawingml/2006/main",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup",
    r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  )

  wrapper_xml <- paste0(
    '<wrapper xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:p><w:r><w:drawing><wp:inline>',
    '<wp:extent cx="5943600" cy="3962400"/>',
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="img1.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="5943600" cy="3962400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>',
    '</pic:pic></a:graphicData></a:graphic>',
    '</wp:inline></w:drawing></w:r></w:p>',
    '</wrapper>'
  )
  content_nodes <- xml2::xml_find_all(xml2::read_xml(wrapper_xml), "./*")

  payload <- list(float_width = "5000dxa", wrap_distance = "0 198dxa 0 198dxa")
  result <- build_group_anchor(content_nodes, payload, ns_ext, next_docpr_id = 1L)

  expect_true(result$success)

  wsp <- xml2::xml_find_first(result$para, ".//wps:wsp", ns = ns_ext)
  expect_false(inherits(wsp, "xml_missing"))
})

test_that("build_group_anchor() fails with no image", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    a = "http://schemas.openxmlformats.org/drawingml/2006/main",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup",
    r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  )

  wrapper_xml <- paste0(
    '<wrapper xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:p><w:r><w:t>Just text, no image</w:t></w:r></w:p>',
    '</wrapper>'
  )
  content_nodes <- xml2::xml_find_all(xml2::read_xml(wrapper_xml), "./*")

  payload <- list(float_width = "5000dxa", wrap_distance = "0 198dxa 0 198dxa")
  result <- build_group_anchor(content_nodes, payload, ns_ext, next_docpr_id = 1L)

  expect_false(result$success)
  expect_equal(result$reason, "no image found in group content")
})

test_that("assemble_anchors() dispatches group content to build_group_anchor", {
  xml_str <- build_anchor_body(
    content_para("Before"),
    anchor_marker("column-margin"),
    content_image_para(),
    content_para("Figure 1. Caption text"),
    anchor_end_marker("column-margin"),
    content_para("After")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_anchors(body, ns, test_anchor_config)

  expect_equal(result$n_assembled, 1L)

  # Should produce a wpg:wgp element
  ns_ext <- c(ns,
    wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"
  )
  wgp <- xml2::xml_find_first(body, ".//wpg:wgp", ns = ns_ext)
  expect_false(inherits(wgp, "xml_missing"))

  # Markers should be removed
  children <- xml2::xml_children(body)
  all_text <- vapply(children, function(c) {
    t <- xml2::xml_find_all(c, ".//w:t", ns = ns)
    paste(xml2::xml_text(t), collapse = "")
  }, character(1))
  expect_false(any(grepl("DOCSTYLE_ANCHOR", all_text)))
})

test_that("assemble_anchors() relocates group via adjacency (direct node reference)", {
  bookmark_para <- paste0(
    '<w:p><w:bookmarkStart w:id="0" w:name="target_para"/>',
    '<w:r><w:t>Target paragraph</w:t></w:r>',
    '<w:bookmarkEnd w:id="0"/></w:p>'
  )

  payload <- list(
    type = "anchor", version = 3L, class = "column-margin",
    vertical_anchor = "text", horizontal_anchor = "margin",
    position_y = "0", position_x = "0",
    float_width = "5000dxa",
    wrap_style = "square", wrap_side = "both",
    wrap_distance = "0 198dxa 0 198dxa",
    adjacent = "#target_para"
  )
  json <- jsonlite::toJSON(payload, auto_unbox = TRUE)
  marker_text <- "DOCSTYLE_ANCHOR::column-margin::#target_para"
  adj_marker <- paste0(
    '<w:p><w:pPr><w:suppressLineNumbers/></w:pPr>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE ', json, ' </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:t>', marker_text, '</w:t></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r>',
    '</w:p>'
  )

  xml_str <- build_anchor_body(
    adj_marker,
    content_image_para(),
    content_para("Figure 1. Caption"),
    anchor_end_marker("column-margin"),
    content_para("Intervening paragraph"),
    bookmark_para
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_anchors(body, ns, test_anchor_config)
  expect_equal(result$n_assembled, 1L)

  # The group should be relocated before the target paragraph
  children <- xml2::xml_children(body)
  child_texts <- vapply(children, function(c) {
    t <- xml2::xml_find_all(c, ".//w:t", ns = ns)
    paste(xml2::xml_text(t), collapse = "")
  }, character(1))

  ns_ext <- c(ns,
    wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"
  )
  group_idx <- which(vapply(children, function(c) {
    length(xml2::xml_find_all(c, ".//wpg:wgp", ns = ns_ext)) > 0
  }, logical(1)))
  target_idx <- which(grepl("Target paragraph", child_texts))

  expect_true(length(group_idx) == 1)
  expect_true(length(target_idx) == 1)
  expect_true(group_idx < target_idx)
})

test_that("assemble_anchors() handles empty content range (markers removed)", {
  # Adjacent start+end markers with no content between them
  xml_str <- build_anchor_body(
    content_para("Before"),
    anchor_marker("column-margin"),
    anchor_end_marker("column-margin"),
    content_para("After")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  expect_warning(
    result <- assemble_anchors(body, ns, test_anchor_config),
    "has no content paragraphs"
  )

  # Markers must be removed (floating table replaces them)
  children <- xml2::xml_children(body)
  all_text <- vapply(children, function(c) {
    t <- xml2::xml_find_all(c, ".//w:t", ns = ns)
    paste(xml2::xml_text(t), collapse = "")
  }, character(1))
  expect_false(any(grepl("DOCSTYLE_ANCHOR", all_text)))

  # Surrounding content preserved
  expect_true(any(grepl("Before", all_text)))
  expect_true(any(grepl("After", all_text)))
})

test_that("build_group_anchor() rescales pic:pic dimensions to group coordinate space", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    a = "http://schemas.openxmlformats.org/drawingml/2006/main",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup",
    r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  )

  # Image with original dimensions 3048000x2286000 (3.2"x2.4")
  wrapper_xml <- paste0(
    '<wrapper xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:p><w:r><w:drawing><wp:inline>',
    '<wp:extent cx="3048000" cy="2286000"/>',
    '<wp:docPr id="1" name="Picture 1"/>',
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="img.jpg"/>',
    '<pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/><a:stretch/></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="3048000" cy="2286000"/></a:xfrm>',
    '</pic:spPr></pic:pic></a:graphicData></a:graphic>',
    '</wp:inline></w:drawing></w:r></w:p>',
    '</wrapper>'
  )
  content_nodes <- xml2::xml_find_all(xml2::read_xml(wrapper_xml), "./*")

  # Group width = 5000 DXA = 3175000 EMU
  payload <- list(float_width = "5000dxa", wrap_distance = "0 198dxa 0 198dxa")
  result <- build_group_anchor(content_nodes, payload, ns_ext, next_docpr_id = 1L)

  expect_true(result$success)

  # The pic:pic inside the group should have rescaled dimensions
  pic_ext <- xml2::xml_find_first(result$para, ".//pic:spPr/a:xfrm/a:ext", ns = ns_ext)
  expect_false(inherits(pic_ext, "xml_missing"))

  pic_cx <- as.numeric(xml2::xml_attr(pic_ext, "cx"))
  pic_cy <- as.numeric(xml2::xml_attr(pic_ext, "cy"))

  # Should be group width (3175000), not original (3048000)
  expect_equal(pic_cx, 3175000)
  # Height should be scaled proportionally: 3175000 * (2286000/3048000)
  expected_cy <- as.integer(round(3175000 * (2286000 / 3048000)))
  expect_equal(pic_cy, expected_cy)
})


# --- Tests for is_anchored_image() ---

test_that("is_anchored_image() returns TRUE for paragraph with wp:anchor containing pic:pic", {
  xml_str <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><w:drawing><wp:anchor distT="0" distB="0" distL="0" distR="0"',
    ' simplePos="0" relativeHeight="1" behindDoc="0" locked="0" layoutInCell="1" allowOverlap="1">',
    '<wp:simplePos x="0" y="0"/>',
    '<wp:positionH relativeFrom="margin"><wp:posOffset>0</wp:posOffset></wp:positionH>',
    '<wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>',
    '<wp:extent cx="914400" cy="914400"/>',
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="img.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/></pic:blipFill>',
    '<pic:spPr/></pic:pic></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing></w:r></w:p>'
  )
  para <- xml2::read_xml(xml_str)
  expect_true(is_anchored_image(para, ns))
})


# --- Tests for is_floating_table() ---

test_that("is_floating_table() returns TRUE for table with w:tblpPr", {
  xml_str <- paste0(
    '<w:tbl xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:tblPr>',
    '<w:tblpPr w:vertAnchor="text" w:horzAnchor="margin" w:tblpY="200" w:tblpX="100"/>',
    '<w:tblW w:w="5000" w:type="dxa"/>',
    '</w:tblPr>',
    '<w:tblGrid><w:gridCol w:w="5000"/></w:tblGrid>',
    '<w:tr><w:tc><w:p/></w:tc></w:tr>',
    '</w:tbl>'
  )
  tbl <- xml2::read_xml(xml_str)
  expect_true(is_floating_table(tbl, ns))
})

test_that("is_floating_table() returns FALSE for table without w:tblpPr", {
  xml_str <- paste0(
    '<w:tbl xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:tblPr><w:tblW w:w="5000" w:type="dxa"/></w:tblPr>',
    '<w:tblGrid><w:gridCol w:w="5000"/></w:tblGrid>',
    '<w:tr><w:tc><w:p/></w:tc></w:tr>',
    '</w:tbl>'
  )
  tbl <- xml2::read_xml(xml_str)
  expect_false(is_floating_table(tbl, ns))
})


# --- Tests for extract_float_properties() ---

test_that("extract_float_properties() extracts all tblpPr attributes", {
  xml_str <- paste0(
    '<w:tbl xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:tblPr>',
    '<w:tblpPr w:vertAnchor="page" w:horzAnchor="margin"',
    ' w:tblpY="200" w:tblpX="100"',
    ' w:leftFromText="50" w:rightFromText="60"',
    ' w:topFromText="70" w:bottomFromText="80"/>',
    '<w:tblW w:w="5000" w:type="dxa"/>',
    '</w:tblPr>',
    '<w:tblGrid><w:gridCol w:w="5000"/></w:tblGrid>',
    '<w:tr><w:tc><w:p/></w:tc></w:tr>',
    '</w:tbl>'
  )
  tbl <- xml2::read_xml(xml_str)
  props <- extract_float_properties(tbl, ns)

  expect_equal(props$vertical_anchor, "page")
  expect_equal(props$horizontal_anchor, "margin")
  expect_equal(props$position_y, "200")
  expect_equal(props$position_x, "100")
  expect_equal(props$float_width, "5000")
  expect_equal(props$left_from_text, "50")
  expect_equal(props$right_from_text, "60")
  expect_equal(props$top_from_text, "70")
  expect_equal(props$bottom_from_text, "80")
})

test_that("extract_float_properties() returns defaults for missing attributes", {
  xml_str <- paste0(
    '<w:tbl xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:tblPr>',
    '<w:tblpPr/>',
    '</w:tblPr>',
    '<w:tr><w:tc><w:p/></w:tc></w:tr>',
    '</w:tbl>'
  )
  tbl <- xml2::read_xml(xml_str)
  props <- extract_float_properties(tbl, ns)

  # Missing attributes should get defaults, not NA
  expect_equal(props$vertical_anchor, "text")
  expect_equal(props$horizontal_anchor, "margin")
  expect_equal(props$position_y, "0")
  expect_equal(props$position_x, "0")
  expect_equal(props$left_from_text, "0")
  expect_equal(props$right_from_text, "0")
  expect_equal(props$top_from_text, "0")
  expect_equal(props$bottom_from_text, "0")
})

test_that("extract_float_properties() returns NULL for non-floating table", {
  xml_str <- paste0(
    '<w:tbl xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:tblPr><w:tblW w:w="5000" w:type="dxa"/></w:tblPr>',
    '<w:tr><w:tc><w:p/></w:tc></w:tr>',
    '</w:tbl>'
  )
  tbl <- xml2::read_xml(xml_str)
  expect_null(extract_float_properties(tbl, ns))
})


# --- Tests for extract_anchor_image_properties() ---

test_that("extract_anchor_image_properties() extracts positioning from wp:anchor", {
  xml_str <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">',
    '<w:r><w:drawing><wp:anchor distT="0" distB="0" distL="114300" distR="114300"',
    ' simplePos="0" relativeHeight="1" behindDoc="0" locked="0" layoutInCell="1" allowOverlap="1">',
    '<wp:simplePos x="0" y="0"/>',
    '<wp:positionH relativeFrom="margin"><wp:posOffset>635000</wp:posOffset></wp:positionH>',
    '<wp:positionV relativeFrom="paragraph"><wp:posOffset>127000</wp:posOffset></wp:positionV>',
    '<wp:extent cx="1828800" cy="914400"/>',
    '<wp:wrapSquare wrapText="bothSides"/>',
    '</wp:anchor></w:drawing></w:r></w:p>'
  )
  para <- xml2::read_xml(xml_str)
  props <- extract_anchor_image_properties(para, ns)

  expect_false(is.null(props))
  expect_equal(props$horizontal_anchor, "margin")
  expect_equal(props$vertical_anchor, "text")  # "paragraph" maps to "text"
  # 635000 EMU / 635 = 1000 DXA
  expect_equal(props$position_x, "1000")
  # 127000 EMU / 635 = 200 DXA
  expect_equal(props$position_y, "200")
  # 1828800 EMU / 635 = 2880 DXA
  expect_equal(props$float_width, "2880")
})

test_that("extract_anchor_image_properties() returns NULL for non-anchored paragraph", {
  xml_str <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:r><w:t>Regular paragraph</w:t></w:r></w:p>'
  )
  para <- xml2::read_xml(xml_str)
  expect_null(extract_anchor_image_properties(para, ns))
})


# --- Test for build_image_anchor() NA dimension guard ---

test_that("build_image_anchor() returns failure for missing extent attributes", {
  # wp:inline with no cx/cy attributes on wp:extent
  xml_str <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><w:drawing><wp:inline>',
    '<wp:extent/>',   # Missing cx and cy
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="img.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/></pic:blipFill>',
    '<pic:spPr/></pic:pic></a:graphicData></a:graphic>',
    '</wp:inline></w:drawing></w:r></w:p>'
  )
  para <- xml2::read_xml(xml_str)
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    a = "http://schemas.openxmlformats.org/drawingml/2006/main",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture",
    r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  )
  payload <- list(float_width = "5000dxa")
  result <- build_image_anchor(para, payload, ns_ext)

  expect_false(result$success)
  expect_match(result$reason, "missing cx/cy")
})
