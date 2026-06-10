# Tests for generated content round-trip markers (issue #21)
#
# Tests that _docstyle_* bookmarks in OOXML are correctly detected by harvest
# and restored as div placeholders, and that validation handles them properly.

# Helper: create minimal docx from XML (same as test-validate-harvest.R)
create_test_docx <- function(doc_xml, comments_xml = NULL, dir = tempdir(),
                             filename = "test.docx") {
  staging <- tempfile("docx_staging_")
  dir.create(staging)
  dir.create(file.path(staging, "word"))
  dir.create(file.path(staging, "_rels"))
  dir.create(file.path(staging, "word", "_rels"))
  on.exit(unlink(staging, recursive = TRUE))

  writeLines(doc_xml, file.path(staging, "word", "document.xml"))
  if (!is.null(comments_xml)) {
    writeLines(comments_xml, file.path(staging, "word", "comments.xml"))
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

# ── Helper: docx XML with bookmarks ─────────────────────────────────────────

make_bookmarked_docx_xml <- function(bookmark_name = "_docstyle_version_history",
                                      bookmark_id = "900",
                                      content_xml = NULL) {
  if (is.null(content_xml)) {
    content_xml <- '
    <w:p>
      <w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
      <w:r><w:t>Version history</w:t></w:r>
    </w:p>
    <w:tbl>
      <w:tr><w:tc><w:p><w:r><w:t>v1.0</w:t></w:r></w:p></w:tc></w:tr>
    </w:tbl>'
  }

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
    <w:bookmarkStart w:id="%s" w:name="%s"/>
    %s
    <w:bookmarkEnd w:id="%s"/>
  </w:body>
</w:document>', bookmark_id, bookmark_name, content_xml, bookmark_id)
}


# ══ detect_docstyle_bookmarks ═══════════════════════════════════════════════

test_that("detect_docstyle_bookmarks finds _docstyle_* bookmarks", {
  doc_xml <- make_bookmarked_docx_xml()

  td <- tempfile("test_bm_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx(doc_xml, dir = td)

  parsed <- docstyle:::parse_docx_xml(docx)
  on.exit(unlink(parsed$temp_dir, recursive = TRUE), add = TRUE)
  body <- xml2::xml_find_first(parsed$doc_xml, ".//w:body", parsed$ns)
  children <- xml2::xml_children(body)

  ranges <- docstyle:::detect_docstyle_bookmarks(body, children, parsed$ns)

  expect_length(ranges, 1)
  expect_equal(ranges[[1]]$name, "_docstyle_version_history")
  expect_equal(ranges[[1]]$div_open, "::: version-history")
  expect_equal(ranges[[1]]$div_close, ":::")
  expect_true(ranges[[1]]$start_idx <= ranges[[1]]$end_idx)
})

test_that("detect_docstyle_bookmarks returns empty for no bookmarks", {
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>Hello</w:t></w:r></w:p>
  </w:body>
</w:document>'

  td <- tempfile("test_nobm_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx(doc_xml, dir = td)

  parsed <- docstyle:::parse_docx_xml(docx)
  on.exit(unlink(parsed$temp_dir, recursive = TRUE), add = TRUE)
  body <- xml2::xml_find_first(parsed$doc_xml, ".//w:body", parsed$ns)
  children <- xml2::xml_children(body)

  ranges <- docstyle:::detect_docstyle_bookmarks(body, children, parsed$ns)
  expect_length(ranges, 0)
})

test_that("detect_docstyle_bookmarks finds multiple bookmark types", {
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:bookmarkStart w:id="901" w:name="_docstyle_author_plate"/>
    <w:p><w:pPr><w:pStyle w:val="Author"/></w:pPr>
      <w:r><w:t>John Doe</w:t></w:r></w:p>
    <w:bookmarkEnd w:id="901"/>
    <w:p><w:r><w:t>Body text</w:t></w:r></w:p>
    <w:bookmarkStart w:id="900" w:name="_docstyle_version_history"/>
    <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
      <w:r><w:t>Version history</w:t></w:r></w:p>
    <w:bookmarkEnd w:id="900"/>
  </w:body>
</w:document>'

  td <- tempfile("test_multi_bm_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx(doc_xml, dir = td)

  parsed <- docstyle:::parse_docx_xml(docx)
  on.exit(unlink(parsed$temp_dir, recursive = TRUE), add = TRUE)
  body <- xml2::xml_find_first(parsed$doc_xml, ".//w:body", parsed$ns)
  children <- xml2::xml_children(body)

  ranges <- docstyle:::detect_docstyle_bookmarks(body, children, parsed$ns)

  expect_length(ranges, 2)
  names <- vapply(ranges, function(r) r$name, character(1))
  expect_true("_docstyle_author_plate" %in% names)
  expect_true("_docstyle_version_history" %in% names)
})

test_that("detect_docstyle_bookmarks ignores non-docstyle bookmarks", {
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:bookmarkStart w:id="1" w:name="_GoBack"/>
    <w:p><w:r><w:t>Hello</w:t></w:r></w:p>
    <w:bookmarkEnd w:id="1"/>
  </w:body>
</w:document>'

  td <- tempfile("test_ignore_bm_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx(doc_xml, dir = td)

  parsed <- docstyle:::parse_docx_xml(docx)
  on.exit(unlink(parsed$temp_dir, recursive = TRUE), add = TRUE)
  body <- xml2::xml_find_first(parsed$doc_xml, ".//w:body", parsed$ns)
  children <- xml2::xml_children(body)

  ranges <- docstyle:::detect_docstyle_bookmarks(body, children, parsed$ns)
  expect_length(ranges, 0)
})


# ══ check_bookmark_range ════════════════════════════════════════════════════

test_that("check_bookmark_range returns NULL outside range", {
  ranges <- list(list(
    name = "_docstyle_version_history",
    start_idx = 3, end_idx = 5,
    div_open = "::: version-history", div_close = ":::"
  ))
  expect_null(docstyle:::check_bookmark_range(1, ranges))
  expect_null(docstyle:::check_bookmark_range(6, ranges))
})

test_that("check_bookmark_range returns is_first for start of range", {
  ranges <- list(list(
    name = "_docstyle_version_history",
    start_idx = 3, end_idx = 5,
    div_open = "::: version-history", div_close = ":::"
  ))
  hit <- docstyle:::check_bookmark_range(3, ranges)
  expect_true(hit$is_first)
  expect_equal(hit$div_open, "::: version-history")
})

test_that("check_bookmark_range returns is_first=FALSE for middle of range", {
  ranges <- list(list(
    name = "_docstyle_version_history",
    start_idx = 3, end_idx = 5,
    div_open = "::: version-history", div_close = ":::"
  ))
  hit <- docstyle:::check_bookmark_range(4, ranges)
  expect_false(hit$is_first)
})


# ══ extract_docx_plain_text excludes bookmarked content ═════════════════════

test_that("extract_docx_plain_text excludes bookmarked content from word count", {
  doc_xml <- make_bookmarked_docx_xml()

  td <- tempfile("test_extract_bm_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx(doc_xml, dir = td)

  result <- docstyle:::extract_docx_plain_text(docx_path = docx)

  # Should contain "Introduction" and "Some body text here" but NOT "Version history" or "v1.0"
  all_text <- paste(result$paragraphs, collapse = " ")
  expect_true(grepl("Introduction", all_text))
  expect_true(grepl("body text", all_text))
  expect_false(grepl("Version history", all_text))
})

test_that("extract_docx_plain_text includes all content when no bookmarks", {
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
      <w:r><w:t>Introduction</w:t></w:r></w:p>
    <w:p><w:r><w:t>Body text</w:t></w:r></w:p>
    <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
      <w:r><w:t>Version history</w:t></w:r></w:p>
  </w:body>
</w:document>'

  td <- tempfile("test_extract_nobm_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx(doc_xml, dir = td)

  result <- docstyle:::extract_docx_plain_text(docx_path = docx)
  all_text <- paste(result$paragraphs, collapse = " ")
  expect_true(grepl("Version history", all_text))
})


# ══ strip_generated_content ═════════════════════════════════════════════════

test_that("strip_generated_content strips class-based version-history div", {
  qmd_body <- "Some text\n\n::: version-history\n:::\n\nMore text"
  result <- docstyle:::strip_generated_content(qmd_body)
  expect_false(grepl("version-history", result$body))
  expect_true("version_history" %in% names(result$sections_stripped))
})

test_that("strip_generated_content strips class-based author-plate div", {
  qmd_body <- "Some text\n\n::: author-plate\n:::\n\nMore text"
  result <- docstyle:::strip_generated_content(qmd_body)
  expect_false(grepl("author-plate", result$body))
  expect_true("author_plate" %in% names(result$sections_stripped))
})

test_that("strip_generated_content strips class-based toc div", {
  qmd_body <- "Some text\n\n::: toc\n:::\n\nMore text"
  result <- docstyle:::strip_generated_content(qmd_body)
  expect_false(grepl("::: toc", result$body))
  expect_true("toc" %in% names(result$sections_stripped))
})

test_that("strip_generated_content still strips ID-based div syntax", {
  qmd_body <- "Some text\n\n::: {#refs}\n:::\n\nMore text"
  result <- docstyle:::strip_generated_content(qmd_body)
  expect_true("bibliography" %in% names(result$sections_stripped))
})


# ══ warn_annotations_in_generated_content ═════════════════════════════════════════

test_that("warn_annotations_in_generated_content warns about tracked changes", {
  doc_xml <- make_bookmarked_docx_xml(
    content_xml = '
    <w:p>
      <w:ins w:id="50" w:author="Editor" w:date="2025-01-15T10:00:00Z">
        <w:r><w:t>Inserted text</w:t></w:r>
      </w:ins>
    </w:p>')

  td <- tempfile("test_warn_rev_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx(doc_xml, dir = td)

  parsed <- docstyle:::parse_docx_xml(docx)
  on.exit(unlink(parsed$temp_dir, recursive = TRUE), add = TRUE)
  body <- xml2::xml_find_first(parsed$doc_xml, ".//w:body", parsed$ns)
  children <- xml2::xml_children(body)
  bookmark_ranges <- docstyle:::detect_docstyle_bookmarks(body, children, parsed$ns)

  expect_warning(
    docstyle:::warn_annotations_in_generated_content(bookmark_ranges, children, parsed$ns),
    "tracked change"
  )
})

test_that("warn_annotations_in_generated_content warns about comments", {
  doc_xml <- make_bookmarked_docx_xml(
    content_xml = '
    <w:p>
      <w:commentRangeStart w:id="10"/>
      <w:r><w:t>Commented text</w:t></w:r>
      <w:commentRangeEnd w:id="10"/>
    </w:p>')

  td <- tempfile("test_warn_cmt_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx(doc_xml, dir = td)

  parsed <- docstyle:::parse_docx_xml(docx)
  on.exit(unlink(parsed$temp_dir, recursive = TRUE), add = TRUE)
  body <- xml2::xml_find_first(parsed$doc_xml, ".//w:body", parsed$ns)
  children <- xml2::xml_children(body)
  bookmark_ranges <- docstyle:::detect_docstyle_bookmarks(body, children, parsed$ns)

  expect_warning(
    docstyle:::warn_annotations_in_generated_content(bookmark_ranges, children, parsed$ns),
    "comment"
  )
})

test_that("warn_annotations_in_generated_content silent when no annotations", {
  doc_xml <- make_bookmarked_docx_xml()

  td <- tempfile("test_warn_none_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx(doc_xml, dir = td)

  parsed <- docstyle:::parse_docx_xml(docx)
  on.exit(unlink(parsed$temp_dir, recursive = TRUE), add = TRUE)
  body <- xml2::xml_find_first(parsed$doc_xml, ".//w:body", parsed$ns)
  children <- xml2::xml_children(body)
  bookmark_ranges <- docstyle:::detect_docstyle_bookmarks(body, children, parsed$ns)

  expect_no_warning(
    docstyle:::warn_annotations_in_generated_content(bookmark_ranges, children, parsed$ns)
  )
})


# ══ find_annotations_in_bookmarks (expected loss) ═════════════════════════

test_that("find_annotations_in_bookmarks finds revisions", {
  doc_xml <- make_bookmarked_docx_xml(
    content_xml = '
    <w:p>
      <w:ins w:id="50" w:author="Editor" w:date="2025-01-15T10:00:00Z">
        <w:r><w:t>Inserted</w:t></w:r>
      </w:ins>
      <w:del w:id="51" w:author="Editor" w:date="2025-01-15T10:00:00Z">
        <w:r><w:delText>Deleted</w:delText></w:r>
      </w:del>
    </w:p>')

  td <- tempfile("test_find_rev_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx(doc_xml, dir = td)

  parsed <- docstyle:::parse_docx_xml(docx)
  on.exit(unlink(parsed$temp_dir, recursive = TRUE), add = TRUE)

  ids <- docstyle:::find_annotations_in_bookmarks(parsed$doc_xml, parsed$ns, "revisions")
  expect_true("50" %in% ids)
  expect_true("51" %in% ids)
})

test_that("find_annotations_in_bookmarks finds comments", {
  doc_xml <- make_bookmarked_docx_xml(
    content_xml = '
    <w:p>
      <w:commentRangeStart w:id="10"/>
      <w:r><w:t>Text</w:t></w:r>
      <w:commentRangeEnd w:id="10"/>
    </w:p>')

  td <- tempfile("test_find_cmt_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx(doc_xml, dir = td)

  parsed <- docstyle:::parse_docx_xml(docx)
  on.exit(unlink(parsed$temp_dir, recursive = TRUE), add = TRUE)

  ids <- docstyle:::find_annotations_in_bookmarks(parsed$doc_xml, parsed$ns, "comments")
  expect_equal(ids, "10")
})

test_that("find_annotations_in_bookmarks returns empty when no annotations", {
  doc_xml <- make_bookmarked_docx_xml()

  td <- tempfile("test_find_none_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx(doc_xml, dir = td)

  parsed <- docstyle:::parse_docx_xml(docx)
  on.exit(unlink(parsed$temp_dir, recursive = TRUE), add = TRUE)

  rev_ids <- docstyle:::find_annotations_in_bookmarks(parsed$doc_xml, parsed$ns, "revisions")
  cmt_ids <- docstyle:::find_annotations_in_bookmarks(parsed$doc_xml, parsed$ns, "comments")
  expect_length(rev_ids, 0)
  expect_length(cmt_ids, 0)
})


# ══ parse_version_history_table ═══════════════════════════════════════════

test_that("parse_version_history_table extracts entries from table", {
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
      <w:tc><w:p><w:r><w:t>1.0.0</w:t></w:r></w:p></w:tc>
      <w:tc><w:p><w:r><w:t>Initial release</w:t></w:r></w:p></w:tc>
      <w:tc><w:p><w:r><w:t>2025-01-15</w:t></w:r></w:p></w:tc>
    </w:tr>
    <w:tr>
      <w:tc><w:p><w:r><w:t>1.1.0</w:t></w:r></w:p></w:tc>
      <w:tc><w:p><w:r><w:t>Added new feature</w:t></w:r></w:p></w:tc>
      <w:tc><w:p><w:r><w:t>2025-06-01</w:t></w:r></w:p></w:tc>
    </w:tr>
  </w:tbl>'

  doc_xml <- make_bookmarked_docx_xml(content_xml = content_xml)

  td <- tempfile("test_parse_vh_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx(doc_xml, dir = td)

  parsed <- docstyle:::parse_docx_xml(docx)
  on.exit(unlink(parsed$temp_dir, recursive = TRUE), add = TRUE)
  body <- xml2::xml_find_first(parsed$doc_xml, ".//w:body", parsed$ns)
  children <- xml2::xml_children(body)
  bookmark_ranges <- docstyle:::detect_docstyle_bookmarks(body, children, parsed$ns)

  entries <- docstyle:::parse_version_history_table(children, bookmark_ranges[[1]], parsed$ns)

  expect_length(entries, 2)
  expect_equal(entries[[1]]$version, "1.0.0")
  expect_equal(entries[[1]]$description, "Initial release")
  expect_equal(entries[[1]]$date, "2025-01-15")
  expect_equal(entries[[2]]$version, "1.1.0")
  expect_equal(entries[[2]]$description, "Added new feature")
})

test_that("parse_version_history_table returns NULL when no table", {
  content_xml <- '
  <w:p>
    <w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
    <w:r><w:t>Version history</w:t></w:r>
  </w:p>'

  doc_xml <- make_bookmarked_docx_xml(content_xml = content_xml)

  td <- tempfile("test_parse_vh_notbl_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx(doc_xml, dir = td)

  parsed <- docstyle:::parse_docx_xml(docx)
  on.exit(unlink(parsed$temp_dir, recursive = TRUE), add = TRUE)
  body <- xml2::xml_find_first(parsed$doc_xml, ".//w:body", parsed$ns)
  children <- xml2::xml_children(body)
  bookmark_ranges <- docstyle:::detect_docstyle_bookmarks(body, children, parsed$ns)

  entries <- docstyle:::parse_version_history_table(children, bookmark_ranges[[1]], parsed$ns)
  expect_null(entries)
})


# ══ update_yaml_version_history ═══════════════════════════════════════════

test_that("update_yaml_version_history replaces existing block", {
  header <- c(
    "---",
    "title: \"My Doc\"",
    "version-history:",
    "  - version: \"0.1.0\"",
    "    date: \"2025-01-01\"",
    "    description: \"Initial\"",
    "format: docx",
    "---"
  )
  entries <- list(
    list(version = "1.0.0", description = "Final", date = "2025-06-01"),
    list(version = "1.1.0", description = "Update", date = "2025-07-01")
  )

  result <- docstyle:::update_yaml_version_history(header, entries)

  result_text <- paste(result, collapse = "\n")
  expect_true(grepl("1\\.0\\.0", result_text))
  expect_true(grepl("1\\.1\\.0", result_text))
  expect_false(grepl("0\\.1\\.0", result_text))
  expect_true(grepl("format: docx", result_text))
  expect_true(grepl("title:", result_text))
})

test_that("update_yaml_version_history inserts when no existing block", {
  header <- c(
    "---",
    "title: \"My Doc\"",
    "format: docx",
    "---"
  )
  entries <- list(
    list(version = "1.0.0", description = "Release", date = "2025-06-01")
  )

  result <- docstyle:::update_yaml_version_history(header, entries)

  result_text <- paste(result, collapse = "\n")
  expect_true(grepl("version-history:", result_text))
  expect_true(grepl("1\\.0\\.0", result_text))
  # Should still have closing ---
  expect_true(grepl("---$", result_text))
})

test_that("format_version_history_yaml formats entries correctly", {
  entries <- list(
    list(version = "1.0.0", description = "Initial", date = "2025-01-15")
  )
  lines <- docstyle:::format_version_history_yaml(entries)
  expect_equal(lines[1], "version-history:")
  expect_true(grepl("version: \"1.0.0\"", lines[2]))
  expect_true(grepl("date: \"2025-01-15\"", lines[3]))
  expect_true(grepl("description: \"Initial\"", lines[4]))
})
