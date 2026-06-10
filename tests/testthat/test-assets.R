test_that("asset_path finds standard assets", {
  # Ensure directories exist (created in prev step)
  dir.create("inst/extdata/popcorn/assets/logo", recursive = TRUE, showWarnings = FALSE)
  
  # Create dummy files for testing
  logo_path <- "inst/extdata/popcorn/assets/logo/popcorn_main-wordmark.png"
  writeLines("", logo_path)
  
  path <- asset_path("logo")
  expect_true(grepl("popcorn_main-wordmark.png", path))
  expect_true(file.exists(path))
  
  # Clean up dummy
  unlink(logo_path)
})
