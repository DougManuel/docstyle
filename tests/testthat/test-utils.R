# Tests for utility functions in R/utils.R

# --- find_project_root ---

test_that("#85: find_project_root — returns QUARTO_PROJECT_DIR when set", {
  tmp <- withr::local_tempdir()
  withr::local_envvar(QUARTO_PROJECT_DIR = tmp)
  expect_equal(find_project_root(getwd()), normalizePath(tmp, mustWork = FALSE))
})

test_that("#85: find_project_root — finds .git anchor via upward walk", {
  withr::local_envvar(QUARTO_PROJECT_DIR = "")
  tmp <- withr::local_tempdir()
  # Structure: tmp/.git  +  tmp/subdir/subsubdir/
  dir.create(file.path(tmp, ".git"))
  subdir <- file.path(tmp, "subdir", "subsubdir")
  dir.create(subdir, recursive = TRUE)
  result <- find_project_root(subdir)
  expect_equal(normalizePath(result), normalizePath(tmp))
})

test_that("#85: find_project_root — finds _quarto.yml with project: section", {
  withr::local_envvar(QUARTO_PROJECT_DIR = "")
  tmp <- withr::local_tempdir()
  writeLines("project:\n  type: default\n", file.path(tmp, "_quarto.yml"))
  subdir <- file.path(tmp, "docs")
  dir.create(subdir)
  result <- find_project_root(subdir)
  expect_equal(normalizePath(result), normalizePath(tmp))
})

test_that("#85: find_project_root — falls back to start when no anchor found", {
  withr::local_envvar(QUARTO_PROJECT_DIR = "")
  # Use a temp dir with no .git or _quarto.yml parents (isolated)
  tmp <- withr::local_tempdir()
  result <- find_project_root(tmp, max_levels = 2)
  # Should return tmp itself (no anchor found within 2 levels)
  expect_true(is.character(result))
  expect_true(nzchar(result))
})

# --- %||% ---

test_that("%||% returns x when not NULL", {
  expect_equal("hello" %||% "default", "hello")
  expect_equal(0L %||% 1L, 0L)
  expect_equal(FALSE %||% TRUE, FALSE)
  expect_equal(list() %||% list(1), list())
})

test_that("%||% returns y when x is NULL", {
  expect_equal(NULL %||% "default", "default")
  expect_equal(NULL %||% 42L, 42L)
  expect_equal(NULL %||% list(1, 2), list(1, 2))
})

test_that("%||% returns y when x is NULL, not when NA or empty", {
  expect_true(is.na(NA %||% "default"))   # NA is not NULL
  expect_equal(character(0) %||% "x", character(0))  # empty is not NULL
})


# --- unescape_xml_entities ---

test_that("unescape_xml_entities replaces all four entities", {
  expect_equal(unescape_xml_entities("&quot;"), '"')
  expect_equal(unescape_xml_entities("&lt;"), "<")
  expect_equal(unescape_xml_entities("&gt;"), ">")
  expect_equal(unescape_xml_entities("&amp;"), "&")
})

test_that("unescape_xml_entities handles combined entities correctly", {
  expect_equal(unescape_xml_entities("a &amp; b &lt; c &gt; d"), "a & b < c > d")
})

test_that("unescape_xml_entities unescapes &amp; AFTER other entities (order matters)", {
  # &amp;lt; should become &lt; (not <), because &amp; is unescaped last
  expect_equal(unescape_xml_entities("&amp;lt;"), "&lt;")
})

test_that("unescape_xml_entities is idempotent on plain text", {
  expect_equal(unescape_xml_entities("hello world"), "hello world")
  expect_equal(unescape_xml_entities(""), "")
})


# --- escape_xml_text ---

test_that("escape_xml_text escapes & < > but not quotes", {
  expect_equal(escape_xml_text("&"), "&amp;")
  expect_equal(escape_xml_text("<"), "&lt;")
  expect_equal(escape_xml_text(">"), "&gt;")
  expect_equal(escape_xml_text('"'), '"')   # quotes NOT escaped
  expect_equal(escape_xml_text("'"), "'")   # single quote NOT escaped
})

test_that("escape_xml_text escapes & before < and > (no double-escape)", {
  expect_equal(escape_xml_text("a < b & c > d"), "a &lt; b &amp; c &gt; d")
})

test_that("escape_xml_text leaves plain text unchanged", {
  expect_equal(escape_xml_text("hello 123"), "hello 123")
})


# --- escape_xml_text_full ---

test_that("escape_xml_text_full escapes all five XML special characters", {
  expect_equal(escape_xml_text_full("&"), "&amp;")
  expect_equal(escape_xml_text_full("<"), "&lt;")
  expect_equal(escape_xml_text_full(">"), "&gt;")
  expect_equal(escape_xml_text_full('"'), "&quot;")
  expect_equal(escape_xml_text_full("'"), "&apos;")
})

test_that("escape_xml_text_full and escape_xml_text agree on non-quote chars", {
  input <- "a < b & c > d"
  expect_equal(escape_xml_text_full(input), escape_xml_text(input))
})


# --- normalize_typographic_dashes ---

test_that("normalize_typographic_dashes converts em dash to ---", {
  expect_equal(normalize_typographic_dashes("\u2014"), "---")
})

test_that("normalize_typographic_dashes converts en dash to --", {
  expect_equal(normalize_typographic_dashes("\u2013"), "--")
})

test_that("normalize_typographic_dashes handles both in one string", {
  expect_equal(
    normalize_typographic_dashes("A\u2014B\u2013C"),
    "A---B--C"
  )
})

test_that("normalize_typographic_dashes leaves plain text unchanged", {
  expect_equal(normalize_typographic_dashes("hello - world"), "hello - world")
  expect_equal(normalize_typographic_dashes(""), "")
})

test_that("normalize_typographic_dashes is idempotent on already-normalised text", {
  expect_equal(normalize_typographic_dashes("---"), "---")
  expect_equal(normalize_typographic_dashes("--"), "--")
})


# --- modify_docx_xml ---

test_that("modify_docx_xml applies string-returning modifier", {
  # Build a minimal valid DOCX in a temp directory
  docx_path  <- tempfile(fileext = ".docx")
  out_path   <- tempfile(fileext = ".docx")
  on.exit({ unlink(docx_path); unlink(out_path) }, add = TRUE)

  # Create minimal word/document.xml
  tmp <- tempfile()
  dir.create(file.path(tmp, "word"), recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(tmp, recursive = TRUE), add = TRUE)

  xml_content <- '<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>hello</w:t></w:r></w:p></w:body></w:document>'
  writeLines(xml_content, file.path(tmp, "word", "document.xml"))

  old_wd <- getwd()
  setwd(tmp)
  utils::zip(docx_path, files = list.files(".", recursive = TRUE, all.files = TRUE),
             flags = "-r9Xq")
  setwd(old_wd)

  # Apply a modifier that replaces "hello" with "world"
  modify_docx_xml(docx_path, out_path, function(xml) {
    gsub("hello", "world", xml, fixed = TRUE)
  })

  # Verify output exists and contains modified content
  expect_true(file.exists(out_path))
  con <- unz(out_path, "word/document.xml")
  result_xml <- paste(readLines(con, warn = FALSE), collapse = "\n")
  close(con)
  expect_true(grepl("world", result_xml, fixed = TRUE))
  expect_false(grepl("hello", result_xml, fixed = TRUE))
})

test_that("modify_docx_xml accepts list-returning modifier with $xml", {
  docx_path <- tempfile(fileext = ".docx")
  out_path  <- tempfile(fileext = ".docx")
  on.exit({ unlink(docx_path); unlink(out_path) }, add = TRUE)

  tmp <- tempfile()
  dir.create(file.path(tmp, "word"), recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(tmp, recursive = TRUE), add = TRUE)

  xml_content <- '<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p/></w:body></w:document>'
  writeLines(xml_content, file.path(tmp, "word", "document.xml"))
  old_wd <- getwd()
  setwd(tmp)
  utils::zip(docx_path, files = list.files(".", recursive = TRUE, all.files = TRUE),
             flags = "-r9Xq")
  setwd(old_wd)

  result <- modify_docx_xml(docx_path, out_path, function(xml) {
    list(xml = gsub("w:p", "w:p2", xml, fixed = TRUE), extra = "data")
  })

  expect_equal(result$extra, "data")
  expect_true(file.exists(out_path))
})

test_that("modify_docx_xml errors on invalid DOCX structure", {
  bad_docx <- tempfile(fileext = ".docx")
  on.exit(unlink(bad_docx), add = TRUE)

  # Create a zip with no word/document.xml
  tmp <- tempfile()
  dir.create(tmp, showWarnings = FALSE)
  on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
  writeLines("not a docx", file.path(tmp, "README.txt"))
  old_wd <- getwd()
  setwd(tmp)
  utils::zip(bad_docx, files = "README.txt", flags = "-r9Xq")
  setwd(old_wd)

  expect_error(
    modify_docx_xml(bad_docx, tempfile(fileext = ".docx"), identity),
    "word/document.xml not found"
  )
})

# --- XML escaping ---------------------------------------------------------

test_that("xml_escape escapes text content entities", {
  expect_equal(xml_escape("a & b"), "a &amp; b")
  expect_equal(xml_escape("<w:p>"), "&lt;w:p&gt;")
  expect_equal(xml_escape("plain"), "plain")
  # Ampersand must be escaped first (no double-escaping)
  expect_equal(xml_escape("&lt;"), "&amp;lt;")
})

test_that("xml_escape_attr escapes all five XML attribute entities", {
  expect_equal(xml_escape_attr("a & b"), "a &amp; b")
  expect_equal(xml_escape_attr("<tag>"), "&lt;tag&gt;")
  expect_equal(xml_escape_attr('say "hi"'), "say &quot;hi&quot;")
  expect_equal(xml_escape_attr("it's"), "it&apos;s")
  expect_equal(
    xml_escape_attr("<a href=\"x\" title='y'> & more"),
    "&lt;a href=&quot;x&quot; title=&apos;y&apos;&gt; &amp; more"
  )
})
