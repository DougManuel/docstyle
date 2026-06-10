# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

R package + Quarto extension for Word document styling with CSS and YAML configuration. Two workflows: (1) QMD → styled Word or PDF, (2) Word ↔ QMD round-trip preserving Zotero citations, comments, and track changes. Two output formats: `docstyle-docx` (Word) and `docstyle-typst` (PDF via bundled mvuorre/preprint Typst template). A single `authors:`/`affiliations:` block serves both formats.

**arXiv submission (v0.11.0+):** `package_arxiv()` wraps any rendered `.tex` (from `arxiv-pdf`, `mikemahoney218/quarto-arxiv`, or a future `docstyle-arxiv` format) into a submission-ready `.tar.gz` — flattens figure paths, rewrites `\includegraphics` references, discovers only `\usepackage`'d `.sty` files, detects casing drift (macOS → arXiv Linux), and avoids AppleDouble leakage. Format-agnostic so it composes with any LaTeX pipeline.

**medRxiv preprints (v0.12.0+):** Setting `medrxiv: true` under `format: docstyle-typst:` in `_quarto.yml` activates submission-ready defaults — single column, line numbering, 1-inch margins. Each default is opt-out: explicit user values (`columns:`, `margin:`, `line-number:`) win over the flag. PDF/UA-1 tagging is opt-in via `pdf-standard: ua-1` (test against your content first; UA-1 is strict about lists, images without alt text, etc.). Methods-protocol scaffold, JATS parallel output, and margin content are tracked separately as part of the preprint workstream.

**Methods protocol scaffolding (v0.13.0+):** `docstyle::use_methods_protocol()` scaffolds a Quarto project with PRISMA-ScR or PRISMA-P section structure, configured for both Word editing and medRxiv preprint output. Includes a `references.bib` skeleton, supplements directory, submission checklist, and the bundled docstyle extension installed.

**JATS XML output (v0.14.0+):** `docstyle-jats` format produces JATS Archiving DTD v1.2 XML for PMC, ar5iv, scholarly KG ingest. List alongside `docstyle-typst` in `_quarto.yml` to get PDF + JATS from one render. The bundled `jats-fixups.lua` filter handles two gaps in Pandoc's default JATS: bold-labelled abstract paragraphs are restructured to nested `<sec>` blocks, and non-canonical CRediT role strings are rebuilt with full vocabulary URIs.

**Post-render validators (v0.15.0+, expanded v0.17.0):** Opt-in via a `docstyle.validators:` block in `_quarto.yml` to run structural checks on rendered outputs and fail the render on silent failures. Each validator is `error`, `warn`, or `false`/off. The registry (`R/validate_output.R`, `VALIDATORS`) is plugin-style — a new validator is a `function(path) -> list(pass, message)` plus one registry line. Current set: `docx.no-docstyle-cite-markers` (greps `word/document.xml` for unreplaced `DOCSTYLE_CITE::` markers — post-render Zotero injection silently skipped, often renv shadowing, see #142); `jats.well-formed` (XML parses via xml2); `jats.abstract-present` (catches a `# Abstract` body heading landing as a `<sec>` in `<body>` instead of an `<abstract>` in `<front>`, which PMC drops); `pdf.tagged` (PDF has a structure tree via `pdfinfo`; bare-minimum PDF/UA precondition, not full UA-1). Catches at render time what would otherwise ship to a reviewer.

**Extension drift warning (v0.16.0+):** Pre-render hook compares the vendored `_extensions/docstyle/_extension.yml` version against the installed docstyle R package version and warns at render time if they differ. Catches the silent-drift failure mode where downstream projects render with a stale extension long after the package has moved on. Suppress with `docstyle.silence-version-warning: true` in `_quarto.yml`. Programmatic entry point: `check_extension_drift()` (useful for CI gating).

**Abstract placeholder (v0.18.0+):** A `:::docstyle-abstract:::` body div controls where the abstract renders in `docstyle-docx` output — typically below the author plate, matching the order Typst/PDF already produce (Pandoc otherwise hoists the YAML `abstract:` to the document top). Opt-in: without the div, behaviour is unchanged. The abstract content stays in the standard `abstract:` front-matter key (so Typst's title page and JATS `<abstract>` are unaffected — the filter is docx-only); the div only controls position. Round-trips on harvest (prose → `abstract:` YAML + empty placeholder). See the harvest-pipeline section below for the relocation + round-trip mechanics. Follow-ups: #154 (cold-harvest of foreign `Abstract`-styled docs), #153 (DRY-unify the metadata-driven section filters).

**For rendering and harvesting instructions, see the `/docstyle` skill (`~/.claude/skills/docstyle/SKILL.md`).**

## Development commands

```r
devtools::load_all()                    # Load package for development
devtools::test()                        # Run all tests (MUST use this, not testthat::test_dir())
testthat::test_file("tests/testthat/test-css-parser.R")  # Single test (after load_all)
devtools::check()                       # Full R CMD check
devtools::document()                    # Rebuild NAMESPACE/docs from roxygen
devtools::install()                     # Install locally
```

**Testing requires `devtools::load_all()` first** — bare `testthat::test_dir()` will fail because the package must be loaded.

### Tests that shell out to `quarto render` need a dual install (#142)

Some tests (e.g. the render smoke tests in `test-use-methods-protocol.R`) call `system2("quarto", c("render", ...))`. Quarto spawns a child `Rscript` for the pre-render hook, which runs `library(docstyle)` — and that child picks up docstyle from **docstyle's own renv library**, *not* the `devtools::load_all()` version in the parent session. The renv copy can be arbitrarily stale, so the test fails with confusing "object not exported" errors against a function that *is* exported in the dev version.

After every change to docstyle source, install into **both** libraries before running shell-out tests:

```r
# Global library — for ad-hoc R sessions and the quarto-spawned child Rscript
install.packages(".", repos = NULL, type = "source",
                 lib = "/Users/<you>/Library/R/arm64/4.4/library")
# docstyle's own renv — for in-repo tests that shell out to quarto
renv::install(".", prompt = FALSE)
```

Forgetting either step reproduces the symptom. (The v0.16.0 render-time drift warning catches the *downstream* version of this — a stale vendored extension — but not the dev-machine library shadowing, which this note covers.)

## Architecture: three-phase render pipeline

```
Phase 1: Pre-render (R)          Phase 2: Lua filters (Pandoc)       Phase 3: Post-render (R)
generate-reference.R              _extension.yml filter chain          update-field-codes.R
├─ Parse CSS + _quarto.yml        ├─ page-section.lua (sections)       ├─ Inject comments from JSON
├─ Generate reference.docx        ├─ toc-field.lua                     ├─ Replace DOCSTYLE_CITE:: markers
├─ Export page-config.json        ├─ table-style.lua                   │   with Zotero field code XML
└─ Hash-based caching             ├─ list-style.lua                    ├─ Inject ZOTERO_PREF
                                  ├─ version-history.lua               ├─ Assemble anchors (anchor_assembly.R)
                                  ├─ author-plate.lua                  ├─ Finalize sections (finalize_docx.R)
                                  ├─ char-style.lua (post-quarto)      ├─ Prune unused styles
                                  ├─ anchor.lua (floating content)     └─ Scan unresolved citations
                                  ├─ comment-inject.lua
                                  ├─ revisions-inject.lua
                                  └─ zotero-inject.lua
```

### Sidecar data flow

Phases communicate through JSON files in `_docstyle/`:

| File | Written by | Read by | Contents |
|------|-----------|---------|----------|
| `reference.docx` | Phase 1 | Pandoc | Styled template with page layout |
| `reference.docx.hash` | Phase 1 | Phase 1 | Cache key (skip regen if unchanged) |
| `page-config.json` | Phase 1 | Phase 3 | Page dimensions, margins, line numbers, footer/header config |
| `field-codes.json` | Harvest or Phase 3 | Phase 3 | Zotero citation field codes (cached across renders) |
| `comments.json` | Harvest | Phase 2+3 | Threaded comments with author/date metadata |
| `revisions.json` | Harvest | Phase 2 | Track changes with author/date |
| `styles.json` | Harvest | — | Style inventory from source document |
| `harvest-map.json` | Harvest | — | Per-paragraph provenance: body-child index, plain-text MD5 hash, style, type, QMD line span. Written unconditionally on every harvest. Foundation for diff-and-patch re-harvesting (#105). |

### R-first assembly pattern

Lua filters emit **text markers** (not complex XML) that R assembles in post-render. This avoids the 3-line gap problem where Pandoc wraps RawBlock in empty paragraphs.

- Lua emits: `DOCSTYLE_SECTION::{class}::{page-break}::{line-numbers}`
- Lua emits: `DOCSTYLE_CITE::key1;key2` and `DOCSTYLE_CITE_BIBL`
- Lua emits: `DOCSTYLE_ANCHOR::{class}::{adjacent}` and `DOCSTYLE_ANCHOR_END::{class}`
- R post-render finds markers and replaces with proper OOXML

### Section assembly (`finalize_docx.R`)

Word's `<w:sectPr>` defines properties for the section that **ends** at that point, not the section that starts. The `assemble_section_breaks()` function uses a three-pass algorithm:

1. **Collect:** Scan for `DOCSTYLE_SECTION::` and `DOCSTYLE_SECTION_END::` text markers
2. **Attach:** For each marker, use `find_content_predecessor()` to walk backward past structural elements and attach `<w:sectPr>` to the last real paragraph. The sectPr uses the **previous** section's line-number settings (because it closes that section)
3. **Finalize body sectPr:** Apply the **last** marker's settings to the body `<w:sectPr>` (defines the final section)

Post-assembly invariants: `suppress_first_paragraph_spacing()` (remove top gap on first paragraph after section breaks, controlled by `--docstyle-suppress-top-spacing` CSS property or `suppress-top-spacing` div attribute), `deduplicate_page_breaks()`, `suppress_structural_paragraphs()` (no line numbers on non-text paragraphs), `remove_trailing_sectPr()`.

Returns a `section_sequence` list used by `inject_section_headers_footers()` to write per-section footer/header XML files.

### Header/footer three-layer system

Headers and footers are handled at three different stages:

1. **Pre-render** (`page_layout.R:apply_footer/apply_header`): Writes default footer/header into reference.docx using officer's R6 API. Two config formats: legacy single-content (`content`, `align`) and multi-position (`left`, `center`, `right`)
2. **Post-render finisher** (`finalize_docx.R:inject_section_headers_footers`): Reads section markers and page-config.json, resolves "same as previous" cascade, writes per-section `footerN.xml`/`headerN.xml` files using raw XML helpers (no officer dependency)
3. **Harvest** (`footer.R`): Extracts footer content from five XML patterns (tab stops, ptab, framePr, jc, tables). Pattern 1 (regular tab stops) is the canonical output format

Key details:
- Tab stops for multi-position: center at 4680 twips, right at 9360 twips (letter width)
- `{page}` → `PAGE`, `{pages}` → `NUMPAGES`, `{sectionpages}` → `SECTIONPAGES` field codes
- `w:titlePg` in sectPr gates first-page behaviour — without it, "first" footerReference is ignored

### CSS-first pipeline pattern

CSS is the single source of truth for all styling. **Never hardcode OOXML values in Lua.** The pipeline:

```
CSS file (selectors + properties)
  → R reads via read_css() in generate-reference.R
  → R transforms to OOXML-ready values (css_to_twips, css_to_half_points, etc.)
  → R writes to _docstyle/page-config.json
  → Lua loads at runtime via load_page_config()
  → Div attributes override CSS defaults per-element
```

Used by: page config (margins, orientation), section config (line numbers), table styles (borders, shading, font-size), anchor positioning (float dimensions, wrap style, content-mode). New features should follow this pattern.

**Anchor `content-mode`:** The `content-mode` CSS property on an anchor class selector (or `content-mode` div attribute) selects the OOXML mechanism for text/mixed anchor content. Value `textbox` produces a DrawingML text box (`wps:wsp`); omitting it defaults to an invisible floating table. See `dev/ARCHITECTURE-anchors.md`.

**Fallback convention:** Lua keeps built-in defaults as fallback. Config loading overlays CSS-derived values over built-ins, so rendering works even without a CSS file.

See `dev/ARCHITECTURE-tables.md` for the table-specific implementation. See `dev/ARCHITECTURE-anchors.md` for anchor positioning (floats, placed content).

### CSS → Word style conversion

CSS files are parsed (`css_reader.R`) and mapped to Word styles:
- `body` → Normal, `h1` → Heading 1, `.footer` → footer
- Properties map to OOXML: `font-family` → `w:rFonts`, `font-size` → `w:sz` (half-points), etc.
- `@page` rules → page dimensions, margins, orientation, line numbers, suppress-top-spacing
- Unit conversions in `css_parser.R`: twips (margins), half-points (font size), eighth-points (borders)

### Minimal reference.docx template

The reference.docx is built from scratch using OOXML templates in `inst/templates/reference/` rather than from Pandoc's default. This is critical because Pandoc's default reference.docx hardcodes explicit formatting on styles (BodyText: 180/180 spacing, Compact: 36/36, headings: theme fonts + opinionated spacing), which shadows CSS-injected values on the parent Normal style.

**Why 38 styles:** Pandoc references styles by ID during rendering. If a style doesn't exist in the reference.docx, Pandoc creates it with hardcoded defaults. By defining all 38 styles with empty pPr/rPr (only structural attributes like `basedOn`, `outlineLvl`, `keepNext`), we ensure CSS is the sole source of formatting. The styles fall into these groups:

| Group | Styles | Purpose |
|-------|--------|---------|
| Body text | Normal, BodyText, FirstParagraph, Compact, BlockText | Pandoc's content paragraph hierarchy |
| Headings | Heading1–9 | Outline levels, keep-with-next |
| Document metadata | Title, Subtitle, Author, Date | Front matter paragraphs |
| Academic | Abstract, AbstractTitle | Abstract formatting |
| References | Bibliography, FootnoteText | Reference list, footnotes |
| Captions/figures | Caption, TableCaption, ImageCaption, Figure, CaptionedFigure | Image/table annotations |
| Definition lists | DefinitionTerm, Definition | `<dl>` element mapping |
| Navigation | TOCHeading | Table of contents header |
| Character | DefaultParagraphFont, BodyTextChar, VerbatimChar, SectionNumber, FootnoteReference, Hyperlink | Inline formatting |
| Table | TableNormal, Table | Table defaults |

**Pandoc overwrite behaviour and CSS cascade:** Pandoc respects explicit values in the reference.docx but injects its own defaults when a style has empty pPr/rPr. The `cascade_css_to_children()` function in `css_injection.R` handles this by copying CSS-injected properties from parent styles (Normal, BodyText, Title, Caption) to their children before Pandoc runs. This ensures CSS `p { margin-bottom: 6pt }` reaches BodyText, FirstParagraph, Compact, and all headings. Children with their own CSS rules (e.g., `.compact { margin-bottom: 2pt }`) are skipped — their explicit values take precedence.

**Backward compatibility:** `base-doc: pandoc` in `_quarto.yml` opts into Pandoc's default reference.docx for projects that need the old behaviour. Template files in `inst/templates/reference/` include all OOXML parts: content types, relationships, styles, numbering (copied from Pandoc for list formatting), settings, footnotes, font table, and a minimal theme with explicit font names (no theme indirection).

### Harvest pipeline (Word → QMD)

Entry point: `docx_to_qmd()`. Extracts sidecar data (citations → `field-codes.json`, comments → `comments.json`, track changes → `revisions.json`, styles → `styles.json`), then converts OOXML paragraphs/runs to markdown.

Round-trip fidelity uses `ADDIN DOCSTYLE` field codes wrapping generated content (sections, TOC, author plate, tables). On re-harvest, `detect_docstyle_field_codes()` in `R/generated_content.R` reads these back. Bibliography uses `::: bibliography :::` div (not header detection) since v0.7.8.

**Deferred emit pattern (harvest):** For block-level types where the content contains information needed for the opening marker (e.g., table column widths from `w:gridCol`), the harvest loop defers `div_open` emission until the content element is found, extracts the needed data, updates the stored `div_open`, then emits it before the content.

**Figure harvest and Quarto crossref (#124):** Harvested figures emit a crossref-valid `fig-<docPrId>` id (NOT `docstyle-fig-FIXME-…`, which lacks the `fig-` prefix Quarto's crossref pass requires — such figures never number). The original Word docPr identity is preserved in the field-code payload (`docpr_id`) and `figures.json`, not the visible id. `strip_figure_label()` removes the literal "Figure N." label Word stores in caption text, because Quarto regenerates the number+supplement from the crossref id (keeping it double-numbers). No render-time filter is needed for PDF/Typst/JATS figures — Quarto handles `.figure` divs natively once the id is crossref-valid and the caption is clean; `figure.lua` is openxml-only (Word field codes). When changing figure behaviour, verify against a real `quarto render` (not bare `pandoc`) — Quarto's crossref pass produces correct figures that bare pandoc does not.

**Style resolution (style_resolver.R):** Before the dispatch switch, `resolve_to_canonical(style_id, props_lookup)` maps non-standard style IDs from journal/institutional templates to canonical keys. `build_style_props_lookup(docx_path)` is called once at the top of `convert_to_qmd()` and returns a named list keyed by `styleId` with `name`, `based_on`, and `outline_level`. Resolution order: (1) already canonical → pass through; (2) `outlineLvl` attribute (0=H1…5=H6); (3) `basedOn` chain walk; (4) display-name pattern fallback ("Heading 1", "heading2"); (5) return unchanged. Levels 6–8 are body-outline levels and are NOT resolved to headings.

**Abstract placeholder (`:::docstyle-abstract:::`, v0.18.0+, #149):** Opt-in div controlling where the abstract renders in docx. Pandoc hoists the YAML `abstract:` to the document top; `abstract.lua` (docx-only) plants a `DOCSTYLE_ABSTRACT` marker wrapped in an `ADDIN DOCSTYLE {type:div,name:abstract}` field code at the div's body position, and `relocate_abstract()` in `finalize_docx` MOVES Pandoc's hoisted `AbstractTitle`+`Abstract` paragraphs to sit *inside* that field-code wrapper, removing only the marker (move, don't rebuild — preserves CSS-driven `Abstract`/`AbstractTitle` styling). The wrapper is KEPT (not deleted) because harvest detects the abstract by the wrapping field code — deleting it would leave bare prose that re-harvests as plain body text. Harvest restores the prose to `abstract:` YAML (`parse_abstract_range` + `format_abstract_yaml`, literal block scalar) and re-emits an empty `:::docstyle-abstract:::` placeholder via the `abstract` div_type. docx-only; the filter returns `nil` for Typst/JATS/LaTeX (Quarto renders `abstract:` natively there). The placeholder class is docstyle-namespaced (NOT Pandoc's special `.abstract` div); the `.abstract` CSS class styles the rendered paragraphs (Loop 1, already wired). Cold-harvest of foreign `Abstract`-styled docs = #154.

**Numbered-heading recovery (#125):** When `resolve_to_canonical()` returns an unresolved style (the `switch` default branch in `convert_to_qmd()`), `infer_numbered_heading_level(text)` provides a last-resort text heuristic: a paragraph whose text begins with a multi-segment section number (`N.N` …, ≥2 segments, followed by a title word) is recovered as a heading at the depth implied by the segment count (clamped to H1–H6), with a `[harvest]` message. This catches journal/institutional templates that style subsection headings with a custom style lacking `outlineLvl`. The style-ID path (`resolve_to_canonical`) only sees the style ID, never paragraph text — so text-based recovery must live in the dispatch loop, not the resolver. Conservative by design (requires `N.N`, not `N.`) so list items and inline decimals aren't misclassified.

**Anchor hyperlinks and heading cross-ref IDs (#96):** `extract_formatted_text()` checks `w:anchor` before the `r:id` relationship lookup — internal links produce `[text](#anchor)`. `bookmarkStart` elements immediately preceding a heading emit `{#name}` on the heading line. Bookmarks with `_docstyle_*`, `_Toc*`, `_Ref*`, or `_GoBack` prefixes are filtered. State is tracked via `pending_heading_id` and cleared on any non-heading intervening node.

**Cross-project citations:** `import_citations(source, dest, citekeys, overwrite)` in `R/project_citations.R` copies citation entries between `field-codes.json` files across projects. Only the `citations` list is merged — `zotero_pref`, `zotero_bibl`, and other fields in the destination are never overwritten.

## Key source file map

| Area | R files | Lua filters |
|------|---------|-------------|
| CSS processing | `css_reader.R`, `css_parser.R`, `css_injection.R` | — |
| Style management | `style_manager.R` | — |
| Page layout / sections | `page_layout.R`, `layout_injector.R`, `finalize_docx.R` | `page-section.lua` |
| Table styling | `css_parser.R` (border/style extraction) | `table-style.lua` |
| Headers / footers | `page_layout.R`, `finalize_docx.R`, `footer.R` | — |
| Zotero citations | `inject_zotero.R`, `extract_citations.R`, `field_codes.R`, `project_citations.R` | `zotero-inject.lua` |
| Comments | `comments.R` | `comment-inject.lua` |
| Track changes | `revisions.R` | `revisions-inject.lua` |
| Harvest (Word → QMD) | `docx_to_qmd.R`, `generated_content.R`, `style_resolver.R`, `harvest_map.R` | — |
| Validation | `validate_docx.R`, `validate_harvest.R`, `validate_structure.R` | — |
| Utilities | `utils.R` (XML escaping, DOCX zip helpers, null coalesce) | — |
| Anchor positioning | `anchor_assembly.R`, `css_parser.R` | `anchor.lua` |
| Project init/maintenance | `use_docstyle.R` (`init`, `use_docstyle`, `update_extension`, `check_project`) | — |

## Extension vs package relationship

The extension (`_extensions/docstyle/`) is the integration layer between Quarto and the R package:

- **`generate-reference.R`** (pre-render): Checks for installed `docstyle` package, falls back to `devtools::load_all()`. Calls `generate_reference_doc()` from the package
- **`update-field-codes.R`** (post-render): Calls `inject_zotero_citations()`, `finalize_docx()`, validators
- **Lua filters**: Emit text markers consumed by the R post-render phase
- **`_extension.yml`**: Declares the `docstyle-docx` format and filter execution order

When developing, changes to R files take effect after `devtools::load_all()`. Changes to Lua filters and extension scripts take effect immediately on next render. External consumers (e.g., POPCORN) have their own copy in `_extensions/docstyle/` — Lua and R script changes must be copied there manually.

### Typst/PDF output (docstyle-typst)

`_extensions/docstyle/preprint/` bundles the mvuorre/preprint Typst template. All docstyle Lua filters are OOXML-specific and return `nil` for Typst — no interference between formats. A project using both formats needs one extension and one author block:

```yaml
format:
  docstyle-docx:
    toc: false
  docstyle-typst:
    running-head: "My Paper"
    bibliography: references.bib
    csl: vancouver.csl
    citeproc: true

authors:
  - name: { given: Jane, family: Smith }
    affiliations: [{ ref: inst1 }]
```

Note: `bibliography:` and `csl:` are Typst-only — for `docstyle-docx`, citations are still handled by Zotero field codes.

## Testing conventions

- Test files: `test-{feature}.R` in `tests/testthat/`
- Fixtures: `tests/testthat/fixtures/` (JSON sidecars, DOCX samples, QMD sources)
- Tests build minimal XML inline with `paste0()` — no external XML templates
- Namespace constants defined per test: `ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")`
- Assertions use XPath queries via `xml2::xml_find_all()`, not string matching
- DOCX zip helpers: `modify_docx_xml()` (unzip → modify → re-zip with cleanup)

## Coding conventions

- **Messaging**: Bracketed prefixes — `[generate-reference]`, `[finalize]`, `[assemble]`. Use `message()`, never `cat()` or `print()`
- **Dependencies**: Core deps are `xml2`, `officer`, `jsonlite`, `yaml`. No tidyverse
- **Naming**: Internal functions use `snake_case`. XML elements use Word schema names verbatim (`w:sectPr`, `w:lnNumType`)
- **XML namespaces**: `xml2::xml_attr()` — try bare attribute name first (`"fldCharType"`), not `"w:fldCharType"`
- **R list gotcha**: Assigning `NULL` to a list element removes it — use sentinel `list(empty = TRUE)` for empty footers/headers

## Project maintenance for downstream projects

Downstream projects (POPCORN, PDP) maintain their own copy of `_extensions/docstyle/`. Two functions manage the lifecycle:

- **`check_project(path)`** — 9-point health check: extension completeness, Quarto format, QMD headers (no `bibliography:`, `csl:`, `reference-doc:`), sidecar JSON validity, citation coverage (all `[@citekey]` in QMD have entries in `field-codes.json`), bibliography div, version consistency. Returns `list(valid, checks, issues)`.
- **`update_extension(path)`** — Smart sync: compares MD5 hashes, copies only changed files, backs up to `docstyle.bak/`, invalidates reference.docx cache. Returns diff summary.

Run `check_project()` when: rendering fails silently, after upgrading the R package, or before sharing with collaborators. Run `update_extension()` when `check_project()` reports missing/stale extension files.

## Common mistakes to avoid

1. **Don't add `reference-doc:` to QMD YAML headers** — bypasses dynamic style generation
2. **Don't commit reference.docx files** — they become stale when CSS changes
3. **Don't add `bibliography:` or `csl:` to the QMD** — citations are handled by Zotero field codes in Word; the post-render hook injects ZOTERO_PREF. Adding bibliography causes Pandoc to duplicate citation processing
4. **Don't add `format: docx` to the QMD** — the format is set in `_quarto.yml` as `docstyle-docx`; overriding it in the QMD prevents Lua filters from running
5. **Author metadata uses standard Quarto `author:` format** — the author-plate Lua filter reads from Quarto's normalized `by-author` metadata. `docstyle.authors` and `docstyle.affiliations` are deprecated. Version history entries and document-specific metadata go in the QMD header
6. **Don't hardcode OOXML values in Lua** — all styling should come from CSS via the CSS-first pipeline. Lua keeps built-in fallbacks only for when no CSS is provided
7. **Don't assume filter execution order for inline content** — `table-style.lua` runs before `char-style.lua` and `comment-inject.lua`. When processing table cell content, inline spans are still Pandoc AST (not OOXML). Any inline renderer in early filters must handle pre-conversion forms

## Debugging and validation

```bash
# Inspect Word XML
unzip -q document.docx -d /tmp/docx_inspect
xmllint --format /tmp/docx_inspect/word/document.xml | head -100
```

```r
# Validate rendered output
validate_docx("output/document.docx", expected = list(
  has_toc = TRUE, has_footnotes = TRUE, footnote_count = 2,
  title_font = "Libre Baskerville", body_font = "Hanken Grotesk"
))
```

All validators return: `list(valid = TRUE/FALSE, issues = list(errors = ..., warnings = ...))`.

**Environment variables** (set before `quarto render`):
- `DOCSTYLE_VALIDATE=1` — enable DOCX structure validation in post-render
- `DOCSTYLE_VALIDATE_COMMENTS=1` — enable comment validation
- `DOCSTYLE_VALIDATE_ZOTERO=1` — enable Zotero field code validation
- `DOCSTYLE_DEBUG=1` — verbose debug output

## Development workflow for new formatting features

1. **Harvest** source document to understand Word XML structure
2. **Develop** in minimal test document (`quarto render test-feature.qmd`)
3. **Validate** with `validate_docx()` property checks
4. **Migrate** to canonical QMD once confirmed working
5. **Render and validate** final output

## GitHub Projects

This repo uses GitHub Project #2 (DougManuel/docstyle) for task tracking.

```bash
gh project item-list 2 --owner DougManuel --format json
gh issue list --repo DougManuel/docstyle
```

## Reference: Anthropic docx skill

The `.claude/reference/anthropic-docx/` directory contains technical reference from Anthropic's official docx skill for OOXML patterns. This is **not an active skill** — consult it when implementing track changes injection, comment infrastructure, or OOXML validation patterns. See `.claude/reference/anthropic-docx/LESSONS.md`.
