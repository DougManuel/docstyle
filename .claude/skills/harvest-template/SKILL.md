---
name: harvest-template
description: Extract styles and content from existing Word documents to create CSS and QMD templates. Use when reverse-engineering a Word template, extracting formatting from a reference document, or migrating an existing Word document to docstyle workflow.
---

# Harvest Template from Word Document

Extract styles, formatting, and content from existing Word documents to bootstrap docstyle projects.

## When to use

- Reverse-engineering a journal or conference template
- Migrating an existing Word document to QMD source
- Extracting font, colour, and spacing specifications from a reference doc
- Creating CSS from an organisation's Word template

## Workflow

### 1. Inspect the Word document structure

Unpack and explore the XML:

```bash
# Unpack document
unzip -q "source-document.docx" -d /tmp/docx_harvest

# View styles defined in document
xmllint --format /tmp/docx_harvest/word/styles.xml | head -200

# View document content structure
xmllint --format /tmp/docx_harvest/word/document.xml | head -100

# List all style names
xmllint --format /tmp/docx_harvest/word/styles.xml | grep -oP 'w:name w:val="\K[^"]+'
```

### Note on journal templates (MDPI, Elsevier, etc.)

Harvesting from journal-formatted documents now works automatically. Non-standard heading style names (e.g., `MDPI21heading1`, `ElsevierHeading1`) are resolved to standard headings via `resolve_to_canonical()`, which walks the `basedOn` chain and checks `outlineLvl`. No manual style mapping is needed.

### 2. Extract content to QMD

Use `docx_to_qmd()` to convert content:

```r
library(docstyle)

result <- docx_to_qmd(
  "source-document.docx",
  "output/harvested.qmd"
)

# Inspect extracted metadata
result$metadata
result$citations
```

### 3. Extract style specifications

Key XML paths for style extraction:

| Property | XML location |
|----------|--------------|
| Font family | `//w:rFonts/@w:ascii` |
| Font size | `//w:sz/@w:val` (half-points) |
| Bold | `//w:b` |
| Italic | `//w:i` |
| Colour | `//w:color/@w:val` |
| Spacing after | `//w:spacing/@w:after` (twips) |
| Line height | `//w:spacing/@w:line` (twips) |

### 4. Convert to CSS

Map extracted values to CSS:

```css
/* Example: extracted from Word template */
.title {
  font-family: "Libre Baskerville", serif;
  font-size: 14pt;  /* Word sz=28 half-points */
  font-weight: bold;
}

p {
  font-family: "Hanken Grotesk", sans-serif;
  font-size: 11pt;
  line-height: 1.15;
}
```

### 5. Extract page layout

Check `word/document.xml` for section properties:

```bash
# Page size and margins
xmllint --format /tmp/docx_harvest/word/document.xml | grep -A20 "w:sectPr"
```

Convert twips to inches: `twips / 1440 = inches`

### 6. Validate round-trip

Render with extracted styles and compare:

```bash
quarto render output/harvested.qmd
```

```r
validate_docx("output/harvested.docx", expected = list(
  title_font = "Libre Baskerville",
  body_font = "Hanken Grotesk"
))
```

## Key R functions

| Function | Purpose |
|----------|---------|
| `docx_to_qmd()` | Convert Word content to QMD with formatting |
| `extract_citations()` | Extract Zotero field codes from Word |
| `import_docx()` | Full import with citation and comment extraction |
| `list_styles()` | List all styles in a Word document |

## Common extraction tasks

### Fonts
```bash
xmllint --format /tmp/docx_harvest/word/styles.xml | grep -B2 -A10 'w:name w:val="Normal"'
```

### Colours
```bash
xmllint --format /tmp/docx_harvest/word/styles.xml | grep "w:color"
```

### Headers/footers
```bash
ls /tmp/docx_harvest/word/header*.xml /tmp/docx_harvest/word/footer*.xml 2>/dev/null
xmllint --format /tmp/docx_harvest/word/footer1.xml
```

## Output

Place harvested files in `output/` (gitignored):
- `output/harvested.qmd` - Converted content
- `output/harvested-styles.css` - Extracted CSS (manual)
- `output/harvested-layout.yml` - Page layout config (manual)
