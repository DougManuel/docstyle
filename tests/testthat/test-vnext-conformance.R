test_that("vNext conformance runner passes", {
  skip_if(Sys.which("quarto") == "", "quarto not on PATH")
  root <- normalizePath(file.path(testthat::test_path(), "..", ".."))
  res <- suppressWarnings(system2(
    "quarto",
    c("run", file.path(root, "tests", "vnext", "conformance", "run.lua")),
    stdout = TRUE, stderr = TRUE
  ))
  status <- attr(res, "status")
  if (is.null(status)) status <- 0L
  expect_identical(status, 0L, info = paste(res, collapse = "\n"))
})
