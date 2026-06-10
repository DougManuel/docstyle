---
name: init-project
description: Initialize a new project with docstyle for Word document generation. Use when setting up docstyle in a new Quarto project, creating the folder structure, or configuring _quarto.yml for docstyle output.
---

# Initialize docstyle Project

Set up a new Quarto project with docstyle extension for styled Word output.

## When to use

- Starting a new document project (manuscript, report, protocol)
- Adding docstyle to an existing Quarto project
- Setting up the required folder structure and configuration

## Quick setup

### 1. Install the extension

```bash
cd your-project
quarto add DougManuel/docstyle
```

This creates `_extensions/docstyle/` with the extension code.

### 2. Create project structure

Required files:

```
project/
├── _quarto.yml          # Project config
├── document.qmd         # Your document
├── styles.css           # Typography (optional)
├── _extensions/
│   └── docstyle/        # Extension (from quarto add)
└── output/              # Rendered output (gitignored)
```

### 3. Configure _quarto.yml

Minimal configuration:

```yaml
project:
  type: default
  output-dir: output
  pre-render: _extensions/docstyle/generate-reference.R

format:
  docstyle-docx:
    toc: false
    number-sections: false
```

With styling and layout:

```yaml
project:
  type: default
  output-dir: output
  pre-render: _extensions/docstyle/generate-reference.R

format:
  docstyle-docx:
    toc: false
    number-sections: false

docstyle:
  css:
    - styles.css

  # Page layout
  page:
    size: letter
    orientation: portrait
    margins:
      top: 1in
      bottom: 1in
      left: 1in
      right: 1in

  # Footer (optional)
  footer:
    enabled: true
    center: "Page {page} of {pages}"
    first-page: false  # Different first page

  # Header (optional)
  header:
    enabled: false
```

### 4. Create document QMD

Basic template:

```yaml
---
title: "Document Title"

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

## Introduction

Your content here...
```

**Author metadata** goes in `_quarto.yml` at the top level using standard Quarto `authors:` and `affiliations:` keys — not in the QMD, and not under `docstyle.authors` (deprecated). Add `::: author-plate :::` div to the QMD body where the author block should appear.

### 5. Create CSS (optional)

Basic typography:

```css
/* styles.css */
@page {
  size: letter;
  margin: 1in;
}

p, body {
  font-family: "Times New Roman", serif;
  font-size: 12pt;
  line-height: 1.5;
}

.title {
  font-family: "Times New Roman", serif;
  font-size: 14pt;
  font-weight: bold;
}

h1, h2, h3 {
  font-family: "Times New Roman", serif;
  font-size: 12pt;
  font-weight: bold;
}
```

### 6. Add .gitignore entries

```gitignore
# docstyle outputs
output/
_docstyle/reference.docx
_docstyle/reference.docx.hash

# Temporary files
~$*.docx
```

### 7. Render and validate

```bash
quarto render document.qmd
```

```r
library(docstyle)
validate_docx("output/document.docx")
```

## Project templates

### Conference abstract

```yaml
# _quarto.yml
project:
  type: default
  output-dir: output
  pre-render: _extensions/docstyle/generate-reference.R

format:
  docstyle-docx:
    toc: false
    number-sections: false

docstyle:
  css:
    - abstract.css
  header:
    enabled: false
  footer:
    enabled: false
```

### Manuscript with citations

Citations are handled by Zotero field codes in Word, not by Quarto/Pandoc. Do not add `bibliography:` or `csl:` to `_quarto.yml` or the QMD.

```yaml
# _quarto.yml
project:
  type: default
  output-dir: output
  pre-render: _extensions/docstyle/generate-reference.R
  post-render: _extensions/docstyle/update-field-codes.R

format:
  docstyle-docx:
    toc: false
    number-sections: true

docstyle:
  css:
    - manuscript.css
  footer:
    enabled: true
    right: "Page {page}"
```

### Report with TOC

```yaml
# _quarto.yml
project:
  type: default
  output-dir: output
  pre-render: _extensions/docstyle/generate-reference.R

format:
  docstyle-docx:
    toc: false  # Using docstyle TOC instead
    number-sections: true

docstyle:
  css:
    - report.css
  toc:
    title: "Table of Contents"
    title-level: 1
    levels: "1-3"
    page-numbers: true
  footer:
    enabled: true
    center: "Page {page} of {pages}"
```

## Checklist

- [ ] Extension installed (`_extensions/docstyle/` exists)
- [ ] `_quarto.yml` configured with `docstyle-docx` format
- [ ] `pre-render` and `post-render` script paths correct
- [ ] CSS file linked (if using custom styles)
- [ ] Author metadata in `_quarto.yml` at top level under `authors:` / `affiliations:` (not in QMD, not under `docstyle.authors`)
- [ ] `::: author-plate :::` in document body (if using authors)
- [ ] `::: version-history :::` in document body (if using version history)
- [ ] QMD does NOT contain `format:`, `bibliography:`, or `csl:` fields
- [ ] `output/` directory gitignored
- [ ] Test render works: `quarto render document.qmd`

## Dual-format output (optional)

To also produce PDF output via the Typst preprint template, add `docstyle-typst:` alongside `docstyle-docx:` in `_quarto.yml`:

```yaml
format:
  docstyle-docx:
    toc: false
    number-sections: false
  docstyle-typst:
    running-head: "Short title"
    bibliography: references.bib
    csl: vancouver.csl
    citeproc: true
```

The same top-level `authors:` / `affiliations:` block serves both formats. Typst-specific fields (`running-head`, `bibliography`, `csl`, `citeproc`) only apply to the PDF output.
