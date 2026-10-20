# Docstyle vNext WP3 Source and CSS Compiler Design

Date: October 16, 2026

Work package position: WP3, "source and CSS compiler", in the programme
specification. This specification precedes the WP3 implementation plan.

Status: accepted October 20, 2026, after three rounds of independent review.

Depends on: WP1 schemas and state model (#30, merged); the metadata-binding
specification (#49, merged) and its amendment 1 (accepted October 20,
2026); the metadata-binding implementation (#57, merged), which supplies the
catalogue library and the contribution, contact and metadata-view schemas;
and the WP2 package core (#52, merged) for shared runtime conventions
and DOCX inspection.

## Context

The programme architecture places a **source normalizer** between authored
input and every backend:

```text
QMD + YAML + CSS + metadata profiles + durable state
        -> source normalizer (WP3)
        -> semantic document model + presentation plan
        -> DOCX backend (WP4), Typst/PDF and JATS backends (WP6)
```

WP3 has six programme bullets: normalize QMD and YAML into the semantic
model; implement the supported CSS parser and cascade; represent document,
page, section and element properties; add backend capability diagnostics;
publish the initial cross-format property-equivalence matrix; and preserve
semantic lists and tables through the filter pipeline. WP1 fixed the model,
identifier, hash, state and report contracts. The metadata-binding
specification fixed the QMD-to-record mappings ("the WP3 compiler implements
exactly these mappings; nothing else reads author YAML"), and amendment 1
settled the remaining binding questions.

Four bodies of evidence informed this design.

1. **Contract survey.** Every obligation the programme, WP1 and
   metadata-binding specifications place on WP3, with the gaps between them.
   The most consequential gap: `document-model.v1` has no place for resolved
   presentation, and the WP1 hash covers node `attrs`, so presentation
   stored in a node would make a CSS edit look like a content change.
2. **Legacy inventory.** The legacy engine parses CSS with regular
   expressions and no tokenizer. It has no specificity. A later duplicate
   selector block replaces the earlier one wholesale at the earlier one's
   position. It mis-parses `@media`, nested braces and quoted semicolons
   without error, ignores unknown properties and selectors silently, and
   treats `em` as a fixed 12 points. A survey of 12 real stylesheets (781
   declarations) found 119 declarations on selectors the legacy engine never
   maps and 53 on unsupported properties.
3. **Quarto runtime spikes** (Quarto 1.9.26, Pandoc 3.8.3).
   - At the `pre-quarto` filter stage, Quarto has already normalized authors
     into `by-author` while shortcodes are still unexpanded.
   - A custom author sub-field such as `email-public` survives under
     `by-author[i].metadata`; `corresponding` and `equal-contributor` arrive
     under `attributes`.
   - Quarto parses a plain name in the BibTeX manner: "Maria da Silva
     Santos" gives family "Silva Santos" and "Ludwig van Beethoven" gives
     family "Beethoven", with the full form only in `name.literal`. A
     single word becomes the family name.
   - An explicit author or affiliation `id` survives; Quarto fills missing
     ones by position (author `1`, affiliation `aff-1`).
   - A filter can handle Quarto's `Shortcode` custom node, read
     `name = "meta"` and its key, and replace each occurrence with an
     identified span that survives to the output.
   - At the `post-quarto` stage, figures and tables are still Quarto
     `FloatRefTarget` custom nodes, and a handler receives their identifier
     and type.
   - Both passes run in one Lua state per format, so they share module-level
     tables; each output format is a separate run with its own AST.
   - `quarto typst query` returns the values Typst resolved for a labelled
     `metadata` probe, after the template's own settings.
4. **Two rounds of independent review.** The first found an
   identifier-reuse order that misassigns identifiers after an insertion,
   undefined multi-format behaviour and a set of contract gaps; the second
   found that the first revision's pairing could still move identifiers
   between unrelated content. Every finding was checked against the code
   and the specifications before revision.

## Goals

1. Normalize QMD and YAML into the WP1 semantic model and metadata records,
   exactly as the metadata-binding specification and amendment 1 prescribe.
2. Assign stable region and record identifiers and persist them in durable
   state, so an identifier stays on its own content across edits.
3. Compile a documented CSS subset with a real tokenizer, an explicit
   cascade and a recorded source for every resolved value.
4. Represent document, page, section and element properties in a
   backend-neutral presentation plan, kept apart from the hashed model.
5. Diagnose every unsupported or approximated property for each backend
   from a published capability matrix, and define how equivalence across
   backends is compared.
6. Keep lists and tables as semantic Pandoc structures through the filter
   pipeline.
7. Run deterministically on Quarto's bundled Lua, with no R or Python.

## Non-goals

- OOXML emission, Word style XML, field codes and catalogue embedding (WP4).
- The DOCX return path, reconciliation and QMD patches (WP5).
- Typst and JATS output and visual baselines (WP6).
- Machine-interface commands (WP7) and project migration (WP8). WP3 accepts
  legacy forms with deprecation warnings but does not rewrite projects.
- Full browser CSS. The subset stays small, documented and tested.
- Inferring semantic regions from typography.
- Domain profiles such as PICOS and PCC.

## Decision summary

| # | Decision | Section |
|---|---|---|
| 1 | Two filter passes: `pre-quarto` normalization, `post-quarto` model construction; CSS compiled inside the filter, no pre-render script | 1 |
| 2 | Each output format is a separate compile; identities are shared, while layouts, hashes and caches are kept per format; only DOCX runs write DOCX-specific state | 1.1 |
| 3 | Presentation lives in a separate, unhashed presentation plan keyed by node id; presentation attributes and unregistered classes never enter hashed content | 2.3, 6 |
| 4 | Every Pandoc block and inline element, and Quarto's callouts, has a normative mapping | 2.1, 2.2 |
| 5 | Identifier reuse aligns the new tree with the prior tree by content, in order, as a text-comparison tool aligns lines; this revises the WP1 tier order | 3.2 |
| 6 | Record identifiers follow fixed derivation rules; Quarto's positional ids are treated as absent | 3.3 |
| 7 | State commits carry every entry forward; garbage collection keeps referenced files | 3.4 |
| 8 | Durable state is committed to version control only in private repositories; a split of shareable and restricted state is proposed | 3.5 |
| 9 | The compiler implements Unicode NFC with vendored composition data | 2.5 |
| 10 | Every `{{< meta key >}}` occurrence becomes a generated region: a metadata view when the key has a record path, otherwise a `quarto-meta` region | 4.4 |
| 11 | Placement uses reserved `docstyle-` classes; legacy names are accepted with a deprecation warning | 4.4 |
| 12 | Every audit-assigned legacy key, class, sidecar and payload key has a stated destination | 4.6, 4.7 |
| 13 | A CSS Syntax Level 3 tokenizer subset with recovery and positioned diagnostics | 5.1 |
| 14 | Lengths normalize to integer English Metric Units (EMU); `em` follows CSS | 5.5 |
| 15 | Wrapping section divs are canonical; legacy marker divs are converted | 6.4 |
| 16 | Headers, footers and named Word style mappings are presentation-plan data | 6.5, 6.6 |
| 17 | WP3 owns the property matrix data and a comparison method that reads values each backend actually resolved; WP6 owns visual baselines | 7 |
| 18 | One diagnostic shape across raised errors, findings and reports | 9 |
| 19 | The WP1 conformance libraries are promoted into a shared runtime tree, with five corrections | 10 |

## 1. Pipeline placement

**Decision.** The compiler runs as two Quarto filters registered by the
extension, at two entry points, and writes its outputs at the end of the
second pass.

**Pass A: `pre-quarto` (normalization).** Quarto has normalized authors and
affiliations, and shortcodes are unexpanded custom nodes. Pass A:

1. reads `_quarto.yml` and document metadata, including `by-author` and
   `by-affiliation`;
2. builds the metadata records (section 4) and loads prior durable state;
3. compiles the project CSS into the style graph (section 5), from cache
   when the inputs are unchanged;
4. replaces each `{{< meta key >}}` occurrence with an identified generated
   span (section 4.4);
5. marks placement divs for the abstract, author plate, version history and
   table of contents.

**Pass B: `post-quarto` (model construction).** Quarto's transforms,
including shortcode expansion and cross-reference processing, have run.
Pass B:

1. walks the final AST and builds the semantic document model (section 2);
2. assigns and reuses region identifiers (section 3);
3. computes WP1 content hashes;
4. binds nodes to the style graph and resolves the presentation plan
   (section 6);
5. writes identifiers and plan references back onto AST elements as
   attributes that the backends read;
6. emits capability diagnostics (section 7) and writes durable state, the
   model and plan caches, and the compile report.

The passes share one compiler context through a module-level table in the
filter's Lua state; nothing passes through temporary files between them.

**No pre-render script.** CSS compiles inside pass A. A pre-render step
would add a second runtime entry point and its own failure mode;
compilation is fast and its result is cached by input hash.

**Quarto interface pin.** Five behaviours come from Quarto rather than
Pandoc: the `Shortcode` custom-node handler, custom author sub-fields under
`by-author[i].metadata`, positional default ids for authors and
affiliations, the `FloatRefTarget` handler for cross-reference floats, and
`quarto typst query`. A conformance test exercises each, so a Quarto
upgrade that changes any of them fails loudly. Reading a float's caption
and content in pass B is the first spike of the implementation plan
(section 14).

### 1.1 Output formats

Quarto renders each output format in a separate run with its own AST:
format-conditional content exists only in the runs whose format matches.
**Decision.**

- **Identities are shared.** Every run reads durable state and may add
  identities for regions it sees; no run deletes an identity. A region that
  is absent from one format's AST may be format-conditional, so only WP5
  reconciliation retires identifiers, as WP1 specifies.
- **Layouts and hashes are per format.** Each region entry gains an
  optional `formats` object keyed by format (`docx`, `typst`, `jats`, …).
  Each value is `{hash, matchHash, parent, index, words}`: the region's
  content hash, match hash (section 3.2), parent, position among its
  siblings in that format's tree, and, for a node that carries inline
  content, its word profile (section 3.2). A run updates only its own
  format's value.
- **The required WP1 fields** `hash` and `parent` mirror the DOCX value when
  the region has one, and otherwise the value from the most recent run that
  recorded the region. WP5 compares a returned DOCX with
  `formats.docx.hash`.
- **Caches are per format:** `cache/<format>/model.json` and
  `cache/<format>/presentation-plan.json`.
- **DOCX-specific state** (the DOCX layout and the catalogue-hash entry of
  amendment 1) is written only by DOCX runs.
- **Diagnostics** in each run report the capabilities of that run's format
  only.

Quarto renders formats sequentially, so runs never commit concurrently.

## 2. Semantic model construction

### 2.1 Block mapping

Pass B maps every Pandoc block element, and Quarto's custom block nodes, to
`document-model.v1` nodes. The policies follow the WP1 migration map, as
corrected by the metadata-binding table policy.

| Pandoc or Quarto element | Node | Classification / policy |
|---|---|---|
| `Div` with a layout section class (`section-<name>`) | `section` | structural / structural |
| `Div` with an identifier or a registered region role (for example `#abstract`, `#methods`) | `section` | authored / authored-preserve |
| `Header` | `heading` | authored / authored-preserve |
| `Para`, `Plain`, wherever they occur, including inside list items, table cells, notes and quotations | `paragraph` | authored / authored-preserve |
| `Para` holding only display math | `equation` | authored / authored-preserve |
| `LineBlock` | `paragraph`, its lines joined by `break` inline elements | authored / authored-preserve |
| `BlockQuote` | `section`, role `blockquote` | authored / authored-preserve |
| `BulletList`, `OrderedList` | `list`, children `list-item` | authored / authored-preserve |
| `DefinitionList` | `list`, role `definition-list`; each entry a `list-item` holding a `paragraph` with role `term` and the definition blocks | authored / authored-preserve |
| `Table` | `table`, `table-row`, `table-cell` | structural / structural; generated tables are generated / generated-replace throughout |
| table or figure caption | `caption` | authored / authored-preserve |
| `Figure`, Quarto figure float | `figure` | authored / authored-preserve |
| `CodeBlock`, Quarto `DecoratedCodeBlock` | `code-block`, with language and filename in `attrs` | authored / authored-preserve |
| `HorizontalRule` | `paragraph`, role `horizontal-rule`, no inline content | authored / authored-preserve |
| `Note` | `footnote` | authored / authored-preserve |
| `Cite` | `citation` | external-managed / external-managed |
| Quarto `Callout` | `section`, role `callout-<type>` | authored / authored-preserve |
| any other Quarto custom block node | `section`, role `quarto-<type>`, with a warning | authored / authored-preserve |
| `Span` with an identifier, a class, any attribute or a generated binding | `span` | authored, or generated / generated-replace (section 4.4) |
| `RawBlock` | `raw` | authored / authored-preserve |

List items and table cells contain paragraph nodes, never inline content
directly, so a cell or item with two paragraphs keeps both, and
metadata-binding's authored cell content has its own nodes. A `Div` with
only unregistered classes is not a semantic node: its children attach to
the enclosing node, so wrapping paragraphs in a styling div leaves their
hashes unchanged. Its classes and presentation attributes become a
**presentation scope** in the plan (section 6.3) that covers exactly the
nodes it wraps, with CSS semantics: inherited properties such as `color`
reach the wrapped nodes and nothing else, and box properties such as a
border or background apply around the group. A `.red` div around one of
two paragraphs colours only that paragraph.

### 2.2 Canonical inline content

**Decision.** Nodes that carry inline content gain an optional `inlines`
property, an array of canonical inline elements defined by Docstyle rather
than by Pandoc's JSON encoding. Hashes then stay stable across Pandoc API
versions, and content derived from QMD hashes identically to content
recovered from a returned DOCX, as WP1 requires.

| Pandoc inline | Canonical element | Notes |
|---|---|---|
| `Str`, `Space`, `SoftBreak` | `{"t": "text", "text": "…"}` | adjacent text, spaces and soft breaks merge into one element; each space or soft break becomes one U+0020 |
| `LineBreak` | `{"t": "break"}` | |
| `Quoted` | merged into `text` with the typographic quotation characters | a returned DOCX holds the characters |
| `Emph`, `Strong`, `Underline`, `Strikeout`, `Superscript`, `Subscript`, `SmallCaps` | `{"t": "emph" \| "strong" \| "underline" \| "strikeout" \| "superscript" \| "subscript" \| "smallcaps", "c": [...]}` | |
| `Code` | `{"t": "code", "text": "…"}` | |
| `Math` | `{"t": "math", "tex": "…", "display": true \| false}` | a paragraph holding only display math is an `equation` node instead |
| `Link` | `{"t": "link", "target": "…", "c": [...]}` | the title attribute is presentation |
| `Image` (inline, outside a figure) | `{"t": "image", "asset": "<asset id>"}` | |
| `Cite` | `{"t": "citation", "node": "<citation node id>"}` | keys and prefixes live on the citation node |
| `Note` | `{"t": "note", "node": "<footnote node id>"}` | |
| `Span` (always a node) | `{"t": "span", "node": "<span node id>"}` | the span's own `inlines` hold its content |
| `RawInline` | `{"t": "raw", "format": "…", "text": "…"}` | |

The definition is normative and becomes `$defs/inline` in
`document-model.v1` as an additive change. `text` on a node remains the
plain-text projection for search and comparison. For identifier matching
(section 3.2), each `node` reference is replaced by the referenced node's
match hash, so an inline reference never carries an identifier into a
comparison.

### 2.3 Attributes: semantic, presentation and pass-through

QMD attributes fall into three classes.

| Class | Examples | Destination | Hashed |
|---|---|---|---|
| Semantic | identifiers, registered classes, `lang`, `data-docstyle-record`, `data-docstyle-rel-*`, profile attributes, the ordered-list start number | node `attrs`; `fig-alt` and `tbl-summary` go to `semantics` | yes |
| Presentation | `widths`, `width`, `line-numbers`, `page-break`, `page-break-after`, `suppress-top-spacing`, `page-start`, `custom-style`, `content-mode`, `header*`, `footer*`, and the legacy table and figure keys in section 4.7; unregistered classes | presentation plan, cascade level 5 | no |
| Pass-through | any other attribute | node `attrs.passthrough` | yes |

The presentation attribute registry is part of the CSS subset (section 5).
An unregistered `data-docstyle-*` attribute produces a warning and is kept
as pass-through. A class has semantic meaning only when the core or an
active profile registers it; every other class is a styling hook, as the
programme specification requires. Pass-through attributes are hashed
because they are authored source with no declared meaning: a change to them
routes to reconciliation rather than being lost.

### 2.4 Tables, figures and generated regions

- Tables and figures follow the metadata-binding specification: structural
  table, row and cell nodes; authored caption and cell content; closed
  `table-semantics` and `figure-semantics`; an asset record per figure
  image, with the local path kept in state only.
- `label` comes from the cross-reference identifier, `caption` from the
  caption node id, `alt` from `fig-alt` and `summary` from `tbl-summary`.
  A figure without `alt` produces a warning at compile time, before
  embedding refuses it.
- A version-history table is a metadata view: `generated-replace`
  throughout, never mixed with authored cells.
- A generated span (a view or a `quarto-meta` region) inside an authored
  table is an error (`compile.view-in-authored-table`): the two policies
  never mix in one table.

### 2.5 Hashes and Unicode

Hashes follow WP1: canonical JSON of the node subtree with `hash`, `source`
and volatile provenance removed, text in NFC with LF line endings.

**Decision (NFC).** The compiler normalizes every text value to NFC before
hashing, which completes WP1's declared bound 1 ("NFD-input normalization
lands with the production model builder (WP3)"). Pandoc's Lua environment
has no normalizer, so WP3 vendors canonical decomposition and composition
data generated from the Unicode Character Database for a pinned Unicode
version, with a provenance record; Hangul syllables compose algorithmically.
Normalization changes only hashed and serialized values, never the AST
handed to the backends.

Four library corrections are prerequisites (section 10):

1. Canonical JSON sorts object keys by byte order. Lua's `<` on strings
   uses the C library's collation, which is `C` unless some code in the
   shared Lua state calls `os.setlocale`; byte order removes the
   dependence. Byte order equals code-point order and differs from
   RFC 8785's UTF-16 code-unit order only for keys mixing characters above
   U+FFFF with characters from U+E000 to U+FFFF; Docstyle's keys are ASCII.
2. The hash strips `hash` and `source` only at the top level of each node,
   not at every depth, so a pass-through attribute named `source` or `hash`
   is not silently left out of the hash.
3. Canonical JSON serializes finite non-integer numbers in shortest
   round-trip form (amendment 1).
4. Content hashing applies NFC.

## 3. Identifiers and durable state

### 3.1 Region identifiers

WP1 rules apply. An explicit QMD identifier is authoritative. Otherwise the
compiler generates `g-<kind>-<6 characters from a-z2-7>`. Duplicate explicit
identifiers, and explicit identifiers beginning `g-` or `docstyle-`, fail the
compile. Identifiers are at most 128 characters. WP3 extends the generated
`<kind>` set from node types to record types (section 3.3), sharing the
reserved prefix.

### 3.2 Reuse of generated identifiers

WP1 reuses a generated identifier by matching the explicit identifier, then
the source location, then the content hash. That order cannot be applied as
written:

- Quarto reads QMD with Pandoc's markdown reader, which does not support
  the `sourcepos` extension (only the CommonMark and djot readers do), so
  no line ranges reach the filter.
- Any positional substitute, such as an ordinal within a parent, shifts
  after an insertion: checking position before content would hand an
  inserted paragraph its successor's identifier, and each later sibling its
  predecessor's.
- The WP1 content hash includes the node's own identifier, so it cannot
  match an unidentified node.

**Decision.** Reuse aligns the new tree with the prior tree, the way a
text-comparison tool aligns two versions of a file.

1. **Match hash.** For every node, computed bottom-up: the WP1
   content-hash procedure applied to the node's subtree with every `id`
   field removed and every inline `node` reference replaced by the
   referenced node's match hash. It depends on content alone. Prior regions
   store their match hash per format (section 1.1).
2. **Explicit identifiers** pair first.
3. **Ordered alignment, top-down.** Starting from the document root, for
   each pair of a new node and a prior region, the compiler aligns their
   children, each in document order, by the longest common subsequence
   under equality of node type and match hash, ignoring children already
   paired by explicit identifier. Ties resolve to the leftmost alignment, so
   identical siblings pair in order. Then, within each gap between
   consecutive aligned children (and before the first and after the last),
   an unpaired prior child and an unpaired new child of the same type pair
   as an edit in place only when each is the other's single best match by
   *text similarity* and that similarity is at least 0.5. Text similarity
   is the Sørensen-Dice coefficient over the multisets of words (maximal
   runs of non-space characters) in the two subtrees' NFC text projections.
   A tie for best match pairs nothing, and nodes without words pair only by
   match hash. The prior side comes from durable state, never from the
   disposable cache: each node that carries inline content stores its
   **word profile**, an object mapping a digest of each word to its count,
   and a container's multiset is the sum of its descendants' profiles. The
   digest is the first 128 bits of the SHA-256 of the word's NFC UTF-8
   bytes, in lower-case hexadecimal (32 characters), computed with the
   runtime's existing SHA-256. A short hash would not do: under 32-bit
   FNV-1a, `costarring` and `liquid` collide, so two unrelated one-word
   paragraphs would score a Dice similarity of 1 and the replacement would
   inherit the old identifier. At 128 bits an accidental collision is out of
   practical reach. Pairing therefore works after a fresh checkout or a
   deleted cache. Digests keep the state compact and free of readable text,
   but they are not a privacy protection, since common words can be
   recovered by hashing a dictionary; durable state stays in private
   repositories (section 3.5). Position never decides a pairing. Any other
   gap content stays unpaired. Alignment recurses into every pair. A gap with more than
   64 unpaired children on either side skips edit pairing, with an info
   finding, to bound the cost.
4. **Moves.** Unpaired nodes and unpaired prior regions anywhere in the
   document pair when their type and match hash are unique among the
   unpaired on both sides. Alignment then recurses into their children.
5. **Regions from other formats.** Nodes still unpaired are offered to
   regions that have no layout entry for this run's format, that is,
   regions another format created: first by unique type and match hash,
   then by the mutual-best similarity rule of step 3 under the same parent
   identifier. A paragraph that a DOCX render introduced therefore keeps
   one identity when Typst renders it.
6. **New identifiers.** Every remaining node gets a new identifier. A prior
   region that nothing pairs keeps its entry until WP5 reconciliation
   retires it.

Consequences:

- An unchanged document reproduces every identifier, including those of
  identical siblings such as repeated table cells.
- A paragraph inserted anywhere gets a new identifier and moves none.
- A deleted paragraph's identifier never passes to an inserted paragraph
  unless the two are textually similar enough to be the same paragraph
  edited.
- A paragraph edited in place keeps its identifier when at least half its
  wording survives, and so do two edited lists side by side.
- An insertion beside an edit gives the inserted node a new identifier, even
  when both cite the same reference.
- Two occurrences of the same metadata view, or two paragraphs citing the
  same reference, pair by position.

**Prior tree.** A run aligns against its own format's stored layout; when
that format has none, against the DOCX layout; otherwise against the most
recently recorded format's layout. A first Typst render therefore reuses
the DOCX identifiers.

This revises the WP1 tier order, and the WP1 specification gains a note
recording the revision.

### 3.3 Record identifiers

The metadata-binding examples (`rec-person-1`, `contrib-1`, `rec-document`)
are illustrative. Record identifiers are derived as follows, so they stay
stable when authors reorder.

- **Author-supplied ids.** An author or affiliation `id` counts only when
  the author wrote it. Quarto fills missing ids by position, so a numeric
  author id and an affiliation id of the form `aff-<number>` are treated as
  absent.
- **Suffix.** A record's suffix is its identifier with the `rec-<type>-` or
  `g-<type>-` prefix removed.

| Record | Identifier |
|---|---|
| document | `docstyle.id` when set; otherwise `rec-doc-<input file stem>`, lowercased with every run of characters outside `a-z0-9` replaced by `-` |
| person | `rec-person-<author id>`; otherwise `rec-person-orcid-<ORCID>`; otherwise a generated `g-person-…`, matched in state by email, then by `name.literal` |
| organization | `rec-org-<affiliation id>`; otherwise `rec-org-ror-<ROR>`; otherwise a generated `g-organization-…`, matched by name |
| contribution | `rec-contrib-<document suffix>-<person suffix>` |
| contact | `rec-contact-<person suffix>`; a second email for the same person adds `-2`, `-3` in YAML order |
| funding | `rec-funding-<funding id>` when set; otherwise a generated `g-funding-…`, matched by funder and award |
| metadata view | the region identifier of its occurrence (amendment 1) |

Generated record identifiers persist in `metadata.json` with the keys used
to match them.

### 3.4 State writes

Pass B commits one durable-state generation through the WP1 manifest
procedure, with two corrections to the current library and to the WP1
procedure text:

- **Carry forward.** A commit starts from the current manifest and replaces
  only the entries it writes (`regions.json` and `metadata.json` from the
  compiler); every other entry, such as `citations.json`, `annotations.json`
  and the catalogue-hash entries, is carried into the new manifest
  unchanged.
- **Referenced files survive.** Garbage collection deletes only physical
  files referenced by neither the new manifest nor its predecessor.

The compiler also writes the per-format caches of section 1.1. A failed
commit leaves the previous generation intact, and the render fails closed,
because generated identifiers that are not persisted would not be stable.

WP1's layout lists `state/document.json` without a schema (#29). The model
snapshot is derived from source on every render, so it belongs in the
cache. **Decision:** remove `document.json` from the WP1 state layout.

### 3.5 Version control

Generated identifiers stay stable across machines only when
`_docstyle/state/` travels with the project, but durable state holds
restricted data: `metadata.json` carries restricted records such as
contacts, and `annotations.json` carries review comments. **Decision.**

- In a **private** repository, commit `_docstyle/state/` and ignore
  `_docstyle/cache/` and `_docstyle/reports/`.
- In a **public** repository, keep `_docstyle/state/` out of version
  control. Explicit identifiers are stable everywhere, so authors give
  explicit identifiers to the regions whose identity matters across
  machines.
- **Proposed follow-up (WP1 revision):** split durable state into a
  shareable part (the region registry and public records) and a restricted
  part, so identities can be shared without restricted content.

Project initialization (WP8) writes the ignore rules for the chosen case.

## 4. Metadata normalization

### 4.1 Mapping table

This table makes the metadata-binding QMD bindings exact. It uses the
binding table's keys, with the aliases amendment 1 allows.

| YAML | Record field | Notes |
|---|---|---|
| `title` | `document.title` | `subtitle` stays presentation-only in v1 |
| `short-title` | `document.shortTitle` | |
| `version` | `document.version` | string |
| `date` | `document.dates.published` | resolved to ISO `YYYY-MM-DD`; `today` and `last-modified` resolve at compile time with an info finding |
| `date-modified` | `document.dates.modified` | as above |
| `docstyle.date-created` | `document.dates.created` | as above |
| `type` | `document.type` | WP1 enum; absent gives `other` with a warning |
| `status` | `document.status` | WP1 enum |
| `licence` (alias: Quarto's `license`) | `document.licence` | SPDX identifier when recognized, otherwise `statement` |
| `identifiers`, `doi` | `document.identifiers[]` | `doi` becomes `{scheme: "doi"}` |
| `keywords` | `document.keywords` | |
| `lang` | `document.language` | |
| `abstract` | `#abstract` section; `document.abstract: {region: "abstract"}` | section 4.3 |
| `author`, `affiliations` | person, organization, contribution, contact | section 4.2 |
| `funding` | funding and organization records | the funder becomes an organization record; the field-level mapping is fixed in the implementation plan against Quarto's funding schema |
| `version-history` | `document.versionHistory[]` | |

Legacy keys are accepted with deprecation warnings and mapped:
`version-summary.version` to `version`, `version-summary.date` to
`dates.modified`, and `docstyle.authors` and `docstyle.affiliations` to the
standard author path.

### 4.2 Authors and contributions

Pass A reads `by-author` and `by-affiliation`.

- **Person:** `name.literal` (always, amendment 1), `name.given`,
  `name.family`, `orcid`. When the literal holds words that neither `given`
  nor `family` contains, the signature of a dropped particle, the compiler
  adds an info finding suggesting a structured name.
- **Contribution:** `position` from `by-author` order; `roles` from Quarto
  `roles`, normalized to the CRediT enum (an unknown role is a warning and is
  left out of the record); `corresponding` from `attributes.corresponding`;
  `affiliations` from the author's affiliation references in order.
- **Equal contribution:** authors with `attributes.equal-contributor: true`
  share the group `equal-contributors`. An author sub-field
  `equal-contribution-group: <name>`, read from `metadata`, names a
  different group for documents that need more than one.
- **Contact:** `email` becomes a contact record written
  `privacy: "restricted"` unless `metadata.email-public` is `true`.
  Contact-bearing properties found on other records migrate as amendment 1
  specifies.
- **Deprecated forms:** `person.roles`, `person.corresponding` and
  `person.affiliations` from legacy state migrate to contributions with
  warnings.

### 4.3 Abstract

A YAML `abstract` string becomes an `#abstract` section node (role
`abstract`, `authored-preserve`) and the document record gets
`abstract: {region: "abstract"}`. A `::: {#abstract}` div in the body is the
same section. Having both is an error (`meta.abstract-duplicate`): two
authored sources for one region. A `::: docstyle-abstract` placeholder is a
placement directive: the abstract section is placed there. Without a
placeholder, the section's position is the backend's front-matter default.

### 4.4 Metadata views and placement

**Every `meta` shortcode becomes a generated region.** Pass A handles each
`Shortcode` node named `meta` and expands it itself, resolving dotted keys
as Quarto does, into a span carrying a region identifier (explicit only
when the author wrapped the shortcode in an identified span, otherwise
generated):

- **Record-bound key** (table below): the span has role `metadata-value`
  and the class `docstyle-view`, with `data-docstyle-path`, and the compiler
  registers one `metadata-view` record for the occurrence. The span's text
  is the record value, so the view renders from the record.
- **Any other key:** the span has the generator role `quarto-meta`, which
  WP3 owns (amendment 1), with the key in `data-docstyle-meta-key` and in
  the catalogue's `generated` container. It renders the YAML value, is
  regenerated on every render, binds to no record and is conflict-only on
  return, so an edit in Word never rewrites the QMD. An info finding
  suggests a record-bound key where one exists.
- **Refused keys:** a key under a YAML path that normalizes into records
  (`author`, `authors`, `by-author`, `affiliations`, `by-affiliation`,
  `funding`) fails the compile (`meta.record-path-unbound`), because those
  values display only through record-bound views such as the author plate.
  A value equal to a protected value of a restricted record fails
  (`meta.restricted-value`), so a restricted email can never reach the page
  through a `meta` shortcode. Protected values are the string values of a
  restricted record's payload fields, excluding the structural fields
  (`id`, `recordType`, `schemaVersion`, `privacy`, `profile`, `document`)
  and reference fields (amendment 1); comparison is exact, so values such as
  `1` or `contact` never cause a refusal.

| Meta key | View source |
|---|---|
| `title` | `document.title` |
| `short-title` | `document.shortTitle` |
| `version`, `version-summary.version` | `document.version` |
| `date` | `document.dates.published` |
| `date-modified`, `version-summary.date` | `document.dates.modified` |
| `status` | `document.status` |

**Placement divs.** Generated displays are placed by empty divs with
reserved classes:

| Class | Generates | Legacy alias |
|---|---|---|
| `docstyle-author-plate` | view: collection over `contribution`, ordered by `position` | `author-plate` |
| `docstyle-version-history` | view: `document.versionHistory` | `version-history` |
| `docstyle-abstract` | placement of the `#abstract` section | (unchanged) |
| `docstyle-toc` | a region with generator role `toc` | `toc` |

A legacy alias produces a deprecation warning. A table-of-contents
placement compiles with role `toc`, and embedding fails closed on it
(amendment 1) until WP4 registers that role.

### 4.5 Profiles and record attributes

`docstyle.profiles` activates profiles. Activating an unavailable profile
fails; data belonging to an inactive profile is preserved with a warning, as
WP1 specifies. `data-docstyle-record` and `data-docstyle-rel-<predicate>`
attributes create relationships; the compiler validates their targets
against the records it has built and reports unresolved targets.

### 4.6 Legacy configuration, classes and sidecars

The WP1 audit assigns these legacy elements to WP3. Each has a stated
destination; none is ignored silently.

| Legacy element | WP3 treatment |
|---|---|
| `docstyle.css` | stylesheet list (section 5.7) |
| `docstyle.header`, `docstyle.footer`, `docstyle.sections.<name>.*` | header and footer definitions in the plan (section 6.5) |
| `docstyle.page` | deprecated; converted to the equivalent `@page` declarations at level 2 with a warning |
| `docstyle.toc` | table-of-contents configuration carried in the plan for WP4 |
| `docstyle.author-plate`, `docstyle.version-history` | view presentation configuration in the plan (markers, title, title level, widths) |
| `medrxiv: true` (Typst) | a bundled preset stylesheet for the Typst format at level 1; explicit user values still win |
| `base-doc` | retired: the DOCX backend builds its own styles from the plan (WP4); a warning names it |
| `docstyle.silence-version-warning` | retired: version checks belong to the WP8 tooling; an info finding names it |
| `docstyle.validators` | WP4 render configuration, as the audit records; carried unchanged |
| character classes `.date`, `.version`, `.author`, `.affiliation` | presentation classes on span nodes |
| `.sc` | converted to `smallcaps` with a deprecation warning |
| `.ins`, `.del` | tracked-change markers, outside WP3; reported and kept as pass-through for WP5 |
| list classes `.list-*` with `start` | `list-style-type`; the start number goes to the list's semantic `start` |
| `.table-*` classes | table styles from CSS class rules |
| `.page-break`, `.center` | `break-before` and `text-align`; content is never rebuilt |
| section and anchor classes | sections per section 6.4; anchors per section 4.7 |
| `page-config.json`, `style-map.json` | replaced by the presentation plan |
| `figures.json` | migration input for asset records and figure semantics (`original_path`, `alt`, `caption`) and plan values (`width`, `align`); the WP8 migration reads it |
| `styles.json` | retired: a harvest-time inventory of Word styles, superseded by the plan's `docxStyles`; WP5 reads styles from the returned DOCX |

### 4.7 Legacy field-code payload keys

The audit assigns 29 legacy payload keys to the WP3 property model. When
migration or a cold import presents them, each goes to a typed destination:

| Payload keys | Destination |
|---|---|
| `class` | presentation classes |
| `source` (char) | pass-through `legacySource` on the span, interpreted by WP5 (audit bound 5) |
| `start` (list) | the list's semantic `start` |
| `page-break`, `line-numbers` (section) | `break-before` and `--docstyle-line-numbers` on the section |
| `widths`, `width`, `font-size` (table) | column widths, `width` and `font-size` on the table element |
| `header-bold`, `header-shading` (table) | `font-weight` and `background-color` on the table's header cells |
| `label` (table), `alt` (figure) | `semantics.label` and `semantics.alt` |
| `width`, `align` (figure) | `width` and `text-align` on the figure element |
| `original_path` (figure) | the asset record's local path, in state |
| `docpr_id` (figure) | the plan's DOCX drawing identifier for the figure, for WP4 to reuse |
| `wrap` (figure) and the anchor keys (`vertical_anchor`, `horizontal_anchor`, `position_x`, `position_y`, `float_width`, `wrap_style`, `wrap_side`, `wrap_distance`, `content_hint`, `z_layer`, `content_mode`, `caption_y`, `image_height`) | carried unchanged in the migration record and reported (`css.anchor-deferred`) until a floats specification types them |

`adjacent` stays dropped, as the audit records.

## 5. CSS compiler

### 5.1 Grammar

**Decision.** A tokenizer implementing the CSS Syntax Level 3 token types
the subset needs (ident, function, at-keyword, hash, string, number,
percentage, dimension, delim, whitespace, colon, semicolon, comma, brackets
and comments), followed by a rule parser. Every token carries its file, line
and column.

Error recovery follows CSS: an invalid declaration is skipped to the next
`;`, an invalid rule to its matching `}`. Every skip produces a diagnostic
with the position. Nothing is mis-parsed silently: an unclosed comment,
string or block is an error at its opening position.

### 5.2 Selectors

| Supported | Examples | Notes |
|---|---|---|
| Type | `body`, `p`, `h1`–`h6`, `blockquote`, `code`, `pre`, `table`, `caption`, `th`, `td`, `figure`, `figcaption`, `ul`, `ol`, `li`, `a`, `dl`, `dt`, `dd` | `body` holds document defaults |
| Class | `.abstract`, `.table-formal` | |
| Identifier | `#abstract` | binds to one region |
| Compound | `p.lead`, `table.table-formal` | one type plus classes |
| Descendant, one level | `.table-formal th`, `ul li` | table and list structure only |
| Selector lists | `h1, h2` | |

Pseudo-classes, pseudo-elements, attribute selectors, child and sibling
combinators, and `*` are unsupported: the rule is skipped with a
diagnostic. Specificity is CSS specificity (identifier, class, type).

### 5.3 At-rules

- `@page`, `@page <name>`, `@page :first` and `@page <name>:first` are
  supported (section 6.4).
- `@media`, `@font-face`, `@import`, `@supports` and every other at-rule are
  skipped whole with a diagnostic. No inner rule leaks into the global
  scope.

### 5.4 Properties

The v1 property set covers the properties real stylesheets use (Appendix A
lists each with its backend capability).

- **Text:** `font-family`, `font-size`, `font-weight`, `font-style`,
  `font-variant` (`small-caps`), `color`, `text-decoration`, `text-align`,
  `text-indent`, `line-height`, `background-color`.
- **Box:** `margin`, `margin-*`, `padding`, `padding-*`, `border`,
  `border-*`, `width`, `break-before`, `break-after` (with the legacy
  `page-break-*` names as aliases), `widows`, `orphans`.
- **Tables:** `border-collapse`, and the box and text properties on
  `table`, `th` and `td`.
- **Lists:** `list-style-type`.
- **Pages:** `size`, `margin`, `column-count`.
- **Docstyle custom properties**, keeping the legacy names and syntax:
  `--docstyle-line-numbers` (`none` or `every <n>`),
  `--docstyle-line-numbers-restart` (`continuous`, `new-page` or
  `new-section`), `--docstyle-line-numbers-distance` (a length) and
  `--docstyle-suppress-top-spacing` (a boolean); and three new properties,
  `--docstyle-page-number-start`, `--docstyle-page-number-format` and
  `--docstyle-word-style` (section 6.6).

Any other property, any other custom property, `var()` and `!important`
are unsupported: the declaration is skipped with a diagnostic. Property
names are case-insensitive, as in CSS.

The legacy floating-anchor properties (`vertical-anchor`,
`horizontal-anchor` and related) are outside the v1 subset: no real
stylesheet uses them, and floats need their own specification with WP4.

### 5.5 Values and units

**Lengths normalize to integer EMU** (914,400 per inch). Every absolute CSS
unit converts exactly: 1pt is 12,700; 1px (at 96 per inch) is 9,525; 1mm is
36,000; 1cm is 360,000; 1pc is 152,400. Backends convert EMU to twips,
half-points or Typst lengths at their own boundaries, so rounding happens
once, at output, where the backend can report it.

- **`em`** follows CSS: on `font-size` it is relative to the parent's
  computed font size; on every other property, to the element's own
  computed font size. **`rem`** is relative to the root font size. The
  legacy engine fixed both at 12 points; projects whose stylesheets relied
  on that get a different, correct result, and the WP8 migration report
  flags them.
- **Percentages** are accepted where CSS defines a reference: `font-size`
  (parent font size), `line-height` (element font size) and `width`
  (containing block). Elsewhere they are a diagnostic.
- **Unitless `line-height`** is a ratio, stored as an integer in thousandths
  (1.25 becomes 1,250); a value with more than three decimals is rounded
  with an info finding.
- **Colours:** `#rgb`, `#rrggbb`, `rgb()` and `rgba()` with alpha 1, and the
  named colours of CSS Color Module Level 4, normalized to lowercase
  `#rrggbb`; and the keyword `transparent`, kept as a keyword. Partial
  transparency, `hsl()` and `currentColor` are diagnostics.
- **Keywords** normalize to the property's enum; anything else is a
  diagnostic.

Integer storage keeps every normalized value representable in canonical
JSON without the fraction rule.

### 5.6 Shorthands

`margin` and `padding` (one to four values), `border` and `border-<side>`
(width, style and colour in any order, as in CSS) and `font` (style,
variant, weight, size, optional line height and family) expand to their
longhands before the cascade, so each longhand keeps its own source.

### 5.7 Stylesheets and order

`docstyle.css` is a file or an ordered list of files, read in order; a later
declaration of equal specificity wins, as in CSS. The bundled default
stylesheet is cascade level 1 and always applies. (The legacy pre-render
hook selects its `default.css` when no `css` key is set but passes it only
to `page-config.json`, so the reference document's styles stay unstyled.)
A missing stylesheet is an error that fails the compile; it is never
skipped.

## 6. Cascade and presentation plan

### 6.1 Cascade

The programme cascade has five levels: backend defaults, project document
defaults, named page or section rules, element and class rules, and
explicit QMD attributes. Within a level, CSS specificity and then source
order decide. Inheritance follows CSS: the font properties, `color`,
`line-height`, `text-align`, `text-indent`, `list-style-type`, `widows`,
`orphans` and `border-collapse` inherit; margins, padding, borders, widths,
backgrounds and breaks do not.

### 6.2 Provenance

Every resolved value records where it came from:

```json
{ "value": 152400, "unit": "emu", "authored": "12pt",
  "source": { "level": 4, "file": "assets/protocol.css",
              "line": 14, "column": 3, "selector": ".abstract" } }
```

Diagnostics and the compile report quote this record, so an author can find
the rule behind any rendered property.

### 6.3 Plan structure

**Decision.** The presentation plan is a style graph: named styles and
element bindings, from which a value for any node is computed on demand. It
contains:

- `document`: document defaults from `body` and the cascade's first two
  levels;
- `pages`: named page definitions, each with an optional `:first` variant;
- `styles`: one named style per type, class or compound selector, holding
  only that selector's own declarations. Every style builds on the document
  defaults and on no other selector's style, so a `p` rule never reaches a
  heading, as in CSS. Inherited properties flow through the document tree,
  from an element to the elements it contains, never between selectors;
- `sections`: one entry per section region, naming its page and its
  section-level properties;
- `elements`: one entry per node that needs one, keyed by node id (span
  nodes included): its styles in cascade order, plus direct properties from
  identifier selectors and QMD attributes;
- `scopes`: one entry per styling div (section 2.1): its classes,
  presentation attributes, the ids of the nodes it wraps in order, and its
  enclosing scope; scope keys are positions within one compile and are
  never persisted;
- `headers` and `footers` (section 6.5) and `docxStyles` (section 6.6);
- `generators` and `views`: the configuration carried for the table of
  contents, author plate and version history (section 4.6);
- `diagnostics`: the capability findings (section 7).

The compiler library offers `resolve(plan, node_id, property)`, which
applies the cascade and inheritance on demand for backends without style
inheritance, such as Typst. The DOCX backend turns named styles into Word
styles with ordinary style inheritance, which replaces the legacy
`cascade_css_to_children` workaround.

The plan has its own schema, `presentation-plan.v1`, and lives in the
per-format cache. It is derived and never hashed into content; its cache key
is the hash of the CSS inputs, the presentation attributes and the model
structure.

### 6.4 Sections and pages

**Decision.** A section is a wrapping div with class `section-<name>`.
`<name>` selects `@page <name>`, and section-level properties come from that
page rule and the div's presentation attributes. A section whose name has no
`@page` rule uses the default page, with an info finding, as the legacy
engine does for `section-default` and `section-body`. Wrapping divs make
containment explicit, which also settles nested-range ambiguity (#19).

The legacy marker idiom (an empty `section-<name>` div starting a section
that runs to the next marker) is converted to the equivalent wrapping
structure with a deprecation warning. A marker sequence that cannot be
converted unambiguously fails with a diagnostic naming both markers.

### 6.5 Headers and footers

Headers and footers are section presentation in the programme
specification. The plan holds, per page definition and per section, a
header and a footer each with `left`, `center` and `right` content
templates, an optional first-page variant, and a style from the `.header` or
`.footer` class rules. Templates accept the fields `{page}`, `{pages}` and
`{sectionpages}`; any other brace field is a diagnostic. Configuration comes
from `docstyle.header`, `docstyle.footer` and `docstyle.sections.<name>`,
with the legacy single-content form converted. WP4 renders them, including
the "same as previous" inheritance between sections.

### 6.6 Named Word style mappings

Named Word style mappings are a document property in the programme
specification. The plan's `docxStyles` table maps each named style to a
Word style identifier: `body` to the document defaults and `Normal`; `p` to
`BodyText`, with Pandoc's `FirstParagraph` built on it; `h1` to `Heading1`
and the other headings likewise, built on `Normal`; `blockquote` to
`BlockText`; `caption` to `Caption`; registered roles such as `abstract` to
`Abstract`; and a custom identifier derived from the class name for each
class style. Because headings build on `Normal` rather than `BodyText`, a
`p` declaration stays out of headings in Word as it does in CSS. The custom
property `--docstyle-word-style` on a rule overrides the identifier. The
mapping is data in the plan; WP4 materializes the styles.

## 7. Capability diagnostics, matrix and comparison method

### 7.1 Levels

Each property has a capability level per backend, as the programme
specification defines: supported; supported with a documented
approximation; omitted with a warning; unsupported and blocking.

### 7.2 Matrix

**Decision.** WP3 publishes the matrix as data,
`property-matrix.v1.json`, and generates the documentation table from it.
Appendix A is the initial content. WP6 owns the visual baselines that test
approximations and may move a property between levels with evidence; the
matrix file is the single record of the current level.

### 7.3 Diagnostics

Each run reports, for its own format, every property the document uses at
a level other than supported, once per property and rule, with the
provenance record. A property at the blocking level fails that format's
render. For JATS, which carries no page or typographic presentation, the
omitted properties produce one warning per property per render rather than
per rule, which keeps the programme's "omitted with a warning" level
without repeating it for every rule.

### 7.4 Comparison method

The property-equivalence comparison the programme assigns to WP3 compares
each backend's resolved value with the plan's:

1. A fixture document exercises each matrix property with known values,
   including values set through templates and inheritance.
2. The resolved plan value is the expected value.
3. **DOCX:** the adapter reads the rendered package through the WP2 package
   core and resolves Word's own inheritance (direct formatting, then the
   paragraph and character style chains through `basedOn`, then document
   defaults) to the effective value of each property.
4. **Typst:** the fixture's Typst output carries a labelled probe per
   element, `#context metadata((…)) <docstyle-probe-<node id>>`, recording
   values such as `text.size` and `par.leading`; `quarto typst query` reads
   them back, so the comparison sees what Typst resolved after its
   template's own settings, not merely what Docstyle emitted.
5. **JATS:** for its supported properties (`list-style-type`), the adapter
   reads the `list-type` attributes of the JATS output.
6. Each adapter converts its observation to the plan's units. A supported
   property must match exactly after the backend's documented rounding (for
   example half-points for DOCX font sizes); an approximated property must
   match its documented approximation. A mismatch fails the test.

Visual correspondence, how much two renderings look alike, is WP6's
separate baseline work.

## 8. Lists and tables through the pipeline

Compiler filters never convert lists or tables to raw markup and never
rebuild their inline content as strings. Presentation attaches by node id
and plan reference only. A conformance test renders a fixture with nested
lists, a table with merged cells and styled inline content, and fails if any
WP3 filter output contains a raw element that the input did not contain.
This replaces the legacy `.center` handling, which rebuilt paragraphs from
plain text and lost emphasis and links.

## 9. Diagnostics and reports

**Decision.** One diagnostic shape:

```json
{ "level": "error", "code": "css.unsupported-property",
  "message": "…", "stage": "compile",
  "where": { "file": "assets/protocol.css", "line": 14, "column": 3 },
  "context": { } }
```

- `where` is an object: a source position (`file`, `line`, `column`) or a
  location in a JSON document (`path`, a JSON Pointer). The #57 catalogue
  validator's string `where` converts to `{"path": …}` when that library is
  promoted.
- Raised errors carry `{code, message, context}`, the WP2 convention, and
  convert to findings at the compile boundary.
- Codes are namespaced by stage: `css.*`, `meta.*`, `model.*`, `ids.*`,
  `state.*`, `compile.*`.
- The compile report uses `report-envelope.v1` with operation `compile`, the
  input hashes and the findings. Result states follow WP1: `PASS`,
  `PASS_WITH_WARNINGS`, `FAIL`.
- Errors that fail the compile: duplicate or reserved explicit identifiers,
  unparseable or missing stylesheets, an unavailable active profile, a
  duplicate abstract, a generated span inside an authored table, a failed
  state commit and any blocking capability. Everything else is a warning or
  info finding.

## 10. Runtime and shared modules

- **Layout.** The compiler lives in `_extensions/docstyle/vnext/compiler/`
  with `init.lua` as its only public interface, isolated from the legacy
  filters, following the WP2 layout.
- **Shared runtime.** The WP1 conformance libraries (`canonical`, `sha256`,
  `hashes`, `ids`, `json`, `jsonschema`, `manifest`, `profile`, and
  `catalogue` from #57) move from `tests/vnext/conformance/lib/` into
  `_extensions/docstyle/vnext/shared/`, and the conformance tests import
  them from there, so one implementation serves runtime and tests. Shared
  modules load under a `docstyle_shared.` prefix to avoid colliding with the
  package core's `lib.` modules.
- **Library corrections taken into WP3:** byte-order key sorting (from #29),
  node-level hash stripping, NFC in content hashing, the canonical JSON
  fraction rule (amendment 1), and manifest carry-forward with
  reference-aware garbage collection; plus the `formats` registry field and
  distinct identifier error messages (from #29).
- **Tests.** A `tests/vnext/compiler/` suite runs with
  `quarto run tests/vnext/compiler/run.lua` and joins the conformance run as
  a child process, following the WP2 pattern. Integration tests render
  through `quarto render`.
- **Determinism.** Iteration is always sorted. Generated identifiers, the
  manifest `stateId` and every clock reading come from injected sources, so
  tests are reproducible. Two fresh processes over the same inputs and the
  same injected sources produce byte-identical model, plan and state.
- **Performance.** No programme budget exists. The plan records compile
  time for the WP0 fixtures. Alignment is quadratic in the number of
  children of one parent, which is acceptable for documents; compilation is
  otherwise linear in document size.

## 11. Schema-change manifest

Every change to an existing v1 schema follows the metadata-binding
versioning discipline. The touched schemas are open objects, so values
such as `inlines: "legacy"` or `formats: 7` validate today; the new typed
forms are canonical definitions rather than restrictive v1 constraints.
Validation at rest stays permissive and warns on a noncanonical value. The
compiler always writes canonical values, and where it reads one it applies
the canonical definition: a region entry whose `formats` value for a format
is noncanonical counts as lacking that format's layout, and a model whose
`inlines` are noncanonical is refused by every canonical operation.

| File | Change | Kind |
|---|---|---|
| `document-model.v1.json` | canonical `$defs/inline` (section 2.2) and the canonical `inlines` property, applied by the canonical validators; v1 validation at rest unchanged | additive definitions |
| `state-regions.v1.json` | canonical per-region `formats` definition (per-format `hash`, `matchHash`, `parent`, `index`, `words`), applied when state is read; v1 validation at rest unchanged | additive definition |
| `presentation-plan.v1.json` | new: document, pages, styles, sections, elements, headers, footers, docxStyles, generators, views, diagnostics | new file |
| `property-matrix.v1.json` | new: property × backend capability levels | new file (data) |
| `report-envelope.v1.json` | canonical finding definition with optional `stage`, `where` and `context`, applied by the canonical validators; v1 validation at rest unchanged | additive definition |
| `metadata-core.v1.json` | canonical `person.name.literal` definition | additive definition (amendment 1) |
| `catalogue.v1.json` | optional `generated` container: generator-role regions with role and parameters | new schema (amendment 1, #57) |
| WP1 specification | remove `document.json` from the state layout; record the revised identifier-reuse procedure; record manifest carry-forward and reference-aware garbage collection in the atomic-update procedure | documentation correction |
| conformance libraries | promoted to `vnext/shared/`, with the corrections in section 10 | implementation |

## 12. Legacy behaviours not preserved

| Legacy behaviour | vNext behaviour |
|---|---|
| Regular-expression parsing; silent mis-parse of `@media`, nested braces and quoted semicolons | Tokenizer with positioned diagnostics |
| No specificity; a later duplicate selector block replaces the earlier one wholesale at the earlier position | CSS specificity, then source order, declaration by declaration |
| Unknown properties and selectors ignored silently | Every skipped declaration diagnosed |
| `em` fixed at 12 points | `em` as in CSS |
| `default.css` selected but never applied to the reference document's styles | Bundled defaults always apply at level 1 |
| `cascade_css_to_children` copying properties into Word styles | Named styles with ordinary inheritance |
| Any `.class` becomes a Word paragraph style, including descendant selectors | Class styles in the plan; descendant selectors limited to tables and lists |
| Hard-coded formatting in table, author-plate, version-history and `.center` filters | All presentation from the plan |
| Anchor properties partly applied (`z-layer` dropped) | Carried and reported until a floats specification |

The legacy line-number syntax (`none`, `every <n>`, the separate `-restart`
and `-distance` properties) is kept.

## 13. Acceptance criteria

1. The three WP0 fixtures compile, and each resulting model validates
   against `document-model.v1` and matches a reviewed expected model stored
   beside the fixture (the WP0 sources stay unchanged). Their
   `short-title`, `docstyle.footer` and `medrxiv` settings are mapped as
   sections 4.1 and 4.6 specify.
2. The normalizer parts of metadata-binding criteria 2 (abstract), 5
   (repeated inline meta), 6 (table policy) and 10 (legacy normalization),
   and of amendment 1 criteria 16 (email migration) and 18 (naming), pass as
   compiler fixtures.
3. The authorship worked example in the metadata-binding specification
   normalizes to records with exactly the specified content, under the
   identifier rules of section 3.3; reordering the authors changes no record
   identifier.
4. Two fresh processes with the same inputs and injected sources produce
   byte-identical model, plan and state, including after an in-process
   `os.setlocale` to a UTF-8 collation.
5. Identifier stability, each case checked on content, not on counts:
   - an unchanged document, including identical sibling table cells and two
     paragraphs citing the same reference, reproduces every identifier;
   - after inserting a paragraph, every unedited node keeps its identifier
     and only the inserted paragraph gets a new one;
   - deleting a paragraph in one place and inserting another elsewhere in
     the same parent moves no identifier onto the inserted paragraph;
   - for prior children [A, P1, P2, C] and new children [A, P2′, N, C]
     (P1 deleted, P2 edited, N inserted), P2′ keeps P2's identifier and N
     gets a new one;
   - a paragraph inserted before an edited paragraph, both citing the same
     reference, gets a new identifier and the edited paragraph keeps its
     own;
   - a paragraph edited in place keeps its identifier, and two adjacent
     lists edited together keep theirs;
   - a section moved unchanged to another parent keeps its identifier and
     its children's;
   - with `_docstyle/cache/` deleted before the second render, a paragraph
     edited from "alpha beta gamma" to "alpha beta delta" keeps its
     identifier, which shows the pairing reads only durable state;
   - with `_docstyle/cache/` deleted before the second render, a one-word
     paragraph "costarring" replaced in the same position by the unrelated
     one-word paragraph "liquid" gets a new identifier: the two words
     collide under 32-bit FNV-1a, so the fixture fails if the stored digest
     is too short.
6. Rendering the same project to DOCX and then Typst keeps one set of
   identities, records per-format layouts and hashes, gives a first Typst
   render the DOCX identifiers, and leaves the DOCX catalogue-hash entry and
   DOCX layout untouched by the Typst run. After a paragraph is inserted
   and the project rendered to DOCX and then to Typst, the paragraph has
   one identity.
7. A commit that writes only `regions.json` and `metadata.json` carries
   every other manifest entry forward, and garbage collection deletes no
   referenced file.
8. NFD input (including Hangul jamo) hashes identically to its NFC form.
9. A fixture containing every Pandoc block and inline element, a Quarto
   callout and a decorated code block maps as sections 2.1 and 2.2 specify,
   including two paragraphs in one list item and in one table cell, and
   attribute-only spans.
10. Every `meta` shortcode produces a generated region: record-bound keys a
    metadata view, other keys a `quarto-meta` region; `{{< meta
    author.1.email >}}` and a custom key whose value equals a restricted
    email both fail the compile; a generated span in an authored table
    fails the compile.
11. The CSS suite covers tokenization, recovery and positions for every
    legacy mis-parse case in section 12; specificity and order; each of the
    five cascade levels; exact unit conversion; `em` on `font-size` and on
    other properties; colours and `transparent`; shorthands; and
    inheritance.
12. All 12 surveyed legacy stylesheets and the two POPCORN stylesheets
    compile with no parse error, and every declaration is either applied or
    reported, with a count of each.
13. `property-matrix.v1.json` covers every v1 property for DOCX, Typst and
    JATS; the documentation table is generated from it; and the comparison
    method of section 7.4 runs for every DOCX and Typst entry and for the
    JATS `list-style-type` entry.
14. The list-and-table preservation test in section 8 passes.
15. Every unsupported or approximated property used by a fixture produces
    the diagnostics section 7.3 specifies, with provenance, and the compile
    report validates against `report-envelope.v1`.
16. The Quarto interface pin test (section 1) passes on the pinned Quarto
    version.
17. The compiler suite runs inside the conformance command, and no test or
    runtime path requires R or Python.
18. A `.red` styling div around one of two paragraphs colours only that
    paragraph, and a bordered styling div around two paragraphs draws one
    border around both; neither div changes the paragraphs' hashes.
19. `p { margin-bottom: 18pt }` leaves the computed margin of `h1`
    unchanged, in the plan and in the DOCX comparison of section 7.4.
20. `inlines: "legacy"` and `formats: 7` validate against their v1 schemas
    at rest with a warning, and the compiler treats each as specified in
    section 11.

## 14. Risks and spikes

1. **Cross-reference floats in pass B.** Figure and table floats reach pass B
   as `FloatRefTarget` custom nodes whose identifier and type a handler can
   read. The first implementation task is a spike that establishes how pass B
   reads their captions and contents.
2. **Quarto custom-node interfaces.** The `Shortcode` handler and the
   author-id defaults are less stable than the Pandoc filter API. The pin test
   detects changes; the fallback for shortcodes is a Docstyle shortcode
   (`{{< docstyle-meta key >}}`) under the extension's control.
3. **Identifier churn on large edits.** Alignment gives new identifiers to
   heavily edited or ambiguous regions, and WP5 reconciles the old ones.
   Explicit identifiers remain the reliable route to stability.
4. **Unicode data maintenance.** The vendored normalization data is pinned
   to one Unicode version and must be regenerated, with its provenance
   record, when Docstyle adopts a newer version.
5. **Behaviour changes for existing stylesheets.** CSS `em`, real
   specificity and the bundled defaults change the result for some legacy
   stylesheets. The WP8 dual-engine comparison measures this before
   retirement.

## 15. Decisions for review

**Owner decisions, October 16, 2026.** Approved: committing state only in
private repositories (8), the YAML key mapping (9), every `meta` shortcode
as a generated region (11), the reserved placement classes (12), retiring
`base-doc` (13, part), CSS `em` (15, part), and the identifier-reuse rule
(6), after a worked explanation. The remaining items are technical; they
passed independent review, and the specification was accepted on October
20, 2026.

1. Two filter passes and no pre-render script (section 1).
2. Per-format runs with shared identities and per-format layouts, hashes
   and caches (1.1).
3. A separate, unhashed presentation plan, with presentation attributes and
   unregistered classes outside hashed content (2.3 and 6).
4. The normative block and inline mappings (2.1 and 2.2).
5. NFC implemented in WP3 with vendored Unicode data (2.5).
6. Ordered alignment for identifier reuse, and its WP1 note (3.2).
7. Record identifier derivation rules (3.3).
8. State commits in private repositories only, and the proposed split of
   shareable and restricted state (3.5).
9. The YAML key mapping, especially `date` to `dates.published` and the
   `type` default of `other` (4.1).
10. Equal-contribution groups from `equal-contributor` and
    `equal-contribution-group` (4.2).
11. Every `meta` shortcode as a generated region, with the WP3-owned
    `quarto-meta` generator role (4.4 and amendment 1).
12. Reserved `docstyle-` placement classes with legacy aliases (4.4).
13. The legacy configuration, sidecar and payload-key treatments, including
    retiring `base-doc`, `silence-version-warning` and `styles.json`, and the
    `medrxiv` preset (4.6 and 4.7).
14. The CSS subset: selectors, at-rules and properties (section 5).
15. Integer EMU lengths and CSS `em` (5.5).
16. Wrapping section divs as canonical (6.4).
17. Headers, footers and Word style mappings as plan data (6.5 and 6.6).
18. WP3 ownership of the property matrix and the comparison method (7).
19. Removing `document.json` from the WP1 state layout, and the WP1 manifest
    procedure corrections (3.4).

## Appendix A. Initial property matrix

Levels: S supported; A supported with a documented approximation; O omitted
with a warning; B unsupported and blocking.

| Property | DOCX | Typst | JATS | Notes |
|---|---|---|---|---|
| `font-family` | S | S | O | DOCX uses the first available family; generic families map to the backend default |
| `font-size` | A | S | O | DOCX rounds to half-points |
| `font-weight` | A | S | O | DOCX has bold or not: 600 and above are bold |
| `font-style` | S | S | O | `oblique` renders as italic |
| `font-variant: small-caps` | S | S | O | |
| `color` | S | S | O | |
| `background-color` | S | A | O | Typst fills the block |
| `text-decoration` | S | S | O | underline and line-through |
| `text-align` | S | S | O | |
| `text-indent` | S | S | O | negative values are hanging indents |
| `line-height` (ratio) | S | A | O | Typst leading differs from CSS line height |
| `line-height` (length) | A | A | O | DOCX exact spacing |
| `margin-top`, `margin-bottom` | S | A | O | Typst block spacing |
| `margin-left`, `margin-right` | S | A | O | indents in DOCX; padding in Typst |
| `padding-*` | A | S | O | DOCX applies padding only with a border |
| `border`, `border-*` (paragraphs) | S | A | O | |
| `width` (tables) | S | S | O | |
| `border-collapse` | A | A | O | Word tables behave as collapsed |
| table, `th`, `td` borders and shading | S | S | O | |
| `break-before`, `break-after` | S | S | O | |
| `widows`, `orphans` | A | O | O | DOCX has one widow-and-orphan control |
| `list-style-type` | S | S | S | JATS `list-type` |
| `@page size`, orientation | S | S | O | |
| `@page margin` | S | S | O | |
| `@page :first` | A | A | O | first-page header and footer variants |
| `column-count` | S | S | O | |
| `--docstyle-line-numbers`, `-restart`, `-distance` | S | A | O | Typst line numbering differs in restart options |
| `--docstyle-suppress-top-spacing` | S | A | O | |
| `--docstyle-page-number-start`, `-format` | S | S | O | |
| `--docstyle-word-style` | S | O | O | DOCX style identifier override (section 6.6) |

## References

- Programme specification: `docs/superpowers/specs/2026-07-12-docstyle-vnext-rebuild-design.md`, sections "CSS and property model", "Backend architecture", "Cross-format visual-fidelity contract", "Lua-first runtime" and "Work package 3".
- WP1 contracts: `docs/superpowers/specs/2026-07-14-docstyle-vnext-wp1-schemas-state-design.md`; schemas under `schemas/`; legacy audit `dev/vnext/wp1-legacy-coverage.md`.
- Metadata-binding specification and amendment 1: `docs/superpowers/specs/2026-08-14-docstyle-vnext-metadata-binding-design.md`.
- WP2 package-core design: `docs/superpowers/specs/2026-08-06-docstyle-vnext-wp2-package-core-design.md`.
- WP1 follow-ups taken up here: #29 (canonical key ordering, identifier error messages, `document.json`).
- Issues promoted into WP3: #15 (pure-Lua CSS); related: #17 (semantic lists and tables) and #19 (nested ranges).
