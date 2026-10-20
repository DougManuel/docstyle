# Docstyle vNext metadata-binding design

Date: August 14, 2026

Work package position: pre-WP3 gate. This specification completes the middle
layer between the WP1 contracts and the WP3/WP4 implementations: the
normalized bindings between QMD metadata, semantic objects, generated views
and catalogue records.

Status: accepted in #49 (merged October 16, 2026). Amendment 1 (October
16, 2026) settles the five contract clarifications recorded at acceptance
and was accepted on October 20, 2026; see the amendment record at the end.

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
meaning and no existing schema-valid instance becomes invalid. The v1 node
and asset definitions are open, so previously valid values at `semantics`
and `credit` remain schema-valid at rest. Neither property gains a restrictive
schema constraint in v1. Canonical normalization and catalogue embedding
apply the typed contracts below; a noncanonical value produces a warning
at rest and prevents embedding until explicitly normalized. It is never
silently discarded or reinterpreted. The abstract string has the same
at-rest versus canonical distinction. Each implemented change ships with
valid and invalid examples under `schemas/examples/`, which the WP1
conformance runner validates automatically. A future change that would
break an existing valid instance mints a v2 schema; nothing in this
specification does so.

**Amendment 1 additions follow the same rule.** The v1 schemas that
amendment 1 touches (`metadata-core`, `profile-manifest` and
`state-manifest`) are open objects, so values such as `name.literal: 7` or
`referenceFields: 7` validate today. Their new typed forms are therefore
canonical definitions in `$defs`, not restrictive v1 constraints:
validation at rest stays permissive and warns on a noncanonical value, and
the canonical validators apply the definitions where Docstyle reads or
publishes the value. A noncanonical `person.name.literal` blocks
normalization and embedding; a noncanonical `referenceFields` or
`documentScoped` makes the manifest invalid at activation
(`profile-manifest-invalid`); a noncanonical `catalogues` entry is treated
as absent, with a warning, so the tampering check degrades to WP1
behaviour. The new `catalogue.v1` schema has no earlier instances and is
strict from the start.

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

The canonical-form boundary: a document record whose `abstract` is a
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

**Generated regions outside metadata (amendment 1).** The view-region
identity applies to every `generated-replace` region whose `role` is
`metadata-value`. Descendants of such a region -- the rows and cells of a
generated version-history table, for example -- are covered by the
outermost region's view and need no view of their own. Every other
outermost `generated-replace` region must carry a role that the binding
contract of the generating work package registers as a **generator role**:
a table of contents or a list of figures, for example, once WP4 specifies
them. A generator-role region binds to no record, so it has no view and no
metadata-view entry (the catalogue's `generated` container, below, records
it); its contract states what regenerates it. A
`generated-replace` region with no role, or with an unregistered role, is
unbound, and embedding fails closed (`unbound-generated-region`). Version 1
registers one generator role, `quarto-meta`, owned by WP3: a Quarto `meta`
value whose key has no record path, regenerated from YAML by every render
and conflict-only on return, so a Word edit never rewrites the QMD. Two
guards keep it from bypassing privacy: a key under the YAML paths that
normalize into records (`author`, `authors`, `by-author`, `affiliations`,
`by-affiliation`, `funding`) is refused, because those values display only
through record-bound views; and a value equal to a protected value of a
restricted record is refused (`quarto-meta-restricted-value`). A
restricted record's protected values are the string values of its payload
fields, that is, every field except the structural ones (`id`,
`recordType`, `schemaVersion`, `privacy`, `profile`, `document`) and its
reference fields; for a contact, that is its `email`. Comparison is exact.
Structural values such as `1` or `contact` therefore never cause a
refusal. The
catalogue's optional `generated` container records, for each generator-role
region, its role and parameters (for `quarto-meta`, the key), so a cold
import can rebuild the shortcode. WP4 registers further roles, such as
`toc`, when it specifies them.

**Restricted views (amendment 1).** A view record may be restricted only
when no rendered region binds it, for example a local-only binding kept in
state for a draft display. A restricted view whose id appears on a
rendered region fails local validation (`view-restricted`), because the
region would place the binding in a public document. The author makes the
view public or removes the display. A restricted view without a rendered
region never enters the catalogue. The privacy of the displayed value is a
separate matter, settled by reference closure: a view whose `sourceRecord`
or collection members are restricted fails closure, so a public display
never renders a restricted value.

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

`person.roles`, `person.corresponding` and (amendment 1)
`person.affiliations` are deprecated in place: still valid, warned on, and
migrated to contribution records by the WP3 normalizer. Legacy
`person.affiliations` move to the `affiliations` of that person's
contributions in the document when a contribution has none; when both are
present and differ, the normalizer keeps the contribution's list and
reports the difference instead of merging. Until migrated,
`person.affiliations` remain closure-required organization references (see
section 6). The person record keeps identity only (name, ORCID).

**Name literal (amendment 1).** Quarto parses a plain author name in the
BibTeX manner and keeps particles such as "da" or "van" only in its literal
form ("Ludwig van Beethoven" gives family "Beethoven"). `person.name`
therefore gains an optional `literal`, the name exactly as the author wrote
it. The normalizer always stores it alongside `given` and `family`, and
displays render `literal` when present, so no part of a name is lost.
Authors who need an exact family name for sorting or JATS write the name in
structured form (`name: {given: Ludwig, family: van Beethoven}`). The
generic relationship triple stays minimal; ordered or qualified
associations get typed records, and contribution is the pattern for any
future case.

The author plate is a metadata view over the contribution
`sourceCollection` ordered by `position` (collection views have no `path`).
Downstream payoff: this is JATS `<contrib>` semantics, so the WP6 JATS
backend maps directly.

### Additional properties on public records (amendment 1)

The WP1 core record definitions are open, so a record can carry properties
its definition does not name, such as an `email` on a person. Validation at
rest stays permissive: such a record is a valid v1 instance and produces a
warning. Canonical publication is strict, in two steps.

1. **Normalizer migration (WP3).** A *contact-bearing property* is any
   property the `contact` definition names other than `id`, `recordType`,
   `schemaVersion` and `privacy`; in version 1 that is `email`. When a
   person record carries one, the normalizer moves it into a contact
   record, written `privacy: "restricted"` unless the author consented with
   `email-public: true`, and links that contact from each of the person's
   contributions in the document that links none. When a contribution
   already links a different contact, the normalizer keeps the existing
   link and reports the conflict instead of choosing. A contact-bearing
   property on any other record type has nothing to link to; the
   normalizer reports it and leaves it in place.
2. **Embedding refusal.** In local validation (step 1 of embedding, section
   6), a public record may carry only the properties its definition names:
   the core v1 definition, or for a profile record the active profile's
   derived schema. A contact-bearing property on any record other than a
   contact fails with `contact-field-misplaced`. Any other undeclared
   property fails with `record-property-undeclared`. Nothing is dropped
   silently: the author migrates the value, declares it through a profile
   or removes it. Restricted records never embed, so neither refusal
   applies to them.

**Decision record.** The owner decided the contact-bearing rule (migration,
then refusal) on October 16, 2026, when #49 was accepted, and ratified
extending the refusal to every other undeclared property the same day.

## 4. Typed table and figure attributes

**Decision.** Canonical table and figure nodes use the optional `semantics`
property. The v1 node schema leaves that property unconstrained. New
`$defs/table-semantics` and `$defs/figure-semantics` define the canonical
forms without being attached as restrictive v1 node properties. The
semantic validator dispatches by node type and validates present semantics
against the appropriate definition before embedding. The new catalogue
schema also applies those definitions to its table and figure objects.
Missing semantics is permitted at rest; public figures must still satisfy
the embed-time alt-text requirement below.

A legacy table with `semantics: "legacy-value"` therefore remains valid
against `document-model.v1.json`, produces a normalization warning and
fails embedding until explicitly normalized. No permissive fallback is
allowed in canonical validation: malformed newly generated semantics must
fail too. The same rule applies to a legacy asset `credit` value; canonical
credit uses the string-or-record-reference form below. The open `attrs`
object is untouched. Canonical semantics is **closed**
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
- `profiles` (amendment 1, optional) — the public projection of each
  active profile manifest (`id`, `version`, declared `schema`,
  `recordTypes`), so a cold import validates profile data against the
  schema embedding used. Without it, a cold import falls back to the
  name-derived schema and warns (`profile-binding-absent`); output that
  embedding accepts must always cold-recover. Reconciliation compares each
  binding like any metadata, so a changed declared schema or version is a
  blocking conflict, while a catalogue with no `profiles` container
  predates bindings and is reported with the same warning, not blocked.
  Cold recovery returns the bindings with the rest of the catalogue.
- Validated by a new `catalogue.v1.json` schema that reuses the
  metadata-core record definitions by reference.

**Reference closure.** The embedded catalogue must be reference-closed: a
semantic validator (running beside the JSON Schema check, which cannot
express this) walks every reference in every embedded record and view —
`sourceRecord`, `sourceCollection` members, contribution `document`,
`person`, `affiliations` and `contact`, legacy person `affiliations`,
funding `funder` (both amendment 1), `provenance.record`,
`credit.record`, figure `asset` — and requires the target to be present.
Reference fields are classified once, in the schema descriptions:

- **Closure-required** (`person`, `affiliations` on contributions and
  legacy person records, `funder`, `document`, `sourceRecord`, collection
  members, `asset`): a public record or object
  whose closure reaches a restricted or absent target is an **embed-time
  error**; the author resolves it by making the target public or removing
  the reference. Embedding must fail closed, never ship a dangling id.
  Resolution scopes: authority record ids resolve against the catalogue's
  `records`, which excludes metadata-view records. Views occur only in
  `views` and cannot be sources of other views. `asset` resolves against the catalogue's `assets`
  container; node-id references inside `semantics` (`caption`, `notes`)
  resolve against the document's field-envelope ids at embed time — the
  content tree is carried by the document itself, never duplicated into
  the catalogue.
- **Prunable** (`contact`, `provenance`, `credit`): when the referenced
  target is restricted, the embedder removes the **entire property** from
  the embedded copy — never just the nested `record` key, which would
  leave an invalid empty object — and ships the record without it. This is
  how a public contribution ships without its restricted email.

Presence alone is insufficient. The semantic validator enforces these
target types: `catalogue.document` and `contribution.document` reference
document records; `person` references a person; `affiliations`, on a
contribution or a legacy person record, references organizations; `funder`
references an organization; `contact` references a contact; and figure
`asset` references an asset. It checks contact target types before pruning restricted contacts.
Missing targets are errors, including for prunable references: only a known
restricted target permits pruning. Record-reference provenance and credit
resolve to records, never views.

For `sourceRecord`, an empty path selects the whole authority record.
Otherwise, a dotted path consists of nonempty object-property segments,
each of which must exist; array indexing and wildcard queries are unsupported.
Existence is independent of value truthiness. Path validation runs against
the projected record, so a path removed by privacy pruning fails embedding.
View-to-view references, self-references and view cycles are invalid.

Collections select records whose type matches `recordType` and whose
`document` equals `catalogue.document`. The record type must be registered
and document-scoped. Selection is evaluated before privacy projection;
a selected restricted member fails closure instead of silently disappearing.
Every selected member must have the declared `orderBy` property, with
uniform finite-number or string values. Sort ascending (strings by UTF-8
byte order), breaking ties by record id. Contribution positions remain
unique per document. Empty collections are permitted.

**Profile references (amendment 1).** A profile manifest may declare the
reference fields of its record types in an optional `referenceFields`
object: `{"<recordType>": {"<field>": {"targets": […], "class":
"closure-required" | "prunable"}}}`. `targets` lists record types, resolved
against the catalogue's `records` with the same type check as core
references, or is the single value `["region"]`, resolved against the
document's field-envelope ids as `caption` and `notes` are. Region
targets are always closure-required; `prunable` is valid only for record
targets, and a manifest that pairs them is invalid
(`profile-manifest-invalid`). A declared field holds one id or an array of
ids, and every element is a reference.
Declared profile references join the closure walk and the three embedding
steps exactly as core references do. Undeclared profile fields carry no
reference semantics. The restricted-id guard stays as defence in depth
for everything without a declared reference classification: in local
validation, any string in an undeclared field of a public profile record,
or in a `semantics.profiles` extension value, that equals the id of a
restricted record fails (`profile-value-restricted-id`). A declared
reference field is exempt from the guard because its classification
already governs it: a declared prunable field naming a restricted record
is pruned as a whole property, and a declared closure-required field
naming one fails closure. Semantics extension values declare no references
in version 1.

**Document-scoped profile types (amendment 1).** A profile manifest may
list record types in an optional `documentScoped` array. Each listed type
must define a required `document` property in the profile's derived
schema, or the manifest is invalid (`profile-manifest-invalid`). That
`document` property is a closure-required reference to a document record,
and the type becomes eligible as a `sourceCollection.recordType` while its
profile is active.

Embedding runs in three ordered steps. The order matters because
projection removes the evidence that some checks need: once a restricted
target is pruned, it is indistinguishable from an absent one.

1. **Local validation, before projection.** Validate the local records
   against their schemas. Validate canonical semantics on every table and
   figure, and canonical `credit` and `provenance` wherever they occur,
   including values that projection will later prune. Check
   reference target types. Resolve every prunable reference and classify
   its target as public, known restricted or absent; an absent target
   fails. Select collection members and fail on any restricted member.
   A malformed or noncanonical value fails here even when its target is
   restricted, so pruning never discards a value that was not validated.
2. **Projection.** Compute `public_projection`, drop restricted records
   and remove the entire property of each prunable reference whose target
   step 1 classified as known restricted. Pruning acts only on that
   classification; it never interprets a value itself.
3. **Embedded validation, after projection.** Validate the resulting
   catalogue against `catalogue.v1.json`, recheck canonical semantics on
   the projected objects, and validate `sourceRecord` paths and reference
   closure against the projected records.

Restricted records never validate as embedded output.

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
detect out-of-band tampering. **Manifest field (amendment 1):** an optional
top-level `catalogues` object in `state-manifest.v1`, keyed by document
record id, each value `{"schema": "<catalogue.v1 $id>", "hash":
"sha256:…"}`. The hash is SHA-256 over the WP1 canonical JSON
serialization of the embedded catalogue, the canonical rule WP1 uses for
content hashes, so a re-serialization that preserves content does not
register as tampering. Because collection sort keys may be finite
non-integer numbers, canonical JSON serializes such a number in its
shortest round-trip form (RFC 8785, section 3.2.2.3); integers are
unchanged. Only a DOCX render writes or removes the entry, in the state
generation that records it: renders to other formats in the same project
leave it untouched, and a document whose last DOCX render embedded no
catalogue has no entry. On return, a catalogue whose canonical hash
differs from the entry is reported as an out-of-band change and never
harvested as authority. A missing part where the manifest records one
degrades to WP1 behaviour and is reported. The entry is not a `files[]`
member: those are durable-state files with generation-qualified physical
names, and the catalogue lives in the DOCX. Cold import order: read the catalogue part
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
| `{{< meta key >}}` for a key with no record path (amendment 1) | no record; a generated span with generator role `quarto-meta`, refused for record-feeding paths and restricted values | Generated span, regenerated from YAML; conflict-only on return |
| pipe/grid table + `: Caption {#tbl-outcomes}` | `table` node (id `tbl-outcomes`, structural) + caption node (authored) + `semantics` (`label`, `caption`, optional `summary`/`notes`/`provenance`) | Structural table envelope with authored descendants |
| `![Caption](flow.png){#fig-flow fig-alt="..."}` | `figure` node (id `fig-flow`, authored) + `semantics` (`alt` from `fig-alt`, `caption`, `asset`) + asset record (path, mediaType, hash) | Authored figure envelope |
| `licence:`, `status:`, `type:`, `identifiers:` | document record fields (WP1 core vocabulary); Quarto's `license` key is accepted as an alias of `licence` (amendment 1) | Metadata views where displayed |
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
| `document-model.v1.json` | add canonical `$defs/table-semantics`, `$defs/figure-semantics` (closed, with namespaced profiles); leave `node.semantics` unconstrained at rest; semantic validator and catalogue schema apply the definitions before embedding | additive definitions |
| `document-model.v1.json` | document canonical asset `credit` as string or record reference; leave existing arbitrary values schema-valid at rest and validate canonical credit before embedding | additive definitions |
| `catalogue.v1.json` | new schema: `records`, `views`, `objects` (public projection of table/figure node semantics) and `assets` containers; amendment 1 adds optional `generated` (generator-role regions: role and parameters) and `profiles` (declared profile-schema bindings) containers | new file |
| conformance runner | JSON Schema subset validator (`tests/vnext/conformance/lib/jsonschema.lua`): resolve `$ref` values of the form `<registered $id>#/<pointer>`, so `catalogue.v1.json` can reuse `document-model.v1.json` and `metadata-core.v1.json` definitions. Constraints that must accompany a reused definition (such as public-only records) use a wrapper — `properties` beside `anyOf: [{"$ref": …}]` — because the validator ignores keywords beside `$ref`; `allOf`, `not` and `if`/`then` stay unsupported | validator extension (additive: every existing schema resolves as before) |
| conformance runner | semantic validator: canonical semantics and credit, typed reference closure, terminal view authority, projected path resolution, collection scope and ordering, whole-property pruning, contribution-position uniqueness, catalogue-vs-`public_projection(local state)` reconciliation | new validator |
| `schemas/examples/…` | valid + invalid examples for every change above | new files |
| `metadata-core.v1.json` | amendment 1: `person.affiliations` marked deprecated; `person.affiliations` and `funding.funder` described as closure-required organization references | additive (descriptions) |
| `metadata-core.v1.json` | amendment 1: canonical `person.name.literal` definition, applied by the canonical validators; v1 validation at rest unchanged | additive definition |
| conformance libraries | amendment 1: canonical JSON serializes finite non-integer numbers in shortest round-trip form (RFC 8785) | library change |
| `profile-manifest.v1.json` | amendment 1: canonical `referenceFields` (per record type: field → `targets`, `class`) and `documentScoped` (record types with a required `document` reference) definitions, applied at profile activation; v1 validation at rest unchanged | additive definitions |
| `state-manifest.v1.json` | amendment 1: canonical `catalogues` definition (keyed by document record id, each `{schema, hash}`), applied when the manifest is read; v1 validation at rest unchanged | additive definition |
| conformance runner | amendment 1 semantic-validator rules: legacy person affiliations and funding funder in closure; generator roles for non-metadata generated regions; restricted views; declared profile references and document-scoped profile types; undeclared and misplaced contact-bearing properties refused at embedding | validator extension |
| `field-envelope.v4.json` | none | — |
| `dev/vnext/wp1-legacy-coverage.md` | correction note on the table-policy row | audit amendment |

## Acceptance criteria

These are implementation acceptance criteria for the subsequent schema,
normalizer and embedder work. This specification PR defines the contracts
and fixture locations; it does not claim to implement those fixtures.

1. Every schema change validates its new valid examples and rejects its
   new invalid examples in the WP1 conformance run; every pre-existing
   valid example still validates (additivity is executable, not asserted).
2. A round-trip fixture shows the abstract contract: YAML string
   in, region-form record + `#abstract` section out, envelope
   `section/abstract/authored-preserve`, and the string form refused by
   the catalogue embedder.
3. A local pre-embed fixture contains a document record, two ordered
   contributions, a metadata view, a restricted contact and an unrelated
   restricted record. Validate the local records, then project and prune.
   The separate embedded output validates against `catalogue.v1.json` and
   semantic closure: both restricted records are absent and the associated
   contribution contact property is absent. The unprojected input must
   fail embedded-catalogue validation.
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
10. Legacy arbitrary table/figure `semantics` and asset `credit` values
    still pass v1 schema validation, produce normalization warnings and
    fail canonical embedding. Explicitly normalized equivalents embed;
    newly generated malformed semantics fails canonical validation too.
11. Negative binding fixtures reject wrong target types, absent targets
    (including prunable ones), stale or pruned paths, view self-references
    and cycles, unregistered collection types, missing or mixed-type sort
    keys and selected restricted members. Positive cases cover empty paths,
    existing false/null values, empty collections, deterministic tie order
    and exclusion of records belonging to a different document.
12. An embedding-order fixture pairs a malformed record-form asset
    `credit` with a restricted target. Embedding fails in local
    validation; the value is not pruned away. The same credit in
    canonical form is pruned and the asset embeds without it. A
    cross-file `$ref` into `document-model.v1.json` resolves in the
    conformance run.
13. Amendment 1 closure fixtures: a public person whose legacy
    `affiliations` name a restricted organization fails embedding; a
    public funding record whose `funder` names an absent or
    non-organization record fails; the same records with public
    organization targets embed.
14. Amendment 1 generated-region fixtures: an outermost
    `generated-replace` region with role `metadata-value` and a public
    view embeds; one with no role, or an unregistered role, fails with
    `unbound-generated-region`; a `quarto-meta` region embeds without a
    view, with its key in the catalogue's `generated` container, while a
    `quarto-meta` key under an author path or with a restricted value fails;
    descendants of a bound region need no view. A rendered region
    bound to a restricted view fails with
    `view-restricted`; a restricted view with no rendered region stays in
    local state and is absent from the catalogue.
15. Amendment 1 profile fixtures: a declared closure-required profile
    reference to a restricted target fails closure, and a declared
    prunable one is pruned as a whole property; a `documentScoped` type
    whose derived schema lacks a required `document` property makes the
    manifest invalid; a valid document-scoped profile type works as a
    collection source. A string equal to a restricted id in an undeclared
    profile field still fails.
16. Amendment 1 additional-property fixtures: a public person carrying
    `email` is valid at rest with a warning and fails embedding with
    `contact-field-misplaced`; a public record with any other undeclared
    property fails with `record-property-undeclared`; restricted records
    carrying either produce no refusal. The normalizer part (the email
    moved to a restricted contact linked from the person's contributions,
    after which the person embeds) is a WP3 acceptance item.
17. Amendment 1 manifest fixtures: a state manifest with a well-formed
    `catalogues` entry validates; an entry with a malformed hash still
    validates at rest but fails canonical validation, so it is treated as
    absent, with a warning, and the tampering check falls back to WP1
    behaviour; the canonical hash of a re-serialized but unchanged catalogue
    matches the recorded one, and a well-formed recorded hash that differs
    from the catalogue is the separate tampering case.
18. Amendment 1 naming fixtures: an author written "Ludwig van Beethoven"
    produces a person whose `name.literal` keeps the particle; a structured
    name keeps its exact family name; a document using Quarto's `license`
    key produces the same `licence` field as one using `licence`; a
    profile manifest pairing a region target with `prunable` is invalid.
19. Amendment 1 compatibility fixtures: `person.name.literal: 7`,
    `referenceFields: 7` and `catalogues: 7` still validate against their v1
    schemas at rest, each with a canonical-validation warning, and each
    fails canonical validation where its canonical form is required: the
    literal blocks normalization and embedding, the reference fields make
    the manifest invalid at profile activation, and the catalogue entry is
    treated as absent, with a warning, so the tampering check falls back to
    WP1 behaviour rather than failing the operation. A declared
    prunable profile reference naming a restricted record is pruned, not
    refused by the restricted-id guard. A `quarto-meta` value equal to `1`
    or `contact` embeds while a restricted contact exists; one equal to that
    contact's email fails.

Fixture homes and commands: schema examples live under
`schemas/examples/<schema-name>/` (`valid-*.json` / `invalid-*.json`, the
naming the WP1 runner already dispatches on); binding fixtures live under
`tests/vnext/conformance/fixtures/metadata-binding/`. The whole set runs
inside the existing conformance command:

```bash
quarto run tests/vnext/conformance/run.lua
```

## Amendment record

**Amendment 1 (October 16, 2026).** Settles the five contract
clarifications recorded when #49 was accepted (independent re-review at
`3d78e19`):

| Clarification | Settled in |
|---|---|
| Classify `funding.funder` and legacy `person.affiliations` | Sections 3 and 6: closure-required organization references; `person.affiliations` deprecated and migrated to contributions |
| Profile reference fields and document-scope registration | Section 6: `referenceFields` and `documentScoped` in the profile manifest; restricted-id guard retained |
| Additional-field publication policy | Section 3: contact-bearing properties migrated by the normalizer, then refused at embedding; other undeclared properties refused (owner-ratified October 16, 2026) |
| Catalogue-hash field in the durable-state manifest | Section 6: top-level `catalogues` keyed by document id, canonical JSON SHA-256 |
| Restricted views and generated regions without metadata bindings | Section 2: generator roles for non-metadata generated regions (`quarto-meta` registered by WP3 in v1); restricted views only when unrendered |

All changes are additive v1 revisions under the versioning discipline above.
The interim implementation in #57 already matches the funder and
affiliation closure, the restricted-view rule and the restricted-id guard.
Its rule that every outermost generated region needs a view is the
generator-role rule without registered roles; it needs the `quarto-meta`
exemption. It also needs the profile declarations, the additional-property
refusal, the manifest field, the `person.affiliations` deprecation warning
(it warns only for `roles` and `corresponding`) and `person.name.literal`.

Review of the first draft added four refinements: region targets cannot be
prunable; only DOCX renders write the catalogue-hash entry; canonical JSON
gains a rule for non-integer numbers; and `person.name.literal` preserves
name particles, with Quarto's `license` accepted as an alias of
`licence`.

## References

- Source of record for the gap analysis: `dev/vnext/metadata-binding-notes.md`.
- WP1 contracts: `docs/superpowers/specs/2026-07-14-docstyle-vnext-wp1-schemas-state-design.md`; schemas under `schemas/`.
- WP2 package-core write primitives (catalogue carrier consumer): `docs/superpowers/specs/2026-08-06-docstyle-vnext-wp2-package-core-design.md`, merged in PR #48.
- Programme specification: `docs/superpowers/specs/2026-07-12-docstyle-vnext-rebuild-design.md`.
