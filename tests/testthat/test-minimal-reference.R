# Tests for minimal reference.docx template (Issue #65)

test_that("build_minimal_reference creates a valid docx", {
  ref_path <- build_minimal_reference()
  expect_true(file.exists(ref_path))

  # Officer can read it
  doc <- officer::read_docx(ref_path)
  expect_s3_class(doc, "rdocx")
})

test_that("minimal reference contains required OOXML parts", {
  ref_path <- build_minimal_reference()

  # Check zip contents
  zip_contents <- utils::unzip(ref_path, list = TRUE)$Name

  expect_true("[Content_Types].xml" %in% zip_contents)
  expect_true("_rels/.rels" %in% zip_contents)
  expect_true("word/document.xml" %in% zip_contents)
  expect_true("word/styles.xml" %in% zip_contents)
  expect_true("word/numbering.xml" %in% zip_contents)
  expect_true("word/settings.xml" %in% zip_contents)
  expect_true("word/footnotes.xml" %in% zip_contents)
  expect_true("word/theme/theme1.xml" %in% zip_contents)
  expect_true("word/_rels/document.xml.rels" %in% zip_contents)
})

test_that("minimal reference styles have empty pPr/rPr", {
  ref_path <- build_minimal_reference()
  doc <- officer::read_docx(ref_path)
  styles_xml <- get_styles_xml(doc)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # BodyText should exist with basedOn Normal, no pPr children
  body_text <- xml2::xml_find_first(
    styles_xml, "//w:style[@w:styleId='BodyText']", ns = ns
  )
  expect_false(inherits(body_text, "xml_missing"))

  # basedOn should be Normal
  based_on <- xml2::xml_find_first(body_text, "w:basedOn", ns = ns)
  expect_equal(xml2::xml_attr(based_on, "val"), "Normal")

  # No pPr element (empty style, CSS controls everything)
  pPr <- xml2::xml_find_first(body_text, "w:pPr", ns = ns)
  expect_true(inherits(pPr, "xml_missing"))

  # No rPr element
  rPr <- xml2::xml_find_first(body_text, "w:rPr", ns = ns)
  expect_true(inherits(rPr, "xml_missing"))
})

test_that("CSS on Normal cascades to BodyText via pre-render cascade", {
  config_dir <- tempdir()

  css_content <- "
  p {
    margin-bottom: 6pt;
    font-family: 'Libre Baskerville';
  }
  "
  css_path <- file.path(config_dir, "cascade_test.css")
  writeLines(css_content, css_path)

  config_path <- file.path(config_dir, "_quarto_cascade.yml")
  writeLines(c(
    "docstyle:",
    "  css: cascade_test.css",
    "  page:",
    "    size: letter"
  ), config_path)

  out_file <- file.path(config_dir, "reference_cascade.docx")
  result <- generate_reference_doc(config_path, output_path = out_file)

  doc <- officer::read_docx(result)
  styles_xml <- get_styles_xml(doc)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # Normal should have the CSS-injected spacing
  normal <- xml2::xml_find_first(
    styles_xml, "//w:style[@w:styleId='Normal']", ns = ns
  )
  spacing <- xml2::xml_find_first(normal, "w:pPr/w:spacing", ns = ns)
  expect_false(inherits(spacing, "xml_missing"))
  expect_equal(xml2::xml_attr(spacing, "after"), "120")  # 6pt = 120 twips

  # Normal should have the CSS-injected font
  rFonts <- xml2::xml_find_first(normal, "w:rPr/w:rFonts", ns = ns)
  expect_false(inherits(rFonts, "xml_missing"))
  expect_equal(xml2::xml_attr(rFonts, "ascii"), "Libre Baskerville")

  # BodyText SHOULD have cascaded spacing from Normal.
  # Pandoc hardcodes 180/180 on BodyText if it has no explicit pPr,
  # so we pre-cascade Normal's CSS values to prevent Pandoc overwrite.
  body_text <- xml2::xml_find_first(
    styles_xml, "//w:style[@w:styleId='BodyText']", ns = ns
  )
  bt_spacing <- xml2::xml_find_first(body_text, "w:pPr/w:spacing", ns = ns)
  expect_false(inherits(bt_spacing, "xml_missing"))
  expect_equal(xml2::xml_attr(bt_spacing, "after"), "120")

  # BodyText should also have cascaded font
  bt_fonts <- xml2::xml_find_first(body_text, "w:rPr/w:rFonts", ns = ns)
  expect_false(inherits(bt_fonts, "xml_missing"))
  expect_equal(xml2::xml_attr(bt_fonts, "ascii"), "Libre Baskerville")

  # FirstParagraph should inherit cascade from BodyText (not Normal)
  fp <- xml2::xml_find_first(
    styles_xml, "//w:style[@w:styleId='FirstParagraph']", ns = ns
  )
  fp_spacing <- xml2::xml_find_first(fp, "w:pPr/w:spacing", ns = ns)
  expect_false(inherits(fp_spacing, "xml_missing"))
  expect_equal(xml2::xml_attr(fp_spacing, "after"), "120")
})

test_that("CSS on .compact overrides Normal cascade", {
  config_dir <- tempdir()

  css_content <- "
  p {
    margin-bottom: 6pt;
  }
  .compact {
    margin-bottom: 2pt;
  }
  "
  css_path <- file.path(config_dir, "compact_test.css")
  writeLines(css_content, css_path)

  config_path <- file.path(config_dir, "_quarto_compact.yml")
  writeLines(c(
    "docstyle:",
    "  css: compact_test.css",
    "  page:",
    "    size: letter"
  ), config_path)

  out_file <- file.path(config_dir, "reference_compact.docx")
  result <- generate_reference_doc(config_path, output_path = out_file)

  doc <- officer::read_docx(result)
  styles_xml <- get_styles_xml(doc)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # Normal has 6pt (120 twips)
  normal <- xml2::xml_find_first(
    styles_xml, "//w:style[@w:styleId='Normal']", ns = ns
  )
  n_spacing <- xml2::xml_find_first(normal, "w:pPr/w:spacing", ns = ns)
  expect_equal(xml2::xml_attr(n_spacing, "after"), "120")

  # Compact has 2pt (40 twips) — explicit override
  compact <- xml2::xml_find_first(
    styles_xml, "//w:style[@w:styleId='Compact']", ns = ns
  )
  c_spacing <- xml2::xml_find_first(compact, "w:pPr/w:spacing", ns = ns)
  expect_false(inherits(c_spacing, "xml_missing"))
  expect_equal(xml2::xml_attr(c_spacing, "after"), "40")
})

test_that("CSS selectors map to Pandoc body text styles", {
  expect_equal(
    map_selector_to_word_style(".body-text"),
    list(id = "BodyText", name = "Body Text")
  )
  expect_equal(
    map_selector_to_word_style(".first-paragraph"),
    list(id = "FirstParagraph", name = "First Paragraph")
  )
  expect_equal(
    map_selector_to_word_style(".compact"),
    list(id = "Compact", name = "Compact")
  )
  expect_equal(
    map_selector_to_word_style(".table-caption"),
    list(id = "TableCaption", name = "Table Caption")
  )
  expect_equal(
    map_selector_to_word_style(".image-caption"),
    list(id = "ImageCaption", name = "Image Caption")
  )
})

test_that("CSS selectors map to all 38 reference styles", {
  # Headings 7-9
  expect_equal(
    map_selector_to_word_style("h7"),
    list(id = "Heading7", name = "heading 7")
  )
  expect_equal(
    map_selector_to_word_style("h8"),
    list(id = "Heading8", name = "heading 8")
  )
  expect_equal(
    map_selector_to_word_style("h9"),
    list(id = "Heading9", name = "heading 9")
  )

  # Bibliography
  expect_equal(
    map_selector_to_word_style(".bibliography"),
    list(id = "Bibliography", name = "Bibliography")
  )
  expect_equal(
    map_selector_to_word_style(".references"),
    list(id = "Bibliography", name = "Bibliography")
  )

  # Figure styles
  expect_equal(
    map_selector_to_word_style(".figure"),
    list(id = "Figure", name = "Figure")
  )
  expect_equal(
    map_selector_to_word_style(".captioned-figure"),
    list(id = "CaptionedFigure", name = "Captioned Figure")
  )

  # Definition list styles
  expect_equal(
    map_selector_to_word_style("dt"),
    list(id = "DefinitionTerm", name = "Definition Term")
  )
  expect_equal(
    map_selector_to_word_style("dd"),
    list(id = "Definition", name = "Definition")
  )
  expect_equal(
    map_selector_to_word_style(".definition-term"),
    list(id = "DefinitionTerm", name = "Definition Term")
  )
  expect_equal(
    map_selector_to_word_style(".definition"),
    list(id = "Definition", name = "Definition")
  )

  # Caption via element selector
  expect_equal(
    map_selector_to_word_style("caption"),
    list(id = "Caption", name = "Caption")
  )
})

test_that("minimal reference has correct basedOn chains", {
  ref_path <- build_minimal_reference()
  doc <- officer::read_docx(ref_path)
  styles_xml <- get_styles_xml(doc)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  get_based_on <- function(style_id) {
    style <- xml2::xml_find_first(
      styles_xml,
      sprintf("//w:style[@w:styleId='%s']", style_id),
      ns = ns
    )
    if (inherits(style, "xml_missing")) return(NA_character_)
    based_on <- xml2::xml_find_first(style, "w:basedOn", ns = ns)
    if (inherits(based_on, "xml_missing")) return(NA_character_)
    xml2::xml_attr(based_on, "val")
  }

  # BodyText → Normal
  expect_equal(get_based_on("BodyText"), "Normal")
  # FirstParagraph → BodyText
  expect_equal(get_based_on("FirstParagraph"), "BodyText")
  # Compact → BodyText
  expect_equal(get_based_on("Compact"), "BodyText")
  # BlockText → BodyText
  expect_equal(get_based_on("BlockText"), "BodyText")
  # Heading1 → Normal
  expect_equal(get_based_on("Heading1"), "Normal")
  # TableCaption → Caption
  expect_equal(get_based_on("TableCaption"), "Caption")
  # ImageCaption → Caption
  expect_equal(get_based_on("ImageCaption"), "Caption")
})

test_that("minimal reference has no theme font references in styles", {
  ref_path <- build_minimal_reference()

  # Read the raw styles.xml to check for theme font references
  temp_dir <- tempfile("ref_check_")
  dir.create(temp_dir)
  on.exit(unlink(temp_dir, recursive = TRUE))
  utils::unzip(ref_path, exdir = temp_dir)

  styles_content <- readLines(
    file.path(temp_dir, "word", "styles.xml"),
    warn = FALSE
  )
  styles_text <- paste(styles_content, collapse = "\n")

  # No asciiTheme or hAnsiTheme references
  expect_false(grepl("asciiTheme", styles_text))
  expect_false(grepl("hAnsiTheme", styles_text))
})

test_that("base-doc: pandoc falls back to Pandoc reference", {
  config_dir <- tempdir()

  css_content <- "p { font-size: 12pt; }"
  css_path <- file.path(config_dir, "pandoc_fallback.css")
  writeLines(css_content, css_path)

  config_path <- file.path(config_dir, "_quarto_pandoc.yml")
  writeLines(c(
    "docstyle:",
    "  css: pandoc_fallback.css",
    "  base-doc: pandoc",
    "  page:",
    "    size: letter"
  ), config_path)

  out_file <- file.path(config_dir, "reference_pandoc.docx")
  # Should succeed and use Pandoc's default reference
  result <- generate_reference_doc(config_path, output_path = out_file)

  expect_true(file.exists(result))

  # Pandoc's reference has many styles with explicit formatting
  doc <- officer::read_docx(result)
  styles_xml <- get_styles_xml(doc)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # Pandoc's BodyText has explicit spacing (180/180)
  body_text <- xml2::xml_find_first(
    styles_xml, "//w:style[@w:styleId='BodyText']", ns = ns
  )
  bt_spacing <- xml2::xml_find_first(body_text, "w:pPr/w:spacing", ns = ns)
  # With Pandoc's default, BodyText has hardcoded spacing
  expect_false(inherits(bt_spacing, "xml_missing"))
})

test_that("generate_reference_doc defaults to minimal reference", {
  config_dir <- tempdir()

  css_content <- "p { font-size: 12pt; }"
  css_path <- file.path(config_dir, "default_test.css")
  writeLines(css_content, css_path)

  config_path <- file.path(config_dir, "_quarto_default.yml")
  writeLines(c(
    "docstyle:",
    "  css: default_test.css",
    "  page:",
    "    size: letter"
  ), config_path)

  # Clear cached reference to force rebuild and capture message
  cached_ref <- file.path(tempdir(), "docstyle_cache", "docstyle_reference.docx")
  if (file.exists(cached_ref)) file.remove(cached_ref)

  out_file <- file.path(config_dir, "reference_default.docx")
  msgs <- capture.output(
    result <- generate_reference_doc(config_path, output_path = out_file),
    type = "message"
  )

  expect_true(file.exists(result))
  # Should mention docstyle templates, not Pandoc
  expect_true(any(grepl("docstyle templates", msgs)))
})
