# Tests for anchor CSS property extraction

test_that("css_to_anchor_style() extracts all positioning properties", {
  props <- list(
    `vertical-anchor` = "text",
    `horizontal-anchor` = "margin",
    `position-y` = "0",
    `position-x` = "0",
    `float-width` = "250pt",
    `wrap-style` = "square",
    `wrap-side` = "both",
    `wrap-distance` = "0 198dxa 0 198dxa",
    `z-layer` = "behind"
  )

  result <- css_to_anchor_style(props)

  expect_equal(result$vertical_anchor, "text")
  expect_equal(result$horizontal_anchor, "margin")
  expect_equal(result$position_y, "0")
  expect_equal(result$position_x, "0")
  expect_equal(result$float_width, "250pt")
  expect_equal(result$wrap_style, "square")
  expect_equal(result$wrap_side, "both")
  expect_equal(result$wrap_distance, "0 198dxa 0 198dxa")
  expect_equal(result$z_layer, "behind")
})

test_that("css_to_anchor_style() returns NULL when no anchor properties", {
  props <- list(`font-size` = "12pt", `color` = "#000000")
  result <- css_to_anchor_style(props)
  expect_null(result)
})

test_that("css_to_anchor_style() applies defaults for missing optional properties", {
  props <- list(`vertical-anchor` = "page", `horizontal-anchor` = "margin")
  result <- css_to_anchor_style(props)

  expect_equal(result$vertical_anchor, "page")
  expect_equal(result$horizontal_anchor, "margin")
  expect_equal(result$position_y, "0")
  expect_equal(result$position_x, "0")
  expect_null(result$float_width)
  expect_equal(result$wrap_style, "square")
  expect_equal(result$wrap_side, "both")
  expect_equal(result$wrap_distance, "0 198dxa 0 198dxa")
  expect_equal(result$z_layer, "front")
})

test_that("extract_anchor_styles() finds anchor-eligible selectors", {
  css_styles <- list(
    `.column-margin` = list(
      `vertical-anchor` = "text",
      `horizontal-anchor` = "margin",
      `float-width` = "250pt"
    ),
    `.journal-sidebar` = list(
      `vertical-anchor` = "page",
      `horizontal-anchor` = "margin",
      `position-y` = "11461dxa",
      `float-width` = "2410dxa"
    ),
    `body` = list(`font-size` = "12pt"),
    `h1` = list(`font-size` = "24pt")
  )

  result <- extract_anchor_styles(css_styles)

  expect_equal(length(result), 2)
  expect_true("column-margin" %in% names(result))
  expect_true("journal-sidebar" %in% names(result))
  expect_equal(result$`column-margin`$vertical_anchor, "text")
  expect_equal(result$`journal-sidebar`$position_y, "11461dxa")
})

test_that("extract_anchor_styles() returns empty list when no anchor selectors", {
  css_styles <- list(
    `body` = list(`font-size` = "12pt"),
    `.table-formal` = list(`border-bottom` = "1pt solid #000000")
  )

  result <- extract_anchor_styles(css_styles)
  expect_equal(length(result), 0)
})

test_that("extract_anchor_styles() handles NULL input", {
  expect_equal(extract_anchor_styles(NULL), list())
})

# --- EMU conversion tests ---

test_that("css_to_emu() converts points to EMU", {
  # 1 pt = 12700 EMU
  expect_equal(css_to_emu("1pt"), 12700L)
  expect_equal(css_to_emu("10pt"), 127000L)
  expect_equal(css_to_emu("250pt"), 3175000L)
})

test_that("css_to_emu() converts inches to EMU", {
  # 1 inch = 914400 EMU
  expect_equal(css_to_emu("1in"), 914400L)
  expect_equal(css_to_emu("0.5in"), 457200L)
})

test_that("css_to_emu() converts cm to EMU", {
  # 1 cm = 360000 EMU
  expect_equal(css_to_emu("1cm"), 360000L)
  expect_equal(css_to_emu("2.54cm"), 914400L)  # = 1 inch
})

test_that("css_to_emu() handles dxa suffix", {
  # 1 dxa (twip) = 635 EMU
  expect_equal(css_to_emu("5000dxa"), 3175000L)
  expect_equal(css_to_emu("198dxa"), 125730L)
})

test_that("css_to_emu() handles plain integer as dxa", {
  # Plain numbers treated as DXA (twips) for backward compat
  expect_equal(css_to_emu("5000"), 3175000L)
})

# --- content-mode tests ---

test_that("css_to_anchor_style() extracts content-mode property", {
  props <- list(
    "vertical-anchor" = "text",
    "horizontal-anchor" = "margin",
    "content-mode" = "textbox"
  )
  result <- css_to_anchor_style(props)
  expect_equal(result$content_mode, "textbox")
})

test_that("css_to_anchor_style() defaults content_mode to auto", {
  props <- list(
    "vertical-anchor" = "text",
    "horizontal-anchor" = "margin"
  )
  result <- css_to_anchor_style(props)
  expect_null(result$content_mode)
})
