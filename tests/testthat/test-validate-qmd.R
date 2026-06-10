# Tests for validate_qmd.R — section fence check (#97)

# ---------------------------------------------------------------------------
# check_section_fences()
# ---------------------------------------------------------------------------

test_that("check_section_fences: balanced fences return no errors (#97)", {
  lines <- c(
    ":::: {.section-body}",
    "Some content",
    "::::"
  )
  result <- check_section_fences(lines)
  expect_length(result$errors, 0L)
  expect_equal(result$opened, 1L)
  expect_equal(result$closed, 1L)
})

test_that("check_section_fences: nested fences balanced (#97)", {
  lines <- c(
    ":::: {.section-body}",
    "::: {.center}",
    "text",
    ":::",
    "::::"
  )
  result <- check_section_fences(lines)
  expect_length(result$errors, 0L)
  expect_equal(result$opened, 2L)
  expect_equal(result$closed, 2L)
})

test_that("check_section_fences: unclosed opener is reported with line number (#97)", {
  lines <- c(
    ":::: {.section-body}",
    "Some content"
  )
  result <- check_section_fences(lines)
  expect_length(result$errors, 1L)
  expect_true(grepl("line 1", result$errors[[1]]))
  expect_true(grepl("section-body", result$errors[[1]]))
})

test_that("check_section_fences: orphan closer is reported (#97)", {
  lines <- c(
    "Some content",
    "::::"
  )
  result <- check_section_fences(lines)
  expect_length(result$errors, 1L)
  expect_true(grepl("Orphan", result$errors[[1]]))
  expect_true(grepl("line 2", result$errors[[1]]))
})

test_that("check_section_fences: mismatched colon depth is reported (#97)", {
  lines <- c(
    ":::: {.section-body}",   # 4 colons open
    ":::"                      # 3 colons close
  )
  result <- check_section_fences(lines)
  expect_length(result$errors, 1L)
  expect_true(grepl("Mismatched", result$errors[[1]]))
})

test_that("check_section_fences: colons inside code block are ignored (#97)", {
  lines <- c(
    "```",
    ":::: {.section-body}",   # inside code block — not a real fence
    "::::",
    "```",
    ":::: {.section-body}",   # real fence
    "::::"
  )
  result <- check_section_fences(lines)
  expect_length(result$errors, 0L)
  expect_equal(result$opened, 1L)
  expect_equal(result$closed, 1L)
})

test_that("check_section_fences: multiple unclosed fences reported individually (#97)", {
  lines <- c(
    ":::: {.section-body}",
    "::: {.center}"
  )
  result <- check_section_fences(lines)
  expect_equal(length(result$errors), 2L)
})

test_that("check_section_fences: empty file returns no errors (#97)", {
  result <- check_section_fences(character(0))
  expect_length(result$errors, 0L)
  expect_equal(result$opened, 0L)
  expect_equal(result$closed, 0L)
})

# ---------------------------------------------------------------------------
# validate_qmd() integration: fence errors surface in result$issues$errors
# ---------------------------------------------------------------------------

test_that("validate_qmd: unclosed fence appears in errors and valid=FALSE (#97)", {
  qmd <- tempfile(fileext = ".qmd")
  on.exit(unlink(qmd))
  writeLines(c(
    "---",
    "title: Test",
    "---",
    "",
    ":::: {.section-body}",
    "Content without closing fence"
  ), qmd)

  result <- validate_qmd(qmd, verbose = FALSE)
  expect_false(result$valid)
  expect_true(any(grepl("section-body", result$issues$errors)))
})

test_that("validate_qmd: balanced fences do not add errors (#97)", {
  qmd <- tempfile(fileext = ".qmd")
  on.exit(unlink(qmd))
  writeLines(c(
    "---",
    "title: Test",
    "---",
    "",
    ":::: {.section-body}",
    "Content",
    "::::"
  ), qmd)

  result <- validate_qmd(qmd, verbose = FALSE)
  expect_true(result$valid)
  expect_length(result$issues$errors, 0L)
})

test_that("check_section_fences: tilde code block colons are ignored (#97)", {
  lines <- c(
    "~~~python",
    ":::: {.section-body}",
    "::::",
    "~~~",
    ":::: {.section-body}",
    "::::"
  )
  result <- check_section_fences(lines)
  expect_length(result$errors, 0L)
  expect_equal(result$opened, 1L)
  expect_equal(result$closed, 1L)
})

test_that("check_section_fences: four-backtick block containing triple-backtick text (#97)", {
  lines <- c(
    "````r",
    "```",
    ":::: {.section-body}",
    "```",
    "````",
    ":::: {.section-body}",
    "::::"
  )
  result <- check_section_fences(lines)
  expect_length(result$errors, 0L)
  expect_equal(result$opened, 1L)
})

test_that("check_section_fences: unclosed tilde code fence produces error (#97)", {
  lines <- c(
    "~~~python",
    ":::: {.section-body}",
    "::::"
  )
  result <- check_section_fences(lines)
  expect_length(result$errors, 1L)
  expect_match(result$errors[[1]], "Unclosed code fence")
  expect_equal(result$opened, 0L)
  expect_equal(result$closed, 0L)
})

# ---------------------------------------------------------------------------
# validate_qmd_quick()
# ---------------------------------------------------------------------------

test_that("validate_qmd_quick: returns FALSE for unclosed fence (#97)", {
  qmd <- tempfile(fileext = ".qmd")
  on.exit(unlink(qmd))
  writeLines(c(":::: {.section-body}", "no close"), qmd)
  expect_false(validate_qmd_quick(qmd))
})

test_that("validate_qmd_quick: returns TRUE for balanced document (#97)", {
  qmd <- tempfile(fileext = ".qmd")
  on.exit(unlink(qmd))
  writeLines(c(":::: {.section-body}", "content", "::::"), qmd)
  expect_true(validate_qmd_quick(qmd))
})
