test_that("read_css parses standard CSS", {
  css <- "
  /* Comment */
  h1 {
    color: #333;
    font-size: 24px;
  }
  
  p, .text {
    font-family: 'Arial';
  }
  "
  
  tmp <- tempfile(fileext = ".css")
  writeLines(css, tmp)
  
  styles <- read_css(tmp)
  
  expect_equal(styles$h1$color, "#333")
  expect_equal(styles$h1[["font-size"]], "24px")
  
  expect_equal(styles$p[["font-family"]], "'Arial'")
  expect_equal(styles[[".text"]][["font-family"]], "'Arial'")
})

test_that("read_css @page with named size (a4) parses without error", {
  css <- "@page { size: a4; margin-top: 1in; }"
  tmp <- tempfile(fileext = ".css")
  writeLines(css, tmp)
  styles <- read_css(tmp)
  page <- attr(styles, "page")
  expect_equal(page$size, "a4")
})

test_that("read_css @page with explicit dimension falls through gracefully (#exp1 regression)", {
  # size_map uses [[]] lookup — unknown names must not crash with 'subscript out of bounds'
  css <- "@page { size: 8.27in 11.69in; margin-top: 1in; }"
  tmp <- tempfile(fileext = ".css")
  writeLines(css, tmp)
  styles <- expect_no_error(read_css(tmp))
  page <- attr(styles, "page")
  # Unknown size passes through as-is (not mapped to a named size)
  expect_equal(page$size, "8.27in")
})

test_that("read_css ignores comments", {
  css <- "h1 { color: red; /* inline comment */ }"
  # My simple parser removes /* ... */ globally first.
  # Let's see if it handles inline correctly.
  
  tmp <- tempfile(fileext = ".css")
  writeLines(css, tmp)
  styles <- read_css(tmp)
  
  expect_equal(styles$h1$color, "red")
})


test_that("default.css defines abstract styling distinct from body (#150)", {
  # Regression guard: the .abstract rule must persist with italic +
  # left margin (not just any body-style override). Catches accidental
  # CSS revert and any future change that drops the metadata-style
  # distinction symptom-by-symptom (font-style: italic is the
  # symptom-defining property; margin alone could be mistaken for a
  # generic body indent).
  #
  # testthat::test_path() resolves relative to tests/testthat regardless
  # of the test runner. default.css lives in the source tree rather
  # than inst/, so it's reachable via "../../" — not via system.file().
  css_path <- testthat::test_path("../../_extensions/docstyle/default.css")
  skip_if_not(file.exists(css_path), "default.css not findable")

  styles <- read_css(css_path)

  abs <- styles[[".abstract"]]
  expect_false(is.null(abs),
               info = ".abstract selector must exist in default.css")
  expect_equal(abs[["font-style"]], "italic",
               info = ".abstract must be italic — symptom-defining property")
  expect_false(is.null(abs[["margin-left"]]),
               info = ".abstract must have a left margin (metadata indent)")

  abs_title <- styles[[".abstract-title"]]
  expect_false(is.null(abs_title),
               info = ".abstract-title selector must exist in default.css")
  expect_equal(abs_title[["font-weight"]], "bold",
               info = ".abstract-title must be bold")
})


test_that("default.css does not define dead-end .Abstract uppercase selectors", {
  # The CSS-to-Word style mapping at css_injection.R:409-410 only
  # matches the lowercase form. Capitalized .Abstract / .AbstractTitle
  # selectors would parse but never resolve to a Word style — silent
  # dead code. Guard against re-introducing them.
  css_path <- testthat::test_path("../../_extensions/docstyle/default.css")
  skip_if_not(file.exists(css_path), "default.css not findable")

  styles <- read_css(css_path)
  expect_null(styles[[".Abstract"]],
              info = ".Abstract (uppercase) is dead — use .abstract")
  expect_null(styles[[".AbstractTitle"]],
              info = ".AbstractTitle (uppercase) is dead — use .abstract-title")
})
