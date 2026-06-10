test_that("read_quarto_config parses yaml", {
  # Create a dummy _quarto.yml in temp dir
  tmp_dir <- tempdir()
  yaml_content <- "
project:
  title: 'Test Project'
docstyle:
  page_layout:
    margins:
      top: '1in'
"
  writeLines(yaml_content, file.path(tmp_dir, "_quarto.yml"))
  
  config <- read_quarto_config(tmp_dir)
  expect_type(config, "list")
  expect_equal(config$project$title, "Test Project")
  expect_equal(config$docstyle$page_layout$margins$top, "1in")
})

test_that("get_docstyle_config extracts block", {
  config <- list(project = list(), docstyle = list(assets = "logo"))
  ds_config <- get_docstyle_config(config)
  expect_equal(ds_config$assets, "logo")
})
