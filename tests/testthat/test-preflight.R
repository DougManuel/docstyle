# Tests for check_render_preconditions() — the P0 footgun guard run by
# the pre-render hook.

make_project <- function(quarto_yml_lines, qmd_lines = NULL) {
  dir <- tempfile("preflight-")
  dir.create(dir)
  writeLines(quarto_yml_lines, file.path(dir, "_quarto.yml"))
  if (!is.null(qmd_lines)) {
    writeLines(qmd_lines, file.path(dir, "document.qmd"))
  }
  dir
}

docstyle_yml <- c(
  "project:",
  "  type: default",
  "format:",
  "  docstyle-docx:",
  "    toc: false"
)

test_that("clean docstyle-docx project passes", {
  dir <- make_project(docstyle_yml, c("---", "title: Test", "---", "", "Body."))
  on.exit(unlink(dir, recursive = TRUE))

  result <- check_render_preconditions(dir)
  expect_true(result$ok)
  expect_length(result$errors, 0)
})

test_that("bibliography:, csl:, and reference-doc: in QMD header are errors", {
  dir <- make_project(docstyle_yml, c(
    "---",
    "title: Test",
    "bibliography: refs.bib",
    "csl: vancouver.csl",
    "reference-doc: custom.docx",
    "---",
    "",
    "Body."
  ))
  on.exit(unlink(dir, recursive = TRUE))

  result <- check_render_preconditions(dir)
  expect_false(result$ok)
  expect_length(result$errors, 3)
  expect_match(result$errors, "bibliography", all = FALSE)
  expect_match(result$errors, "csl", all = FALSE)
  expect_match(result$errors, "reference-doc", all = FALSE)
})

test_that("format: docx override in QMD is an error (scalar and list forms)", {
  dir <- make_project(docstyle_yml, c(
    "---", "title: Test", "format: docx", "---", "", "Body."
  ))
  on.exit(unlink(dir, recursive = TRUE))
  expect_false(check_render_preconditions(dir)$ok)

  dir2 <- make_project(docstyle_yml, c(
    "---", "title: Test", "format:", "  docx:", "    toc: true", "---", "", "Body."
  ))
  on.exit(unlink(dir2, recursive = TRUE), add = TRUE)
  expect_false(check_render_preconditions(dir2)$ok)
})

test_that("plain format: docx in _quarto.yml is an error", {
  dir <- make_project(c(
    "project:",
    "  type: default",
    "format:",
    "  docx:",
    "    toc: false"
  ))
  on.exit(unlink(dir, recursive = TRUE))

  result <- check_render_preconditions(dir)
  expect_false(result$ok)
  expect_match(result$errors, "docstyle-docx", all = FALSE)
})

test_that("Typst-only project with bibliography: passes (checks are docx-scoped)", {
  dir <- make_project(c(
    "project:",
    "  type: default",
    "format:",
    "  docstyle-typst:",
    "    citeproc: true"
  ), c(
    "---", "title: Test", "bibliography: refs.bib", "---", "", "Body."
  ))
  on.exit(unlink(dir, recursive = TRUE))

  expect_true(check_render_preconditions(dir)$ok)
})

test_that("missing or unparseable _quarto.yml passes silently", {
  dir <- tempfile("preflight-")
  dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE))

  expect_true(check_render_preconditions(dir)$ok)

  writeLines("format: [unclosed", file.path(dir, "_quarto.yml"))
  expect_true(check_render_preconditions(dir)$ok)
})
