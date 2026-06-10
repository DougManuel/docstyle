# P3: Round-trip validation testing

## Objective

Add validation that confirms harvest → render produces faithful output, catching regressions in the round-trip workflow.

## Current state

- `validate_docx_structure()` checks basic XML validity
- No automated comparison of round-trip fidelity
- Manual inspection required to verify changes survive

## Validation approach

Following Anthropic's pattern: rather than checking edits are valid, confirm that the workflow preserves content faithfully.

### What to compare

| Element | Compare method | Tolerance |
|---------|---------------|-----------|
| Text content | Exact match after normalization | Whitespace differences OK |
| Headings | Count and text match | - |
| Citations | Cite keys present | Formatting may differ |
| Comments | Count and content | Anchor positions may shift |
| Track changes | Preserved in spans | - |
| Tables | Row/column count, content | Cell formatting may differ |
| Lists | Item count and content | Numbering style may differ |

### What to ignore

- Font families (CSS-driven, intentionally different)
- Page breaks (layout-dependent)
- Exact whitespace
- Style IDs (regenerated)

## Implementation plan

### Phase 1: Create test fixture workflow

```r
#' Create round-trip test fixture
#' @param qmd_content Character vector of QMD content
#' @param name Fixture name for identification
create_roundtrip_fixture <- function(qmd_content, name) {
  fixture_dir <- tempfile(paste0("fixture_", name, "_"))
  dir.create(fixture_dir)

  # Write QMD
  qmd_path <- file.path(fixture_dir, paste0(name, ".qmd"))
  writeLines(qmd_content, qmd_path)

  # Copy minimal _quarto.yml
  quarto_yml <- c(
    "project:",
    "  type: default",
    "format:",
    "  docx:",
    "    filters:",
    "      - docstyle"
  )
  writeLines(quarto_yml, file.path(fixture_dir, "_quarto.yml"))

  fixture_dir
}
```

### Phase 2: Round-trip execution

```r
#' Execute round-trip: render → harvest → compare
#' @param fixture_dir Path from create_roundtrip_fixture
#' @return List with comparison results
execute_roundtrip <- function(fixture_dir) {
  qmd_files <- list.files(fixture_dir, pattern = "\\.qmd$", full.names = TRUE)
  qmd_path <- qmd_files[1]
  name <- tools::file_path_sans_ext(basename(qmd_path))

  # Step 1: Render to DOCX
  docx_path <- file.path(fixture_dir, paste0(name, ".docx"))
  withr::with_dir(fixture_dir, {
    system2("quarto", c("render", basename(qmd_path)), stdout = TRUE, stderr = TRUE)
  })

  if (!file.exists(docx_path)) {
    stop("Render failed - no DOCX produced")
  }

  # Step 2: Harvest back to QMD
  harvested_qmd <- file.path(fixture_dir, paste0(name, "_harvested.qmd"))
  docx_to_qmd(docx_path, harvested_qmd, preserve_header = FALSE)

  # Step 3: Compare
  list(
    original_qmd = qmd_path,
    rendered_docx = docx_path,
    harvested_qmd = harvested_qmd,
    comparison = compare_qmd_content(qmd_path, harvested_qmd)
  )
}
```

### Phase 3: Content comparison

```r
#' Compare QMD content for round-trip fidelity
#' @return List with match status and differences
compare_qmd_content <- function(original_qmd, harvested_qmd) {
  original <- readLines(original_qmd)
  harvested <- readLines(harvested_qmd)

  # Normalize for comparison
  normalize <- function(lines) {
    # Remove YAML header
    yaml_end <- which(lines == "---")[2]
    if (!is.na(yaml_end)) {
      lines <- lines[(yaml_end + 1):length(lines)]
    }
    # Normalize whitespace
    lines <- trimws(lines)
    lines <- lines[lines != ""]
    lines
  }

  orig_norm <- normalize(original)
  harv_norm <- normalize(harvested)

  # Text similarity
  text_match <- identical(orig_norm, harv_norm)

  # Structural checks
  count_pattern <- function(lines, pattern) {
    sum(grepl(pattern, lines))
  }

  list(
    text_match = text_match,
    heading_count_match = count_pattern(orig_norm, "^#{1,6} ") ==
                          count_pattern(harv_norm, "^#{1,6} "),
    citation_count_match = count_pattern(orig_norm, "@[a-zA-Z]") ==
                           count_pattern(harv_norm, "@[a-zA-Z]"),
    list_count_match = count_pattern(orig_norm, "^[0-9]+\\.|^- ") ==
                       count_pattern(harv_norm, "^[0-9]+\\.|^- "),
    differences = if (!text_match) {
      list(
        only_in_original = setdiff(orig_norm, harv_norm),
        only_in_harvested = setdiff(harv_norm, orig_norm)
      )
    } else NULL
  )
}
```

### Phase 4: Assertion helper for testthat

```r
#' Assert round-trip fidelity
#' @export
expect_roundtrip_fidelity <- function(qmd_content, name = "test") {
  fixture_dir <- create_roundtrip_fixture(qmd_content, name)
  on.exit(unlink(fixture_dir, recursive = TRUE))

  result <- execute_roundtrip(fixture_dir)

  testthat::expect_true(
    result$comparison$text_match,
    info = paste("Text content differs:",
                 paste(result$comparison$differences$only_in_original[1:3], collapse = "\n"))
  )
  testthat::expect_true(result$comparison$heading_count_match,
                        info = "Heading count mismatch")
  testthat::expect_true(result$comparison$citation_count_match,
                        info = "Citation count mismatch")
}
```

### Phase 5: Test cases

```r
test_that("basic text survives round-trip", {
  qmd <- c(
    "---",
    "title: Test",
    "---",
    "",
    "# Heading 1",
    "",
    "This is a paragraph with **bold** and *italic* text.",
    "",
    "## Heading 2",
    "",
    "Another paragraph."
  )
  expect_roundtrip_fidelity(qmd, "basic_text")
})

test_that("citations survive round-trip", {
  qmd <- c(
    "---",
    "title: Test",
    "bibliography: references.bib",
    "---",
    "",
    "As shown by @smith2020, this is important [@jones2021]."
  )
  # Note: Need to provide references.bib in fixture
  expect_roundtrip_fidelity(qmd, "citations")
})

test_that("track changes survive round-trip", {
  qmd <- c(
    "---",
    "title: Test",
    "---",
    "",
    "This has [inserted text]{.ins id=\"rev_1\"} and [~~deleted~~]{.del id=\"rev_2\"}."
  )
  expect_roundtrip_fidelity(qmd, "track_changes")
})
```

## CI/CD considerations

1. **GitHub Actions:** Add round-trip tests to test workflow
2. **Fixtures:** Store minimal test fixtures in `tests/testthat/fixtures/`
3. **Quarto requirement:** CI needs Quarto installed for render step
4. **Timeout:** Round-trip tests are slower; consider separate test job

## Files to create/modify

- `R/validate_roundtrip.R` - New validation functions
- `tests/testthat/test-roundtrip.R` - Test cases
- `tests/testthat/fixtures/` - Test fixtures
- `.github/workflows/test.yml` - Update CI

## Success criteria

- [ ] Basic text round-trip passes
- [ ] Citations preserved (count match)
- [ ] Track changes preserved in QMD spans
- [ ] Comments preserved (count match)
- [ ] CI runs round-trip tests on PR
