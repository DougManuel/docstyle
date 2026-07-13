# Docstyle vNext work package 0 characterization implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish compact DemPoRT, POPCORN and independent fixtures; capture normalized legacy DOCX, PDF and JATS behaviour; and publish explicit observed-behaviour and known-loss records for later vNext acceptance tests.

**Architecture:** Work package 0 is a migration-only characterization layer. Focused R scripts use the legacy engine and its existing `xml2`/`jsonlite` dependencies to render and inspect outputs, then commit portable artifacts and normalized JSON inventories under `tests/vnext/fixtures/`. Later vNext work consumes those files without importing the R harness or treating legacy behaviour as proof of correctness.

**Tech stack:** R 4.4+, testthat, jsonlite, xml2, digest, Quarto, Pandoc,
Typst, Poppler command-line tools for optional PDF rasterization,
contributor-time curl for pinned third-party source retrieval, and the current
Docstyle extension.

**Programme specification:** `docs/superpowers/specs/2026-07-12-docstyle-vnext-rebuild-design.md`

## Global constraints

- This plan implements work package 0 only. It does not create the vNext engine, semantic-model schema, field-code vNext schema or OOXML parser.
- Task 0 is the sole legacy-engine change: it resolves offline-render blocker
  [#25](https://github.com/DougManuel/docstyle/issues/25) so the legacy Typst
  baselines can be captured without a warm package cache or network access.
- Use an isolated worktree created through `superpowers:using-git-worktrees` before execution.
- Do not modify the DemPoRT or POPCORN repositories. Commit manually reduced fixtures containing synthetic prose and no private contact information.
- Record legacy output as `observed`, `known-bug`, `approximated`, `omitted` or `unsupported`. Never label an observed legacy result as a vNext requirement merely because it exists.
- R is permitted only in `dev/vnext/characterization/` and its testthat tests. No vNext runtime or release command may source this harness.
- Use only packages already listed in `DESCRIPTION`. Poppler is an optional development dependency and must not become a Docstyle user dependency.
- Every committed fixture must use local bibliography, CSL and image assets. Characterization must not require network access.
- Do not compare regenerated DOCX or PDF files by binary hash. Compare normalized inventories, declared properties and selected page images.
- Remove absolute paths, render timestamps, temporary directory names and machine-specific usernames from committed JSON.
- Keep each fixture below 5 MiB and all committed work package 0 artifacts below 15 MiB.
- Preserve current legacy failures in `expectations.json` with an issue or work-package reference. Do not weaken a test to make a legacy failure disappear.

---

## File structure

### Migration-only characterization harness

- Modify `_extensions/docstyle/preprint/typst/typst-template.typ` -- replace
  two remote Typst dependencies with local equivalents.
- Create `_extensions/docstyle/preprint/vendor/wordometer-0.1.5/` -- pinned
  MIT-licensed word-count implementation, licence and provenance.
- Create `dev/vnext/characterization/catalog.R` -- read and validate the fixture catalogue.
- Create `dev/vnext/characterization/render-legacy.R` -- stage a fixture with the current extension and render one requested format.
- Create `dev/vnext/characterization/inspect-docx.R` -- produce a deterministic DOCX semantic and package inventory.
- Create `dev/vnext/characterization/inspect-publication.R` -- inspect PDF and JATS output and rasterize selected PDF pages.
- Create `dev/vnext/characterization/legacy-contract.R` -- freeze legacy field-code and sidecar compatibility.
- Create `dev/vnext/characterization/capture-baselines.R` -- command-line orchestrator for all fixtures and formats.
- Create `dev/vnext/characterization/README.md` -- regeneration, Word-export and interpretation instructions.

### Portable fixture data

- Create `tests/vnext/fixtures/catalog.json` -- fixture origins, formats, feature coverage and visual pages.
- Create `tests/vnext/fixtures/<fixture>/source/assets/fixture.css` -- deterministic styling within each Typst project root.
- Create `tests/vnext/fixtures/<fixture>/source/assets/fixture.csl` -- local deterministic citation style within each project root.
- Create `tests/vnext/fixtures/<fixture>/source/assets/references.bib` -- two local synthetic references within each project root.
- Create `tests/vnext/fixtures/<fixture>/source/assets/diagram.svg` -- deterministic accessible figure within each project root.
- Create `tests/vnext/fixtures/demport-protocol/source/_quarto.yml`.
- Create `tests/vnext/fixtures/demport-protocol/source/protocol.qmd`.
- Create `tests/vnext/fixtures/demport-protocol/expectations.json`.
- Create `tests/vnext/fixtures/popcorn-protocol/source/_quarto.yml`.
- Create `tests/vnext/fixtures/popcorn-protocol/source/protocol.qmd`.
- Create `tests/vnext/fixtures/popcorn-protocol/expectations.json`.
- Create `tests/vnext/fixtures/independent-manuscript/source/_quarto.yml`.
- Create `tests/vnext/fixtures/independent-manuscript/source/manuscript.qmd`.
- Create `tests/vnext/fixtures/independent-manuscript/expectations.json`.
- Generate `tests/vnext/fixtures/<fixture>/baseline/legacy/<format>.<extension>`.
- Generate `tests/vnext/fixtures/<fixture>/baseline/legacy/<format>-inventory.json`.
- Generate `tests/vnext/fixtures/<fixture>/baseline/legacy/pages/docstyle-typst-page-<NNN>.png`.
- Generate `tests/vnext/fixtures/<fixture>/baseline/legacy/manifest.json`.
- Create `tests/vnext/fixtures/legacy-contract.json`.

### Tests

- Create `tests/testthat/test-typst-offline-assets.R`.
- Create `tests/testthat/test-vnext-fixture-catalog.R`.
- Create `tests/testthat/test-vnext-legacy-render.R`.
- Create `tests/testthat/test-vnext-docx-inventory.R`.
- Create `tests/testthat/test-vnext-publication-inventory.R`.
- Create `tests/testthat/test-vnext-legacy-contract.R`.
- Create `tests/testthat/test-vnext-baseline-capture.R`.
- Create `tests/testthat/test-vnext-baselines.R`.

---

### Task 0: Remove network and external-font requirements from legacy Typst

**Files:**
- Modify: `_extensions/docstyle/preprint/typst/typst-template.typ`
- Create: `_extensions/docstyle/preprint/vendor/wordometer-0.1.5/exports.typ`
- Create: `_extensions/docstyle/preprint/vendor/wordometer-0.1.5/lib.typ`
- Create: `_extensions/docstyle/preprint/vendor/wordometer-0.1.5/LICENSE`
- Create: `_extensions/docstyle/preprint/vendor/wordometer-0.1.5/PROVENANCE.md`
- Create: `_extensions/docstyle/preprint/vendor/wordometer-0.1.5/SHA256SUMS`
- Create: `tests/testthat/test-typst-offline-assets.R`

**Interfaces:**
- Preserves: `total-words` and `word-count` used by the preprint template
- Replaces: `fa-orcid(fill, size)` with local
  `docstyle-orcid-mark(fill, size)`
- Addresses: GitHub issue #25
- Consumed by: Tasks 7 and 8

- [ ] **Step 1: Write the failing offline-asset tests**

Create `tests/testthat/test-typst-offline-assets.R`:

```r
locate_offline_typst_root <- function() {
  candidates <- c(
    testthat::test_path("../.."),
    normalizePath(".", mustWork = FALSE)
  )
  hit <- candidates[file.exists(file.path(
    candidates,
    "_extensions", "docstyle", "_extension.yml"
  ))]
  if (length(hit) < 1L) {
    stop("Docstyle repository root not found", call. = FALSE)
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
Rscript -e 'devtools::load_all(quiet = TRUE); testthat::test_file("tests/testthat/test-typst-offline-assets.R")'
```

Expected: all three tests fail because the template still imports two
`@preview` packages and the vendored directory does not exist.

- [ ] **Step 3: Retrieve the pinned MIT-licensed wordometer sources**

Create the vendor directory, then retrieve the unmodified upstream files from
Typst packages commit `1491a1e60c4ec8bcef8d598f1f501712f643fb23`:

```bash
mkdir -p _extensions/docstyle/preprint/vendor/wordometer-0.1.5
curl --fail --location --output _extensions/docstyle/preprint/vendor/wordometer-0.1.5/exports.typ https://raw.githubusercontent.com/typst/packages/1491a1e60c4ec8bcef8d598f1f501712f643fb23/packages/preview/wordometer/0.1.5/src/exports.typ
curl --fail --location --output _extensions/docstyle/preprint/vendor/wordometer-0.1.5/lib.typ https://raw.githubusercontent.com/typst/packages/1491a1e60c4ec8bcef8d598f1f501712f643fb23/packages/preview/wordometer/0.1.5/src/lib.typ
curl --fail --location --output _extensions/docstyle/preprint/vendor/wordometer-0.1.5/LICENSE https://raw.githubusercontent.com/typst/packages/1491a1e60c4ec8bcef8d598f1f501712f643fb23/packages/preview/wordometer/0.1.5/LICENSE
```

These three commands are the one contributor-time network step in this plan.
They retrieve immutable third-party sources; user rendering and baseline
capture remain offline.

Create `SHA256SUMS`:

```text
83dba74bcfaa29018e5158837a418995b65ca0f061b09e673948c878d5063cd3  exports.typ
79561b79f62ae043b985b723a0db4e75859fefc203590a811c671ff9fee6b4d2  lib.typ
c33a5648cee72a57bdfee4b309998e04569001904d65189cd1204b1772a0fe86  LICENSE
```

Run:

```bash
shasum -a 256 -c _extensions/docstyle/preprint/vendor/wordometer-0.1.5/SHA256SUMS
```

Expected: `exports.typ`, `lib.typ` and `LICENSE` each report `OK`.

- [ ] **Step 4: Record third-party provenance**

Create `PROVENANCE.md`:

```markdown
# wordometer 0.1.5 provenance

- Upstream package: `@preview/wordometer:0.1.5`
- Upstream repository: <https://github.com/Jollywatt/typst-wordometer>
- Registry source: <https://github.com/typst/packages/tree/1491a1e60c4ec8bcef8d598f1f501712f643fb23/packages/preview/wordometer/0.1.5>
- Pinned registry commit: `1491a1e60c4ec8bcef8d598f1f501712f643fb23`
- Licence: MIT
- Vendored files: `src/exports.typ` as `exports.typ`, `src/lib.typ` as
  `lib.typ`, and `LICENSE`

The files are unmodified. `SHA256SUMS` records their upstream bytes. Docstyle
vendors them so PDF rendering does not require a network connection or a warm
Typst package cache.
```

- [ ] **Step 5: Replace registry imports and the external icon font**

In `_extensions/docstyle/preprint/typst/typst-template.typ`, replace:

```typst
#import "@preview/fontawesome:0.5.0": *
#import "@preview/wordometer:0.1.5": total-words, word-count
```

with:

```typst
#import "_extensions/docstyle/preprint/vendor/wordometer-0.1.5/exports.typ": total-words, word-count

#let docstyle-orcid-mark(fill: rgb("a6ce39"), size: 0.8em) = {
  h(0.2em)
  text(fill: fill, size: size, weight: "bold")[ORCID]
}
```

Replace the only `fa-orcid` call:

```typst
parts.push(link(a.orcid, docstyle-orcid-mark(fill: rgb("a6ce39"), size: 0.8em)))
```

The visible word `ORCID` is accessible without an icon font and remains
inside the existing ORCID link.

- [ ] **Step 6: Run the focused and existing Typst tests**

Run:

```bash
Rscript -e 'devtools::load_all(quiet = TRUE); testthat::test_file("tests/testthat/test-typst-offline-assets.R")'
Rscript -e 'devtools::load_all(quiet = TRUE); testthat::test_file("tests/testthat/test-medrxiv-flag.R")'
```

Expected: the offline-asset tests pass with an empty home and blocked proxy,
and the existing medRxiv tests remain green.

- [ ] **Step 7: Commit**

```bash
git add _extensions/docstyle/preprint/typst/typst-template.typ _extensions/docstyle/preprint/vendor/wordometer-0.1.5 tests/testthat/test-typst-offline-assets.R
git commit -m "Make legacy Typst rendering self-contained"
```

---

### Task 1: Define and validate the fixture catalogue contract

**Files:**
- Create: `dev/vnext/characterization/catalog.R`
- Create: `tests/testthat/test-vnext-fixture-catalog.R`

**Interfaces:**
- Produces: `read_fixture_catalog(path, check_files = TRUE) -> list`
- Produces: `validate_fixture_catalog(catalog, root, check_files = TRUE) -> invisible(TRUE)`
- Consumed by: Tasks 2, 3, 7 and 8

- [ ] **Step 1: Write the failing catalogue tests**

Create `tests/testthat/test-vnext-fixture-catalog.R`:

```r
source(testthat::test_path(
  "../../dev/vnext/characterization/catalog.R"
))

valid_catalog <- function() {
  list(
    schemaVersion = 1L,
    fixtures = list(list(
      id = "example-fixture",
      description = "A compact example.",
      origin = list(
        repository = "https://example.org/repository",
        path = "paper/protocol.qmd",
        sourceLicence = "CC BY 4.0",
        fixtureLicence = "CC BY 4.0"
      ),
      sourceDir = "example-fixture/source",
      document = "protocol.qmd",
      formats = c("docstyle-docx", "docstyle-typst"),
      features = c("abstract", "table"),
      visualPages = c(1L)
    ))
  )
}

test_that("fixture catalogue accepts the version 1 contract", {
  expect_true(validate_fixture_catalog(
    valid_catalog(),
    root = tempdir(),
    check_files = FALSE
  ))
})

test_that("fixture catalogue rejects duplicate fixture identifiers", {
  catalog <- valid_catalog()
  catalog$fixtures[[2]] <- catalog$fixtures[[1]]
  expect_error(
    validate_fixture_catalog(catalog, tempdir(), check_files = FALSE),
    "fixture ids must be unique"
  )
})

test_that("fixture catalogue rejects unsupported formats", {
  catalog <- valid_catalog()
  catalog$fixtures[[1]]$formats <- "html"
  expect_error(
    validate_fixture_catalog(catalog, tempdir(), check_files = FALSE),
    "unsupported format"
  )
})

test_that("fixture catalogue checks source files when requested", {
  expect_error(
    validate_fixture_catalog(valid_catalog(), tempdir(), check_files = TRUE),
    "source directory does not exist"
  )
})
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
Rscript -e 'devtools::load_all(quiet = TRUE); testthat::test_file("tests/testthat/test-vnext-fixture-catalog.R")'
```

Expected: FAIL because `dev/vnext/characterization/catalog.R` does not exist.

- [ ] **Step 3: Implement the catalogue contract**

Create `dev/vnext/characterization/catalog.R`:

```r
characterization_required_fields <- c(
  "id", "description", "origin", "sourceDir", "document",
  "formats", "features", "visualPages"
)

characterization_formats <- c(
  "docstyle-docx", "docstyle-typst", "docstyle-jats"
)

validate_fixture_catalog <- function(catalog, root, check_files = TRUE) {
  if (!identical(as.integer(catalog$schemaVersion), 1L)) {
    stop("catalogue schemaVersion must be 1", call. = FALSE)
  }
  if (!is.list(catalog$fixtures) || length(catalog$fixtures) < 1L) {
    stop("catalogue fixtures must be a non-empty list", call. = FALSE)
  }

  ids <- vapply(catalog$fixtures, function(fixture) {
    missing <- setdiff(characterization_required_fields, names(fixture))
    if (length(missing) > 0L) {
      stop(
        "fixture is missing fields: ",
        paste(missing, collapse = ", "),
        call. = FALSE
      )
    }
    formats <- as.character(unlist(fixture$formats, use.names = FALSE))
    if (!all(formats %in% characterization_formats)) {
      stop(
        "fixture contains unsupported format: ",
        paste(setdiff(formats, characterization_formats),
              collapse = ", "),
        call. = FALSE
      )
    }
    if (!all(c(
      "repository", "path", "sourceLicence", "fixtureLicence"
    ) %in%
             names(fixture$origin))) {
      stop("fixture origin is incomplete", call. = FALSE)
    }
    if (check_files) {
      source_dir <- file.path(root, fixture$sourceDir)
      if (!dir.exists(source_dir)) {
        stop(
          "source directory does not exist: ", fixture$sourceDir,
          call. = FALSE
        )
      }
      document <- file.path(source_dir, fixture$document)
      if (!file.exists(document)) {
        stop(
          "fixture document does not exist: ", fixture$document,
          call. = FALSE
        )
      }
    }
    as.character(fixture$id)
  }, character(1))

  if (anyDuplicated(ids)) {
    stop("fixture ids must be unique", call. = FALSE)
  }
  invisible(TRUE)
}

read_fixture_catalog <- function(
  path = "tests/vnext/fixtures/catalog.json",
  check_files = TRUE
) {
  if (!file.exists(path)) {
    stop("fixture catalogue does not exist: ", path, call. = FALSE)
  }
  catalog <- jsonlite::read_json(path, simplifyVector = FALSE)
  validate_fixture_catalog(
    catalog,
    root = dirname(path),
    check_files = check_files
  )
  catalog
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```bash
Rscript -e 'devtools::load_all(quiet = TRUE); testthat::test_file("tests/testthat/test-vnext-fixture-catalog.R")'
```

Expected: four tests pass.

- [ ] **Step 5: Commit**

```bash
git add dev/vnext/characterization/catalog.R tests/testthat/test-vnext-fixture-catalog.R
git commit -m "Add vNext fixture catalogue contract"
```

---

### Task 2: Add compact, licensed and offline fixtures

**Files:**
- Create: `tests/vnext/fixtures/catalog.json`
- Create: an identical `source/assets/` directory in each of the three fixture projects
- Create: three fixture source directories and three `expectations.json` files listed in the file structure
- Modify: `tests/testthat/test-vnext-fixture-catalog.R`

**Interfaces:**
- Produces: three self-contained source projects described by `catalog.json`
- Produces: `expectations.json` records with `status`, `feature`, `format`, `evidence` and `reference`
- Consumed by: Tasks 3, 7 and 8

- [ ] **Step 1: Add a failing repository-catalogue test**

Append to `tests/testthat/test-vnext-fixture-catalog.R`:

```r
test_that("repository fixture catalogue resolves all three projects", {
  catalog_path <- testthat::test_path("../vnext/fixtures/catalog.json")
  catalog <- read_fixture_catalog(catalog_path, check_files = TRUE)
  ids <- vapply(catalog$fixtures, function(x) x$id, character(1))

  expect_setequal(
    ids,
    c("demport-protocol", "popcorn-protocol", "independent-manuscript")
  )
  expect_true(all(vapply(
    catalog$fixtures,
    function(x) length(x$features) >= 5L,
    logical(1)
  )))
})
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
Rscript -e 'devtools::load_all(quiet = TRUE); testthat::test_file("tests/testthat/test-vnext-fixture-catalog.R")'
```

Expected: FAIL because `tests/vnext/fixtures/catalog.json` does not exist.

- [ ] **Step 3: Create the fixture catalogue**

Create `tests/vnext/fixtures/catalog.json`:

```json
{
  "schemaVersion": 1,
  "fixtures": [
    {
      "id": "demport-protocol",
      "description": "Reduced prediction-protocol fixture with structured abstract, many authors, citations, tables and a landscape section.",
      "origin": {
        "repository": "https://github.com/Big-Life-Lab/DemPoRT-V2-dev",
        "path": "papers/protocol/demport-v2-protocol.qmd",
        "sourceLicence": "Not declared",
        "fixtureLicence": "MIT; synthetic prose and reduced structure"
      },
      "sourceDir": "demport-protocol/source",
      "document": "protocol.qmd",
      "formats": ["docstyle-docx", "docstyle-typst"],
      "features": [
        "structured-abstract",
        "author-affiliations",
        "inline-metadata",
        "citations",
        "semantic-table",
        "landscape-section"
      ],
      "visualPages": [1, 2]
    },
    {
      "id": "popcorn-protocol",
      "description": "Reduced scoping-review protocol with author plate, version history, line-numbered sections and parallel JATS output.",
      "origin": {
        "repository": "https://github.com/Big-Life-Lab/popcorn-review",
        "path": "reports/scoping-review-protocol/POPCORN_scoping_protocol.qmd",
        "sourceLicence": "CC BY 4.0",
        "fixtureLicence": "CC BY 4.0"
      },
      "sourceDir": "popcorn-protocol/source",
      "document": "protocol.qmd",
      "formats": ["docstyle-docx", "docstyle-typst", "docstyle-jats"],
      "features": [
        "structured-abstract",
        "author-plate",
        "version-history",
        "inline-metadata",
        "line-numbered-section",
        "jats"
      ],
      "visualPages": [1, 2]
    },
    {
      "id": "independent-manuscript",
      "description": "Synthetic manuscript designed independently of DemPoRT and POPCORN with nested lists, a figure, footnote, equation and mixed page geometry.",
      "origin": {
        "repository": "https://github.com/DougManuel/docstyle",
        "path": "tests/vnext/fixtures/independent-manuscript/source/manuscript.qmd",
        "sourceLicence": "MIT",
        "fixtureLicence": "MIT"
      },
      "sourceDir": "independent-manuscript/source",
      "document": "manuscript.qmd",
      "formats": ["docstyle-docx", "docstyle-typst", "docstyle-jats"],
      "features": [
        "nested-lists",
        "semantic-table",
        "accessible-figure",
        "footnote",
        "equation",
        "landscape-section"
      ],
      "visualPages": [1, 2]
    }
  ]
}
```

- [ ] **Step 4: Create deterministic project-local assets**

Write each asset below to `source/assets/` in all three fixture projects.
The small duplication is intentional: Typst rejects bibliography, CSL and
image paths outside the Quarto project root.

Create `source/assets/fixture.css` in each fixture:

```css
@page {
  size: letter;
  margin: 0.85in;
}

@page landscape {
  size: letter landscape;
  margin: 0.6in;
}

body {
  font-family: "Arial", sans-serif;
  font-size: 10pt;
  line-height: 1.25;
  color: #111111;
}

h1 {
  font-family: "Arial", sans-serif;
  font-size: 15pt;
  font-weight: bold;
  color: #1f4e79;
}

h2 {
  font-family: "Arial", sans-serif;
  font-size: 12pt;
  font-weight: bold;
  color: #1f4e79;
}

.abstract {
  font-size: 9pt;
  margin-bottom: 6pt;
}

table {
  font-size: 9pt;
  border-collapse: collapse;
}
```

Create `source/assets/references.bib` in each fixture:

```bibtex
@article{fixture2024,
  author = {Researcher, Alex and Partner, Morgan},
  title = {A synthetic reference for document testing},
  journal = {Journal of Reproducible Fixtures},
  year = {2024},
  volume = {1},
  pages = {1--8},
  doi = {10.5555/docstyle.fixture.2024}
}

@report{fixture2025,
  author = {{Open Methods Group}},
  title = {Portable scientific documents},
  institution = {Open Methods Group},
  year = {2025},
  url = {https://example.org/portable-documents}
}
```

Create `source/assets/fixture.csl` in each fixture:

```xml
<?xml version="1.0" encoding="utf-8"?>
<style xmlns="http://purl.org/net/xbiblio/csl" version="1.0"
       class="in-text" default-locale="en-CA">
  <info>
    <title>Docstyle fixture numeric style</title>
    <id>https://example.org/styles/docstyle-fixture</id>
    <link href="https://example.org/styles/docstyle-fixture" rel="self"/>
    <updated>2026-07-13T00:00:00+00:00</updated>
  </info>
  <citation collapse="citation-number">
    <layout prefix="[" suffix="]" delimiter=",">
      <text variable="citation-number"/>
    </layout>
  </citation>
  <bibliography et-al-min="7" et-al-use-first="3">
    <layout suffix=".">
      <text variable="citation-number" suffix=". "/>
      <names variable="author" suffix=". ">
        <name initialize-with=" " delimiter=", "/>
      </names>
      <text variable="title"/>
      <date variable="issued" prefix=". ">
        <date-part name="year"/>
      </date>
    </layout>
  </bibliography>
</style>
```

Create `source/assets/diagram.svg` in each fixture:

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="600" height="180"
     viewBox="0 0 600 180" role="img"
     aria-labelledby="title description">
  <title id="title">Three-step document workflow</title>
  <desc id="description">Source flows to semantic model and then output.</desc>
  <rect x="20" y="55" width="150" height="70" fill="#d9eaf7"/>
  <rect x="225" y="55" width="150" height="70" fill="#d9ead3"/>
  <rect x="430" y="55" width="150" height="70" fill="#fce5cd"/>
  <path d="M170 90 H225 M375 90 H430" stroke="#222" stroke-width="4"/>
  <text x="95" y="96" text-anchor="middle" font-family="Arial">Source</text>
  <text x="300" y="96" text-anchor="middle" font-family="Arial">Model</text>
  <text x="505" y="96" text-anchor="middle" font-family="Arial">Output</text>
</svg>
```

- [ ] **Step 5: Create the three reduced source projects**

For each fixture, create `source/_quarto.yml` with this common project block and the format block stated below:

```yaml
project:
  type: default
  output-dir: output
  pre-render: _extensions/docstyle/generate-reference.R
  post-render: _extensions/docstyle/update-field-codes.R

bibliography: assets/references.bib
csl: assets/fixture.csl

docstyle:
  css: assets/fixture.css
  footer:
    enabled: true
    right: "Page {page}"
```

For `demport-protocol/source/_quarto.yml`, append:

```yaml
format:
  docstyle-docx:
    toc: true
    number-sections: true
  docstyle-typst:
    medrxiv: true
    toc: false
    number-sections: true
```

For `popcorn-protocol/source/_quarto.yml`, append:

```yaml
format:
  docstyle-docx:
    toc: false
  docstyle-typst:
    medrxiv: true
    line-number: true
  docstyle-jats:
    citeproc: true
```

For `independent-manuscript/source/_quarto.yml`, append:

```yaml
format:
  docstyle-docx:
    toc: true
  docstyle-typst:
    toc: true
  docstyle-jats:
    citeproc: true
```

Create `demport-protocol/source/protocol.qmd`:

```qmd
---
title: "Prediction Model Protocol Fixture"
short-title: "Prediction protocol"
version: "0.1"
date: 2026-07-13
author:
  - name: Researcher One
    affiliations: [{ref: centre}]
  - name: Researcher Two
    affiliations: [{ref: centre}, {ref: institute}]
affiliations:
  - id: centre
    name: Population Health Centre
  - id: institute
    name: Open Methods Institute
abstract: |
  **Background:** This synthetic protocol represents a prediction study.

  **Methods:** The fixture exercises metadata, tables and section geometry.
keywords: [prediction, protocol, reproducibility]
---

Protocol version {{< meta version >}}

::: docstyle-abstract
:::

# Background

The study develops a prediction model using reproducible methods
[@fixture2024].

# Methods

The analysis includes:

1. prespecified predictors;
2. internal validation; and
3. calibration assessment.

| Construct | Representation | Policy |
|---|---|---|
| Age | Continuous | Authored |
| Outcome | Time to event | Authored |

::: section-landscape
:::

## Wide analysis table

| Model | Development | Validation | Calibration | Reporting |
|---|---|---|---|---|
| Base | Full cohort | Bootstrap | Flexible curve | Full equation |

::: section-default
:::

# References

::: {#refs}
:::
```

Create `popcorn-protocol/source/protocol.qmd`:

```qmd
---
title: "Scoping Review Protocol Fixture"
version-summary:
  version: "0.2"
  date: "2026-07-13"
version-history:
  - version: "0.1"
    date: "2026-06-01"
    description: "Initial fixture."
  - version: "0.2"
    date: "2026-07-13"
    description: "Added structured metadata."
author:
  - name: Review Author
    affiliations: [{ref: network}]
    roles: [conceptualization, methodology]
affiliations:
  - id: network
    name: Open Review Network
abstract: |
  **Introduction:** Reporting varies across modelling studies.

  **Methods:** This synthetic review uses a structured protocol.

  **Dissemination:** Outputs will be openly available.
keywords: [scoping review, reporting guideline, modelling]
---

[{{< meta version-summary.date >}}]{.date} |
Version: [{{< meta version-summary.version >}}]{.version}

::: author-plate
:::

::: {.section-body line-numbers="continuous"}

# Introduction

The protocol examines transparent reporting [@fixture2025].

# Eligibility

- Population models
  - Cohort models
  - Microsimulation models
- Applied policy questions

:::

# Version history

::: version-history
:::

# References

::: {#refs}
:::
```

Create `independent-manuscript/source/manuscript.qmd`:

```qmd
---
title: "Independent Scientific Manuscript Fixture"
author: Independent Author
date: 2026-07-13
abstract: |
  This synthetic manuscript tests structures not selected from either
  project fixture.
---

# Introduction

The workflow has three parts (Figure @fig-workflow).[^note]

![Source, semantic model and output](assets/diagram.svg){#fig-workflow fig-alt="Source flows to semantic model and then output."}

[^note]: This footnote verifies note preservation.

# Structured content

1. First stage
   - Authored content
   - Typed metadata
2. Second stage
   1. DOCX output
   2. PDF output

| Object | Identifier | Editable |
|---|---|---|
| Abstract | region:abstract | Yes |
| Version | metadata:version | Yes |

The model includes the expression

$$
R(t) = 1 - exp(-H(t)).
$$

::: section-landscape
:::

## Landscape content

| Property | DOCX | PDF | JATS | Expected |
|---|---|---|---|---|
| Heading | Native | Native | Native | Preserved |
| Margin | Section | Page | Omitted | Reported |

::: section-default
:::

# References

The approach follows a synthetic reference [@fixture2024].

::: {#refs}
:::
```

- [ ] **Step 6: Declare observed and unsupported legacy behaviour**

Create each `expectations.json` with the same versioned envelope:

```json
{
  "schemaVersion": 1,
  "fixture": "demport-protocol",
  "expectations": [
    {
      "feature": "structured-abstract",
      "format": "docstyle-docx",
      "status": "observed",
      "evidence": "DOCSTYLE abstract field and Abstract paragraphs",
      "reference": "legacy v0.19.0"
    },
    {
      "feature": "section-geometry",
      "format": "docstyle-docx",
      "status": "known-bug",
      "evidence": "Legacy section geometry may be assigned to the preceding section.",
      "reference": "GitHub issue #18"
    },
    {
      "feature": "cross-format-page-size",
      "format": "docstyle-typst",
      "status": "approximated",
      "evidence": "Legacy Typst uses the preprint template page size rather than the CSS @page size.",
      "reference": "vNext work packages 3 and 6"
    },
    {
      "feature": "picos-profile",
      "format": "all",
      "status": "unsupported",
      "evidence": "The legacy engine has no domain metadata profile contract.",
      "reference": "vNext work package 1"
    },
    {
      "feature": "embedded-metadata-envelope",
      "format": "docstyle-typst",
      "status": "unsupported",
      "evidence": "The legacy PDF has no attached Docstyle metadata envelope.",
      "reference": "vNext work package 6"
    }
  ]
}
```

Create `popcorn-protocol/expectations.json`:

```json
{
  "schemaVersion": 1,
  "fixture": "popcorn-protocol",
  "expectations": [
    {
      "feature": "author-plate",
      "format": "docstyle-docx",
      "status": "observed",
      "evidence": "DOCSTYLE author-plate field wraps visible content.",
      "reference": "legacy v0.19.0"
    },
    {
      "feature": "version-history",
      "format": "docstyle-docx",
      "status": "observed",
      "evidence": "Generated version-history field and table are present.",
      "reference": "legacy v0.19.0"
    },
    {
      "feature": "structured-abstract",
      "format": "docstyle-jats",
      "status": "observed",
      "evidence": "The JATS front matter contains an abstract.",
      "reference": "legacy v0.19.0"
    },
    {
      "feature": "cross-format-visual-correspondence",
      "format": "docstyle-docx,docstyle-typst",
      "status": "approximated",
      "evidence": "Legacy backends share some source styles but no property matrix.",
      "reference": "vNext work packages 3 and 6"
    }
  ]
}
```

Create `independent-manuscript/expectations.json`:

```json
{
  "schemaVersion": 1,
  "fixture": "independent-manuscript",
  "expectations": [
    {
      "feature": "semantic-lists-and-tables",
      "format": "all",
      "status": "observed",
      "evidence": "Lists and tables are emitted as native backend structures.",
      "reference": "legacy v0.19.0"
    },
    {
      "feature": "nested-field-ranges",
      "format": "docstyle-docx",
      "status": "known-bug",
      "evidence": "Flat range precedence can mis-handle nested generated regions.",
      "reference": "GitHub issue #19"
    },
    {
      "feature": "independent-validation",
      "format": "docstyle-docx",
      "status": "known-bug",
      "evidence": "The legacy validator can pass when harvest loses a table.",
      "reference": "GitHub issue #20"
    }
  ]
}
```

- [ ] **Step 7: Run the catalogue test**

Run:

```bash
Rscript -e 'devtools::load_all(quiet = TRUE); testthat::test_file("tests/testthat/test-vnext-fixture-catalog.R")'
```

Expected: all catalogue tests pass and the repository catalogue contains exactly three fixture identifiers.

- [ ] **Step 8: Commit**

```bash
git add tests/vnext/fixtures tests/testthat/test-vnext-fixture-catalog.R
git commit -m "Add compact vNext characterization fixtures"
```

---

### Task 3: Build the isolated legacy-render harness

**Files:**
- Create: `dev/vnext/characterization/render-legacy.R`
- Create: `tests/testthat/test-vnext-legacy-render.R`

**Interfaces:**
- Consumes: one fixture record from `read_fixture_catalog()`
- Produces: `render_legacy_fixture(fixture, format, catalog_root, repo_root, work_root, quarto_bin = "quarto") -> list(path, format, log)`
- Consumed by: Task 7

- [ ] **Step 1: Write the failing render-harness test**

Create `tests/testthat/test-vnext-legacy-render.R`:

```r
source(testthat::test_path(
  "../../dev/vnext/characterization/render-legacy.R"
))

make_fake_quarto <- function(path) {
  writeLines(c(
    "#!/bin/sh",
    "format=''",
    "while [ \"$#\" -gt 0 ]; do",
    "  if [ \"$1\" = '--to' ]; then format=\"$2\"; shift 2; else shift; fi",
    "done",
    "case \"$format\" in",
    "  docstyle-docx) extension='docx' ;;",
    "  docstyle-typst) extension='pdf' ;;",
    "  docstyle-jats) extension='xml' ;;",
    "  *) exit 64 ;;",
    "esac",
    "mkdir -p output",
    ": > output/protocol.$extension",
    "printf '%s\\n' \"$format\""
  ), path)
  Sys.chmod(path, mode = "0755")
  path
}

test_that("legacy renderer stages the fixture and selected format", {
  root <- tempfile("render-root-")
  dir.create(file.path(root, "fixtures", "example", "source"),
             recursive = TRUE)
  dir.create(file.path(root, "repo", "_extensions", "docstyle"),
             recursive = TRUE)
  writeLines("# fixture", file.path(
    root, "fixtures", "example", "source", "protocol.qmd"
  ))
  writeLines("title: extension", file.path(
    root, "repo", "_extensions", "docstyle", "_extension.yml"
  ))
  fake_quarto <- make_fake_quarto(file.path(root, "quarto"))

  fixture <- list(
    id = "example",
    sourceDir = "example/source",
    document = "protocol.qmd"
  )
  result <- render_legacy_fixture(
    fixture = fixture,
    format = "docstyle-docx",
    catalog_root = file.path(root, "fixtures"),
    repo_root = file.path(root, "repo"),
    work_root = file.path(root, "work"),
    quarto_bin = fake_quarto
  )

  expect_true(file.exists(result$path))
  expect_equal(tools::file_ext(result$path), "docx")
  expect_equal(result$format, "docstyle-docx")
  expect_match(paste(result$log, collapse = "\n"), "docstyle-docx")
})

test_that("legacy renderer rejects undeclared formats", {
  expect_error(
    legacy_output_extension("html"),
    "unsupported characterization format"
  )
})
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
Rscript -e 'devtools::load_all(quiet = TRUE); testthat::test_file("tests/testthat/test-vnext-legacy-render.R")'
```

Expected: FAIL because `render-legacy.R` does not exist.

- [ ] **Step 3: Implement staging and rendering**

Create `dev/vnext/characterization/render-legacy.R`:

```r
copy_characterization_tree <- function(from, to) {
  if (!dir.exists(from)) {
    stop("source tree does not exist: ", from, call. = FALSE)
  }
  dir.create(to, recursive = TRUE, showWarnings = FALSE)
  entries <- list.files(
    from,
    recursive = TRUE,
    all.files = TRUE,
    no.. = TRUE,
    include.dirs = TRUE
  )
  if (length(entries) == 0L) {
    return(invisible(to))
  }
  source_paths <- file.path(from, entries)
  info <- file.info(source_paths)

  directories <- entries[!is.na(info$isdir) & info$isdir]
  for (entry in directories) {
    dir.create(file.path(to, entry), recursive = TRUE, showWarnings = FALSE)
  }
  files <- entries[is.na(info$isdir) | !info$isdir]
  for (entry in files) {
    destination <- file.path(to, entry)
    dir.create(dirname(destination), recursive = TRUE, showWarnings = FALSE)
    if (!file.copy(file.path(from, entry), destination, overwrite = TRUE)) {
      stop("failed to copy fixture entry: ", entry, call. = FALSE)
    }
  }
  invisible(to)
}

legacy_output_extension <- function(format) {
  extensions <- c(
    "docstyle-docx" = "docx",
    "docstyle-typst" = "pdf",
    "docstyle-jats" = "xml"
  )
  value <- unname(extensions[[format]])
  if (is.null(value)) {
    stop(
      "unsupported characterization format: ", format,
      call. = FALSE
    )
  }
  value
}

render_legacy_fixture <- function(
  fixture,
  format,
  catalog_root,
  repo_root,
  work_root,
  quarto_bin = "quarto"
) {
  extension <- legacy_output_extension(format)
  if (dir.exists(work_root)) {
    unlink(work_root, recursive = TRUE, force = TRUE)
  }
  dir.create(work_root, recursive = TRUE)

  staged_catalog <- file.path(work_root, "fixtures")
  copy_characterization_tree(catalog_root, staged_catalog)
  project_dir <- file.path(staged_catalog, fixture$sourceDir)
  extension_dir <- file.path(project_dir, "_extensions", "docstyle")
  copy_characterization_tree(
    file.path(repo_root, "_extensions", "docstyle"),
    extension_dir
  )

  log <- withr::with_dir(project_dir, {
    output <- system2(
      quarto_bin,
      c("render", fixture$document, "--to", format),
      stdout = TRUE,
      stderr = TRUE
    )
    status <- attr(output, "status")
    if (!is.null(status) && status != 0L) {
      stop(
        "legacy render failed for ", fixture$id, " (", format, "):\n",
        paste(output, collapse = "\n"),
        call. = FALSE
      )
    }
    output
  })

  candidates <- list.files(
    file.path(project_dir, "output"),
    pattern = paste0("\\.", extension, "$"),
    full.names = TRUE,
    recursive = TRUE
  )
  if (length(candidates) != 1L) {
    stop(
      "expected one ", extension, " output for ", fixture$id,
      "; found ", length(candidates),
      call. = FALSE
    )
  }
  list(
    path = normalizePath(candidates[[1]], mustWork = TRUE),
    format = format,
    log = unname(log)
  )
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```bash
Rscript -e 'devtools::load_all(quiet = TRUE); testthat::test_file("tests/testthat/test-vnext-legacy-render.R")'
```

Expected: two tests pass.

- [ ] **Step 5: Commit**

```bash
git add dev/vnext/characterization/render-legacy.R tests/testthat/test-vnext-legacy-render.R
git commit -m "Add isolated legacy fixture renderer"
```

---

### Task 4: Create the normalized DOCX inventory

**Files:**
- Create: `dev/vnext/characterization/inspect-docx.R`
- Create: `tests/testthat/test-vnext-docx-inventory.R`

**Interfaces:**
- Produces: `inspect_legacy_docx(path) -> list` with `schemaVersion = 1`
- Produces: `extract_docx_field_instructions(document) -> character()`
- Consumed by: Task 7

- [ ] **Step 1: Write the failing DOCX inventory tests**

Create `tests/testthat/test-vnext-docx-inventory.R`:

```r
source(testthat::test_path(
  "../../dev/vnext/characterization/inspect-docx.R"
))

test_that("DOCX inventory describes package and semantic structures", {
  path <- testthat::test_path(
    "../../inst/extdata/minimal-example/minimal-example.docx"
  )
  inventory <- inspect_legacy_docx(path)

  expect_identical(inventory$schemaVersion, 1L)
  expect_true("word/document.xml" %in% inventory$packageParts)
  expect_gt(inventory$counts$paragraphs, 10L)
  expect_gt(inventory$counts$tables, 0L)
  expect_gt(inventory$counts$sections, 0L)
  expect_gt(inventory$fields$total, 0L)
  expect_match(inventory$textHash, "^sha256:[0-9a-f]{64}$")
  expect_false(any(grepl(tempdir(), unlist(inventory), fixed = TRUE)))
})

test_that("field classifier distinguishes Zotero and DOCSTYLE fields", {
  expect_equal(
    classify_docx_field("ADDIN ZOTERO_ITEM CSL_CITATION {}"),
    "zotero-citation"
  )
  expect_equal(
    classify_docx_field('ADDIN DOCSTYLE {"type":"div"}'),
    "docstyle"
  )
  expect_equal(
    classify_docx_field("ADDIN ZOTERO_PREF {}"),
    "zotero-preferences"
  )
  expect_equal(classify_docx_field("PAGE"), "page")
})

test_that("DOCX inventory records comments and tracked revisions", {
  path <- testthat::test_path(
    "../../inst/extdata/minimal-example/comments-revisions-test-roundtrip.docx"
  )
  inventory <- inspect_legacy_docx(path)

  expect_gt(inventory$counts$comments, 0L)
  expect_gt(inventory$counts$insertions, 0L)
  expect_gt(inventory$counts$deletions, 0L)
  expect_true("word/comments.xml" %in% inventory$packageParts)
})
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
Rscript -e 'devtools::load_all(quiet = TRUE); testthat::test_file("tests/testthat/test-vnext-docx-inventory.R")'
```

Expected: FAIL because `inspect-docx.R` does not exist.

- [ ] **Step 3: Implement field extraction and deterministic inventory**

Create `dev/vnext/characterization/inspect-docx.R`:

```r
characterization_w_ns <- c(
  w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
)

characterization_sha256 <- function(value) {
  paste0(
    "sha256:",
    digest::digest(value, algo = "sha256", serialize = FALSE)
  )
}

classify_docx_field <- function(instruction) {
  normalized <- toupper(trimws(instruction))
  if (startsWith(normalized, "ADDIN ZOTERO_ITEM")) {
    return("zotero-citation")
  }
  if (startsWith(normalized, "ADDIN ZOTERO_BIBL")) {
    return("zotero-bibliography")
  }
  if (startsWith(normalized, "ADDIN ZOTERO_PREF")) {
    return("zotero-preferences")
  }
  if (startsWith(normalized, "ADDIN DOCSTYLE")) {
    return("docstyle")
  }
  if (startsWith(normalized, "TOC")) {
    return("toc")
  }
  if (startsWith(normalized, "NUMPAGES")) {
    return("num-pages")
  }
  if (startsWith(normalized, "SECTIONPAGES")) {
    return("section-pages")
  }
  if (startsWith(normalized, "PAGE")) {
    return("page")
  }
  if (startsWith(normalized, "HYPERLINK")) {
    return("hyperlink")
  }
  "other"
}

extract_docx_field_instructions <- function(document) {
  nodes <- xml2::xml_find_all(
    document,
    ".//w:fldChar | .//w:instrText",
    ns = characterization_w_ns
  )
  stack <- list()
  instructions <- character()

  for (node in nodes) {
    if (identical(xml2::xml_name(node), "fldChar")) {
      field_type <- xml2::xml_attr(
        node,
        "fldCharType"
      )
      if (identical(field_type, "begin")) {
        stack[[length(stack) + 1L]] <- list(
          capture = TRUE,
          parts = character()
        )
      } else if (identical(field_type, "separate") &&
                 length(stack) > 0L) {
        stack[[length(stack)]]$capture <- FALSE
      } else if (identical(field_type, "end") &&
                 length(stack) > 0L) {
        current <- stack[[length(stack)]]
        instruction <- trimws(paste0(current$parts, collapse = ""))
        if (nzchar(instruction)) {
          instructions <- c(instructions, instruction)
        }
        stack <- stack[-length(stack)]
      }
    } else if (length(stack) > 0L &&
               isTRUE(stack[[length(stack)]]$capture)) {
      index <- length(stack)
      stack[[index]]$parts <- c(
        stack[[index]]$parts,
        xml2::xml_text(node)
      )
    }
  }
  instructions
}

docx_section_record <- function(section) {
  page_size <- xml2::xml_find_first(
    section, "./w:pgSz", ns = characterization_w_ns
  )
  margins <- xml2::xml_find_first(
    section, "./w:pgMar", ns = characterization_w_ns
  )
  line_numbers <- xml2::xml_find_first(
    section, "./w:lnNumType", ns = characterization_w_ns
  )
  value <- function(node, attribute) {
    result <- xml2::xml_attr(node, attribute)
    if (is.na(result)) NULL else unname(result)
  }
  list(
    width = value(page_size, "w"),
    height = value(page_size, "h"),
    orientation = value(page_size, "orient"),
    marginTop = value(margins, "top"),
    marginRight = value(margins, "right"),
    marginBottom = value(margins, "bottom"),
    marginLeft = value(margins, "left"),
    lineNumbering = value(line_numbers, "countBy")
  )
}

inspect_legacy_docx <- function(path) {
  if (!file.exists(path)) {
    stop("DOCX does not exist: ", path, call. = FALSE)
  }
  unpacked <- tempfile("docstyle-characterization-docx-")
  dir.create(unpacked)
  on.exit(unlink(unpacked, recursive = TRUE, force = TRUE), add = TRUE)
  utils::unzip(path, exdir = unpacked)

  document_path <- file.path(unpacked, "word", "document.xml")
  if (!file.exists(document_path)) {
    stop("DOCX lacks word/document.xml", call. = FALSE)
  }
  document <- xml2::read_xml(document_path)
  instructions <- extract_docx_field_instructions(document)
  field_types <- vapply(
    instructions,
    classify_docx_field,
    character(1)
  )
  field_counts <- as.list(as.integer(table(field_types)))
  names(field_counts) <- names(table(field_types))

  text_nodes <- xml2::xml_find_all(
    document,
    ".//w:t | .//w:delText",
    ns = characterization_w_ns
  )
  visible_text <- gsub(
    "[[:space:]]+",
    " ",
    trimws(paste(xml2::xml_text(text_nodes), collapse = " "))
  )
  sections <- xml2::xml_find_all(
    document, ".//w:sectPr", ns = characterization_w_ns
  )
  style_values <- xml2::xml_attr(
    xml2::xml_find_all(
      document, ".//w:pStyle", ns = characterization_w_ns
    ),
    "val"
  )
  package_parts <- sort(utils::unzip(path, list = TRUE)$Name)

  list(
    schemaVersion = 1L,
    artifact = "docx",
    packageParts = unname(package_parts),
    counts = list(
      paragraphs = length(xml2::xml_find_all(
        document, ".//w:p", ns = characterization_w_ns
      )),
      tables = length(xml2::xml_find_all(
        document, ".//w:tbl", ns = characterization_w_ns
      )),
      tableRows = length(xml2::xml_find_all(
        document, ".//w:tr", ns = characterization_w_ns
      )),
      tableCells = length(xml2::xml_find_all(
        document, ".//w:tc", ns = characterization_w_ns
      )),
      sections = length(sections),
      comments = length(xml2::xml_find_all(
        document, ".//w:commentRangeStart", ns = characterization_w_ns
      )),
      insertions = length(xml2::xml_find_all(
        document, ".//w:ins", ns = characterization_w_ns
      )),
      deletions = length(xml2::xml_find_all(
        document, ".//w:del", ns = characterization_w_ns
      ))
    ),
    fields = list(
      total = length(instructions),
      byType = field_counts,
      instructionHashes = unname(vapply(
        instructions,
        characterization_sha256,
        character(1)
      ))
    ),
    paragraphStyles = sort(unique(style_values[!is.na(style_values)])),
    sections = unname(lapply(sections, docx_section_record)),
    textHash = characterization_sha256(visible_text)
  )
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```bash
Rscript -e 'devtools::load_all(quiet = TRUE); testthat::test_file("tests/testthat/test-vnext-docx-inventory.R")'
```

Expected: three tests pass against the tracked minimal-example and
comments-and-revisions fixtures.

- [ ] **Step 5: Commit**

```bash
git add dev/vnext/characterization/inspect-docx.R tests/testthat/test-vnext-docx-inventory.R
git commit -m "Add normalized legacy DOCX inventory"
```

---

### Task 5: Create normalized PDF, JATS and page-image inventories

**Files:**
- Create: `dev/vnext/characterization/inspect-publication.R`
- Create: `tests/testthat/test-vnext-publication-inventory.R`

**Interfaces:**
- Produces: `inspect_legacy_pdf(path, pdfinfo_bin = "pdfinfo", pdftotext_bin = "pdftotext") -> list`
- Produces: `inspect_legacy_jats(path) -> list`
- Produces: `rasterize_pdf_pages(path, pages, output_dir, prefix, pdftoppm_bin = "pdftoppm", resolution = 110L) -> character()`
- Consumed by: Tasks 7 and later work package 6 comparisons

- [ ] **Step 1: Write the failing publication-inventory tests**

Create `tests/testthat/test-vnext-publication-inventory.R`:

```r
source(testthat::test_path(
  "../../dev/vnext/characterization/inspect-publication.R"
))

test_that("pdfinfo parser retains only stable publication properties", {
  parsed <- parse_characterization_pdfinfo(c(
    "Title:           Fixture title",
    "Pages:           12",
    "Page size:       612 x 792 pts (letter)",
    "Tagged:          yes",
    "Encrypted:       no",
    "PDF version:     1.7",
    "CreationDate:    Mon Jul 13 10:00:00 2026"
  ))

  expect_equal(parsed$title, "Fixture title")
  expect_identical(parsed$pages, 12L)
  expect_true(parsed$tagged)
  expect_false(parsed$encrypted)
  expect_equal(parsed$pageSize, "612 x 792 pts (letter)")
  expect_equal(parsed$pdfVersion, "1.7")
  expect_false("creationDate" %in% names(parsed))
})

test_that("JATS inventory records native scholarly structures", {
  path <- tempfile(fileext = ".xml")
  writeLines(c(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<article article-type="protocol">',
    '  <front><article-meta>',
    '    <title-group><article-title>Fixture</article-title></title-group>',
    '    <abstract><p>A structured abstract.</p></abstract>',
    '  </article-meta></front>',
    '  <body><sec id="s1"><title>Methods</title><p>Text.</p>',
    '    <table-wrap id="t1"><table><tbody><tr><td>A</td></tr></tbody></table></table-wrap>',
    '    <fig id="f1"><caption><p>Workflow.</p></caption></fig>',
    '  </sec></body>',
    '  <back><ref-list><ref id="r1"><mixed-citation>Reference.</mixed-citation></ref></ref-list></back>',
    '</article>'
  ), path)

  inventory <- inspect_legacy_jats(path)

  expect_identical(inventory$schemaVersion, 1L)
  expect_identical(inventory$counts$sections, 1L)
  expect_identical(inventory$counts$tables, 1L)
  expect_identical(inventory$counts$figures, 1L)
  expect_identical(inventory$counts$references, 1L)
  expect_match(inventory$abstractHash, "^sha256:[0-9a-f]{64}$")
  expect_match(inventory$textHash, "^sha256:[0-9a-f]{64}$")
})

make_fake_pdftoppm <- function(path) {
  writeLines(c(
    "#!/bin/sh",
    "prefix=''",
    "for argument in \"$@\"; do prefix=\"$argument\"; done",
    "printf '\\211PNG\\r\\n\\032\\n' > \"${prefix}.png\""
  ), path)
  Sys.chmod(path, mode = "0755")
  path
}

test_that("PDF rasterizer creates deterministically named selected pages", {
  root <- tempfile("publication-pages-")
  dir.create(root)
  pdf <- file.path(root, "fixture.pdf")
  file.create(pdf)
  fake_pdftoppm <- make_fake_pdftoppm(file.path(root, "pdftoppm"))

  pages <- rasterize_pdf_pages(
    path = pdf,
    pages = c(1L, 3L),
    output_dir = file.path(root, "pages"),
    prefix = "docstyle-typst",
    pdftoppm_bin = fake_pdftoppm
  )

  expect_equal(
    basename(pages),
    c("docstyle-typst-page-001.png", "docstyle-typst-page-003.png")
  )
  expect_true(all(file.exists(pages)))
})
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
Rscript -e 'devtools::load_all(quiet = TRUE); testthat::test_file("tests/testthat/test-vnext-publication-inventory.R")'
```

Expected: FAIL because `inspect-publication.R` does not exist.

- [ ] **Step 3: Implement the stable publication inventories**

Create `dev/vnext/characterization/inspect-publication.R`:

```r
`%||%` <- function(x, y) if (is.null(x)) y else x

publication_sha256 <- function(value) {
  paste0(
    "sha256:",
    digest::digest(value, algo = "sha256", serialize = FALSE)
  )
}

normalize_publication_text <- function(value) {
  gsub("[[:space:]]+", " ", trimws(paste(value, collapse = " ")))
}

run_characterization_command <- function(command, arguments, label) {
  output <- suppressWarnings(system2(
    command,
    arguments,
    stdout = TRUE,
    stderr = TRUE
  ))
  status <- attr(output, "status")
  if (!is.null(status) && status != 0L) {
    stop(
      label, " failed with status ", status, ":\n",
      paste(output, collapse = "\n"),
      call. = FALSE
    )
  }
  unname(output)
}

parse_characterization_pdfinfo <- function(lines) {
  matches <- regexec("^([^:]+):[[:space:]]*(.*)$", lines)
  fields <- regmatches(lines, matches)
  fields <- fields[lengths(fields) == 3L]
  keys <- vapply(fields, function(x) trimws(x[[2]]), character(1))
  values <- vapply(fields, function(x) trimws(x[[3]]), character(1))
  names(values) <- keys

  value_or_null <- function(key) {
    if (!key %in% names(values)) {
      return(NULL)
    }
    value <- unname(values[[key]])
    if (is.null(value) || !nzchar(value)) NULL else value
  }
  integer_or_null <- function(key) {
    value <- value_or_null(key)
    if (is.null(value)) NULL else as.integer(value)
  }
  yes <- function(key) {
    identical(tolower(value_or_null(key) %||% ""), "yes")
  }

  list(
    title = value_or_null("Title"),
    pages = integer_or_null("Pages"),
    pageSize = value_or_null("Page size"),
    tagged = yes("Tagged"),
    encrypted = yes("Encrypted"),
    pdfVersion = value_or_null("PDF version")
  )
}

inspect_legacy_pdf <- function(
  path,
  pdfinfo_bin = "pdfinfo",
  pdftotext_bin = "pdftotext"
) {
  if (!file.exists(path)) {
    stop("PDF does not exist: ", path, call. = FALSE)
  }
  info <- parse_characterization_pdfinfo(
    run_characterization_command(
      pdfinfo_bin,
      path,
      "pdfinfo"
    )
  )
  text_path <- tempfile(fileext = ".txt")
  on.exit(unlink(text_path, force = TRUE), add = TRUE)
  run_characterization_command(
    pdftotext_bin,
    c("-enc", "UTF-8", path, text_path),
    "pdftotext"
  )
  text <- if (file.exists(text_path)) {
    readLines(text_path, warn = FALSE, encoding = "UTF-8")
  } else {
    character()
  }

  c(
    list(schemaVersion = 1L, artifact = "pdf"),
    info,
    list(textHash = publication_sha256(normalize_publication_text(text)))
  )
}

inspect_legacy_jats <- function(path) {
  if (!file.exists(path)) {
    stop("JATS XML does not exist: ", path, call. = FALSE)
  }
  document <- xml2::read_xml(path)
  count <- function(xpath) {
    length(xml2::xml_find_all(document, xpath))
  }
  text_at <- function(xpath) {
    nodes <- xml2::xml_find_all(document, xpath)
    normalize_publication_text(xml2::xml_text(nodes))
  }

  list(
    schemaVersion = 1L,
    artifact = "jats",
    articleType = unname(xml2::xml_attr(
      xml2::xml_find_first(document, "/*[local-name()='article']"),
      "article-type"
    )),
    counts = list(
      sections = count("//*[local-name()='sec']"),
      paragraphs = count("//*[local-name()='p']"),
      tables = count("//*[local-name()='table-wrap']"),
      figures = count("//*[local-name()='fig']"),
      references = count("//*[local-name()='ref-list']/*[local-name()='ref']"),
      crossReferences = count("//*[local-name()='xref']")
    ),
    abstractHash = publication_sha256(
      text_at("//*[local-name()='abstract']")
    ),
    textHash = publication_sha256(
      text_at("/*[local-name()='article']")
    )
  )
}

rasterize_pdf_pages <- function(
  path,
  pages,
  output_dir,
  prefix,
  pdftoppm_bin = "pdftoppm",
  resolution = 110L
) {
  if (!file.exists(path)) {
    stop("PDF does not exist: ", path, call. = FALSE)
  }
  pages <- sort(unique(as.integer(pages)))
  if (length(pages) < 1L || any(is.na(pages)) || any(pages < 1L)) {
    stop("pages must contain positive integers", call. = FALSE)
  }
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

  outputs <- vapply(pages, function(page) {
    output <- file.path(
      output_dir,
      sprintf("%s-page-%03d", prefix, page)
    )
    run_characterization_command(
      pdftoppm_bin,
      c(
        "-f", page,
        "-l", page,
        "-r", as.integer(resolution),
        "-png",
        "-singlefile",
        path,
        output
      ),
      paste0("pdftoppm page ", page)
    )
    png <- paste0(output, ".png")
    if (!file.exists(png)) {
      stop("pdftoppm did not create: ", png, call. = FALSE)
    }
    normalizePath(png, mustWork = TRUE)
  }, character(1))
  unname(outputs)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```bash
Rscript -e 'devtools::load_all(quiet = TRUE); testthat::test_file("tests/testthat/test-vnext-publication-inventory.R")'
```

Expected: three tests pass without requiring installed Poppler because the
parsing and rasterization tests use synthetic input and a fake executable.

- [ ] **Step 5: Commit**

```bash
git add dev/vnext/characterization/inspect-publication.R tests/testthat/test-vnext-publication-inventory.R
git commit -m "Add PDF and JATS characterization inventories"
```

---

### Task 6: Freeze the supported legacy field-code and sidecar contract

**Files:**
- Create: `dev/vnext/characterization/legacy-contract.R`
- Create: `tests/vnext/fixtures/legacy-contract.json`
- Create: `tests/testthat/test-vnext-legacy-contract.R`

**Interfaces:**
- Produces: `characterize_legacy_contract(repo_root) -> list`
- Produces: `validate_legacy_contract(contract) -> invisible(TRUE)`
- Produces: `write_legacy_contract(repo_root, path) -> invisible(path)`
- Consumed by: Task 7 and work packages 1 and 8

- [ ] **Step 1: Write the failing legacy-contract tests**

Create `tests/testthat/test-vnext-legacy-contract.R`:

```r
source(testthat::test_path(
  "../../dev/vnext/characterization/legacy-contract.R"
))

test_that("legacy contract records field-code reader and writer versions", {
  repo_root <- normalizePath(testthat::test_path("../.."))
  contract <- characterize_legacy_contract(repo_root)

  expect_identical(contract$schemaVersion, 1L)
  expect_identical(contract$characterizedRelease, "0.19.0")
  expect_identical(contract$fieldCodes$writerVersion, 3L)
  expect_identical(
    unlist(contract$fieldCodes$readerVersions, use.names = FALSE),
    1:3
  )
  expect_setequal(
    unlist(contract$fieldCodes$payloadTypes, use.names = FALSE),
    c("char", "div", "list", "section", "table", "figure",
      "float", "anchor")
  )
})

test_that("legacy contract classifies every known JSON sidecar", {
  contract <- characterize_legacy_contract(
    normalizePath(testthat::test_path("../.."))
  )
  names <- vapply(contract$sidecars, function(x) x$name, character(1))

  expect_setequal(names, c(
    "field-codes.json", "comments.json", "revisions.json",
    "references.json", "page-config.json", "style-map.json",
    "section-map.json", "harvest-map.json", "figures.json",
    "styles.json"
  ))
  expect_true(all(vapply(
    contract$sidecars,
    function(x) identical(x$versioning, "unversioned"),
    logical(1)
  )))
  expect_true(validate_legacy_contract(contract))
})

test_that("committed legacy contract matches the characterized release", {
  path <- testthat::test_path("../vnext/fixtures/legacy-contract.json")
  expect_true(file.exists(path))
  committed <- jsonlite::read_json(path, simplifyVector = FALSE)
  current <- characterize_legacy_contract(
    normalizePath(testthat::test_path("../.."))
  )

  expect_identical(committed, current)
})
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
Rscript -e 'devtools::load_all(quiet = TRUE); testthat::test_file("tests/testthat/test-vnext-legacy-contract.R")'
```

Expected: FAIL because `legacy-contract.R` and the committed contract do not
exist.

- [ ] **Step 3: Implement the compatibility inventory**

Create `dev/vnext/characterization/legacy-contract.R`:

```r
legacy_sidecar_contract <- function() {
  records <- list(
    c("field-codes.json", "durable", "mixed",
      "Zotero fields, references hash and extraction provenance"),
    c("comments.json", "durable", "returned-docx",
      "Word comments and replies"),
    c("revisions.json", "durable", "returned-docx",
      "Tracked insertion and deletion metadata"),
    c("references.json", "generated", "source",
      "CSL JSON reference cache"),
    c("page-config.json", "generated", "source",
      "Resolved document, page and named-section properties"),
    c("style-map.json", "generated", "source",
      "Resolved Word style identifiers"),
    c("section-map.json", "generated", "rendered-docx",
      "Section boundary inventory"),
    c("harvest-map.json", "generated", "rendered-docx",
      "Paragraph correspondence cache"),
    c("figures.json", "generated", "mixed",
      "Figure identifiers and source paths"),
    c("styles.json", "generated", "rendered-docx",
      "Extracted style inventory")
  )
  lapply(records, function(record) {
    list(
      name = record[[1]],
      lifecycle = record[[2]],
      authority = record[[3]],
      purpose = record[[4]],
      versioning = "unversioned"
    )
  })
}

read_characterized_package_version <- function(repo_root) {
  fields <- read.dcf(file.path(repo_root, "DESCRIPTION"))
  unname(fields[1, "Version"])
}

characterize_legacy_contract <- function(repo_root) {
  schema_path <- file.path(
    repo_root,
    "inst", "schema", "docstyle-field-codes.json"
  )
  schema <- jsonlite::read_json(schema_path, simplifyVector = FALSE)
  writer_version <- as.integer(schema$schema_version)

  list(
    schemaVersion = 1L,
    characterizedRelease = read_characterized_package_version(repo_root),
    fieldCodes = list(
      instructionPrefix = "ADDIN DOCSTYLE",
      writerVersion = writer_version,
      readerVersions = as.list(seq_len(writer_version)),
      futureVersionPolicy = paste(
        "Strict reading rejects versions greater than",
        writer_version
      ),
      payloadTypes = as.list(c(
        "char", "div", "list", "section", "table", "figure",
        "float", "anchor"
      )),
      interoperablePrefixes = as.list(c(
        "ADDIN ZOTERO_ITEM",
        "ADDIN ZOTERO_BIBL",
        "ADDIN ZOTERO_PREF"
      ))
    ),
    sidecars = legacy_sidecar_contract()
  )
}

validate_legacy_contract <- function(contract) {
  if (!identical(as.integer(contract$schemaVersion), 1L)) {
    stop("legacy contract schemaVersion must be 1", call. = FALSE)
  }
  writer <- as.integer(contract$fieldCodes$writerVersion)
  readers <- as.integer(unlist(
    contract$fieldCodes$readerVersions,
    use.names = FALSE
  ))
  if (!identical(readers, seq_len(writer))) {
    stop(
      "field-code readerVersions must cover 1 through writerVersion",
      call. = FALSE
    )
  }
  sidecar_names <- vapply(
    contract$sidecars,
    function(x) as.character(x$name),
    character(1)
  )
  if (anyDuplicated(sidecar_names)) {
    stop("legacy sidecar names must be unique", call. = FALSE)
  }
  valid_lifecycles <- c("durable", "generated")
  if (!all(vapply(
    contract$sidecars,
    function(x) as.character(x$lifecycle) %in% valid_lifecycles,
    logical(1)
  ))) {
    stop("legacy sidecar lifecycle is invalid", call. = FALSE)
  }
  invisible(TRUE)
}

write_legacy_contract <- function(repo_root, path) {
  contract <- characterize_legacy_contract(repo_root)
  validate_legacy_contract(contract)
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(
    contract,
    path,
    pretty = TRUE,
    auto_unbox = TRUE,
    null = "null"
  )
  invisible(path)
}
```

The reader-version range records actual legacy behaviour: an absent payload
version is treated as version 1, explicit versions through 3 are accepted, and
future versions are rejected in strict mode. The sidecars are marked
`unversioned` because release 0.19.0 has no per-file schema-version key; this
finding exposes an interoperability gap for work package 1.

- [ ] **Step 4: Generate the committed contract**

Run:

```bash
Rscript -e 'source("dev/vnext/characterization/legacy-contract.R"); write_legacy_contract(".", "tests/vnext/fixtures/legacy-contract.json")'
```

Expected: `tests/vnext/fixtures/legacy-contract.json` contains release
`0.19.0`, field-code writer version 3, reader versions 1 through 3 and ten
classified unversioned sidecars. Review the generated diff before continuing.

- [ ] **Step 5: Run the tests to verify they pass**

Run:

```bash
Rscript -e 'devtools::load_all(quiet = TRUE); testthat::test_file("tests/testthat/test-vnext-legacy-contract.R")'
```

Expected: three tests pass and the committed JSON is identical to fresh
characterization.

- [ ] **Step 6: Commit**

```bash
git add dev/vnext/characterization/legacy-contract.R tests/vnext/fixtures/legacy-contract.json tests/testthat/test-vnext-legacy-contract.R
git commit -m "Freeze the legacy compatibility contract"
```

---

### Task 7: Implement deterministic baseline capture

**Files:**
- Create: `dev/vnext/characterization/capture-baselines.R`
- Create: `tests/testthat/test-vnext-baseline-capture.R`

**Interfaces:**
- Produces: `capture_fixture_baseline(fixture, catalog_root, repo_root, output_root, ...) -> list`
- Produces: `capture_legacy_baselines(repo_root, catalog_path, output_root, ...) -> invisible(list)`
- Produces CLI: `Rscript dev/vnext/characterization/capture-baselines.R [--key=value]`
- Consumed by: Task 8 and later dual-engine comparisons

- [ ] **Step 1: Write the failing baseline-capture tests**

Create `tests/testthat/test-vnext-baseline-capture.R`:

```r
source(testthat::test_path(
  "../../dev/vnext/characterization/capture-baselines.R"
))

fake_renderer <- function(
  fixture, format, catalog_root, repo_root, work_root, quarto_bin
) {
  extension <- legacy_output_extension(format)
  dir.create(work_root, recursive = TRUE, showWarnings = FALSE)
  path <- file.path(work_root, paste0(fixture$id, ".", extension))
  writeLines(paste(fixture$id, format), path)
  list(path = path, format = format, log = "fake render")
}

fake_rasterizer <- function(
  path, pages, output_dir, prefix, pdftoppm_bin, resolution
) {
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  vapply(pages, function(page) {
    output <- file.path(
      output_dir,
      sprintf("%s-page-%03d.png", prefix, as.integer(page))
    )
    writeBin(as.raw(c(0x89, 0x50, 0x4e, 0x47)), output)
    output
  }, character(1))
}

test_that("capture writes artifacts, inventories, visual pages and manifest", {
  root <- tempfile("baseline-capture-")
  dir.create(root)
  fixture <- list(
    id = "example",
    sourceDir = "example/source",
    document = "protocol.qmd",
    formats = c("docstyle-docx", "docstyle-typst", "docstyle-jats"),
    visualPages = c(1L, 2L)
  )

  manifest <- capture_fixture_baseline(
    fixture = fixture,
    catalog_root = root,
    repo_root = root,
    output_root = root,
    characterized_release = "0.19.0",
    renderer = fake_renderer,
    docx_inspector = function(path) {
      list(schemaVersion = 1L, artifact = "docx")
    },
    pdf_inspector = function(path, pdfinfo_bin, pdftotext_bin) {
      list(schemaVersion = 1L, artifact = "pdf")
    },
    jats_inspector = function(path) {
      list(schemaVersion = 1L, artifact = "jats")
    },
    rasterizer = fake_rasterizer
  )

  baseline <- file.path(root, "example", "baseline", "legacy")
  expect_true(file.exists(file.path(baseline, "docstyle-docx.docx")))
  expect_true(file.exists(file.path(baseline, "docstyle-typst.pdf")))
  expect_true(file.exists(file.path(baseline, "docstyle-jats.xml")))
  expect_true(file.exists(file.path(
    baseline, "docstyle-docx-inventory.json"
  )))
  expect_true(file.exists(file.path(
    baseline, "pages", "docstyle-typst-page-001.png"
  )))
  expect_true(file.exists(file.path(baseline, "manifest.json")))
  expect_identical(manifest$fixture, "example")
  expect_length(manifest$artifacts, 3L)
  expect_false(any(grepl(
    tempdir(),
    unlist(manifest, use.names = FALSE),
    fixed = TRUE
  )))
})

test_that("capture CLI rejects unknown options", {
  expect_error(
    parse_capture_arguments("--unknown=value"),
    "unknown capture option"
  )
})
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
Rscript -e 'devtools::load_all(quiet = TRUE); testthat::test_file("tests/testthat/test-vnext-baseline-capture.R")'
```

Expected: FAIL because `capture-baselines.R` does not exist.

- [ ] **Step 3: Implement baseline capture and the command interface**

Create `dev/vnext/characterization/capture-baselines.R`:

```r
characterization_script_names <- c(
  "catalog.R",
  "render-legacy.R",
  "inspect-docx.R",
  "inspect-publication.R",
  "legacy-contract.R"
)

load_characterization_scripts <- function(repo_root) {
  directory <- file.path(repo_root, "dev", "vnext", "characterization")
  for (name in characterization_script_names) {
    source(file.path(directory, name), local = .GlobalEnv)
  }
  invisible(TRUE)
}

write_characterization_json <- function(value, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(
    value,
    path,
    pretty = TRUE,
    auto_unbox = TRUE,
    null = "null"
  )
  invisible(path)
}

baseline_artifact_filename <- function(format) {
  paste0(format, ".", legacy_output_extension(format))
}

capture_fixture_baseline <- function(
  fixture,
  catalog_root,
  repo_root,
  output_root,
  characterized_release,
  quarto_bin = "quarto",
  pdfinfo_bin = "pdfinfo",
  pdftotext_bin = "pdftotext",
  pdftoppm_bin = "pdftoppm",
  renderer = render_legacy_fixture,
  docx_inspector = inspect_legacy_docx,
  pdf_inspector = inspect_legacy_pdf,
  jats_inspector = inspect_legacy_jats,
  rasterizer = rasterize_pdf_pages
) {
  fixture_id <- as.character(fixture$id)
  formats <- as.character(unlist(fixture$formats, use.names = FALSE))
  visual_pages <- as.integer(unlist(
    fixture$visualPages,
    use.names = FALSE
  ))
  baseline_parent <- file.path(output_root, fixture_id, "baseline")
  baseline <- file.path(baseline_parent, "legacy")
  dir.create(baseline_parent, recursive = TRUE, showWarnings = FALSE)
  staging <- tempfile("legacy-staging-", tmpdir = baseline_parent)
  dir.create(staging)
  on.exit(
    unlink(staging, recursive = TRUE, force = TRUE),
    add = TRUE
  )

  artifacts <- lapply(formats, function(format) {
    work_root <- tempfile(
      paste0("docstyle-", fixture_id, "-", format, "-")
    )
    on.exit(
      unlink(work_root, recursive = TRUE, force = TRUE),
      add = TRUE
    )
    rendered <- renderer(
      fixture = fixture,
      format = format,
      catalog_root = catalog_root,
      repo_root = repo_root,
      work_root = work_root,
      quarto_bin = quarto_bin
    )
    artifact_name <- baseline_artifact_filename(format)
    artifact_path <- file.path(staging, artifact_name)
    if (!file.copy(rendered$path, artifact_path, overwrite = TRUE)) {
      stop("failed to freeze artifact: ", artifact_name, call. = FALSE)
    }

    inventory <- switch(
      format,
      "docstyle-docx" = docx_inspector(artifact_path),
      "docstyle-typst" = pdf_inspector(
        artifact_path,
        pdfinfo_bin = pdfinfo_bin,
        pdftotext_bin = pdftotext_bin
      ),
      "docstyle-jats" = jats_inspector(artifact_path),
      stop("unsupported characterization format: ", format,
           call. = FALSE)
    )
    inventory_name <- paste0(format, "-inventory.json")
    write_characterization_json(
      inventory,
      file.path(staging, inventory_name)
    )

    page_paths <- character()
    if (identical(format, "docstyle-typst")) {
      page_paths <- rasterizer(
        path = artifact_path,
        pages = visual_pages,
        output_dir = file.path(staging, "pages"),
        prefix = format,
        pdftoppm_bin = pdftoppm_bin,
        resolution = 110L
      )
    }

    list(
      format = format,
      file = artifact_name,
      inventory = inventory_name,
      visualPages = as.list(file.path(
        "pages",
        basename(page_paths)
      ))
    )
  })

  manifest <- list(
    schemaVersion = 1L,
    fixture = fixture_id,
    characterizedRelease = characterized_release,
    expectations = "../../expectations.json",
    legacyContract = "../../../legacy-contract.json",
    artifacts = artifacts
  )
  write_characterization_json(
    manifest,
    file.path(staging, "manifest.json")
  )
  if (dir.exists(baseline)) {
    unlink(baseline, recursive = TRUE, force = TRUE)
  }
  if (!file.rename(staging, baseline)) {
    stop("failed to atomically replace baseline: ", baseline, call. = FALSE)
  }
  manifest
}

capture_legacy_baselines <- function(
  repo_root,
  catalog_path,
  output_root,
  quarto_bin = "quarto",
  pdfinfo_bin = "pdfinfo",
  pdftotext_bin = "pdftotext",
  pdftoppm_bin = "pdftoppm"
) {
  catalog <- read_fixture_catalog(catalog_path, check_files = TRUE)
  contract <- characterize_legacy_contract(repo_root)
  manifests <- lapply(catalog$fixtures, function(fixture) {
    capture_fixture_baseline(
      fixture = fixture,
      catalog_root = dirname(catalog_path),
      repo_root = repo_root,
      output_root = output_root,
      characterized_release = contract$characterizedRelease,
      quarto_bin = quarto_bin,
      pdfinfo_bin = pdfinfo_bin,
      pdftotext_bin = pdftotext_bin,
      pdftoppm_bin = pdftoppm_bin
    )
  })
  invisible(manifests)
}

parse_capture_arguments <- function(arguments) {
  defaults <- list(
    repo_root = ".",
    catalog = "tests/vnext/fixtures/catalog.json",
    output_root = "tests/vnext/fixtures",
    quarto = "quarto",
    pdfinfo = "pdfinfo",
    pdftotext = "pdftotext",
    pdftoppm = "pdftoppm"
  )
  keys <- names(defaults)
  for (argument in arguments) {
    match <- regexec("^--([^=]+)=(.*)$", argument)
    parts <- regmatches(argument, match)[[1]]
    if (length(parts) != 3L) {
      stop("capture options must use --key=value", call. = FALSE)
    }
    key <- gsub("-", "_", parts[[2]], fixed = TRUE)
    if (!key %in% keys) {
      stop("unknown capture option: ", parts[[2]], call. = FALSE)
    }
    defaults[[key]] <- parts[[3]]
  }
  defaults
}

capture_baselines_main <- function(arguments = commandArgs(trailingOnly = TRUE)) {
  options <- parse_capture_arguments(arguments)
  repo_root <- normalizePath(options$repo_root, mustWork = TRUE)
  load_characterization_scripts(repo_root)
  catalog_path <- file.path(repo_root, options$catalog)
  output_root <- file.path(repo_root, options$output_root)
  capture_legacy_baselines(
    repo_root = repo_root,
    catalog_path = catalog_path,
    output_root = output_root,
    quarto_bin = options$quarto,
    pdfinfo_bin = options$pdfinfo,
    pdftotext_bin = options$pdftotext,
    pdftoppm_bin = options$pdftoppm
  )
}

if (sys.nframe() == 0L) {
  capture_baselines_main()
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```bash
Rscript -e 'devtools::load_all(quiet = TRUE); source("dev/vnext/characterization/render-legacy.R"); source("dev/vnext/characterization/inspect-docx.R"); source("dev/vnext/characterization/inspect-publication.R"); testthat::test_file("tests/testthat/test-vnext-baseline-capture.R")'
```

Expected: two tests pass using injected fakes; no Quarto or Poppler process is
started.

- [ ] **Step 5: Commit**

```bash
git add dev/vnext/characterization/capture-baselines.R tests/testthat/test-vnext-baseline-capture.R
git commit -m "Add deterministic legacy baseline capture"
```

---

### Task 8: Capture, guard and document the frozen baselines

**Files:**
- Create: `dev/vnext/characterization/README.md`
- Create: `tests/testthat/test-vnext-baselines.R`
- Generate: all `tests/vnext/fixtures/<fixture>/baseline/legacy/` artifacts listed in the file structure

**Interfaces:**
- Consumes: Tasks 1 through 7
- Produces: committed release-0.19.0 evidence for later vNext acceptance tests
- Produces: a human- and machine-reviewable baseline update procedure

- [ ] **Step 1: Write the failing frozen-baseline guards**

Create `tests/testthat/test-vnext-baselines.R`:

```r
source(testthat::test_path(
  "../../dev/vnext/characterization/catalog.R"
))

allowed_expectation_statuses <- c(
  "observed", "known-bug", "approximated", "omitted", "unsupported"
)

read_fixture_expectations <- function(path) {
  value <- jsonlite::read_json(path, simplifyVector = FALSE)
  expect_identical(as.integer(value$schemaVersion), 1L)
  statuses <- vapply(
    value$expectations,
    function(x) as.character(x$status),
    character(1)
  )
  expect_true(all(statuses %in% allowed_expectation_statuses))
  expect_true(all(vapply(
    value$expectations,
    function(x) {
      nzchar(as.character(x$evidence)) &&
        nzchar(as.character(x$reference))
    },
    logical(1)
  )))
  value
}

test_that("every fixture has a complete frozen legacy manifest", {
  root <- testthat::test_path("../vnext/fixtures")
  catalog <- read_fixture_catalog(
    file.path(root, "catalog.json"),
    check_files = TRUE
  )

  for (fixture in catalog$fixtures) {
    fixture_id <- as.character(fixture$id)
    formats <- as.character(unlist(fixture$formats, use.names = FALSE))
    baseline <- file.path(
      root, fixture_id, "baseline", "legacy"
    )
    manifest_path <- file.path(baseline, "manifest.json")
    expect_true(file.exists(manifest_path), info = fixture_id)
    manifest <- jsonlite::read_json(
      manifest_path,
      simplifyVector = FALSE
    )

    expect_identical(as.integer(manifest$schemaVersion), 1L)
    expect_identical(as.character(manifest$fixture), fixture_id)
    expect_identical(
      as.character(manifest$characterizedRelease),
      "0.19.0"
    )
    artifact_formats <- vapply(
      manifest$artifacts,
      function(x) as.character(x$format),
      character(1)
    )
    expect_setequal(artifact_formats, formats)

    for (artifact in manifest$artifacts) {
      artifact_path <- file.path(baseline, artifact$file)
      inventory_path <- file.path(baseline, artifact$inventory)
      expect_true(file.exists(artifact_path), info = artifact_path)
      expect_gt(file.info(artifact_path)$size, 0, info = artifact_path)
      expect_true(file.exists(inventory_path), info = inventory_path)
      inventory <- jsonlite::read_json(
        inventory_path,
        simplifyVector = FALSE
      )
      expect_identical(as.integer(inventory$schemaVersion), 1L)

      page_paths <- as.character(unlist(
        artifact$visualPages,
        use.names = FALSE
      ))
      if (identical(as.character(artifact$format), "docstyle-typst")) {
        expect_length(
          page_paths,
          length(unlist(fixture$visualPages, use.names = FALSE))
        )
        for (page_path in page_paths) {
          png <- file.path(baseline, page_path)
          expect_true(file.exists(png), info = png)
          signature <- readBin(png, what = "raw", n = 8L)
          expect_identical(
            signature,
            as.raw(c(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))
          )
        }
      } else {
        expect_length(page_paths, 0L)
      }
    }

    expectations_path <- file.path(
      baseline,
      as.character(manifest$expectations)
    )
    expectations <- read_fixture_expectations(expectations_path)
    expect_identical(
      as.character(expectations$fixture),
      fixture_id
    )
    expect_true(file.exists(file.path(
      baseline,
      as.character(manifest$legacyContract)
    )))
  }
})

test_that("frozen characterization data is portable and bounded", {
  root <- testthat::test_path("../vnext/fixtures")
  files <- list.files(
    root,
    recursive = TRUE,
    full.names = TRUE,
    all.files = TRUE,
    no.. = TRUE
  )
  files <- files[!file.info(files)$isdir]
  expect_lt(sum(file.info(files)$size), 15 * 1024^2)

  fixture_directories <- file.path(root, c(
    "demport-protocol",
    "popcorn-protocol",
    "independent-manuscript"
  ))
  for (directory in fixture_directories) {
    fixture_files <- list.files(
      directory,
      recursive = TRUE,
      full.names = TRUE,
      all.files = TRUE,
      no.. = TRUE
    )
    fixture_files <- fixture_files[!file.info(fixture_files)$isdir]
    expect_lt(sum(file.info(fixture_files)$size), 5 * 1024^2)
  }

  json_files <- files[tools::file_ext(files) == "json"]
  json_text <- unlist(lapply(
    json_files,
    readLines,
    warn = FALSE,
    encoding = "UTF-8"
  ))
  machine_patterns <- c(
    "/Users/", "/home/", "/private/tmp/", "\\\\Users\\\\",
    "docstyle-characterization-docx-"
  )
  expect_false(any(vapply(
    machine_patterns,
    function(pattern) any(grepl(pattern, json_text, fixed = TRUE)),
    logical(1)
  )))
})
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
Rscript -e 'devtools::load_all(quiet = TRUE); testthat::test_file("tests/testthat/test-vnext-baselines.R")'
```

Expected: FAIL because the frozen artifacts and manifests have not been
captured.

- [ ] **Step 3: Document evidence status and regeneration**

Create `dev/vnext/characterization/README.md`:

````markdown
# vNext legacy characterization

This directory contains the migration-only harness for Docstyle vNext work
package 0. It freezes what release 0.19.0 produces; it does not define what
vNext ought to reproduce.

## Evidence model

Each fixture has an `expectations.json` record. Its statuses mean:

- `observed`: present in the frozen output and eligible for later acceptance
  testing;
- `known-bug`: reproduced legacy behaviour that vNext must not adopt as its
  contract;
- `approximated`: the legacy backends express similar intent without a
  shared property contract;
- `omitted`: intentionally excluded from the compact fixture, with the
  reason recorded;
- `unsupported`: absent from the legacy engine and assigned to a later work
  package.

Normalized JSON inventories are semantic evidence. Selected 110-DPI PNG pages
are visual-review evidence. Binary DOCX and PDF hashes are not regression
assertions because ZIP metadata and render environments can change without a
semantic change.

## Requirements

Baseline capture uses R only as a legacy migration harness. It requires the
current Docstyle package, Quarto, Pandoc and Typst, plus Poppler commands
`pdfinfo`, `pdftotext` and `pdftoppm`. Fixture sources use only local
CSS, CSL, bibliography and image assets.

## Regenerate release 0.19.0 baselines

From the repository root:

```bash
R CMD INSTALL .
quarto check
command -v pdfinfo
command -v pdftotext
command -v pdftoppm
Rscript dev/vnext/characterization/capture-baselines.R --repo-root=.
```

Then inspect every changed `expectations.json`, inventory, DOCX, PDF, JATS
file and selected page image. A changed baseline requires an explanatory
expectation update; never regenerate merely to make a test green. Confirm that
no absolute path, username or render timestamp entered committed JSON.

## Visual review

The automated capture rasterizes the selected Typst/PDF pages named in
`catalog.json`. For a local Word comparison, open the frozen DOCX in the
target Word version, export it to PDF without accepting revisions, and run:

```bash
Rscript -e 'devtools::load_all(quiet = TRUE); source("dev/vnext/characterization/inspect-publication.R"); rasterize_pdf_pages("WORD-EXPORT.pdf", c(1L, 2L), "/tmp/docstyle-word-pages", "docstyle-docx")'
```

Review corresponding Word and Typst page images side by side. Do not commit
Word-exported images in work package 0: Word rendering varies by platform and
font installation. Work package 6 will define pinned environments, supported
property equivalence and quantitative visual tolerances.

## Update discipline

Keep each fixture below 5 MiB and the complete fixture tree below 15 MiB.
Change fixture source and its expectation record in the same commit. Preserve
known failures with their issue reference. The R harness remains isolated
under `dev/vnext/characterization/` and must not become a vNext runtime
dependency.
````

- [ ] **Step 4: Verify the legacy toolchain before capture**

Run:

```bash
R CMD INSTALL .
quarto check
command -v pdfinfo
command -v pdftotext
command -v pdftoppm
```

Expected: Docstyle 0.19.0 installs; Quarto reports working Pandoc and Typst
engines; each Poppler command prints an absolute executable path. Stop and
record the missing tool if any check fails rather than capturing partial
baselines.

- [ ] **Step 5: Capture the frozen artifacts**

Run:

```bash
Rscript dev/vnext/characterization/capture-baselines.R --repo-root=.
```

Expected:

- DemPoRT produces one DOCX, one PDF, two inventories, two PDF page images and
  one manifest.
- POPCORN produces one DOCX, one PDF, one JATS XML, three inventories, two PDF
  page images and one manifest.
- The independent fixture produces one DOCX, one PDF, one JATS XML, three
  inventories, two PDF page images and one manifest.
- No render accesses the network or modifies the source project fixtures.

- [ ] **Step 6: Review the artifacts before treating them as evidence**

Open each of the three DOCX files in Word, each PDF in a PDF viewer and each
JATS file in a text or XML editor. Review for the following evidence:

- the title, abstract, citations and tables expected by the fixture are
  present;
- portrait and landscape sections occur in the intended order;
- author-plate and version-history fields appear where declared;
- JATS output contains the expected front matter and native structural
  elements;
- every observed difference or loss is represented in `expectations.json`;
- the selected PDF page images are legible and correspond to catalogue page
  numbers.

If the review reveals a new loss, add a `known-bug`, `approximated`,
`omitted` or `unsupported` expectation with an issue or work-package
reference before continuing.

- [ ] **Step 7: Run focused and full verification**

Run:

```bash
Rscript -e 'devtools::load_all(quiet = TRUE); testthat::test_dir("tests/testthat", filter = "vnext")'
Rscript -e 'devtools::test()'
R CMD build .
env _R_CHECK_FORCE_SUGGESTS_=false R CMD check --output=/tmp --no-manual docstyle_0.19.0.tar.gz
git diff --check
```

Expected: all vNext tests pass, the existing package test suite passes, the
source package builds, `R CMD check` reports no errors, and
`git diff --check` prints no output. Investigate any existing-suite
regression before committing; do not update baselines to conceal it.

- [ ] **Step 8: Commit**

```bash
git add dev/vnext/characterization/README.md tests/vnext/fixtures tests/testthat/test-vnext-baselines.R
git commit -m "Freeze Docstyle 0.19.0 characterization baselines"
```

---

## Work package 0 completion gate

Before requesting review, verify:

- [ ] DemPoRT, POPCORN and independent fixtures are compact, sanitized,
  licensed and offline.
- [ ] Every declared format has a frozen artifact and normalized inventory.
- [ ] Selected Typst/PDF pages are committed for repeatable visual review.
- [ ] Legacy successes, known bugs, approximations, omissions and unsupported
  features are explicit.
- [ ] Field-code reader versions 1 through 3, writer version 3 and all legacy
  JSON sidecars are recorded.
- [ ] No committed JSON contains an absolute path, timestamp or username.
- [ ] Fixture and aggregate size limits pass.
- [ ] The migration-only R harness is not sourced by the extension runtime.
- [ ] The Typst cold-home test passes with registry imports absent and network
  proxies blocked.
- [ ] Focused tests, the existing test suite, package build and package check
  pass.
- [ ] The implementation PR links this plan and the vNext programme
  specification, and includes `Closes #25`.
