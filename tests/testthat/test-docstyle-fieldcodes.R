# Tests for ADDIN DOCSTYLE field code round-trip (inline character styles)
#
# Tests that char-style.lua's ADDIN DOCSTYLE field codes are correctly parsed
# by the harvest state machine in extract_formatted_text(), restoring the
# original QMD source from the JSON payload.

# ── Helper: build paragraph XML with DOCSTYLE field code ────────────────────

make_docstyle_field_code_para <- function(class, source, display_text, style_id = NULL) {
  if (is.null(style_id)) {
    style_id <- paste0(toupper(substring(class, 1, 1)), substring(class, 2))
  }

  # Build JSON payload and XML-escape it (matching char-style.lua behaviour)
  # The source field may contain shortcode angle brackets that need escaping
  json_source <- gsub("\\\\", "\\\\\\\\", source)
  json_source <- gsub('"', '\\\\"', json_source)
  json <- sprintf('{"type":"char","version":1,"class":"%s","source":"%s"}', class, json_source)
  json_xml <- gsub("&", "&amp;", json)
  json_xml <- gsub("<", "&lt;", json_xml)
  json_xml <- gsub(">", "&gt;", json_xml)
  json_xml <- gsub('"', "&quot;", json_xml)
  json_xml <- gsub("'", "&apos;", json_xml)

  sprintf('<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:r><w:t xml:space="preserve">Date: </w:t></w:r>
  <w:r><w:fldChar w:fldCharType="begin"/></w:r>
  <w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE %s </w:instrText></w:r>
  <w:r><w:fldChar w:fldCharType="separate"/></w:r>
  <w:r><w:rPr><w:rStyle w:val="%s"/></w:rPr><w:t xml:space="preserve">%s</w:t></w:r>
  <w:r><w:fldChar w:fldCharType="end"/></w:r>
</w:p>', json_xml, style_id, display_text)
}

# ── Helper: parse paragraph XML and extract text ────────────────────────────

extract_from_para_xml <- function(para_xml) {
  doc <- xml2::read_xml(para_xml)
  ns <- xml2::xml_ns(doc)
  # Ensure we have the 'w' prefix
  if (!"w" %in% names(ns)) {
    ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  }
  result <- docstyle:::extract_formatted_text(doc, ns)
  result$text
}


# ══ Basic field code parsing ════════════════════════════════════════════════

test_that("DOCSTYLE field code restores date shortcode source", {
  para_xml <- make_docstyle_field_code_para(
    class = "date",
    source = "[{{< meta version-summary.date >}}]{.date}",
    display_text = "2025-12-11",
    style_id = "Date"
  )

  text <- extract_from_para_xml(para_xml)

  # Should contain the shortcode source, not the display text
  expect_true(grepl("\\{\\{< meta version-summary\\.date >\\}\\}", text))
  expect_true(grepl("\\]\\{\\.date\\}", text, perl = TRUE))
  # Display text should NOT appear
  expect_false(grepl("2025-12-11", text))
  # Prefix text should still be there
  expect_true(grepl("^Date: ", text))
})

test_that("DOCSTYLE field code restores version shortcode source", {
  para_xml <- make_docstyle_field_code_para(
    class = "version",
    source = "[{{< meta version-summary.version >}}]{.version}",
    display_text = "0.2.0",
    style_id = "Version"
  )

  text <- extract_from_para_xml(para_xml)

  expect_true(grepl("\\{\\{< meta version-summary\\.version >\\}\\}", text))
  expect_false(grepl("0\\.2\\.0", text))
})

test_that("DOCSTYLE field code restores explicit content source", {
  para_xml <- make_docstyle_field_code_para(
    class = "author",
    source = "[Jane Smith]{.author}",
    display_text = "Jane Smith",
    style_id = "Author"
  )

  text <- extract_from_para_xml(para_xml)

  expect_true(grepl("\\[Jane Smith\\]\\{.author\\}", text))
  # The display text "Jane Smith" appears in the source, so just check
  # it's wrapped in the span syntax
  expect_true(grepl("\\[Jane Smith\\]\\{", text))
})


# ══ XML escaping round-trip ═════════════════════════════════════════════════

test_that("shortcode angle brackets survive XML escaping round-trip", {
  # This tests the critical path: {{< >}} must be XML-escaped in instrText
  # and correctly unescaped by the harvest
  source <- "[{{< meta version-summary.date >}}]{.date}"

  para_xml <- make_docstyle_field_code_para(
    class = "date",
    source = source,
    display_text = "2025-12-11"
  )

  text <- extract_from_para_xml(para_xml)

  # The exact source string should be restored
  expect_true(grepl(fixed = TRUE, source, text))
})


# ══ Multiple field codes in one paragraph ═══════════════════════════════════

test_that("multiple DOCSTYLE field codes in one paragraph are parsed independently", {
  para_xml <- '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:r><w:t xml:space="preserve">Date: </w:t></w:r>
  <w:r><w:fldChar w:fldCharType="begin"/></w:r>
  <w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE {&quot;type&quot;:&quot;char&quot;,&quot;version&quot;:1,&quot;class&quot;:&quot;date&quot;,&quot;source&quot;:&quot;[{{&lt; meta version-summary.date &gt;}}]{.date}&quot;} </w:instrText></w:r>
  <w:r><w:fldChar w:fldCharType="separate"/></w:r>
  <w:r><w:rPr><w:rStyle w:val="Date"/></w:rPr><w:t xml:space="preserve">2025-12-11</w:t></w:r>
  <w:r><w:fldChar w:fldCharType="end"/></w:r>
  <w:r><w:t xml:space="preserve"> | Version: </w:t></w:r>
  <w:r><w:fldChar w:fldCharType="begin"/></w:r>
  <w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE {&quot;type&quot;:&quot;char&quot;,&quot;version&quot;:1,&quot;class&quot;:&quot;version&quot;,&quot;source&quot;:&quot;[{{&lt; meta version-summary.version &gt;}}]{.version}&quot;} </w:instrText></w:r>
  <w:r><w:fldChar w:fldCharType="separate"/></w:r>
  <w:r><w:rPr><w:rStyle w:val="Version"/></w:rPr><w:t xml:space="preserve">0.2.0</w:t></w:r>
  <w:r><w:fldChar w:fldCharType="end"/></w:r>
</w:p>'

  text <- extract_from_para_xml(para_xml)

  expect_true(grepl("\\{\\{< meta version-summary\\.date >\\}\\}", text))
  expect_true(grepl("\\{\\{< meta version-summary\\.version >\\}\\}", text))
  expect_true(grepl("\\| Version:", text))
  expect_false(grepl("2025-12-11", text))
  expect_false(grepl("0\\.2\\.0", text))
})


# ══ Non-DOCSTYLE field codes pass through ═══════════════════════════════════

test_that("non-DOCSTYLE field codes are not affected", {
  # A plain Word field code (e.g., PAGE) should pass through normally
  para_xml <- '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:r><w:fldChar w:fldCharType="begin"/></w:r>
  <w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r>
  <w:r><w:fldChar w:fldCharType="separate"/></w:r>
  <w:r><w:t>3</w:t></w:r>
  <w:r><w:fldChar w:fldCharType="end"/></w:r>
</w:p>'

  text <- extract_from_para_xml(para_xml)

  # Display text should pass through for non-handled field codes
  expect_true(grepl("3", text))
})


# ══ Malformed JSON is handled gracefully ════════════════════════════════════

test_that("malformed DOCSTYLE JSON falls through gracefully", {
  para_xml <- '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:r><w:fldChar w:fldCharType="begin"/></w:r>
  <w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE {broken json} </w:instrText></w:r>
  <w:r><w:fldChar w:fldCharType="separate"/></w:r>
  <w:r><w:t>fallback text</w:t></w:r>
  <w:r><w:fldChar w:fldCharType="end"/></w:r>
</w:p>'

  text <- extract_from_para_xml(para_xml)

  # With malformed JSON, tryCatch returns NULL, skip_field_display stays FALSE,
  # so display text passes through
  expect_true(grepl("fallback text", text))
})

test_that("DOCSTYLE payload missing source field falls through", {
  # Valid JSON but no source field
  para_xml <- '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:r><w:fldChar w:fldCharType="begin"/></w:r>
  <w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE {&quot;type&quot;:&quot;div&quot;,&quot;version&quot;:1,&quot;name&quot;:&quot;version-history&quot;} </w:instrText></w:r>
  <w:r><w:fldChar w:fldCharType="separate"/></w:r>
  <w:r><w:t>Table content</w:t></w:r>
  <w:r><w:fldChar w:fldCharType="end"/></w:r>
</w:p>'

  text <- extract_from_para_xml(para_xml)

  # type=div with no source field should not be handled as char,
  # display text passes through
  expect_true(grepl("Table content", text))
})


# ══ Backward compatibility — no field codes ═════════════════════════════════

test_that("paragraph with plain styled run (no field code) passes through", {
  # Pre-field-code styled run — just rStyle, no ADDIN DOCSTYLE wrapper
  para_xml <- '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:r><w:t xml:space="preserve">Date: </w:t></w:r>
  <w:r>
    <w:rPr><w:rStyle w:val="Date"/></w:rPr>
    <w:t xml:space="preserve">2025-12-11</w:t>
  </w:r>
</w:p>'

  text <- extract_from_para_xml(para_xml)

  # Without field codes, the literal text should pass through
  expect_true(grepl("2025-12-11", text))
  expect_true(grepl("Date:", text))
})


# ══════════════════════════════════════════════════════════════════════════════
# Block-level ADDIN DOCSTYLE field codes (type="div")
# ══════════════════════════════════════════════════════════════════════════════

# ── Helper: create minimal docx from raw XML ─────────────────────────────────

create_test_docx <- function(doc_xml, dir = tempdir(), filename = "test.docx") {
  staging <- tempfile("docx_staging_")
  dir.create(staging)
  dir.create(file.path(staging, "word"))
  dir.create(file.path(staging, "_rels"))
  dir.create(file.path(staging, "word", "_rels"))
  on.exit(unlink(staging, recursive = TRUE))

  writeLines(doc_xml, file.path(staging, "word", "document.xml"))

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

# ── Helper: build docx XML with ADDIN DOCSTYLE div field code ────────────────

make_field_code_docx_xml <- function(div_name = "version-history",
                                      content_xml = NULL) {
  if (is.null(content_xml)) {
    content_xml <- '
    <w:p>
      <w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
      <w:r><w:t>Version history</w:t></w:r>
    </w:p>
    <w:tbl>
      <w:tr>
        <w:tc><w:p><w:r><w:t>Version</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>Description</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>Date</w:t></w:r></w:p></w:tc>
      </w:tr>
      <w:tr>
        <w:tc><w:p><w:r><w:t>1.0</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>Initial release</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>2025-01-15</w:t></w:r></w:p></w:tc>
      </w:tr>
    </w:tbl>'
  }

  # Build JSON payload and XML-escape it
  json <- sprintf('{"type":"div","version":1,"name":"%s"}', div_name)
  json_xml <- gsub('"', '&quot;', json)

  sprintf('<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
      <w:r><w:t>Introduction</w:t></w:r>
    </w:p>
    <w:p>
      <w:r><w:t>Some body text here.</w:t></w:r>
    </w:p>
    <w:p>
      <w:r><w:fldChar w:fldCharType="begin"/></w:r>
      <w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE %s </w:instrText></w:r>
      <w:r><w:fldChar w:fldCharType="separate"/></w:r>
    </w:p>
    %s
    <w:p>
      <w:r><w:fldChar w:fldCharType="end"/></w:r>
    </w:p>
    <w:p>
      <w:r><w:t>Text after the div.</w:t></w:r>
    </w:p>
  </w:body>
</w:document>', json_xml, content_xml)
}


# ── Helper: parse docx and run detect_docstyle_field_codes ───────────────────

detect_from_docx_xml <- function(doc_xml) {
  td <- tempfile("test_fc_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx(doc_xml, dir = td)

  parsed <- docstyle:::parse_docx_xml(docx)
  on.exit(unlink(parsed$temp_dir, recursive = TRUE), add = TRUE)
  body <- xml2::xml_find_first(parsed$doc_xml, ".//w:body", parsed$ns)
  children <- xml2::xml_children(body)

  list(
    ranges = docstyle:::detect_docstyle_field_codes(body, children, parsed$ns),
    body = body,
    children = children,
    ns = parsed$ns
  )
}


# ══ detect_docstyle_field_codes ══════════════════════════════════════════════

test_that("detect_docstyle_field_codes finds version-history field code", {
  doc_xml <- make_field_code_docx_xml("version-history")
  result <- detect_from_docx_xml(doc_xml)

  expect_length(result$ranges, 1)
  expect_equal(result$ranges[[1]]$name, "version-history")
  expect_equal(result$ranges[[1]]$div_open, "::: version-history")
  expect_equal(result$ranges[[1]]$div_close, ":::")
  # Range should span from begin paragraph to end paragraph
  expect_true(result$ranges[[1]]$start_idx < result$ranges[[1]]$end_idx)
})

test_that("detect_docstyle_field_codes finds author-plate field code", {
  content_xml <- '<w:p><w:r><w:t>Author Name</w:t></w:r></w:p>'
  doc_xml <- make_field_code_docx_xml("author-plate", content_xml)
  result <- detect_from_docx_xml(doc_xml)

  expect_length(result$ranges, 1)
  expect_equal(result$ranges[[1]]$name, "author-plate")
  expect_equal(result$ranges[[1]]$div_open, "::: author-plate")
  expect_equal(result$ranges[[1]]$div_close, ":::")
})

test_that("detect_docstyle_field_codes finds toc field code", {
  content_xml <- '<w:p>
    <w:r><w:fldChar w:fldCharType="begin"/></w:r>
    <w:r><w:instrText xml:space="preserve"> TOC \\o "1-3" \\h \\z \\u </w:instrText></w:r>
    <w:r><w:fldChar w:fldCharType="separate"/></w:r>
    <w:r><w:t>[Update field to generate table of contents]</w:t></w:r>
    <w:r><w:fldChar w:fldCharType="end"/></w:r>
  </w:p>'
  doc_xml <- make_field_code_docx_xml("toc", content_xml)
  result <- detect_from_docx_xml(doc_xml)

  expect_length(result$ranges, 1)
  expect_equal(result$ranges[[1]]$name, "toc")
  expect_equal(result$ranges[[1]]$div_open, "::: toc")
})

test_that("detect_docstyle_field_codes handles nested field codes (TOC inside DOCSTYLE)", {
  # TOC has its own begin/separate/end inside the DOCSTYLE field code
  content_xml <- '
  <w:p>
    <w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
    <w:r><w:t>Contents</w:t></w:r>
  </w:p>
  <w:p>
    <w:r><w:fldChar w:fldCharType="begin"/></w:r>
    <w:r><w:instrText xml:space="preserve"> TOC \\o "1-3" \\h \\z \\u </w:instrText></w:r>
    <w:r><w:fldChar w:fldCharType="separate"/></w:r>
    <w:r><w:t>[Update field]</w:t></w:r>
    <w:r><w:fldChar w:fldCharType="end"/></w:r>
  </w:p>'
  doc_xml <- make_field_code_docx_xml("toc", content_xml)
  result <- detect_from_docx_xml(doc_xml)

  # Should find exactly 1 range (the outer DOCSTYLE), not confused by inner TOC
  expect_length(result$ranges, 1)
  expect_equal(result$ranges[[1]]$name, "toc")
})

test_that("detect_docstyle_field_codes returns empty list when no field codes", {
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>Just text.</w:t></w:r></w:p>
  </w:body>
</w:document>'
  result <- detect_from_docx_xml(doc_xml)
  expect_length(result$ranges, 0)
})

test_that("detect_docstyle_field_codes ignores non-DOCSTYLE field codes", {
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:r><w:fldChar w:fldCharType="begin"/></w:r>
      <w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r>
      <w:r><w:fldChar w:fldCharType="separate"/></w:r>
      <w:r><w:t>3</w:t></w:r>
      <w:r><w:fldChar w:fldCharType="end"/></w:r>
    </w:p>
  </w:body>
</w:document>'
  result <- detect_from_docx_xml(doc_xml)
  expect_length(result$ranges, 0)
})

test_that("detect_docstyle_field_codes ignores char-type field codes", {
  # Inline char field codes should not be detected as block-level
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:r><w:fldChar w:fldCharType="begin"/></w:r>
      <w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE {&quot;type&quot;:&quot;char&quot;,&quot;version&quot;:1,&quot;class&quot;:&quot;date&quot;,&quot;source&quot;:&quot;[2025-01-15]{.date}&quot;} </w:instrText></w:r>
      <w:r><w:fldChar w:fldCharType="separate"/></w:r>
      <w:r><w:t>2025-01-15</w:t></w:r>
      <w:r><w:fldChar w:fldCharType="end"/></w:r>
    </w:p>
  </w:body>
</w:document>'
  result <- detect_from_docx_xml(doc_xml)
  expect_length(result$ranges, 0)
})

test_that("detect_docstyle_field_codes finds multiple field codes", {
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>Intro text.</w:t></w:r></w:p>
    <w:p>
      <w:r><w:fldChar w:fldCharType="begin"/></w:r>
      <w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE {&quot;type&quot;:&quot;div&quot;,&quot;version&quot;:1,&quot;name&quot;:&quot;toc&quot;} </w:instrText></w:r>
      <w:r><w:fldChar w:fldCharType="separate"/></w:r>
    </w:p>
    <w:p><w:r><w:t>[TOC placeholder]</w:t></w:r></w:p>
    <w:p>
      <w:r><w:fldChar w:fldCharType="end"/></w:r>
    </w:p>
    <w:p><w:r><w:t>Some content.</w:t></w:r></w:p>
    <w:p>
      <w:r><w:fldChar w:fldCharType="begin"/></w:r>
      <w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE {&quot;type&quot;:&quot;div&quot;,&quot;version&quot;:1,&quot;name&quot;:&quot;version-history&quot;} </w:instrText></w:r>
      <w:r><w:fldChar w:fldCharType="separate"/></w:r>
    </w:p>
    <w:tbl>
      <w:tr>
        <w:tc><w:p><w:r><w:t>Version</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>Description</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>Date</w:t></w:r></w:p></w:tc>
      </w:tr>
      <w:tr>
        <w:tc><w:p><w:r><w:t>1.0</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>Initial</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>2025-01-15</w:t></w:r></w:p></w:tc>
      </w:tr>
    </w:tbl>
    <w:p>
      <w:r><w:fldChar w:fldCharType="end"/></w:r>
    </w:p>
  </w:body>
</w:document>'
  result <- detect_from_docx_xml(doc_xml)

  expect_length(result$ranges, 2)
  expect_equal(result$ranges[[1]]$name, "toc")
  expect_equal(result$ranges[[2]]$name, "version-history")
})


# ══ Version history table parsing with field codes ═══════════════════════════

test_that("version history table is parsed from field code range", {
  doc_xml <- make_field_code_docx_xml("version-history")
  result <- detect_from_docx_xml(doc_xml)

  expect_length(result$ranges, 1)

  # Parse version history table from the range
  entries <- docstyle:::parse_version_history_table(
    result$children, result$ranges[[1]], result$ns
  )

  expect_false(is.null(entries))
  expect_length(entries, 1)
  expect_equal(entries[[1]]$version, "1.0")
  expect_equal(entries[[1]]$description, "Initial release")
  expect_equal(entries[[1]]$date, "2025-01-15")
})


# ══ Backward compatibility: bookmarks still work ═════════════════════════════

test_that("bookmark ranges still detected when no field codes present", {
  # This tests that the bookmark fallback in convert_to_qmd() still works
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>Intro.</w:t></w:r></w:p>
    <w:bookmarkStart w:id="900" w:name="_docstyle_version_history"/>
    <w:p>
      <w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
      <w:r><w:t>Version history</w:t></w:r>
    </w:p>
    <w:bookmarkEnd w:id="900"/>
  </w:body>
</w:document>'

  td <- tempfile("test_compat_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx(doc_xml, dir = td)

  parsed <- docstyle:::parse_docx_xml(docx)
  on.exit(unlink(parsed$temp_dir, recursive = TRUE), add = TRUE)
  body <- xml2::xml_find_first(parsed$doc_xml, ".//w:body", parsed$ns)
  children <- xml2::xml_children(body)

  # Field codes should find nothing
  fc_ranges <- docstyle:::detect_docstyle_field_codes(body, children, parsed$ns)
  expect_length(fc_ranges, 0)

  # Bookmarks should still work
  bk_ranges <- docstyle:::detect_docstyle_bookmarks(body, children, parsed$ns)
  expect_length(bk_ranges, 1)
  expect_equal(bk_ranges[[1]]$name, "_docstyle_version_history")
})


# ══ Section field codes (type="section") ═════════════════════════════════════

# ── Helper: build docx XML with section field code ───────────────────────────

make_section_field_code_docx_xml <- function(class = "section-body",
                                              page_break = FALSE,
                                              line_numbers = NULL) {
  # Build JSON payload with XML-escaped quotes
  json_parts <- paste0('{&quot;type&quot;:&quot;section&quot;,&quot;class&quot;:&quot;',
                        class, '&quot;')
  if (isTRUE(page_break)) {
    json_parts <- paste0(json_parts, ',&quot;page-break&quot;:true')
  }
  if (!is.null(line_numbers)) {
    json_parts <- paste0(json_parts, ',&quot;line-numbers&quot;:&quot;',
                          line_numbers, '&quot;')
  }
  json_parts <- paste0(json_parts, '}')

  sprintf('<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
      <w:r><w:t>Front Matter</w:t></w:r>
    </w:p>
    <w:p>
      <w:r><w:fldChar w:fldCharType="begin"/></w:r>
      <w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE %s </w:instrText></w:r>
      <w:r><w:fldChar w:fldCharType="separate"/></w:r>
    </w:p>
    <w:p>
      <w:pPr>
        <w:sectPr>
          <w:type w:val="continuous"/>
          <w:pgSz w:w="12240" w:h="15840"/>
          <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"
                   w:header="720" w:footer="720" w:gutter="0"/>
        </w:sectPr>
      </w:pPr>
    </w:p>
    <w:p>
      <w:r><w:fldChar w:fldCharType="end"/></w:r>
    </w:p>
    <w:p>
      <w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
      <w:r><w:t>Introduction</w:t></w:r>
    </w:p>
    <w:p>
      <w:r><w:t>Body content here.</w:t></w:r>
    </w:p>
  </w:body>
</w:document>', json_parts)
}


test_that("detect_docstyle_field_codes finds section-body field code", {
  doc_xml <- make_section_field_code_docx_xml("section-body")
  result <- detect_from_docx_xml(doc_xml)

  expect_length(result$ranges, 1)
  expect_equal(result$ranges[[1]]$name, "section-body")
  expect_equal(result$ranges[[1]]$type, "section")
  expect_equal(result$ranges[[1]]$div_open, "::: {.section-body}")
  expect_equal(result$ranges[[1]]$div_close, ":::")
})

test_that("section field code with page-break=true reconstructs attribute", {
  doc_xml <- make_section_field_code_docx_xml("section-body", page_break = TRUE)
  result <- detect_from_docx_xml(doc_xml)

  expect_length(result$ranges, 1)
  expect_equal(result$ranges[[1]]$div_open,
               '::: {.section-body page-break="true"}')
})

test_that("section field code with line-numbers reconstructs attribute", {
  doc_xml <- make_section_field_code_docx_xml("section-body",
                                               line_numbers = "continuous")
  result <- detect_from_docx_xml(doc_xml)

  expect_length(result$ranges, 1)
  expect_equal(result$ranges[[1]]$div_open,
               '::: {.section-body line-numbers="continuous"}')
})

test_that("section field code with all attributes reconstructs correctly", {
  doc_xml <- make_section_field_code_docx_xml("section-body",
                                               page_break = TRUE,
                                               line_numbers = "page")
  result <- detect_from_docx_xml(doc_xml)

  expect_length(result$ranges, 1)
  expect_equal(result$ranges[[1]]$div_open,
               '::: {.section-body page-break="true" line-numbers="page"}')
})

test_that("section-landscape field code detected correctly", {
  doc_xml <- make_section_field_code_docx_xml("section-landscape")
  result <- detect_from_docx_xml(doc_xml)

  expect_length(result$ranges, 1)
  expect_equal(result$ranges[[1]]$name, "section-landscape")
  expect_equal(result$ranges[[1]]$div_open, "::: {.section-landscape}")
})

test_that("section field code without optional attrs omits them", {
  doc_xml <- make_section_field_code_docx_xml("section-body",
                                               page_break = FALSE,
                                               line_numbers = NULL)
  result <- detect_from_docx_xml(doc_xml)

  expect_length(result$ranges, 1)
  # No page-break or line-numbers in the div_open
  expect_equal(result$ranges[[1]]$div_open, "::: {.section-body}")
  expect_false(grepl("page-break", result$ranges[[1]]$div_open))
  expect_false(grepl("line-numbers", result$ranges[[1]]$div_open))
})


# ══ Native section break detection ════════════════════════════════════════════

# ── Helper: build docx XML with native section breaks ────────────────────────

make_native_section_docx_xml <- function(
    break_type = "continuous",
    with_line_numbers = FALSE,
    ln_restart = "continuous",
    sectpr_has_content = FALSE
) {
  ln_xml <- if (with_line_numbers) {
    sprintf('<w:lnNumType w:countBy="1" w:restart="%s"/>', ln_restart)
  } else {
    ""
  }

  # The sectPr paragraph: either empty or with text content
  sectpr_para <- if (sectpr_has_content) {
    sprintf('<w:p>
      <w:pPr>
        <w:sectPr>
          <w:type w:val="%s"/>
          <w:pgSz w:w="12240" w:h="15840"/>
          %s
        </w:sectPr>
      </w:pPr>
      <w:r><w:t>Last paragraph of section.</w:t></w:r>
    </w:p>', break_type, ln_xml)
  } else {
    sprintf('<w:p>
      <w:pPr>
        <w:sectPr>
          <w:type w:val="%s"/>
          <w:pgSz w:w="12240" w:h="15840"/>
          %s
        </w:sectPr>
      </w:pPr>
    </w:p>', break_type, ln_xml)
  }

  sprintf('<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
      <w:r><w:t>Front Matter</w:t></w:r>
    </w:p>
    <w:p>
      <w:r><w:t>Keywords: something</w:t></w:r>
    </w:p>
    %s
    <w:p>
      <w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
      <w:r><w:t>Introduction</w:t></w:r>
    </w:p>
    <w:p>
      <w:r><w:t>Body content here.</w:t></w:r>
    </w:p>
    <w:sectPr>
      <w:pgSz w:w="12240" w:h="15840"/>
    </w:sectPr>
  </w:body>
</w:document>', sectpr_para)
}

# ── Helper: parse XML and run detect_native_section_breaks ───────────────────

detect_native_from_xml <- function(doc_xml) {
  td <- tempfile("test_native_sec_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx(doc_xml, dir = td)

  parsed <- docstyle:::parse_docx_xml(docx)
  on.exit(unlink(parsed$temp_dir, recursive = TRUE), add = TRUE)
  body <- xml2::xml_find_first(parsed$doc_xml, ".//w:body", parsed$ns)
  children <- xml2::xml_children(body)

  list(
    breaks = docstyle:::detect_native_section_breaks(children, parsed$ns),
    children = children,
    ns = parsed$ns,
    n_children = length(children)
  )
}

test_that("detect_native_section_breaks finds mid-document sectPr", {
  doc_xml <- make_native_section_docx_xml("continuous", FALSE)
  result <- detect_native_from_xml(doc_xml)

  expect_length(result$breaks, 1)
  expect_equal(result$breaks[[1]]$type, "continuous")
  expect_false(result$breaks[[1]]$has_line_numbers)
  expect_false(result$breaks[[1]]$has_content)
})

test_that("detect_native_section_breaks extracts line numbering", {
  doc_xml <- make_native_section_docx_xml("continuous", TRUE, "continuous")
  result <- detect_native_from_xml(doc_xml)

  expect_length(result$breaks, 1)
  expect_true(result$breaks[[1]]$has_line_numbers)
  expect_equal(result$breaks[[1]]$line_numbers_restart, "continuous")
})

test_that("detect_native_section_breaks extracts newSection restart", {
  doc_xml <- make_native_section_docx_xml("nextPage", TRUE, "newSection")
  result <- detect_native_from_xml(doc_xml)

  expect_length(result$breaks, 1)
  expect_equal(result$breaks[[1]]$type, "nextPage")
  expect_equal(result$breaks[[1]]$line_numbers_restart, "newSection")
})

test_that("detect_native_section_breaks detects content in sectPr paragraph", {
  doc_xml <- make_native_section_docx_xml("continuous", TRUE, "continuous",
                                           sectpr_has_content = TRUE)
  result <- detect_native_from_xml(doc_xml)

  expect_length(result$breaks, 1)
  expect_true(result$breaks[[1]]$has_content)
})

test_that("detect_native_section_breaks ignores final body sectPr", {
  # The final w:sectPr is a direct child of w:body, not inside w:pPr
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:r><w:t>Content.</w:t></w:r>
    </w:p>
    <w:sectPr>
      <w:pgSz w:w="12240" w:h="15840"/>
      <w:lnNumType w:countBy="1" w:restart="continuous"/>
    </w:sectPr>
  </w:body>
</w:document>'
  result <- detect_native_from_xml(doc_xml)
  expect_length(result$breaks, 0)
})

test_that("detect_native_section_breaks extracts countBy, start, distance", {
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>Front matter</w:t></w:r></w:p>
    <w:p>
      <w:pPr>
        <w:sectPr>
          <w:type w:val="continuous"/>
          <w:pgSz w:w="12240" w:h="15840"/>
          <w:lnNumType w:countBy="5" w:restart="newPage" w:distance="720" w:start="10"/>
        </w:sectPr>
      </w:pPr>
    </w:p>
    <w:p><w:r><w:t>Body text</w:t></w:r></w:p>
    <w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr>
  </w:body>
</w:document>'
  result <- detect_native_from_xml(doc_xml)

  expect_length(result$breaks, 1)
  brk <- result$breaks[[1]]
  expect_true(brk$has_line_numbers)
  expect_equal(brk$line_numbers_restart, "newPage")
  expect_equal(brk$line_numbers_count_by, "5")
  expect_equal(brk$line_numbers_start, "10")
  expect_equal(brk$line_numbers_distance, "720")
})

test_that("section_breaks_to_ranges emits extended line number div attrs", {
  breaks <- list(
    list(idx = 3L, type = "continuous", has_line_numbers = TRUE,
         line_numbers_restart = "newPage",
         line_numbers_count_by = "5",
         line_numbers_start = "10",
         line_numbers_distance = "720",
         footer_refs = list(), page_start = NULL, has_title_pg = FALSE,
         has_content = FALSE, has_page_break = FALSE)
  )
  ranges <- docstyle:::section_breaks_to_ranges(breaks, 10L)

  expect_length(ranges, 1)
  div <- ranges[[1]]$div_open
  expect_true(grepl('line-numbers="page"', div))
  expect_true(grepl('line-numbers-count-by="5"', div))
  expect_true(grepl('line-numbers-start="10"', div))
  expect_true(grepl('line-numbers-distance="0.50in"', div))
})

test_that("section_breaks_to_ranges omits default line number attrs", {
  # countBy=1 and distance=360 are defaults — should not appear in div attrs
  breaks <- list(
    list(idx = 3L, type = "continuous", has_line_numbers = TRUE,
         line_numbers_restart = "continuous",
         line_numbers_count_by = "1",
         line_numbers_start = NULL,
         line_numbers_distance = "360",
         footer_refs = list(), page_start = NULL, has_title_pg = FALSE,
         has_content = FALSE, has_page_break = FALSE)
  )
  ranges <- docstyle:::section_breaks_to_ranges(breaks, 10L)

  expect_length(ranges, 1)
  div <- ranges[[1]]$div_open
  expect_true(grepl('line-numbers="continuous"', div))
  expect_false(grepl('line-numbers-count-by', div))
  expect_false(grepl('line-numbers-start', div))
  expect_false(grepl('line-numbers-distance', div))
})

test_that("section_breaks_to_ranges wraps only sections with line numbers", {
  breaks <- list(
    list(idx = 3L, type = "continuous", has_line_numbers = FALSE,
         line_numbers_restart = NULL, has_content = FALSE),
    list(idx = 10L, type = "continuous", has_line_numbers = TRUE,
         line_numbers_restart = "continuous", has_content = FALSE)
  )
  ranges <- docstyle:::section_breaks_to_ranges(breaks, 15L)

  expect_length(ranges, 1)
  # Section 2: paras 4 to 9 (content_end = 10 - 1 because empty sectPr para)
  expect_equal(ranges[[1]]$start_idx, 4L)
  expect_equal(ranges[[1]]$end_idx, 9L)
  expect_equal(ranges[[1]]$type, "native-section")
  expect_true(grepl('line-numbers="continuous"', ranges[[1]]$div_open))
  expect_false(grepl('page-break', ranges[[1]]$div_open))
})

test_that("section_breaks_to_ranges preserves different restart modes", {
  breaks <- list(
    list(idx = 3L, type = "continuous", has_line_numbers = FALSE,
         line_numbers_restart = NULL, has_content = FALSE),
    list(idx = 10L, type = "continuous", has_line_numbers = TRUE,
         line_numbers_restart = "continuous", has_content = FALSE),
    list(idx = 20L, type = "nextPage", has_line_numbers = TRUE,
         line_numbers_restart = "newSection", has_content = FALSE)
  )
  ranges <- docstyle:::section_breaks_to_ranges(breaks, 25L)

  # Two separate wrappers (not merged)
  expect_length(ranges, 2)

  # First: continuous line numbers
  expect_equal(ranges[[1]]$start_idx, 4L)
  expect_equal(ranges[[1]]$end_idx, 9L)
  expect_true(grepl('line-numbers="continuous"', ranges[[1]]$div_open))
  expect_false(grepl('page-break', ranges[[1]]$div_open))


  # Second: section restart + page break
  expect_equal(ranges[[2]]$start_idx, 11L)
  expect_equal(ranges[[2]]$end_idx, 19L)
  expect_true(grepl('line-numbers="section"', ranges[[2]]$div_open))
  expect_true(grepl('page-break="true"', ranges[[2]]$div_open))
})

test_that("section_breaks_to_ranges includes sectPr para when it has content", {
  breaks <- list(
    list(idx = 5L, type = "continuous", has_line_numbers = TRUE,
         line_numbers_restart = "continuous", has_content = TRUE)
  )
  ranges <- docstyle:::section_breaks_to_ranges(breaks, 10L)

  expect_length(ranges, 1)
  # content_end includes the sectPr paragraph itself
  expect_equal(ranges[[1]]$end_idx, 5L)
})

test_that("native section detection deferred when field codes exist", {
  # Document with ADDIN DOCSTYLE section field code
  doc_xml <- make_section_field_code_docx_xml("section-body",
                                               line_numbers = "continuous")
  result <- detect_from_docx_xml(doc_xml)

  # Field code should be detected
  has_section <- any(vapply(result$ranges,
    function(r) identical(r$type, "section"), logical(1)))
  expect_true(has_section)
})
