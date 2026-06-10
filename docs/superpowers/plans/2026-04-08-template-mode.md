# Template mode implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a template-based styling pathway so users can provide a `.dot`/`.docx` template as the reference document, with optional CSS overlay and post-render style ID swap to preserve native template style names.

**Architecture:** Pre-render copies the template to `_docstyle/reference.docx` and generates `style-map.json` mapping Pandoc's expected style IDs to the template's native IDs. Post-render swaps IDs back before section assembly. CSS overlay is optional and updates only specified properties. Pruning preserves all template-sourced styles.

**Tech Stack:** R (xml2, jsonlite, officer), existing docstyle utilities (`with_docx_temp`, `extract_docx_temp`, `modify_docx_xml`)

---

## File structure

| File | Responsibility |
|------|---------------|
| `R/style_map.R` (new) | `build_style_map()` — scan template styles.xml, build Pandoc→template ID mapping, write `style-map.json`. `swap_style_ids()` — post-render rename of style IDs in output docx. |
| `R/page_layout.R` (modify) | Add template-mode message in `generate_reference_doc()`. No logic changes needed — the existing file-path branch already copies the template correctly. |
| `R/css_injection.R` (modify) | Add `template_styles` parameter to `inject_css_styles()` and `cascade_css_to_children()` to skip cascade for template-resident styles. |
| `R/style_manager.R` (modify) | Add `template_path` parameter to `get_allowed_styles()` to preserve all template styles during pruning. |
| `_extensions/docstyle/generate-reference.R` (modify) | Call `build_style_map()` after copying template. Include template hash in cache key. |
| `_extensions/docstyle/update-field-codes.R` (modify) | Call `swap_style_ids()` before `finalize_docx()`. Pass `template_path` to `prune_styles_file()`. |
| `tests/testthat/test-style-map.R` (new) | Tests for style map generation and style ID swap. |

---

### Task 1: Style map generation — `build_style_map()`

**Files:**
- Create: `R/style_map.R`
- Create: `tests/testthat/test-style-map.R`

This is the core new function. It scans a template's `styles.xml` and builds a mapping from Pandoc's expected style IDs to the template's native style IDs, using the same resolution logic as `style_resolver.R`.

- [ ] **Step 1: Write failing tests for `build_style_map()`**

Create `tests/testthat/test-style-map.R`:

```r
test_that("build_style_map returns empty list for template with standard names", {
  # Template where Heading1 = Heading1, Normal = Normal — no swap needed
  styles_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:style w:type="paragraph" w:styleId="Normal">',
    '  <w:name w:val="Normal"/>',
    '</w:style>',
    '<w:style w:type="paragraph" w:styleId="Heading1">',
    '  <w:name w:val="heading 1"/>',
    '  <w:pPr><w:outlineLvl w:val="0"/></w:pPr>',
    '</w:style>',
    '</w:styles>'
  )

  result <- build_style_map_from_xml(styles_xml)
  expect_equal(result, list())
})

test_that("build_style_map detects outlineLvl-based heading mapping", {
  styles_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:style w:type="paragraph" w:styleId="Normal">',
    '  <w:name w:val="Normal"/>',
    '</w:style>',
    '<w:style w:type="paragraph" w:styleId="MDPI21heading1">',
    '  <w:name w:val="MDPI 21 heading 1"/>',
    '  <w:pPr><w:outlineLvl w:val="0"/></w:pPr>',
    '</w:style>',
    '<w:style w:type="paragraph" w:styleId="MDPI22heading2">',
    '  <w:name w:val="MDPI 22 heading 2"/>',
    '  <w:pPr><w:outlineLvl w:val="1"/></w:pPr>',
    '</w:style>',
    '</w:styles>'
  )

  result <- build_style_map_from_xml(styles_xml)
  expect_equal(result[["Heading1"]], "MDPI21heading1")
  expect_equal(result[["Heading2"]], "MDPI22heading2")
  # Normal maps to itself — omitted from map
  expect_null(result[["Normal"]])
})

test_that("build_style_map detects basedOn chain mapping", {
  styles_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:style w:type="paragraph" w:styleId="Normal">',
    '  <w:name w:val="Normal"/>',
    '</w:style>',
    '<w:style w:type="paragraph" w:styleId="BodyText">',
    '  <w:name w:val="Body Text"/>',
    '  <w:basedOn w:val="Normal"/>',
    '</w:style>',
    '<w:style w:type="paragraph" w:styleId="MDPI31text">',
    '  <w:name w:val="MDPI 31 text"/>',
    '  <w:basedOn w:val="BodyText"/>',
    '</w:style>',
    '</w:styles>'
  )

  result <- build_style_map_from_xml(styles_xml)
  # MDPI31text is based on BodyText — maps BodyText → MDPI31text
  expect_equal(result[["BodyText"]], "MDPI31text")
})

test_that("build_style_map detects display name pattern match", {
  styles_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:style w:type="paragraph" w:styleId="JournalCaption">',
    '  <w:name w:val="Caption"/>',
    '</w:style>',
    '</w:styles>'
  )

  result <- build_style_map_from_xml(styles_xml)
  expect_equal(result[["Caption"]], "JournalCaption")
})

test_that("build_style_map handles multiple resolution methods together", {
  styles_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:style w:type="paragraph" w:styleId="Normal">',
    '  <w:name w:val="Normal"/>',
    '</w:style>',
    '<w:style w:type="paragraph" w:styleId="CustomH1">',
    '  <w:name w:val="Custom H1"/>',
    '  <w:pPr><w:outlineLvl w:val="0"/></w:pPr>',
    '</w:style>',
    '<w:style w:type="paragraph" w:styleId="CustomBody">',
    '  <w:name w:val="Body Text"/>',
    '</w:style>',
    '</w:styles>'
  )

  result <- build_style_map_from_xml(styles_xml)
  expect_equal(result[["Heading1"]], "CustomH1")
  expect_equal(result[["BodyText"]], "CustomBody")
  expect_null(result[["Normal"]])
})

test_that("build_style_map prefers outlineLvl over name match", {
  # Style has outlineLvl=0 but name is NOT "heading 1"
  styles_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:style w:type="paragraph" w:styleId="SectionTitle">',
    '  <w:name w:val="Section Title"/>',
    '  <w:pPr><w:outlineLvl w:val="0"/></w:pPr>',
    '</w:style>',
    '</w:styles>'
  )

  result <- build_style_map_from_xml(styles_xml)
  expect_equal(result[["Heading1"]], "SectionTitle")
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-style-map.R")'`
Expected: FAIL — `build_style_map_from_xml` not found

- [ ] **Step 3: Implement `build_style_map_from_xml()` and `build_style_map()`**

Create `R/style_map.R`:

```r
#' Build Style Map from Template XML
#'
#' Scans a template's styles.xml content and builds a mapping from Pandoc's
#' expected style IDs to the template's native style IDs. Identity mappings
#' are omitted.
#'
#' @param styles_xml_str Character string of styles.xml content, or xml2 document
#' @return Named list: Pandoc style ID -> template style ID (non-identity only)
#' @export
build_style_map_from_xml <- function(styles_xml_str) {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  styles_xml <- if (inherits(styles_xml_str, "xml_document")) {
    styles_xml_str
  } else {
    xml2::read_xml(styles_xml_str)
  }

  style_nodes <- xml2::xml_find_all(styles_xml, "/w:styles/w:style", ns)

  # Build lookup of all styles: id -> {name, based_on, outline_level, type}
  lookup <- list()
  for (node in style_nodes) {
    style_id <- xml2::xml_attr(node, "styleId")
    if (is.na(style_id)) next

    style_type <- xml2::xml_attr(node, "type")

    name_node <- xml2::xml_find_first(node, "w:name/@w:val", ns)
    name <- if (!inherits(name_node, "xml_missing")) {
      xml2::xml_text(name_node)
    } else {
      style_id
    }

    based_on_node <- xml2::xml_find_first(node, "w:basedOn/@w:val", ns)
    based_on <- if (!inherits(based_on_node, "xml_missing")) {
      xml2::xml_text(based_on_node)
    } else {
      NULL
    }

    outline_node <- xml2::xml_find_first(node, "w:pPr/w:outlineLvl/@w:val", ns)
    outline_level <- if (!inherits(outline_node, "xml_missing")) {
      val <- xml2::xml_text(outline_node)
      if (grepl("^[0-9]+$", val)) as.integer(val) else NA_integer_
    } else {
      NA_integer_
    }

    lookup[[style_id]] <- list(
      name          = name,
      based_on      = based_on,
      outline_level = outline_level,
      type          = if (is.na(style_type)) "paragraph" else style_type
    )
  }

  # Pandoc style IDs we need to map
  pandoc_targets <- c(
    "Heading1", "Heading2", "Heading3", "Heading4", "Heading5",
    "Heading6", "Heading7", "Heading8", "Heading9",
    "Normal", "BodyText", "FirstParagraph", "Compact", "BlockText",
    "Title", "Subtitle", "Author", "Date", "Abstract",
    "Caption", "TableCaption", "ImageCaption",
    "Bibliography", "FootnoteText",
    "Figure", "CaptionedFigure",
    "DefinitionTerm", "Definition",
    "TOCHeading"
  )

  # Build reverse index: for each template style, find which Pandoc target it maps to
  style_map <- list()

  for (pandoc_id in pandoc_targets) {
    # 1. Direct match — template already has this exact style ID
    if (pandoc_id %in% names(lookup)) next

    # 2. outlineLvl match (headings only)
    if (grepl("^Heading[1-9]$", pandoc_id)) {
      target_level <- as.integer(sub("Heading", "", pandoc_id)) - 1L
      for (sid in names(lookup)) {
        if (sid == pandoc_id) next
        props <- lookup[[sid]]
        if (!is.na(props$outline_level) && props$outline_level == target_level) {
          style_map[[pandoc_id]] <- sid
          break
        }
      }
      if (!is.null(style_map[[pandoc_id]])) next
    }

    # 3. basedOn chain — find template style whose basedOn chain reaches pandoc_id
    for (sid in names(lookup)) {
      if (sid == pandoc_id) next
      # Walk basedOn chain from this style
      current <- lookup[[sid]]$based_on
      seen <- sid
      while (!is.null(current) && !(current %in% seen)) {
        if (current == pandoc_id) {
          # This template style is based on the Pandoc style
          # Only map if no better match found yet
          if (is.null(style_map[[pandoc_id]])) {
            style_map[[pandoc_id]] <- sid
          }
          break
        }
        seen <- c(seen, current)
        current <- lookup[[current]]$based_on
      }
    }
    if (!is.null(style_map[[pandoc_id]])) next

    # 4. Display name pattern match (case-insensitive)
    pandoc_display <- .PANDOC_DISPLAY_NAMES[[pandoc_id]]
    if (!is.null(pandoc_display)) {
      for (sid in names(lookup)) {
        if (sid == pandoc_id) next
        if (tolower(lookup[[sid]]$name) == tolower(pandoc_display)) {
          style_map[[pandoc_id]] <- sid
          break
        }
      }
    }
  }

  style_map
}


# Display name mapping for name-pattern fallback (step 4)
.PANDOC_DISPLAY_NAMES <- list(
  Heading1 = "Heading 1", Heading2 = "Heading 2", Heading3 = "Heading 3",
  Heading4 = "Heading 4", Heading5 = "Heading 5", Heading6 = "Heading 6",
  Heading7 = "Heading 7", Heading8 = "Heading 8", Heading9 = "Heading 9",
  Normal = "Normal",
  BodyText = "Body Text",
  FirstParagraph = "First Paragraph",
  Compact = "Compact",
  BlockText = "Block Text",
  Title = "Title",
  Subtitle = "Subtitle",
  Author = "Author",
  Date = "Date",
  Abstract = "Abstract",
  Caption = "Caption",
  TableCaption = "Table Caption",
  ImageCaption = "Image Caption",
  Bibliography = "Bibliography",
  FootnoteText = "Footnote Text",
  Figure = "Figure",
  CaptionedFigure = "Captioned Figure",
  DefinitionTerm = "Definition Term",
  Definition = "Definition",
  TOCHeading = "TOC Heading"
)


#' Build Style Map from Template File
#'
#' Reads a template .docx or .dot file, scans its styles.xml, and writes
#' `style-map.json` to the sidecar directory. Returns the map invisibly.
#'
#' @param template_path Path to the template .docx or .dot file
#' @param sidecar_dir Path to `_docstyle/` directory for writing style-map.json
#' @return Named list: Pandoc style ID -> template style ID (invisible)
#' @export
build_style_map <- function(template_path, sidecar_dir = NULL) {
  style_map <- with_docx_temp(template_path, function(temp_dir) {
    styles_path <- file.path(temp_dir, "word", "styles.xml")
    if (!file.exists(styles_path)) {
      warning("[style-map] No styles.xml found in template: ", template_path,
              call. = FALSE)
      return(list())
    }
    styles_xml <- xml2::read_xml(styles_path)
    build_style_map_from_xml(styles_xml)
  })

  if (!is.null(sidecar_dir) && length(style_map) > 0L) {
    dir.create(sidecar_dir, recursive = TRUE, showWarnings = FALSE)
    json_path <- file.path(sidecar_dir, "style-map.json")
    jsonlite::write_json(style_map, json_path, auto_unbox = TRUE, pretty = TRUE)
    message("[style-map] Wrote ", length(style_map), " mapping(s) to ",
            json_path)
  } else if (!is.null(sidecar_dir) && length(style_map) == 0L) {
    message("[style-map] Template uses standard Pandoc style names, no mapping needed")
  }

  invisible(style_map)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-style-map.R")'`
Expected: All 6 tests PASS

- [ ] **Step 5: Commit**

```bash
git add R/style_map.R tests/testthat/test-style-map.R
git commit -m "feat: add build_style_map() for template style ID mapping"
```

---

### Task 2: Post-render style swap — `swap_style_ids()`

**Files:**
- Modify: `R/style_map.R`
- Modify: `tests/testthat/test-style-map.R`

After Pandoc renders using Pandoc's standard style IDs, this function renames them back to the template's native IDs in both `styles.xml` and `document.xml`.

- [ ] **Step 1: Write failing tests for `swap_style_ids()`**

Append to `tests/testthat/test-style-map.R`:

```r
test_that("swap_style_ids renames pStyle in document.xml", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  doc_xml <- xml2::read_xml(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr></w:p>',
    '<w:p><w:pPr><w:pStyle w:val="BodyText"/></w:pPr></w:p>',
    '<w:p><w:pPr><w:pStyle w:val="Normal"/></w:pPr></w:p>',
    '</w:body>',
    '</w:document>'
  ))

  style_map <- list(Heading1 = "MDPI21heading1", BodyText = "MDPI31text")
  swap_document_styles(doc_xml, style_map, ns)

  pstyles <- xml2::xml_attr(
    xml2::xml_find_all(doc_xml, "//w:pStyle", ns), "val"
  )
  expect_equal(pstyles, c("MDPI21heading1", "MDPI31text", "Normal"))
})

test_that("swap_style_ids renames rStyle in document.xml", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  doc_xml <- xml2::read_xml(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    '<w:p><w:r><w:rPr><w:rStyle w:val="Hyperlink"/></w:rPr></w:r></w:p>',
    '</w:body>',
    '</w:document>'
  ))

  style_map <- list(Hyperlink = "MDPI_hyperlink")
  swap_document_styles(doc_xml, style_map, ns)

  rstyles <- xml2::xml_attr(
    xml2::xml_find_all(doc_xml, "//w:rStyle", ns), "val"
  )
  expect_equal(rstyles, "MDPI_hyperlink")
})

test_that("swap_style_ids renames styleId, basedOn, link, next in styles.xml", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  styles_xml <- xml2::read_xml(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:style w:type="paragraph" w:styleId="Heading1">',
    '  <w:name w:val="heading 1"/>',
    '  <w:basedOn w:val="Normal"/>',
    '  <w:next w:val="BodyText"/>',
    '  <w:link w:val="Heading1Char"/>',
    '</w:style>',
    '<w:style w:type="character" w:styleId="Heading1Char">',
    '  <w:name w:val="heading 1 Char"/>',
    '  <w:link w:val="Heading1"/>',
    '</w:style>',
    '<w:style w:type="paragraph" w:styleId="BodyText">',
    '  <w:name w:val="Body Text"/>',
    '</w:style>',
    '</w:styles>'
  ))

  style_map <- list(
    Heading1 = "MDPI21heading1",
    Heading1Char = "MDPI21heading1Char",
    BodyText = "MDPI31text"
  )
  swap_styles_xml(styles_xml, style_map, ns)

  # styleId renamed
  ids <- xml2::xml_attr(xml2::xml_find_all(styles_xml, "//w:style", ns), "styleId")
  expect_true("MDPI21heading1" %in% ids)
  expect_true("MDPI21heading1Char" %in% ids)
  expect_true("MDPI31text" %in% ids)
  expect_false("Heading1" %in% ids)

  # basedOn preserved (Normal not in map)
  based_on <- xml2::xml_attr(
    xml2::xml_find_first(styles_xml,
      "//w:style[@w:styleId='MDPI21heading1']/w:basedOn", ns), "val"
  )
  expect_equal(based_on, "Normal")

  # next renamed
  next_val <- xml2::xml_attr(
    xml2::xml_find_first(styles_xml,
      "//w:style[@w:styleId='MDPI21heading1']/w:next", ns), "val"
  )
  expect_equal(next_val, "MDPI31text")

  # link renamed (both directions)
  link1 <- xml2::xml_attr(
    xml2::xml_find_first(styles_xml,
      "//w:style[@w:styleId='MDPI21heading1']/w:link", ns), "val"
  )
  expect_equal(link1, "MDPI21heading1Char")

  link2 <- xml2::xml_attr(
    xml2::xml_find_first(styles_xml,
      "//w:style[@w:styleId='MDPI21heading1Char']/w:link", ns), "val"
  )
  expect_equal(link2, "MDPI21heading1")
})

test_that("swap_style_ids_file modifies docx in place", {
  # Create a minimal DOCX with known styles
  temp_dir <- tempfile("swap_test_")
  dir.create(file.path(temp_dir, "word"), recursive = TRUE)
  dir.create(file.path(temp_dir, "_rels"), recursive = TRUE)

  writeLines('<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="xml" ContentType="application/xml"/>
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
</Types>', file.path(temp_dir, "[Content_Types].xml"))

  writeLines('<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>', file.path(temp_dir, "_rels", ".rels"))

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr></w:p>',
    '</w:body></w:document>'
  ), file.path(temp_dir, "word", "document.xml"))

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:style w:type="paragraph" w:styleId="Heading1">',
    '<w:name w:val="heading 1"/></w:style></w:styles>'
  ), file.path(temp_dir, "word", "styles.xml"))

  # Zip into a docx
  docx_path <- tempfile(fileext = ".docx")
  old_wd <- getwd()
  setwd(temp_dir)
  utils::zip(docx_path, files = list.files(".", recursive = TRUE, all.files = TRUE),
             flags = "-r9Xq")
  setwd(old_wd)

  # Write style-map.json
  sidecar_dir <- tempfile("sidecar_")
  dir.create(sidecar_dir)
  jsonlite::write_json(
    list(Heading1 = "CustomH1"),
    file.path(sidecar_dir, "style-map.json"),
    auto_unbox = TRUE
  )

  # Run swap
  result <- swap_style_ids(docx_path, sidecar_dir = sidecar_dir)
  expect_true(result$swapped)
  expect_equal(result$n_mappings, 1L)

  # Verify the docx was modified
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  verify_dir <- tempfile("verify_")
  utils::unzip(docx_path, exdir = verify_dir)
  doc_xml <- xml2::read_xml(file.path(verify_dir, "word", "document.xml"))
  pstyle <- xml2::xml_attr(
    xml2::xml_find_first(doc_xml, "//w:pStyle", ns), "val"
  )
  expect_equal(pstyle, "CustomH1")

  unlink(c(temp_dir, sidecar_dir, verify_dir, docx_path), recursive = TRUE)
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-style-map.R")'`
Expected: FAIL — new test functions not found

- [ ] **Step 3: Implement `swap_document_styles()`, `swap_styles_xml()`, and `swap_style_ids()`**

Append to `R/style_map.R`:

```r
#' Swap Style IDs in document.xml
#'
#' Renames w:pStyle and w:rStyle val attributes from Pandoc IDs to template IDs.
#'
#' @param doc_xml xml2 document (word/document.xml)
#' @param style_map Named list: Pandoc ID -> template ID
#' @param ns XML namespace vector
#' @return NULL (modifies doc_xml in place)
#' @noRd
swap_document_styles <- function(doc_xml, style_map, ns) {
  # Swap paragraph styles
  pstyle_nodes <- xml2::xml_find_all(doc_xml, "//w:pStyle", ns)
  for (node in pstyle_nodes) {
    val <- xml2::xml_attr(node, "val")
    if (!is.na(val) && !is.null(style_map[[val]])) {
      xml2::xml_set_attr(node, "w:val", style_map[[val]])
    }
  }

  # Swap run (character) styles
  rstyle_nodes <- xml2::xml_find_all(doc_xml, "//w:rStyle", ns)
  for (node in rstyle_nodes) {
    val <- xml2::xml_attr(node, "val")
    if (!is.na(val) && !is.null(style_map[[val]])) {
      xml2::xml_set_attr(node, "w:val", style_map[[val]])
    }
  }

  # Swap table styles
  tblstyle_nodes <- xml2::xml_find_all(doc_xml, "//w:tblStyle", ns)
  for (node in tblstyle_nodes) {
    val <- xml2::xml_attr(node, "val")
    if (!is.na(val) && !is.null(style_map[[val]])) {
      xml2::xml_set_attr(node, "w:val", style_map[[val]])
    }
  }

  invisible(NULL)
}


#' Swap Style IDs in styles.xml
#'
#' Renames styleId attributes and updates basedOn, link, and next references.
#'
#' @param styles_xml xml2 document (word/styles.xml)
#' @param style_map Named list: Pandoc ID -> template ID
#' @param ns XML namespace vector
#' @return NULL (modifies styles_xml in place)
#' @noRd
swap_styles_xml <- function(styles_xml, style_map, ns) {
  style_nodes <- xml2::xml_find_all(styles_xml, "/w:styles/w:style", ns)

  for (node in style_nodes) {
    style_id <- xml2::xml_attr(node, "styleId")
    if (is.na(style_id)) next

    # Rename the styleId itself
    if (!is.null(style_map[[style_id]])) {
      xml2::xml_set_attr(node, "w:styleId", style_map[[style_id]])
    }

    # Update basedOn reference
    based_on <- xml2::xml_find_first(node, "w:basedOn", ns)
    if (!inherits(based_on, "xml_missing")) {
      val <- xml2::xml_attr(based_on, "val")
      if (!is.na(val) && !is.null(style_map[[val]])) {
        xml2::xml_set_attr(based_on, "w:val", style_map[[val]])
      }
    }

    # Update next reference
    next_node <- xml2::xml_find_first(node, "w:next", ns)
    if (!inherits(next_node, "xml_missing")) {
      val <- xml2::xml_attr(next_node, "val")
      if (!is.na(val) && !is.null(style_map[[val]])) {
        xml2::xml_set_attr(next_node, "w:val", style_map[[val]])
      }
    }

    # Update link reference
    link_node <- xml2::xml_find_first(node, "w:link", ns)
    if (!inherits(link_node, "xml_missing")) {
      val <- xml2::xml_attr(link_node, "val")
      if (!is.na(val) && !is.null(style_map[[val]])) {
        xml2::xml_set_attr(link_node, "w:val", style_map[[val]])
      }
    }
  }

  invisible(NULL)
}


#' Swap Style IDs in a Rendered DOCX
#'
#' Post-render step: reads style-map.json, renames Pandoc style IDs back to
#' template native IDs in both styles.xml and document.xml. Modifies the
#' DOCX file in place.
#'
#' @param docx_path Path to the rendered DOCX file
#' @param sidecar_dir Path to `_docstyle/` directory containing style-map.json
#' @return List with `swapped` (logical) and `n_mappings` (integer)
#' @export
swap_style_ids <- function(docx_path, sidecar_dir) {
  map_path <- file.path(sidecar_dir, "style-map.json")
  if (!file.exists(map_path)) {
    return(list(swapped = FALSE, n_mappings = 0L))
  }

  style_map <- jsonlite::read_json(map_path)
  if (length(style_map) == 0L) {
    return(list(swapped = FALSE, n_mappings = 0L))
  }

  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  temp <- extract_docx_temp(docx_path)
  on.exit(temp$cleanup(), add = TRUE)

  # Swap in document.xml
  doc_path <- file.path(temp$dir, "word", "document.xml")
  if (file.exists(doc_path)) {
    doc_xml <- xml2::read_xml(doc_path)
    swap_document_styles(doc_xml, style_map, ns)
    xml2::write_xml(doc_xml, doc_path)
  }

  # Swap in styles.xml
  styles_path <- file.path(temp$dir, "word", "styles.xml")
  if (file.exists(styles_path)) {
    styles_xml <- xml2::read_xml(styles_path)
    swap_styles_xml(styles_xml, style_map, ns)
    xml2::write_xml(styles_xml, styles_path)
  }

  # Swap in footnotes.xml, endnotes.xml, headers, footers
  for (extra_file in c("word/footnotes.xml", "word/endnotes.xml")) {
    extra_path <- file.path(temp$dir, extra_file)
    if (file.exists(extra_path)) {
      extra_xml <- xml2::read_xml(extra_path)
      swap_document_styles(extra_xml, style_map, ns)
      xml2::write_xml(extra_xml, extra_path)
    }
  }

  # Headers and footers
  hf_files <- list.files(file.path(temp$dir, "word"),
                         pattern = "^(header|footer)[0-9]*\\.xml$",
                         full.names = TRUE)
  for (hf_path in hf_files) {
    hf_xml <- xml2::read_xml(hf_path)
    swap_document_styles(hf_xml, style_map, ns)
    xml2::write_xml(hf_xml, hf_path)
  }

  # Re-zip
  docx_path_abs <- normalizePath(docx_path, mustWork = TRUE)
  old_wd <- getwd()
  on.exit(setwd(old_wd), add = TRUE)
  setwd(temp$dir)

  all_files <- list.files(".", recursive = TRUE, all.files = TRUE)
  file.remove(docx_path_abs)
  result <- utils::zip(docx_path_abs, files = all_files, flags = "-r9Xq")
  if (result != 0) stop("Failed to re-zip DOCX after style swap: ", docx_path_abs)

  message("[style-map] Swapped ", length(style_map), " style ID(s) in ",
          basename(docx_path))

  list(swapped = TRUE, n_mappings = length(style_map))
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-style-map.R")'`
Expected: All 10 tests PASS

- [ ] **Step 5: Commit**

```bash
git add R/style_map.R tests/testthat/test-style-map.R
git commit -m "feat: add swap_style_ids() for post-render template ID restoration"
```

---

### Task 3: CSS overlay — skip cascade for template styles

**Files:**
- Modify: `R/css_injection.R:207-260`
- Modify: `tests/testthat/test-style-map.R`

When a template is used, `cascade_css_to_children()` should skip any style that exists in the template — the template author's values are authoritative.

- [ ] **Step 1: Write failing test for template-aware cascade skip**

Append to `tests/testthat/test-style-map.R`:

```r
test_that("cascade_css_to_children skips template-resident styles", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # styles.xml with Normal having font properties, and BodyText as child
  styles_xml <- xml2::read_xml(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:style w:type="paragraph" w:styleId="Normal">',
    '  <w:name w:val="Normal"/>',
    '  <w:pPr><w:spacing w:after="120"/></w:pPr>',
    '  <w:rPr><w:rFonts w:ascii="Palatino"/></w:rPr>',
    '</w:style>',
    '<w:style w:type="paragraph" w:styleId="BodyText">',
    '  <w:name w:val="Body Text"/>',
    '  <w:basedOn w:val="Normal"/>',
    '</w:style>',
    '<w:style w:type="paragraph" w:styleId="Heading1">',
    '  <w:name w:val="heading 1"/>',
    '  <w:basedOn w:val="Normal"/>',
    '</w:style>',
    '</w:styles>'
  ))

  # CSS styles: p selector (Normal) has properties
  css_styles <- list(p = list(`font-family` = "Palatino", `margin-bottom` = "10pt"))

  # With template_styles = NULL (CSS-first mode), cascade happens
  cascade_css_to_children(styles_xml, ns, css_styles, template_styles = NULL)
  bt_spacing <- xml2::xml_find_first(
    styles_xml, "//w:style[@w:styleId='BodyText']/w:pPr/w:spacing", ns
  )
  expect_false(inherits(bt_spacing, "xml_missing"))

  # Reset: reload XML
  styles_xml2 <- xml2::read_xml(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:style w:type="paragraph" w:styleId="Normal">',
    '  <w:name w:val="Normal"/>',
    '  <w:pPr><w:spacing w:after="120"/></w:pPr>',
    '  <w:rPr><w:rFonts w:ascii="Palatino"/></w:rPr>',
    '</w:style>',
    '<w:style w:type="paragraph" w:styleId="BodyText">',
    '  <w:name w:val="Body Text"/>',
    '  <w:basedOn w:val="Normal"/>',
    '</w:style>',
    '<w:style w:type="paragraph" w:styleId="Heading1">',
    '  <w:name w:val="heading 1"/>',
    '  <w:basedOn w:val="Normal"/>',
    '</w:style>',
    '</w:styles>'
  ))

  # With template_styles including BodyText, cascade skips it
  cascade_css_to_children(styles_xml2, ns, css_styles,
                          template_styles = c("BodyText", "Heading1"))
  bt_spacing2 <- xml2::xml_find_first(
    styles_xml2, "//w:style[@w:styleId='BodyText']/w:pPr/w:spacing", ns
  )
  expect_true(inherits(bt_spacing2, "xml_missing"))
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-style-map.R")'`
Expected: FAIL — `cascade_css_to_children` doesn't accept `template_styles` parameter

- [ ] **Step 3: Add `template_styles` parameter to `cascade_css_to_children()`**

In `R/css_injection.R`, modify the function signature at line 207:

Change:
```r
cascade_css_to_children <- function(styles_xml, ns, css_styles) {
```

To:
```r
cascade_css_to_children <- function(styles_xml, ns, css_styles, template_styles = NULL) {
```

Then inside the `for (child_id in cascade_chains[[parent_id]])` loop (after line 245 `if (child_id %in% css_styled_ids) next`), add:

```r
      # Skip children that exist in the template — template values are authoritative
      if (!is.null(template_styles) && child_id %in% template_styles) next
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-style-map.R")'`
Expected: All 11 tests PASS

- [ ] **Step 5: Run full test suite for regression**

Run: `Rscript -e 'devtools::test()'`
Expected: All ~2750 tests PASS (existing cascade tests still pass because default `template_styles = NULL` preserves current behaviour)

- [ ] **Step 6: Commit**

```bash
git add R/css_injection.R tests/testthat/test-style-map.R
git commit -m "feat: skip CSS cascade for template-resident styles"
```

---

### Task 4: Pruning adjustment — preserve template styles

**Files:**
- Modify: `R/style_manager.R:371-410`
- Modify: `tests/testthat/test-style-map.R`

When a template is used, all styles from the template's `styles.xml` should be preserved during pruning, not just the ones used in the output document.

- [ ] **Step 1: Write failing test for template-aware pruning**

Append to `tests/testthat/test-style-map.R`:

```r
test_that("get_allowed_styles includes all template styles when template_path provided", {
  # Create a minimal template docx with custom styles
  temp_dir <- tempfile("template_prune_")
  dir.create(file.path(temp_dir, "word"), recursive = TRUE)
  dir.create(file.path(temp_dir, "_rels"), recursive = TRUE)

  writeLines('<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="xml" ContentType="application/xml"/>
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
</Types>', file.path(temp_dir, "[Content_Types].xml"))

  writeLines('<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>', file.path(temp_dir, "_rels", ".rels"))

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body><w:p/></w:body></w:document>'
  ), file.path(temp_dir, "word", "document.xml"))

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:style w:type="paragraph" w:styleId="Normal"><w:name w:val="Normal"/></w:style>',
    '<w:style w:type="paragraph" w:styleId="MDPI21heading1"><w:name w:val="MDPI heading"/></w:style>',
    '<w:style w:type="paragraph" w:styleId="MDPI31text"><w:name w:val="MDPI text"/></w:style>',
    '</w:styles>'
  ), file.path(temp_dir, "word", "styles.xml"))

  template_path <- tempfile(fileext = ".docx")
  old_wd <- getwd()
  setwd(temp_dir)
  utils::zip(template_path, files = list.files(".", recursive = TRUE, all.files = TRUE),
             flags = "-r9Xq")
  setwd(old_wd)

  allowed <- get_allowed_styles(config = NULL, sidecar_dir = NULL,
                                template_path = template_path)
  expect_true("MDPI21heading1" %in% allowed)
  expect_true("MDPI31text" %in% allowed)
  expect_true("Normal" %in% allowed)

  unlink(c(temp_dir, template_path), recursive = TRUE)
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-style-map.R")'`
Expected: FAIL — `get_allowed_styles()` doesn't accept `template_path`

- [ ] **Step 3: Add `template_path` parameter to `get_allowed_styles()`**

In `R/style_manager.R`, modify `get_allowed_styles()` at line 371:

Change:
```r
get_allowed_styles <- function(config = NULL, sidecar_dir = NULL) {
```

To:
```r
get_allowed_styles <- function(config = NULL, sidecar_dir = NULL, template_path = NULL) {
```

After the existing "Styles from reference.docx" block (after line 403), add:

```r
  # 2c. All styles from template (if template mode)
  if (!is.null(template_path) && file.exists(template_path)) {
    template_inventory <- extract_style_inventory(template_path, output_dir = NULL)
    template_styles <- names(template_inventory$styles)
    allowed <- c(allowed, template_styles)
  }
```

Also update `prune_styles_file()` at line 582 to accept and pass through `template_path`:

Change:
```r
prune_styles_file <- function(docx_path, config = NULL, sidecar_dir = NULL,
                              verbose = FALSE) {
```

To:
```r
prune_styles_file <- function(docx_path, config = NULL, sidecar_dir = NULL,
                              template_path = NULL, verbose = FALSE) {
```

And change the call at line 600:
```r
  allowed <- get_allowed_styles(config, sidecar_dir)
```

To:
```r
  allowed <- get_allowed_styles(config, sidecar_dir, template_path)
```

Similarly update `prune_styles()` at line 548 to accept and pass through `template_path`:

Change:
```r
prune_styles <- function(doc, config = NULL, sidecar_dir = NULL, verbose = FALSE) {
```

To:
```r
prune_styles <- function(doc, config = NULL, sidecar_dir = NULL,
                         template_path = NULL, verbose = FALSE) {
```

And change the call at line 559:
```r
  allowed <- get_allowed_styles(config, sidecar_dir)
```

To:
```r
  allowed <- get_allowed_styles(config, sidecar_dir, template_path)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-style-map.R")'`
Expected: All 12 tests PASS

- [ ] **Step 5: Run full test suite for regression**

Run: `Rscript -e 'devtools::test()'`
Expected: All tests PASS (default `template_path = NULL` preserves current behaviour)

- [ ] **Step 6: Commit**

```bash
git add R/style_manager.R tests/testthat/test-style-map.R
git commit -m "feat: preserve template styles during pruning"
```

---

### Task 5: Pre-render integration — generate-reference.R

**Files:**
- Modify: `_extensions/docstyle/generate-reference.R`
- Modify: `R/page_layout.R`

Wire up template mode in the pre-render hook: detect template file, call `build_style_map()`, include template hash in cache key, pass template style IDs to cascade skip.

- [ ] **Step 1: Add template detection message to `generate_reference_doc()`**

In `R/page_layout.R`, after the file-path branch at line 91-99, add a message for template mode:

Change lines 91-99:
```r
  } else if (!is.null(base_doc)) {
    # Resolve relative path for file-based base-doc
    if (!is.list(config_path) && file.exists(config_path)) {
      resolved <- file.path(dirname(config_path), base_doc)
      if (file.exists(resolved)) base_doc <- resolved
    }
    if (!file.exists(base_doc)) {
      stop("Base reference document not found: ", base_doc)
    }
```

To:
```r
  } else if (!is.null(base_doc)) {
    # Resolve relative path for file-based base-doc
    if (!is.list(config_path) && file.exists(config_path)) {
      resolved <- file.path(dirname(config_path), base_doc)
      if (file.exists(resolved)) base_doc <- resolved
    }
    if (!file.exists(base_doc)) {
      stop("Base reference document not found: ", base_doc)
    }
    message("[generate-reference] Template mode: using ", basename(base_doc))
```

- [ ] **Step 2: Pass `template_styles` to cascade in `inject_css_styles()` call**

In `R/page_layout.R`, modify the CSS injection call at line 136. Add logic to detect template mode and pass template style IDs:

Change:
```r
  # Inject CSS styles into Word styles.xml
  if (!is.null(css_styles)) {
    doc <- inject_css_styles(doc, css_styles, toc_config = ds$toc)
  }
```

To:
```r
  # Inject CSS styles into Word styles.xml
  if (!is.null(css_styles)) {
    # In template mode, collect template style IDs to skip cascade
    template_style_ids <- NULL
    if (!is.null(ds$`base-doc`) && ds$`base-doc` != "pandoc") {
      template_style_ids <- get_template_style_ids(base_doc)
    }
    doc <- inject_css_styles(doc, css_styles, toc_config = ds$toc,
                             template_styles = template_style_ids)
  }
```

- [ ] **Step 3: Add `get_template_style_ids()` helper to `R/style_map.R`**

Append to `R/style_map.R`:

```r
#' Get All Style IDs from a Template File
#'
#' Reads the template's styles.xml and returns all style IDs. Used to determine
#' which styles should skip CSS cascade (template author's values are authoritative).
#'
#' @param template_path Path to template .docx or .dot file
#' @return Character vector of style IDs, or NULL on error
#' @noRd
get_template_style_ids <- function(template_path) {
  tryCatch(
    with_docx_temp(template_path, function(temp_dir) {
      styles_path <- file.path(temp_dir, "word", "styles.xml")
      if (!file.exists(styles_path)) return(NULL)

      ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
      styles_xml <- xml2::read_xml(styles_path)
      nodes <- xml2::xml_find_all(styles_xml, "/w:styles/w:style/@w:styleId", ns)
      xml2::xml_text(nodes)
    }),
    error = function(e) {
      warning("[style-map] Could not read template styles: ",
              conditionMessage(e), call. = FALSE)
      NULL
    }
  )
}
```

- [ ] **Step 4: Add `template_styles` parameter to `inject_css_styles()`**

In `R/css_injection.R`, modify the function signature at line 20:

Change:
```r
inject_css_styles <- function(doc, css_styles, toc_config = NULL) {
```

To:
```r
inject_css_styles <- function(doc, css_styles, toc_config = NULL, template_styles = NULL) {
```

Then find the `cascade_css_to_children()` call inside `inject_css_styles()` and pass the parameter through. Search for:
```r
  cascade_css_to_children(styles_xml, ns, css_styles)
```

Change to:
```r
  cascade_css_to_children(styles_xml, ns, css_styles, template_styles = template_styles)
```

- [ ] **Step 5: Wire up `build_style_map()` in `generate-reference.R`**

In `_extensions/docstyle/generate-reference.R`, after the `generate_reference_doc()` call (around line 239), add:

```r
# Generate style map if template mode
base_doc_config <- ds[["base-doc"]]
is_template_mode <- !is.null(base_doc_config) && base_doc_config != "pandoc"

if (is_template_mode) {
  # Resolve template path relative to project
  template_path <- base_doc_config
  resolved_template <- file.path(project_dir, template_path)
  if (file.exists(resolved_template)) template_path <- resolved_template

  # Only regenerate style-map.json if no user-edited version exists,
  # or if the cache was invalidated (hash changed)
  style_map_path <- file.path(sidecar_dir, "style-map.json")
  if (!file.exists(style_map_path) || !cache_valid) {
    docstyle::build_style_map(template_path, sidecar_dir = sidecar_dir)
  } else {
    message("[generate-reference] Using existing style-map.json (template unchanged)")
  }
}
```

- [ ] **Step 6: Include template file hash in cache key**

In `generate-reference.R`, find the hash computation section (around line 142-171). Add template content to the hash input:

After the existing hash inputs, add:

```r
# Include template file hash if template mode
if (is_template_mode) {
  template_path_for_hash <- base_doc_config
  resolved <- file.path(project_dir, template_path_for_hash)
  if (file.exists(resolved)) template_path_for_hash <- resolved
  if (file.exists(template_path_for_hash)) {
    hash_inputs <- c(hash_inputs, digest::digest(file = template_path_for_hash))
  }
}
```

Note: The `is_template_mode` variable needs to be computed before the hash section. Move the template mode detection up:

```r
# Detect template mode (needed for hash computation)
base_doc_config <- ds[["base-doc"]]
is_template_mode <- !is.null(base_doc_config) && base_doc_config != "pandoc"
```

Place this before the hash computation block (around line 135).

- [ ] **Step 7: Run full test suite**

Run: `Rscript -e 'devtools::test()'`
Expected: All tests PASS

- [ ] **Step 8: Commit**

```bash
git add R/page_layout.R R/css_injection.R R/style_map.R _extensions/docstyle/generate-reference.R
git commit -m "feat: wire up template mode in pre-render pipeline"
```

---

### Task 6: Post-render integration — update-field-codes.R

**Files:**
- Modify: `_extensions/docstyle/update-field-codes.R`

Call `swap_style_ids()` before `finalize_docx()` so section assembly and other post-render steps see the final style names. Pass `template_path` to pruning.

- [ ] **Step 1: Add style swap call before finalize_docx()**

In `_extensions/docstyle/update-field-codes.R`, before the finalize step (around line 324), add:

```r
  # Step 4b: Swap style IDs (template mode only)
  n_styles_swapped <- 0L
  style_map_path <- file.path(output_dir, "style-map.json")
  if (file.exists(style_map_path)) {
    tryCatch({
      swap_result <- docstyle::swap_style_ids(
        docx_path = docx_path,
        sidecar_dir = output_dir
      )
      n_styles_swapped <- swap_result$n_mappings
    }, error = function(e) {
      message("[docstyle] Error swapping style IDs: ", conditionMessage(e))
    })
  }
```

- [ ] **Step 2: Pass template_path to prune_styles_file()**

In `update-field-codes.R`, modify the pruning call (around line 343):

First, resolve the template path from config. Add before the pruning block:

```r
  # Resolve template path for pruning (preserve template styles)
  template_path_for_prune <- NULL
  if (!is.null(ds) && !is.null(ds[["base-doc"]]) && ds[["base-doc"]] != "pandoc") {
    template_path_for_prune <- ds[["base-doc"]]
    resolved <- file.path(project_dir, template_path_for_prune)
    if (file.exists(resolved)) template_path_for_prune <- resolved
  }
```

Then change:
```r
    n_styles_pruned <- docstyle::prune_styles_file(
      docx_path = docx_path,
      sidecar_dir = output_dir,
      verbose = debug_mode
    )
```

To:
```r
    n_styles_pruned <- docstyle::prune_styles_file(
      docx_path = docx_path,
      sidecar_dir = output_dir,
      template_path = template_path_for_prune,
      verbose = debug_mode
    )
```

- [ ] **Step 3: Add swap count to summary output**

In `update-field-codes.R`, find the summary reporting section (around line 385). Add to the summary:

```r
  if (n_styles_swapped > 0L) {
    parts <- c(parts, paste0(n_styles_swapped, " style(s) swapped"))
  }
```

- [ ] **Step 4: Ensure config is available for template path resolution**

Check that `ds` (the `docstyle:` config section) is available at the point where we need it. If it's parsed earlier in the script, it's already in scope. If not, add:

```r
  # Parse docstyle config for template mode detection
  config_path <- file.path(project_dir, "_quarto.yml")
  ds <- NULL
  if (file.exists(config_path)) {
    config <- yaml::read_yaml(config_path)
    ds <- config$docstyle
  }
```

Place this near the top of the per-file processing loop, before the style swap call.

- [ ] **Step 5: Commit**

```bash
git add _extensions/docstyle/update-field-codes.R
git commit -m "feat: wire up style swap and template pruning in post-render"
```

---

### Task 7: NAMESPACE and documentation

**Files:**
- Modify: `NAMESPACE` (via `devtools::document()`)

Register the new exported functions.

- [ ] **Step 1: Run `devtools::document()`**

Run: `Rscript -e 'devtools::document()'`

This regenerates `NAMESPACE` from the roxygen `@export` tags in `R/style_map.R`.

Expected new exports: `build_style_map_from_xml`, `build_style_map`, `swap_style_ids`

- [ ] **Step 2: Verify NAMESPACE**

Run: `grep -E "build_style_map|swap_style_ids" NAMESPACE`
Expected: Three export lines

- [ ] **Step 3: Run full test suite**

Run: `Rscript -e 'devtools::test()'`
Expected: All tests PASS

- [ ] **Step 4: Commit**

```bash
git add NAMESPACE man/
git commit -m "docs: register style_map exports in NAMESPACE"
```

---

### Task 8: Integration test with MDPI fixture

**Files:**
- Modify: `tests/testthat/test-style-map.R`

Test the full template mode flow with a synthetic MDPI-like template fixture.

- [ ] **Step 1: Write integration test**

Append to `tests/testthat/test-style-map.R`:

```r
test_that("full template mode flow: build map + swap IDs round-trips correctly", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # Create a template docx with MDPI-style custom names
  template_dir <- tempfile("template_")
  dir.create(file.path(template_dir, "word"), recursive = TRUE)
  dir.create(file.path(template_dir, "_rels"), recursive = TRUE)

  writeLines('<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="xml" ContentType="application/xml"/>
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
</Types>', file.path(template_dir, "[Content_Types].xml"))

  writeLines('<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>', file.path(template_dir, "_rels", ".rels"))

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body><w:p/></w:body></w:document>'
  ), file.path(template_dir, "word", "document.xml"))

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:style w:type="paragraph" w:styleId="Normal">',
    '  <w:name w:val="Normal"/>',
    '</w:style>',
    '<w:style w:type="paragraph" w:styleId="MDPI21heading1">',
    '  <w:name w:val="MDPI heading 1"/>',
    '  <w:pPr><w:outlineLvl w:val="0"/></w:pPr>',
    '</w:style>',
    '<w:style w:type="paragraph" w:styleId="MDPI22heading2">',
    '  <w:name w:val="MDPI heading 2"/>',
    '  <w:pPr><w:outlineLvl w:val="1"/></w:pPr>',
    '</w:style>',
    '<w:style w:type="paragraph" w:styleId="MDPI31text">',
    '  <w:name w:val="Body Text"/>',
    '</w:style>',
    '</w:styles>'
  ), file.path(template_dir, "word", "styles.xml"))

  template_path <- tempfile(fileext = ".docx")
  old_wd <- getwd()
  setwd(template_dir)
  utils::zip(template_path, files = list.files(".", recursive = TRUE, all.files = TRUE),
             flags = "-r9Xq")
  setwd(old_wd)

  # Step 1: Build style map
  sidecar_dir <- tempfile("sidecar_")
  dir.create(sidecar_dir)
  style_map <- build_style_map(template_path, sidecar_dir = sidecar_dir)

  expect_equal(style_map[["Heading1"]], "MDPI21heading1")
  expect_equal(style_map[["Heading2"]], "MDPI22heading2")
  expect_equal(style_map[["BodyText"]], "MDPI31text")

  # Verify JSON was written
  map_path <- file.path(sidecar_dir, "style-map.json")
  expect_true(file.exists(map_path))
  loaded_map <- jsonlite::read_json(map_path)
  expect_equal(loaded_map$Heading1, "MDPI21heading1")

  # Step 2: Create a "rendered" docx with Pandoc-style IDs
  render_dir <- tempfile("rendered_")
  dir.create(file.path(render_dir, "word"), recursive = TRUE)
  dir.create(file.path(render_dir, "_rels"), recursive = TRUE)

  writeLines('<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="xml" ContentType="application/xml"/>
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
</Types>', file.path(render_dir, "[Content_Types].xml"))

  writeLines('<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>', file.path(render_dir, "_rels", ".rels"))

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>',
    '<w:r><w:t>Introduction</w:t></w:r></w:p>',
    '<w:p><w:pPr><w:pStyle w:val="BodyText"/></w:pPr>',
    '<w:r><w:t>Some text</w:t></w:r></w:p>',
    '<w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr>',
    '<w:r><w:t>Methods</w:t></w:r></w:p>',
    '</w:body></w:document>'
  ), file.path(render_dir, "word", "document.xml"))

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:style w:type="paragraph" w:styleId="Normal">',
    '<w:name w:val="Normal"/></w:style>',
    '<w:style w:type="paragraph" w:styleId="Heading1">',
    '<w:name w:val="heading 1"/>',
    '<w:basedOn w:val="Normal"/></w:style>',
    '<w:style w:type="paragraph" w:styleId="Heading2">',
    '<w:name w:val="heading 2"/>',
    '<w:basedOn w:val="Normal"/></w:style>',
    '<w:style w:type="paragraph" w:styleId="BodyText">',
    '<w:name w:val="Body Text"/>',
    '<w:basedOn w:val="Normal"/></w:style>',
    '</w:styles>'
  ), file.path(render_dir, "word", "styles.xml"))

  rendered_path <- tempfile(fileext = ".docx")
  setwd(render_dir)
  utils::zip(rendered_path, files = list.files(".", recursive = TRUE, all.files = TRUE),
             flags = "-r9Xq")
  setwd(old_wd)

  # Step 3: Swap style IDs
  result <- swap_style_ids(rendered_path, sidecar_dir = sidecar_dir)
  expect_true(result$swapped)
  expect_equal(result$n_mappings, 3L)

  # Step 4: Verify output has template style names
  verify_dir <- tempfile("verify_")
  utils::unzip(rendered_path, exdir = verify_dir)

  doc_xml <- xml2::read_xml(file.path(verify_dir, "word", "document.xml"))
  pstyles <- xml2::xml_attr(
    xml2::xml_find_all(doc_xml, "//w:pStyle", ns), "val"
  )
  expect_equal(pstyles, c("MDPI21heading1", "MDPI31text", "MDPI22heading2"))

  styles_xml <- xml2::read_xml(file.path(verify_dir, "word", "styles.xml"))
  style_ids <- xml2::xml_attr(
    xml2::xml_find_all(styles_xml, "//w:style", ns), "styleId"
  )
  expect_true("MDPI21heading1" %in% style_ids)
  expect_true("MDPI22heading2" %in% style_ids)
  expect_true("MDPI31text" %in% style_ids)
  expect_false("Heading1" %in% style_ids)
  expect_false("Heading2" %in% style_ids)
  expect_false("BodyText" %in% style_ids)

  unlink(c(template_dir, sidecar_dir, render_dir, rendered_path, verify_dir),
         recursive = TRUE)
})

test_that("CSS-first mode unchanged when base-doc is omitted", {
  # build_style_map on a minimal docx with standard names produces empty map
  temp_dir <- tempfile("standard_")
  dir.create(file.path(temp_dir, "word"), recursive = TRUE)
  dir.create(file.path(temp_dir, "_rels"), recursive = TRUE)

  writeLines('<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="xml" ContentType="application/xml"/>
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
</Types>', file.path(temp_dir, "[Content_Types].xml"))

  writeLines('<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>', file.path(temp_dir, "_rels", ".rels"))

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body><w:p/></w:body></w:document>'
  ), file.path(temp_dir, "word", "document.xml"))

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:style w:type="paragraph" w:styleId="Normal"><w:name w:val="Normal"/></w:style>',
    '<w:style w:type="paragraph" w:styleId="Heading1">',
    '<w:name w:val="heading 1"/>',
    '<w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style>',
    '<w:style w:type="paragraph" w:styleId="BodyText">',
    '<w:name w:val="Body Text"/></w:style>',
    '</w:styles>'
  ), file.path(temp_dir, "word", "styles.xml"))

  standard_path <- tempfile(fileext = ".docx")
  old_wd <- getwd()
  setwd(temp_dir)
  utils::zip(standard_path, files = list.files(".", recursive = TRUE, all.files = TRUE),
             flags = "-r9Xq")
  setwd(old_wd)

  map <- build_style_map(standard_path)
  expect_equal(map, list())

  # swap_style_ids with no style-map.json is a no-op
  sidecar <- tempfile("sidecar_")
  dir.create(sidecar)
  result <- swap_style_ids(standard_path, sidecar_dir = sidecar)
  expect_false(result$swapped)
  expect_equal(result$n_mappings, 0L)

  unlink(c(temp_dir, standard_path, sidecar), recursive = TRUE)
})
```

- [ ] **Step 2: Run tests**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-style-map.R")'`
Expected: All 14 tests PASS

- [ ] **Step 3: Run full test suite**

Run: `Rscript -e 'devtools::test()'`
Expected: All tests PASS

- [ ] **Step 4: Commit**

```bash
git add tests/testthat/test-style-map.R
git commit -m "test: add integration tests for template mode round-trip"
```

---

## Self-review

**1. Spec coverage:**
- Configuration (`base-doc:` with file path) → Task 5 (pre-render) + existing `generate_reference_doc()` already handles file paths
- Style map generation → Task 1 (`build_style_map()`)
- CSS overlay semantics (skip cascade for template styles) → Task 3
- Post-render style swap → Task 2 (`swap_style_ids()`)
- Style pruning adjustment → Task 4
- Cache invalidation (template hash) → Task 5, step 6
- User-editable `style-map.json` → Task 5 (only regenerates when cache invalid)
- Harvest direction (no changes) → confirmed, no task needed
- Regression (CSS-first unchanged) → Task 8, final test

**2. Placeholder scan:** No TBD, TODO, or vague steps found. All steps have code blocks.

**3. Type consistency:**
- `build_style_map_from_xml()` — consistent across Tasks 1, 8
- `swap_style_ids()` returns `list(swapped, n_mappings)` — consistent in Tasks 2, 6, 8
- `template_styles` parameter name — consistent across Tasks 3, 5
- `template_path` parameter name — consistent across Tasks 4, 6
- `style_map` as named list — consistent throughout
