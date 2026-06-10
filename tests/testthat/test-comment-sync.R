# Test comment ID validation and sync functions

test_that("validate_comment_ids detects matching IDs", {
  # Create temp QMD with comment markers
  temp_qmd <- tempfile(fileext = ".qmd")
  temp_json <- file.path(dirname(temp_qmd), "_docstyle", "comments.json")
  dir.create(dirname(temp_json), recursive = TRUE)

  writeLines(c(
    "---",
    "title: Test",
    "---",
    "",
    "Some text `<!-- comment:start id=\"1\" -->`{=html}with a comment`<!-- comment:end id=\"1\" -->`{=html}.",
    "",
    "More text `<!-- comment:start id=\"2\" -->`{=html}another comment`<!-- comment:end id=\"2\" -->`{=html}."
  ), temp_qmd)

  # Create matching comments.json
  comments <- list(
    "1" = list(id = "1", author = "Test", content = "First comment"),
    "2" = list(id = "2", author = "Test", content = "Second comment")
  )
  jsonlite::write_json(comments, temp_json, auto_unbox = TRUE, pretty = TRUE)

  result <- validate_comment_ids(temp_qmd)

  expect_true(result$valid)
  expect_equal(sort(result$qmd_ids), c("1", "2"))
  expect_equal(sort(result$json_ids), c("1", "2"))
  expect_length(result$missing, 0)
  expect_length(result$orphaned, 0)

  unlink(dirname(temp_json), recursive = TRUE)
  unlink(temp_qmd)
})


test_that("validate_comment_ids detects missing IDs (QMD refs not in JSON)", {
  temp_qmd <- tempfile(fileext = ".qmd")
  temp_json <- file.path(dirname(temp_qmd), "_docstyle", "comments.json")
  dir.create(dirname(temp_json), recursive = TRUE)

  # QMD references IDs 1, 2, 3
  writeLines(c(
    "---",
    "title: Test",
    "---",
    "",
    "`<!-- comment:start id=\"1\" -->`{=html}text`<!-- comment:end id=\"1\" -->`{=html}",
    "`<!-- comment:start id=\"2\" -->`{=html}text`<!-- comment:end id=\"2\" -->`{=html}",
    "`<!-- comment:start id=\"3\" -->`{=html}text`<!-- comment:end id=\"3\" -->`{=html}"
  ), temp_qmd)

  # JSON only has IDs 1, 2 (missing 3)
  comments <- list(
    "1" = list(id = "1", author = "Test", content = "First"),
    "2" = list(id = "2", author = "Test", content = "Second")
  )
  jsonlite::write_json(comments, temp_json, auto_unbox = TRUE, pretty = TRUE)

  result <- validate_comment_ids(temp_qmd)

  expect_false(result$valid)
  expect_equal(result$missing, "3")
  expect_match(result$message, "CRITICAL")

  unlink(dirname(temp_json), recursive = TRUE)
  unlink(temp_qmd)
})


test_that("validate_comment_ids detects orphaned IDs (JSON has extras)", {
  temp_qmd <- tempfile(fileext = ".qmd")
  temp_json <- file.path(dirname(temp_qmd), "_docstyle", "comments.json")
  dir.create(dirname(temp_json), recursive = TRUE)

  # QMD only references ID 1
  writeLines(c(
    "---",
    "title: Test",
    "---",
    "",
    "`<!-- comment:start id=\"1\" -->`{=html}text`<!-- comment:end id=\"1\" -->`{=html}"
  ), temp_qmd)

  # JSON has IDs 1, 2, 3 (2 and 3 are orphaned)
  comments <- list(
    "1" = list(id = "1", author = "Test", content = "First"),
    "2" = list(id = "2", author = "Test", content = "Second"),
    "3" = list(id = "3", author = "Test", content = "Third")
  )
  jsonlite::write_json(comments, temp_json, auto_unbox = TRUE, pretty = TRUE)

  # Strict mode (default): orphaned = invalid
  result <- validate_comment_ids(temp_qmd, strict = TRUE)
  expect_false(result$valid)
  expect_equal(sort(result$orphaned), c("2", "3"))

  # Non-strict mode: orphaned = warning but valid
  result <- validate_comment_ids(temp_qmd, strict = FALSE)
  expect_true(result$valid)
  expect_equal(sort(result$orphaned), c("2", "3"))

  unlink(dirname(temp_json), recursive = TRUE)
  unlink(temp_qmd)
})


test_that("content_similarity calculates correctly", {
  # Identical strings
  expect_equal(content_similarity("hello world", "hello world"), 1)

  # Completely different
  expect_equal(content_similarity("hello", "goodbye"), 0)

  # Partial overlap
  score <- content_similarity("hello world", "hello there")
  expect_true(score > 0 && score < 1)

  # Empty strings
  expect_equal(content_similarity("", "hello"), 0)
  expect_equal(content_similarity("hello", ""), 0)

  # NULL handling
  expect_equal(content_similarity(NULL, "hello"), 0)
  expect_equal(content_similarity("hello", NULL), 0)
})


test_that("sync_comment_ids dry_run reports changes without modifying", {
  skip_if_not(file.exists(system.file("extdata", "minimal-example",
                                       "minimal-example.docx", package = "docstyle")))

  # Use the minimal example fixture
  fixture_docx <- system.file("extdata", "minimal-example",
                               "minimal-example.docx", package = "docstyle")

  # Create temp QMD with old IDs
  temp_qmd <- tempfile(fileext = ".qmd")
  temp_json <- file.path(dirname(temp_qmd), "_docstyle", "comments.json")
  dir.create(dirname(temp_json), recursive = TRUE)

  # Extract comments from fixture to get real IDs
  real_comments <- extract_comments(fixture_docx)

  if (length(real_comments) > 0) {
    # Create QMD with fake old IDs
    writeLines(c(
      "---",
      "title: Test",
      "---",
      "",
      "`<!-- comment:start id=\"999\" -->`{=html}text`<!-- comment:end id=\"999\" -->`{=html}"
    ), temp_qmd)

    # Create comments.json with old content matching real comment
    first_id <- names(real_comments)[1]
    comments <- list(
      "999" = list(
        id = "999",
        author = real_comments[[first_id]]$author,
        content = real_comments[[first_id]]$content
      )
    )
    jsonlite::write_json(comments, temp_json, auto_unbox = TRUE, pretty = TRUE)

    # Dry run should report mapping without changing files
    result <- sync_comment_ids(
      qmd_path = temp_qmd,
      source_docx = fixture_docx,
      comments_json = temp_json,
      dry_run = TRUE
    )

    expect_true(result$success)
    expect_match(result$message, "DRY RUN")

    # Verify QMD was not modified
    qmd_content <- readLines(temp_qmd)
    expect_true(any(grepl('id="999"', qmd_content)))
  }

  unlink(dirname(temp_json), recursive = TRUE)
  unlink(temp_qmd)
})
