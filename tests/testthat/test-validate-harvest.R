# ── Helper: create minimal docx from XML strings ──────────────────────────────

#' Create a minimal .docx file for testing
#'
#' @param doc_xml Character. XML content for word/document.xml
#' @param comments_xml Character or NULL. XML content for word/comments.xml
#' @param dir Path to directory where the .docx will be created
#' @param filename Name for the .docx file
#' @return Path to the created .docx file
create_test_docx <- function(doc_xml, comments_xml = NULL, dir = tempdir(),
                             filename = "test.docx", styles_xml = NULL) {
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

  if (!is.null(styles_xml)) {
    writeLines(styles_xml, file.path(staging, "word", "styles.xml"))
  }

  # Minimal [Content_Types].xml
  ct <- '<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="xml" ContentType="application/xml"/>
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Override PartName="/word/document.xml"
    ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>'
  writeLines(ct, file.path(staging, "[Content_Types].xml"))

  # Minimal _rels/.rels
  rels <- '<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
    Target="word/document.xml"/>
</Relationships>'
  writeLines(rels, file.path(staging, "_rels", ".rels"))

  # word/_rels/document.xml.rels
  doc_rels <- '<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
</Relationships>'
  writeLines(doc_rels, file.path(staging, "word", "_rels", "document.xml.rels"))

  out_path <- file.path(dir, filename)
  # Create zip from staging directory
  old_wd <- getwd()
  setwd(staging)
  on.exit(setwd(old_wd), add = TRUE)
  files <- list.files(".", recursive = TRUE, all.files = TRUE)
  utils::zip(out_path, files, flags = "-q")

  out_path
}


# ══ Precondition gate ═══════════════════════════════════════════════════════

test_that("precondition gate passes for well-formed docx with body", {
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:r><w:t>Hello world</w:t></w:r>
    </w:p>
  </w:body>
</w:document>'

  td <- tempfile("test_precond_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx(doc_xml, dir = td)

  result <- docstyle:::check_xml_precondition(docx, verbose = FALSE)

  expect_true(result$pass)
  expect_true(result$summary$xml_parsed)
  expect_true(result$summary$has_body)
  expect_null(result$message)
})

test_that("precondition gate fails for non-existent file", {
  result <- validate_harvest("does_not_exist.docx", verbose = FALSE)
  expect_false(result$valid)
  expect_true(any(grepl("not found", result$issues$errors)))
})

test_that("precondition gate detects orphaned comment markers", {
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:commentRangeStart w:id="99"/>
      <w:r><w:t>Orphaned marker</w:t></w:r>
      <w:commentRangeEnd w:id="99"/>
    </w:p>
  </w:body>
</w:document>'

  # comments.xml exists but doesn't have comment 99
  comments_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:comments xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:comment w:id="1" w:author="Test">
    <w:p><w:r><w:t>A comment</w:t></w:r></w:p>
  </w:comment>
</w:comments>'

  td <- tempfile("test_orphan_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx(doc_xml, comments_xml = comments_xml, dir = td)

  result <- docstyle:::check_xml_precondition(docx, verbose = FALSE)

  expect_true(result$pass)  # Orphans are warnings, not failures
  expect_true(length(result$warnings) > 0)
  expect_true(any(grepl("comment marker", result$warnings)))
  expect_true("99" %in% result$details$orphaned_comment_markers)
})


# ══ Layer 1: Extraction fidelity ════════════════════════════════════════════

test_that("extraction fidelity matches comments between source and sidecar", {
  doc_xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:commentRangeStart w:id="1"/>
      <w:r><w:t>Text with comment</w:t></w:r>
      <w:commentRangeEnd w:id="1"/>
    </w:p>
  </w:body>
</w:document>'

  comments_xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
<w:comments xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:comment w:id="1" w:author="Tester">
    <w:p><w:r><w:t>A comment</w:t></w:r></w:p>
  </w:comment>
</w:comments>'

  td <- tempfile("test_extract_")
  dir.create(td)
  sidecar <- file.path(td, "_docstyle")
  dir.create(sidecar)
  on.exit(unlink(td, recursive = TRUE))

  doc_xml <- xml2::read_xml(doc_xml_str)
  ns <- xml2::xml_ns(doc_xml)
  comments_xml <- xml2::read_xml(comments_xml_str)

  # Matching sidecar
  jsonlite::write_json(
    list(list(id = "1", author = "Tester", content = "A comment")),
    file.path(sidecar, "comments.json"),
    auto_unbox = TRUE
  )

  result <- docstyle:::check_harvest_extraction(doc_xml, ns, comments_xml,
                                                 sidecar, verbose = FALSE)

  expect_true(result$checks$comments)
  expect_equal(result$summary$comments$source_count, 1)
  expect_equal(result$summary$comments$sidecar_count, 1)
  expect_length(result$details$comments$missing, 0)
})

test_that("extraction fidelity detects missing comments in sidecar", {
  doc_xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>Text</w:t></w:r></w:p>
  </w:body>
</w:document>'

  comments_xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
<w:comments xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:comment w:id="1" w:author="A"><w:p><w:r><w:t>c1</w:t></w:r></w:p></w:comment>
  <w:comment w:id="2" w:author="B"><w:p><w:r><w:t>c2</w:t></w:r></w:p></w:comment>
</w:comments>'

  td <- tempfile("test_missing_")
  dir.create(td)
  sidecar <- file.path(td, "_docstyle")
  dir.create(sidecar)
  on.exit(unlink(td, recursive = TRUE))

  doc_xml <- xml2::read_xml(doc_xml_str)
  ns <- xml2::xml_ns(doc_xml)
  comments_xml <- xml2::read_xml(comments_xml_str)

  # Sidecar only has comment 1
  jsonlite::write_json(
    list(list(id = "1", author = "A", content = "c1")),
    file.path(sidecar, "comments.json"),
    auto_unbox = TRUE
  )

  result <- docstyle:::check_harvest_extraction(doc_xml, ns, comments_xml,
                                                 sidecar, verbose = FALSE)

  expect_false(result$checks$comments)
  expect_true("2" %in% result$details$comments$missing)
  expect_true(length(result$errors) > 0)
})

test_that("extraction fidelity matches revisions between source and sidecar", {
  doc_xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:ins w:id="10" w:author="A"><w:r><w:t>inserted</w:t></w:r></w:ins>
      <w:del w:id="11" w:author="A"><w:r><w:delText>deleted</w:delText></w:r></w:del>
    </w:p>
  </w:body>
</w:document>'

  td <- tempfile("test_rev_")
  dir.create(td)
  sidecar <- file.path(td, "_docstyle")
  dir.create(sidecar)
  on.exit(unlink(td, recursive = TRUE))

  doc_xml <- xml2::read_xml(doc_xml_str)
  ns <- xml2::xml_ns(doc_xml)

  # Matching sidecar
  rev_data <- list(
    rev_10 = list(type = "insertion", content = "inserted"),
    rev_11 = list(type = "deletion", content = "deleted")
  )
  jsonlite::write_json(rev_data, file.path(sidecar, "revisions.json"),
                       auto_unbox = TRUE)

  result <- docstyle:::check_harvest_extraction(doc_xml, ns, NULL,
                                                 sidecar, verbose = FALSE)

  expect_true(result$checks$revisions)
  expect_equal(result$summary$revisions$source_count, 2)
  expect_equal(result$summary$revisions$sidecar_count, 2)
  expect_length(result$details$revisions$missing, 0)
})

test_that("extraction fidelity counts Zotero field codes", {
  doc_xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:r><w:fldChar w:fldCharType="begin"/></w:r>
      <w:r><w:instrText>ADDIN ZOTERO_ITEM CSL_CITATION {"citationItems":[{"id":"smith2020"}]}</w:instrText></w:r>
      <w:r><w:fldChar w:fldCharType="separate"/></w:r>
      <w:r><w:t>(Smith, 2020)</w:t></w:r>
      <w:r><w:fldChar w:fldCharType="end"/></w:r>
    </w:p>
    <w:p>
      <w:r><w:instrText>TOC \\o "1-3"</w:instrText></w:r>
    </w:p>
  </w:body>
</w:document>'

  doc_xml <- xml2::read_xml(doc_xml_str)
  ns <- xml2::xml_ns(doc_xml)

  result <- docstyle:::check_harvest_extraction(doc_xml, ns, NULL,
                                                 NULL, verbose = FALSE)

  expect_true(result$checks$citations)
  expect_equal(result$summary$citations$source_field_codes, 1)  # Only ZOTERO_ITEM
})

test_that("extraction fidelity works without sidecar", {
  doc_xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>Simple doc</w:t></w:r></w:p>
  </w:body>
</w:document>'

  doc_xml <- xml2::read_xml(doc_xml_str)
  ns <- xml2::xml_ns(doc_xml)

  result <- docstyle:::check_harvest_extraction(doc_xml, ns, NULL,
                                                 NULL, verbose = FALSE)

  expect_true(result$checks$citations)
  expect_true(result$checks$comments)
  expect_true(result$checks$revisions)
})

test_that("extraction fidelity handles empty document (no comments/revisions)", {
  doc_xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>No annotations here</w:t></w:r></w:p>
  </w:body>
</w:document>'

  td <- tempfile("test_empty_")
  dir.create(td)
  sidecar <- file.path(td, "_docstyle")
  dir.create(sidecar)
  on.exit(unlink(td, recursive = TRUE))

  doc_xml <- xml2::read_xml(doc_xml_str)
  ns <- xml2::xml_ns(doc_xml)

  # Empty sidecar files
  jsonlite::write_json(list(), file.path(sidecar, "comments.json"))
  jsonlite::write_json(list(), file.path(sidecar, "revisions.json"))

  result <- docstyle:::check_harvest_extraction(doc_xml, ns, NULL,
                                                 sidecar, verbose = FALSE)

  expect_true(result$checks$comments)
  expect_true(result$checks$revisions)
  expect_equal(result$summary$comments$source_count, 0)
  expect_equal(result$summary$revisions$source_count, 0)
})


# ══ Layer 2: Text fidelity ══════════════════════════════════════════════════

test_that("strip_generated_content removes version history div", {
  qmd_body <- "## Introduction

Some text here.

::: {#version-history}
## Version history

| Date | Author | Change |
|------|--------|--------|
| 2026-01-01 | Test | Initial |
:::

## Methods

More text here."

  result <- docstyle:::strip_generated_content(qmd_body)

  expect_true("version_history" %in% names(result$sections_stripped))
  expect_equal(result$sections_stripped$version_history$detected_by, "div")
  expect_false(grepl("Version history", result$body))
  expect_true(grepl("Introduction", result$body))
  expect_true(grepl("Methods", result$body))
})

test_that("strip_generated_content falls back to heading when no div", {
  qmd_body <- "## Introduction

Some text here.

## Version history

| Date | Author | Change |
|------|--------|--------|
| 2026-01-01 | Test | Initial |

## Methods

More text here."

  result <- docstyle:::strip_generated_content(qmd_body)

  expect_true("version_history" %in% names(result$sections_stripped))
  expect_equal(result$sections_stripped$version_history$detected_by, "heading")
  expect_false(grepl("Version history", result$body))
})

test_that("strip_generated_content removes bibliography div", {
  qmd_body <- "## Discussion

Final thoughts.

:::{#refs}
## References

Smith, J. (2020). A study.
:::
"

  result <- docstyle:::strip_generated_content(qmd_body)

  expect_true("bibliography" %in% names(result$sections_stripped))
  expect_equal(result$sections_stripped$bibliography$detected_by, "div")
})

test_that("strip_generated_content removes ZOTERO_PREF lines", {
  qmd_body <- "## Introduction

Some text.

ZOTERO_PREF {\"something\":\"value\"}

## Methods

More text."

  result <- docstyle:::strip_generated_content(qmd_body)

  expect_true("zotero_pref" %in% names(result$sections_stripped))
  expect_false(grepl("ZOTERO_PREF", result$body))
})

test_that("strip_generated_content handles QMD with no generated content", {
  qmd_body <- "## Introduction

Some text here.

## Methods

More text here."

  result <- docstyle:::strip_generated_content(qmd_body)

  expect_length(result$sections_stripped, 0)
  expect_true(grepl("Introduction", result$body))
})

test_that("check_harvest_text passes for similar word counts", {
  # Use enough words so that minor differences are < 5%
  words <- paste(rep("lorem ipsum dolor sit amet", 10), collapse = " ")
  docx_text <- list(
    paragraphs = c("Title", words),
    headings = data.frame(level = 1L, text = "Title",
                          stringsAsFactors = FALSE),
    table_count = 0L,
    word_count = 51L,
    char_count = 300L
  )
  qmd_body <- paste0("## Title\n\n", words)

  result <- docstyle:::check_harvest_text(docx_text, qmd_body, verbose = FALSE)

  expect_true(result$pass)
  expect_equal(result$severity, "ok")
})

test_that("check_harvest_text warns for 5-10% difference", {
  docx_text <- list(
    paragraphs = rep("word", 100),
    headings = data.frame(level = integer(), text = character(),
                          stringsAsFactors = FALSE),
    table_count = 0L,
    word_count = 100L,
    char_count = 500L
  )
  # QMD with ~92 words (8% difference)
  qmd_body <- paste(rep("word", 92), collapse = " ")

  result <- docstyle:::check_harvest_text(docx_text, qmd_body, verbose = FALSE)

  expect_true(result$pass)  # Warning, not error
  expect_equal(result$severity, "warning")
})

test_that("check_harvest_text fails for >10% difference", {
  docx_text <- list(
    paragraphs = rep("word", 100),
    headings = data.frame(level = integer(), text = character(),
                          stringsAsFactors = FALSE),
    table_count = 0L,
    word_count = 100L,
    char_count = 500L
  )
  # QMD with ~80 words (20% difference)
  qmd_body <- paste(rep("word", 80), collapse = " ")

  result <- docstyle:::check_harvest_text(docx_text, qmd_body, verbose = FALSE)

  expect_false(result$pass)
  expect_equal(result$severity, "error")
})


# ══ Layer 3: Structural fidelity ════════════════════════════════════════════

test_that("heading count matches when heading-detected section exists in both source and QMD", {
  # Heading-detected sections (e.g. bibliography) have their heading in BOTH
  # the source DOCX and QMD — no adjustment is needed for these.
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
      <w:r><w:t>Introduction</w:t></w:r></w:p>
    <w:p><w:r><w:t>Some text</w:t></w:r></w:p>
    <w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr>
      <w:r><w:t>References</w:t></w:r></w:p>
  </w:body>
</w:document>'

  td <- tempfile("test_heading_adj_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))

  docx <- create_test_docx(doc_xml, dir = td)

  docx_text <- docstyle:::extract_docx_plain_text(docx)

  # QMD has 2 headings matching source: "Introduction" + "References"
  qmd_body <- "# Introduction\n\nSome text\n\n## References\n\nBibliography content"

  generated <- list(
    bibliography = list(detected_by = "heading", word_count = 5)
  )

  parsed <- docstyle:::parse_docx_xml(docx)
  on.exit(unlink(parsed$temp_dir, recursive = TRUE), add = TRUE)

  result <- docstyle:::check_harvest_structure(
    parsed$doc_xml, parsed$ns, docx_text, qmd_body, NULL, verbose = FALSE,
    generated_sections = generated
  )

  # Heading-detected sections don't need adjustment — heading exists in both
  expect_true(result$checks$headings)
  expect_equal(result$summary$headings$generated, 0)
  expect_equal(result$summary$headings$qmd_adjusted, 2)
})

test_that("heading count does not adjust for div-detected content", {
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
      <w:r><w:t>Introduction</w:t></w:r></w:p>
    <w:p><w:r><w:t>Some text</w:t></w:r></w:p>
  </w:body>
</w:document>'

  td <- tempfile("test_heading_div_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))

  docx <- create_test_docx(doc_xml, dir = td)
  docx_text <- docstyle:::extract_docx_plain_text(docx)

  # QMD with div-detected version history (not heading-detected)
  qmd_body <- "# Introduction\n\nSome text"

  generated <- list(
    version_history = list(detected_by = "div", word_count = 5)
  )

  parsed <- docstyle:::parse_docx_xml(docx)
  on.exit(unlink(parsed$temp_dir, recursive = TRUE), add = TRUE)

  result <- docstyle:::check_harvest_structure(
    parsed$doc_xml, parsed$ns, docx_text, qmd_body, NULL, verbose = FALSE,
    generated_sections = generated
  )

  expect_true(result$checks$headings)
  expect_equal(result$summary$headings$generated, 0)
})

test_that("table count comparison works", {
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>Before table</w:t></w:r></w:p>
    <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
    <w:p><w:r><w:t>After table</w:t></w:r></w:p>
  </w:body>
</w:document>'

  td <- tempfile("test_table_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))

  docx <- create_test_docx(doc_xml, dir = td)
  docx_text <- docstyle:::extract_docx_plain_text(docx)

  qmd_body <- "Before table\n\n| Col |\n|-----|\n| Cell |\n\nAfter table"

  parsed <- docstyle:::parse_docx_xml(docx)
  on.exit(unlink(parsed$temp_dir, recursive = TRUE), add = TRUE)

  result <- docstyle:::check_harvest_structure(
    parsed$doc_xml, parsed$ns, docx_text, qmd_body, NULL, verbose = FALSE
  )

  expect_true(result$checks$tables)
  expect_equal(result$summary$tables$docx, 1)
  expect_equal(result$summary$tables$qmd, 1)
})


# ══ Expected loss registries ════════════════════════════════════════════════

test_that("classify_revision_loss identifies revisions in tables as expected", {
  doc_xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:tbl>
      <w:tr><w:tc><w:p>
        <w:ins w:id="5" w:author="A"><w:r><w:t>in table</w:t></w:r></w:ins>
      </w:p></w:tc></w:tr>
    </w:tbl>
    <w:p>
      <w:ins w:id="6" w:author="A"><w:r><w:t>in paragraph</w:t></w:r></w:ins>
    </w:p>
  </w:body>
</w:document>'

  doc_xml <- xml2::read_xml(doc_xml_str)
  ns <- xml2::xml_ns(doc_xml)

  # Both rev_5 and rev_6 are missing, but rev_5 is in a table

  result <- docstyle:::classify_revision_loss(c("rev_5", "rev_6"), doc_xml, ns)

  expect_true("rev_5" %in% result$expected)
  expect_true("rev_6" %in% result$unexpected)
  expect_true("revisions_in_tables" %in% names(result$by_pattern))
  expect_true("rev_5" %in% result$by_pattern$revisions_in_tables)
})

test_that("classify_revision_loss identifies empty content revisions as expected", {
  doc_xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:ins w:id="20" w:author="A">
        <w:r><w:rPr><w:b/></w:rPr></w:r>
      </w:ins>
      <w:del w:id="21" w:author="A">
        <w:r><w:rPr><w:i/></w:rPr></w:r>
      </w:del>
    </w:p>
  </w:body>
</w:document>'

  doc_xml <- xml2::read_xml(doc_xml_str)
  ns <- xml2::xml_ns(doc_xml)

  result <- docstyle:::classify_revision_loss(
    c("rev_20", "rev_21"), doc_xml, ns)

  expect_length(result$unexpected, 0)
  expect_true("rev_20" %in% result$expected)
  expect_true("rev_21" %in% result$expected)
  expect_true("revisions_empty_content" %in% names(result$by_pattern))
})

test_that("classify_comment_loss identifies comments in tables as expected", {
  doc_xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:tbl>
      <w:tr><w:tc><w:p>
        <w:commentRangeStart w:id="10"/>
        <w:r><w:t>in table</w:t></w:r>
        <w:commentRangeEnd w:id="10"/>
      </w:p></w:tc></w:tr>
    </w:tbl>
  </w:body>
</w:document>'

  doc_xml <- xml2::read_xml(doc_xml_str)
  ns <- xml2::xml_ns(doc_xml)

  result <- docstyle:::classify_comment_loss(c("10"), doc_xml, ns)

  expect_length(result$unexpected, 0)
  expect_true("10" %in% result$expected)
  expect_true("comments_in_tables" %in% names(result$by_pattern))
})

test_that("classify_comment_loss identifies comments on metadata as expected", {
  doc_xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:pPr><w:pStyle w:val="Title"/></w:pPr>
      <w:commentRangeStart w:id="0"/>
      <w:r><w:t>Document Title</w:t></w:r>
      <w:commentRangeEnd w:id="0"/>
    </w:p>
  </w:body>
</w:document>'

  doc_xml <- xml2::read_xml(doc_xml_str)
  ns <- xml2::xml_ns(doc_xml)

  result <- docstyle:::classify_comment_loss(c("0"), doc_xml, ns)

  expect_length(result$unexpected, 0)
  expect_true("0" %in% result$expected)
  expect_true("comments_on_metadata" %in% names(result$by_pattern))
})

test_that("classify_comment_loss flags unexpected loss for paragraph comments", {
  doc_xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:pPr><w:pStyle w:val="Normal"/></w:pPr>
      <w:commentRangeStart w:id="5"/>
      <w:r><w:t>Normal paragraph text</w:t></w:r>
      <w:commentRangeEnd w:id="5"/>
    </w:p>
  </w:body>
</w:document>'

  doc_xml <- xml2::read_xml(doc_xml_str)
  ns <- xml2::xml_ns(doc_xml)

  result <- docstyle:::classify_comment_loss(c("5"), doc_xml, ns)

  expect_length(result$expected, 0)
  expect_true("5" %in% result$unexpected)
})

test_that("classify_comment_loss identifies body-level comment markers", {
  doc_xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:commentRangeStart w:id="42"/>
    <w:p><w:r><w:t>Some text</w:t></w:r></w:p>
    <w:commentRangeEnd w:id="42"/>
  </w:body>
</w:document>'

  doc_xml <- xml2::read_xml(doc_xml_str)
  ns <- xml2::xml_ns(doc_xml)

  result <- docstyle:::classify_comment_loss(c("42"), doc_xml, ns)

  expect_length(result$unexpected, 0)
  expect_true("42" %in% result$expected)
  expect_true("comments_at_body_level" %in% names(result$by_pattern))
})

test_that("classify_revision_loss identifies pPr revisions as expected", {
  doc_xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:pPr>
        <w:rPr>
          <w:ins w:id="50" w:author="Sarah Beach" w:date="2026-01-15T00:00:00Z"/>
        </w:rPr>
      </w:pPr>
      <w:r><w:t>Paragraph with formatting change</w:t></w:r>
    </w:p>
    <w:p>
      <w:pPr>
        <w:rPr>
          <w:del w:id="51" w:author="Sarah Beach" w:date="2026-01-15T00:00:00Z"/>
        </w:rPr>
      </w:pPr>
      <w:r><w:t>Another paragraph</w:t></w:r>
    </w:p>
    <w:p>
      <w:ins w:id="52" w:author="Sarah Beach">
        <w:r><w:t>Real inserted text</w:t></w:r>
      </w:ins>
    </w:p>
  </w:body>
</w:document>'

  doc_xml <- xml2::read_xml(doc_xml_str)
  ns <- xml2::xml_ns(doc_xml)

  # rev_50 and rev_51 are pPr formatting-only; rev_52 is a real text insertion
  result <- docstyle:::classify_revision_loss(
    c("rev_50", "rev_51", "rev_52"), doc_xml, ns)

  expect_true("rev_50" %in% result$expected)
  expect_true("rev_51" %in% result$expected)
  expect_true("rev_52" %in% result$unexpected)
  expect_true("revisions_in_pPr" %in% names(result$by_pattern))
  expect_equal(sort(result$by_pattern$revisions_in_pPr),
               sort(c("rev_50", "rev_51")))
})

test_that("classify_revision_loss identifies revisions in field code ranges as expected", {
  doc_xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:r><w:fldChar w:fldCharType="begin"/></w:r>
      <w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE {"type":"div","name":"version-history"} </w:instrText></w:r>
      <w:r><w:fldChar w:fldCharType="separate"/></w:r>
    </w:p>
    <w:p>
      <w:ins w:id="70" w:author="A">
        <w:r><w:t>inside field code</w:t></w:r>
      </w:ins>
    </w:p>
    <w:p>
      <w:r><w:fldChar w:fldCharType="end"/></w:r>
    </w:p>
    <w:p>
      <w:ins w:id="71" w:author="A">
        <w:r><w:t>outside field code</w:t></w:r>
      </w:ins>
    </w:p>
  </w:body>
</w:document>'

  doc_xml <- xml2::read_xml(doc_xml_str)
  ns <- xml2::xml_ns(doc_xml)

  result <- docstyle:::classify_revision_loss(
    c("rev_70", "rev_71"), doc_xml, ns)

  expect_true("rev_70" %in% result$expected)
  expect_true("rev_71" %in% result$unexpected)
  expect_true("revisions_in_field_codes" %in% names(result$by_pattern))
})

test_that("classify_comment_loss identifies comments in field code ranges as expected", {
  doc_xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:r><w:fldChar w:fldCharType="begin"/></w:r>
      <w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE {"type":"div","name":"version-history"} </w:instrText></w:r>
      <w:r><w:fldChar w:fldCharType="separate"/></w:r>
    </w:p>
    <w:p>
      <w:commentRangeStart w:id="117"/>
      <w:r><w:t>inside field code</w:t></w:r>
      <w:commentRangeEnd w:id="117"/>
    </w:p>
    <w:p>
      <w:r><w:fldChar w:fldCharType="end"/></w:r>
    </w:p>
    <w:p>
      <w:commentRangeStart w:id="5"/>
      <w:r><w:t>outside field code</w:t></w:r>
      <w:commentRangeEnd w:id="5"/>
    </w:p>
  </w:body>
</w:document>'

  doc_xml <- xml2::read_xml(doc_xml_str)
  ns <- xml2::xml_ns(doc_xml)

  result <- docstyle:::classify_comment_loss(c("117", "5"), doc_xml, ns)

  expect_true("117" %in% result$expected)
  expect_true("5" %in% result$unexpected)
  expect_true("comments_in_field_codes" %in% names(result$by_pattern))
})

test_that("comments_on_metadata matches style name variants with prefix matching", {
  doc_xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:pPr><w:pStyle w:val="Title1"/></w:pPr>
      <w:commentRangeStart w:id="0"/>
      <w:r><w:t>Document Title</w:t></w:r>
      <w:commentRangeEnd w:id="0"/>
    </w:p>
    <w:p>
      <w:pPr><w:pStyle w:val="AuthorName"/></w:pPr>
      <w:commentRangeStart w:id="1"/>
      <w:r><w:t>John Smith</w:t></w:r>
      <w:commentRangeEnd w:id="1"/>
    </w:p>
    <w:p>
      <w:pPr><w:pStyle w:val="AbstractText"/></w:pPr>
      <w:commentRangeStart w:id="2"/>
      <w:r><w:t>Abstract content</w:t></w:r>
      <w:commentRangeEnd w:id="2"/>
    </w:p>
    <w:p>
      <w:pPr><w:pStyle w:val="Normal"/></w:pPr>
      <w:commentRangeStart w:id="3"/>
      <w:r><w:t>Normal paragraph</w:t></w:r>
      <w:commentRangeEnd w:id="3"/>
    </w:p>
  </w:body>
</w:document>'

  doc_xml <- xml2::read_xml(doc_xml_str)
  ns <- xml2::xml_ns(doc_xml)

  result <- docstyle:::classify_comment_loss(
    c("0", "1", "2", "3"), doc_xml, ns)

  # Title1, AuthorName, AbstractText should all match via prefix
  expect_true("0" %in% result$expected)
  expect_true("1" %in% result$expected)
  expect_true("2" %in% result$expected)
  # Normal should not match
  expect_true("3" %in% result$unexpected)
  expect_true("comments_on_metadata" %in% names(result$by_pattern))
})

test_that("classifiers return empty results when no IDs missing", {
  doc_xml_str <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body><w:p><w:r><w:t>Text</w:t></w:r></w:p></w:body>
</w:document>'

  doc_xml <- xml2::read_xml(doc_xml_str)
  ns <- xml2::xml_ns(doc_xml)

  rev_result <- docstyle:::classify_revision_loss(character(), doc_xml, ns)
  expect_length(rev_result$expected, 0)
  expect_length(rev_result$unexpected, 0)

  comment_result <- docstyle:::classify_comment_loss(character(), doc_xml, ns)
  expect_length(comment_result$expected, 0)
  expect_length(comment_result$unexpected, 0)
})


# ══ Shared helpers ══════════════════════════════════════════════════════════

test_that("strip_yaml_header removes YAML front matter", {
  lines <- c("---", "title: Test", "---", "## Heading", "", "Body text")
  result <- docstyle:::strip_yaml_header(lines)
  expect_true(grepl("## Heading", result))
  expect_false(grepl("title: Test", result))
})

test_that("strip_yaml_header handles file with no YAML", {
  lines <- c("## Heading", "", "Body text")
  result <- docstyle:::strip_yaml_header(lines)
  expect_true(grepl("## Heading", result))
})

test_that("detect_heading_level parses Word heading styles", {
  expect_equal(docstyle:::detect_heading_level("Heading1"), 1L)
  expect_equal(docstyle:::detect_heading_level("Heading2"), 2L)
  expect_equal(docstyle:::detect_heading_level("heading 3"), 3L)
  expect_true(is.na(docstyle:::detect_heading_level("Normal")))
  expect_true(is.na(docstyle:::detect_heading_level("BodyText")))
})

test_that("extract_docx_plain_text extracts paragraphs and headings", {
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
      <w:r><w:t>Title</w:t></w:r></w:p>
    <w:p><w:r><w:t>Body text with some words</w:t></w:r></w:p>
    <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
    <w:p><w:r><w:t>After table</w:t></w:r></w:p>
  </w:body>
</w:document>'

  td <- tempfile("test_plain_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))

  docx <- create_test_docx(doc_xml, dir = td)
  result <- docstyle:::extract_docx_plain_text(docx)

  expect_equal(result$table_count, 1L)
  expect_equal(nrow(result$headings), 1)
  expect_equal(result$headings$text, "Title")
  expect_equal(result$headings$level, 1L)
  expect_true(result$word_count > 0)
})

test_that("extract_paragraph_display_text skips instrText JSON", {
  # Build a paragraph with a Zotero field code
  p_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:r><w:t>Before </w:t></w:r>
  <w:r><w:fldChar w:fldCharType="begin"/></w:r>
  <w:r><w:instrText>ADDIN ZOTERO_ITEM {"big":"json"}</w:instrText></w:r>
  <w:r><w:fldChar w:fldCharType="separate"/></w:r>
  <w:r><w:t>(Smith 2020)</w:t></w:r>
  <w:r><w:fldChar w:fldCharType="end"/></w:r>
  <w:r><w:t> after</w:t></w:r>
</w:p>'

  p <- xml2::read_xml(p_xml)
  ns <- xml2::xml_ns(p)

  result <- docstyle:::extract_paragraph_display_text(p, ns)

  expect_true(grepl("Before", result))
  expect_true(grepl("Smith 2020", result))
  expect_true(grepl("after", result))
  expect_false(grepl("ZOTERO_ITEM", result))
  expect_false(grepl("big.*json", result))
})


# ══ Regression: custom heading style resolution (#126) ═════════════════════

test_that("extract_docx_plain_text counts custom styles basedOn Heading1", {
  # Paragraphs:
  #   1. Native Heading1 — must count
  #   2. Custom CVH1 basedOn Heading1 — must count after canonical resolution
  #   3. Plain Normal — must not count
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
      <w:r><w:t>Native heading</w:t></w:r></w:p>
    <w:p><w:pPr><w:pStyle w:val="CVH1"/></w:pPr>
      <w:r><w:t>Custom CV heading</w:t></w:r></w:p>
    <w:p><w:pPr><w:pStyle w:val="Normal"/></w:pPr>
      <w:r><w:t>Body paragraph</w:t></w:r></w:p>
  </w:body>
</w:document>'

  styles_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="paragraph" w:styleId="Heading1">
    <w:name w:val="heading 1"/>
  </w:style>
  <w:style w:type="paragraph" w:customStyle="1" w:styleId="CVH1">
    <w:name w:val="CV H1"/>
    <w:basedOn w:val="Heading1"/>
  </w:style>
  <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
    <w:name w:val="Normal"/>
  </w:style>
</w:styles>'

  td <- tempfile("test_cvh_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx(doc_xml, styles_xml = styles_xml, dir = td)

  result <- docstyle:::extract_docx_plain_text(docx)

  expect_equal(nrow(result$headings), 2L)
  expect_setequal(result$headings$text,
                  c("Native heading", "Custom CV heading"))
  expect_equal(result$headings$level, c(1L, 1L))
})

test_that("extract_docx_plain_text resolves outlineLvl-based custom headings", {
  # JournalH2 has no basedOn, but declares outlineLvl="1" → Heading2
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:pPr><w:pStyle w:val="JournalH2"/></w:pPr>
      <w:r><w:t>Journal subheading</w:t></w:r></w:p>
  </w:body>
</w:document>'

  styles_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="paragraph" w:customStyle="1" w:styleId="JournalH2">
    <w:name w:val="Journal H2"/>
    <w:pPr><w:outlineLvl w:val="1"/></w:pPr>
  </w:style>
</w:styles>'

  td <- tempfile("test_journalh_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx(doc_xml, styles_xml = styles_xml, dir = td)

  result <- docstyle:::extract_docx_plain_text(docx)

  expect_equal(nrow(result$headings), 1L)
  expect_equal(result$headings$text, "Journal subheading")
  expect_equal(result$headings$level, 2L)
})

test_that("extract_docx_plain_text resolves custom headings via display-name fallback", {
  # MDPI-style: custom styleId, no basedOn, no outlineLvl, but w:name matches
  # "heading 1" pattern. resolve_to_canonical() reaches this via its
  # display-name regex fallback (style_resolver.R, name-pattern branch).
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:pPr><w:pStyle w:val="MDPI21heading1"/></w:pPr>
      <w:r><w:t>Journal section heading</w:t></w:r></w:p>
  </w:body>
</w:document>'

  styles_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="paragraph" w:customStyle="1" w:styleId="MDPI21heading1">
    <w:name w:val="heading 1"/>
  </w:style>
</w:styles>'

  td <- tempfile("test_mdpi_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx(doc_xml, styles_xml = styles_xml, dir = td)

  result <- docstyle:::extract_docx_plain_text(docx)

  expect_equal(nrow(result$headings), 1L)
  expect_equal(result$headings$text, "Journal section heading")
  expect_equal(result$headings$level, 1L)
})

test_that("extract_docx_plain_text degrades to exact-match when docx_path is NULL", {
  # When only doc_xml/ns are supplied, no styles.xml is accessible. Detection
  # reverts to exact Heading\d+ matching. Custom styles won't count — this
  # documents the degraded path, which must not crash and must emit a
  # diagnostic so the user sees why counts differ.
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
      <w:r><w:t>Native</w:t></w:r></w:p>
    <w:p><w:pPr><w:pStyle w:val="CVH1"/></w:pPr>
      <w:r><w:t>Custom</w:t></w:r></w:p>
  </w:body>
</w:document>'

  doc <- xml2::read_xml(doc_xml)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  expect_message(
    result <- docstyle:::extract_docx_plain_text(doc_xml = doc, ns = ns),
    "No docx_path supplied"
  )

  expect_equal(nrow(result$headings), 1L)
  expect_equal(result$headings$text, "Native")
})

test_that("validate_harvest surfaces matching heading counts for custom-styled source", {
  # End-to-end integration: confirms the docx_path threading through both
  # call sites (lines 192, 211) actually reaches the validator output. A
  # refactor that dropped docx_path would pass unit tests but fail here.
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:pPr><w:pStyle w:val="CVH1"/></w:pPr>
      <w:r><w:t>First heading</w:t></w:r></w:p>
    <w:p><w:r><w:t>Body text one.</w:t></w:r></w:p>
    <w:p><w:pPr><w:pStyle w:val="CVH1"/></w:pPr>
      <w:r><w:t>Second heading</w:t></w:r></w:p>
    <w:p><w:r><w:t>Body text two.</w:t></w:r></w:p>
  </w:body>
</w:document>'

  styles_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="paragraph" w:styleId="Heading1">
    <w:name w:val="heading 1"/>
  </w:style>
  <w:style w:type="paragraph" w:customStyle="1" w:styleId="CVH1">
    <w:name w:val="CV H1"/>
    <w:basedOn w:val="Heading1"/>
  </w:style>
</w:styles>'

  td <- tempfile("test_vh_integ_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_test_docx(doc_xml, styles_xml = styles_xml, dir = td)

  qmd_path <- file.path(td, "doc.qmd")
  writeLines(c(
    "# First heading", "", "Body text one.", "",
    "# Second heading", "", "Body text two."
  ), qmd_path)

  result <- validate_harvest(docx, qmd_path = qmd_path, verbose = FALSE)

  expect_equal(result$summary$structure$headings$docx, 2L)
  expect_equal(result$summary$structure$headings$qmd, 2L)
  expect_true(result$checks$headings_match)
})


# ══ Wrapper integration ═════════════════════════════════════════════════════

test_that("validate_harvest returns expected result structure", {
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
      <w:r><w:t>Introduction</w:t></w:r></w:p>
    <w:p><w:r><w:t>Some body text for the document</w:t></w:r></w:p>
  </w:body>
</w:document>'

  td <- tempfile("test_wrapper_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))

  docx <- create_test_docx(doc_xml, dir = td)

  # Create a matching QMD
  qmd_path <- file.path(td, "test.qmd")
  writeLines(c(
    "---", "title: Test", "---",
    "", "# Introduction", "", "Some body text for the document"
  ), qmd_path)

  result <- validate_harvest(docx, qmd_path, verbose = FALSE)

  # Check structure
  expect_type(result, "list")
  expect_true("valid" %in% names(result))
  expect_true("summary" %in% names(result))
  expect_true("checks" %in% names(result))
  expect_true("issues" %in% names(result))
  expect_true("details" %in% names(result))

  # Check individual check fields exist
  expect_true("xml_wellformed" %in% names(result$checks))
  expect_true("text_fidelity" %in% names(result$checks))
  expect_true("headings_match" %in% names(result$checks))

  # Should pass for this clean case
  expect_true(result$valid)
  expect_true(result$checks$xml_wellformed)
})

test_that("validate_harvest with qmd_path = NULL runs extraction only", {
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>Text</w:t></w:r></w:p>
  </w:body>
</w:document>'

  td <- tempfile("test_no_qmd_")
  dir.create(td)
  sidecar <- file.path(td, "_docstyle")
  dir.create(sidecar)
  on.exit(unlink(td, recursive = TRUE))

  docx <- create_test_docx(doc_xml, dir = td)
  jsonlite::write_json(list(), file.path(sidecar, "comments.json"))

  result <- validate_harvest(docx, qmd_path = NULL,
                             sidecar_dir = sidecar, verbose = FALSE)

  expect_true(result$valid)
  # Text and structure layers should not have run
  expect_null(result$checks$text_fidelity)
  expect_null(result$checks$headings_match)
  # Extraction should have run
  expect_true(result$checks$xml_wellformed)
})

test_that("validate_harvest checks parameter filters layers", {
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>Simple text</w:t></w:r></w:p>
  </w:body>
</w:document>'

  td <- tempfile("test_checks_param_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))

  docx <- create_test_docx(doc_xml, dir = td)
  qmd_path <- file.path(td, "test.qmd")
  writeLines(c("---", "title: Test", "---", "", "Simple text"), qmd_path)

  result <- validate_harvest(docx, qmd_path, checks = "text",
                             verbose = FALSE)

  # Only text layer should have run
  expect_true(!is.null(result$checks$text_fidelity))
  # Extraction and structure should not have run
  expect_null(result$checks$citations_extracted)
  expect_null(result$checks$headings_match)
})


# ══ Integration test: POPCORN protocol ══════════════════════════════════════

test_that("validate_harvest runs on POPCORN protocol without error", {
  # Integration test: verifies validate_harvest runs on a real document
  # without crashing. Individual check results depend on doc/qmd sync state
  # and are not asserted here — use validate_harvest() interactively to
  # diagnose specific mismatches.
  popcorn_dir <- "/Users/dmanuel/github/popcorn-review/reports/scoping-review-protocol"
  docx_path <- file.path(popcorn_dir, "source",
                         "POPCORN_scoping_protocol-2026-01-29.docx")
  qmd_path <- file.path(popcorn_dir,
                         "POPCORN_scoping_protocol-2026-01-29.qmd")

  skip_if_not(file.exists(docx_path), "POPCORN docx not available")
  skip_if_not(file.exists(qmd_path), "POPCORN qmd not available")

  result <- validate_harvest(docx_path, qmd_path, verbose = FALSE)

  # Structural checks: function returns valid S3 object with expected fields
  expect_s3_class(result, "docstyle_validation")
  expect_true(is.logical(result$valid))
  expect_true(result$checks$xml_wellformed)
  expect_true(result$checks$citations_extracted)
})


# ══ S3 class and print/report methods ═══════════════════════════════════════

test_that("validate_harvest returns docstyle_validation S3 class", {
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body><w:p><w:r><w:t>Hello</w:t></w:r></w:p></w:body>
</w:document>'

  td <- tempfile("test_s3_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))

  docx <- create_test_docx(doc_xml, dir = td)
  qmd_path <- file.path(td, "test.qmd")
  writeLines(c("---", "title: Test", "---", "", "Hello"), qmd_path)

  result <- validate_harvest(docx, qmd_path, verbose = FALSE)

  expect_s3_class(result, "docstyle_validation")
  expect_equal(attr(result, "validation_type"), "harvest")
  expect_false(is.null(attr(result, "source_file")))
  expect_false(is.null(attr(result, "timestamp")))
})

test_that("print.docstyle_validation summary works without error", {
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body><w:p><w:r><w:t>Hello</w:t></w:r></w:p></w:body>
</w:document>'

  td <- tempfile("test_print_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))

  docx <- create_test_docx(doc_xml, dir = td)
  qmd_path <- file.path(td, "test.qmd")
  writeLines(c("---", "title: Test", "---", "", "Hello"), qmd_path)

  result <- validate_harvest(docx, qmd_path, verbose = FALSE)

  # Summary mode should not error
  output <- capture.output(print(result))
  expect_true(any(grepl("Harvest validation", output)))
  expect_true(any(grepl("PASSED", output)))
  expect_true(any(grepl("error.*warning.*note", output)))
})

test_that("print.docstyle_validation full mode includes detail section", {
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body><w:p><w:r><w:t>Hello</w:t></w:r></w:p></w:body>
</w:document>'

  td <- tempfile("test_print_full_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))

  docx <- create_test_docx(doc_xml, dir = td)
  qmd_path <- file.path(td, "test.qmd")
  writeLines(c("---", "title: Test", "---", "", "Hello"), qmd_path)

  result <- validate_harvest(docx, qmd_path, verbose = FALSE)

  output <- capture.output(print(result, detail = "full"))
  expect_true(any(grepl("Detail", output)))
})

test_that("report.docstyle_validation generates markdown", {
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body><w:p><w:r><w:t>Hello world</w:t></w:r></w:p></w:body>
</w:document>'

  td <- tempfile("test_report_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))

  docx <- create_test_docx(doc_xml, dir = td)
  qmd_path <- file.path(td, "test.qmd")
  writeLines(c("---", "title: Test", "---", "", "Hello world"), qmd_path)

  result <- validate_harvest(docx, qmd_path, verbose = FALSE)

  # Report to string
  output <- capture.output(rpt <- report(result, format = "markdown"))
  expect_true(grepl("Harvest validation report", rpt))
  expect_true(grepl("PASS", rpt))
  expect_true(grepl("Check.*Status.*Details", rpt))
})

test_that("report.docstyle_validation writes to file", {
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body><w:p><w:r><w:t>Test</w:t></w:r></w:p></w:body>
</w:document>'

  td <- tempfile("test_report_file_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))

  docx <- create_test_docx(doc_xml, dir = td)
  qmd_path <- file.path(td, "test.qmd")
  writeLines(c("---", "title: Test", "---", "", "Test"), qmd_path)

  result <- validate_harvest(docx, qmd_path, verbose = FALSE)

  report_file <- file.path(td, "report.md")
  returned_path <- report(result, file = report_file, format = "markdown")

  expect_true(file.exists(report_file))
  expect_equal(returned_path, report_file)

  content <- readLines(report_file)
  expect_true(any(grepl("Harvest validation report", content)))
})

test_that("report.docstyle_validation generates text format", {
  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body><w:p><w:r><w:t>Test doc</w:t></w:r></w:p></w:body>
</w:document>'

  td <- tempfile("test_report_text_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))

  docx <- create_test_docx(doc_xml, dir = td)
  qmd_path <- file.path(td, "test.qmd")
  writeLines(c("---", "title: Test", "---", "", "Test doc"), qmd_path)

  result <- validate_harvest(docx, qmd_path, verbose = FALSE)

  output <- capture.output(rpt <- report(result, format = "text"))
  expect_true(grepl("Harvest validation report", rpt))
  expect_true(grepl("PASS", rpt))
})

test_that("count_notes counts expected losses and generated content", {
  # Build a result with expected losses
  result <- list(
    valid = TRUE,
    stages = NULL,
    details = list(
      text = list(
        generated_sections = list(
          version_history = list(detected_by = "heading", word_count = 100)
        )
      ),
      structure = list(
        revision_loss = list(
          expected = c("rev_1", "rev_2"),
          unexpected = character(),
          by_pattern = list(revisions_in_tables = c("rev_1", "rev_2"))
        ),
        comment_loss = list(
          expected = c("5"),
          unexpected = character(),
          by_pattern = list(comments_in_tables = c("5"))
        )
      )
    ),
    issues = list(errors = character(), warnings = character())
  )

  n <- docstyle:::count_notes(result)
  expect_equal(n, 3L)  # revision loss + comment loss + generated content
})

# ── detect_adhoc_lists tests ──────────────────────────────────────────────────

# Helper: create minimal DOCX with numbering.xml for ad-hoc list tests
create_adhoc_test_docx <- function(doc_xml, numbering_xml = NULL, dir = tempdir()) {
  staging <- tempfile("adhoc_docx_")
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

  out_path <- file.path(dir, "adhoc-test.docx")
  old_wd <- getwd()
  setwd(staging)
  on.exit(setwd(old_wd), add = TRUE)
  files <- list.files(".", recursive = TRUE, all.files = TRUE)
  utils::zip(out_path, files, flags = "-q")
  out_path
}


test_that("detect_adhoc_lists finds lowerLetter list without field code", {
  skip_if_not_installed("xml2")

  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>
      <w:r><w:t>Item a</w:t></w:r></w:p>
    <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>
      <w:r><w:t>Item b</w:t></w:r></w:p>
  </w:body>
</w:document>'

  numbering_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:abstractNum w:abstractNumId="0">
    <w:lvl w:ilvl="0"><w:numFmt w:val="lowerLetter"/></w:lvl>
  </w:abstractNum>
  <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
</w:numbering>'

  td <- tempfile("adhoc_test_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_adhoc_test_docx(doc_xml, numbering_xml, dir = td)

  temp <- tempfile("unzip_")
  dir.create(temp)
  utils::unzip(docx, exdir = temp)
  parsed <- xml2::read_xml(file.path(temp, "word", "document.xml"))
  ns <- xml2::xml_ns(parsed)
  unlink(temp, recursive = TRUE)

  result <- docstyle:::detect_adhoc_lists(docx, parsed, ns, verbose = FALSE)

  expect_s3_class(result, "data.frame")
  expect_equal(nrow(result), 1)
  expect_equal(result$num_fmt, "lowerLetter")
  expect_equal(result$suggested_class, ".list-alpha")
  expect_equal(result$count, 2L)
})


test_that("detect_adhoc_lists returns empty for bullet/decimal lists", {
  skip_if_not_installed("xml2")

  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>
      <w:r><w:t>Bullet item</w:t></w:r></w:p>
    <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr></w:pPr>
      <w:r><w:t>Decimal item</w:t></w:r></w:p>
  </w:body>
</w:document>'

  numbering_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:abstractNum w:abstractNumId="0">
    <w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl>
  </w:abstractNum>
  <w:abstractNum w:abstractNumId="1">
    <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl>
  </w:abstractNum>
  <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
  <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
</w:numbering>'

  td <- tempfile("adhoc_test_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_adhoc_test_docx(doc_xml, numbering_xml, dir = td)

  temp <- tempfile("unzip_")
  dir.create(temp)
  utils::unzip(docx, exdir = temp)
  parsed <- xml2::read_xml(file.path(temp, "word", "document.xml"))
  ns <- xml2::xml_ns(parsed)
  unlink(temp, recursive = TRUE)

  result <- docstyle:::detect_adhoc_lists(docx, parsed, ns, verbose = FALSE)

  expect_s3_class(result, "data.frame")
  expect_equal(nrow(result), 0)
})


test_that("detect_adhoc_lists skips lists inside field code ranges", {
  skip_if_not_installed("xml2")

  doc_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:fldChar w:fldCharType="begin"/></w:r>
      <w:r><w:instrText> ADDIN DOCSTYLE {"type":"list","class":"list-alpha"} </w:instrText></w:r>
      <w:r><w:fldChar w:fldCharType="separate"/></w:r></w:p>
    <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>
      <w:r><w:t>Alpha item</w:t></w:r></w:p>
    <w:p><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>
  </w:body>
</w:document>'

  numbering_xml <- '<?xml version="1.0" encoding="UTF-8"?>
<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:abstractNum w:abstractNumId="0">
    <w:lvl w:ilvl="0"><w:numFmt w:val="lowerLetter"/></w:lvl>
  </w:abstractNum>
  <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
</w:numbering>'

  td <- tempfile("adhoc_test_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- create_adhoc_test_docx(doc_xml, numbering_xml, dir = td)

  temp <- tempfile("unzip_")
  dir.create(temp)
  utils::unzip(docx, exdir = temp)
  parsed <- xml2::read_xml(file.path(temp, "word", "document.xml"))
  ns <- xml2::xml_ns(parsed)
  unlink(temp, recursive = TRUE)

  result <- docstyle:::detect_adhoc_lists(docx, parsed, ns, verbose = FALSE)

  expect_s3_class(result, "data.frame")
  expect_equal(nrow(result), 0)
})


test_that("print works for POPCORN protocol without error", {
  popcorn_dir <- "/Users/dmanuel/github/popcorn-review/reports/scoping-review-protocol"
  docx_path <- file.path(popcorn_dir, "source",
                         "POPCORN_scoping_protocol-2026-01-29.docx")
  qmd_path <- file.path(popcorn_dir,
                         "POPCORN_scoping_protocol-2026-01-29.qmd")

  skip_if_not(file.exists(docx_path), "POPCORN docx not available")
  skip_if_not(file.exists(qmd_path), "POPCORN qmd not available")

  result <- validate_harvest(docx_path, qmd_path, verbose = FALSE)

  # Print should work without error and produce recognizable output
  output <- capture.output(print(result))
  expect_true(any(grepl("Harvest validation", output)))
})
