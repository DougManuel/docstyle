# Tests for sync_extension_version() — the helper that keeps each
# project's vendored _extension.yml version in sync with the installed
# docstyle package version. Without this, check_extension_drift() would
# falsely report drift on every render even immediately after a fresh
# update_extension(), because the bundled source manifest's version
# isn't tightly coupled to DESCRIPTION's Version.

test_that("sync_extension_version overwrites an existing version line", {
  td <- tempfile("sync_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  yml <- file.path(td, "_extension.yml")
  writeLines(c(
    "title: docstyle",
    "author: docstyle",
    "version: 0.1.0",
    "contributes: {}"
  ), yml)

  ok <- docstyle:::sync_extension_version(yml, "0.16.0")
  expect_true(ok)

  result <- readLines(yml)
  ver_line <- grep("^version:", result, value = TRUE)
  expect_equal(ver_line, "version: 0.16.0")
  # Preserved structure (no lines lost)
  expect_equal(length(result), 4)
  expect_match(result[1], "^title")
  expect_match(result[4], "^contributes")
})


test_that("sync_extension_version preserves comments and other content", {
  td <- tempfile("sync_comments_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  yml <- file.path(td, "_extension.yml")
  writeLines(c(
    "# An important comment",
    "title: docstyle",
    "version: 0.1.0",
    "# Another comment",
    "contributes:",
    "  formats:",
    "    docx:",
    "      reference-doc: _docstyle/reference.docx"
  ), yml)

  docstyle:::sync_extension_version(yml, "0.16.0")
  result <- readLines(yml)

  # All comments and structure intact
  expect_match(result[1], "^# An important comment")
  expect_match(result[4], "^# Another comment")
  expect_equal(grep("^version:", result, value = TRUE), "version: 0.16.0")
  expect_equal(length(result), 8)
})


test_that("sync_extension_version inserts a version line when absent", {
  td <- tempfile("sync_insert_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  yml <- file.path(td, "_extension.yml")
  writeLines(c(
    "title: docstyle",
    "author: docstyle",
    "contributes: {}"
  ), yml)

  docstyle:::sync_extension_version(yml, "0.16.0")
  result <- readLines(yml)

  expect_true(any(grepl("^version: 0\\.16\\.0", result)))
  # Inserted after the author line (last of title/author/description)
  ver_idx <- which(grepl("^version:", result))
  author_idx <- which(grepl("^author:", result))
  expect_true(ver_idx > author_idx,
              info = "version: should be inserted after author:")
})


test_that("sync_extension_version replaces only the first version line", {
  # Defensive: a multi-version-line manifest is malformed but
  # shouldn't multi-write — only the first match is replaced.
  td <- tempfile("sync_multi_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  yml <- file.path(td, "_extension.yml")
  writeLines(c(
    "title: docstyle",
    "version: 0.1.0",
    "contributes:",
    "  formats:",
    "    docx:",
    "      version: 1.0.0"  # NOT a top-level version (different indent)
  ), yml)

  docstyle:::sync_extension_version(yml, "0.16.0")
  result <- readLines(yml)

  # Top-level version updated
  expect_equal(result[2], "version: 0.16.0")
  # Indented "version:" inside the contributes/formats/docx block
  # should stay unchanged (regex requires leading-of-line match).
  expect_match(result[6], "^      version: 1\\.0\\.0")
})


test_that("sync_extension_version returns FALSE for missing file", {
  result <- docstyle:::sync_extension_version("/no/such/file.yml", "0.16.0")
  expect_false(result)
})


# ── Integration: update_extension() rewrites the version on copy ─────────────

test_that("update_extension rewrites destination _extension.yml version (#142 follow-up)", {
  # The bundled source `_extension.yml` may have a different version
  # than the installed package's DESCRIPTION (historically they
  # haven't been kept in sync). update_extension() must rewrite the
  # destination's version field so check_extension_drift() reports
  # 'match' immediately after a fresh update.
  td <- tempfile("upd_sync_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))

  # First install — creates the extension at the destination
  suppressMessages(use_docstyle(td))

  yml_path <- file.path(td, "_extensions", "docstyle", "_extension.yml")
  expect_true(file.exists(yml_path))

  ver_line <- grep("^version:", readLines(yml_path), value = TRUE)
  pkg_version <- as.character(utils::packageVersion("docstyle"))
  expect_equal(ver_line, paste0("version: ", pkg_version),
               info = "use_docstyle should rewrite version to package version")

  # Now run check_extension_drift — should report 'match'
  drift <- check_extension_drift(td)
  expect_equal(drift$status, "match",
               info = "Fresh install should not show drift")
})


test_that("update_extension on existing project also rewrites version", {
  td <- tempfile("upd_sync_existing_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))

  # Set up a project with a stale _extension.yml
  ext_dir <- file.path(td, "_extensions", "docstyle")
  dir.create(ext_dir, recursive = TRUE)
  # Copy a real extension file so update_extension knows where it is
  source_yml <- system.file("_extensions", "docstyle", "_extension.yml",
                            package = "docstyle")
  skip_if_not(nzchar(source_yml), "package extension not findable")
  file.copy(source_yml, file.path(ext_dir, "_extension.yml"))
  # Force the destination version to something stale
  docstyle:::sync_extension_version(file.path(ext_dir, "_extension.yml"),
                                     "0.0.1")

  # Run update_extension
  suppressMessages(update_extension(td, backup = FALSE))

  # Destination version now matches package
  ver_line <- grep("^version:", readLines(file.path(ext_dir, "_extension.yml")),
                   value = TRUE)
  pkg_version <- as.character(utils::packageVersion("docstyle"))
  expect_equal(ver_line, paste0("version: ", pkg_version))
})


test_that("DESCRIPTION Version matches _extensions/docstyle/_extension.yml version", {
  # Sentinel: the bundled extension manifest's version must match
  # DESCRIPTION's Version. Drifting these apart silently breaks
  # check_extension_drift() for projects that haven't run
  # update_extension() recently — see the v0.16.0 follow-up.
  desc_path <- testthat::test_path("../../DESCRIPTION")
  yml_path  <- testthat::test_path("../../_extensions/docstyle/_extension.yml")
  skip_if_not(file.exists(desc_path) && file.exists(yml_path),
              "DESCRIPTION or extension manifest not findable")

  desc_ver <- unname(read.dcf(desc_path, fields = "Version")[1, 1])
  yml_ver  <- sub("^version:[[:space:]]*", "",
                  grep("^version:", readLines(yml_path, warn = FALSE),
                       value = TRUE)[1])

  expect_equal(yml_ver, desc_ver,
    info = paste0("DESCRIPTION Version=", desc_ver,
                  " but _extension.yml version=", yml_ver,
                  ". Bump _extension.yml's `version:` field to match",
                  " DESCRIPTION's `Version:` whenever the package",
                  " version bumps."))
})
