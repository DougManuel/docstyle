test_that("create_style_node constructs valid XML", {
  props <- list(
    id = "MyStyle",
    name = "My Style",
    based_on = "Normal",
    pPr = list(
      spacing = list(after = "200"),
      jc = "center"
    ),
    rPr = list(
      b = "1", # Bold
      color = "FF0000"
    )
  )
  
  node <- create_style_node(props)
  # print(node)
  
  # Attributes are namespaced w:styleId
  expect_equal(xml2::xml_attr(node, "w:styleId"), "MyStyle")
  
  # Check pPr
  pPr <- xml2::xml_find_first(node, "w:pPr")
  expect_false(inherits(pPr, "xml_missing"))
  
  spacing <- xml2::xml_find_first(pPr, "w:spacing")
  # print(xml2::xml_attrs(spacing))
  
  # It seems xml_set_attr might behave differently regarding namespaces?
  # If we just check "after", does it work?
  val <- xml2::xml_attr(spacing, "w:after")
  if (is.na(val)) val <- xml2::xml_attr(spacing, "after")
  expect_equal(val, "200")
  
  jc <- xml2::xml_find_first(pPr, "w:jc")
  expect_equal(xml2::xml_attr(jc, "w:val"), "center")
  
  # Check rPr
  rPr <- xml2::xml_find_first(node, "w:rPr")
  color <- xml2::xml_find_first(rPr, "w:color")
  expect_equal(xml2::xml_attr(color, "w:val"), "FF0000")
})
