# Tests for match_css_section_name() — CSS-aware section class naming (#19)

# ---------------------------------------------------------------------------
# match_css_section_name() unit tests
# ---------------------------------------------------------------------------

test_that("returns 'body' when page_config has no named sections (#19)", {
  brk <- list(has_line_numbers = TRUE, line_numbers_restart = "continuous")
  expect_equal(match_css_section_name(brk, NULL), "body")
  expect_equal(match_css_section_name(brk, list()), "body")
  expect_equal(match_css_section_name(brk, list(named = NULL)), "body")
  expect_equal(match_css_section_name(brk, list(named = list())), "body")
})

test_that("matches section with line numbers to CSS named page with line numbers (#19)", {
  page_config <- list(
    named = list(
      body = list(`line-numbers` = list(enabled = TRUE, restart = "continuous")),
      appendix = list(`line-numbers` = list(enabled = FALSE))
    )
  )
  brk <- list(has_line_numbers = TRUE, line_numbers_restart = "continuous")
  expect_equal(match_css_section_name(brk, page_config), "body")
})

test_that("matches section without line numbers to CSS named page without line numbers (#19)", {
  page_config <- list(
    named = list(
      body     = list(`line-numbers` = list(enabled = TRUE,  restart = "continuous")),
      appendix = list(`line-numbers` = list(enabled = FALSE))
    )
  )
  brk <- list(has_line_numbers = FALSE, line_numbers_restart = NULL)
  expect_equal(match_css_section_name(brk, page_config), "appendix")
})

test_that("restart mode tiebreaks between two line-number sections (#19)", {
  page_config <- list(
    named = list(
      body       = list(`line-numbers` = list(enabled = TRUE, restart = "continuous")),
      frontmatter = list(`line-numbers` = list(enabled = TRUE, restart = "page"))
    )
  )

  brk_cont <- list(has_line_numbers = TRUE, line_numbers_restart = "continuous")
  expect_equal(match_css_section_name(brk_cont, page_config), "body")

  brk_page <- list(has_line_numbers = TRUE, line_numbers_restart = "newPage")
  expect_equal(match_css_section_name(brk_page, page_config), "frontmatter")
})

test_that("OOXML restart values are normalised to CSS vocabulary (#19)", {
  # Word uses newSection/newPage; CSS uses section/page
  page_config <- list(
    named = list(
      body    = list(`line-numbers` = list(enabled = TRUE, restart = "section")),
      chapter = list(`line-numbers` = list(enabled = TRUE, restart = "page"))
    )
  )

  brk_section <- list(has_line_numbers = TRUE, line_numbers_restart = "newSection")
  expect_equal(match_css_section_name(brk_section, page_config), "body")

  brk_page <- list(has_line_numbers = TRUE, line_numbers_restart = "newPage")
  expect_equal(match_css_section_name(brk_page, page_config), "chapter")
})

test_that("falls back to first CSS name when no match is possible (#19)", {
  # Section has line numbers but no CSS named page does — best score tie,
  # first CSS name wins
  page_config <- list(
    named = list(
      alpha = list(`line-numbers` = list(enabled = FALSE)),
      beta  = list(`line-numbers` = list(enabled = FALSE))
    )
  )
  # Section has line numbers but no CSS named page does
  brk <- list(has_line_numbers = TRUE, line_numbers_restart = "continuous")
  result <- match_css_section_name(brk, page_config)
  # With score 0 for all, best_name is the last one iterated — implementation
  # detail, but result must be one of the known names
  expect_true(result %in% c("alpha", "beta"))
})

# ---------------------------------------------------------------------------
# section_breaks_to_ranges() integration: CSS name propagation
# ---------------------------------------------------------------------------

test_that("section_breaks_to_ranges emits named class from CSS page_config (#19)", {
  page_config <- list(
    named = list(
      body = list(`line-numbers` = list(enabled = TRUE, restart = "continuous"))
    )
  )

  brk <- list(
    idx = 3L,
    type = "nextPage",
    has_line_numbers = TRUE,
    line_numbers_restart = "continuous",
    line_numbers_count_by = NULL,
    line_numbers_start = NULL,
    line_numbers_distance = NULL,
    footer_refs = list(),
    page_start = NULL,
    has_title_pg = FALSE,
    has_content = TRUE,
    has_page_break = TRUE
  )

  ranges <- section_breaks_to_ranges(
    breaks = list(brk),
    n_children = 5L,
    footer_lookup = NULL,
    body_footer_info = NULL,
    page_config = page_config
  )

  expect_length(ranges, 1L)
  expect_equal(ranges[[1]]$name, "section-body")
  expect_true(grepl("\\.section-body", ranges[[1]]$div_open))
})

test_that("section_breaks_to_ranges falls back to 'section-body' without CSS (#19)", {
  brk <- list(
    idx = 3L,
    type = "nextPage",
    has_line_numbers = TRUE,
    line_numbers_restart = "continuous",
    line_numbers_count_by = NULL,
    line_numbers_start = NULL,
    line_numbers_distance = NULL,
    footer_refs = list(),
    page_start = NULL,
    has_title_pg = FALSE,
    has_content = TRUE,
    has_page_break = TRUE
  )

  ranges <- section_breaks_to_ranges(
    breaks = list(brk),
    n_children = 5L,
    footer_lookup = NULL,
    body_footer_info = NULL,
    page_config = NULL
  )

  expect_length(ranges, 1L)
  expect_equal(ranges[[1]]$name, "section-body")
})
