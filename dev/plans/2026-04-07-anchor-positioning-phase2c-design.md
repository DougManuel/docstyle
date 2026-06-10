# Anchor positioning Phase 2c: grouped image+caption figures

## Goal

Add grouped figure assembly and harvest for anchor positioning. A positioned div containing an image and caption text produces a Word Group Shape (`wpg:wgp`) instead of an invisible floating table, with pixel-accurate round-trip fidelity.

## Context

Phase 2a (PR #120) established the unified anchor model with content-aware dispatch. Phase 2b (PR #121) added text/mixed content via floating tables, DrawingML text boxes, and explicit adjacency. Both phases handle single-type content well, but the `"mixed"` content type (image + text) falls through to an invisible floating table — a workaround, not a proper representation.

The PHES-ODM-v3 Microorganisms document contains 10 grouped figures using `wpg:wgp`, each with a `pic:pic` (image) and `wps:wsp` (caption text box) as sibling children. These need to round-trip through harvest and re-render.

## Related issues

- #116 — Umbrella: unified float positioning model
- #112 — Text boxes (completed in Phase 2b)
- #117 — Explicit adjacency (completed in Phase 2b)

## Scope

- Detect image+text content as `"group"` (new content type)
- Assemble `wpg:wgp` with `pic:pic` and `wps:wsp` children inside `wp:anchor`
- Harvest grouped figures from Word, including inside `mc:AlternateContent` wrappers
- Pixel-accurate round-trip via div attributes for internal layout
- Single image + caption only (no multi-image groups or nested `wpg:grpSp`)

## Not in scope

- `mc:AlternateContent` output wrapping (modern Word reads `wpg:wgp` directly)
- Nested groups (`wpg:grpSp`)
- Multi-image groups (multiple `pic:pic` in one group)
- Typst grouped figure output

---

## Feature 1: Content detection

### Behaviour

`detect_anchor_content()` gains a new return value `"group"`. When content nodes contain at least one image paragraph (`w:drawing` with `pic:pic`) and at least one text paragraph (non-empty `w:t` outside drawings), the function returns `"group"` instead of `"mixed"`.

This narrows `"mixed"` to cases without a clear semantic mapping (e.g., table + text, table + image). In practice, the only `"mixed"` pattern encountered is image+caption, which now becomes `"group"`. Existing tests that assert `"mixed"` for image+text content will need updating to expect `"group"`.

### Dispatch

In `assemble_anchors()`, the new branch sits between the image path and the text/mixed path:

```r
if (content_type == "group") {
  # → build_group_anchor()
}
```

No changes to the existing image, text, textbox, or floating table paths.

## Feature 2: Group assembly

### `build_group_anchor()`

Constructs a `wpg:wgp` inside `wp:anchor` via `sprintf`, following the same pattern as `build_text_box_anchor()`.

**Input processing:**
1. Separates content nodes into image paragraphs (contain `w:drawing` with `pic:pic`) and caption paragraphs (everything else)
2. Extracts the `pic:pic` element from inside the first image paragraph's `w:drawing/wp:inline` wrapper. The `pic:pic` is detached from `wp:inline` and re-embedded directly as a child of `wpg:wgp`. The `a:blip@r:embed` relationship ID is preserved (same document, same relationships file).
3. Serialises caption paragraphs to XML strings for embedding in `wps:txbx/w:txbxContent`

**OOXML structure produced:**

```xml
<w:p>
  <w:r>
    <w:drawing>
      <wp:anchor distT="..." distB="..." distL="..." distR="..."
                 simplePos="0" relativeHeight="251658240"
                 behindDoc="0" locked="0" layoutInCell="1" allowOverlap="1">
        <wp:simplePos x="0" y="0"/>
        <wp:positionH relativeFrom="..."><wp:posOffset>...</wp:posOffset></wp:positionH>
        <wp:positionV relativeFrom="..."><wp:posOffset>...</wp:posOffset></wp:positionV>
        <wp:extent cx="..." cy="..."/>
        <wp:effectExtent l="0" t="0" r="0" b="0"/>
        <wp:wrapSquare wrapText="bothSides"/>
        <wp:docPr id="..." name="Group ..."/>
        <wp:cNvGraphicFramePr/>
        <a:graphic>
          <a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup">
            <wpg:wgp>
              <wpg:cNvGrpSpPr/>
              <wpg:grpSpPr>
                <a:xfrm>
                  <a:off x="0" y="0"/>
                  <a:ext cx="..." cy="..."/>
                  <a:chOff x="0" y="0"/>
                  <a:chExt cx="..." cy="..."/>
                </a:xfrm>
              </wpg:grpSpPr>
              <pic:pic>
                <!-- image element with a:blip r:embed preserved -->
                <pic:nvPicPr>...</pic:nvPicPr>
                <pic:blipFill>
                  <a:blip r:embed="..."/>
                  <a:stretch><a:fillRect/></a:stretch>
                </pic:blipFill>
                <pic:spPr>
                  <a:xfrm>
                    <a:off x="0" y="0"/>
                    <a:ext cx="..." cy="..."/>
                  </a:xfrm>
                  <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
                </pic:spPr>
              </pic:pic>
              <wps:wsp>
                <wps:cNvSpPr txBox="1"/>
                <wps:spPr>
                  <a:xfrm>
                    <a:off x="0" y="..."/>  <!-- caption-y offset -->
                    <a:ext cx="..." cy="..."/>
                  </a:xfrm>
                  <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
                  <a:noFill/>
                  <a:ln><a:noFill/></a:ln>
                </wps:spPr>
                <wps:txbx>
                  <w:txbxContent>
                    <!-- caption w:p paragraphs -->
                  </w:txbxContent>
                </wps:txbx>
                <wps:bodyPr rot="0" wrap="square"
                            lIns="91440" tIns="45720" rIns="91440" bIns="45720"
                            anchor="t" anchorCtr="0"/>
              </wps:wsp>
            </wpg:wgp>
          </a:graphicData>
        </a:graphic>
      </wp:anchor>
    </w:drawing>
  </w:r>
</w:p>
```

**Positioning from payload** (same as other builders):
- `vertical_anchor`, `horizontal_anchor`, `position_x`, `position_y` — `wp:anchor` positioning
- `float_width` — overall group width (`wp:extent@cx` and `wpg:grpSpPr` extents)
- `wrap_style`, `z_layer` — wrap element and `behindDoc` attribute

**Group-specific attributes from payload:**
- `caption_y` — vertical offset of the caption `wps:wsp` within the group coordinate space (stored as DXA in div attributes, converted to EMU for OOXML)
- `image_height` — height of the `pic:pic` member (DXA → EMU). Together with `caption_y`, defines the group's total height.

**Defaults for new authoring** (when `caption_y` and `image_height` are absent):
- `image_height`: computed from `float_width` assuming 4:3 aspect ratio, or 3 inches (2743200 EMU) as fallback
- `caption_y`: `image_height` + small gap (91440 EMU = 0.1 inch)
- Caption text box height: 914400 EMU (1 inch) as generous default — Word auto-sizes
- Group total height (`wpg:grpSpPr` `a:ext@cy` and `a:chExt@cy`): `caption_y` + caption text box height

**Return value:** `list(success, para, docpr_id, reason)` — same interface as `build_text_box_anchor()`.

**Error handling:**
- No image paragraph found → `list(success = FALSE, reason = "no image found in group content")`
- `pic:pic` extraction fails → `list(success = FALSE, reason = "could not extract pic:pic from image paragraph")`
- XML parse failure → includes `conditionMessage()` in the reason string (lesson from Phase 2b review)

### Integration into `assemble_anchors()`

The group branch in the main dispatch:
1. Calls `build_group_anchor(content_nodes, anchor_config, ns_ext, next_docpr_id)`
2. Inserts the returned `para` before the start marker
3. Removes marker and content paragraphs (same removal pattern as textbox path)
4. Adjacency relocation uses the direct node reference `result$para` (lesson from Phase 2b review)

## Feature 3: Harvest

### Detection

**`is_grouped_figure(para, ns)`** — Returns `TRUE` when a `w:p` contains `wp:anchor` (directly or inside `mc:AlternateContent/mc:Choice`) with `wpg:wgp` that has both `pic:pic` and `wps:txbx` descendants.

Must handle `mc:AlternateContent` wrapping: Word always emits grouped shapes inside `mc:Choice Requires="wpg"`. The detector looks for `wpg:wgp` both directly under `wp:anchor` (our output) and inside `mc:Choice` (Word's output).

**Detection order** (in `convert_to_qmd()` harvest loop):

1. `is_grouped_figure()` — most specific: `wp:anchor` + `wpg:wgp` + both `pic:pic` and `wps:txbx`
2. `is_text_box()` — `wp:anchor` + `wps:txbx` but not `pic:pic`
3. `is_anchored_image()` — `wp:anchor` + `pic:pic`
4. `is_floating_table()` — `w:tbl` + `w:tblpPr`

### Property extraction

**`extract_group_properties(para, ns)`** — Returns a named list:
- Standard anchor properties: `horizontal_anchor`, `vertical_anchor`, `position_x`, `position_y`, `float_width`, `z_layer`, `wrap_style` (same extraction logic as `extract_text_box_properties()`)
- Group-specific: `caption_y` (from `wps:wsp/wps:spPr/a:xfrm/a:off@y`, converted EMU → DXA), `image_height` (from `pic:pic/pic:spPr/a:xfrm/a:ext@cy`, converted EMU → DXA)

NA guards on all numeric conversions (lesson from Phase 2b review).

Returns `NULL` if `wp:anchor` is missing.

### Content extraction

**`extract_group_content(para, ns)`** — Returns a list:
- `$image_rel_id` — `r:embed` attribute from `a:blip` inside the `pic:pic`
- `$caption_nodes` — xml2 nodeset of `w:p` elements from `wps:txbx/w:txbxContent`

Both lookups handle `mc:AlternateContent` wrapping by searching inside `mc:Choice` when the direct path yields `xml_missing`.

### Harvest loop integration

In `convert_to_qmd()`, the new check runs before `is_text_box()`:

```r
if (is_grouped_figure(p, ns)) {
  group_props <- extract_group_properties(p, ns)
  group_content <- extract_group_content(p, ns)

  # Build div attributes from positioning + group internals
  # Emit div_open
  # Emit image: ![](media/imageN.png)
  # Emit blank line
  # Emit caption paragraphs via extract_formatted_text()
  # Emit div_close (:::)
}
```

**QMD output:**

```markdown
::: {.column-margin float-width="9348dxa" caption-y="4978dxa" image-height="3200dxa"}
![](media/image1.png)

**Figure 1.** Caption text with *formatting* and [@citations].
:::
```

The image path comes from `image_rels[[group_content$image_rel_id]]`. Caption paragraphs are converted to markdown using the existing `extract_formatted_text()` function, preserving inline formatting and Zotero citation markers.

## Feature 4: Schema and pipeline

**Field code schema** (`R/field_codes.R` and `inst/schema/docstyle-field-codes.json`):
- Add `"caption_y"` and `"image_height"` to `docstyle_schemas$anchor$optional`
- `handle_docstyle_anchor()` already passes through unknown payload keys — these flow into div attributes on harvest automatically

**CSS pipeline**: No new CSS properties. The existing anchor properties cover positioning. Group-specific internal layout (`caption-y`, `image-height`) is per-instance via div attributes only — no CSS use case for global caption offset.

**Lua filter**: No changes. `anchor.lua` emits markers for any positioned div. Group detection is entirely R post-render.

## Testing

### Unit tests (`test-anchor-assembly.R`)
- `detect_anchor_content()` returns `"group"` for image+text content
- `detect_anchor_content()` still returns `"mixed"` for table+text, table+image
- `build_group_anchor()` success: valid `wpg:wgp` with `pic:pic` and `wps:txbx` children
- `build_group_anchor()` with `caption_y` and `image_height` — verify internal offsets in EMU
- `build_group_anchor()` defaults: absent `caption_y`/`image_height` produce sensible layout
- `build_group_anchor()` no image → `success = FALSE`
- `build_group_anchor()` empty caption → group with image only (degenerate case)
- Adjacency relocation with grouped figure (direct node reference)

### Harvest tests (`test-harvest-anchor.R`)
- `is_grouped_figure()` returns `TRUE` for `wpg:wgp` with `pic:pic` + `wps:txbx`
- `is_grouped_figure()` returns `FALSE` for plain anchored image (no `wps:txbx`)
- `is_grouped_figure()` returns `FALSE` for text box (no `pic:pic`)
- `is_grouped_figure()` detects group inside `mc:AlternateContent/mc:Choice`
- `extract_group_properties()` reads anchor positioning + `caption_y` + `image_height`
- `extract_group_properties()` handles missing position nodes (NA guards)
- `extract_group_content()` returns image rel ID and caption nodes
- Detection order: grouped figure beats text box and anchored image

### Integration test
- Harvest a grouped figure from the PHES-ODM-v3 Microorganisms document
- Verify emitted QMD contains div with image, caption, and positioning attributes
- Verify field code schema accepts `caption_y` and `image_height`

## File changes

| File | Change |
|------|--------|
| `R/anchor_assembly.R` | `detect_anchor_content()`: `has_image && has_text` → `"group"`. New `build_group_anchor()`, `is_grouped_figure()`, `extract_group_properties()`, `extract_group_content()`. Dispatch branch in `assemble_anchors()`. |
| `R/docx_to_qmd.R` | New harvest path before `is_text_box` check. |
| `R/field_codes.R` | Add `"caption_y"`, `"image_height"` to `docstyle_schemas$anchor$optional`. |
| `inst/schema/docstyle-field-codes.json` | Add `caption_y`, `image_height` to `anchor_payload_fields`. |
| `tests/testthat/test-anchor-assembly.R` | Group detection, assembly, edge cases. |
| `tests/testthat/test-harvest-anchor.R` | Group harvest detection, extraction, `mc:AlternateContent`. |
| `dev/ARCHITECTURE-anchors.md` | Content dispatch table: add `"group"`. Harvest detection order. Group OOXML structure. |
