# #134: JATS XML output for docstyle. The format is provided by Quarto/
# Pandoc; docstyle's contribution is jats-fixups.lua, which:
#   1. Converts bold-labelled abstract paragraphs into proper <sec>
#      blocks (otherwise PMC/scite can't parse the structure).
#   2. Rebuilds CRediT role MetaMaps so non-canonical role strings
#      ("writing - original draft" with hyphen) get the full URI
#      enrichment (vocab-identifier, vocab-term-identifier).
#
# These tests render the fixture and parse the emitted XML to assert
# both transformations are applied. They also verify that other
# already-correct JATS features (multi-affiliation cross-refs,
# <element-citation>, table semantics) survive the filter unchanged.

# ── Helpers ──────────────────────────────────────────────────────────────────

skip_if_no_jats_tools <- function() {
  testthat::skip_if_not(nzchar(Sys.which("quarto")), "quarto not available")
  testthat::skip_if_not_installed("xml2")
}

# Locate the fixture and the docstyle extension. Mirrors the resolver
# from test-medrxiv-flag.R so the suite degrades uniformly.
locate_jats_resources <- function() {
  resolve <- function(paths) {
    for (p in paths) {
      n <- normalizePath(file.path(getwd(), p), mustWork = FALSE)
      if (dir.exists(n)) return(n)
    }
    NA_character_
  }
  list(
    fixture = resolve(c("../../inst/extdata/jats-fixture",
                        "inst/extdata/jats-fixture")),
    ext     = resolve(c("../../_extensions/docstyle",
                        "_extensions/docstyle"))
  )
}

stage_jats_render <- function(target_dir, paths) {
  fixture_files <- list.files(paths$fixture, full.names = TRUE)
  ok <- file.copy(fixture_files, target_dir, recursive = TRUE)
  if (!all(ok)) {
    failed <- fixture_files[!ok]
    stop("[test] file.copy failed for fixture file(s): ",
         paste(failed, collapse = ", "), call. = FALSE)
  }
  ext_dir <- file.path(target_dir, "_extensions", "docstyle")
  dir.create(ext_dir, recursive = TRUE)
  ext_files <- list.files(paths$ext, full.names = TRUE)
  ok <- file.copy(ext_files, ext_dir, recursive = TRUE)
  if (!all(ok)) {
    failed <- ext_files[!ok]
    stop("[test] file.copy failed for extension file(s): ",
         paste(failed, collapse = ", "), call. = FALSE)
  }
}

render_jats <- function(qmd) {
  out <- system2("quarto", c("render", qmd), stdout = TRUE, stderr = TRUE)
  status <- attr(out, "status")
  status <- if (is.null(status)) 0L else status
  xml <- sub("\\.qmd$", ".xml", qmd)
  if (status != 0L || !file.exists(xml)) {
    # Print full output first; stop() truncates messages at
    # getOption("warning.length") (default 1000 chars) which can hide
    # long Pandoc Lua tracebacks.
    message(paste(out, collapse = "\n"))
    stop(sprintf("[test] quarto render failed (status=%s); see message above",
                 status), call. = FALSE)
  }
  # JATS DOCTYPE references the JATS DTD via PUBLIC declaration. Use
  # NONET to disable network fetches of the DTD (offline CI safety) and
  # NOENT to substitute entities. NOENT alone enables DTD/entity
  # processing — it does NOT block network — and was a misnamed option
  # in earlier revisions of this helper.
  xml2::read_xml(xml, options = c("NONET", "NOENT"))
}


# ── Hard assertion: fixture must ship ────────────────────────────────────────

test_that("jats-fixture and docstyle extension ship with the package", {
  fixture <- system.file("extdata", "jats-fixture", package = "docstyle")
  expect_true(nzchar(fixture))
  expect_true(dir.exists(fixture))
  for (f in c("protocol.qmd", "_quarto.yml", "refs.bib")) {
    expect_true(file.exists(file.path(fixture, f)),
                info = paste("Missing fixture file:", f))
  }
  ext <- system.file("_extensions", "docstyle", "jats-fixups.lua",
                     package = "docstyle")
  expect_true(nzchar(ext))
  expect_true(file.exists(ext),
              info = "jats-fixups.lua not installed in extension")
})


# ── Render smoke test ────────────────────────────────────────────────────────

test_that("docstyle-jats renders the fixture to a JATS XML document", {
  skip_if_no_jats_tools()
  paths <- locate_jats_resources()
  skip_if_not(!is.na(paths$fixture), "jats-fixture not found")
  skip_if_not(!is.na(paths$ext), "docstyle extension not found")

  td <- tempfile("jats_render_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  stage_jats_render(td, paths)

  xml <- render_jats(file.path(td, "protocol.qmd"))
  ns <- c(jats = "")
  expect_equal(xml2::xml_name(xml), "article")
  expect_equal(xml2::xml_attr(xml, "dtd-version"), "1.2")
})


# ── Structured abstract ──────────────────────────────────────────────────────

test_that("bold-labelled abstract paragraphs become nested <sec> blocks", {
  skip_if_no_jats_tools()
  paths <- locate_jats_resources()
  skip_if_not(!is.na(paths$fixture), "jats-fixture not found")
  skip_if_not(!is.na(paths$ext), "docstyle extension not found")

  td <- tempfile("jats_abstract_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  stage_jats_render(td, paths)

  xml <- render_jats(file.path(td, "protocol.qmd"))
  abstract_secs <- xml2::xml_find_all(xml, ".//abstract/sec")
  expect_length(abstract_secs, 4)

  titles <- xml2::xml_text(xml2::xml_find_all(abstract_secs, "./title"))
  expect_equal(titles,
               c("Background", "Methods", "Findings", "Conclusions"))

  # Each <sec> contains a <p> sibling of <title> — the section body.
  for (sec in abstract_secs) {
    p <- xml2::xml_find_first(sec, "./p")
    expect_false(inherits(p, "xml_missing"),
                 info = "Each abstract <sec> must contain a <p> body")
    expect_true(nchar(xml2::xml_text(p)) > 0)
  }
})


# ── CRediT canonicalization ──────────────────────────────────────────────────

test_that("abstract restructuring is a no-op when no labelled paragraphs", {
  # Plain abstract with no `**Label:**` prefixes should pass through
  # unchanged — Pandoc emits the abstract as flat <p> paragraphs and
  # the filter must not introduce <sec> blocks.
  skip_if_no_jats_tools()
  paths <- locate_jats_resources()
  skip_if_not(!is.na(paths$fixture), "jats-fixture not found")
  skip_if_not(!is.na(paths$ext), "docstyle extension not found")

  td <- tempfile("jats_abs_unlabelled_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  stage_jats_render(td, paths)

  writeLines(c(
    "---",
    "title: Plain abstract",
    "abstract: |",
    "  This is a single-paragraph abstract with no labelled sections.",
    "  It should remain a flat <p> in the rendered JATS.",
    "format:",
    "  docstyle-jats: default",
    "---",
    "Body."
  ), file.path(td, "protocol.qmd"))

  xml <- render_jats(file.path(td, "protocol.qmd"))
  expect_length(xml2::xml_find_all(xml, ".//abstract/sec"), 0)
  expect_true(length(xml2::xml_find_all(xml, ".//abstract/p")) >= 1)
})


test_that("abstract over-match guard: bold-emphasis prose is not promoted to <sec>", {
  # An abstract that opens "**emphasis:** the introduction begins ..."
  # should NOT be reinterpreted as a section labelled "emphasis". The
  # MAX_LABEL_WORDS guard rejects bold prefixes longer than 4 words;
  # this test exercises a 1-word bold prefix that's NOT a section
  # label by context (it's followed by lowercase prose, not a section
  # body). Without the guard, the filter would over-match.
  skip_if_no_jats_tools()
  paths <- locate_jats_resources()
  skip_if_not(!is.na(paths$fixture), "jats-fixture not found")
  skip_if_not(!is.na(paths$ext), "docstyle extension not found")

  td <- tempfile("jats_abs_overmatch_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  stage_jats_render(td, paths)

  # A 5-word bolded prefix exceeds MAX_LABEL_WORDS — must NOT be
  # treated as a section heading. (Single-word bold-colon is harder
  # to disambiguate from a real section; the guard accepts it. This
  # documents the trade-off.)
  writeLines(c(
    "---",
    "title: Bold-prose abstract",
    "abstract: |",
    "  **A long emphatic phrase here:** this is body prose that",
    "  begins with a bold lead-in but is not a labelled section.",
    "format:",
    "  docstyle-jats: default",
    "---",
    "Body."
  ), file.path(td, "protocol.qmd"))

  xml <- render_jats(file.path(td, "protocol.qmd"))
  # The 5-word bold prefix should not be promoted to a section.
  expect_length(xml2::xml_find_all(xml, ".//abstract/sec"), 0)
})


test_that("mixed abstract: labelled and unlabelled paragraphs both preserved", {
  skip_if_no_jats_tools()
  paths <- locate_jats_resources()
  skip_if_not(!is.na(paths$fixture), "jats-fixture not found")
  skip_if_not(!is.na(paths$ext), "docstyle extension not found")

  td <- tempfile("jats_abs_mixed_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  stage_jats_render(td, paths)

  writeLines(c(
    "---",
    "title: Mixed abstract",
    "abstract: |",
    "  An opening sentence with no label.",
    "",
    "  **Methods:** The methodology is described.",
    "",
    "  A trailing sentence with no label.",
    "format:",
    "  docstyle-jats: default",
    "---",
    "Body."
  ), file.path(td, "protocol.qmd"))

  xml <- render_jats(file.path(td, "protocol.qmd"))
  # One <sec> for "Methods" — the labelled paragraph promotes to a
  # section. Pandoc's JATS writer is section-spanning: any content
  # following a section heading nests inside that section until the
  # next section begins. So the trailing unlabelled paragraph ends up
  # as a child of <sec>, NOT a direct child of <abstract>. The opening
  # unlabelled paragraph (before the section starts) IS a direct
  # <abstract> child. Both content paragraphs survive — none lost.
  secs <- xml2::xml_find_all(xml, ".//abstract/sec")
  expect_length(secs, 1)
  expect_equal(xml2::xml_text(xml2::xml_find_first(secs[[1]], "./title")),
               "Methods")

  # Opening paragraph is a direct child of <abstract>.
  direct_ps <- xml2::xml_find_all(xml, ".//abstract/p")
  expect_length(direct_ps, 1)
  expect_match(xml2::xml_text(direct_ps[[1]]), "An opening sentence")

  # All <p> inside <abstract> (including those nested in <sec>) survive.
  all_ps <- xml2::xml_find_all(xml, ".//abstract//p")
  expect_true(length(all_ps) >= 3,
              info = "All three abstract paragraphs (opening, methods body, trailing) should survive")
})


test_that("non-canonical CRediT roles get rebuilt MetaMap with vocab URIs", {
  skip_if_no_jats_tools()
  paths <- locate_jats_resources()
  skip_if_not(!is.na(paths$fixture), "jats-fixture not found")
  skip_if_not(!is.na(paths$ext), "docstyle extension not found")

  td <- tempfile("jats_credit_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  stage_jats_render(td, paths)

  xml <- render_jats(file.path(td, "protocol.qmd"))
  roles <- xml2::xml_find_all(xml, ".//contrib/role")
  expect_length(roles, 3)

  # All three roles should carry vocab-term-identifier URIs after the
  # filter rebuilds the MetaMap for unrecognized inputs.
  uris <- xml2::xml_attr(roles, "vocab-term-identifier")
  expect_false(any(is.na(uris)),
               info = "All CRediT roles should have vocab-term-identifier URIs")

  # Assert the FULL URI string for each role, not just a substring.
  # A typo in CREDIT_BASE_URI (e.g., credits.niso.org) would still pass
  # a substring check but fail this exact-match assertion.
  expect_equal(uris[1],
               "https://credit.niso.org/contributor-roles/conceptualization/")
  expect_equal(uris[2],
               "https://credit.niso.org/contributor-roles/methodology/")
  expect_equal(uris[3],
               "https://credit.niso.org/contributor-roles/writing-original-draft/")

  # The `vocab` attribute (Pandoc/JATS shorthand for the vocabulary
  # URI) should carry the full base URI, not a substring. (The JATS
  # spec also defines vocab-identifier as a separate attribute, but
  # Pandoc emits the URI on `vocab` itself.)
  vocab_attrs <- xml2::xml_attr(roles, "vocab")
  expect_true(all(vocab_attrs == "https://credit.niso.org"))
})


test_that("CRediT canonicalization handles dash variants and case", {
  # The filter's normalize_for_match folds en-dash, em-dash, hyphen,
  # whitespace, and case so user-supplied variants all resolve to the
  # canonical CRediT URI. We render four authors who each spell the
  # same role differently.
  skip_if_no_jats_tools()
  paths <- locate_jats_resources()
  skip_if_not(!is.na(paths$fixture), "jats-fixture not found")
  skip_if_not(!is.na(paths$ext), "docstyle extension not found")

  td <- tempfile("jats_credit_variants_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  stage_jats_render(td, paths)

  # Override the fixture's QMD with one that has four authors, each
  # spelling "writing - original draft" differently. All should resolve
  # to the writing-original-draft URI.
  writeLines(c(
    "---",
    "title: Dash variants test",
    "author:",
    "  - name: { given: A, family: One }",
    "    roles:",
    "      - 'writing - original draft'",          # hyphen
    "  - name: { given: B, family: Two }",
    "    roles:",
    "      - 'writing – original draft'",      # en-dash (canonical)
    "  - name: { given: C, family: Three }",
    "    roles:",
    "      - 'writing — original draft'",      # em-dash
    "  - name: { given: D, family: Four }",
    "    roles:",
    "      - '  Writing - Original Draft  '",      # mixed case + padding
    "format:",
    "  docstyle-jats: default",
    "---",
    "Body."
  ), file.path(td, "protocol.qmd"))

  xml <- render_jats(file.path(td, "protocol.qmd"))
  roles <- xml2::xml_find_all(xml, ".//contrib/role")
  uris <- xml2::xml_attr(roles, "vocab-term-identifier")
  expected <- "https://credit.niso.org/contributor-roles/writing-original-draft/"
  expect_equal(uris, rep(expected, 4),
               info = "All dash/case/padding variants resolve to same URI")
})


test_that("CRediT canonical roles pass through unchanged (no-op)", {
  # If a user types the canonical en-dash + lowercase form, Quarto
  # itself populates the full MetaMap. The filter's guard
  # `if not role["vocab-term-identifier"]` should skip the rebuild —
  # otherwise we'd be doing redundant work and could drift the
  # MetaMap shape on every render.
  skip_if_no_jats_tools()
  paths <- locate_jats_resources()
  skip_if_not(!is.na(paths$fixture), "jats-fixture not found")
  skip_if_not(!is.na(paths$ext), "docstyle extension not found")

  td <- tempfile("jats_credit_canonical_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  stage_jats_render(td, paths)

  writeLines(c(
    "---",
    "title: Canonical roles test",
    "author:",
    "  - name: { given: E, family: Five }",
    "    roles:",
    "      - conceptualization",                           # canonical
    "      - 'writing – original draft'",              # canonical
    "format:",
    "  docstyle-jats: default",
    "---",
    "Body."
  ), file.path(td, "protocol.qmd"))

  xml <- render_jats(file.path(td, "protocol.qmd"))
  roles <- xml2::xml_find_all(xml, ".//contrib/role")
  uris <- xml2::xml_attr(roles, "vocab-term-identifier")
  expect_equal(uris[1],
               "https://credit.niso.org/contributor-roles/conceptualization/")
  expect_equal(uris[2],
               "https://credit.niso.org/contributor-roles/writing-original-draft/")
})


test_that("CRediT vocabulary completeness — every term has matching slug", {
  # The credit_terms_to_slug table in jats-fixups.lua is hardcoded.
  # If a future edit typoes a slug for one of the 14 CRediT terms,
  # only an exhaustive test catches it. We extract the table directly
  # from the Lua source and assert every slug matches the canonical
  # CRediT URI shape (lowercase, hyphenated, no spaces).
  ext_dir <- system.file("_extensions", "docstyle", package = "docstyle")
  skip_if_not(nzchar(ext_dir), "extension not findable")
  filter_path <- file.path(ext_dir, "jats-fixups.lua")
  skip_if_not(file.exists(filter_path))

  src <- readLines(filter_path, warn = FALSE)
  table_lines <- grep('^\\s*\\["[^"]+"\\]\\s*=\\s*"[^"]+"', src,
                      value = TRUE)
  expect_true(length(table_lines) >= 14,
              info = "Expected at least 14 CRediT terms in the lookup table")

  for (line in table_lines) {
    canonical <- sub('^\\s*\\["([^"]+)"\\].*', "\\1", line)
    slug <- sub('.*=\\s*"([^"]+)".*', "\\1", line)

    # Slug must be lowercase, hyphenated, no spaces, alphanumeric+hyphen.
    expect_match(slug, "^[a-z][a-z0-9-]*[a-z0-9]$",
                 info = paste("Slug malformed for term:", canonical,
                              "->", slug))
  }
})


# ── JATS already-correct features survive filter ─────────────────────────────

test_that("multi-author affiliations cross-ref correctly in JATS output", {
  skip_if_no_jats_tools()
  paths <- locate_jats_resources()
  skip_if_not(!is.na(paths$fixture), "jats-fixture not found")
  skip_if_not(!is.na(paths$ext), "docstyle extension not found")

  td <- tempfile("jats_aff_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  stage_jats_render(td, paths)

  xml <- render_jats(file.path(td, "protocol.qmd"))

  affs <- xml2::xml_find_all(xml, ".//aff")
  expect_length(affs, 1)
  expect_equal(xml2::xml_attr(affs[[1]], "id"), "aff1")

  xrefs <- xml2::xml_find_all(xml, ".//contrib//xref[@ref-type='aff']")
  expect_true(length(xrefs) >= 1)
  expect_equal(xml2::xml_attr(xrefs[[1]], "rid"), "aff1")
})


test_that("citations emit <ref-list> with <element-citation> records", {
  skip_if_no_jats_tools()
  paths <- locate_jats_resources()
  skip_if_not(!is.na(paths$fixture), "jats-fixture not found")
  skip_if_not(!is.na(paths$ext), "docstyle extension not found")

  td <- tempfile("jats_refs_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  stage_jats_render(td, paths)

  xml <- render_jats(file.path(td, "protocol.qmd"))
  ec <- xml2::xml_find_all(xml, ".//ref-list/ref/element-citation")
  expect_length(ec, 1)

  # DOI tagged as <pub-id pub-id-type="doi">.
  doi <- xml2::xml_find_first(ec, ".//pub-id[@pub-id-type='doi']")
  expect_false(inherits(doi, "xml_missing"))
  expect_equal(xml2::xml_text(doi), "10.1234/x")

  # In-text citation appears as <xref ref-type="bibr">.
  citations <- xml2::xml_find_all(xml,
                                  ".//body//xref[@ref-type='bibr']")
  expect_true(length(citations) >= 1)
})


test_that("tables render as <table-wrap>/<table>/<thead>/<tbody>", {
  skip_if_no_jats_tools()
  paths <- locate_jats_resources()
  skip_if_not(!is.na(paths$fixture), "jats-fixture not found")
  skip_if_not(!is.na(paths$ext), "docstyle extension not found")

  td <- tempfile("jats_table_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  stage_jats_render(td, paths)

  xml <- render_jats(file.path(td, "protocol.qmd"))
  tw <- xml2::xml_find_all(xml, ".//table-wrap")
  expect_length(tw, 1)
  expect_length(xml2::xml_find_all(tw, ".//thead"), 1)
  expect_length(xml2::xml_find_all(tw, ".//tbody"), 1)
  # Two data rows in the fixture.
  expect_length(xml2::xml_find_all(tw, ".//tbody/tr"), 2)
})


# ── Filter is no-op for non-JATS formats ─────────────────────────────────────

test_that("jats-fixups.lua returns nil for non-JATS formats (no interference)", {
  # Minimal QMD rendered through docstyle-typst. The contract: the
  # filter's early-return path must not crash or alter non-JATS
  # pipelines. We use a fresh minimal QMD (not the JATS fixture, whose
  # `bibliography:` and `csl:` URL clash with Typst) so the assertion
  # is solely about the filter, not Typst's bibliography handling.
  skip_if_no_jats_tools()
  paths <- locate_jats_resources()
  skip_if_not(!is.na(paths$ext), "docstyle extension not found")

  td <- tempfile("jats_noop_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE))
  dir.create(file.path(td, "_extensions", "docstyle"), recursive = TRUE)
  ok <- file.copy(list.files(paths$ext, full.names = TRUE),
                  file.path(td, "_extensions", "docstyle"),
                  recursive = TRUE)
  if (!all(ok)) skip("Could not stage extension")

  writeLines(c(
    "---", "title: Minimal non-JATS render",
    "format: docstyle-typst", "---",
    "Body text."
  ), file.path(td, "doc.qmd"))

  out <- system2("quarto", c("render", file.path(td, "doc.qmd")),
                 stdout = TRUE, stderr = TRUE)
  status <- attr(out, "status")
  status <- if (is.null(status)) 0L else status
  expect_equal(status, 0L,
               info = paste("Non-JATS render failed:",
                            paste(out, collapse = "\n")))
  expect_true(file.exists(file.path(td, "doc.pdf")))
})
