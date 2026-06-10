# Tests for pure parsing functions in R/generated_content.R

ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
        r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships")

# --- field_instr_to_placeholder ---

test_that("field_instr_to_placeholder maps PAGE to {page}", {
  expect_equal(field_instr_to_placeholder("PAGE"), "{page}")
  expect_equal(field_instr_to_placeholder("page"), "{page}")  # case-insensitive
})

test_that("field_instr_to_placeholder maps NUMPAGES to {pages}", {
  expect_equal(field_instr_to_placeholder("NUMPAGES"), "{pages}")
})

test_that("field_instr_to_placeholder maps SECTIONPAGES to {sectionpages}", {
  expect_equal(field_instr_to_placeholder("SECTIONPAGES"), "{sectionpages}")
})

test_that("field_instr_to_placeholder strips MERGEFORMAT switch", {
  expect_equal(field_instr_to_placeholder("PAGE \\* MERGEFORMAT"), "{page}")
  expect_equal(field_instr_to_placeholder("NUMPAGES \\* Arabic"), "{pages}")
})

test_that("field_instr_to_placeholder wraps unknown codes in braces", {
  expect_equal(field_instr_to_placeholder("DATE"), "{DATE}")
  expect_equal(field_instr_to_placeholder("AUTHOR"), "{AUTHOR}")
})


# --- assign_segments_to_positions ---

test_that("assign_segments_to_positions: single-left layout", {
  layout <- list(type = "single", position = "left")
  result <- assign_segments_to_positions(c("Page 1"), layout)
  expect_equal(result$left, "Page 1")
  expect_null(result$center)
  expect_null(result$right)
})

test_that("assign_segments_to_positions: single-right layout", {
  layout <- list(type = "single", position = "right")
  result <- assign_segments_to_positions(c("{page}"), layout)
  expect_equal(result$right, "{page}")
  expect_null(result$left)
  expect_null(result$center)
})

test_that("assign_segments_to_positions: single layout joins multiple segments", {
  layout <- list(type = "single", position = "center")
  result <- assign_segments_to_positions(c("Page ", "{page}"), layout)
  expect_equal(result$center, "Page {page}")
})

test_that("assign_segments_to_positions: tabbed layout with center+right tabs", {
  layout <- list(
    type = "tabbed",
    tab_info = list(
      list(val = "center", pos = "4680"),
      list(val = "right",  pos = "9360")
    )
  )
  result <- assign_segments_to_positions(c("Left text", "Center text", "Right text"), layout)
  expect_equal(result$left,   "Left text")
  expect_equal(result$center, "Center text")
  expect_equal(result$right,  "Right text")
})

test_that("assign_segments_to_positions: tabbed layout with right tab only", {
  layout <- list(
    type = "tabbed",
    tab_info = list(list(val = "right", pos = "9360"))
  )
  result <- assign_segments_to_positions(c("Left text", "{page}"), layout)
  expect_equal(result$left,  "Left text")
  expect_equal(result$right, "{page}")
  expect_null(result$center)
})

test_that("assign_segments_to_positions: empty segments returns all NULL", {
  layout <- list(type = "single", position = "left")
  result <- assign_segments_to_positions(character(0), layout)
  expect_null(result$left)
  expect_null(result$center)
  expect_null(result$right)
})


# --- extract_sectpr_footer_info ---

make_sectpr_xml <- function(body_xml) {
  doc <- xml2::read_xml(paste0(
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:body>', body_xml, '</w:body></w:document>'
  ))
  xml2::xml_find_first(doc, "//w:body/w:sectPr", ns)
}

test_that("extract_sectpr_footer_info: empty sectPr returns no refs", {
  sect_pr <- make_sectpr_xml('<w:sectPr/>')
  result <- extract_sectpr_footer_info(sect_pr, ns)
  expect_equal(length(result$footer_refs), 0)
  expect_null(result$page_start)
  expect_false(result$has_title_pg)
})

test_that("extract_sectpr_footer_info: extracts default footer reference", {
  sect_pr <- make_sectpr_xml(
    '<w:sectPr>
       <w:footerReference w:type="default" r:id="rId2"/>
     </w:sectPr>'
  )
  result <- extract_sectpr_footer_info(sect_pr, ns)
  expect_equal(length(result$footer_refs), 1)
  expect_equal(result$footer_refs[[1]]$type, "default")
  expect_equal(result$footer_refs[[1]]$r_id, "rId2")
})

test_that("extract_sectpr_footer_info: extracts first-page footer reference", {
  sect_pr <- make_sectpr_xml(
    '<w:sectPr>
       <w:footerReference w:type="first" r:id="rId3"/>
       <w:titlePg/>
     </w:sectPr>'
  )
  result <- extract_sectpr_footer_info(sect_pr, ns)
  expect_equal(result$footer_refs[[1]]$type, "first")
  expect_true(result$has_title_pg)
})

test_that("extract_sectpr_footer_info: detects page-start", {
  sect_pr <- make_sectpr_xml(
    '<w:sectPr>
       <w:pgNumType w:start="5"/>
     </w:sectPr>'
  )
  result <- extract_sectpr_footer_info(sect_pr, ns)
  expect_equal(result$page_start, "5")
})

test_that("extract_sectpr_footer_info: warns on even-page footer", {
  sect_pr <- make_sectpr_xml(
    '<w:sectPr>
       <w:footerReference w:type="even" r:id="rId4"/>
     </w:sectPr>'
  )
  expect_warning(
    extract_sectpr_footer_info(sect_pr, ns),
    "even-page footer"
  )
})


# --- build_footer_div_attrs ---

test_that("build_footer_div_attrs: returns empty string when no footer lookup", {
  result <- build_footer_div_attrs("rId1", NULL, FALSE, NULL, footer_lookup = NULL)
  expect_equal(result, "")
})

test_that("build_footer_div_attrs: emits footer=false for empty footer", {
  lookup <- list(rId1 = list(empty = TRUE))
  result <- build_footer_div_attrs("rId1", NULL, FALSE, NULL, footer_lookup = lookup)
  expect_true(grepl('footer="false"', result, fixed = TRUE))
})

test_that("build_footer_div_attrs: emits footer-right for right-only footer", {
  lookup <- list(rId1 = list(right = "{page}"))
  result <- build_footer_div_attrs("rId1", NULL, FALSE, NULL, footer_lookup = lookup)
  expect_true(grepl('footer-right="{page}"', result, fixed = TRUE))
  expect_false(grepl("footer-left", result, fixed = TRUE))
  expect_false(grepl("footer-center", result, fixed = TRUE))
})

test_that("build_footer_div_attrs: emits all three positions", {
  lookup <- list(rId1 = list(left = "Left", center = "Center", right = "Right"))
  result <- build_footer_div_attrs("rId1", NULL, FALSE, NULL, footer_lookup = lookup)
  expect_true(grepl('footer-left="Left"', result, fixed = TRUE))
  expect_true(grepl('footer-center="Center"', result, fixed = TRUE))
  expect_true(grepl('footer-right="Right"', result, fixed = TRUE))
})

test_that("build_footer_div_attrs: appends page-start when provided", {
  lookup <- list(rId1 = list(right = "{page}"))
  result <- build_footer_div_attrs("rId1", NULL, FALSE, "3", footer_lookup = lookup)
  expect_true(grepl('page-start="3"', result, fixed = TRUE))
})

test_that("build_footer_div_attrs: emits first-page footer when titlePg enabled", {
  lookup <- list(
    rId1 = list(right = "{page}"),
    rId2 = list(empty = TRUE)
  )
  result <- build_footer_div_attrs("rId1", "rId2", TRUE, NULL, footer_lookup = lookup)
  expect_true(grepl('footer-first="false"', result, fixed = TRUE))
})

test_that("build_footer_div_attrs: skips first-page footer when titlePg disabled", {
  lookup <- list(
    rId1 = list(right = "{page}"),
    rId2 = list(empty = TRUE)
  )
  result <- build_footer_div_attrs("rId1", "rId2", FALSE, NULL, footer_lookup = lookup)
  expect_false(grepl("footer-first", result, fixed = TRUE))
})


# --- check_bookmark_range ---

test_that("check_bookmark_range: returns NULL when index out of all ranges", {
  ranges <- list(
    list(start_idx = 1L, end_idx = 5L, div_open = "::: foo", div_close = ":::")
  )
  expect_null(check_bookmark_range(10L, ranges))
})

test_that("check_bookmark_range: returns range data for matching index", {
  ranges <- list(
    list(start_idx = 1L, end_idx = 5L, div_open = "::: foo", div_close = ":::")
  )
  result <- check_bookmark_range(3L, ranges)
  expect_equal(result$div_open, "::: foo")
  expect_equal(result$div_close, ":::")
})

test_that("check_bookmark_range: boundary indices are included", {
  ranges <- list(
    list(start_idx = 2L, end_idx = 4L, div_open = "::: a", div_close = ":::")
  )
  expect_equal(check_bookmark_range(2L, ranges)$div_open, "::: a")
  expect_equal(check_bookmark_range(4L, ranges)$div_open, "::: a")
  expect_null(check_bookmark_range(1L, ranges))
  expect_null(check_bookmark_range(5L, ranges))
})

test_that("check_bookmark_range: returns innermost (last) match for nested ranges", {
  ranges <- list(
    list(start_idx = 1L, end_idx = 10L, div_open = "::: outer", div_close = ":::"),
    list(start_idx = 3L, end_idx  = 7L, div_open = "::: inner", div_close = ":::")
  )
  # Index in both ranges — inner (last) wins
  result <- check_bookmark_range(5L, ranges)
  expect_equal(result$div_open, "::: inner")
})

test_that("check_bookmark_range: returns NULL for empty ranges", {
  expect_null(check_bookmark_range(3L, list()))
})
