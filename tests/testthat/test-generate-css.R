test_that("generate_reference_doc creates docx from YAML config with CSS", {
  # Create a temp config file
  config_dir <- tempdir()
  css_source <- system.file("extdata/popcorn-theme/popcorn-base.css", package = "docstyle")
  if (css_source == "") css_source <- "../../inst/extdata/popcorn-theme/popcorn-base.css"

  # Copy CSS to temp dir
  css_path <- file.path(config_dir, "popcorn-base.css")
  file.copy(css_source, css_path, overwrite = TRUE)

  # Create YAML config
  config_path <- file.path(config_dir, "_quarto.yml")
  writeLines(c(
    "docstyle:",
    "  css: popcorn-base.css",
    "  page:",
    "    size: letter"
  ), config_path)

  out_file <- file.path(config_dir, "reference.docx")
  result <- generate_reference_doc(config_path, output_path = out_file)

  expect_true(file.exists(result))

  # Verify content
  doc <- officer::read_docx(result)
  styles_xml <- get_styles_xml(doc)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # Check Heading 1 (h1 in CSS)
  # In CSS: h1 { font: 600 48px ...; color: #262c3a; }
  h1_node <- xml2::xml_find_first(styles_xml, "//w:style[@w:styleId='Heading1']", ns = ns)
  expect_false(inherits(h1_node, "xml_missing"))

  # Color
  color <- xml2::xml_find_first(h1_node, "w:rPr/w:color", ns = ns)
  val_col <- xml2::xml_attr(color, "val")
  expect_equal(toupper(val_col), "262C3A")

  # Size: 14pt -> 28 half-points (popcorn-base.css uses 14pt for h1)
  sz <- xml2::xml_find_first(h1_node, "w:rPr/w:sz", ns = ns)
  val_sz <- xml2::xml_attr(sz, "val")
  expect_equal(val_sz, "28")
})


test_that("generate_reference_doc applies page margins", {
  config_dir <- tempdir()

  # Create YAML config with margins
  config_path <- file.path(config_dir, "_quarto_margins.yml")
  writeLines(c(
    "docstyle:",
    "  page:",
    "    size: letter",
    "    margins:",
    "      top: 2in"
  ), config_path)

  out_file <- file.path(config_dir, "reference_margins.docx")
  result <- generate_reference_doc(config_path, output_path = out_file)

  # Verify margins
  doc <- officer::read_docx(result)
  xml <- doc$doc_obj$get()
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  pgMar <- xml2::xml_find_first(xml, "//w:sectPr/w:pgMar", ns = ns)
  val <- xml2::xml_attr(pgMar, "top")

  # 2in = 2880 twips
  expect_equal(val, "2880")
})


test_that("generate_reference_doc applies footer", {
  config_dir <- tempdir()

  # Create YAML config with footer
  config_path <- file.path(config_dir, "_quarto_footer.yml")
  writeLines(c(
    "docstyle:",
    "  page:",
    "    size: letter",
    "  footer:",
    "    enabled: true",
    "    content: 'Page {page} of {pages}'"
  ), config_path)

  out_file <- file.path(config_dir, "reference_footer.docx")
  result <- generate_reference_doc(config_path, output_path = out_file)

  expect_true(file.exists(result))

  # Verify footer exists
  doc <- officer::read_docx(result)
  footer_path <- file.path(doc$package_dir, "word", "footer1.xml")
  expect_true(file.exists(footer_path))

  # Check footer contains PAGE field
  footer_xml <- xml2::read_xml(footer_path)
  instr <- xml2::xml_find_first(footer_xml, "//w:instrText")
  expect_true(grepl("PAGE", xml2::xml_text(instr)))
})
