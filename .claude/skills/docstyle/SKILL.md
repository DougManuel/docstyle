# docstyle — CSS-styled Word documents from Quarto

Generate professionally styled Word documents from Quarto markdown using CSS for typography and YAML for configuration. Supports Zotero citation round-trip, comments, track changes, tables, headers/footers, and section breaks.

## Quick start

```r
# Install
remotes::install_github("DougManuel/docstyle")

# Initialize a project (creates _quarto.yml, styles.css, bootstrap scripts)
docstyle::init()

# Render
quarto::quarto_render("document.qmd")
```

Available presets: `"default"` (Arial 11pt), `"formal"` (reports, TOC), `"academic"` (Times 12pt, double-spaced)

```r
docstyle::init(preset = "formal")
```

## Project structure

After `docstyle::init()`:

```
my-project/
├── _quarto.yml          # project config (format, docstyle settings)
├── styles.css           # CSS for fonts, margins, colours
├── document.qmd         # your content
├── .gitignore           # generated — gitignores _extensions/, .quarto/, etc.
├── _docstyle/           # committed bootstrap + sidecar data
│   ├── pre-render.R     # auto-installs extension before render
│   ├── post-render.R    # finalizes document after render
│   └── (field-codes.json, comments.json, etc.)  # sidecar data
└── _extensions/         # auto-restored from R package (gitignored)
```

## Configuration

### _quarto.yml — essential settings

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

  header:
    enabled: true
    left: "Author - Title"
    first-page: false
    style: header

  footer:
    enabled: true
    left: "Document Title"
    right: "Page {page} of {pages}"
    first-page: false
    style: footer

  toc:
    title: "Table of contents"
    levels: "1-3"
    page-numbers: true
    tab-leader: dots

  version-history:
    title: "Version history"
    widths: "15,65,20"
    style: "table-grid"

  author-plate:
    show-email: true
    corresponding-marker: "*"
```

### Author metadata (standard Quarto format)

Author information goes at the top level of `_quarto.yml` using standard Quarto schema:

```yaml
author:
  - name:
      given: "Jane"
      family: "Smith"
    email: "jane@example.com"
    corresponding: true
    affiliations:
      - ref: inst1

affiliations:
  - id: inst1
    name: "University of Ottawa"
    department: "Department of Medicine"
```

**Do NOT use `docstyle.authors`** — this is deprecated.

### Multi-format output (docstyle-typst)

The `docstyle-typst` format produces PDF output via a bundled Typst/preprint template. Both `docstyle-docx` and `docstyle-typst` can be listed under `format:` in `_quarto.yml`. A single `authors:`/`affiliations:` block at the top level serves both formats.

```yaml
# _quarto.yml — dual-format configuration
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

**Typst-specific fields** (`running-head`, `bibliography`, `csl`, `citeproc`) apply only to the Typst format. For `docstyle-docx`, citations are still handled by Zotero field codes — do not add `bibliography:` or `csl:` to the `docstyle-docx` block or the QMD header.

Render both formats:

```bash
quarto render document.qmd            # renders both if both listed in _quarto.yml
quarto render document.qmd --to docstyle-typst   # Typst/PDF only
quarto render document.qmd --to docstyle-docx    # Word only
```

### CSS — what maps to Word

```css
@page {
  size: letter;           /* letter | a4 | legal */
  margin: 1in;            /* or individual sides */
  /* Line numbers */
  --docstyle-line-numbers: every 1;
  --docstyle-line-numbers-restart: page;  /* page | section | continuous */
  /* Suppress top margin gap on first paragraph after section breaks */
  --docstyle-suppress-top-spacing: true;  /* true | false */
}

body {
  font-family: "Times New Roman", serif;
  font-size: 12pt;
  line-height: 1.5;       /* 1.0 = single, 2.0 = double */
}

h1 { font-size: 16pt; font-weight: bold; }
h2 { font-size: 14pt; font-weight: bold; }

.footer { font-family: "Arial"; font-size: 9pt; }
.header { font-family: "Arial"; font-size: 9pt; }
```

**CSS cascade for body text:** CSS on `p` / `body` (mapped to Word's Normal style) automatically cascades to BodyText, FirstParagraph, Compact, headings, and other child styles. You only need explicit selectors when overriding the parent:

```css
p { margin-bottom: 6pt; }                   /* sets Normal; cascades to all children */
.compact { margin-bottom: 2pt; }            /* override for tight lists only */
.first-paragraph { text-indent: 0; }        /* override for first paragraph after heading */
.bibliography { text-indent: -0.5in; padding-left: 0.5in; }  /* hanging indent */
```

All available selectors: `p`/`body`, `h1`–`h9`, `.title`, `.subtitle`, `.author`, `.date`, `.abstract`, `.abstract-title`, `.body-text`, `.first-paragraph`, `.compact`, `blockquote`, `caption`/`.caption`, `.table-caption`, `.image-caption`, `.bibliography`/`.references`, `.figure`, `.captioned-figure`, `dt`/`.definition-term`, `dd`/`.definition`, `.footnote-text`, `.footer`, `.header`, `.toc-heading`, `.toc-1` through `.toc-5`.

### QMD body placeholders

Insert these fenced divs where you want dynamic content:

```markdown
::: toc
:::

::: author-plate
:::

::: version-history
:::
```

Each requires corresponding config in `_quarto.yml`.

### Table styling

Define table CSS classes, then wrap markdown tables:

```css
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

```markdown
::: {.table-formal widths="30,70"}
| Variable | Description |
|----------|-------------|
| Age      | Years       |
:::
```

Per-table attributes: `widths` (column percentages), `font-size` (points), `header-bold` (true/false).

### Section breaks

```css
@page landscape {
  size: letter landscape;
  margin: 0.5in;
}
```

```markdown
::: section-landscape
:::

Wide table here...

::: section-default
:::
```

Attributes on section divs: `page-break="true"`, `line-numbers="continuous"`, `suppress-top-spacing="true"`.

## Troubleshooting

### Render fails completely

1. **Check R package installed:** `library(docstyle)` — if not found, run `remotes::install_github("DougManuel/docstyle")`
2. **Check bootstrap scripts exist:** `_docstyle/pre-render.R` and `_docstyle/post-render.R` must exist. If missing, run `docstyle::init(overwrite = TRUE)`
3. **Check _quarto.yml format:** Must use `docstyle-docx` not `docx`:
   ```yaml
   format:
     docstyle-docx:    # correct
   ```
4. **Check CSS file exists:** The file referenced by `docstyle.css` must exist
5. **Delete and regenerate:** `rm -rf _extensions/ _docstyle/reference.docx .quarto/` then re-render

### Wrong fonts or styles

1. **Is a static reference.docx overriding?** Remove any `reference-doc:` from QMD YAML header — docstyle generates reference.docx dynamically from CSS
2. **Is CSS being read?** Check for `[generate-reference]` messages in render output
3. **Are fonts installed?** The fonts in your CSS must be installed on your system
4. **Force regeneration:** Delete `_docstyle/reference.docx.hash` and re-render

### Missing TOC / author plate / version history

1. **Check the div placeholder exists** in your QMD body: `::: toc :::`, `::: author-plate :::`, `::: version-history :::`
2. **Check configuration** in `_quarto.yml` under `docstyle.toc`, `docstyle.author-plate`, or `docstyle.version-history`
3. **For version history:** Entries go in the QMD front matter:
   ```yaml
   version-history:
     - version: "1.0"
       date: "2025-01-15"
       description: "Initial release"
   ```

### Footer/header missing

1. **Check enabled:** `docstyle.footer.enabled: true` in `_quarto.yml`
2. **Check first-page:** If `first-page: false`, footer won't appear on page 1
3. **Check CSS:** `.footer` class must exist in your CSS file

### Tables unstyled

1. **Wrap in a div:** Tables must be inside `::: {.table-formal} ... :::` or `::: {.table-grid} ... :::`
2. **Check CSS:** `.table-formal` or `.table-grid` class must be defined in your CSS
3. **Check div closure:** The closing `:::` must be on its own line

### Zotero citations not working

1. **Do NOT add `bibliography:` or `csl:` to QMD** — this causes Pandoc to resolve citations, duplicating them. Citations are handled by Zotero field codes in Word.
2. **Check field-codes.json:** Must exist in `_docstyle/` (created by harvest or manually)
3. **Check ZOTERO_PREF injection:** Look for `[inject-zotero]` in render output

### Section breaks wrong

1. **Named page styles:** CSS `@page landscape { ... }` matches `::: section-landscape :::`
2. **Page breaks:** Add `page-break="true"` attribute to the section div
3. **Line numbers:** Use `line-numbers="continuous"` on the section div, not just CSS

## Known limitations (not bugs)

These are inherent to the architecture and will not be "fixed":

- **Pandoc splits text across runs:** Search-and-replace in rendered DOCX may find text split across `<w:r>` elements. This is normal Word/Pandoc behaviour.
- **Cached field values:** PAGE, NUMPAGES show `#` until the document is opened in Word and fields are updated. This is by design (forces field update on open).
- **Table content in revisions:** Pandoc drops tracked changes inside table cells. This is a Pandoc limitation.
- **Comments on metadata:** Comments attached to title, author, or other metadata paragraphs are lost during harvest. These are structural elements, not content.
- **Round-trip is lossy for formatting-only changes:** Paragraph-level formatting revisions (spacing, numbering changes) are classified as expected loss.

## Sharing citations across projects

`import_citations()` copies citation entries between `field-codes.json` files without touching other fields in the destination:

```r
docstyle::import_citations(
  source = "../other-project/_docstyle",
  dest   = "_docstyle",
  citekeys  = c("smith2023", "jones2024"),  # omit to copy all
  overwrite = FALSE
)
```

Only the `citations` list is merged — metadata, preferences, and other keys in the destination file are preserved.

## When to file a bug

If you encounter unexpected behaviour that isn't listed above:

1. **Create a minimal reproduction:** Strip your document down to the smallest QMD that demonstrates the problem
2. **Include your configuration:** `_quarto.yml` and `styles.css`
3. **Include the error output:** Full render output with `DOCSTYLE_DEBUG=1 quarto render document.qmd`
4. **Check existing issues:** https://github.com/DougManuel/docstyle/issues
5. **File an issue** with the reproduction files and output at the link above

## Round-trip workflow (advanced)

For collaborating with Word users while preserving Zotero citations:

```
source.docx → docx_to_qmd() → edit.qmd → quarto render → back.docx
```

```r
# Import Word document
docstyle::docx_to_qmd("source/document.docx", output = "document.qmd")

# This creates sidecar files in _docstyle/:
#   field-codes.json  — Zotero citations
#   comments.json     — threaded comments
#   revisions.json    — track changes

# Edit the QMD, then render back to Word
quarto::quarto_render("document.qmd")
# Sidecar data is automatically injected into the output
```

Validate the round-trip:

```r
docstyle::validate_harvest("source/document.docx", "document.qmd")
```

## Architecture overview

docstyle uses a three-phase pipeline:

1. **Pre-render (R):** Parses CSS, builds `reference.docx` from a minimal OOXML template with 38 empty styles, injects CSS properties, and cascades them to child styles. Caches by hash — only regenerates when CSS or templates change.

2. **Pandoc + Lua filters:** Converts QMD to DOCX using the reference template. 12 Lua filters handle TOC, tables, sections, author plate, character styles, comments, revisions, and Zotero citation markers.

3. **Post-render (R):** Opens the rendered DOCX and injects Zotero field codes, comments, section breaks, headers/footers. Validates structure.

CSS is the single source of truth for all styling. The Lua filters emit text markers (not complex XML) that R assembles in post-render.
