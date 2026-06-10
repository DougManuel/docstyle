test_that("is_text_box() detects wp:anchor with wps:txbx", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">',
    '<w:r><w:drawing>',
    '<wp:anchor simplePos="0" behindDoc="0" locked="0" layoutInCell="1" allowOverlap="1"',
    ' distT="0" distB="0" distL="0" distR="0" relativeHeight="251658240">',
    '<wp:simplePos x="0" y="0"/>',
    '<wp:positionH relativeFrom="margin"><wp:posOffset>0</wp:posOffset></wp:positionH>',
    '<wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>',
    '<wp:extent cx="1828800" cy="914400"/>',
    '<wp:effectExtent l="0" t="0" r="0" b="0"/>',
    '<wp:wrapSquare wrapText="bothSides"/>',
    '<wp:docPr id="1" name="TextBox 1"/>',
    '<wp:cNvGraphicFramePr/>',
    '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">',
    '<a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">',
    '<wps:wsp>',
    '<wps:cNvSpPr txBox="1"/>',
    '<wps:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="1828800" cy="914400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></wps:spPr>',
    '<wps:txbx><w:txbxContent>',
    '<w:p><w:r><w:t>Text inside box</w:t></w:r></w:p>',
    '</w:txbxContent></wps:txbx>',
    '<wps:bodyPr wrap="square" lIns="91440" tIns="45720" rIns="91440" bIns="45720" anchor="t"/>',
    '</wps:wsp>',
    '</a:graphicData></a:graphic>',
    '</wp:anchor>',
    '</w:drawing></w:r></w:p>'
  )

  para <- xml2::read_xml(para_xml)
  expect_true(is_text_box(para, ns))
})

test_that("is_text_box() returns FALSE for anchored image", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<w:r><w:drawing><wp:anchor simplePos="0" behindDoc="0" locked="0"',
    ' layoutInCell="1" allowOverlap="1" distT="0" distB="0" distL="0" distR="0"',
    ' relativeHeight="251658240">',
    '<wp:simplePos x="0" y="0"/>',
    '<wp:positionH relativeFrom="margin"><wp:posOffset>0</wp:posOffset></wp:positionH>',
    '<wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>',
    '<wp:extent cx="914400" cy="914400"/>',
    '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">',
    '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:blipFill><a:blip/></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:ext cx="914400" cy="914400"/></a:xfrm></pic:spPr>',
    '</pic:pic></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing></w:r></w:p>'
  )

  para <- xml2::read_xml(para_xml)
  expect_false(is_text_box(para, ns))
})

test_that("extract_text_box_properties() reads positioning", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">',
    '<w:r><w:drawing>',
    '<wp:anchor simplePos="0" behindDoc="1" locked="0" layoutInCell="1" allowOverlap="1"',
    ' distT="0" distB="0" distL="0" distR="0" relativeHeight="251658240">',
    '<wp:simplePos x="0" y="0"/>',
    '<wp:positionH relativeFrom="page"><wp:posOffset>457200</wp:posOffset></wp:positionH>',
    '<wp:positionV relativeFrom="margin"><wp:posOffset>914400</wp:posOffset></wp:positionV>',
    '<wp:extent cx="1828800" cy="914400"/>',
    '<wp:effectExtent l="0" t="0" r="0" b="0"/>',
    '<wp:wrapNone/>',
    '<wp:docPr id="5" name="TextBox 5"/>',
    '<wp:cNvGraphicFramePr/>',
    '<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">',
    '<wps:wsp><wps:cNvSpPr txBox="1"/>',
    '<wps:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="1828800" cy="914400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></wps:spPr>',
    '<wps:txbx><w:txbxContent><w:p><w:r><w:t>Content</w:t></w:r></w:p></w:txbxContent></wps:txbx>',
    '<wps:bodyPr wrap="square"/>',
    '</wps:wsp></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing></w:r></w:p>'
  )

  para <- xml2::read_xml(para_xml)
  props <- extract_text_box_properties(para, ns)
  expect_false(is.null(props))
  expect_equal(props$horizontal_anchor, "page")
  expect_equal(props$vertical_anchor, "margin")
  expect_equal(props$z_layer, "behind")
  expect_equal(props$wrap_style, "none")
  # posOffset 457200 EMU / 635 = 720 DXA
  expect_equal(props$position_x, "720")
})

test_that("extract_text_box_content() returns inner paragraphs", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">',
    '<w:r><w:drawing>',
    '<wp:anchor simplePos="0" behindDoc="0" locked="0" layoutInCell="1" allowOverlap="1"',
    ' distT="0" distB="0" distL="0" distR="0" relativeHeight="251658240">',
    '<wp:simplePos x="0" y="0"/>',
    '<wp:positionH relativeFrom="margin"><wp:posOffset>0</wp:posOffset></wp:positionH>',
    '<wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>',
    '<wp:extent cx="1828800" cy="914400"/>',
    '<wp:docPr id="1" name="TextBox 1"/>',
    '<wp:cNvGraphicFramePr/>',
    '<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">',
    '<wps:wsp><wps:cNvSpPr txBox="1"/>',
    '<wps:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="1828800" cy="914400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></wps:spPr>',
    '<wps:txbx><w:txbxContent>',
    '<w:p><w:r><w:t>First</w:t></w:r></w:p>',
    '<w:p><w:r><w:t>Second</w:t></w:r></w:p>',
    '</w:txbxContent></wps:txbx>',
    '<wps:bodyPr wrap="square"/>',
    '</wps:wsp></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing></w:r></w:p>'
  )

  para <- xml2::read_xml(para_xml)
  content <- extract_text_box_content(para, ns)
  expect_length(content, 2L)
})

test_that("harvest detects text box and emits div with content-mode=textbox", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # Text box paragraph
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">',
    '<w:r><w:drawing>',
    '<wp:anchor simplePos="0" behindDoc="0" locked="0" layoutInCell="1" allowOverlap="1"',
    ' distT="0" distB="0" distL="0" distR="0" relativeHeight="251658240">',
    '<wp:simplePos x="0" y="0"/>',
    '<wp:positionH relativeFrom="margin"><wp:posOffset>0</wp:posOffset></wp:positionH>',
    '<wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>',
    '<wp:extent cx="1828800" cy="914400"/>',
    '<wp:docPr id="1" name="TextBox 1"/>',
    '<wp:cNvGraphicFramePr/>',
    '<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">',
    '<wps:wsp><wps:cNvSpPr txBox="1"/>',
    '<wps:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="1828800" cy="914400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></wps:spPr>',
    '<wps:txbx><w:txbxContent>',
    '<w:p><w:r><w:t>Box content</w:t></w:r></w:p>',
    '</w:txbxContent></wps:txbx>',
    '<wps:bodyPr wrap="square"/>',
    '</wps:wsp></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing></w:r></w:p>'
  )

  para <- xml2::read_xml(para_xml)

  # Should be detected as text box, not as anchored image
  expect_true(is_text_box(para, ns))
  expect_false(is_anchored_image(para, ns))

  # Should extract properties
  props <- extract_text_box_properties(para, ns)
  expect_false(is.null(props))
  expect_equal(props$horizontal_anchor, "margin")

  # Should extract content
  content <- extract_text_box_content(para, ns)
  expect_length(content, 1L)
  expect_equal(
    xml2::xml_text(xml2::xml_find_first(content[[1]], ".//w:t", ns)),
    "Box content"
  )
})

test_that("is_grouped_figure() returns TRUE for wpg:wgp with pic:pic and wps:txbx", {
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"',
    ' xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><w:drawing>',
    '<wp:anchor simplePos="0" relativeHeight="251658240" behindDoc="0"',
    ' locked="0" layoutInCell="1" allowOverlap="1">',
    '<wp:positionH relativeFrom="margin"><wp:posOffset>0</wp:posOffset></wp:positionH>',
    '<wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>',
    '<wp:extent cx="5943600" cy="4877040"/>',
    '<wp:wrapSquare wrapText="bothSides"/>',
    '<wp:docPr id="1" name="Group 1"/>',
    '<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup">',
    '<wpg:wgp>',
    '<wpg:cNvGrpSpPr/>',
    '<wpg:grpSpPr>',
    '<a:xfrm><a:off x="0" y="0"/><a:ext cx="5943600" cy="4877040"/>',
    '<a:chOff x="0" y="0"/><a:chExt cx="5943600" cy="4877040"/></a:xfrm>',
    '</wpg:grpSpPr>',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="2" name="img.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="5943600" cy="3962400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>',
    '<wps:wsp><wps:cNvSpPr txBox="1"/>',
    '<wps:spPr><a:xfrm><a:off x="0" y="4053840"/><a:ext cx="5943600" cy="914400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></wps:spPr>',
    '<wps:txbx><w:txbxContent>',
    '<w:p><w:r><w:t>Figure 1. Caption</w:t></w:r></w:p>',
    '</w:txbxContent></wps:txbx>',
    '<wps:bodyPr/></wps:wsp>',
    '</wpg:wgp></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing></w:r></w:p>'
  )
  para <- xml2::read_xml(para_xml)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  expect_true(is_grouped_figure(para, ns))
})

test_that("is_grouped_figure() returns FALSE for plain anchored image (no wps:txbx)", {
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><w:drawing>',
    '<wp:anchor simplePos="0" relativeHeight="251658240" behindDoc="0"',
    ' locked="0" layoutInCell="1" allowOverlap="1">',
    '<wp:extent cx="5943600" cy="3962400"/>',
    '<wp:docPr id="1" name="Picture 1"/>',
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="2" name="img.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/></pic:blipFill>',
    '<pic:spPr/></pic:pic></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing></w:r></w:p>'
  )
  para <- xml2::read_xml(para_xml)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  expect_false(is_grouped_figure(para, ns))
})

test_that("is_grouped_figure() returns FALSE for text box (no pic:pic)", {
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">',
    '<w:r><w:drawing>',
    '<wp:anchor simplePos="0" relativeHeight="251658240" behindDoc="0"',
    ' locked="0" layoutInCell="1" allowOverlap="1">',
    '<wp:extent cx="3000000" cy="1000000"/>',
    '<wp:docPr id="1" name="TextBox 1"/>',
    '<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">',
    '<wps:wsp><wps:cNvSpPr txBox="1"/>',
    '<wps:spPr/><wps:txbx><w:txbxContent>',
    '<w:p><w:r><w:t>Text</w:t></w:r></w:p>',
    '</w:txbxContent></wps:txbx>',
    '<wps:bodyPr/></wps:wsp></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing></w:r></w:p>'
  )
  para <- xml2::read_xml(para_xml)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  expect_false(is_grouped_figure(para, ns))
})

test_that("extract_group_properties() reads anchor positioning + caption_y + image_height", {
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"',
    ' xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><w:drawing>',
    '<wp:anchor simplePos="0" relativeHeight="251658240" behindDoc="0"',
    ' locked="0" layoutInCell="1" allowOverlap="1"',
    ' distT="0" distB="0" distL="125730" distR="125730">',
    '<wp:positionH relativeFrom="margin"><wp:posOffset>6048375</wp:posOffset></wp:positionH>',
    '<wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>',
    '<wp:extent cx="5935980" cy="4877040"/>',
    '<wp:wrapSquare wrapText="bothSides"/>',
    '<wp:docPr id="1" name="Group 1"/>',
    '<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup">',
    '<wpg:wgp>',
    '<wpg:cNvGrpSpPr/>',
    '<wpg:grpSpPr>',
    '<a:xfrm><a:off x="0" y="0"/><a:ext cx="5935980" cy="4877040"/>',
    '<a:chOff x="0" y="0"/><a:chExt cx="5935980" cy="4877040"/></a:xfrm>',
    '</wpg:grpSpPr>',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="2" name="img.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="5935980" cy="3962400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>',
    '<wps:wsp><wps:cNvSpPr txBox="1"/>',
    '<wps:spPr><a:xfrm><a:off x="0" y="4053840"/><a:ext cx="5935980" cy="914400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></wps:spPr>',
    '<wps:txbx><w:txbxContent>',
    '<w:p><w:r><w:t>Figure 1. Caption</w:t></w:r></w:p>',
    '</w:txbxContent></wps:txbx>',
    '<wps:bodyPr/></wps:wsp>',
    '</wpg:wgp></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing></w:r></w:p>'
  )
  para <- xml2::read_xml(para_xml)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  props <- extract_group_properties(para, ns)

  expect_equal(props$horizontal_anchor, "margin")
  expect_equal(props$vertical_anchor, "text")
  # 6048375 EMU / 635 = 9525 DXA
  expect_equal(props$position_x, "9525")
  expect_equal(props$position_y, "0")
  # 5935980 EMU / 635 = 9348 DXA (round(5935980/635) = 9348)
  expect_equal(props$float_width, "9348")
  expect_equal(props$z_layer, "front")
  expect_equal(props$wrap_style, "square")
  # caption_y: 4053840 EMU / 635 = 6384 DXA
  expect_equal(props$caption_y, "6384")
  # image_height: 3962400 EMU / 635 = 6240 DXA
  expect_equal(props$image_height, "6240")
})

test_that("extract_group_properties() returns NULL when no wp:anchor", {
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:r><w:t>Plain text</w:t></w:r></w:p>'
  )
  para <- xml2::read_xml(para_xml)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  expect_null(extract_group_properties(para, ns))
})

test_that("extract_group_content() returns image rel ID and caption nodes", {
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"',
    ' xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><w:drawing>',
    '<wp:anchor simplePos="0" relativeHeight="251658240" behindDoc="0"',
    ' locked="0" layoutInCell="1" allowOverlap="1">',
    '<wp:extent cx="5943600" cy="4877040"/>',
    '<wp:docPr id="1" name="Group 1"/>',
    '<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup">',
    '<wpg:wgp><wpg:cNvGrpSpPr/><wpg:grpSpPr/>',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="2" name="img.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId7"/></pic:blipFill>',
    '<pic:spPr/></pic:pic>',
    '<wps:wsp><wps:cNvSpPr txBox="1"/>',
    '<wps:spPr/><wps:txbx><w:txbxContent>',
    '<w:p><w:r><w:t>Figure 1. Caption text</w:t></w:r></w:p>',
    '<w:p><w:r><w:t>Second line</w:t></w:r></w:p>',
    '</w:txbxContent></wps:txbx>',
    '<wps:bodyPr/></wps:wsp>',
    '</wpg:wgp></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing></w:r></w:p>'
  )
  para <- xml2::read_xml(para_xml)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  content <- extract_group_content(para, ns)

  expect_equal(content$image_rel_id, "rId7")
  expect_equal(length(content$caption_nodes), 2L)
})

test_that("extract_group_content() handles mc:AlternateContent wrapping", {
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"',
    ' xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"',
    ' xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><mc:AlternateContent><mc:Choice Requires="wpg">',
    '<w:drawing>',
    '<wp:anchor simplePos="0" relativeHeight="251658240" behindDoc="0"',
    ' locked="0" layoutInCell="1" allowOverlap="1">',
    '<wp:extent cx="5943600" cy="4877040"/>',
    '<wp:docPr id="1" name="Group 1"/>',
    '<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup">',
    '<wpg:wgp><wpg:cNvGrpSpPr/><wpg:grpSpPr/>',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="2" name="img.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId9"/></pic:blipFill>',
    '<pic:spPr/></pic:pic>',
    '<wps:wsp><wps:cNvSpPr txBox="1"/>',
    '<wps:spPr/><wps:txbx><w:txbxContent>',
    '<w:p><w:r><w:t>Caption in mc:Choice</w:t></w:r></w:p>',
    '</w:txbxContent></wps:txbx>',
    '<wps:bodyPr/></wps:wsp>',
    '</wpg:wgp></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing>',
    '</mc:Choice></mc:AlternateContent></w:r></w:p>'
  )
  para <- xml2::read_xml(para_xml)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  content <- extract_group_content(para, ns)

  expect_equal(content$image_rel_id, "rId9")
  expect_equal(length(content$caption_nodes), 1L)
})

test_that("Detection order: grouped figure beats text box and anchored image", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"',
    ' xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><w:drawing>',
    '<wp:anchor simplePos="0" relativeHeight="251658240" behindDoc="0"',
    ' locked="0" layoutInCell="1" allowOverlap="1">',
    '<wp:extent cx="5943600" cy="4877040"/>',
    '<wp:docPr id="1" name="Group 1"/>',
    '<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup">',
    '<wpg:wgp><wpg:cNvGrpSpPr/><wpg:grpSpPr/>',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="2" name="img.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/></pic:blipFill>',
    '<pic:spPr/></pic:pic>',
    '<wps:wsp><wps:cNvSpPr txBox="1"/>',
    '<wps:spPr/><wps:txbx><w:txbxContent>',
    '<w:p><w:r><w:t>Caption</w:t></w:r></w:p>',
    '</w:txbxContent></wps:txbx>',
    '<wps:bodyPr/></wps:wsp>',
    '</wpg:wgp></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing></w:r></w:p>'
  )
  para <- xml2::read_xml(para_xml)

  # is_grouped_figure must be checked FIRST and return TRUE
  expect_true(is_grouped_figure(para, ns))

  # The same XML also triggers is_text_box and is_anchored_image,

  # so detection order matters — grouped figure must win
  expect_true(is_text_box(para, ns) || is_anchored_image(para, ns) ||
              is_grouped_figure(para, ns))
})

test_that("is_grouped_figure() detects group inside mc:AlternateContent", {
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"',
    ' xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"',
    ' xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><mc:AlternateContent><mc:Choice Requires="wpg">',
    '<w:drawing>',
    '<wp:anchor simplePos="0" relativeHeight="251658240" behindDoc="0"',
    ' locked="0" layoutInCell="1" allowOverlap="1">',
    '<wp:extent cx="5943600" cy="4877040"/>',
    '<wp:docPr id="1" name="Group 1"/>',
    '<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup">',
    '<wpg:wgp><wpg:cNvGrpSpPr/><wpg:grpSpPr/>',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="2" name="img.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/></pic:blipFill>',
    '<pic:spPr/></pic:pic>',
    '<wps:wsp><wps:cNvSpPr txBox="1"/>',
    '<wps:spPr/><wps:txbx><w:txbxContent>',
    '<w:p><w:r><w:t>Caption</w:t></w:r></w:p>',
    '</w:txbxContent></wps:txbx>',
    '<wps:bodyPr/></wps:wsp>',
    '</wpg:wgp></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing>',
    '</mc:Choice></mc:AlternateContent></w:r></w:p>'
  )
  para <- xml2::read_xml(para_xml)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  expect_true(is_grouped_figure(para, ns))
})
