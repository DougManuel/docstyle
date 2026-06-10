---
name: render-document
description: Render QMD documents to Word using docstyle. Use when asked to render, build, or generate Word documents from Quarto/QMD files, or when troubleshooting document styling issues.
allowed-tools: Bash(quarto:*), Bash(unzip:*), Bash(xmllint:*), Read, Glob, Grep
---

# Render document with docstyle

Render Quarto documents to styled Word output using the docstyle extension.

## Critical workflow rules

### Citations are handled by Zotero in Word, not by Quarto/Pandoc

Do NOT add `bibliography:` or `csl:` fields to the QMD header. Citations in docstyle projects follow this flow:

1. **Harvest** extracts Zotero field codes from the source docx → `_docstyle/field-codes.json`
2. **Render** produces the docx with `[@citekey]` placeholders
3. **Post-render hook** injects `ZOTERO_PREF` into the output docx
4. **Zotero in Word** resolves the live field codes when the document is opened

Adding `bibliography:` would cause Pandoc to resolve citations at render time, duplicating them and breaking the Zotero field code workflow.

### Format is set in `_quarto.yml`, not the QMD

The QMD must NOT contain `format: docx` or any format key. The project-level `_quarto.yml` defines `format: docstyle-docx`, which activates the extension's Lua filters. If the QMD overrides this, filters won't run.

### What goes where

| Setting | Location | Why |
|---------|----------|-----|
| `format: docstyle-docx` | `_quarto.yml` | Activates extension filters |
| `authors:`, `affiliations:` (top-level) | `_quarto.yml` | Shared across documents; read by author-plate Lua filter. Do NOT use `docstyle.authors` (deprecated) |
| `docstyle.toc`, `docstyle.footer`, etc. | `_quarto.yml` | Project-level layout config |
| `docstyle.version-history` (config) | `_quarto.yml` | Table format settings (widths, style, title) |
| `title` | QMD header | Document-specific |
| `version-history` (entries) | QMD header | Document-specific version log |
| `version-summary` | QMD header | Current version/date display |
| `status` | QMD header | Document status (draft, final) |

### Generated content div placeholders

Lua filters replace these fenced divs with OOXML during render:

```markdown
::: version-history
:::

::: author-plate
:::

::: toc
:::
```

Only include divs for features the document uses. Each div requires corresponding config in `_quarto.yml` (e.g., `docstyle.toc` for `::: toc :::`).

Since v0.4.0, rendered OOXML is wrapped in `ADDIN DOCSTYLE` field codes carrying JSON metadata payloads, so harvest can restore div placeholders and inline shortcodes during round-trip. Documents rendered with v0.3.1 bookmarks are still supported as a fallback.

## Workflow

### 1. Render the document

```bash
quarto render <document.qmd>
```

Output goes to `output/` directory (gitignored).

The render pipeline:
1. **Pre-render**: `generate-reference.R` builds `reference.docx` from CSS using a minimal OOXML template (38 empty styles). CSS properties are injected into styles, then cascaded to child styles so Pandoc preserves them.
2. **Pandoc + Lua filters**: Convert QMD to docx with page sections, TOC field codes, version history table, author plate, character styles, comments, revisions, and Zotero field codes
3. **Post-render**: `update-field-codes.R` injects comments and ZOTERO_PREF into the output

### 2. Validate the output

Check key properties:
```r
validate_docx("output/document.docx", expected = list(
  has_toc = TRUE,
  title_font = "Expected Font",
  body_font = "Expected Font"
))
```

### 3. Troubleshoot issues

If styling is wrong, check:
1. Is a static `reference-doc:` bypassing dynamic generation?
2. Is CSS being applied? Check `_quarto.yml` for `docstyle.css`
3. Are fonts installed? Check system fonts.
4. Does the QMD have `format: docx`? Remove it — `_quarto.yml` controls the format.
5. Are Lua filters running? Check stderr for `[version-history]`, `[author-plate]`, `[toc-field]` messages.

### Inspect Word XML directly

```bash
unzip -q output/document.docx -d /tmp/docx_inspect
xmllint --format /tmp/docx_inspect/word/document.xml | head -100
xmllint --format /tmp/docx_inspect/word/styles.xml | grep -A5 "w:name"
```

## Common issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| Wrong fonts | Static reference doc | Remove `reference-doc:` from YAML |
| No TOC | Missing `::: toc :::` | Add placeholder div to QMD body |
| No version history table | Missing `::: version-history :::` | Add placeholder div to QMD body |
| Styles not applied | CSS not linked | Check `docstyle.css` in `_quarto.yml` |
| Footer missing | Footer disabled | Set `docstyle.footer.enabled: true` |
| Lua filters not running | QMD has `format: docx` | Remove format from QMD; use `_quarto.yml` |
| Duplicate citations | `bibliography:` in QMD | Remove it; citations use Zotero field codes |
| CSL file not found | `csl:` in QMD | Remove it; Zotero handles citation formatting |

## Key files

- `_quarto.yml` - Project config, page layout, docstyle settings, author metadata
- `*.css` - Typography, colours, spacing
- `_extensions/docstyle/` - Extension code and Lua filters
- `_docstyle/` - Sidecar files (references, comments, revisions, field codes)
