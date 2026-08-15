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

```text
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
   record path — or ordered record collection — that generates it.
3. Concrete QMD bindings: a mapping table and worked examples from
   author-facing YAML/QMD to the normalized records for every bound
   object.
4. An ordered, document-specific contribution model separating identity
   from per-document authorship facts.
5. Typed semantic attributes for table and figure nodes, separated from
   presentation properties.
6. A settled preservation and reverse-edit policy for tables.
7. The embedded catalogue schema and its DOCX carrier.
8. An explicit versioning rule for every schema change this specification
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
meaning and no existing valid instance becomes invalid, with one deliberate,
declared exception: the abstract canonical-form rule (a warning only).
The typed table and figure semantics live in a **new** closed `semantics`
node field rather than closing the existing open `attrs` object — closing
`attrs` would have invalidated previously valid v1 documents, contradicting
this rule. Each change ships with
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

(This example is an author-named display region, so it keeps its explicit
id; an unnamed occurrence carries a generated id per the occurrence rule
below.)

A view has exactly one source, in one of two forms:

- **Single record:** `sourceRecord` (record id) plus `path` — a dotted path
  into that record (`version`, `dates.published`, `versionHistory`). An
  empty path means the whole record.
- **Collection:** `sourceCollection` — an ordered, document-scoped set of
  typed records: `{ "recordType": "contribution", "orderBy": "position" }`.
  The collection is every record of that type whose `document` field names
  this document, ordered by the named field. The author plate is the
  canonical case:

```json
{
  "id": "view-author-plate",
  "recordType": "metadata-view",
  "schemaVersion": 1,
  "privacy": "public",
  "sourceCollection": { "recordType": "contribution", "orderBy": "position" },
  "presentation": "block"
}
```

- `presentation` — `span`, `block`, `section` or `table`; a rendering hint,
  never authority.

`sourceRecord`+`path` and `sourceCollection` are mutually exclusive
(`oneOf` in the schema). The collection form covers every multi-record
display (author plates, affiliation blocks); a single-record view cannot
describe an ordered set, and no free-query language is introduced —
collections are typed, document-scoped and ordered by one declared field.

The rendered region's field envelope uses the **same id** as the view
record, `role: "metadata-value"`, `policy: "generated-replace"`. That
identity equation is the binding: a cold DOCX import reads the envelope id,
finds the view record in the embedded catalogue, and knows which value
generated the region and where authority lives.

**One view record per rendered occurrence.** A view record identifies one
region, so its id obeys WP1's one-id-per-region rule. When the same value
is displayed twice — `{{< meta version >}}` in two paragraphs — each
occurrence gets its own uniquely identified view record; the records share
`sourceRecord` and `path` but never an id. Occurrence ids follow the WP1
identifier rules: explicit when the author names the region, otherwise
generated (`g-span-…`) and persisted in durable state. A repeated-inline
fixture is part of the conformance evidence.

Author plates, affiliation blocks, date and version spans, version-summary
blocks and version-history tables all become metadata views; WP4 renders
them from records and must not invent unbound generated regions.

**Decision (product behaviour, explicit).** A Word-side edit inside a
`generated-replace` metadata display — author plate, date, version,
version-history table, title or status span — is **never** applied as a
patch, to the record or to the QMD. Reconciliation reports it as a
conflict naming the authoritative record and path, and the render
regenerates the display from the record. Collaborators change metadata by
changing the YAML or the record, not the rendered display. This is the
strict reading of the WP1 authority rules, chosen deliberately: accepting
display edits would create a second write path into records that bypasses
validation and privacy separation. If a workflow later needs Word-side
metadata editing, that requires a new reversibility contract for a
specific field type; this rule stands.

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
  "contact": "rec-contact-1",
  "equalContributionGroup": "first-authors",
  "affiliations": ["rec-org-1"]
}
```

Required: `id`, `recordType`, `schemaVersion`, `document`, `person`,
`position` (integer, 1-based; unique per document). Optional: `roles`
(the CRediT enum moves here), `corresponding`, `contact` (see below),
`equalContributionGroup` (contributions sharing a group string contributed
equally), `affiliations` (organization record ids, ordered). This closes
the equal-contributor gap the legacy audit deferred.

**Email is restricted PII and never lives on the public contribution
record.** The WP1 audit classifies author email as restricted-privacy;
record-level privacy cannot publish authorship while concealing one field.
Email therefore lives on a separate `contact` record —
`{id, recordType: "contact", schemaVersion, privacy, email}`. Because WP1
defines a *missing* `privacy` field as public for metadata records, and a
JSON Schema `default` annotation applies no value, relying on a default
would silently publish emails. So the contract is explicit at three
levels:

1. **Schema:** `contact.privacy` is **required**. A contact record without
   it is invalid (a missing-privacy invalid fixture is part of the
   conformance evidence).
2. **Normalizer:** every YAML-derived contact record is written with
   `privacy: "restricted"` unless the author has consented (below). The
   normalizer never emits a contact without the field.
3. **Renderer (WP4):** a restricted email is never displayed, regardless
   of author-plate styling configuration — the render config can only
   choose whether to show a *public* contact, never override privacy.

A contribution references the contact through the optional `contact`
field. **Consent is author-facing and explicit:** the author sub-field
`email-public: true` (see QMD bindings) makes the normalizer write the
contact record with `privacy: "public"`; nothing else does. The catalogue
embedder prunes the `contact` property whenever the target record is
restricted (see the closure rules), so the public authorship record ships
without the email and the display degrades gracefully.

**Reconciliation against the projection.** The embedded catalogue is
compared with `public_projection(local state)`, never with raw local
records: the projection drops restricted records and applies the same
pruning the embedder applies, and embedded-record hashes are computed over
the projected form. A pruned contribution in the catalogue therefore
matches its projected local counterpart — same id, same projected bytes —
and is not a WP1 identifier contradiction.

`person.roles` and `person.corresponding` are deprecated in place: still
valid, warned on, and migrated to contribution records by the WP3
normalizer. The person record keeps identity only (name, ORCID). The
generic relationship triple stays minimal; ordered or qualified
associations get typed records, and contribution is the pattern for any
future case.

The author plate is a metadata view over the contribution
`sourceCollection` ordered by `position` (collection views have no `path`).
Downstream payoff: this is JATS `<contrib>` semantics, so the WP6 JATS
backend maps directly.

## 4. Typed table and figure attributes

**Decision.** The typed semantics live in a **new optional node field**,
`semantics`, validated conditionally by node type against
`$defs/table-semantics` and `$defs/figure-semantics`. The conditional is
encoded with the conformance validator's **supported vocabulary** — a
`oneOf` over node shapes (table node with table semantics, figure node
with figure semantics, any other node without a `semantics` constraint) —
because the WP1 Lua validator implements `oneOf`/`anyOf` but not
`if`/`then` or `allOf`; no validator extension is required. The existing open
`attrs` object is untouched — it remains the home for loose, harvested or
transitional data — so every previously valid v1 document stays valid and
the change is genuinely additive. The `semantics` object is **closed**
(`additionalProperties: false`) so typos and collisions fail validation;
extension happens only through a namespaced container: an optional
`profiles` object keyed by registered profile identifier, whose values are
validated by that profile's manifest. A profile extends a table or figure
by adding records under its own key, never by inventing loose core fields.

Semantic fields only:

- **table-semantics:** `label` (crossref label text), `caption` (node id
  of the caption), `summary` (accessibility summary), `notes` (array of
  node ids — table notes are authored content nodes, not metadata
  strings), `provenance` (`oneOf [string, {record: <id>}]` — a simple
  statement or a reference to a catalogue record when the provenance is
  itself a structured scholarly object), `profiles` (namespaced
  extensions).
- **figure-semantics:** `label`, `caption` (node id), `alt` (alt text —
  required for the catalogue embedder when the figure is public),
  `asset` (asset registry id), `credit` (`oneOf [string, {record: <id>}]`),
  `profiles` (namespaced extensions).

The record-reference forms keep simple cases simple (a plain string) while
letting rich provenance, licences and source relationships live as
catalogue records related to the table or figure by id — the intended
scholarly-object model — without changing the core schema.

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

**This policy applies to authored QMD tables only.** A *generated* table —
a version-history table or any other metadata view rendered as a table —
is `generated-replace` throughout: the table, its rows, its cells and all
descendants regenerate from the source records, and no edit inside one
ever produces a patch (it is a conflict, per the generated-views
decision). The two policies never mix within one table: a table is either
an authored region or a generated view.

Consequences for authored tables, fixed here so WP4 and WP5 build against
them: Word-side edits to cell content are authored edits and become
proposed QMD patches; adding or removing rows or columns is a structural
change, reported by reconciliation but never silently patched or
discarded. The migration
audit's `legacy table -> authored-preserve` row is amended to this contract
(the audit row described the whole-table envelope, which is now structural
with authored descendants; the audit file gains a correction note rather
than a rewritten history).

## 6. Embedded catalogue and DOCX carrier

**Decision.** The embedded catalogue is a JSON document:

```json
{
  "schemaVersion": 1,
  "generator": "docstyle 1.0.0",
  "document": "rec-document",
  "records": {
    "rec-document": { "id": "rec-document", "recordType": "document",
      "schemaVersion": 1, "privacy": "public",
      "type": "protocol", "title": "Example protocol", "version": "2.1" },
    "rec-person-1": { "id": "rec-person-1", "recordType": "person",
      "schemaVersion": 1, "privacy": "public",
      "name": { "given": "Jane", "family": "Smith" } },
    "contrib-1": { "id": "contrib-1", "recordType": "contribution",
      "schemaVersion": 1, "privacy": "public",
      "document": "rec-document", "person": "rec-person-1", "position": 1 }
  },
  "views": {
    "g-span-k3m7ap": { "id": "g-span-k3m7ap",
      "recordType": "metadata-view", "schemaVersion": 1,
      "privacy": "public",
      "sourceRecord": "rec-document", "path": "version",
      "presentation": "span" }
  },
  "objects": {
    "tbl-outcomes": { "id": "tbl-outcomes", "type": "table",
      "semantics": { "label": "Table 1",
        "caption": "g-caption-x2r9qa", "summary": "Outcomes by arm" } }
  },
  "assets": {
    "asset-flow": { "id": "asset-flow", "path": "media/flow.png",
      "mediaType": "image/png",
      "hash": "sha256:0000000000000000000000000000000000000000000000000000000000000000" }
  }
}
```

(View ids in examples follow the occurrence-id rule: an unnamed inline
occurrence carries a generated `g-span-…` id; an author-named region keeps
its explicit id.)

- `records` — every **public** record (privacy separation is enforced at
  embed time: a `privacy: "restricted"` record never enters the catalogue;
  restricted data stays in local state).
- `views` — the metadata-view records for every generated region present
  in the document.
- `objects` — the public projection of table and figure node semantics,
  keyed by node id: `{id, type, semantics}`. Without this container a cold
  DOCX import could not recover table provenance, notes bindings, figure
  credit or profile data — the semantics live in the document model, and
  the catalogue is their only DOCX carrier.
- `assets` — the public asset records (`path`, `mediaType`, `hash`,
  optional `credit`), so asset identity and integrity survive a cold
  import.
- Validated by a new `catalogue.v1.json` schema that reuses the
  metadata-core record definitions by reference.

**Reference closure.** The embedded catalogue must be reference-closed: a
semantic validator (running beside the JSON Schema check, which cannot
express this) walks every reference in every embedded record and view —
`sourceRecord`, `sourceCollection` members, contribution `document`,
`person`, `affiliations` and `contact`, `provenance.record`,
`credit.record`, figure `asset` — and requires the target to be present.
Reference fields are classified once, in the schema descriptions:

- **Closure-required** (`person`, `affiliations`, `document`,
  `sourceRecord`, collection members, `asset`): a public record or object
  whose closure reaches a restricted or absent target is an **embed-time
  error**; the author resolves it by making the target public or removing
  the reference. Embedding must fail closed, never ship a dangling id.
  Resolution scopes: record ids resolve against the catalogue's `records`
  and `views`; `asset` resolves against the catalogue's `assets`
  container; node-id references inside `semantics` (`caption`, `notes`)
  resolve against the document's field-envelope ids at embed time — the
  content tree is carried by the document itself, never duplicated into
  the catalogue.
- **Prunable** (`contact`, `provenance`, `credit`): when the referenced
  target is restricted, the embedder removes the **entire property** from
  the embedded copy — never just the nested `record` key, which would
  leave an invalid empty object — and ships the record without it. This is
  how a public contribution ships without its restricted email.

The semantic validator also enforces what JSON Schema cannot:
contribution `position` values are unique per document (a
duplicate-position fixture must fail), and reconciliation compares the
catalogue with `public_projection(local state)`.

A negative fixture with a dangling restricted reference (a public
contribution whose `person` is restricted) is part of the conformance
evidence and must fail embedding.

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

## Legacy authority migration

The claim that nothing but the WP3 compiler reads author YAML holds for the
vNext engine, and two legacy-engine paths currently contradict it. They are
designated here so WP4 and WP5 replace rather than accidentally preserve
them:

- **`R/metadata_inject.R` (`inject_title_page_metadata`,
  `inject_version_history_table`)** renders title-page and version-history
  content directly from YAML into the DOCX. Legacy path: replaced in WP4
  by metadata views rendered from records. It remains frozen legacy-engine
  behaviour until then, per the programme's legacy freeze.
- **`inst/schema/docstyle-field-codes.json` `version_summary.*` harvest
  rows** read displayed date/version values back out of generated
  regions. Legacy path: superseded by the view binding. In the vNext
  return path, generated metadata displays are **observation-only and
  conflict-only on harvest** — their displayed values are never harvested
  into authority.

Any other code path found reading YAML metadata or harvesting generated
display values during WP3/WP4 implementation gets the same treatment:
designate, replace, never silently coexist.

## QMD bindings

The last mile between author-facing QMD and the normalized model. The WP3
compiler implements exactly these mappings; nothing else reads author YAML.

| Author writes (QMD/YAML) | Normalizes to | Rendered as |
|---|---|---|
| `abstract: "Background..."` or a `::: {#abstract}` div | `#abstract` section node (role `abstract`, authored-preserve); document record `{"abstract": {"region": "abstract"}}` | Authored section, envelope id `abstract` |
| `author:` + `affiliations:` (standard Quarto) | one `person` record per author (identity only), `organization` records, one ordered `contribution` record per author; `email` becomes a `contact` record with explicit `privacy: "restricted"` | Author plate: metadata view over `sourceCollection` contribution/position |
| author sub-field `email-public: true` | the author's `contact` record is written `privacy: "public"` — the explicit consent action; absent, email stays restricted and is never displayed | Public contact rendered per author-plate config |
| `date: 2026-08-14`, `version: "2.1"` | document record `dates.*`, `version` | Generated spans bound by metadata views (`sourceRecord` + path) |
| `version-history:` YAML list | document record `versionHistory[]` | Generated section or table, view path `versionHistory` |
| `{{< meta version >}}` inline | no source-record change — registers one metadata view per occurrence over the named document-record path | Generated span, `role: "metadata-value"` |
| pipe/grid table + `: Caption {#tbl-outcomes}` | `table` node (id `tbl-outcomes`, structural) + caption node (authored) + `semantics` (`label`, `caption`, optional `summary`/`notes`/`provenance`) | Structural table envelope with authored descendants |
| `![Caption](flow.png){#fig-flow fig-alt="..."}` | `figure` node (id `fig-flow`, authored) + `semantics` (`alt` from `fig-alt`, `caption`, `asset`) + asset record (path, mediaType, hash) | Authored figure envelope |
| `licence:`, `status:`, `type:`, `identifiers:` | document record fields (WP1 core vocabulary) | Metadata views where displayed |
| profile fields (PICOS, PCC — future) | profile records under the profile's registered key | Per the profile's own specification |

Two worked examples fix the author-to-record shape.

Authorship — the author writes standard Quarto:

```yaml
author:
  - name: Jane Smith
    orcid: 0000-0002-1825-0097
    email: jane.smith@example.org
    corresponding: true
    roles: [conceptualization, methodology]
    affiliations:
      - ref: uottawa
affiliations:
  - id: uottawa
    name: University of Ottawa
```

The normalizer produces `person` `{id: "rec-person-1", name: {given: "Jane", family: "Smith"}, orcid: …}`, `organization` `{id: "rec-org-uottawa", name: "University of Ottawa"}`, `contact` `{id: "rec-contact-1", privacy: "restricted", email: "jane.smith@example.org"}` (the normalizer always writes `privacy` explicitly, `restricted` unless consented), and `contribution` `{id: "contrib-1", document: "rec-document", person: "rec-person-1", position: 1, roles: […], corresponding: true, contact: "rec-contact-1", affiliations: ["rec-org-uottawa"]}`. Author order in YAML is `position` order; nothing else encodes it. The embedder prunes the `contact` property while the contact record stays restricted. Adding `email-public: true` to that author's YAML entry is the consent action: the normalizer then writes the contact record with `privacy: "public"` and the email ships in the catalogue and may be displayed.

Version display — the author writes `version: "2.1"` and, in prose,
`Protocol version {{< meta version >}}.` The normalizer stores
`version: "2.1"` on the document record and registers one metadata view
per occurrence — this unnamed inline occurrence gets a generated id
(e.g. `g-span-k3m7ap`), per the occurrence-id rule — and WP4 renders the
span wrapped in an envelope whose id is the view id. Editing the rendered "2.1" in Word is
a conflict (see the generated-views decision); editing the YAML changes
the record and every view of it.

## Schema-change manifest

| File | Change | Kind |
|---|---|---|
| `metadata-core.v1.json` | `document.abstract` becomes `oneOf [string, {region}]` | additive (widening) |
| `metadata-core.v1.json` | new `$defs/metadata-view` (`oneOf` sourceRecord+path / sourceCollection; one record per rendered occurrence), `$defs/contribution` (with `contact` reference; `position` unique per document via the semantic validator), `$defs/contact` (**`privacy` required** — the normalizer writes `restricted` explicitly unless `email-public` consent); all join the record dispatch | additive |
| `metadata-core.v1.json` | `person.roles`, `person.corresponding` marked deprecated in descriptions | additive |
| `document-model.v1.json` | new optional `node.semantics` field + `$defs/table-semantics`, `$defs/figure-semantics` (closed; namespaced `profiles` container; `notes` as node ids; `provenance`/`credit` as `oneOf [string, {record}]`); conditional typing encoded as `oneOf` over node shapes (the WP1 Lua validator has `oneOf`/`anyOf`, no `if`/`then`/`allOf`); the open `attrs` object is untouched | additive |
| `document-model.v1.json` | asset gains optional `credit` | additive |
| `catalogue.v1.json` | new schema: `records`, `views`, `objects` (public projection of table/figure node semantics) and `assets` containers | new file |
| conformance runner | semantic validator beside the JSON Schema checks: reference closure (closure-required vs prunable classes, scoped resolution), whole-property pruning, contribution-position uniqueness, catalogue-vs-`public_projection(local state)` reconciliation | new validator |
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
   order, one metadata view, one restricted contact record and one
   restricted unrelated record validates against `catalogue.v1.json`; the
   restricted records are absent from the embedded output and the
   contributions' `contact` references are pruned.
4. A negative closure fixture — a public contribution whose `person` is
   restricted — **fails** embedding through the semantic closure
   validator.
5. A repeated-inline fixture with `{{< meta version >}}` in two
   paragraphs produces two view records with distinct ids sharing
   `sourceRecord` and `path`.
6. The table-policy fixture shows a structural authored table envelope
   with authored cell-content descendants AND a generated version-history
   table that is `generated-replace` throughout; the audit correction
   note is in place.
7. A contact record without `privacy` is an invalid example and fails
   schema validation; a document with two contributions sharing a
   `position` fails the semantic validator.
8. A cold-recovery fixture starts from the DOCX alone (no QMD, no local
   state) and recovers the table and figure semantics and asset identity
   (path, media type, hash) through the catalogue's `objects` and
   `assets` containers.
9. This specification names no WP3/WP4 implementation behaviour beyond the
   contracts above (scope check at review).

Fixture homes and commands: schema examples live under
`schemas/examples/<schema-name>/` (`valid-*.json` / `invalid-*.json`, the
naming the WP1 runner already dispatches on); binding fixtures live under
`tests/vnext/conformance/fixtures/metadata-binding/`. The whole set runs
inside the existing conformance command:

```bash
quarto run tests/vnext/conformance/run.lua
```

## References

- Source of record for the gap analysis: `dev/vnext/metadata-binding-notes.md`.
- WP1 contracts: `docs/superpowers/specs/2026-07-14-docstyle-vnext-wp1-schemas-state-design.md`; schemas under `schemas/`.
- WP2 package-core write primitives (catalogue carrier consumer): PR #48, which carries `docs/superpowers/specs/2026-08-06-docstyle-vnext-wp2-package-core-design.md` (the path lands on `main` when #48 merges).
- Programme specification: `docs/superpowers/specs/2026-07-12-docstyle-vnext-rebuild-design.md`.
