test_that("read_bib_as_csl converts bibtex correctly", {
  # Skip if pandoc not available
  if (Sys.which("pandoc") == "") skip("Pandoc not found")
  
  bib_path <- "test_refs.bib"
  if (!file.exists(bib_path)) bib_path <- "tests/testthat/test_refs.bib" # Fallback for dev mode
  
  items <- read_bib_as_csl(bib_path)
  
  expect_type(items, "list")
  expect_equal(length(items), 2)
  
  # Check content
  # Note: CSL-JSON structure from Pandoc
  item1 <- Find(function(x) x$id == "smith2023", items)
  expect_false(is.null(item1))
  # Pandoc/CSL often sentence-cases titles
  expect_true(tolower(item1$title) == "a study of everything")
  expect_equal(item1$DOI, "10.1000/xyz123")
  
  # Check date (Pandoc usually outputs date-parts)
  # But structure depends on Pandoc version.
  # Generally: issued: { date-parts: [[2023]] }
  expect_equal(item1$issued$`date-parts`[[1]][[1]], 2023)
})
