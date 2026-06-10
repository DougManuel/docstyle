---
name: validate-output
description: Validate rendered Word documents for correct styling, structure, and content. Use after rendering to check fonts, TOC, footnotes, headers/footers, and catch regressions.
---

# Validate docstyle Output

Property-based validation of rendered Word documents to catch styling regressions and verify correct output.

## When to use

- After rendering a document to verify styling
- When troubleshooting wrong fonts or missing elements
- As part of a test workflow for style changes
- Comparing output against expected specifications

## Quick validation

### Using R

```r
library(docstyle)

# Basic validation
validate_docx("output/document.docx", expected = list(
  has_toc = TRUE,
  has_footnotes = TRUE,
  title_font = "Libre Baskerville",
  body_font = "Hanken Grotesk"
))

# Quick inspection (returns properties without assertions)
inspect_docx("output/document.docx")
```

### Using command line

```bash
# Unpack for inspection
unzip -q output/document.docx -d /tmp/docx_check

# Check fonts used
xmllint --format /tmp/docx_check/word/styles.xml | grep "w:rFonts" | head -20

# Check if TOC exists
grep -l "TOC" /tmp/docx_check/word/document.xml

# Check footnotes
ls /tmp/docx_check/word/footnotes.xml 2>/dev/null && echo "Has footnotes"

# Check headers/footers
ls /tmp/docx_check/word/header*.xml /tmp/docx_check/word/footer*.xml 2>/dev/null
```

## Validation properties

| Property | Type | Description |
|----------|------|-------------|
| `has_toc` | boolean | Table of contents present |
| `has_footnotes` | boolean | Footnote definitions exist |
| `footnote_count` | integer | Expected number of footnotes |
| `title_font` | string | Font family for Title style |
| `body_font` | string | Font family for Normal/body text |
| `has_header` | boolean | Header content present |
| `has_footer` | boolean | Footer content present |
| `page_count` | integer | Approximate page count |

## Troubleshooting common issues

### Wrong fonts

**Symptom**: Title or body text in wrong font (often Calibri or Times)

**Check**:
```bash
xmllint --format /tmp/docx_check/word/styles.xml | grep -A5 'w:name w:val="Title"'
```

**Common causes**:
1. Static `reference-doc:` in YAML bypassing dynamic generation
2. CSS file not linked in `_quarto.yml`
3. Font not installed on system
4. Reference doc hash mismatch (delete `_docstyle/reference.docx.hash`)

### Missing TOC

**Check**:
```bash
grep -i "TOC\|HYPERLINK" /tmp/docx_check/word/document.xml | head -5
```

**Common causes**:
1. Missing `::: toc :::` placeholder in QMD body
2. `toc: false` in `_quarto.yml`

### Missing footnotes

**Check**:
```bash
cat /tmp/docx_check/word/footnotes.xml 2>/dev/null | xmllint --format - | head -50
```

**Common causes**:
1. Footnote syntax error in QMD (`[^1]` without definition)
2. Footnote definitions at wrong location

### Footer not appearing

**Check**:
```bash
cat /tmp/docx_check/word/footer1.xml | xmllint --format -
```

**Common causes**:
1. `docstyle.footer.enabled: false` in `_quarto.yml`
2. First page different setting (`first-page: false`)

## Visual inspection

Convert to images for quick visual check:

```bash
# Convert to PDF then images
soffice --headless --convert-to pdf output/document.docx --outdir /tmp
pdftoppm -jpeg -r 150 /tmp/document.pdf /tmp/page

# View first page
open /tmp/page-1.jpg  # macOS
```

## Regression testing workflow

1. Define expected properties in a test file
2. Render document
3. Run validation
4. Fail build if properties don't match

```r
# test-document-style.R
library(testthat)
library(docstyle)

test_that("TOR document has correct styling", {
  result <- validate_docx("output/TOR-current.docx", expected = list(
    has_toc = TRUE,
    has_footnotes = TRUE,
    footnote_count = 5,
    title_font = "Libre Baskerville",
    body_font = "Hanken Grotesk",
    has_footer = TRUE
  ))

  expect_true(result$valid)
})
```
