# docx Abstract Position (#149) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an author control where the abstract renders in `docstyle-docx` output (e.g. below the author plate) via an opt-in `:::docstyle-abstract:::` placeholder, instead of Pandoc always hoisting it to the document top.

**Architecture:** R-first assembly — a docx-only Lua filter emits a `DOCSTYLE_ABSTRACT` position marker (wrapped in an `ADDIN DOCSTYLE` `div` field code) at the placeholder div; a new `relocate_abstract()` step in `finalize_docx` *moves* Pandoc's hoisted `AbstractTitle`+`Abstract` paragraphs to the marker. Harvest round-trips via the existing field-code registry (register `abstract` as a `div_type`) plus a content-capture step that restores the prose to `abstract:` YAML. CSS→Word styling (Loop 1) is already wired; we move Pandoc's styled paragraphs, never rebuild them.

**Tech Stack:** R (xml2, officer-free raw XML), Pandoc Lua filters, Quarto extension, testthat.

**Spec:** `docs/superpowers/specs/2026-05-30-docx-abstract-position-design.md`

**Out of scope (separate issues):** #153 (DRY-unify the section filters), #154 (Loop 2 cold-harvest of foreign `Abstract`-styled docs). Do NOT touch version-history/author-plate/toc/bibliography rendering.

---

## File Structure

- **Create** `_extensions/docstyle/abstract.lua` — Lua filter; `Div` handler matches class `docstyle-abstract`, emits the marker (docx only).
- **Modify** `_extensions/docstyle/_extension.yml` — register `abstract.lua` under the `docx` format's `filters:` list only.
- **Modify** `R/use_docstyle.R` — add `"abstract.lua"` to `EXTENSION_SOURCE_FILES`.
- **Create** `R/relocate_abstract.R` — `relocate_abstract(body, ns, verbose)` finisher step.
- **Modify** `R/finalize_docx.R` — call `relocate_abstract()` after `assemble_anchors`.
- **Modify** `inst/schema/docstyle-field-codes.json` — add `abstract` to `div_types`.
- **Modify** `R/field_codes.R` — add `abstract` to the `.docstyle_div_fallback` registry.
- **Modify** `R/docx_to_qmd.R` — harvest: capture the `abstract` field-code range's prose into `harvested_abstract`, write to `yaml_header$abstract`, emit empty `:::docstyle-abstract:::` div.
- **Create** `tests/testthat/test-relocate-abstract.R` — unit tests for the finisher.
- **Modify** `tests/testthat/test-docx-to-qmd.R` — harvest round-trip tests.
- **Create** `tests/testthat/test-abstract-filter.R` — pandoc-only Lua filter test (cross-format safety).

---

## Task 1: Register the `abstract` div type (schema + R fallback)

This is the harvest registry entry. Doing it first means later harvest work has the registration in place.

**Files:**
- Modify: `inst/schema/docstyle-field-codes.json` (the `div_types` object)
- Modify: `R/field_codes.R` (the `.docstyle_div_fallback` list, ~line 356-369)
- Test: `tests/testthat/test-field-codes.R` (or wherever div-type handling is tested — verify with `grep -rl "docstyle_div_fallback\|div_types" tests/`)

- [ ] **Step 1: Write the failing test**

Add to `tests/testthat/test-field-codes.R` (create the file if absent, using the standard `library`-free testthat style — `devtools::load_all()` provides internals):

```r
test_that("abstract is a registered div type (#149)", {
  # handle_docstyle_div should reconstruct the :::docstyle-abstract::: div
  res <- docstyle:::handle_docstyle_div(list(type = "div", name = "abstract"))
  expect_equal(res$div_open, "::: docstyle-abstract")
  expect_equal(res$div_close, ":::")
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Rscript -e 'devtools::load_all(quiet=TRUE); testthat::test_file("tests/testthat/test-field-codes.R", filter=NULL)'`
Expected: FAIL — `abstract` not in registry, `div_open` is NULL or the fallback default.

- [ ] **Step 3: Add the schema entry**

In `inst/schema/docstyle-field-codes.json`, add to the `div_types` object (after `author-plate`):

```json
    "abstract": {
      "div_open": "::: docstyle-abstract",
      "div_close": ":::"
    }
```

- [ ] **Step 4: Add the R fallback entry**

In `R/field_codes.R`, find `.docstyle_div_fallback` (~line 356). It is a named list mapping div names to `list(div_open=, div_close=)`. Add:

```r
  "abstract" = list(div_open = "::: docstyle-abstract", div_close = ":::"),
```

Place it alongside the existing `toc` / `version-history` / `author-plate` entries, matching their exact syntax.

- [ ] **Step 5: Run test to verify it passes**

Run: `Rscript -e 'devtools::load_all(quiet=TRUE); testthat::test_file("tests/testthat/test-field-codes.R")'`
Expected: PASS.

- [ ] **Step 6: Verify the schema JSON is valid**

Run: `Rscript -e 'jsonlite::read_json("inst/schema/docstyle-field-codes.json")$div_types$abstract'`
Expected: prints the `div_open`/`div_close` list, no parse error.

- [ ] **Step 7: Commit**

```bash
git add inst/schema/docstyle-field-codes.json R/field_codes.R tests/testthat/test-field-codes.R
git commit -m "Register abstract div type for harvest round-trip (#149)"
```

---

## Task 2: The `abstract.lua` Lua filter (emit the position marker)

**Files:**
- Create: `_extensions/docstyle/abstract.lua`
- Test: `tests/testthat/test-abstract-filter.R`

- [ ] **Step 1: Write the failing test (pandoc-only, cross-format safety)**

Create `tests/testthat/test-abstract-filter.R`. Mirrors the #140 pandoc-only pattern: drive the real filter via `pandoc` and assert on output, needing only pandoc (not quarto), so it runs on tool-light CI. The filter `require`s `field-code-utils.lua`, which resolves only when pandoc runs from the extension dir — so each test `setwd`s there.

The positive (docx) assertion writes a real `.docx` and greps `word/document.xml` (the marker is openxml RawBlock content, which lands there; capturing `-t docx` from stdout is binary and unreliable). The negative (typst/jats/latex) assertion captures stdout text, where the filter must produce no marker.

```r
# #149: abstract.lua emits a DOCSTYLE_ABSTRACT marker for :::docstyle-abstract:::
# in docx output only; returns nil (no marker leak) for typst/jats/latex.

locate_ext_dir <- function() {
  for (p in c("../../_extensions/docstyle", "_extensions/docstyle")) {
    n <- normalizePath(file.path(getwd(), p), mustWork = FALSE)
    if (dir.exists(n)) return(n)
  }
  NA_character_
}

abstract_qmd_lines <- function() {
  c("---", "title: T", 'abstract: "Real abstract."', "---",
    "", "::: docstyle-abstract", ":::", "", "# Intro", "", "Body.")
}

# Non-docx writers: capture stdout text and check the marker is absent.
run_abstract_to_text <- function(ext_dir, writer) {
  doc <- tempfile(fileext = ".md"); writeLines(abstract_qmd_lines(), doc)
  old <- setwd(ext_dir); on.exit(setwd(old), add = TRUE)
  out <- system2("pandoc", c("-f", "markdown", "-t", writer,
                             "--lua-filter=abstract.lua", doc),
                 stdout = TRUE, stderr = TRUE)
  paste(out, collapse = "\n")
}

test_that("abstract.lua emits DOCSTYLE_ABSTRACT marker under docx (#149)", {
  testthat::skip_if_not(nzchar(Sys.which("pandoc")), "pandoc not available")
  ext <- locate_ext_dir(); testthat::skip_if(is.na(ext), "ext not found")
  doc <- tempfile(fileext = ".md"); writeLines(abstract_qmd_lines(), doc)
  out_docx <- tempfile(fileext = ".docx")
  old <- setwd(ext); on.exit(setwd(old), add = TRUE)
  system2("pandoc", c("-f", "markdown", "-t", "docx",
                      "--lua-filter=abstract.lua", doc, "-o", out_docx),
          stdout = TRUE, stderr = TRUE)
  testthat::skip_if_not(file.exists(out_docx), "pandoc docx render failed")
  xml <- paste(readLines(unzip(out_docx, "word/document.xml",
                               exdir = tempfile()), warn = FALSE), collapse = "")
  expect_match(xml, "DOCSTYLE_ABSTRACT")
})

test_that("abstract.lua returns nil (no marker leak) for typst/jats/latex (#149)", {
  testthat::skip_if_not(nzchar(Sys.which("pandoc")), "pandoc not available")
  ext <- locate_ext_dir(); testthat::skip_if(is.na(ext), "ext not found")
  for (w in c("typst", "jats", "latex")) {
    out <- run_abstract_to_text(ext, w)
    expect_false(grepl("DOCSTYLE_ABSTRACT", out),
                 info = paste0("marker leaked into ", w, ":\n", out))
  }
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Rscript -e 'devtools::load_all(quiet=TRUE); testthat::test_file("tests/testthat/test-abstract-filter.R")'`
Expected: FAIL — `abstract.lua` does not exist (`--lua-filter` errors or marker absent).

- [ ] **Step 3: Create the filter**

Create `_extensions/docstyle/abstract.lua`:

```lua
-- abstract.lua
-- Emits a DOCSTYLE_ABSTRACT position marker (wrapped in an ADDIN DOCSTYLE
-- div field code) at a :::docstyle-abstract::: placeholder div, so the R
-- post-render relocate_abstract() step can MOVE Pandoc's hoisted
-- AbstractTitle+Abstract paragraphs to that position (#149). docx only;
-- returns nil for typst/jats/latex (Quarto renders the abstract natively
-- there). The placeholder class is docstyle-namespaced, NOT Pandoc's
-- special `.abstract` div.

local fcu = require("field-code-utils")

local function is_word_format()
  return FORMAT == "docx" or FORMAT == "openxml"
end

function Div(div)
  if not div.classes:includes("docstyle-abstract") then
    return nil
  end
  if not is_word_format() then
    return nil  -- Quarto handles the abstract natively for non-docx formats
  end

  -- field_start | DOCSTYLE_ABSTRACT marker paragraph | field_end
  -- No content: the abstract paragraphs are relocated from the document
  -- top by relocate_abstract() in post-render.
  local marker = '<w:p><w:r><w:t xml:space="preserve">DOCSTYLE_ABSTRACT</w:t></w:r></w:p>'
  return pandoc.Blocks({
    pandoc.RawBlock("openxml", fcu.build_div_field_start("abstract")),
    pandoc.RawBlock("openxml", marker),
    pandoc.RawBlock("openxml", fcu.build_block_field_end())
  })
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Rscript -e 'devtools::load_all(quiet=TRUE); testthat::test_file("tests/testthat/test-abstract-filter.R")'`
Expected: PASS — marker present under docx, absent under typst/jats/latex.

- [ ] **Step 5: Commit**

```bash
git add _extensions/docstyle/abstract.lua tests/testthat/test-abstract-filter.R
git commit -m "Add abstract.lua: emit DOCSTYLE_ABSTRACT position marker, docx only (#149)"
```

---

## Task 3: Register `abstract.lua` in the extension + manifest

**Files:**
- Modify: `_extensions/docstyle/_extension.yml` (the `docx:` format `filters:` list, ~line 16-29)
- Modify: `R/use_docstyle.R` (`EXTENSION_SOURCE_FILES`, ~line 686-708)
- Test: `tests/testthat/test-use-docstyle.R` (the `EXTENSION_SOURCE_FILES` manifest test, ~line 749)

- [ ] **Step 1: Run the manifest guard test to verify it FAILS after adding the file**

The `EXTENSION_SOURCE_FILES` test asserts the constant matches the actual extension dir contents. Since Task 2 added `abstract.lua` to the dir but not the constant, this test should already be failing:

Run: `Rscript -e 'devtools::load_all(quiet=TRUE); testthat::test_file("tests/testthat/test-use-docstyle.R")'`
Expected: FAIL — `abstract.lua` in dir but missing from `EXTENSION_SOURCE_FILES`.

- [ ] **Step 2: Add to the manifest constant**

In `R/use_docstyle.R`, in the `EXTENSION_SOURCE_FILES` vector, add `"abstract.lua"` in alphabetical position (after `"anchor.lua"`-area / before `"author-plate.lua"` — match the existing ordering):

```r
  "abstract.lua",
```

- [ ] **Step 3: Register the filter under the docx format**

In `_extensions/docstyle/_extension.yml`, in the `docx:` → `filters:` list, add `abstract.lua`. Place it before `author-plate.lua` (so the marker is planted before the author-plate filter runs; order is not strictly load-bearing since relocation happens in R, but keep it grouped with the other generated-section filters):

```yaml
        - abstract.lua
```

Do NOT add it to the `typst:` or `jats:` filter lists.

- [ ] **Step 4: Run the manifest test to verify it passes**

Run: `Rscript -e 'devtools::load_all(quiet=TRUE); testthat::test_file("tests/testthat/test-use-docstyle.R")'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add _extensions/docstyle/_extension.yml R/use_docstyle.R
git commit -m "Register abstract.lua under docx format + manifest (#149)"
```

---

## Task 4: `relocate_abstract()` — single-paragraph abstract

The core finisher. Build it up across Tasks 4-6 (single → multi-paragraph → no-content), TDD each.

**Files:**
- Create: `R/relocate_abstract.R`
- Test: `tests/testthat/test-relocate-abstract.R`

- [ ] **Step 1: Write the failing test**

Create `tests/testthat/test-relocate-abstract.R`. Build a synthetic `document.xml` body where the abstract paragraphs are at the TOP and the `DOCSTYLE_ABSTRACT` marker is further down (simulating Pandoc's hoist + our marker in the body). Assert the abstract paragraphs end up at the marker's position and the marker is removed.

```r
# #149: relocate_abstract() moves Pandoc's hoisted AbstractTitle+Abstract
# paragraphs to the DOCSTYLE_ABSTRACT marker position, then removes the marker.

ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

# Build a w:body from a vector of paragraph XML strings; return the parsed
# <w:body> node (matching how finalize_docx passes `body`).
make_body <- function(paras) {
  doc <- paste0(
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>', paste(paras, collapse = ""), '</w:body></w:document>')
  xml2::xml_find_first(xml2::read_xml(doc), "//w:body", ns)
}

styled_p <- function(style, text) {
  sprintf('<w:p><w:pPr><w:pStyle w:val="%s"/></w:pPr><w:r><w:t>%s</w:t></w:r></w:p>',
          style, text)
}
plain_p  <- function(text) sprintf('<w:p><w:r><w:t>%s</w:t></w:r></w:p>', text)
marker_p <- '<w:p><w:r><w:t>DOCSTYLE_ABSTRACT</w:t></w:r></w:p>'

# Return the ordered vector of (style|text) signatures for body paragraphs,
# so assertions can check final order. Uses pStyle val or "" + first text.
para_sig <- function(body) {
  ps <- xml2::xml_find_all(body, "./w:p", ns)
  vapply(ps, function(p) {
    style <- xml2::xml_text(xml2::xml_find_first(p, "./w:pPr/w:pStyle/@w:val", ns))
    txt   <- xml2::xml_text(xml2::xml_find_first(p, ".//w:t", ns))
    paste0(if (is.na(style)) "" else style, "|", if (is.na(txt)) "" else txt)
  }, character(1))
}

test_that("relocate_abstract moves a single-paragraph abstract to the marker (#149)", {
  body <- make_body(c(
    styled_p("AbstractTitle", "Abstract"),
    styled_p("Abstract", "The abstract text."),
    plain_p("Author plate stand-in."),
    marker_p,
    plain_p("Body intro.")
  ))

  n <- docstyle:::relocate_abstract(body, ns, verbose = FALSE)

  expect_equal(n, 1L)  # one relocation performed
  sig <- para_sig(body)
  # Marker removed.
  expect_false(any(grepl("DOCSTYLE_ABSTRACT", sig)))
  # Abstract now sits where the marker was: after the author plate, before body.
  expect_equal(sig, c(
    "|Author plate stand-in.",
    "AbstractTitle|Abstract",
    "Abstract|The abstract text.",
    "|Body intro."
  ))
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Rscript -e 'devtools::load_all(quiet=TRUE); testthat::test_file("tests/testthat/test-relocate-abstract.R")'`
Expected: FAIL — `relocate_abstract` not found.

- [ ] **Step 3: Write the implementation**

Create `R/relocate_abstract.R`:

```r
#' Relocate the abstract to its placeholder position (#149)
#'
#' Pandoc's docx writer hoists the YAML `abstract:` to the top of the
#' document as `AbstractTitle` + `Abstract`-styled paragraphs, before any
#' body content. When the author opts in with a `:::docstyle-abstract:::`
#' placeholder, `abstract.lua` plants a `DOCSTYLE_ABSTRACT` marker at that
#' body position. This finisher MOVES the hoisted abstract paragraphs to the
#' marker, then removes the marker.
#'
#' Move, don't rebuild: relocating Pandoc's already-styled paragraphs
#' preserves the CSS-driven `Abstract`/`AbstractTitle` styling (Loop 1) and
#' any multi-paragraph structure intact.
#'
#' @param body The `<w:body>` xml2 node.
#' @param ns Namespace map (`w = ...`).
#' @param verbose Logical; print a diagnostic.
#' @return Integer count of relocations performed (0 or 1).
#' @noRd
relocate_abstract <- function(body, ns, verbose = FALSE) {
  paras <- xml2::xml_find_all(body, "./w:p", ns)
  if (length(paras) == 0L) return(0L)

  # Find the marker paragraph (a w:p whose text is exactly DOCSTYLE_ABSTRACT).
  marker_idx <- NA_integer_
  for (i in seq_along(paras)) {
    txt <- xml2::xml_text(paras[[i]])
    if (identical(trimws(txt), "DOCSTYLE_ABSTRACT")) { marker_idx <- i; break }
  }
  if (is.na(marker_idx)) return(0L)  # no opt-in; leave document untouched

  marker <- paras[[marker_idx]]

  # Find the contiguous abstract block: an AbstractTitle paragraph followed
  # by one or more contiguous Abstract paragraphs (the hoisted block).
  abstract_nodes <- find_abstract_block(paras, ns)

  if (length(abstract_nodes) == 0L) {
    # Marker present but no abstract content: remove marker, warn, no move.
    if (verbose) {
      message("[finalize] abstract placeholder present but no abstract ",
              "content found")
    }
    xml2::xml_remove(marker)
    return(0L)
  }

  # Move each abstract node to just before the marker (in order), then
  # remove the marker. xml_add_sibling on an in-tree node performs a MOVE.
  for (node in abstract_nodes) {
    xml2::xml_add_sibling(marker, node, .where = "before")
  }
  xml2::xml_remove(marker)

  if (verbose) {
    message("[finalize] Relocated abstract (", length(abstract_nodes),
            " paragraph(s)) to placeholder position")
  }
  1L
}

#' Find the hoisted abstract paragraph block
#'
#' Returns the `AbstractTitle` paragraph (if present) plus all immediately
#' following contiguous `Abstract`-styled paragraphs, as a list of xml2
#' nodes. Returns an empty list if no `Abstract`-styled paragraph exists.
#' @noRd
find_abstract_block <- function(paras, ns) {
  para_style <- function(p) {
    s <- xml2::xml_text(xml2::xml_find_first(p, "./w:pPr/w:pStyle/@w:val", ns))
    if (is.na(s)) "" else s
  }
  styles <- vapply(paras, para_style, character(1))

  # Locate the first Abstract or AbstractTitle paragraph.
  start <- which(styles %in% c("AbstractTitle", "Abstract"))
  if (length(start) == 0L) return(list())
  start <- start[1]

  # Collect AbstractTitle (if at start) + contiguous Abstract paragraphs.
  block <- list()
  i <- start
  # AbstractTitle may or may not be present; include it if it's the start.
  if (styles[i] == "AbstractTitle") {
    block[[length(block) + 1L]] <- paras[[i]]
    i <- i + 1L
  }
  while (i <= length(styles) && styles[i] == "Abstract") {
    block[[length(block) + 1L]] <- paras[[i]]
    i <- i + 1L
  }
  block
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Rscript -e 'devtools::load_all(quiet=TRUE); testthat::test_file("tests/testthat/test-relocate-abstract.R")'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add R/relocate_abstract.R tests/testthat/test-relocate-abstract.R
git commit -m "Add relocate_abstract(): move single-paragraph abstract to marker (#149)"
```

---

## Task 5: `relocate_abstract()` — multi-paragraph abstract + no-marker passthrough

**Files:**
- Test: `tests/testthat/test-relocate-abstract.R` (add cases)

- [ ] **Step 1: Write the failing tests**

Add to `tests/testthat/test-relocate-abstract.R`:

```r
test_that("relocate_abstract moves all contiguous Abstract paragraphs (#149)", {
  body <- make_body(c(
    styled_p("AbstractTitle", "Abstract"),
    styled_p("Abstract", "Para one."),
    styled_p("Abstract", "Para two."),
    styled_p("Abstract", "Para three."),
    plain_p("Author plate."),
    marker_p,
    plain_p("Body.")
  ))
  n <- docstyle:::relocate_abstract(body, ns, verbose = FALSE)
  expect_equal(n, 1L)
  sig <- para_sig(body)
  expect_false(any(grepl("DOCSTYLE_ABSTRACT", sig)))
  expect_equal(sig, c(
    "|Author plate.",
    "AbstractTitle|Abstract",
    "Abstract|Para one.",
    "Abstract|Para two.",
    "Abstract|Para three.",
    "|Body."
  ))
})

test_that("relocate_abstract is a no-op when no marker present (#149)", {
  # Author did not opt in: abstract stays at top, untouched, no error.
  body <- make_body(c(
    styled_p("AbstractTitle", "Abstract"),
    styled_p("Abstract", "The abstract."),
    plain_p("Body.")
  ))
  before <- para_sig(body)
  n <- docstyle:::relocate_abstract(body, ns, verbose = FALSE)
  expect_equal(n, 0L)
  expect_equal(para_sig(body), before)  # unchanged
})

test_that("relocate_abstract removes marker but does not error when no abstract (#149)", {
  # Marker present (opt-in) but no YAML abstract → no Abstract paragraphs.
  body <- make_body(c(
    plain_p("Author plate."),
    marker_p,
    plain_p("Body.")
  ))
  n <- docstyle:::relocate_abstract(body, ns, verbose = FALSE)
  expect_equal(n, 0L)
  sig <- para_sig(body)
  expect_false(any(grepl("DOCSTYLE_ABSTRACT", sig)))  # marker removed
  expect_equal(sig, c("|Author plate.", "|Body."))
})

test_that("relocate_abstract handles Abstract paragraphs with no AbstractTitle (#149)", {
  # Some templates emit only the Abstract style, no title paragraph.
  body <- make_body(c(
    styled_p("Abstract", "The abstract."),
    plain_p("Author plate."),
    marker_p,
    plain_p("Body.")
  ))
  n <- docstyle:::relocate_abstract(body, ns, verbose = FALSE)
  expect_equal(n, 1L)
  sig <- para_sig(body)
  expect_equal(sig, c(
    "|Author plate.",
    "Abstract|The abstract.",
    "|Body."
  ))
})
```

- [ ] **Step 2: Run tests**

Run: `Rscript -e 'devtools::load_all(quiet=TRUE); testthat::test_file("tests/testthat/test-relocate-abstract.R")'`
Expected: The multi-paragraph, no-marker, and no-AbstractTitle cases should PASS with the Task 4 implementation (it already handles these). The "removes marker but no abstract" case should also PASS. If any fail, fix `find_abstract_block`/`relocate_abstract` minimally until green.

- [ ] **Step 3: Commit**

```bash
git add tests/testthat/test-relocate-abstract.R
git commit -m "Cover multi-paragraph, no-marker, no-title abstract relocation (#149)"
```

---

## Task 6: Wire `relocate_abstract()` into `finalize_docx`

**Files:**
- Modify: `R/finalize_docx.R` (after the `assemble_anchors` call, ~line 69-73)
- Test: `tests/testthat/test-relocate-abstract.R` (add an integration-ish test through `finalize_docx` if a DOCX fixture is convenient; otherwise rely on the Task 8 render test)

- [ ] **Step 1: Add the call**

In `R/finalize_docx.R`, immediately after the `assemble_anchors(...)` block (the `if (verbose && anchor_result$n_assembled > 0)` message ends ~line 72), add:

```r
  # === ABSTRACT RELOCATION (#149) ===
  # Move Pandoc's hoisted AbstractTitle+Abstract paragraphs to the
  # DOCSTYLE_ABSTRACT marker (if the author opted in via :::docstyle-abstract:::).
  # Runs after anchor assembly, before body sectPr / header-footer / pruning
  # steps, so the abstract paragraphs are in their final position before any
  # style or section finalisation touches the body.
  n_abstract <- relocate_abstract(body, ns, verbose = verbose)
```

- [ ] **Step 2: Verify the package loads and existing finalize tests pass**

Run: `Rscript -e 'devtools::load_all(quiet=TRUE); testthat::test_file("tests/testthat/test-relocate-abstract.R")'`
Then the broader finalize suite (find it: `ls tests/testthat/ | grep -iE "finalize|section"`):
Run: `Rscript -e 'devtools::load_all(quiet=TRUE); devtools::test(filter="finalize|section|relocate")'`
Expected: PASS, no regressions.

- [ ] **Step 3: Commit**

```bash
git add R/finalize_docx.R
git commit -m "Wire relocate_abstract into finalize_docx after anchor assembly (#149)"
```

---

## Task 7: Harvest — capture abstract prose to YAML + emit empty placeholder

On re-harvest, the `abstract` field-code range must (a) emit the empty `:::docstyle-abstract:::` div (free, via Task 1's registry) and (b) capture the relocated `Abstract`-styled paragraphs' text into `yaml_header$abstract`.

**Files:**
- Modify: `R/docx_to_qmd.R` (the field-code range handling, near the `version-history` capture at ~line 1692-1697, and the YAML emission)
- Test: `tests/testthat/test-docx-to-qmd.R`

- [ ] **Step 1: Write the failing round-trip test**

Add to `tests/testthat/test-docx-to-qmd.R`. Reuse the `build_docx_with_styles` helper added for #125 (it writes `word/styles.xml` + `document.xml`). Build a docx whose body contains an `abstract` field-code range wrapping `AbstractTitle`+`Abstract` paragraphs, and assert harvest produces `abstract:` YAML + an empty `:::docstyle-abstract:::` div.

```r
test_that("harvest captures relocated abstract to YAML + empty placeholder (#149)", {
  skip_if_not_installed("xml2")
  td <- tempfile("h149_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)

  ns_w <- "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
  # ADDIN DOCSTYLE div field code (begin) carrying name=abstract, then the
  # AbstractTitle+Abstract paragraphs, then the field-code end.
  fc_begin <- paste0(
    '<w:p><w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE ',
    '{"type":"div","name":"abstract"} </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>')
  fc_end <- paste0(
    '<w:p><w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE ',
    '{"type":"div-end"} </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>')

  styles <- paste0(
    '<w:style w:type="paragraph" w:styleId="AbstractTitle">',
    '<w:name w:val="Abstract Title"/></w:style>',
    '<w:style w:type="paragraph" w:styleId="Abstract">',
    '<w:name w:val="Abstract"/></w:style>')
  body <- paste0(
    fc_begin,
    '<w:p><w:pPr><w:pStyle w:val="AbstractTitle"/></w:pPr><w:r><w:t>Abstract</w:t></w:r></w:p>',
    '<w:p><w:pPr><w:pStyle w:val="Abstract"/></w:pPr><w:r><w:t>First line of abstract.</w:t></w:r></w:p>',
    '<w:p><w:pPr><w:pStyle w:val="Abstract"/></w:pPr><w:r><w:t>Second line of abstract.</w:t></w:r></w:p>',
    fc_end,
    '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Intro</w:t></w:r></w:p>')

  docx <- build_docx_with_styles(td, styles, body, filename = "abs.docx")
  qmd <- file.path(td, "out.qmd")
  suppressMessages(docx_to_qmd(docx, qmd))
  lines <- readLines(qmd)
  text  <- paste(lines, collapse = "\n")

  # Empty placeholder div emitted at the range position.
  expect_true(any(grepl("^::: \\{?#?docstyle-abstract", lines)) ||
              any(grepl("^::: docstyle-abstract", lines)),
              info = paste0("no docstyle-abstract placeholder:\n", text))
  # Abstract prose captured into YAML, NOT emitted inline in the body.
  expect_match(text, "abstract:")
  expect_match(text, "First line of abstract")
  expect_match(text, "Second line of abstract")
  # The AbstractTitle literal "Abstract" heading is not dumped as body prose.
  expect_false(any(grepl("^Abstract$", lines)))
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Rscript -e 'devtools::load_all(quiet=TRUE); testthat::test_file("tests/testthat/test-docx-to-qmd.R", filter=NULL)'`
Expected: FAIL — the range is detected (placeholder may emit), but the abstract prose is either dumped inline or not captured to YAML.

- [ ] **Step 3: Implement capture (mirror version-history)**

In `R/docx_to_qmd.R`, find the field-code range capture block (~line 1692-1697) where `harvested_version_history` is populated for the `version-history` range. Add a parallel capture for the `abstract` range. First, near the other `harvested_*` initialisations (~line 1692), add:

```r
  harvested_abstract <- NULL
```

Then in the range-handling loop where `version-history` is captured, add an `abstract` branch. The exact structure mirrors the existing `if (rng$name %in% c("_docstyle_version_history", "version-history"))` block. Add after it:

```r
      if (rng$name == "abstract") {
        harvested_abstract <- parse_abstract_range(children, rng, ns)
      }
```

- [ ] **Step 4: Write `parse_abstract_range()`**

Add a helper in `R/docx_to_qmd.R` (near `parse_version_history_table`):

```r
#' Extract abstract prose from an abstract field-code range (#149)
#'
#' Collects the text of `Abstract`-styled paragraphs within the range
#' (skipping the `AbstractTitle` heading paragraph), joined as paragraphs,
#' for restoration to `abstract:` YAML on harvest.
#' @noRd
parse_abstract_range <- function(children, rng, ns) {
  idxs <- seq.int(rng$start_idx, rng$end_idx)
  texts <- character(0)
  for (i in idxs) {
    node <- children[[i]]
    if (is.na(xml2::xml_name(node)) || xml2::xml_name(node) != "p") next
    style <- xml2::xml_text(
      xml2::xml_find_first(node, "./w:pPr/w:pStyle/@w:val", ns))
    if (identical(style, "AbstractTitle")) next        # skip the title
    if (!identical(style, "Abstract")) next            # only Abstract paras
    t_nodes <- xml2::xml_find_all(node, ".//w:t", ns)
    if (length(t_nodes) == 0L) next
    texts <- c(texts, paste(xml2::xml_text(t_nodes), collapse = ""))
  }
  if (length(texts) == 0L) return(NULL)
  paste(texts, collapse = "\n\n")
}
```

- [ ] **Step 5: Write the captured abstract to YAML**

Find where `yaml_header` is assembled / where `harvested_version_history` is written into `yaml_header` (search `harvested_version_history` usages). Add, in the same place:

```r
  if (!is.null(harvested_abstract)) {
    yaml_header$abstract <- harvested_abstract
  }
```

Confirm the YAML serialiser emits a multi-line `abstract:` correctly (it should — `yaml::as.yaml` / the existing writer handles multi-line strings). If the existing code uses a custom YAML writer, match how it emits other multi-line fields.

- [ ] **Step 6: Ensure the range body prose is NOT also emitted inline**

The generic div-range handler emits the placeholder and `next`s past inner paragraphs (per the spec's harvest analysis — field-code range detection at the top of the loop preempts per-paragraph dispatch). Verify that `abstract` uses the placeholder-and-`next` path (the generic `else` branch), NOT a fall-through path. If the abstract range is incorrectly falling through (inner paragraphs emitted), ensure it routes through the same handler as `version-history`. The Task 7 test's `expect_false(grepl("^Abstract$", lines))` and the absence of inline prose guard this.

- [ ] **Step 7: Run test to verify it passes**

Run: `Rscript -e 'devtools::load_all(quiet=TRUE); testthat::test_file("tests/testthat/test-docx-to-qmd.R")'`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add R/docx_to_qmd.R tests/testthat/test-docx-to-qmd.R
git commit -m "Harvest: capture relocated abstract to YAML + empty placeholder (#149)"
```

---

## Task 8: End-to-end render + cross-format integration test

**Files:**
- Test: `tests/testthat/test-abstract-filter.R` (add render tests) or a new `tests/testthat/test-abstract-render.R`

- [ ] **Step 1: Write the integration test (quarto-gated)**

Create `tests/testthat/test-abstract-render.R`. Stage the extension, render a QMD with `abstract:` + `:::author-plate:::` + `:::docstyle-abstract:::` to `docstyle-docx`, and assert via XPath that the abstract paragraphs appear AFTER the author-plate content. Then render the same QMD to `docstyle-typst` and assert the abstract is on the title page with no stray marker.

```r
`%||%` <- function(x, y) if (is.null(x)) y else x

locate_ext <- function() {
  for (p in c("../../_extensions/docstyle", "_extensions/docstyle")) {
    n <- normalizePath(file.path(getwd(), p), mustWork = FALSE)
    if (dir.exists(n)) return(n)
  }
  NA_character_
}

stage <- function(td, fmt_block, qmd_body) {
  dir.create(file.path(td, "_extensions", "docstyle"), recursive = TRUE)
  ext <- locate_ext()
  ok <- file.copy(list.files(ext, full.names = TRUE),
                  file.path(td, "_extensions", "docstyle"), recursive = TRUE)
  if (!all(ok)) stop("stage failed")
  writeLines(c("project:", "  type: default", "format:", fmt_block),
             file.path(td, "_quarto.yml"))
  writeLines(qmd_body, file.path(td, "doc.qmd"))
}

QMD <- c(
  "---", "title: Abstract Position Test",
  "abstract: |", "  UNIQABS this is the abstract body text.",
  "author:", "  - name: Jane Smith", "---",
  "", "::: author-plate", ":::",
  "", "::: docstyle-abstract", ":::",
  "", "# Introduction", "", "Body paragraph.")

test_that("docx: abstract renders after the author plate (#149)", {
  testthat::skip_if_not(nzchar(Sys.which("quarto")), "quarto not available")
  testthat::skip_if(is.na(locate_ext()), "ext not found")
  td <- tempfile("abs_docx_"); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  stage(td, c("  docstyle-docx: default"), QMD)
  out <- system2("quarto", c("render", file.path(td, "doc.qmd")),
                 stdout = TRUE, stderr = TRUE)
  docx <- file.path(td, "doc.docx")
  testthat::skip_if_not(file.exists(docx),
    paste("render failed:", paste(out, collapse = "\n")))

  xml <- xml2::read_xml(unzip(docx, "word/document.xml", exdir = tempfile()))
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  txt <- vapply(xml2::xml_find_all(xml, "//w:p", ns), xml2::xml_text, character(1))

  plate_i <- which(grepl("Jane Smith", txt))[1]
  abs_i   <- which(grepl("UNIQABS", txt))[1]
  expect_false(is.na(plate_i))
  expect_false(is.na(abs_i))
  expect_true(abs_i > plate_i,
              info = "abstract should appear AFTER the author plate")
  # No marker leaked into final output.
  expect_false(any(grepl("DOCSTYLE_ABSTRACT", txt)))
})

test_that("typst: abstract on title page, no marker leak (#149)", {
  testthat::skip_if_not(nzchar(Sys.which("quarto")), "quarto not available")
  testthat::skip_if(is.na(locate_ext()), "ext not found")
  td <- tempfile("abs_typ_"); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  stage(td, c("  docstyle-typst:", "    keep-typ: true"), QMD)
  out <- system2("quarto", c("render", file.path(td, "doc.qmd")),
                 stdout = TRUE, stderr = TRUE)
  typ <- file.path(td, "doc.typ")
  testthat::skip_if_not(file.exists(typ),
    paste("render failed:", paste(out, collapse = "\n")))
  body <- paste(readLines(typ, warn = FALSE), collapse = "\n")
  # Abstract passed to the preprint() call; no docstyle marker leaked.
  expect_match(body, "UNIQABS")
  expect_false(grepl("DOCSTYLE_ABSTRACT", body))
})
```

- [ ] **Step 2: Run the integration test**

Run: `Rscript -e 'devtools::load_all(quiet=TRUE); testthat::test_file("tests/testthat/test-abstract-render.R")'`
Expected: PASS (or SKIP if quarto unavailable). If the docx test fails on ordering, inspect the rendered `document.xml` paragraph order and adjust `relocate_abstract` insertion (it should already be correct from Tasks 4-6).

- [ ] **Step 3: Commit**

```bash
git add tests/testthat/test-abstract-render.R
git commit -m "Add end-to-end + cross-format integration tests for abstract position (#149)"
```

---

## Task 9: Full suite, version bump, NEWS, CLAUDE.md, close

**Files:**
- Modify: `DESCRIPTION` (Version)
- Modify: `_extensions/docstyle/_extension.yml` (version)
- Modify: `NEWS.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Run the full suite**

Run: `Rscript -e 'devtools::test()'`
Expected: 0 failures (skips for POPCORN/quarto-unavailable are fine). If anything regressed, fix before proceeding.

- [ ] **Step 2: Bump version**

Current version is whatever `grep '^Version' DESCRIPTION` shows (this is a feature → minor bump; if currently `0.17.x`, go to `0.18.0`). Update BOTH:
- `DESCRIPTION`: `Version: 0.18.0`
- `_extensions/docstyle/_extension.yml`: `version: 0.18.0`

- [ ] **Step 3: Add NEWS entry**

Prepend to `NEWS.md` (above the current top entry):

```markdown
# docstyle 0.18.0

## New features

* `:::docstyle-abstract:::` placeholder lets authors control where the
  abstract renders in `docstyle-docx` output — typically below the author
  plate, matching the Typst/PDF order (#149). Opt-in: add the div where you
  want the abstract; without it, behaviour is unchanged (abstract at top).
  Implemented via R-first assembly — a docx-only filter plants a marker and
  `finalize_docx` *moves* Pandoc's hoisted `Abstract`-styled paragraphs to
  it, preserving the CSS-driven `Abstract`/`AbstractTitle` styling. Round-
  trips through harvest (abstract prose restored to `abstract:` YAML, empty
  placeholder re-emitted). The abstract still lives in `abstract:` YAML and
  feeds the Typst title page and JATS `<abstract>` unchanged. Cold-harvest
  of foreign `Abstract`-styled documents is tracked separately (#154).
```

- [ ] **Step 4: Document in CLAUDE.md**

In the harvest / generated-content area of `CLAUDE.md`, add a note (near the existing generated-content / field-code description):

```markdown
**Abstract placeholder (`:::docstyle-abstract:::`, v0.18.0+, #149):** Opt-in div controlling where the abstract renders in docx. Pandoc hoists the YAML `abstract:` to the document top; `abstract.lua` plants a `DOCSTYLE_ABSTRACT` marker at the div, and `relocate_abstract()` in `finalize_docx` MOVES Pandoc's `AbstractTitle`+`Abstract` paragraphs to the marker (move, don't rebuild — preserves CSS-driven styling). docx-only; Typst/JATS render `abstract:` natively. Harvest restores prose to `abstract:` YAML + empty placeholder via the `abstract` div_type. The placeholder class is docstyle-namespaced (NOT Pandoc's special `.abstract`); the `.abstract` CSS class styles the rendered paragraphs. Cold-harvest of foreign abstracts = #154.
```

- [ ] **Step 5: Run the full suite once more after doc/version changes**

Run: `Rscript -e 'devtools::test()'`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add DESCRIPTION _extensions/docstyle/_extension.yml NEWS.md CLAUDE.md
git commit -m "Bump to 0.18.0; document :::docstyle-abstract::: placeholder (#149)"
```

- [ ] **Step 7: Push and close**

```bash
git push origin main
gh issue close 149 --repo DougManuel/docstyle --comment "Fixed in v0.18.0. Authors opt in with a :::docstyle-abstract::: div to control where the abstract renders in docx (typically below the author plate). R-first assembly: docx-only abstract.lua plants a marker, relocate_abstract() in finalize_docx moves Pandoc's hoisted Abstract paragraphs to it. Round-trips via harvest. Typst/JATS unaffected. Loop 2 cold-harvest of foreign abstracts tracked in #154."
```

---

## Notes for the implementer

- **Run `devtools::load_all()` before any `testthat::test_file()`** — the package must be loaded for internal (`docstyle:::`) functions.
- **Lua + R dual nature:** changes to `abstract.lua` and `_extension.yml` take effect immediately on next render; R changes need `load_all()`. Tests that shell out to `quarto render` need docstyle installed in BOTH the global lib AND renv (see CLAUDE.md "dual install" note) — but the unit tests (Tasks 1, 4-7) and the pandoc-only filter test (Task 2) do NOT need quarto.
- **Verify against real `quarto render`, not bare pandoc** for any figure/abstract/crossref behaviour — Quarto's passes differ from bare pandoc (this bit a prior figure fix). Task 8 is the real-render guard.
- **`build_docx_with_styles` helper** (used in Task 7) was added to `test-docx-to-qmd.R` for #125 — reuse it; do not duplicate.
- If `relocate_abstract`'s `find_abstract_block` needs to handle a future edge (e.g. abstract paragraphs not contiguous, or interleaved), extend the contiguity logic — but the current contiguous-run assumption matches Pandoc's actual emission (verified).
