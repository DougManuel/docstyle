test_that("harvest_map_entry: content entry has expected fields", {
  e <- harvest_map_entry(
    para_index   = 3L,
    type         = "content",
    qmd_lines    = c(10L, 11L),
    para_hash    = "abc123",
    style        = "Normal",
    text_preview = "Hello world"
  )
  expect_equal(e$para_index, 3L)
  expect_equal(e$type, "content")
  expect_equal(e$qmd_lines, c(10L, 11L))
  expect_equal(e$para_hash, "abc123")
  expect_equal(e$style, "Normal")
  expect_equal(e$text_preview, "Hello world")
})

test_that("harvest_map_entry: metadata entry omits optional fields", {
  e <- harvest_map_entry(para_index = 0L, type = "metadata", style = "Title")
  expect_equal(e$para_index, 0L)
  expect_equal(e$type, "metadata")
  expect_equal(e$qmd_lines, c(NA_integer_, NA_integer_))
  expect_null(e$para_hash)
  expect_null(e$range_name)
})

test_that("harvest_map_entry: range entry includes range fields", {
  e <- harvest_map_entry(
    para_index = 5L,
    type       = "range",
    qmd_lines  = c(20L, 21L),
    range_name = "bibliography",
    range_type = "div",
    para_span  = c(5L, 12L)
  )
  expect_equal(e$range_name, "bibliography")
  expect_equal(e$range_type, "div")
  expect_equal(e$para_span, c(5L, 12L))
})

test_that("harvest_map_entry: text_preview truncated to 80 chars", {
  long <- paste(rep("x", 100), collapse = "")
  e <- harvest_map_entry(para_index = 0L, type = "content", text_preview = long)
  expect_equal(nchar(e$text_preview), 80L)
})

# ── Input guards (#115) ──────────────────────────────────────────────────────

test_that("harvest_map_entry: rejects non-integer or non-scalar para_index (#115)", {
  expect_error(harvest_map_entry(para_index = "x", type = "content"),
               "para_index", ignore.case = TRUE)
  expect_error(harvest_map_entry(para_index = c(1L, 2L), type = "content"),
               "para_index", ignore.case = TRUE)
  expect_error(harvest_map_entry(para_index = NA_integer_, type = "content"),
               "para_index", ignore.case = TRUE)
})

test_that("harvest_map_entry: rejects missing or non-character type (#115)", {
  expect_error(harvest_map_entry(para_index = 0L, type = NULL),
               "type", ignore.case = TRUE)
  expect_error(harvest_map_entry(para_index = 0L, type = ""),
               "type", ignore.case = TRUE)
  expect_error(harvest_map_entry(para_index = 0L, type = 42L),
               "type", ignore.case = TRUE)
})

test_that("harvest_map_entry: accepts all real harvest types incl. grouped-figure (#115)", {
  # Guards must NOT hardcode a closed type enum — harvest emits
  # 'grouped-figure' and content entries that legitimately omit para_hash
  # (tables, anchor text boxes). Regression guard against over-strict guards.
  expect_silent(harvest_map_entry(para_index = 0L, type = "grouped-figure",
                                   style = "grouped-figure"))
  expect_silent(harvest_map_entry(para_index = 1L, type = "content",
                                   qmd_lines = c(3L, 4L), style = "tbl"))
  expect_silent(harvest_map_entry(para_index = 2L, type = "skipped"))
})

test_that("para_plain_text_hash: stable hash for identical text", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  xml_str <- '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:r><w:t>Hello world</w:t></w:r>
  </w:p>'
  p <- xml2::read_xml(xml_str)
  h1 <- para_plain_text_hash(p, ns)
  h2 <- para_plain_text_hash(p, ns)
  expect_equal(h1, h2)
  expect_equal(nchar(h1), 32L)  # MD5 hex
})

test_that("para_plain_text_hash: different text yields different hash", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  p1 <- xml2::read_xml('<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:r><w:t>Hello</w:t></w:r></w:p>')
  p2 <- xml2::read_xml('<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:r><w:t>World</w:t></w:r></w:p>')
  expect_false(para_plain_text_hash(p1, ns) == para_plain_text_hash(p2, ns))
})

test_that("para_plain_text_hash: empty paragraph returns NA", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  p <- xml2::read_xml('<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>')
  expect_true(is.na(para_plain_text_hash(p, ns)))
})

test_that("para_plain_text_hash: hash ignores bold/italic formatting runs", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  # Plain text version
  p_plain <- xml2::read_xml('<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:r><w:t>Hello world</w:t></w:r>
  </w:p>')
  # Same text but split into bold/normal runs
  p_bold <- xml2::read_xml('<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:r><w:rPr><w:b/></w:rPr><w:t>Hello</w:t></w:r>
    <w:r><w:t xml:space="preserve"> world</w:t></w:r>
  </w:p>')
  expect_equal(para_plain_text_hash(p_plain, ns), para_plain_text_hash(p_bold, ns))
})

test_that("write_harvest_map and read_harvest_map round-trip", {
  td <- tempfile()
  on.exit(unlink(td, recursive = TRUE))
  dir.create(td)

  entries <- list(
    harvest_map_entry(0L, "content", c(5L, 5L), "hash1", "Normal", text_preview = "Intro"),
    harvest_map_entry(1L, "metadata", style = "Title"),
    harvest_map_entry(2L, "skipped")
  )

  out <- write_harvest_map(
    entries        = entries,
    source_docx    = "test.docx",
    para_count     = 3L,
    sidecar_path   = td,
    docstyle_version = "test"
  )
  expect_true(file.exists(file.path(td, "harvest-map.json")))

  map <- read_harvest_map(td)
  expect_equal(map$docstyle_version, "test")
  expect_equal(map$source_docx, "test.docx")
  expect_equal(map$paragraph_count, 3L)
  expect_length(map$entries, 3L)
  expect_equal(map$entries[[1]]$type, "content")
  expect_equal(map$entries[[1]]$qmd_lines, list(5L, 5L))
  expect_equal(map$entries[[2]]$type, "metadata")
  expect_equal(map$entries[[3]]$type, "skipped")
})

test_that("read_harvest_map returns NULL for missing file", {
  td <- tempfile()
  on.exit(unlink(td, recursive = TRUE))
  dir.create(td)
  expect_null(read_harvest_map(td))
})

test_that("write_harvest_map uses atomic write (no .tmp on success)", {
  td <- tempfile()
  on.exit(unlink(td, recursive = TRUE))
  dir.create(td)

  write_harvest_map(
    entries = list(), source_docx = "x.docx", para_count = 0L,
    sidecar_path = td, docstyle_version = "test"
  )
  expect_false(file.exists(file.path(td, "harvest-map.json.tmp")))
  expect_true(file.exists(file.path(td, "harvest-map.json")))
})

# =============================================================================
# Section-level summaries
# =============================================================================

test_that("compute_section_summaries: no sections creates single document section", {
  entries <- list(
    harvest_map_entry(0L, "content", c(1L, 1L), para_hash = "aaa"),
    harvest_map_entry(1L, "content", c(2L, 2L), para_hash = "bbb"),
    harvest_map_entry(2L, "content", c(3L, 3L), para_hash = "ccc")
  )
  qmd_lines <- c("Line 1", "Line 2", "Line 3")
  all_ranges <- list()

  sections <- compute_section_summaries(entries, all_ranges, qmd_lines)
  expect_length(sections, 1L)
  expect_equal(sections[[1]]$name, "document")
  expect_equal(sections[[1]]$para_range, c(0L, 2L))
  expect_equal(sections[[1]]$qmd_range, c(1L, 3L))
  expect_false(is.na(sections[[1]]$section_hash))
  expect_equal(nchar(sections[[1]]$section_hash), 32L)
})

test_that("compute_section_summaries: all skipped entries yields NA hash", {
  entries <- list(
    harvest_map_entry(0L, "skipped"),
    harvest_map_entry(1L, "metadata", style = "Title")
  )
  qmd_lines <- character(0)
  all_ranges <- list()

  sections <- compute_section_summaries(entries, all_ranges, qmd_lines)
  expect_length(sections, 1L)
  expect_equal(sections[[1]]$name, "document")
  expect_true(is.na(sections[[1]]$section_hash))
})

test_that("compute_section_summaries: qmd_range spans all content entries", {
  # min(qmd_lines[1]) across entries = 2; max(qmd_lines[2]) = 9
  # Verifies compute_section_qmd_range tracks both ends across non-contiguous entries.
  entries <- list(
    harvest_map_entry(0L, "content", c(2L, 3L), para_hash = "a"),
    harvest_map_entry(1L, "skipped"),
    harvest_map_entry(2L, "content", c(7L, 9L), para_hash = "b")
  )
  qmd_lines <- rep("x", 9)
  all_ranges <- list()

  sections <- compute_section_summaries(entries, all_ranges, qmd_lines)
  expect_equal(sections[[1]]$qmd_range, c(2L, 9L))
})

test_that("compute_section_summaries: metadata-only section has NA qmd_range and zero citations", {
  # When all entries lack qmd_lines (type != "content"), qmd_range must be NA
  # and the NA guard in build_section_summary must suppress citation extraction.
  entries <- list(
    harvest_map_entry(0L, "metadata", style = "Title"),
    harvest_map_entry(1L, "metadata", style = "Date")
  )
  all_ranges <- list()

  sections <- compute_section_summaries(entries, all_ranges, character(0))
  s <- sections[[1]]
  expect_true(is.na(s$qmd_range[[1]]))
  expect_equal(s$citation_keys, list())
  expect_equal(s$comment_count, 0L)
})

test_that("compute_section_summaries: one explicit section", {
  entries <- list(
    harvest_map_entry(0L, "skipped"),
    harvest_map_entry(1L, "content", c(2L, 2L), para_hash = "hash1"),
    harvest_map_entry(2L, "content", c(3L, 3L), para_hash = "hash2"),
    harvest_map_entry(3L, "skipped")
  )
  qmd_lines <- c("", "Para 1", "Para 2", "")
  all_ranges <- list(
    list(name = "section-body", type = "native-section",
         start_idx = 1L, end_idx = 4L)
  )

  sections <- compute_section_summaries(entries, all_ranges, qmd_lines)
  expect_length(sections, 1L)
  expect_equal(sections[[1]]$name, "section-body")
  expect_equal(sections[[1]]$para_range, c(0L, 3L))
})

test_that("compute_section_summaries: preamble boundary uses first_start_idx - 2", {
  # section starts at 1-based index 1 (0-based 0): no room for preamble
  entries <- list(
    harvest_map_entry(0L, "content", c(1L, 1L), para_hash = "aaa")
  )
  all_ranges <- list(
    list(name = "section-body", type = "section", start_idx = 1L, end_idx = 1L)
  )
  sections <- compute_section_summaries(entries, all_ranges, c("Para 1"))
  names <- vapply(sections, function(s) s$name, character(1))
  expect_false("preamble" %in% names)
  expect_true("section-body" %in% names)
})

test_that("compute_section_summaries: gap between two sections with content", {
  # section-body: paras 0-1 (1-based 1-2), section-appendix: paras 4-5 (1-based 5-6)
  # gap: paras 2-3 (1-based 3-4)
  entries <- list(
    harvest_map_entry(0L, "content", c(1L, 1L), para_hash = "s1a"),
    harvest_map_entry(1L, "content", c(2L, 2L), para_hash = "s1b"),
    harvest_map_entry(2L, "content", c(3L, 3L), para_hash = "gap_content"),
    harvest_map_entry(3L, "skipped"),
    harvest_map_entry(4L, "content", c(5L, 5L), para_hash = "s2a"),
    harvest_map_entry(5L, "content", c(6L, 6L), para_hash = "s2b")
  )
  qmd_lines <- c("Sec1 A", "Sec1 B", "Gap para", "", "Sec2 A", "Sec2 B")
  all_ranges <- list(
    list(name = "section-body",     type = "section", start_idx = 1L, end_idx = 2L),
    list(name = "section-appendix", type = "section", start_idx = 5L, end_idx = 6L)
  )

  sections <- compute_section_summaries(entries, all_ranges, qmd_lines)
  names <- vapply(sections, function(s) s$name, character(1))

  expect_true("section-body"     %in% names)
  expect_true("gap_1"            %in% names)
  expect_true("section-appendix" %in% names)

  gap <- sections[[which(names == "gap_1")]]
  expect_equal(gap$para_range, c(2L, 3L))
})

test_that("compute_section_summaries: adjacent sections produce no gap (end_0 < start_0 guard)", {
  # section-body: paras 0-1 (1-based 1-2), section-appendix: paras 2-3 (1-based 3-4)
  # gap arithmetic: gap_start = 2, gap_end = 3 - 2 = 1 → end_0 < start_0 → suppressed
  entries <- list(
    harvest_map_entry(0L, "content", c(1L, 1L), para_hash = "s1"),
    harvest_map_entry(1L, "content", c(2L, 2L), para_hash = "s2"),
    harvest_map_entry(2L, "content", c(3L, 3L), para_hash = "s3"),
    harvest_map_entry(3L, "content", c(4L, 4L), para_hash = "s4")
  )
  qmd_lines <- c("S1", "S2", "S3", "S4")
  all_ranges <- list(
    list(name = "section-body",     type = "section", start_idx = 1L, end_idx = 2L),
    list(name = "section-appendix", type = "section", start_idx = 3L, end_idx = 4L)
  )

  sections <- compute_section_summaries(entries, all_ranges, qmd_lines)
  names <- vapply(sections, function(s) s$name, character(1))
  expect_false("gap_1" %in% names)
  expect_true("section-body"     %in% names)
  expect_true("section-appendix" %in% names)
})

test_that("compute_section_summaries: single-paragraph gap (gap_start == gap_end)", {
  # section-body: paras 0-1 (1-based 1-2), section-appendix: paras 3-4 (1-based 4-5)
  # gap: para 2 only (1-based 3) — gap_start = 2, gap_end = 4 - 2 = 2
  entries <- list(
    harvest_map_entry(0L, "content", c(1L, 1L), para_hash = "s1"),
    harvest_map_entry(1L, "content", c(2L, 2L), para_hash = "s2"),
    harvest_map_entry(2L, "content", c(3L, 3L), para_hash = "gap_only"),
    harvest_map_entry(3L, "content", c(4L, 4L), para_hash = "s3"),
    harvest_map_entry(4L, "content", c(5L, 5L), para_hash = "s4")
  )
  qmd_lines <- c("S1", "S2", "Gap", "S3", "S4")
  all_ranges <- list(
    list(name = "section-body",     type = "section", start_idx = 1L, end_idx = 2L),
    list(name = "section-appendix", type = "section", start_idx = 4L, end_idx = 5L)
  )

  sections <- compute_section_summaries(entries, all_ranges, qmd_lines)
  names <- vapply(sections, function(s) s$name, character(1))
  expect_true("gap_1" %in% names)
  gap <- sections[[which(names == "gap_1")]]
  expect_equal(gap$para_range, c(2L, 2L))
})

test_that("compute_section_summaries: unsorted ranges are sorted by start_idx", {
  # Pass sections in reverse order — output should be in document order
  entries <- list(
    harvest_map_entry(0L, "content", c(1L, 1L), para_hash = "s1"),
    harvest_map_entry(1L, "content", c(2L, 2L), para_hash = "s2"),
    harvest_map_entry(2L, "content", c(3L, 3L), para_hash = "s3"),
    harvest_map_entry(3L, "content", c(4L, 4L), para_hash = "s4")
  )
  qmd_lines <- c("S1", "S2", "S3", "S4")
  # Reversed order: section-appendix before section-body
  all_ranges <- list(
    list(name = "section-appendix", type = "section", start_idx = 3L, end_idx = 4L),
    list(name = "section-body",     type = "section", start_idx = 1L, end_idx = 2L)
  )

  sections <- compute_section_summaries(entries, all_ranges, qmd_lines)
  names <- vapply(sections, function(s) s$name, character(1))
  # First section in output should be section-body (lower start_idx)
  expect_equal(names[[1]], "section-body")
  expect_equal(names[[2]], "section-appendix")
  # para_ranges should be non-overlapping and increasing
  expect_equal(sections[[1]]$para_range, c(0L, 1L))
  expect_equal(sections[[2]]$para_range, c(2L, 3L))
})

# ── Section-range bounds guards (#114) ───────────────────────────────────────

test_that("compute_section_summaries: rejects non-integer range bounds (#114)", {
  # A malformed range (missing/non-integer start_idx or end_idx) previously
  # produced silently-wrong para ranges via index arithmetic. It must now
  # fail fast, naming the offending range.
  entries <- list(harvest_map_entry(0L, "content", c(1L, 1L), para_hash = "a"))
  qmd_lines <- c("X")

  bad_start <- list(list(name = "section-body", type = "section",
                         start_idx = "1", end_idx = 2L))
  expect_error(compute_section_summaries(entries, bad_start, qmd_lines),
               "section-body", ignore.case = TRUE)

  missing_end <- list(list(name = "section-x", type = "section",
                           start_idx = 1L))
  expect_error(compute_section_summaries(entries, missing_end, qmd_lines),
               "section-x", ignore.case = TRUE)
})

test_that("compute_section_summaries: rejects inverted or out-of-bounds ranges (#114)", {
  entries <- list(harvest_map_entry(0L, "content", c(1L, 1L), para_hash = "a"))
  qmd_lines <- c("X")

  inverted <- list(list(name = "section-bad", type = "section",
                        start_idx = 5L, end_idx = 2L))
  expect_error(compute_section_summaries(entries, inverted, qmd_lines),
               "section-bad", ignore.case = TRUE)

  zero_start <- list(list(name = "section-zero", type = "section",
                          start_idx = 0L, end_idx = 2L))
  expect_error(compute_section_summaries(entries, zero_start, qmd_lines),
               "section-zero", ignore.case = TRUE)
})

test_that("compute_section_summaries: non-section ranges are not bounds-checked (#114)", {
  # Only section/native-section ranges are processed; a malformed range of
  # another type must be ignored (filtered out), not error.
  entries <- list(harvest_map_entry(0L, "content", c(1L, 1L), para_hash = "a"))
  qmd_lines <- c("X")
  other <- list(list(name = "tbl-range", type = "table",
                     start_idx = "garbage", end_idx = NULL))
  expect_silent(s <- compute_section_summaries(entries, other, qmd_lines))
  # Falls through to the single "document" section.
  expect_equal(s[[1]]$name, "document")
})

test_that("compute_section_summaries: gap with only skipped entries is suppressed", {
  entries <- list(
    harvest_map_entry(0L, "content", c(1L, 1L), para_hash = "s1"),
    harvest_map_entry(1L, "skipped"),   # gap paragraph — skipped only
    harvest_map_entry(2L, "content", c(3L, 3L), para_hash = "s2")
  )
  qmd_lines <- c("Sec1", "", "Sec2")
  all_ranges <- list(
    list(name = "section-body",     type = "section", start_idx = 1L, end_idx = 1L),
    list(name = "section-appendix", type = "section", start_idx = 3L, end_idx = 3L)
  )

  sections <- compute_section_summaries(entries, all_ranges, qmd_lines)
  names <- vapply(sections, function(s) s$name, character(1))
  expect_false("gap_1" %in% names)
})

test_that("compute_section_summaries: postamble after last section", {
  entries <- list(
    harvest_map_entry(0L, "content", c(1L, 1L), para_hash = "s1"),
    harvest_map_entry(1L, "content", c(2L, 2L), para_hash = "post")
  )
  qmd_lines <- c("Section para", "Postamble para")
  all_ranges <- list(
    list(name = "section-body", type = "section", start_idx = 1L, end_idx = 1L)
  )

  sections <- compute_section_summaries(entries, all_ranges, qmd_lines)
  names <- vapply(sections, function(s) s$name, character(1))

  expect_true("section-body" %in% names)
  expect_true("postamble"    %in% names)

  post <- sections[[which(names == "postamble")]]
  expect_equal(post$para_range, c(1L, 1L))
})

test_that("compute_section_summaries: no postamble when last section ends at doc end", {
  entries <- list(
    harvest_map_entry(0L, "content", c(1L, 1L), para_hash = "s1")
  )
  all_ranges <- list(
    list(name = "section-body", type = "section", start_idx = 1L, end_idx = 1L)
  )

  sections <- compute_section_summaries(entries, all_ranges, c("Para"))
  names <- vapply(sections, function(s) s$name, character(1))
  expect_false("postamble" %in% names)
})

test_that("compute_section_summaries: preamble + two sections", {
  entries <- list(
    harvest_map_entry(0L, "content", c(1L, 1L), para_hash = "pre1"),
    harvest_map_entry(1L, "content", c(2L, 2L), para_hash = "pre2"),
    harvest_map_entry(2L, "skipped"),
    harvest_map_entry(3L, "content", c(4L, 4L), para_hash = "sec1a"),
    harvest_map_entry(4L, "content", c(5L, 5L), para_hash = "sec1b"),
    harvest_map_entry(5L, "skipped"),
    harvest_map_entry(6L, "skipped"),
    harvest_map_entry(7L, "content", c(8L, 8L), para_hash = "sec2a"),
    harvest_map_entry(8L, "skipped")
  )
  qmd_lines <- c("Pre 1", "Pre 2", "", "Sec1 A", "Sec1 B", "", "", "Sec2 A", "")
  all_ranges <- list(
    list(name = "section-body", type = "native-section",
         start_idx = 3L, end_idx = 6L),
    list(name = "section-appendix", type = "native-section",
         start_idx = 7L, end_idx = 9L)
  )

  sections <- compute_section_summaries(entries, all_ranges, qmd_lines)
  expect_length(sections, 3L)
  expect_equal(sections[[1]]$name, "preamble")
  expect_equal(sections[[1]]$para_range, c(0L, 1L))
  expect_equal(sections[[2]]$name, "section-body")
  expect_equal(sections[[2]]$para_range, c(2L, 5L))
  expect_equal(sections[[3]]$name, "section-appendix")
  expect_equal(sections[[3]]$para_range, c(6L, 8L))
})

test_that("compute_section_summaries: hash stability", {
  entries <- list(
    harvest_map_entry(0L, "content", c(1L, 1L), para_hash = "abc"),
    harvest_map_entry(1L, "content", c(2L, 2L), para_hash = "def")
  )
  s1 <- compute_section_summaries(entries, list(), c("A", "B"))
  s2 <- compute_section_summaries(entries, list(), c("A", "B"))
  expect_equal(s1[[1]]$section_hash, s2[[1]]$section_hash)
})

test_that("compute_section_summaries: hash changes when content changes", {
  entries1 <- list(
    harvest_map_entry(0L, "content", c(1L, 1L), para_hash = "abc"),
    harvest_map_entry(1L, "content", c(2L, 2L), para_hash = "def")
  )
  entries2 <- list(
    harvest_map_entry(0L, "content", c(1L, 1L), para_hash = "abc"),
    harvest_map_entry(1L, "content", c(2L, 2L), para_hash = "CHANGED")
  )
  s1 <- compute_section_summaries(entries1, list(), c("A", "B"))
  s2 <- compute_section_summaries(entries2, list(), c("A", "B"))
  expect_false(s1[[1]]$section_hash == s2[[1]]$section_hash)
})

test_that("extract_citation_keys_from_lines: extracts keys correctly", {
  lines <- c(
    "Some text [@smith2020].",
    "See also [see @jones2019; @doe2021, p. 42].",
    "No citation here."
  )
  keys <- extract_citation_keys_from_lines(lines)
  expect_equal(sort(keys), c("doe2021", "jones2019", "smith2020"))
})

test_that("extract_citation_keys_from_lines: empty input returns empty", {
  expect_length(extract_citation_keys_from_lines(character(0)), 0L)
  expect_length(extract_citation_keys_from_lines(c("No citations")), 0L)
})

test_that("extract_citation_keys_from_lines: suppressed-author citation [-@key]", {
  keys <- extract_citation_keys_from_lines(c("As shown [-@smith2020]."))
  expect_equal(keys, "smith2020")
})

test_that("extract_citation_keys_from_lines: keys with dots and slashes", {
  keys <- extract_citation_keys_from_lines(
    c("See [@r-base_4.3; @doe2021/j.nature].")
  )
  expect_true("r-base_4.3" %in% keys)
  expect_true("doe2021/j.nature" %in% keys)
})

test_that("compute_section_summaries: comment count", {
  entries <- list(
    harvest_map_entry(0L, "content", c(1L, 3L), para_hash = "aaa")
  )
  qmd_lines <- c(
    '`<!-- comment:start id="1" -->`{=html}Text`<!-- comment:end id="1" -->`{=html}',
    "Normal line",
    '`<!-- comment:start id="2" -->`{=html}More`<!-- comment:end id="2" -->`{=html}'
  )
  sections <- compute_section_summaries(entries, list(), qmd_lines)
  expect_equal(sections[[1]]$comment_count, 2L)
})

test_that("compute_section_summaries: citation keys in sections", {
  entries <- list(
    harvest_map_entry(0L, "content", c(1L, 1L), para_hash = "aaa"),
    harvest_map_entry(1L, "skipped"),
    harvest_map_entry(2L, "content", c(3L, 3L), para_hash = "bbb")
  )
  qmd_lines <- c(
    "Cited [@knuth1984].",
    "",
    "Also [@tufte2018]."
  )
  all_ranges <- list(
    list(name = "section-body", type = "section",
         start_idx = 1L, end_idx = 1L),
    list(name = "section-refs", type = "section",
         start_idx = 3L, end_idx = 3L)
  )

  sections <- compute_section_summaries(entries, all_ranges, qmd_lines)
  # Should have section-body with knuth and section-refs with tufte
  body_sec <- Filter(function(s) s$name == "section-body", sections)[[1]]
  refs_sec <- Filter(function(s) s$name == "section-refs", sections)[[1]]
  expect_true("knuth1984" %in% unlist(body_sec$citation_keys))
  expect_true("tufte2018" %in% unlist(refs_sec$citation_keys))
})

test_that("write_harvest_map and read_harvest_map round-trip with sections", {
  td <- tempfile()
  on.exit(unlink(td, recursive = TRUE))
  dir.create(td)

  entries <- list(
    harvest_map_entry(0L, "content", c(1L, 1L), "hash1", "Normal")
  )
  test_sections <- list(
    list(
      name = "document",
      section_hash = "abc123",
      para_range = c(0L, 0L),
      qmd_range = c(1L, 1L),
      citation_keys = list("smith2020"),
      comment_count = 1L
    )
  )

  write_harvest_map(
    entries = entries, source_docx = "test.docx", para_count = 1L,
    sections = test_sections, sidecar_path = td, docstyle_version = "test"
  )

  map <- read_harvest_map(td)
  expect_false(is.null(map$sections))
  expect_length(map$sections, 1L)
  expect_equal(map$sections[[1]]$name, "document")
  expect_equal(map$sections[[1]]$section_hash, "abc123")
  expect_equal(map$sections[[1]]$citation_keys, list("smith2020"))
  expect_equal(map$sections[[1]]$comment_count, 1L)
})

test_that("read_harvest_map: old map without sections returns NULL for sections", {
  td <- tempfile()
  on.exit(unlink(td, recursive = TRUE))
  dir.create(td)

  # Write a map without sections (old format)
  write_harvest_map(
    entries = list(), source_docx = "x.docx", para_count = 0L,
    sidecar_path = td, docstyle_version = "test"
  )
  map <- read_harvest_map(td)
  expect_null(map$sections)
})

test_that("docx_to_qmd writes harvest-map.json with correct entry count", {
  skip_if_not_installed("xml2")
  docx_path <- test_path("fixtures/word-native-comments.docx")
  skip_if_not(file.exists(docx_path))

  td <- tempfile()
  on.exit(unlink(td, recursive = TRUE))
  dir.create(td)
  out_qmd <- file.path(td, "out.qmd")

  docx_to_qmd(docx_path, output_path = out_qmd, validate = FALSE)

  map_path <- file.path(td, "_docstyle", "harvest-map.json")
  expect_true(file.exists(map_path))

  map <- read_harvest_map(file.path(td, "_docstyle"))
  expect_true(map$paragraph_count >= 1L)
  expect_true(length(map$entries) >= 1L)

  # Every body child must have exactly one entry (no gaps, no duplicates)
  expect_equal(length(map$entries), map$paragraph_count)

  # qmd_line_count is recorded
  expect_true(!is.null(map$qmd_line_count) && map$qmd_line_count >= 1L)

  # All entries have valid type
  types <- vapply(map$entries, function(e) e$type, character(1))
  expect_true(all(types %in% c("content", "metadata", "range", "skipped")))

  # qmd_lines for content entries should be valid line numbers within qmd_line_count
  content <- Filter(function(e) e$type == "content", map$entries)
  if (length(content) > 0) {
    starts <- vapply(content, function(e) e$qmd_lines[[1]], integer(1))
    ends   <- vapply(content, function(e) e$qmd_lines[[2]], integer(1))
    expect_true(all(starts >= 1L))
    expect_true(all(ends >= starts))
    expect_true(all(ends <= map$qmd_line_count))
  }

  # sections array must be present and non-empty
  expect_false(is.null(map$sections))
  expect_true(length(map$sections) >= 1L)

  # Each section has required fields
  for (sec in map$sections) {
    expect_true(!is.null(sec$name))
    expect_true(!is.null(sec$para_range))
    expect_true(!is.null(sec$qmd_range))
    expect_true(!is.null(sec$citation_keys))
    expect_true(!is.null(sec$comment_count))
    # para_range within valid bounds
    expect_true(sec$para_range[[1]] >= 0L)
    expect_true(sec$para_range[[2]] < map$paragraph_count)
  }
})
