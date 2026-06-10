# Anchor positioning Phase 2a — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename "float" to "anchor" throughout, then add positioned image support via `wp:anchor` + `pic:pic` with full round-trip (render + harvest).

**Architecture:** CSS properties on any class trigger anchor positioning. Lua emits `DOCSTYLE_ANCHOR::` text markers. R post-render assembly inspects content type (table vs image) and picks the appropriate OOXML mechanism. Harvest detects both `w:tblpPr` tables and `wp:anchor` images, mapping back to CSS vocabulary.

**Tech stack:** R (xml2, jsonlite), Lua (Pandoc filters), OOXML (WordprocessingML + DrawingML)

**Spec:** `dev/plans/2026-04-06-anchor-positioning-phase2a-design.md`

**Issues:** #119 (Phase 2a), #116 (umbrella)

---

## File structure

| File | Responsibility |
|------|---------------|
| `R/anchor_assembly.R` | Post-render: scan markers, detect content type, build table or image anchors, remove markers |
| `R/css_parser.R` | CSS → anchor style extraction, `css_to_emu()` unit conversion |
| `R/field_codes.R` | Schema validation and dispatch for `anchor` type (backward compat for `float`) |
| `R/generated_content.R` | Block-level field code detection (add `"anchor"` type) |
| `R/docx_to_qmd.R` | Harvest: detect `wp:anchor` images, extract positioning, emit QMD divs |
| `R/finalize_docx.R` | Call `assemble_anchors()` instead of `assemble_float_tables()` |
| `R/use_docstyle.R` | Extension file registry: `anchor.lua` |
| `_extensions/docstyle/anchor.lua` | Lua filter: emit `DOCSTYLE_ANCHOR::` markers for anchor-eligible divs |
| `_extensions/docstyle/_extension.yml` | Filter chain: rename entry |
| `inst/schema/docstyle-field-codes.json` | Replace `float_*` sections with `anchor_payload_fields` |
| `tests/testthat/test-css-anchor.R` | CSS extraction and EMU conversion tests |
| `tests/testthat/test-anchor-assembly.R` | Assembly: table anchors, image anchors, content detection, backward compat |
| `tests/testthat/test-harvest-anchor.R` | Harvest: detect anchored images, extract properties, round-trip |
| `tests/testthat/test-field-codes.R` | Schema and dispatch tests for anchor type |

---

### Task 1: Rename CSS functions and tests (float → anchor)

Mechanical rename of CSS-layer functions. No new logic.

**Files:**
- Modify: `R/css_parser.R:470-525`
- Rename: `tests/testthat/test-css-float.R` → `tests/testthat/test-css-anchor.R`

- [ ] **Step 1: Rename R functions in css_parser.R**

In `R/css_parser.R`, rename `css_to_float_style` → `css_to_anchor_style` and `extract_float_styles` → `extract_anchor_styles`. Update all internal references and roxygen comments.

```r
# Line 470-494: Rename function and update docs
#' Extract anchor positioning properties from CSS
#'
#' Extracts anchor positioning properties from a parsed CSS property list.
#' Returns NULL if no anchor-triggering properties are present.
#'
#' @param props Named list of CSS properties for a single selector.
#' @return Named list of anchor style properties, or NULL if not an anchor.
#' @export
css_to_anchor_style <- function(props) {
  if (is.null(props)) return(NULL)

  # Detection: must have at least one anchor property
  v_anchor <- props[["vertical-anchor"]]
  h_anchor <- props[["horizontal-anchor"]]
  if (is.null(v_anchor) && is.null(h_anchor)) return(NULL)

  list(
    vertical_anchor  = v_anchor %||% "text",
    horizontal_anchor = h_anchor %||% "margin",
    position_y       = props[["position-y"]] %||% "0",
    position_x       = props[["position-x"]] %||% "0",
    float_width      = props[["float-width"]],
    wrap_style       = props[["wrap-style"]] %||% "square",
    wrap_side        = props[["wrap-side"]] %||% "both",
    wrap_distance    = props[["wrap-distance"]] %||% "0 198dxa 0 198dxa",
    z_layer          = props[["z-layer"]] %||% "front"
  )
}

# Line 497-525: Rename function and update docs
#' Extract all anchor styles from parsed CSS
#'
#' Scans parsed CSS for class selectors that contain anchor positioning
#' properties (`vertical-anchor` or `horizontal-anchor`). Any class selector
#' with these properties becomes an anchor-eligible class.
#'
#' @param css_styles Parsed CSS list from `read_css()`.
#' @return Named list of anchor style configurations keyed by class name.
#' @export
extract_anchor_styles <- function(css_styles) {
  if (is.null(css_styles)) return(list())

  anchor_styles <- list()
  for (sel in names(css_styles)) {
    if (!grepl("^\\.[a-zA-Z]", sel)) next
    if (grepl("\\s", sel)) next

    style <- css_to_anchor_style(css_styles[[sel]])
    if (!is.null(style)) {
      class_name <- sub("^\\.", "", sel)
      anchor_styles[[class_name]] <- style
    }
  }

  anchor_styles
}
```

- [ ] **Step 2: Rename test file and update test function names**

Rename `tests/testthat/test-css-float.R` to `tests/testthat/test-css-anchor.R`. Update all references from `css_to_float_style` → `css_to_anchor_style` and `extract_float_styles` → `extract_anchor_styles`. Add `z_layer` test.

```r
# tests/testthat/test-css-anchor.R
# Tests for anchor CSS property extraction

test_that("css_to_anchor_style() extracts all positioning properties", {
  props <- list(
    `vertical-anchor` = "text",
    `horizontal-anchor` = "margin",
    `position-y` = "0",
    `position-x` = "0",
    `float-width` = "250pt",
    `wrap-style` = "square",
    `wrap-side` = "both",
    `wrap-distance` = "0 198dxa 0 198dxa",
    `z-layer` = "behind"
  )

  result <- css_to_anchor_style(props)

  expect_equal(result$vertical_anchor, "text")
  expect_equal(result$horizontal_anchor, "margin")
  expect_equal(result$position_y, "0")
  expect_equal(result$position_x, "0")
  expect_equal(result$float_width, "250pt")
  expect_equal(result$wrap_style, "square")
  expect_equal(result$wrap_side, "both")
  expect_equal(result$wrap_distance, "0 198dxa 0 198dxa")
  expect_equal(result$z_layer, "behind")
})

test_that("css_to_anchor_style() returns NULL when no anchor properties", {
  props <- list(`font-size` = "12pt", `color` = "#000000")
  result <- css_to_anchor_style(props)
  expect_null(result)
})

test_that("css_to_anchor_style() applies defaults for missing optional properties", {
  props <- list(`vertical-anchor` = "page", `horizontal-anchor` = "margin")
  result <- css_to_anchor_style(props)

  expect_equal(result$vertical_anchor, "page")
  expect_equal(result$horizontal_anchor, "margin")
  expect_equal(result$position_y, "0")
  expect_equal(result$position_x, "0")
  expect_null(result$float_width)
  expect_equal(result$wrap_style, "square")
  expect_equal(result$wrap_side, "both")
  expect_equal(result$wrap_distance, "0 198dxa 0 198dxa")
  expect_equal(result$z_layer, "front")
})

test_that("extract_anchor_styles() finds anchor-eligible selectors", {
  css_styles <- list(
    `.column-margin` = list(
      `vertical-anchor` = "text",
      `horizontal-anchor` = "margin",
      `float-width` = "250pt"
    ),
    `.journal-sidebar` = list(
      `vertical-anchor` = "page",
      `horizontal-anchor` = "margin",
      `position-y` = "11461dxa",
      `float-width` = "2410dxa"
    ),
    `body` = list(`font-size` = "12pt"),
    `h1` = list(`font-size` = "24pt")
  )

  result <- extract_anchor_styles(css_styles)

  expect_equal(length(result), 2)
  expect_true("column-margin" %in% names(result))
  expect_true("journal-sidebar" %in% names(result))
  expect_equal(result$`column-margin`$vertical_anchor, "text")
  expect_equal(result$`journal-sidebar`$position_y, "11461dxa")
})

test_that("extract_anchor_styles() returns empty list when no anchor selectors", {
  css_styles <- list(
    `body` = list(`font-size` = "12pt"),
    `.table-formal` = list(`border-bottom` = "1pt solid #000000")
  )

  result <- extract_anchor_styles(css_styles)
  expect_equal(length(result), 0)
})

test_that("extract_anchor_styles() handles NULL input", {
  expect_equal(extract_anchor_styles(NULL), list())
})
```

- [ ] **Step 3: Delete old test file**

```bash
git rm tests/testthat/test-css-float.R
```

- [ ] **Step 4: Run tests to verify rename works**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-css-anchor.R")'`
Expected: All 6 tests PASS

- [ ] **Step 5: Update NAMESPACE**

Run: `Rscript -e 'devtools::document()'`

This updates NAMESPACE to export `css_to_anchor_style` and `extract_anchor_styles` instead of the old names.

- [ ] **Step 6: Update callers of renamed functions**

Search for `extract_float_styles` and `css_to_float_style` in all R files and update. The main caller is in `R/generate_reference.R` (pre-render). Search with:

```bash
grep -rn "float_styles\|extract_float_styles\|css_to_float_style" R/
```

Update each occurrence. The key change in `generate_reference.R` (or wherever `extract_float_styles` is called):

```r
# Old:
float_styles <- extract_float_styles(css_styles)
# New:
anchor_styles <- extract_anchor_styles(css_styles)
```

And in `page-config.json` writing:

```r
# Old:
page_config$float_styles <- float_styles
# New:
page_config$anchor_styles <- anchor_styles
```

- [ ] **Step 7: Commit**

```bash
git add R/css_parser.R tests/testthat/test-css-anchor.R R/generate_reference.R NAMESPACE
git add -u  # catches deleted test-css-float.R
git commit -m "Rename float CSS functions to anchor (Phase 2a rename)"
```

---

### Task 2: Add css_to_emu() unit conversion

New function for DrawingML EMU conversion, following the established `css_to_twips()` pattern.

**Files:**
- Modify: `R/css_parser.R` (add function after `css_to_eighth_points`)
- Modify: `tests/testthat/test-css-anchor.R` (add EMU tests)

- [ ] **Step 1: Write failing tests for css_to_emu()**

Append to `tests/testthat/test-css-anchor.R`:

```r
# --- EMU conversion tests ---

test_that("css_to_emu() converts points to EMU", {
  # 1 pt = 12700 EMU
  expect_equal(css_to_emu("1pt"), 12700L)
  expect_equal(css_to_emu("10pt"), 127000L)
  expect_equal(css_to_emu("250pt"), 3175000L)
})

test_that("css_to_emu() converts inches to EMU", {
  # 1 inch = 914400 EMU
  expect_equal(css_to_emu("1in"), 914400L)
  expect_equal(css_to_emu("0.5in"), 457200L)
})

test_that("css_to_emu() converts cm to EMU", {
  # 1 cm = 360000 EMU
  expect_equal(css_to_emu("1cm"), 360000L)
  expect_equal(css_to_emu("2.54cm"), 914400L)  # = 1 inch
})

test_that("css_to_emu() handles dxa suffix", {
  # 1 dxa (twip) = 635 EMU
  expect_equal(css_to_emu("5000dxa"), 3175000L)
  expect_equal(css_to_emu("198dxa"), 125730L)
})

test_that("css_to_emu() handles plain integer as dxa", {
  # Plain numbers treated as DXA (twips) for backward compat
  expect_equal(css_to_emu("5000"), 3175000L)
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-css-anchor.R")'`
Expected: New EMU tests FAIL (function not found), old tests still PASS

- [ ] **Step 3: Implement css_to_emu()**

Add to `R/css_parser.R` after `css_to_eighth_points()` (around line 95):

```r
#' Convert CSS Value to EMU (English Metric Units)
#'
#' DrawingML uses EMUs for measurements in `wp:anchor`, `wp:extent`, etc.
#' 1 inch = 914400 EMU, 1 pt = 12700 EMU, 1 cm = 360000 EMU,
#' 1 twip (DXA) = 635 EMU.
#'
#' Values with a "dxa" suffix are treated as twips (DXA). Plain integers
#' are also treated as DXA for backward compatibility with field code payloads.
#'
#' @param val_str String. CSS value (e.g., "250pt", "1in", "5000dxa") or
#'   plain integer string.
#' @return Integer. Value in EMU.
#' @export
css_to_emu <- function(val_str) {
  if (is.null(val_str) || !nzchar(val_str)) return(0L)
  val_str <- trimws(val_str)

  # DXA suffix: strip and convert (1 DXA = 635 EMU)
  if (grepl("dxa$", val_str)) {
    dxa <- as.numeric(sub("dxa$", "", val_str))
    return(as.integer(round(dxa * 635)))
  }

  # Plain integer: treat as DXA
  if (grepl("^-?[0-9]+$", val_str)) {
    dxa <- as.numeric(val_str)
    return(as.integer(round(dxa * 635)))
  }

  # CSS unit: parse to points, then convert (1 pt = 12700 EMU)
  pts <- parse_css_unit(val_str)
  as.integer(round(pts * 12700))
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-css-anchor.R")'`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add R/css_parser.R tests/testthat/test-css-anchor.R
git commit -m "Add css_to_emu() for DrawingML unit conversion"
```

---

### Task 3: Rename field code schema, handler, and dispatch (float → anchor)

Update the field code layer to use "anchor" type with backward compat for "float".

**Files:**
- Modify: `R/field_codes.R:241-246` (schema), `:535-551` (dispatch), `:787-798` (handler)
- Modify: `R/generated_content.R:125`
- Modify: `inst/schema/docstyle-field-codes.json`
- Modify: `tests/testthat/test-field-codes.R` (extend with anchor tests)

- [ ] **Step 1: Write failing tests for anchor schema and dispatch**

Append to `tests/testthat/test-field-codes.R`:

```r
# --- Anchor type tests ---

test_that("anchor schema validates required fields", {
  payload <- list(type = "anchor", class = "column-margin")
  result <- dispatch_docstyle_handler(payload)
  expect_false(is.null(result))
  expect_equal(result$type, "anchor")
  expect_equal(result$class, "column-margin")
})

test_that("anchor schema accepts all optional fields", {
  payload <- list(
    type = "anchor", version = 3L, class = "column-margin",
    content_hint = "image",
    vertical_anchor = "text", horizontal_anchor = "margin",
    position_y = "0", position_x = "0",
    float_width = "250pt",
    wrap_style = "square", wrap_side = "both",
    wrap_distance = "0 198dxa 0 198dxa",
    z_layer = "front"
  )
  result <- dispatch_docstyle_handler(payload)
  expect_equal(result$class, "column-margin")
})

test_that("float type dispatches to anchor handler (backward compat)", {
  payload <- list(type = "float", class = "column-margin")
  result <- dispatch_docstyle_handler(payload)
  expect_false(is.null(result))
  expect_equal(result$type, "anchor")
  expect_equal(result$class, "column-margin")
})

test_that("handle_docstyle_anchor() builds correct div_open/div_close", {
  payload <- list(type = "anchor", class = "journal-sidebar")
  result <- dispatch_docstyle_handler(payload)
  expect_equal(result$div_open, "::: {.journal-sidebar}")
  expect_equal(result$div_close, ":::")
})

test_that("handle_docstyle_anchor() includes positioning attributes in div_open", {
  payload <- list(
    type = "anchor", class = "column-margin",
    vertical_anchor = "page", position_y = "720"
  )
  result <- dispatch_docstyle_handler(payload)
  expect_true(grepl('vertical-anchor="page"', result$div_open))
  expect_true(grepl('position-y="720"', result$div_open))
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-field-codes.R")'`
Expected: New anchor tests FAIL

- [ ] **Step 3: Update schema in field_codes.R**

In `R/field_codes.R`, replace the `float` schema entry (line ~241-246) and add `anchor`:

```r
  float = list(
    required = c("type", "class"),
    optional = c("version", "vertical_anchor", "horizontal_anchor",
                 "position_y", "position_x", "float_width",
                 "wrap_style", "wrap_side", "wrap_distance", "adjacent")
  ),
  anchor = list(
    required = c("type", "class"),
    optional = c("version", "content_hint", "vertical_anchor", "horizontal_anchor",
                 "position_y", "position_x", "float_width",
                 "wrap_style", "wrap_side", "wrap_distance",
                 "z_layer", "adjacent")
  )
```

Keep `float` schema for backward compat. Add `anchor` with the new fields (`content_hint`, `z_layer`).

Update `DOCSTYLE_SCHEMA_VERSION` (line ~252):

```r
DOCSTYLE_SCHEMA_VERSION <- 3L
```

- [ ] **Step 4: Add handle_docstyle_anchor() and update dispatch**

Replace `handle_docstyle_float` (line ~787-798) with `handle_docstyle_anchor`:

```r
#' Handle anchor-type docstyle field code
#'
#' Reconstructs a fenced div from an anchor field code payload.
#' Includes non-default positioning attributes in the div_open for
#' round-trip fidelity.
#'
#' @param payload Validated payload with type="anchor" (or "float")
#' @param context Unused
#' @return List with type, class, div_open, div_close
#' @noRd
handle_docstyle_anchor <- function(payload, context = list()) {
  anchor_class <- payload$class %||% "column-margin"

  # Build div attributes from non-default positioning values
  div_attrs <- character(0)
  if (!is.null(payload$vertical_anchor) && payload$vertical_anchor != "text")
    div_attrs <- c(div_attrs, paste0('vertical-anchor="', payload$vertical_anchor, '"'))
  if (!is.null(payload$horizontal_anchor) && payload$horizontal_anchor != "margin")
    div_attrs <- c(div_attrs, paste0('horizontal-anchor="', payload$horizontal_anchor, '"'))
  if (!is.null(payload$position_y) && payload$position_y != "0")
    div_attrs <- c(div_attrs, paste0('position-y="', payload$position_y, '"'))
  if (!is.null(payload$position_x) && payload$position_x != "0")
    div_attrs <- c(div_attrs, paste0('position-x="', payload$position_x, '"'))
  if (!is.null(payload$float_width))
    div_attrs <- c(div_attrs, paste0('float-width="', payload$float_width, '"'))
  if (!is.null(payload$z_layer) && payload$z_layer != "front")
    div_attrs <- c(div_attrs, paste0('z-layer="', payload$z_layer, '"'))

  if (length(div_attrs) > 0) {
    div_open <- paste0("::: {.", anchor_class, " ", paste(div_attrs, collapse = " "), "}")
  } else {
    div_open <- paste0("::: {.", anchor_class, "}")
  }

  list(
    type = "anchor",
    class = anchor_class,
    div_open = div_open,
    div_close = ":::"
  )
}
```

Update dispatch (line ~538-547):

```r
  handler <- switch(payload$type,
    "char"    = handle_docstyle_char,
    "div"     = handle_docstyle_div,
    "list"    = handle_docstyle_list,
    "section" = handle_docstyle_section,
    "table"   = handle_docstyle_table,
    "figure"  = handle_docstyle_figure,
    "anchor"  = handle_docstyle_anchor,
    "float"   = handle_docstyle_anchor,  # backward compat
    NULL
  )
```

- [ ] **Step 5: Update generated_content.R type filter**

In `R/generated_content.R` line ~125, add `"anchor"` to the type list:

```r
          if (payload$type %in% c("div", "list", "section", "table", "figure", "float", "anchor")) {
```

- [ ] **Step 6: Update JSON schema**

Replace `float_classes` and `float_payload_fields` in `inst/schema/docstyle-field-codes.json`:

```json
  "anchor_payload_fields": {
    "class":             "CSS class name; determines positioning via anchor_styles in page-config.json",
    "content_hint":      "Advisory content type: table | image | text | mixed",
    "vertical_anchor":   "Vertical anchor: text | margin | page | section",
    "horizontal_anchor": "Horizontal anchor: text | margin | page",
    "position_y":        "Vertical offset from anchor (CSS length or dxa)",
    "position_x":        "Horizontal offset from anchor (CSS length or dxa)",
    "float_width":       "Width of anchored element (CSS length or dxa)",
    "wrap_style":        "Wrap type: none | square | tight | top-and-bottom",
    "wrap_side":         "Wrap side: both | left | right | largest",
    "wrap_distance":     "Wrap spacing: 1-4 value CSS shorthand (top right bottom left)",
    "z_layer":           "Layer: front | behind (maps to behindDoc on wp:anchor)",
    "adjacent":          "Anchor target element ID (deferred, #117)"
  },
```

Keep `float_classes` temporarily (remove in a later cleanup) or remove now since no downstream project uses it. Remove `float_payload_fields` — replaced by `anchor_payload_fields`.

- [ ] **Step 7: Run all field code tests**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-field-codes.R")'`
Expected: All tests PASS (including new anchor tests and existing float tests via backward compat)

- [ ] **Step 8: Commit**

```bash
git add R/field_codes.R R/generated_content.R inst/schema/docstyle-field-codes.json tests/testthat/test-field-codes.R
git commit -m "Add anchor schema and handler, backward compat for float type"
```

---

### Task 4: Rename Lua filter and assembly module (float-table → anchor)

Rename files, update marker prefixes, update callers.

**Files:**
- Rename: `_extensions/docstyle/float-table.lua` → `_extensions/docstyle/anchor.lua`
- Rename: `R/float_assembly.R` → `R/anchor_assembly.R`
- Rename: `tests/testthat/test-float-assembly.R` → `tests/testthat/test-anchor-assembly.R`
- Rename: `tests/testthat/test-harvest-float.R` → `tests/testthat/test-harvest-anchor.R`
- Modify: `_extensions/docstyle/_extension.yml:21`
- Modify: `R/use_docstyle.R:690`
- Modify: `R/finalize_docx.R:67-71`

- [ ] **Step 1: Rename Lua filter file**

```bash
git mv _extensions/docstyle/float-table.lua _extensions/docstyle/anchor.lua
```

- [ ] **Step 2: Update anchor.lua content**

In `_extensions/docstyle/anchor.lua`, update:

1. Header comment: "float-table.lua" → "anchor.lua", "DOCSTYLE_FLOAT::" → "DOCSTYLE_ANCHOR::"
2. Debug prefix: `[float-table]` → `[anchor]`
3. Variable name: `float_styles` → `anchor_styles`
4. Function name: `load_float_styles` → `load_anchor_styles`
5. Function name: `find_float_class` → `find_anchor_class`
6. Marker text: `DOCSTYLE_FLOAT::` → `DOCSTYLE_ANCHOR::`, `DOCSTYLE_FLOAT_END::` → `DOCSTYLE_ANCHOR_END::`
7. Config key: `config.float_styles` → `config.anchor_styles`
8. Function name: `build_float_marker_para` → `build_anchor_marker_para`
9. Function name: `build_float_end_marker_para` → `build_anchor_end_marker_para`
10. Add `content_hint` to payload based on div content inspection:

In the `Div(div)` function, after building `field_attrs`, add content hint detection:

```lua
  -- Detect content hint from div content
  local content_hint = "text"
  for _, block in ipairs(div.content) do
    if block.t == "Table" then
      content_hint = "table"
      break
    elseif block.t == "Para" then
      for _, inline in ipairs(block.content) do
        if inline.t == "Image" then
          content_hint = "image"
          break
        end
      end
    end
  end
  field_attrs.content_hint = content_hint
```

- [ ] **Step 3: Update _extension.yml filter entry**

In `_extensions/docstyle/_extension.yml` line 21, change:

```yaml
        - float-table.lua
```

to:

```yaml
        - anchor.lua
```

- [ ] **Step 4: Update EXTENSION_SOURCE_FILES in use_docstyle.R**

In `R/use_docstyle.R` line ~690, change `"float-table.lua"` to `"anchor.lua"`.

- [ ] **Step 5: Rename R assembly module**

```bash
git mv R/float_assembly.R R/anchor_assembly.R
```

- [ ] **Step 6: Update anchor_assembly.R content**

In `R/anchor_assembly.R`:

1. Header comment: "FLOAT TABLE ASSEMBLY" → "ANCHOR ASSEMBLY", all "DOCSTYLE_FLOAT" → "DOCSTYLE_ANCHOR"
2. Rename `assemble_float_tables` → `assemble_anchors`
3. Rename `build_float_table_xml` → `build_table_anchor_xml`
4. Update all `[float-assembly]` message prefixes to `[anchor-assembly]`
5. Update marker detection regex: `"^DOCSTYLE_FLOAT::"` → `"^DOCSTYLE_ANCHOR::"` and `"^DOCSTYLE_FLOAT_END::"` → `"^DOCSTYLE_ANCHOR_END::"`
6. Add backward compat: also detect `DOCSTYLE_FLOAT::` markers by using `"^DOCSTYLE_(ANCHOR|FLOAT)::"` patterns
7. Rename `is_floating_table` → keep as-is (it's still about detecting floating tables specifically)
8. Rename `extract_float_properties` → keep as-is (it's about table float properties specifically)

For the marker detection, update the regex patterns in the scan loop:

```r
    # Check for opening marker (anchor or legacy float)
    if (grepl("^DOCSTYLE_(ANCHOR|FLOAT)::", para_text)) {
```

```r
    # Check for closing marker
    if (grepl("^DOCSTYLE_(ANCHOR|FLOAT)_END::", para_text)) {
```

- [ ] **Step 7: Update finalize_docx.R caller**

In `R/finalize_docx.R` line ~67-71, change:

```r
  # Old:
  # Assemble floating tables from DOCSTYLE_FLOAT:: text markers.
  # Must run after section assembly (markers may be near section boundaries).
  float_result <- assemble_float_tables(body, ns, page_config, verbose = verbose)
  if (verbose && float_result$n_assembled > 0) {
    message("[finalize] Assembled ", float_result$n_assembled, " float table(s)")
  }
```

to:

```r
  # Assemble anchored content from DOCSTYLE_ANCHOR:: text markers.
  # Must run after section assembly (markers may be near section boundaries).
  anchor_result <- assemble_anchors(body, ns, page_config, verbose = verbose)
  if (verbose && anchor_result$n_assembled > 0) {
    message("[finalize] Assembled ", anchor_result$n_assembled, " anchor(s)")
  }
```

- [ ] **Step 8: Rename test files**

```bash
git mv tests/testthat/test-float-assembly.R tests/testthat/test-anchor-assembly.R
git mv tests/testthat/test-harvest-float.R tests/testthat/test-harvest-anchor.R
```

- [ ] **Step 9: Update test-anchor-assembly.R**

Update all references:
- `assemble_float_tables` → `assemble_anchors`
- `float_marker` helper function → update marker text from `DOCSTYLE_FLOAT::` to `DOCSTYLE_ANCHOR::`
- `float_end_marker` helper → update from `DOCSTYLE_FLOAT_END::` to `DOCSTYLE_ANCHOR_END::`
- `test_float_config` → `test_anchor_config`
- `float_styles` key → `anchor_styles` key in config
- All test descriptions: "float" → "anchor" where appropriate
- Payload `type`: `"float"` → `"anchor"`, `version`: `2L` → `3L`

Add a backward compat test:

```r
test_that("assemble_anchors() handles legacy DOCSTYLE_FLOAT:: markers", {
  # Use old-style float markers to verify backward compat
  old_marker <- function(class) {
    payload <- list(
      type = "float", version = 2L, class = class,
      vertical_anchor = "text", horizontal_anchor = "margin",
      position_y = "0", position_x = "0",
      float_width = "5000dxa",
      wrap_style = "square", wrap_side = "both",
      wrap_distance = "0 198dxa 0 198dxa"
    )
    json <- jsonlite::toJSON(payload, auto_unbox = TRUE)
    marker_text <- paste0("DOCSTYLE_FLOAT::", class, "::")
    paste0(
      '<w:p><w:pPr><w:suppressLineNumbers/></w:pPr>',
      '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
      '<w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE ', json, ' </w:instrText></w:r>',
      '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
      '<w:r><w:t>', marker_text, '</w:t></w:r>',
      '<w:r><w:fldChar w:fldCharType="end"/></w:r>',
      '</w:p>'
    )
  }

  old_end_marker <- function(class) {
    marker_text <- paste0("DOCSTYLE_FLOAT_END::", class)
    paste0(
      '<w:p><w:pPr><w:suppressLineNumbers/></w:pPr>',
      '<w:r><w:t>', marker_text, '</w:t></w:r>',
      '</w:p>'
    )
  }

  xml_str <- build_float_body(
    content_para("Before"),
    old_marker("column-margin"),
    content_para("Legacy float content"),
    old_end_marker("column-margin"),
    content_para("After")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_anchors(body, ns, test_anchor_config)
  expect_equal(result$n_assembled, 1L)
})
```

- [ ] **Step 10: Update test-harvest-anchor.R**

Update function references: `is_floating_table`, `extract_float_properties`, `handle_docstyle_float` → `handle_docstyle_anchor`. Test descriptions: "float" → "anchor" where it refers to the system name.

- [ ] **Step 11: Run all tests**

Run: `Rscript -e 'devtools::test()'`
Expected: All tests PASS (2588+ tests)

- [ ] **Step 12: Commit**

```bash
git add -A
git commit -m "Rename float-table to anchor throughout (files, markers, functions)"
```

---

### Task 5: Update docx_to_qmd.R harvest — rename float references to anchor

Rename state variables and range dispatch for anchor in the harvest pipeline.

**Files:**
- Modify: `R/docx_to_qmd.R:1616` (state var), `:1682-1702` (range dispatch), `:1813-1876` (floating table harvest)

- [ ] **Step 1: Rename state variable**

In `R/docx_to_qmd.R` line ~1616, change:

```r
  pending_float_range <- NULL  # For float ranges: deferred div_open from field code
```

to:

```r
  pending_anchor_range <- NULL  # For anchor ranges: deferred div_open from field code
```

- [ ] **Step 2: Update range dispatch for anchor type**

In the range dispatch block (line ~1682-1702), update:

```r
        } else if (range_hit$type %in% c("anchor", "float")) {
          # Anchor ranges: defer div_open until we find the anchored content
          if (range_hit$is_first) {
            pending_anchor_range <- range_hit
            harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
              para_index = i - 1L, type = "skipped"
            )
            next
          }
          if (range_hit$is_last) {
            if (!is.null(pending_anchor_range)) {
              lines <- c(lines, "", pending_anchor_range$div_open,
                         pending_anchor_range$div_close)
              pending_anchor_range <- NULL
            }
            harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
              para_index = i - 1L, type = "skipped"
            )
            next
          }
```

- [ ] **Step 3: Update floating table harvest block**

In the table harvest block (line ~1813-1876), update `pending_float_range` → `pending_anchor_range` and harvest style name:

```r
        float_class <- "column-margin"
        if (!is.null(pending_anchor_range)) {
          float_class <- pending_anchor_range$class
          pending_anchor_range <- NULL
        }
```

And the harvest map entry style:

```r
        harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
          para_index = i - 1L, type = "content",
          qmd_lines  = c(length(lines) - 1L, length(lines)),
          style      = "anchor-table"
        )
```

- [ ] **Step 4: Run harvest tests**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-harvest-anchor.R")'`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add R/docx_to_qmd.R
git commit -m "Rename float references to anchor in harvest pipeline"
```

---

### Task 6: Add content type detection to assembly

Add `detect_anchor_content()` to classify what's inside anchor markers, preparing for image handling.

**Files:**
- Modify: `R/anchor_assembly.R` (add function)
- Modify: `tests/testthat/test-anchor-assembly.R` (add tests)

- [ ] **Step 1: Write failing tests for detect_anchor_content()**

Append to `tests/testthat/test-anchor-assembly.R`:

```r
# --- Content detection tests ---

test_that("detect_anchor_content() classifies table-only content", {
  xml_str <- paste0(
    '<?xml version="1.0"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    '<w:tbl><w:tblPr><w:tblW w:w="5000" w:type="dxa"/></w:tblPr>',
    '<w:tblGrid><w:gridCol w:w="5000"/></w:tblGrid>',
    '<w:tr><w:tc><w:tcPr><w:tcW w:w="5000" w:type="dxa"/></w:tcPr>',
    '<w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>',
    '</w:body></w:document>'
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  children <- xml2::xml_children(body)

  expect_equal(detect_anchor_content(children, ns), "table")
})

test_that("detect_anchor_content() classifies image content", {
  xml_str <- paste0(
    '<?xml version="1.0"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:body>',
    '<w:p><w:r><w:drawing>',
    '<wp:inline distT="0" distB="0" distL="0" distR="0">',
    '<wp:extent cx="3175000" cy="2381250"/>',
    '<wp:docPr id="1" name="Picture 1"/>',
    '<wp:cNvGraphicFramePr/>',
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="img.png"/>',
    '<pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="3175000" cy="2381250"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>',
    '</pic:pic></a:graphicData></a:graphic>',
    '</wp:inline></w:drawing></w:r></w:p>',
    '</w:body></w:document>'
  )
  xml <- xml2::read_xml(xml_str)
  ns_full <- c(
    w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture"
  )
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns_full)
  children <- xml2::xml_children(body)

  expect_equal(detect_anchor_content(children, ns_full), "image")
})

test_that("detect_anchor_content() classifies text-only content", {
  xml_str <- paste0(
    '<?xml version="1.0"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    '<w:p><w:r><w:t>Just text</w:t></w:r></w:p>',
    '<w:p><w:r><w:t>More text</w:t></w:r></w:p>',
    '</w:body></w:document>'
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  children <- xml2::xml_children(body)

  expect_equal(detect_anchor_content(children, ns), "text")
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-anchor-assembly.R")'`
Expected: New detection tests FAIL

- [ ] **Step 3: Implement detect_anchor_content()**

Add to `R/anchor_assembly.R` before `assemble_anchors()`:

```r
#' Detect content type inside anchor markers
#'
#' Inspects body children between anchor markers to classify the content.
#' Used by `assemble_anchors()` to pick the correct OOXML mechanism.
#'
#' @param content_nodes xml2 nodeset of children between markers
#' @param ns Named character vector of XML namespaces
#' @return Character: "table", "image", "text", or "mixed"
#' @noRd
detect_anchor_content <- function(content_nodes, ns) {
  has_table <- FALSE
  has_image <- FALSE
  has_text <- FALSE

  for (node in content_nodes) {
    node_name <- xml2::xml_name(node)

    if (node_name == "tbl") {
      has_table <- TRUE
      next
    }

    if (node_name == "p") {
      # Check for drawing with image
      drawings <- xml2::xml_find_all(node, ".//w:drawing", ns = ns)
      if (length(drawings) > 0) {
        for (drawing in drawings) {
          pic_nodes <- xml2::xml_find_all(drawing, ".//pic:pic",
            ns = c(ns, pic = "http://schemas.openxmlformats.org/drawingml/2006/picture"))
          if (length(pic_nodes) > 0) {
            has_image <- TRUE
          }
        }
      }

      # Check for text content (non-empty paragraphs without images)
      if (!has_image || length(drawings) == 0) {
        text_nodes <- xml2::xml_find_all(node, ".//w:t", ns = ns)
        para_text <- paste(xml2::xml_text(text_nodes), collapse = "")
        if (nzchar(trimws(para_text))) {
          has_text <- TRUE
        }
      }
    }
  }

  # Classification logic
  if (has_table && has_image) return("mixed")
  if (has_table && !has_image) return("table")
  if (has_image) return("image")
  "text"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-anchor-assembly.R")'`
Expected: All tests PASS

- [ ] **Step 5: Wire detect_anchor_content() into assemble_anchors()**

In `assemble_anchors()`, after collecting content nodes and before building the table XML, add content type detection. For Phase 2a, only `"table"` proceeds to the existing table assembly logic; `"image"` will be handled in Task 7. Other types warn and skip:

```r
    # Detect content type
    children <- xml2::xml_children(body)
    content_start <- fr$start_idx + 1L
    content_end <- fr$end_idx - 1L
    content_type <- "table"  # default
    if (content_start <= content_end) {
      content_nodes <- children[content_start:content_end]
      content_type <- detect_anchor_content(content_nodes, ns)
    }

    if (content_type == "image") {
      # Phase 2a: image anchor assembly (Task 7)
      # For now, skip with warning
      if (verbose) {
        message("[anchor-assembly] Image content detected for class '", fr$class,
                "', skipping (not yet implemented)")
      }
      next
    }

    if (content_type %in% c("text", "mixed")) {
      if (verbose) {
        message("[anchor-assembly] ", content_type, " content for class '", fr$class,
                "', skipping (Phase 2b)")
      }
      next
    }

    # content_type == "table": proceed with existing table assembly logic
```

- [ ] **Step 6: Commit**

```bash
git add R/anchor_assembly.R tests/testthat/test-anchor-assembly.R
git commit -m "Add detect_anchor_content() for content-aware anchor assembly"
```

---

### Task 7: Implement build_image_anchor() — wp:inline → wp:anchor rewrite

The core Phase 2a logic: rewrite Pandoc's `wp:inline` image to a positioned `wp:anchor`.

**Files:**
- Modify: `R/anchor_assembly.R` (add `build_image_anchor()`, wire into `assemble_anchors()`)
- Modify: `tests/testthat/test-anchor-assembly.R` (add image assembly tests)

- [ ] **Step 1: Write failing tests for build_image_anchor()**

Append to `tests/testthat/test-anchor-assembly.R`:

```r
# --- Image anchor assembly tests ---

# Extended namespace for DrawingML
ns_drawingml <- c(
  w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
  wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
  a = "http://schemas.openxmlformats.org/drawingml/2006/main",
  pic = "http://schemas.openxmlformats.org/drawingml/2006/picture",
  r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
)

# Helper: build a paragraph containing wp:inline image
build_inline_image_para <- function(embed_id = "rId5", cx = "3175000", cy = "2381250") {
  paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><w:drawing>',
    '<wp:inline distT="0" distB="0" distL="0" distR="0">',
    '<wp:extent cx="', cx, '" cy="', cy, '"/>',
    '<wp:effectExtent l="0" t="0" r="0" b="0"/>',
    '<wp:docPr id="1" name="Picture 1"/>',
    '<wp:cNvGraphicFramePr/>',
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="img.png"/>',
    '<pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="', embed_id, '"/>',
    '<a:stretch><a:fillRect/></a:stretch></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="', cx, '" cy="', cy, '"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>',
    '</pic:pic></a:graphicData></a:graphic>',
    '</wp:inline></w:drawing></w:r></w:p>'
  )
}

test_that("build_image_anchor() produces wp:anchor with correct positioning", {
  para <- xml2::read_xml(build_inline_image_para())
  payload <- list(
    vertical_anchor = "text",
    horizontal_anchor = "margin",
    position_y = "0",
    position_x = "0",
    float_width = "250pt",
    z_layer = "front",
    wrap_style = "square",
    wrap_side = "both",
    wrap_distance = "0 198dxa 0 198dxa"
  )

  result <- build_image_anchor(para, payload, ns_drawingml, next_docpr_id = 100L)

  expect_true(result$success)

  # The paragraph should now contain wp:anchor instead of wp:inline
  anchor <- xml2::xml_find_first(para, ".//wp:anchor", ns = ns_drawingml)
  expect_false(inherits(anchor, "xml_missing"))

  inline <- xml2::xml_find_first(para, ".//wp:inline", ns = ns_drawingml)
  expect_true(inherits(inline, "xml_missing"))

  # Check positioning
  posH <- xml2::xml_find_first(anchor, "wp:positionH", ns = ns_drawingml)
  expect_equal(xml2::xml_attr(posH, "relativeFrom"), "margin")

  posV <- xml2::xml_find_first(anchor, "wp:positionV", ns = ns_drawingml)
  expect_equal(xml2::xml_attr(posV, "relativeFrom"), "paragraph")
})

test_that("build_image_anchor() sets behindDoc from z_layer", {
  para <- xml2::read_xml(build_inline_image_para())
  payload <- list(
    vertical_anchor = "page", horizontal_anchor = "page",
    position_y = "0", position_x = "0",
    z_layer = "behind",
    wrap_style = "none",
    wrap_distance = "0 0 0 0"
  )

  build_image_anchor(para, payload, ns_drawingml, next_docpr_id = 101L)

  anchor <- xml2::xml_find_first(para, ".//wp:anchor", ns = ns_drawingml)
  expect_equal(xml2::xml_attr(anchor, "behindDoc"), "1")
})

test_that("build_image_anchor() scales width and preserves aspect ratio", {
  # Original: 3175000 EMU wide x 2381250 EMU tall (250pt x 187.5pt = 4:3)
  para <- xml2::read_xml(build_inline_image_para(cx = "3175000", cy = "2381250"))
  payload <- list(
    vertical_anchor = "text", horizontal_anchor = "margin",
    position_y = "0", position_x = "0",
    float_width = "125pt",  # Half the original width
    z_layer = "front",
    wrap_style = "square",
    wrap_distance = "0 198dxa 0 198dxa"
  )

  build_image_anchor(para, payload, ns_drawingml, next_docpr_id = 102L)

  anchor <- xml2::xml_find_first(para, ".//wp:anchor", ns = ns_drawingml)
  extent <- xml2::xml_find_first(anchor, "wp:extent", ns = ns_drawingml)
  new_cx <- as.integer(xml2::xml_attr(extent, "cx"))
  new_cy <- as.integer(xml2::xml_attr(extent, "cy"))

  # 125pt = 1587500 EMU
  expect_equal(new_cx, 1587500L)
  # Height should scale proportionally: 1587500 * (2381250 / 3175000) = 1190625
  expect_equal(new_cy, 1190625L)
})

test_that("build_image_anchor() generates correct wrap element", {
  para <- xml2::read_xml(build_inline_image_para())
  payload <- list(
    vertical_anchor = "text", horizontal_anchor = "margin",
    position_y = "0", position_x = "0",
    z_layer = "front",
    wrap_style = "top-and-bottom",
    wrap_distance = "100dxa 0 100dxa 0"
  )

  build_image_anchor(para, payload, ns_drawingml, next_docpr_id = 103L)

  anchor <- xml2::xml_find_first(para, ".//wp:anchor", ns = ns_drawingml)
  wrap <- xml2::xml_find_first(anchor, "wp:wrapTopAndBottom", ns = ns_drawingml)
  expect_false(inherits(wrap, "xml_missing"))
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-anchor-assembly.R")'`
Expected: New image tests FAIL

- [ ] **Step 3: Implement build_image_anchor()**

Add to `R/anchor_assembly.R`:

```r
#' Map CSS anchor value to wp:positionH relativeFrom
#' @noRd
anchor_to_posH_relative <- function(css_value) {
  switch(css_value,
    "text"   = "column",
    "margin" = "margin",
    "page"   = "page",
    "margin"  # default
  )
}

#' Map CSS anchor value to wp:positionV relativeFrom
#' @noRd
anchor_to_posV_relative <- function(css_value) {
  switch(css_value,
    "text"    = "paragraph",
    "margin"  = "margin",
    "page"    = "page",
    "section" = "margin",
    "paragraph"  # default
  )
}

#' Map CSS wrap-side to OOXML wrapText value
#' @noRd
wrap_side_to_ooxml <- function(css_value) {
  switch(css_value %||% "both",
    "both"    = "bothSides",
    "left"    = "left",
    "right"   = "right",
    "largest" = "largest",
    "bothSides"  # default
  )
}

#' Build wp:anchor XML from wp:inline content
#'
#' Rewrites a `wp:inline` image in a paragraph to a positioned `wp:anchor`.
#' Preserves the original `a:graphic` subtree (blip reference, picture properties).
#'
#' @param para xml2 node of the paragraph containing `w:drawing/wp:inline`
#' @param payload Named list of positioning properties from field code
#' @param ns Named character vector of XML namespaces (must include wp, a, pic)
#' @param next_docpr_id Integer. Next available wp:docPr ID.
#' @return List with `success` (logical) and `docpr_id` (integer used)
#' @noRd
build_image_anchor <- function(para, payload, ns, next_docpr_id = 1L) {
  drawing <- xml2::xml_find_first(para, ".//w:drawing", ns = ns)
  if (inherits(drawing, "xml_missing")) {
    return(list(success = FALSE))
  }

  inline <- xml2::xml_find_first(drawing, "wp:inline", ns = ns)
  if (inherits(inline, "xml_missing")) {
    return(list(success = FALSE))
  }

  # Extract original extent
  orig_extent <- xml2::xml_find_first(inline, "wp:extent", ns = ns)
  orig_cx <- as.numeric(xml2::xml_attr(orig_extent, "cx"))
  orig_cy <- as.numeric(xml2::xml_attr(orig_extent, "cy"))

  # Calculate new dimensions from float_width (preserve aspect ratio)
  new_cx <- orig_cx
  new_cy <- orig_cy
  if (!is.null(payload$float_width)) {
    new_cx <- css_to_emu(payload$float_width)
    if (orig_cx > 0) {
      new_cy <- as.integer(round(new_cx * (orig_cy / orig_cx)))
    }
    new_cx <- as.integer(new_cx)
  }

  # Extract the a:graphic subtree (preserves blip reference)
  graphic <- xml2::xml_find_first(inline, "a:graphic", ns = ns)
  if (inherits(graphic, "xml_missing")) {
    return(list(success = FALSE))
  }

  # Build positioning values
  vert_anchor <- payload$vertical_anchor %||% "text"
  horz_anchor <- payload$horizontal_anchor %||% "margin"
  pos_y_emu <- css_to_emu(payload$position_y %||% "0")
  pos_x_emu <- css_to_emu(payload$position_x %||% "0")
  behind_doc <- if (identical(payload$z_layer, "behind")) "1" else "0"

  # Parse wrap distances
  dist <- parse_wrap_distance(payload$wrap_distance)
  dist_t <- as.integer(dist$top * 635)    # DXA → EMU
  dist_b <- as.integer(dist$bottom * 635)
  dist_l <- as.integer(dist$left * 635)
  dist_r <- as.integer(dist$right * 635)

  # Build wrap element
  wrap_style <- payload$wrap_style %||% "square"
  wrap_xml <- switch(wrap_style,
    "none" = '<wp:wrapNone/>',
    "square" = sprintf(
      '<wp:wrapSquare wrapText="%s" distT="%d" distB="%d" distL="%d" distR="%d"/>',
      wrap_side_to_ooxml(payload$wrap_side), dist_t, dist_b, dist_l, dist_r
    ),
    "top-and-bottom" = sprintf(
      '<wp:wrapTopAndBottom distT="%d" distB="%d"/>',
      dist_t, dist_b
    ),
    '<wp:wrapSquare wrapText="bothSides"/>'  # fallback
  )

  # Build the wp:anchor XML
  anchor_xml <- sprintf(paste0(
    '<wp:anchor xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"',
    ' distT="%d" distB="%d" distL="%d" distR="%d"',
    ' simplePos="0" relativeHeight="251658240" behindDoc="%s"',
    ' locked="0" layoutInCell="1" allowOverlap="1">',
    '<wp:simplePos x="0" y="0"/>',
    '<wp:positionH relativeFrom="%s"><wp:posOffset>%d</wp:posOffset></wp:positionH>',
    '<wp:positionV relativeFrom="%s"><wp:posOffset>%d</wp:posOffset></wp:positionV>',
    '<wp:extent cx="%d" cy="%d"/>',
    '<wp:effectExtent l="0" t="0" r="0" b="0"/>',
    '%s',
    '<wp:docPr id="%d" name="Picture %d"/>',
    '<wp:cNvGraphicFramePr/>',
    '</wp:anchor>'
  ),
    dist_t, dist_b, dist_l, dist_r,
    behind_doc,
    anchor_to_posH_relative(horz_anchor), pos_x_emu,
    anchor_to_posV_relative(vert_anchor), pos_y_emu,
    new_cx, new_cy,
    wrap_xml,
    next_docpr_id, next_docpr_id
  )

  # Parse the anchor element
  anchor_doc <- xml2::read_xml(anchor_xml)

  # Copy the original a:graphic into the anchor (before closing tag)
  xml2::xml_add_child(anchor_doc, graphic)

  # Replace wp:inline with wp:anchor in the drawing element
  xml2::xml_replace(inline, anchor_doc)

  # Update internal pic:spPr extent to match new dimensions
  new_anchor <- xml2::xml_find_first(drawing, "wp:anchor", ns = ns)
  if (!inherits(new_anchor, "xml_missing")) {
    int_ext <- xml2::xml_find_first(new_anchor, ".//pic:spPr/a:xfrm/a:ext", ns = ns)
    if (!inherits(int_ext, "xml_missing")) {
      xml2::xml_set_attr(int_ext, "cx", as.character(new_cx))
      xml2::xml_set_attr(int_ext, "cy", as.character(new_cy))
    }
  }

  list(success = TRUE, docpr_id = next_docpr_id)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-anchor-assembly.R")'`
Expected: All tests PASS

- [ ] **Step 5: Wire build_image_anchor() into assemble_anchors()**

In `assemble_anchors()`, replace the "image" skip block (from Task 6 Step 5) with actual image handling:

```r
    if (content_type == "image") {
      # Find the paragraph containing the image
      children <- xml2::xml_children(body)
      for (ci in content_start:content_end) {
        img_drawings <- xml2::xml_find_all(children[[ci]], ".//w:drawing", ns = ns)
        if (length(img_drawings) > 0) {
          # Extend ns with DrawingML namespaces for image rewrite
          ns_ext <- c(ns,
            wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
            a = "http://schemas.openxmlformats.org/drawingml/2006/main",
            pic = "http://schemas.openxmlformats.org/drawingml/2006/picture",
            r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
          )

          # Determine next docPr ID (scan existing)
          existing_ids <- xml2::xml_find_all(body, ".//wp:docPr", ns = ns_ext)
          max_id <- 0L
          for (dp in existing_ids) {
            dp_id <- as.integer(xml2::xml_attr(dp, "id"))
            if (!is.na(dp_id) && dp_id > max_id) max_id <- dp_id
          }
          next_id <- max_id + 1L

          result <- build_image_anchor(children[[ci]], float_config, ns_ext,
                                       next_docpr_id = next_id)
          if (!result$success) {
            warning("[anchor-assembly] Failed to build image anchor for class '",
                    fr$class, "'.", call. = FALSE)
            next
          }
          break
        }
      }

      # Remove marker paragraphs (start and end), keep content paragraphs
      children <- xml2::xml_children(body)
      # Remove end marker
      xml2::xml_remove(children[[fr$end_idx]])
      children <- xml2::xml_children(body)
      # Remove start marker
      xml2::xml_remove(children[[fr$start_idx]])

      n_assembled <- n_assembled + 1L
      if (verbose) {
        message("[anchor-assembly] Assembled image anchor: ", fr$class)
      }
      next
    }
```

- [ ] **Step 6: Add end-to-end image assembly test**

Append to `tests/testthat/test-anchor-assembly.R`:

```r
test_that("assemble_anchors() handles image content end-to-end", {
  # Build body with anchor markers containing an inline image
  image_para <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><w:drawing>',
    '<wp:inline distT="0" distB="0" distL="0" distR="0">',
    '<wp:extent cx="3175000" cy="2381250"/>',
    '<wp:effectExtent l="0" t="0" r="0" b="0"/>',
    '<wp:docPr id="1" name="Picture 1"/>',
    '<wp:cNvGraphicFramePr/>',
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="img.png"/>',
    '<pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/>',
    '<a:stretch><a:fillRect/></a:stretch></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="3175000" cy="2381250"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>',
    '</pic:pic></a:graphicData></a:graphic>',
    '</wp:inline></w:drawing></w:r></w:p>'
  )

  # Build anchor marker with image content_hint
  payload <- list(
    type = "anchor", version = 3L, class = "column-margin",
    content_hint = "image",
    vertical_anchor = "text", horizontal_anchor = "margin",
    position_y = "0", position_x = "0",
    float_width = "250pt",
    wrap_style = "square", wrap_side = "both",
    wrap_distance = "0 198dxa 0 198dxa",
    z_layer = "front"
  )
  json <- jsonlite::toJSON(payload, auto_unbox = TRUE)

  xml_str <- paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:body>',
    '<w:p><w:r><w:t>Before</w:t></w:r></w:p>',
    # Opening marker
    '<w:p><w:pPr><w:suppressLineNumbers/></w:pPr>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE ', json, ' </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:t>DOCSTYLE_ANCHOR::column-margin::</w:t></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r>',
    '</w:p>',
    # Image content
    image_para,
    # Closing marker
    '<w:p><w:pPr><w:suppressLineNumbers/></w:pPr>',
    '<w:r><w:t>DOCSTYLE_ANCHOR_END::column-margin</w:t></w:r>',
    '</w:p>',
    '<w:p><w:r><w:t>After</w:t></w:r></w:p>',
    '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr>',
    '</w:body></w:document>'
  )

  xml <- xml2::read_xml(xml_str)
  ns_full <- c(
    w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
  )
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns_full)

  result <- assemble_anchors(body, ns_full, list())
  expect_equal(result$n_assembled, 1L)

  # Verify wp:anchor exists and wp:inline is gone
  anchors <- xml2::xml_find_all(body, ".//wp:anchor", ns = ns_full)
  expect_equal(length(anchors), 1)
  inlines <- xml2::xml_find_all(body, ".//wp:inline", ns = ns_full)
  expect_equal(length(inlines), 0)

  # Verify marker paragraphs removed
  all_text <- xml2::xml_text(xml2::xml_find_all(body, ".//w:t", ns = ns_full))
  expect_false(any(grepl("DOCSTYLE_ANCHOR", all_text)))
})
```

- [ ] **Step 7: Run all tests**

Run: `Rscript -e 'devtools::test()'`
Expected: All tests PASS

- [ ] **Step 8: Commit**

```bash
git add R/anchor_assembly.R tests/testthat/test-anchor-assembly.R
git commit -m "Implement build_image_anchor() for wp:inline → wp:anchor rewrite"
```

---

### Task 8: Implement harvest for anchored images

Add detection and extraction of `wp:anchor` images in the harvest pipeline.

**Files:**
- Modify: `R/anchor_assembly.R` (add `is_anchored_image()`, `extract_anchor_image_properties()`)
- Modify: `R/docx_to_qmd.R` (add wp:anchor image detection in body scan)
- Modify: `tests/testthat/test-harvest-anchor.R` (add image harvest tests)

- [ ] **Step 1: Write failing tests for is_anchored_image() and extract_anchor_image_properties()**

Append to `tests/testthat/test-harvest-anchor.R`:

```r
# --- Anchored image harvest tests ---

ns_harvest <- c(
  w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
  wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
  a = "http://schemas.openxmlformats.org/drawingml/2006/main",
  pic = "http://schemas.openxmlformats.org/drawingml/2006/picture",
  r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
)

build_anchor_image_para <- function(
  relH = "margin", relV = "paragraph",
  posH = "0", posV = "0",
  cx = "3175000", cy = "2381250",
  behindDoc = "0",
  wrap = "square"
) {
  wrap_xml <- switch(wrap,
    "square" = '<wp:wrapSquare wrapText="bothSides" distT="0" distB="0" distL="125730" distR="125730"/>',
    "none" = '<wp:wrapNone/>',
    "top-and-bottom" = '<wp:wrapTopAndBottom distT="0" distB="0"/>',
    '<wp:wrapSquare wrapText="bothSides"/>'
  )

  paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><w:drawing>',
    '<wp:anchor simplePos="0" relativeHeight="251658240" behindDoc="', behindDoc, '"',
    ' locked="0" layoutInCell="1" allowOverlap="1"',
    ' distT="0" distB="0" distL="125730" distR="125730">',
    '<wp:simplePos x="0" y="0"/>',
    '<wp:positionH relativeFrom="', relH, '"><wp:posOffset>', posH, '</wp:posOffset></wp:positionH>',
    '<wp:positionV relativeFrom="', relV, '"><wp:posOffset>', posV, '</wp:posOffset></wp:positionV>',
    '<wp:extent cx="', cx, '" cy="', cy, '"/>',
    '<wp:effectExtent l="0" t="0" r="0" b="0"/>',
    wrap_xml,
    '<wp:docPr id="5" name="Picture 5"/>',
    '<wp:cNvGraphicFramePr/>',
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="5" name="img.png"/>',
    '<pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/>',
    '<a:stretch><a:fillRect/></a:stretch></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="', cx, '" cy="', cy, '"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>',
    '</pic:pic></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing></w:r></w:p>'
  )
}

test_that("is_anchored_image() detects wp:anchor with pic:pic", {
  para <- xml2::read_xml(build_anchor_image_para())
  expect_true(is_anchored_image(para, ns_harvest))
})

test_that("is_anchored_image() returns FALSE for wp:inline image", {
  inline_para <- xml2::read_xml(paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<w:r><w:drawing><wp:inline>',
    '<wp:extent cx="100" cy="100"/>',
    '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">',
    '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="x"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" r:embed="rId1"/>',
    '<a:stretch><a:fillRect/></a:stretch></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="100" cy="100"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>',
    '</pic:pic></a:graphicData></a:graphic>',
    '</wp:inline></w:drawing></w:r></w:p>'
  ))
  expect_false(is_anchored_image(inline_para, ns_harvest))
})

test_that("extract_anchor_image_properties() reads positioning attributes", {
  para <- xml2::read_xml(build_anchor_image_para(
    relH = "page", relV = "page",
    posH = "457200", posV = "914400",
    cx = "3175000", behindDoc = "1"
  ))

  props <- extract_anchor_image_properties(para, ns_harvest)

  expect_equal(props$horizontal_anchor, "page")
  expect_equal(props$vertical_anchor, "page")
  # 457200 EMU / 635 = 720 DXA
  expect_equal(props$position_x, "720")
  # 914400 EMU / 635 = 1440 DXA
  expect_equal(props$position_y, "1440")
  # 3175000 EMU / 635 = 5000 DXA
  expect_equal(props$float_width, "5000")
  expect_equal(props$z_layer, "behind")
})

test_that("extract_anchor_image_properties() maps relativeFrom to CSS vocabulary", {
  para <- xml2::read_xml(build_anchor_image_para(relH = "margin", relV = "paragraph"))
  props <- extract_anchor_image_properties(para, ns_harvest)

  expect_equal(props$horizontal_anchor, "margin")
  expect_equal(props$vertical_anchor, "text")
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-harvest-anchor.R")'`
Expected: New tests FAIL

- [ ] **Step 3: Implement is_anchored_image() and extract_anchor_image_properties()**

Add to `R/anchor_assembly.R`:

```r
#' Check if a paragraph contains an anchored (positioned) image
#'
#' Detects `w:drawing/wp:anchor` containing `pic:pic`.
#'
#' @param para xml2 node for w:p
#' @param ns Named character vector of XML namespaces
#' @return Logical
#' @export
is_anchored_image <- function(para, ns) {
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture"
  )
  anchors <- xml2::xml_find_all(para, ".//wp:anchor", ns = ns_ext)
  if (length(anchors) == 0) return(FALSE)

  for (anchor in anchors) {
    pics <- xml2::xml_find_all(anchor, ".//pic:pic", ns = ns_ext)
    if (length(pics) > 0) return(TRUE)
  }
  FALSE
}


#' Map OOXML positionH relativeFrom to CSS horizontal-anchor
#' @noRd
posH_relative_to_css <- function(rel) {
  switch(rel %||% "margin",
    "column" = "text",
    "margin" = "margin",
    "page"   = "page",
    "margin"  # default
  )
}

#' Map OOXML positionV relativeFrom to CSS vertical-anchor
#' @noRd
posV_relative_to_css <- function(rel) {
  switch(rel %||% "paragraph",
    "paragraph" = "text",
    "margin"    = "margin",
    "page"      = "page",
    "text"  # default
  )
}


#' Extract positioning properties from an anchored image
#'
#' Reads `wp:anchor` attributes and converts to CSS vocabulary.
#' EMU values are converted to DXA for consistency with the field code payload.
#'
#' @param para xml2 node for w:p containing wp:anchor
#' @param ns Named character vector of XML namespaces
#' @return Named list of positioning properties, or NULL if not an anchored image
#' @export
extract_anchor_image_properties <- function(para, ns) {
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
  )

  anchor <- xml2::xml_find_first(para, ".//wp:anchor", ns = ns_ext)
  if (inherits(anchor, "xml_missing")) return(NULL)

  # Positioning
  posH <- xml2::xml_find_first(anchor, "wp:positionH", ns = ns_ext)
  posV <- xml2::xml_find_first(anchor, "wp:positionV", ns = ns_ext)

  relH <- if (!inherits(posH, "xml_missing")) xml2::xml_attr(posH, "relativeFrom") else "margin"
  relV <- if (!inherits(posV, "xml_missing")) xml2::xml_attr(posV, "relativeFrom") else "paragraph"

  offsetH <- "0"
  if (!inherits(posH, "xml_missing")) {
    off_node <- xml2::xml_find_first(posH, "wp:posOffset", ns = ns_ext)
    if (!inherits(off_node, "xml_missing")) {
      emu_val <- as.numeric(xml2::xml_text(off_node))
      offsetH <- as.character(as.integer(round(emu_val / 635)))
    }
  }

  offsetV <- "0"
  if (!inherits(posV, "xml_missing")) {
    off_node <- xml2::xml_find_first(posV, "wp:posOffset", ns = ns_ext)
    if (!inherits(off_node, "xml_missing")) {
      emu_val <- as.numeric(xml2::xml_text(off_node))
      offsetV <- as.character(as.integer(round(emu_val / 635)))
    }
  }

  # Extent (width)
  extent <- xml2::xml_find_first(anchor, "wp:extent", ns = ns_ext)
  width_dxa <- NULL
  if (!inherits(extent, "xml_missing")) {
    cx <- as.numeric(xml2::xml_attr(extent, "cx"))
    width_dxa <- as.character(as.integer(round(cx / 635)))
  }

  # Behind doc
  behind_doc <- xml2::xml_attr(anchor, "behindDoc") %||% "0"
  z_layer <- if (behind_doc == "1") "behind" else "front"

  # Wrap style
  wrap_style <- "square"
  if (length(xml2::xml_find_all(anchor, "wp:wrapNone", ns = ns_ext)) > 0) wrap_style <- "none"
  if (length(xml2::xml_find_all(anchor, "wp:wrapTopAndBottom", ns = ns_ext)) > 0) wrap_style <- "top-and-bottom"
  if (length(xml2::xml_find_all(anchor, "wp:wrapTight", ns = ns_ext)) > 0) wrap_style <- "tight"

  list(
    horizontal_anchor = posH_relative_to_css(relH),
    vertical_anchor   = posV_relative_to_css(relV),
    position_x        = offsetH,
    position_y        = offsetV,
    float_width       = width_dxa,
    z_layer           = z_layer,
    wrap_style        = wrap_style
  )
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-harvest-anchor.R")'`
Expected: All tests PASS

- [ ] **Step 5: Wire anchored image detection into docx_to_qmd.R**

In `R/docx_to_qmd.R`, in the body child scan loop, add anchored image detection. This goes after the floating table check (line ~1815) and before the general table handling. Find the section around the `node_name == "p"` handling and add, early in the paragraph processing:

```r
    # Check for anchored image (wp:anchor with pic:pic) before general paragraph handling
    if (node_name == "p") {
      ns_ext <- c(ns,
        wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
        pic = "http://schemas.openxmlformats.org/drawingml/2006/picture"
      )
      if (is_anchored_image(child, ns_ext)) {
        anchor_props <- extract_anchor_image_properties(child, ns_ext)

        # Determine class from pending anchor range or default
        anchor_class <- "column-margin"
        if (!is.null(pending_anchor_range)) {
          anchor_class <- pending_anchor_range$class
          pending_anchor_range <- NULL
        }

        # Build div attributes from positioning
        div_attrs <- character(0)
        if (!is.null(anchor_props)) {
          if (!is.null(anchor_props$float_width))
            div_attrs <- c(div_attrs, paste0('float-width="', anchor_props$float_width, 'dxa"'))
          if (anchor_props$vertical_anchor != "text")
            div_attrs <- c(div_attrs, paste0('vertical-anchor="', anchor_props$vertical_anchor, '"'))
          if (anchor_props$horizontal_anchor != "margin")
            div_attrs <- c(div_attrs, paste0('horizontal-anchor="', anchor_props$horizontal_anchor, '"'))
          if (anchor_props$position_y != "0")
            div_attrs <- c(div_attrs, paste0('position-y="', anchor_props$position_y, 'dxa"'))
          if (anchor_props$position_x != "0")
            div_attrs <- c(div_attrs, paste0('position-x="', anchor_props$position_x, 'dxa"'))
          if (anchor_props$z_layer != "front")
            div_attrs <- c(div_attrs, paste0('z-layer="', anchor_props$z_layer, '"'))
        }

        if (length(div_attrs) > 0) {
          div_open <- paste0("::: {.", anchor_class, " ", paste(div_attrs, collapse = " "), "}")
        } else {
          div_open <- paste0("::: {.", anchor_class, "}")
        }

        lines <- c(lines, "", div_open)

        # Extract image as markdown (use existing image extraction logic)
        # The image is in wp:anchor — extract blip relationship ID
        anchor_node <- xml2::xml_find_first(child, ".//wp:anchor", ns = ns_ext)
        blip <- xml2::xml_find_first(anchor_node, ".//a:blip",
          ns = c(ns_ext, a = "http://schemas.openxmlformats.org/drawingml/2006/main"))
        if (!inherits(blip, "xml_missing")) {
          embed_id <- xml2::xml_attr(blip, "embed")
          if (!is.null(embed_id) && !is.null(hyperlink_rels[[embed_id]])) {
            img_path <- hyperlink_rels[[embed_id]]
            lines <- c(lines, paste0("![](", img_path, ")"))
          }
        }

        lines <- c(lines, ":::")
        harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
          para_index = i - 1L, type = "content",
          qmd_lines  = c(length(lines) - 1L, length(lines)),
          style      = "anchor-image"
        )
        next
      }
    }
```

Note: The exact placement depends on where paragraph processing begins in the existing code. Insert this early, before the general `extract_formatted_text()` call.

- [ ] **Step 6: Run all tests**

Run: `Rscript -e 'devtools::test()'`
Expected: All tests PASS

- [ ] **Step 7: Commit**

```bash
git add R/anchor_assembly.R R/docx_to_qmd.R tests/testthat/test-harvest-anchor.R
git commit -m "Add harvest support for anchored images (wp:anchor + pic:pic)"
```

---

### Task 9: Update CLAUDE.md and write architecture doc

Update documentation to reflect the rename and new architecture.

**Files:**
- Modify: `CLAUDE.md`
- Create: `dev/ARCHITECTURE-anchors.md`

- [ ] **Step 1: Update CLAUDE.md file map**

In the "Key source file map" table, update:

```
| Float/Anchor positioning | `anchor_assembly.R`, `css_parser.R` | `anchor.lua` |
```

Update any references to `float-table.lua`, `float_assembly.R`, `assemble_float_tables()`, `DOCSTYLE_FLOAT::` throughout CLAUDE.md.

- [ ] **Step 2: Write ARCHITECTURE-anchors.md**

Create `dev/ARCHITECTURE-anchors.md` with a concise architecture reference:

```markdown
# Anchor positioning architecture

## Overview

Unified CSS-driven positioning for all floating content. Two placement modes
(float, place), one CSS vocabulary, content-aware OOXML mechanism selection.

## Pipeline

```
CSS class with vertical-anchor/horizontal-anchor
  → extract_anchor_styles() → page-config.json { anchor_styles }
  → anchor.lua emits DOCSTYLE_ANCHOR::{class} markers
  → assemble_anchors() detects content type:
      table → w:tblpPr (invisible floating table)
      image → wp:anchor + pic:pic (DrawingML anchor)
      text  → wps:txbx (Phase 2b)
```

## CSS properties

| Property | Default | OOXML (tblpPr) | OOXML (wp:anchor) |
|----------|---------|----------------|-------------------|
| vertical-anchor | text | @vertAnchor | positionV@relativeFrom |
| horizontal-anchor | margin | @horzAnchor | positionH@relativeFrom |
| position-y | 0 | @tblpY (DXA) | posOffset (EMU) |
| position-x | 0 | @tblpX (DXA) | posOffset (EMU) |
| float-width | content | @tblW (DXA) | extent@cx (EMU) |
| wrap-style | square | fromText attrs | wp:wrapSquare etc. |
| z-layer | front | n/a | @behindDoc |

## Unit conversion

| Unit | DXA | EMU |
|------|-----|-----|
| 1 pt | 20 | 12700 |
| 1 in | 1440 | 914400 |
| 1 cm | ~567 | 360000 |
| 1 DXA | 1 | 635 |

## Key files

- `R/anchor_assembly.R` — assembly + harvest functions
- `R/css_parser.R` — css_to_anchor_style(), css_to_emu()
- `R/field_codes.R` — anchor schema + handler
- `_extensions/docstyle/anchor.lua` — Lua marker emitter
- `R/docx_to_qmd.R` — harvest integration

## Marker format

Opening: `DOCSTYLE_ANCHOR::{class}::{adjacent}`
Closing: `DOCSTYLE_ANCHOR_END::{class}`
Legacy: `DOCSTYLE_FLOAT::` accepted for backward compat.
```

- [ ] **Step 3: Run full test suite**

Run: `Rscript -e 'devtools::test()'`
Expected: All tests PASS

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git add -f dev/ARCHITECTURE-anchors.md
git commit -m "Update docs for anchor positioning architecture"
```

---

## Self-review checklist

**Spec coverage:**
- [x] Rename float → anchor (Task 1, 3, 4, 5)
- [x] css_to_emu() (Task 2)
- [x] Field code schema v3 with anchor type, content_hint, z_layer (Task 3)
- [x] Backward compat for float type and DOCSTYLE_FLOAT:: markers (Task 3, 4)
- [x] Content detection (Task 6)
- [x] build_image_anchor() — wp:inline → wp:anchor rewrite (Task 7)
- [x] Harvest: is_anchored_image(), extract_anchor_image_properties() (Task 8)
- [x] Harvest integration in docx_to_qmd.R (Task 8)
- [x] Architecture doc (Task 9)
- [x] CLAUDE.md update (Task 9)
- [x] Lua content_hint detection (Task 4 Step 2)
- [x] z_layer CSS property in css_to_anchor_style() (Task 1)

**Placeholder scan:** No TBD/TODO. All code blocks are complete.

**Type consistency:**
- `css_to_anchor_style()` — used consistently in Tasks 1, 6
- `extract_anchor_styles()` — used in Task 1, referenced in Task 4
- `handle_docstyle_anchor()` — defined in Task 3, dispatched in Task 3
- `detect_anchor_content()` — defined in Task 6, called in Task 6 Step 5
- `build_image_anchor()` — defined in Task 7, called in Task 7 Step 5
- `is_anchored_image()` — defined in Task 8, called in Task 8 Step 5
- `extract_anchor_image_properties()` — defined in Task 8, called in Task 8 Step 5
- `assemble_anchors()` — renamed in Task 4, called in Task 4 Step 7
- `css_to_emu()` — defined in Task 2, called in Task 7
- `parse_wrap_distance()` — existing function, called in Task 7 (unchanged name)
- `anchor_to_posH_relative()` / `anchor_to_posV_relative()` — defined and used in Task 7
- `posH_relative_to_css()` / `posV_relative_to_css()` — defined and used in Task 8
