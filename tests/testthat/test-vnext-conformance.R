# This bridge only fails ITS OWN test_that() block on a runner failure;
# whether that failure actually stops the R process depends on how the
# surrounding suite is invoked. Run the full suite with
# devtools::test(stop_on_failure = TRUE) -- the default stop_on_failure =
# FALSE lets `Rscript -e 'devtools::test()'` exit 0 even when this bridge
# (or any other test) fails, which would silently pass a broken runner in
# CI or a pre-commit check.
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
