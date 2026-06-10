
# =============================================================================
# Tests for style_map.R
# =============================================================================
# build_style_map_from_xml() scans a template's styles.xml and builds a mapping
# from Pandoc's expected style IDs to the template's native style IDs. This
# enables post-render rewriting when templates use non-standard style names.
#
# Map direction: Pandoc ID -> template ID (e.g., "Heading1" -> "MDPI21heading1")

# Helper: build minimal styles.xml string
make_styles_xml <- function(...) {
  styles <- paste0(...)
  paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    styles,
    '</w:styles>'
  )
}

# Helper: build a single style element
make_style <- function(id, name = id, based_on = NULL, outline_lvl = NULL,
                       type = "paragraph") {
  parts <- paste0(
    '<w:style w:type="', type, '" w:styleId="', id, '">',
    '<w:name w:val="', name, '"/>'
  )
  if (!is.null(based_on)) {
    parts <- paste0(parts, '<w:basedOn w:val="', based_on, '"/>')
  }
  if (!is.null(outline_lvl)) {
    parts <- paste0(parts, '<w:pPr><w:outlineLvl w:val="', outline_lvl, '"/></w:pPr>')
  }
  paste0(parts, '</w:style>')
}

# ---- identity: standard names produce empty map -----------------------------

test_that("build_style_map_from_xml returns empty list for standard Pandoc names", {
  xml_str <- make_styles_xml(
    make_style("Heading1", "heading 1", outline_lvl = 0),
    make_style("Heading2", "heading 2", outline_lvl = 1),
    make_style("Normal", "Normal"),
    make_style("BodyText", "Body Text", based_on = "Normal"),
    make_style("Caption", "Caption"),
    make_style("Title", "Title")
  )
  result <- build_style_map_from_xml(xml_str)
  expect_true(is.list(result))
  expect_equal(length(result), 0L)
})

# ---- outlineLvl resolution --------------------------------------------------

test_that("build_style_map_from_xml detects outlineLvl-based heading mapping", {
  xml_str <- make_styles_xml(
    make_style("MDPI21heading1", "MDPI 2.1 Heading 1", outline_lvl = 0),
    make_style("MDPI21heading2", "MDPI 2.1 Heading 2", outline_lvl = 1),
    make_style("Normal", "Normal")
  )
  result <- build_style_map_from_xml(xml_str)
  expect_equal(result[["Heading1"]], "MDPI21heading1")
  expect_equal(result[["Heading2"]], "MDPI21heading2")
})

test_that("build_style_map_from_xml ignores outlineLvl 6+ (body outline)", {
  xml_str <- make_styles_xml(
    make_style("BodyOutline", "Body Outline Level", outline_lvl = 6),
    make_style("Normal", "Normal")
  )
  result <- build_style_map_from_xml(xml_str)
  # Should not map any heading to BodyOutline
  expect_false("Heading7" %in% names(result))
  expect_equal(length(result), 0L)
})

# ---- basedOn chain resolution -----------------------------------------------

test_that("build_style_map_from_xml detects basedOn chain mapping", {
  xml_str <- make_styles_xml(
    make_style("MDPI31text", "MDPI 3.1 Text", based_on = "BodyText"),
    make_style("BodyText", "Body Text", based_on = "Normal"),
    make_style("Normal", "Normal")
  )
  result <- build_style_map_from_xml(xml_str)
  expect_equal(result[["BodyText"]], "MDPI31text")
})

test_that("build_style_map_from_xml basedOn chain with outlineLvl on parent", {
  # CustomStyle basedOn BaseH1 which has outlineLvl=0
  xml_str <- make_styles_xml(
    make_style("CustomH1", "Custom Heading", based_on = "BaseH1"),
    make_style("BaseH1", "Base Heading 1", outline_lvl = 0),
    make_style("Normal", "Normal")
  )
  result <- build_style_map_from_xml(xml_str)
  # CustomH1 resolves to Heading1 via basedOn -> outlineLvl
  expect_equal(result[["Heading1"]], "CustomH1")
})

# ---- display name pattern match ---------------------------------------------

test_that("build_style_map_from_xml detects display name pattern match", {
  xml_str <- make_styles_xml(
    make_style("JournalCaption", "Caption"),
    make_style("Normal", "Normal")
  )
  result <- build_style_map_from_xml(xml_str)
  expect_equal(result[["Caption"]], "JournalCaption")
})

test_that("build_style_map_from_xml display name match is case-insensitive", {
  xml_str <- make_styles_xml(
    make_style("myTitle", "title"),
    make_style("Normal", "Normal")
  )
  result <- build_style_map_from_xml(xml_str)
  expect_equal(result[["Title"]], "myTitle")
})

# ---- multiple resolution methods together -----------------------------------

test_that("build_style_map_from_xml handles multiple resolution methods", {
  xml_str <- make_styles_xml(
    # outlineLvl match
    make_style("MDPI21heading1", "MDPI Heading", outline_lvl = 0),
    # basedOn chain
    make_style("MDPI31text", "MDPI Text", based_on = "BodyText"),
    make_style("BodyText", "Body Text", based_on = "Normal"),
    # display name match
    make_style("JournalCaption", "Caption"),
    # standard name (identity, should NOT appear)
    make_style("Normal", "Normal"),
    make_style("Title", "Title")
  )
  result <- build_style_map_from_xml(xml_str)
  expect_equal(result[["Heading1"]], "MDPI21heading1")
  expect_equal(result[["BodyText"]], "MDPI31text")
  expect_equal(result[["Caption"]], "JournalCaption")
  # Identity mappings should not appear
  expect_null(result[["Normal"]])
  expect_null(result[["Title"]])
})

# ---- priority: outlineLvl preferred over name match -------------------------

test_that("build_style_map_from_xml prefers outlineLvl over name match", {
  # Style has outlineLvl=0 AND a name containing "Heading 2"
  # outlineLvl should win (maps to Heading1, not Heading2)
  xml_str <- make_styles_xml(
    make_style("WeirdStyle", "Heading 2", outline_lvl = 0),
    make_style("Normal", "Normal")
  )
  result <- build_style_map_from_xml(xml_str)
  expect_equal(result[["Heading1"]], "WeirdStyle")
  # Should NOT also map Heading2
  expect_null(result[["Heading2"]])
})

# ---- first-match wins for same Pandoc target --------------------------------

test_that("build_style_map_from_xml first match wins for same Pandoc target", {
  # Two styles both resolve to Heading1 via outlineLvl — first one wins
  xml_str <- make_styles_xml(
    make_style("FirstH1", "First H1", outline_lvl = 0),
    make_style("SecondH1", "Second H1", outline_lvl = 0),
    make_style("Normal", "Normal")
  )
  result <- build_style_map_from_xml(xml_str)
  expect_equal(result[["Heading1"]], "FirstH1")
})

# ---- get_template_style_ids -------------------------------------------------

test_that("get_template_style_ids returns all style IDs from XML", {
  xml_str <- make_styles_xml(
    make_style("Normal", "Normal"),
    make_style("Heading1", "heading 1", outline_lvl = 0),
    make_style("CustomStyle", "Custom")
  )
  ids <- get_template_style_ids_from_xml(xml_str)
  expect_true(is.character(ids))
  expect_true("Normal" %in% ids)
  expect_true("Heading1" %in% ids)
  expect_true("CustomStyle" %in% ids)
  expect_equal(length(ids), 3L)
})

# ---- edge cases -------------------------------------------------------------

test_that("build_style_map_from_xml handles xml2 document input", {
  xml_str <- make_styles_xml(
    make_style("MDPI21heading1", "MDPI Heading", outline_lvl = 0)
  )
  doc <- xml2::read_xml(xml_str)
  result <- build_style_map_from_xml(doc)
  expect_equal(result[["Heading1"]], "MDPI21heading1")
})

test_that("build_style_map_from_xml handles empty styles", {
  xml_str <- make_styles_xml()
  result <- build_style_map_from_xml(xml_str)
  expect_true(is.list(result))
  expect_equal(length(result), 0L)
})

test_that("build_style_map_from_xml skips character styles for heading resolution", {
  # A character style with outlineLvl should not be mapped as a heading
  xml_str <- make_styles_xml(
    make_style("CharStyle", "Char Heading", outline_lvl = 0, type = "character"),
    make_style("Normal", "Normal")
  )
  result <- build_style_map_from_xml(xml_str)
  expect_equal(length(result), 0L)
})

# =============================================================================
# Tests for swap_style_ids (post-render style rewriting)
# =============================================================================

# Helper: build minimal document.xml string
make_document_xml <- function(...) {
  paras <- paste0(...)
  paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    paras,
    '</w:body></w:document>'
  )
}

# ---- swap_document_styles: pStyle -------------------------------------------

test_that("swap_document_styles renames pStyle values", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  style_map <- list(Heading1 = "MDPI21heading1", BodyText = "MDPI31text")

  xml_str <- make_document_xml(
    '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr></w:p>',
    '<w:p><w:pPr><w:pStyle w:val="BodyText"/></w:pPr></w:p>',
    '<w:p><w:pPr><w:pStyle w:val="Normal"/></w:pPr></w:p>'
  )
  doc <- xml2::read_xml(xml_str)

  swap_document_styles(doc, style_map, ns)

  pstyles <- xml2::xml_find_all(doc, "//w:pStyle", ns)
  vals <- vapply(pstyles, function(n) xml2::xml_attr(n, "val"), character(1))
  expect_equal(vals, c("MDPI21heading1", "MDPI31text", "Normal"))
})

# ---- swap_document_styles: rStyle -------------------------------------------

test_that("swap_document_styles renames rStyle values", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  style_map <- list(FootnoteReference = "MDPIFootnoteRef")

  xml_str <- make_document_xml(
    '<w:p><w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr></w:r></w:p>',
    '<w:p><w:r><w:rPr><w:rStyle w:val="Hyperlink"/></w:rPr></w:r></w:p>'
  )
  doc <- xml2::read_xml(xml_str)

  swap_document_styles(doc, style_map, ns)

  rstyles <- xml2::xml_find_all(doc, "//w:rStyle", ns)
  vals <- vapply(rstyles, function(n) xml2::xml_attr(n, "val"), character(1))
  expect_equal(vals, c("MDPIFootnoteRef", "Hyperlink"))
})

# ---- swap_document_styles: tblStyle ------------------------------------------

test_that("swap_document_styles renames tblStyle values", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  style_map <- list(Table = "MDPITable")

  xml_str <- paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    '<w:tbl><w:tblPr><w:tblStyle w:val="Table"/></w:tblPr></w:tbl>',
    '<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/></w:tblPr></w:tbl>',
    '</w:body></w:document>'
  )
  doc <- xml2::read_xml(xml_str)

  swap_document_styles(doc, style_map, ns)

  tblstyles <- xml2::xml_find_all(doc, "//w:tblStyle", ns)
  vals <- vapply(tblstyles, function(n) xml2::xml_attr(n, "val"), character(1))
  expect_equal(vals, c("MDPITable", "TableGrid"))
})

# ---- swap_styles_xml: renames styleId, basedOn, link, next ------------------

test_that("swap_styles_xml renames styleId, basedOn, link, and next references", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  style_map <- list(Heading1 = "MDPI21heading1", BodyText = "MDPI31text")

  xml_str <- make_styles_xml(
    '<w:style w:type="paragraph" w:styleId="Heading1">',
    '  <w:name w:val="heading 1"/>',
    '  <w:basedOn w:val="Normal"/>',
    '  <w:next w:val="BodyText"/>',
    '  <w:link w:val="Heading1Char"/>',
    '</w:style>',
    '<w:style w:type="paragraph" w:styleId="BodyText">',
    '  <w:name w:val="Body Text"/>',
    '  <w:basedOn w:val="Normal"/>',
    '</w:style>',
    '<w:style w:type="paragraph" w:styleId="Normal">',
    '  <w:name w:val="Normal"/>',
    '</w:style>'
  )
  doc <- xml2::read_xml(xml_str)

  swap_styles_xml(doc, style_map, ns)

  # styleId attributes renamed
  style_nodes <- xml2::xml_find_all(doc, "//w:style", ns)
  ids <- vapply(style_nodes, function(n) xml2::xml_attr(n, "styleId"), character(1))
  expect_true("MDPI21heading1" %in% ids)
  expect_true("MDPI31text" %in% ids)
  expect_false("Heading1" %in% ids)
  expect_false("BodyText" %in% ids)

  # basedOn NOT changed (Normal is not in the map)
  based_on_nodes <- xml2::xml_find_all(doc, "//w:basedOn", ns)
  based_on_vals <- vapply(based_on_nodes, function(n) xml2::xml_attr(n, "val"), character(1))
  expect_true(all(based_on_vals == "Normal"))

  # next renamed (BodyText -> MDPI31text)
  next_node <- xml2::xml_find_first(doc, "//w:next", ns)
  expect_equal(xml2::xml_attr(next_node, "val"), "MDPI31text")
})

# ---- swap_style_ids: end-to-end with zip/unzip -----------------------------

test_that("swap_style_ids modifies a docx file in place", {
  skip_on_cran()
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # Create a minimal docx with known style references
  temp_dir <- tempfile("swap_test_")
  dir.create(file.path(temp_dir, "word"), recursive = TRUE)

  # document.xml with pStyle="Heading1"
  writeLines(make_document_xml(
    '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr></w:p>'
  ), file.path(temp_dir, "word", "document.xml"))

  # styles.xml with the style definition
  writeLines(make_styles_xml(
    '<w:style w:type="paragraph" w:styleId="Heading1">',
    '  <w:name w:val="heading 1"/>',
    '</w:style>'
  ), file.path(temp_dir, "word", "styles.xml"))

  # [Content_Types].xml (minimal)
  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
    '<Default Extension="xml" ContentType="application/xml"/>',
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
    '</Types>'
  ), file.path(temp_dir, "[Content_Types].xml"))

  # _rels/.rels (minimal)
  dir.create(file.path(temp_dir, "_rels"), recursive = TRUE)
  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    '</Relationships>'
  ), file.path(temp_dir, "_rels", ".rels"))

  # Zip it into a docx
  docx_path <- file.path(tempdir(), "swap_test.docx")
  old_wd <- getwd()
  setwd(temp_dir)
  utils::zip(docx_path, files = list.files(".", recursive = TRUE, all.files = TRUE),
             flags = "-r9Xq")
  setwd(old_wd)

  # Write style-map.json
  sidecar_dir <- tempfile("sidecar_")
  dir.create(sidecar_dir)
  jsonlite::write_json(
    list(Heading1 = "MDPI21heading1"),
    file.path(sidecar_dir, "style-map.json"),
    auto_unbox = TRUE
  )

  # Run swap
  result <- swap_style_ids(docx_path, sidecar_dir)
  expect_true(result$swapped)
  expect_equal(result$n_mappings, 1L)

  # Verify the docx was modified
  verify_dir <- tempfile("verify_")
  utils::unzip(docx_path, exdir = verify_dir)
  doc_xml <- xml2::read_xml(file.path(verify_dir, "word", "document.xml"))
  pstyle <- xml2::xml_find_first(doc_xml, "//w:pStyle", ns)
  expect_equal(xml2::xml_attr(pstyle, "val"), "MDPI21heading1")

  styles_xml <- xml2::read_xml(file.path(verify_dir, "word", "styles.xml"))
  style_node <- xml2::xml_find_first(styles_xml, "//w:style", ns)
  expect_equal(xml2::xml_attr(style_node, "styleId"), "MDPI21heading1")

  # Cleanup
  unlink(temp_dir, recursive = TRUE)
  unlink(verify_dir, recursive = TRUE)
  unlink(sidecar_dir, recursive = TRUE)
  unlink(docx_path)
})

test_that("swap_style_ids returns early when no style-map.json", {
  sidecar_dir <- tempfile("empty_sidecar_")
  dir.create(sidecar_dir)

  result <- swap_style_ids("dummy.docx", sidecar_dir)
  expect_false(result$swapped)
  expect_equal(result$n_mappings, 0L)

  unlink(sidecar_dir, recursive = TRUE)
})

test_that("cascade_css_to_children skips template-resident styles", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # Build styles.xml with Normal having properties, BodyText and Heading1 as children
  styles_xml <- xml2::read_xml(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:style w:type="paragraph" w:styleId="Normal">',
    '  <w:name w:val="Normal"/>',
    '  <w:pPr><w:spacing w:after="120"/></w:pPr>',
    '  <w:rPr><w:rFonts w:ascii="Palatino"/></w:rPr>',
    '</w:style>',
    '<w:style w:type="paragraph" w:styleId="BodyText">',
    '  <w:name w:val="Body Text"/>',
    '  <w:basedOn w:val="Normal"/>',
    '</w:style>',
    '<w:style w:type="paragraph" w:styleId="Heading1">',
    '  <w:name w:val="heading 1"/>',
    '  <w:basedOn w:val="Normal"/>',
    '</w:style>',
    '</w:styles>'
  ))

  css_styles <- list(p = list(`font-family` = "Palatino", `margin-bottom` = "10pt"))

  # With template_styles = NULL (CSS-first mode), cascade happens
  cascade_css_to_children(styles_xml, ns, css_styles, template_styles = NULL)
  bt_spacing <- xml2::xml_find_first(
    styles_xml, "//w:style[@w:styleId='BodyText']/w:pPr/w:spacing", ns
  )
  expect_false(inherits(bt_spacing, "xml_missing"))

  # Reload XML for second test
  styles_xml2 <- xml2::read_xml(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:style w:type="paragraph" w:styleId="Normal">',
    '  <w:name w:val="Normal"/>',
    '  <w:pPr><w:spacing w:after="120"/></w:pPr>',
    '  <w:rPr><w:rFonts w:ascii="Palatino"/></w:rPr>',
    '</w:style>',
    '<w:style w:type="paragraph" w:styleId="BodyText">',
    '  <w:name w:val="Body Text"/>',
    '  <w:basedOn w:val="Normal"/>',
    '</w:style>',
    '<w:style w:type="paragraph" w:styleId="Heading1">',
    '  <w:name w:val="heading 1"/>',
    '  <w:basedOn w:val="Normal"/>',
    '</w:style>',
    '</w:styles>'
  ))

  # With template_styles including BodyText, cascade skips it but still cascades to Heading1
  cascade_css_to_children(styles_xml2, ns, css_styles,
                          template_styles = c("BodyText"))
  bt_spacing2 <- xml2::xml_find_first(
    styles_xml2, "//w:style[@w:styleId='BodyText']/w:pPr/w:spacing", ns
  )
  # BodyText should NOT have been cascaded (template style)
  expect_true(inherits(bt_spacing2, "xml_missing"))

  # Heading1 should still get the cascade (not in template_styles)
  h1_spacing <- xml2::xml_find_first(
    styles_xml2, "//w:style[@w:styleId='Heading1']/w:pPr/w:spacing", ns
  )
  expect_false(inherits(h1_spacing, "xml_missing"))
})

test_that("get_allowed_styles includes all template styles when template_path provided", {
  # Create a minimal template docx with custom styles
  temp_dir <- tempfile("template_prune_")
  dir.create(file.path(temp_dir, "word"), recursive = TRUE)
  dir.create(file.path(temp_dir, "_rels"), recursive = TRUE)

  writeLines('<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="xml" ContentType="application/xml"/>
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
</Types>', file.path(temp_dir, "[Content_Types].xml"))

  writeLines('<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>', file.path(temp_dir, "_rels", ".rels"))

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body><w:p/></w:body></w:document>'
  ), file.path(temp_dir, "word", "document.xml"))

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:style w:type="paragraph" w:styleId="Normal"><w:name w:val="Normal"/></w:style>',
    '<w:style w:type="paragraph" w:styleId="MDPI21heading1"><w:name w:val="MDPI heading"/></w:style>',
    '<w:style w:type="paragraph" w:styleId="MDPI31text"><w:name w:val="MDPI text"/></w:style>',
    '</w:styles>'
  ), file.path(temp_dir, "word", "styles.xml"))

  template_path <- tempfile(fileext = ".docx")
  old_wd <- getwd()
  on.exit(setwd(old_wd), add = TRUE)
  setwd(temp_dir)
  utils::zip(template_path, files = list.files(".", recursive = TRUE, all.files = TRUE),
             flags = "-r9Xq")
  setwd(old_wd)

  allowed <- get_allowed_styles(config = NULL, sidecar_dir = NULL,
                                template_path = template_path)
  expect_true("MDPI21heading1" %in% allowed)
  expect_true("MDPI31text" %in% allowed)
  expect_true("Normal" %in% allowed)

  # Without template_path, those custom styles would not be in allowed
  allowed_no_template <- get_allowed_styles(config = NULL, sidecar_dir = NULL,
                                            template_path = NULL)
  expect_false("MDPI21heading1" %in% allowed_no_template)

  unlink(c(temp_dir, template_path), recursive = TRUE)
})

# =============================================================================
# Integration tests: full template mode pipeline
# =============================================================================

# Helper to create minimal DOCX from styles.xml and document.xml content
make_test_docx <- function(styles_xml_content, doc_xml_content = NULL) {
  temp_dir <- tempfile("test_docx_")
  dir.create(file.path(temp_dir, "word"), recursive = TRUE)
  dir.create(file.path(temp_dir, "_rels"), recursive = TRUE)

  writeLines('<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="xml" ContentType="application/xml"/>
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
</Types>', file.path(temp_dir, "[Content_Types].xml"))

  writeLines('<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>', file.path(temp_dir, "_rels", ".rels"))

  if (is.null(doc_xml_content)) {
    doc_xml_content <- paste0(
      '<?xml version="1.0" encoding="UTF-8"?>',
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
      '<w:body><w:p/></w:body></w:document>'
    )
  }
  writeLines(doc_xml_content, file.path(temp_dir, "word", "document.xml"))
  writeLines(styles_xml_content, file.path(temp_dir, "word", "styles.xml"))

  docx_path <- tempfile(fileext = ".docx")
  old_wd <- getwd()
  on.exit(setwd(old_wd), add = TRUE)
  setwd(temp_dir)
  utils::zip(docx_path, files = list.files(".", recursive = TRUE, all.files = TRUE),
             flags = "-r9Xq")
  setwd(old_wd)

  list(path = docx_path, temp_dir = temp_dir)
}

# ---- integration: MDPI-like template round-trip ------------------------------

test_that("full template mode flow: build map + swap IDs round-trips correctly", {
  skip_on_cran()
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # --- Step 1: Create MDPI-like template DOCX ---
  # MDPI31text basedOn BodyText so the chain walk resolves to BodyText (Pandoc ID)
  template_styles <- make_styles_xml(
    make_style("Normal", "Normal"),
    make_style("BodyText", "Body Text", based_on = "Normal"),
    make_style("MDPI21heading1", "MDPI 2.1 Heading 1", outline_lvl = 0),
    make_style("MDPI22heading2", "MDPI 2.2 Heading 2", outline_lvl = 1),
    make_style("MDPI31text", "MDPI 3.1 Text", based_on = "BodyText")
  )
  template <- make_test_docx(template_styles)
  on.exit(unlink(c(template$path, template$temp_dir), recursive = TRUE), add = TRUE)

  # --- Step 2: build_style_map produces correct mappings + writes JSON ---
  sidecar_dir <- tempfile("sidecar_")
  dir.create(sidecar_dir)
  on.exit(unlink(sidecar_dir, recursive = TRUE), add = TRUE)

  style_map <- build_style_map(template$path, sidecar_dir)

  expect_equal(style_map[["Heading1"]], "MDPI21heading1")
  expect_equal(style_map[["Heading2"]], "MDPI22heading2")
  expect_equal(style_map[["BodyText"]], "MDPI31text")
  expect_null(style_map[["Normal"]])  # identity, should not appear

  # JSON file exists with correct content
  json_path <- file.path(sidecar_dir, "style-map.json")
  expect_true(file.exists(json_path))
  json_map <- jsonlite::fromJSON(json_path, simplifyVector = FALSE)
  expect_equal(json_map[["Heading1"]], "MDPI21heading1")
  expect_equal(json_map[["Heading2"]], "MDPI22heading2")
  expect_equal(json_map[["BodyText"]], "MDPI31text")

  # --- Step 3: Create "rendered" DOCX with Pandoc-style IDs ---
  rendered_styles <- make_styles_xml(
    make_style("Normal", "Normal"),
    make_style("Heading1", "heading 1", outline_lvl = 0),
    make_style("Heading2", "heading 2", outline_lvl = 1),
    make_style("BodyText", "Body Text", based_on = "Normal")
  )
  rendered_doc <- make_document_xml(
    '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Title</w:t></w:r></w:p>',
    '<w:p><w:pPr><w:pStyle w:val="BodyText"/></w:pPr><w:r><w:t>Body text</w:t></w:r></w:p>',
    '<w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>Subtitle</w:t></w:r></w:p>'
  )
  rendered <- make_test_docx(rendered_styles, rendered_doc)
  on.exit(unlink(c(rendered$path, rendered$temp_dir), recursive = TRUE), add = TRUE)

  # --- Step 4: swap_style_ids rewrites to template-native IDs ---
  result <- swap_style_ids(rendered$path, sidecar_dir)
  expect_true(result$swapped)
  expect_equal(result$n_mappings, 3L)

  # Verify document.xml has MDPI-native IDs
  verify_dir <- tempfile("verify_")
  utils::unzip(rendered$path, exdir = verify_dir)
  on.exit(unlink(verify_dir, recursive = TRUE), add = TRUE)

  doc_xml <- xml2::read_xml(file.path(verify_dir, "word", "document.xml"))
  pstyles <- xml2::xml_find_all(doc_xml, "//w:pStyle", ns)
  pstyle_vals <- vapply(pstyles, function(n) xml2::xml_attr(n, "val"), character(1))
  expect_equal(pstyle_vals, c("MDPI21heading1", "MDPI31text", "MDPI22heading2"))

  # Verify styles.xml has renamed styleIds
  styles_xml <- xml2::read_xml(file.path(verify_dir, "word", "styles.xml"))
  style_nodes <- xml2::xml_find_all(styles_xml, "//w:style", ns)
  style_ids <- vapply(style_nodes, function(n) xml2::xml_attr(n, "styleId"), character(1))
  expect_true("MDPI21heading1" %in% style_ids)
  expect_true("MDPI22heading2" %in% style_ids)
  expect_true("MDPI31text" %in% style_ids)
  expect_false("Heading1" %in% style_ids)
  expect_false("Heading2" %in% style_ids)
  expect_false("BodyText" %in% style_ids)
})

# ---- integration: CSS-first mode unchanged when base-doc omitted -------------

test_that("CSS-first mode unchanged: standard names produce no swap", {
  skip_on_cran()

  # Create DOCX with standard Pandoc style names
  standard_styles <- make_styles_xml(
    make_style("Normal", "Normal"),
    make_style("Heading1", "heading 1", outline_lvl = 0),
    make_style("BodyText", "Body Text", based_on = "Normal")
  )
  standard <- make_test_docx(standard_styles)
  on.exit(unlink(c(standard$path, standard$temp_dir), recursive = TRUE), add = TRUE)

  # build_style_map returns empty list (all identity)
  sidecar_dir <- tempfile("sidecar_css_")
  dir.create(sidecar_dir)
  on.exit(unlink(sidecar_dir, recursive = TRUE), add = TRUE)

  style_map <- build_style_map(standard$path, sidecar_dir)
  expect_true(is.list(style_map))
  expect_equal(length(style_map), 0L)

  # swap_style_ids with no style-map.json returns swapped=FALSE
  # (build_style_map writes an empty map to JSON, so use a fresh sidecar)
  empty_sidecar <- tempfile("empty_sidecar_")
  dir.create(empty_sidecar)
  on.exit(unlink(empty_sidecar, recursive = TRUE), add = TRUE)

  result <- swap_style_ids("dummy.docx", empty_sidecar)
  expect_false(result$swapped)
  expect_equal(result$n_mappings, 0L)
})
