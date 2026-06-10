# Template mode for docstyle

## Goal

Add a second styling pathway — template-based — alongside the existing CSS-first default. Users provide a `.dot` or `.docx` template, and docstyle uses it as the reference document, preserving the template's native style names through the round-trip. CSS overlays are optional.

## Motivation

Publishers provide Word templates (`.dot`/`.docx`) with hundreds of pre-defined styles. Extracting every property to CSS is tedious and often incomplete — CSS can't express every OOXML property (complex list numbering, theme-linked fonts, table conditional formatting). For one-off papers or when a publisher template exists, using the template directly is the pragmatic choice.

CSS-first remains the default and recommended path for repeated use (transparent, diffable, controllable). Template mode is the supported alternative for cases where a publisher template exists and full CSS extraction isn't worth the effort. The user decides.

## Configuration

```yaml
docstyle:
  base-doc: path/to/microorganisms-template.dot
  css: optional-overrides.css  # optional — overlays on top of template
```

The `base-doc` key accepts three value types:

| Value | Behaviour |
|---|---|
| *(omitted)* | Default. Build minimal reference.docx from CSS |
| `"pandoc"` | Use Pandoc's built-in default reference.docx |
| File path (`.dot`, `.docx`) | Use the provided template as reference.docx |

## Design principle: preserve native style names

The round-trip should preserve the template's own style identifiers. Rather than normalising `MDPI21heading1` to `Heading1` and back, the pipeline maintains the template's naming:

```
MDPI21heading1 (source docx)
  → # Heading text (QMD, with style recorded in harvest map)
  → Heading1 (Pandoc's output, using reference.docx)
  → MDPI21heading1 (post-render swap restores template name)
```

This avoids lossy translation and ensures the output document uses the same style names as the source — critical when co-authors or publishers open the document in Word and expect their template styles.

## Architecture

### Pre-render phase (generate-reference.R)

Current CSS-first flow:

1. Read CSS → build style properties
2. Build minimal reference.docx from OOXML templates
3. Inject CSS styles into empty style definitions
4. Write to `_docstyle/reference.docx`

Template mode flow:

1. **Copy template** to `_docstyle/reference.docx`
2. **Scan template styles.xml** → build style map (Pandoc ID → template ID) → save to `_docstyle/style-map.json`
3. **If CSS provided**, overlay CSS properties onto template styles (update specified properties, preserve unspecified ones from the template)
4. Write to `_docstyle/reference.docx`

Cache key = `hash(template file) + hash(CSS file if present)`. Template changes invalidate the cache automatically.

### Style map generation

The pre-render scans the template's `styles.xml` and builds a mapping from Pandoc's expected style IDs to the template's native style IDs. Detection uses the same resolution logic as `style_resolver.R`:

1. **Direct match** — template has `Heading1` → maps to itself (no swap needed)
2. **`outlineLvl` match** — template style has `outlineLvl="0"` → maps `Heading1` → that style ID
3. **`basedOn` chain** — template style is based on `Heading1` → maps `Heading1` → that style ID
4. **Display name match** — style display name is "Heading 1" (case-insensitive) → maps `Heading1` → that style ID

The map is saved as `_docstyle/style-map.json`:

```json
{
  "Heading1": "MDPI21heading1",
  "Heading2": "MDPI22heading2",
  "Heading3": "MDPI23heading3",
  "BodyText": "MDPI31text",
  "Caption": "MDPI51figurecaption"
}
```

Only entries where the template style ID differs from Pandoc's expected ID appear. Identity mappings (e.g., `Normal` → `Normal`) are omitted.

**User-editable:** If auto-detection gets a mapping wrong, the user edits `style-map.json`. The file is regenerated only when the template changes (cache invalidation). Manual edits persist across renders as long as the template is unchanged.

### CSS overlay semantics

When both `base-doc` (template) and `css` are provided:

- For each CSS rule that maps to a Word style, if that style exists in the template: **update** the properties CSS specifies, **preserve** properties CSS doesn't mention
- If the style doesn't exist in the template: **create** it (same as current CSS-first behaviour)
- **Skip** `cascade_css_to_children()` for any style that exists in the template — the template author's values are authoritative. Cascade only applies to styles created by CSS that don't exist in the template
- Only touch styles explicitly targeted by CSS rules. All other template styles pass through untouched.

### Render phase (no changes)

Pandoc uses `_docstyle/reference.docx` as the reference document. Lua filters emit markers. Pandoc applies its expected style IDs (`Heading1`, `BodyText`, etc.). No changes to this phase.

### Post-render phase (new step: style swap)

After Pandoc produces the output docx, before other post-render steps:

1. Read `_docstyle/style-map.json`
2. In the output's `word/styles.xml`: rename style IDs from Pandoc names back to template names (e.g., `Heading1` → `MDPI21heading1`). Update `basedOn`, `link`, and `next` references too.
3. In `word/document.xml`: replace all `<w:pStyle w:val="Heading1"/>` with `<w:pStyle w:val="MDPI21heading1"/>` (and similarly for `w:rStyle`).
4. Run this swap before section assembly, citation injection, and other post-render steps so those steps see the final style names.

### Style pruning changes

Current behaviour: remove unused styles from the output docx to reduce file size.

Template mode behaviour:
- **Preserve all styles that exist in the template** — they're part of the publisher's template identity and may be needed when the document is edited in Word
- **Only prune** styles that are neither in the template nor used in the output
- This is a simple check: if a style ID exists in the template's `styles.xml`, skip pruning it

### Harvest direction (no changes needed)

The harvest pipeline already:
- Records the template's native style names in `styles.json` and harvest map entries
- Uses `style_resolver.R` to map non-standard names to canonical roles for QMD output (headings, body text, etc.)
- Preserves the native style name in `harvest_map_entry.style` for provenance

No changes needed. The existing harvest captures all the information the post-render swap needs.

## Sidecar files

| File | Written by | Purpose |
|---|---|---|
| `_docstyle/style-map.json` | Pre-render (new) | Pandoc ID → template ID mapping. Auto-generated, user-editable. |
| `_docstyle/reference.docx` | Pre-render (modified) | Copied from template + CSS overlay (instead of built from scratch) |
| All existing sidecars | Unchanged | `page-config.json`, `field-codes.json`, `comments.json`, etc. |

## Scope boundaries

**Included:**
- Template-as-reference-doc support via `base-doc:` config
- Style map generation and post-render swap
- CSS overlay on template styles
- Pruning adjustment for template-sourced styles
- Cache invalidation for template changes

**Not included:**
- CSS extraction from templates (separate future project — the `harvest-template` skill)
- Template editing or modification tools
- Multi-template support (one template per project)
- Automatic style name detection beyond the four resolution methods listed above

## Test strategy

- Unit tests for style map generation (scan template styles.xml → produce correct map)
- Unit tests for post-render style swap (rename IDs in styles.xml and document.xml)
- Unit tests for CSS overlay on pre-populated styles (update specified, preserve unspecified)
- Unit tests for pruning skip (template styles preserved, non-template unused styles removed)
- Integration test: template-mode render with the Microorganisms template as fixture
- Regression: existing CSS-first mode unchanged when `base-doc` is omitted

## Files to modify

| File | Change |
|---|---|
| `R/page_layout.R` | Branch on `base-doc` type: copy template vs build minimal |
| `R/css_injection.R` | Overlay mode: update existing style properties instead of injecting into empty ones |
| `R/style_manager.R` | New: `build_style_map()` to scan template and generate mapping |
| `R/finalize_docx.R` or new `R/style_swap.R` | New: post-render style ID swap using style-map.json |
| `R/style_manager.R` | Modify pruning to preserve template-sourced styles |
| `_extensions/docstyle/generate-reference.R` | Pass `base-doc` value to `generate_reference_doc()` |
| Tests | New test file `test-template-mode.R` |
