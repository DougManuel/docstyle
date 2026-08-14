# Docstyle vNext metadata-binding design

Date: August 14, 2026

Work package position: pre-WP3 gate. This specification completes the middle
layer between the WP1 contracts and the WP3/WP4 implementations: the
normalized bindings between QMD metadata, semantic objects, generated views
and catalogue records.

Status: draft for review.

## Context

WP1 established identifiers, the v4 field envelope, the generic document
model and the record registries. An external architecture review (source of
record: `dev/vnext/metadata-binding-notes.md`) supported the flow —

```
QMD/YAML authority
    -> normalized semantic document model
        -> DOCSTYLE field envelope: identity, kind, policy, hash
        -> embedded catalogue: rich public metadata
        -> local state: source locations, private data, reconciliation history
```

— and identified six gaps that WP3 (the compiler) and WP4 (DOCX rendering) cannot
implement around: an inconsistent abstract representation, missing bindings
for generated metadata views, no document-specific authorship model, untyped
table and figure attributes, an unsettled table preservation policy, and an
unspecified catalogue carrier. Each claim was verified against the merged
schemas before this specification was drafted.

This document resolves those six items. It gives WP3 a precise compiler
target and WP4 a precise field-code and catalogue rendering contract.

## Goals

1. One canonical normalized form for the document abstract.
2. A metadata-view record binding every generated span or block to the
   record path that generates it.
3. An ordered, document-specific contribution model separating identity
   from per-document authorship facts.
4. Typed semantic attributes for table and figure nodes, separated from
   presentation properties.
5. A settled preservation and reverse-edit policy for tables.
6. The embedded catalogue schema and its DOCX carrier.
7. An explicit versioning rule for every schema change this specification
   requires.

## Non-goals

- The WP3 CSS and property model (presentation values themselves).
- WP4 rendering behaviour, author-plate layout or field-code emission code.
- WP5 patch algorithms; this document fixes only which edits are patchable.
- Domain profiles (PICOS, PCC); they consume these mechanisms later.
- Any change to the v4 field envelope. Every binding below fits the
  existing eight keys; the envelope's `role` field is already a free
  string. That the envelope needs no change is evidence the WP1 design
  holds.

## Versioning discipline

The WP1 schemas are merged v1 contracts. Every change in this specification
is an **additive v1 revision**: new optional fields, new record types added
to the record dispatch, and new `$defs`. No existing required field changes
meaning, no existing valid instance becomes invalid, with one deliberate
exception recorded in the abstract decision below. Each change ships with
valid and invalid examples under `schemas/examples/`, which the WP1
conformance runner validates automatically. A future change that would
break an existing valid instance mints a v2 schema; nothing in this
specification does so.

Deprecations are marked in schema descriptions and validator warnings, not
by removal. The normalizer (WP3) upgrades deprecated forms to canonical
forms; validation accepts both during the v1 lifetime.

## 1. Abstract

**Decision.** The canonical normalized form is a region reference:

```json
{ "abstract": { "region": "abstract" } }
```

`metadata-core.v1` `document.abstract` becomes
`oneOf: [string, {region: string}]`. The string form remains valid as
authoring input; the WP3 normalizer compiles a YAML `abstract:` string into
an `#abstract` section node (role `abstract`, policy `authored-preserve`)
and rewrites the document record to the region form. The normalized model
and the embedded catalogue always carry the region form — abstract text
lives in exactly one place, the content tree.

The DOCX field wraps the visible abstract with `kind: "section"`,
`role: "abstract"`, `policy: "authored-preserve"`, id `abstract`. On
return, edits to the abstract are authored-content edits and become
proposed QMD patches like any other authored region.

The exception to strict additivity: a document record whose `abstract` is a
string is valid at rest but is not canonical; validation passes it with a
normalization warning rather than failing it. The catalogue embedder
refuses the string form, because embedding it would duplicate authored
text into metadata.

## 2. Generated metadata views

**Decision.** A new `metadata-view` record type binds every generated
region to its source:

```json
{
  "id": "view-document-version",
  "recordType": "metadata-view",
  "schemaVersion": 1,
  "privacy": "public",
  "sourceRecord": "rec-document",
  "path": "version",
  "presentation": "span"
}
```

- `sourceRecord` — id of the record the view renders (document, person,
  organization, funding or contribution).
- `path` — dotted path into that record (`version`, `dates.published`,
  `versionHistory`). An empty path means the whole record (author plates).
- `presentation` — `span`, `block`, `section` or `table`; a rendering hint,
  never authority.

The rendered region's field envelope uses the **same id** as the view
record, `role: "metadata-value"`, `policy: "generated-replace"`. That
identity equation is the binding: a cold DOCX import reads the envelope id,
finds the view record in the embedded catalogue, and knows which value
generated the region and where authority lives. Author plates, affiliation
blocks, date and version spans, version-summary blocks and version-history
tables all become metadata views; WP4 renders them from records and must
not invent unbound generated regions.

Round trip: a Word-side edit inside a `generated-replace` region is never a
patch; reconciliation reports it as a conflict against the authoritative
record, per the WP1 authority rules.

## 3. Contribution model

**Decision.** A new `contribution` record type separates identity from
per-document authorship:

```json
{
  "id": "contrib-1",
  "recordType": "contribution",
  "schemaVersion": 1,
  "privacy": "public",
  "document": "rec-document",
  "person": "rec-person-1",
  "position": 1,
  "roles": ["conceptualization", "methodology"],
  "corresponding": true,
  "email": "jane.smith@example.org",
  "equalContributionGroup": "first-authors",
  "affiliations": ["rec-org-1"]
}
```

Required: `id`, `recordType`, `schemaVersion`, `document`, `person`,
`position` (integer, 1-based; unique per document). Optional: `roles`
(the CRediT enum moves here), `corresponding`, `email`,
`equalContributionGroup` (contributions sharing a group string contributed
equally), `affiliations` (organization record ids, ordered). This closes
the email and equal-contributor gaps the legacy audit deferred.

`person.roles` and `person.corresponding` are deprecated in place: still
valid, warned on, and migrated to contribution records by the WP3
normalizer. The person record keeps identity only (name, ORCID). The
generic relationship triple stays minimal; ordered or qualified
associations get typed records, and contribution is the pattern for any
future case.

The author plate is a metadata view with an empty `path` over the ordered
contribution set. Downstream payoff: this is JATS `<contrib>` semantics,
so the WP6 JATS backend maps directly.

## 4. Typed table and figure attributes

**Decision.** `document-model.v1` gains `$defs/table-attrs` and
`$defs/figure-attrs`, applied conditionally by node type (`if type ==
"table" then attrs matches table-attrs`; likewise `figure`). Both remain
open objects (`additionalProperties: true`) so profiles can extend them.

Semantic attributes only:

- **table-attrs:** `label` (crossref label text), `caption` (node id of the
  caption), `summary` (accessibility summary), `notes` (array of strings),
  `provenance` (free string: data source statement).
- **figure-attrs:** `label`, `caption` (node id), `alt` (alt text —
  required for the catalogue embedder when the figure is public),
  `asset` (asset registry id), `credit` (attribution string).

Presentation data — column widths, alignment, borders, image width,
wrapping, anchor position — is excluded from the semantic model. It belongs
to the WP3 property model (CSS-first) and, where harvested from Word,
to durable state. The asset registry stays portable (`path`, `mediaType`,
`hash`, plus optional `credit`); local source paths live only in durable
state, per the WP1 privacy rule.

## 5. Table preservation policy

**Decision.** Tables are structural containers of authored content:

- The outer `table`, `table-row` and `table-cell` nodes carry
  `policy: "structural"`.
- Cell **content** nodes (paragraphs, spans inside cells) and the caption
  carry `policy: "authored-preserve"`.
- The whole-table field envelope is `kind: "table"`,
  `policy: "structural"`, with authored descendants recoverable through
  their own node identity and hashes.

Consequences, fixed here so WP4 and WP5 build against them: Word-side edits
to cell content are authored edits and become proposed QMD patches; adding
or removing rows or columns is a structural change, reported by
reconciliation but never silently patched or discarded. The migration
audit's `legacy table -> authored-preserve` row is amended to this contract
(the audit row described the whole-table envelope, which is now structural
with authored descendants; the audit file gains a correction note rather
than a rewritten history).

## 6. Embedded catalogue and DOCX carrier

**Decision.** The embedded catalogue is a JSON document:

```json
{
  "schemaVersion": 1,
  "generator": "docstyle <version>",
  "document": "rec-document",
  "records": { "<id>": { … } },
  "views": { "<id>": { … } }
}
```

- `records` — every **public** record (privacy separation is enforced at
  embed time: a `privacy: "restricted"` record never enters the catalogue;
  restricted data stays in local state).
- `views` — the metadata-view records for every generated region present
  in the document.
- Validated by a new `catalogue.v1.json` schema that reuses the
  metadata-core record definitions by reference.

Carrier: an OPC part `/docstyle/catalogue.json`, content type
`application/vnd.docstyle.catalogue+json`, with a relationship from
`/word/document.xml` of type
`https://dougmanuel.github.io/docstyle/relationships/catalogue`. This uses
exactly the WP2 package-core primitives (`add_part`, `add_relationship`
from a document part) and respects the WP2 decision that package-root
relationship addition stays deferred — the catalogue does not need it.
The part is regenerated on every render (`generated-replace` semantics);
its hash is recorded in the durable-state manifest so reconciliation can
detect out-of-band tampering. Cold import order: read the catalogue part
if present, then bind envelopes to records by id; a document with
envelopes but no catalogue degrades to WP1 behaviour (identity and policy
known, rich metadata unknown).

## Schema-change manifest

| File | Change | Kind |
|---|---|---|
| `metadata-core.v1.json` | `document.abstract` becomes `oneOf [string, {region}]` | additive (widening) |
| `metadata-core.v1.json` | new `$defs/metadata-view`, `$defs/contribution`; both join the record dispatch | additive |
| `metadata-core.v1.json` | `person.roles`, `person.corresponding` marked deprecated in descriptions | additive |
| `document-model.v1.json` | `$defs/table-attrs`, `$defs/figure-attrs` + conditional application to `node.attrs` | additive |
| `document-model.v1.json` | asset gains optional `credit` | additive |
| `catalogue.v1.json` | new schema | new file |
| `schemas/examples/…` | valid + invalid examples for every change above | new files |
| `field-envelope.v4.json` | none | — |
| `dev/vnext/wp1-legacy-coverage.md` | correction note on the table-policy row | audit amendment |

## Acceptance criteria

1. Every schema change validates its new valid examples and rejects its
   new invalid examples in the WP1 conformance run; every pre-existing
   valid example still validates (additivity is executable, not asserted).
2. A round-trip fixture shows the abstract contract: YAML string
   in, region-form record + `#abstract` section out, envelope
   `section/abstract/authored-preserve`, and the string form refused by
   the catalogue embedder.
3. A fixture catalogue containing a document record, two contributions in
   order, one metadata view and one restricted record validates against
   `catalogue.v1.json`, and the restricted record is absent from the
   embedded output.
4. The table-policy fixture shows a structural table envelope with
   authored cell-content descendants, and the audit correction note is in
   place.
5. This specification names no WP3/WP4 implementation behaviour beyond the
   contracts above (scope check at review).

## References

- Source of record for the gap analysis: `dev/vnext/metadata-binding-notes.md`.
- WP1 contracts: `docs/superpowers/specs/2026-07-14-docstyle-vnext-wp1-schemas-state-design.md`; schemas under `schemas/`.
- WP2 package-core write primitives (catalogue carrier consumer): `docs/superpowers/specs/2026-08-06-docstyle-vnext-wp2-package-core-design.md` (PR #48).
- Programme specification: `docs/superpowers/specs/2026-07-12-docstyle-vnext-rebuild-design.md`.
