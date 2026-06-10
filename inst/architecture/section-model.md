# OOXML section model mapping

This document maps docstyle's section abstractions to the OOXML section model defined in ECMA-376 (5th edition, Part 1). It serves as an audit artifact for verifying architectural alignment and as a reference during development.

## 1. OOXML section model (normative reference)

### 1.1 What a section is

A section is a contiguous range of document content that shares a common set of page-level properties: page size, margins, orientation, headers/footers, page numbering, and line numbering. Every Word document has at least one section.

**Spec reference:** ECMA-376 Part 1, 17.6.17 `sectPr` (Section Properties)

### 1.2 The backward-looking sectPr

The `w:sectPr` element defines properties for the section that **ends** at the point where the sectPr appears — not the section that begins after it. This is the single most important fact about the OOXML section model.

```
Section 1 content...
<w:p>
  <w:pPr>
    <w:sectPr>            ← defines Section 1's properties
      <w:type w:val="nextPage"/>
      <w:pgSz .../>
      ...
    </w:sectPr>
  </w:pPr>
</w:p>
Section 2 content...      ← Section 2 properties come from the NEXT sectPr
```

The body-level `w:sectPr` (direct child of `w:body`, not inside a paragraph) defines the **last** section.

**Spec reference:** 17.6.17 — "This element defines the section properties for the final section of the document. [...] For any other section, section properties are stored as part of the final paragraph's properties."

### 1.3 Section type (break type)

The `w:type` element within sectPr defines how the section **starts** (the break type between the previous section and this one):

| Value | Meaning |
|-------|---------|
| `nextPage` | Section starts on a new page |
| `continuous` | Section starts on the same page (column break only) |
| `evenPage` | Section starts on the next even page |
| `oddPage` | Section starts on the next odd page |
| (omitted) | Same as `nextPage` |

**Spec reference:** 17.18.77 `ST_SectionMark`

### 1.4 Headers and footers

Each sectPr can reference footer and header files via `w:footerReference` / `w:headerReference`:

```xml
<w:sectPr>
  <w:footerReference w:type="default" r:id="rId10"/>
  <w:footerReference w:type="first" r:id="rId11"/>
  <w:headerReference w:type="default" r:id="rId12"/>
  ...
</w:sectPr>
```

**Type values:** `default`, `first`, `even`

**Inheritance ("same as previous"):** If a sectPr omits a footerReference for a given type (e.g., no `type="default"` footer), Word inherits that footer from the preceding section. An explicit reference — even to the same file — breaks inheritance.

**First-page gating (`w:titlePg`):** The `w:titlePg` element in a sectPr enables first-page behaviour. Without it, a `type="first"` footerReference is **ignored** and the default footer is used on all pages. `titlePg` is per-section: each sectPr independently controls whether its first page uses a different footer/header.

**Spec references:** 17.10.5 `footerReference`, 17.10.6 `titlePg`

### 1.5 Page numbering

```xml
<w:pgNumType w:start="1"/>
```

Restarts page numbering at the given value for the section defined by this sectPr. When absent, numbering continues from the previous section. Only works reliably with `nextPage` breaks (continuous breaks can produce unpredictable results).

**Spec reference:** 17.6.12 `pgNumType`

### 1.6 Line numbering

```xml
<w:lnNumType w:countBy="1" w:restart="newSection" w:distance="360"/>
```

Restart values: `continuous` (across sections), `newSection`, `newPage`. Per-paragraph suppression via `w:suppressLineNumbers` in pPr.

**Spec reference:** 17.6.8 `lnNumType`

### 1.7 sectPr child element order

OOXML requires specific ordering of child elements within sectPr:

```
footerReference/headerReference → type → pgSz → pgMar → lnNumType → pgNumType → cols → docGrid → titlePg
```

Non-compliance can cause Word to reject the document.

**Spec reference:** 17.6.17 (XML schema definition)


## 2. Docstyle's section representations

### 2.1 Three-phase pipeline

Docstyle processes sections across three phases:

| Phase | Tool | Section representation |
|-------|------|-----------------------|
| 1. Pre-render | R (officer) | Footer/header files in reference.docx; page layout in body sectPr |
| 2. Pandoc | Lua filter | Text markers: `DOCSTYLE_SECTION::{class}::{page-break}::{line-numbers}` |
| 3. Post-render | R (xml2) | OOXML sectPr elements in final document |

### 2.2 QMD section divs

User-facing abstraction. Sections are declared as Pandoc divs with class and attributes:

```markdown
::: {.section-body page-break="true" line-numbers="continuous"
     footer-right="{page}" page-start="1"}
Content here...
:::
```

This is a **forward-looking** declaration: "the content inside this div should have these properties." This is the fundamental semantic gap with OOXML's backward-looking model.

### 2.3 Text markers (Lua output)

The Lua filter (`page-section.lua`) converts QMD divs into text markers that R can find in the rendered DOCX:

```
DOCSTYLE_SECTION::section-body::true::continuous
(content)
DOCSTYLE_SECTION_END::section-body::false::continuous
```

Each marker also carries a JSON payload in an `ADDIN DOCSTYLE` field code wrapped around the marker text. This payload contains all div attributes (footer-right, page-start, etc.) for round-trip fidelity.

### 2.4 Section sequence (assembly output)

`assemble_section_breaks()` produces a `section_sequence` list, where each entry has:

- `section_class`: e.g., "section-body"
- `sectpr_para`: the XML node where sectPr was attached
- `is_closing`: whether this is a closing marker
- `field_code_payload`: the JSON attributes from the QMD div
- `line_numbers`: line numbering mode

### 2.5 page-config.json (sidecar)

Written by the pre-render phase, read by the post-render finisher. Contains page layout defaults, footer/header configuration, and per-section style overrides. This is the "desired state" for the document's page-level formatting.


## 3. Translation points

These are places where docstyle compensates for the semantic gap between its forward-looking div model and OOXML's backward-looking sectPr model.

### 3.1 Payload shift (finalize_docx.R, lines 79-98)

**Problem:** Each text marker maps to its **preceding** sectPr (the paragraph before the marker receives the sectPr). But the marker's attributes describe the section **after** the marker, not before it.

**Translation:** `finalize_docx.R` shifts `field_code_payload` forward by one position in the section_sequence:

```
section_sequence[1].sectpr → gets YAML defaults (no field code overrides)
section_sequence[2].sectpr → gets section_sequence[1]'s payload
section_sequence[3].sectpr → gets section_sequence[2]'s payload
body sectPr               → gets section_sequence[last]'s payload
```

**OOXML alignment:** This correctly maps to the backward-looking model. Marker N's sectPr ends the **previous** section, so it should carry the previous section's footer configuration. The current section's footer goes on the **next** sectPr.

**Risk:** The shift logic assumes a linear sequence of markers. Nested or interleaved divs would break this assumption (currently not supported).

### 3.2 Line-numbers backward assignment (section_assembly.R, lines 380-537)

**Problem:** A marker says "the section starting here should have line-numbers=continuous." But the sectPr attached at this marker ends the **previous** section.

**Translation:** During assembly, the loop tracks `prev_line_numbers`. When processing marker N, it builds the sectPr with marker N-1's line-numbers value (which is correct, since this sectPr ends the section started by marker N-1). The body sectPr receives the last marker's line-numbers value.

**OOXML alignment:** Direct mapping to the spec. Each sectPr receives the line-numbers for the section it defines (ends).

### 3.3 Wrapping divs and section count

**Problem:** A QMD wrapping div creates two sectPr elements: one opening (ends the previous section) and one closing (ends the wrapped section). A document with 3 QMD sections can have 4+ OOXML sections.

**Translation:** Opening marker's sectPr closes the section before the div. Closing marker's sectPr closes the div's own section. Content after the last closing marker is in the "final section" defined by the body sectPr.

**OOXML alignment:** Correct. Each OOXML section has a well-defined sectPr that controls it.

**Edge case — adjacent markers:** When a closing marker and the next opening marker share the same predecessor paragraph, the opening marker's sectPr replaces the closing marker's. The opening marker's `nextPage` type is deferred to the next closing marker to preserve correct page break behaviour.

### 3.4 Body sectPr as final section (section_assembly.R, lines 561-621)

**Problem:** After all closing markers, the body sectPr defines the final section. This section typically has no content (just empty marker paragraphs). Without a `continuous` type, it creates a trailing blank page.

**Translation:** The assembler sets the body sectPr to `continuous` after processing markers.

**OOXML alignment:** Correct use of continuous to avoid an unwanted page break. However, this means the body sectPr's type is always overridden, regardless of the last section's properties. A document that genuinely needs the last section to start on a new page would need special handling (not currently implemented — no known use case).

### 3.5 Footer cascade resolution (section_headers.R, lines 216-311)

**Problem:** OOXML's "same as previous" inheritance is implicit (omit footerReference = inherit). Docstyle's QMD model uses explicit attributes (footer-right="{page}").

**Translation:** `resolve_all_sections()` walks the section sequence with a "previous effective footer" state. When a section's payload specifies footer positions, those override; unspecified positions inherit from the previous section. The result is explicit footerReference elements on every sectPr — no implicit inheritance in the output.

**Design choice:** Always emit explicit references (no reliance on OOXML inheritance). This is more verbose but deterministic. Every sectPr in the output has the footer references it needs. Identical configs share footer XML files via fingerprint-based deduplication (`hf_fingerprint()`).

**OOXML alignment:** Valid. Explicit references are never wrong — they just prevent "same as previous" from appearing in Word's UI. This is acceptable for programmatically generated documents.

### 3.6 titlePg per-section control (section_headers.R, lines 298-307)

**Problem:** `first-page: false` means "suppress footer on the title page." But cascading this to all sections would suppress the footer on the first page of every section.

**Translation:** The cascade resolver sets `first_page = TRUE` for all sections after the first one that inherits footer text. Only the document's first section (typically the title page section) can have `titlePg` enabled.

**OOXML alignment:** Correct per ECMA-376 17.10.6. titlePg is per-section, and docstyle handles it per-section.

### 3.7 Suppress first paragraph top spacing (section_cleanup.R)

**Problem:** When a heading with CSS `margin-top` (rendered as `w:before` in Word) is the first element after a section break, Word renders the space-before as a visible gap at the top of the page. Word's `suppressSpBfAfterPgBrk` compat setting only works after hard page breaks, not section breaks.

**Translation:** `suppress_first_paragraph_spacing()` runs after assembly (section boundaries established, markers removed) but before the payload shift. For each section boundary, it finds the first content paragraph (skipping empty/structural paragraphs) and sets `w:before="0"`.

**Resolution precedence:** div `suppress-top-spacing` attribute > named `@page` `--docstyle-suppress-top-spacing` > global `@page` `--docstyle-suppress-top-spacing`. This follows the same pattern as other div attribute overrides.

**Timing:** Runs before the payload shift because `suppress-top-spacing` is forward-looking (describes the section the div starts). Before the shift, each entry's `field_code_payload` still contains the original div attributes for that section.

**OOXML alignment:** Direct manipulation of `w:spacing w:before` on paragraph properties. No sectPr involvement — this is a paragraph-level correction.

### 3.8 pgNumType placement for wrapping divs (section_assembly.R, lines 421-446)

**Problem:** `page-start` should apply to the section containing the div's content. For wrapping divs, that's the section defined by the closing marker's sectPr, not the opening marker's.

**Translation:** The assembler checks whether an opening marker has a matching closing pair. If yes, page-start is deferred to the closing marker. If no (empty marker div), page-start goes on the opening marker's sectPr.

**OOXML alignment:** Correct. The closing marker's sectPr defines the wrapped section, so pgNumType belongs there.


## 4. Concepts with direct OOXML equivalents

These docstyle concepts map 1:1 to OOXML elements with no translation layer.

| Docstyle concept | OOXML element | Notes |
|-----------------|---------------|-------|
| `page-break="true"` | `<w:type w:val="nextPage"/>` | Section type on the sectPr defining that section |
| `line-numbers="continuous"` | `<w:lnNumType w:restart="continuous"/>` | Direct attribute mapping |
| `footer-right="{page}"` | `footerN.xml` with `PAGE` field code | Content generated per spec 17.16.5.51 |
| `{page}` | `PAGE` field code | Current page number |
| `{pages}` | `NUMPAGES` field code | Total document pages |
| `{sectionpages}` | `SECTIONPAGES` field code | Pages in current section |
| `page-start="1"` | `<w:pgNumType w:start="1"/>` | Direct value pass-through |
| `footer="false"` | Empty footerN.xml (no content runs) | Explicit suppression |
| `suppress-top-spacing="true"` | `<w:spacing w:before="0"/>` on first content paragraph | Post-assembly invariant enforcement |

### Field code structure

Docstyle generates field codes exactly per ECMA-376 17.16 (Fields):

```xml
<w:r><w:fldChar w:fldCharType="begin"/></w:r>
<w:r><w:instrText> PAGE </w:instrText></w:r>
<w:r><w:fldChar w:fldCharType="separate"/></w:r>
<w:r><w:t>#</w:t></w:r>
<w:r><w:fldChar w:fldCharType="end"/></w:r>
```

Cached display value is `#` (not a real number) to make stale values visually obvious. Word replaces this on field update. `updateFields` in settings.xml triggers automatic recalculation on document open.

### Footer XML structure

Docstyle uses Pattern 1 (regular tab stops) as the canonical output format:

```xml
<w:ftr>
  <w:p>
    <w:pPr>
      <w:tabs>
        <w:tab w:val="center" w:pos="4680"/>
        <w:tab w:val="right" w:pos="9360"/>
      </w:tabs>
    </w:pPr>
    (left runs)(tab)(center runs)(tab)(right runs)
  </w:p>
</w:ftr>
```

Tab stop positions (4680/9360 twips) correspond to center/right positions on a US Letter page with 1-inch margins. This is the same pattern Word uses for tab-based footer positioning.


## 5. Untested boundaries and known risks

### 5.1 Even-page headers/footers

OOXML supports `w:type="even"` for different even-page footers/headers. Docstyle does not generate or handle these. Documents with even-page footer requirements would need additional infrastructure.

**Impact:** Low for current use cases (academic manuscripts, protocols). Would matter for book-format documents.

### 5.2 Nested or interleaved section divs

The payload shift (3.1) and line-numbers assignment (3.2) assume a strictly linear sequence of markers. If divs were nested (section inside section), the shift logic would assign payloads incorrectly.

**Current guard:** Lua filter does not support nesting. QMD syntax naturally prevents it. But no runtime validation exists.

### 5.3 continuous breaks with pgNumType

ECMA-376 does not guarantee that pgNumType works with continuous section breaks. In practice, Word sometimes honours it and sometimes doesn't. Docstyle's `apply_page_start()` upgrades continuous to nextPage when page-start is specified, which is the safe approach.

**Untested:** A document that genuinely needs continuous + page number restart. No known use case.

### 5.4 Multiple paragraphs in footer/header files

Footer XML files can contain multiple paragraphs. Docstyle always generates single-paragraph footers. The harvester (`parse_footer_xml()`) uses the first content paragraph and warns if additional content paragraphs exist. Multi-paragraph footers from third-party tools could lose content on round-trip.

### 5.5 Orphaned pre-render footer files

The pre-render phase (officer) writes footer1.xml/header1.xml into reference.docx. The post-render finisher writes new files starting from footer3.xml. Pandoc strips footerReference from the body sectPr, so footer1.xml becomes unreferenced. These files are harmless dead weight but increase archive size.

**Tracked:** GitHub issue #44

### 5.6 Redundant attributes on closing markers

The Lua filter copies all div attributes to both opening and closing markers. Closing markers therefore carry footer-right, page-start, etc., even though only the payload shift determines where these attributes are applied. This is intentional for round-trip fidelity (re-harvesting the docx reconstructs the full div attributes), but creates redundancy.

**Tracked:** GitHub issue #45

### 5.7 Body sectPr always set to continuous

After assembly, the body sectPr type is always set to continuous (3.4). This prevents trailing blank pages but means the final section can never start on a new page. For current document types (where the last wrapping div's closing marker is the logical end of content), this is correct. Documents with significant content after the last section div would need a different approach.

### 5.8 sectPr child element ordering

`build_sect_pr_xml()` generates elements in the correct ECMA-376 order (type, pgSz, pgMar, lnNumType, pgNumType, cols, docGrid). The finisher also respects this order when adding elements to existing sectPr nodes. However, `add_hf_refs_to_sectpr()` inserts footerReference at position 0 (before type), which is correct per spec (references precede type).

**Risk:** Any code that adds child elements to sectPr must respect the ordering. There is no centralised validation of element order after all modifications.


## 6. Architectural patterns

### 6.1 State flow through the pipeline

```
QMD div attributes
    ↓ (Lua filter)
Text markers + JSON payload in ADDIN DOCSTYLE field codes
    ↓ (R assembler)
section_sequence with sectpr_para nodes and field_code_payload
    ↓ (payload shift in finalize_docx.R)
Shifted section_sequence (payload[i] → section[i+1])
    ↓ (cascade resolver in section_headers.R)
Resolved per-section footer/header configs
    ↓ (XML writer in footer.R + section_headers.R)
footerN.xml files + footerReference elements in sectPr
```

Each stage transforms the representation closer to OOXML's model. The JSON payload is the "desired state" for each section's page-level formatting; the finisher translates this into the backward-looking sectPr structure.

### 6.2 Comparison with Zotero citation pipeline

The Zotero pipeline uses a similar state-flow pattern:

```
Pandoc citation keys → DOCSTYLE_CITE:: markers → field-codes.json (state) → ADDIN ZOTERO_BIBL XML
```

Both pipelines:
- Use text markers as an intermediate representation
- Store desired state in JSON sidecar files
- Transform to OOXML XML in the post-render phase
- Preserve state for round-trip (field-codes.json persists across renders)

The section pipeline differs in that its "state" is transient (section_sequence exists only during finalize_docx execution), while Zotero's state is durable (field-codes.json persists on disk). A durable section state model would be the natural next step if section complexity grows.

### 6.3 Current approach: implicit state model

Docstyle does not have an explicit "section state object" analogous to a virtual DOM. Instead, the state is implicit in the pipeline:

- The QMD div attributes **are** the desired state
- The Lua filter preserves them in JSON payloads
- The R finisher transforms them to OOXML

This works because the transformation is straightforward (each div maps to one or two sectPr elements with well-defined rules). The complexity is in the **translation rules** (payload shift, line-numbers assignment, pgNumType placement), not in managing complex interacting state.

An explicit section state model (analogous to React's virtual DOM) would add value if:
- Sections needed cross-references to each other (e.g., "inherit from section X")
- The transformation rules became order-dependent or stateful
- Multiple independent passes needed to read/modify section state
- Validation required a holistic view of all sections before rendering

Currently, none of these conditions hold. The translation rules are local (each section depends only on its predecessor) and the pipeline is single-pass.


## 7. Open questions for review

1. **Element ordering enforcement:** Should docstyle validate sectPr child element order after all modifications, or is the current approach (each function respects order individually) sufficient?

2. **Explicit vs implicit footer inheritance:** Docstyle always writes explicit footerReference elements. Should there be a mode that uses OOXML's implicit inheritance (omit reference = same as previous) for cleaner output?

3. **Durable section state:** Should the section_sequence be persisted to a JSON sidecar (like field-codes.json for Zotero) to enable cross-render state tracking and validation?

4. **Nested section support:** If nested sections become necessary, what changes would the payload shift and line-numbers assignment need? Is the current linear model a dead end or a reasonable starting point?

5. **Body sectPr flexibility:** The current "always continuous" rule for the body sectPr works for wrapping-div documents. How should documents with content after the last section div be handled?
