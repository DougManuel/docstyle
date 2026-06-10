# #145: post-render output validators. Tests focus on the orchestrator
# (config parsing, dispatch, error vs warn semantics) and the first
# concrete validator (no-docstyle-cite-markers for docx). Future
# validators get their own test_that blocks alongside.

`%||%` <- function(x, y) if (is.null(x)) y else x

# Resolve the bundled extension dir under both `devtools::test()` (cwd =
# tests/testthat/) and `devtools::check()` (different cwd).
locate_validate_resources <- function() {
  resolve <- function(paths) {
    for (p in paths) {
      n <- normalizePath(file.path(getwd(), p), mustWork = FALSE)
      if (dir.exists(n)) return(n)
    }
    NA_character_
  }
  list(ext = resolve(c("../../_extensions/docstyle",
                       "_extensions/docstyle")))
}


# ── Helper: build a minimal docx with controllable document.xml ──────────────

# Reuse the simpler helper pattern from test-validate-harvest.R: zip a
# small staging dir with [Content_Types].xml + word/document.xml. The
# zip is enough for the validator (it only reads document.xml).
make_minimal_docx <- function(doc_xml_body, out_path) {
  staging <- tempfile("docx_min_"); dir.create(staging)
  on.exit(unlink(staging, recursive = TRUE), add = TRUE)
  dir.create(file.path(staging, "word"))
  dir.create(file.path(staging, "_rels"))

  doc_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8"?>\n',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>', doc_xml_body, '</w:body></w:document>'
  )
  writeLines(doc_xml, file.path(staging, "word", "document.xml"))
  writeLines(
    '<?xml version="1.0" encoding="UTF-8"?>\n<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>',
    file.path(staging, "[Content_Types].xml"))
  writeLines(
    '<?xml version="1.0" encoding="UTF-8"?>\n<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>',
    file.path(staging, "_rels", ".rels"))

  old_wd <- getwd(); on.exit(setwd(old_wd), add = TRUE)
  setwd(staging)
  utils::zip(out_path, files = list.files(".", recursive = TRUE),
             flags = "-q")
  out_path
}


# ══ no-docstyle-cite-markers validator ═══════════════════════════════════════

test_that("docx with DOCSTYLE_CITE:: markers triggers error", {
  td <- tempfile("vo_cite_err_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))

  docx <- file.path(td, "doc.docx")
  make_minimal_docx(
    '<w:p><w:r><w:t>Some text DOCSTYLE_CITE::key1 more text</w:t></w:r></w:p>',
    docx)

  result <- docstyle:::docx_no_docstyle_cite_markers(docx)
  expect_false(result$pass)
  expect_match(result$message, "DOCSTYLE_CITE")
})


test_that("clean docx passes the no-docstyle-cite-markers validator", {
  td <- tempfile("vo_cite_clean_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))

  docx <- file.path(td, "doc.docx")
  make_minimal_docx(
    '<w:p><w:r><w:t>Just regular text without any markers.</w:t></w:r></w:p>',
    docx)

  result <- docstyle:::docx_no_docstyle_cite_markers(docx)
  expect_true(result$pass)
})


test_that("missing docx returns FALSE with diagnostic", {
  result <- docstyle:::docx_no_docstyle_cite_markers("/no/such/file.docx")
  expect_false(result$pass)
  expect_match(result$message, "not found", ignore.case = TRUE)
})


# ══ jats well-formed validator (#145) ════════════════════════════════════════

test_that("well-formed JATS passes the jats well-formed validator", {
  td <- tempfile("vo_jats_wf_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  xml <- file.path(td, "doc.xml")
  writeLines(c('<?xml version="1.0" encoding="UTF-8"?>',
               '<article><front><article-meta>',
               '<abstract><p>An abstract.</p></abstract>',
               '</article-meta></front><body><p>Body.</p></body></article>'),
             xml)

  result <- docstyle:::jats_well_formed(xml)
  expect_true(result$pass)
})


test_that("malformed JATS fails the jats well-formed validator", {
  td <- tempfile("vo_jats_bad_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  xml <- file.path(td, "doc.xml")
  # Unclosed <body> tag — not well-formed.
  writeLines(c('<?xml version="1.0" encoding="UTF-8"?>',
               '<article><body><p>Body.</p></article>'),
             xml)

  result <- docstyle:::jats_well_formed(xml)
  expect_false(result$pass)
  expect_match(result$message, "well-formed|parse|XML", ignore.case = TRUE)
})


# ══ jats abstract-present validator (#145) ═══════════════════════════════════

test_that("JATS with <abstract> passes the abstract-present validator", {
  td <- tempfile("vo_jats_abs_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  xml <- file.path(td, "doc.xml")
  writeLines(c('<?xml version="1.0" encoding="UTF-8"?>',
               '<article><front><article-meta>',
               '<abstract><p>An abstract.</p></abstract>',
               '</article-meta></front><body><p>Body.</p></body></article>'),
             xml)

  result <- docstyle:::jats_abstract_present(xml)
  expect_true(result$pass)
})


test_that("JATS without <abstract> fails the abstract-present validator", {
  # The exact failure mode #145 names: `# Abstract` body heading produces
  # a <sec> in <body>, not an <abstract> in <front>. PMC ingest needs the
  # real <abstract> element.
  td <- tempfile("vo_jats_noabs_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  xml <- file.path(td, "doc.xml")
  writeLines(c('<?xml version="1.0" encoding="UTF-8"?>',
               '<article><front><article-meta></article-meta></front>',
               '<body><sec><title>Abstract</title><p>Mislocated.</p></sec>',
               '</body></article>'),
             xml)

  result <- docstyle:::jats_abstract_present(xml)
  expect_false(result$pass)
  expect_match(result$message, "abstract", ignore.case = TRUE)
})


# ══ pdf tagged validator (#145) ══════════════════════════════════════════════

test_that("pdf_tagged reports FALSE for a non-existent file", {
  result <- docstyle:::pdf_tagged("/no/such/file.pdf")
  expect_false(result$pass)
})

test_that("pdf_tagged confirms tagging on a tagged PDF via pdfinfo", {
  # Needs a real tagged PDF; we render one with quarto if available.
  testthat::skip_if_not(nzchar(Sys.which("pdfinfo")), "pdfinfo not available")
  testthat::skip_if_not(nzchar(Sys.which("quarto")), "quarto not available")
  paths <- locate_validate_resources()
  skip_if_not(!is.na(paths$ext), "_extensions/docstyle not found")

  td <- tempfile("vo_pdf_tag_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  ext_dir <- file.path(td, "_extensions", "docstyle")
  dir.create(ext_dir, recursive = TRUE)
  ok <- file.copy(list.files(paths$ext, full.names = TRUE),
                  ext_dir, recursive = TRUE)
  if (!all(ok)) skip("Could not stage extension")
  writeLines(c("project:", "  type: default", "format:",
               "  docstyle-typst:", "    pdf-standard: ua-1",
               "    keep-typ: false"),
             file.path(td, "_quarto.yml"))
  writeLines(c("---", "title: Tagged PDF probe", "---",
               "# Heading", "", "Body text for a tagged PDF."),
             file.path(td, "doc.qmd"))

  out <- system2("quarto", c("render", file.path(td, "doc.qmd")),
                 stdout = TRUE, stderr = TRUE)
  pdf <- file.path(td, "doc.pdf")
  skip_if_not(file.exists(pdf),
              paste("render failed:", paste(out, collapse = "\n")))

  result <- docstyle:::pdf_tagged(pdf)
  expect_true(result$pass, info = paste(result$message, collapse = " "))
})


# ══ Orchestrator: validate_docstyle_output() ═════════════════════════════════

test_that("no validators configured = no-op", {
  td <- tempfile("vo_noop_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- file.path(td, "doc.docx")
  make_minimal_docx('<w:p><w:r><w:t>x</w:t></w:r></w:p>', docx)

  # No _quarto.yml in project_dir — should silent no-op.
  result <- validate_docstyle_output(docx, project_dir = td, verbose = FALSE)
  expect_length(result$errors, 0)
  expect_length(result$warnings, 0)
})


test_that("error-level validator fails the render with actionable message", {
  td <- tempfile("vo_err_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- file.path(td, "doc.docx")
  make_minimal_docx(
    '<w:p><w:r><w:t>Bad: DOCSTYLE_CITE::abc</w:t></w:r></w:p>', docx)

  expect_error(
    validate_docstyle_output(
      docx,
      config = list(docx = list(`no-docstyle-cite-markers` = "error")),
      verbose = FALSE),
    "DOCSTYLE_CITE"
  )
})


test_that("warn-level validator returns warnings without failing", {
  td <- tempfile("vo_warn_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- file.path(td, "doc.docx")
  make_minimal_docx(
    '<w:p><w:r><w:t>DOCSTYLE_CITE::leak</w:t></w:r></w:p>', docx)

  result <- validate_docstyle_output(
    docx,
    config = list(docx = list(`no-docstyle-cite-markers` = "warn")),
    verbose = FALSE)
  expect_length(result$errors, 0)
  expect_length(result$warnings, 1)
  expect_match(result$warnings[1], "DOCSTYLE_CITE")
})


test_that("severity = TRUE is treated as error", {
  td <- tempfile("vo_true_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- file.path(td, "doc.docx")
  make_minimal_docx(
    '<w:p><w:r><w:t>DOCSTYLE_CITE::leak</w:t></w:r></w:p>', docx)

  expect_error(
    validate_docstyle_output(
      docx,
      config = list(docx = list(`no-docstyle-cite-markers` = TRUE)),
      verbose = FALSE),
    "DOCSTYLE_CITE"
  )
})


test_that("severity = FALSE skips the validator", {
  td <- tempfile("vo_false_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- file.path(td, "doc.docx")
  make_minimal_docx(
    '<w:p><w:r><w:t>DOCSTYLE_CITE::leak</w:t></w:r></w:p>', docx)

  result <- validate_docstyle_output(
    docx,
    config = list(docx = list(`no-docstyle-cite-markers` = FALSE)),
    verbose = FALSE)
  expect_length(result$errors, 0)
  expect_length(result$warnings, 0)
})


test_that("unknown validator name reports as error", {
  td <- tempfile("vo_unknown_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- file.path(td, "doc.docx")
  make_minimal_docx('<w:p><w:r><w:t>x</w:t></w:r></w:p>', docx)

  expect_error(
    validate_docstyle_output(
      docx,
      config = list(docx = list(`nonexistent-validator` = "error")),
      verbose = FALSE),
    "Unknown validator"
  )
})


test_that("validators only run for matching format (docx vs jats)", {
  # JATS file with "DOCSTYLE_CITE::" in its body should not be checked
  # by the docx validator (different format).
  td <- tempfile("vo_format_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))

  jats <- file.path(td, "doc.xml")
  writeLines(c('<?xml version="1.0"?>',
               '<article><body><p>DOCSTYLE_CITE::abc</p></body></article>'),
             jats)

  result <- validate_docstyle_output(
    jats,
    config = list(docx = list(`no-docstyle-cite-markers` = "error")),
    verbose = FALSE)
  # No error: the docx validator doesn't run on .xml files.
  expect_length(result$errors, 0)
})


test_that("orchestrator runs jats validators on .xml output (#145)", {
  td <- tempfile("vo_jats_orch_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))

  # Abstract mislocated in <body> as a <sec> — abstract-present should
  # fire at error severity and fail the render.
  jats <- file.path(td, "doc.xml")
  writeLines(c('<?xml version="1.0" encoding="UTF-8"?>',
               '<article><front><article-meta></article-meta></front>',
               '<body><sec><title>Abstract</title><p>x</p></sec></body>',
               '</article>'),
             jats)

  expect_error(
    validate_docstyle_output(
      jats,
      config = list(jats = list(`abstract-present` = "error",
                                `well-formed` = "error")),
      verbose = FALSE),
    "abstract", ignore.case = TRUE
  )

  # A well-formed JATS WITH an abstract passes both.
  good <- file.path(td, "good.xml")
  writeLines(c('<?xml version="1.0" encoding="UTF-8"?>',
               '<article><front><article-meta>',
               '<abstract><p>An abstract.</p></abstract>',
               '</article-meta></front><body><p>b</p></body></article>'),
             good)
  result <- validate_docstyle_output(
    good,
    config = list(jats = list(`abstract-present` = "error",
                              `well-formed` = "error")),
    verbose = FALSE)
  expect_length(result$errors, 0)
})


# ══ _quarto.yml config reading ═══════════════════════════════════════════════

test_that("validate_docstyle_output reads docstyle.validators from _quarto.yml", {
  td <- tempfile("vo_yml_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))

  writeLines(c(
    "project:",
    "  type: default",
    "docstyle:",
    "  validators:",
    "    docx:",
    "      no-docstyle-cite-markers: error"
  ), file.path(td, "_quarto.yml"))

  docx <- file.path(td, "doc.docx")
  make_minimal_docx(
    '<w:p><w:r><w:t>DOCSTYLE_CITE::leak</w:t></w:r></w:p>', docx)

  expect_error(
    validate_docstyle_output(docx, project_dir = td, verbose = FALSE),
    "DOCSTYLE_CITE"
  )
})


test_that("missing _quarto.yml is a silent no-op (not an error)", {
  td <- tempfile("vo_no_yml_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  docx <- file.path(td, "doc.docx")
  make_minimal_docx(
    '<w:p><w:r><w:t>DOCSTYLE_CITE::leak</w:t></w:r></w:p>', docx)

  # Even though the docx HAS a leak, with no config the validator is
  # not run — opt-in semantics.
  result <- validate_docstyle_output(docx, project_dir = td, verbose = FALSE)
  expect_length(result$errors, 0)
})


# ══ Edge cases ═══════════════════════════════════════════════════════════════

test_that("missing output file is reported but doesn't crash", {
  result <- validate_docstyle_output(
    "/no/such/file.docx",
    config = list(docx = list(`no-docstyle-cite-markers` = "error")),
    verbose = FALSE)
  # Skipped silently — config exists but file doesn't (already reported
  # by Quarto as a render failure).
  expect_length(result$errors, 0)
})


test_that("empty output_files vector is a no-op", {
  result <- validate_docstyle_output(
    character(),
    config = list(docx = list(`no-docstyle-cite-markers` = "error")),
    verbose = FALSE)
  expect_length(result$errors, 0)
  expect_length(result$warnings, 0)
})
