# Tests for section_map.R — structural metadata sidecar (#72)

ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

make_body <- function(n_paras = 5) {
  xml2::read_xml(paste0(
    '<w:body xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    paste(sprintf('<w:p><w:r><w:t>Para %d</w:t></w:r></w:p>', seq_len(n_paras)),
          collapse = ""),
    '<w:sectPr/>',
    '</w:body>'
  ))
}

# ---------------------------------------------------------------------------
# Group 1: compute_para_position()
# ---------------------------------------------------------------------------

test_that("compute_para_position returns correct 1-based index (#72)", {
  body <- make_body(4)
  children <- xml2::xml_children(body)

  expect_equal(compute_para_position(children[[1]], body), 1L)
  expect_equal(compute_para_position(children[[3]], body), 3L)
  expect_equal(compute_para_position(children[[5]], body), 5L)  # sectPr
})

test_that("compute_para_position returns NA for node not in body (#72)", {
  body <- make_body(3)
  other <- xml2::read_xml('<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>')
  result <- compute_para_position(other, body)
  expect_true(is.na(result))
})

# ---------------------------------------------------------------------------
# Group 2: write_section_map() / read_section_map()
# ---------------------------------------------------------------------------

test_that("write_section_map / read_section_map round-trips correctly (#72)", {
  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  body <- make_body(5)
  children <- xml2::xml_children(body)

  seq <- list(
    list(
      section_class     = "section-body",
      sectpr_para       = children[[2]],
      is_closing        = FALSE,
      line_numbers      = "continuous",
      field_code_payload = list(`footer-right` = "Page {page}")
    ),
    list(
      section_class     = "section-appendix",
      sectpr_para       = children[[4]],
      is_closing        = TRUE,
      line_numbers      = "none",
      field_code_payload = list()
    )
  )
  body_section <- list(line_numbers = "none", field_code_payload = list())

  write_section_map(seq, body_section, body, sidecar_path = td,
                    docstyle_version = "test")

  result <- read_section_map(td)
  expect_false(is.null(result))
  expect_equal(result$docstyle_version, "test")
  expect_length(result$sections, 2L)

  s1 <- result$sections[[1]]
  expect_equal(s1$section_class, "section-body")
  expect_equal(s1$para_position, 2L)
  expect_false(s1$is_closing)
  expect_equal(s1$line_numbers, "continuous")
  expect_equal(s1$field_code_payload[["footer-right"]], "Page {page}")

  s2 <- result$sections[[2]]
  expect_equal(s2$section_class, "section-appendix")
  expect_equal(s2$para_position, 4L)
  expect_true(s2$is_closing)

  expect_equal(result$body_section$line_numbers, "none")
})

test_that("write_section_map handles NULL sectpr_para as null para_position (#72)", {
  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  body <- make_body(3)
  seq <- list(list(
    section_class     = "section-body",
    sectpr_para       = NULL,
    is_closing        = FALSE,
    line_numbers      = "none",
    field_code_payload = list()
  ))
  body_section <- list(line_numbers = "none", field_code_payload = list())

  write_section_map(seq, body_section, body, sidecar_path = td)
  result <- read_section_map(td)

  expect_null(result$sections[[1]]$para_position)
})

test_that("write_section_map returns NULL invisibly for empty section_sequence (#72)", {
  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  body <- make_body(2)
  result <- write_section_map(list(), list(), body, sidecar_path = td)
  expect_null(result)
  expect_false(file.exists(file.path(td, "section-map.json")))
})

test_that("write_section_map uses atomic write (tmp file renamed) (#72)", {
  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  body <- make_body(2)
  children <- xml2::xml_children(body)
  seq <- list(list(
    section_class = "section-body", sectpr_para = children[[1]],
    is_closing = FALSE, line_numbers = "none", field_code_payload = list()
  ))
  body_section <- list(line_numbers = "none", field_code_payload = list())

  write_section_map(seq, body_section, body, sidecar_path = td)

  # After successful write, tmp file should not exist
  expect_false(file.exists(file.path(td, "section-map.json.tmp")))
  expect_true(file.exists(file.path(td, "section-map.json")))
})

test_that("read_section_map returns NULL silently for missing file (required=FALSE) (#72)", {
  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  # Default: silent on first render (no warning)
  expect_no_warning(result <- read_section_map(td))
  expect_null(result)
})

test_that("read_section_map warns when required=TRUE and file is missing (#72)", {
  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  expect_warning(result <- read_section_map(td, required = TRUE), regexp = "not found")
  expect_null(result)
})

test_that("read_section_map returns NULL with warning for corrupt JSON (#72)", {
  td <- tempfile()
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  writeLines("{not valid json{{", file.path(td, "section-map.json"))
  expect_warning(result <- read_section_map(td), regexp = "Could not parse")
  expect_null(result)
})

# ---------------------------------------------------------------------------
# Group 3: scoped deferral — regression tests for #72
# ---------------------------------------------------------------------------

make_section_body <- function(markers_xml) {
  xml2::read_xml(paste0(
    '<w:body xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:p><w:r><w:t>Preamble content</w:t></w:r></w:p>',
    markers_xml,
    '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr>',
    '</w:body>'
  ))
}

# Helper: build a DOCSTYLE_SECTION marker paragraph with optional field code payload
section_marker_para <- function(class, page_break = FALSE,
                                 line_numbers = "none",
                                 page_start = NULL) {
  payload <- list()
  if (!is.null(page_start)) payload[["page-start"]] <- page_start
  json_str <- if (length(payload) > 0) {
    jsonlite::toJSON(payload, auto_unbox = TRUE)
  } else { "{}" }

  prefix <- if (grepl("-end$", class)) "DOCSTYLE_SECTION_END" else "DOCSTYLE_SECTION"
  marker_text <- paste(prefix, class,
                       if (page_break) "true" else "false",
                       line_numbers, sep = "::")

  # Escape XML special chars in JSON string for embedding in XML attribute
  json_escaped <- gsub("&", "&amp;", json_str, fixed = TRUE)
  json_escaped <- gsub('"', "&quot;", json_escaped, fixed = TRUE)

  paste0(
    '<w:p>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText> DOCSTYLE ', json_escaped, ' </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:t>', marker_text, '</w:t></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r>',
    '</w:p>'
  )
}

content_para <- function(text = "Content paragraph") {
  paste0('<w:p><w:r><w:t>', text, '</w:t></w:r></w:p>')
}

test_that("scoped deferral: adjacent wrapping divs get independent page-start (#72)", {
  # Two adjacent wrapping divs, each with page-start=1.
  # Previously, deferred_page_start was unscoped so the second div's closing
  # marker would consume the first div's deferred value (or vice versa).
  body_xml <- paste0(
    content_para("Before main"),
    section_marker_para("section-main", page_break = TRUE,
                        line_numbers = "continuous", page_start = "1"),
    content_para("Main content"),
    section_marker_para("section-main-end"),
    content_para("Before appendix"),
    section_marker_para("section-appendix", page_break = TRUE,
                        line_numbers = "none", page_start = "1"),
    content_para("Appendix content"),
    section_marker_para("section-appendix-end")
  )
  body <- make_section_body(body_xml)
  ns_local <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  page_config <- list(size = "letter", orientation = "portrait",
                      margins = list(top = 1440, bottom = 1440,
                                     left = 1440, right = 1440))

  result <- assemble_section_breaks(body, ns_local, page_config, verbose = FALSE)

  # Both closing markers should have produced sectPr nodes
  all_sectpr <- xml2::xml_find_all(body, ".//w:pPr/w:sectPr", ns_local)
  # At least 2 sectPr (one per wrapping div)
  expect_gte(length(all_sectpr), 2L)

  # Each sectPr that has pgNumType should have start="1" from its OWN div
  pg_num_types <- xml2::xml_find_all(body, ".//w:sectPr/w:pgNumType", ns_local)
  for (pnt in pg_num_types) {
    expect_equal(xml2::xml_attr(pnt, "start"), "1")
  }
})

test_that("scoped deferral: page-break (sect_type=nextPage) on first div does not leak to second (#72)", {
  # First div has page_break=TRUE (defers sect_type=nextPage), second does not.
  # Previously, deferred_sect_type was unscoped; the second closing marker
  # would receive nextPage from the first div's deferred state.
  body_xml <- paste0(
    content_para("Before main"),
    section_marker_para("section-main", page_break = TRUE,
                        line_numbers = "none"),
    content_para("Main content"),
    section_marker_para("section-main-end"),
    content_para("Before appendix"),
    section_marker_para("section-appendix", page_break = FALSE,
                        line_numbers = "none"),
    content_para("Appendix content"),
    section_marker_para("section-appendix-end")
  )
  body <- make_section_body(body_xml)
  ns_local <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  page_config <- list(size = "letter", orientation = "portrait",
                      margins = list(top = 1440, bottom = 1440,
                                     left = 1440, right = 1440))

  assemble_section_breaks(body, ns_local, page_config, verbose = FALSE)

  # Collect all inline sectPr elements (opening + closing markers, 2 divs = 4 total)
  all_sectpr <- xml2::xml_find_all(body, ".//w:pPr/w:sectPr", ns_local)
  expect_length(all_sectpr, 4L)

  # Only the first closing marker's sectPr should have w:type="nextPage"
  types <- vapply(all_sectpr, function(sp) {
    t <- xml2::xml_find_first(sp, "w:type", ns_local)
    if (inherits(t, "xml_missing")) NA_character_
    else xml2::xml_attr(t, "val")
  }, character(1))

  n_next_page <- sum(types == "nextPage", na.rm = TRUE)
  expect_equal(n_next_page, 1L,
    info = "Only the first closing marker should have sect_type=nextPage; second should not inherit it")
})

test_that("scoped deferral: page-start on first div does not leak to second (#72)", {
  # First div has page-start=5, second has no page-start.
  # Previously, deferred_page_start would leak and second closing marker
  # would apply page-start=5.
  body_xml <- paste0(
    content_para("Before main"),
    section_marker_para("section-main", page_break = TRUE,
                        line_numbers = "none", page_start = "5"),
    content_para("Main content"),
    section_marker_para("section-main-end"),
    content_para("Before appendix"),
    section_marker_para("section-appendix", page_break = FALSE,
                        line_numbers = "none"),
    content_para("Appendix content"),
    section_marker_para("section-appendix-end")
  )
  body <- make_section_body(body_xml)
  ns_local <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  page_config <- list(size = "letter", orientation = "portrait",
                      margins = list(top = 1440, bottom = 1440,
                                     left = 1440, right = 1440))

  assemble_section_breaks(body, ns_local, page_config, verbose = FALSE)

  all_sectpr <- xml2::xml_find_all(body, ".//w:pPr/w:sectPr", ns_local)
  pg_num_types <- xml2::xml_find_all(body, ".//w:sectPr/w:pgNumType", ns_local)

  # Only one pgNumType should exist (from the first div's page-start=5)
  expect_length(pg_num_types, 1L)
  expect_equal(xml2::xml_attr(pg_num_types[[1]], "start"), "5")
})

# ---------------------------------------------------------------------------
# Group 4: operation order — node pointers survive DOM cleanup
# ---------------------------------------------------------------------------

test_that("section_sequence node pointers remain valid after DOM cleanup passes (#72)", {
  # Build a body with section markers and some empty paragraphs that
  # clean_orphaned_paragraphs() would remove
  body_xml <- paste0(
    content_para("Real content"),
    section_marker_para("section-body", page_break = FALSE,
                        line_numbers = "continuous"),
    content_para("Section content"),
    '<w:p/>',  # orphaned empty paragraph
    '<w:p/>',
    section_marker_para("section-body-end")
  )
  body <- make_section_body(body_xml)
  ns_local <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  page_config <- list(size = "letter", orientation = "portrait",
                      margins = list(top = 1440, bottom = 1440,
                                     left = 1440, right = 1440))

  assembly_result <- assemble_section_breaks(body, ns_local, page_config)

  # Simulate DOM cleanup passes
  deduplicate_page_breaks(body, ns_local, verbose = FALSE)
  suppress_structural_paragraphs(body, ns_local, verbose = FALSE)
  clean_orphaned_paragraphs(body, ns_local, verbose = FALSE)

  # Node pointers in section_sequence should still resolve to valid sectPr
  seq <- assembly_result$section_sequence
  valid_count <- 0L
  for (s in seq) {
    if (is.null(s$sectpr_para)) next
    sectPr <- xml2::xml_find_first(s$sectpr_para, "w:pPr/w:sectPr", ns_local)
    if (!inherits(sectPr, "xml_missing")) valid_count <- valid_count + 1L
  }
  # Both opening and closing markers have a predecessor, so both get non-NULL
  # sectpr_para. The wrapping div contributes exactly 2 entries with valid pointers.
  expect_equal(valid_count, 2L)
})
