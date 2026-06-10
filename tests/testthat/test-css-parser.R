test_that("css_to_twips converts correctly", {
  # 1 inch = 72 pts = 1440 twips
  expect_equal(css_to_twips("1in"), 1440)
  expect_equal(css_to_twips("0.5in"), 720)
  
  # 72 points = 1440 twips
  expect_equal(css_to_twips("72pt"), 1440)
  expect_equal(css_to_twips("36pt"), 720)
  
  # 96 px = 1 inch = 1440 twips (at 96 DPI)
  expect_equal(css_to_twips("96px"), 1440)
  
  # 1 cm = 1/2.54 in = 1440 / 2.54 twips = 566.9... -> 567
  expect_equal(css_to_twips("1cm"), 567)
})

test_that("css_to_half_points converts correctly", {
  # 12pt = 24 half-points
  expect_equal(css_to_half_points("12pt"), 24)
  
  # 16px = 12pt = 24 half-points
  expect_equal(css_to_half_points("16px"), 24)
  
  # 1em = 12pt (default base) = 24 half-points
  expect_equal(css_to_half_points("1em"), 24)
})

test_that("css_to_eighth_points converts correctly", {
  # 1pt = 8 eighth-points
  expect_equal(css_to_eighth_points("1pt"), 8)
  expect_equal(css_to_eighth_points("0.5pt"), 4)
  expect_equal(css_to_eighth_points("0.125pt"), 1)
})

test_that("css_to_ooxml_color converts correctly", {
  expect_equal(css_to_ooxml_color("#FFFFFF"), "FFFFFF")
  expect_equal(css_to_ooxml_color("#ffffff"), "FFFFFF")
  expect_equal(css_to_ooxml_color("#FFF"), "FFFFFF")
  expect_equal(css_to_ooxml_color("red"), "FF0000")
  expect_equal(css_to_ooxml_color("blue"), "0000FF")
  expect_equal(css_to_ooxml_color("transparent"), "auto")
})

test_that("invalid inputs handle gracefully", {
  expect_warning(val <- css_to_twips("invalid"))
  expect_equal(val, 0)

  expect_warning(col <- css_to_ooxml_color("super_color"))
  expect_equal(col, "auto")
})


# ═══════════════════════════════════════════════════════════════════════════
# Border Parsing Tests
# ═══════════════════════════════════════════════════════════════════════════

test_that("parse_css_border handles standard shorthand", {
  result <- parse_css_border("1pt solid #000000")
  expect_equal(result$val, "single")
  expect_equal(result$sz, "8")  # 1pt = 8 eighth-points
  expect_equal(result$color, "000000")
})

test_that("parse_css_border handles different styles", {
  dashed <- parse_css_border("1pt dashed #7F7F7F")
  expect_equal(dashed$val, "dashed")
  expect_equal(dashed$color, "7F7F7F")

  dotted <- parse_css_border("0.5pt dotted #000000")
  expect_equal(dotted$val, "dotted")
  expect_equal(dotted$sz, "4")  # 0.5pt = 4 eighth-points

  double <- parse_css_border("2pt double #000000")
  expect_equal(double$val, "double")
  expect_equal(double$sz, "16")  # 2pt = 16 eighth-points
})

test_that("parse_css_border returns NULL for none", {
  expect_null(parse_css_border("none"))
  expect_null(parse_css_border(NULL))
  expect_null(parse_css_border(""))
  expect_null(parse_css_border(NA))
})

test_that("parse_css_border handles missing color", {
  result <- parse_css_border("1pt solid")
  expect_equal(result$val, "single")
  expect_equal(result$color, "auto")
})


# ═══════════════════════════════════════════════════════════════════════════
# Table Style Extraction Tests
# ═══════════════════════════════════════════════════════════════════════════

test_that("css_to_table_style extracts borders from table selector", {
  table_props <- list(
    `border-top` = "1pt solid #000000",
    `border-bottom` = "1pt solid #000000"
  )
  result <- css_to_table_style(table_props)

  expect_equal(result$borders$top$val, "single")
  expect_equal(result$borders$top$color, "000000")
  expect_equal(result$borders$bottom$val, "single")
  expect_null(result$borders$left)
  expect_null(result$borders$right)
})

test_that("css_to_table_style uses shorthand border for all sides", {
  table_props <- list(border = "1pt solid #000000")
  result <- css_to_table_style(table_props)

  expect_equal(result$borders$top$val, "single")
  expect_equal(result$borders$bottom$val, "single")
  expect_equal(result$borders$left$val, "single")
  expect_equal(result$borders$right$val, "single")
})

test_that("css_to_table_style extracts header shading and bold", {
  table_props <- list()
  th_props <- list(
    `background-color` = "#D9D9D9",
    `font-weight` = "bold"
  )
  result <- css_to_table_style(table_props, th_props)

  expect_equal(result$header_shading, "D9D9D9")
  expect_true(result$header_bold)
})

test_that("css_to_table_style extracts cell borders as insideH/insideV", {
  table_props <- list()
  td_props <- list(border = "1pt solid #000000")
  result <- css_to_table_style(table_props, td_props = td_props)

  expect_equal(result$borders$insideH$val, "single")
  expect_equal(result$borders$insideV$val, "single")
})

test_that("css_to_table_style extracts font size", {
  table_props <- list(`font-size` = "9pt")
  result <- css_to_table_style(table_props)

  expect_equal(result$font_size_half_pts, 18)  # 9pt = 18 half-points
})

test_that("extract_table_styles finds all table-* selectors", {
  css_styles <- list(
    `.table-formal` = list(
      `border-top` = "1pt solid #000000",
      `border-bottom` = "1pt solid #000000"
    ),
    `.table-formal th` = list(
      `background-color` = "#D9D9D9",
      `font-weight` = "bold"
    ),
    `.table-grid` = list(
      border = "1pt solid #000000"
    ),
    `.table-grid th, .table-grid td` = list(
      border = "1pt solid #000000"
    ),
    `.not-a-table` = list(color = "red")
  )

  result <- extract_table_styles(css_styles)

  expect_true("table-formal" %in% names(result))
  expect_true("table-grid" %in% names(result))
  expect_false("not-a-table" %in% names(result))

  # table-formal should have header shading
  expect_equal(result$`table-formal`$header_shading, "D9D9D9")
  expect_true(result$`table-formal`$header_bold)
})

# ---------------------------------------------------------------------------
# css_to_pPr: background-color and border-left (#99)
# ---------------------------------------------------------------------------

test_that("css_to_pPr: background-color produces pPr$shd with hex fill (#99)", {
  pPr <- css_to_pPr(list("background-color" = "#F2F2F2"))
  expect_equal(pPr$shd, "F2F2F2")
})

test_that("css_to_pPr: background-color 'auto' or unknown produces no shd (#99)", {
  pPr <- css_to_pPr(list("background-color" = "transparent"))
  expect_null(pPr$shd)
})

test_that("css_to_pPr: border-left produces pPr$pBdr$left (#99)", {
  pPr <- css_to_pPr(list("border-left" = "3pt solid #262c3a"))
  expect_equal(pPr$pBdr$left$val, "single")
  expect_equal(pPr$pBdr$left$sz, "24")   # 3pt * 8 = 24 eighth-points
  expect_equal(pPr$pBdr$left$color, "262C3A")
})

test_that("css_to_pPr: border shorthand sets all four sides (#99)", {
  pPr <- css_to_pPr(list("border" = "1pt solid #000000"))
  for (side in c("top", "bottom", "left", "right")) {
    expect_equal(pPr$pBdr[[side]]$val, "single",
      info = paste("side:", side))
  }
})

test_that("css_to_pPr: border-left side overrides shorthand (#99)", {
  pPr <- css_to_pPr(list(
    "border" = "1pt solid #000000",
    "border-left" = "3pt solid #FF0000"
  ))
  # Left uses the explicit side rule
  expect_equal(pPr$pBdr$left$sz, "24")
  expect_equal(pPr$pBdr$left$color, "FF0000")
  # Other sides still use shorthand
  expect_equal(pPr$pBdr$top$sz, "8")
})

# ---------------------------------------------------------------------------
# inject_pPr_to_style: XML output for shd and pBdr (#99)
# ---------------------------------------------------------------------------

test_that("inject_pPr_to_style: writes w:shd with correct attributes (#99)", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  style_node <- xml2::read_xml(
    '<w:style xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
       <w:pPr/>
     </w:style>'
  )
  inject_pPr_to_style(style_node, list(shd = "F2F2F2"), ns)

  shd <- xml2::xml_find_first(style_node, ".//w:shd", ns = ns)
  expect_false(inherits(shd, "xml_missing"))
  expect_equal(xml2::xml_attr(shd, "fill"), "F2F2F2")
  expect_equal(xml2::xml_attr(shd, "val"), "clear")
  expect_equal(xml2::xml_attr(shd, "color"), "auto")
})

test_that("inject_pPr_to_style: w:shd is idempotent — only one shd node (#99)", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  style_node <- xml2::read_xml(
    '<w:style xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
       <w:pPr/>
     </w:style>'
  )
  inject_pPr_to_style(style_node, list(shd = "F2F2F2"), ns)
  inject_pPr_to_style(style_node, list(shd = "EEEEEE"), ns)

  shd_nodes <- xml2::xml_find_all(style_node, ".//w:shd", ns = ns)
  expect_length(shd_nodes, 1L)
  expect_equal(xml2::xml_attr(shd_nodes[[1]], "fill"), "EEEEEE")
})

test_that("inject_pPr_to_style: writes w:pBdr left with correct attributes (#99)", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  style_node <- xml2::read_xml(
    '<w:style xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
       <w:pPr/>
     </w:style>'
  )
  pPr <- list(pBdr = list(left = list(val = "single", sz = "24", color = "262C3A")))
  inject_pPr_to_style(style_node, pPr, ns)

  left <- xml2::xml_find_first(style_node, ".//w:pBdr/w:left", ns = ns)
  expect_false(inherits(left, "xml_missing"))
  expect_equal(xml2::xml_attr(left, "val"), "single")
  expect_equal(xml2::xml_attr(left, "sz"),  "24")
  expect_equal(xml2::xml_attr(left, "color"), "262C3A")

  expect_true(inherits(xml2::xml_find_first(style_node, ".//w:pBdr/w:top",    ns = ns), "xml_missing"))
  expect_true(inherits(xml2::xml_find_first(style_node, ".//w:pBdr/w:right",  ns = ns), "xml_missing"))
  expect_true(inherits(xml2::xml_find_first(style_node, ".//w:pBdr/w:bottom", ns = ns), "xml_missing"))
})

test_that("inject_pPr_to_style: w:pBdr precedes w:ind in output (#99)", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  style_node <- xml2::read_xml(
    '<w:style xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
       <w:pPr/>
     </w:style>'
  )
  pPr <- list(
    ind  = list(left = "720"),
    pBdr = list(left = list(val = "single", sz = "8", color = "000000"))
  )
  inject_pPr_to_style(style_node, pPr, ns)

  children <- xml2::xml_name(xml2::xml_children(
    xml2::xml_find_first(style_node, "w:pPr", ns = ns)
  ))
  expect_true(which(children == "pBdr") < which(children == "ind"))
})

test_that("inject_pPr_to_style: w:shd precedes w:ind in output (#99)", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  style_node <- xml2::read_xml(
    '<w:style xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
       <w:pPr/>
     </w:style>'
  )
  pPr <- list(
    ind = list(left = "720"),
    shd = "F2F2F2"
  )
  inject_pPr_to_style(style_node, pPr, ns)

  children <- xml2::xml_name(xml2::xml_children(
    xml2::xml_find_first(style_node, "w:pPr", ns = ns)
  ))
  expect_true(which(children == "shd") < which(children == "ind"))
})
