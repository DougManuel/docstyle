# #133: use_methods_protocol() scaffolds a methods-protocol Quarto
# project with PRISMA-ScR or PRISMA-P section scaffolding, the
# docstyle-typst medRxiv flag set, and the docstyle extension installed.
# This file also covers regressions for the upstream Typst fixes
# (#138 NormalTok tokens, #139 categories shape handling) since those
# fixes only manifest at render time.

# ── Hard assertion: template MUST be findable ────────────────────────────────
# A misconfigured CI / install order issue could leave system.file()
# returning "" and silently skip every test below. Make that a hard
# failure here rather than a green-with-zero-coverage skip cascade.
test_that("methods-protocol template ships with the package", {
  src <- system.file("extdata", "methods-protocol", package = "docstyle")
  expect_true(nzchar(src),
              info = "system.file() returned empty — package install lacks inst/extdata/methods-protocol")
  expect_true(dir.exists(src))
  # Each file referenced by use_methods_protocol() must exist.
  for (f in c("protocol-prisma-scr.qmd", "protocol-prisma-p.qmd",
              "_quarto.yml", "references.bib", "README.md",
              "supplements/README.md", "supplements/search-strategy.json",
              "supplements/data-charting-fields.csv",
              "supplements/data-extraction-fields.csv")) {
    expect_true(file.exists(file.path(src, f)),
                info = paste("Missing template file:", f))
  }
})


# ── Format-level default guard ───────────────────────────────────────────────
# 0.13.0 reverted `pdf-standard: ua-1` from being a format-level default
# in _extension.yml. A future change that re-adds it would silently
# break rendering for typical authored content (markdown bullets, images
# without alt text). This test is the cheap deterministic guard.
test_that("docstyle-typst does NOT set pdf-standard at the format level", {
  ext_yml <- system.file("_extensions", "docstyle", "_extension.yml",
                         package = "docstyle")
  skip_if_not(nzchar(ext_yml), "_extension.yml not findable")
  yml_text <- readLines(ext_yml, warn = FALSE)
  # Find the typst format block and assert no active `pdf-standard:` line
  # within it. We scan a window after `typst:` and before the next
  # top-level format key (`docx:`).
  typst_start <- grep("^    typst:", yml_text)[1]
  expect_false(is.na(typst_start), info = "typst format block not found")
  active_pdf_standard <- grep("^      pdf-standard:", yml_text)
  expect_length(active_pdf_standard, 0)
})


# ── Helpers ──────────────────────────────────────────────────────────────────

# All scaffold tests need this; centralise so a missing template (which
# the hard assertion above already catches) doesn't cascade as 5+ noisy
# skips.
template_findable <- function() {
  src <- system.file("extdata", "methods-protocol", package = "docstyle")
  nzchar(src) && dir.exists(src)
}


# ══ Basic scaffold (PRISMA-ScR default) ══════════════════════════════════════

test_that("use_methods_protocol scaffolds a PRISMA-ScR project by default", {
  skip_if_not(template_findable())

  td <- tempfile("mp_scr_"); on.exit(unlink(td, recursive = TRUE))
  result <- suppressMessages(
    use_methods_protocol(path = td, title = "Test scoping protocol")
  )

  # Expected file tree.
  expect_true(file.exists(file.path(td, "protocol.qmd")))
  expect_true(file.exists(file.path(td, "_quarto.yml")))
  expect_true(file.exists(file.path(td, "references.bib")))
  expect_true(file.exists(file.path(td, "README.md")))
  expect_true(file.exists(file.path(td, "supplements", "README.md")))
  expect_true(file.exists(file.path(td, "supplements",
                                    "search-strategy.json")))
  expect_true(file.exists(file.path(td, "supplements",
                                    "data-charting-fields.csv")))
  # PRISMA-P-only file should NOT be present in PRISMA-ScR scaffold.
  expect_false(file.exists(file.path(td, "supplements",
                                     "data-extraction-fields.csv")))
  expect_true(dir.exists(file.path(td, "_extensions", "docstyle")))

  # Title substitution in QMD and YAML.
  qmd_text <- readLines(file.path(td, "protocol.qmd"))
  expect_true(any(grepl("Test scoping protocol", qmd_text)))
  yml_text <- readLines(file.path(td, "_quarto.yml"))
  expect_true(any(grepl("Test scoping protocol", yml_text)))

  # Date substitution — assert today's date is present in QMD.
  expect_true(any(grepl(format(Sys.Date(), "%Y-%m-%d"), qmd_text)),
              info = "{{DATE}} substitution should produce today's date")

  # Framework markers — strong (heading-order) and discriminating.
  prisma_scr_headings <- c("^# 1\\. Introduction",
                           "^## 1\\.1 Rationale",
                           "^# 2\\. Methods",
                           "^## 2\\.2 Study scope",
                           "^## 2\\.6 Data charting")
  for (pat in prisma_scr_headings) {
    expect_true(any(grepl(pat, qmd_text)),
                info = paste("PRISMA-ScR heading missing:", pat))
  }

  # medRxiv flag on Typst format.
  expect_true(any(grepl("medrxiv: true", yml_text, fixed = TRUE)))
})


# ══ PRISMA-P framework selection ═════════════════════════════════════════════

test_that("use_methods_protocol with framework = 'prisma-p' scaffolds PICO sections", {
  skip_if_not(template_findable())

  td <- tempfile("mp_prisma_p_"); on.exit(unlink(td, recursive = TRUE))
  suppressMessages(
    use_methods_protocol(
      path = td, title = "Test systematic review",
      framework = "prisma-p"
    )
  )

  qmd_text <- readLines(file.path(td, "protocol.qmd"))
  prisma_p_headings <- c("^## 1\\.2 Objectives",
                         "^### 1\\.2\\.1 PICO",
                         "^## 2\\.1 Eligibility criteria",
                         "^## 2\\.7 Risk of bias assessment",
                         "^## 2\\.10 Confidence in cumulative evidence")
  for (pat in prisma_p_headings) {
    expect_true(any(grepl(pat, qmd_text)),
                info = paste("PRISMA-P heading missing:", pat))
  }
  expect_true(any(grepl("PROSPERO", qmd_text, fixed = TRUE)))

  # PRISMA-P-specific supplement file shipped (and the PRISMA-ScR one not).
  expect_true(file.exists(file.path(td, "supplements",
                                    "data-extraction-fields.csv")))
  expect_false(file.exists(file.path(td, "supplements",
                                     "data-charting-fields.csv")))
})


# ══ Refuse to overwrite without explicit consent ═════════════════════════════

test_that("use_methods_protocol refuses to overwrite without overwrite = TRUE", {
  skip_if_not(template_findable())

  td <- tempfile("mp_overwrite_"); on.exit(unlink(td, recursive = TRUE))
  suppressMessages(use_methods_protocol(path = td, title = "First"))

  expect_error(
    suppressMessages(use_methods_protocol(path = td, title = "Second")),
    "Refusing to overwrite"
  )

  qmd_text <- readLines(file.path(td, "protocol.qmd"))
  expect_true(any(grepl("First", qmd_text)),
              info = "Original title should still be present")
})


test_that("use_methods_protocol with overwrite = TRUE replaces files", {
  skip_if_not(template_findable())

  td <- tempfile("mp_owrite_"); on.exit(unlink(td, recursive = TRUE))
  suppressMessages(use_methods_protocol(path = td, title = "First"))
  suppressMessages(use_methods_protocol(path = td, title = "Second",
                                        overwrite = TRUE))

  qmd_text <- readLines(file.path(td, "protocol.qmd"))
  expect_true(any(grepl("Second", qmd_text)))
})


# ══ Input validation ═════════════════════════════════════════════════════════

test_that("use_methods_protocol rejects invalid framework", {
  skip_if_not(template_findable())

  td <- tempfile("mp_bad_fw_"); on.exit(unlink(td, recursive = TRUE))
  expect_error(
    suppressMessages(
      use_methods_protocol(path = td, title = "x", framework = "invalid")
    ),
    "should be one of"
  )
})


test_that("use_methods_protocol rejects empty title", {
  skip_if_not(template_findable())

  td <- tempfile("mp_empty_title_"); on.exit(unlink(td, recursive = TRUE))
  expect_error(
    suppressMessages(use_methods_protocol(path = td, title = "")),
    "non-empty"
  )
})


# ══ Path handling ════════════════════════════════════════════════════════════

test_that("use_methods_protocol creates the target dir if it doesn't exist", {
  skip_if_not(template_findable())

  parent <- tempfile("mp_parent_"); on.exit(unlink(parent, recursive = TRUE))
  dir.create(parent)
  target <- file.path(parent, "new-project")
  expect_false(dir.exists(target))

  suppressMessages(use_methods_protocol(path = target, title = "New"))
  expect_true(dir.exists(target))
  expect_true(file.exists(file.path(target, "protocol.qmd")))
})


# ══ Render smoke test ════════════════════════════════════════════════════════

test_that("scaffolded PRISMA-ScR project renders successfully with quarto", {
  # End-to-end: scaffold + render. Catches Typst regressions in
  # definitions.typ (#138 token classes) and typst-template.typ (#139
  # categories shape) that the unit tests above would miss.
  skip_if_not(template_findable())
  skip_if_not(nzchar(Sys.which("quarto")), "quarto not available")

  td <- tempfile("mp_render_"); on.exit(unlink(td, recursive = TRUE))
  suppressMessages(use_methods_protocol(path = td, title = "Render test",
                                        framework = "prisma-scr"))

  out <- system2("quarto",
                 c("render", file.path(td, "protocol.qmd"),
                   "--to", "docstyle-typst"),
                 stdout = TRUE, stderr = TRUE)
  status <- attr(out, "status")
  status <- if (is.null(status)) 0L else status
  expect_equal(status, 0L,
               info = paste("quarto render failed:",
                            paste(out, collapse = "\n")))
  expect_true(file.exists(file.path(td, "output", "protocol.pdf")))
})


# ══ Regression tests for #138 (NormalTok) and #139 (categories shape) ════════

# These are minimal-fixture renders that isolate each upstream fix. The
# methods-protocol render above exercises both transitively, but a
# direct test catches the regression closer to the source.

test_that("inline backticks render without crashing (#138 regression)", {
  skip_if_not(nzchar(Sys.which("quarto")), "quarto not available")
  ext_src <- system.file("_extensions", "docstyle", package = "docstyle")
  skip_if_not(nzchar(ext_src) && dir.exists(ext_src),
              "extension not findable")

  td <- tempfile("mp_138_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  dir.create(file.path(td, "_extensions"))
  file.copy(ext_src, file.path(td, "_extensions"), recursive = TRUE)

  writeLines(c(
    "---", "title: Inline code test",
    "format: docstyle-typst", "---",
    "Body has `inline backticks` and `another path/to/file.txt`."
  ), file.path(td, "doc.qmd"))

  out <- system2("quarto", c("render", file.path(td, "doc.qmd")),
                 stdout = TRUE, stderr = TRUE)
  status <- attr(out, "status")
  status <- if (is.null(status)) 0L else status
  expect_equal(status, 0L,
               info = paste("Inline code crashed render:",
                            paste(out, collapse = "\n")))
  expect_true(file.exists(file.path(td, "doc.pdf")))
})


test_that("YAML keywords field renders without crashing (#139 regression)", {
  skip_if_not(nzchar(Sys.which("quarto")), "quarto not available")
  ext_src <- system.file("_extensions", "docstyle", package = "docstyle")
  skip_if_not(nzchar(ext_src) && dir.exists(ext_src),
              "extension not findable")

  td <- tempfile("mp_139_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  dir.create(file.path(td, "_extensions"))
  file.copy(ext_src, file.path(td, "_extensions"), recursive = TRUE)

  writeLines(c(
    "---", "title: Keywords test",
    "keywords: [protocol, test, multiple-words]",
    "format: docstyle-typst", "---",
    "Body."
  ), file.path(td, "doc.qmd"))

  out <- system2("quarto", c("render", file.path(td, "doc.qmd")),
                 stdout = TRUE, stderr = TRUE)
  status <- attr(out, "status")
  status <- if (is.null(status)) 0L else status
  expect_equal(status, 0L,
               info = paste("keywords crashed render:",
                            paste(out, collapse = "\n")))
  expect_true(file.exists(file.path(td, "doc.pdf")))
})
