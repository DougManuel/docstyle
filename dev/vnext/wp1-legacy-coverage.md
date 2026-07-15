# WP1 Legacy Coverage Audit

## Purpose and scope

This document is acceptance test 9 for Docstyle vNext work package 1 (WP1):
every legacy data element from release 0.19.0 gets exactly one
classification, so nothing already in the legacy system falls through the
gap between WP1's schemas and the work packages that follow it.

A legacy data element is anything the current writer or harvester persists
or reads as data: an `ADDIN DOCSTYLE` field-code payload type or key, a
sidecar JSON file or one of its top-level fields, a QMD authoring
convention (div, class or attribute), or a front-matter YAML key. Transient
in-process values (for example, the `DOCSTYLE_SECTION`/`DOCSTYLE_CITE`
text-marker vocabulary that Lua filters emit for the R post-render phase to
consume within the same render pass) are not data elements in this sense:
they carry no persisted state across a render, so they are out of scope
here. `DOCSTYLE_SCHEMA_VERSION` (the writer-version constant) is the same
concept as the `version` field-code key already inventoried below and is
not counted twice.

Three classifications are possible, matching the WP1 implementation plan:

- **mapped** -- a vNext WP1 schema and field already exist for this element.
- **assigned** -- no WP1 schema field exists; a later work package (WP2
  text layer, WP3 production model builder and property model, WP4
  citations and reference rendering, or WP5 reconciliation and the real
  migration driver) owns building it.
- **dropped** -- the element is discarded, with the rationale recorded.

Presentation properties are assigned to WP3 and OOXML-level rendering
behaviour is assigned to WP2 or WP4 without re-deriving the mechanics
already implemented in the current `R/` and Lua sources; this audit records
where each element's data lives next, not how the current renderer
produces it.

## Methodology and sources

Commands run, per the task brief:

```bash
jq -r '.. | objects | keys[]' inst/schema/docstyle-field-codes.json | sort -u
rg -o 'DOCSTYLE_[A-Z_]+' _extensions/docstyle/*.lua R/*.R | sort -u
rg -l 'write_json|toJSON' R/*.R
rg -o '"[a-z-]+"\s*=' R/field_codes.R R/generated_content.R | sort -u
rg -o 'docstyle[.-][a-z-]+' R/*.R _extensions/docstyle/*.lua | sort -u
```

The `jq` command returned the four class registries and two field
glossaries in `inst/schema/docstyle-field-codes.json` (five `char_classes`,
four `div_types`, two `list_classes`, two `table_classes`, 15
`anchor_payload_fields`, six `figure_payload_fields`). Cross-checking these
21 field-glossary names
against `tests/vnext/conformance/legacy/key-map.json`'s 34-key table found
an exact match with no gaps -- confirming `key-map.json` (Task 8's own
disposition inventory, built from the authoritative
`docstyle_schemas` list in `R/field_codes.R`) already accounts for every
payload key named in the JSON schema glossary. Payload types and keys
below take `key-map.json`'s dispositions as the authoritative account of
migration behaviour rather than re-deriving them, as instructed.
Disposition and audit classification are related but distinct: `mapped`
and `dropped` dispositions carry over directly, while `record`-disposition
keys are classified under the ruling stated ahead of the inventory table.

The `rg 'DOCSTYLE_'` command found nine marker names; all nine are the
intra-render text-marker vocabulary described above and are out of scope
(see Purpose and scope).

The `rg -l 'write_json|toJSON'` command found the thirteen `R/` files that
write sidecar JSON. Reading each writer function gave the top-level field
list for every one of the ten sidecars in
`tests/vnext/fixtures/legacy-contract.json`. The three durable sidecars
(`field-codes.json`, `comments.json`, `revisions.json`) are the ones
`tests/vnext/conformance/lib/migrate.lua` actually transforms today, so
their fields are enumerated individually below. The seven generated
sidecars are each recorded as one row, with their top-level fields listed
in the Notes column, because within each of those files every field shares
the same classification and target.

None of these three durable sidecars appear among the WP0 characterization
baselines (`tests/vnext/fixtures/*/baseline/legacy/`, which capture only
the rendered `docstyle-docx`/`-typst`/`-jats` outputs plus their inventory
and manifest JSON; every editing-session-only sidecar is absent from those
captures). The real-shape
evidence this audit and `lib/migrate.lua`'s real-shape sidecar test case
rely on -- id-keyed JSON objects rather than arrays, `content` instead of
`text`, `citationGroups`'s `citekeys`/`instrText` rather than
`keys`/`instruction` -- is read directly from the R writer functions
(`R/comments.R`, `R/revisions.R`, `R/extract_citations.R`), not from a
captured baseline file.

The `rg '"[a-z-]+"\s*='` command against `R/field_codes.R` and
`R/generated_content.R` returned only the eight payload-type dispatch
strings (the type-to-handler switch); the deeper per-type key lists live in
`docstyle_schemas`, already captured via `key-map.json` as above.

The `rg 'docstyle[.-][a-z-]+'` command returned 28 distinct strings once
deduplicated across files (deduplicating only within one file's matches
under-counts, since `sort -u` on `rg`'s `file:match` output does not merge
the same match found in different files). Most are internal code
references to YAML keys and div/class conventions already named in
CLAUDE.md's conventions list (`docstyle.validators`,
`docstyle.silence-version-warning`, `docstyle.authors`,
`docstyle.affiliations`, `docstyle-abstract`, `docstyle-field-codes`, and
so on) and are inventoried below under their conventional names.
`docstyle.toc`, `docstyle.zotero` and `docstyle.date`/`docstyle.version`
surfaced distinct front-matter YAML conventions not on CLAUDE.md's list
and are added below, as are three further per-feature render-config blocks
found by reading each match in context: `docstyle.page` (an inline-YAML
fallback for page layout, read by `page-section.lua` when
`page-config.json` is absent), `docstyle.version-history` (heading text,
heading level, column widths and table style for the rendered
version-history table) and `docstyle.author-plate` (corresponding/equal
contributor markers, ORCID and email display, affiliation style for the
rendered author plate).

The remaining matches were reviewed and excluded as not user-facing data:
`docstyle-docx`, `docstyle-typst`, `docstyle-arxiv` are Quarto format
identifiers used for format selection rather than a data field; `docstyle-generated`,
`docstyle-injected`, `docstyle-namespaced`, `docstyle-specific` are
descriptive language inside code comments, not literal keys or classes;
`docstyle.bak`, `docstyle.lua` are the extension's own backup-directory and
filter-file naming; `docstyle-cite-markers` and `docstyle-fig-` are
fragments of, respectively, the `docstyle.validators` check id and a
rejected legacy id-prefix pattern CLAUDE.md documents as superseded, both
already covered under rows recorded elsewhere.

Standard Quarto `author:`/`affiliations:` front matter and its deprecated
`docstyle.authors`/`docstyle.affiliations` predecessor are inventoried
because CLAUDE.md's "Common mistakes" section calls out the deprecation by
name and the current metadata-core.v1 schema turns out to match the
Quarto-normalized shape closely, aside from two sub-fields noted in the
table below.

## Element inventory

One ruling applies to 29 payload-key rows at once and is stated here
rather than repeated in each row's Notes. Keys whose only WP1 handling is
the migration record -- exactly the 29 keys carrying `key-map.json`'s
`record` disposition -- are classified assigned, target WP3 property
model, because the definition of mapped requires a WP1 schema and field
and no WP1 schema types these values. Today's migration folds them into
the migration record, whose canonical encoding feeds the field-envelope
`hash`: that gives change detection, and nothing more -- the hash is
one-way, so the values are carried for comparison rather than stored in a
typed, recoverable form. Their intended vNext carrier is the
document-model node's `attrs` object, which WP1 deliberately leaves
untyped; WP3's property matrix is where each value gets a typed field.
`key-map.json` itself is unchanged by this ruling: its `record`
disposition accurately describes what `migrate.lua` does with these keys,
and the correction here is to how that behaviour is classified under the
audit's definitions.

| Element | Source | Classification | Target | Notes |
|---|---|---|---|---|
| Field-code payload type `char` | `key-map.json` (`R/field_codes.R` `docstyle_schemas`) | mapped | field-envelope.v4 kind `span`, policy `authored-preserve` | |
| Field-code payload type `div` | `key-map.json` | mapped | field-envelope.v4 kind `section`, policy `authored-preserve` | |
| Field-code payload type `list` | `key-map.json` | mapped | field-envelope.v4 kind `list`, policy `authored-preserve` | |
| Field-code payload type `section` | `key-map.json` | mapped | field-envelope.v4 kind `section`, policy `structural` | |
| Field-code payload type `table` | `key-map.json` | mapped | field-envelope.v4 kind `table`, policy `authored-preserve` | |
| Field-code payload type `figure` | `key-map.json` | mapped | field-envelope.v4 kind `figure`, policy `authored-preserve` | |
| Field-code payload type `float` | `key-map.json` | mapped | field-envelope.v4 kind `anchor`, policy `structural` | Legacy alias of `anchor` (backward-compatible dispatch) |
| Field-code payload type `anchor` | `key-map.json` | mapped | field-envelope.v4 kind `anchor`, policy `structural` | |
| Field-code payload key `type` | `key-map.json` | mapped | field-envelope.v4 `kind` (derived via payload-type lookup rather than copied verbatim) | |
| Field-code payload key `version` | `key-map.json` | mapped | field-envelope.v4 `v` (constant 4; legacy value only gates the 1--3 support range) | |
| Field-code payload key `name` (div) | `key-map.json` | mapped | field-envelope.v4 `id` | |
| Field-code payload key `id` (figure) | `key-map.json` | mapped | field-envelope.v4 `id` | |
| Field-code payload key `class` | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `source` (char) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above; carried in the record as `legacySource` -- declared bound 5 |
| Field-code payload key `start` (list) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `page-break` (section) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `line-numbers` (section) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `widths` (table) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `width` (table, figure) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `font-size` (table) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `header-bold` (table) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `header-shading` (table) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `label` (table) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `docpr_id` (figure) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `align` (figure) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `wrap` (figure) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `original_path` (figure) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `alt` (figure) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `vertical_anchor` (float, anchor) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `horizontal_anchor` (float, anchor) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `position_y` (float, anchor) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `position_x` (float, anchor) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `float_width` (float, anchor) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `wrap_style` (float, anchor) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `wrap_side` (float, anchor) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `wrap_distance` (float, anchor) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `adjacent` (float, anchor) | `key-map.json` | dropped | No consumer exists; documented upstream as deferred (`inst/schema/docstyle-field-codes.json`, issue #117) | |
| Field-code payload key `content_hint` (anchor) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `z_layer` (anchor) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `content_mode` (anchor) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `caption_y` (anchor) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Field-code payload key `image_height` (anchor) | `key-map.json` | assigned | WP3 property model | Migration-record ruling above |
| Sidecar `field-codes.json` fields `citations`/`citationGroups` | `R/extract_citations.R` | mapped | state-citations.v1 `citations[]` (`id`, `keys`, `instruction`, `privacy`) via `migrate.sidecars` | The real per-citekey `citations` shape (`itemData`/`uris`) is a separate item catalogue, out of scope here (WP4); the real `citationGroups` shape (`citekeys`/`instrText`, `R/extract_citations.R:306-312`) is what `migrate.sidecars` normalizes into `citations[]`, preferring `citationGroups` when present and falling back to a `citations` container of `{keys, instruction}` entries for the synthetic test shape |
| Sidecar `field-codes.json` field `zotero_pref` | `R/extract_citations.R` | mapped | state-citations.v1 `zoteroPref` | |
| Sidecar `field-codes.json` field `zotero_bibl` | `R/extract_citations.R` | assigned | WP4 (bibliography rendering) | Not read by the current `migrate.sidecars` |
| Sidecar `field-codes.json` bookkeeping fields `docstyle_version`, `source`, `references_hash`, `extracted_from`, `extracted_at` | `R/extract_citations.R` | mapped | report-envelope.v1 (`operation`, `toolVersion`, `inputs[].hash`) | `migrate.sidecars` currently hardcodes `toolVersion` rather than reading these legacy stamps (Task 8 deferred minor); report-envelope.v1 carries no timestamp property, so `extracted_at` specifically has no counterpart field yet |
| Sidecar `comments.json` fields `id`, `author`, `date`, `content` | `R/comments.R` | mapped | state-annotations.v1 comment (`id`, `author`, `date`, `text`) | Legacy `content` becomes schema `text`; `migrate.sidecars` normalizes the real id-keyed object container (`comments[[id]] <- ...`, `R/comments.R:87`) to the schema's array shape by iterating a sorted key list, so a real object-keyed `comments.json` migrates the same way as the synthetic array fixture |
| Sidecar `comments.json` field `parent_id` | `R/comments.R` | assigned | WP5 (reply-threading reconstruction into the nested `replies[]` shape) | Current `migrate.sidecars` does not build `replies`; flat legacy threading is dropped on the floor until a real driver exists |
| Sidecar `comments.json` field `para_id` | `R/comments.R` | assigned | WP5 anchor resolution | Word's paragraph-threading id (the last `w:p` paraId inside the comment's content); this is the anchor-identity data the WP5 reconciliation driver needs to replace `migrate.sidecars`'s placeholder `legacy-anchor-*` values with real anchors |
| Sidecar `comments.json` field `initials` | `R/comments.R` | dropped | Derivable from `author` at render time; not persisted separately | |
| Sidecar `comments.json` field `done` | `R/comments.R` | assigned | WP5 migration driver | state-annotations.v1's comment shape has no resolved-status field yet; flagged as an open question in the task report |
| Sidecar `revisions.json` fields `id`, `author`, `date`, `content` | `R/revisions.R` | mapped | state-annotations.v1 revision (`id`, `author`, `date`, `text`) | Legacy `content` becomes schema `text`; `migrate.sidecars` normalizes the real id-keyed object container (`revisions[[rev_id]] <- ...`, `R/revisions.R:61`) to the schema's array shape the same way as `comments.json` above |
| Sidecar `revisions.json` field `type` | `R/revisions.R` | mapped | state-annotations.v1 revision `op` | `insertion`/`deletion` normalized to `insert`/`delete` by `migrate.lua`'s `normalize_op` |
| Sidecar `revisions.json` field `initials` | `R/revisions.R` | dropped | Derivable from `author` at render time; not persisted separately | |
| Sidecar `references.json` | `R/extract_citations.R` | assigned | WP4 (CSL-JSON bibliography cache) | Array of CSL-JSON records keyed by citekey |
| Sidecar `page-config.json` | `R/page_layout.R`, `_extensions/docstyle/generate-reference.R` | assigned | WP3 property model | Fields: page size/margins/orientation/line-numbers/named sections, `footer`, `header`, `sections`, `table_styles`, `anchor_styles` |
| Sidecar `style-map.json` | `R/style_map.R` | assigned | WP3 property model | Flat Pandoc-style-id to template-style-id map |
| Sidecar `section-map.json` | `R/section_map.R` | assigned | WP5 (paragraph-correspondence reconciliation) | Fields: `docstyle_version`, `sections[]` (`index`, `section_class`, `para_position`, `is_closing`, `line_numbers`, `field_code_payload`), `body_section`; likely destination is state-regions.v1 once a real driver exists |
| Sidecar `harvest-map.json` | `R/harvest_map.R` | assigned | WP5 (diff-and-patch reconciliation) | Per-body-child provenance entries (`para_index`, `type`, `qmd_lines`, `para_hash`, `style`, `range_name`, `range_type`, `para_span`, `text_preview`) |
| Sidecar `figures.json` | `R/docx_to_qmd.R` | assigned | WP3 (feeds document-model.v1 `registries.assets`) | Fields per entry: `docpr_id`, `qmd_id`, `caption`, `alt`, `width`, `align`, `wrap`, `original_path` |
| Sidecar `styles.json` | `R/style_manager.R` | assigned | WP3 property model | Fields: `styles` (per-style `custom`, `outline_level`, `used`), `hierarchy`, `linked_pairs`, `docstyle_version`, `source_file`, `extracted_at` |
| QMD div `bibliography` | CLAUDE.md; `R/inject_zotero.R` | assigned | WP4 (citation rendering) | |
| QMD div `docstyle-abstract` (field-code `div_types.abstract`) | CLAUDE.md; `inst/schema/docstyle-field-codes.json`; `R/relocate_abstract.R` | mapped | document-model.v1 `section` node, `role` = `abstract` | |
| QMD div class convention `section-*` (for example `.section-body`, `.section-appendix`) | CLAUDE.md; `R/css_reader.R` | assigned | WP3 structural property model | Authoring-side CSS-class convention; distinct from, but persisted into, the field-code payload `class` key above |
| QMD anchor CSS classes (for example `.column-margin`, `.journal-sidebar`) | CLAUDE.md; `extract_anchor_styles()` in `R/css_parser.R` | assigned | WP3 structural property model | Resolved into `page-config.json`'s `anchor_styles` |
| Field-code div type `toc` | `inst/schema/docstyle-field-codes.json` | assigned | WP3 (structural regeneration, no persisted authored content) | Linked to YAML key `docstyle.toc` below |
| Field-code div type `version-history` | `inst/schema/docstyle-field-codes.json` | mapped | metadata-core.v1 document `versionHistory` | Rendered form of the YAML key of the same name below |
| Field-code div type `author-plate` | `inst/schema/docstyle-field-codes.json` | mapped | metadata-core.v1 `person` and `organization` records | Rendered form of `author:`/`affiliations:` YAML below |
| QMD div attributes `page-break`, `line-numbers`, `suppress-top-spacing`, `content-mode`, `widths` | CLAUDE.md; `page-section.lua`, `anchor.lua`, `table-style.lua` | assigned | WP3 property model | Authoring-time attribute syntax read by Lua filters, persisted into the field-code payload keys of near-identical name above; `suppress-top-spacing` has a second authoring path as a `--docstyle-suppress-top-spacing` CSS custom property; the attribute is hyphenated (`content-mode`) while the payload key uses `_` (`content_mode`) |
| Char class `date` | `inst/schema/docstyle-field-codes.json` `char_classes` | mapped | metadata-core.v1 document `dates` | `harvests_to: version_summary.date` |
| Char class `version` | `inst/schema/docstyle-field-codes.json` `char_classes` | mapped | metadata-core.v1 document `version` | `harvests_to: version_summary.version` |
| Char class `sc` (small caps) | `inst/schema/docstyle-field-codes.json` `char_classes` | assigned | WP3 property model | Presentational only; no `harvests_to` |
| Char class `author` | `inst/schema/docstyle-field-codes.json` `char_classes` | assigned | WP3 property model | Presentational only; no `harvests_to` |
| Char class `affiliation` | `inst/schema/docstyle-field-codes.json` `char_classes` | assigned | WP3 property model | Presentational only; no `harvests_to` |
| List class `list-alpha` | `inst/schema/docstyle-field-codes.json` `list_classes` | assigned | WP3 property model | |
| List class `list-roman` | `inst/schema/docstyle-field-codes.json` `list_classes` | assigned | WP3 property model | |
| Table class `table-formal` | `inst/schema/docstyle-field-codes.json` `table_classes` | assigned | WP3 property model | |
| Table class `table-grid` | `inst/schema/docstyle-field-codes.json` `table_classes` | assigned | WP3 property model | |
| YAML key `version-history` (front matter) | CLAUDE.md; `_extensions/docstyle/version-history.lua` | mapped | metadata-core.v1 document `versionHistory` | |
| YAML key `version-summary` (date/version block) | CLAUDE.md; `inst/schema/docstyle-field-codes.json` `char_classes` | mapped | metadata-core.v1 document `dates`/`version` | Exact sub-field of `dates` (created/modified/published) is a driver decision rather than a schema gap |
| YAML key `medrxiv` | CLAUDE.md | assigned | WP3 render config | Submission defaults: columns, margins, line-numbering |
| YAML key `base-doc` | CLAUDE.md | assigned | WP3 render config | Template-generation opt-out |
| YAML key `docstyle.validators` | CLAUDE.md; `R/validate_output.R` | assigned | WP4 render config | The `docx.no-docstyle-cite-markers` check is citation-pipeline-specific; the other three (`jats.well-formed`, `jats.abstract-present`, `pdf.tagged`) are format-structural and could equally sit with WP3 |
| YAML key `docstyle.silence-version-warning` | CLAUDE.md; `R/check_extension_drift.R` | assigned | WP3 (extension/build-tooling config) | |
| YAML key `docstyle.toc` | `_extensions/docstyle/toc-field.lua`; `R/css_injection.R` | assigned | WP3 (TOC generation config) | Linked to field-code div type `toc` above |
| YAML key `docstyle.zotero` | `R/validate_zotero.R` | mapped | state-citations.v1 `zoteroPref` | Authoring-side origin of the same data already mapped from sidecar field `zotero_pref` above |
| YAML key `docstyle.page` (inline page-layout fallback) | `_extensions/docstyle/page-section.lua` | assigned | WP3 property model | Testing-oriented fallback input (`size`, `orientation`, `margins`) feeding the same internal structure as `page-config.json` above, used when that sidecar is absent |
| YAML key `docstyle.version-history` (render config) | `_extensions/docstyle/version-history.lua` | assigned | WP3 render config | Controls heading text/level, column `widths` and table style of the rendered table; distinct from the `version-history` entry data above |
| YAML key `docstyle.author-plate` (render config) | `_extensions/docstyle/author-plate.lua` | assigned | WP3 render config | Controls corresponding/equal-contributor markers, ORCID and email display, affiliation style; distinct from the `author:`/`affiliations:` data below |
| YAML `author:`/`affiliations:` (standard Quarto, Quarto-normalized `by-author`) | CLAUDE.md; `_extensions/docstyle/author-plate.lua` | mapped | metadata-core.v1 `person` (`name.given`/`name.family`, `orcid`, `roles`, `corresponding`, `affiliations`) and `organization` (`name`, `ror`) | The QMD author block also carries `email` and `equal-contributor`, neither present on metadata-core.v1's `person` shape yet |
| YAML `docstyle.authors`/`docstyle.affiliations` (deprecated) | CLAUDE.md; `R/metadata_inject.R`; `_extensions/docstyle/author-plate.lua` | mapped | Same target as `author:`/`affiliations:` above | Deprecated in favour of standard Quarto `author:` per CLAUDE.md's common-mistakes list |
| YAML keys `docstyle.date`/`docstyle.version` (preferred-over-plain override) | `R/metadata_inject.R` | mapped | metadata-core.v1 document `dates`/`version` | Same target as char classes `date`/`version` and `version-summary` above; an alternate override path for the same document properties |

Row count: 92. 29 mapped, 60 assigned, 3 dropped.

## Declared bounds

1. **NFC assumption (Task 2).** WP1 canonicalization assumes input text is
   already Unicode NFC; Pandoc Lua exposes no normalizer. The contract in
   the spec stands as written; NFD-input normalization lands with the
   production model builder (WP3) or the WP2 text layer. Acceptance test 4
   runs on NFC fixtures only; LF line-ending normalization is implemented
   in the hash input preparation.
2. **Regex dialect subset (Task 1; narrowed at the pre-merge review).**
   Schema `pattern` strings now use a documented dual-dialect subset --
   bracket character classes (`[0-9]`, `[0-9a-f]`, `[a-z]`), single-literal
   brackets for characters that are metacharacters in one dialect or the
   other (`[-]`, `[.]`), the `^`/`$` anchors, and `{n}`/`{n,m}` brace
   repetition (expanded by `lib/jsonschema.lua` before matching, and native
   to ECMA regular expressions) -- so the same literal pattern string
   validates identically under this harness's Lua-pattern validator and a
   standard ECMA-regex engine. Verified empirically for every date, ORCID
   and semver pattern in `schemas/`, both against `lib/jsonschema.lua`
   directly and cross-checked against Python's `re` module as an ECMA-regex
   stand-in. The remaining bound is narrower than before: `lib/jsonschema.lua`
   itself still implements only this subset, not full ECMA regular
   expressions (no alternation, lookaround, non-capturing groups or
   backreferences), so a schema author must stay inside the documented
   subset for a `pattern` to validate correctly in this harness.
3. **`anchor` node-type addition.** The 17th node type, `anchor`, was added
   to the `document-model.v1` and `field-envelope.v4` type/kind enums
   beyond the approved specification's illustrative list, because the
   legacy `float` and `anchor` field-code payload types need a
   positioned-content kind. This is a spec revision and is flagged here for
   review.
4. **Acceptance-test-8 reading.** The reconciliation rules named in
   acceptance test 8 are spec contracts consumed by WP5, not something WP1
   executes. WP1's scope is verifying their data preconditions: that ids,
   hashes and policies are present in every schema the rules will operate
   over. `tests/vnext/conformance/tests/test-migrate.lua` exercises the
   migration primitives those preconditions depend on; it does not
   exercise the six reconciliation rules themselves.
5. **`source` payload-key rename.** The legacy `char` payload's `source`
   key (literal QMD shortcode text, for example
   `[{{< meta version-summary.date >}}]{.date}`) is stored under
   `legacySource` in the migration record, not under its legacy name. This
   is because `hashes.content_hash()`'s provenance strip list removes any
   key named `hash` or `source` at every depth; keeping the legacy name
   would silently exclude the shortcode text from the envelope hash. This
   is the only migration-record key whose name differs from its legacy
   key.
6. **v1/v2 evidence gap.** The WP0 baseline captures contain no v1 or v2
   field-code payloads -- every payload observed in the three frozen
   0.19.0 render baselines is writer-v3. The v1 and v2 mapping cases under
   `legacy/cases/` were sourced verbatim from `tests/testthat/` fixture
   strings instead, each cited by file and line in its case file. This is
   a genuine evidence gap in the WP0 characterization rather than a defect
   in the migration logic, and is worth closing if a v1- or v2-authored
   document ever surfaces in the field.

## Completion statement

No element remains unclassified.
