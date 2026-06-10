---
name: harvest
description: Convert a Word document (.docx) back to Quarto markdown (.qmd), preserving Zotero citations, comments, and track changes. Use this skill for round-trip workflows when you need to import edits made in Word back into the QMD source.
---

# Harvest: Word to Quarto round-trip

Convert edited Word documents back to Quarto markdown while preserving:
- Zotero citations (live field codes for future editing)
- Comments (mapped to sidecar JSON)
- Track changes/revisions
- YAML front matter (from existing QMD)
- Generated content placeholders (version history, author plate, TOC)

## Critical workflow rules

### Do not add bibliography or csl to the QMD

Citations are handled by Zotero field codes in Word, not by Quarto/Pandoc. The harvest extracts field codes to `_docstyle/field-codes.json` and references to `_docstyle/references.json`. The post-render hook re-injects them.

Adding `bibliography:` or `csl:` to the QMD header causes Pandoc to resolve citations at render time, duplicating them and breaking the Zotero round-trip.

### Do not add format to the QMD

The format (`docstyle-docx`) is set in `_quarto.yml`. If the QMD contains `format: docx`, it overrides the project config and the extension's Lua filters won't run.

### Generated content round-trip (v0.4.0+)

Lua filters wrap generated content (version history, author plate, TOC) in `ADDIN DOCSTYLE` field codes carrying JSON metadata payloads. During harvest:

1. Field codes are detected automatically by pre-scanning `w:body` children
2. Content inside field code ranges is skipped (not converted to markdown)
3. The corresponding div placeholder is restored (`::: version-history :::`, etc.)
4. Version history tables are parsed back to YAML `version-history:` entries
5. Tracked changes and comments inside field codes trigger a warning (they are discarded)

Inline character-styled metadata (date, version) is also wrapped in field codes with a `source` payload containing the original QMD text. This restores shortcodes verbatim (e.g., `[{{< meta version-summary.date >}}]{.date}`) instead of replacing them with display text.

**Fallback**: Documents rendered with v0.3.1 bookmarks (`_docstyle_*`) are still detected. Field codes take priority when present; bookmarks fill gaps. Pre-v0.3.1 documents (no markers) convert everything to literal markdown.

## When to use

- **Round-trip editing**: Collaborator edited the .docx, now you need changes back in QMD
- **Import revised content**: Word document has text edits, new citations, or comments
- **Living documents**: Periodic harvest of external edits into source control

## Choosing parameters

### Which `project` mode?

Ask two questions:

**1. Does a `_quarto.yml` already exist for this project?**

- No → use `project = "init"` (first-time setup; creates `_quarto.yml`, CSS scaffold, placeholder QMD body)
- Yes → use `project = "update"` (re-harvest; preserves `_quarto.yml` and YAML header, overwrites body)

**2. Do you want to inspect changes before overwriting the canonical QMD?**

- Yes → harvest to a temp file first (see staged harvest below), then diff
- No → harvest directly to the canonical QMD with `project = "update"`

Use `project = "none"` only for quick inspection or debugging — it makes no project infrastructure changes and is not appropriate for committing back to source control.

Use `project = "overwrite"` only when the Word document should completely replace the project setup — it regenerates `_quarto.yml` and discards any QMD-only customisation.

### `preserve_header`: when to change it

Default is `TRUE` — almost always correct for re-harvest. Keep it unless:

| Situation | Setting |
|-----------|---------|
| Re-harvesting a collaborator's edits — QMD has curated metadata (version-history, custom YAML) | `TRUE` (default) |
| First harvest of a new Word document — no existing QMD | `FALSE` (or use `project = "init"`) |
| Word doc is the authoritative metadata source and you want to discard QMD-only YAML | `FALSE` |

**Rule of thumb:** If the QMD existed before the collaborator's edit, keep `preserve_header = TRUE`.

### Staged harvest (inspect before overwriting)

When a collaborator returns a heavily edited document, harvest to a dated temp file first:

```r
# 1. Harvest to a review copy — same name as source for traceability
docx_to_qmd(
  "source/document-2026-01-29-refs.docx",
  "document-2026-01-29-refs.qmd",   # matches source filename
  preserve_header = FALSE           # extract everything for review
)

# 2. Diff against canonical
# In terminal: diff document-2026-01-29-refs.qmd document.qmd
# Or: git diff --no-index document-2026-01-29-refs.qmd document.qmd

# 3. When satisfied, harvest directly to canonical
docx_to_qmd(
  "source/document-2026-01-29-refs.docx",
  "document.qmd",
  project = "update",
  preserve_header = TRUE
)

# 4. Clean up temp file
file.remove("document-2026-01-29-refs.qmd")
```

The staging step is optional but recommended when the scope of collaborator edits is unknown or when citations may have changed significantly.

## Prerequisites

1. **docstyle R package** installed in the project
2. **Existing _quarto.yml** with docstyle configuration (for re-harvest)
3. **Source Word document** in the project (usually in `source/` or `output/`)

## Workflow

### Step 1: Identify source and target files

Check project structure:

```bash
# Find the source docx (the one with edits to import)
ls -la source/*.docx output/*.docx

# Find existing QMD (will preserve its YAML header)
ls -la *.qmd
```

For POPCORN protocol example:
- **Source docx** (with edits): `source/POPCORN_scoping_protocol.docx`
- **Target qmd**: `POPCORN_scoping_protocol.qmd`
- **Sidecar dir**: `_docstyle/`

### Step 2: Run harvest with R

```r
library(docstyle)

# Basic harvest (preserves existing YAML header)
docx_to_qmd(
  docx_path = "source/POPCORN_scoping_protocol.docx",
  output_path = "POPCORN_scoping_protocol.qmd",
  sidecar_dir = "_docstyle",
  preserve_header = TRUE  # Keep existing YAML from QMD
)
```

**What happens:**
1. Existing QMD backed up as `*_old.qmd`
2. YAML header extracted and preserved
3. Citations extracted to `_docstyle/field-codes.json` and `_docstyle/references.json`
4. Comments extracted to `_docstyle/comments.json`
5. Track changes extracted to `_docstyle/revisions.json`
6. Content converted to markdown with `[@citekey]` syntax
7. `ADDIN DOCSTYLE` field codes detected → div placeholders restored, inline shortcodes restored
8. Version history table entries parsed back to YAML
9. Non-standard heading styles (e.g., `MDPI21heading1`) resolved to canonical headings via `outlineLvl` and `basedOn` chain before dispatch
10. Internal Word hyperlinks (`w:hyperlink w:anchor`) harvested as `[text](#target)` Markdown links
11. `bookmarkStart` elements immediately preceding a heading produce `{#name}` on the heading line (e.g., `# Introduction {#intro}`) for Quarto cross-references; `_docstyle_*`, `_Toc*`, `_Ref*`, and `_GoBack` bookmarks are filtered
12. Paragraph provenance map written to `_docstyle/harvest-map.json`

### Step 3: Validate harvest

Run validation to check fidelity against the source:

```r
result <- validate_harvest("source/POPCORN_scoping_protocol.docx",
                           "POPCORN_scoping_protocol.qmd")
```

Or pass `validate = TRUE` to `docx_to_qmd()` to run automatically.

See the **validate-harvest** skill for details on interpreting results.

### Step 4: Review changes

Compare harvested QMD with backup:

```bash
# Visual diff of content changes
diff POPCORN_scoping_protocol_old.qmd POPCORN_scoping_protocol.qmd | head -100

# Or use git diff if the old version was committed
git diff POPCORN_scoping_protocol.qmd
```

Check sidecar files for new data:

```bash
# New or updated citations
cat _docstyle/field-codes.json | jq '.citations | keys'

# Comments from collaborators
cat _docstyle/comments.json | jq '.[].content'

# Track changes
cat _docstyle/revisions.json | jq '.[].type, .[].content'
```

### Step 5: Verify round-trip

Run a full round-trip validation to establish a clean baseline:

```r
result <- validate_round_trip("source/POPCORN_scoping_protocol.docx",
                              "POPCORN_scoping_protocol.qmd")
```

This renders back to Word and validates the output (OOXML structure, comments, citations). If this passes, any future failures after QMD edits are attributable to the edits, not the pipeline.

For detail or to save a report:

```r
print(result, detail = "full")
report(result, file = "validation-report.md")
```

## Key functions

| Function | Purpose |
|----------|---------|
| `docx_to_qmd()` | Main harvest function - converts docx to qmd |
| `extract_citations()` | Extract Zotero field codes (called by docx_to_qmd) |
| `extract_comments()` | Extract Word comments |
| `extract_revisions()` | Extract track changes |
| `validate_harvest()` | Validate harvest fidelity |
| `validate_round_trip()` | Full round-trip validation |

## Sidecar files

After harvest, `_docstyle/` contains:

| File | Purpose |
|------|---------|
| `references.json` | CSL-JSON for Pandoc citation rendering |
| `field-codes.json` | Zotero metadata for round-trip (preserves original field codes) |
| `comments.json` | Comment metadata (author, date, content) |
| `revisions.json` | Track changes metadata |
| `harvest-map.json` | Paragraph-level source mapping (body index, plain-text hash, style, QMD line span); written unconditionally on every harvest |
| `reference.docx` | Generated from CSS (by pre-render hook) |

## QMD header template

A properly configured QMD header for a docstyle project:

```yaml
---
title: "Document Title"

# Current version summary
version-summary:
  date: "2025-12-11"
  version: "0.2.0"

# Version history entries (rendered as table by Lua filter)
version-history:
  - version: "0.1.0"
    date: "2025-01-01"
    description: "Initial draft"

status: draft

# DO NOT include: bibliography, csl, or format
# - Citations handled by Zotero field codes (not Pandoc)
# - Format set in _quarto.yml (docstyle-docx)
# - Authors/affiliations in _quarto.yml at top level (authors:/affiliations:)
---

::: version-history
:::

# First heading
```

## Options

### preserve_header (default: TRUE)

When TRUE, keeps the YAML front matter from the existing QMD file. This preserves:
- Version history entries
- Version summary
- Status and custom metadata

Set to FALSE only for initial import of a new document.

### extract_images (default: TRUE)

Extracts embedded images to `images/` subdirectory.

### validate_bib

Optional path to canonical BibTeX for citation validation.

## Troubleshooting

### Citations not converting

Check if Zotero field codes exist:

```bash
unzip -p source/document.docx word/document.xml | grep -o "ZOTERO_ITEM" | wc -l
```

If 0, the document may have been "unlinked" from Zotero.

### Comments not appearing

Verify comments.xml exists:

```bash
unzip -l source/document.docx | grep comments
```

### YAML header lost

Ensure `preserve_header = TRUE` and the target QMD existed before harvest.

### Headings appear as body text

The heading style has no `outlineLvl` attribute and no `basedOn` chain pointing to a standard heading. The resolver (`resolve_to_canonical()`) walks the `basedOn` chain first, then falls back to `outlineLvl`. If neither is set, the paragraph is treated as body text.

Inspect the style in the Word XML:

```bash
unzip -p source/document.docx word/styles.xml | xmllint --format - | grep -A20 'w:styleId="MDPI21heading1"'
```

Look for `<w:outlineLvl w:val="0"/>` (0 = heading 1) or `<w:basedOn w:val="Heading1"/>`.

### Heading has unexpected `{#id}` suffix

This is intentional — it comes from a Word bookmark (`bookmarkStart`) immediately before the heading and enables Quarto cross-references (`@sec-intro`). It is not an error. Bookmarks generated by Word's internal tools (`_Toc*`, `_Ref*`, `_GoBack`, `_docstyle_*`) are filtered automatically.

### Generated content converted to literal markdown

The source docx was rendered before v0.4.0 (no `ADDIN DOCSTYLE` field codes or `_docstyle_*` bookmarks). You need to:
1. Manually add div placeholders (`::: version-history :::`, etc.)
2. Re-render to get field codes in the output
3. Future harvests from that output will detect field codes automatically

## Example: POPCORN protocol harvest

```r
# In R console from reports/scoping-review-protocol/
library(docstyle)

# Harvest edited docx back to qmd
docx_to_qmd(
  "source/POPCORN_scoping_protocol.docx",
  "POPCORN_scoping_protocol.qmd",
  preserve_header = TRUE
)

# Check what changed
# (compare with _old.qmd backup)
```

Then render to verify:

```bash
quarto render POPCORN_scoping_protocol.qmd
```
