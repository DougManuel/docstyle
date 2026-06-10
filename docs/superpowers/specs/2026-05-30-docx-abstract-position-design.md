# Design: docx abstract position (#149)

**Date:** 2026-05-30
**Issue:** [#149](https://github.com/DougManuel/docstyle/issues/149) — docstyle-docx: author plate appears AFTER abstract in title block
**Related:** [#153](https://github.com/DougManuel/docstyle/issues/153) (DRY unification of metadata-driven sections), [#154](https://github.com/DougManuel/docstyle/issues/154) (Loop 2 cold-harvest of foreign `Abstract`-styled docs) — both deliberately separate follow-ups; do *not* couple this fix to them.

## Problem

When a Quarto document renders via `docstyle-docx`, the abstract appears at the very top of the document, above docstyle's formatted author plate. The expected academic-preprint order is Title → Author block → Abstract. The Typst PDF path already renders this order correctly; only docx is wrong.

**Root cause (verified):** Pandoc emits the YAML `abstract:` as `AbstractTitle` + `Abstract`-styled paragraphs and **hoists them to the top of the document**, before any body content — regardless of where `abstract:` or any `.abstract` div sits in the source. `author-plate.lua` replaces the `:::author-plate:::` body div *in place* (at its body position), which is necessarily downstream of the hoisted abstract. No div placement or Lua-layer change moves the abstract up or down in the rendered docx, because the hoisting happens in Pandoc's writer. The abstract paragraphs must therefore be **relocated in post-render**.

## Cross-format verification (the prerequisite check)

Confirmed empirically before committing to the design — a `:::abstract:::` div in the QMD source must not break the other output paths a shared QMD also targets:

| Format | Behaviour with `:::abstract:::` div present | Verdict |
|---|---|---|
| Typst (docstyle PDF) | Abstract renders on the title page via the preprint `abstract:` argument; the div is absorbed, no duplication | No issue |
| JATS | `jats-fixups.lua` + the `docx`/`jats` validators (#145) read native `abstract:` metadata; the div does not interfere | No issue |
| LaTeX / arXiv PDF | Quarto handles `abstract:` natively | No issue |
| docx | Abstract hoisted to top — the bug this design fixes | Fixed here |

Two suspected cross-format bugs were investigated and dismissed on reading the actual structure: (1) the `:::abstract:::` div does *not* capture the abstract in Typst (output identical with/without the div); (2) the Typst `.typ` `abstract: none` at the `#let preprint(...)` signature is a *default parameter value*, not a mis-placement — the real `#show: doc => preprint(...)` call passes the abstract correctly.

Note: this verification used the *bare* `:::abstract:::` (Pandoc's special div) and found it safe across formats. The final design uses the namespaced `:::docstyle-abstract:::` (see next section), which is strictly safer — it is inert to Pandoc's special-div machinery entirely — so the cross-format safety conclusion holds a fortiori.

## Two separable concerns: placeholder class vs. style class

A key correction from investigation — these are distinct and must not be conflated:

- **The rendered abstract** carries Word `Abstract` / `AbstractTitle` paragraph styles, which docstyle's CSS-first pipeline already maps from the `.abstract` / `.abstract-title` CSS selectors (`R/css_injection.R:409-410`; both Word styles pre-exist in `inst/templates/reference/word/styles.xml`). **This render-direction mapping (Loop 1) is already wired** — Pandoc applies these styles to the YAML `abstract:` natively. The relocation "moves, doesn't rebuild," so this CSS-driven styling is preserved automatically.
- **The placeholder marker** the author types is **docstyle-namespaced: `:::docstyle-abstract:::`** — NOT bare `:::abstract:::`. Bare `.abstract` is a **Pandoc "special div"** (wired to the abstract metadata field; its body content folds into the `Abstract` block) *and* an already-defined docstyle CSS class. Using it as the position marker would triple-overload the name and risk Pandoc's special-div machinery interacting with our empty placeholder. A docstyle-namespaced placeholder class is inert to Pandoc, unambiguously ours, and keeps "where to position" cleanly separate from "how to style."

So: author types `:::docstyle-abstract:::` (position); the relocated paragraphs keep the `Abstract` style → `.abstract` CSS (styling). Styling and positioning never share a class.

## Opt-in surface

The author places a `:::docstyle-abstract:::` div in the body where they want the abstract to appear (e.g. below `:::author-plate:::`). Explicit opt-in only — no smart auto-relocation.

| Author writes | docx result |
|---|---|
| `abstract:` YAML + `:::docstyle-abstract:::` div | Abstract relocated to the div's position (the fix) |
| `abstract:` YAML, no div | Abstract stays at top (today's behaviour — **non-breaking**) |
| Plain `## Abstract` heading + prose, no YAML | Ordinary body content, renders in place, untouched |
| No abstract at all | Nothing happens |

The feature is purely additive: a user who never adds `:::docstyle-abstract:::` sees no behaviour change.

## Architecture: R-first assembly (Lua marker → R relocation)

Follows docstyle's established pattern — Lua emits a text marker, R moves real OOXML in post-render — used today by sections, citations, and anchors. The abstract is a textbook fit because the thing being fought (Pandoc hoisting the abstract to the top) is precisely the Pandoc-layer behaviour the R-first pattern exists to work around.

### Phase 2 — Lua filter (docx only)

A `Div` handler matches class `docstyle-abstract` (the namespaced placeholder, not Pandoc's special `.abstract`). When matched:
- Emits a `DOCSTYLE_ABSTRACT` text marker wrapped in an `ADDIN DOCSTYLE` field code with `type: div`, name `abstract` (via `field-code-utils.lua`, same helpers as the other generated sections), at the div's body position. The `div` payload type means harvest recovers it through the existing generic registry (see Harvest).
- Does **not** build any abstract content — it only plants a position marker. Pandoc's own abstract emission is left to Pandoc.
- Returns `nil` for non-docx formats (`FORMAT ~= "openxml"`), so no marker leaks into Typst/JATS/LaTeX.

Open implementation detail: whether this lives in a new `abstract.lua` or extends an existing filter. Either is fine; the new-file choice is cleaner pending the #153 unification.

### Phase 3 — R post-render: `relocate_abstract()` inside `finalize_docx`

1. Scan `document.xml` for the `DOCSTYLE_ABSTRACT` marker paragraph; record its position. The marker sits inside a three-paragraph `ADDIN DOCSTYLE` `div` field code (field-start paragraph with `fldChar begin` + `instrText {"type":"div","name":"abstract"}` + `separate`; the marker paragraph; field-end paragraph with `fldChar end`).
2. Find the contiguous `AbstractTitle` + `Abstract`-styled paragraphs Pandoc hoisted to the document head.
3. **Move** that block (detach + re-insert via `xml_add_sibling`; a same-document-tree move, like adjacency relocation in `anchor_assembly.R`) to sit **inside the field-code wrapper** — between the field-start and field-end paragraphs (insert before field-end). Remove **only** the `DOCSTYLE_ABSTRACT` marker paragraph; **keep the field-start and field-end paragraphs**. This is load-bearing for round-trip: harvest detects the abstract by the wrapping field code (nesting `fldChar begin`…`end`), so the wrapper must survive — deleting it would leave bare `Abstract`-styled prose that re-harvests as plain body text, not a `:::docstyle-abstract:::` placeholder. (Note: xml2's `xml_add_sibling` copies an in-tree node in the version in use, so the move is implemented as add-sibling + `xml_remove` of the originals; capture all node references before mutating.)
4. Marker present but no abstract paragraphs found → remove **only** the marker paragraph, **keep the empty field-code wrapper** (an author who opted in but has no abstract yet still round-trips to an empty `:::docstyle-abstract:::` placeholder), emit a `message()` diagnostic, return 0L. No error.
5. Graceful fallback — bare `DOCSTYLE_ABSTRACT` marker with no field-code wrapper (should not occur from the real pipeline): move the abstract before the bare marker and remove it. This path cannot round-trip (no wrapper) but does not corrupt the document.

**Key design choices:**
- **Move, don't rebuild** — relocate Pandoc's already-styled paragraphs so the `Abstract`/`AbstractTitle` styling (and multi-paragraph structure, language tags, etc.) is inherited intact. This is what makes this approach more robust than re-emitting the abstract from a Lua filter (the rejected alternative, which would have to track Pandoc's emission format forever).
- **Ordering within `finalize_docx`** — runs as a `finalize_docx` sub-step operating on the assembled `document.xml`, consistent with `inject_section_headers_footers` and the other finisher steps. Must run before style pruning (the abstract paragraphs carry styles pruning could otherwise touch). Exact ordering relative to section assembly is pinned in the implementation plan.

**Primary implementation risk:** reliably identifying the hoisted abstract block in step 2. A multi-paragraph abstract yields one `AbstractTitle` paragraph followed by multiple contiguous `Abstract` paragraphs; the relocation must grab the whole contiguous run as a unit. Tractable (the styles are distinctive and the run is contiguous at the document head) but the part most likely to need edge-case care. Covered by tests.

## Harvest (Word → QMD round-trip)

Harvest is driven by the **field-code mechanism (Loop 3)**, the same one toc / version-history / author-plate already use — *not* by Word-`Abstract`-style recognition. Investigation confirmed why this is the right and only clean choice: field-code-range detection runs at the top of the harvest loop (`docx_to_qmd.R:1727-1728`), ~800 lines *before* the per-paragraph style `switch` (`:2516`), and the generic div handler calls `next` — so a field-code-wrapped range structurally preempts style dispatch. The two mechanisms cannot both fire on the same paragraphs; Loop 3 wins.

The abstract straddles a line the other generated sections don't: it is **both metadata and rendered prose**. So harvest must split what render+relocate joined.

1. **Position round-trip (free, via registry):** register `abstract` as a `div_type` in `inst/schema/docstyle-field-codes.json` (and the `.docstyle_div_fallback` in `R/field_codes.R`). The existing `detect_docstyle_field_codes()` → generic div handler (`docx_to_qmd.R:1868-1882`) then emits the `:::docstyle-abstract:::` div at the correct body position with **no new harvest switch case**.
2. **Content round-trip (the wrinkle):** the generic div handler emits the div but does not populate YAML. So the abstract handler must, when processing the field-code range, extract the `Abstract`-styled paragraphs' text into `yaml_header$abstract` (multi-paragraph preserved) and emit the **empty** `:::docstyle-abstract:::` placeholder div at that position — *not* the prose inline. This mirrors how `version-history` captures its content to `yaml_header` while emitting an empty placeholder. (Exact insertion point in the harvest loop pinned in the implementation plan — it sits alongside the existing range-content capture, on the placeholder-and-`next` path so it stays mutually exclusive with any future Loop 2 fallback.)

**Result:** the harvested QMD reproduces the input shape — `abstract:` in YAML, empty `:::docstyle-abstract:::` div in the body. Re-rendering re-runs relocation and lands the abstract in the same place. Round-trip stable.

**Why this is load-bearing for cross-format fidelity:** because harvest restores `abstract:` to YAML (not body prose), a subsequent render to *any* format still finds the abstract in metadata where the Typst template and JATS validator expect it. Leaving the prose inline would lose the title-page abstract on the next Typst render.

**Edge case — abstract at top, no field code** (foreign docx, or never opted in): harvest treats it as today — the `Abstract`-styled paragraphs fall through the style switch to plain body text (`docx_to_qmd.R` default branch; there is deliberately no `Abstract` case). Harvest of foreign/non-opted-in documents is unchanged by this work.

**Loop 2 (cold-harvest of foreign abstracts) is OUT OF SCOPE — separate follow-up.** Recognizing the Word `Abstract` style in a *foreign* document (a journal template harvested cold, with no docstyle field code) so it round-trips to `:::docstyle-abstract:::` + `abstract:` YAML is the symmetric CSS-first harvest-direction gap, but it is distinct from the #149 bug and is filed separately. If/when added, the investigation flagged a hazard: the abstract div range must stay on the placeholder-and-`next` path (never the fall-through path used by list/table/section/figure branches), or Loop 2 + Loop 3 would double-emit. This spec keeps them mutually exclusive by construction.

## Testing

**Unit — `relocate_abstract()` (synthetic `document.xml`, XPath assertions):**
- Single-paragraph abstract + marker → moved to marker position; marker removed; styles intact.
- Multi-paragraph abstract → `AbstractTitle` + all contiguous `Abstract` paragraphs moved as one block, order preserved. *(the flagged risk)*
- Marker present, no abstract paragraphs → marker removed silently, no error, document otherwise unchanged.
- No marker → abstract left at top, untouched.
- Target below the author-plate block → final order is plate → abstract (XPath paragraph indices).

**Lua filter (pandoc-only, like the #140 unit test):**
- `.abstract` div under docx/openxml → emits `DOCSTYLE_ABSTRACT` marker wrapped in `ADDIN DOCSTYLE`.
- `.abstract` div under `-t typst` / `-t jats` / `-t latex` → filter returns nil, **no marker leak**. *(the cross-format-safety tripwire — the #124 lesson encoded permanently)*

**Harvest (round-trip):**
- docx with relocated-abstract field code → harvest emits empty `:::docstyle-abstract:::` div at the right position **and** populates `abstract:` YAML (multi-paragraph preserved).
- Foreign docx (abstract at top, no field code) → harvest extracts to `abstract:` YAML, no `:::docstyle-abstract:::` div (unchanged).

**Integration (quarto-gated):**
- Full render: QMD with `abstract:` + `:::author-plate:::` + `:::docstyle-abstract:::` → rendered docx has abstract below the plate (XPath on paragraph order).
- Cross-format non-regression: same QMD → `docstyle-typst` → abstract still on title page, no duplication, no stray marker.

## Error handling

No hard-fail paths. Every degradation lands on today's behaviour (abstract at top) rather than a broken render — for post-render OOXML surgery, "the fix didn't apply" is the correct worst case, never "the document is corrupted." The single diagnostic is a non-error `message()` when a `:::docstyle-abstract:::` marker is present but no abstract content exists.

## Out of scope

- The #153 DRY unification of metadata-driven section placeholders. This fix can later register `abstract` in that unified pattern (its generator being "relocate, don't build"), but the two are independent and #149 depends on none of #153.
- Any change to version-history / author-plate / toc / bibliography rendering.
- Auto-relocation without an explicit `:::docstyle-abstract:::` div (rejected in favour of explicit opt-in).
- Loop 2 cold-harvest of foreign `Abstract`-styled documents — filed as **#154** (separate follow-up; see Harvest section for the mutual-exclusivity constraint).

## Files touched (anticipated)

- New: `_extensions/docstyle/abstract.lua` (or extension of an existing filter) — emits `DOCSTYLE_ABSTRACT` marker.
- `_extensions/docstyle/_extension.yml` — register the filter under `docx` only; add to `EXTENSION_SOURCE_FILES` in `R/use_docstyle.R`.
- `R/finalize_docx.R` (or a finisher submodule) — new `relocate_abstract()` step.
- `R/docx_to_qmd.R` — harvest: extract abstract prose to YAML, emit empty `:::docstyle-abstract:::` div.
- `inst/schema/docstyle-field-codes.json` — register `abstract` div type.
- Tests: `test-finalize-*` (relocation unit), a Lua-filter test, harvest tests, integration test.
- `inst/schema/docstyle-field-codes.json` + `R/field_codes.R` `.docstyle_div_fallback` — register `abstract` div type.
- `NEWS.md`, version bump, `CLAUDE.md` (document the `:::docstyle-abstract:::` placeholder + relocation, and that Loop 1 CSS→Word styling is already wired).
