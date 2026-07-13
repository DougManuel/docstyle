locate_offline_typst_root <- function() {
  candidates <- c(
    testthat::test_path("../.."),
    normalizePath(".", mustWork = FALSE),
    system.file(package = "docstyle")
  )
  candidates <- candidates[nzchar(candidates)]
  hit <- candidates[file.exists(file.path(
    candidates,
    "_extensions", "docstyle", "_extension.yml"
  ))]
  if (length(hit) < 1L) {
    stop(
      "Docstyle source or installed package root not found",
      call. = FALSE
    )
  }
  normalizePath(hit[[1]], mustWork = TRUE)
}

offline_wordometer_hashes <- c(
  "exports.typ" =
    "83dba74bcfaa29018e5158837a418995b65ca0f061b09e673948c878d5063cd3",
  "lib.typ" =
    "79561b79f62ae043b985b723a0db4e75859fefc203590a811c671ff9fee6b4d2",
  "LICENSE" =
    "c33a5648cee72a57bdfee4b309998e04569001904d65189cd1204b1772a0fe86"
)

read_wordometer_checksum_file <- function(path) {
  if (!file.exists(path)) {
    stop("wordometer checksum manifest does not exist", call. = FALSE)
  }
  lines <- trimws(readLines(path, warn = FALSE, encoding = "UTF-8"))
  lines <- lines[nzchar(lines)]
  matches <- regexec(
    "^([0-9a-fA-F]{64})[[:space:]]+[*]?(.+)$",
    lines
  )
  fields <- regmatches(lines, matches)
  if (length(fields) < 1L || any(lengths(fields) != 3L)) {
    stop("wordometer checksum manifest is malformed", call. = FALSE)
  }
  hashes <- tolower(vapply(fields, function(x) x[[2]], character(1)))
  names(hashes) <- vapply(fields, function(x) x[[3]], character(1))
  if (anyDuplicated(names(hashes))) {
    stop("wordometer checksum filenames must be unique", call. = FALSE)
  }
  hashes
}

test_that("wordometer checksum manifest matches independent pins", {
  root <- locate_offline_typst_root()
  checksum_path <- file.path(
    root,
    "_extensions", "docstyle", "preprint", "vendor",
    "wordometer-0.1.5", "SHA256SUMS"
  )
  manifest_hashes <- read_wordometer_checksum_file(checksum_path)

  expect_setequal(names(manifest_hashes), names(offline_wordometer_hashes))
  expect_identical(
    manifest_hashes[names(offline_wordometer_hashes)],
    offline_wordometer_hashes
  )
})

test_that("Typst template imports only project-local dependencies", {
  root <- locate_offline_typst_root()
  template <- readLines(file.path(
    root,
    "_extensions", "docstyle", "preprint", "typst",
    "typst-template.typ"
  ), warn = FALSE)

  expect_false(any(grepl("@preview/", template, fixed = TRUE)))
  expect_true(any(grepl(
    "_extensions/docstyle/preprint/vendor/wordometer-0.1.5/exports.typ",
    template,
    fixed = TRUE
  )))
  expect_true(any(grepl(
    "docstyle-orcid-mark",
    template,
    fixed = TRUE
  )))
})

test_that("vendored wordometer sources match the pinned upstream files", {
  root <- locate_offline_typst_root()
  vendor <- file.path(
    root,
    "_extensions", "docstyle", "preprint", "vendor",
    "wordometer-0.1.5"
  )

  for (name in names(offline_wordometer_hashes)) {
    path <- file.path(vendor, name)
    expect_true(file.exists(path), info = name)
    expect_identical(
      digest::digest(file = path, algo = "sha256", serialize = FALSE),
      unname(offline_wordometer_hashes[[name]]),
      info = name
    )
  }
  expect_true(file.exists(file.path(vendor, "PROVENANCE.md")))
  expect_true(file.exists(file.path(vendor, "SHA256SUMS")))
})

test_that("docstyle-typst renders with a cold home and blocked proxy", {
  testthat::skip_if_not(nzchar(Sys.which("quarto")), "quarto unavailable")
  root <- locate_offline_typst_root()
  project <- tempfile("docstyle-offline-typst-")
  dir.create(file.path(project, "_extensions"), recursive = TRUE)
  on.exit(unlink(project, recursive = TRUE, force = TRUE), add = TRUE)
  expect_true(file.copy(
    file.path(root, "_extensions", "docstyle"),
    file.path(project, "_extensions"),
    recursive = TRUE
  ))

  writeLines(c(
    "project:",
    "  type: default",
    "format:",
    "  docstyle-typst:",
    "    keep-typ: true",
    "    wordcount: true"
  ), file.path(project, "_quarto.yml"))
  writeLines(c(
    "---",
    "title: \"Offline Typst fixture\"",
    "author:",
    "  - name: Local Author",
    "    orcid: 0000-0000-0000-0000",
    "abstract: A local-only render.",
    "---",
    "",
    "# Methods",
    "",
    "This document exercises local word count and ORCID rendering."
  ), file.path(project, "paper.qmd"))

  empty_home <- file.path(project, "empty-home")
  dir.create(empty_home)
  output <- withr::with_envvar(
    c(
      HOME = empty_home,
      XDG_CACHE_HOME = file.path(empty_home, "cache"),
      XDG_DATA_HOME = file.path(empty_home, "data"),
      HTTP_PROXY = "http://127.0.0.1:9",
      HTTPS_PROXY = "http://127.0.0.1:9",
      ALL_PROXY = "http://127.0.0.1:9",
      NO_PROXY = ""
    ),
    withr::with_dir(project, system2(
      "quarto",
      c("render", "paper.qmd"),
      stdout = TRUE,
      stderr = TRUE
    ))
  )
  status <- attr(output, "status")
  expect_true(
    is.null(status) || status == 0L,
    info = paste(output, collapse = "\n")
  )
  expect_true(file.exists(file.path(project, "paper.pdf")))
  typst <- readLines(file.path(project, "paper.typ"), warn = FALSE)
  expect_false(any(grepl("@preview/", typst, fixed = TRUE)))
})
