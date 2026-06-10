# Tests for update_extension() and check_project() (issue #67)

# --- Test fixtures -----------------------------------------------------------

# Create a minimal docstyle project in a temp directory
create_test_project <- function(
    with_extension = TRUE,
    with_quarto_yml = TRUE,
    with_qmd = TRUE,
    with_sidecar = TRUE,
    qmd_content = NULL,
    quarto_format = "docstyle-docx",
    field_codes_citations = list(smith2020 = list(), jones2021 = list()),
    sidecar_version = NULL
) {
  dir <- tempfile("docstyle_test_project_")
  dir.create(dir, recursive = TRUE)


  # Extension
  if (with_extension) {
    ext_dir <- file.path(dir, "_extensions", "docstyle")
    dir.create(ext_dir, recursive = TRUE)
    # Copy from installed package
    ext_source <- system.file("_extensions", "docstyle", package = "docstyle")
    if (ext_source != "" && dir.exists(ext_source)) {
      src_files <- list.files(ext_source, full.names = TRUE)
      file.copy(src_files, ext_dir, recursive = TRUE)
    } else {
      # Minimal: just create _extension.yml
      writeLines("title: docstyle\nversion: 0.1.0", file.path(ext_dir, "_extension.yml"))
    }
  }

  # _quarto.yml
  if (with_quarto_yml) {
    if (quarto_format == "docstyle-docx") {
      yml_content <- paste0(
        "project:\n  type: default\n",
        "format:\n  docstyle-docx: default\n",
        "docstyle:\n  sidecar-dir: _docstyle\n"
      )
    } else {
      yml_content <- paste0(
        "project:\n  type: default\n",
        "format:\n  ", quarto_format, ":\n    toc: true\n"
      )
    }
    writeLines(yml_content, file.path(dir, "_quarto.yml"))
  }

  # QMD file
  if (with_qmd) {
    if (is.null(qmd_content)) {
      qmd_content <- paste0(
        "---\ntitle: Test Document\n---\n\n",
        "Some text with a citation [@smith2020] and another [@jones2021].\n\n",
        "::: bibliography :::\n"
      )
    }
    writeLines(qmd_content, file.path(dir, "document.qmd"))
  }

  # Sidecar directory
  if (with_sidecar) {
    sidecar_dir <- file.path(dir, "_docstyle")
    dir.create(sidecar_dir, recursive = TRUE)

    # field-codes.json
    fc <- list(
      citations = field_codes_citations,
      docstyle_version = sidecar_version %||%
        as.character(utils::packageVersion("docstyle"))
    )
    jsonlite::write_json(fc, file.path(sidecar_dir, "field-codes.json"),
                         auto_unbox = TRUE, pretty = TRUE)
  }

  dir
}


# --- extract_qmd_yaml tests -------------------------------------------------

test_that("extract_qmd_yaml parses standard YAML header", {
  tmp <- tempfile(fileext = ".qmd")
  on.exit(unlink(tmp))
  writeLines(c("---", "title: Test", "author: Me", "---", "Body text"), tmp)

  result <- docstyle:::extract_qmd_yaml(tmp)
  expect_type(result, "list")
  expect_equal(result$title, "Test")
  expect_equal(result$author, "Me")
})

test_that("extract_qmd_yaml returns NULL for no YAML", {
  tmp <- tempfile(fileext = ".qmd")
  on.exit(unlink(tmp))
  writeLines(c("Just body text", "No YAML here"), tmp)

  result <- docstyle:::extract_qmd_yaml(tmp)
  expect_null(result)
})

test_that("extract_qmd_yaml handles ... terminator", {
  tmp <- tempfile(fileext = ".qmd")
  on.exit(unlink(tmp))
  writeLines(c("---", "title: Test", "...", "Body text"), tmp)

  result <- docstyle:::extract_qmd_yaml(tmp)
  expect_type(result, "list")
  expect_equal(result$title, "Test")
})


# --- extract_qmd_citekeys tests ---------------------------------------------

test_that("extract_qmd_citekeys finds single citations", {
  tmp <- tempfile(fileext = ".qmd")
  on.exit(unlink(tmp))
  writeLines(c("---", "title: Test", "---", "",
               "Some text [@smith2020] and more."), tmp)

  keys <- docstyle:::extract_qmd_citekeys(tmp)
  expect_equal(keys, "smith2020")
})

test_that("extract_qmd_citekeys finds grouped citations", {
  tmp <- tempfile(fileext = ".qmd")
  on.exit(unlink(tmp))
  writeLines(c("---", "title: Test", "---", "",
               "Evidence suggests [@smith2020; @jones2021] that..."), tmp)

  keys <- docstyle:::extract_qmd_citekeys(tmp)
  expect_setequal(keys, c("smith2020", "jones2021"))
})

test_that("extract_qmd_citekeys ignores YAML front matter", {
  tmp <- tempfile(fileext = ".qmd")
  on.exit(unlink(tmp))
  writeLines(c("---", "title: \"[@notacitation]\"", "---", "",
               "Real citation: [@real2020]"), tmp)

  keys <- docstyle:::extract_qmd_citekeys(tmp)
  expect_equal(keys, "real2020")
})

test_that("extract_qmd_citekeys returns empty for no citations", {
  tmp <- tempfile(fileext = ".qmd")
  on.exit(unlink(tmp))
  writeLines(c("---", "title: Test", "---", "", "No citations here."), tmp)

  keys <- docstyle:::extract_qmd_citekeys(tmp)
  expect_length(keys, 0)
})

test_that("extract_qmd_citekeys deduplicates repeated keys", {
  tmp <- tempfile(fileext = ".qmd")
  on.exit(unlink(tmp))
  writeLines(c("---", "title: Test", "---", "",
               "First use [@smith2020]. Again [@smith2020]."), tmp)

  keys <- docstyle:::extract_qmd_citekeys(tmp)
  expect_equal(keys, "smith2020")
})


# --- compare_extension_files tests ------------------------------------------

test_that("compare_extension_files detects added, updated, unchanged files", {
  src <- tempfile("src_ext_")
  dst <- tempfile("dst_ext_")
  dir.create(src)
  dir.create(dst)
  on.exit({
    unlink(src, recursive = TRUE)
    unlink(dst, recursive = TRUE)
  })

  # File present in both, identical
  writeLines("same content", file.path(src, "a.lua"))
  writeLines("same content", file.path(dst, "a.lua"))

  # File present in both, different
  writeLines("new version", file.path(src, "b.lua"))
  writeLines("old version", file.path(dst, "b.lua"))

  # File only in source (added)
  writeLines("brand new", file.path(src, "c.lua"))

  # File only in dest (extra)
  writeLines("custom", file.path(dst, "custom.lua"))

  result <- docstyle:::compare_extension_files(
    src, dst, c("a.lua", "b.lua", "c.lua")
  )

  expect_equal(result$unchanged, "a.lua")
  expect_equal(result$updated, "b.lua")
  expect_equal(result$added, "c.lua")
  expect_equal(result$extra, "custom.lua")
})


# --- update_extension tests -------------------------------------------------

test_that("update_extension copies files from package", {
  proj <- create_test_project(with_extension = FALSE)
  on.exit(unlink(proj, recursive = TRUE))

  # Ensure _extensions parent exists
  dir.create(file.path(proj, "_extensions"), recursive = TRUE)

  result <- update_extension(proj, backup = FALSE, verbose = FALSE)

  # Extension should now be installed
  expect_true(has_docstyle(proj))
  expect_true(length(result$added) > 0)
})

test_that("update_extension creates backup", {
  proj <- create_test_project(with_extension = TRUE)
  on.exit(unlink(proj, recursive = TRUE))

  # Modify a file so there's something to update
  ext_dir <- file.path(proj, "_extensions", "docstyle")
  writeLines("-- old version", file.path(ext_dir, "toc-field.lua"))

  result <- update_extension(proj, backup = TRUE, verbose = FALSE)

  backup_path <- file.path(proj, "_extensions", "docstyle.bak")
  expect_true(dir.exists(backup_path))
  # Backup should contain the old file
  expect_true(file.exists(file.path(backup_path, "toc-field.lua")))
})

test_that("update_extension skips backup when backup = FALSE", {
  proj <- create_test_project(with_extension = TRUE)
  on.exit(unlink(proj, recursive = TRUE))

  # Modify a file
  ext_dir <- file.path(proj, "_extensions", "docstyle")
  writeLines("-- old version", file.path(ext_dir, "toc-field.lua"))

  result <- update_extension(proj, backup = FALSE, verbose = FALSE)

  backup_path <- file.path(proj, "_extensions", "docstyle.bak")
  expect_false(dir.exists(backup_path))
})

test_that("update_extension reports changed files", {
  proj <- create_test_project(with_extension = TRUE)
  on.exit(unlink(proj, recursive = TRUE))

  # Modify one file
  ext_dir <- file.path(proj, "_extensions", "docstyle")
  writeLines("-- old version", file.path(ext_dir, "toc-field.lua"))

  result <- update_extension(proj, backup = FALSE, verbose = FALSE)

  expect_true("toc-field.lua" %in% result$updated)
})

test_that("update_extension invalidates reference.docx cache", {
  proj <- create_test_project(with_extension = TRUE, with_sidecar = TRUE)
  on.exit(unlink(proj, recursive = TRUE))

  # Create a hash file
  hash_file <- file.path(proj, "_docstyle", "reference.docx.hash")
  writeLines("abc123", hash_file)
  expect_true(file.exists(hash_file))

  # Modify a file to trigger update
  ext_dir <- file.path(proj, "_extensions", "docstyle")
  writeLines("-- old version", file.path(ext_dir, "toc-field.lua"))

  result <- update_extension(proj, backup = FALSE, verbose = FALSE)

  expect_false(file.exists(hash_file))
  expect_true(result$cache_invalidated)
})

test_that("update_extension reports up-to-date when nothing changed", {
  proj <- create_test_project(with_extension = TRUE)
  on.exit(unlink(proj, recursive = TRUE))

  result <- update_extension(proj, backup = FALSE, verbose = FALSE)

  expect_length(result$added, 0)
  expect_length(result$updated, 0)
  expect_true(length(result$unchanged) > 0)
})

test_that("update_extension errors for non-existent directory", {
  expect_error(
    update_extension("/nonexistent/path", verbose = FALSE),
    "does not exist"
  )
})


# --- check_project tests ----------------------------------------------------

test_that("check_project passes for well-configured project", {
  proj <- create_test_project()
  on.exit(unlink(proj, recursive = TRUE))

  result <- check_project(proj, verbose = FALSE)

  expect_true(result$valid)
  expect_length(result$issues$errors, 0)
  expect_true(result$checks$extension_installed)
  expect_true(result$checks$qmd_headers)
  expect_true(result$checks$citation_coverage)
})

test_that("check_project detects missing extension", {
  proj <- create_test_project(with_extension = FALSE)
  on.exit(unlink(proj, recursive = TRUE))

  result <- check_project(proj, verbose = FALSE)

  expect_false(result$valid)
  expect_false(result$checks$extension_installed)
  expect_true(any(grepl("not installed", result$issues$errors)))
  expect_true(any(grepl("init\\(\\)", result$issues$errors)))
})

test_that("check_project detects wrong format in _quarto.yml", {
  proj <- create_test_project(quarto_format = "docx")
  on.exit(unlink(proj, recursive = TRUE))

  result <- check_project(proj, verbose = FALSE)

  expect_false(result$checks$quarto_format)
  expect_true(any(grepl("docx.*bypass", result$issues$errors)))
})

test_that("check_project detects bibliography in QMD header", {
  proj <- create_test_project(
    qmd_content = paste0(
      "---\ntitle: Test\nbibliography: refs.bib\n---\n\n",
      "Text with [@smith2020].\n\n::: bibliography :::\n"
    )
  )
  on.exit(unlink(proj, recursive = TRUE))

  result <- check_project(proj, verbose = FALSE)

  expect_false(result$checks$qmd_headers)
  expect_true(any(grepl("bibliography", result$issues$errors)))
})

test_that("check_project detects reference-doc in QMD header", {
  proj <- create_test_project(
    qmd_content = paste0(
      "---\ntitle: Test\nreference-doc: custom.docx\n---\n\n",
      "Text with [@smith2020].\n\n::: bibliography :::\n"
    )
  )
  on.exit(unlink(proj, recursive = TRUE))

  result <- check_project(proj, verbose = FALSE)

  expect_false(result$checks$qmd_headers)
  expect_true(any(grepl("reference-doc", result$issues$errors)))
})

test_that("check_project detects missing sidecar directory", {
  proj <- create_test_project(with_sidecar = FALSE)
  on.exit(unlink(proj, recursive = TRUE))

  result <- check_project(proj, verbose = FALSE)

  expect_false(result$checks$sidecar_exists)
  expect_true(any(grepl("Sidecar directory", result$issues$warnings)))
  # Citations exist but sidecar missing: coverage should fail

  expect_false(result$checks$citation_coverage)
  expect_true(any(grepl("sidecar directory not found", result$issues$errors)))
})

test_that("check_project detects invalid sidecar JSON", {
  proj <- create_test_project()
  on.exit(unlink(proj, recursive = TRUE))

  # Corrupt the JSON
  writeLines("{ invalid json }", file.path(proj, "_docstyle", "field-codes.json"))

  result <- check_project(proj, verbose = FALSE)

  expect_false(result$checks$sidecar_valid)
  expect_true(any(grepl("Invalid JSON", result$issues$errors)))
})

test_that("check_project detects uncovered citation keys", {
  # QMD references smith2020 and jones2021, but field-codes only has smith2020
  proj <- create_test_project(
    field_codes_citations = list(smith2020 = list())
  )
  on.exit(unlink(proj, recursive = TRUE))

  result <- check_project(proj, verbose = FALSE)

  expect_false(result$checks$citation_coverage)
  expect_true(any(grepl("jones2021", result$issues$errors)))
})

test_that("check_project detects missing bibliography div", {
  proj <- create_test_project(
    qmd_content = paste0(
      "---\ntitle: Test\n---\n\n",
      "Text with [@smith2020].\n"
      # No ::: bibliography ::: div
    )
  )
  on.exit(unlink(proj, recursive = TRUE))

  result <- check_project(proj, verbose = FALSE)

  expect_false(result$checks$bibliography_div)
  expect_true(any(grepl("bibliography", result$issues$warnings)))
})

test_that("check_project warns about version drift", {
  proj <- create_test_project(sidecar_version = "0.4.4")
  on.exit(unlink(proj, recursive = TRUE))

  result <- check_project(proj, verbose = FALSE)

  # Version mismatch is a warning, not an error
  expect_false(result$checks$version_consistent)
  expect_true(any(grepl("0\\.4\\.4", result$issues$warnings)))
})

test_that("check_project handles projects with no citations", {
  proj <- create_test_project(
    qmd_content = "---\ntitle: Test\n---\n\nNo citations in this document.\n"
  )
  on.exit(unlink(proj, recursive = TRUE))

  result <- check_project(proj, verbose = FALSE)

  # Should pass — no citations means citation check is skipped
  expect_true(result$checks$citation_coverage)
})

test_that("check_project handles multiple QMD files", {
  proj <- create_test_project(
    field_codes_citations = list(smith2020 = list(), jones2021 = list(),
                                 doe2019 = list())
  )
  on.exit(unlink(proj, recursive = TRUE))

  # Create a second QMD with a different citation
  writeLines(
    paste0("---\ntitle: Second\n---\n\n",
           "More text [@doe2019].\n\n::: bibliography :::\n"),
    file.path(proj, "appendix.qmd")
  )

  result <- check_project(proj, verbose = FALSE)

  expect_true(result$valid)
  expect_true(result$checks$citation_coverage)
})

test_that("check_project errors for non-existent directory", {
  expect_error(
    check_project("/nonexistent/path", verbose = FALSE),
    "does not exist"
  )
})


# --- Additional coverage tests (review findings) ---------------------------

test_that("check_project detects incomplete extension", {
  proj <- create_test_project(with_extension = TRUE)
  on.exit(unlink(proj, recursive = TRUE))

  # Delete one required file
  file.remove(file.path(proj, "_extensions", "docstyle", "toc-field.lua"))

  result <- check_project(proj, verbose = FALSE)

  expect_false(result$checks$extension_complete)
  expect_true(any(grepl("toc-field.lua", result$issues$errors)))
})

test_that("check_project detects missing _quarto.yml", {
  proj <- create_test_project(with_quarto_yml = FALSE)
  on.exit(unlink(proj, recursive = TRUE))

  result <- check_project(proj, verbose = FALSE)

  expect_false(result$checks$quarto_format)
  expect_true(any(grepl("_quarto.yml", result$issues$errors)))
})

test_that("check_project warns when format is not docx-related", {
  proj <- create_test_project(quarto_format = "html")
  on.exit(unlink(proj, recursive = TRUE))

  result <- check_project(proj, verbose = FALSE)

  expect_false(result$checks$quarto_format)
  expect_true(any(grepl("No docx format", result$issues$warnings)))
  # Should be a warning, not an error
  expect_false(any(grepl("No docx format", result$issues$errors)))
})

test_that("check_project detects csl in QMD header", {
  proj <- create_test_project(
    qmd_content = paste0(
      "---\ntitle: Test\ncsl: apa.csl\n---\n\n",
      "Text with [@smith2020].\n\n::: bibliography :::\n"
    )
  )
  on.exit(unlink(proj, recursive = TRUE))

  result <- check_project(proj, verbose = FALSE)

  expect_false(result$checks$qmd_headers)
  expect_true(any(grepl("csl", result$issues$errors)))
})

test_that("check_project detects format: docx override in QMD (scalar)", {
  proj <- create_test_project(
    qmd_content = paste0(
      "---\ntitle: Test\nformat: docx\n---\n\n",
      "Text with [@smith2020].\n\n::: bibliography :::\n"
    )
  )
  on.exit(unlink(proj, recursive = TRUE))

  result <- check_project(proj, verbose = FALSE)

  expect_false(result$checks$qmd_headers)
  expect_true(any(grepl("format: docx", result$issues$errors)))
})

test_that("check_project detects format: docx override in QMD (named-list)", {
  proj <- create_test_project(
    qmd_content = paste0(
      "---\ntitle: Test\nformat:\n  docx:\n    toc: true\n---\n\n",
      "Text with [@smith2020].\n\n::: bibliography :::\n"
    )
  )
  on.exit(unlink(proj, recursive = TRUE))

  result <- check_project(proj, verbose = FALSE)

  expect_false(result$checks$qmd_headers)
  expect_true(any(grepl("format: docx", result$issues$errors)))
})

test_that("check_project detects citations without field-codes.json", {
  proj <- create_test_project(with_sidecar = TRUE)
  on.exit(unlink(proj, recursive = TRUE))

  # Remove field-codes.json but keep sidecar dir
  file.remove(file.path(proj, "_docstyle", "field-codes.json"))

  result <- check_project(proj, verbose = FALSE)

  expect_false(result$checks$citation_coverage)
  expect_true(any(grepl("field-codes.json not found", result$issues$errors)))
})

test_that("check_project warns when field-codes.json has no citations key", {
  proj <- create_test_project()
  on.exit(unlink(proj, recursive = TRUE))

  # Write field-codes.json without citations key
  jsonlite::write_json(
    list(docstyle_version = "0.9.0"),
    file.path(proj, "_docstyle", "field-codes.json"),
    auto_unbox = TRUE
  )

  result <- check_project(proj, verbose = FALSE)

  expect_false(result$checks$citation_coverage)
  expect_true(any(grepl("no citations entry", result$issues$warnings)))
})

test_that("check_project warns on unparseable QMD YAML", {
  proj <- create_test_project(
    qmd_content = paste0(
      "---\ntitle: [unclosed\n---\n\n",
      "Text with [@smith2020].\n\n::: bibliography :::\n"
    )
  )
  on.exit(unlink(proj, recursive = TRUE))

  result <- check_project(proj, verbose = FALSE)

  expect_true(any(grepl("could not parse YAML", result$issues$warnings)))
})

test_that("extract_qmd_citekeys finds suppress-author citations", {
  tmp <- tempfile(fileext = ".qmd")
  on.exit(unlink(tmp))
  writeLines(c("---", "title: Test", "---", "",
               "As shown by [-@smith2020], the results..."), tmp)

  keys <- docstyle:::extract_qmd_citekeys(tmp)
  expect_equal(keys, "smith2020")
})

test_that("extract_qmd_citekeys finds citations with prefix text", {
  tmp <- tempfile(fileext = ".qmd")
  on.exit(unlink(tmp))
  writeLines(c("---", "title: Test", "---", "",
               "Evidence [see @smith2020, p. 42] supports this."), tmp)

  keys <- docstyle:::extract_qmd_citekeys(tmp)
  expect_equal(keys, "smith2020")
})

test_that("extract_qmd_yaml returns NULL for empty file", {
  tmp <- tempfile(fileext = ".qmd")
  on.exit(unlink(tmp))
  writeLines(character(0), tmp)

  result <- docstyle:::extract_qmd_yaml(tmp)
  expect_null(result)
})

test_that("extract_qmd_yaml returns NULL for unclosed YAML block", {
  tmp <- tempfile(fileext = ".qmd")
  on.exit(unlink(tmp))
  writeLines(c("---", "title: Test", "author: Me"), tmp)

  result <- docstyle:::extract_qmd_yaml(tmp)
  expect_null(result)
})

test_that("extract_qmd_yaml warns on malformed YAML", {
  tmp <- tempfile(fileext = ".qmd")
  on.exit(unlink(tmp))
  writeLines(c("---", "title: [unclosed", "---"), tmp)

  expect_warning(
    result <- docstyle:::extract_qmd_yaml(tmp),
    "Failed to parse YAML"
  )
  expect_null(result)
})

test_that("compare_extension_files excludes generated files from extra", {
  src <- tempfile("src_ext_")
  dst <- tempfile("dst_ext_")
  dir.create(src)
  dir.create(dst)
  on.exit({ unlink(src, recursive = TRUE); unlink(dst, recursive = TRUE) })

  writeLines("content", file.path(dst, "reference.docx"))
  writeLines("hash", file.path(dst, "reference.docx.hash"))

  result <- docstyle:::compare_extension_files(src, dst, character())

  expect_false("reference.docx" %in% result$extra)
  expect_false("reference.docx.hash" %in% result$extra)
})

# ---------------------------------------------------------------------------
# use_preprint_profile() (#56)
# ---------------------------------------------------------------------------

test_that("use_preprint_profile writes _quarto-preprint.yml (#56)", {
  proj <- tempfile("preprint_test_")
  dir.create(proj)
  on.exit(unlink(proj, recursive = TRUE))

  # Install extension so strip-docstyle.lua is present
  use_docstyle(proj)

  result <- use_preprint_profile(proj)

  profile_path <- file.path(proj, "_quarto-preprint.yml")
  expect_true(file.exists(profile_path))
  expect_equal(normalizePath(result), normalizePath(profile_path))

  content <- readLines(profile_path)
  expect_true(any(grepl("preprint-typst", content)))
  expect_true(any(grepl("strip-docstyle.lua", content)))
})

test_that("use_preprint_profile respects theme argument (#56)", {
  proj <- tempfile("preprint_theme_")
  dir.create(proj)
  on.exit(unlink(proj, recursive = TRUE))

  use_docstyle(proj)
  use_preprint_profile(proj, theme = "jou")

  content <- paste(readLines(file.path(proj, "_quarto-preprint.yml")), collapse = "\n")
  expect_true(grepl('theme: "jou"', content, fixed = TRUE))
})

test_that("use_preprint_profile errors without extension installed (#56)", {
  proj <- tempfile("preprint_noext_")
  dir.create(proj)
  on.exit(unlink(proj, recursive = TRUE))

  expect_error(use_preprint_profile(proj), "strip-docstyle.lua not found")
})

test_that("use_preprint_profile does not overwrite without overwrite=TRUE (#56)", {
  proj <- tempfile("preprint_noover_")
  dir.create(proj)
  on.exit(unlink(proj, recursive = TRUE))

  use_docstyle(proj)
  use_preprint_profile(proj, theme = "man")
  # Write a marker so we can tell if it got overwritten
  writeLines("# sentinel", file.path(proj, "_quarto-preprint.yml"))

  expect_message(use_preprint_profile(proj), "already exists")
  expect_equal(readLines(file.path(proj, "_quarto-preprint.yml")), "# sentinel")
})

test_that("use_preprint_profile overwrites when overwrite=TRUE (#56)", {
  proj <- tempfile("preprint_over_")
  dir.create(proj)
  on.exit(unlink(proj, recursive = TRUE))

  use_docstyle(proj)
  use_preprint_profile(proj, theme = "man")
  writeLines("# sentinel", file.path(proj, "_quarto-preprint.yml"))

  use_preprint_profile(proj, overwrite = TRUE, theme = "jou")
  content <- paste(readLines(file.path(proj, "_quarto-preprint.yml")), collapse = "\n")
  expect_match(content, "jou")
  expect_false(grepl("sentinel", content))
})

test_that("use_preprint_profile errors on invalid theme (#56)", {
  proj <- tempfile("preprint_badtheme_")
  dir.create(proj)
  on.exit(unlink(proj, recursive = TRUE))

  use_docstyle(proj)
  expect_error(use_preprint_profile(proj, theme = "journal"), "Invalid theme")
})

test_that("EXTENSION_SOURCE_FILES matches inst/_extensions/docstyle/ contents", {
  ext_dir <- system.file("_extensions", "docstyle", package = "docstyle")
  skip_if(ext_dir == "", message = "Extension not found in installed package")

  actual_files <- list.files(ext_dir, recursive = FALSE)
  generated <- c("reference.docx", "reference.docx.hash")
  source_files <- setdiff(actual_files, generated)

  # Every non-generated file in the extension should be in the constant
  missing_from_constant <- setdiff(source_files, docstyle:::EXTENSION_SOURCE_FILES)
  expect_length(missing_from_constant, 0)

  # Every file in the constant should exist in the extension
  missing_from_ext <- setdiff(docstyle:::EXTENSION_SOURCE_FILES, source_files)
  expect_length(missing_from_ext, 0)
})
