# #149: abstract.lua emits a DOCSTYLE_ABSTRACT marker for :::docstyle-abstract:::
# in docx output only; returns nil (no marker leak) for typst/jats/latex.

locate_ext_dir <- function() {
  for (p in c("../../_extensions/docstyle", "_extensions/docstyle")) {
    n <- normalizePath(file.path(getwd(), p), mustWork = FALSE)
    if (dir.exists(n)) return(n)
  }
  NA_character_
}

abstract_qmd_lines <- function() {
  # The YAML `abstract:` key simulates the real use case: a document with a
  # real abstract that Pandoc hoists to the top of the output. The
  # :::docstyle-abstract::: div is the marker the filter must relocate to the
  # correct position in the Word XML — it exists to solve that hoisting problem,
  # not merely to exercise the filter in isolation.
  c("---", "title: T", 'abstract: "Real abstract."', "---",
    "", "::: docstyle-abstract", ":::", "", "# Intro", "", "Body.")
}

# Non-docx writers: capture stdout text and check the marker is absent.
# abstract.lua does require("field-code-utils"), which resolves via Lua's package
# path. Pandoc 3.1.x does NOT add a filter's own directory to the Lua path when
# the filter is specified by absolute path — require only finds siblings when the
# cwd is the extension directory. A single setwd() with one clean on.exit() is
# the robust solution; no nesting required because the filter path itself is
# relative ("abstract.lua") and pandoc's Lua loader searches "./" (the cwd).
run_abstract_to_text <- function(ext_dir, writer) {
  doc <- tempfile(fileext = ".md"); writeLines(abstract_qmd_lines(), doc)
  old <- setwd(ext_dir); on.exit(setwd(old))
  out <- system2("pandoc", c("-f", "markdown", "-t", writer,
                             "--lua-filter=abstract.lua", doc),
                 stdout = TRUE, stderr = TRUE)
  paste(out, collapse = "\n")
}

test_that("abstract.lua emits DOCSTYLE_ABSTRACT marker under docx (#149)", {
  testthat::skip_if_not(nzchar(Sys.which("pandoc")), "pandoc not available")
  ext <- locate_ext_dir(); testthat::skip_if(is.na(ext), "ext not found")
  doc <- tempfile(fileext = ".md"); writeLines(abstract_qmd_lines(), doc)
  td <- tempfile("absfilt_"); dir.create(td)
  old <- setwd(ext)
  on.exit({ setwd(old); unlink(td, recursive = TRUE) }, add = TRUE)
  out_docx <- file.path(td, "out.docx")
  system2("pandoc", c("-f", "markdown", "-t", "docx",
                      "--lua-filter=abstract.lua", doc, "-o", out_docx),
          stdout = TRUE, stderr = TRUE)
  testthat::skip_if_not(file.exists(out_docx), "pandoc docx render failed")
  xml <- paste(readLines(unzip(out_docx, "word/document.xml", exdir = td), warn = FALSE),
               collapse = "")
  expect_match(xml, "DOCSTYLE_ABSTRACT")
})

test_that("abstract.lua returns nil (no marker leak) for typst/jats/latex (#149)", {
  testthat::skip_if_not(nzchar(Sys.which("pandoc")), "pandoc not available")
  ext <- locate_ext_dir(); testthat::skip_if(is.na(ext), "ext not found")
  for (w in c("typst", "jats", "latex")) {
    out <- run_abstract_to_text(ext, w)
    expect_false(grepl("DOCSTYLE_ABSTRACT", out),
                 info = paste0("marker leaked into ", w, ":\n", out))
  }
})
