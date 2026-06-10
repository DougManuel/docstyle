# Anchor positioning Phase 2b: text anchors, text boxes, and explicit adjacency

## Goal

Complete the anchor positioning subsystem by adding text/mixed content assembly (two mechanisms), explicit adjacency targeting via bookmark lookup, and harvest round-trip for all new paths.

## Context

Phase 2a (PR #120, merged) established the unified anchor model:
- Renamed float → anchor throughout
- Content-aware dispatch in `assemble_anchors()` (table → `w:tblpPr`, image → `wp:anchor`)
- CSS-first pipeline: `extract_anchor_styles()` → `page-config.json` → Lua → R post-render
- Harvest round-trip for floating tables and anchored images
- `adjacent` attribute captured by Lua and stored in payload, but not acted on

Phase 2b fills the remaining gaps: text/mixed content (currently skipped with "Phase 2b" message), DrawingML text boxes, and explicit adjacency relocation.

## Scope

Three features, prioritised:

1. **Text anchor assembly via floating table** (priority — needed for microorganism template)
2. **Text anchor assembly via DrawingML text box** (opt-in, more common long-term use case)
3. **Explicit adjacency** (#117 — relocate any anchor type to a target bookmark)

Plus harvest round-trip for all new paths.

## Related issues

- #112 — Support text boxes (`w:drawing/wps:txbx`)
- #117 — Explicit adjacency for floating elements

---

## Feature 1: Text/mixed content via floating table

### Behaviour

When `detect_anchor_content()` returns `"text"` or `"mixed"` and `content_mode` is `"auto"` (default), assembly reuses the existing `build_table_anchor_xml()` infrastructure. Content paragraphs between markers are moved into the invisible floating table's single cell. No new OOXML mechanism needed.

### QMD authoring

```qmd
This paragraph discusses methodology.

::: {.column-margin}
A margin note about the methods.
:::
```

### Assembly dispatch

Remove the "Phase 2b" skip in `assemble_anchors()`. For text/mixed content with `content_mode != "textbox"`, call `build_table_anchor_xml()` and move content paragraphs into the cell — same path as table content.

### Harvest

No new harvest code needed. Floating tables with text content are already detected by `is_floating_table()` and the cell content is converted to markdown by the existing paragraph-level harvest loop.

---

## Feature 2: DrawingML text boxes (opt-in)

### Behaviour

When `content_mode` is `"textbox"` (via CSS or div attribute), text/mixed content is wrapped in a DrawingML text box instead of a floating table. This produces better results for styled text containers with wrap styles.

### CSS property

```css
.sidebar-note {
  --docstyle-content-mode: textbox;
  --docstyle-vertical-anchor: text;
  --docstyle-horizontal-anchor: margin;
  --docstyle-float-width: 2in;
}
```

Div attribute override: `::: {.column-margin content-mode="textbox"}`.

### OOXML structure

```xml
w:p  (anchor paragraph)
  w:r
    w:drawing
      wp:anchor distT="..." distB="..." distL="..." distR="..."
                simplePos="0" behindDoc="0" locked="0"
                layoutInCell="1" allowOverlap="1"
        wp:simplePos x="0" y="0"/>
        wp:positionH relativeFrom="..."
          wp:posOffset>...</wp:posOffset>
        wp:positionV relativeFrom="..."
          wp:posOffset>...</wp:posOffset>
        wp:extent cx="..." cy="..."/>
        wp:effectExtent l="0" t="0" r="0" b="0"/>
        wp:wrapSquare wrapText="bothSides" .../>  (or wrapNone, wrapTopAndBottom)
        wp:docPr id="..." name="TextBox ..."/>
        wp:cNvGraphicFramePr/>
        a:graphic
          a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
            wps:wsp
              wps:cNvSpPr txBox="1"/>
              wps:spPr
                a:xfrm
                  a:off x="0" y="0"/>
                  a:ext cx="..." cy="..."/>
                a:prstGeom prst="rect"/>
                a:noFill/>       (transparent background)
                a:ln>
                  a:noFill/>     (no border by default)
                a:ln>
              wps:txbx
                w:txbxContent
                  w:p ...        (content paragraphs moved here)
              wps:bodyPr rot="0" spcFirstLastPara="0" vertOverflow="overflow"
                         horzOverflow="overflow" wrap="square"
                         lIns="91440" tIns="45720" rIns="91440" bIns="45720"
                         anchor="t" anchorCtr="0"/>
```

### New function: `build_text_box_anchor()`

Sibling to `build_image_anchor()`. Takes content paragraphs and positioning config:

1. Build `wps:wsp` with `wps:txbx/w:txbxContent` containing the content paragraphs
2. Wrap in `a:graphic/a:graphicData`
3. Wrap in `wp:anchor` with positioning (same as image anchors: positionH, positionV, wrap, z-layer)
4. Create `w:drawing > wp:anchor` structure
5. Insert into a `w:r` inside a new dedicated `w:p` (consistent with adjacency relocation — never inject into existing content paragraphs)

Height calculation: use a generous default (e.g., 9144000 EMU = 10 inches) as the initial `cy` extent. Word auto-sizes the text box to fit content when `wps:bodyPr wrap="square"` is set, so the initial height is a maximum bound, not a fixed size.

### Dispatch update in `assemble_anchors()`

```
content_type in ("text", "mixed"):
  if content_mode == "textbox":
    build_text_box_anchor(content_paragraphs, anchor_config, ns)
  else:
    build_table_anchor_xml()  # existing path
```

### Schema

Add `content_mode` to `anchor_payload_fields` in `inst/schema/docstyle-field-codes.json`:

```json
"content_mode": "Assembly mechanism: auto | textbox (default auto)"
```

No schema version bump — additive optional field within v3.

### CSS pipeline

`extract_anchor_styles()` in `css_parser.R` reads `--docstyle-content-mode` and includes it in the anchor_styles dict. `anchor.lua` includes `content_mode` in the JSON payload. `assemble_anchors()` reads `payload$content_mode` for dispatch.

---

## Feature 3: Explicit adjacency

### Behaviour

`adjacent="#id"` on a div targets a specific paragraph by bookmark ID instead of using source-proximity positioning. Works with all content types (table, image, text, text box).

### QMD authoring

Source proximity (default — no change):
```qmd
This paragraph discusses methodology.

::: {.column-margin}
A margin note next to the paragraph above.
:::
```

Explicit targeting:
```qmd
## Methods {#methods}

This paragraph discusses our methodology.

## Results

More content here...

::: {.column-margin adjacent="#methods"}
This margin note appears next to the Methods heading.
:::
```

### OOXML relocation mechanics

Adjacency requires physically moving the assembled content in the Word XML tree. The strategy depends on the OOXML mechanism:

**Floating tables** (`w:tblpPr` — tables and default text):
- OOXML rule: a floating table anchors to the **next sibling `w:p`** after the `w:tbl` in `w:body`
- Relocation: insert the `w:tbl` immediately **before** the target paragraph

**DrawingML** (`wp:anchor` — images and text boxes):
- OOXML rule: `wp:anchor` anchors to its **parent `w:p`**
- Relocation: create a dedicated empty `w:p` containing only the `w:r > w:drawing`, insert before the target paragraph
- Do not inject the drawing into the target paragraph itself (would alter its visible content)

### Bookmark lookup

New helper: `find_bookmark_paragraph(body, bookmark_id, ns)`

1. Strip `#` prefix from the ID
2. Scan all `w:bookmarkStart` elements in `w:body` for `w:name` matching the ID
3. Quarto emits heading IDs as `_docstyle_{id}` bookmarks — check both bare and prefixed forms
4. Return the `w:p` containing the bookmark, or `NULL` if not found

### Fallback

If the bookmark is not found:
- Emit `warning("[anchor-assembly] Bookmark '{id}' not found, using source position")`
- Fall through to default source-proximity positioning (do not skip the anchor)

### Lua changes

`anchor.lua` already captures `adjacent` from div attributes and includes it in the payload. No Lua changes needed.

### Assembly changes

After building the anchor content (table, image, or text box) and before inserting it, check `payload$adjacent`:

1. If set, call `find_bookmark_paragraph()` to locate the target
2. If found, relocate the assembled content to the target position
3. If not found, fall back to source position with warning

---

## Harvest round-trip

### Floating table with text content

Already handled by existing harvest infrastructure. `is_floating_table()` detects `w:tblpPr`, cell content is recursively converted to markdown. No changes needed.

### Text boxes

New detection and extraction functions:

- **`is_text_box(node, ns)`**: Checks for `w:drawing/wp:anchor` containing `wps:txbx` inside a paragraph
- **`extract_text_box_properties(node, ns)`**: Reads `wp:anchor` positioning (same fields as `extract_anchor_image_properties()`) plus identifies text box via `wps:cNvSpPr[@txBox='1']`
- **`extract_text_box_content(node, ns)`**: Returns `w:p` elements inside `wps:txbx/w:txbxContent` for recursive markdown conversion

Harvest loop addition (before general paragraph handler):
```
if is_text_box(p, ns):
    props <- extract_text_box_properties(p, ns)
    content_paras <- extract_text_box_content(p, ns)
    emit div_open with .class and content-mode="textbox"
    for each content_para: convert to markdown
    emit div_close
    next
```

### Adjacency

Phase 2b preserves `adjacent` via field code payload round-trip only. If the source QMD had `adjacent="#methods"`, the ADDIN DOCSTYLE field code stores it, and harvest reads it back to emit `adjacent="#methods"` on the div.

Spatial inference (detecting that a float was relocated from its source position) is deferred to a future phase.

---

## Typst considerations

No changes needed for the Typst output path:

- `anchor.lua` returns `nil` for non-OOXML formats — Quarto Marginalia handles `.column-margin` natively in Typst
- The QMD syntax (`::: {.column-margin}`, `::: {.column-margin content-mode="textbox"}`) is compatible with both output formats
- Typst has no adjacency concept (source-order only via `place()`); `adjacent` attribute is Word-specific
- Harvest operates only on Word documents

---

## Files changed

| File | Change |
|------|--------|
| `R/anchor_assembly.R` | Remove "Phase 2b" skip; add `build_text_box_anchor()`; add `find_bookmark_paragraph()`; add adjacency relocation logic |
| `R/css_parser.R` | `extract_anchor_styles()` reads `--docstyle-content-mode` |
| `R/docx_to_qmd.R` | Add `is_text_box()`, `extract_text_box_properties()`, `extract_text_box_content()`; text box harvest path |
| `R/field_codes.R` | `handle_docstyle_anchor()` includes `content_mode` in div attributes |
| `_extensions/docstyle/anchor.lua` | Include `content_mode` in JSON payload (minor) |
| `inst/schema/docstyle-field-codes.json` | Add `content_mode` to `anchor_payload_fields` |
| `dev/ARCHITECTURE-anchors.md` | Update with text box mechanism, adjacency mechanics |
| `CLAUDE.md` | Update anchor assembly description |
| `tests/testthat/test-anchor-assembly.R` | Text assembly, text box assembly, adjacency tests |
| `tests/testthat/test-harvest-anchor.R` | Text box harvest, adjacency round-trip tests |
| `tests/testthat/test-css-anchor.R` | `content_mode` extraction test |

---

## Success criteria

1. `::: {.column-margin}` with text content renders as a positioned floating table in Word
2. `::: {.column-margin content-mode="textbox"}` renders as a DrawingML text box
3. `adjacent="#id"` relocates any anchor type to the target bookmark paragraph
4. Missing bookmark falls back to source position with warning (no silent failure)
5. All new paths harvest back to correct QMD (round-trip fidelity)
6. Existing table and image anchor tests continue to pass (no regressions)
7. Typst output unaffected
