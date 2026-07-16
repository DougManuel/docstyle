# Docstyle vNext WP1: Schemas and State Model Design

**Status:** Approved July 14, 2026, with the legacy-coverage acceptance test added at review
**Date:** July 14, 2026
**Work package:** WP1 of the vNext rebuild programme
**Programme specification:** `docs/superpowers/specs/2026-07-12-docstyle-vnext-rebuild-design.md`
**Tracking:** issue #28 (WP1); programme issue #27
**Scope rule:** This document defines contracts, schemas and examples. It does not define OOXML parsing, ZIP packaging, CSS compilation, rendering behaviour or command-line syntax.

## Executive summary

WP1 defines the data contracts that every later work package consumes: the semantic document model, stable identifiers and content hashes, the field-code envelope, the durable state store, the core metadata vocabulary and the metadata-profile mechanism. Each contract has a versioned JSON Schema, valid and invalid examples, and explicit authority and reconciliation rules.

Two decisions from the takeover discussion bound the metadata scope. The core vocabulary includes universal document metadata only, adding document type and licence to the fields the programme specification already names. Domain metadata such as PICOS or PCC ships later as registered profiles; WP1 tests the profile mechanism with a synthetic fixture profile used only in conformance tests.

## Goals

WP1 will:

1. Specify the serialized semantic document model as an ordered content tree plus identifier-linked registries.
2. Specify stable identifiers, generated-identifier rules and collision handling.
3. Specify the canonical content-hash input and algorithm.
4. Specify authority and reconciliation rules for every information type.
5. Specify QMD binding rules for identifiers, classes, attributes and inline variables.
6. Specify the minimum core metadata vocabulary, including document type and licence.
7. Specify the profile mechanism: namespace, versioning, registration, validation and migration.
8. Specify the DOCSTYLE field-code envelope, its size bound and its preservation policies.
9. Specify the durable state store: manifest, typed files, lifecycle rules and atomic updates.
10. Specify privacy classification for embedded and local data.
11. Specify which legacy field-code and sidecar versions vNext promises to migrate.
12. Publish JSON Schemas with valid and invalid examples for each contract.

## Non-goals

WP1 will not:

- implement the OOXML parser, ZIP package layer, CSS compiler or any rendering backend;
- define the Lua XML library (WP2), the CSS grammar (WP3), the embedded DOCX metadata carrier (WP4) or the command-line syntax (WP7);
- ship a real domain metadata profile; PICOS and PCC are deferred to their own profile specifications;
- define controlled vocabularies beyond the enumerations named in the core vocabulary;
- define report payloads beyond a shared report envelope; detailed fidelity and validation reports belong to WP5 and WP7;
- promise byte-level compatibility with legacy sidecar files.

## Decision record

Decisions carried into this specification from the WP1 discussion and the July 14, 2026 takeover review:

1. **Source-first hybrid identifiers.** An explicit QMD identifier is the stable region identifier. Docstyle generates an identifier only when the source supplies none. Hashes detect change; they never define identity.
2. **Ordered content tree plus registries.** The serialized model uses a tree for order and nesting, with separate registries for metadata records, profiles, relationships and assets.
3. **Manifest plus typed durable stores.** Local state uses `_docstyle/state/manifest.json` as the single entry point, hashing typed files. Provisionally accepted; approval of this specification makes it final.
4. **Self-describing field envelope plus catalogue reference.** DOCSTYLE fields carry a small bounded envelope; richer records live in the embedded catalogue and durable state.
5. **Core metadata includes document type and licence**, mapped to existing standards rather than a new vocabulary.
6. **The profile mechanism is conformance-tested with a synthetic fixture profile.** No real domain profile ships in WP1.
7. **PICOS is deferred.** The mechanism must also accommodate PCC for scoping reviews; this constraint shaped the profile design below.

The remaining sections resolve the ten bounded decisions listed in issue #28. Each resolution is marked **Decision** so review can accept or revise it in place.

## Semantic document model

### Structure

The serialized model is one JSON document with two parts:

- `content`: an ordered tree of typed nodes carrying document order, nesting and authored structure;
- `registries`: `metadata`, `relationships` and `assets` are each a JSON object keyed by the contained record's, relationship's or asset's own `id` (`profiles` is keyed by profile identifier, unchanged); JSON object-key semantics make id uniqueness within a registry structural rather than a rule enforced separately.

Content nodes reference registry records by identifier. Registry records reference content nodes by identifier. Neither side embeds the other.

### Content nodes

Every content node has:

| Field | Requirement | Meaning |
|---|---|---|
| `id` | required | Stable identifier (explicit or generated) |
| `type` | required | Node type from the model schema (`section`, `heading`, `paragraph`, `list`, `list-item`, `table`, `table-row`, `table-cell`, `figure`, `caption`, `equation`, `code-block`, `footnote`, `citation`, `span`, `raw`, `anchor`) — `anchor` is the positioned/floating-content kind the legacy `float` and `anchor` field-code payloads map to (ratified at the WP1 pre-merge review) |
| `role` | optional | Registered semantic role (for example `abstract`, `methods`) |
| `classification` | required | One of `authored`, `generated`, `structural`, `external-managed` |
| `policy` | required | Preservation policy (see field-code contract) |
| `hash` | required | Content hash of the node subtree |
| `children` | optional | Ordered child nodes |
| `attrs` | optional | Typed attributes (alignment intent, list numbering type, table dimensions) |
| `source` | optional | Source location: file, start line, end line |

Lists and tables remain structured nodes with items, rows and cells as children. No node type stores rendered markup as its primary representation. A `raw` node exists only for explicitly authored raw blocks and records its target format.

### Registries

- `metadata`: a JSON object keyed by record id. Each value is a typed record (see core vocabulary) with `id`, `recordType`, `schemaVersion`, optional `profile`, optional `privacy` and its typed body.
- `profiles`: the profile manifests active in this document, keyed by profile identifier.
- `relationships`: a JSON object keyed by relationship id. Each value is a qualified link `{id, subject, predicate, object}` where subject and object are record or node identifiers and predicates come from the core relationship set or a registered profile.
- `assets`: a JSON object keyed by asset id. Each value describes a file the document references (images, CSL, bibliography), with path, media type and hash.

Each registry's key and its value's own `id` field must agree. The body keeps its own `id` for round-trip fidelity and explicitness even though the key already identifies the entry.

**Decision (model API):** the serialized model is the public contract; internal Lua object behaviour is unspecified. The model schema is `document-model.v1`.

## Identifiers

### Explicit identifiers

A QMD identifier (`#abstract`, `#tbl-outcomes`) is authoritative and immutable for the life of the region. Renaming an identifier is a delete plus create unless durable state records the rename.

### Generated identifiers

**Decision (format):** generated identifiers use the form `g-<type>-<suffix>`, where `<type>` is the content-node type and `<suffix>` is six characters from the lowercase base32 alphabet (`a-z`, `2-7`), assigned when the region first enters the model. Example: `g-table-k3m7ap`.

**Decision (stability):** a generated identifier is assigned once and persisted in durable state (`regions.json`). Later renders reuse the persisted identifier by matching explicit identifiers first, then source location, then content hash. A generated identifier never changes because content changed; it is retired when reconciliation establishes that the region was deleted.

**Decision (collision rule):** the generator draws a new suffix until the identifier is unused within the document and its durable state. Two explicit identifiers that collide, or an explicit identifier using the reserved `g-` prefix, are validation failures (`FAIL`). The prefixes `g-` and `docstyle-` are reserved.

## Content hashes

**Decision (algorithm and format):** SHA-256, rendered as `sha256:` followed by 64 lowercase hexadecimal characters.

**Decision (canonical input):** the hash input is the canonical JSON serialization of the node's semantic content, defined as:

- the node subtree with `hash`, `source` and volatile provenance fields removed;
- object keys sorted lexicographically; no insignificant whitespace; UTF-8 encoding (the RFC 8785 canonicalization rules);
- text values normalized to Unicode NFC with LF line endings.

Because the input is the semantic model rather than QMD text or OOXML markup, the same authored content hashes identically whether derived from source or recovered from a returned DOCX. Hash equality means unchanged content; hash inequality routes the region into reconciliation.

## Authority and reconciliation

Four representations can describe the same object: QMD source, the field envelope, the embedded metadata catalogue and local durable state. They are linked by identifier and compared by hash. None may silently overwrite another.

**Decision (precedence by information type):**

| Information type | Authority | On disagreement |
|---|---|---|
| Authored content | QMD | A returned DOCX difference becomes a proposed patch; it is never applied silently |
| Generated content | Source metadata (YAML, records) | Display edits are ignored unless the field type declares reverse editing |
| Structural intent | QMD-derived model | Recovered structure is reconciled; unsupported edits are reported, not discarded silently |
| External-managed objects | The owning system (for example Zotero field instructions) | Preserve exact field data; reconcile through the owner's adapter |
| Comments and revisions | Returned DOCX during return | Normalized into annotation state with stable anchors |
| Metadata records | YAML and typed records | Embedded catalogue and state are synchronized views; contradiction is a conflict |

**Decision (reconciliation rules):**

1. Matching identifier and matching hash: the representations agree; sidecars may enrich embedded records.
2. Matching identifier, differing hash: a change. Route by authority row above; authored content produces a proposed patch.
3. Identifier present in one representation and absent in another: additions and deletions follow the same authority routing; an unexplained loss of authored content is a blocking conflict.
4. The same identifier bound to different kinds or roles across representations: a blocking conflict.
5. Missing caches are rebuilt. Missing durable state triggers cold reconstruction from the DOCX. Neither is a conflict.
6. Blocking conflicts fail closed: no QMD patch is applied and no durable state is overwritten until a person resolves them.

## QMD binding rules

WP1 registers the binding conventions; it introduces no new markup.

- **Identifiers** bind content to records and round-trip regions: `::: {#abstract}`.
- **Registered classes** declare semantic roles. A class has semantic meaning only when the core vocabulary or a registered profile declares it; unregistered classes remain presentation hooks.
- **Attributes** carry typed references. `data-docstyle-record="<record-id>"` links a region to a metadata record. `data-docstyle-rel-<predicate>="<id>"` asserts a relationship. Unknown `data-docstyle-*` attributes are diagnostics, not errors.
- **Inline variables** (`{{< meta version >}}`) render metadata as prose; the rendered string is a view and never authoritative.
- **YAML** holds concise metadata. The `docstyle.profiles` key lists active profiles. Larger record sets may live in a linked metadata file named in YAML; the schema treats inline and linked records identically.

Reserved namespaces: the `docstyle-` class prefix, the `data-docstyle-` attribute prefix and the `g-` identifier prefix.

## Core metadata vocabulary

**Decision (minimum core vocabulary):** the core record types and their required fields are:

### Document record

| Field | Requirement | Notes |
|---|---|---|
| `id` | required | Stable document identifier |
| `type` | required | Document type (see below) |
| `title` | required | With optional `shortTitle` |
| `licence` | recommended | SPDX identifier where one exists, plus optional URL and statement |
| `abstract` | optional | Region reference or inline text |
| `keywords` | optional | Ordered list |
| `version` | optional | With optional `versionHistory` entries (version, date, description) |
| `status` | optional | One of `draft`, `submitted`, `preprint`, `accepted`, `published` |
| `dates` | optional | Typed dates: created, modified, published |
| `language` | optional | BCP 47 tag |
| `identifiers` | optional | Typed external identifiers (DOI and similar) |

**Decision (document type):** the `type` enumeration adopts JATS `@article-type` values as its base set, beginning with `research-article`, `review-article`, `protocol`, `brief-report`, `case-report`, `editorial`, `letter` and `other`. The schema records the JATS mapping directly and a documented mapping to CSL item types. New values enter through a schema minor version rather than through a profile.

**Decision (licence):** `licence` is a structured object `{spdx, url, statement}` with at least one member present. `spdx` takes an SPDX licence identifier such as `CC-BY-4.0`. The WP0 fixture catalogue's source and fixture licences migrate to this shape.

### People and organizations

- `person`: name parts, optional ORCID, ordered `roles` from the CRediT vocabulary, optional corresponding flag, affiliation references;
- `organization`: name, optional ROR identifier;
- `funding`: funder (organization reference), optional grant identifier.

### Regions and relationships

- Core region roles: `abstract`, `introduction`, `methods`, `results`, `discussion`, `acknowledgements`, `references`, `appendix`, `supplement`. Profiles may register additional roles.
- Core relationship predicates: `describes`, `supports`, `derivedFrom`, `references`, `supplementTo`. Profiles may register additional predicates.

Version history remains core metadata: it is the most heavily used structured metadata in the real projects and it is universal.

## Metadata-profile mechanism

### Profile manifest

A profile is registered by a manifest conforming to `profile-manifest.v1`:

| Field | Requirement | Meaning |
|---|---|---|
| `id` | required | `<namespace>:<name>`, for example `docstyle:fixture` |
| `version` | required | Semantic version; compatibility breaks only on major |
| `schema` | required | The profile's record schema (bundled file reference) |
| `recordTypes` | required | Record types the profile defines |
| `classes` | optional | QMD classes the profile registers as semantic |
| `regionRoles` | optional | Region roles the profile registers |
| `predicates` | optional | Relationship predicates the profile registers |
| `mappings` | optional | Declared backend mappings (informative in WP1) |
| `migratesFrom` | optional | Profile identifier and version ranges this version reads |

**Decision (namespace and registration):** the namespace `docstyle` is reserved for profiles bundled with the extension. Other namespaces are free-form lowercase tokens chosen by the profile author; uniqueness is the author's responsibility until a public registry exists, which WP1 does not create. A document activates profiles through `docstyle.profiles` in YAML; activation of an unavailable profile is a validation failure, while profile-typed data for an inactive profile is preserved as opaque data with a warning.

**Decision (versioning and migration):** a reader accepts records whose major version it supports. Records with a newer major version are preserved unmodified and reported. `migratesFrom` names the versions a profile can upgrade and implies a documented mapping in the profile's specification.

### Fixture profile

WP1 ships `docstyle:fixture`, a synthetic test-only profile exercising every mechanism feature: a required scalar field, an optional repeatable field, a controlled term, a region link and a registered predicate. It appears in conformance tests and examples only and is not documented as a user profile.

### Deferred domain profiles

PICOS (population, intervention or exposure, comparator, outcomes, study design) and PCC (population, concept, context) are the intended first real profiles. Each requires its own bounded specification. The repeatable-field, region-link and controlled-term features above are the mechanism requirements those two profiles impose; a mechanism change discovered during their specification requires a WP1 schema revision.

## Field-code contract

### Envelope

A DOCSTYLE field instruction is `ADDIN DOCSTYLE ` followed by one compact JSON object, the envelope, conforming to `field-envelope.v4`:

| Key | Requirement | Meaning |
|---|---|---|
| `v` | required | Field-schema version; integer; `4` for vNext |
| `id` | required | Stable identifier of the region |
| `kind` | required | Object kind (from the content-node type set) |
| `policy` | required | Preservation policy |
| `hash` | required | Content hash of the region at render time |
| `role` | optional | Registered semantic role |
| `parent` | optional | Identifier of the enclosing region |
| `profile` | optional | Profile identifier when the region is profile-typed |

**Decision (envelope keys):** the eight keys above are the complete v4 envelope. Source file paths do not appear in the envelope; they are local information and live in durable state. Rich records live in the embedded metadata catalogue (carrier defined in WP4) and durable state, linked by `id` and `hash`.

**Decision (size bound):** a serialized envelope must not exceed 1,024 bytes. The writer fails rather than truncating. The bound forces rich data into the catalogue, keeps fields inspectable and protects Word interoperability.

**Decision (unknown keys and future versions):** unknown envelope keys are preserved semantically on read and re-emit and are never interpreted. Because the envelope is decoded and re-encoded as JSON, key order and insignificant whitespace are not guaranteed to survive, but every unknown key and its value are carried through unchanged. A field with `v` greater than 4 is preserved unmodified and reported. Envelope content is untrusted data; no key's value is ever executed or followed as an instruction.

**Decision (version line):** vNext continues the single DOCSTYLE version line. The legacy engine wrote version 3 and read versions 1 through 3; vNext writes version 4 and reads 1 through 4.

### Preservation policies

The four policies from the programme specification are adopted unchanged: `authored-preserve`, `generated-replace`, `structural` and `external-managed`, with the return behaviour defined in the authority table above. Policy is always explicit in the envelope; nothing is inferred from field order. Nested regions declare `parent` and ranges must be balanced; malformed or overlapping ranges are diagnostics that block an unqualified pass.

Zotero fields remain external-managed. Docstyle preserves their instructions exactly and never rewrites them into DOCSTYLE citations.

## Durable state, caches and reports

### Layout

```text
_docstyle/
|-- state/
|   |-- manifest.json      one coherent state generation
|   |-- document.json      document record and model snapshot references
|   |-- regions.json       region registry: id, kind, role, policy, hash, source
|   |-- metadata.json      metadata records, active profiles, relationships
|   |-- citations.json     citation catalogue and exact field instructions
|   `-- annotations.json   comment and revision state with stable anchors
|-- cache/                 derived artifacts; deletable and rebuildable
`-- reports/               operation outcomes; append-only per operation
```

`state/` is durable and authoritative for local workflow context. `cache/` may be deleted at any time. `reports/` records outcomes and is never read back as authority.

### Manifest and atomic updates

**Decision (state generation):** the manifest carries `stateId`, a 128-bit random hexadecimal identifier assigned when the state directory is created, and `generation`, an integer incremented on every committed update. Each manifest entry lists a typed file with its schema version and SHA-256 hash.

**Decision (atomic update procedure):** each typed file is published under a generation-qualified physical name (`<logical-name>.<generation>.json`, for example `regions.2.json`) that no existing manifest yet references; the manifest entry carries this physical name alongside the stable logical name (`regions.json`), plus schema and hash. A writer produces the new generation's typed files under temporary names, renames each into place, writes a complete new manifest to a temporary name, then renames the manifest over `manifest.json` as the single commit point. Because every physical name belongs to the generation being committed, none of the renames before the manifest rename can disturb a file the current manifest still references -- readers only ever see either the complete previous generation or the complete next one, never a mix. Readers start from the manifest; a typed file whose hash does not match its manifest entry is stale and triggers regeneration for caches or a conflict for durable state. A failed update leaves the previous manifest and its generation's files intact and fully readable. After a successful commit, physical files from generations older than the one just superseded are removed on a best-effort basis; a failed cleanup is a non-fatal warning, never a failed commit.

### Report envelope

All reports share `report-envelope.v1`: operation, tool version, state generation, input hashes, result state (`PASS`, `PASS_WITH_WARNINGS`, `FAIL`) and a findings list. Detailed findings payloads for fidelity and validation are defined in WP5 and WP7.

## Privacy and security

**Decision (classification):** every metadata record and every sidecar schema supports an optional `privacy` field with values `public` and `restricted`; absence means `public` for metadata records and `restricted` for annotation content. Two hard rules follow:

1. Only `public` records may enter the embedded metadata catalogue or any field envelope. Everything else stays in local state.
2. Local file paths, author account details from tracked changes and comment text never appear in embedded representations beyond what OOXML itself already carries.

Sidecars must never contain credentials. Schemas mark the specific fields that may contain personal information (annotation authors, comment bodies, source paths) so projects can apply access controls. All payloads from fields, catalogues or sidecars are validated against allowlisted schemas before use; free text inside payloads is never treated as an instruction.

## Versioning and legacy migration

**Decision (migration promises):** vNext reads and migrates:

- **Field codes:** versions 1 through 3, covering the eight legacy payload types recorded in `tests/vnext/fixtures/legacy-contract.json` (`char`, `div`, `list`, `section`, `table`, `figure`, `float`, `anchor`), emitting version 4 envelopes plus catalogue records.
- **Durable sidecars:** `field-codes.json` (citations, references hash, Zotero preferences), `comments.json` and `revisions.json`, migrating into `citations.json` and `annotations.json`.
- **Generated sidecars:** `references.json`, `page-config.json`, `style-map.json`, `section-map.json`, `harvest-map.json`, `figures.json` and `styles.json` are regenerated by vNext operations, not migrated.

Legacy sidecars are unversioned; the migration layer identifies each file by name and shape checks documented per file, and reports any file it cannot identify rather than guessing. Migration is one-way and produces a report; the legacy files are left in place untouched.

**Decision (schema dialect and identifiers):** all WP1 schemas use JSON Schema draft 2020-12. Canonical identifiers use the form `https://dougmanuel.github.io/docstyle/schemas/<name>.v<major>.json`. Identifiers are names, not fetch locations: schemas ship with the extension, a bundled registry maps identifiers to files, and no operation requires network access to resolve a schema. This preserves the local path.

## JSON Schema inventory

WP1 publishes, under `schemas/` in the repository:

| Schema | Contract |
|---|---|
| `document-model.v1.json` | Serialized semantic model: content tree and registries |
| `metadata-core.v1.json` | Core record types: document, person, organization, funding (regions and relationships are not metadata-core record types — they are document-model registries and the `state-regions`/`state-metadata` stores) |
| `profile-manifest.v1.json` | Profile registration |
| `field-envelope.v4.json` | DOCSTYLE field envelope |
| `state-manifest.v1.json` | State manifest and generation |
| `state-regions.v1.json` | Region registry |
| `state-metadata.v1.json` | Metadata and relationship state |
| `state-citations.v1.json` | Citation catalogue |
| `state-annotations.v1.json` | Comment and revision state |
| `report-envelope.v1.json` | Shared report header |
| `profiles/fixture.v1.json` | Fixture profile records |

Each schema ships with at least one valid example and at least one invalid example whose violation is the contract's most likely real-world mistake. Distribution packaging of the schemas is a WP4 and WP7 concern.

## Acceptance tests

The WP1 implementation plan will build a conformance runner on the approved Quarto and Lua contributor path. WP1 is complete when:

1. Every schema validates its valid examples and rejects its invalid examples.
2. A synthetic document model exercises every content-node type, both identifier forms, and all four preservation policies, and round-trips through serialization without loss.
3. Identifier generation respects the collision rule and persists across a simulated re-render using durable state.
4. Content hashing is reproducible across platforms for fixtures containing non-ASCII text, combining characters and mixed line endings.
5. The fixture profile registers, validates, links a region, asserts a relationship and survives serialization; a record with an unavailable profile is preserved and reported.
6. The manifest update procedure is atomic under simulated interruption: after a failed update the previous generation reads cleanly.
7. Legacy mapping fixtures derived from the WP0 baselines translate version 1 through 3 field payloads and the three durable sidecars into the new schemas, with a migration report and untouched inputs.
8. Reconciliation rules produce the specified outcome for each disagreement class, including the fail-closed cases.
9. **Legacy element coverage.** A completion audit reviews the current implementation code and shows that every legacy data element has been considered. Elements in scope for WP1 are the data contracts: field-code payload types and their keys, sidecar files and their fields, QMD div, class and attribute conventions, and metadata YAML keys. The audit report classifies each element as mapped in a WP1 schema, assigned to a named later work package, or dropped with a recorded rationale. An element in none of the three classes blocks WP1 completion. Presentation properties belong to the WP3 property matrix and OOXML behaviours to WP2 and WP4; the audit lists them as assigned rather than re-analysing them.

WP0 characterization baselines are read-only evidence for these tests and must not be modified.

## Deferred work

- PICOS and PCC profile specifications, including vocabularies and cardinality.
- The embedded DOCX metadata-catalogue carrier (WP4) and PDF metadata envelope details (WP6).
- Detailed fidelity and validation report payloads (WP5, WP7).
- A public profile registry and third-party namespace governance.
- Schema distribution and packaging (WP4, WP7).
- Reverse-editable field types beyond the policy hook defined here (WP5).

## References

- Programme specification: `docs/superpowers/specs/2026-07-12-docstyle-vnext-rebuild-design.md`
- Legacy contract: `tests/vnext/fixtures/legacy-contract.json`
- WP0 characterization guide: `dev/vnext/characterization/README.md`
- JSON Schema draft 2020-12: <https://json-schema.org/specification>
- RFC 8785, JSON Canonicalization Scheme: <https://www.rfc-editor.org/rfc/rfc8785>
- SPDX licence list: <https://spdx.org/licenses/>
- JATS article types: <https://jats.nlm.nih.gov/archiving/tag-library/1.2/attribute/article-type.html>
- CRediT contributor roles: <https://credit.niso.org/>
- ECMA-376, Office Open XML File Formats, Part 1
