# docstyle 0.19.0

## New features

* Render preflight: the pre-render hook now runs
  `check_render_preconditions()` automatically and blocks the render
  when a documented P0 footgun is present — `bibliography:`, `csl:`,
  `reference-doc:`, or a `format: docx` override in a QMD header, or a
  plain `format: docx` in `_quarto.yml`. These previously produced
  silently broken output (duplicate citation processing, bypassed CSS
  styling, skipped Lua filters) that only a manual `check_project()`
  call would catch. Checks are scoped to projects rendering
  `docstyle-docx`; Typst-only projects with `bibliography:` are
  unaffected. Disable with `docstyle: preflight: false` in
  `_quarto.yml`.

## Documentation

* README gains a "Status and philosophy" section describing the
  project's scope, maintenance expectations, and the two design ideas
  it explores (CSS as the single styling source of truth; Word field
  codes as an extensible metadata layer), plus a warning box on where
  configuration keys belong (`_quarto.yml` vs QMD front matter).
* 62 pipeline-internal exports are now marked `@keywords internal`,
  shrinking the documented API reference from 109 to 47 user-facing
  functions. All functions remain exported, so extension scripts and
  existing code are unaffected.
* Package site URLs corrected to `dougmanuel.github.io/docstyle`.

## Bug fixes

* `xml_escape_attr()` had two competing definitions; the live one did
  not escape apostrophes. Consolidated in `utils.R`, escaping all five
  XML entities, with regression tests.
* `rstudioapi` moved from Imports to Suggests (used only by
  `insert_citation()` inside an editor, now guarded by
  `requireNamespace()`).

# docstyle 0.18.0

## New features

* `:::docstyle-abstract:::` placeholder controls where the abstract
  renders in `docstyle-docx` output — typically below the author plate,
  matching the order the Typst/PDF path already produces (#149). Opt-in:
  add the div where you want the abstract; without it, behaviour is
  unchanged (Pandoc renders the abstract at the document top). A plain
  `## Abstract` heading in the body is also untouched.

  Implemented via R-first assembly. A docx-only Lua filter
  (`abstract.lua`) plants a `DOCSTYLE_ABSTRACT` marker, wrapped in an
  `ADDIN DOCSTYLE` field code, at the placeholder position;
  `relocate_abstract()` in `finalize_docx` *moves* Pandoc's hoisted
  `Abstract`/`AbstractTitle` paragraphs into that field-code wrapper
  (move, not rebuild — the CSS-driven Word styling is preserved). The
  field-code wrapper is kept so the abstract round-trips on harvest:
  `docx_to_qmd()` restores the prose to `abstract:` YAML and re-emits an
  empty `:::docstyle-abstract:::` placeholder at the right position. The
  abstract continues to live in `abstract:` YAML, so the Typst title
  page and JATS `<abstract>` are unaffected (the filter returns `nil`
  for non-docx formats). Cold-harvest of foreign `Abstract`-styled
  documents (no docstyle field code) is tracked separately (#154).


# docstyle 0.17.3

## Bug fixes

* Input guards in the harvest-map layer fail fast on malformed input
  instead of letting it propagate to an opaque downstream error
  (#114, #115). `harvest_map_entry()` validates that `para_index` is a
  single non-NA integer and `type` a non-empty string (deliberately not a
  closed enum, and `para_hash` is not required — real harvest emits
  `grouped-figure` entries and content entries without a hash).
  `compute_section_summaries()` validates each section range's
  `start_idx`/`end_idx` (integer, `start_idx >= 1`, `end_idx >= start_idx`)
  before the index arithmetic, naming the offending range — a malformed
  bound previously produced silently-wrong paragraph ranges. Non-section
  ranges are not bounds-checked (they are filtered out before the
  arithmetic).


# docstyle 0.17.2

## Bug fixes

* Harvested figures now render correctly as numbered, cross-referenceable
  figures in PDF/Typst and JATS output (#124). Two harvest-side changes:
  - The figure div id is now a crossref-valid `fig-<docPrId>` (was
    `docstyle-fig-FIXME-<docPrId>`, which has no `fig-` prefix and so was
    invisible to Quarto's crossref pass — the figure never numbered). The
    original Word docPr identity is preserved in the field-code payload and
    `figures.json`, not the visible id.
  - The literal "Figure N." label Word stores in caption text is stripped on
    harvest (`strip_figure_label()`). Quarto regenerates the number and
    supplement from the crossref id, so keeping the literal label
    double-numbered the rendered figure. Stripping is conservative — a
    figure number is required, so captions that merely begin with the word
    "Figures"/"Figured" are left intact.

  No new render-time filter is needed: Quarto already renders `.figure` divs
  as native figures for PDF/Typst/JATS once the id is crossref-valid and the
  caption is clean. Word output continues to use Zotero-style field codes.


# docstyle 0.17.1

## Bug fixes

* Harvest now recovers numbered section headings that were styled with a
  custom paragraph style which doesn't resolve to a canonical `HeadingN`
  key (#125). Some journal/institutional Word templates apply such a
  style — no `outlineLvl`, name not matching "heading N" — to a
  subsection heading, which previously flattened to a plain paragraph on
  `docx_to_qmd()` (observed: 3.4.2–3.4.8 lost their `###` while the
  adjacent 3.4.1 kept it). When a paragraph's text begins with a
  multi-segment section number (`N.N` …) and its style didn't resolve to
  a heading, the harvest infers the heading depth from the segment count
  (clamped to H1–H6) and emits a `[harvest]` message so the recovery is
  visible. The heuristic is conservative: it requires at least two
  numeric segments followed by a title word, so numbered list items
  (`1. item`), bare years (`2020 was…`), and inline decimals (`the ratio
  3.4 was…`) are not misclassified.


# docstyle 0.17.0

## New features

* Three additional post-render validators round out the framework
  introduced in 0.15.0 (#145). Configure under
  `docstyle.validators.<format>` in `_quarto.yml`:
  - `jats.well-formed` — error if the rendered JATS XML does not parse.
  - `jats.abstract-present` — error if no `<abstract>` element is
    present. Catches the silent failure where a `# Abstract` body
    heading produces a `<sec>` in `<body>` instead of `abstract:`
    YAML — PMC and other JATS consumers drop the abstract entirely.
  - `pdf.tagged` — error if the PDF carries no structure tree
    (`Tagged: yes`). Bare-minimum PDF/UA precondition; full UA-1
    conformance still needs veraPDF and is out of scope. Degrades to a
    pass-through when `pdfinfo` is unavailable rather than failing.

  These were the three "highest signal-to-noise" validators named in
  #145 — together they would have caught the silent failures hit while
  preparing the POPCORN scoping protocol for medRxiv.


# docstyle 0.16.2

## Bug fixes

* `docstyle-typst` with `medrxiv: true` now respects an explicit
  `line-number: false` in the same YAML block (#140). Previously,
  Pandoc's `$if(line-number)$` template syntax could not distinguish
  "key unset" from "key set to false", so an explicit user opt-out
  fell through to the medRxiv-flag default and line numbers stayed
  on. A small new typst-only Lua filter
  (`typst-bool-overrides.lua`) emits a `line-number-explicit-false`
  sentinel when the user typed an explicit `false`, and
  `typst-show.typ` now consults the sentinel ahead of the
  flag-driven elseif branch. Value-typed overrides (`columns:`,
  `margin:`) were already correct and are unaffected.


# docstyle 0.16.1

## Bug fixes

* `update_extension()` and `use_docstyle()` now rewrite the
  destination project's `_extensions/docstyle/_extension.yml`
  `version:` field to match the installed docstyle package version.
  Previously the bundled source `_extension.yml`'s version field
  was not tracked alongside DESCRIPTION's `Version:` (frozen at an
  early value), so vendored projects always carried a stale manifest
  even immediately after a fresh `update_extension()`. The 0.16.0
  drift warning would have falsely fired on every render of every
  project as a result. Tests added to keep the source manifest
  version coupled to DESCRIPTION going forward.


# docstyle 0.16.0

## New features

* Render-time extension drift warning. The pre-render hook now
  compares the version declared in the project's vendored
  `_extensions/docstyle/_extension.yml` with the installed docstyle
  R package version. If they differ, the render emits a one-line
  warning at the top of its output:

  ```
  [check-extension] WARN: Vendored docstyle extension is v0.1.0 but
  installed R package is v0.16.0. Run docstyle::update_extension() to
  bring the project's _extensions/docstyle/ in sync.
  ```

  Catches the recurring "rendered with a stale extension and didn't
  notice" failure mode (POPCORN's protocol shipped with v0.1.0
  vendored long after the package moved to v0.15+, accumulating
  several weeks of drift). Authors render constantly; surfacing the
  drift at render time aligns the warning with the workflow loop
  most likely to act on it.

  Suppress by adding to `_quarto.yml`:

  ```yaml
  docstyle:
    silence-version-warning: true
  ```

  New exported function `check_extension_drift()` is the
  programmatic entry point — useful for CI checks that gate merges
  on a clean state.


# docstyle 0.15.1

## Bug fixes

* Default CSS now styles `.abstract` and `.abstract-title` distinctly
  from body text — italic, slight indent, smaller font. Quarto's
  `abstract:` YAML metadata gets rendered with Word's "Abstract"
  paragraph style by Pandoc, but in earlier versions docstyle's
  `default.css` had no rule for it, so the abstract inherited Normal
  styling and looked like an unmarked body paragraph rather than
  metadata. Authors using `default.css` now see the conventional
  italic-and-indented abstract block. Authors with custom CSS can
  override `.abstract` / `.abstract-title` to taste
  (Big-Life-Lab/popcorn-review#101 item 3).


# docstyle 0.15.0

## New features

* Post-render output validators (#145). Configure via a
  `docstyle.validators:` block in `_quarto.yml` to run structural
  checks on the rendered docx/pdf/jats outputs and fail the render if
  silent failures are detected. Default off — opt-in by adding the
  block. Each validator can be `error` (fail), `"warn"` (stderr but
  complete), or `false`/omitted (skip).

  ```yaml
  docstyle:
    validators:
      docx:
        no-docstyle-cite-markers: error
  ```

  First validator shipped: `no-docstyle-cite-markers` for docx. Greps
  the rendered `word/document.xml` for `DOCSTYLE_CITE::` text — these
  markers are emitted by the Lua filter and replaced by the post-
  render R hook with proper Word field codes. If the hook silently
  skipped (renv shadowing, missing extension install, etc.), the
  markers leak through as literal text. The validator catches this
  before the broken docx ships to a reviewer or preprint server.
  Recurring failure mode in POPCORN integration; the validator
  catches it at render time instead of submission time.

  More validators (PDF/UA-1 conformance via veraPDF, JATS abstract-
  presence, JATS structured-abstract heuristic) ship in follow-ups.


# docstyle 0.14.1

## Bug fixes

* `docstyle-typst` author-block now renders affiliations as numeric
  superscripts (medRxiv / academic-preprint convention) instead of
  the YAML `id:` strings (#144). Previously a multi-author document
  with `affiliations: [{ ref: ohri }, { ref: uottawa }]` rendered as
  `First Author^ohri,uottawa^` — visible to readers. The Pandoc
  template now emits the affiliation IDs as a separate
  `affiliation_ids` array, and the bundled preprint Typst function
  resolves each ID against the top-level `affiliations:` block to
  emit a 1-based index. The affiliation list at the title page
  footer is also numbered (1, 2, 3) to match.


# docstyle 0.14.0

## New features

* `docstyle-jats` Quarto format produces JATS XML alongside Word and
  Typst output (#134). Rendered XML is JATS Archiving DTD v1.2 — the
  format PMC, Europe PMC, scite, semantic scholar, and other
  scholarly knowledge graphs ingest. Composes with `docstyle-typst`:
  list both formats in `_quarto.yml` and a single `quarto render`
  produces both PDF and JATS from the same source.

  Quarto's default JATS output is already strong out of the box
  (multi-affiliation cross-refs, ORCID, CRediT vocab URIs, tables as
  `<table-wrap>`, references as `<element-citation>`). docstyle's
  contribution is `jats-fixups.lua`, which fills two gaps:

  - **Structured abstract.** Bold-labelled abstract paragraphs
    (`**Background:** ...`) are converted to nested `<sec>` blocks
    with proper `<title>` and `<p>`. PMC and other consumers parse
    the structured form more reliably than `<p><bold>X:</bold>...</p>`.
  - **CRediT canonicalization.** Non-canonical role strings ("writing -
    original draft" with hyphen) are looked up against the canonical
    CRediT vocabulary and rebuilt as full MetaMaps with
    `vocab-identifier` and `vocab-term-identifier` URIs.

* The methods-protocol scaffold (`use_methods_protocol()`) now ships
  with `docstyle-jats` listed alongside `docstyle-typst` in the
  default `_quarto.yml`. New protocols produce both PDF and JATS
  from the start. Constitution principle 2 ("Open science as
  infrastructure") — every docstyle-rendered preprint becomes a
  first-class citizen of the scholarly knowledge graph rather than
  a dead-end PDF.


# docstyle 0.13.0

## New features

* `use_methods_protocol()` scaffolds a methods-protocol Quarto project
  with PRISMA-ScR (scoping reviews) or PRISMA-P (systematic reviews)
  section scaffolding (#133). One command produces a working project
  pre-configured for both Word editing (`docstyle-docx` with Zotero
  field codes) and medRxiv-ready preprint output (`docstyle-typst` with
  `medrxiv: true`). Drops in a scaffolded `protocol.qmd`, a
  `references.bib` skeleton, a `supplements/` directory with a README,
  a project README with a submission checklist, and the bundled
  docstyle extension.

  ```r
  use_methods_protocol(
    path = "my-protocol",
    title = "Protocol working title",
    framework = "prisma-scr"   # or "prisma-p"
  )
  ```

## Bug fixes

* `docstyle-typst` now defines Pandoc's syntax-highlighting token
  classes (`NormalTok`, `KeywordTok`, etc.) so QMDs with inline
  backticks (`` `path/to/file` ``) render without crashing the Typst
  compile (#138). Tokens are rendered as plain monospace by default;
  users wanting coloured syntax highlighting can override the
  definitions in their own template.

* `keywords:` YAML field on `docstyle-typst` no longer crashes the
  Typst compile with "text does not have field 'children'" (#139).
  The bundled preprint Typst function now defensively handles all
  shapes Pandoc emits for the `categories` parameter (single-text
  content, multi-child content, array, string).

## Breaking changes

* `pdf-standard: ua-1` is no longer a format-level default for
  `docstyle-typst`. Reverting the 0.12.0 default. UA-1 conformance
  fails on content patterns common in authored documents — markdown
  bulleted lists, images without alt text, missing document language —
  which were not caught before 0.12.0 shipped. The default is now
  opt-in: users who want UA-1 should set `pdf-standard: ua-1`
  explicitly in their `_quarto.yml` or QMD front matter and verify
  their content passes (veraPDF or similar) before submission. Typst
  still produces tagged PDFs by default (`pdfinfo` reports
  `Tagged: yes`); UA-1 is a stricter conformance level on top of
  basic tagging.


# docstyle 0.12.0

## New features

* `docstyle-typst` now supports a `medrxiv: true` flag for medRxiv-ready
  preprint output (#136). When set, the renderer applies medRxiv-friendly
  defaults — single column, line numbering, 1-inch all-around margins — so
  the resulting PDF is submission-ready without further configuration.
  Users can still override any individual default (`columns:`, `margin:`,
  etc.) and the explicit value wins.

* All `docstyle-typst` output is now PDF/UA-1 tagged by default. Screen
  readers, scholarly knowledge graphs, and PDF data-extraction tools
  benefit. No visual change in well-formed documents; non-conforming
  inputs (images without alt text, missing document language) may now
  warn or error during render — see Typst's `pdf.ua-1` documentation.
  Users can override with their own `pdf-standard:` value if they need a
  different standard. Requires the Quarto 1.9 series (PDF/UA-1 support
  for Typst).


# docstyle 0.11.0

## Breaking changes

* **Removed three Zotero library-management functions: `add_zotero_item()`, `update_zotero_item()`, `update_zotero_doi()`.** These do not belong in a document-styling package (they create, modify, and delete items in a Zotero library via the Web API — unrelated to docx rendering). Callers should migrate to the Python helper at [`DougManuel/ai-infrastructure/skills/zotero-tools/`](https://github.com/DougManuel/ai-infrastructure/tree/main/skills/zotero-tools): `add_zotero_item()` → `add_item()`, `update_zotero_item()` → `update_item()`. The BBT-citekey wrapper `update_zotero_doi(citekey, doi)` has no direct replacement — look up the item key first (e.g. via `find_item()`) then call `update_item(key, {"DOI": doi})`. The new helper also provides a DOI dedup pre-flight that catches the "script POSTed twice" case (the incident that motivated this refactor). From R, invoke the Python helper via `reticulate::py_run_file()` or `system2("python", ...)`; see the helper's `README.md` for examples. Rendering-adjacent Zotero functions (`add_citations_from_zotero`, `inject_zotero_citations`, and the `zotero_pref` family) remain in docstyle — they are genuinely docx-concerned.

## New features

* `package_arxiv()` produces an arXiv-ready submission archive from a
  rendered `.tex` file. Flattens figure subdirectory references
  (`\includegraphics{images/fig.png}` → `\includegraphics{fig.png}`) and
  rewrites the staged `.tex` to match; ships a `.tar.gz` (default) or
  `.zip`. Format-agnostic: takes any LaTeX source, so it composes with
  the upstream `mikemahoney218/quarto-arxiv` extension today and any
  future `docstyle-arxiv` format (#128, #130).

  Additional safeguards:
  - Style discovery parses `\usepackage{}` / `\documentclass{}` and
    bundles only `.sty`/`.cls` files the document actually loads — stale
    styles in the render directory no longer leak into submissions.
  - Bibliography auto-detection for both `\bibliography{refs}` → `.bib`
    and `<tex_stem>.bbl` (biber/bibtex output, required by arXiv).
  - Casing-drift detection: warns when figure paths resolve via
    case-insensitive macOS APFS but reference disk filenames in a
    different case. arXiv's Linux AutoTeX is case-sensitive and would
    otherwise fail silently.
  - AppleDouble-safe: `tar = "internal"` and `COPYFILE_DISABLE=1` prevent
    macOS `._*` metadata files from leaking into the archive (arXiv
    rejects these).
  - Every `file.copy()` and archive-creation call is status-checked;
    failures abort with context rather than shipping a broken archive.

---

# docstyle 0.10.1

## Bug fixes

* `validate_harvest()` now resolves custom heading styles (e.g. `CVH1` basedOn
  `Heading1`, MDPI journal templates, `outlineLvl`-tagged styles) when counting
  source-side headings. Previously reported `source=0, QMD=N` for documents
  using institutional or journal templates even when the harvest itself
  succeeded. The validator now uses the same `resolve_to_canonical()` machinery
  as `docx_to_qmd()`, so source and QMD counts are fair (#126, #127).

* `validate_harvest()` emits a `[validate-harvest]` diagnostic when `docx_path`
  is unavailable, making the degraded exact-match-only heading detection
  visible rather than silently under-counting.


# docstyle 0.10.0

## New features

* `import_citations()` copies citation entries between `_docstyle/field-codes.json`
  files across projects. Accepts directory or file paths; only the `citations` list
  is merged, preserving all other fields in the destination (#102).

* New `docstyle-typst` output format bundles the mvuorre/preprint Typst template
  for PDF/preprint output. A single `authors:`/`affiliations:` block in `_quarto.yml`
  now serves both `docstyle-docx` and `docstyle-typst` formats. The `docstyle.authors`
  block is deprecated (#103, #104).

* `docx_to_qmd()` now writes `_docstyle/harvest-map.json` after every harvest.
  Each entry records the body-child index, plain-text MD5 hash, style, type
  (content/metadata/range/skipped), and QMD line span for paragraph-level
  provenance tracking (#106).

* Custom Word styles from journal and institutional templates (e.g., MDPI's
  `MDPI21heading1`) are now automatically resolved to canonical heading levels
  during harvest via `resolve_to_canonical()` and `build_style_props_lookup()`.
  Resolution uses `outlineLvl` attribute, `basedOn` chain, and display-name
  pattern fallback. See `R/style_resolver.R` (#107, #108).

* Internal Word hyperlinks (`w:hyperlink w:anchor`) are now harvested as
  `[text](#anchor)` Markdown links. `bookmarkStart` elements preceding heading
  paragraphs emit `{#id}` cross-reference IDs on the heading line. Word
  auto-generated bookmarks (`_Toc*`, `_Ref*`, `_GoBack`) are filtered (#96, #110).

---

# docstyle 0.9.0

## New features

* **Configurable Zotero preferences via `_quarto.yml` (#16):** `inject_zotero_components()` now accepts a `zotero_config` list (read from `docstyle.zotero` in `_quarto.yml`) to configure the injected `ZOTERO_PREF` without a Word round-trip. Supported keys: `style` (CSL style URL), `field-type` ("Fields" or "Bookmarks"), `journal-abbreviations` (logical), `store-references` (logical). Priority: stored ZOTERO_PREF from `field-codes.json` > YAML config > `default_style` parameter. `build_zotero_pref_xml()` gains a `journal_abbreviations` parameter (previously hardcoded `TRUE`); `inject_zotero_pref()` gains `field_type`, `journal_abbreviations`, `store_references`.

* **CSS-aware section naming in harvest (#19):** `section_breaks_to_ranges()` now accepts a `page_config` parameter and uses a new `match_css_section_name()` helper to match native Word `sectPr` properties against CSS named `@page` rules. When harvesting a docstyle project (where `_docstyle/page-config.json` exists), sections are mapped to their correct class name (e.g. `.section-body`) instead of the generic fallback. Falls back to `section-body` when no CSS config is available or no match is found.

---

# docstyle 0.8.9

## New features

* **Multi-section test project (#43):** Added `tests/projects/section-matrix/` — a four-section test document covering the full feature matrix: title (no line numbers, default footer), body (continuous line numbers, `Draft` footer, page-start=1), appendix (no line numbers, `Appendix` footer with `{section-pages}`), and back matter (footer suppressed). Verified XML output: 5 sectPr elements, 5 footerReferences, per-section footer files, and lnNumType on the body section only.

## Bug fixes

* **`get_section_page_props()` — line-numbers not propagated (#43):** The function was returning a stripped subset of page_config with only `size`, `orientation`, and `margins`. The `line-numbers` key (containing `count-by` and `distance`) was never carried into section props, so `build_sect_pr_xml()` always produced `w:countBy="1"` regardless of CSS config. Fixed by merging `line-numbers` from root `page_config` when the key is absent in the named section config.

---

# docstyle 0.8.8

## New features

* **`preview_css_mapping()` — dry-run CSS-to-Word style translation (#88):** New exported function that reads a CSS file and prints a formatted summary of how each selector maps to a Word style and how CSS properties translate to OOXML values (margin in pt/twips, font size in pt/half-points, colour as hex). Accepts a single path, multiple paths (merged), or defaults to `default.css`. Useful for debugging CSS configurations without a full render cycle.

---

# docstyle 0.8.7

## New features

* **`find_project_root()` — robust project root discovery (#85):** New exported function that resolves the project root directory for render scripts, walking upward from the current directory to find a `_quarto.yml` with a `project:` or `docstyle:` section, or a `.git` anchor. Prefers `QUARTO_PROJECT_DIR` when set (the authoritative Quarto context). Used by `generate-reference.R` and `update-field-codes.R` to replace fragile fixed-depth parent walks, correctly handling renders from subdirectories.

---

# docstyle 0.8.6

## New features

* **`update()` — one-command project maintenance (#87):** New exported function that combines `check_project()` and `update_extension()` into a single call. Checks project health (9-point check), synchronizes `_extensions/docstyle/` with the installed package version, and prints a unified summary. Equivalent to the previous two-step manual workflow.

---

# docstyle 0.8.5

## New features

* **`title-block-style: none` set as extension default (#86):** The `docstyle-docx` format now sets `title-block-style: none` in `_extension.yml`, suppressing Quarto's default plain-text title block. Previously users had to add this manually to avoid a duplicate author block when `author-plate.lua` was active. Users who need the native title block can override with `title-block-style: default` in their QMD header.

## Bug fixes

* **Author-plate deprecation warning fires even when plate is disabled (#91):** `author-plate.lua` now reads the `docstyle.author-plate.enabled` flag before emitting `docstyle.authors`/`docstyle.affiliations` deprecation warnings. When `author-plate: enabled: false`, no warning is produced.

* **Section page-break removal searches past Pandoc-injected elements (#41-B):** `assemble_section_breaks()` previously used a fixed 5-predecessor limit when searching backward for the `<w:br type="page"/>` to remove before a `nextPage` sectPr. If Pandoc inserted bookmarks, comments, or empty paragraphs between the break and the section marker, the search could miss the break and leave a double page break. The search is now unbounded and stops only when it encounters a paragraph with real text content.

## Tests

* **Section assembly correctness tests (#42):** Added four high-priority tests to `test-section-assembly.R` and `test-section-hf.R`:
  - Deferred nextPage: closing marker immediately followed by opening marker with `page-break=true` produces a single `nextPage` sectPr, not a duplicate
  - Page-break removal (direct): Lua-emitted `<w:br type="page"/>` is removed after `nextPage` sectPr assembly
  - Page-break removal (with intervening empty paragraphs): removal works even when Pandoc inserts empty paragraphs between the break and the section marker
  - Body sectPr continuous: after assembly, the body sectPr has `<w:type w:val="continuous"/>` when the last section is a wrapping div
  - Footer suppression: `footer="false"` resolves to `suppressed = TRUE` (not an omitted reference)

---

# docstyle 0.8.4

## Bug fixes

* **Post-render path resolution: complete fix for output-dir above project root (#89):** The v0.8.3 fix was incomplete. `QUARTO_PROJECT_OUTPUT_FILES` contains paths relative to the project root, but when `output-dir: ../_site/docs` is set in a subdirectory `_quarto.yml`, the resolved path goes above the project root and `normalizePath(file.path(project_dir, path))` still fails. The post-render script now falls back to `QUARTO_DOCUMENT_PATH` (the document's directory, always set by Quarto) as a second resolution base. This correctly resolves `../_site/docs/file.docx` from `docs/` to `/project/_site/docs/file.docx`.

---

# docstyle 0.8.3

## New features

* **`add_zotero_item()` — create new items in a Zotero library via the Web API:** New exported function POSTs a new item to Zotero using the REST API. Accepts an `item_type` (e.g. `"journalArticle"`) and a named list of metadata `fields`. Returns the new Zotero item key invisibly. Requires `ZOTERO_API_KEY` in the environment.

## Bug fixes

* **Post-render citation injection fails when output-dir points above document directory (#89):** `QUARTO_PROJECT_OUTPUT_FILES` can contain paths relative to the document directory (e.g. `../_site/docs/file.docx`) that are invalid from the project root. The post-render script now resolves such paths against `QUARTO_PROJECT_DIR` before checking `file.exists()`, so citation and comment injection work correctly for subdirectory projects.

---

# docstyle 0.8.2

## New features

* **`add_citations_from_zotero()` — direct Zotero injection without Word round-trip (#84):** New exported function populates `_docstyle/field-codes.json` directly from the local Zotero API, bypassing the Word round-trip for adding citations. Requires Zotero running with Better BibTeX. Existing entries are never overwritten; citekeys not found produce a warning. By default (`write_bib = TRUE`) also syncs `_docstyle/references.bib` via `export_bibliography()` for LaTeX/Typst workflows.

* **Figure field codes — Phase 1 harvest (#83):** Images followed by an `ImageCaption` paragraph are now harvested as `.figure` divs with stable IDs derived from Word's internal `wp:docPr/@id`. Harvest produces `_docstyle/figures.json` keyed by drawing ID, enabling stable round-trip identity even when figures are moved or reordered. IDs use the `docstyle-fig-FIXME-N` prefix (rather than `fig-FIXME-N`) to avoid Quarto's built-in `fig-*` cross-reference interception.

* **Figure field codes — Phase 2 render (#83):** New `figure.lua` filter wraps `.figure` divs in `ADDIN DOCSTYLE` field codes at render time, embedding the `id`, `width`, `align`, and `original_path` attributes in the payload. On re-harvest, the stored `id` is restored from the field code (replacing the FIXME placeholder), and `original_path` is used to restore the original image path rather than the Word-assigned `rIdN` reference.

## Bug fixes

* **Distinguish staged vs unknown unresolved citations in render log (#49):** The post-render scan now partitions unresolved `[@citekey]` markers into two categories. Citations with metadata in `field-codes.json` but no citationGroup (e.g., added via `add_citations_from_zotero()` or QMD-first drafting) are reported as `Info: N staged citation(s) pending Zotero insertion in Word`. Citations with no metadata at all are reported as `Warning: N unresolved citation(s) with no metadata — check citekeys or re-harvest`. This eliminates false-alarm warnings during normal QMD-first drafting workflows.

* **Empty section div creates blank page (#74):** Opening and closing section markers with no content between them are now detected in the pre-pass and suppressed entirely. Previously, a `::: section-body ::: ::: section-body-end :::` pair with no content would emit two back-to-back section breaks, creating a blank page. The `has_content_between()` helper walks forward from the opening marker and tags both markers as `skip_empty_pair` when no real content is found.

* **Em/en dash normalization (#78):** Unicode em dashes (`—`) and en dashes (`–`) in harvested text are now converted back to Pandoc's `---`/`--` sequences. This matches the source QMD convention and prevents false positive track-change detection on re-harvest.

* **Spurious version-history div suppressed (#82):** The version-history Lua filter no longer emits an empty `::: version-history :::` div when no version entries are present in the document metadata.

## Tests

* Full suite: 1,761 passing, 0 failures
* Added tests for figure harvest (image+caption div, image-without-caption, multiple figures, figures.json), figure field code round-trip (author ID restored, original_path restored), empty section div suppression, em/en dash preservation, version-history div suppression, and `add_citations_from_zotero()` (unit tests for file I/O, citekey skip/merge, BibTeX write; integration tests against live Zotero)
* **New test files (#31):** `test-utils.R` (43 tests for `%||%`, XML escaping/unescaping, dash normalization, `modify_docx_xml`); `test-generated-content.R` (54 tests for `field_instr_to_placeholder`, `assign_segments_to_positions`, `extract_sectpr_footer_info`, `build_footer_div_attrs`, `check_bookmark_range`)

---

# docstyle 0.8.1

## New features

* **Suppress top spacing after section breaks (#75):** New CSS property `--docstyle-suppress-top-spacing: true` and div attribute `suppress-top-spacing="true"`. Sets `w:before="0"` on the first content paragraph after each section break, eliminating the gap that heading styles with `margin-top` create at the top of a page. Resolution precedence: div attribute > named `@page` > global `@page`.

## Bug fixes

* **Blank paragraph before first heading (#69):** Section marker field code runs are now merged into the adjacent content paragraph, and the marker paragraph is removed. Previously, the cleared marker text left a visible empty paragraph. Field codes are preserved in the content paragraph for harvest round-trip fidelity.

* **Page numbers missing in footer (#70):** `page-start` from wrapping div opening markers (e.g., `::: {.section-appendix page-start="1"}`) is now correctly deferred to the closing marker's `sectPr`. Previously, the assembly loop skipped `page-start` on opening markers that had closing pairs, but never carried the value forward — so `pgNumType` was never written.

* **Per-section header overrides (#71):** Confirmed working via payload shift and cascade resolution. Header attributes on section divs (e.g., `header-left="Custom"`) correctly override YAML defaults for that section.

## Tests

* Full suite: 1,500 passing, 0 failures
* Added tests for marker merge-and-remove, page-start deferral, footer pipeline end-to-end, per-section header overrides, and suppress-top-spacing

---

# docstyle 0.8.0

## New features

### Bootstrap auto-restore

New `_docstyle/pre-render.R` and `_docstyle/post-render.R` bootstrap scripts auto-install the extension from the R package if `_extensions/docstyle/` is missing. This solves the chicken-and-egg problem of gitignoring the extension directory:

* `_extensions/` can now be gitignored — it's auto-restored on every render
* `init()` copies bootstrap scripts and `.gitignore` to new projects
* All preset `_quarto.yml` files updated to use `_docstyle/` bootstrap paths

### Template starter repo

New [DougManuel/docstyle-starter](https://github.com/DougManuel/docstyle-starter) template repo. Users can start with `quarto use template DougManuel/docstyle-starter`.

### Table field codes with CSS-first styling

Tables wrapped in `::: {.table-formal}` or `::: {.table-grid}` divs are now styled via the CSS-first pipeline and wrapped in `ADDIN DOCSTYLE` field codes for round-trip fidelity:

* CSS selectors `.table-formal`, `.table-grid` (plus `th`/`td` sub-selectors) define borders, shading, and font size
* Per-table attributes: `widths`, `font-size`, `header-bold`
* `parse_css_border()` converts CSS border shorthand to OOXML components
* Table styles survive round-trip — div and attributes are restored on harvest
* Rich inline content (character styles, comments) renders correctly inside table cells

### Export bibliography

New `export_bibliography()` function reads CSL JSON from sidecar `field-codes.json` and writes BibTeX format.

### Standard Quarto author metadata

The author-plate Lua filter now uses standard Quarto `author:` metadata (via `by-author`). `docstyle.authors` and `docstyle.affiliations` are deprecated with warnings — use standard Quarto `author:` and `affiliations:` format instead.

## Bug fixes

* Suppress `normalizePath` warning in `read_quarto_config()` when `_quarto.yml` doesn't exist
* Version-history filter now warns when metadata entries exist but no `::: version-history :::` div is in the document
* Fixed `apply_preset()` not copying hidden files (`.gitignore`) due to `list.files()` default behaviour

## Tests

* Full suite: 1,323 passing, 0 failures

---

# docstyle 0.6.1

## Bug fixes

### Invariant-driven section management

Replaced symptomatic patch functions with invariant-based approach for more robust section handling:

* **`deduplicate_page_breaks()`**: Enforces "no consecutive page breaks without intervening content". Removes redundant breaks that cause extra blank pages when Lua filters and Pandoc both emit page breaks.

* **`suppress_structural_paragraphs()`**: Enforces "structural paragraphs never display line numbers". A paragraph is structural if it has no `<w:t>` (text) nodes, regardless of bookmarks, field codes, or comments inside it.

These replace the more targeted (but fragile) `suppress_pre_heading_line_numbers()` and `suppress_pagebreak_line_numbers()` functions, which are now deprecated.

### Stray `:::` paragraph consumption

The Lua filter now consumes standalone `:::` paragraphs that appear when users add fenced div markers. Authors only need to mark section STARTS - no closing markers needed.

See issue #37 and `dev/architecture-review.md` for architectural context.

---

# docstyle 0.6.0

## New features

### Shared schema architecture for field codes

Single source of truth for field code definitions between Lua filters (render) and R harvesters. Eliminates brittle pattern-matching and duplicated registries.

* New `inst/schema/docstyle-field-codes.json` defines all field code types, classes, and metadata
* New `_extensions/docstyle/field-code-utils.lua` shared module with JSON builder, escaping, and schema loading
* All Lua filters (`char-style.lua`, `list-style.lua`, `version-history.lua`, `author-plate.lua`, `toc-field.lua`, `page-section.lua`) refactored to use the shared module
* R harvesters read schema with fallback registries for backwards compatibility
* Accessor functions: `get_char_class_def()`, `get_div_def()`, `get_list_class_def()`

### Schema-driven field code generation

Lua filters now use `field-code-utils.lua` for consistent field code XML generation:

* `fcu.build_char_field_code(style_id, text, class)` - inline char-type field codes
* `fcu.build_div_field_start(name)`, `fcu.build_list_field_start(class)` - block-level markers
* `fcu.build_section_field_start(class, attrs)` - section breaks with attributes
* `fcu.build_block_field_end()` - closing markers
* `fcu.xml_escape()`, `fcu.json_escape()` - consistent escaping

### Benefits

* **DRY**: Field code semantics defined once in schema
* **No pattern matching**: Handlers use class lookup instead of regex
* **Extensible**: Add new class by adding schema entry
* **Testable**: Schema is pure data, easy to validate
* **Maintainable**: Single module for all field code generation

## Tests

* 159 field code tests including schema validation and Lua→R compatibility
* Full suite: 878 passing, 0 failures

---

# docstyle 0.5.0

## New features

### Zotero citation injection via R finisher

New `inject_zotero_citations()` function post-processes rendered DOCX files to inject Zotero citation field codes. Runs automatically in the post-render hook when `field-codes.json` contains citation data.

The finisher:
- Matches citation keys to document text using flexible matching
- Injects `ADDIN ZOTERO_ITEM` field codes with CSL-JSON payloads
- Supports grouped citations with configurable `citationGroups` schema
- Validates injection results with position and context

### citationGroups schema

New schema in `field-codes.json` for grouped citation handling:
- Groups track which citation keys appear together
- Enables correct multi-citation injection (e.g., `(Smith 2020; Jones 2021)`)
- Harvested from source documents, preserved through round-trip

---

# docstyle 0.4.4

## Bug fixes

### Section defaults and trailing sectPr

- Fixed section div defaults not being applied correctly
- Fixed trailing sectPr handling for proper document structure
- Footer cleanup improvements

---

# docstyle 0.4.3

## New features

### Post-render finisher for section structure

New `finalize_docx()` function post-processes rendered DOCX files to fix structural issues that Pandoc's docx writer introduces. Runs automatically as Step 5 in the post-render hook.

The finisher currently:
- Removes leaked line numbers from the body-level sectPr (fixes References/Version History getting line numbers from the reference doc)
- Suppresses line numbers on structural paragraphs (sectPr holders, field code markers, empty spacers before headings)
- Validates opening/closing sectPr elements against DOCSTYLE section markers

### Standalone page break div

New `::: {.page-break} :::` syntax for reliable page breaks in QMD. Emits an explicit `<w:br w:type="page"/>` that Pandoc passes through verbatim, replacing `\newpage` which Pandoc drops near headings and bookmarks.

## Bug fixes

### Body sectPr line number leak

The reference doc's final sectPr carried `w:lnNumType`, which leaked line numbers to the document's final section (typically References or Version History). The finisher now strips this automatically.

### Phantom line numbers on empty paragraphs

Pandoc's required blank line before headings creates empty paragraphs that Word numbers when line numbering is enabled. The finisher adds `w:suppressLineNumbers` to these spacer paragraphs.

## Tests

* 10 new finalize_docx tests (marker parsing, wrapping div detection, body sectPr fix, heading spacer suppression, end-to-end)
* Full suite: 700 passing, 0 failures

---

# docstyle 0.4.2

## New features

### Section div round-trip with field codes

Section divs (`::: {.section-body}`) are now wrapped in ADDIN DOCSTYLE field codes during rendering, enabling harvest round-trip. The field code JSON payload preserves `page-break` and `line-numbers` attributes, so `docx_to_qmd()` can reconstruct the div with all attributes intact.

```markdown
::: {.section-body page-break="true" line-numbers="continuous"}
:::
```

After render → Word editing → harvest, the div is restored as written.

### Explicit `line-numbers` attribute on section divs

Line numbers can now be specified directly on the section div via `line-numbers="continuous"` (or `"page"`, `"section"`, `"false"`), rather than relying solely on CSS `@page` rules. Div attributes override CSS defaults and survive harvest round-trips.

## Bug fixes

### Page break before sections now works reliably

Fixed page breaks being silently dropped when `page-break="true"` was used on section divs. The root cause was the Lua filter's `Pandoc()` function inserting an extra `<w:sectPr>` at document end, creating three sections instead of two. Word dropped the earlier `<w:br type="page"/>` when three sectPrs were present.

The fix moves line number configuration to the reference document's final sectPr (via `generate_reference_doc()`) and removes the extra sectPr from the filter. Page breaks now use an explicit `<w:br w:type="page"/>` paragraph followed by a continuous sectPr, matching Word's native pattern.

### Separate RawBlock emission for section breaks

Section break XML is now emitted as separate `pandoc.RawBlock` elements (one for the page break paragraph, one for the sectPr paragraph) rather than a single concatenated block. This ensures Pandoc's docx writer processes each block independently.

## Documentation

* Updated README with `page-break` and `line-numbers` attribute table for section divs
* Added detailed comments in `page-section.lua` explaining the Pandoc docx writer interaction, the three-sectPr problem, and the reference document approach
* Added `dev/spec-harvest-line-numbers.md` specification

## Tests

* 6 new section field code tests (detection, attribute reconstruction, all combinations)
* Full suite: 620 passing, 0 failures

---

# docstyle 0.4.1

## Bug fixes

### Expected loss classification for revisions and comments (#22, #23)

* New `revisions_in_pPr` pattern classifies formatting-only tracked changes (`w:pPr/w:rPr/w:ins|del`) as expected loss — these are paragraph property changes (numbering, style, spacing) with no text content
* New `revisions_in_field_codes` pattern classifies revisions inside ADDIN DOCSTYLE field code ranges as expected loss
* New `comments_in_field_codes` pattern classifies comments inside ADDIN DOCSTYLE field code ranges as expected loss
* Improved `comments_on_metadata` to use case-insensitive prefix matching, handling style variants like `Title1`, `AuthorName`, `AbstractText`
* Reordered revision loss registry so `revisions_in_pPr` runs before `revisions_empty_content` for more specific classification

### Validation hardening

* `extract_docx_plain_text()` now excludes content inside ADDIN DOCSTYLE field code ranges (not just bookmarks) from word counts
* Fixed heading count validation: generated content headings no longer double-counted between source and QMD
* Table count validation now tracks generated content tables (e.g., version history) and reports them in the summary
* Fixed `build_comments_extended_xml()` crash when `parent_id` is `NA` from JSON null

### Code quality

* Extracted `collect_annotations_in_ranges()` shared helper, eliminating duplicated annotation collection logic between `find_annotations_in_bookmarks()` and `find_annotations_in_field_codes()`
* Simplified field code scanning in `find_annotations_in_field_codes()` using XPath attribute selectors

## Documentation

* Updated harvest, render, and validate-harvest skills for v0.4.0 field codes
* Removed superseded development files

## Tests

* 4 new expected loss classification tests (pPr revisions, field code revisions, field code comments, metadata prefix matching)
* Full suite: 514 passing, 0 failures

---

# docstyle 0.4.0

## New features

### ADDIN DOCSTYLE field codes for round-trip metadata

Replaces `_docstyle_*` bookmarks with `ADDIN DOCSTYLE` field codes as the primary round-trip mechanism. Field codes carry JSON metadata payloads that enable lossless source reconstruction.

#### Inline field codes (UC2: character-styled metadata)

* `char-style.lua` wraps styled spans in `ADDIN DOCSTYLE` field codes with `{"type":"char","version":1,...}` payloads containing the original QMD source
* Shortcodes like `[{{< meta version-summary.date >}}]{.date}` are restored verbatim during harvest instead of being replaced by display text
* Harvest state machine in `extract_formatted_text()` detects `ADDIN DOCSTYLE` field codes and emits the `source` field from the JSON payload

#### Block-level field codes (UC1: generated content divs)

* `version-history.lua`, `author-plate.lua`, and `toc-field.lua` wrap generated OOXML in block-spanning field codes with `{"type":"div","version":1,"name":"..."}` payloads
* New `detect_docstyle_field_codes()` function pre-scans `w:body` children with a nesting-aware state machine to find block-level field code ranges
* Harvest detects field codes first, then falls back to bookmarks for v0.3.1 documents
* Version history table parsing works within field code ranges

### Implementation review hardening

Based on dual-reviewer analysis (`development/implementation-review-2026-01-31.md`):

* Field code detection uses the body-level child directly instead of fragile `xml_parent(xml_parent())` traversal
* All `fromJSON()` calls in `validate_harvest.R` wrapped in `tryCatch` with informative warnings for malformed sidecar JSON
* Schema version validation — warns and falls back to display text for `version > 1`
* Renamed `warn_annotations_in_bookmarks()` to `warn_annotations_in_generated_content()` to reflect dual field code/bookmark scope
* `strip_generated_content()` warns on unclosed divs

## Bug fixes

* Fixed `escape_xml_text` name collision between `inject_zotero.R` (preserves quotes for Zotero JSON) and `validate_zotero.R` (full XML escaping)
* Fixed `test-generate-css.R` referencing wrong CSS path (`extdata/popcorn/` → `extdata/popcorn-theme/`)
* POPCORN protocol integration tests verify structural correctness rather than asserting sync-dependent check results

## Backward compatibility

* Documents rendered with v0.3.1 bookmarks harvest correctly — `detect_docstyle_bookmarks()` runs as fallback when no field codes are detected
* Documents with both field codes and bookmarks: field codes take priority, bookmarks fill gaps
* Pre-v0.3.1 documents (no markers): unchanged behaviour

## Tests

* 48 inline field code tests + 29 block-level field code tests + 53 roundtrip-marker tests + 139 harvest validation tests
* Full suite: 498 passing, 0 failures

---

# docstyle 0.3.1

## Bug fixes

### Generated content round-trip (issue #21)
* Lua filters (version-history, author-plate, toc-field) now wrap generated OOXML in `_docstyle_*` Word bookmarks as round-trip markers
* Harvest detects these bookmarks and restores the corresponding div placeholders (`::: version-history :::`, `::: author-plate :::`, `::: toc :::`) instead of converting generated content to literal markdown
* `extract_docx_plain_text()` excludes bookmarked content from word counts, preventing false positives in text fidelity checks
* `check_harvest_structure()` gains a `generated_roundtrip` check verifying bookmarks are restored as div placeholders
* Fixed `strip_generated_content()` div patterns using ID syntax (`{#version-history}`) instead of class syntax (`version-history`), which didn't match actual placeholders
* Added TOC stripping support to `strip_generated_content()`
* Harvest now warns when tracked changes or comments exist inside generated content bookmarks (these annotations are discarded during harvest)
* Version history table edits are harvested back to YAML `version-history:` metadata when a `_docstyle_version_history` bookmark is detected
* New expected loss patterns (`revisions_in_bookmarks`, `comments_in_bookmarks`) classify annotations inside generated content as expected loss

---

# docstyle 0.3.0

## New features

### Harvest validation
* New `validate_harvest()` validates that a harvested QMD faithfully represents its source Word document using a layered architecture:
  - Precondition gate: XML well-formedness, orphaned comment markers
  - Layer 1 (extraction fidelity): independent XPath on source XML vs sidecar files for citations, comments, and revisions
  - Layer 2 (text fidelity): word count comparison with generated content exclusion and 5%/10% thresholds
  - Layer 3 (structural fidelity): headings, tables, citation placement, revision placement, comment placement
* Extraction-only mode (`qmd_path = NULL`) validates sidecar files without needing a QMD
* Selective layer execution via `checks` parameter
* `docx_to_qmd()` gains a `validate` parameter for automatic post-harvest validation

### Round-trip validation
* New `validate_round_trip()` chains harvest validation with Quarto render and output validation to establish a clean baseline
* Optional `render = FALSE` to validate an existing output without re-rendering

### Expected loss registries
* Revision loss patterns: `revisions_in_tables` (Pandoc limitation), `revisions_empty_content` (formatting-only changes)
* Comment loss patterns: `comments_in_tables`, `comments_on_metadata`, `comments_at_body_level`
* Registries are extensible with new pattern functions

### Reporting
* S3 class `docstyle_validation` with `print()` and `report()` methods
* `print()` provides devtools-style summary; `print(detail = "full")` shows per-ID breakdown
* `report()` generates markdown or text reports

## Internal improvements

* Single DOCX parse: `parse_docx_xml()` unzips and parses once, threaded through all validation layers
* Unified loss classifier: generic `classify_loss()` replaces duplicated revision/comment classification logic
* Shared `print_harvest_checks()` eliminates duplicated print logic between harvest and round-trip reports

---

# docstyle 0.2.0

## New features

### Project setup modes for harvest
* `docx_to_qmd()` gains a `project` parameter with four modes: `"none"` (default), `"init"`, `"update"`, and `"overwrite"` for controlling how harvest interacts with existing project infrastructure
* `"init"` mode creates `_quarto.yml`, CSS, and placeholder divs from a preset on first harvest
* `"update"` mode preserves existing YAML header and merges `_quarto.yml` config when re-harvesting collaborator edits
* New `extract_styles` parameter in `docx_to_qmd()` for extracting Word styles during harvest

### Track changes and comments
* `fix_comment_deletion_nesting()` repositions comment markers that end up after tracked deletions due to Lua filter ordering
* Comment markers inside track change deletions are now preserved correctly

## Bug fixes

* Fixed `inject_zotero_pref()` dropping `_rels/.rels` during DOCX repackaging because `list.files()` was called without `all.files = TRUE`
* Fixed `merge_quarto_config()` writing YAML 1.1 booleans (`yes`/`no`) instead of YAML 1.2 (`true`/`false`), which caused Quarto validation errors

## Documentation

* Updated README with line numbers for manuscript review and section div examples
* Corrected `page-section.lua` header comment to use `section-` prefix (not `page-`)
* Added troubleshooting entries for line numbers and section div class naming

---

# docstyle 0.1.0

## New features

### Zotero round-trip support
* `extract_citations()` now extracts ZOTERO_PREF (document preferences) and ZOTERO_BIBL (bibliography metadata) from source documents, storing them in field-codes.json for re-injection during render
* New `inject_zotero_components()` function injects ZOTERO_PREF into rendered documents if missing, enabling full Zotero functionality for documents starting from vanilla QMD
* New `validate_zotero()` function validates Zotero field code structure (balanced begin/separate/end triples)
* Post-render hook now automatically injects Zotero components and optionally validates (set `DOCSTYLE_VALIDATE_ZOTERO=1`)

### Comment round-trip support
* New `validate_comment_ids()` function checks that QMD comment markers match comments.json before rendering, preventing corrupt DOCX output
* New `sync_comment_ids()` function re-synchronizes comment IDs after Word editing renumbers them, using content-based matching
* `extract_comments()` now preserves paragraph structure in multi-paragraph comments (e.g., numbered lists)
* `build_comments_xml()` now creates proper multi-paragraph structure when injecting comments

## Bug fixes

* Fixed missing spaces in extracted comments where multi-paragraph content was concatenated without line breaks
* Fixed `extract_zotero_pref()` regex to handle nested JSON braces in style preferences
* Fixed ZOTERO_BIBL extraction pattern to allow `]` characters in JSON arrays

## Validation improvements

* New `DOCSTYLE_VALIDATE_ZOTERO=1` environment variable enables Zotero field code validation in post-render hook
* Validation now checks for unbalanced field codes, missing ZOTERO_PREF, and structural issues

---

# docstyle 0.0.0.9000

* Initial development version
* Basic DOCX to QMD conversion with comment and revision tracking
* Comment injection via Lua filter and post-render hook
* Zotero citation extraction to CSL-JSON
