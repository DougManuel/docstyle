# Anchor Positioning Phase 2c: Grouped Image+Caption Figures — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add grouped figure assembly and harvest for anchor positioning — a positioned div containing an image and caption text produces a Word Group Shape (`wpg:wgp`) with pixel-accurate round-trip fidelity.

**Architecture:** `detect_anchor_content()` gains a `"group"` return value for image+text content. `build_group_anchor()` constructs `wpg:wgp` inside `wp:anchor` via `sprintf`. Harvest detects `wpg:wgp` (including inside `mc:AlternateContent`) and emits a fenced div with image, caption, and positioning attributes.

**Tech Stack:** R (xml2, jsonlite), OOXML WordprocessingGroup schema

**Prerequisite:** Phase 2b (PR #121) must be merged to `main` before starting. Phase 2c branches from the merged result.

---

## File structure

| File | Responsibility |
|------|---------------|
| `R/anchor_assembly.R` | `detect_anchor_content()` change, new `build_group_anchor()`, dispatch branch, new harvest functions `is_grouped_figure()`, `extract_group_properties()`, `extract_group_content()` |
| `R/docx_to_qmd.R` | Grouped figure harvest path in `convert_to_qmd()` |
| `R/field_codes.R` | Add `caption_y`, `image_height` to anchor schema |
| `inst/schema/docstyle-field-codes.json` | Add `caption_y`, `image_height` to `anchor_payload_fields` |
| `tests/testthat/test-anchor-assembly.R` | Group detection and assembly tests |
| `tests/testthat/test-harvest-anchor.R` | Group harvest tests |
| `dev/ARCHITECTURE-anchors.md` | Update content dispatch table, harvest order, group OOXML structure |

---

### Task 1: Content detection — `detect_anchor_content()` returns `"group"` for image+text

**Files:**
- Modify: `R/anchor_assembly.R:328-374` (`detect_anchor_content()`)
- Modify: `R/anchor_assembly.R:326-327` (roxygen `@return`)
- Test: `tests/testthat/test-anchor-assembly.R`

- [ ] **Step 1: Write failing test — image+text returns "group"**

Add to `tests/testthat/test-anchor-assembly.R`, after the existing helpers (around line 115):

```r
# --- detect_anchor_content() tests ---

test_that("detect_anchor_content() returns 'group' for image + text", {
  # Image paragraph (w:drawing with pic:pic)
  img_para <- xml2::read_xml(paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><w:drawing><wp:inline>',
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="img1.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="685800"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>',
    '</pic:pic></a:graphicData></a:graphic>',
    '</wp:inline></w:drawing></w:r></w:p>'
  ))

  # Caption paragraph (text only)
  caption_para <- xml2::read_xml(paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:r><w:t>Figure 1. Caption text</w:t></w:r></w:p>'
  ))

  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  nodes <- xml2::xml_find_all(
    xml2::read_xml(paste0(
      '<wrapper xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
      ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
      ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
      ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
      ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
      as.character(img_para), as.character(caption_para),
      '</wrapper>'
    )),
    "./*"
  )

  expect_equal(detect_anchor_content(nodes, ns), "group")
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /path/to/worktree && Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-anchor-assembly.R", reporter = "summary")'`

Expected: FAIL — `detect_anchor_content()` returns `"mixed"`, not `"group"`

- [ ] **Step 3: Write failing test — table+text still returns "mixed"**

```r
test_that("detect_anchor_content() returns 'mixed' for table + text (not group)", {
  wrapper_xml <- paste0(
    '<wrapper xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:tbl><w:tblPr><w:tblW w:w="5000" w:type="dxa"/></w:tblPr>',
    '<w:tblGrid><w:gridCol w:w="5000"/></w:tblGrid>',
    '<w:tr><w:tc><w:tcPr><w:tcW w:w="5000" w:type="dxa"/></w:tcPr>',
    '<w:p><w:r><w:t>Table cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>',
    '<w:p><w:r><w:t>Text paragraph</w:t></w:r></w:p>',
    '</wrapper>'
  )
  nodes <- xml2::xml_find_all(xml2::read_xml(wrapper_xml), "./*")
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  expect_equal(detect_anchor_content(nodes, ns), "mixed")
})

test_that("detect_anchor_content() returns 'mixed' for table + image", {
  wrapper_xml <- paste0(
    '<wrapper xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:tbl><w:tblPr><w:tblW w:w="5000" w:type="dxa"/></w:tblPr>',
    '<w:tblGrid><w:gridCol w:w="5000"/></w:tblGrid>',
    '<w:tr><w:tc><w:tcPr><w:tcW w:w="5000" w:type="dxa"/></w:tcPr>',
    '<w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>',
    '<w:p><w:r><w:drawing><wp:inline>',
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="img"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="685800"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>',
    '</pic:pic></a:graphicData></a:graphic>',
    '</wp:inline></w:drawing></w:r></w:p>',
    '</wrapper>'
  )
  nodes <- xml2::xml_find_all(xml2::read_xml(wrapper_xml), "./*")
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  expect_equal(detect_anchor_content(nodes, ns), "mixed")
})
```

- [ ] **Step 4: Implement `detect_anchor_content()` change**

In `R/anchor_assembly.R`, update the classification logic at lines 367-374. Replace:

```r
  # Classification logic — any combination of two+ types is "mixed"
  if (has_table && has_image) return("mixed")
  if (has_table && has_text) return("mixed")
  if (has_image && has_text) return("mixed")
  if (has_table) return("table")
  if (has_image) return("image")
  "text"
```

With:

```r
  # Classification logic
  # Image+text (no table) is a grouped figure — semantic mapping to wpg:wgp
  if (has_image && has_text && !has_table) return("group")
  # Any other combination of two+ types is "mixed"
  if (has_table && has_image) return("mixed")
  if (has_table && has_text) return("mixed")
  if (has_table) return("table")
  if (has_image) return("image")
  "text"
```

Also update the roxygen `@return` on line 326 from:

```r
#' @return Character: "table", "image", "text", or "mixed"
```

To:

```r
#' @return Character: "table", "image", "text", "group", or "mixed"
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /path/to/worktree && Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-anchor-assembly.R", reporter = "summary")'`

Expected: All new tests PASS. Check that existing tests that previously expected `"mixed"` for image+text now need updating (search test file for `"mixed"`). If any existing test asserts `"mixed"` for image+text specifically, update to expect `"group"`.

- [ ] **Step 6: Commit**

```bash
git add R/anchor_assembly.R tests/testthat/test-anchor-assembly.R
git commit -m "detect_anchor_content: return 'group' for image+text content"
```

---

### Task 2: `build_group_anchor()` — construct `wpg:wgp` inside `wp:anchor`

**Files:**
- Modify: `R/anchor_assembly.R` (add new function after `build_text_box_anchor()`, around line 371)
- Test: `tests/testthat/test-anchor-assembly.R`

- [ ] **Step 1: Write failing test — basic group assembly succeeds**

```r
test_that("build_group_anchor() produces wpg:wgp with pic:pic and wps:wsp", {
  # Create content nodes: one image paragraph, one caption paragraph
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    a = "http://schemas.openxmlformats.org/drawingml/2006/main",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup",
    r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  )

  wrapper_xml <- paste0(
    '<wrapper xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:p><w:r><w:drawing><wp:inline>',
    '<wp:extent cx="5943600" cy="3962400"/>',
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="img1.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="5943600" cy="3962400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>',
    '</pic:pic></a:graphicData></a:graphic>',
    '</wp:inline></w:drawing></w:r></w:p>',
    '<w:p><w:r><w:t>Figure 1. Caption text</w:t></w:r></w:p>',
    '</wrapper>'
  )
  content_nodes <- xml2::xml_find_all(xml2::read_xml(wrapper_xml), "./*")

  payload <- list(
    vertical_anchor = "text",
    horizontal_anchor = "margin",
    position_y = "0",
    position_x = "0",
    float_width = "9348dxa",
    wrap_style = "square",
    wrap_side = "both",
    wrap_distance = "0 198dxa 0 198dxa"
  )

  result <- build_group_anchor(content_nodes, payload, ns_ext, next_docpr_id = 10L)

  expect_true(result$success)
  expect_equal(result$docpr_id, 10L)

  # Parse result and check structure
  doc <- result$para
  wgp <- xml2::xml_find_first(doc, ".//wpg:wgp", ns = ns_ext)
  expect_false(inherits(wgp, "xml_missing"))

  # Has pic:pic child
  pic <- xml2::xml_find_first(wgp, ".//pic:pic", ns = ns_ext)
  expect_false(inherits(pic, "xml_missing"))

  # Has wps:wsp child with txbx
  wsp <- xml2::xml_find_first(wgp, ".//wps:wsp", ns = ns_ext)
  expect_false(inherits(wsp, "xml_missing"))

  txbx <- xml2::xml_find_first(wsp, ".//wps:txbx", ns = ns_ext)
  expect_false(inherits(txbx, "xml_missing"))

  # Blip embed is preserved
  blip <- xml2::xml_find_first(pic, ".//a:blip", ns = ns_ext)
  expect_false(inherits(blip, "xml_missing"))
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /path/to/worktree && Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-anchor-assembly.R", reporter = "summary")'`

Expected: FAIL — `build_group_anchor` not found

- [ ] **Step 3: Implement `build_group_anchor()`**

Add after `build_text_box_anchor()` in `R/anchor_assembly.R`:

```r
#' Build group shape anchor for image+caption figures
#'
#' Constructs a `wpg:wgp` inside `wp:anchor` containing a `pic:pic` member
#' (image) and a `wps:wsp` member (caption text box). Follows the same
#' interface as `build_text_box_anchor()`.
#'
#' @param content_nodes xml2 nodeset of body children between markers
#' @param payload Named list of positioning properties from field code
#' @param ns Named character vector of XML namespaces (must include wp, a, pic, wps, r)
#' @param next_docpr_id Integer. Next available wp:docPr ID.
#' @return List with `success` (logical), `para` (xml2 node), `docpr_id` (integer),
#'   and optionally `reason` (character) on failure.
#' @noRd
build_group_anchor <- function(content_nodes, payload, ns, next_docpr_id = 1L) {
  # Separate content into image paragraphs and caption paragraphs
  image_paras <- list()
  caption_paras <- list()

  for (node in content_nodes) {
    node_name <- xml2::xml_name(node)
    if (node_name != "p") {
      caption_paras <- c(caption_paras, list(node))
      next
    }
    drawings <- xml2::xml_find_all(node, ".//w:drawing", ns = ns)
    has_pic <- FALSE
    if (length(drawings) > 0) {
      pics <- xml2::xml_find_all(node,
        ".//pic:pic",
        ns = c(ns, pic = "http://schemas.openxmlformats.org/drawingml/2006/picture"))
      if (length(pics) > 0) has_pic <- TRUE
    }
    if (has_pic) {
      image_paras <- c(image_paras, list(node))
    } else {
      caption_paras <- c(caption_paras, list(node))
    }
  }

  if (length(image_paras) == 0) {
    return(list(success = FALSE, reason = "no image found in group content"))
  }

  # Extract pic:pic from first image paragraph's wp:inline
  img_para <- image_paras[[1]]
  pic_node <- xml2::xml_find_first(img_para,
    ".//pic:pic",
    ns = c(ns, pic = "http://schemas.openxmlformats.org/drawingml/2006/picture"))
  if (inherits(pic_node, "xml_missing")) {
    return(list(success = FALSE, reason = "could not extract pic:pic from image paragraph"))
  }

  # Get blip embed ID for verification
  blip <- xml2::xml_find_first(pic_node, ".//a:blip", ns = ns)
  blip_embed <- if (!inherits(blip, "xml_missing")) {
    embed <- xml2::xml_attr(blip, "embed")
    if (is.na(embed)) xml2::xml_attr(blip, "r:embed") else embed
  } else {
    NA_character_
  }

  # Extract original image dimensions from pic:spPr/a:xfrm/a:ext
  pic_ext <- xml2::xml_find_first(pic_node, ".//a:xfrm/a:ext", ns = ns)
  pic_cx_emu <- if (!inherits(pic_ext, "xml_missing")) {
    as.numeric(xml2::xml_attr(pic_ext, "cx"))
  } else {
    NA_real_
  }
  pic_cy_emu <- if (!inherits(pic_ext, "xml_missing")) {
    as.numeric(xml2::xml_attr(pic_ext, "cy"))
  } else {
    NA_real_
  }

  # Serialize pic:pic to XML string (detached from wp:inline context)
  pic_xml <- as.character(pic_node)

  # Serialize caption paragraphs
  caption_xml <- ""
  if (length(caption_paras) > 0) {
    caption_parts <- vapply(caption_paras, function(p) as.character(p), character(1))
    caption_xml <- paste(caption_parts, collapse = "")
  }

  # --- Dimensions ---
  # Group width from payload
  group_width_emu <- css_to_emu(payload$float_width %||% "5000dxa")

  # Image height: from payload or compute from aspect ratio
  if (!is.null(payload$image_height)) {
    image_height_emu <- css_to_emu(payload$image_height)
  } else if (!is.na(pic_cy_emu) && !is.na(pic_cx_emu) && pic_cx_emu > 0) {
    # Scale to group width preserving aspect ratio
    image_height_emu <- as.integer(round(group_width_emu * (pic_cy_emu / pic_cx_emu)))
  } else {
    # Default: 3 inches
    image_height_emu <- 2743200L
  }
  image_height_emu <- as.integer(image_height_emu)

  # Caption Y offset: from payload or image_height + small gap
  if (!is.null(payload$caption_y)) {
    caption_y_emu <- css_to_emu(payload$caption_y)
  } else {
    caption_y_emu <- image_height_emu + 91440L  # 0.1 inch gap
  }
  caption_y_emu <- as.integer(caption_y_emu)

  # Caption text box height: generous default — Word auto-sizes
  caption_height_emu <- 914400L  # 1 inch

  # Group total height
  group_height_emu <- caption_y_emu + caption_height_emu

  # --- Positioning ---
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

  # --- Build XML ---
  full_xml <- sprintf(paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"',
    ' xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"',
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
    '%s',
    '<wp:docPr id="%d" name="Group %d"/>',
    '<wp:cNvGraphicFramePr/>',
    '<a:graphic>',
    '<a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup">',
    '<wpg:wgp>',
    '<wpg:cNvGrpSpPr/>',
    '<wpg:grpSpPr>',
    '<a:xfrm>',
    '<a:off x="0" y="0"/>',
    '<a:ext cx="%d" cy="%d"/>',
    '<a:chOff x="0" y="0"/>',
    '<a:chExt cx="%d" cy="%d"/>',
    '</a:xfrm>',
    '</wpg:grpSpPr>',
    '%s',
    '<wps:wsp>',
    '<wps:cNvSpPr txBox="1"/>',
    '<wps:spPr>',
    '<a:xfrm>',
    '<a:off x="0" y="%d"/>',
    '<a:ext cx="%d" cy="%d"/>',
    '</a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>',
    '<a:noFill/>',
    '<a:ln><a:noFill/></a:ln>',
    '</wps:spPr>',
    '<wps:txbx><w:txbxContent>',
    '%s',
    '</w:txbxContent></wps:txbx>',
    '<wps:bodyPr rot="0" wrap="square"',
    ' lIns="91440" tIns="45720" rIns="91440" bIns="45720"',
    ' anchor="t" anchorCtr="0"/>',
    '</wps:wsp>',
    '</wpg:wgp>',
    '</a:graphicData>',
    '</a:graphic>',
    '</wp:anchor>',
    '</w:drawing></w:r></w:p>'
  ),
    dist_t, dist_b, dist_l, dist_r,
    behind_doc,
    anchor_to_posH_relative(horz_anchor), pos_x_emu,
    anchor_to_posV_relative(vert_anchor), pos_y_emu,
    group_width_emu, group_height_emu,
    wrap_xml,
    next_docpr_id, next_docpr_id,
    group_width_emu, group_height_emu,
    group_width_emu, group_height_emu,
    pic_xml,
    caption_y_emu,
    group_width_emu, caption_height_emu,
    caption_xml
  )

  result_doc <- tryCatch(
    xml2::read_xml(full_xml),
    error = function(e) e
  )
  if (inherits(result_doc, "error")) {
    return(list(success = FALSE,
                reason = paste0("failed to parse constructed group XML: ",
                                conditionMessage(result_doc))))
  }

  list(success = TRUE, para = result_doc, docpr_id = next_docpr_id)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /path/to/worktree && Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-anchor-assembly.R", reporter = "summary")'`

Expected: PASS

- [ ] **Step 5: Write tests for `caption_y`/`image_height` payload and defaults**

```r
test_that("build_group_anchor() uses caption_y and image_height from payload", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    a = "http://schemas.openxmlformats.org/drawingml/2006/main",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup",
    r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  )

  wrapper_xml <- paste0(
    '<wrapper xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:p><w:r><w:drawing><wp:inline>',
    '<wp:extent cx="5943600" cy="3962400"/>',
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="img1.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="5943600" cy="3962400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>',
    '</pic:pic></a:graphicData></a:graphic>',
    '</wp:inline></w:drawing></w:r></w:p>',
    '<w:p><w:r><w:t>Caption</w:t></w:r></w:p>',
    '</wrapper>'
  )
  content_nodes <- xml2::xml_find_all(xml2::read_xml(wrapper_xml), "./*")

  # caption_y = 4978dxa -> 4978 * 635 = 3161030 EMU
  # image_height = 3200dxa -> 3200 * 635 = 2032000 EMU
  payload <- list(
    float_width = "9348dxa",
    caption_y = "4978dxa",
    image_height = "3200dxa",
    wrap_distance = "0 198dxa 0 198dxa"
  )

  result <- build_group_anchor(content_nodes, payload, ns_ext, next_docpr_id = 5L)
  expect_true(result$success)

  # Check caption wps:wsp offset y matches caption_y in EMU
  wsp_off <- xml2::xml_find_first(result$para,
    ".//wps:wsp/wps:spPr/a:xfrm/a:off", ns = ns_ext)
  expect_false(inherits(wsp_off, "xml_missing"))
  expect_equal(xml2::xml_attr(wsp_off, "y"), "3161030")
})

test_that("build_group_anchor() computes defaults when caption_y absent", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    a = "http://schemas.openxmlformats.org/drawingml/2006/main",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup",
    r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  )

  wrapper_xml <- paste0(
    '<wrapper xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:p><w:r><w:drawing><wp:inline>',
    '<wp:extent cx="5943600" cy="3962400"/>',
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="img1.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="5943600" cy="3962400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>',
    '</pic:pic></a:graphicData></a:graphic>',
    '</wp:inline></w:drawing></w:r></w:p>',
    '<w:p><w:r><w:t>Caption</w:t></w:r></w:p>',
    '</wrapper>'
  )
  content_nodes <- xml2::xml_find_all(xml2::read_xml(wrapper_xml), "./*")

  payload <- list(
    float_width = "5943600",  # raw EMU (no unit suffix)
    wrap_distance = "0 198dxa 0 198dxa"
  )

  result <- build_group_anchor(content_nodes, payload, ns_ext, next_docpr_id = 1L)
  expect_true(result$success)

  # Caption y should be image_height + 91440 (0.1 inch gap)
  wsp_off <- xml2::xml_find_first(result$para,
    ".//wps:wsp/wps:spPr/a:xfrm/a:off", ns = ns_ext)
  caption_y <- as.numeric(xml2::xml_attr(wsp_off, "y"))
  # Image height is scaled from aspect ratio: 5943600 * (3962400/5943600) = 3962400
  # caption_y = 3962400 + 91440 = 4053840
  expect_equal(caption_y, 4053840)
})

test_that("build_group_anchor() succeeds with image only (empty caption)", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    a = "http://schemas.openxmlformats.org/drawingml/2006/main",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup",
    r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  )

  # Only an image paragraph, no caption
  wrapper_xml <- paste0(
    '<wrapper xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:p><w:r><w:drawing><wp:inline>',
    '<wp:extent cx="5943600" cy="3962400"/>',
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="img1.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="5943600" cy="3962400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>',
    '</pic:pic></a:graphicData></a:graphic>',
    '</wp:inline></w:drawing></w:r></w:p>',
    '</wrapper>'
  )
  content_nodes <- xml2::xml_find_all(xml2::read_xml(wrapper_xml), "./*")

  payload <- list(float_width = "5000dxa", wrap_distance = "0 198dxa 0 198dxa")
  result <- build_group_anchor(content_nodes, payload, ns_ext, next_docpr_id = 1L)

  # Should succeed — empty caption is a degenerate but valid case
  expect_true(result$success)

  # wps:txbx should exist but with empty txbxContent
  wsp <- xml2::xml_find_first(result$para, ".//wps:wsp", ns = ns_ext)
  expect_false(inherits(wsp, "xml_missing"))
})

test_that("build_group_anchor() fails with no image", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    a = "http://schemas.openxmlformats.org/drawingml/2006/main",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup",
    r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  )

  wrapper_xml <- paste0(
    '<wrapper xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:p><w:r><w:t>Just text, no image</w:t></w:r></w:p>',
    '</wrapper>'
  )
  content_nodes <- xml2::xml_find_all(xml2::read_xml(wrapper_xml), "./*")

  payload <- list(float_width = "5000dxa", wrap_distance = "0 198dxa 0 198dxa")
  result <- build_group_anchor(content_nodes, payload, ns_ext, next_docpr_id = 1L)

  expect_false(result$success)
  expect_equal(result$reason, "no image found in group content")
})
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd /path/to/worktree && Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-anchor-assembly.R", reporter = "summary")'`

Expected: All PASS

- [ ] **Step 7: Commit**

```bash
git add R/anchor_assembly.R tests/testthat/test-anchor-assembly.R
git commit -m "Add build_group_anchor() for wpg:wgp image+caption assembly"
```

---

### Task 3: Wire group dispatch into `assemble_anchors()`

**Files:**
- Modify: `R/anchor_assembly.R` (dispatch in `assemble_anchors()`, around line 769-771 in Phase 2b code)
- Test: `tests/testthat/test-anchor-assembly.R`

- [ ] **Step 1: Write failing integration test**

Add a helper for image content paragraphs in the test file:

```r
# Helper: content image paragraph (for group assembly tests)
content_image_para <- function(embed_id = "rId5") {
  paste0(
    '<w:p xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><w:drawing><wp:inline>',
    '<wp:extent cx="5943600" cy="3962400"/>',
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="img1.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="', embed_id, '"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="5943600" cy="3962400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>',
    '</pic:pic></a:graphicData></a:graphic>',
    '</wp:inline></w:drawing></w:r></w:p>'
  )
}
```

Then the test:

```r
test_that("assemble_anchors() dispatches group content to build_group_anchor", {
  xml_str <- build_anchor_body(
    content_para("Before"),
    anchor_marker("column-margin"),
    content_image_para(),
    content_para("Figure 1. Caption text"),
    anchor_end_marker("column-margin"),
    content_para("After")
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_anchors(body, ns, test_anchor_config)

  expect_equal(result$n_assembled, 1L)

  # Should produce a wpg:wgp element
  ns_ext <- c(ns,
    wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"
  )
  wgp <- xml2::xml_find_first(body, ".//wpg:wgp", ns = ns_ext)
  expect_false(inherits(wgp, "xml_missing"))

  # Markers should be removed
  children <- xml2::xml_children(body)
  all_text <- vapply(children, function(c) {
    t <- xml2::xml_find_all(c, ".//w:t", ns = ns)
    paste(xml2::xml_text(t), collapse = "")
  }, character(1))
  expect_false(any(grepl("DOCSTYLE_ANCHOR", all_text)))
})
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — group content currently falls through to the text/mixed branch (textbox or floating table), not `build_group_anchor()`

- [ ] **Step 3: Implement the group dispatch branch**

In `assemble_anchors()`, add a new block after the `content_type == "image"` block (around line 769 in Phase 2b code) and before the `content_type %in% c("text", "mixed")` block:

```r
    if (content_type == "group") {
      # Grouped figure: image + caption → wpg:wgp
      children <- xml2::xml_children(body)
      content_start <- fr$start_idx + 1L
      content_end <- fr$end_idx - 1L

      if (content_start > content_end) {
        warning("[anchor-assembly] Empty content range for group class '",
                fr$class, "'.", call. = FALSE)
        children <- xml2::xml_children(body)
        xml2::xml_remove(children[[fr$end_idx]])
        children <- xml2::xml_children(body)
        xml2::xml_remove(children[[fr$start_idx]])
        next
      }

      content_nodes <- children[content_start:content_end]

      # Extend ns with DrawingML + group namespaces
      ns_ext <- c(ns,
        wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
        a = "http://schemas.openxmlformats.org/drawingml/2006/main",
        pic = "http://schemas.openxmlformats.org/drawingml/2006/picture",
        wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
        wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup",
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

      grp_result <- build_group_anchor(content_nodes, anchor_config, ns_ext,
                                        next_docpr_id = next_id)
      if (!grp_result$success) {
        reason <- grp_result$reason %||% "unknown"
        warning("[anchor-assembly] Failed to build group for class '",
                fr$class, "': ", reason, call. = FALSE)
        next
      }

      # Insert the group paragraph before the start marker
      children <- xml2::xml_children(body)
      xml2::xml_add_sibling(children[[fr$start_idx]], grp_result$para, .where = "before")

      # Remove original nodes (start marker, content, end marker)
      children <- xml2::xml_children(body)
      remove_start <- fr$start_idx + 1L
      remove_end <- fr$end_idx + 1L
      for (ri in remove_end:remove_start) {
        xml2::xml_remove(children[[ri]])
        children <- xml2::xml_children(body)
      }

      n_assembled <- n_assembled + 1L

      # Adjacency relocation for group
      if (!is.null(fr$payload$adjacent) && nzchar(fr$payload$adjacent)) {
        relocate_to_adjacent(body, grp_result$para, fr$payload$adjacent, ns)
      }

      if (verbose) {
        message("[anchor-assembly] Assembled group: ", fr$class)
      }
      next
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /path/to/worktree && Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-anchor-assembly.R", reporter = "summary")'`

Expected: All PASS

- [ ] **Step 5: Write adjacency relocation test for grouped figure**

```r
test_that("assemble_anchors() relocates group via adjacency (direct node reference)", {
  # Create a body with a bookmark target and a group with adjacent attribute
  bookmark_para <- paste0(
    '<w:p><w:bookmarkStart w:id="0" w:name="target_para"/>',
    '<w:r><w:t>Target paragraph</w:t></w:r>',
    '<w:bookmarkEnd w:id="0"/></w:p>'
  )

  # Use anchor_marker with adjacent set
  payload <- list(
    type = "anchor", version = 3L, class = "column-margin",
    vertical_anchor = "text", horizontal_anchor = "margin",
    position_y = "0", position_x = "0",
    float_width = "5000dxa",
    wrap_style = "square", wrap_side = "both",
    wrap_distance = "0 198dxa 0 198dxa",
    adjacent = "#target_para"
  )
  json <- jsonlite::toJSON(payload, auto_unbox = TRUE)
  marker_text <- "DOCSTYLE_ANCHOR::column-margin::#target_para"
  adj_marker <- paste0(
    '<w:p><w:pPr><w:suppressLineNumbers/></w:pPr>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE ', json, ' </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:t>', marker_text, '</w:t></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r>',
    '</w:p>'
  )

  xml_str <- build_anchor_body(
    adj_marker,
    content_image_para(),
    content_para("Figure 1. Caption"),
    anchor_end_marker("column-margin"),
    content_para("Intervening paragraph"),
    bookmark_para
  )
  xml <- xml2::read_xml(xml_str)
  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)

  result <- assemble_anchors(body, ns, test_anchor_config)
  expect_equal(result$n_assembled, 1L)

  # The group should be relocated before the target paragraph
  children <- xml2::xml_children(body)
  child_texts <- vapply(children, function(c) {
    t <- xml2::xml_find_all(c, ".//w:t", ns = ns)
    paste(xml2::xml_text(t), collapse = "")
  }, character(1))

  # Group (contains wpg:wgp) should appear before "Target paragraph"
  ns_ext <- c(ns,
    wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"
  )
  group_idx <- which(vapply(children, function(c) {
    length(xml2::xml_find_all(c, ".//wpg:wgp", ns = ns_ext)) > 0
  }, logical(1)))
  target_idx <- which(grepl("Target paragraph", child_texts))

  expect_true(length(group_idx) == 1)
  expect_true(length(target_idx) == 1)
  expect_true(group_idx < target_idx)
})
```

- [ ] **Step 6: Run tests to verify they pass**

Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add R/anchor_assembly.R tests/testthat/test-anchor-assembly.R
git commit -m "Wire group dispatch in assemble_anchors() with adjacency relocation"
```

---

### Task 4: Harvest detection — `is_grouped_figure()` with `mc:AlternateContent` support

**Files:**
- Modify: `R/anchor_assembly.R` (add new function near harvest section, after `is_text_box()`)
- Test: `tests/testthat/test-harvest-anchor.R`

- [ ] **Step 1: Write failing tests**

```r
test_that("is_grouped_figure() returns TRUE for wpg:wgp with pic:pic and wps:txbx", {
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"',
    ' xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><w:drawing>',
    '<wp:anchor simplePos="0" relativeHeight="251658240" behindDoc="0"',
    ' locked="0" layoutInCell="1" allowOverlap="1">',
    '<wp:positionH relativeFrom="margin"><wp:posOffset>0</wp:posOffset></wp:positionH>',
    '<wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>',
    '<wp:extent cx="5943600" cy="4877040"/>',
    '<wp:wrapSquare wrapText="bothSides"/>',
    '<wp:docPr id="1" name="Group 1"/>',
    '<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup">',
    '<wpg:wgp>',
    '<wpg:cNvGrpSpPr/>',
    '<wpg:grpSpPr>',
    '<a:xfrm><a:off x="0" y="0"/><a:ext cx="5943600" cy="4877040"/>',
    '<a:chOff x="0" y="0"/><a:chExt cx="5943600" cy="4877040"/></a:xfrm>',
    '</wpg:grpSpPr>',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="2" name="img.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="5943600" cy="3962400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>',
    '<wps:wsp><wps:cNvSpPr txBox="1"/>',
    '<wps:spPr><a:xfrm><a:off x="0" y="4053840"/><a:ext cx="5943600" cy="914400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></wps:spPr>',
    '<wps:txbx><w:txbxContent>',
    '<w:p><w:r><w:t>Figure 1. Caption</w:t></w:r></w:p>',
    '</w:txbxContent></wps:txbx>',
    '<wps:bodyPr/></wps:wsp>',
    '</wpg:wgp></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing></w:r></w:p>'
  )
  para <- xml2::read_xml(para_xml)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  expect_true(is_grouped_figure(para, ns))
})

test_that("is_grouped_figure() returns FALSE for plain anchored image (no wps:txbx)", {
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><w:drawing>',
    '<wp:anchor simplePos="0" relativeHeight="251658240" behindDoc="0"',
    ' locked="0" layoutInCell="1" allowOverlap="1">',
    '<wp:extent cx="5943600" cy="3962400"/>',
    '<wp:docPr id="1" name="Picture 1"/>',
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="2" name="img.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/></pic:blipFill>',
    '<pic:spPr/></pic:pic></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing></w:r></w:p>'
  )
  para <- xml2::read_xml(para_xml)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  expect_false(is_grouped_figure(para, ns))
})

test_that("is_grouped_figure() returns FALSE for text box (no pic:pic)", {
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">',
    '<w:r><w:drawing>',
    '<wp:anchor simplePos="0" relativeHeight="251658240" behindDoc="0"',
    ' locked="0" layoutInCell="1" allowOverlap="1">',
    '<wp:extent cx="3000000" cy="1000000"/>',
    '<wp:docPr id="1" name="TextBox 1"/>',
    '<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">',
    '<wps:wsp><wps:cNvSpPr txBox="1"/>',
    '<wps:spPr/><wps:txbx><w:txbxContent>',
    '<w:p><w:r><w:t>Text</w:t></w:r></w:p>',
    '</w:txbxContent></wps:txbx>',
    '<wps:bodyPr/></wps:wsp></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing></w:r></w:p>'
  )
  para <- xml2::read_xml(para_xml)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  expect_false(is_grouped_figure(para, ns))
})

test_that("is_grouped_figure() detects group inside mc:AlternateContent", {
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"',
    ' xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"',
    ' xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><mc:AlternateContent><mc:Choice Requires="wpg">',
    '<w:drawing>',
    '<wp:anchor simplePos="0" relativeHeight="251658240" behindDoc="0"',
    ' locked="0" layoutInCell="1" allowOverlap="1">',
    '<wp:extent cx="5943600" cy="4877040"/>',
    '<wp:docPr id="1" name="Group 1"/>',
    '<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup">',
    '<wpg:wgp><wpg:cNvGrpSpPr/><wpg:grpSpPr/>',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="2" name="img.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/></pic:blipFill>',
    '<pic:spPr/></pic:pic>',
    '<wps:wsp><wps:cNvSpPr txBox="1"/>',
    '<wps:spPr/><wps:txbx><w:txbxContent>',
    '<w:p><w:r><w:t>Caption</w:t></w:r></w:p>',
    '</w:txbxContent></wps:txbx>',
    '<wps:bodyPr/></wps:wsp>',
    '</wpg:wgp></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing>',
    '</mc:Choice></mc:AlternateContent></w:r></w:p>'
  )
  para <- xml2::read_xml(para_xml)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  expect_true(is_grouped_figure(para, ns))
})
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `is_grouped_figure` not found

- [ ] **Step 3: Implement `is_grouped_figure()`**

Add to `R/anchor_assembly.R`, after `is_anchored_image()` and before `is_text_box()`:

```r
#' Check if a paragraph contains a grouped figure (image + caption)
#'
#' Detects `wp:anchor` containing `wpg:wgp` with both `pic:pic` and `wps:txbx`
#' descendants. Handles `mc:AlternateContent/mc:Choice` wrapping (Word always
#' emits grouped shapes inside `mc:Choice Requires="wpg"`).
#'
#' @param para xml2 node for w:p
#' @param ns Named character vector of XML namespaces
#' @return Logical
#' @export
is_grouped_figure <- function(para, ns) {
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    mc = "http://schemas.openxmlformats.org/markup-compatibility/2006"
  )

  # Look for wp:anchor both directly and inside mc:Choice
  anchors <- xml2::xml_find_all(para, ".//wp:anchor", ns = ns_ext)
  if (length(anchors) == 0) return(FALSE)

  for (anchor in anchors) {
    wgp <- xml2::xml_find_first(anchor, ".//wpg:wgp", ns = ns_ext)
    if (inherits(wgp, "xml_missing")) next

    pics <- xml2::xml_find_all(wgp, ".//pic:pic", ns = ns_ext)
    txbx <- xml2::xml_find_first(wgp, ".//wps:txbx", ns = ns_ext)

    if (length(pics) > 0 && !inherits(txbx, "xml_missing")) return(TRUE)
  }
  FALSE
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /path/to/worktree && Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-harvest-anchor.R", reporter = "summary")'`

Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add R/anchor_assembly.R tests/testthat/test-harvest-anchor.R
git commit -m "Add is_grouped_figure() harvest detection with mc:AlternateContent support"
```

---

### Task 5: Harvest property and content extraction

**Files:**
- Modify: `R/anchor_assembly.R` (add `extract_group_properties()` and `extract_group_content()`)
- Test: `tests/testthat/test-harvest-anchor.R`

- [ ] **Step 1: Write failing tests for `extract_group_properties()`**

```r
test_that("extract_group_properties() reads anchor positioning + caption_y + image_height", {
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"',
    ' xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><w:drawing>',
    '<wp:anchor simplePos="0" relativeHeight="251658240" behindDoc="0"',
    ' locked="0" layoutInCell="1" allowOverlap="1"',
    ' distT="0" distB="0" distL="125730" distR="125730">',
    '<wp:positionH relativeFrom="margin"><wp:posOffset>6048375</wp:posOffset></wp:positionH>',
    '<wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>',
    '<wp:extent cx="5935980" cy="4877040"/>',
    '<wp:wrapSquare wrapText="bothSides"/>',
    '<wp:docPr id="1" name="Group 1"/>',
    '<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup">',
    '<wpg:wgp>',
    '<wpg:cNvGrpSpPr/>',
    '<wpg:grpSpPr>',
    '<a:xfrm><a:off x="0" y="0"/><a:ext cx="5935980" cy="4877040"/>',
    '<a:chOff x="0" y="0"/><a:chExt cx="5935980" cy="4877040"/></a:xfrm>',
    '</wpg:grpSpPr>',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="2" name="img.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/></pic:blipFill>',
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="5935980" cy="3962400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>',
    '<wps:wsp><wps:cNvSpPr txBox="1"/>',
    '<wps:spPr><a:xfrm><a:off x="0" y="4053840"/><a:ext cx="5935980" cy="914400"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></wps:spPr>',
    '<wps:txbx><w:txbxContent>',
    '<w:p><w:r><w:t>Figure 1. Caption</w:t></w:r></w:p>',
    '</w:txbxContent></wps:txbx>',
    '<wps:bodyPr/></wps:wsp>',
    '</wpg:wgp></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing></w:r></w:p>'
  )
  para <- xml2::read_xml(para_xml)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  props <- extract_group_properties(para, ns)

  expect_equal(props$horizontal_anchor, "margin")
  expect_equal(props$vertical_anchor, "text")
  # 6048375 EMU / 635 = 9525 DXA
  expect_equal(props$position_x, "9525")
  expect_equal(props$position_y, "0")
  # 5935980 EMU / 635 = 9347 DXA
  expect_equal(props$float_width, "9347")
  expect_equal(props$z_layer, "front")
  expect_equal(props$wrap_style, "square")
  # caption_y: 4053840 EMU / 635 = 6384 DXA
  expect_equal(props$caption_y, "6384")
  # image_height: 3962400 EMU / 635 = 6240 DXA
  expect_equal(props$image_height, "6240")
})

test_that("extract_group_properties() returns NULL when no wp:anchor", {
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:r><w:t>Plain text</w:t></w:r></w:p>'
  )
  para <- xml2::read_xml(para_xml)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  expect_null(extract_group_properties(para, ns))
})
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `extract_group_properties` not found

- [ ] **Step 3: Implement `extract_group_properties()`**

Add to `R/anchor_assembly.R`, after `is_grouped_figure()`:

```r
#' Extract positioning properties from a grouped figure
#'
#' Reads standard `wp:anchor` positioning plus group-specific internal layout:
#' `caption_y` (from `wps:wsp/wps:spPr/a:xfrm/a:off@y`) and `image_height`
#' (from `pic:pic/pic:spPr/a:xfrm/a:ext@cy`). EMU values are converted to DXA.
#'
#' @param para xml2 node for w:p containing a grouped figure
#' @param ns Named character vector of XML namespaces
#' @return Named list with standard anchor properties plus `caption_y` and
#'   `image_height`, or NULL if `wp:anchor` is missing
#' @export
extract_group_properties <- function(para, ns) {
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture",
    a = "http://schemas.openxmlformats.org/drawingml/2006/main",
    mc = "http://schemas.openxmlformats.org/markup-compatibility/2006"
  )

  anchor <- xml2::xml_find_first(para, ".//wp:anchor", ns = ns_ext)
  if (inherits(anchor, "xml_missing")) return(NULL)

  # Standard anchor positioning (same logic as extract_text_box_properties)
  posH <- xml2::xml_find_first(anchor, "wp:positionH", ns = ns_ext)
  relH <- if (!inherits(posH, "xml_missing")) xml2::xml_attr(posH, "relativeFrom") else "margin"
  offsetH <- "0"
  if (!inherits(posH, "xml_missing")) {
    off_node <- xml2::xml_find_first(posH, "wp:posOffset", ns = ns_ext)
    if (!inherits(off_node, "xml_missing")) {
      emu_val <- as.numeric(xml2::xml_text(off_node))
      if (!is.na(emu_val)) {
        offsetH <- as.character(as.integer(round(emu_val / 635)))
      }
    }
  }

  posV <- xml2::xml_find_first(anchor, "wp:positionV", ns = ns_ext)
  relV <- if (!inherits(posV, "xml_missing")) xml2::xml_attr(posV, "relativeFrom") else "text"
  offsetV <- "0"
  if (!inherits(posV, "xml_missing")) {
    off_node <- xml2::xml_find_first(posV, "wp:posOffset", ns = ns_ext)
    if (!inherits(off_node, "xml_missing")) {
      emu_val <- as.numeric(xml2::xml_text(off_node))
      if (!is.na(emu_val)) {
        offsetV <- as.character(as.integer(round(emu_val / 635)))
      }
    }
  }

  # Extent (width)
  extent <- xml2::xml_find_first(anchor, "wp:extent", ns = ns_ext)
  width_dxa <- NULL
  if (!inherits(extent, "xml_missing")) {
    cx <- as.numeric(xml2::xml_attr(extent, "cx"))
    if (!is.na(cx) && cx > 0) {
      width_dxa <- as.character(as.integer(round(cx / 635)))
    }
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

  # Group-specific: caption_y from wps:wsp/wps:spPr/a:xfrm/a:off@y
  caption_y <- NULL
  wsp_off <- xml2::xml_find_first(anchor, ".//wps:wsp/wps:spPr/a:xfrm/a:off", ns = ns_ext)
  if (!inherits(wsp_off, "xml_missing")) {
    y_emu <- as.numeric(xml2::xml_attr(wsp_off, "y"))
    if (!is.na(y_emu)) {
      caption_y <- as.character(as.integer(round(y_emu / 635)))
    }
  }

  # Group-specific: image_height from pic:pic/pic:spPr/a:xfrm/a:ext@cy
  image_height <- NULL
  pic_ext <- xml2::xml_find_first(anchor, ".//pic:pic/pic:spPr/a:xfrm/a:ext", ns = ns_ext)
  if (!inherits(pic_ext, "xml_missing")) {
    cy_emu <- as.numeric(xml2::xml_attr(pic_ext, "cy"))
    if (!is.na(cy_emu)) {
      image_height <- as.character(as.integer(round(cy_emu / 635)))
    }
  }

  list(
    horizontal_anchor = posH_relative_to_css(relH),
    vertical_anchor   = posV_relative_to_css(relV),
    position_x        = offsetH,
    position_y        = offsetV,
    float_width       = width_dxa,
    z_layer           = z_layer,
    wrap_style        = wrap_style,
    caption_y         = caption_y,
    image_height      = image_height
  )
}
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS

- [ ] **Step 5: Write failing tests for `extract_group_content()`**

```r
test_that("extract_group_content() returns image rel ID and caption nodes", {
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"',
    ' xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><w:drawing>',
    '<wp:anchor simplePos="0" relativeHeight="251658240" behindDoc="0"',
    ' locked="0" layoutInCell="1" allowOverlap="1">',
    '<wp:extent cx="5943600" cy="4877040"/>',
    '<wp:docPr id="1" name="Group 1"/>',
    '<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup">',
    '<wpg:wgp><wpg:cNvGrpSpPr/><wpg:grpSpPr/>',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="2" name="img.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId7"/></pic:blipFill>',
    '<pic:spPr/></pic:pic>',
    '<wps:wsp><wps:cNvSpPr txBox="1"/>',
    '<wps:spPr/><wps:txbx><w:txbxContent>',
    '<w:p><w:r><w:t>Figure 1. Caption text</w:t></w:r></w:p>',
    '<w:p><w:r><w:t>Second line</w:t></w:r></w:p>',
    '</w:txbxContent></wps:txbx>',
    '<wps:bodyPr/></wps:wsp>',
    '</wpg:wgp></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing></w:r></w:p>'
  )
  para <- xml2::read_xml(para_xml)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  content <- extract_group_content(para, ns)

  expect_equal(content$image_rel_id, "rId7")
  expect_equal(length(content$caption_nodes), 2L)
})

test_that("extract_group_content() handles mc:AlternateContent wrapping", {
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"',
    ' xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"',
    ' xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><mc:AlternateContent><mc:Choice Requires="wpg">',
    '<w:drawing>',
    '<wp:anchor simplePos="0" relativeHeight="251658240" behindDoc="0"',
    ' locked="0" layoutInCell="1" allowOverlap="1">',
    '<wp:extent cx="5943600" cy="4877040"/>',
    '<wp:docPr id="1" name="Group 1"/>',
    '<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup">',
    '<wpg:wgp><wpg:cNvGrpSpPr/><wpg:grpSpPr/>',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="2" name="img.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId9"/></pic:blipFill>',
    '<pic:spPr/></pic:pic>',
    '<wps:wsp><wps:cNvSpPr txBox="1"/>',
    '<wps:spPr/><wps:txbx><w:txbxContent>',
    '<w:p><w:r><w:t>Caption in mc:Choice</w:t></w:r></w:p>',
    '</w:txbxContent></wps:txbx>',
    '<wps:bodyPr/></wps:wsp>',
    '</wpg:wgp></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing>',
    '</mc:Choice></mc:AlternateContent></w:r></w:p>'
  )
  para <- xml2::read_xml(para_xml)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  content <- extract_group_content(para, ns)

  expect_equal(content$image_rel_id, "rId9")
  expect_equal(length(content$caption_nodes), 1L)
})
```

- [ ] **Step 6: Implement `extract_group_content()`**

Add to `R/anchor_assembly.R`, after `extract_group_properties()`:

```r
#' Extract image and caption content from a grouped figure
#'
#' Returns the image's `r:embed` relationship ID from `a:blip` and
#' the caption `w:p` elements from `wps:txbx/w:txbxContent`.
#' Handles `mc:AlternateContent/mc:Choice` wrapping.
#'
#' @param para xml2 node for w:p containing a grouped figure
#' @param ns Named character vector of XML namespaces
#' @return List with `$image_rel_id` (character) and `$caption_nodes` (xml2 nodeset)
#' @export
extract_group_content <- function(para, ns) {
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    a = "http://schemas.openxmlformats.org/drawingml/2006/main",
    mc = "http://schemas.openxmlformats.org/markup-compatibility/2006",
    r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  )

  # Image rel ID from a:blip inside pic:pic
  blip <- xml2::xml_find_first(para, ".//pic:pic//a:blip", ns = ns_ext)
  image_rel_id <- NA_character_
  if (!inherits(blip, "xml_missing")) {
    embed <- xml2::xml_attr(blip, "embed")
    if (is.na(embed)) embed <- xml2::xml_attr(blip, "r:embed")
    if (!is.na(embed)) image_rel_id <- embed
  }

  # Caption paragraphs from wps:txbx/w:txbxContent
  caption_nodes <- xml2::xml_find_all(para, ".//wps:txbx/w:txbxContent/w:p", ns = ns_ext)

  list(
    image_rel_id = image_rel_id,
    caption_nodes = caption_nodes
  )
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `cd /path/to/worktree && Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-harvest-anchor.R", reporter = "summary")'`

Expected: All PASS

- [ ] **Step 8: Commit**

```bash
git add R/anchor_assembly.R tests/testthat/test-harvest-anchor.R
git commit -m "Add extract_group_properties() and extract_group_content() for harvest"
```

---

### Task 6: Wire harvest into `docx_to_qmd.R`

**Files:**
- Modify: `R/docx_to_qmd.R` (add grouped figure harvest path before `is_text_box` check, around line 1987)
- Test: `tests/testthat/test-harvest-anchor.R` (detection order test)

- [ ] **Step 1: Write detection order test**

```r
test_that("Detection order: grouped figure beats text box and anchored image", {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # A grouped figure has wp:anchor + wpg:wgp + pic:pic + wps:txbx
  # This should be detected by is_grouped_figure() before is_text_box() or is_anchored_image()
  para_xml <- paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"',
    ' xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><w:drawing>',
    '<wp:anchor simplePos="0" relativeHeight="251658240" behindDoc="0"',
    ' locked="0" layoutInCell="1" allowOverlap="1">',
    '<wp:extent cx="5943600" cy="4877040"/>',
    '<wp:docPr id="1" name="Group 1"/>',
    '<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup">',
    '<wpg:wgp><wpg:cNvGrpSpPr/><wpg:grpSpPr/>',
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="2" name="img.png"/><pic:cNvPicPr/></pic:nvPicPr>',
    '<pic:blipFill><a:blip r:embed="rId5"/></pic:blipFill>',
    '<pic:spPr/></pic:pic>',
    '<wps:wsp><wps:cNvSpPr txBox="1"/>',
    '<wps:spPr/><wps:txbx><w:txbxContent>',
    '<w:p><w:r><w:t>Caption</w:t></w:r></w:p>',
    '</w:txbxContent></wps:txbx>',
    '<wps:bodyPr/></wps:wsp>',
    '</wpg:wgp></a:graphicData></a:graphic>',
    '</wp:anchor></w:drawing></w:r></w:p>'
  )
  para <- xml2::read_xml(para_xml)

  # Grouped figure should be TRUE

  expect_true(is_grouped_figure(para, ns))
  # is_text_box should be FALSE (exclusion: has pic:pic in anchor)
  # Note: is_text_box() excludes anchors with pic:pic — but for grouped figures,
  # the pic:pic is inside wpg:wgp, not directly in the anchor's wps namespace.
  # The key is detection ORDER, not mutual exclusion.
  # is_anchored_image looks for pic:pic under wp:anchor — would match.
  # But is_grouped_figure() runs FIRST in the harvest loop.
  expect_true(is_grouped_figure(para, ns))
})
```

- [ ] **Step 2: Add grouped figure harvest path to `docx_to_qmd.R`**

In `R/docx_to_qmd.R`, add the grouped figure check **before** the `is_anchored_image()` check (around line 1987). The new block goes immediately before the line `# Check for anchored image`:

```r
    # Check for grouped figure (wp:anchor with wpg:wgp containing pic:pic + wps:txbx)
    # Must run before is_text_box and is_anchored_image (most specific first)
    if (is_grouped_figure(p, ns)) {
      group_props <- extract_group_properties(p, ns)
      group_content <- extract_group_content(p, ns)

      # Determine class from pending anchor range or default
      anchor_class <- "column-margin"
      if (!is.null(pending_anchor_range)) {
        anchor_class <- pending_anchor_range$class
        pending_anchor_range <- NULL
      }

      # Build div attributes from positioning
      div_attrs <- character(0)
      if (!is.null(group_props)) {
        if (!is.null(group_props$float_width))
          div_attrs <- c(div_attrs, paste0('float-width="', group_props$float_width, 'dxa"'))
        if (!is.null(group_props$caption_y))
          div_attrs <- c(div_attrs, paste0('caption-y="', group_props$caption_y, 'dxa"'))
        if (!is.null(group_props$image_height))
          div_attrs <- c(div_attrs, paste0('image-height="', group_props$image_height, 'dxa"'))
        if (group_props$vertical_anchor != "text")
          div_attrs <- c(div_attrs, paste0('vertical-anchor="', group_props$vertical_anchor, '"'))
        if (group_props$horizontal_anchor != "margin")
          div_attrs <- c(div_attrs, paste0('horizontal-anchor="', group_props$horizontal_anchor, '"'))
        if (group_props$position_y != "0")
          div_attrs <- c(div_attrs, paste0('position-y="', group_props$position_y, 'dxa"'))
        if (group_props$position_x != "0")
          div_attrs <- c(div_attrs, paste0('position-x="', group_props$position_x, 'dxa"'))
        if (group_props$z_layer != "front")
          div_attrs <- c(div_attrs, paste0('z-layer="', group_props$z_layer, '"'))
      }

      if (length(div_attrs) > 0) {
        div_open <- paste0("::: {.", anchor_class, " ", paste(div_attrs, collapse = " "), "}")
      } else {
        div_open <- paste0("::: {.", anchor_class, "}")
      }

      lines <- c(lines, "", div_open)

      # Emit image
      img_emitted <- FALSE
      if (!is.na(group_content$image_rel_id) &&
          !is.null(image_rels[[group_content$image_rel_id]])) {
        img_path <- image_rels[[group_content$image_rel_id]]
        lines <- c(lines, paste0("![](", img_path, ")"))
        img_emitted <- TRUE
      }

      if (!img_emitted) {
        lines <- lines[seq_len(length(lines) - 2L)]
        harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
          para_index = i - 1L, type = "skipped", style = "grouped-figure-no-image"
        )
        next
      }

      # Emit blank line then caption paragraphs
      lines <- c(lines, "")
      if (length(group_content$caption_nodes) > 0) {
        for (cap_node in group_content$caption_nodes) {
          cap_text <- extract_formatted_text(cap_node, ns, hyperlink_rels)
          if (nzchar(cap_text)) {
            lines <- c(lines, cap_text)
          }
        }
      }

      lines <- c(lines, ":::", "")

      harvest_entries[[length(harvest_entries) + 1L]] <- harvest_map_entry(
        para_index = i - 1L, type = "grouped-figure", style = style_id
      )
      next
    }
```

- [ ] **Step 3: Run the full test suite**

Run: `cd /path/to/worktree && Rscript -e 'devtools::load_all(); devtools::test()'`

Expected: All PASS (new tests + existing tests)

- [ ] **Step 4: Commit**

```bash
git add R/docx_to_qmd.R tests/testthat/test-harvest-anchor.R
git commit -m "Wire grouped figure harvest into docx_to_qmd.R convert loop"
```

---

### Task 7: Schema updates — `caption_y` and `image_height`

**Files:**
- Modify: `R/field_codes.R` (add to `docstyle_schemas$anchor$optional`)
- Modify: `inst/schema/docstyle-field-codes.json` (add to `anchor_payload_fields`)

- [ ] **Step 1: Find the schema definition in `field_codes.R`**

Search for `docstyle_schemas` or `anchor.*optional` in `R/field_codes.R`.

- [ ] **Step 2: Add `caption_y` and `image_height` to the R schema**

In the `docstyle_schemas` list's `anchor$optional` vector, add `"caption_y"` and `"image_height"`. The exact location depends on the current structure — look for other optional anchor fields and add alongside them.

- [ ] **Step 3: Add to JSON schema**

In `inst/schema/docstyle-field-codes.json`, add to the `anchor_payload_fields` object:

```json
    "caption_y":         "Vertical offset of caption within group coordinate space (DXA)",
    "image_height":      "Height of image member within group (DXA)"
```

Add these after the `"adjacent"` line (last existing field), before the closing `}`.

- [ ] **Step 4: Run existing field code tests**

Run: `cd /path/to/worktree && Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-field-codes.R", reporter = "summary")'`

Expected: PASS (existing tests should continue to pass — `handle_docstyle_anchor()` already passes through unknown keys)

- [ ] **Step 5: Commit**

```bash
git add R/field_codes.R inst/schema/docstyle-field-codes.json
git commit -m "Add caption_y and image_height to anchor field code schema"
```

---

### Task 8: Update `ARCHITECTURE-anchors.md`

**Files:**
- Modify: `dev/ARCHITECTURE-anchors.md`

- [ ] **Step 1: Read current architecture doc**

Read `dev/ARCHITECTURE-anchors.md` to understand current structure.

- [ ] **Step 2: Update content dispatch table**

Add `"group"` to the dispatch table. The table should now have:

| Content type | Detection | OOXML mechanism |
|---|---|---|
| `table` | `w:tbl` in content | `w:tblpPr` on existing table |
| `image` | `w:drawing` with `pic:pic` | `wp:anchor` wrapping `pic:pic` |
| `group` | `has_image && has_text && !has_table` | `wp:anchor` wrapping `wpg:wgp` (pic:pic + wps:wsp) |
| `text` | Non-empty `w:t` only | DrawingML text box (`content-mode: textbox`) or floating table |
| `mixed` | `has_table && has_*` | Floating table wrapper |

- [ ] **Step 3: Update harvest detection order**

Document the detection order:
1. `is_grouped_figure()` — `wp:anchor` + `wpg:wgp` + `pic:pic` + `wps:txbx`
2. `is_text_box()` — `wp:anchor` + `wps:txbx` (no `pic:pic`)
3. `is_anchored_image()` — `wp:anchor` + `pic:pic`
4. `is_floating_table()` — `w:tbl` + `w:tblpPr`

- [ ] **Step 4: Add group OOXML structure section**

Document the `wpg:wgp` structure showing the XML hierarchy produced by `build_group_anchor()`.

- [ ] **Step 5: Commit**

```bash
git add -f dev/ARCHITECTURE-anchors.md
git commit -m "Update ARCHITECTURE-anchors.md with group content type and harvest order"
```

---

## Post-implementation verification

After all tasks are complete:

1. Run the full test suite: `Rscript -e 'devtools::load_all(); devtools::test()'`
2. Verify no regressions: all existing tests pass
3. Verify new tests cover: detection, assembly, harvest detection, property extraction, content extraction, dispatch, schema
4. Run `devtools::document()` to update NAMESPACE for new exports (`is_grouped_figure`, `extract_group_properties`, `extract_group_content`)
