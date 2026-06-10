test_that("parse_keyword resolves correctly", {
  config <- list(
    assets = list(
      logo = list(primary = "path/to/logo.png"),
      flat_icon = "path/to/icon.png"
    )
  )
  metadata <- list(title = "My Report", date = "2023-01-01")
  
  # 1. Asset Lookup
  # Nested with dash
  expect_equal(parse_keyword("asset:logo-primary", config, metadata), "path/to/logo.png")
  # Nested with dot
  expect_equal(parse_keyword("asset:logo.primary", config, metadata), "path/to/logo.png")
  # Flat
  expect_equal(parse_keyword("asset:flat_icon", config, metadata), "path/to/icon.png")
  # Missing
  expect_warning(parse_keyword("asset:missing", config, metadata))
  
  # 2. Metadata Lookup
  expect_equal(parse_keyword("metadata:title", config, metadata), "My Report")
  expect_null(parse_keyword("metadata:author", config, metadata)) # Missing
  
  # 3. Field Codes
  res <- parse_keyword("field:page_number", config, metadata)
  expect_equal(res$type, "field")
  expect_equal(res$code, "PAGE")
  
  # 4. Plain String
  expect_equal(parse_keyword("Plain Text", config, metadata), "Plain Text")
})
