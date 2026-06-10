# Workstream 1 (#136): docstyle-typst with `medrxiv: true` should render a
# medRxiv-submission-ready PDF — single column, line-numbered, 1-inch
# margins, PDF/UA-1 tagged. Each value-typed default must be opt-out
# (user-set values win), and PDF/UA-1 tagging applies to ALL
# docstyle-typst output (not flag-gated) so it must be present in the
# negative control too.
#
# Tests use `keep-typ: true` so the rendered Typst intermediate is
# preserved and we can directly assert template emission rather than
# relying on PDF-level heuristics. This catches regressions in the
# template logic itself, not just their downstream effect on the PDF.

# ── Helpers ──────────────────────────────────────────────────────────────────

`%||%` <- function(x, y) if (is.null(x)) y else x

# system2() with status check. Failures throw with stderr context so the
# test reports the actual error rather than a downstream NA-on-empty mystery.
safe_system2 <- function(cmd, args = character()) {
  result <- system2(cmd, args, stdout = TRUE, stderr = TRUE)
  status <- attr(result, "status") %||% 0L
  if (status != 0L) {
    stop(sprintf("[test] %s failed (status=%s):\n%s",
                 cmd, status, paste(result, collapse = "\n")),
         call. = FALSE)
  }
  result
}

# file.copy() with hard-fail (recurring repo concern; PR #130 review).
safe_file_copy <- function(from, to, recursive = FALSE) {
  ok <- file.copy(from, to, recursive = recursive)
  if (!all(ok)) {
    failures <- if (length(from) == length(ok)) from[!ok] else from
    stop("[test] file.copy failed: ", paste(failures, collapse = ", "),
         call. = FALSE)
  }
  invisible(TRUE)
}

# Resolve fixture and extension paths to handle both `devtools::test()`
# (cwd = tests/testthat/) and `devtools::check()` (different cwd).
locate_medrxiv_resources <- function() {
  resolve <- function(paths) {
    for (p in paths) {
      n <- normalizePath(file.path(getwd(), p), mustWork = FALSE)
      if (dir.exists(n)) return(n)
    }
    NA_character_
  }
  list(
    fixture = resolve(c("../../inst/extdata/medrxiv-fixture",
                        "inst/extdata/medrxiv-fixture")),
    ext     = resolve(c("../../_extensions/docstyle",
                        "_extensions/docstyle"))
  )
}

# Stage a render directory: copy fixture and extension; optionally overwrite
# `_quarto.yml` with `yaml_override` so each test probes a different
# configuration without contaminating the on-disk fixture.
stage_render_dir <- function(target_dir, paths, yaml_override = NULL) {
  safe_file_copy(list.files(paths$fixture, full.names = TRUE),
                 target_dir, recursive = TRUE)
  ext_dir <- file.path(target_dir, "_extensions", "docstyle")
  dir.create(ext_dir, recursive = TRUE)
  safe_file_copy(list.files(paths$ext, full.names = TRUE),
                 ext_dir, recursive = TRUE)
  if (!is.null(yaml_override)) {
    writeLines(yaml_override, file.path(target_dir, "_quarto.yml"))
  }
  invisible(target_dir)
}

# Render with quarto. Hard-fails on render failure (no silent skip).
# Returns paths to the rendered PDF and the kept Typst intermediate.
render_with_quarto <- function(qmd) {
  out <- system2("quarto", c("render", qmd),
                 stdout = TRUE, stderr = TRUE)
  status <- attr(out, "status") %||% 0L
  pdf <- sub("\\.qmd$", ".pdf", qmd)
  typ <- sub("\\.qmd$", ".typ", qmd)
  if (status != 0L || !file.exists(pdf)) {
    stop(sprintf("[test] quarto render failed (status=%s):\n%s",
                 status, paste(out, collapse = "\n")),
         call. = FALSE)
  }
  list(pdf = pdf, typ = typ, log = out)
}

# Read the kept .typ intermediate and return the args block of the
# `preprint(...)` show call — the lines between `#show: doc => preprint(`
# and the matching `)`. Direct inspection of these lines verifies what
# the Pandoc template actually emitted.
read_preprint_args <- function(typ_path) {
  if (!file.exists(typ_path)) {
    stop("[test] Typst intermediate not found: ", typ_path, call. = FALSE)
  }
  lines <- readLines(typ_path, warn = FALSE)
  start <- grep("#show: doc => preprint\\(", lines)[1]
  if (is.na(start)) {
    stop("[test] preprint() call not found in .typ", call. = FALSE)
  }
  end <- which(lines == ")" & seq_along(lines) > start)[1]
  if (is.na(end)) end <- length(lines)
  lines[start:end]
}

# Skip cascade unified across all tests (centralized so the suite degrades
# uniformly on CI containers without poppler/quarto).
skip_if_no_render_tools <- function() {
  testthat::skip_if_not(nzchar(Sys.which("quarto")), "quarto not available")
  testthat::skip_if_not(nzchar(Sys.which("pdfinfo")), "pdfinfo not available")
}


# ══ Happy path: medrxiv: true activates all four defaults ════════════════════

test_that("medrxiv: true emits cols: 1, linenumbering: \"1\", 1in margins, PDF/UA-1", {
  skip_if_no_render_tools()
  paths <- locate_medrxiv_resources()
  skip_if_not(!is.na(paths$fixture), "medrxiv-fixture not found")
  skip_if_not(!is.na(paths$ext), "_extensions/docstyle not found")

  td <- tempfile("medrxiv_happy_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  stage_render_dir(td, paths, yaml_override = c(
    "project:",
    "  type: default",
    "format:",
    "  docstyle-typst:",
    "    medrxiv: true",
    "    keep-typ: true"
  ))

  rendered <- render_with_quarto(file.path(td, "protocol.qmd"))

  # Direct check: each medRxiv default appears in the preprint() call's
  # args block in the .typ intermediate. This verifies template emission
  # directly, not its downstream PDF-level effect.
  args <- read_preprint_args(rendered$typ)
  args_text <- paste(args, collapse = "\n")
  expect_match(args_text, "linenumbering:\\s*\"1\"", info = args_text)
  expect_match(args_text, "cols:\\s*1\\b", info = args_text)
  expect_match(args_text,
               "margin:\\s*\\(top:\\s*1in,\\s*bottom:\\s*1in,\\s*left:\\s*1in,\\s*right:\\s*1in\\)",
               info = args_text)

  # PDF/UA-1: format-level default. pdfinfo confirms the structure tree
  # is present (Tagged: yes). Strict UA-1 conformance requires veraPDF;
  # we assert the necessary precondition.
  info <- safe_system2("pdfinfo", rendered$pdf)
  expect_true(any(grepl("^Tagged:\\s*yes", info, ignore.case = TRUE)),
              info = paste(info, collapse = "\n"))
  # PDF metadata embeds title and author from YAML.
  expect_true(any(grepl("medRxiv flag fixture", info, ignore.case = TRUE)))
  expect_true(any(grepl("Test Author", info)))
})


# ══ Negative control: flag absent ════════════════════════════════════════════

test_that("medrxiv flag absent: defaults inactive but PDF/UA-1 still on", {
  # PDF/UA-1 is a format-level default for ALL docstyle-typst output. A
  # regression that gated it behind the flag would surface here.
  # Conversely, no flag means none of the medRxiv-driven defaults
  # (line numbering, single column, 1in margins) appear in the .typ.
  skip_if_no_render_tools()
  paths <- locate_medrxiv_resources()
  skip_if_not(!is.na(paths$fixture), "medrxiv-fixture not found")
  skip_if_not(!is.na(paths$ext), "_extensions/docstyle not found")

  td <- tempfile("medrxiv_neg_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  stage_render_dir(td, paths, yaml_override = c(
    "project:",
    "  type: default",
    "format:",
    "  docstyle-typst:",
    "    keep-typ: true"
  ))

  rendered <- render_with_quarto(file.path(td, "protocol.qmd"))

  args <- paste(read_preprint_args(rendered$typ), collapse = "\n")
  # None of the flag-driven defaults should appear when medrxiv is absent.
  expect_false(grepl("linenumbering:\\s*\"1\"", args),
               info = "linenumbering should not be set without medrxiv flag")
  expect_false(grepl("cols:\\s*1\\b", args),
               info = "cols: 1 should not be emitted without medrxiv flag")
  expect_false(grepl("margin:\\s*\\(top:\\s*1in", args),
               info = "1-inch margins should not be emitted without medrxiv flag")

  # PDF/UA-1 still on (format-level default).
  info <- safe_system2("pdfinfo", rendered$pdf)
  expect_true(any(grepl("^Tagged:\\s*yes", info, ignore.case = TRUE)),
              info = "PDF/UA-1 should be on for all docstyle-typst output")
})


# ══ User override: explicit columns: 2 wins over flag's cols: 1 ══════════════

test_that("medrxiv: true + columns: 2 → user value wins (cols: 2 in .typ)", {
  # Central contract: $if(user-set)$ ... $elseif(medrxiv)$ means the
  # user's explicit value wins. Direct .typ inspection: we expect
  # cols: 2 (not cols: 1) when both medrxiv and columns are set.
  # A regex flip from $elseif$ to $else$ in typst-show.typ would fail
  # this test.
  #
  # Note: value-typed keys (columns, margin) work via the `$if(user-set)$`
  # path directly. Boolean keys (line-number) need a Lua sentinel because
  # Pandoc templates cannot distinguish "unset" from "explicit false";
  # see the line-number: false test below (#140).
  skip_if_no_render_tools()
  paths <- locate_medrxiv_resources()
  skip_if_not(!is.na(paths$fixture), "medrxiv-fixture not found")
  skip_if_not(!is.na(paths$ext), "_extensions/docstyle not found")

  td <- tempfile("medrxiv_override_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  stage_render_dir(td, paths, yaml_override = c(
    "project:",
    "  type: default",
    "format:",
    "  docstyle-typst:",
    "    medrxiv: true",
    "    columns: 2",
    "    keep-typ: true"
  ))

  rendered <- render_with_quarto(file.path(td, "protocol.qmd"))
  args <- paste(read_preprint_args(rendered$typ), collapse = "\n")

  expect_match(args, "cols:\\s*2\\b",
               info = "User columns: 2 should win over medrxiv default")
  expect_false(grepl("cols:\\s*1\\b", args),
               info = "cols: 1 should not appear when user sets columns: 2")
})


# ══ User override: explicit margin wins over flag's 1in default ══════════════

test_that("medrxiv: true + explicit margin → user margin wins", {
  skip_if_no_render_tools()
  paths <- locate_medrxiv_resources()
  skip_if_not(!is.na(paths$fixture), "medrxiv-fixture not found")
  skip_if_not(!is.na(paths$ext), "_extensions/docstyle not found")

  td <- tempfile("medrxiv_margin_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  stage_render_dir(td, paths, yaml_override = c(
    "project:",
    "  type: default",
    "format:",
    "  docstyle-typst:",
    "    medrxiv: true",
    "    margin:",
    "      top: 0.5in",
    "      bottom: 0.5in",
    "      left: 0.5in",
    "      right: 0.5in",
    "    keep-typ: true"
  ))

  rendered <- render_with_quarto(file.path(td, "protocol.qmd"))
  args <- paste(read_preprint_args(rendered$typ), collapse = "\n")

  expect_match(args, "margin:\\s*\\([^)]*0\\.5in",
               info = "User 0.5in margin should win over medrxiv 1in default")
  expect_false(grepl("margin:\\s*\\(top:\\s*1in", args),
               info = "medrxiv 1in margin should not appear when user sets margin")
})


# ══ Explicit medrxiv: false suppresses flag's defaults ═══════════════════════

test_that("medrxiv: false explicit setting suppresses the flag's defaults", {
  # Pandoc's $if(medrxiv)$ is truthy for non-empty values. Explicit
  # `medrxiv: false` (boolean) must evaluate as falsy and NOT activate
  # the medRxiv defaults.
  skip_if_no_render_tools()
  paths <- locate_medrxiv_resources()
  skip_if_not(!is.na(paths$fixture), "medrxiv-fixture not found")
  skip_if_not(!is.na(paths$ext), "_extensions/docstyle not found")

  td <- tempfile("medrxiv_false_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  stage_render_dir(td, paths, yaml_override = c(
    "project:",
    "  type: default",
    "format:",
    "  docstyle-typst:",
    "    medrxiv: false",
    "    keep-typ: true"
  ))

  rendered <- render_with_quarto(file.path(td, "protocol.qmd"))
  args <- paste(read_preprint_args(rendered$typ), collapse = "\n")

  expect_false(grepl("linenumbering:\\s*\"1\"", args),
               info = "medrxiv: false should not activate line numbering")
  expect_false(grepl("cols:\\s*1\\b", args),
               info = "medrxiv: false should not emit cols: 1")
  expect_false(grepl("margin:\\s*\\(top:\\s*1in", args),
               info = "medrxiv: false should not emit 1in margins")
})


# ══ Boolean override: explicit line-number: false suppresses flag default (#140)

test_that("medrxiv: true + line-number: false → no line numbering (#140)", {
  # Pandoc's $if(x)$ cannot distinguish "x unset" from "x: false" in
  # template logic, so the naive `$if(line-number)$"1"$elseif(medrxiv)$`
  # ladder ignores an explicit `line-number: false` and falls through to
  # the medRxiv default. Fix: a Lua pre-pass sets a sentinel
  # `line-number-explicit-false: true` when the user typed an explicit
  # boolean false, and the template consults that sentinel before the
  # medrxiv branch. This test asserts the user's explicit opt-out wins.
  skip_if_no_render_tools()
  paths <- locate_medrxiv_resources()
  skip_if_not(!is.na(paths$fixture), "medrxiv-fixture not found")
  skip_if_not(!is.na(paths$ext), "_extensions/docstyle not found")

  td <- tempfile("medrxiv_lineoff_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  stage_render_dir(td, paths, yaml_override = c(
    "project:",
    "  type: default",
    "format:",
    "  docstyle-typst:",
    "    medrxiv: true",
    "    line-number: false",
    "    keep-typ: true"
  ))

  rendered <- render_with_quarto(file.path(td, "protocol.qmd"))
  args <- paste(read_preprint_args(rendered$typ), collapse = "\n")

  expect_false(grepl("linenumbering:\\s*\"1\"", args),
               info = paste0("User line-number: false should win over ",
                             "medrxiv default; .typ args:\n", args))
  expect_match(args, "linenumbering:\\s*none",
               info = "linenumbering should be `none` when user opts out")
  # Other medrxiv defaults still apply — only line-number is overridden.
  expect_match(args, "cols:\\s*1\\b",
               info = "cols: 1 should still apply (medrxiv default)")
})


# ══ Boolean override: explicit line-number: true survives the fix (#140 mirror)

test_that("medrxiv: true + line-number: true → line numbering stays on (#140)", {
  # Mirror of the #140 fix. The fix prepended a
  # `$if(line-number-explicit-false)$none` branch to the linenumbering
  # ladder (typst-show.typ). This test guards the SYMMETRIC case: an
  # explicit `line-number: true` must still produce line numbers and must
  # NOT be swallowed by the new first branch. The sentinel filter only
  # fires on explicit `false` (AFFECTED_BOOLEAN_KEYS + is_explicit_false),
  # so `true` should fall through to `$elseif(line-number)$"1"`. Without
  # this test, a future widening of the sentinel (e.g. emitting a key for
  # ANY explicit boolean) or a regex typo could break explicit-true with
  # nothing to catch it.
  skip_if_no_render_tools()
  paths <- locate_medrxiv_resources()
  skip_if_not(!is.na(paths$fixture), "medrxiv-fixture not found")
  skip_if_not(!is.na(paths$ext), "_extensions/docstyle not found")

  td <- tempfile("medrxiv_lineon_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  stage_render_dir(td, paths, yaml_override = c(
    "project:",
    "  type: default",
    "format:",
    "  docstyle-typst:",
    "    medrxiv: true",
    "    line-number: true",
    "    keep-typ: true"
  ))

  rendered <- render_with_quarto(file.path(td, "protocol.qmd"))
  args <- paste(read_preprint_args(rendered$typ), collapse = "\n")

  expect_match(args, "linenumbering:\\s*\"1\"",
               info = paste0("Explicit line-number: true must keep line ",
                             "numbering on; .typ args:\n", args))
  expect_false(grepl("linenumbering:\\s*none", args),
               info = "linenumbering should not be `none` when line-number: true")
})


# ══ Affiliation numbered superscripts (#144) ═════════════════════════════════

test_that("multi-author affiliations render as numeric superscripts in PDF (#144)", {
  # Author block must show 1,2,3-style superscripts on names AND on the
  # affiliation list at the bottom — NOT the YAML id strings. The bug
  # showed `^ohri,uottawa^` in pdftotext output instead of `^1,2^`.
  skip_if_no_render_tools()
  testthat::skip_if_not(nzchar(Sys.which("pdftotext")), "pdftotext not available")
  paths <- locate_medrxiv_resources()
  skip_if_not(!is.na(paths$fixture), "medrxiv-fixture not found")
  skip_if_not(!is.na(paths$ext), "_extensions/docstyle not found")

  td <- tempfile("medrxiv_aff_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  # Stage just the extension; write a custom QMD with multiple authors
  # so the numbering path is exercised (the fixture has a single author
  # which doesn't trigger the affiliation superscript code at all).
  ext_dir <- file.path(td, "_extensions", "docstyle")
  dir.create(ext_dir, recursive = TRUE)
  ok <- file.copy(list.files(paths$ext, full.names = TRUE),
                  ext_dir, recursive = TRUE)
  if (!all(ok)) skip("Could not stage extension")

  writeLines(c(
    "---",
    "title: Numbered affiliations test",
    "authors:",
    "  - name: { given: First, family: Author }",
    "    affiliations:",
    "      - ref: aff_a",
    "      - ref: aff_b",
    "  - name: { given: Second, family: Author }",
    "    affiliations:",
    "      - ref: aff_a",
    "  - name: { given: Third, family: Author }",
    "    affiliations:",
    "      - ref: aff_b",
    "      - ref: aff_c",
    "affiliations:",
    "  - id: aff_a",
    "    name: Institution Alpha",
    "  - id: aff_b",
    "    name: Institution Beta",
    "  - id: aff_c",
    "    name: Institution Gamma",
    "format:",
    "  docstyle-typst:",
    "    keep-typ: true",
    "---",
    "Body."
  ), file.path(td, "protocol.qmd"))

  out <- system2("quarto", c("render", file.path(td, "protocol.qmd")),
                 stdout = TRUE, stderr = TRUE)
  status <- attr(out, "status")
  status <- if (is.null(status)) 0L else status
  pdf <- file.path(td, "protocol.pdf")
  testthat::expect_equal(status, 0L,
    info = paste("Render failed:", paste(out, collapse = "\n")))
  testthat::expect_true(file.exists(pdf))

  body <- paste(suppressWarnings(system2("pdftotext", c(pdf, "-"),
                                          stdout = TRUE)),
                collapse = "\n")

  # Numbered superscripts on author names: First Author1,2; Second
  # Author1; Third Author2,3. pdftotext flattens superscripts inline.
  expect_match(body, "First Author1,2",
               info = "First author should show numeric superscripts 1,2")
  expect_match(body, "Second Author1",
               info = "Second author should show numeric superscript 1")
  expect_match(body, "Third Author2,3",
               info = "Third author should show numeric superscripts 2,3")

  # Affiliation list at the bottom must use the same numeric ordering.
  # Each line begins with its number followed by the institution name.
  expect_match(body, "1Institution Alpha",
               info = "Affiliation list line 1 should start with '1'")
  expect_match(body, "2Institution Beta",
               info = "Affiliation list line 2 should start with '2'")
  expect_match(body, "3Institution Gamma",
               info = "Affiliation list line 3 should start with '3'")

  # The YAML id strings should NOT appear as superscripts. (Substring
  # presence elsewhere is harmless; the failure mode was 'aff_a,aff_b'
  # immediately after the author name.)
  expect_false(grepl("First Authoraff_a", body),
               info = "YAML id strings should not appear as superscripts")
})


# ══ Filter unit test: sentinel contract via bare pandoc (#140, no poppler) ════
#
# The render-based tests above all gate on quarto + pdfinfo, so on a
# tool-less CI container the ENTIRE #140 surface skips and the fix could
# regress silently. This test drives the REAL typst-bool-overrides.lua
# filter through bare `pandoc -t typst` with a one-line probe template,
# needing only pandoc (bundled with quarto, often present standalone).
#
# It pins three things the render tests cover only transitively:
#   1. is_explicit_false fires on explicit false, not on true/unset.
#   2. The `.t == "MetaBool"` branch is LOAD-BEARING under bare pandoc.
#      (Bare pandoc represents `line-number: false` as a MetaBool table,
#      NOT a bare Lua boolean — verified empirically, pandoc 3.1.2. The
#      Quarto pipeline normalizes it to a bare boolean instead, so the
#      two is_explicit_false branches are each live on a different stack.
#      A future "simplification" that drops either branch breaks one
#      stack; this test guards the MetaBool one.)
#   3. The FORMAT guard suppresses the sentinel for non-typst writers.

# Run the real filter over a tiny YAML doc via `pandoc -t <writer>` with a
# probe template that prints SENTINEL=YES when line-number-explicit-false
# is set, NO otherwise. Returns the trimmed probe output ("YES"/"NO").
probe_sentinel <- function(filter_path, yaml_line, writer = "typst") {
  td <- tempfile("bool_unit_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  tmpl <- file.path(td, "probe.txt")
  writeLines("SENTINEL=$if(line-number-explicit-false)$YES$else$NO$endif$",
             tmpl)
  doc <- file.path(td, "doc.md")
  writeLines(c("---", yaml_line, "---", "body"), doc)
  out <- system2("pandoc",
                 c("-f", "markdown", "-t", writer,
                   paste0("--lua-filter=", filter_path),
                   paste0("--template=", tmpl), doc),
                 stdout = TRUE, stderr = TRUE)
  status <- attr(out, "status") %||% 0L
  if (status != 0L) {
    stop(sprintf("[test] pandoc probe failed (status=%s):\n%s",
                 status, paste(out, collapse = "\n")), call. = FALSE)
  }
  trimws(sub("^SENTINEL=", "", grep("^SENTINEL=", out, value = TRUE)[1]))
}

test_that("typst-bool-overrides.lua emits sentinel only for explicit false (#140)", {
  testthat::skip_if_not(nzchar(Sys.which("pandoc")), "pandoc not available")
  paths <- locate_medrxiv_resources()
  skip_if_not(!is.na(paths$ext), "_extensions/docstyle not found")
  filter <- file.path(paths$ext, "typst-bool-overrides.lua")
  skip_if_not(file.exists(filter), "typst-bool-overrides.lua not found")

  # Core contract under the typst writer (filter active).
  expect_equal(probe_sentinel(filter, "line-number: false"), "YES",
               info = "explicit false must set the sentinel (the #140 fix)")
  expect_equal(probe_sentinel(filter, "line-number: true"), "NO",
               info = "explicit true must NOT set the sentinel")
  expect_equal(probe_sentinel(filter, "title: x"), "NO",
               info = "unset line-number must NOT set the sentinel")

  # FORMAT guard: under a non-typst writer the filter is inert, so the
  # sentinel never appears even for explicit false. Guards against the
  # key leaking into docx/jats metadata.
  expect_equal(probe_sentinel(filter, "line-number: false",
                              writer = "markdown"), "NO",
               info = "FORMAT guard must suppress sentinel for non-typst")
})
