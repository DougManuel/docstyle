test_that("generate_reference_doc handles custom classes (Semantic Mapping)", {
  # Create a CSS with a custom class
  config_dir <- tempdir()

  css_content <- "
  .checklist {
    color: #FF0000;
    font-size: 14px;
    font-weight: bold;
  }
  "
  css_path <- file.path(config_dir, "custom.css")
  writeLines(css_content, css_path)

  # Create YAML config
  config_path <- file.path(config_dir, "_quarto_custom.yml")
  writeLines(c(
    "docstyle:",
    "  css: custom.css",
    "  page:",
    "    size: letter"
  ), config_path)

  out_file <- file.path(config_dir, "reference_custom.docx")
  result <- generate_reference_doc(config_path, output_path = out_file)

  expect_true(file.exists(result))

  # Verify content
  doc <- officer::read_docx(result)
  styles_xml <- get_styles_xml(doc)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # Check for "Checklist" style
  # map_selector_to_word_style converts ".checklist" -> ID: "checklist", Name: "Checklist"
  style_node <- xml2::xml_find_first(styles_xml, "//w:style[@w:styleId='checklist']", ns = ns)
  expect_false(inherits(style_node, "xml_missing"))

  # Check Name
  name_node <- xml2::xml_find_first(style_node, "w:name", ns = ns)
  val_name <- xml2::xml_attr(name_node, "val")
  expect_equal(val_name, "Checklist")

  # Check Properties
  # Color: #FF0000
  color <- xml2::xml_find_first(style_node, "w:rPr/w:color", ns = ns)
  val_col <- xml2::xml_attr(color, "val")
  expect_equal(toupper(val_col), "FF0000")

  # Size: 14px -> 10.5pt -> 21 half-points
  sz <- xml2::xml_find_first(style_node, "w:rPr/w:sz", ns = ns)
  val_sz <- xml2::xml_attr(sz, "val")
  expect_equal(val_sz, "21")

  # Bold
  b <- xml2::xml_find_first(style_node, "w:rPr/w:b", ns = ns)
  expect_false(inherits(b, "xml_missing"))
})
