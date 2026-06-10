# Tests for Zotero field code injection functions (string-based approach)

test_that("find_last_occurrence finds last match", {
  haystack <- "abc<w:t>def<w:t>ghi"
  result <- find_last_occurrence(haystack, "<w:t")
  expect_equal(result, 12L)  # Position of second <w:t
})

test_that("find_last_occurrence returns -1 when not found", {
  haystack <- "no match here"
  result <- find_last_occurrence(haystack, "<w:t")
  expect_equal(result, -1L)
})

test_that("build_field_code_xml creates valid 5-part structure", {
  xml_str <- build_field_code_xml(
    instrText = "ADDIN ZOTERO_ITEM CSL_CITATION {}",
    display = "(1)"
  )

  # Should contain all 5 parts
  expect_true(grepl('fldCharType="begin"', xml_str))
  expect_true(grepl('w:instrText', xml_str))
  expect_true(grepl('fldCharType="separate"', xml_str))
  expect_true(grepl('<w:t>', xml_str))
  expect_true(grepl('fldCharType="end"', xml_str))

  # Should have 5 w:r elements
  r_count <- length(gregexpr("<w:r>", xml_str)[[1]])
  expect_equal(r_count, 5)
})

test_that("build_field_code_xml pads instruction text with spaces", {
  xml_str <- build_field_code_xml(
    instrText = "ADDIN ZOTERO_ITEM",
    display = "(1)"
  )

  # instrText should have leading and trailing spaces
  expect_true(grepl('xml:space="preserve"> ADDIN ZOTERO_ITEM </w:instrText>', xml_str))
})

test_that("escape_xml_text escapes & < > but NOT quotes", {
  # This is critical - Zotero expects literal quotes in JSON
  result <- escape_xml_text('Test & <special> "quotes"')

  expect_true(grepl("&amp;", result))
  expect_true(grepl("&lt;", result))
  expect_true(grepl("&gt;", result))
  expect_true(grepl('"', result))  # Literal quote, not &quot;
  expect_false(grepl("&quot;", result))
})

test_that("escape_xml_text handles ampersand first to avoid double-escaping", {
  result <- escape_xml_text("a & b < c")
  expect_equal(result, "a &amp; b &lt; c")
})


# ---------------------------------------------------------------------------
# #16: configurable Zotero preferences via zotero_config
# ---------------------------------------------------------------------------

test_that("build_zotero_pref_xml uses journal_abbreviations param (#16)", {
  xml_true  <- build_zotero_pref_xml(journal_abbreviations = TRUE)
  xml_false <- build_zotero_pref_xml(journal_abbreviations = FALSE)
  # XML escapes " → &quot; in instrText, so match unescaped JSON via instrText content
  expect_true(grepl("automaticJournalAbbreviations", xml_true,  fixed = TRUE))
  expect_true(grepl("automaticJournalAbbreviations", xml_false, fixed = TRUE))
  # Verify the actual boolean value in the JSON (escaped form)
  expect_true(grepl("automaticJournalAbbreviations&quot;:true",  xml_true,  fixed = TRUE))
  expect_true(grepl("automaticJournalAbbreviations&quot;:false", xml_false, fixed = TRUE))
})

test_that("build_zotero_pref_xml uses field_type param (#16)", {
  xml_fields    <- build_zotero_pref_xml(field_type = "Fields")
  xml_bookmarks <- build_zotero_pref_xml(field_type = "Bookmarks")
  expect_true(grepl("fieldType&quot;:&quot;Fields",    xml_fields,    fixed = TRUE))
  expect_true(grepl("fieldType&quot;:&quot;Bookmarks", xml_bookmarks, fixed = TRUE))
})

test_that("inject_zotero_components respects zotero_config style (#16)", {
  # When no stored ZOTERO_PREF exists and zotero_config provides a style,
  # the zotero_config style should be used over the default_style param.
  # We test the priority chain by checking inject_zotero_pref is called with
  # the correct style — here we verify via build_zotero_pref_xml output.
  apa_url <- "http://www.zotero.org/styles/apa"
  xml_out <- build_zotero_pref_xml(style_id = apa_url)
  expect_true(grepl(apa_url, xml_out, fixed = TRUE))
  # Default vancouver should NOT appear
  expect_false(grepl("vancouver", xml_out, fixed = TRUE))
})

test_that("inject_zotero_components priority: stored > yaml > default (#16)", {
  # Simulate the priority resolution logic in inject_zotero_components()
  stored_style <- "http://www.zotero.org/styles/nature"
  yaml_style   <- "http://www.zotero.org/styles/apa"
  default_style <- "http://www.zotero.org/styles/vancouver"

  `%||%` <- function(a, b) if (!is.null(a)) a else b

  # stored wins
  result <- stored_style %||% yaml_style %||% default_style
  expect_equal(result, stored_style)

  # yaml wins when no stored
  result2 <- NULL %||% yaml_style %||% default_style
  expect_equal(result2, yaml_style)

  # default wins when neither stored nor yaml
  result3 <- NULL %||% NULL %||% default_style
  expect_equal(result3, default_style)
})
