# Tests for extended comment support (P2)
# Tests comment threading, resolved status, and people.xml generation

test_that("build_comments_extended_xml generates valid XML", {
  comments <- list(
    "1" = list(
      id = "1",
      author = "Sarah Beach",
      date = "2026-01-08T10:49:00Z",
      content = "Parent comment",
      para_id = "4A3B2C1D",
      parent_id = NULL,
      done = FALSE
    ),
    "2" = list(
      id = "2",
      author = "Doug Manuel",
      date = "2026-01-09T14:22:00Z",
      content = "Reply comment",
      para_id = "5E6F7A8B",
      parent_id = "1",
      done = FALSE
    ),
    "3" = list(
      id = "3",
      author = "Reviewer",
      date = "2026-01-10T09:00:00Z",
      content = "Resolved comment",
      para_id = "A1B2C3D4",
      parent_id = NULL,
      done = TRUE
    )
  )

  para_ids <- list(
    "1" = "4A3B2C1D",
    "2" = "5E6F7A8B",
    "3" = "A1B2C3D4"
  )

  xml <- build_comments_extended_xml(comments, para_ids)

  # Check XML declaration
  expect_match(xml, '<\\?xml version="1\\.0"')

  # Check namespace
  expect_match(xml, "w15:commentsEx")
  expect_match(xml, "http://schemas.microsoft.com/office/word/2012/wordml")

  # Check para_id attributes
  expect_match(xml, 'w15:paraId="4A3B2C1D"')
  expect_match(xml, 'w15:paraId="5E6F7A8B"')

  # Check threading - reply should have paraIdParent
  expect_match(xml, 'w15:paraIdParent="4A3B2C1D"')

  # Check done status
  expect_match(xml, 'w15:done="1"')  # Resolved comment
})

test_that("build_people_xml generates valid author metadata", {
  comments <- list(
    "1" = list(author = "Sarah Beach"),
    "2" = list(author = "Doug Manuel"),
    "3" = list(author = "Sarah Beach")  # Duplicate author
  )

  xml <- build_people_xml(comments)

  # Check XML structure
  expect_match(xml, '<\\?xml version="1\\.0"')
  expect_match(xml, "w15:people")

  # Check authors are present (using w15 namespace)
  expect_match(xml, 'w15:author="Sarah Beach"')
  expect_match(xml, 'w15:author="Doug Manuel"')

  # Authors should be deduplicated (only 2 unique)
  sarah_count <- length(gregexpr('w15:author="Sarah Beach"', xml)[[1]])
  expect_equal(sarah_count, 1)
})

test_that("generate_para_id creates valid hex IDs", {
  id1 <- generate_para_id()
  id2 <- generate_para_id()

  # Should be 8 hex characters
  expect_match(id1, "^[0-9A-F]{8}$")
  expect_match(id2, "^[0-9A-F]{8}$")

  # Should be unique
  expect_false(id1 == id2)
})

test_that("build_comments_xml returns para_ids mapping", {
  comments <- list(
    "1" = list(
      id = "1",
      author = "Test Author",
      initials = "TA",
      date = "2026-01-01T00:00:00Z",
      content = "Test comment"
    )
  )

  result <- build_comments_xml(comments)

  # Should return list with xml and para_ids
  expect_type(result, "list")
  expect_named(result, c("xml", "para_ids"))

  # para_ids should map comment ID to generated para_id
  expect_true("1" %in% names(result$para_ids))
  expect_match(result$para_ids[["1"]], "^[0-9A-F]{8}$")
})

test_that("comments with parent_id use existing para_id for threading", {
  comments <- list(
    "1" = list(
      id = "1",
      author = "Author",
      date = "2026-01-01T00:00:00Z",
      content = "Parent",
      para_id = "EXISTINGID"  # Pre-existing from harvest
    ),
    "2" = list(
      id = "2",
      author = "Author",
      date = "2026-01-02T00:00:00Z",
      content = "Reply",
      parent_id = "1"
    )
  )

  result <- build_comments_xml(comments)

  # Parent should use existing para_id
  expect_equal(result$para_ids[["1"]], "EXISTINGID")

  # Reply should get new para_id
  expect_match(result$para_ids[["2"]], "^[0-9A-F]{8}$")
})
