# Anchor Positioning Architecture

## Overview

Unified CSS-driven positioning for all floating content. Content-aware OOXML
mechanism selection based on a single CSS vocabulary.

## Pipeline

```
CSS class with vertical-anchor/horizontal-anchor
  → extract_anchor_styles() → page-config.json { anchor_styles }
  → anchor.lua emits DOCSTYLE_ANCHOR::{class} markers
  → assemble_anchors() detects content type:
      table → w:tblpPr (invisible floating table)
      image → wp:anchor + pic:pic (DrawingML anchor)
      text  → floating table (default) or wps:txbx (content-mode: textbox)
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

## Content dispatch

`detect_anchor_content()` inspects nodes between markers and selects the assembly path:

| Content type | Detection | Builder | OOXML mechanism |
|-------------|-----------|---------|-----------------|
| Table (`w:tbl`) | Has `w:tbl` child | `build_table_anchor_xml()` | NEW invisible floating wrapper table (`w:tblpPr`); original table nested inside `w:tc` |
| Image (`w:drawing`) | Has `wp:inline` inside drawing | `build_image_anchor()` | DrawingML `wp:anchor` wrapping `pic:pic` |
| Group (image + caption) | `has_image && has_text && !has_table` | `build_group_anchor()` | DrawingML `wp:anchor` wrapping `wpg:wgp` (`pic:pic` + `wps:wsp`) |
| Text/mixed (default) | No table or image detected | `build_table_anchor_xml()` | NEW invisible single-cell floating table wrapping content in `w:tc` |
| Text/mixed (`content-mode: textbox`) | `content-mode="textbox"` div attr | `build_text_box_anchor()` | DrawingML text box (`wps:wsp` → `wps:txbx` → `w:txbxContent`) |

### Text box OOXML structure

The `build_text_box_anchor()` path produces a DrawingML text box inside `wp:anchor`:

```xml
<w:p>
  <w:r>
    <w:drawing>
      <wp:anchor ...>
        <wp:positionH relativeFrom="..."><wp:posOffset>...</wp:posOffset></wp:positionH>
        <wp:positionV relativeFrom="..."><wp:posOffset>...</wp:posOffset></wp:positionV>
        <wp:extent cx="..." cy="..." />
        <wp:wrapSquare wrapText="bothSides" />
        <wp:docPr id="..." name="TextBox ..." />
        <a:graphic>
          <a:graphicData uri="...wps...">
            <wps:wsp>
              <wps:cNvSpPr txBox="1" />
              <wps:spPr>...</wps:spPr>
              <wps:txbx>
                <w:txbxContent>
                  <!-- original w:p paragraphs moved here -->
                </w:txbxContent>
              </wps:txbx>
              <wps:bodyPr ... />
            </wps:wsp>
          </a:graphicData>
        </a:graphic>
      </wp:anchor>
    </w:drawing>
  </w:r>
</w:p>
```

Note: Word may wrap this in `mc:AlternateContent` when saving, but docstyle emits the simpler structure. Modern Word (2013+) reads both forms correctly.

### Group OOXML structure

The `build_group_anchor()` path produces a WordprocessingGroup inside `wp:anchor`, combining an image (`pic:pic`) and a caption text box (`wps:wsp`) as sibling members:

```xml
<wp:anchor ...>
  <wp:positionH relativeFrom="..."><wp:posOffset>...</wp:posOffset></wp:positionH>
  <wp:positionV relativeFrom="..."><wp:posOffset>...</wp:posOffset></wp:positionV>
  <wp:extent cx="..." cy="..."/>
  <wp:wrapSquare wrapText="..."/>
  <wp:docPr id="..." name="Group ..."/>
  <a:graphic>
    <a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup">
      <wpg:wgp>
        <wpg:cNvGrpSpPr/>
        <wpg:grpSpPr>
          <a:xfrm>
            <a:off x="0" y="0"/>
            <a:ext cx="..." cy="..."/>          <!-- group extent -->
            <a:chOff x="0" y="0"/>
            <a:chExt cx="..." cy="..."/>        <!-- child coordinate space -->
          </a:xfrm>
        </wpg:grpSpPr>
        <pic:pic>...</pic:pic>                   <!-- image member -->
        <wps:wsp>                                <!-- caption text box member -->
          <wps:cNvSpPr txBox="1"/>
          <wps:spPr>
            <a:xfrm>
              <a:off x="0" y="..."/>             <!-- caption_y offset -->
              <a:ext cx="..." cy="..."/>         <!-- caption dimensions -->
            </a:xfrm>
          </wps:spPr>
          <wps:txbx>
            <w:txbxContent>
              <w:p>...</w:p>                     <!-- caption paragraphs -->
            </w:txbxContent>
          </wps:txbx>
        </wps:wsp>
      </wpg:wgp>
    </a:graphicData>
  </a:graphic>
</wp:anchor>
```

#### Group-specific payload fields

Two additional fields are harvested from group anchors for round-trip fidelity:

- `caption_y` — vertical offset of the caption text box within the group coordinate space (DXA). Determines the gap between image and caption.
- `image_height` — height of the image member within the group (DXA). Needed to reconstruct the group layout without re-reading the image file.

These are emitted as div attributes in the QMD and passed through the field code payload on re-render.

### `content-mode` CSS property

Opt-in via CSS property or div attribute:

- CSS: `content-mode: textbox` on the anchor class selector
- Div attribute: `content-mode="textbox"` on the fenced div in QMD

When omitted, text/mixed content defaults to the invisible floating table path.

## Adjacency

Anchored content can be relocated next to a specific paragraph using the `adjacent` attribute.

### Bookmark lookup

`find_bookmark_paragraph()` scans all `w:bookmarkStart` elements in the document body for a matching `w:name` attribute (with or without `_docstyle_` prefix). Returns the parent `w:p` of the matching bookmark.

### Relocation

Adjacency relocation moves assembled content before the target paragraph. The strategy depends on the xml2 document tree origin:

- **Same-document nodes** (images via `build_image_anchor`): `xml_add_sibling` performs a move (detach + re-insert). `relocate_to_adjacent()` handles this directly.
- **Cross-document nodes** (floating tables, text boxes, groups): These are created via `read_xml()` in a separate document tree. `xml_add_sibling` COPIES rather than moves. The assembly code uses a remove-then-insert pattern: remove the in-tree copy, then insert the original cross-document node at the target.

### QMD syntax

```markdown
::: {.note-box adjacent="#my-heading"}
This content floats next to the paragraph containing bookmark "my-heading".
:::
```

The Lua filter emits `DOCSTYLE_ANCHOR::note-box::my-heading` — the second field carries the adjacency target.

## Harvest detection order

On round-trip (Word → QMD), `convert_to_qmd()` checks anchor types most-specific-first:

1. **Grouped figure** — `is_grouped_figure()`: `wp:anchor` + `wpg:wgp` + `pic:pic` + `wps:txbx`
2. **Text box** — `is_text_box()`: `wp:anchor` + `wps:txbx` (no `pic:pic`)
3. **Anchored image** — `is_anchored_image()`: `wp:anchor` + `pic:pic`
4. **Floating table** — `is_floating_table()`: `w:tbl` + `w:tblpPr`

Order matters: a grouped figure contains both `pic:pic` and `wps:txbx`, so it must be checked before the text box and image detectors. Word emits grouped shapes inside `mc:AlternateContent/mc:Choice Requires="wpg"` — the detection functions use `.//wp:anchor` XPath which descends through this wrapper transparently.

Each detector has a paired extractor (`extract_group_properties()`, `extract_text_box_properties()`, `extract_anchor_image_properties()`, `extract_float_properties()`) that reads positioning attributes back to CSS-level values.

## Marker format

Opening: `DOCSTYLE_ANCHOR::{class}::{adjacent}`
Closing: `DOCSTYLE_ANCHOR_END::{class}`
Legacy: `DOCSTYLE_FLOAT::` accepted for backward compat.
