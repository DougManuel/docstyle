---
name: validate-harvest
description: Validate that a harvested QMD faithfully represents its source Word document. Uses a layered architecture (precondition gate, extraction fidelity, text fidelity, structural fidelity) with independent XPath validation and an expected loss registry. Run after docx_to_qmd() to check for content loss, citation errors, tracked change loss, and structural changes.
---

# Validate harvest

Compare a source Word document against its harvested QMD and sidecar files to detect discrepancies. Uses a layered validation architecture where each layer checks a different aspect of harvest fidelity.

## When to use

- After running `docx_to_qmd()` (the harvest skill)
- When collaborators report "something looks different" after a round-trip
- As a QA step before committing harvested changes
- When debugging citation or tracked-change issues
- Extraction-only validation (no QMD needed) with `qmd_path = NULL`

## Quick validation

```r
library(docstyle)

result <- validate_harvest(
  docx_path = "source/document.docx",
  qmd_path = "document.qmd",
  sidecar_dir = "_docstyle"
)
```

Extraction-only (no QMD file needed):

```r
result <- validate_harvest(
  docx_path = "source/document.docx",
  sidecar_dir = "_docstyle"
)
```

Or auto-validate during harvest:

```r
docx_to_qmd("source/document.docx", "document.qmd",
  preserve_header = TRUE, validate = TRUE)
```

## Validation layers

The validation runs in order of diagnostic value. Each layer is an independently callable internal function; `validate_harvest()` is the wrapper that runs them all.

```
┌───────────────────────────────────────────────────┐
│ Precondition: Source XML well-formed              │
│   Parse document.xml, check for body element.     │
│   Detect orphaned comment markers.                │
│   GATE: if parse fails, stop immediately.         │
├───────────────────────────────────────────────────┤
│ Layer 1: Extraction fidelity                      │
│   Independent XPath on source XML vs sidecar      │
│   files. ID-level set operations.                 │
│   • Citations: ZOTERO_ITEM instrText vs           │
│     field-codes.json                              │
│   • Comments: w:comment IDs vs comments.json      │
│   • Revisions: w:ins/w:del IDs vs revisions.json  │
├───────────────────────────────────────────────────┤
│ Layer 2: Text fidelity                            │
│   Source display text vs QMD body text.            │
│   Generated content excluded before comparison.   │
│   Word count with 5%/10% thresholds.              │
├───────────────────────────────────────────────────┤
│ Layer 3: Structural fidelity                      │
│   Headings, tables, citation placement,           │
│   revision placement (with expected loss           │
│   registry), comment placement.                   │
└───────────────────────────────────────────────────┘
```

### Layer rationale

- **Extraction before text**: if sidecar files are wrong, text and structure checks are unreliable
- **Text before structure**: a document could have the right headings but be missing paragraphs
- **Structure last**: Pandoc handles headings/tables reliably; these are sanity checks

### Key design principle

Layer 1 uses **independent XPath** on the raw source XML — a different code path from `extract_*()` functions. Re-extracting with the same function is not validation.

## What each layer checks

### Precondition gate

- Parses `document.xml` from the source docx
- Verifies `w:body` element exists
- Detects orphaned comment markers (markers referencing non-existent comments)
- **If parse fails**: all layers are skipped, returns `valid = FALSE`

### Layer 1: Extraction fidelity

| Element   | Source XPath                                    | Sidecar comparison                  |
|-----------|-------------------------------------------------|-------------------------------------|
| Citations | `//w:instrText[contains(., 'ZOTERO_ITEM')]`     | `field-codes.json` citation entries |
| Comments  | `//w:comment/@w:id` in comments.xml             | Comment IDs in `comments.json`      |
| Revisions | `//w:ins/@w:id` and `//w:del/@w:id`            | Entry IDs in `revisions.json`       |

Reports `setdiff()` results: `missing_from_sidecar` and `extra_in_sidecar`.

In verbose mode, also reports a breakdown of non-Zotero field codes (TOC, REF, PAGE, other).

### Layer 2: Text fidelity

Compares word count from source docx display text against QMD body text.

**Generated content excluded** before comparison:

| Content              | Detection method                                    |
|----------------------|-----------------------------------------------------|
| Version history      | `ADDIN DOCSTYLE` field code, `::: version-history` div, fallback to heading |
| Author plate         | `ADDIN DOCSTYLE` field code, `::: author-plate` div, fallback to heading    |
| Bibliography         | `:::{#refs}` div, fallback to `## References`       |
| ZOTERO_PREF marker   | Line containing `ZOTERO_PREF`                       |

Reports which sections were stripped, detection method (div vs heading), and word counts per section.

**Thresholds:**
- < 5% difference: pass
- 5–10% difference: warning
- \> 10% difference: error

### Layer 3: Structural fidelity

- **Headings**: docx paragraph styles vs QMD `#` levels. Content inside `ADDIN DOCSTYLE` field codes and `_docstyle_*` bookmarks is excluded from the source count.
- **Tables**: `<w:tbl>` count vs QMD table separator rows. Tables inside field code/bookmark ranges are excluded from the source count.
- **Citation placement**: source ZOTERO_ITEM count vs `[@citekey]` count in QMD
- **Revision placement**: QMD `{.ins id="rev_*"}`/`{.del id="rev_*"}` spans vs sidecar entries, with **expected loss registry** classification
- **Comment placement**: QMD `comment:start` markers vs sidecar comment IDs, with **expected comment loss** classification

### Expected loss registries

Missing revisions and comments are classified by named pattern functions. When all missing items are classified as expected, the check **passes with info**. Unexpected loss is an error.

**Revision loss patterns:**

| Pattern                    | Meaning                                          |
|----------------------------|--------------------------------------------------|
| `revisions_in_tables`      | Pandoc doesn't preserve tracked changes in tables |
| `revisions_empty_content`  | Formatting-only changes with no text content      |
| `revisions_in_bookmarks`   | Revisions inside `_docstyle_*` bookmark ranges (generated content) |
| `revisions_in_field_codes` | Revisions inside ADDIN DOCSTYLE field code ranges (generated content) |
| `revisions_in_pPr`         | Formatting-only changes in paragraph properties (`w:pPr/w:rPr/w:ins\|del`) |

**Comment loss patterns:**

| Pattern                    | Meaning                                          |
|----------------------------|--------------------------------------------------|
| `comments_in_tables`       | Table conversion doesn't place comment markers    |
| `comments_on_metadata`     | Comments on Title/Subtitle/Date/Author/Abstract paragraphs (consumed into YAML; case-insensitive prefix matching) |
| `comments_in_bookmarks`    | Comments inside `_docstyle_*` bookmark ranges (generated content) |
| `comments_in_field_codes`  | Comments inside ADDIN DOCSTYLE field code ranges (generated content) |
| `comments_at_body_level`   | Comment markers at body level (not inside a paragraph) |

Both registries are extensible — new patterns can be added as discovered.

## Severity rules

| Check               | Error                | Warning                    | Pass            |
|---------------------|---------------------:|---------------------------:|----------------:|
| XML well-formed     | Parse failure        | —                          | Parses cleanly  |
| Orphaned markers    | —                    | Markers reference missing  | No orphans      |
| Citation extraction | —                    | Count mismatch             | IDs match       |
| Comment extraction  | Count mismatch       | —                          | IDs match       |
| Revision extraction | —                    | Count mismatch             | IDs match       |
| Text fidelity       | >10% word difference | 5–10% difference           | <5% difference  |
| Heading match       | —                    | Count differs              | Counts match    |
| Table match         | —                    | Count differs              | Counts match    |
| Citation placement  | Count mismatch       | —                          | Counts match    |
| Revision placement  | >0 unexpected loss   | —                          | All preserved   |
| Comment placement   | >0 unexpected loss   | —                          | All placed      |

## Interpreting results

```r
result$valid        # TRUE/FALSE — overall pass/fail
result$summary      # Per-layer metrics
result$checks       # Named list of TRUE/FALSE per check
result$issues       # $errors (critical) and $warnings (non-critical)
result$details      # Per-layer detail data for investigation
```

### Key detail paths

```r
# Extraction layer — which IDs are missing?
result$details$extraction$citations$missing
result$details$extraction$comments$missing
result$details$extraction$revisions$missing

# Text layer — what generated content was excluded?
result$details$text$generated_sections
# e.g. list(version_history = list(detected_by = "heading", word_count = 255))

# Structure layer — revision loss classification
result$details$structure$revision_loss$expected
result$details$structure$revision_loss$unexpected
result$details$structure$revision_loss$by_pattern

# Structure layer — comment loss classification
result$details$structure$comment_loss$expected
result$details$structure$comment_loss$unexpected
result$details$structure$comment_loss$by_pattern
```

### Common findings

| Finding | Meaning | Action |
|---------|---------|--------|
| Word count diff < 5% | Normal markdown formatting differences | None needed |
| Version history excluded (div) | Generated content correctly stripped via field code | None needed |
| Expected revision loss in tables | Pandoc limitation, classified correctly | None needed |
| Expected revision loss in pPr | Formatting-only tracked changes (paragraph properties) | None needed |
| Expected revision loss in field codes | Revisions inside generated content (field code range) | None needed |
| Unexpected revision loss | Tracked change in simple paragraph text | Review specific revision IDs |
| Expected comment loss in tables | Table conversion limitation, classified correctly | None needed |
| Expected comment loss on metadata | Comment on Title/Author/Abstract paragraph consumed into YAML | None needed |
| Expected comment loss in field codes | Comment inside generated content (field code range) | None needed |
| Unexpected comment loss | Comment in simple paragraph not placed | Review specific comment IDs |
| Tables "in generated content" | Table inside field code/bookmark range excluded from source count | None needed |
| Non-Zotero field codes reported | ADDIN DOCSTYLE or other field codes detected | Expected for docstyle v0.4.0+ |
| Citation extraction warning | Non-Zotero field codes or complex fields | Check verbose output for field code breakdown |

## Selective checks

Run specific layers only:

```r
# Extraction fidelity only
validate_harvest(docx_path, qmd_path, sidecar_dir, checks = "extraction")

# Text and structure only
validate_harvest(docx_path, qmd_path, sidecar_dir, checks = c("text", "structure"))
```

The precondition gate always runs regardless of the `checks` parameter.

## AI-assisted analysis

When running this skill as an AI agent:

1. Run `validate_harvest()` with verbose output and read the structured result
2. For **extraction warnings**, check `result$details$extraction` — report which specific IDs are missing or extra
3. For **text warnings**, check `result$details$text$generated_sections` — verify that excluded content is truly generated (not user content incorrectly stripped)
4. For **revision loss**, read `result$details$structure$revision_loss$by_pattern` — explain each pattern (e.g., "7 revisions inside tables — this is a known Pandoc limitation")
5. For **comment placement errors**, identify which comments are missing from QMD and check whether they span complex structures (tables, field codes)
6. For **heading mismatches**, compare `result$details$structure$docx_heading_texts` vs `result$details$structure$qmd_heading_texts` to identify which heading differs
7. Suggest specific fixes for unexpected issues

## Round-trip validation

For a complete baseline, use `validate_round_trip()` which runs harvest validation, renders the QMD, and validates the output:

```r
result <- validate_round_trip(
  docx_path = "source/document.docx",
  qmd_path = "document.qmd"
)
```

This establishes a clean baseline: if harvest + render + output validation all pass before edits, post-edit failures are attributable to the edits, not the pipeline.

Skip rendering (validate existing output):

```r
result <- validate_round_trip(
  docx_path = "source/document.docx",
  qmd_path = "document.qmd",
  render = FALSE
)
```

## Reporting

Results are S3 objects (`docstyle_validation`) with `print()` and `report()` methods:

```r
# Default summary (devtools-style)
print(result)

# Full detail with per-ID breakdown
print(result, detail = "full")

# Markdown report to file
report(result, file = "validation-report.md")

# Text report to console
report(result, format = "text")
```

## Integration with harvest workflow

After harvesting, validation is step 3:

```r
# 1. Harvest
docx_to_qmd("source/protocol.docx", "protocol.qmd", preserve_header = TRUE)

# 2. Review sidecar changes
# (comments.json, revisions.json, field-codes.json)

# 3. Validate (harvest only)
result <- validate_harvest("source/protocol.docx", "protocol.qmd", "_docstyle")

# 4. Or full round-trip (harvest + render + output validation)
result <- validate_round_trip("source/protocol.docx", "protocol.qmd")

# 5. If issues, investigate
if (!result$valid) {
  print(result, detail = "full")  # Per-ID details
  report(result, file = "debug-report.md")  # Save for sharing
}
```
