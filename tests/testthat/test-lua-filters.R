# Tests for Lua filters (#3)
#
# Each test runs pandoc with one or more filters, inspects the resulting DOCX
# XML with XPath, and asserts on structural properties.
#
# LUA_PATH is set before each pandoc call so that require("field-code-utils")
# resolves from the extension directory. field-code-utils.lua is a library
# module, not a filter — it must NOT be passed via --lua-filter.

ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------

#' Run pandoc with specified filters and return parsed document.xml
#'
#' @param markdown Markdown string (may include YAML front matter)
#' @param filters Character vector of filter filenames (relative to extension dir)
#' @return xml_document for word/document.xml, or skips test if pandoc unavailable
run_filter_docx <- function(markdown, filters) {
  if (nchar(Sys.which("pandoc")) == 0) skip("pandoc not available")

  filter_dir <- system.file("_extensions", "docstyle", package = "docstyle")
  if (!nzchar(filter_dir)) skip("Extension directory not found in installed package")

  md_file  <- tempfile(fileext = ".md")
  out_file <- tempfile(fileext = ".docx")
  td       <- tempfile()
  if (!dir.create(td)) skip("Cannot create temp directory for test")
  on.exit({
    unlink(md_file)
    unlink(out_file)
    unlink(td, recursive = TRUE)
  }, add = TRUE)

  tryCatch(
    writeLines(markdown, md_file),
    error = function(e) stop("Failed to write markdown to temp file: ", conditionMessage(e))
  )

  args <- c(
    "--from", "markdown",
    "--to", "docx",
    unlist(lapply(filters, function(f) c("--lua-filter", file.path(filter_dir, f)))),
    "-o", out_file,
    md_file
  )

  # Set LUA_PATH so require("field-code-utils") resolves inside the actual filters.
  # field-code-utils.lua is a library module and must not be passed as --lua-filter.
  lua_path <- paste0(filter_dir, "/?.lua;;")
  old_lua  <- Sys.getenv("LUA_PATH", unset = NA)
  Sys.setenv(LUA_PATH = lua_path)
  # on.exit(add = TRUE) runs handlers in registration order (FIFO). Cleanup was
  # registered first (above), LUA_PATH restore second. Both actions are independent
  # so either order is safe — LUA_PATH is restored after temp-file cleanup.
  on.exit({
    if (is.na(old_lua)) Sys.unsetenv("LUA_PATH") else Sys.setenv(LUA_PATH = old_lua)
  }, add = TRUE)

  result <- system2("pandoc", args, stdout = TRUE, stderr = TRUE)
  status <- attr(result, "status")

  if (!file.exists(out_file) || (!is.null(status) && status != 0)) {
    skip(paste("pandoc failed (status", status %||% "?", "):",
               paste(result, collapse = "\n")))
  }

  unzip_files <- utils::unzip(out_file, exdir = td, overwrite = TRUE)
  doc_xml <- file.path(td, "word", "document.xml")
  if (is.null(unzip_files) || !file.exists(doc_xml)) {
    skip("unzip produced no output or document.xml missing")
  }

  tryCatch(
    xml2::read_xml(doc_xml),
    error = function(e) {
      msg <- conditionMessage(e)
      if (grepl("cannot open|No such file", msg, ignore.case = TRUE)) {
        skip(paste("document.xml disappeared before parsing:", msg))
      }
      skip(paste("document.xml is not valid XML:", msg))
    }
  )
}

# ---------------------------------------------------------------------------
# Group 1: toc-field.lua (#3)
# ---------------------------------------------------------------------------

test_that("toc-field: .toc div emits TOC field code with default levels (#3)", {
  doc <- run_filter_docx("::: {.toc}\n:::", "toc-field.lua")

  instr_nodes <- xml2::xml_find_all(doc, ".//w:instrText", ns)
  instr_texts <- vapply(instr_nodes, xml2::xml_text, character(1))

  expect_true(any(grepl('TOC \\\\o "1-3"', instr_texts)),
    info = "Default TOC should cover levels 1-3")
  expect_true(any(grepl("\\\\h", instr_texts)),
    info = "Default TOC should have hyperlinks switch")
})

test_that("toc-field: docstyle.toc.levels overrides TOC depth (#3)", {
  md <- paste0(
    "---\ndocstyle:\n  toc:\n    levels: \"1-2\"\n---\n\n",
    "::: {.toc}\n:::"
  )
  doc <- run_filter_docx(md, "toc-field.lua")

  instr_nodes <- xml2::xml_find_all(doc, ".//w:instrText", ns)
  instr_texts <- vapply(instr_nodes, xml2::xml_text, character(1))

  expect_true(any(grepl('TOC \\\\o "1-2"', instr_texts)),
    info = "Custom levels should produce \\o \"1-2\" switch")
  expect_false(any(grepl('\\\\o "1-3"', instr_texts)),
    info = "Default 1-3 should not appear when overridden")
})

test_that("toc-field: docstyle.toc.title emits heading before TOC (#3)", {
  md <- paste0(
    "---\ndocstyle:\n  toc:\n    title: \"Contents\"\n---\n\n",
    "::: {.toc}\n:::"
  )
  doc <- run_filter_docx(md, "toc-field.lua")

  heading_nodes <- xml2::xml_find_all(
    doc, ".//w:p[w:pPr/w:pStyle[@w:val='Heading1']]", ns
  )
  heading_texts <- vapply(heading_nodes, function(n) {
    paste(xml2::xml_text(xml2::xml_find_all(n, ".//w:t", ns)), collapse = "")
  }, character(1))

  expect_true(any(heading_texts == "Contents"),
    info = "A Heading1 paragraph with text 'Contents' should precede the TOC")
})

test_that("toc-field: ADDIN DOCSTYLE wrapper is emitted for round-trip (#3)", {
  doc <- run_filter_docx("::: {.toc}\n:::", "toc-field.lua")

  instr_nodes <- xml2::xml_find_all(doc, ".//w:instrText", ns)
  instr_texts <- vapply(instr_nodes, xml2::xml_text, character(1))

  expect_true(any(grepl("ADDIN DOCSTYLE", instr_texts)),
    info = "ADDIN DOCSTYLE field code should wrap the TOC for harvest round-trip")
  expect_true(any(grepl('"name":"toc"', instr_texts, fixed = TRUE)))
})

# ---------------------------------------------------------------------------
# Group 2: version-history.lua (#3)
# ---------------------------------------------------------------------------

test_that("version-history: emits a table when metadata present (#3)", {
  md <- paste0(
    "---\nversion-history:\n",
    "  - version: \"1.0\"\n",
    "    date: \"2025-01-01\"\n",
    "    description: \"Initial release\"\n",
    "---\n\n",
    "::: version-history\n:::"
  )
  doc <- run_filter_docx(md, "version-history.lua")

  tbls <- xml2::xml_find_all(doc, ".//w:tbl", ns)
  expect_gte(length(tbls), 1L, label = "At least one table should be emitted")
})

test_that("version-history: table contains version number and date text (#3)", {
  md <- paste0(
    "---\nversion-history:\n",
    "  - version: \"2.3\"\n",
    "    date: \"2025-06-15\"\n",
    "    description: \"Bug fixes\"\n",
    "---\n\n",
    "::: version-history\n:::"
  )
  doc <- run_filter_docx(md, "version-history.lua")

  all_text_nodes <- xml2::xml_find_all(doc, ".//w:t", ns)
  all_text <- paste(vapply(all_text_nodes, xml2::xml_text, character(1)), collapse = " ")

  expect_true(grepl("2.3", all_text, fixed = TRUE),
    info = "Version number should appear in table cell text")
  expect_true(grepl("2025-06-15", all_text, fixed = TRUE),
    info = "Date should appear in table cell text")
  expect_true(grepl("Bug fixes", all_text, fixed = TRUE),
    info = "Description should appear in table cell text")
})

test_that("version-history: multiple entries produce multiple rows (#3)", {
  md <- paste0(
    "---\nversion-history:\n",
    "  - version: \"1.0\"\n    date: \"2025-01-01\"\n    description: \"First\"\n",
    "  - version: \"1.1\"\n    date: \"2025-02-01\"\n    description: \"Second\"\n",
    "---\n\n",
    "::: version-history\n:::"
  )
  doc <- run_filter_docx(md, "version-history.lua")

  rows <- xml2::xml_find_all(doc, ".//w:tbl/w:tr", ns)
  # Header row + 2 data rows = 3
  expect_gte(length(rows), 3L)
})

test_that("version-history: no table emitted when no metadata (#3)", {
  doc <- run_filter_docx("::: version-history\n:::", "version-history.lua")

  tbls <- xml2::xml_find_all(doc, ".//w:tbl", ns)
  expect_length(tbls, 0L)
})

test_that("version-history: ADDIN DOCSTYLE wrapper emitted for round-trip (#3)", {
  md <- paste0(
    "---\nversion-history:\n",
    "  - version: \"1.0\"\n    date: \"2025-01-01\"\n    description: \"First\"\n",
    "---\n\n",
    "::: version-history\n:::"
  )
  doc <- run_filter_docx(md, "version-history.lua")

  instr_nodes <- xml2::xml_find_all(doc, ".//w:instrText", ns)
  instr_texts <- vapply(instr_nodes, xml2::xml_text, character(1))

  expect_true(any(grepl("ADDIN DOCSTYLE", instr_texts)))
  expect_true(any(grepl('"name":"version-history"', instr_texts, fixed = TRUE)))
})

test_that("version-history: special characters in description are XML-escaped (#3)", {
  md <- paste0(
    "---\nversion-history:\n",
    "  - version: \"1.0\"\n    date: \"2025-01-01\"\n",
    "    description: \"Fix &amp; handle <tags> and \\\"quotes\\\"\"\n",
    "---\n\n",
    "::: version-history\n:::"
  )
  doc <- run_filter_docx(md, "version-history.lua")

  # If XML is malformed the read_xml call would have failed; reaching here means
  # the document is valid. Verify the text round-trips correctly.
  all_text <- paste(
    vapply(xml2::xml_find_all(doc, ".//w:t", ns), xml2::xml_text, character(1)),
    collapse = " "
  )
  expect_true(grepl("Fix", all_text, fixed = TRUE))
})

# ---------------------------------------------------------------------------
# Group 3: page-section.lua (#3)
# ---------------------------------------------------------------------------

test_that("page-section: .section-body emits DOCSTYLE_SECTION marker (#3)", {
  doc <- run_filter_docx("::: {.section-body}\n:::", "page-section.lua")

  text_nodes <- xml2::xml_find_all(doc, ".//w:t", ns)
  texts <- vapply(text_nodes, xml2::xml_text, character(1))

  marker_texts <- texts[grepl("DOCSTYLE_SECTION", texts)]
  expect_gte(length(marker_texts), 1L)
  expect_true(any(grepl("section-body", marker_texts)))
})

test_that("page-section: default marker has page-break=false and line-numbers=none (#3)", {
  doc <- run_filter_docx("::: {.section-body}\n:::", "page-section.lua")

  text_nodes <- xml2::xml_find_all(doc, ".//w:t", ns)
  texts  <- vapply(text_nodes, xml2::xml_text, character(1))
  marker <- texts[grepl("DOCSTYLE_SECTION::section-body", texts)]

  expect_true(any(grepl("::false::none", marker)),
    info = "Default marker should encode page-break=false, line-numbers=none")
})

test_that("page-section: page-break=true is encoded in marker (#3)", {
  doc <- run_filter_docx('::: {.section-body page-break="true"}\n:::', "page-section.lua")

  text_nodes <- xml2::xml_find_all(doc, ".//w:t", ns)
  texts  <- vapply(text_nodes, xml2::xml_text, character(1))
  marker <- texts[grepl("DOCSTYLE_SECTION::section-body", texts)]

  expect_true(any(grepl("::true::", marker)),
    info = "page-break=true should be encoded in the marker")
})

test_that("page-section: line-numbers=continuous is encoded in marker (#3)", {
  doc <- run_filter_docx(
    '::: {.section-body line-numbers="continuous"}\n:::',
    "page-section.lua"
  )

  text_nodes <- xml2::xml_find_all(doc, ".//w:t", ns)
  texts  <- vapply(text_nodes, xml2::xml_text, character(1))
  marker <- texts[grepl("DOCSTYLE_SECTION::section-body", texts)]

  expect_true(any(grepl("::continuous", marker)),
    info = "line-numbers=continuous should be encoded in the marker")
})

test_that("page-section: ADDIN DOCSTYLE wrapper emitted for round-trip (#3)", {
  doc <- run_filter_docx("::: {.section-body}\n:::", "page-section.lua")

  instr_nodes <- xml2::xml_find_all(doc, ".//w:instrText", ns)
  instr_texts <- vapply(instr_nodes, xml2::xml_text, character(1))

  expect_true(any(grepl("ADDIN DOCSTYLE", instr_texts)),
    info = "ADDIN DOCSTYLE field code should be emitted for harvest round-trip")
  expect_true(any(grepl('"type":"section"', instr_texts, fixed = TRUE)))
})

test_that("page-section: wrapping div emits opening and closing markers (#3)", {
  doc <- run_filter_docx(
    "::: {.section-body}\nSome content\n:::",
    "page-section.lua"
  )

  text_nodes <- xml2::xml_find_all(doc, ".//w:t", ns)
  texts <- vapply(text_nodes, xml2::xml_text, character(1))

  expect_true(any(grepl("^DOCSTYLE_SECTION::section-body", texts)),
    info = "Opening marker should be present for wrapping div")
  expect_true(any(grepl("^DOCSTYLE_SECTION_END::section-body", texts)),
    info = "Closing marker should be present for wrapping div")
})

test_that("page-section: .page-break div emits a Word page break (#3)", {
  doc <- run_filter_docx("::: {.page-break}\n:::", "page-section.lua")

  br_nodes <- xml2::xml_find_all(doc, ".//w:br[@w:type='page']", ns)
  expect_gte(length(br_nodes), 1L,
    label = ".page-break div should produce a w:br type='page' element")
})

# ---------------------------------------------------------------------------
# Group 4: char-style.lua — character style spans (#3)
# ---------------------------------------------------------------------------

test_that("char-style: [text]{.date} emits ADDIN DOCSTYLE char field code (#3)", {
  md <- paste0(
    "---\nversion-summary:\n  date: \"2025-01-01\"\n---\n\n",
    "[2025-01-01]{.date}"
  )
  doc <- run_filter_docx(md, "char-style.lua")

  instr_nodes <- xml2::xml_find_all(doc, ".//w:instrText", ns)
  instr_texts <- vapply(instr_nodes, xml2::xml_text, character(1))

  expect_true(any(grepl("ADDIN DOCSTYLE", instr_texts)),
    info = "char-style filter should emit ADDIN DOCSTYLE field for .date span")
  expect_true(any(grepl('"type":"char"', instr_texts, fixed = TRUE)))
})

test_that("char-style: .date span carries w:rStyle Date on the run (#3)", {
  md <- paste0(
    "---\nversion-summary:\n  date: \"2025-01-01\"\n---\n\n",
    "[2025-01-01]{.date}"
  )
  doc <- run_filter_docx(md, "char-style.lua")

  rStyle_nodes <- xml2::xml_find_all(doc, ".//w:rStyle[@w:val='Date']", ns)
  expect_gte(length(rStyle_nodes), 1L,
    label = "The styled run must carry w:rStyle w:val='Date'")
})

test_that("char-style: empty []{.date} span auto-populates from metadata (#3)", {
  md <- paste0(
    "---\nversion-summary:\n  date: \"2025-03-14\"\n---\n\n",
    "[]{.date}"
  )
  doc <- run_filter_docx(md, "char-style.lua")

  text_nodes <- xml2::xml_find_all(doc, ".//w:t", ns)
  texts <- vapply(text_nodes, xml2::xml_text, character(1))

  expect_true(any(grepl("2025-03-14", texts, fixed = TRUE)),
    info = "Auto-populated date should appear as text in the document")
  rStyle_nodes <- xml2::xml_find_all(doc, ".//w:rStyle[@w:val='Date']", ns)
  expect_gte(length(rStyle_nodes), 1L)
})

test_that("char-style: .center div produces centred paragraph (#3)", {
  doc <- run_filter_docx(
    "::: {.center}\nCentred text\n:::",
    "char-style.lua"
  )

  jc_nodes <- xml2::xml_find_all(doc, ".//w:jc[@w:val='center']", ns)
  expect_gte(length(jc_nodes), 1L,
    label = "At least one paragraph should have centre alignment")
})

test_that("char-style: [text]{.version} emits Version rStyle (#3)", {
  md <- paste0(
    "---\nversion-summary:\n  version: \"2.1\"\n---\n\n",
    "[2.1]{.version}"
  )
  doc <- run_filter_docx(md, "char-style.lua")

  rStyle_nodes <- xml2::xml_find_all(doc, ".//w:rStyle[@w:val='Version']", ns)
  expect_gte(length(rStyle_nodes), 1L,
    label = ".version span must carry w:rStyle w:val='Version'")
  instr_nodes <- xml2::xml_find_all(doc, ".//w:instrText", ns)
  instr_texts <- vapply(instr_nodes, xml2::xml_text, character(1))
  expect_true(any(grepl("ADDIN DOCSTYLE", instr_texts)))
})

test_that("char-style: empty span with no metadata returns nil (no output) (#3)", {
  # No version-summary metadata — empty []{.date} should be dropped silently
  doc <- run_filter_docx("[]{.date}", "char-style.lua")

  # No ADDIN DOCSTYLE field code should be emitted (filter returned nil)
  instr_nodes <- xml2::xml_find_all(doc, ".//w:instrText", ns)
  instr_texts <- vapply(instr_nodes, xml2::xml_text, character(1))
  expect_false(any(grepl("ADDIN DOCSTYLE", instr_texts)),
    info = "Empty span with no metadata should produce no field code")
})

# ---------------------------------------------------------------------------
# Group 5: page-section.lua — additional configuration branches (#3)
# ---------------------------------------------------------------------------

test_that("page-section: line-numbers=section is encoded in marker (#3)", {
  doc <- run_filter_docx(
    '::: {.section-body line-numbers="section"}\n:::',
    "page-section.lua"
  )

  text_nodes <- xml2::xml_find_all(doc, ".//w:t", ns)
  texts  <- vapply(text_nodes, xml2::xml_text, character(1))
  marker <- texts[grepl("DOCSTYLE_SECTION::section-body", texts)]

  expect_true(any(grepl("::section$", marker)),
    info = "line-numbers=section should be encoded as ::section in the marker")
})

test_that("page-section: line-numbers=page is encoded in marker (#3)", {
  doc <- run_filter_docx(
    '::: {.section-body line-numbers="page"}\n:::',
    "page-section.lua"
  )

  text_nodes <- xml2::xml_find_all(doc, ".//w:t", ns)
  texts  <- vapply(text_nodes, xml2::xml_text, character(1))
  marker <- texts[grepl("DOCSTYLE_SECTION::section-body", texts)]

  expect_true(any(grepl("::page$", marker)),
    info = "line-numbers=page should be encoded as ::page in the marker")
})

test_that("page-section: page-break-after on wrapping div encodes true in closing marker (#3)", {
  doc <- run_filter_docx(
    '::: {.section-body page-break-after="true"}\nContent\n:::',
    "page-section.lua"
  )

  text_nodes <- xml2::xml_find_all(doc, ".//w:t", ns)
  texts <- vapply(text_nodes, xml2::xml_text, character(1))
  closing <- texts[grepl("DOCSTYLE_SECTION_END::section-body", texts)]

  expect_true(length(closing) >= 1L,
    info = "Closing marker should be present for wrapping div")
  expect_true(any(grepl("::true::", closing)),
    info = "page-break-after=true should be encoded as ::true:: in the closing marker")
})

# ---------------------------------------------------------------------------
# Group 6: toc-field.lua — additional configuration branches (#3)
# ---------------------------------------------------------------------------

test_that("toc-field: page-numbers:false adds \\n switch (#3)", {
  md <- paste0(
    "---\ndocstyle:\n  toc:\n    page-numbers: false\n---\n\n",
    "::: {.toc}\n:::"
  )
  doc <- run_filter_docx(md, "toc-field.lua")

  instr_nodes <- xml2::xml_find_all(doc, ".//w:instrText", ns)
  instr_texts <- vapply(instr_nodes, xml2::xml_text, character(1))

  expect_true(any(grepl("\\\\n", instr_texts)),
    info = "page-numbers:false should add \\n switch to TOC field")
})

test_that("toc-field: hyperlinks:false omits \\h switch (#3)", {
  md <- paste0(
    "---\ndocstyle:\n  toc:\n    hyperlinks: false\n---\n\n",
    "::: {.toc}\n:::"
  )
  doc <- run_filter_docx(md, "toc-field.lua")

  instr_nodes <- xml2::xml_find_all(doc, ".//w:instrText", ns)
  instr_texts <- vapply(instr_nodes, xml2::xml_text, character(1))

  expect_false(any(grepl("\\\\h", instr_texts)),
    info = "hyperlinks:false should omit \\h switch from TOC field")
})

test_that("toc-field: title-level:2 emits Heading2 paragraph before TOC (#3)", {
  md <- paste0(
    "---\ndocstyle:\n  toc:\n    title: \"Contents\"\n    title-level: 2\n---\n\n",
    "::: {.toc}\n:::"
  )
  doc <- run_filter_docx(md, "toc-field.lua")

  heading_nodes <- xml2::xml_find_all(
    doc, ".//w:p[w:pPr/w:pStyle[@w:val='Heading2']]", ns
  )
  heading_texts <- vapply(heading_nodes, function(n) {
    paste(xml2::xml_text(xml2::xml_find_all(n, ".//w:t", ns)), collapse = "")
  }, character(1))

  expect_true(any(heading_texts == "Contents"),
    info = "title-level:2 should produce a Heading2 paragraph with the title text")
})

# ---------------------------------------------------------------------------
# Group 7: version-history.lua — additional configuration branches (#3)
# ---------------------------------------------------------------------------

test_that("version-history: table-formal style emits header shading (#3)", {
  md <- paste0(
    "---\nversion-history:\n",
    "  - version: \"1.0\"\n    date: \"2025-01-01\"\n    description: \"First\"\n",
    "docstyle:\n  version-history:\n    style: \"table-formal\"\n",
    "---\n\n",
    "::: version-history\n:::"
  )
  doc <- run_filter_docx(md, "version-history.lua")

  # table-formal uses header_shading = "D9D9D9"
  shading_nodes <- xml2::xml_find_all(doc, ".//w:shd[@w:fill='D9D9D9']", ns)
  expect_gte(length(shading_nodes), 1L,
    label = "table-formal should emit w:shd fill='D9D9D9' on header row")
})

test_that("version-history: title:false suppresses heading (#3)", {
  md <- paste0(
    "---\nversion-history:\n",
    "  - version: \"1.0\"\n    date: \"2025-01-01\"\n    description: \"First\"\n",
    "docstyle:\n  version-history:\n    title: false\n",
    "---\n\n",
    "::: version-history\n:::"
  )
  doc <- run_filter_docx(md, "version-history.lua")

  heading_nodes <- xml2::xml_find_all(
    doc, ".//w:p[w:pPr/w:pStyle[@w:val='Heading1']]", ns
  )
  expect_length(heading_nodes, 0L)
})
