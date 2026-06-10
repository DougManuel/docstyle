# Tests for footnote extraction and round-trip

test_that("extract_footnotes extracts footnotes from Word XML", {
  skip("extract_footnotes reads from file path, not XML object - test needs rework")
})

test_that("extract_formatted_text detects footnote references", {
  # Create a paragraph with a footnote reference
  p_xml <- xml2::read_xml('
    <w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:r><w:t>Text before</w:t></w:r>
      <w:r><w:footnoteReference w:id="1"/></w:r>
      <w:r><w:t> and after.</w:t></w:r>
    </w:p>
  ')
  ns <- xml2::xml_ns(p_xml)

  footnotes <- list("1" = "This is the footnote content")

  result <- docstyle:::extract_formatted_text(p_xml, ns, footnotes, 0)

  expect_equal(result$text, "Text before[^1] and after.")
  expect_equal(result$footnote_counter, 1)
  expect_equal(length(result$new_definitions), 1)
  expect_equal(result$new_definitions[1], "[^1]: This is the footnote content")
})

test_that("extract_formatted_text handles multiple footnotes", {
  p_xml <- xml2::read_xml('
    <w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:r><w:t>First</w:t></w:r>
      <w:r><w:footnoteReference w:id="1"/></w:r>
      <w:r><w:t> second</w:t></w:r>
      <w:r><w:footnoteReference w:id="2"/></w:r>
      <w:r><w:t> end.</w:t></w:r>
    </w:p>
  ')
  ns <- xml2::xml_ns(p_xml)

  footnotes <- list(
    "1" = "First footnote",
    "2" = "Second footnote"
  )

  result <- docstyle:::extract_formatted_text(p_xml, ns, footnotes, 0)

  expect_equal(result$text, "First[^1] second[^2] end.")
  expect_equal(result$footnote_counter, 2)
  expect_equal(length(result$new_definitions), 2)
})

test_that("extract_formatted_text handles paragraph without footnotes", {
  p_xml <- xml2::read_xml('
    <w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:r><w:t>Just regular text.</w:t></w:r>
    </w:p>
  ')
  ns <- xml2::xml_ns(p_xml)

  result <- docstyle:::extract_formatted_text(p_xml, ns, list(), 0)

  expect_equal(result$text, "Just regular text.")
  expect_equal(result$footnote_counter, 0)
  expect_equal(length(result$new_definitions), 0)
})
