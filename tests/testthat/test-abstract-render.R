# #149 end-to-end integration tests: abstract relocation through a real
# `quarto render` call.  Unit tests (test-abstract-filter.R,
# test-relocate-abstract.R) use synthetic XML; these tests prove the full
# pipeline — Lua filter → Pandoc → R post-render (relocate_abstract) — places
# the abstract AFTER the author plate in the rendered Word XML.  A cross-format
# Typst check guards against the docx-only marker leaking into .typ output.

# ── Helpers ───────────────────────────────────────────────────────────────────

`%||%` <- function(x, y) if (is.null(x)) y else x

# Resolve the extension directory for both devtools::test() and
# devtools::check() working directories.
locate_ext <- function() {
  for (p in c("../../_extensions/docstyle", "_extensions/docstyle")) {
    n <- normalizePath(file.path(getwd(), p), mustWork = FALSE)
    if (dir.exists(n)) return(n)
  }
  NA_character_
}

# Stage a minimal render directory: copy the extension, write _quarto.yml
# and doc.qmd from the supplied lines.
#
# `fmt_block` is a character vector of lines appended under `format:`.
# `docstyle_block` is an optional character vector of additional lines
# appended at the top level (e.g. a `docstyle:` section).  When NULL a
# minimal `docstyle:` stub is injected so the pre-render hook produces
# reference.docx (it skips entirely when the key is absent).
stage_render_dir <- function(td, fmt_block, qmd_body,
                             docstyle_block = NULL) {
  ext <- locate_ext()
  ext_dir <- file.path(td, "_extensions", "docstyle")
  dir.create(ext_dir, recursive = TRUE)
  ok <- file.copy(list.files(ext, full.names = TRUE),
                  ext_dir, recursive = TRUE)
  if (!all(ok)) stop("[test] file.copy failed for extension files")

  # Pre- and post-render hooks are required for docx output:
  #   pre-render  → generates _docstyle/reference.docx from CSS
  #   post-render → runs relocate_abstract() (the feature under test)
  # Without `docstyle:` the pre-render hook exits early and reference.docx
  # is never created, which causes a Pandoc "file not found" error.
  if (is.null(docstyle_block)) {
    docstyle_block <- c("docstyle:", "  css: ~")   # ~ = YAML null; uses default.css
  }

  yaml_lines <- c(
    "project:",
    "  type: default",
    "  pre-render: _extensions/docstyle/generate-reference.R",
    "  post-render: _extensions/docstyle/update-field-codes.R",
    "format:",
    fmt_block,
    docstyle_block
  )
  writeLines(yaml_lines, file.path(td, "_quarto.yml"))
  writeLines(qmd_body, file.path(td, "doc.qmd"))
  invisible(td)
}

# Shared QMD body used for both the docx and Typst render tests.
# - YAML `abstract:` is what Pandoc hoists to the top in docx output.
# - `:::author-plate:::` marks where the author plate lands.
# - `:::docstyle-abstract:::` is the opt-in placeholder that abstract.lua
#   turns into a DOCSTYLE_ABSTRACT marker and relocate_abstract() then
#   MOVES the abstract paragraphs to.
# "UNIQABS" is a unique token embedded in the abstract text so the XPath
# text search below can pinpoint the relocated abstract paragraph.
abstract_qmd <- function() {
  c(
    "---",
    "title: Abstract Position Test",
    "abstract: |",
    "  UNIQABS this is the abstract body text.",
    "author:",
    "  - name: Jane Smith",
    "---",
    "",
    "::: author-plate",
    ":::",
    "",
    "::: docstyle-abstract",
    ":::",
    "",
    "# Introduction",
    "",
    "Body paragraph."
  )
}

# Unified skip guard — mirrors the pattern in test-medrxiv-flag.R.
skip_if_no_render_tools <- function() {
  testthat::skip_if_not(nzchar(Sys.which("quarto")), "quarto not available")
  testthat::skip_if(is.na(locate_ext()), "_extensions/docstyle not found")
}

# ══ Test 1: docx — abstract renders AFTER the author plate ═══════════════════

test_that("docx: abstract renders after the author plate (#149)", {
  skip_if_no_render_tools()

  td <- tempfile("abs_docx_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  stage_render_dir(td,
                   fmt_block = c("  docstyle-docx:", "    toc: false"),
                   qmd_body  = abstract_qmd())

  out <- system2("quarto", c("render", file.path(td, "doc.qmd")),
                 stdout = TRUE, stderr = TRUE)
  status <- attr(out, "status") %||% 0L

  docx <- file.path(td, "doc.docx")
  # Use skip_if_not rather than a hard fail: a render failure will be obvious
  # from the skip message + quarto stderr captured below.
  testthat::skip_if_not(
    file.exists(docx),
    paste("render failed (status=", status, "):",
          paste(out, collapse = "\n"), sep = "")
  )

  # Unzip word/document.xml and collect paragraph text in document order.
  xml_path <- unzip(docx, "word/document.xml",
                    exdir = file.path(td, "xml_inspect"))
  xml <- xml2::read_xml(xml_path)
  ns  <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  txt <- vapply(xml2::xml_find_all(xml, "//w:p", ns),
                xml2::xml_text, character(1))

  plate_i <- which(grepl("Jane Smith", txt))[1]
  abs_i   <- which(grepl("UNIQABS", txt))[1]

  expect_false(is.na(plate_i),
               info = "Author plate paragraph (Jane Smith) not found in document.xml")
  expect_false(is.na(abs_i),
               info = "Abstract paragraph (UNIQABS) not found in document.xml")
  expect_true(abs_i > plate_i,
              info = paste0(
                "Abstract should be AFTER the author plate; ",
                "plate_i=", plate_i, " abs_i=", abs_i, "\n",
                "Paragraph order (first 30):\n",
                paste(seq_along(head(txt, 30)), head(txt, 30), sep = ": ",
                      collapse = "\n")))

  # The marker itself must have been consumed by relocate_abstract().
  expect_false(any(grepl("DOCSTYLE_ABSTRACT", txt)),
               info = "DOCSTYLE_ABSTRACT marker was not consumed by post-render")
})


# ══ Test 2: Typst — abstract present, no marker leak ═════════════════════════

test_that("typst: abstract on title page, no DOCSTYLE_ABSTRACT marker leak (#149)", {
  skip_if_no_render_tools()

  td <- tempfile("abs_typ_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  stage_render_dir(td,
                   fmt_block = c("  docstyle-typst:", "    keep-typ: true"),
                   qmd_body  = abstract_qmd())

  out <- system2("quarto", c("render", file.path(td, "doc.qmd")),
                 stdout = TRUE, stderr = TRUE)
  status <- attr(out, "status") %||% 0L

  typ <- file.path(td, "doc.typ")
  testthat::skip_if_not(
    file.exists(typ),
    paste("typst render failed (status=", status, "):",
          paste(out, collapse = "\n"), sep = "")
  )

  body <- paste(readLines(typ, warn = FALSE), collapse = "\n")

  # Abstract text should appear (Typst renders it natively on the title page).
  expect_match(body, "UNIQABS",
               info = "Abstract text should appear in .typ output")

  # The docx-specific marker must NOT have leaked into the Typst intermediate.
  expect_false(grepl("DOCSTYLE_ABSTRACT", body),
               info = paste("DOCSTYLE_ABSTRACT marker leaked into .typ output.",
                            "abstract.lua must return nil for non-docx writers."))
})
