# Metadata architecture review notes (source of record)

External reviewer analysis relayed by the project owner on August 14, 2026.
These notes are the source material for the metadata-binding specification
(`docs/superpowers/specs/2026-08-14-docstyle-vnext-metadata-binding-design.md`).
Recorded verbatim apart from link formatting (absolute worktree paths reduced
to repo-relative paths).

---

The metadata architecture is fundamentally sound, but it is not yet specified deeply enough for implementation. WP1 established the identifiers, field envelopes, generic document model and record registries. The detailed QMD-to-model bindings and typed metadata for tables, figures and generated metadata displays are deferred to WP3 and WP4.

The intended flow is:

```text
QMD/YAML authority
    → normalized semantic document model
        → DOCSTYLE field envelope: identity, kind, policy, hash
        → embedded catalogue: rich public metadata
        → local state: source locations, private data, reconciliation history
```

That is the right field-code approach. A field code should identify and protect a visible semantic object; it should not contain the entire metadata record. The v4 envelope is deliberately limited to eight keys and 1,024 bytes (WP1 specification, field-code contract).

## What is already in place

- Stable field-code kinds for table, figure, caption, section, span and other structures
- Stable IDs, content hashes, parent relationships and explicit preservation policies
- Core records for documents, people, organizations and funding
- Document fields for title, version, version history, typed dates, identifiers, licence and status
- Structured table, row, cell, figure and caption nodes
- An asset registry for media path, media type and hash
- QMD conventions for identifiers, record references, relationships and inline metadata variables
- Privacy separation: only public records may enter the embedded catalogue; restricted data stays local

WP4 is explicitly meant to render "metadata, a named abstract, prose, lists, one table and one figure," emit field codes and embed the catalogue.

## Important gaps

### 1. Abstract representation is inconsistent

The WP1 prose allows the document abstract to be "region reference or inline text," but `schemas/metadata-core.v1.json` (document record) accepts only a string. Meanwhile, the document model correctly represents the abstract as a section node with `role: "abstract"`.

Recommended: one canonical normalized form:

```json
{ "abstract": { "region": "abstract" } }
```

A YAML `abstract:` value would be compiled into the `#abstract` region. The document record would reference that region rather than duplicate its text. The DOCX field would wrap the visible abstract with `kind: "section"` and `policy: "authored-preserve"`.

### 2. Generated metadata views need an explicit binding

The design says `{{< meta version >}}` is a rendered view and never authoritative. That principle is correct, but there is no schema describing what a generated span or block displays.

This affects: author plates, affiliations, date and version spans, version-summary blocks, version-history tables, potential title and status displays.

Each generated region needs a catalogue binding such as:

```json
{
  "id": "view-document-version",
  "recordType": "metadata-view",
  "sourceRecord": "rec-document",
  "path": "version"
}
```

Its field envelope could then be:

```json
{
  "v": 4,
  "id": "view-document-version",
  "kind": "span",
  "role": "metadata-value",
  "policy": "generated-replace",
  "hash": "sha256:..."
}
```

Without this binding, a cold DOCX import knows that something is a generated span, but not which metadata value generated it.

### 3. Authorship needs a document-specific contribution model

Person and organization records exist, and standard Quarto `author:` and `affiliations:` are mapped to them. But the document record does not contain an ordered author list, and the generic relationship schema cannot express author order or contribution qualifiers.

Also, CRediT roles and `corresponding` currently sit on the person record. Those facts generally describe a person's role in a particular document, not the person universally.

A stronger model separates identity from contribution:

```json
{
  "id": "contrib-1",
  "recordType": "contribution",
  "document": "rec-document",
  "person": "rec-person-1",
  "position": 1,
  "roles": ["conceptualization", "methodology"],
  "corresponding": true,
  "affiliations": ["rec-org-1"]
}
```

Email and equal-contributor status are already recognized as gaps deferred to WP4 (`dev/vnext/wp1-legacy-coverage.md`).

### 4. Tables and figures have identity, but not typed object metadata

The current document model gives every node an untyped `attrs` object. The asset registry contains only path, mediaType and hash. That is enough for WP1 conformance, but not the robust object contract intended.

WP3 should define type-specific attributes:

| Object | Semantic metadata | Presentation/property data |
|---|---|---|
| Table | ID, caption, label, accessibility summary, notes, provenance | Column widths, alignment, borders, header styling |
| Figure | ID, caption, alt text, asset reference, credit/source | Width, alignment, wrapping, anchor position |
| Asset | Portable package path/URI, media type, content hash | Local source path belongs only in durable state |

This separation matters. Alt text and captions are semantic; width and wrapping are presentation. Profiles should be able to relate richer domain records to a table or figure without changing the core table schema.

### 5. Table preservation policy needs a decision

A current inconsistency: the migration audit maps legacy tables to `authored-preserve`; the full document-model example marks the table, rows and cells as `structural`.

A good contract may be: outer table structure `structural`; caption and cell content authored content; whole-table field envelope either `authored-preserve`, or a structural parent with clearly recoverable authored descendants.

That must be settled before WP4, because it determines whether edits to Word table cells become proposed QMD patches.

## Recommended metadata contract

| Content | QMD authority | Field-code role | Rich catalogue/state |
|---|---|---|---|
| Abstract | YAML/QMD `#abstract` region | Authored section | Document record references region |
| Authors | Standard `author:` and affiliations | Generated author-plate region | Person, organization and contribution records |
| Date/version | Document metadata | Generated spans | Metadata-view binding to document field |
| Version history | Structured YAML records | Generated section/table | Document versionHistory plus view binding |
| Table | QMD table with stable `#tbl-*` ID | Authored/structural table contract | Typed table attributes and relationships |
| Figure | QMD figure with stable `#fig-*` ID | Authored figure | Typed figure attributes plus asset record |
| Caption/alt text | QMD figure/table semantics | Nested caption or figure identity | Semantic node data, not CSS |
| Layout | CSS and typed attributes | Structural where necessary | WP3 property model |

## Conclusion

The field-code direction is correct and appropriately extensible. The weak point is the uncompleted middle layer: the normalized bindings between QMD metadata, semantic objects, generated views and catalogue records.

Add a bounded metadata-binding specification before WP3 implementation. It should resolve:

1. Abstract region references
2. Ordered, document-specific authorship
3. Generated metadata-view bindings
4. Typed table and figure attributes
5. Table/figure preservation and reverse-edit policies
6. The embedded catalogue schema and DOCX carrier

That specification would give WP3 a precise compiler target and WP4 a precise field-code/catalogue rendering contract.
