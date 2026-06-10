# Tests for finalize_docx.R

test_that("find_section_markers() finds DOCSTYLE section field codes", {
  # Build minimal document.xml with one section marker
  xml_str <- paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    '<w:p><w:r><w:t>Front matter</w:t></w:r></w:p>',
    # Field code start
    '<w:p>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve">',
    ' ADDIN DOCSTYLE {"type":"section","class":"section-body","page-break":true,"line-numbers":"continuous"} ',
    '</w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '</w:p>',
    # Opening sectPr
    '<w:p><w:pPr><w:sectPr><w:type w:val="continuous"/></w:sectPr></w:pPr></w:p>',
    # Field code end
    '<w:p><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>',
    # Body content
    '<w:p><w:r><w:t>Body content</w:t></w:r></w:p>',
    # Body sectPr
    '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr>',
    '</w:body></w:document>'
  )

  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  markers <- find_section_markers(body, ns)

  expect_length(markers, 1)
  expect_equal(markers[[1]]$class, "section-body")
  expect_true(markers[[1]]$page_break)
  expect_equal(markers[[1]]$line_numbers, "continuous")
})


test_that("find_section_markers() skips non-section field codes", {
  xml_str <- paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    # List field code (not section)
    '<w:p>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve">',
    ' ADDIN DOCSTYLE {"type":"list","class":"list-decimal"} ',
    '</w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '</w:p>',
    '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr>',
    '</w:body></w:document>'
  )

  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  markers <- find_section_markers(body, ns)
  expect_length(markers, 0)
})


test_that("find_section_markers() detects wrapping div (START + content + closing sectPr)", {
  xml_str <- paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    '<w:p><w:r><w:t>Front matter</w:t></w:r></w:p>',
    # Field code start
    '<w:p>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve">',
    ' ADDIN DOCSTYLE {"type":"section","class":"section-body","line-numbers":"continuous"} ',
    '</w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '</w:p>',
    # Opening sectPr
    '<w:p><w:pPr><w:sectPr><w:type w:val="continuous"/></w:sectPr></w:pPr></w:p>',
    # Field code end
    '<w:p><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>',
    # Body content (wrapping div has content)
    '<w:p><w:r><w:t>Introduction</w:t></w:r></w:p>',
    '<w:p><w:r><w:t>Body content</w:t></w:r></w:p>',
    # Closing sectPr (ends the wrapped section)
    '<w:p><w:pPr><w:sectPr><w:type w:val="continuous"/>',
    '<w:lnNumType w:countBy="1" w:restart="continuous" w:distance="360"/></w:sectPr></w:pPr></w:p>',
    # After-div content
    '<w:p><w:r><w:t>References</w:t></w:r></w:p>',
    '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr>',
    '</w:body></w:document>'
  )

  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  markers <- find_section_markers(body, ns)

  expect_length(markers, 1)
  expect_true(markers[[1]]$is_wrapping)
  expect_false(is.null(markers[[1]]$opening_sectPr_para))
  expect_false(is.null(markers[[1]]$closing_sectPr_para))
})


test_that("fix_body_sectPr() removes line numbers from body sectPr", {
  xml_str <- paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    # Marker (wrapping div)
    '<w:p>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve">',
    ' ADDIN DOCSTYLE {"type":"section","class":"section-body","line-numbers":"continuous"} ',
    '</w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '</w:p>',
    '<w:p><w:pPr><w:sectPr><w:type w:val="continuous"/></w:sectPr></w:pPr></w:p>',
    '<w:p><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>',
    '<w:p><w:r><w:t>Content</w:t></w:r></w:p>',
    '<w:p><w:pPr><w:sectPr><w:type w:val="continuous"/>',
    '<w:lnNumType w:countBy="1" w:restart="continuous" w:distance="360"/></w:sectPr></w:pPr></w:p>',
    # Body sectPr WITH line numbers (the bug)
    '<w:sectPr>',
    '<w:pgSz w:w="12240" w:h="15840"/>',
    '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/>',
    '<w:lnNumType w:countBy="1" w:restart="continuous" w:distance="360"/>',
    '</w:sectPr>',
    '</w:body></w:document>'
  )

  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  markers <- find_section_markers(body, ns)
  result <- fix_body_sectPr(body, ns, markers, verbose = FALSE)

  expect_true(result)

  # Verify lnNumType was removed
  body_sectPr <- xml2::xml_find_first(body, "w:sectPr", ns)
  lnNum <- xml2::xml_find_first(body_sectPr, "w:lnNumType", ns)
  expect_true(inherits(lnNum, "xml_missing"))

  # Verify page size/margins still present
  pgSz <- xml2::xml_find_first(body_sectPr, "w:pgSz", ns)
  expect_false(inherits(pgSz, "xml_missing"))
  pgMar <- xml2::xml_find_first(body_sectPr, "w:pgMar", ns)
  expect_false(inherits(pgMar, "xml_missing"))
})


test_that("fix_body_sectPr() is no-op when no wrapping divs exist", {
  xml_str <- paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    '<w:p><w:r><w:t>Content</w:t></w:r></w:p>',
    '<w:sectPr>',
    '<w:lnNumType w:countBy="1" w:restart="continuous" w:distance="360"/>',
    '</w:sectPr>',
    '</w:body></w:document>'
  )

  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  # No markers at all
  result <- fix_body_sectPr(body, ns, list(), verbose = FALSE)
  expect_false(result)

  # lnNumType should still be there
  body_sectPr <- xml2::xml_find_first(body, "w:sectPr", ns)
  lnNum <- xml2::xml_find_first(body_sectPr, "w:lnNumType", ns)
  expect_false(inherits(lnNum, "xml_missing"))
})


test_that("fix_section_breaks() removes line numbers from opening sectPr", {
  xml_str <- paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    # Marker
    '<w:p>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve">',
    ' ADDIN DOCSTYLE {"type":"section","class":"section-body","line-numbers":"continuous"} ',
    '</w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '</w:p>',
    # Opening sectPr WITH line numbers (incorrect — should not have them)
    '<w:p><w:pPr><w:sectPr><w:type w:val="continuous"/>',
    '<w:lnNumType w:countBy="1" w:restart="continuous" w:distance="360"/>',
    '</w:sectPr></w:pPr></w:p>',
    # Field code end
    '<w:p><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>',
    '<w:p><w:r><w:t>Content</w:t></w:r></w:p>',
    '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr>',
    '</w:body></w:document>'
  )

  xml <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  markers <- find_section_markers(body, ns)
  n_fixed <- fix_section_breaks(markers, body, ns, verbose = FALSE)

  expect_equal(n_fixed, 1)

  # Verify the opening sectPr no longer has lnNumType
  opening_sect <- xml2::xml_find_first(
    markers[[1]]$opening_sectPr_para, "w:pPr/w:sectPr", ns)
  lnNum <- xml2::xml_find_first(opening_sect, "w:lnNumType", ns)
  expect_true(inherits(lnNum, "xml_missing"))
})


test_that("set_line_number_attrs() maps QMD values to Word values", {
  xml_str <- '<w:lnNumType xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>'
  node <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  set_line_number_attrs(node, "continuous", ns)
  expect_equal(xml2::xml_attr(node, "restart"), "continuous")

  set_line_number_attrs(node, "section", ns)
  expect_equal(xml2::xml_attr(node, "restart"), "newSection")

  set_line_number_attrs(node, "page", ns)
  expect_equal(xml2::xml_attr(node, "restart"), "newPage")

  # Verify countBy and distance are set (defaults)
  expect_equal(xml2::xml_attr(node, "countBy"), "1")
  expect_equal(xml2::xml_attr(node, "distance"), "360")
})

test_that("set_line_number_attrs() accepts custom count_by, distance, start_num", {
  xml_str <- '<w:lnNumType xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>'
  node <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  set_line_number_attrs(node, "page", ns, count_by = 5, distance = 720, start_num = 10)
  expect_equal(xml2::xml_attr(node, "countBy"), "5")
  expect_equal(xml2::xml_attr(node, "distance"), "720")
  expect_equal(xml2::xml_attr(node, "restart"), "newPage")
  expect_equal(xml2::xml_attr(node, "start"), "10")
})

test_that("set_line_number_attrs() omits start when NULL", {
  xml_str <- '<w:lnNumType xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>'
  node <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  set_line_number_attrs(node, "continuous", ns, count_by = 3)
  expect_equal(xml2::xml_attr(node, "countBy"), "3")
  expect_true(is.na(xml2::xml_attr(node, "start")))
})


test_that("finalize_docx() is end-to-end functional", {
  skip_if_not_installed("xml2")

  # Create a minimal DOCX with a section marker and body sectPr with line nums
  temp_dir <- tempfile("test_finalize_")
  dir.create(file.path(temp_dir, "word"), recursive = TRUE)
  dir.create(file.path(temp_dir, "_rels"))

  # Minimal [Content_Types].xml
  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
    '<Default Extension="xml" ContentType="application/xml"/>',
    '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>',
    '</Types>'
  ), file.path(temp_dir, "[Content_Types].xml"))

  # Minimal .rels
  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>',
    '</Relationships>'
  ), file.path(temp_dir, "_rels", ".rels"))

  dir.create(file.path(temp_dir, "word", "_rels"))
  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>'),
    file.path(temp_dir, "word", "_rels", "document.xml.rels"))

  # document.xml with wrapping div and body sectPr with line numbers
  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    '<w:p><w:r><w:t>Front matter</w:t></w:r></w:p>',
    '<w:p>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE {"type":"section","class":"section-body","line-numbers":"continuous"} </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '</w:p>',
    '<w:p><w:pPr><w:sectPr><w:type w:val="continuous"/></w:sectPr></w:pPr></w:p>',
    '<w:p><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>',
    '<w:p><w:r><w:t>Body content</w:t></w:r></w:p>',
    '<w:p><w:pPr><w:sectPr><w:type w:val="continuous"/>',
    '<w:lnNumType w:countBy="1" w:restart="continuous" w:distance="360"/>',
    '</w:sectPr></w:pPr></w:p>',
    '<w:p><w:r><w:t>References</w:t></w:r></w:p>',
    '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/>',
    '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/>',
    '<w:lnNumType w:countBy="1" w:restart="continuous" w:distance="360"/>',
    '</w:sectPr>',
    '</w:body></w:document>'
  ), file.path(temp_dir, "word", "document.xml"))

  # Zip into a DOCX
  input_docx <- tempfile(fileext = ".docx")
  old_wd <- getwd()
  setwd(temp_dir)
  all_files <- list.files(".", recursive = TRUE, all.files = TRUE)
  utils::zip(input_docx, files = all_files, flags = "-r9Xq")
  setwd(old_wd)

  output_docx <- tempfile(fileext = ".docx")

  # Run finalize
  result <- finalize_docx(input_docx, output_docx, verbose = TRUE)

  expect_equal(result$markers, 1)
  expect_true(result$body_fixed)

  # Verify output: unpack and check body sectPr
  out_dir <- tempfile("verify_")
  dir.create(out_dir)
  utils::unzip(output_docx, exdir = out_dir)

  out_xml <- xml2::read_xml(file.path(out_dir, "word", "document.xml"))
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  out_body <- xml2::xml_find_first(out_xml, "//w:body", ns = ns)

  # Body sectPr should NOT have lnNumType
  body_sect <- xml2::xml_find_first(out_body, "w:sectPr", ns)
  lnNum <- xml2::xml_find_first(body_sect, "w:lnNumType", ns)
  expect_true(inherits(lnNum, "xml_missing"))

  # But pgSz and pgMar should still be there
  expect_false(inherits(xml2::xml_find_first(body_sect, "w:pgSz", ns), "xml_missing"))
  expect_false(inherits(xml2::xml_find_first(body_sect, "w:pgMar", ns), "xml_missing"))

  # Cleanup
  unlink(c(input_docx, output_docx, temp_dir, out_dir), recursive = TRUE)
})


test_that("finalize_docx() handles documents with no markers gracefully", {
  skip_if_not_installed("xml2")

  temp_dir <- tempfile("test_finalize_nomark_")
  dir.create(file.path(temp_dir, "word"), recursive = TRUE)
  dir.create(file.path(temp_dir, "_rels"))
  dir.create(file.path(temp_dir, "word", "_rels"))

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
    '<Default Extension="xml" ContentType="application/xml"/>',
    '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>',
    '</Types>'
  ), file.path(temp_dir, "[Content_Types].xml"))

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>',
    '</Relationships>'
  ), file.path(temp_dir, "_rels", ".rels"))

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>'),
    file.path(temp_dir, "word", "_rels", "document.xml.rels"))

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    '<w:p><w:r><w:t>Just a paragraph</w:t></w:r></w:p>',
    '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr>',
    '</w:body></w:document>'
  ), file.path(temp_dir, "word", "document.xml"))

  input_docx <- tempfile(fileext = ".docx")
  old_wd <- getwd()
  setwd(temp_dir)
  utils::zip(input_docx, files = list.files(".", recursive = TRUE, all.files = TRUE), flags = "-r9Xq")
  setwd(old_wd)

  result <- finalize_docx(input_docx, verbose = FALSE)

  expect_equal(result$markers, 0)
  expect_equal(result$fixed, 0)
  expect_false(result$body_fixed)

  unlink(c(input_docx, temp_dir), recursive = TRUE)
})


test_that("suppress_pre_heading_line_numbers() adds suppressLineNumbers to empty paras before headings", {
  xml_str <- paste0(
    '<w:body xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    # Empty paragraph before heading (should get suppressed)
    '<w:p><w:r><w:t></w:t></w:r></w:p>',
    # Heading paragraph
    '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Introduction</w:t></w:r></w:p>',
    # Non-empty paragraph before heading (should NOT get suppressed)
    '<w:p><w:r><w:t>Some content</w:t></w:r></w:p>',
    '<w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>Methods</w:t></w:r></w:p>',
    # Empty paragraph with bookmarks between it and heading
    '<w:p/>',
    '<w:bookmarkStart w:id="1" w:name="_Toc1"/>',
    '<w:bookmarkEnd w:id="1"/>',
    '<w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>Results</w:t></w:r></w:p>',
    '</w:body>')
  body <- xml2::read_xml(xml_str)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  n <- suppress_pre_heading_line_numbers(body, ns, verbose = FALSE)

  # Should have suppressed 2 empty paragraphs (before Introduction and Results)
  expect_equal(n, 2L)

  # Check the first empty paragraph has suppressLineNumbers
  paras <- xml2::xml_find_all(body, "w:p", ns)
  suppress1 <- xml2::xml_find_first(paras[[1]], "w:pPr/w:suppressLineNumbers", ns)
  expect_false(inherits(suppress1, "xml_missing"))

  # The "Some content" paragraph should NOT have it
  suppress2 <- xml2::xml_find_first(paras[[3]], "w:pPr/w:suppressLineNumbers", ns)
  expect_true(inherits(suppress2, "xml_missing"))

  # The empty paragraph before Results (past bookmarks) should have it
  suppress3 <- xml2::xml_find_first(paras[[5]], "w:pPr/w:suppressLineNumbers", ns)
  expect_false(inherits(suppress3, "xml_missing"))
})
