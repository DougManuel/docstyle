# Unified anchor positioning model — Phase 2a design spec

> **Issue:** #119 (Phase 2a), #116 (umbrella)
> **Depends on:** PR #118 (Phase 1, merged)
> **Related:** #112 (Phase 2b: text boxes), #117 (explicit adjacency)

## Goal

Extend the floating content pipeline from Phase 1 (text in invisible floating tables) to positioned images via DrawingML `wp:anchor` + `pic:pic`. Rename the vocabulary from "float" to "anchor" throughout. Full round-trip: render (QMD → Word) and harvest (Word → QMD).

## Design scope and forward compatibility

Phase 2a implements positioned images, but the architecture is designed to extend to:

- **Typst output** — the same CSS properties (`vertical-anchor`, `horizontal-anchor`, `position-x/y`) map to Typst's `float()` and `place()` functions. `anchor.lua` already returns `nil` for Typst; when Typst support is added, it emits Typst-native raw blocks instead of OOXML markers. CSS remains the single source of truth across both formats. `anchor_assembly.R` is Word-only; Typst handles positioning natively.
- **Text boxes** (Phase 2b, #112) — same `DOCSTYLE_ANCHOR::` markers, same CSS properties. `detect_anchor_content()` classifies as `"text"` and calls `build_textbox_anchor()`. No new Lua filter needed.
- **Grouped image+caption** (Phase 2c) — `detect_anchor_content()` adds a `"group"` classification → `build_group_anchor()`. Same markers, same CSS.
- **Figures** — `figure.lua` (identity/metadata) and `anchor.lua` (positioning) remain separate concerns. A `.figure` div with anchor CSS triggers both. The separation is clean: identity says *what* it is; anchor says *where* it goes.

### Naming validation against extension scenarios

The names chosen for Phase 2a were validated against all planned extensions:

| Name | Typst? | Text boxes? | Groups? | Figures? |
|------|--------|-------------|---------|----------|
| `anchor.lua` | Returns `nil` today; emits Typst blocks later. "Anchor" is format-neutral (Typst `place()` also anchors to a frame). | Same filter, no changes. | Same filter. | Separate filter (`figure.lua`), no conflict. |
| `anchor_assembly.R` | Word-only; Typst needs no R assembly. | Adds `build_textbox_anchor()`. | Adds `build_group_anchor()`. | No changes needed. |
| `DOCSTYLE_ANCHOR::` | Word-only markers. | Same markers. | Same markers. | Wraps figure markers (outer container). |
| `vertical-anchor` / `horizontal-anchor` (CSS) | Maps to Typst `place(alignment, dx, dy)`. | Same properties. | Same properties. | Same properties. |
| `float-width` (CSS) | "Float" here is the standard CSS concept (width of a floating element), not our old naming. Alternatives (`anchor-width`) are less intuitive. Kept as-is. | Same property. | Same property (group extent). | Same property. |
| `assemble_anchors()` | Not called for Typst. | Dispatches to textbox builder. | Dispatches to group builder. | Not involved (figure identity is separate). |

## Architecture

### Two placement modes, one CSS vocabulary

| Mode | CSS trigger | Meaning | OOXML (tables) | OOXML (images) | Typst |
|------|------------|---------|-----------------|-----------------|-------|
| **float** | `vertical-anchor: text` | Beside text, text wraps | `w:tblpPr` | `wp:anchor` (text-relative) | `float()` |
| **place** | `vertical-anchor: page` or `section` | Fixed position | `w:tblpPr` | `wp:anchor` (page-relative) | `place()` |

### Approach C — positioning as a CSS property layer, not a filter concern

Lua stays simple: any div with an anchor-eligible CSS class gets `DOCSTYLE_ANCHOR` markers. R post-render assembly is the smart layer that inspects content type and picks the OOXML mechanism.

```
Phase 1 (Pre-render, R):
  read_css() → extract_anchor_styles() → page-config.json { anchor_styles: { ... } }

Phase 2 (Pandoc, Lua):
  anchor.lua loads anchor_styles from page-config.json
  Detects divs with anchor-eligible CSS classes
  Emits: DOCSTYLE_ANCHOR::{class}::{adjacent}
  Passes through div content unchanged
  Emits: DOCSTYLE_ANCHOR_END::{class}
  (figure.lua continues to handle identity/metadata separately)

Phase 3 (Post-render, R):
  assemble_anchors() scans for DOCSTYLE_ANCHOR:: markers
  For each marker pair:
    1. Read JSON payload from ADDIN DOCSTYLE field code
    2. Inspect content between markers:
       - Only w:tbl children → use w:tblpPr (Phase 1, existing)
       - w:p with wp:inline image → rewrite to wp:anchor (Phase 2a)
       - w:p with text only → use wps:txbx (Phase 2b, future)
    3. Apply positioning from payload
    4. Remove markers
```

### Why Approach C

- "Where does positioning happen?" has one answer: R assembly
- DRY and staged — easier for both humans and AI to maintain
- Lua is a thin marker emitter; R has full XML context
- Extends naturally to text boxes and groups without Lua changes

## CSS properties (unified vocabulary)

| Property | Values | Default | Notes |
|----------|--------|---------|-------|
| `vertical-anchor` | `text`, `margin`, `page`, `section` | `text` | `section` maps to `margin` in OOXML |
| `horizontal-anchor` | `text`, `margin`, `page` | `margin` | |
| `position-x` | CSS length or `dxa` | `0` | |
| `position-y` | CSS length or `dxa` | `0` | |
| `float-width` | CSS length or `dxa` | content width | |
| `wrap-style` | `none`, `square`, `tight`, `top-and-bottom` | `square` | `tight`/`through` deferred |
| `wrap-side` | `both`, `left`, `right`, `largest` | `both` | |
| `wrap-distance` | 1-4 value CSS shorthand | `0 198dxa 0 198dxa` | |
| `z-layer` | `front`, `behind` | `front` | Maps to `behindDoc` on `wp:anchor` |

**Detection rule:** A class selector with `vertical-anchor` or `horizontal-anchor` becomes anchor-eligible.

**No predefined class names in schema.** `.column-margin`, `.journal-sidebar` etc. are template CSS concerns. Any class with anchor CSS properties becomes anchor-eligible. `.column-margin` is preserved as a class name for Typst compatibility (Quarto Marginalia handles it natively).

### Semantic class examples

```css
/* Tufte margin note — float mode */
.column-margin {
  vertical-anchor: text;
  horizontal-anchor: margin;
  float-width: 250pt;
  wrap-style: square;
}

/* Journal sidebar — place mode */
.journal-sidebar {
  vertical-anchor: page;
  horizontal-anchor: margin;
  position-y: 11461dxa;
  float-width: 2410dxa;
}

/* Letterhead logo — place mode, behind text */
.letterhead-logo {
  vertical-anchor: page;
  horizontal-anchor: page;
  position-x: 720dxa;
  position-y: 360dxa;
  z-layer: behind;
}
```

### QMD authoring

```markdown
::: {.column-margin}
![Figure caption](image.png)
:::
```

The same QMD produces a margin figure or an inline figure depending on whether the CSS profile defines `.column-margin` with anchor properties.

## Renames (Phase 1 → Phase 2a)

| Current | New | Reason |
|---------|-----|--------|
| `float-table.lua` | `anchor.lua` | Umbrella term for both float and place |
| `float_assembly.R` | `anchor_assembly.R` | Matches Lua filter |
| `test-float-assembly.R` | `test-anchor-assembly.R` | Matches module |
| `test-harvest-float.R` | `test-harvest-anchor.R` | Matches module |
| `test-css-float.R` | `test-css-anchor.R` | Matches module |
| `DOCSTYLE_FLOAT::` | `DOCSTYLE_ANCHOR::` | Unified marker prefix |
| `DOCSTYLE_FLOAT_END::` | `DOCSTYLE_ANCHOR_END::` | Matching end marker |
| `float_styles` (page-config.json) | `anchor_styles` | Consistent vocabulary |
| `extract_float_styles()` | `extract_anchor_styles()` | R function |
| `css_to_float_style()` | `css_to_anchor_style()` | R function |
| `assemble_float_tables()` | `assemble_anchors()` | Content-agnostic |
| `handle_docstyle_float()` | `handle_docstyle_anchor()` | Field code handler |

## Field code payload (v3)

```json
{
  "type": "anchor",
  "version": 3,
  "class": "column-margin",
  "content_hint": "image",
  "vertical_anchor": "text",
  "horizontal_anchor": "margin",
  "position_y": "0",
  "position_x": "0",
  "float_width": "250pt",
  "wrap_style": "square",
  "wrap_side": "both",
  "wrap_distance": "0 198dxa 0 198dxa",
  "z_layer": "front"
}
```

Changes from Phase 1:
- `type`: `"float"` → `"anchor"`
- `version`: `2` → `3`
- New: `content_hint` — `"table"`, `"image"`, `"text"`, `"mixed"`. Advisory; R inspects actual content.
- New: `z_layer` — `"front"` or `"behind"`
- `adjacent` remains optional, deferred to #117

### Schema (`docstyle-field-codes.json`)

`float_classes` and `float_payload_fields` removed. Replaced by:

```json
{
  "anchor_payload_fields": {
    "type": "anchor",
    "version": 3,
    "class": "string (CSS class name)",
    "content_hint": "table | image | text | mixed",
    "vertical_anchor": "text | margin | page | section",
    "horizontal_anchor": "text | margin | page",
    "position_y": "CSS length or dxa",
    "position_x": "CSS length or dxa",
    "float_width": "CSS length or dxa",
    "wrap_style": "none | square | tight | top-and-bottom",
    "wrap_side": "both | left | right | largest",
    "wrap_distance": "1-4 value CSS shorthand",
    "z_layer": "front | behind",
    "adjacent": "string (paragraph ID, optional)"
  }
}
```

### Dispatch (`field_codes.R`)

```r
docstyle_schemas$anchor <- list(
  required = c("type", "class"),
  optional = c("version", "content_hint", "vertical_anchor", "horizontal_anchor",
               "position_y", "position_x", "float_width",
               "wrap_style", "wrap_side", "wrap_distance",
               "z_layer", "adjacent")
)

# Backward compat:
"float" = handle_docstyle_anchor   # deprecated alias
```

### Filter interaction

When a div has both `.figure` and an anchor-eligible class, both filters fire:
- `figure.lua` emits identity field codes (type `"figure"`, carries `id`, `original_path`)
- `anchor.lua` emits positioning field codes (type `"anchor"`, carries positioning)

Nesting order: anchor markers wrap figure markers (positioning is the outer container). On harvest, both are detected — figure identity restores `#fig-id`, anchor positioning restores the `::: {.class}` wrapper.

## Render path (Phase 2a new work)

### Content detection in R assembly

```
assemble_anchors(body, ns, page_config):
  for each marker pair:
    content_nodes ← children between start and end markers
    content_type ← detect_anchor_content(content_nodes, ns)

    switch(content_type):
      "table"  → build_table_anchor(content_nodes, payload)    # Phase 1
      "image"  → build_image_anchor(content_nodes, payload)    # Phase 2a
      "text"   → build_textbox_anchor(content_nodes, payload)  # Phase 2b
      "mixed"  → build_textbox_anchor(content_nodes, payload)  # fallback
```

**Content classification rules for `detect_anchor_content()`:**
- **"table"** — all content nodes are `w:tbl` elements (no paragraphs outside tables)
- **"image"** — at least one paragraph contains `w:drawing/wp:inline` with `pic:pic`. Adjacent paragraphs (captions, whitespace) are included — the image is the primary content. If the div also contains `.figure` field code markers, these are identity metadata and don't change the classification.
- **"text"** — paragraphs with no tables or images
- **"mixed"** — tables and images in the same marker range (fallback to textbox in Phase 2b)

**`content_hint` in Lua:** `anchor.lua` sets `content_hint` based on Pandoc AST inspection (an `Image` block inside the div = `"image"`, a `Table` = `"table"`, otherwise `"text"`). This is advisory — R assembly inspects actual rendered OOXML, but the hint improves harvest round-trip when content is ambiguous.

### `build_image_anchor()`

1. Find `w:drawing/wp:inline` in content paragraphs
2. Extract existing image data (`a:blip r:embed`, extent `cx`/`cy`)
3. Replace `wp:inline` with `wp:anchor`:
   - `simplePos="0"` `relativeHeight="251658240"` `behindDoc` from `z_layer`
   - `allowOverlap="1"` `layoutInCell="1"` `locked="0"`
   - `wp:positionH relativeFrom="{horizontal-anchor}"` → `wp:posOffset` in EMU
   - `wp:positionV relativeFrom="{vertical-anchor}"` → `wp:posOffset` in EMU
   - Wrap element from `wrap_style` (`wp:wrapSquare`, `wp:wrapNone`, `wp:wrapTopAndBottom`)
   - `wp:extent cx="{float-width in EMU}" cy="{scaled height}"`
   - `wp:effectExtent l="0" t="0" r="0" b="0"`
   - `wp:docPr` with unique ID (scan existing IDs)
   - `wp:cNvGraphicFramePr` (empty, schema-required)
   - Original `a:graphic` subtree preserved unchanged
4. Remove marker paragraphs, keep rewritten paragraph in place

### Unit conversion

| Source | EMU | Formula |
|--------|-----|---------|
| 1 twip/DXA | 635 EMU | `× 635` |
| 1 pt | 12700 EMU | `× 12700` |
| 1 inch | 914400 EMU | `× 914400` |
| 1 cm | 360000 EMU | `× 360000` |

New function: `css_to_emu()` in `css_parser.R`.

### OOXML anchor mapping

**Positioning anchors:**

| CSS value | `w:tblpPr` | `wp:anchor positionV` | `wp:anchor positionH` |
|-----------|------------|----------------------|----------------------|
| `text` | `@vertAnchor="text"` | `@relativeFrom="paragraph"` | `@relativeFrom="column"` |
| `margin` | `@vertAnchor="margin"` | `@relativeFrom="margin"` | `@relativeFrom="margin"` |
| `page` | `@vertAnchor="page"` | `@relativeFrom="page"` | `@relativeFrom="page"` |

**Wrap style:**

| CSS `wrap-style` | `w:tblpPr` | `wp:anchor` |
|------------------|------------|-------------|
| `none` | (no wrap attributes) | `<wp:wrapNone/>` |
| `square` | `leftFromText`/`rightFromText` etc. | `<wp:wrapSquare wrapText="{wrap-side}"/>` |
| `top-and-bottom` | `topFromText`/`bottomFromText` only | `<wp:wrapTopAndBottom/>` |

**Wrap side:**

| CSS `wrap-side` | OOXML `@wrapText` |
|-----------------|-------------------|
| `both` | `bothSides` |
| `left` | `left` |
| `right` | `right` |
| `largest` | `largest` |

**Wrap distance:**

| Context | Unit | Attributes |
|---------|------|------------|
| `w:tblpPr` | DXA | `@topFromText`, `@rightFromText`, `@bottomFromText`, `@leftFromText` |
| `wp:anchor` | EMU | `@distT`, `@distR`, `@distB`, `@distL` |

### Mandatory boilerplate for `wp:anchor`

| Element / attribute | Default | Notes |
|---------------------|---------|-------|
| `wp:effectExtent` | `l="0" t="0" r="0" b="0"` | Schema-required |
| `wp:simplePos` | `x="0" y="0"` | Placeholder when `simplePos="0"` |
| `wp:docPr` | Unique `id` + `name` | Scan existing IDs |
| `wp:cNvGraphicFramePr` | Empty element | Schema-required |
| `@simplePos` | `"0"` | Must be 0 with positionH/V |
| `@relativeHeight` | Auto-increment | Z-ordering |
| `@behindDoc` | `"0"` | `"1"` when `z-layer: behind` |
| `@locked` | `"0"` | Future: #117 scope |
| `@layoutInCell` | `"1"` | |
| `@allowOverlap` | `"1"` | |

## Harvest path (Phase 2a new work)

### Detection

1. During body child scan, detect `w:drawing/wp:anchor` containing `a:graphicData/pic:pic`
2. `is_anchored_image(node, ns)` returns TRUE/FALSE

### Property extraction

`extract_anchor_properties(anchor_node, ns)` reads:
- `wp:positionH@relativeFrom` → `horizontal_anchor`
- `wp:positionV@relativeFrom` → `vertical_anchor`
- `wp:posOffset` values → `position_x`/`position_y` (EMU → DXA)
- `wp:extent@cx` → `float_width` (EMU → DXA)
- Wrap element type → `wrap_style`
- `@behindDoc` → `z_layer`

### Class resolution

- If `ADDIN DOCSTYLE` field code present → use `class` from payload (exact round-trip)
- If no field code → emit raw positioning attributes on div, no class name

### Output

```markdown
::: {.column-margin}
![Caption](image.png)
:::
```

Or without field code:

```markdown
::: {vertical-anchor="text" horizontal-anchor="margin" float-width="3175dxa"}
![](image.png)
:::
```

## Backward compatibility

- `DOCSTYLE_FLOAT::` markers accepted by `assemble_anchors()` as deprecated alias
- `type: "float"` in field code payloads dispatched to `handle_docstyle_anchor()`
- `"float"` added to type filter alongside `"anchor"` in `detect_docstyle_field_codes()`
- Documents rendered with Phase 1 continue to harvest correctly

## Testing strategy

### `test-css-anchor.R` (rename + extend)

- `css_to_anchor_style()` extracts all 9 properties including `z_layer`
- `css_to_anchor_style()` returns NULL for non-anchor selectors
- `extract_anchor_styles()` finds anchor-eligible selectors
- `css_to_emu()` converts pt, cm, in, dxa to EMU

### `test-anchor-assembly.R` (rename + extend)

- Existing table assembly tests with renamed functions and `DOCSTYLE_ANCHOR::` markers
- `detect_anchor_content()` classifies: table-only, image-only, text-only, mixed
- `build_image_anchor()` produces valid `wp:anchor` XML:
  - `positionH`/`positionV` with correct EMU offsets
  - Wrap element matching `wrap_style`
  - `behindDoc` reflecting `z_layer`
  - `extent` with EMU width and scaled height
  - Preserved `a:graphic` subtree
- `assemble_anchors()` end-to-end with image content
- Backward compat: `DOCSTYLE_FLOAT::` markers still assembled

### `test-harvest-anchor.R` (rename + extend)

- `is_anchored_image()` detects `wp:anchor` with `pic:pic`
- `is_anchored_image()` returns FALSE for `wp:inline`
- `extract_anchor_properties()` reads all attributes from `wp:anchor`
- Round-trip: properties → div attributes → CSS vocabulary
- Harvest with `ADDIN DOCSTYLE` → exact class restoration
- Harvest without field code → raw positioning attributes

### `test-field-codes.R` (extend)

- `handle_docstyle_anchor()` returns correct `div_open`/`div_close`
- Backward compat: `type: "float"` dispatches to `handle_docstyle_anchor()`
- Schema validation for `anchor` type

### Not tested in Phase 2a

- Text box assembly/harvest (Phase 2b)
- Grouped content (Phase 2c)
- `adjacent` attribute (#117)
- Wrap contour polygons

## File map

### New files

| File | Purpose |
|------|---------|
| `R/anchor_assembly.R` | Renamed + extended from `float_assembly.R` |
| `_extensions/docstyle/anchor.lua` | Renamed from `float-table.lua` |
| `tests/testthat/test-anchor-assembly.R` | Renamed + extended |
| `tests/testthat/test-harvest-anchor.R` | Renamed + extended |
| `tests/testthat/test-css-anchor.R` | Renamed + extended |
| `dev/ARCHITECTURE-anchors.md` | Architecture doc |

### Modified files

| File | Changes |
|------|---------|
| `R/css_parser.R` | Rename functions, add `css_to_emu()` |
| `R/field_codes.R` | `anchor` schema, `handle_docstyle_anchor()`, backward compat |
| `R/generated_content.R` | Add `"anchor"` to type filter |
| `R/docx_to_qmd.R` | `is_anchored_image()`, `extract_anchor_properties()`, rename state vars |
| `R/finalize_docx.R` | Call `assemble_anchors()` |
| `R/use_docstyle.R` | `EXTENSION_SOURCE_FILES`: `anchor.lua` |
| `inst/schema/docstyle-field-codes.json` | `anchor_payload_fields` |
| `_extensions/docstyle/_extension.yml` | Filter entry rename |
| `CLAUDE.md` | Update file map and architecture refs |

### Deleted files

| File | Reason |
|------|--------|
| `R/float_assembly.R` | Renamed |
| `_extensions/docstyle/float-table.lua` | Renamed |
| `tests/testthat/test-float-assembly.R` | Renamed |
| `tests/testthat/test-harvest-float.R` | Renamed |
| `tests/testthat/test-css-float.R` | Renamed |

## Not in Phase 2a

- Text boxes (`wps:txbx`) — Phase 2b, #112
- Grouped image+caption (`wpg:wgp`) — Phase 2c
- Explicit adjacency (`adjacent="#id"`) — #117
- Wrap contour polygons (`wrapTight`/`wrapThrough`)
- `locked` attribute (tracked, low priority)
- Typst `place()` integration (future)
