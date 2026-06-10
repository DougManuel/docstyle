# docstyle

Style-as-code for scientific publishing. A Quarto extension and R package that generates styled Word documents from CSS + YAML configuration, with round-trip support for Zotero citations, comments, and track changes.

## Get started in 1 minute

```r
remotes::install_github("DougManuel/docstyle")
docstyle::init()                        # creates _quarto.yml, styles.css, bootstrap scripts
quarto::quarto_render("document.qmd")   # styled Word output
```

Or start from a template: `quarto use template DougManuel/docstyle-starter`

## Quick start

### Option A: One-command setup (recommended)

```r
# Install the R package
remotes::install_github("DougManuel/docstyle")

# Initialize your project (creates extension, _quarto.yml, and starter CSS)
docstyle::init()

# Render
quarto::quarto_render("document.qmd")
```

Available presets: `"default"`, `"formal"`, `"academic"`

```r
docstyle::init(preset = "formal")     # Reports, proposals, coloured headings
docstyle::init(preset = "academic")   # Double-spaced manuscript, Times New Roman
```

### Option B: Template starter

```bash
quarto use template DougManuel/docstyle-starter
```

Then install the R package:

```r
remotes::install_github("DougManuel/docstyle")
```

### Option C: Manual setup

#### Step 1: Install the extension

```bash
cd your-project
quarto add DougManuel/docstyle
```

#### Step 2: Install the R package (required)

```r
remotes::install_github("DougManuel/docstyle")
```

#### Step 3: Create `_quarto.yml`

```yaml
project:
  type: default
  pre-render: _docstyle/pre-render.R
  post-render: _docstyle/post-render.R

format:
  docstyle-docx:
    toc: false
    number-sections: false

docstyle:
  css: styles.css

  footer:
    enabled: true
    left: "My Document"
    right: "Page {page} of {pages}"
    first-page: false
    style: footer
```

#### Step 4: Create `styles.css`

```css
@page {
  size: letter;
  margin: 1in;
}

body {
  font-family: "Times New Roman", serif;
  font-size: 12pt;
  line-height: 1.5;
}

h1 {
  font-family: "Arial", sans-serif;
  font-size: 14pt;
  font-weight: bold;
}

h2 {
  font-family: "Arial", sans-serif;
  font-size: 12pt;
  font-weight: bold;
}

.footer {
  font-family: "Arial", sans-serif;
  font-size: 9pt;
}
```

#### Step 5: Render

```bash
quarto render document.qmd
```

Your Word document uses styles from CSS, with page layout and footers configured in YAML.

## Why docstyle?

Microsoft Word's `reference.docx` templates are fragile and hard to version control. docstyle lets you:

- **Define styles in CSS** — familiar syntax, easy to diff and review
- **Configure page layout in CSS** — use standard `@page` rules for margins, size, orientation
- **Generate reference.docx automatically** — no manual Word template editing

## Project structure

After `docstyle::init()`, your project looks like:

```
my-project/
├── _quarto.yml              # project configuration
├── styles.css               # your styles (fonts, margins, colours)
├── document.qmd             # your content
├── .gitignore               # keeps generated files out of git
├── _docstyle/               # committed bootstrap + sidecar data
│   ├── pre-render.R         # auto-installs extension before render
│   └── post-render.R        # finalizes document after render
└── _extensions/             # auto-restored on render (gitignored)
```

The `_extensions/` directory is auto-restored from the R package on each render — no need to commit it.

## Two workflows

### Workflow 1: QMD → Word (most users)

Write in Quarto, render to styled Word:

```
your-document.qmd → quarto render → styled.docx
```

This is the primary use case. See the [getting started tutorial](https://dougmanuel.github.io/docstyle/articles/tutorial-getting-started.html).

### Workflow 2: Word ↔ QMD round-trip (advanced)

Collaborate with Word users while preserving Zotero citations:

```
colleague.docx → import_docx() → edit.qmd → quarto render → back-to-colleague.docx
```

This preserves live Zotero citations through the round-trip. See the [round-trip guide](https://dougmanuel.github.io/docstyle/articles/how-to-roundtrip.html).

## Features

| Feature | Status |
|---------|--------|
| CSS → Word styles | ✅ |
| Page margins, size, orientation | ✅ |
| Table styling (CSS classes) | ✅ |
| Section breaks (landscape tables) | ✅ |
| Line numbers | ✅ |
| Headers and footers | ✅ |
| Zotero citation round-trip | ✅ |
| Import Word → QMD | ✅ |
| Comments and track changes | ✅ |

## Installation

Both the Quarto extension and R package are required:

```r
# Install the R package (handles extension installation automatically)
remotes::install_github("DougManuel/docstyle")

# Initialize your project
docstyle::init()
```

Or install the extension separately:

```bash
quarto add DougManuel/docstyle
```

For subdirectory projects and private repositories, see the [troubleshooting guide](https://dougmanuel.github.io/docstyle/articles/troubleshooting.html).

## Configuration reference

> [!WARNING]
> **Where a setting goes matters.** Keys read by the pre-render R script (`css:`, `page:`, `header:`, `footer:`, `sections:`) belong in `_quarto.yml` under `docstyle:`. Keys read by Lua filters at render time (`author-plate:`, `authors:`, `affiliations:`, `version-history:`) must go in the QMD front matter. Quarto does not pass project-level `docstyle:` metadata through to Lua filters, so filter settings placed in `_quarto.yml` are silently ignored. The [troubleshooting guide](https://dougmanuel.github.io/docstyle/articles/troubleshooting.html) has the full table.

### Page layout (CSS)

Page layout is configured via CSS `@page` rules:

```css
/* styles.css */
@page {
  size: letter;              /* letter | a4 | legal */
  margin: 1in;               /* or individual: margin-top, margin-right, etc. */

  /* Optional: line numbers for manuscript review */
  --docstyle-line-numbers: every 1;        /* every N | none */
  --docstyle-line-numbers-restart: page;   /* page | section | continuous */
  --docstyle-line-numbers-distance: 0.25in;

  /* Optional: suppress top spacing on first paragraph after section break */
  --docstyle-suppress-top-spacing: true;   /* true | false */
}

/* Optional: different settings for first page */
@page :first {
  --docstyle-line-numbers: none;
}

/* Named page style for landscape sections */
@page landscape {
  size: letter landscape;
  margin: 0.5in;
}
```

Use named page styles in your document with `::: {.section-*}` divs. The class name uses the `section-` prefix followed by the `@page` rule name.

#### Line numbers for manuscript review

Define a named `@page body` rule with line numbers, then use a section div with explicit attributes:

```css
/* styles.css */
@page {
  size: letter;
  margin: 1in;
  --docstyle-line-numbers: none;       /* No line numbers on title/abstract */
}

@page body {
  size: letter;
  margin: 1in;
  --docstyle-line-numbers: every 1;
  --docstyle-line-numbers-restart: continuous;
  --docstyle-line-numbers-distance: 0.25in;
}
```

```markdown
# Abstract

Abstract text here (no line numbers)...

::: {.section-body page-break="true" line-numbers="continuous"}
:::

## Introduction

Body text here (starts on new page, with line numbers)...

## Methods

More body text...
```

The section div supports these attributes:

| Attribute | Values | Description |
|-----------|--------|-------------|
| `page-break` | `"true"` | Start section on a new page |
| `line-numbers` | `"page"`, `"section"`, `"continuous"`, `"false"` | Line number restart behaviour |
| `suppress-top-spacing` | `"true"`, `"false"` | Suppress top margin on the first paragraph after the section break (overrides CSS `@page` setting) |

Attributes on the div override CSS defaults and survive harvest round-trips. The CSS `@page` rules provide fallback defaults when attributes are not specified.

#### Landscape sections

```markdown
## Regular content here...

{{< pagebreak >}}

::: section-landscape
:::

### Wide table (now in landscape)

| Col A | Col B | Col C | Col D | Col E |
|-------|-------|-------|-------|-------|
| data  | data  | data  | data  | data  |

{{< pagebreak >}}

::: section-default
:::

## Back to portrait
```

### Table styling

Tables are styled with CSS classes. Define table styles in your CSS file and apply them with fenced divs in your QMD.

#### CSS

```css
/* Grid style — borders on all cells */
.table-grid {
  font-size: 9pt;
}
.table-grid th, .table-grid td {
  border: 0.5pt solid #000000;
}
.table-grid th {
  background-color: #f0f0f0;
  font-weight: bold;
}

/* Formal style — top/bottom borders only (APA-like) */
.table-formal {
  font-size: 9pt;
  border-top: 1pt solid #000000;
  border-bottom: 1pt solid #000000;
}
.table-formal th {
  border-bottom: 0.5pt solid #000000;
  font-weight: bold;
}
```

#### QMD usage

```markdown
::: {.table-formal widths="30,70"}
| Variable | Description |
|----------|-------------|
| Age      | Years       |
| Sex      | M/F         |
:::
```

Per-table attributes:

| Attribute | Example | Description |
|-----------|---------|-------------|
| `widths` | `"30,70"` | Column width percentages |
| `font-size` | `"9"` | Font size in points |
| `header-bold` | `"false"` | Disable bold headers |

Table styles survive round-trip — the div and its attributes are restored when harvesting back from Word.

### Complete `_quarto.yml` reference

```yaml
# =============================================================================
# Project settings
# =============================================================================
project:
  type: default
  output-dir: output
  pre-render: _docstyle/pre-render.R    # Bootstrap: auto-installs extension
  post-render: _docstyle/post-render.R  # Injects Zotero field codes, finalizes sections

# =============================================================================
# Output format
# =============================================================================
format:
  docstyle-docx:
    toc: false                    # Use docstyle TOC filter instead (see below)
    number-sections: false

execute:
  echo: false
  warning: false

# =============================================================================
# docstyle configuration
# =============================================================================
docstyle:
  # CSS files - can be single file or array for layered styles
  css:
    - base-styles.css           # Base typography
    - project-overrides.css     # Project-specific overrides

  # Round-trip workflow metadata (optional)
  source-docx: "source/original.docx"
  imported: "2025-01-15"
  sidecar-dir: _docstyle

  # -----------------------------------------------------------------------------
  # Header (top of page)
  # -----------------------------------------------------------------------------
  header:
    enabled: true
    left: "Author - Short Title"
    first-page: false             # No header on title page
    style: header                 # CSS class

  # -----------------------------------------------------------------------------
  # Footer (bottom of page)
  # -----------------------------------------------------------------------------
  footer:
    enabled: true
    left: "Document Title"
    right: "Page {page} of {pages}"
    first-page: false             # No footer on title page
    style: footer                 # CSS class

  # -----------------------------------------------------------------------------
  # Table of contents (replaces ::: toc ::: div)
  # -----------------------------------------------------------------------------
  toc:
    title: "Table of contents"
    title-level: 1                # Heading level for TOC title
    levels: "1-2"                 # Include Heading1 and Heading2
    page-numbers: true
    hyperlinks: true
    tab-leader: none              # none | dots | underline

  # -----------------------------------------------------------------------------
  # Author plate (replaces ::: author-plate ::: div)
  # -----------------------------------------------------------------------------
  author-plate:
    corresponding-marker: "*"
    equal-marker: "†"
    show-orcid: false
    show-email: true

  # -----------------------------------------------------------------------------
  # Version history table (replaces ::: version-history ::: div)
  # -----------------------------------------------------------------------------
  version-history:
    title: "Version history"
    title-level: 1
    widths: "15,65,20"            # Column percentages
    style: "table-grid"           # table-grid | table-formal

# =============================================================================
# Author metadata (standard Quarto format)
# =============================================================================
author:
  - name:
      given: "Jane"
      family: "Smith"
    orcid: "0000-0000-0000-0000"
    email: "jane@example.com"
    corresponding: true
    affiliations:
      - ref: inst1
  - name:
      given: "John"
      family: "Doe"
    affiliations:
      - ref: inst2
    equal-contributor: true

affiliations:
  - id: inst1
    name: "University of Example"
    department: "Department of Research"
    city: "Ottawa"
    region: "Ontario"
    country: "Canada"
  - id: inst2
    name: "Research Institute"
    city: "Toronto"
    country: "Canada"
```

### QMD body placeholders

Use these fenced divs in your QMD to insert dynamic content:

```markdown
---
title: "My Document"
abstract: |
  Background, methods, and findings in brief.
version-history:
  - version: "1.0"
    date: "2025-01-15"
    description: "Initial release"
---

::: toc
:::

::: author-plate
:::

::: docstyle-abstract
:::

## Introduction

Document content here...

::: version-history
:::
```

The Lua filters replace these placeholders with formatted content based on your `_quarto.yml` configuration.

`::: docstyle-abstract :::` positions the abstract (from the `abstract:` front-matter key) at that point in the document — typically below the author plate, matching the order the PDF/Typst output produces. It applies to **`docstyle-docx` only**: Word would otherwise place the abstract at the very top. Without the div the abstract stays at the top; Typst and JATS render `abstract:` natively in their own title areas regardless.

## Documentation

- [Getting started](https://dougmanuel.github.io/docstyle/articles/tutorial-getting-started.html) — Tutorial
- [CSS to Word](https://dougmanuel.github.io/docstyle/articles/css-to-word.html) — How CSS maps to Word styles
- [Round-trip workflow](https://dougmanuel.github.io/docstyle/articles/how-to-roundtrip.html) — Word ↔ QMD collaboration
- [Troubleshooting](https://dougmanuel.github.io/docstyle/articles/troubleshooting.html) — Common issues and solutions
- [API reference](https://dougmanuel.github.io/docstyle/reference/index.html) — R function documentation

## Requirements

- [Quarto](https://quarto.org/) >= 1.4
- [R](https://www.r-project.org/) >= 4.2.0
- R packages: `xml2`, `officer`, `jsonlite`, `yaml` (installed automatically as dependencies)

## Status and philosophy

docstyle is a working research tool, built and maintained by one person to support our group's publishing workflow. It is shared in that spirit: use it, learn from it, borrow from it, but read this section before depending on it.

### The ideas it explores

Two design decisions carry the project, and both deserve more attention than current tools give them.

**CSS as the single source of truth for document styling.** Word's `reference.docx` templates are opaque binaries that drift, break, and resist version control. A stylesheet is diffable text, and most researchers already know some CSS. docstyle generates the Word template from CSS on every render; the template is never the authority. The same stylesheet and YAML drive Word, PDF (Typst), and JATS output, and the results compare well with what journal templates and default Pandoc output produce.

**Word field codes as an extensible metadata layer.** docstyle wraps the content it generates (sections, tables, author plates, abstracts) in `ADDIN DOCSTYLE` field codes carrying JSON payloads. Word ignores them; docstyle reads them back when importing the document. The same mechanism keeps Zotero citations live through the round trip. This layer could carry much more than it does today: structured author contributions, data availability statements, review provenance.

### What to expect

- The QMD to Word and QMD to PDF rendering paths are stable and used in production for multi-author protocols and preprints.
- The Word to QMD import direction works well on documents docstyle produced. Arbitrary Word documents from journals and collaborators are an open world; expect edge cases, and check imported output with `validate_harvest()`.
- One maintainer, no release schedule, and no CRAN submission planned. docstyle is more than an R package (it bundles a Quarto extension, Lua filters, and a Typst template), and it moves faster than CRAN's cadence suits.
- The API may change before v1.0.
- Issues, ideas, and critical questions are welcome. So is patience.

### Open questions

These are the directions still being worked out. Opinions are welcome in the issue tracker.

- How far should the field-code metadata layer go before it becomes a private format rather than an annotation on standard OOXML?
- Should the Zotero citation layer become its own package? It is the most reusable piece and the most CRAN-shaped.
- What is an honest round-trip guarantee for the import direction? The current answer is layered validation with an expected-loss registry, which reports what was lost rather than promising nothing is.

## Licence

MIT
