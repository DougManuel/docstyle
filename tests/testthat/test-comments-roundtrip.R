# Tests for comment round-trip (P3)
# Tests extraction from real Word documents and re-injection

test_that("extract_comments reads threading from real Word document", {
  # Use fixture with native Word threaded comments
  fixture_path <- test_path("fixtures", "word-native-comments.docx")
  skip_if_not(file.exists(fixture_path), "Fixture not available")

  comments <- extract_comments(fixture_path)

  # Should have extracted comments

  expect_true(length(comments) > 0)

  # Check that we have at least one threaded comment (with parent_id)
  has_threading <- any(sapply(comments, function(c) !is.null(c$parent_id)))
  expect_true(has_threading, info = "Expected at least one threaded comment reply")

  # Check that we have resolved comments (done = TRUE)
  has_resolved <- any(sapply(comments, function(c) isTRUE(c$done)))
  expect_true(has_resolved, info = "Expected at least one resolved comment")

  # Check that para_id is extracted
  has_para_id <- any(sapply(comments, function(c) !is.null(c$para_id)))
  expect_true(has_para_id, info = "Expected para_id to be extracted")
})

test_that("extract_comments captures correct threading relationships", {
  fixture_path <- test_path("fixtures", "word-native-comments.docx")
  skip_if_not(file.exists(fixture_path), "Fixture not available")

  comments <- extract_comments(fixture_path)

  # Find comments with parent_id
  replies <- Filter(function(c) !is.null(c$parent_id), comments)

  if (length(replies) > 0) {
    # Each reply's parent_id should reference an existing comment
    for (reply in replies) {
      expect_true(
        reply$parent_id %in% names(comments),
        info = paste("Reply", reply$id, "parent_id", reply$parent_id, "not found in comments")
      )
    }
  }
})

test_that("comment round-trip preserves threading and resolved status", {
  fixture_path <- test_path("fixtures", "word-native-comments.docx")
  skip_if_not(file.exists(fixture_path), "Fixture not available")

  # Extract original comments
  original_comments <- extract_comments(fixture_path)
  skip_if(length(original_comments) == 0, "No comments in fixture")

  # Write to temp JSON
  temp_json <- tempfile(fileext = ".json")
  on.exit(unlink(temp_json), add = TRUE)
  write_comments_json(original_comments, temp_json)

  # Read back
  reloaded <- read_comments_json(temp_json)

  # Verify structure preserved
  expect_equal(length(reloaded), length(original_comments))

  for (id in names(original_comments)) {
    orig <- original_comments[[id]]
    reload <- reloaded[[id]]

    expect_equal(reload$author, orig$author, info = paste("Author mismatch for", id))
    expect_equal(reload$content, orig$content, info = paste("Content mismatch for", id))
    expect_equal(reload$parent_id, orig$parent_id, info = paste("parent_id mismatch for", id))
    expect_equal(reload$done, orig$done, info = paste("done mismatch for", id))
  }
})

test_that("inject_comments creates valid DOCX with extended files", {
  # Create minimal test document
  temp_docx <- tempfile(fileext = ".docx")
  temp_json <- tempfile(fileext = ".json")
  on.exit(unlink(c(temp_docx, temp_json)), add = TRUE)

  # Create a simple docx using officer
  skip_if_not_installed("officer")
  doc <- officer::read_docx()
  doc <- officer::body_add_par(doc, "Test paragraph for comments.")
  print(doc, target = temp_docx)

  # Create test comments with threading
  comments <- list(
    "1" = list(
      id = "1",
      author = "Test Author",
      initials = "TA",
      date = "2026-01-15T10:00:00Z",
      content = "Parent comment",
      parent_id = NULL,
      done = FALSE
    ),
    "2" = list(
      id = "2",
      author = "Reply Author",
      initials = "RA",
      date = "2026-01-15T11:00:00Z",
      content = "This is a reply",
      parent_id = "1",
      done = FALSE
    ),
    "3" = list(
      id = "3",
      author = "Test Author",
      initials = "TA",
      date = "2026-01-15T12:00:00Z",
      content = "Resolved comment",
      parent_id = NULL,
      done = TRUE
    )
  )

  # Write comments JSON
  write_comments_json(comments, temp_json)

  # Inject comments
  inject_comments(temp_docx, temp_json)

  # Verify the DOCX has the expected files
  temp_extract <- tempfile("extract_")
  dir.create(temp_extract)
  on.exit(unlink(temp_extract, recursive = TRUE), add = TRUE)
  utils::unzip(temp_docx, exdir = temp_extract)

  # Check comments.xml exists
  expect_true(file.exists(file.path(temp_extract, "word", "comments.xml")))

  # Check commentsExtended.xml exists (for threading)
  expect_true(file.exists(file.path(temp_extract, "word", "commentsExtended.xml")))

  # Check people.xml exists
  expect_true(file.exists(file.path(temp_extract, "word", "people.xml")))

  # Verify commentsExtended.xml has threading
  extended_content <- readLines(file.path(temp_extract, "word", "commentsExtended.xml"))
  extended_text <- paste(extended_content, collapse = "")
  expect_match(extended_text, "paraIdParent", info = "Expected threading in commentsExtended.xml")

  # Verify resolved status
  expect_match(extended_text, 'done="1"', info = "Expected resolved status in commentsExtended.xml")
})

test_that("full round-trip: extract -> modify -> inject -> extract", {
  fixture_path <- test_path("fixtures", "word-native-comments.docx")
  skip_if_not(file.exists(fixture_path), "Fixture not available")

  # Step 1: Extract from original
  original_comments <- extract_comments(fixture_path)
  skip_if(length(original_comments) == 0, "No comments in fixture")

  # Step 2: Modify - mark first comment as resolved
  first_id <- names(original_comments)[1]
  modified_comments <- original_comments
  modified_comments[[first_id]]$done <- TRUE

  # Step 3: Write to JSON and inject into a copy
  temp_docx <- tempfile(fileext = ".docx")
  temp_json <- tempfile(fileext = ".json")
  on.exit(unlink(c(temp_docx, temp_json)), add = TRUE)

  file.copy(fixture_path, temp_docx)
  write_comments_json(modified_comments, temp_json)
  inject_comments(temp_docx, temp_json)

  # Step 4: Extract again and verify modification persisted
  final_comments <- extract_comments(temp_docx)

  expect_true(
    isTRUE(final_comments[[first_id]]$done),
    info = "Expected first comment to be marked as resolved after round-trip"
  )

  # Verify threading still intact
  original_replies <- Filter(function(c) !is.null(c$parent_id), original_comments)
  final_replies <- Filter(function(c) !is.null(c$parent_id), final_comments)

  expect_equal(
    length(final_replies),
    length(original_replies),
    info = "Threading should be preserved through round-trip"
  )
})
