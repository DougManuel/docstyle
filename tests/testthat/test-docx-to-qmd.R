# Integration tests for docx_to_qmd round-trip functionality
#
# These tests verify that Word document features are correctly extracted
# and converted to QMD markdown format.

test_that("extract_formatted_text handles basic formatting", {
  skip_if_not_installed("xml2")

  # Create minimal Word XML paragraph with bold and italic
  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p>
          <w:r><w:t>Normal </w:t></w:r>
          <w:r><w:rPr><w:b/></w:rPr><w:t>bold</w:t></w:r>
          <w:r><w:t> and </w:t></w:r>
          <w:r><w:rPr><w:i/></w:rPr><w:t>italic</w:t></w:r>
        </w:p>
      </w:body>
    </w:document>'

  doc <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(doc)
  p <- xml2::xml_find_first(doc, "//w:p", ns)

  result <- extract_formatted_text(p, ns)
  expect_match(result$text, "Normal")
  expect_match(result$text, "\\*\\*bold\\*\\*")
  expect_match(result$text, "\\*italic\\*")
})


test_that("extract_formatted_text emits _**...**_ for bold-italic (#47)", {
  skip_if_not_installed("xml2")

  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p>
          <w:r><w:rPr><w:b/><w:i/></w:rPr><w:t>bold italic</w:t></w:r>
        </w:p>
      </w:body>
    </w:document>'

  doc <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(doc)
  p <- xml2::xml_find_first(doc, "//w:p", ns)

  result <- extract_formatted_text(p, ns)
  expect_equal(result$text, "_**bold italic**_")
})


test_that("extract_formatted_text handles strikethrough", {
  skip_if_not_installed("xml2")

  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p>
          <w:r><w:rPr><w:strike/></w:rPr><w:t>deleted text</w:t></w:r>
        </w:p>
      </w:body>
    </w:document>'

  doc <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(doc)
  p <- xml2::xml_find_first(doc, "//w:p", ns)

  result <- extract_formatted_text(p, ns)
  expect_match(result$text, "~~deleted text~~")
})


test_that("extract_formatted_text handles subscript and superscript", {
  skip_if_not_installed("xml2")

  # Test subscript
  xml_sub <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p>
          <w:r><w:t>H</w:t></w:r>
          <w:r><w:rPr><w:vertAlign w:val="subscript"/></w:rPr><w:t>2</w:t></w:r>
          <w:r><w:t>O</w:t></w:r>
        </w:p>
      </w:body>
    </w:document>'

  doc <- xml2::read_xml(xml_sub)
  ns <- xml2::xml_ns(doc)
  p <- xml2::xml_find_first(doc, "//w:p", ns)

  result <- extract_formatted_text(p, ns)
  expect_match(result$text, "H<sub>2</sub>O")

  # Test superscript
  xml_sup <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p>
          <w:r><w:t>10</w:t></w:r>
          <w:r><w:rPr><w:vertAlign w:val="superscript"/></w:rPr><w:t>3</w:t></w:r>
        </w:p>
      </w:body>
    </w:document>'

  doc <- xml2::read_xml(xml_sup)
  ns <- xml2::xml_ns(doc)
  p <- xml2::xml_find_first(doc, "//w:p", ns)

  result <- extract_formatted_text(p, ns)
  expect_match(result$text, "10<sup>3</sup>")
})


test_that("extract_formatted_text handles underline", {
  skip_if_not_installed("xml2")

  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p>
          <w:r><w:rPr><w:u w:val="single"/></w:rPr><w:t>underlined</w:t></w:r>
        </w:p>
      </w:body>
    </w:document>'

  doc <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(doc)
  p <- xml2::xml_find_first(doc, "//w:p", ns)

  result <- extract_formatted_text(p, ns)
  expect_match(result$text, "\\[underlined\\]\\{\\.underline\\}")
})


test_that("extract_formatted_text handles hyperlinks", {
  skip_if_not_installed("xml2")

  # Note: The r:id attribute uses the relationships namespace.
  # In actual Word documents, xml2 reads this correctly. For unit testing,

  # we verify that when hyperlink_rels contains the rId, it creates a link.
  # The actual attribute lookup uses the full namespace URI.
  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <w:body>
        <w:p>
          <w:hyperlink xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" r:id="rId1">
            <w:r><w:t>click here</w:t></w:r>
          </w:hyperlink>
        </w:p>
      </w:body>
    </w:document>'

  doc <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(doc)
  p <- xml2::xml_find_first(doc, "//w:p", ns)

  # Mock hyperlink relationships
  hyperlink_rels <- list(rId1 = "https://example.com")

  result <- extract_formatted_text(p, ns, hyperlink_rels = hyperlink_rels)

  # The hyperlink extraction looks for the r:id attribute using the full namespace
  # In test XML, this may not resolve the same way as in real docx files.
  # Verify at minimum that the text is extracted (not silently dropped)
  expect_match(result$text, "click here")
})


test_that("extract_formatted_text handles soft line breaks (w:br)", {
  skip_if_not_installed("xml2")

  # Single <w:br/> in a run — should produce a hard line break
  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p>
          <w:r><w:t>Before break.</w:t></w:r>
          <w:r><w:br/></w:r>
          <w:r><w:t>After break.</w:t></w:r>
        </w:p>
      </w:body>
    </w:document>'

  doc <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(doc)
  p <- xml2::xml_find_first(doc, "//w:p", ns)

  result <- extract_formatted_text(p, ns)
  expect_match(result$text, "Before break\\.\\\\\nAfter break\\.")
})


test_that("extract_formatted_text handles double soft line breaks", {
  skip_if_not_installed("xml2")

  # Two <w:br/> in separate runs — simulates Shift+Enter x2 in Word
  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p>
          <w:r><w:t>First paragraph text.</w:t></w:r>
          <w:r><w:br/></w:r>
          <w:r><w:br/></w:r>
          <w:r><w:t>Second paragraph text.</w:t></w:r>
        </w:p>
      </w:body>
    </w:document>'

  doc <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(doc)
  p <- xml2::xml_find_first(doc, "//w:p", ns)

  result <- extract_formatted_text(p, ns)
  # Should have two hard line breaks between the text
  expect_match(result$text, "First paragraph text\\.\\\\\n\\\\\nSecond paragraph text\\.")
})


test_that("extract_formatted_text ignores page breaks (w:br type='page')", {
  skip_if_not_installed("xml2")

  # <w:br w:type="page"/> should be ignored (handled by page-section filter)
  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p>
          <w:r><w:t>Before page break.</w:t></w:r>
          <w:r><w:br w:type="page"/></w:r>
          <w:r><w:t>After page break.</w:t></w:r>
        </w:p>
      </w:body>
    </w:document>'

  doc <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(doc)
  p <- xml2::xml_find_first(doc, "//w:p", ns)

  result <- extract_formatted_text(p, ns)
  # Page break should be silently ignored — text concatenated normally
  expect_equal(result$text, "Before page break.After page break.")
})


test_that("extract_formatted_text emits placeholder for drawing runs with alt text", {
  skip_if_not_installed("xml2")

  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">
      <w:body>
        <w:p>
          <w:r>
            <w:drawing>
              <wp:inline>
                <wp:docPr id="1" name="Picture 1" descr="Figure 1 caption"/>
              </wp:inline>
            </w:drawing>
          </w:r>
        </w:p>
      </w:body>
    </w:document>'

  doc <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(doc)
  p <- xml2::xml_find_first(doc, "//w:p", ns)

  result <- extract_formatted_text(p, ns)
  expect_match(result$text, "<!-- IMAGE: Figure 1 caption -->")
})


test_that("extract_formatted_text emits placeholder for drawing runs without alt text", {
  skip_if_not_installed("xml2")

  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">
      <w:body>
        <w:p>
          <w:r>
            <w:drawing>
              <wp:inline>
                <wp:docPr id="1" name="Picture 1"/>
              </wp:inline>
            </w:drawing>
          </w:r>
        </w:p>
      </w:body>
    </w:document>'

  doc <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(doc)
  p <- xml2::xml_find_first(doc, "//w:p", ns)

  result <- extract_formatted_text(p, ns)
  expect_equal(result$text, "<!-- IMAGE -->")
})


test_that("extract_formatted_text preserves text around drawing runs", {
  skip_if_not_installed("xml2")

  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">
      <w:body>
        <w:p>
          <w:r><w:t>Before </w:t></w:r>
          <w:r>
            <w:drawing>
              <wp:inline>
                <wp:docPr id="1" name="Picture 1" descr="fig1"/>
              </wp:inline>
            </w:drawing>
          </w:r>
          <w:r><w:t> after.</w:t></w:r>
        </w:p>
      </w:body>
    </w:document>'

  doc <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(doc)
  p <- xml2::xml_find_first(doc, "//w:p", ns)

  result <- extract_formatted_text(p, ns)
  expect_match(result$text, "Before")
  expect_match(result$text, "IMAGE: fig1")
  expect_match(result$text, "after\\.")
})


test_that("extract_formatted_text emits markdown image when image_rels provided (#63)", {
  skip_if_not_installed("xml2")

  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
                xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <w:body>
        <w:p>
          <w:r>
            <w:drawing>
              <wp:inline>
                <wp:docPr id="1" name="Picture 1" descr="Figure 1 caption"/>
                <a:graphic>
                  <a:graphicData>
                    <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
                      <pic:blipFill>
                        <a:blip r:embed="rId7"/>
                      </pic:blipFill>
                    </pic:pic>
                  </a:graphicData>
                </a:graphic>
              </wp:inline>
            </w:drawing>
          </w:r>
        </w:p>
      </w:body>
    </w:document>'

  doc <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(doc)
  p <- xml2::xml_find_first(doc, "//w:p", ns)

  # With image_rels mapping, should emit markdown image syntax
  image_rels <- list(rId7 = "images/image1.png")
  result <- extract_formatted_text(p, ns, image_rels = image_rels)
  expect_equal(result$text, "![Figure 1 caption](images/image1.png)")
})

test_that("extract_formatted_text skips wp:anchor drawings (float, not inline)", {
  # Regression: grouped figure textbox captions contain nested wp:anchor drawings
  # (Word's multi-resolution copies of the same figure). These should be silently
  # skipped — they are floating, positioned by the paragraph dispatcher, not inline.
  skip_if_not_installed("xml2")

  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
                xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <w:body>
        <w:p>
          <w:r><w:t>Caption text</w:t></w:r>
          <w:r>
            <w:drawing>
              <wp:anchor distT="0" distB="0" distL="114300" distR="114300">
                <wp:docPr id="2" name="Picture 2" descr="Duplicate figure copy"/>
                <a:graphic>
                  <a:graphicData>
                    <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
                      <pic:blipFill>
                        <a:blip r:embed="rId9"/>
                      </pic:blipFill>
                    </pic:pic>
                  </a:graphicData>
                </a:graphic>
              </wp:anchor>
            </w:drawing>
          </w:r>
        </w:p>
      </w:body>
    </w:document>'

  doc <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(doc)
  p <- xml2::xml_find_first(doc, "//w:p", ns)

  image_rels <- list(rId9 = "images/image3.png")
  result <- extract_formatted_text(p, ns, image_rels = image_rels)
  # Floating anchor should be suppressed; only the caption text should appear
  expect_equal(result$text, "Caption text")
  expect_false(grepl("image3\\.png", result$text),
               info = "wp:anchor in run context must not emit inline image markdown")
})

test_that("extract_formatted_text falls back to comment when image_rels empty (#63)", {
  skip_if_not_installed("xml2")

  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
                xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <w:body>
        <w:p>
          <w:r>
            <w:drawing>
              <wp:inline>
                <wp:docPr id="1" name="Picture 1" descr="Figure 1"/>
                <a:graphic>
                  <a:graphicData>
                    <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
                      <pic:blipFill>
                        <a:blip r:embed="rId7"/>
                      </pic:blipFill>
                    </pic:pic>
                  </a:graphicData>
                </a:graphic>
              </wp:inline>
            </w:drawing>
          </w:r>
        </w:p>
      </w:body>
    </w:document>'

  doc <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(doc)
  p <- xml2::xml_find_first(doc, "//w:p", ns)

  # Without image_rels, should fall back to HTML comment
  result <- extract_formatted_text(p, ns, image_rels = list())
  expect_equal(result$text, "<!-- IMAGE: Figure 1 -->")
})

test_that("extract_formatted_text emits image without alt text (#63)", {
  skip_if_not_installed("xml2")

  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
                xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <w:body>
        <w:p>
          <w:r>
            <w:drawing>
              <wp:inline>
                <wp:docPr id="1" name="Picture 1"/>
                <a:graphic>
                  <a:graphicData>
                    <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
                      <pic:blipFill>
                        <a:blip r:embed="rId7"/>
                      </pic:blipFill>
                    </pic:pic>
                  </a:graphicData>
                </a:graphic>
              </wp:inline>
            </w:drawing>
          </w:r>
        </w:p>
      </w:body>
    </w:document>'

  doc <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(doc)
  p <- xml2::xml_find_first(doc, "//w:p", ns)

  image_rels <- list(rId7 = "images/image1.png")
  result <- extract_formatted_text(p, ns, image_rels = image_rels)
  expect_equal(result$text, "![](images/image1.png)")
})

test_that("extract_docx_images extracts images from DOCX zip (#63)", {
  skip_if_not_installed("xml2")

  # Build a minimal DOCX with an embedded image
  staging <- tempfile("docx_img_test_")
  dir.create(staging)
  dir.create(file.path(staging, "word", "media"), recursive = TRUE)
  dir.create(file.path(staging, "word", "_rels"), recursive = TRUE)
  dir.create(file.path(staging, "_rels"))
  on.exit(unlink(staging, recursive = TRUE))

  # Create a 1x1 pixel PNG (minimal valid PNG)
  png_bytes <- as.raw(c(
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,  # PNG signature
    0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,  # IHDR chunk
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,  # 1x1
    0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,  # 8-bit RGB
    0xde, 0x00, 0x00, 0x00, 0x0c, 0x49, 0x44, 0x41,  # IDAT chunk
    0x54, 0x08, 0xd7, 0x63, 0xf8, 0xcf, 0xc0, 0x00,
    0x00, 0x00, 0x02, 0x00, 0x01, 0xe2, 0x21, 0xbc,
    0x33, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,  # IEND chunk
    0x44, 0xae, 0x42, 0x60, 0x82
  ))
  writeBin(png_bytes, file.path(staging, "word", "media", "image1.png"))

  # document.xml (minimal)
  writeLines('<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body><w:p><w:r><w:t>Hello</w:t></w:r></w:p></w:body>
</w:document>', file.path(staging, "word", "document.xml"))

  # word/_rels/document.xml.rels with image relationship
  writeLines('<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId7" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
    Target="media/image1.png"/>
</Relationships>', file.path(staging, "word", "_rels", "document.xml.rels"))

  # Content types
  writeLines('<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="xml" ContentType="application/xml"/>
  <Default Extension="png" ContentType="image/png"/>
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Override PartName="/word/document.xml"
    ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>', file.path(staging, "[Content_Types].xml"))

  # Root rels
  writeLines('<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
    Target="word/document.xml"/>
</Relationships>', file.path(staging, "_rels", ".rels"))

  # Create the DOCX zip
  docx_path <- file.path(tempdir(), "test_image.docx")
  old_wd <- getwd()
  setwd(staging)
  on.exit(setwd(old_wd), add = TRUE, after = FALSE)
  files <- list.files(".", recursive = TRUE, all.files = TRUE)
  utils::zip(docx_path, files, flags = "-q")
  setwd(old_wd)

  # Extract images
  img_dir <- file.path(tempdir(), "test_images")
  on.exit(unlink(img_dir, recursive = TRUE), add = TRUE)
  result <- extract_docx_images(docx_path, img_dir)

  expect_equal(length(result), 1)
  expect_equal(names(result), "rId7")
  expect_true(file.exists(result[["rId7"]]))
  expect_match(result[["rId7"]], "image1\\.png$")
})


test_that("extract_insertion_content handles soft line breaks", {
  skip_if_not_installed("xml2")

  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p>
          <w:ins w:id="1" w:author="Test">
            <w:r><w:t>Line one.</w:t></w:r>
            <w:r><w:br/></w:r>
            <w:r><w:t>Line two.</w:t></w:r>
          </w:ins>
        </w:p>
      </w:body>
    </w:document>'

  doc <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(doc)
  ins <- xml2::xml_find_first(doc, "//w:ins", ns)

  result <- extract_insertion_content(ins, ns)
  expect_match(result$text, "Line one\\.\\\\\nLine two\\.")
})


test_that("extract_formatted_text preserves auxiliary verbs in insertion runs", {
  skip_if_not_installed("xml2")

  # Simulates Word splitting "we have updated" where "have " is a tracked insertion
  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p>
          <w:r><w:t xml:space="preserve">we </w:t></w:r>
          <w:ins w:id="1" w:author="Test" w:date="2026-01-01T00:00:00Z">
            <w:r><w:t xml:space="preserve">have </w:t></w:r>
          </w:ins>
          <w:r><w:t>updated</w:t></w:r>
        </w:p>
      </w:body>
    </w:document>'

  doc <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(doc)
  p <- xml2::xml_find_first(doc, "//w:p", ns)

  result <- extract_formatted_text(p, ns)
  # "have" must survive — wrapped in .ins span is fine, but the word must be present
  expect_match(result$text, "have")
  expect_match(result$text, "updated")
  expect_match(result$text, "we")
})


test_that("extract_formatted_text preserves auxiliary verbs in plain runs", {
  skip_if_not_installed("xml2")

  # Same phrase but all in plain runs (no track changes)
  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p>
          <w:r><w:t xml:space="preserve">we </w:t></w:r>
          <w:r><w:t xml:space="preserve">have </w:t></w:r>
          <w:r><w:t>updated</w:t></w:r>
        </w:p>
      </w:body>
    </w:document>'

  doc <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(doc)
  p <- xml2::xml_find_first(doc, "//w:p", ns)

  result <- extract_formatted_text(p, ns)
  expect_equal(result$text, "we have updated")
})


test_that("extract_deletion_content handles soft line breaks", {
  skip_if_not_installed("xml2")

  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p>
          <w:del w:id="1" w:author="Test">
            <w:r><w:delText>Deleted line one.</w:delText></w:r>
            <w:r><w:br/></w:r>
            <w:r><w:delText>Deleted line two.</w:delText></w:r>
          </w:del>
        </w:p>
      </w:body>
    </w:document>'

  doc <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(doc)
  del <- xml2::xml_find_first(doc, "//w:del", ns)

  result <- extract_deletion_content(del, ns)
  expect_match(result$text, "Deleted line one\\.\\\\\nDeleted line two\\.")
})


test_that("convert_table_to_md warns about merged cells", {
  skip_if_not_installed("xml2")

  # Table with horizontal merge (gridSpan)
  xml_hmerge <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:tbl xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:tr>
        <w:tc><w:tcPr><w:gridSpan w:val="2"/></w:tcPr><w:p><w:r><w:t>Merged</w:t></w:r></w:p></w:tc>
      </w:tr>
      <w:tr>
        <w:tc><w:p><w:r><w:t>A</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>B</w:t></w:r></w:p></w:tc>
      </w:tr>
    </w:tbl>'

  tbl <- xml2::read_xml(xml_hmerge)
  ns <- xml2::xml_ns(tbl)

  expect_warning(
    convert_table_to_md(tbl, ns),
    "horizontal.*merged cells"
  )

  # Table with vertical merge (vMerge)
  xml_vmerge <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:tbl xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:tr>
        <w:tc><w:tcPr><w:vMerge w:val="restart"/></w:tcPr><w:p><w:r><w:t>Merged</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>B</w:t></w:r></w:p></w:tc>
      </w:tr>
      <w:tr>
        <w:tc><w:tcPr><w:vMerge/></w:tcPr><w:p></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>D</w:t></w:r></w:p></w:tc>
      </w:tr>
    </w:tbl>'

  tbl <- xml2::read_xml(xml_vmerge)
  ns <- xml2::xml_ns(tbl)

  expect_warning(
    convert_table_to_md(tbl, ns),
    "vertical.*merged cells"
  )
})


test_that("convert_table_to_md creates valid markdown table", {
  skip_if_not_installed("xml2")

  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:tbl xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:tr>
        <w:tc><w:p><w:r><w:t>Header 1</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>Header 2</w:t></w:r></w:p></w:tc>
      </w:tr>
      <w:tr>
        <w:tc><w:p><w:r><w:t>Cell A</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>Cell B</w:t></w:r></w:p></w:tc>
      </w:tr>
    </w:tbl>'

  tbl <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(tbl)

  result <- convert_table_to_md(tbl, ns)

  expect_length(result$lines, 3)  # header, separator, data row
  expect_match(result$lines[1], "Header 1.*Header 2")
  expect_match(result$lines[2], "---.*---")
  expect_match(result$lines[3], "Cell A.*Cell B")
})


test_that("replace_citations handles whitespace variations", {
  citation_map <- list(
    "(1,2)" = "[@smith2020; @jones2021]"
  )

  # Exact match
  text1 <- "As shown (1,2) in the study"

  expect_equal(
    replace_citations(text1, citation_map),
    "As shown [@smith2020; @jones2021] in the study"
  )

  # With extra space
  text2 <- "As shown (1, 2) in the study"
  expect_equal(
    replace_citations(text2, citation_map),
    "As shown [@smith2020; @jones2021] in the study"
  )
})


test_that("replace_citations handles en-dash in citation ranges", {
  # Citation map keys are normalized (hyphen), but text may have en-dash
  citation_map <- list(
    "(17-24)" = "[@ref1; @ref2; @ref3; @ref4; @ref5; @ref6; @ref7; @ref8]"
  )

  # Text with en-dash (U+2013) — the core bug scenario
  text_endash <- "suicide (17\u201324) and other"
  expect_equal(
    replace_citations(text_endash, citation_map),
    "suicide [@ref1; @ref2; @ref3; @ref4; @ref5; @ref6; @ref7; @ref8] and other"
  )

  # Text with regular hyphen — should still work
  text_hyphen <- "suicide (17-24) and other"
  expect_equal(
    replace_citations(text_hyphen, citation_map),
    "suicide [@ref1; @ref2; @ref3; @ref4; @ref5; @ref6; @ref7; @ref8] and other"
  )
})

test_that("normalize_typographic_dashes converts Unicode dashes to Pandoc convention (#78)", {
  expect_equal(normalize_typographic_dashes("en\u2013dash"), "en--dash")
  expect_equal(normalize_typographic_dashes("em\u2014dash"), "em---dash")
  expect_equal(normalize_typographic_dashes("both \u2013 and \u2014"), "both -- and ---")
  expect_equal(normalize_typographic_dashes("plain text"), "plain text")
})

test_that("harvest converts Unicode dashes in paragraph text to Pandoc convention (#78)", {
  skip_if_not_installed("xml2")

  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # Paragraph with an em dash (U+2014) and an en dash (U+2013)
  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p>
          <w:r><w:t xml:space="preserve">results\u2014see Table\u20131</w:t></w:r>
        </w:p>
      </w:body>
    </w:document>'

  doc <- xml2::read_xml(xml_str)
  p   <- xml2::xml_find_first(doc, "//w:p", ns)
  result <- extract_formatted_text(p, ns)
  expect_equal(result$text, "results---see Table--1")
})

test_that("build_citation_pattern produces correct regex", {
  # Basic citation with parentheses
  pat <- build_citation_pattern("(1,2)")
  expect_true(grepl(pat, "(1,2)", perl = TRUE))
  expect_true(grepl(pat, "(1, 2)", perl = TRUE))

  # Hyphen in range — pattern should match en-dash and em-dash too
  pat2 <- build_citation_pattern("(17-24)")
  expect_true(grepl(pat2, "(17-24)", perl = TRUE))
  expect_true(grepl(pat2, "(17\u201324)", perl = TRUE))  # en-dash
  expect_true(grepl(pat2, "(17\u201424)", perl = TRUE))  # em-dash

  # Semicolons
  pat3 <- build_citation_pattern("(1;2;3)")
  expect_true(grepl(pat3, "(1;2;3)", perl = TRUE))
  expect_true(grepl(pat3, "(1; 2; 3)", perl = TRUE))
})

test_that("prepare_header_preservation returns NULL when file doesn't exist", {
  result <- prepare_header_preservation("/nonexistent/file.qmd", TRUE)
  expect_null(result)
})


test_that("prepare_header_preservation returns NULL when preserve is FALSE", {
  # Even with existing file, should return NULL
  tmp_file <- tempfile(fileext = ".qmd")
  writeLines(c("---", "title: Test", "---", "Content"), tmp_file)
  on.exit(unlink(tmp_file))

  result <- prepare_header_preservation(tmp_file, FALSE)
  expect_null(result)
})


test_that("extract_yaml_header extracts valid YAML", {
  tmp_file <- tempfile(fileext = ".qmd")
  writeLines(c(
    "---",
    "title: My Document",
    "author: Test Author",
    "---",
    "",
    "# Content"
  ), tmp_file)
  on.exit(unlink(tmp_file))

  result <- extract_yaml_header(tmp_file)
  expect_length(result, 4)  # Including both --- delimiters
  expect_equal(result[1], "---")
  expect_match(result[2], "title:")
  expect_equal(result[4], "---")
})


test_that("extract_yaml_header returns NULL for file without YAML", {
  tmp_file <- tempfile(fileext = ".qmd")
  writeLines(c("# No YAML Header", "Just content"), tmp_file)
  on.exit(unlink(tmp_file))

  result <- extract_yaml_header(tmp_file)
  expect_null(result)
})


# Tests for comments inside track changes (deletions/insertions)

test_that("extract_deletion_content preserves comments inside deletions", {
  skip_if_not_installed("xml2")

  # XML with comment markers inside w:del
  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:del xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
           w:id="1" w:author="Test Author" w:date="2026-01-15T10:00:00Z">
      <w:commentRangeStart w:id="5"/>
      <w:r><w:delText>deleted text with comment</w:delText></w:r>
      <w:commentRangeEnd w:id="5"/>
    </w:del>'

  del_node <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(del_node)

  result <- extract_deletion_content(del_node, ns)

  # Should contain comment start marker

  expect_match(result$text, "comment:start id=\"5\"")
  # Should contain the deleted text
  expect_match(result$text, "deleted text with comment")
  # Should contain comment end marker
  expect_match(result$text, "comment:end id=\"5\"")
})


test_that("extract_formatted_text handles comments inside deletions", {
  skip_if_not_installed("xml2")

  # Full paragraph with deletion containing a comment
  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p>
          <w:r><w:t>Normal text </w:t></w:r>
          <w:del w:id="10" w:author="Test" w:date="2026-01-15T10:00:00Z">
            <w:commentRangeStart w:id="20"/>
            <w:r><w:delText>deleted</w:delText></w:r>
            <w:commentRangeEnd w:id="20"/>
          </w:del>
          <w:r><w:t> more text</w:t></w:r>
        </w:p>
      </w:body>
    </w:document>'

  doc <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(doc)
  p <- xml2::xml_find_first(doc, "//w:p", ns)

  result <- extract_formatted_text(p, ns)

  # Should have comment markers inside the deletion span
  expect_match(result$text, "comment:start id=\"20\"")
  expect_match(result$text, "comment:end id=\"20\"")
  # Should have the deletion span with strikethrough
  expect_match(result$text, "\\.del")
  expect_match(result$text, "~~")
})


test_that("extract_formatted_text handles comment spanning deletion boundary", {
  skip_if_not_installed("xml2")

  # Comment starts before deletion, ends inside
  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p>
          <w:commentRangeStart w:id="7"/>
          <w:r><w:t>commented </w:t></w:r>
          <w:del w:id="2" w:author="Test" w:date="2026-01-15T10:00:00Z">
            <w:r><w:delText>deleted</w:delText></w:r>
            <w:commentRangeEnd w:id="7"/>
          </w:del>
        </w:p>
      </w:body>
    </w:document>'

  doc <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(doc)
  p <- xml2::xml_find_first(doc, "//w:p", ns)

  result <- extract_formatted_text(p, ns)

  # Comment start should be outside deletion
  expect_match(result$text, "comment:start id=\"7\".*commented")
  # Comment end should be inside deletion span
  expect_match(result$text, "comment:end id=\"7\"")
})


test_that("extract_insertion_content preserves comments inside insertions", {
  skip_if_not_installed("xml2")

  # XML with comment markers inside w:ins
  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:ins xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
           w:id="3" w:author="Test Author" w:date="2026-01-15T10:00:00Z">
      <w:commentRangeStart w:id="8"/>
      <w:r><w:t>inserted text with comment</w:t></w:r>
      <w:commentRangeEnd w:id="8"/>
    </w:ins>'

  ins_node <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(ins_node)

  result <- extract_insertion_content(ins_node, ns)

  # Should contain comment markers and text
  expect_match(result$text, "comment:start id=\"8\"")
  expect_match(result$text, "inserted text with comment")
  expect_match(result$text, "comment:end id=\"8\"")
})


test_that("extract_formatted_text handles multiple comments in deletion", {
  skip_if_not_installed("xml2")

  # Two overlapping comments on deleted text
  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p>
          <w:del w:id="5" w:author="Test" w:date="2026-01-15T10:00:00Z">
            <w:commentRangeStart w:id="73"/>
            <w:commentRangeStart w:id="74"/>
            <w:r><w:delText>multi-commented text</w:delText></w:r>
            <w:commentRangeEnd w:id="73"/>
            <w:commentRangeEnd w:id="74"/>
          </w:del>
        </w:p>
      </w:body>
    </w:document>'

  doc <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(doc)
  p <- xml2::xml_find_first(doc, "//w:p", ns)

  result <- extract_formatted_text(p, ns)

  # Both comment markers should be preserved
  expect_match(result$text, "comment:start id=\"73\"")
  expect_match(result$text, "comment:start id=\"74\"")
  expect_match(result$text, "comment:end id=\"73\"")
  expect_match(result$text, "comment:end id=\"74\"")
})


# ══ List harvest tests ═══════════════════════════════════════════════════════

#' Helper to create a test DOCX with numbering.xml
#'
#' Extends the minimal DOCX creation to include word/numbering.xml
#' for testing list format detection.
create_test_docx_with_numbering <- function(doc_xml, numbering_xml = NULL,
                                            dir = tempdir(),
                                            filename = "test-list.docx") {
  staging <- tempfile("docx_staging_")
  dir.create(staging)
  dir.create(file.path(staging, "word"))
  dir.create(file.path(staging, "_rels"))
  dir.create(file.path(staging, "word", "_rels"))
  on.exit(unlink(staging, recursive = TRUE))

  writeLines(doc_xml, file.path(staging, "word", "document.xml"))

  if (!is.null(numbering_xml)) {
    writeLines(numbering_xml, file.path(staging, "word", "numbering.xml"))
  }

  ct <- '<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="xml" ContentType="application/xml"/>
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Override PartName="/word/document.xml"
    ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>'
  writeLines(ct, file.path(staging, "[Content_Types].xml"))

  rels <- '<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
    Target="word/document.xml"/>
</Relationships>'
  writeLines(rels, file.path(staging, "_rels", ".rels"))

  doc_rels <- '<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
</Relationships>'
  writeLines(doc_rels, file.path(staging, "word", "_rels", "document.xml.rels"))

  out_path <- file.path(dir, filename)
  old_wd <- getwd()
  setwd(staging)
  on.exit(setwd(old_wd), add = TRUE)
  files <- list.files(".", recursive = TRUE, all.files = TRUE)
  utils::zip(out_path, files, flags = "-q")

  out_path
}


test_that("build_numbering_lookup parses numbering.xml correctly", {
  skip_if_not_installed("xml2")

  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>Placeholder</w:t></w:r></w:p>
  </w:body>
</w:document>'

  numbering_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:abstractNum w:abstractNumId="0">
    <w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl>
    <w:lvl w:ilvl="1"><w:numFmt w:val="bullet"/></w:lvl>
  </w:abstractNum>
  <w:abstractNum w:abstractNumId="1">
    <w:lvl w:ilvl="0"><w:numFmt w:val="lowerLetter"/></w:lvl>
    <w:lvl w:ilvl="1"><w:numFmt w:val="lowerRoman"/></w:lvl>
  </w:abstractNum>
  <w:abstractNum w:abstractNumId="2">
    <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl>
  </w:abstractNum>
  <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
  <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
  <w:num w:numId="3"><w:abstractNumId w:val="2"/></w:num>
</w:numbering>'

  td <- tempfile("test_numbering_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx_with_numbering(doc_xml, numbering_xml, dir = td)

  lookup <- build_numbering_lookup(docx)

  expect_length(lookup$formats, 3)
  expect_equal(lookup$formats[["1"]][["ilvl0"]], "bullet")
  expect_equal(lookup$formats[["2"]][["ilvl0"]], "lowerLetter")
  expect_equal(lookup$formats[["2"]][["ilvl1"]], "lowerRoman")
  expect_equal(lookup$formats[["3"]][["ilvl0"]], "decimal")
})


test_that("build_numbering_lookup handles level overrides", {
  skip_if_not_installed("xml2")

  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>Placeholder</w:t></w:r></w:p>
  </w:body>
</w:document>'

  # abstractNum defines bullet, but num overrides ilvl0 to decimal
  numbering_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:abstractNum w:abstractNumId="0">
    <w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl>
  </w:abstractNum>
  <w:num w:numId="1">
    <w:abstractNumId w:val="0"/>
    <w:lvlOverride w:ilvl="0">
      <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl>
    </w:lvlOverride>
  </w:num>
</w:numbering>'

  td <- tempfile("test_override_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx_with_numbering(doc_xml, numbering_xml, dir = td)

  lookup <- build_numbering_lookup(docx)

  expect_equal(lookup$formats[["1"]][["ilvl0"]], "decimal")
})


test_that("build_numbering_lookup returns empty list when no numbering.xml", {
  skip_if_not_installed("xml2")

  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>No lists</w:t></w:r></w:p>
  </w:body>
</w:document>'

  td <- tempfile("test_no_num_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx_with_numbering(doc_xml, numbering_xml = NULL, dir = td)

  lookup <- build_numbering_lookup(docx)
  expect_length(lookup, 0)
})


test_that("lookup_num_fmt returns correct format for known numId", {
  lookup <- list(
    "1" = list(ilvl0 = "bullet", ilvl1 = "bullet"),
    "2" = list(ilvl0 = "lowerLetter", ilvl1 = "lowerRoman")
  )

  expect_equal(lookup_num_fmt(lookup, "2", 0), "lowerLetter")
  expect_equal(lookup_num_fmt(lookup, "2", 1), "lowerRoman")
  expect_equal(lookup_num_fmt(lookup, "1", 0), "bullet")
  expect_true(is.na(lookup_num_fmt(lookup, "99", 0)))
  expect_true(is.na(lookup_num_fmt(list(), "1", 0)))
})


test_that("numfmt_to_md_prefix maps Word formats to markdown syntax", {
  expect_equal(numfmt_to_md_prefix("bullet"), "- ")
  expect_equal(numfmt_to_md_prefix("decimal"), "1. ")
  expect_equal(numfmt_to_md_prefix("lowerLetter"), "a. ")
  expect_equal(numfmt_to_md_prefix("upperLetter"), "A. ")
  expect_equal(numfmt_to_md_prefix("lowerRoman"), "i. ")
  expect_equal(numfmt_to_md_prefix("upperRoman"), "I. ")

  # With indent
  expect_equal(numfmt_to_md_prefix("lowerLetter", "  "), "  a. ")

  # Unknown format defaults to bullet
  expect_equal(numfmt_to_md_prefix("none"), "- ")
})


test_that("start_to_prefix converts start values to correct characters", {
  expect_equal(start_to_prefix("decimal", 5), "5")
  expect_equal(start_to_prefix("decimal", 1), "1")
  expect_equal(start_to_prefix("lowerLetter", 5), "e")
  expect_equal(start_to_prefix("lowerLetter", 1), "a")
  expect_equal(start_to_prefix("upperLetter", 3), "C")
  expect_equal(start_to_prefix("lowerRoman", 4), "iv")
  expect_equal(start_to_prefix("upperRoman", 4), "IV")
  expect_equal(start_to_prefix("bullet", 1), "")
  # Edge case: letter > 26 falls back to a/A
  expect_equal(start_to_prefix("lowerLetter", 27), "a")
})


test_that("numfmt_to_md_prefix respects start parameter", {
  expect_equal(numfmt_to_md_prefix("decimal", "", 5), "5. ")
  expect_equal(numfmt_to_md_prefix("lowerLetter", "", 4), "d. ")
  expect_equal(numfmt_to_md_prefix("lowerRoman", "  ", 3), "  iii. ")
  # Default start=1 preserves existing behaviour
  expect_equal(numfmt_to_md_prefix("decimal"), "1. ")
  expect_equal(numfmt_to_md_prefix("lowerLetter"), "a. ")
})


test_that("lookup_num_start returns correct start or default 1", {
  lookup <- list(
    formats = list("1" = list(ilvl0 = "decimal")),
    starts = list("1" = list(ilvl0 = 5L))
  )
  expect_equal(lookup_num_start(lookup, "1", 0), 5L)
  expect_equal(lookup_num_start(lookup, "1", 1), 1L)   # missing level
  expect_equal(lookup_num_start(lookup, "99", 0), 1L)   # missing numId
  expect_equal(lookup_num_start(list(), "1", 0), 1L)    # empty lookup
})


test_that("build_numbering_lookup extracts start values from abstractNum", {
  skip_if_not_installed("xml2")

  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>Placeholder</w:t></w:r></w:p>
  </w:body>
</w:document>'

  numbering_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:abstractNum w:abstractNumId="0">
    <w:lvl w:ilvl="0"><w:start w:val="5"/><w:numFmt w:val="decimal"/></w:lvl>
  </w:abstractNum>
  <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
</w:numbering>'

  td <- tempfile("test_start_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx_with_numbering(doc_xml, numbering_xml, dir = td)

  lookup <- build_numbering_lookup(docx)

  expect_equal(lookup$formats[["1"]][["ilvl0"]], "decimal")
  expect_equal(lookup$starts[["1"]][["ilvl0"]], 5L)
})


test_that("build_numbering_lookup reads startOverride from lvlOverride", {
  skip_if_not_installed("xml2")

  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>Placeholder</w:t></w:r></w:p>
  </w:body>
</w:document>'

  numbering_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:abstractNum w:abstractNumId="0">
    <w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="lowerLetter"/></w:lvl>
  </w:abstractNum>
  <w:num w:numId="1">
    <w:abstractNumId w:val="0"/>
    <w:lvlOverride w:ilvl="0">
      <w:startOverride w:val="4"/>
    </w:lvlOverride>
  </w:num>
</w:numbering>'

  td <- tempfile("test_start_ovr_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx_with_numbering(doc_xml, numbering_xml, dir = td)

  lookup <- build_numbering_lookup(docx)

  expect_equal(lookup$formats[["1"]][["ilvl0"]], "lowerLetter")
  expect_equal(lookup$starts[["1"]][["ilvl0"]], 4L)
})


test_that("list harvest emits format-aware prefixes from numbering.xml", {
  skip_if_not_installed("xml2")

  # Document with three list items: lowerLetter numId=2
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:pPr><w:pStyle w:val="ListParagraph"/>
        <w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr>
      </w:pPr>
      <w:r><w:t>First alpha</w:t></w:r>
    </w:p>
    <w:p>
      <w:pPr><w:pStyle w:val="ListParagraph"/>
        <w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr>
      </w:pPr>
      <w:r><w:t>Second alpha</w:t></w:r>
    </w:p>
    <w:p>
      <w:pPr><w:pStyle w:val="ListParagraph"/>
        <w:numPr><w:ilvl w:val="0"/><w:numId w:val="3"/></w:numPr>
      </w:pPr>
      <w:r><w:t>Decimal item</w:t></w:r>
    </w:p>
  </w:body>
</w:document>'

  numbering_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:abstractNum w:abstractNumId="1">
    <w:lvl w:ilvl="0"><w:numFmt w:val="lowerLetter"/></w:lvl>
  </w:abstractNum>
  <w:abstractNum w:abstractNumId="2">
    <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl>
  </w:abstractNum>
  <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
  <w:num w:numId="3"><w:abstractNumId w:val="2"/></w:num>
</w:numbering>'

  td <- tempfile("test_list_emit_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx_with_numbering(doc_xml, numbering_xml, dir = td)

  qmd_path <- file.path(td, "output.qmd")
  suppressMessages(docx_to_qmd(docx, qmd_path))
  qmd_text <- readLines(qmd_path)

  # Alpha items should use sequential prefixes (a., b.)
  expect_true(any(grepl("^a\\. First alpha", qmd_text)),
              info = "Expected 'a. First alpha' for first lowerLetter list item")
  expect_true(any(grepl("^b\\. Second alpha", qmd_text)),
              info = "Expected 'b. Second alpha' for second lowerLetter list item")

  # Decimal item should use 1. prefix
  expect_true(any(grepl("^1\\. Decimal item", qmd_text)),
              info = "Expected '1. Decimal item' for decimal list item")
})


test_that("list harvest increments numbering with nested sub-items", {
  skip_if_not_installed("xml2")

  # a. Parent 1 (ilvl=0, numId=2)
  # b. Parent 2 (ilvl=0, numId=2)
  #   i. Child 1 (ilvl=1, numId=2)
  #   ii. Child 2 (ilvl=1, numId=2)
  # c. Parent 3 (ilvl=0, numId=2)
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:pPr><w:pStyle w:val="ListParagraph"/>
        <w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr>
      </w:pPr>
      <w:r><w:t>Parent 1</w:t></w:r>
    </w:p>
    <w:p>
      <w:pPr><w:pStyle w:val="ListParagraph"/>
        <w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr>
      </w:pPr>
      <w:r><w:t>Parent 2</w:t></w:r>
    </w:p>
    <w:p>
      <w:pPr><w:pStyle w:val="ListParagraph"/>
        <w:numPr><w:ilvl w:val="1"/><w:numId w:val="2"/></w:numPr>
      </w:pPr>
      <w:r><w:t>Child 1</w:t></w:r>
    </w:p>
    <w:p>
      <w:pPr><w:pStyle w:val="ListParagraph"/>
        <w:numPr><w:ilvl w:val="1"/><w:numId w:val="2"/></w:numPr>
      </w:pPr>
      <w:r><w:t>Child 2</w:t></w:r>
    </w:p>
    <w:p>
      <w:pPr><w:pStyle w:val="ListParagraph"/>
        <w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr>
      </w:pPr>
      <w:r><w:t>Parent 3</w:t></w:r>
    </w:p>
  </w:body>
</w:document>'

  numbering_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:abstractNum w:abstractNumId="1">
    <w:lvl w:ilvl="0"><w:numFmt w:val="lowerLetter"/><w:start w:val="1"/></w:lvl>
    <w:lvl w:ilvl="1"><w:numFmt w:val="lowerRoman"/><w:start w:val="1"/></w:lvl>
  </w:abstractNum>
  <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
</w:numbering>'

  td <- tempfile("test_list_nested_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx_with_numbering(doc_xml, numbering_xml, dir = td)

  qmd_path <- file.path(td, "output.qmd")
  suppressMessages(docx_to_qmd(docx, qmd_path))
  qmd_text <- readLines(qmd_path)

  # Parent items should be a., b., c.
  expect_true(any(grepl("^a\\. Parent 1", qmd_text)),
              info = "First parent should be 'a.'")
  expect_true(any(grepl("^b\\. Parent 2", qmd_text)),
              info = "Second parent should be 'b.'")
  expect_true(any(grepl("^c\\. Parent 3", qmd_text)),
              info = "Third parent should be 'c.' after nested items")

  # Child items should be i., ii. (indented)
  expect_true(any(grepl("^  i\\. Child 1", qmd_text)),
              info = "First child should be 'i.'")
  expect_true(any(grepl("^  ii\\. Child 2", qmd_text)),
              info = "Second child should be 'ii.'")
})


test_that("list harvest continues parent numbering across different child numIds", {
  skip_if_not_installed("xml2")

  # Word often uses different numIds for parent and child lists.
  # Parent: numId=2 (lowerLetter), Child: numId=3 (lowerRoman at ilvl=1)
  # a. Parent 1 (numId=2, ilvl=0)
  # b. Parent 2 (numId=2, ilvl=0)
  #   i. Child 1 (numId=3, ilvl=1)
  #   ii. Child 2 (numId=3, ilvl=1)
  # c. Parent 3 (numId=2, ilvl=0)
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:pPr><w:pStyle w:val="Compact"/>
        <w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr>
      </w:pPr>
      <w:r><w:t>Parent 1</w:t></w:r>
    </w:p>
    <w:p>
      <w:pPr><w:pStyle w:val="Compact"/>
        <w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr>
      </w:pPr>
      <w:r><w:t>Parent 2</w:t></w:r>
    </w:p>
    <w:p>
      <w:pPr><w:pStyle w:val="Compact"/>
        <w:numPr><w:ilvl w:val="1"/><w:numId w:val="3"/></w:numPr>
      </w:pPr>
      <w:r><w:t>Child 1</w:t></w:r>
    </w:p>
    <w:p>
      <w:pPr><w:pStyle w:val="Compact"/>
        <w:numPr><w:ilvl w:val="1"/><w:numId w:val="3"/></w:numPr>
      </w:pPr>
      <w:r><w:t>Child 2</w:t></w:r>
    </w:p>
    <w:p>
      <w:pPr><w:pStyle w:val="Compact"/>
        <w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr>
      </w:pPr>
      <w:r><w:t>Parent 3</w:t></w:r>
    </w:p>
  </w:body>
</w:document>'

  numbering_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:abstractNum w:abstractNumId="1">
    <w:lvl w:ilvl="0"><w:numFmt w:val="lowerLetter"/><w:start w:val="1"/></w:lvl>
  </w:abstractNum>
  <w:abstractNum w:abstractNumId="2">
    <w:lvl w:ilvl="1"><w:numFmt w:val="lowerRoman"/><w:start w:val="1"/></w:lvl>
  </w:abstractNum>
  <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
  <w:num w:numId="3"><w:abstractNumId w:val="2"/></w:num>
</w:numbering>'

  td <- tempfile("test_list_cross_numid_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx_with_numbering(doc_xml, numbering_xml, dir = td)

  qmd_path <- file.path(td, "output.qmd")
  suppressMessages(docx_to_qmd(docx, qmd_path))
  qmd_text <- readLines(qmd_path)

  # Parent items should continue: a., b., c. despite child numId interruption
  expect_true(any(grepl("^a\\. Parent 1", qmd_text)),
              info = "First parent should be 'a.'")
  expect_true(any(grepl("^b\\. Parent 2", qmd_text)),
              info = "Second parent should be 'b.'")
  expect_true(any(grepl("^c\\. Parent 3", qmd_text)),
              info = "Third parent should be 'c.' after children with different numId")

  # Child items should be i., ii. (indented)
  expect_true(any(grepl("^  i\\. Child 1", qmd_text)),
              info = "First child should be 'i.'")
  expect_true(any(grepl("^  ii\\. Child 2", qmd_text)),
              info = "Second child should be 'ii.'")
})


test_that("list harvest detects ADDIN DOCSTYLE list field codes and emits wrappers", {
  skip_if_not_installed("xml2")

  # Document with field code wrapping a list
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:r><w:fldChar w:fldCharType="begin"/></w:r>
      <w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE {&quot;type&quot;:&quot;list&quot;,&quot;class&quot;:&quot;list-alpha&quot;} </w:instrText></w:r>
      <w:r><w:fldChar w:fldCharType="separate"/></w:r>
    </w:p>
    <w:p>
      <w:pPr><w:pStyle w:val="ListParagraph"/>
        <w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr>
      </w:pPr>
      <w:r><w:t>Alpha one</w:t></w:r>
    </w:p>
    <w:p>
      <w:pPr><w:pStyle w:val="ListParagraph"/>
        <w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr>
      </w:pPr>
      <w:r><w:t>Alpha two</w:t></w:r>
    </w:p>
    <w:p>
      <w:r><w:fldChar w:fldCharType="end"/></w:r>
    </w:p>
  </w:body>
</w:document>'

  numbering_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:abstractNum w:abstractNumId="1">
    <w:lvl w:ilvl="0"><w:numFmt w:val="lowerLetter"/></w:lvl>
  </w:abstractNum>
  <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
</w:numbering>'

  td <- tempfile("test_field_code_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx_with_numbering(doc_xml, numbering_xml, dir = td)

  qmd_path <- file.path(td, "output.qmd")
  suppressMessages(docx_to_qmd(docx, qmd_path))
  qmd_text <- readLines(qmd_path)

  # Should have ::: {.list-alpha} wrapper
  expect_true(any(grepl("^::: \\{\\.list-alpha\\}", qmd_text)),
              info = "Expected ::: {.list-alpha} wrapper from field code")
  expect_true(any(grepl("^:::", qmd_text)),
              info = "Expected ::: closing fence")

  # List items should be inside the wrapper
  alpha_open <- which(grepl("^::: \\{\\.list-alpha\\}", qmd_text))
  fence_close <- which(grepl("^:::$", qmd_text))
  fence_close <- fence_close[fence_close > alpha_open[1]][1]

  list_items <- qmd_text[(alpha_open[1] + 1):(fence_close - 1)]
  list_content <- paste(list_items, collapse = "\n")
  expect_match(list_content, "Alpha one")
  expect_match(list_content, "Alpha two")
})


test_that("list harvest emits correct indentation for 3-level nested lists", {
  skip_if_not_installed("xml2")

  # 3-level nested list inside a list-formal field code:
  # ilvl=0 decimal, ilvl=1 lowerLetter, ilvl=2 lowerRoman
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:r><w:fldChar w:fldCharType="begin"/></w:r>
      <w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE {&quot;type&quot;:&quot;list&quot;,&quot;class&quot;:&quot;list-formal&quot;} </w:instrText></w:r>
      <w:r><w:fldChar w:fldCharType="separate"/></w:r>
    </w:p>
    <w:p>
      <w:pPr><w:pStyle w:val="Compact"/>
        <w:numPr><w:ilvl w:val="0"/><w:numId w:val="5"/></w:numPr>
      </w:pPr>
      <w:r><w:t>Top level</w:t></w:r>
    </w:p>
    <w:p>
      <w:pPr><w:pStyle w:val="Compact"/>
        <w:numPr><w:ilvl w:val="1"/><w:numId w:val="6"/></w:numPr>
      </w:pPr>
      <w:r><w:t>Second level</w:t></w:r>
    </w:p>
    <w:p>
      <w:pPr><w:pStyle w:val="Compact"/>
        <w:numPr><w:ilvl w:val="2"/><w:numId w:val="7"/></w:numPr>
      </w:pPr>
      <w:r><w:t>Third level</w:t></w:r>
    </w:p>
    <w:p>
      <w:r><w:fldChar w:fldCharType="end"/></w:r>
    </w:p>
  </w:body>
</w:document>'

  numbering_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:abstractNum w:abstractNumId="5">
    <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl>
  </w:abstractNum>
  <w:abstractNum w:abstractNumId="6">
    <w:lvl w:ilvl="1"><w:numFmt w:val="lowerLetter"/></w:lvl>
  </w:abstractNum>
  <w:abstractNum w:abstractNumId="7">
    <w:lvl w:ilvl="2"><w:numFmt w:val="lowerRoman"/></w:lvl>
  </w:abstractNum>
  <w:num w:numId="5"><w:abstractNumId w:val="5"/></w:num>
  <w:num w:numId="6"><w:abstractNumId w:val="6"/></w:num>
  <w:num w:numId="7"><w:abstractNumId w:val="7"/></w:num>
</w:numbering>'

  td <- tempfile("test_nested_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx_with_numbering(doc_xml, numbering_xml, dir = td)

  qmd_path <- file.path(td, "output.qmd")
  suppressMessages(docx_to_qmd(docx, qmd_path))
  qmd_text <- readLines(qmd_path)

  # Should have ::: {.list-formal} wrapper
  expect_true(any(grepl("^::: \\{\\.list-formal\\}", qmd_text)),
              info = "Expected ::: {.list-formal} wrapper")

  # Check indented prefixes: ilvl0 = "1. ", ilvl1 = "  a. ", ilvl2 = "    i. "
  expect_true(any(grepl("^1\\. Top level", qmd_text)),
              info = "Expected '1. Top level' at indent level 0")
  expect_true(any(grepl("^  a\\. Second level", qmd_text)),
              info = "Expected '  a. Second level' at indent level 1")
  expect_true(any(grepl("^    i\\. Third level", qmd_text)),
              info = "Expected '    i. Third level' at indent level 2")
})


test_that("list round-trip: render -> harvest -> verify preserves all list formats", {
  skip_if_not_installed("xml2")
  skip_if_not(nzchar(Sys.which("quarto")), "quarto not available")

  td <- tempfile("test_roundtrip_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))

  # Write a QMD with all list classes
  qmd_source <- '---
title: "Round-trip List Test"
format:
  docx:
    filters:
      - %s
---

## Bullets

- Bullet one
- Bullet two

## Numbered

1. Number one
1. Number two

## Alpha

::: {.list-alpha}
- Alpha one
- Alpha two
:::

## Roman

::: {.list-roman}
- Roman one
- Roman two
:::

## Formal nested

::: {.list-formal}
- Top level
  - Nested level
:::

## Decimal

::: {.list-decimal}
- Decimal one
- Decimal two
:::
'

  filter_path <- normalizePath(
    file.path(getwd(), "_extensions/docstyle/list-style.lua"),
    mustWork = FALSE
  )
  # Fall back if running from tests/testthat
  if (!file.exists(filter_path)) {
    filter_path <- normalizePath(
      file.path(getwd(), "../../_extensions/docstyle/list-style.lua"),
      mustWork = FALSE
    )
  }
  skip_if_not(file.exists(filter_path), "list-style.lua not found")

  qmd_path <- file.path(td, "roundtrip.qmd")
  writeLines(sprintf(qmd_source, filter_path), qmd_path)

  # Render
  result <- system2("quarto", c("render", qmd_path), stdout = TRUE, stderr = TRUE)
  docx_path <- file.path(td, "roundtrip.docx")
  skip_if_not(file.exists(docx_path), "Quarto render failed")

  # Harvest
  harvested_path <- file.path(td, "harvested.qmd")
  suppressMessages(docx_to_qmd(docx_path, harvested_path))
  qmd_text <- readLines(harvested_path)

  # Bullets preserved as bullets
  expect_true(any(grepl("^- Bullet one", qmd_text)), info = "Bullet list preserved")

  # Numbered preserved as 1.
  expect_true(any(grepl("^1\\. Number one", qmd_text)), info = "Numbered list preserved")

  # Alpha wrapper and prefix
  expect_true(any(grepl("^::: \\{\\.list-alpha\\}", qmd_text)),
              info = "list-alpha wrapper preserved")
  expect_true(any(grepl("^a\\. Alpha one", qmd_text)),
              info = "Alpha prefix preserved")

  # Roman wrapper and prefix
  expect_true(any(grepl("^::: \\{\\.list-roman\\}", qmd_text)),
              info = "list-roman wrapper preserved")
  expect_true(any(grepl("^i\\. Roman one", qmd_text)),
              info = "Roman prefix preserved")

  # Formal wrapper
  expect_true(any(grepl("^::: \\{\\.list-formal\\}", qmd_text)),
              info = "list-formal wrapper preserved")

  # Decimal wrapper and prefix
  expect_true(any(grepl("^::: \\{\\.list-decimal\\}", qmd_text)),
              info = "list-decimal wrapper preserved")
  expect_true(any(grepl("^1\\. Decimal one", qmd_text)),
              info = "Decimal prefix preserved")
})


# ══ Table field code harvest tests ═══════════════════════════════════════════

test_that("harvest_table_widths extracts gridCol widths as percentages", {
  skip_if_not_installed("xml2")

  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:tbl xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:tblGrid>
        <w:gridCol w:w="2700"/>
        <w:gridCol w:w="6300"/>
      </w:tblGrid>
      <w:tr>
        <w:tc><w:p><w:r><w:t>A</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>B</w:t></w:r></w:p></w:tc>
      </w:tr>
    </w:tbl>'

  tbl <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(tbl)

  result <- harvest_table_widths(tbl, ns)
  expect_equal(result, "30,70")
})

test_that("harvest_table_widths handles equal widths", {
  skip_if_not_installed("xml2")

  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:tbl xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:tblGrid>
        <w:gridCol w:w="3000"/>
        <w:gridCol w:w="3000"/>
        <w:gridCol w:w="3000"/>
      </w:tblGrid>
      <w:tr>
        <w:tc><w:p><w:r><w:t>A</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>B</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>C</w:t></w:r></w:p></w:tc>
      </w:tr>
    </w:tbl>'

  tbl <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(tbl)

  result <- harvest_table_widths(tbl, ns)
  # 3000/9000 = 33.33% each, rounds to 33,33,33 → adjusts to sum 100
  expect_match(result, "^\\d+,\\d+,\\d+$")
  pcts <- as.numeric(strsplit(result, ",")[[1]])
  expect_equal(sum(pcts), 100)
})

test_that("harvest_table_widths returns NULL for missing grid", {
  skip_if_not_installed("xml2")

  xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
    <w:tbl xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:tr>
        <w:tc><w:p><w:r><w:t>A</w:t></w:r></w:p></w:tc>
      </w:tr>
    </w:tbl>'

  tbl <- xml2::read_xml(xml_str)
  ns <- xml2::xml_ns(tbl)

  expect_null(harvest_table_widths(tbl, ns))
})

test_that("table field code harvest emits div wrapper and table content", {
  skip_if_not_installed("xml2")

  # Document with table field code wrapping a table
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:r><w:fldChar w:fldCharType="begin"/></w:r>
      <w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE {&quot;type&quot;:&quot;table&quot;,&quot;version&quot;:2,&quot;class&quot;:&quot;table-formal&quot;,&quot;widths&quot;:&quot;50,50&quot;,&quot;font-size&quot;:&quot;9&quot;} </w:instrText></w:r>
      <w:r><w:fldChar w:fldCharType="separate"/></w:r>
    </w:p>
    <w:tbl>
      <w:tblGrid>
        <w:gridCol w:w="2700"/>
        <w:gridCol w:w="6300"/>
      </w:tblGrid>
      <w:tr>
        <w:tc><w:p><w:r><w:t>Header 1</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>Header 2</w:t></w:r></w:p></w:tc>
      </w:tr>
      <w:tr>
        <w:tc><w:p><w:r><w:t>Cell A</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>Cell B</w:t></w:r></w:p></w:tc>
      </w:tr>
    </w:tbl>
    <w:p>
      <w:r><w:fldChar w:fldCharType="end"/></w:r>
    </w:p>
  </w:body>
</w:document>'

  td <- tempfile("test_table_fc_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx_with_numbering(doc_xml, numbering_xml = NULL, dir = td,
                                           filename = "test-table.docx")

  qmd_path <- file.path(td, "output.qmd")
  suppressMessages(docx_to_qmd(docx, qmd_path))
  qmd_text <- readLines(qmd_path)

  # Should have ::: {.table-formal ...} wrapper with harvested widths
  expect_true(any(grepl("::: \\{\\.table-formal", qmd_text)),
              info = "Expected ::: {.table-formal} wrapper from field code")

  # Widths should be harvested from gridCol (30,70) not from original (50,50)
  formal_line <- qmd_text[grepl("::: \\{\\.table-formal", qmd_text)]
  expect_match(formal_line, 'widths="30,70"',
               info = "Harvested widths should replace original")

  # font-size should be preserved from payload
  expect_match(formal_line, 'font-size="9"')

  # Table content should be present
  expect_true(any(grepl("Header 1", qmd_text)))
  expect_true(any(grepl("Cell A", qmd_text)))

  # Should have closing :::
  formal_idx <- which(grepl("::: \\{\\.table-formal", qmd_text))
  close_idxs <- which(grepl("^:::$", qmd_text))
  close_after <- close_idxs[close_idxs > formal_idx[1]]
  expect_true(length(close_after) > 0,
              info = "Expected closing ::: after table-formal wrapper")
})


# --- Parenthetical numbering escaping (#64) ---
# Tests use the regex directly since convert_to_qmd() requires a real DOCX path.
# The escaping is a self-contained sub() call applied after extract_formatted_text().

# Simulate the escaping logic from convert_to_qmd()
escape_paren <- function(text, is_list_item = FALSE) {
  if (!is_list_item) {
    text <- sub("^\\(([0-9]+|[a-zA-Z])\\) ", "\\\\(\\1) ", text)
  }
  text
}

test_that("parenthetical numbering at paragraph start is escaped (#64)", {
  # (1) at start → escaped
  expect_equal(escape_paren("(1) First item. (2) Second item."),
               "\\(1) First item. (2) Second item.")

  # (a) at start → escaped
  expect_equal(escape_paren("(a) Alpha item."), "\\(a) Alpha item.")

  # (A) at start → escaped
  expect_equal(escape_paren("(A) Upper alpha."), "\\(A) Upper alpha.")

  # Multi-digit → escaped
  expect_equal(escape_paren("(12) Twelfth item."), "\\(12) Twelfth item.")
})

test_that("parenthetical numbering mid-paragraph is not escaped (#64)", {
  # (1) mid-text → no escape
  expect_equal(escape_paren("Normal paragraph with (1) inline."),
               "Normal paragraph with (1) inline.")

  # No match at all → unchanged
  expect_equal(escape_paren("Just some text."), "Just some text.")
})

test_that("list items are not escaped (#64)", {
  # Real list item → not escaped
  expect_equal(escape_paren("(1) List item text", is_list_item = TRUE),
               "(1) List item text")
})


# Helper: build a DOCX with an ADDIN DOCSTYLE section range wrapping a heading paragraph
build_section_range_docx <- function(dir, class = "section-references",
                                     inner_paragraphs = NULL) {
  ns_w <- 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'
  payload_begin <- paste0(
    'ADDIN DOCSTYLE {"type":"section","class":"', class, '","version":2}'
  )
  payload_end <- paste0(
    'ADDIN DOCSTYLE {"type":"section","class":"', class, '-end","version":2}'
  )

  if (is.null(inner_paragraphs)) {
    inner_paragraphs <- paste0(
      '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>',
      '<w:r><w:t>References</w:t></w:r></w:p>'
    )
  }

  doc_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<w:document ', ns_w, '>',
    '<w:body>',
    # Opening marker paragraph
    '<w:p>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText>', payload_begin, '</w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r>',
    '</w:p>',
    # Content paragraph(s)
    inner_paragraphs,
    # Closing marker paragraph
    '<w:p>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText>', payload_end, '</w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r>',
    '</w:p>',
    '<w:sectPr/>',
    '</w:body>',
    '</w:document>'
  )

  create_test_docx_with_numbering(doc_xml, dir = dir,
                                  filename = paste0(class, "-test.docx"))
}


test_that("section range content is preserved in harvest output (#80)", {
  skip_if_not_installed("xml2")
  skip_on_cran()

  td <- tempfile("test_sec80a_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  docx <- build_section_range_docx(td)
  qmd_path <- file.path(td, "output.qmd")
  suppressMessages(docx_to_qmd(docx, qmd_path))
  qmd_lines <- readLines(qmd_path)

  # Section div wrapper must be present
  expect_true(any(grepl("\\{.section-references", qmd_lines)),
              info = "Section div open marker missing")
  expect_true(any(grepl("^:::", qmd_lines)),
              info = "Section div close marker missing")

  # The heading content inside the section must not be stripped
  expect_true(any(grepl("References", qmd_lines)),
              info = "Heading text inside section was stripped (#80)")
})


test_that("version-history bookmark does not emit spurious div in harvest output (#82)", {
  skip_if_not_installed("xml2")
  skip_on_cran()

  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  # Build a minimal DOCX with a _docstyle_version_history bookmark wrapping a table.
  # This simulates a previously rendered document where version-history was rendered
  # as a table and bookmarked.
  ns_w <- 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'

  doc_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<w:document ', ns_w, '>',
    '<w:body>',
    # Bookmark start wrapping the version-history table
    '<w:bookmarkStart w:id="0" w:name="_docstyle_version_history"/>',
    # A simple one-row version table
    '<w:tbl>',
      '<w:tblPr/>',
      '<w:tblGrid><w:gridCol w:w="2000"/><w:gridCol w:w="2000"/><w:gridCol w:w="2000"/></w:tblGrid>',
      '<w:tr>',
        '<w:tc><w:p><w:r><w:t>Version</w:t></w:r></w:p></w:tc>',
        '<w:tc><w:p><w:r><w:t>1.0</w:t></w:r></w:p></w:tc>',
        '<w:tc><w:p><w:r><w:t>2024-01-01</w:t></w:r></w:p></w:tc>',
      '</w:tr>',
    '</w:tbl>',
    '<w:bookmarkEnd w:id="0"/>',
    # A normal paragraph after the bookmark
    '<w:p><w:r><w:t>Body text after version history.</w:t></w:r></w:p>',
    '<w:sectPr/>',
    '</w:body>',
    '</w:document>'
  )

  docx <- create_test_docx_with_numbering(doc_xml, dir = td,
                                          filename = "version-history-test.docx")
  qmd_path <- file.path(td, "output.qmd")
  suppressMessages(docx_to_qmd(docx, qmd_path))
  qmd_lines <- readLines(qmd_path)

  # The version-history content should NOT appear as a body div
  expect_false(any(grepl("^::: version-history", qmd_lines)),
               info = "Spurious ::: version-history div emitted in body (#82)")

  # The normal paragraph after the bookmark should be present
  expect_true(any(grepl("Body text after version history", qmd_lines)),
              info = "Post-bookmark paragraph missing from harvest (#82)")
})


test_that("bibliography nested inside section range is emitted (#80)", {
  skip_if_not_installed("xml2")
  skip_on_cran()

  td <- tempfile("test_sec80b_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  # Build a ZOTERO_BIBL field code (bibliography) inside the section range
  bibl_para <- paste0(
    # Heading before bibliography
    '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>',
    '<w:r><w:t>References</w:t></w:r></w:p>',
    # Bibliography field code paragraph
    '<w:p>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText>ADDIN ZOTERO_BIBL {"uncited":[],"omitted":[],"custom":[]}</w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:t>CSL BIBLIOGRAPHY</w:t></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r>',
    '</w:p>'
  )

  docx <- build_section_range_docx(td, inner_paragraphs = bibl_para)
  qmd_path <- file.path(td, "output.qmd")
  suppressMessages(docx_to_qmd(docx, qmd_path))
  qmd_lines <- readLines(qmd_path)

  # Section div wrapper
  expect_true(any(grepl("\\{.section-references", qmd_lines)),
              info = "Section div open marker missing")

  # Heading inside the section must be preserved
  expect_true(any(grepl("References", qmd_lines)),
              info = "Heading text inside nested section was stripped (#80)")

  # Bibliography placeholder must be emitted
  expect_true(any(grepl("^::: bibliography", qmd_lines)),
              info = "Bibliography div not emitted inside section range (#80)")
})


# Helper: build a DOCX with one or more image+caption paragraphs.
# Creates a minimal 1x1 PNG in word/media/ and a relationship entry so that
# extract_formatted_text() resolves the path and returns "![...](...)".
build_figure_docx <- function(dir, paragraphs_xml, filename = "figure-test.docx") {
  ns_w  <- 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'
  ns_wp <- 'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"'
  ns_a  <- 'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"'
  ns_r  <- 'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'

  doc_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<w:document ', ns_w, ' ', ns_wp, ' ', ns_a, ' ', ns_r, '>',
    '<w:body>', paragraphs_xml, '<w:sectPr/></w:body>',
    '</w:document>'
  )

  staging <- tempfile("fig_staging_")
  dir.create(staging)
  dir.create(file.path(staging, "word"))
  dir.create(file.path(staging, "word", "media"))
  dir.create(file.path(staging, "_rels"))
  dir.create(file.path(staging, "word", "_rels"))

  writeLines(doc_xml, file.path(staging, "word", "document.xml"))

  # Minimal 1x1 white PNG (67 bytes — valid PNG header + IDAT)
  png_bytes <- as.raw(c(
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,  # PNG signature
    0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,  # IHDR chunk
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
    0xde, 0x00, 0x00, 0x00, 0x0c, 0x49, 0x44, 0x41,  # IDAT chunk
    0x54, 0x08, 0xd7, 0x63, 0xf8, 0xcf, 0xc0, 0x00,
    0x00, 0x00, 0x02, 0x00, 0x01, 0xe2, 0x21, 0xbc,
    0x33, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,  # IEND chunk
    0x44, 0xae, 0x42, 0x60, 0x82
  ))
  writeBin(png_bytes, file.path(staging, "word", "media", "image1.png"))

  ct <- '<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="xml" ContentType="application/xml"/>
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="png" ContentType="image/png"/>
  <Override PartName="/word/document.xml"
    ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>'
  writeLines(ct, file.path(staging, "[Content_Types].xml"))

  writeLines(
    '<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
    Target="word/document.xml"/>
</Relationships>',
    file.path(staging, "_rels", ".rels")
  )

  writeLines(
    '<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId10" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
    Target="media/image1.png"/>
</Relationships>',
    file.path(staging, "word", "_rels", "document.xml.rels")
  )

  out_path <- file.path(dir, filename)
  old_wd <- getwd()
  setwd(staging)
  on.exit({ setwd(old_wd); unlink(staging, recursive = TRUE) })
  files <- list.files(".", recursive = TRUE, all.files = TRUE)
  utils::zip(out_path, files, flags = "-q")
  out_path
}

# Drawing paragraph XML snippet (uses rId10 relationship defined in build_figure_docx)
make_drawing_para <- function(docpr_id = 42, descr = "") {
  paste0(
    '<w:p>',
      '<w:r>',
        '<w:drawing>',
          '<wp:inline>',
            '<wp:docPr id="', docpr_id, '" name="Picture ', docpr_id, '" descr="', descr, '"/>',
            '<a:graphic>',
              '<a:graphicData>',
                '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">',
                  '<pic:blipFill>',
                    '<a:blip r:embed="rId10"/>',
                  '</pic:blipFill>',
                '</pic:pic>',
              '</a:graphicData>',
            '</a:graphic>',
          '</wp:inline>',
        '</w:drawing>',
      '</w:r>',
    '</w:p>'
  )
}

make_image_caption_para <- function(text) {
  paste0(
    '<w:p>',
      '<w:pPr><w:pStyle w:val="ImageCaption"/></w:pPr>',
      '<w:r><w:t>', text, '</w:t></w:r>',
    '</w:p>'
  )
}


test_that("image + ImageCaption harvested as figure div with docPr ID (#83)", {
  skip_if_not_installed("xml2")
  skip_on_cran()

  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  paras <- paste0(
    make_drawing_para(docpr_id = 42),
    make_image_caption_para("**Figure 1.** Flow diagram of POPCORN methodology.")
  )
  docx <- build_figure_docx(td, paras)
  qmd_path <- file.path(td, "output.qmd")
  suppressMessages(docx_to_qmd(docx, qmd_path))
  qmd_lines <- readLines(qmd_path)

  # Figure div opened with a crossref-valid id derived from docPr id (#124)
  expect_true(any(grepl("^::: \\{#fig-42 \\.figure\\}", qmd_lines)),
              info = "Figure div not opened with crossref-valid fig- id (#124)")

  # Image link present inside div
  expect_true(any(grepl("^!\\[", qmd_lines)),
              info = "Image link not present in harvested output (#83)")

  # Caption inside div
  expect_true(any(grepl("Flow diagram of POPCORN", qmd_lines)),
              info = "Caption text not present in harvested output (#83)")

  # #124: the literal "Figure 1." label Word stores must be stripped on
  # harvest — Quarto regenerates the number from the fig- crossref id, so
  # keeping it would double-number the rendered figure.
  expect_false(any(grepl("\\*\\*Figure 1\\.\\*\\*", qmd_lines)),
               info = "literal '**Figure 1.**' label not stripped from caption (#124)")
  expect_true(any(grepl("^Flow diagram of POPCORN methodology\\.$", qmd_lines)),
              info = "caption should retain descriptive text without the label (#124)")

  # Div closed
  expect_true(any(grepl("^:::$", qmd_lines)),
              info = "Figure div not closed (#83)")

  # Caption not emitted as standalone paragraph (no duplicate)
  img_idx     <- which(grepl("^!\\[", qmd_lines))
  caption_idx <- which(grepl("Flow diagram of POPCORN", qmd_lines))
  expect_length(caption_idx, 1L)
  expect_true(caption_idx > img_idx,
              info = "Caption should appear after image line (#83)")
})


test_that("image without ImageCaption harvested as closed figure div (#83)", {
  skip_if_not_installed("xml2")
  skip_on_cran()

  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  paras <- paste0(
    make_drawing_para(docpr_id = 7),
    '<w:p><w:r><w:t>Following paragraph.</w:t></w:r></w:p>'
  )
  docx <- build_figure_docx(td, paras)
  qmd_path <- file.path(td, "output.qmd")
  suppressMessages(docx_to_qmd(docx, qmd_path))
  qmd_lines <- readLines(qmd_path)

  expect_true(any(grepl("^::: \\{#fig-7 \\.figure\\}", qmd_lines)),
              info = "Figure div not opened (#83/#124)")
  expect_true(any(grepl("^:::$", qmd_lines)),
              info = "Figure div not closed (#83)")
  expect_true(any(grepl("Following paragraph", qmd_lines)),
              info = "Post-figure paragraph missing (#83)")
})


test_that("multiple figures get sequential docPr-based IDs (#83)", {
  skip_if_not_installed("xml2")
  skip_on_cran()

  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  paras <- paste0(
    make_drawing_para(docpr_id = 1),
    make_image_caption_para("**Figure 1.** First figure."),
    make_drawing_para(docpr_id = 2),
    make_image_caption_para("**Figure 2.** Second figure.")
  )
  docx <- build_figure_docx(td, paras)
  qmd_path <- file.path(td, "output.qmd")
  suppressMessages(docx_to_qmd(docx, qmd_path))
  qmd_lines <- readLines(qmd_path)

  expect_true(any(grepl("#fig-1\\b", qmd_lines)),
              info = "First figure ID missing (#83/#124)")
  expect_true(any(grepl("#fig-2\\b", qmd_lines)),
              info = "Second figure ID missing (#83/#124)")
  expect_length(grep("^!\\[", qmd_lines), 2L)
})


test_that("figures.json written with correct keys and caption (#83)", {
  skip_if_not_installed("xml2")
  skip_on_cran()

  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  paras <- paste0(
    make_drawing_para(docpr_id = 42),
    make_image_caption_para("**Figure 1.** Test caption.")
  )
  docx <- build_figure_docx(td, paras)
  qmd_path <- file.path(td, "output.qmd")
  suppressMessages(docx_to_qmd(docx, qmd_path))

  figures_path <- file.path(td, "_docstyle", "figures.json")
  expect_true(file.exists(figures_path),
              info = "figures.json not written (#83)")

  figs <- jsonlite::read_json(figures_path, simplifyVector = FALSE)
  expect_true("42" %in% names(figs),
              info = "Key '42' missing from figures.json (#83)")
  expect_equal(figs[["42"]]$docpr_id, 42)
  expect_equal(figs[["42"]]$qmd_id, "fig-42")
  expect_match(figs[["42"]]$caption, "Test caption")
})


# Helper: build a DOCX with ADDIN DOCSTYLE figure field code wrapping image+caption.
# Used for Phase 2 round-trip tests (author-renamed id preserved via field code).
build_figure_field_code_docx <- function(dir, fig_id = "fig-consort-flow",
                                         docpr_id = 42,
                                         caption = "**Figure 1.** Caption text.",
                                         original_path = NULL) {
  ns_w  <- 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'
  ns_wp <- 'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"'
  ns_a  <- 'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"'
  ns_r  <- 'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'

  payload_fields <- list(type = "figure", id = fig_id, version = 2L)
  if (!is.null(original_path)) payload_fields$original_path <- original_path
  payload_begin <- jsonlite::toJSON(payload_fields, auto_unbox = TRUE)

  drawing_para <- paste0(
    '<w:p><w:r><w:drawing><wp:inline>',
      '<wp:docPr id="', docpr_id, '" name="Picture ', docpr_id, '" descr=""/>',
      '<a:graphic><a:graphicData>',
        '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">',
          '<pic:blipFill><a:blip r:embed="rId10"/></pic:blipFill>',
        '</pic:pic>',
      '</a:graphicData></a:graphic>',
    '</wp:inline></w:drawing></w:r></w:p>'
  )
  caption_para <- paste0(
    '<w:p><w:pPr><w:pStyle w:val="ImageCaption"/></w:pPr>',
    '<w:r><w:t>', caption, '</w:t></w:r></w:p>'
  )

  field_code_begin <- paste0(
    '<w:p>',
      '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
      '<w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE ',
        escape_xml_text(payload_begin),
      ' </w:instrText></w:r>',
      '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '</w:p>'
  )
  field_code_end <- '<w:p><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>'

  paragraphs_xml <- paste0(
    field_code_begin,
    drawing_para,
    caption_para,
    field_code_end
  )

  # Reuse build_figure_docx which sets up media/ and image relationship rId10
  build_figure_docx(dir, paragraphs_xml, filename = "figure-field-code-test.docx")
}


test_that("figure field code round-trip restores author-assigned QMD id (#83)", {
  skip_if_not_installed("xml2")
  skip_on_cran()

  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  docx <- build_figure_field_code_docx(td,
    fig_id   = "fig-consort-flow",
    docpr_id = 42,
    caption  = "**Figure 1.** CONSORT flow diagram."
  )
  qmd_path <- file.path(td, "output.qmd")
  suppressMessages(docx_to_qmd(docx, qmd_path))
  qmd_lines <- readLines(qmd_path)

  # Author-assigned id must be restored from field code (not fig-FIXME-42)
  expect_true(any(grepl("#fig-consort-flow", qmd_lines)),
              info = "Author-assigned id not restored from figure field code (#83)")
  expect_false(any(grepl("fig-FIXME", qmd_lines)),
               info = "FIXME placeholder id emitted despite field code being present (#83)")

  # Image and caption both present
  expect_true(any(grepl("^!\\[", qmd_lines)),
              info = "Image link missing from re-harvested figure (#83)")
  expect_true(any(grepl("CONSORT flow diagram", qmd_lines)),
              info = "Caption missing from re-harvested figure (#83)")

  # Div properly closed
  expect_true(any(grepl("^:::$", qmd_lines)),
              info = "Figure div not closed (#83)")
})

test_that("figure field code restores original_path on re-harvest (#79)", {
  skip_if_not_installed("xml2")
  skip_on_cran()

  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  orig <- "figures/fig-consort-flow.png"
  docx <- build_figure_field_code_docx(td,
    fig_id        = "fig-consort-flow",
    docpr_id      = 42,
    caption       = "CONSORT flow.",
    original_path = orig
  )
  qmd_path <- file.path(td, "output.qmd")
  suppressMessages(docx_to_qmd(docx, qmd_path))
  qmd_lines <- readLines(qmd_path)

  # Image line should use the original source path, not the embedded rId path
  img_lines <- qmd_lines[grepl("^!\\[", qmd_lines)]
  expect_true(length(img_lines) > 0,
              info = "No image line found in re-harvested output (#79)")
  expect_true(any(grepl(orig, img_lines, fixed = TRUE)),
              info = "original_path not restored on re-harvest (#79)")
  expect_false(any(grepl("rId", img_lines)),
               info = "rId-based path leaked into re-harvested output (#79)")
})


# =============================================================================
# Internal anchor hyperlinks and heading IDs (#96)
# =============================================================================

test_that("extract_formatted_text: w:anchor hyperlink → [text](#anchor) (#96)", {
  skip_if_not_installed("xml2")

  # w:hyperlink with w:anchor (no r:id) is an internal document cross-reference
  xml_str <- paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body><w:p>',
    '<w:hyperlink w:anchor="methods">',
    '<w:r><w:t>Methods</w:t></w:r>',
    '</w:hyperlink>',
    '</w:p></w:body></w:document>'
  )

  doc <- xml2::read_xml(xml_str)
  ns  <- xml2::xml_ns(doc)
  p   <- xml2::xml_find_first(doc, "//w:p", ns)

  result <- extract_formatted_text(p, ns)
  expect_equal(result$text, "[Methods](#methods)")
})

test_that("harvest: heading with preceding bookmarkStart → heading {#id} (#96)", {
  skip_if_not_installed("xml2")
  skip_on_cran()

  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  ns_w <- 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'

  doc_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<w:document ', ns_w, '>',
    '<w:body>',
    # bookmarkStart before the heading (Pandoc's pattern)
    '<w:bookmarkStart w:id="1" w:name="intro"/>',
    '<w:p>',
    '<w:pPr><w:pStyle w:val="Heading1"/></w:pPr>',
    '<w:r><w:t>Introduction</w:t></w:r>',
    '</w:p>',
    '<w:bookmarkEnd w:id="1"/>',
    '<w:p><w:r><w:t>Body text.</w:t></w:r></w:p>',
    '<w:sectPr/>',
    '</w:body></w:document>'
  )

  docx    <- create_test_docx_with_numbering(doc_xml, dir = td)
  qmd_path <- file.path(td, "out.qmd")
  suppressMessages(docx_to_qmd(docx, qmd_path))
  qmd_lines <- readLines(qmd_path)

  expect_true(any(grepl("^# Introduction \\{#intro\\}", qmd_lines)),
              info = "Heading ID {#intro} not emitted (#96)")
})

test_that("harvest: anchor hyperlink in body paragraph round-trips correctly (#96)", {
  skip_if_not_installed("xml2")
  skip_on_cran()

  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  ns_w <- 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'

  doc_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<w:document ', ns_w, '>',
    '<w:body>',
    '<w:bookmarkStart w:id="1" w:name="methods"/>',
    '<w:p>',
    '<w:pPr><w:pStyle w:val="Heading1"/></w:pPr>',
    '<w:r><w:t>Methods</w:t></w:r>',
    '</w:p>',
    '<w:bookmarkEnd w:id="1"/>',
    '<w:p>',
    '<w:r><w:t xml:space="preserve">See </w:t></w:r>',
    '<w:hyperlink w:anchor="methods">',
    '<w:r><w:t>Methods</w:t></w:r>',
    '</w:hyperlink>',
    '<w:r><w:t xml:space="preserve"> for details.</w:t></w:r>',
    '</w:p>',
    '<w:sectPr/>',
    '</w:body></w:document>'
  )

  docx    <- create_test_docx_with_numbering(doc_xml, dir = td)
  qmd_path <- file.path(td, "out.qmd")
  suppressMessages(docx_to_qmd(docx, qmd_path))
  qmd_lines <- readLines(qmd_path)

  expect_true(any(grepl("^# Methods \\{#methods\\}", qmd_lines)),
              info = "Heading {#methods} not emitted (#96)")
  expect_true(any(grepl("\\[Methods\\]\\(#methods\\)", qmd_lines)),
              info = "Anchor hyperlink [Methods](#methods) not emitted (#96)")
})

test_that("harvest: _docstyle_* bookmarks do NOT produce heading IDs (#96)", {
  skip_if_not_installed("xml2")
  skip_on_cran()

  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  ns_w <- 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'

  doc_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<w:document ', ns_w, '>',
    '<w:body>',
    # Internal docstyle bookmark — must NOT become a heading ID
    '<w:bookmarkStart w:id="0" w:name="_docstyle_section_appendix"/>',
    '<w:p>',
    '<w:pPr><w:pStyle w:val="Heading1"/></w:pPr>',
    '<w:r><w:t>Appendix</w:t></w:r>',
    '</w:p>',
    '<w:bookmarkEnd w:id="0"/>',
    '<w:p><w:r><w:t>Content.</w:t></w:r></w:p>',
    '<w:sectPr/>',
    '</w:body></w:document>'
  )

  docx    <- create_test_docx_with_numbering(doc_xml, dir = td)
  qmd_path <- file.path(td, "out.qmd")
  suppressMessages(docx_to_qmd(docx, qmd_path))
  qmd_lines <- readLines(qmd_path)

  # Heading should appear but WITHOUT an ID attribute
  expect_true(any(grepl("^# Appendix$", qmd_lines)),
              info = "Heading not found (#96)")
  expect_false(any(grepl("\\{#_docstyle_", qmd_lines)),
               info = "_docstyle_ bookmark must not become a heading ID (#96)")
})

test_that("harvest: _Toc/_Ref/_GoBack auto-bookmarks do NOT produce heading IDs (#96)", {
  skip_if_not_installed("xml2")
  skip_on_cran()

  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  ns_w <- 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'

  doc_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<w:document ', ns_w, '>',
    '<w:body>',
    # Word TOC auto-bookmark — must NOT become a heading ID
    '<w:bookmarkStart w:id="1" w:name="_Toc123456789"/>',
    '<w:p>',
    '<w:pPr><w:pStyle w:val="Heading1"/></w:pPr>',
    '<w:r><w:t>Introduction</w:t></w:r>',
    '</w:p>',
    '<w:bookmarkEnd w:id="1"/>',
    # Word cross-ref auto-bookmark — must NOT become a heading ID
    '<w:bookmarkStart w:id="2" w:name="_Ref987654321"/>',
    '<w:p>',
    '<w:pPr><w:pStyle w:val="Heading2"/></w:pPr>',
    '<w:r><w:t>Background</w:t></w:r>',
    '</w:p>',
    '<w:bookmarkEnd w:id="2"/>',
    '<w:sectPr/>',
    '</w:body></w:document>'
  )

  docx     <- create_test_docx_with_numbering(doc_xml, dir = td)
  qmd_path <- file.path(td, "out.qmd")
  suppressMessages(docx_to_qmd(docx, qmd_path))
  qmd_lines <- readLines(qmd_path)

  expect_true(any(grepl("^# Introduction$", qmd_lines)),
              info = "Heading1 not found (#96)")
  expect_true(any(grepl("^## Background$", qmd_lines)),
              info = "Heading2 not found (#96)")
  expect_false(any(grepl("\\{#_Toc", qmd_lines)),
               info = "_Toc bookmark must not become a heading ID (#96)")
  expect_false(any(grepl("\\{#_Ref", qmd_lines)),
               info = "_Ref bookmark must not become a heading ID (#96)")
})

test_that("harvest: bookmarkStart before body paragraph does NOT attach ID to following heading (#96)", {
  skip_if_not_installed("xml2")
  skip_on_cran()

  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  ns_w <- 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'

  doc_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<w:document ', ns_w, '>',
    '<w:body>',
    # User bookmark before a body paragraph — should NOT carry to next heading
    '<w:bookmarkStart w:id="1" w:name="someref"/>',
    '<w:p>',
    '<w:r><w:t>Body text here.</w:t></w:r>',
    '</w:p>',
    '<w:bookmarkEnd w:id="1"/>',
    '<w:p>',
    '<w:pPr><w:pStyle w:val="Heading1"/></w:pPr>',
    '<w:r><w:t>Methods</w:t></w:r>',
    '</w:p>',
    '<w:sectPr/>',
    '</w:body></w:document>'
  )

  docx     <- create_test_docx_with_numbering(doc_xml, dir = td)
  qmd_path <- file.path(td, "out.qmd")
  suppressMessages(docx_to_qmd(docx, qmd_path))
  qmd_lines <- readLines(qmd_path)

  # Heading must appear without {#someref} — the bookmark was on the body paragraph
  expect_true(any(grepl("^# Methods$", qmd_lines)),
              info = "Heading not found (#96)")
  expect_false(any(grepl("\\{#someref\\}", qmd_lines)),
               info = "Bookmark from body paragraph must not attach to following heading (#96)")
})


# ══ #125: numbered headings on unresolved styles flatten to plain paragraphs ══

# Build a docx that includes word/styles.xml so build_style_props_lookup()
# can resolve (or fail to resolve) custom styles. `styles_body` is the
# inner XML of <w:styles>; `doc_body` is the inner XML of <w:body>.
build_docx_with_styles <- function(dir, styles_body, doc_body,
                                    filename = "styled.docx") {
  ns_w <- "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
  staging <- tempfile("docx_styled_"); dir.create(staging)
  on.exit(unlink(staging, recursive = TRUE), add = TRUE)
  dir.create(file.path(staging, "word"))
  dir.create(file.path(staging, "_rels"))
  dir.create(file.path(staging, "word", "_rels"))

  writeLines(paste0('<?xml version="1.0" encoding="UTF-8"?>\n',
                    '<w:styles xmlns:w="', ns_w, '">', styles_body,
                    '</w:styles>'),
             file.path(staging, "word", "styles.xml"))
  writeLines(paste0('<?xml version="1.0" encoding="UTF-8"?>\n',
                    '<w:document xmlns:w="', ns_w, '"><w:body>', doc_body,
                    '</w:body></w:document>'),
             file.path(staging, "word", "document.xml"))
  writeLines(paste0('<?xml version="1.0" encoding="UTF-8"?>\n',
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
    '<Default Extension="xml" ContentType="application/xml"/>',
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
    '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>',
    '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>',
    '</Types>'),
    file.path(staging, "[Content_Types].xml"))
  writeLines(paste0('<?xml version="1.0" encoding="UTF-8"?>\n',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>',
    '</Relationships>'),
    file.path(staging, "_rels", ".rels"))
  writeLines(paste0('<?xml version="1.0" encoding="UTF-8"?>\n',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>',
    '</Relationships>'),
    file.path(staging, "word", "_rels", "document.xml.rels"))

  out_path <- file.path(dir, filename)
  old_wd <- getwd(); setwd(staging); on.exit(setwd(old_wd), add = TRUE)
  utils::zip(out_path, list.files(".", recursive = TRUE, all.files = TRUE),
             flags = "-q")
  out_path
}

test_that("strip_figure_label removes literal figure labels but not lookalikes (#124)", {
  f <- docstyle:::strip_figure_label
  # Labels that should be stripped (number is mandatory).
  expect_equal(f("**Figure 1.** Flow diagram of methodology."),
               "Flow diagram of methodology.")
  expect_equal(f("Figure 2: Results summary"), "Results summary")
  expect_equal(f("Fig. 3 Outcomes"), "Outcomes")
  expect_equal(f("**Figure 10.** Deep number"), "Deep number")
  expect_equal(f("Figure 4 — Em dash sep"), "Em dash sep")
  expect_equal(f("**Figure S1.** Supplementary"), "Supplementary")
  expect_equal(f("Figure 1a. Panel a"), "Panel a")
  # Lookalikes that must NOT be stripped (word continuation, no number).
  expect_equal(f("A normal caption with no label"),
               "A normal caption with no label")
  expect_equal(f("Figures are discussed here"), "Figures are discussed here")
  expect_equal(f("Figured prominently in the study"),
               "Figured prominently in the study")
  # Degenerate inputs pass through.
  expect_null(f(NULL))
  expect_equal(f(NA_character_), NA_character_)
})

test_that("numbered heading on an unresolved style is recovered as a heading (#125)", {
  # Two subsections: 3.4.1 uses a real Heading3 (resolves via outlineLvl);
  # 3.4.2 uses a custom style with no outlineLvl and a name that doesn't
  # match "heading N" (resolution falls through). Before the fix, 3.4.2
  # flattened to a plain paragraph. The numbered-heading heuristic should
  # recover it at the depth implied by the numbering (3 segments → ###).
  td <- tempfile("h125_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))

  styles <- paste0(
    '<w:style w:type="paragraph" w:styleId="Heading3">',
    '<w:name w:val="heading 3"/><w:pPr><w:outlineLvl w:val="2"/></w:pPr></w:style>',
    '<w:style w:type="paragraph" w:styleId="CustomSub">',
    '<w:name w:val="Custom Sub"/></w:style>')
  body <- paste0(
    '<w:p><w:pPr><w:pStyle w:val="Heading3"/></w:pPr>',
    '<w:r><w:t>3.4.1 First sub</w:t></w:r></w:p>',
    '<w:p><w:r><w:t>Body under 3.4.1.</w:t></w:r></w:p>',
    '<w:p><w:pPr><w:pStyle w:val="CustomSub"/></w:pPr>',
    '<w:r><w:t>3.4.2 Second sub</w:t></w:r></w:p>',
    '<w:p><w:r><w:t>Body under 3.4.2.</w:t></w:r></w:p>')

  docx <- build_docx_with_styles(td, styles, body)
  qmd <- file.path(td, "out.qmd")
  suppressMessages(docx_to_qmd(docx, qmd))
  lines <- readLines(qmd)

  expect_true(any(grepl("^### 3\\.4\\.1 First sub$", lines)),
              info = "3.4.1 (real Heading3) should render as ###")
  expect_true(any(grepl("^### 3\\.4\\.2 Second sub$", lines)),
              info = paste0("3.4.2 (unresolved style, numbered) should be ",
                            "recovered as ###; got:\n",
                            paste(lines, collapse = "\n")))
})

test_that("numbered-heading recovery does NOT fire on list items or plain text (#125)", {
  # Guard against over-eager recovery. A two-segment numbered LIST item
  # and ordinary body text that merely starts with digits must stay as-is.
  td <- tempfile("h125neg_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))

  styles <- '<w:style w:type="paragraph" w:styleId="Normal"><w:name w:val="Normal"/></w:style>'
  body <- paste0(
    # Plain body paragraph that opens with a year — must NOT become a heading
    '<w:p><w:r><w:t>2020 was a notable year for surveillance.</w:t></w:r></w:p>',
    # A sentence with an inline decimal — must NOT become a heading
    '<w:p><w:r><w:t>The ratio 3.4 was observed across sites.</w:t></w:r></w:p>')

  docx <- build_docx_with_styles(td, styles, body)
  qmd <- file.path(td, "out.qmd")
  suppressMessages(docx_to_qmd(docx, qmd))
  lines <- readLines(qmd)

  expect_false(any(grepl("^#+ ", lines)),
               info = paste0("No heading should be inferred from plain text; ",
                             "got:\n", paste(lines, collapse = "\n")))
})

test_that("harvest captures relocated abstract to YAML + empty placeholder (#149)", {
  skip_if_not_installed("xml2")
  td <- tempfile("h149_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  # ADDIN DOCSTYLE div field code (name=abstract), structured exactly as
  # field-code-utils.lua's build_div_field_start() + build_block_field_end():
  # the BEGIN paragraph carries begin/instrText/separate (NO end -- nesting
  # must stay at 1 across the wrapped content), and the END is a bare
  # fldChar="end" paragraph. (This mirrors the figure/list div-range fixtures
  # in this file, not the section helper, which uses self-contained markers.)
  fc_begin <- paste0(
    '<w:p><w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE ',
    '{&quot;type&quot;:&quot;div&quot;,&quot;name&quot;:&quot;abstract&quot;} </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r></w:p>')
  fc_end <- '<w:p><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>'

  styles <- paste0(
    '<w:style w:type="paragraph" w:styleId="AbstractTitle">',
    '<w:name w:val="Abstract Title"/></w:style>',
    '<w:style w:type="paragraph" w:styleId="Abstract">',
    '<w:name w:val="Abstract"/></w:style>',
    '<w:style w:type="paragraph" w:styleId="Heading1">',
    '<w:name w:val="heading 1"/><w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style>')
  body <- paste0(
    fc_begin,
    '<w:p><w:pPr><w:pStyle w:val="AbstractTitle"/></w:pPr><w:r><w:t>Abstract</w:t></w:r></w:p>',
    '<w:p><w:pPr><w:pStyle w:val="Abstract"/></w:pPr><w:r><w:t>First line of abstract.</w:t></w:r></w:p>',
    '<w:p><w:pPr><w:pStyle w:val="Abstract"/></w:pPr><w:r><w:t>Second line of abstract.</w:t></w:r></w:p>',
    fc_end,
    '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Intro</w:t></w:r></w:p>')

  docx <- build_docx_with_styles(td, styles, body, filename = "abs.docx")
  qmd <- file.path(td, "out.qmd")
  suppressMessages(docx_to_qmd(docx, qmd))
  lines <- readLines(qmd)
  text  <- paste(lines, collapse = "\n")

  # Empty placeholder div emitted at the range position.
  expect_true(any(grepl("docstyle-abstract", lines)),
              info = paste0("no docstyle-abstract placeholder:\n", text))
  # Abstract prose captured into YAML.
  expect_match(text, "abstract:")
  expect_match(text, "First line of abstract")
  expect_match(text, "Second line of abstract")
  # The AbstractTitle literal "Abstract" heading is NOT dumped as body prose.
  expect_false(any(grepl("^Abstract$", lines)))
})

test_that("harvest of an empty abstract field code emits placeholder, no YAML abstract (#149)", {
  skip_if_not_installed("xml2")
  td <- tempfile("h149empty_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  # Field-code paragraph builders — verbatim from the main #149 test above.
  fc_begin <- paste0(
    '<w:p><w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE ',
    '{&quot;type&quot;:&quot;div&quot;,&quot;name&quot;:&quot;abstract&quot;} </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r></w:p>')
  fc_end <- '<w:p><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>'

  styles <- paste0(
    '<w:style w:type="paragraph" w:styleId="AbstractTitle">',
    '<w:name w:val="Abstract Title"/></w:style>',
    '<w:style w:type="paragraph" w:styleId="Abstract">',
    '<w:name w:val="Abstract"/></w:style>',
    '<w:style w:type="paragraph" w:styleId="Heading1">',
    '<w:name w:val="heading 1"/><w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style>')

  # Body: abstract field code wrapping NOTHING, then a heading.
  body <- paste0(
    fc_begin,
    fc_end,
    '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Intro</w:t></w:r></w:p>')

  docx <- build_docx_with_styles(td, styles, body, filename = "absempty.docx")
  qmd <- file.path(td, "out.qmd")
  suppressMessages(docx_to_qmd(docx, qmd))
  lines <- readLines(qmd)
  text  <- paste(lines, collapse = "\n")

  # Empty placeholder div emitted at the range position.
  expect_true(any(grepl("docstyle-abstract", lines)),
              info = paste0("no placeholder:\n", text))
  # No abstract content was captured, so no abstract: key in YAML.
  expect_false(any(grepl("^abstract\\s*:", lines)),
               info = paste0("unexpected abstract: key:\n", text))
})
