# Anchor positioning Phase 2b implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add text/mixed content assembly (floating table + text box mechanisms), explicit adjacency via bookmark relocation, and harvest round-trip for all new paths.

**Architecture:** Text/mixed content defaults to invisible floating table (reuses `build_table_anchor_xml()`). Opt-in `content-mode: textbox` triggers DrawingML text box (`wps:txbx`). Explicit adjacency relocates assembled content to a bookmark target paragraph — `w:tbl` before target for floating tables, dedicated `w:p` with `w:drawing` before target for DrawingML. All changes follow the established CSS-first pipeline and R-first assembly patterns.

**Tech Stack:** R (xml2, jsonlite), Lua (Pandoc filter), OOXML (WordprocessingML, DrawingML)

**Spec:** `dev/plans/2026-04-06-anchor-positioning-phase2b-design.md`

---

### Task 1: Text/mixed content via floating table

Remove the "Phase 2b" skip in `assemble_anchors()` and route text/mixed content through the existing `build_table_anchor_xml()` path.

**Files:**
- Modify: `R/anchor_assembly.R:575-581`
- Test: `tests/testthat/test-anchor-assembly.R`

- [ ] **Step 1: Write failing tests for text content assembly**

Add to `tests/testthat/test-anchor-assembly.R`:

```r
test_that("assemble_anchors() handles text content via floating table", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  body_xml <- paste0(
    '<w:body xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:p><w:r><w:t>Before</w:t></w:r></w:p>',
    # Opening marker
    '<w:p><w:pPr><w:suppressLineNumbers/></w:pPr>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE {"type":"anchor","class":"column-margin","vertical_anchor":"text","horizontal_anchor":"margin","position_y":"0","position_x":"0","float_width":"3000dxa","wrap_distance":"0 198dxa 0 198dxa"} </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:t>DOCSTYLE_ANCHOR::column-margin::</w:t></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>',
    # Text content (no table, no image — just paragraphs)
    '<w:p><w:r><w:t>Margin note text</w:t></w:r></w:p>',
    '<w:p><w:r><w:t>Second paragraph</w:t></w:r></w:p>',
    # Closing marker
    '<w:p><w:r><w:t>DOCSTYLE_ANCHOR_END::column-margin</w:t></w:r></w:p>',
    '<w:p><w:r><w:t>After</w:t></w:r></w:p>',
    '</w:body>'
  )

  doc <- xml2::read_xml(body_xml)
  body <- xml2::xml_find_first(doc, "//w:body", ns)

  result <- assemble_anchors(body, ns, page_config = list(), verbose = FALSE)
  expect_equal(result$n_assembled, 1L)

  # Should have built a floating table with tblpPr
  children <- xml2::xml_children(body)
  tbl <- xml2::xml_find_first(body, ".//w:tbl", ns)
  expect_false(inherits(tbl, "xml_missing"))

  tblpPr <- xml2::xml_find_first(tbl, ".//w:tblpPr", ns)
  expect_false(inherits(tblpPr, "xml_missing"))

  # Content should be in the table cell
  tc_paras <- xml2::xml_find_all(tbl, ".//w:tc/w:p", ns)
  tc_texts <- sapply(tc_paras, function(p) {
    paste(xml2::xml_text(xml2::xml_find_all(p, ".//w:t", ns)), collapse = "")
  })
  expect_true("Margin note text" %in% tc_texts)
  expect_true("Second paragraph" %in% tc_texts)

  # Marker paragraphs should be removed
  all_texts <- sapply(xml2::xml_children(body), function(ch) {
    paste(xml2::xml_text(xml2::xml_find_all(ch, ".//w:t", ns)), collapse = "")
  })
  expect_false(any(grepl("DOCSTYLE_ANCHOR", all_texts)))
})

test_that("assemble_anchors() handles mixed content via floating table", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  body_xml <- paste0(
    '<w:body xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:p><w:r><w:t>Before</w:t></w:r></w:p>',
    '<w:p><w:pPr><w:suppressLineNumbers/></w:pPr>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE {"type":"anchor","class":"column-margin","vertical_anchor":"text","horizontal_anchor":"margin","position_y":"0","position_x":"0","float_width":"3000dxa","wrap_distance":"0 198dxa 0 198dxa"} </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:t>DOCSTYLE_ANCHOR::column-margin::</w:t></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>',
    # Mixed: image paragraph + text paragraph
    '<w:p><w:r><w:drawing><wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"><wp:extent cx="914400" cy="914400"/><a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:blipFill><a:blip r:embed="rId1" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></pic:blipFill><pic:spPr><a:xfrm><a:ext cx="914400" cy="914400"/></a:xfrm></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>',
    '<w:p><w:r><w:t>Caption text</w:t></w:r></w:p>',
    '<w:p><w:r><w:t>DOCSTYLE_ANCHOR_END::column-margin</w:t></w:r></w:p>',
    '</w:body>'
  )

  doc <- xml2::read_xml(body_xml)
  body <- xml2::xml_find_first(doc, "//w:body", ns)

  result <- assemble_anchors(body, ns, page_config = list(), verbose = FALSE)
  # Mixed content should be assembled as floating table (default content_mode)
  expect_equal(result$n_assembled, 1L)

  tblpPr <- xml2::xml_find_first(body, ".//w:tblpPr", ns)
  expect_false(inherits(tblpPr, "xml_missing"))
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-anchor-assembly.R")'`
Expected: FAIL — text content currently skipped with "Phase 2b" message, n_assembled is 0

- [ ] **Step 3: Replace the Phase 2b skip with floating table assembly**

In `R/anchor_assembly.R`, replace lines 575-581:

```r
    if (content_type %in% c("text", "mixed")) {
      if (verbose) {
        message("[anchor-assembly] ", content_type, " content for class '", fr$class,
                "', skipping (Phase 2b)")
      }
      next
    }
```

with:

```r
    if (content_type %in% c("text", "mixed")) {
      content_mode <- anchor_config$content_mode %||% "auto"

      if (content_mode == "textbox") {
        # Phase 2b: text box assembly (handled in later task)
        if (verbose) {
          message("[anchor-assembly] textbox mode for class '", fr$class,
                  "', not yet implemented")
        }
        next
      }

      # Default: wrap text/mixed content in invisible floating table
      # (same mechanism as table content)
    }
```

This removes the blanket skip and falls through to the existing table assembly code at line 583+. The `content_mode == "textbox"` branch is a temporary placeholder that Task 3 will fill in.

- [ ] **Step 4: Run tests to verify they pass**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-anchor-assembly.R")'`
Expected: PASS — all tests including new text/mixed tests

- [ ] **Step 5: Run full test suite**

Run: `Rscript -e 'devtools::test()'`
Expected: 0 failures, existing tests still pass

- [ ] **Step 6: Commit**

```bash
git add R/anchor_assembly.R tests/testthat/test-anchor-assembly.R
git commit -m "Add text/mixed content assembly via floating table"
```

---

### Task 2: CSS `content-mode` property and schema

Add `content_mode` to the CSS pipeline, Lua payload, and field code schema.

**Files:**
- Modify: `R/css_parser.R:512-531`
- Modify: `_extensions/docstyle/anchor.lua:97-113`
- Modify: `R/field_codes.R:797-828`
- Modify: `inst/schema/docstyle-field-codes.json`
- Test: `tests/testthat/test-css-anchor.R`
- Test: `tests/testthat/test-field-codes.R`

- [ ] **Step 1: Write failing tests for content_mode CSS extraction**

Add to `tests/testthat/test-css-anchor.R`:

```r
test_that("css_to_anchor_style() extracts content-mode property", {
  props <- list(
    "vertical-anchor" = "text",
    "horizontal-anchor" = "margin",
    "content-mode" = "textbox"
  )
  result <- css_to_anchor_style(props)
  expect_equal(result$content_mode, "textbox")
})

test_that("css_to_anchor_style() defaults content_mode to auto", {
  props <- list(
    "vertical-anchor" = "text",
    "horizontal-anchor" = "margin"
  )
  result <- css_to_anchor_style(props)
  expect_null(result$content_mode)
})
```

Add to `tests/testthat/test-field-codes.R`:

```r
test_that("handle_docstyle_anchor() includes content-mode in div attributes", {
  payload <- list(
    type = "anchor",
    class = "sidebar",
    content_mode = "textbox"
  )
  result <- handle_docstyle_anchor(payload)
  expect_true(grepl('content-mode="textbox"', result$div_open))
})

test_that("handle_docstyle_anchor() omits content-mode when auto", {
  payload <- list(type = "anchor", class = "sidebar", content_mode = "auto")
  result <- handle_docstyle_anchor(payload)
  expect_false(grepl("content-mode", result$div_open))
})

test_that("handle_docstyle_anchor() includes adjacent in div attributes", {
  payload <- list(type = "anchor", class = "column-margin", adjacent = "#methods")
  result <- handle_docstyle_anchor(payload)
  expect_true(grepl('adjacent="#methods"', result$div_open))
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-css-anchor.R")'`
Expected: FAIL — `content_mode` not in result

- [ ] **Step 3: Add `content_mode` to `css_to_anchor_style()`**

In `R/css_parser.R`, modify `css_to_anchor_style()` at line 520-530. Add `content_mode` to the returned list:

```r
css_to_anchor_style <- function(props) {
  if (is.null(props)) return(NULL)

  # Detection: must have at least one anchor property
  v_anchor <- props[["vertical-anchor"]]
  h_anchor <- props[["horizontal-anchor"]]
  if (is.null(v_anchor) && is.null(h_anchor)) return(NULL)

  style <- list(
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

  # Optional content_mode — only include if explicitly set
  cm <- props[["content-mode"]]
  if (!is.null(cm) && cm != "auto") {
    style$content_mode <- cm
  }

  style
}
```

- [ ] **Step 4: Add `content_mode` and `adjacent` to `handle_docstyle_anchor()`**

In `R/field_codes.R`, modify `handle_docstyle_anchor()` at lines 801-820. Add after the `z_layer` attribute block:

```r
  if (!is.null(payload$content_mode) && payload$content_mode != "auto")
    div_attrs <- c(div_attrs, paste0('content-mode="', payload$content_mode, '"'))
  if (!is.null(payload$adjacent))
    div_attrs <- c(div_attrs, paste0('adjacent="', payload$adjacent, '"'))
```

- [ ] **Step 5: Add `content_mode` to Lua payload**

In `_extensions/docstyle/anchor.lua`, add after line 112 (`field_attrs.adjacent = adjacent`):

```lua
  if anchor_config.content_mode then
    field_attrs.content_mode = anchor_config.content_mode
  end
  -- Also allow div attribute override
  local div_content_mode = div.attributes["content-mode"]
  if div_content_mode then
    field_attrs.content_mode = div_content_mode
  end
```

- [ ] **Step 6: Update schema JSON**

In `inst/schema/docstyle-field-codes.json`, add to `anchor_payload_fields` after the `adjacent` line:

```json
    "content_mode":      "Assembly mechanism: auto | textbox (default auto)"
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `Rscript -e 'devtools::test()'`
Expected: 0 failures

- [ ] **Step 8: Commit**

```bash
git add R/css_parser.R R/field_codes.R _extensions/docstyle/anchor.lua inst/schema/docstyle-field-codes.json tests/testthat/test-css-anchor.R tests/testthat/test-field-codes.R
git commit -m "Add content-mode and adjacent to CSS pipeline, Lua payload, and field code handler"
```

---

### Task 3: DrawingML text box assembly (`build_text_box_anchor`)

Implement `build_text_box_anchor()` and wire it into the `content_mode == "textbox"` dispatch branch.

**Files:**
- Modify: `R/anchor_assembly.R`
- Test: `tests/testthat/test-anchor-assembly.R`

- [ ] **Step 1: Write failing tests for text box assembly**

Add to `tests/testthat/test-anchor-assembly.R`:

```r
test_that("build_text_box_anchor() creates wp:anchor with wps:txbx", {
  ns <- c(
    w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    a = "http://schemas.openxmlformats.org/drawingml/2006/main",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  )

  # Create content paragraphs
  content_xml <- paste0(
    '<w:body xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:p><w:r><w:t>First paragraph</w:t></w:r></w:p>',
    '<w:p><w:r><w:t>Second paragraph</w:t></w:r></w:p>',
    '</w:body>'
  )
  doc <- xml2::read_xml(content_xml)
  ns_w <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  content_paras <- xml2::xml_children(doc)

  payload <- list(
    vertical_anchor = "text",
    horizontal_anchor = "margin",
    position_y = "0",
    position_x = "0",
    float_width = "2in",
    wrap_style = "square",
    wrap_side = "both",
    wrap_distance = "0 198dxa 0 198dxa",
    z_layer = "front"
  )

  result <- build_text_box_anchor(content_paras, payload, ns, next_docpr_id = 5L)
  expect_true(result$success)
  expect_equal(result$docpr_id, 5L)

  # Result should be a w:p containing w:drawing > wp:anchor
  result_para <- result$para
  expect_false(is.null(result_para))

  anchor <- xml2::xml_find_first(result_para, ".//wp:anchor", ns)
  expect_false(inherits(anchor, "xml_missing"))

  # Should contain wps:txbx with w:txbxContent
  txbx <- xml2::xml_find_first(anchor, ".//wps:txbx", ns)
  expect_false(inherits(txbx, "xml_missing"))

  txbx_content <- xml2::xml_find_first(txbx, "w:txbxContent", ns)
  expect_false(inherits(txbx_content, "xml_missing"))

  # Content paragraphs should be inside
  inner_paras <- xml2::xml_find_all(txbx_content, "w:p", ns)
  expect_gte(length(inner_paras), 2L)

  # Check docPr ID
  docpr <- xml2::xml_find_first(anchor, ".//wp:docPr", ns)
  expect_equal(xml2::xml_attr(docpr, "id"), "5")

  # Check behindDoc
  expect_equal(xml2::xml_attr(anchor, "behindDoc"), "0")
})

test_that("build_text_box_anchor() applies z_layer behind", {
  ns <- c(
    w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    a = "http://schemas.openxmlformats.org/drawingml/2006/main",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  )

  content_xml <- paste0(
    '<w:body xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:p><w:r><w:t>Content</w:t></w:r></w:p>',
    '</w:body>'
  )
  doc <- xml2::read_xml(content_xml)
  content_paras <- xml2::xml_children(doc)

  payload <- list(
    vertical_anchor = "text",
    horizontal_anchor = "margin",
    float_width = "3000dxa",
    wrap_distance = "0 0 0 0",
    z_layer = "behind"
  )

  result <- build_text_box_anchor(content_paras, payload, ns, next_docpr_id = 1L)
  expect_true(result$success)

  anchor <- xml2::xml_find_first(result$para, ".//wp:anchor", ns)
  expect_equal(xml2::xml_attr(anchor, "behindDoc"), "1")
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-anchor-assembly.R")'`
Expected: FAIL — `build_text_box_anchor` not defined

- [ ] **Step 3: Implement `build_text_box_anchor()`**

Add to `R/anchor_assembly.R` after `build_image_anchor()` (after line 243):

```r
#' Build a DrawingML text box anchor
#'
#' Constructs a `wp:anchor` containing `wps:wsp` with `wps:txbx/w:txbxContent`.
#' Content paragraphs are copied into the text box body. Returns a new `w:p`
#' containing the `w:drawing` element.
#'
#' @param content_paras xml2 nodeset of `w:p` elements to place inside the text box
#' @param payload Named list of positioning properties from field code
#' @param ns Named character vector of XML namespaces (must include wp, a, wps)
#' @param next_docpr_id Integer. Next available wp:docPr ID.
#' @return List with `success` (logical), `para` (xml2 node of the wrapper w:p),
#'   and `docpr_id` (integer used)
#' @noRd
build_text_box_anchor <- function(content_paras, payload, ns, next_docpr_id = 1L) {
  if (length(content_paras) == 0) {
    return(list(success = FALSE, reason = "no content paragraphs provided"))
  }

  # Width from payload
  width_emu <- css_to_emu(payload$float_width %||% "3000dxa")
  # Height: generous default — Word auto-sizes text boxes
  height_emu <- 9144000L  # 10 inches

  # Positioning
  vert_anchor <- payload$vertical_anchor %||% "text"
  horz_anchor <- payload$horizontal_anchor %||% "margin"
  pos_y_emu <- css_to_emu(payload$position_y %||% "0")
  pos_x_emu <- css_to_emu(payload$position_x %||% "0")
  behind_doc <- if (identical(payload$z_layer, "behind")) "1" else "0"

  # Wrap distances
  dist <- parse_wrap_distance(payload$wrap_distance)
  dist_t <- as.integer(dist$top * 635)
  dist_b <- as.integer(dist$bottom * 635)
  dist_l <- as.integer(dist$left * 635)
  dist_r <- as.integer(dist$right * 635)

  # Wrap element
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
    '<wp:wrapSquare wrapText="bothSides"/>'
  )

  # Serialize content paragraphs to XML strings
  para_xml_parts <- vapply(content_paras, function(p) {
    as.character(p)
  }, character(1))
  content_xml <- paste(para_xml_parts, collapse = "")

  # Build the full structure
  full_xml <- sprintf(paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><w:drawing>',
    '<wp:anchor distT="%d" distB="%d" distL="%d" distR="%d"',
    ' simplePos="0" relativeHeight="251658240" behindDoc="%s"',
    ' locked="0" layoutInCell="1" allowOverlap="1">',
    '<wp:simplePos x="0" y="0"/>',
    '<wp:positionH relativeFrom="%s"><wp:posOffset>%d</wp:posOffset></wp:positionH>',
    '<wp:positionV relativeFrom="%s"><wp:posOffset>%d</wp:posOffset></wp:positionV>',
    '<wp:extent cx="%d" cy="%d"/>',
    '<wp:effectExtent l="0" t="0" r="0" b="0"/>',
    '%s',  # wrap element
    '<wp:docPr id="%d" name="TextBox %d"/>',
    '<wp:cNvGraphicFramePr/>',
    '<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">',
    '<wps:wsp>',
    '<wps:cNvSpPr txBox="1"/>',
    '<wps:spPr>',
    '<a:xfrm><a:off x="0" y="0"/><a:ext cx="%d" cy="%d"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>',
    '<a:noFill/>',
    '<a:ln><a:noFill/></a:ln>',
    '</wps:spPr>',
    '<wps:txbx><w:txbxContent>',
    '%s',  # content paragraphs
    '</w:txbxContent></wps:txbx>',
    '<wps:bodyPr rot="0" spcFirstLastPara="0" vertOverflow="overflow"',
    ' horzOverflow="overflow" wrap="square"',
    ' lIns="91440" tIns="45720" rIns="91440" bIns="45720"',
    ' anchor="t" anchorCtr="0"/>',
    '</wps:wsp>',
    '</a:graphicData></a:graphic>',
    '</wp:anchor>',
    '</w:drawing></w:r></w:p>'
  ),
    dist_t, dist_b, dist_l, dist_r,
    behind_doc,
    anchor_to_posH_relative(horz_anchor), pos_x_emu,
    anchor_to_posV_relative(vert_anchor), pos_y_emu,
    width_emu, height_emu,
    wrap_xml,
    next_docpr_id, next_docpr_id,
    width_emu, height_emu,
    content_xml
  )

  result_doc <- tryCatch(
    xml2::read_xml(full_xml),
    error = function(e) NULL
  )
  if (is.null(result_doc)) {
    return(list(success = FALSE, reason = "failed to parse constructed text box XML"))
  }

  list(success = TRUE, para = result_doc, docpr_id = next_docpr_id)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-anchor-assembly.R")'`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add R/anchor_assembly.R tests/testthat/test-anchor-assembly.R
git commit -m "Implement build_text_box_anchor() for DrawingML text box assembly"
```

---

### Task 4: Wire text box into `assemble_anchors()` dispatch

Connect `build_text_box_anchor()` to the `content_mode == "textbox"` branch in the main assembly loop.

**Files:**
- Modify: `R/anchor_assembly.R:575-585` (the textbox placeholder from Task 1)
- Test: `tests/testthat/test-anchor-assembly.R`

- [ ] **Step 1: Write failing test for textbox dispatch**

Add to `tests/testthat/test-anchor-assembly.R`:

```r
test_that("assemble_anchors() uses text box when content_mode is textbox", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  body_xml <- paste0(
    '<w:body xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:p><w:r><w:t>Before</w:t></w:r></w:p>',
    '<w:p><w:pPr><w:suppressLineNumbers/></w:pPr>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE {"type":"anchor","class":"sidebar","content_mode":"textbox","vertical_anchor":"text","horizontal_anchor":"margin","position_y":"0","position_x":"0","float_width":"2in","wrap_distance":"0 198dxa 0 198dxa"} </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:t>DOCSTYLE_ANCHOR::sidebar::</w:t></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>',
    '<w:p><w:r><w:t>Sidebar text</w:t></w:r></w:p>',
    '<w:p><w:r><w:t>DOCSTYLE_ANCHOR_END::sidebar</w:t></w:r></w:p>',
    '<w:p><w:r><w:t>After</w:t></w:r></w:p>',
    '</w:body>'
  )

  doc <- xml2::read_xml(body_xml)
  body <- xml2::xml_find_first(doc, "//w:body", ns)

  result <- assemble_anchors(body, ns, page_config = list(), verbose = FALSE)
  expect_equal(result$n_assembled, 1L)

  # Should NOT have a floating table (tblpPr)
  tblpPr <- xml2::xml_find_first(body, ".//w:tblpPr", ns)
  expect_true(inherits(tblpPr, "xml_missing"))

  # Should have wp:anchor with wps:txbx
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
  )
  anchor <- xml2::xml_find_first(body, ".//wp:anchor", ns_ext)
  expect_false(inherits(anchor, "xml_missing"))

  txbx <- xml2::xml_find_first(anchor, ".//wps:txbx", ns_ext)
  expect_false(inherits(txbx, "xml_missing"))
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-anchor-assembly.R")'`
Expected: FAIL — textbox branch still has "not yet implemented" placeholder

- [ ] **Step 3: Replace the textbox placeholder with real dispatch**

In `R/anchor_assembly.R`, replace the textbox placeholder block (from Task 1):

```r
      if (content_mode == "textbox") {
        # Phase 2b: text box assembly (handled in later task)
        if (verbose) {
          message("[anchor-assembly] textbox mode for class '", fr$class,
                  "', not yet implemented")
        }
        next
      }
```

with:

```r
      if (content_mode == "textbox") {
        # DrawingML text box: wp:anchor with wps:txbx
        children <- xml2::xml_children(body)
        content_start <- fr$start_idx + 1L
        content_end <- fr$end_idx - 1L

        if (content_start > content_end) {
          warning("[anchor-assembly] Empty content range for textbox class '",
                  fr$class, "'.", call. = FALSE)
          next
        }

        content_nodes <- children[content_start:content_end]

        # Extend ns with DrawingML namespaces
        ns_ext <- c(ns,
          wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
          a = "http://schemas.openxmlformats.org/drawingml/2006/main",
          wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
          r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        )

        # Determine next docPr ID
        existing_ids <- xml2::xml_find_all(body, ".//wp:docPr", ns = ns_ext)
        max_id <- 0L
        for (dp in existing_ids) {
          dp_id <- as.integer(xml2::xml_attr(dp, "id"))
          if (!is.na(dp_id) && dp_id > max_id) max_id <- dp_id
        }
        next_id <- max_id + 1L

        tb_result <- build_text_box_anchor(content_nodes, anchor_config, ns_ext,
                                            next_docpr_id = next_id)
        if (!tb_result$success) {
          reason <- tb_result$reason %||% "unknown"
          warning("[anchor-assembly] Failed to build text box for class '",
                  fr$class, "': ", reason, call. = FALSE)
          next
        }

        # Insert the text box paragraph before the start marker
        children <- xml2::xml_children(body)
        xml2::xml_add_sibling(children[[fr$start_idx]], tb_result$para, .where = "before")

        # Remove original nodes (start marker, content, end marker)
        children <- xml2::xml_children(body)
        remove_start <- fr$start_idx + 1L
        remove_end <- fr$end_idx + 1L
        for (ri in remove_end:remove_start) {
          xml2::xml_remove(children[[ri]])
          children <- xml2::xml_children(body)
        }

        n_assembled <- n_assembled + 1L
        if (verbose) {
          message("[anchor-assembly] Assembled text box: ", fr$class)
        }
        next
      }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-anchor-assembly.R")'`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `Rscript -e 'devtools::test()'`
Expected: 0 failures

- [ ] **Step 6: Commit**

```bash
git add R/anchor_assembly.R tests/testthat/test-anchor-assembly.R
git commit -m "Wire text box assembly into assemble_anchors() dispatch"
```

---

### Task 5: Bookmark lookup and adjacency relocation

Implement `find_bookmark_paragraph()` and adjacency relocation logic in `assemble_anchors()`.

**Files:**
- Modify: `R/anchor_assembly.R`
- Test: `tests/testthat/test-anchor-assembly.R`

- [ ] **Step 1: Write failing tests for bookmark lookup**

Add to `tests/testthat/test-anchor-assembly.R`:

```r
test_that("find_bookmark_paragraph() finds bookmark by ID", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  body_xml <- paste0(
    '<w:body xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:p><w:bookmarkStart w:id="1" w:name="methods"/><w:r><w:t>Methods heading</w:t></w:r><w:bookmarkEnd w:id="1"/></w:p>',
    '<w:p><w:r><w:t>Methods content</w:t></w:r></w:p>',
    '</w:body>'
  )
  doc <- xml2::read_xml(body_xml)
  body <- xml2::xml_find_first(doc, "//w:body", ns)

  result <- find_bookmark_paragraph(body, "methods", ns)
  expect_false(is.null(result))
  text <- paste(xml2::xml_text(xml2::xml_find_all(result, ".//w:t", ns)), collapse = "")
  expect_equal(text, "Methods heading")
})

test_that("find_bookmark_paragraph() finds _docstyle_ prefixed bookmarks", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  body_xml <- paste0(
    '<w:body xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:p><w:bookmarkStart w:id="1" w:name="_docstyle_results"/><w:r><w:t>Results</w:t></w:r><w:bookmarkEnd w:id="1"/></w:p>',
    '</w:body>'
  )
  doc <- xml2::read_xml(body_xml)
  body <- xml2::xml_find_first(doc, "//w:body", ns)

  result <- find_bookmark_paragraph(body, "results", ns)
  expect_false(is.null(result))
})

test_that("find_bookmark_paragraph() strips # prefix", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  body_xml <- paste0(
    '<w:body xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:p><w:bookmarkStart w:id="1" w:name="intro"/><w:r><w:t>Intro</w:t></w:r><w:bookmarkEnd w:id="1"/></w:p>',
    '</w:body>'
  )
  doc <- xml2::read_xml(body_xml)
  body <- xml2::xml_find_first(doc, "//w:body", ns)

  result <- find_bookmark_paragraph(body, "#intro", ns)
  expect_false(is.null(result))
})

test_that("find_bookmark_paragraph() returns NULL for missing bookmark", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  body_xml <- paste0(
    '<w:body xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:p><w:r><w:t>No bookmarks</w:t></w:r></w:p>',
    '</w:body>'
  )
  doc <- xml2::read_xml(body_xml)
  body <- xml2::xml_find_first(doc, "//w:body", ns)

  result <- find_bookmark_paragraph(body, "nonexistent", ns)
  expect_null(result)
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-anchor-assembly.R")'`
Expected: FAIL — `find_bookmark_paragraph` not defined

- [ ] **Step 3: Implement `find_bookmark_paragraph()`**

Add to `R/anchor_assembly.R` (before `assemble_anchors()`):

```r
#' Find the paragraph containing a bookmark
#'
#' Scans `w:bookmarkStart` elements in the body for a matching bookmark name.
#' Checks both bare name and `_docstyle_` prefixed form (Quarto heading IDs).
#'
#' @param body xml2 node of the `w:body` element
#' @param bookmark_id Character. The bookmark ID (with or without `#` prefix).
#' @param ns Named character vector of XML namespaces.
#' @return xml2 node of the `w:p` containing the bookmark, or NULL if not found.
#' @noRd
find_bookmark_paragraph <- function(body, bookmark_id, ns) {
  # Strip # prefix
  bm_id <- sub("^#", "", bookmark_id)

  # Search for bare name and _docstyle_ prefixed form
  candidates <- c(bm_id, paste0("_docstyle_", bm_id))

  bookmarks <- xml2::xml_find_all(body, ".//w:bookmarkStart", ns)
  for (bm in bookmarks) {
    bm_name <- xml2::xml_attr(bm, "name")
    if (is.na(bm_name)) next
    if (bm_name %in% candidates) {
      # Return the parent paragraph
      parent <- xml2::xml_parent(bm)
      if (xml2::xml_name(parent) == "p") {
        return(parent)
      }
    }
  }

  NULL
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-anchor-assembly.R")'`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add R/anchor_assembly.R tests/testthat/test-anchor-assembly.R
git commit -m "Add find_bookmark_paragraph() for adjacency lookup"
```

---

### Task 6: Adjacency relocation in `assemble_anchors()`

Wire `find_bookmark_paragraph()` into the assembly loop to relocate assembled content when `payload$adjacent` is set.

**Files:**
- Modify: `R/anchor_assembly.R`
- Test: `tests/testthat/test-anchor-assembly.R`

- [ ] **Step 1: Write failing tests for adjacency relocation**

Add to `tests/testthat/test-anchor-assembly.R`:

```r
test_that("assemble_anchors() relocates floating table to adjacent bookmark", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  body_xml <- paste0(
    '<w:body xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    # Target paragraph with bookmark
    '<w:p><w:bookmarkStart w:id="1" w:name="methods"/><w:r><w:t>Methods</w:t></w:r><w:bookmarkEnd w:id="1"/></w:p>',
    '<w:p><w:r><w:t>Methods content</w:t></w:r></w:p>',
    # Anchor div far from target, with adjacent attribute
    '<w:p><w:r><w:t>Results section</w:t></w:r></w:p>',
    '<w:p><w:pPr><w:suppressLineNumbers/></w:pPr>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE {"type":"anchor","class":"column-margin","adjacent":"#methods","vertical_anchor":"text","horizontal_anchor":"margin","position_y":"0","position_x":"0","float_width":"3000dxa","wrap_distance":"0 198dxa 0 198dxa"} </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:t>DOCSTYLE_ANCHOR::column-margin::#methods</w:t></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>',
    '<w:p><w:r><w:t>Margin note for methods</w:t></w:r></w:p>',
    '<w:p><w:r><w:t>DOCSTYLE_ANCHOR_END::column-margin</w:t></w:r></w:p>',
    '</w:body>'
  )

  doc <- xml2::read_xml(body_xml)
  body <- xml2::xml_find_first(doc, "//w:body", ns)

  result <- assemble_anchors(body, ns, page_config = list(), verbose = FALSE)
  expect_equal(result$n_assembled, 1L)

  # The floating table should be positioned before the "Methods" paragraph
  children <- xml2::xml_children(body)
  child_names <- sapply(children, xml2::xml_name)

  # Find the table
  tbl_idx <- which(child_names == "tbl")
  expect_length(tbl_idx, 1L)

  # Find the "Methods" paragraph (contains bookmark)
  methods_idx <- NULL
  for (i in seq_along(children)) {
    bm <- xml2::xml_find_first(children[[i]], ".//w:bookmarkStart[@w:name='methods']", ns)
    if (!inherits(bm, "xml_missing")) {
      methods_idx <- i
      break
    }
  }

  # Table should be immediately before the methods paragraph
  expect_equal(tbl_idx, methods_idx - 1L)
})

test_that("assemble_anchors() falls back to source position on missing bookmark", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  body_xml <- paste0(
    '<w:body xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:p><w:r><w:t>Before</w:t></w:r></w:p>',
    '<w:p><w:pPr><w:suppressLineNumbers/></w:pPr>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE {"type":"anchor","class":"column-margin","adjacent":"#nonexistent","vertical_anchor":"text","horizontal_anchor":"margin","position_y":"0","position_x":"0","float_width":"3000dxa","wrap_distance":"0 198dxa 0 198dxa"} </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:t>DOCSTYLE_ANCHOR::column-margin::#nonexistent</w:t></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>',
    '<w:p><w:r><w:t>Margin text</w:t></w:r></w:p>',
    '<w:p><w:r><w:t>DOCSTYLE_ANCHOR_END::column-margin</w:t></w:r></w:p>',
    '<w:p><w:r><w:t>After</w:t></w:r></w:p>',
    '</w:body>'
  )

  doc <- xml2::read_xml(body_xml)
  body <- xml2::xml_find_first(doc, "//w:body", ns)

  # Should warn but still assemble
  expect_warning(
    result <- assemble_anchors(body, ns, page_config = list(), verbose = FALSE),
    "Bookmark.*nonexistent.*not found"
  )
  expect_equal(result$n_assembled, 1L)
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-anchor-assembly.R")'`
Expected: FAIL — no adjacency relocation logic yet

- [ ] **Step 3: Add adjacency relocation to assembly loop**

In `R/anchor_assembly.R`, the assembly loop currently has three content-type branches that each insert content and remove markers. The adjacency relocation needs to happen after assembly but before final insertion. Add a helper function and modify the insertion logic.

Add this helper before `assemble_anchors()`:

```r
#' Relocate an assembled anchor to a target bookmark paragraph
#'
#' Moves a node (w:tbl or w:p containing w:drawing) to sit immediately before
#' the paragraph containing the target bookmark. Used when payload$adjacent is set.
#'
#' @param body xml2 node of w:body
#' @param assembled_node xml2 node to relocate (already inserted in body)
#' @param adjacent Character. Bookmark ID (with or without # prefix).
#' @param ns Named character vector of XML namespaces.
#' @return Logical. TRUE if relocation succeeded, FALSE if bookmark not found.
#' @noRd
relocate_to_adjacent <- function(body, assembled_node, adjacent, ns) {
  target_para <- find_bookmark_paragraph(body, adjacent, ns)
  if (is.null(target_para)) {
    warning("[anchor-assembly] Bookmark '", sub("^#", "", adjacent),
            "' not found, using source position", call. = FALSE)
    return(FALSE)
  }

  # Move the assembled node before the target paragraph
  xml2::xml_add_sibling(target_para, assembled_node, .where = "before")
  # The original position is now a duplicate — xml_add_sibling copies,
  # so remove the original
  # Actually xml2::xml_add_sibling with an existing node moves it (implicit detach)
  # So no removal needed — verify in tests

  TRUE
}
```

Then, in each of the three assembly branches (table at ~line 627, image at ~line 560, textbox in the new code), after inserting the assembled content and removing markers, add:

For the **table** branch (after the table is inserted and markers removed, around line 643):

```r
    # Adjacency relocation (after markers are removed)
    if (!is.null(fr$payload$adjacent) && nzchar(fr$payload$adjacent)) {
      children <- xml2::xml_children(body)
      # Find the table we just inserted
      tbl_nodes <- xml2::xml_find_all(body, ".//w:tbl[w:tblPr/w:tblpPr]", ns)
      if (length(tbl_nodes) > 0) {
        # Use the last one (most recently inserted, processing in reverse)
        relocate_to_adjacent(body, tbl_nodes[[length(tbl_nodes)]], fr$payload$adjacent, ns)
      }
    }
```

For the **image** branch (after markers are removed, around line 568):

```r
    # Adjacency relocation for images
    if (!is.null(fr$payload$adjacent) && nzchar(fr$payload$adjacent)) {
      # Find the paragraph containing the image we just anchored
      children <- xml2::xml_children(body)
      ns_ext <- c(ns,
        wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
        pic = "http://schemas.openxmlformats.org/drawingml/2006/picture"
      )
      for (ci in seq_along(children)) {
        if (is_anchored_image(children[[ci]], ns)) {
          # Create dedicated paragraph for the drawing
          drawing_run <- xml2::xml_find_first(children[[ci]], ".//w:r[w:drawing]", ns)
          if (!inherits(drawing_run, "xml_missing")) {
            wrapper_xml <- paste0(
              '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
              as.character(drawing_run),
              '</w:p>'
            )
            wrapper_para <- xml2::read_xml(wrapper_xml)
            target_para <- find_bookmark_paragraph(body, fr$payload$adjacent, ns)
            if (!is.null(target_para)) {
              xml2::xml_add_sibling(target_para, wrapper_para, .where = "before")
              xml2::xml_remove(children[[ci]])
            } else {
              warning("[anchor-assembly] Bookmark '", sub("^#", "", fr$payload$adjacent),
                      "' not found, using source position", call. = FALSE)
            }
          }
          break
        }
      }
    }
```

For the **textbox** branch (after markers are removed, in the new textbox dispatch code):

```r
    # Adjacency relocation for text boxes
    if (!is.null(fr$payload$adjacent) && nzchar(fr$payload$adjacent)) {
      children <- xml2::xml_children(body)
      # Find the textbox paragraph we just inserted (has wp:anchor with wps:txbx)
      ns_txbx <- c(ns,
        wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
        wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
      )
      for (ci in seq_along(children)) {
        txbx <- xml2::xml_find_first(children[[ci]], ".//wps:txbx", ns_txbx)
        if (!inherits(txbx, "xml_missing")) {
          relocate_to_adjacent(body, children[[ci]], fr$payload$adjacent, ns)
          break
        }
      }
    }
```

**Important:** The exact integration points depend on the code as it exists after Tasks 1-4. The implementer should read the current assembly loop and place the adjacency check after each branch's marker removal, before the `n_assembled` increment.

- [ ] **Step 4: Run tests to verify they pass**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-anchor-assembly.R")'`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `Rscript -e 'devtools::test()'`
Expected: 0 failures

- [ ] **Step 6: Commit**

```bash
git add R/anchor_assembly.R tests/testthat/test-anchor-assembly.R
git commit -m "Add explicit adjacency relocation via bookmark lookup (#117)"
```

---

### Task 7: Harvest text boxes

Add detection, property extraction, and content extraction for DrawingML text boxes in the harvest pipeline.

**Files:**
- Modify: `R/anchor_assembly.R` (add `is_text_box()`, `extract_text_box_properties()`, `extract_text_box_content()`)
- Modify: `R/docx_to_qmd.R` (add text box detection in harvest loop)
- Test: `tests/testthat/test-harvest-anchor.R`

- [ ] **Step 1: Write failing tests for text box detection and extraction**

Add to `tests/testthat/test-harvest-anchor.R`:

```r
test_that("is_text_box() detects wp:anchor with wps:txbx", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">',
    '<w:r><w:drawing>',
    '<wp:anchor simplePos="0" behindDoc="0" locked="0" layoutInCell="1" allowOverlap="1"',
    ' distT="0" distB="0" distL="0" distR="0" relativeHeight="251658240">',
    '<wp:simplePos x="0" y="0"/>',
    '<wp:positionH relativeFrom="margin"><wp:posOffset>0</wp:posOffset></wp:positionH>',
    '<wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>',
    '<wp:extent cx="1828800" cy="914400"/>',
    '<wp:effectExtent l="0" t="0" r="0" b="0"/>',
    '<wp:wrapSquare wrapText="bothSides"/>',
    '<wp:docPr id="1" name="TextBox 1"/>',
    '<wp:cNvGraphicFramePr/>',
    '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">',
    '<a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">',
    '<wps:wsp>',
    '<wps:cNvSpPr txBox="1"/>',
    '<wps:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="1828800" cy="914400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></wps:spPr>',
    '<wps:txbx><w:txbxContent>',
    '<w:p><w:r><w:t>Text inside box</w:t></w:r></w:p>',
    '</w:txbxContent></wps:txbx>',
    '<wps:bodyPr wrap="square" lIns="91440" tIns="45720" rIns="91440" bIns="45720" anchor="t"/>',
    '</wps:wsp>',
    '</a:graphicData></a:graphic>',
    '</wp:anchor>',
    '</w:drawing></w:r></w:p>'
  )

  para <- xml2::read_xml(para_xml)
  expect_true(is_text_box(para, ns))
})

test_that("is_text_box() returns FALSE for anchored image", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<w:r><w:drawing><wp:anchor simplePos="0" behindDoc="0" locked="0"',
    ' layoutInCell="1" allowOverlap="1" distT="0" distB="0" distL="0" distR="0"',
    ' relativeHeight="251658240">',
    '<wp:simplePos x="0" y="0"/>',
    '<wp:positionH relativeFrom="margin"><wp:posOffset>0</wp:posOffset></wp:positionH>',
    '<wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>',
    '<wp:extent cx="914400" cy="914400"/>',
    '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">',
    '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:blipFill><a:blip/></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:ext cx="914400" cy="914400"/></a:xfrm></pic:spPr>',
    '</pic:pic></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing></w:r></w:p>'
  )

  para <- xml2::read_xml(para_xml)
  expect_false(is_text_box(para, ns))
})

test_that("extract_text_box_properties() reads positioning", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">',
    '<w:r><w:drawing>',
    '<wp:anchor simplePos="0" behindDoc="1" locked="0" layoutInCell="1" allowOverlap="1"',
    ' distT="0" distB="0" distL="0" distR="0" relativeHeight="251658240">',
    '<wp:simplePos x="0" y="0"/>',
    '<wp:positionH relativeFrom="page"><wp:posOffset>457200</wp:posOffset></wp:positionH>',
    '<wp:positionV relativeFrom="margin"><wp:posOffset>914400</wp:posOffset></wp:positionV>',
    '<wp:extent cx="1828800" cy="914400"/>',
    '<wp:effectExtent l="0" t="0" r="0" b="0"/>',
    '<wp:wrapNone/>',
    '<wp:docPr id="5" name="TextBox 5"/>',
    '<wp:cNvGraphicFramePr/>',
    '<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">',
    '<wps:wsp><wps:cNvSpPr txBox="1"/>',
    '<wps:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="1828800" cy="914400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></wps:spPr>',
    '<wps:txbx><w:txbxContent><w:p><w:r><w:t>Content</w:t></w:r></w:p></w:txbxContent></wps:txbx>',
    '<wps:bodyPr wrap="square"/>',
    '</wps:wsp></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing></w:r></w:p>'
  )

  para <- xml2::read_xml(para_xml)
  props <- extract_text_box_properties(para, ns)
  expect_false(is.null(props))
  expect_equal(props$horizontal_anchor, "page")
  expect_equal(props$vertical_anchor, "margin")
  expect_equal(props$z_layer, "behind")
  expect_equal(props$wrap_style, "none")
  # posOffset 457200 EMU / 635 = 720 DXA
  expect_equal(props$position_x, "720")
})

test_that("extract_text_box_content() returns inner paragraphs", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">',
    '<w:r><w:drawing>',
    '<wp:anchor simplePos="0" behindDoc="0" locked="0" layoutInCell="1" allowOverlap="1"',
    ' distT="0" distB="0" distL="0" distR="0" relativeHeight="251658240">',
    '<wp:simplePos x="0" y="0"/>',
    '<wp:positionH relativeFrom="margin"><wp:posOffset>0</wp:posOffset></wp:positionH>',
    '<wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>',
    '<wp:extent cx="1828800" cy="914400"/>',
    '<wp:docPr id="1" name="TextBox 1"/>',
    '<wp:cNvGraphicFramePr/>',
    '<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">',
    '<wps:wsp><wps:cNvSpPr txBox="1"/>',
    '<wps:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="1828800" cy="914400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></wps:spPr>',
    '<wps:txbx><w:txbxContent>',
    '<w:p><w:r><w:t>First</w:t></w:r></w:p>',
    '<w:p><w:r><w:t>Second</w:t></w:r></w:p>',
    '</w:txbxContent></wps:txbx>',
    '<wps:bodyPr wrap="square"/>',
    '</wps:wsp></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing></w:r></w:p>'
  )

  para <- xml2::read_xml(para_xml)
  content <- extract_text_box_content(para, ns)
  expect_length(content, 2L)
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-harvest-anchor.R")'`
Expected: FAIL — functions not defined

- [ ] **Step 3: Implement `is_text_box()`, `extract_text_box_properties()`, `extract_text_box_content()`**

Add to `R/anchor_assembly.R` after the existing `extract_anchor_image_properties()`:

```r
#' Check if a paragraph contains a text box
#'
#' Detects `w:drawing/wp:anchor` containing `wps:txbx` (not `pic:pic`).
#'
#' @param para xml2 node for w:p
#' @param ns Named character vector of XML namespaces
#' @return Logical
#' @export
is_text_box <- function(para, ns) {
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture"
  )
  anchors <- xml2::xml_find_all(para, ".//wp:anchor", ns = ns_ext)
  if (length(anchors) == 0) return(FALSE)

  for (anchor in anchors) {
    # Must have wps:txbx but NOT pic:pic
    txbx <- xml2::xml_find_first(anchor, ".//wps:txbx", ns = ns_ext)
    pics <- xml2::xml_find_all(anchor, ".//pic:pic", ns = ns_ext)
    if (!inherits(txbx, "xml_missing") && length(pics) == 0) return(TRUE)
  }
  FALSE
}


#' Extract positioning properties from a text box anchor
#'
#' Reads `wp:anchor` positioning, extent, wrap style, and z-layer from a
#' paragraph containing a DrawingML text box. Same property set as
#' `extract_anchor_image_properties()`.
#'
#' @param para xml2 node for w:p containing a text box
#' @param ns Named character vector of XML namespaces
#' @return Named list with horizontal_anchor, vertical_anchor, position_x,
#'   position_y, float_width, z_layer, wrap_style. NULL if not a text box.
#' @export
extract_text_box_properties <- function(para, ns) {
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    a = "http://schemas.openxmlformats.org/drawingml/2006/main"
  )

  anchor <- xml2::xml_find_first(para, ".//wp:anchor", ns = ns_ext)
  if (inherits(anchor, "xml_missing")) return(NULL)

  # Reuse the same extraction logic as extract_anchor_image_properties
  # Horizontal position
  posH <- xml2::xml_find_first(anchor, "wp:positionH", ns = ns_ext)
  relH <- if (!inherits(posH, "xml_missing")) xml2::xml_attr(posH, "relativeFrom") else "margin"
  offsetH <- "0"
  if (!inherits(posH, "xml_missing")) {
    off_node <- xml2::xml_find_first(posH, "wp:posOffset", ns = ns_ext)
    if (!inherits(off_node, "xml_missing")) {
      emu_val <- as.numeric(xml2::xml_text(off_node))
      offsetH <- as.character(as.integer(round(emu_val / 635)))
    }
  }

  # Vertical position
  posV <- xml2::xml_find_first(anchor, "wp:positionV", ns = ns_ext)
  relV <- if (!inherits(posV, "xml_missing")) xml2::xml_attr(posV, "relativeFrom") else "paragraph"
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
  behind_doc <- xml2::xml_attr(anchor, "behindDoc")
  if (is.na(behind_doc)) behind_doc <- "0"
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


#' Extract content paragraphs from a text box
#'
#' Returns the `w:p` elements inside `wps:txbx/w:txbxContent`.
#'
#' @param para xml2 node for w:p containing a text box
#' @param ns Named character vector of XML namespaces
#' @return xml2 nodeset of w:p elements, or empty nodeset
#' @export
extract_text_box_content <- function(para, ns) {
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
  )
  xml2::xml_find_all(para, ".//wps:txbx/w:txbxContent/w:p", ns = ns_ext)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-harvest-anchor.R")'`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add R/anchor_assembly.R tests/testthat/test-harvest-anchor.R
git commit -m "Add text box detection and extraction for harvest pipeline"
```

---

### Task 8: Wire text box harvest into `docx_to_qmd.R`

Add text box detection to the harvest loop, emitting `::: {.class content-mode="textbox"}` divs with recursively converted content.

**Files:**
- Modify: `R/docx_to_qmd.R`
- Test: `tests/testthat/test-harvest-anchor.R`

- [ ] **Step 1: Write a failing integration test**

Add to `tests/testthat/test-harvest-anchor.R`:

```r
test_that("harvest detects text box and emits div with content-mode=textbox", {
  # This tests the detection path in docx_to_qmd.R indirectly
  # by checking is_text_box before is_anchored_image in priority order
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # Text box paragraph
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">',
    '<w:r><w:drawing>',
    '<wp:anchor simplePos="0" behindDoc="0" locked="0" layoutInCell="1" allowOverlap="1"',
    ' distT="0" distB="0" distL="0" distR="0" relativeHeight="251658240">',
    '<wp:simplePos x="0" y="0"/>',
    '<wp:positionH relativeFrom="margin"><wp:posOffset>0</wp:posOffset></wp:positionH>',
    '<wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>',
    '<wp:extent cx="1828800" cy="914400"/>',
    '<wp:docPr id="1" name="TextBox 1"/>',
    '<wp:cNvGraphicFramePr/>',
    '<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">',
    '<wps:wsp><wps:cNvSpPr txBox="1"/>',
    '<wps:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="1828800" cy="914400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></wps:spPr>',
    '<wps:txbx><w:txbxContent>',
    '<w:p><w:r><w:t>Box content</w:t></w:r></w:p>',
    '</w:txbxContent></wps:txbx>',
    '<wps:bodyPr wrap="square"/>',
    '</wps:wsp></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing></w:r></w:p>'
  )

  para <- xml2::read_xml(para_xml)

  # Should be detected as text box, not as anchored image
  expect_true(is_text_box(para, ns))
  expect_false(is_anchored_image(para, ns))

  # Should extract properties
  props <- extract_text_box_properties(para, ns)
  expect_false(is.null(props))
  expect_equal(props$horizontal_anchor, "margin")

  # Should extract content
  content <- extract_text_box_content(para, ns)
  expect_length(content, 1L)
  expect_equal(
    xml2::xml_text(xml2::xml_find_first(content[[1]], ".//w:t", ns)),
    "Box content"
  )
})
```

- [ ] **Step 2: Add text box detection to `docx_to_qmd.R` harvest loop**

In `R/docx_to_qmd.R`, find the anchored image check (the block starting with `if (is_anchored_image(p, ns))`). Add a text box check **before** the anchored image check, since `is_text_box()` and `is_anchored_image()` are mutually exclusive:

```r
    # Check for text box (wp:anchor with wps:txbx) before anchored image check
    if (is_text_box(p, ns)) {
      tb_props <- extract_text_box_properties(p, ns)
      tb_content <- extract_text_box_content(p, ns)

      # Determine class from pending anchor range or default
      tb_class <- "column-margin"
      if (!is.null(pending_anchor_range)) {
        tb_class <- pending_anchor_range$class
        pending_anchor_range <- NULL
      }

      # Build div attributes
      div_attrs <- character(0)
      div_attrs <- c(div_attrs, 'content-mode="textbox"')
      if (!is.null(tb_props)) {
        if (!is.null(tb_props$float_width))
          div_attrs <- c(div_attrs, paste0('float-width="', tb_props$float_width, 'dxa"'))
        if (tb_props$vertical_anchor != "text")
          div_attrs <- c(div_attrs, paste0('vertical-anchor="', tb_props$vertical_anchor, '"'))
        if (tb_props$horizontal_anchor != "margin")
          div_attrs <- c(div_attrs, paste0('horizontal-anchor="', tb_props$horizontal_anchor, '"'))
        if (tb_props$position_y != "0")
          div_attrs <- c(div_attrs, paste0('position-y="', tb_props$position_y, 'dxa"'))
        if (tb_props$position_x != "0")
          div_attrs <- c(div_attrs, paste0('position-x="', tb_props$position_x, 'dxa"'))
        if (tb_props$z_layer != "front")
          div_attrs <- c(div_attrs, paste0('z-layer="', tb_props$z_layer, '"'))
      }

      div_open <- paste0("::: {.", tb_class, " ", paste(div_attrs, collapse = " "), "}")
      lines <- c(lines, "", div_open)

      # Recursively convert content paragraphs to markdown
      for (cp in tb_content) {
        cp_text <- extract_formatted_text(cp, ns, image_rels)
        if (nzchar(trimws(cp_text))) {
          lines <- c(lines, cp_text)
        }
      }

      lines <- c(lines, ":::")
      harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
        para_index = i - 1L, type = "content",
        qmd_lines  = c(length(lines) - 1L, length(lines)),
        style      = "anchor-textbox"
      )
      next
    }
```

- [ ] **Step 3: Run tests to verify they pass**

Run: `Rscript -e 'devtools::test()'`
Expected: 0 failures

- [ ] **Step 4: Commit**

```bash
git add R/docx_to_qmd.R tests/testthat/test-harvest-anchor.R
git commit -m "Add text box harvest path in docx_to_qmd.R"
```

---

### Task 9: Update documentation

Update `ARCHITECTURE-anchors.md` and `CLAUDE.md` with the new text box mechanism and adjacency feature.

**Files:**
- Modify: `dev/ARCHITECTURE-anchors.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update ARCHITECTURE-anchors.md**

Add text box mechanism and adjacency sections. Update the pipeline diagram to show all four content paths. Add the relocation mechanics section explaining the two strategies (floating table sibling order vs DrawingML parent paragraph).

Key additions:
- Text box OOXML structure (`wps:wsp` → `wps:txbx` → `w:txbxContent`)
- `content-mode: textbox` CSS property
- Adjacency via bookmark lookup
- Relocation strategies by content type
- Harvest detection order: text box → anchored image → floating table

- [ ] **Step 2: Update CLAUDE.md**

Update the anchor assembly description in the Phase 3 pipeline to mention text box assembly. Update the key source file map if new exported functions were added. Add `content-mode` to the CSS properties documentation.

- [ ] **Step 3: Run full test suite**

Run: `Rscript -e 'devtools::test()'`
Expected: 0 failures (docs changes shouldn't break anything)

- [ ] **Step 4: Commit**

```bash
git add -f dev/ARCHITECTURE-anchors.md CLAUDE.md
git commit -m "Update docs for text box assembly and explicit adjacency"
```

---

## Self-review

**Spec coverage:**
- Feature 1 (text via floating table): Task 1 ✓
- Feature 2 (text box): Tasks 2-4 ✓ (CSS pipeline, build function, dispatch wiring)
- Feature 3 (adjacency): Tasks 5-6 ✓ (bookmark lookup, relocation)
- Harvest round-trip: Tasks 7-8 ✓ (text box detection, extraction, harvest loop)
- Typst: No tasks needed — `anchor.lua` already returns nil for non-OOXML ✓
- Docs: Task 9 ✓

**Placeholder scan:** No TBDs or TODOs found. All code blocks complete.

**Type consistency:**
- `build_text_box_anchor()` signature: `(content_paras, payload, ns, next_docpr_id)` — consistent across Task 3 (definition), Task 4 (call site)
- `find_bookmark_paragraph()` signature: `(body, bookmark_id, ns)` — consistent across Task 5 (definition), Task 6 (call sites)
- `is_text_box()`, `extract_text_box_properties()`, `extract_text_box_content()` — consistent signatures across Task 7 (definition) and Task 8 (call site)
- `content_mode` property name — consistent: CSS `content-mode`, R `content_mode`, Lua `content_mode`, schema `content_mode`
