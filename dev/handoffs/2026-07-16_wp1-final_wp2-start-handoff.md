# Docstyle WP1 Final and WP2 Start Handoff

- **Prepared:** July 16, 2026
- **Repository:** <https://github.com/DougManuel/docstyle>
- **WP1 merge:** PR #30, merge commit `be60244`
- **Current branch:** `codex/vnext-wp2-ooxml-spike`, based on `origin/main` at `be60244`
- **Purpose:** replace the July 14--16 root-level handoffs with one post-merge record and orient review of the WP2 feasibility specification.

## Current state

WP0 and WP1 are complete. WP1 merged after the final specification-author review closed the document-scoped identifier and manifest-contract blockers. The isolated WP2 branch contains only documentation for review; no XML, ZIP or production code has been implemented.

Baseline verification on the new branch:

```text
quarto run tests/vnext/conformance/run.lua
PASS 136 | FAIL 0

env R_PROFILE_USER=/dev/null Rscript -e 'devtools::test(stop_on_failure = TRUE)'
FAIL 0 | WARN 30 | SKIP 4 | PASS 3400
```

WP0 fixtures are unchanged.

## GitHub state

- Programme issue #27 marks WP1 complete and links the final verification record.
- WP1 issue #28 is closed as completed.
- Follow-up issue #29 was pruned after the merge and now lists only unresolved work.
- WP2 feasibility issue #31 defines the bounded spike, gates, outputs and exclusions.
- The merged remote branch `docs/vnext-wp1-schema-state` still exists. Delete it only after this consolidated handoff is reviewed and pushed.

## WP1 decisions now settled

- QMD is authoritative; returned authored edits become reviewable proposals.
- The semantic model is an ordered content tree plus identifier-keyed registries.
- Explicit identifiers are authoritative; generated identifiers are durable and document-scoped.
- Hashes detect change and do not define identity.
- DOCSTYLE version-four envelopes remain small and self-describing; rich metadata lives in catalogues and durable state.
- Local state uses a manifest plus typed generation-qualified stores with the manifest rename as the commit point.
- Profile validation is composed through active profile schemas; PICOS and PCC remain deferred profiles.
- `anchor` is the seventeenth node type.
- Core metadata includes document type, licence and version history.
- Unknown future data is preserved as data and never executed.
- The local contributor and user path must not require R, Python, a cloud service or a proprietary server.

Do not reopen these decisions during the XML spike unless executable evidence shows that a WP1 contract is impossible. Such a result is an architectural finding for Doug, not permission to change the contract inside the spike.

## WP2 specification for review

Proposed specification:

`docs/superpowers/specs/2026-07-16-docstyle-vnext-wp2-ooxml-feasibility-design.md`

The specification treats the XML layer as a critical feasibility gate. It compares:

1. a vendored pure-Lua namespace parser plus a Docstyle token-preservation overlay;
2. a broader pure-Lua tree library behind the same adapter;
3. a narrow purpose-built token layer.

The leading hypothesis uses SLAXML for namespace events and a Docstyle byte-span index for bounded edits. SLAXML is not accepted as-is: its documented well-formedness and namespace-serialization limitations must be closed by guards or the candidate fails.

The package experiment uses Pandoc's bundled ZIP API only if Docstyle can validate central-directory metadata before decompression and cap actual decompressed output. If the API does not expose enough metadata or cannot bound output, the spike must add a bounded Lua layer or return no-go. Decompressing an untrusted entry and checking its size afterwards is not safe.

## Review priorities

Review the proposed specification for:

- whether byte preservation outside edited ranges is the correct contract;
- whether UTF-8 and UTF-16 coverage is sufficient for the supported OOXML boundary;
- whether the archive interface can preflight ZIP bombs and cap actual decompression output;
- whether the three candidate approaches are genuinely comparable;
- whether the performance gates are strict enough to reveal an impractical parser without creating hardware-sensitive CI;
- whether any requirement accidentally expands the spike into production WP2.

## Sources checked for the design

- Local runtime: Quarto 1.9.26, Pandoc 3.8.3, embedded Lua 5.4.
- Pandoc documents dependency-free Lua filters, `pandoc.system.cputime`, file helpers and `pandoc.zip` archive/entry objects.
- SLAXML documents Lua 5.4 support, namespace events, comments, processing instructions, CDATA and DOM serialization. It also documents incomplete well-formedness enforcement and namespace-serialization hazards.
- LuaXML is current and pure Lua but has a broader LuaTeX-oriented API and mixed module licences.
- xml2lua documents Lua 5.1--5.3 and table conversion; it does not establish the required namespace and lexical-preservation contract.

## Remaining housekeeping

The original root-level files remain untracked in the primary checkout:

- `2026-07-14_handoff.md`
- `2026-07-15_wp1-pr-review-handoff.md`
- `2026-07-16_handoff.md`

Do not remove them until this consolidated file has been reviewed and pushed. Afterward, remove the superseded local files, delete the merged remote WP1 branch and retain this file as the handoff of record.

## Next action

Doug reviews the proposed WP2 specification. Revise it until approved. Only then write the detailed spike implementation plan; do not prototype candidates before approval.
