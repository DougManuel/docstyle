# Docstyle vNext Rebuild Programme Specification

**Status:** Draft for review
**Date:** July 12, 2026
**Decision:** Proceed with a field-code-centred, Lua-first rebuild
**Primary audiences:** Users and collaborators; maintainers, contributors and coding agents
**Implementation planning:** Separate work-package specifications and plans will follow this programme specification

## Executive summary

Docstyle vNext will rebuild Docstyle as long-term open infrastructure for reproducible scientific documents. Quarto will be the only required user runtime. Lua and Pandoc will implement the core pipeline. R will remain available during migration, but it will not be part of the permanent user-facing architecture.

QMD will remain the normal authored source. YAML will hold semantic document metadata. CSS will provide transparent, version-controlled styling for document, page, section and element properties. Versioned `ADDIN DOCSTYLE` field codes will preserve portable semantics inside DOCX files. JSON sidecars will retain richer local state for citations, comments, revisions, stable identifiers, provenance and round-trip reconciliation.

A shared semantic document model will support separate DOCX, Typst and JATS backends. The backends will preserve common content and metadata while declaring format-specific capabilities. They will not promise visual equivalence.

The rebuild will be FAIR-informed. It will favour machine-actionable metadata, persistent identifiers, open schemas, qualified relationships, provenance, accessible local tools and transparent document structure. It will not claim that a DOCX file or Docstyle output is formally FAIR-compliant.

The current engine will remain runnable during a bounded migration period. vNext will replace it only after defined content-preservation, interoperability and real-project acceptance gates pass.

## Decision and rationale

The current Docstyle implementation has established that the underlying approach is useful. It renders styled scientific manuscripts, preserves live Zotero citations, carries structured metadata in Word field codes and supports Word-to-QMD collaboration. DemPoRT and POPCORN provide substantial real-world examples.

The existing implementation also shows that incremental correction alone will not provide a durable foundation. The present pipeline distributes document intent across QMD divs, CSS, YAML, Lua markers, field codes, JSON sidecars, R state and OOXML. Some behaviours depend on processing order or on several modules interpreting the same construct identically. Section assembly, nested field-code ranges and harvest validation have exposed these limits.

vNext will retain the successful concepts and replace the distributed processing model. The rebuild is preferred to a sequence of local refactors because the intended product has changed from an internal renderer into reusable open infrastructure.

## Goals

vNext will:

1. Require only Quarto for installation and use.
2. Keep QMD as the normal authored source of manuscript content.
3. Use CSS as the transparent source for document, page, section and element presentation.
4. Use versioned field codes as the portable semantic layer inside DOCX.
5. Use versioned JSON sidecars for durable local workflow state.
6. Support warm and cold DOCX round trips with explicit fidelity reporting.
7. Preserve semantic structure for headings, paragraphs, lists, tables, citations, figures and annotations.
8. Use one shared semantic model with separate DOCX, Typst and JATS backends.
9. Provide model-neutral local commands for inspection, extraction, semantic patching and validation.
10. Fail safely when content, metadata or provenance cannot be reconciled.
11. Publish schemas, capability contracts and migration rules.
12. Retire the legacy R engine after explicit acceptance gates pass.

## Non-goals

The initial rebuild will not:

- claim formal FAIR compliance;
- reproduce full browser CSS;
- require exact visual parity across DOCX, Typst and JATS;
- round-trip arbitrary Word documents without constraints;
- accept every edit that Word permits;
- preserve the current R API or internal file structure;
- preserve incidental layout quirks from the legacy engine;
- include MCP or provider-specific LLM integrations in the core;
- maintain two permanent rendering engines;
- replace Zotero as a reference manager;
- infer causal or semantic meaning from visual formatting alone.

## Design principles

### The local path is complete

A user with Quarto and the Docstyle extension must be able to render, inspect, validate and round-trip a supported document without R, Python, a cloud service or a proprietary Docstyle server. Optional integrations may add convenience, but they must not replace the local workflow.

### QMD remains the normal authored source

Docstyle will treat edits returned from DOCX as proposed changes to QMD. It will not silently make DOCX and QMD peer authorities. Conflicts or unexplained losses will block source updates until a user resolves them.

### Field codes are durable semantic carriers

Docstyle will build on the `ADDIN` field-code pattern used successfully by Zotero. DOCSTYLE fields will carry typed, versioned payloads with stable identifiers and preservation policies. Word users will continue to see ordinary document content between the field separator and field end.

### Sidecars provide transparent local state

Field codes must travel with the DOCX. Sidecars may retain richer state that would be inefficient or inappropriate to repeat in every field. Sidecars will use documented JSON schemas and clear lifecycle classifications: durable state, derived cache or operation report.

### Semantic structure precedes presentation

Lists, tables, headings and other structures must remain semantic Pandoc and OOXML objects for as long as possible. Styling must not require converting their authored content into opaque strings or monolithic raw XML. This principle improves accessibility, harvest fidelity, machine interpretation and filter composition.

### CSS is the presentation source

CSS will describe document defaults, Word styles, page properties, section properties and element styling. The supported subset and its mapping to each backend will be public. Unsupported or approximated properties will produce diagnostics.

### Backends share meaning, not implementation

DOCX, Typst and JATS will consume one semantic model. Each backend will implement the model using format-appropriate mechanisms. The architecture will not force OOXML, Typst and XML publishing structures through one rendering implementation.

### Validation is independent and conservative

The validator must not merely report that the harvester agrees with itself. It will compare source intent, rendered structures, embedded metadata and returned content according to explicit preservation policies. It will fail closed for unexplained loss of authored content.

### AI tools receive data, not hidden instructions

Field-code and sidecar payloads are untrusted data. Docstyle will validate them against allowlisted schemas. It will never execute code or follow free-text instructions embedded in a document payload.

## Conceptual architecture

```text
QMD + YAML + CSS + durable sidecar state
                    |
                    v
             source normalizer
                    |
                    v
          semantic document model
                    |
        +-----------+-----------+
        |                       |
        v                       v
   DOCX backend          Typst/JATS backends
        |
        v
DOCX with DOCSTYLE and Zotero field codes
        |
        v
reviewed DOCX + prior sidecar state
        |
        v
OOXML and field-code interpreter
        |
        +--> typed QMD patch
        +--> updated durable state
        +--> fidelity and conflict report
```

The semantic document model is an internal, serializable representation derived during rendering. It supports diagnostics, testing and backends. It does not replace QMD as the manuscript source.

## Authority and state model

Docstyle will distinguish authored intent, portable document state and local workflow state.

| Information | Normal authority | Portable or recoverable representation |
|---|---|---|
| Authored prose and semantic structure | QMD | Visible DOCX content within identified regions |
| Document metadata | YAML | Document-level field-code snapshot and standard DOCX properties where appropriate |
| Presentation and layout | CSS | Resolved styles and page/section properties in the rendered artifact |
| Region identity and preservation policy | QMD-derived semantic model | DOCSTYLE field-code payload |
| Zotero-managed citations | Zotero field instructions and citation catalogue | Live Zotero fields in DOCX plus citation sidecar |
| Comments and revisions | Reviewed DOCX during return | OOXML annotation parts plus normalized annotation sidecar |
| Render lineage and source hashes | Durable sidecar state | Selected identifiers and hashes in document metadata |
| Validation outcomes | Operation report | JSON report; selected summary in document provenance when required |

Authority for a returned edit is type-specific. The field-code schema will state whether content is authored, generated, structural or externally managed. The interpreter will use that policy when deciding whether to propose a QMD patch, regenerate content or preserve an external object.

## Semantic document model

The shared model will include:

- document identity, version and provenance;
- title, abstract and structured metadata;
- authors, affiliations, ORCID identifiers and ROR identifiers;
- funders, grants and related persistent identifiers;
- ordered semantic content;
- stable region identifiers and parent-child relationships;
- citations, bibliographies and related scholarly objects;
- document, page and section property intent;
- block, table, list and inline style intent;
- generated, authored, structural and externally managed classifications;
- editability and preservation policies;
- source locations and content hashes;
- backend capability requirements;
- accessibility metadata, including captions, labels and alternative text;
- declared expected losses or approximations.

The model will have a versioned JSON Schema. Internal Lua objects may provide behaviour, but serialized model output must remain inspectable with ordinary JSON tools.

## Field-code contract

### Purpose

DOCSTYLE field codes will identify semantic regions and carry the information needed for portable interpretation. They will support cold round trips when the original project sidecars are unavailable.

### Illustrative payload

```json
{
  "schema": 2,
  "id": "table-004",
  "kind": "table",
  "role": "predictor-definition",
  "policy": "authored-preserve",
  "parent": "section-methods",
  "source": "papers/protocol/protocol.qmd",
  "contentHash": "sha256:..."
}
```

The final schema and field names will be defined in a dedicated field-code specification. The programme requirements are:

- every portable field has a schema version and stable identifier;
- payloads use typed keys and bounded values;
- nested regions use explicit parent relationships and balanced field ranges;
- preservation policy is explicit rather than inferred from list order;
- content hashes detect stale, altered or mismatched regions;
- unknown keys and future schema versions are preserved without execution;
- malformed or overlapping ranges produce diagnostics;
- migration functions read supported legacy payloads and emit the current schema;
- public documentation explains each field type and policy;
- the visible result remains usable when Docstyle is absent.

### Initial preservation policies

| Policy | Meaning | Return behaviour |
|---|---|---|
| `authored-preserve` | User-authored content must survive | Compare and propose a QMD patch |
| `generated-replace` | Content is generated from source metadata | Ignore display edits unless the field type explicitly supports reverse editing |
| `structural` | Field describes boundaries or layout intent | Recover structure and properties; preserve contained authored regions |
| `external-managed` | Another system owns the object | Preserve exact field data and reconcile through its adapter |

Zotero fields remain Zotero-managed objects. Docstyle will preserve their instructions and provide a compatible citation catalogue without converting them into private DOCSTYLE citations.

## JSON sidecar store

### Roles

The local store will separate files by lifecycle:

```text
_docstyle/
|-- state/
|   |-- document.json
|   |-- regions.json
|   |-- citations.json
|   `-- annotations.json
|-- cache/
|   |-- reference.docx
|   |-- render-plan.json
|   `-- styles.json
`-- reports/
    |-- fidelity.json
    `-- validation.json
```

The exact split is subject to a sidecar subsystem specification. The lifecycle distinction is required:

- `state/` contains durable information needed for the next operation;
- `cache/` contains derived artifacts that may be deleted and rebuilt;
- `reports/` records the outcome of a render, import or validation operation.

### Durable state requirements

Durable state will include:

- document and render identifiers;
- schema and software versions;
- source and content hashes;
- stable region registry;
- citation metadata and exact field instructions where required;
- comment and revision anchors;
- source-to-DOCX mappings;
- imported external object state;
- provenance needed to reconcile a returned document.

### Reconciliation

Embedded fields and sidecars must not become competing sources. Matching identifiers and hashes will link them. Sidecars may enrich embedded records. Contradictions will produce explicit conflicts. Missing caches will be regenerated. Missing durable state will trigger cold reconstruction.

Sidecars will not contain credentials or unnecessary private content. The schema will identify fields that may contain personal or confidential information so projects can apply appropriate access controls.

## Warm and cold round trips

### Warm round trip

A warm round trip has the reviewed DOCX, current QMD and prior durable sidecar state. Docstyle can compare the prior render, current source, embedded fields and returned content. This is the preferred workflow and provides the strongest conflict detection.

### Cold round trip

A cold round trip has only the DOCX. Docstyle will reconstruct a new project state from DOCSTYLE fields, Zotero fields, comments, revisions, document properties and structural OOXML. Cold import may lack local history, but it must recover every object declared portable by the field-code contract.

### Foreign Word documents

A DOCX that Docstyle did not create is outside the full round-trip guarantee. Docstyle may provide a best-effort import path using semantic Word styles and OOXML structures. It must label inferred structures and must not represent them as field-code-backed provenance.

## CSS and property model

CSS will be the text-based source for presentation and layout. It will cover four levels.

### Document properties

- default fonts and language-related presentation;
- body paragraph spacing and line height;
- default list and table presentation;
- document-wide widow, orphan and pagination-related settings where supported;
- named Word style mappings.

### Page properties

- page size;
- margins and gutter;
- orientation;
- first-page variants;
- columns where supported;
- page background and related printable properties where supported.

### Section properties

- named section layouts;
- page and section breaks;
- page-number start and format;
- line numbering and restart behaviour;
- headers and footers presentation;
- first-page header and footer rules;
- section-specific columns;
- suppression of spacing at section starts;
- inheritance and explicit reset behaviour.

### Element properties

- headings and paragraphs;
- ordered and unordered lists;
- tables, rows, headers and cells;
- figures and captions;
- links, code and inline character styles;
- generated components such as author plates and version history.

### Precedence

The property engine will use an explicit cascade:

1. backend defaults;
2. project CSS document defaults;
3. named page or section CSS rules;
4. element and class CSS rules;
5. explicit QMD div or element attributes.

Every resolved value will retain its source for diagnostics. Backends will report unsupported and approximated properties. They will not silently reinterpret a property with materially different semantics.

### Transparent lists and tables

Lists and tables will remain semantic structures through the Pandoc pipeline. A styling filter must not implement its own incomplete inline renderer. DOCX field codes may wrap a list or table, but they must not hide the underlying `w:numPr`, `w:tbl`, row, cell and paragraph structure.

This requirement supports accessibility, machine interpretation and round-trip fidelity. It also permits LLM tools to reason about lists and tables through extracted structure rather than visual position alone.

## Backend architecture

### Shared contract

Each backend will consume the semantic document model and publish a capability profile. The profile will classify each feature as:

- supported;
- supported with a documented approximation;
- omitted with a warning;
- unsupported and blocking.

### DOCX backend

The DOCX backend will preserve Word-native collaboration features, field codes, comments, revisions, styles, section properties and package relationships. It will use Pandoc for the main document writer and Lua for semantic filters and package finalization.

### Typst backend

The Typst backend will render the shared scholarly content and metadata using Typst-native structures. DOCX-only collaboration metadata may be omitted from visible output but must remain represented in validation and provenance where relevant.

### JATS backend

The JATS backend will prioritize structured scholarly metadata and machine-readable publication content. It may represent some semantic relationships more directly than DOCX. Presentation-only CSS properties will generally not apply to JATS, but structural and semantic intent must remain available.

### Cross-format validation

Cross-format tests will compare semantic content and declared metadata, not binary files or page-by-page visual identity. Backend-specific approximations must appear in machine-readable reports.

## Lua-first runtime

Quarto provides embedded Lua for filters and project scripts. Pandoc provides archive, path and system modules, including ZIP archive support suitable for DOCX packages. vNext will use these capabilities so users do not need R or external ZIP tools.

The Lua runtime will support:

- pre-render source and CSS normalization;
- Pandoc AST filters;
- field-code generation;
- post-render DOCX package inspection and modification;
- validation;
- import and extraction commands;
- structured JSON input and output.

The main technical prerequisite is safe XML processing. vNext will vendor or implement a namespace-aware, token-preserving XML layer suitable for OOXML. Regular-expression rewriting will not be the general XML strategy. An early work package will compare candidate approaches against Word-produced fixtures and serialization-preservation tests.

## DOCX return path

The return path will use semantic patches rather than wholesale source regeneration.

```text
inspect reviewed DOCX
        |
        v
inventory fields, regions, annotations and package state
        |
        v
reconcile with QMD and durable sidecars
        |
        v
produce proposed operations and conflicts
        |
        v
validate and apply approved QMD patch
```

Supported operations will include, as their subsystem specifications mature:

- replace or edit identified authored regions;
- update supported table content and dimensions;
- return comments and tracked revisions to stable source anchors;
- preserve or reconcile Zotero fields;
- update explicitly reversible metadata fields;
- recover supported section and style changes;
- report unsupported structural edits without discarding them silently.

Generated content will normally be regenerated from QMD or YAML. Reverse editing will require an explicit field-type contract.

## Local machine interface

The initial rebuild will provide model-neutral commands with JSON results. Command names are illustrative:

```text
quarto run docstyle.lua inspect manuscript.docx
quarto run docstyle.lua extract manuscript.docx
quarto run docstyle.lua validate manuscript.docx
quarto run docstyle.lua diff manuscript.docx
quarto run docstyle.lua apply manuscript.docx patch.json
quarto run docstyle.lua review-bundle manuscript.docx
```

The interface will:

- separate human-readable diagnostics from machine-readable output;
- use stable operation and region identifiers;
- support dry runs;
- emit reviewable patches;
- return non-zero status for blocking failures;
- avoid provider-specific prompt conventions;
- document security and privacy behaviour.

MCP servers, Codex skills and other agent integrations may wrap this interface later. The local commands remain the authoritative implementation path.

## Validation and error handling

### Validation layers

1. **Schema validation:** field codes, sidecars and semantic-model objects.
2. **Package validation:** ZIP parts, content types, relationships and XML well-formedness.
3. **Structural validation:** sections, styles, fields, annotations, lists and tables.
4. **Semantic validation:** required metadata and backend capability contracts.
5. **Fidelity validation:** authored content, citations, comments, revisions and region identity.
6. **Cross-format validation:** shared content and metadata across DOCX, Typst and JATS.
7. **Visual validation:** rendered pages for properties that require layout inspection.

### Result states

Validation will use explicit top-level states:

- `PASS` -- all required contracts satisfied;
- `PASS_WITH_WARNINGS` -- no required content loss, with documented approximations or non-blocking issues;
- `FAIL` -- unsafe, incomplete or internally inconsistent result.

A table mismatch, unresolved authored-content loss or broken region boundary cannot produce an unqualified pass.

### Safe writes

Docstyle will:

- validate before replacing an existing artifact;
- write new files atomically;
- retain recovery information when an operation fails;
- refuse to patch QMD while conflicts remain;
- preserve unknown OOXML parts and relationships where possible;
- identify expected losses through a public registry rather than ad hoc warning suppression.

## FAIR-informed requirements

Docstyle will improve machine actionability and transparency without claiming formal conformance.

### Findability

- support DOI, ORCID, ROR, funder and grant identifiers;
- retain stable document and region identifiers;
- export metadata suitable for repository indexing;
- include explicit relationships to code, data and related outputs.

### Accessibility

- use open, documented schemas and local extraction commands;
- keep metadata accessible independently of proprietary Word automation;
- support access-control descriptions when underlying content is restricted;
- preserve useful visible content when Docstyle is absent.

### Interoperability

- use shared identifiers and controlled vocabularies where suitable;
- publish the DOCSTYLE field-code and sidecar schemas;
- preserve standard Word, Zotero, Typst and JATS structures;
- provide mappings rather than replacing established scholarly standards.

### Reusability

- record licence, provenance, source commit and software versions;
- preserve qualified relationships among manuscripts, protocols, data and code;
- document backend approximations and expected losses;
- use community standards for scholarly metadata where available.

CSS supports this objective indirectly by keeping styling and document structure inspectable and version-controlled. Semantic lists and tables remain transparent to humans and machines rather than being represented only through visual formatting.

## Migration contract

vNext will preserve content and supported semantics rather than the legacy implementation.

The migration layer will:

- read supported legacy DOCSTYLE field payloads;
- read existing citation, comment, revision and style sidecars;
- accept common existing QMD and project configuration;
- emit current field-code and sidecar schemas;
- report unsupported legacy settings;
- compare legacy and vNext outputs using shared fixtures;
- provide an explicit project migration command and report.

The migration layer will not promise:

- compatibility with every exported R function;
- identical internal paths or sidecar layout;
- byte-identical DOCX output;
- preservation of undocumented legacy behaviour;
- indefinite support for legacy schema versions.

## Coexistence and retirement

The same repository will contain an isolated vNext engine during migration. Users and tests will select the engine explicitly. Both engines will run against shared fixtures so differences are visible.

The dual-engine period will end. Legacy retirement requires the acceptance gates in this specification. After retirement, the R engine may remain in tagged releases and repository history, but it will not remain an alternative production path on the main branch.

## Work packages

### Work package 0: characterize the legacy engine

- freeze representative outputs;
- create sanitized DemPoRT and POPCORN fixtures;
- record known successes, failures and expected losses;
- establish semantic and visual comparison tools;
- identify the supported legacy field-code and sidecar versions.

### Work package 1: schemas and state model

- specify the semantic document model;
- specify field-code types and preservation policies;
- specify durable sidecar state, cache and reports;
- define identifiers, hashes, provenance and migration rules;
- publish initial JSON Schemas and examples.

### Work package 2: Lua OOXML foundation

- select or implement the XML layer;
- implement ZIP package reading and atomic writing;
- implement namespaces, relationships and content-type helpers;
- verify behaviour against Word and LibreOffice fixtures;
- establish Lua unit and integration test runners.

### Work package 3: source and CSS compiler

- normalize QMD and YAML into the semantic model;
- implement the supported CSS parser and cascade;
- represent document, page, section and element properties;
- add backend capability diagnostics;
- preserve semantic lists and tables through the filter pipeline.

### Work package 4: DOCX render vertical slice

- render metadata, prose, lists, one table and one figure;
- render portrait and landscape sections;
- emit and validate DOCSTYLE field codes;
- generate headers, footers and page fields;
- produce a self-describing DOCX without R.

### Work package 5: DOCX return path

- implement warm and cold inspection;
- reconstruct sidecars from DOCX;
- reconcile fields, annotations and authored content;
- produce typed QMD patches and conflict reports;
- validate render-to-return-to-render fidelity.

### Work package 6: Typst and JATS backends

- adapt each backend to the shared model;
- define capability profiles;
- preserve common scholarly metadata;
- add cross-format semantic tests;
- document backend-specific styling and approximation rules.

### Work package 7: machine interface and review bundles

- implement inspect, extract, diff, apply and validate commands;
- define stable JSON outputs and exit states;
- generate optional DOCX, PDF, QMD, JSON and page-image review bundles;
- document how agent integrations can call the local interface safely.

### Work package 8: migration and legacy retirement

- implement project and field-schema migration;
- run dual-engine comparisons on real projects;
- complete user and contributor documentation;
- satisfy stability gates;
- remove the legacy engine from the main development path.

Each work package will receive a bounded design specification and implementation plan. Work may overlap only where interfaces have already been approved.

## Test strategy

### Unit and contract tests

- Lua parsers, serializers and utility modules;
- field-code schema and migration rules;
- CSS parsing, cascade and unit conversion;
- sidecar reconciliation;
- backend capability decisions;
- semantic patch generation.

### Integration tests

- QMD to each backend;
- QMD to DOCX to QMD;
- warm and cold DOCX return paths;
- DOCX package mutation and relationship integrity;
- comments, revisions and Zotero fields;
- adjacent and nested semantic regions;
- repeated and mixed section properties;
- list and table semantic preservation.

### Interoperability tests

- Microsoft Word open, edit, save and field update;
- LibreOffice open, edit and save;
- Google Docs import and export if retained in the capability contract;
- generic DOCX text extraction;
- field and sidecar survival across supported workflows.

### Real-project fixtures

1. DemPoRT protocol;
2. POPCORN protocol or manuscript;
3. one independent scientific document not used to design the engine.

The fixtures will be sanitized where necessary and will remain small enough for routine continuous integration.

### Continuous integration

The vNext core test suite will require only Quarto. Network-dependent tests will run separately with pinned dependencies. Tests will write only to temporary directories. Release checks will build distributable extension artifacts and execute the full vertical slice.

## Stability gates

vNext will not replace the legacy engine until:

- Quarto is the only required user runtime;
- supported legacy field codes and sidecars can be migrated;
- authored content is never lost silently;
- sidecars can be reconstructed from a self-describing DOCX to the declared cold-import level;
- warm round trips detect conflicts among source, sidecars and returned DOCX;
- DemPoRT, POPCORN and an independent fixture pass;
- DOCX, Typst and JATS preserve the shared semantic model within their capability contracts;
- supported CSS document, page, section and element properties are documented;
- semantic lists and tables remain inspectable and round-trippable;
- validation failures block unsafe source updates;
- public schemas, migration documentation and security guidance are complete;
- continuous integration is reproducibly green.

## Measures of success

The rebuild succeeds when:

- a new user can install the extension and render with Quarto alone;
- a contributor can understand each subsystem through its public interface and tests;
- a collaborator can edit a supported DOCX without destroying portable semantics;
- a returned DOCX produces a reviewable patch rather than an unexplained source rewrite;
- a machine can inspect document structure, metadata, provenance and validation state through local JSON commands;
- the same QMD produces semantically consistent DOCX, Typst and JATS outputs;
- unsupported behaviour is explicit;
- legacy code can be removed without losing the tested product contract.

## Risks and required research

### Lua XML processing

Quarto supplies the runtime and ZIP capabilities, but not a complete OOXML DOM. The XML work package must show namespace correctness, token preservation, deterministic serialization and acceptable performance before the DOCX backend expands.

### Field-code survival

Field codes work well in Word and follow a pattern used successfully by Zotero. Their survival across LibreOffice, Google Docs and generic document-processing services must be measured. The capability contract will reflect evidence rather than assumptions.

### Sidecar divergence

Redundant embedded and local state can diverge. Stable identifiers, hashes, explicit authority and conflict reports are required. Silent precedence rules are prohibited.

### Cross-format scope

A shared model can become too broad if it attempts to encode every backend detail. The model will contain shared scholarly meaning and declared presentation intent. Backend-only implementation detail remains inside the backend.

### CSS scope

CSS is useful because it is transparent and familiar, but browser-level compatibility is neither feasible nor necessary. The supported subset must remain small, documented and tested.

### Maintainer capacity

The project currently depends heavily on one maintainer. The rebuild must reduce public API size, split modules by responsibility, document interfaces and make test failures interpretable by new contributors and coding agents.

## Deferred subsystem decisions

The programme direction is approved. The following implementation decisions belong in work-package specifications:

- the Lua XML parser or token-preserving editor;
- the exact sidecar file split;
- the final field-code vNext key names;
- identifier generation and collision handling;
- the serialized semantic-model API;
- the exact CSS grammar and backend property matrix;
- the command-line syntax;
- the migration support window for each legacy schema;
- the precise set of reversible DOCX edits;
- whether Google Docs remains a supported interoperability target.

Deferral does not make these optional. Each decision must be resolved before its dependent work package begins.

## Relationship to current issues and documents

This specification supersedes the assumption that the DOCX round-trip path must remain R-backed. It provides the programme context for existing issues concerning Lua tests, generated-section registries, harvest decomposition, citation backends, hermetic continuous integration, section assembly, nested ranges and validator correctness.

Existing architecture documents remain valuable descriptions of the legacy engine and OOXML behaviour:

- `dev/ARCHITECTURE-sections.md`;
- `dev/ARCHITECTURE-footers.md`;
- `dev/ARCHITECTURE-footer-dirty-flag.md`;
- `dev/ARCHITECTURE-tables.md`;
- `dev/ARCHITECTURE-anchors.md`;
- `inst/architecture/section-model.md`.

They will become inputs to vNext subsystem specifications rather than normative descriptions of the new implementation.

### Existing issue disposition

| Issue | vNext treatment |
|---|---|
| [#7](https://github.com/DougManuel/docstyle/issues/7), generated-section registry | Inform the field-code registry and semantic-region model |
| [#9](https://github.com/DougManuel/docstyle/issues/9), harvest decomposition | Superseded by the vNext DOCX interpreter boundary; retain lessons and tests |
| [#10](https://github.com/DougManuel/docstyle/issues/10), Lua tests | Absorb into work packages 2--7 and the Quarto-only continuous integration gate |
| [#13](https://github.com/DougManuel/docstyle/issues/13), two-tier contract | Revise: vNext targets a Quarto-only core rather than an R-backed DOCX tier |
| [#15](https://github.com/DougManuel/docstyle/issues/15), pure-Lua CSS | Promote into work package 3 |
| [#17](https://github.com/DougManuel/docstyle/issues/17), Lua inline crash | Fix as a legacy blocker and cover in the new semantic list/table pipeline |
| [#18](https://github.com/DougManuel/docstyle/issues/18), section geometry | Use as a required vNext section-model regression fixture |
| [#19](https://github.com/DougManuel/docstyle/issues/19), nested range precedence | Resolve through typed region containment rather than ordered flat ranges |
| [#20](https://github.com/DougManuel/docstyle/issues/20), false validation pass | Use as a required independent-validation regression fixture |
| [#21](https://github.com/DougManuel/docstyle/issues/21), relationship validation | Absorb into the Lua OOXML package layer |
| [#22](https://github.com/DougManuel/docstyle/issues/22), citation backend | Resolve through backend and external-object capability contracts |
| [#23](https://github.com/DougManuel/docstyle/issues/23), hermetic CI | Implement as a programme prerequisite and stability gate |
| [#24](https://github.com/DougManuel/docstyle/issues/24), package build | Fix for the legacy migration period; vNext distribution must not depend on an R package build |

## Immediate next actions

1. Review and approve this programme specification.
2. Create a vNext programme issue and milestone structure.
3. Write the work package 0 characterization plan.
4. Write the work package 1 field-code, semantic-model and sidecar specification.
5. Run the work package 2 Lua XML feasibility spike before expanding implementation.
6. Freeze new legacy features unless they address data loss, security or an active project blocker.

## References

- Wilkinson MD, Dumontier M, Aalbersberg IJ, et al. The FAIR Guiding Principles for scientific data management and stewardship. *Scientific Data*. 2016;3:160018. https://doi.org/10.1038/sdata.2016.18
- [Quarto project scripts](https://quarto.org/docs/projects/scripts.html)
- [Quarto Lua filters](https://quarto.org/docs/extensions/filters.html)
- [Pandoc Lua filters and `pandoc.zip`](https://pandoc.org/lua-filters.html#module-pandoc.zip)
- ECMA-376, Office Open XML File Formats, Part 1: Fundamentals and Markup Language Reference.
