# Docstyle vNext WP2 package-core design

Date: August 6, 2026

Work package: WP2 — Lua OOXML foundation (production build)

Status: design for review, before implementation planning.

## Context

The WP2 feasibility spike concluded with a **conditional go** (PR #47, issue #31): the Quarto-bundled Pandoc and Lua runtime can support a bounded OOXML read-and-edit seam with no R, no system Lua, no LuaRocks, no native shared library and no external ZIP executable. The spike selected LuaXML plus a Docstyle strictness and byte-span overlay for XML, and a Docstyle central-directory and OPC preflight reader with bounded LibDeflate decompression and the Pandoc ZIP writer for the archive layer. The decision report and its provenance are the record of the spike's results.

The programme specification defines the DOCX backend as two architectural layers. This work package builds the first:

> A package core will provide ZIP parts, content types, namespace-aware XML, relationships, identifiers, atomic writes and preservation of unknown parts.

The spike already implemented and tested every one of those responsibilities as a narrow one-edit seam under `dev/vnext/xml-spike/`. WP2 production promotes that tested code into a real Lua module, hardens it, extends it to the finalization primitives that feature modules will need, and satisfies the performance prerequisite the conditional go was gated on.

## Goals

- Promote the tested spike modules into a production package-core Lua library with no R dependency, isolated from the legacy engine.
- Expose one stable, module-facing public interface that later feature modules (WP4/WP5) and the machine interface (WP7) build on.
- Extend the write interface from the spike's in-place edits to the full package-core responsibility set: add and replace parts, manage relationships (minting relationship ids), register content types, atomic write, preserve unknown parts.
- Support multiple non-overlapping byte-span edits per XML part, with coordinate rebasing.
- Satisfy the conditional-go performance prerequisite: measure representative part sizes, set an explicit XML-part input-byte limit, and reject over-limit parts before parsing.
- Carry over the spike's full gate coverage (archive safety, functional, preservation, safety, determinism, performance) and add coverage for the new finalization primitives.

## Non-goals

These belong to later work packages and are explicitly out of scope here:

- The module registry and capability-profile composition seam, and any feature module (comments, revisions, sections, tables): WP4.
- The DOCX render pipeline and Pandoc-writer integration: WP4.
- The DOCX return path (inventory, reconcile, patch): WP5.
- The source and CSS compiler: WP3.
- The local machine interface (`quarto run docstyle.lua ...`): WP7.
- Part removal from a package: no consumer needs it yet.
- General OOXML identifier allocation beyond relationship ids (drawing `w:docPr`, bookmark and comment ids): deferred to the WP4 feature modules, which define their own id spaces and stability rules. WP1 semantic-region identifiers (`g-<type>-<suffix>`, `regions.json`) are a separate id space and are not a package-core concern.
- A stable public extension interface for third parties: the programme specification defers this until several independently developed modules establish the boundary.

## Scope and approach

Promote and harden (not rewrite). The tested spike modules move by `git mv` into the production tree, preserving history and the passing test evidence, and are then hardened and extended. The production home is:

```
_extensions/docstyle/vnext/package-core/
```

Runtime Lua, loadable by Quarto and by `quarto run` with no R dependency, under a `vnext/` namespace isolated from the legacy `_extensions/docstyle/*.lua` filters. The legacy engine is untouched; WP2 is additive. Legacy retirement is WP8.

## Architecture and module layout

The promoted modules keep their tested internals and take production names:

| Production module | Promoted from | Responsibility |
|---|---|---|
| `zip.lua` | `archive/zip_preflight.lua` | Central-directory and local-header preflight: checked integer arithmetic, ZIP64, entry-name validation, physical-span overlap, central/local name agreement. Fails closed before the package handle is exposed. |
| `inflate.lua` | `archive/inflate_limited.lua` (+ vendored libdeflate) | Bounded decompression that enforces the output cap while decompressing. |
| `entry.lua` | `archive/entry_reader.lua` | CRC-32 and declared-size checked part reads, charged against the per-handle materialization budget. |
| `opc.lua` | `archive/opc.lua` | The package object: parts, content types, relationships, materialization budget, and the atomic-write handle. Extended with the finalization primitives below. |
| `xml.lua` | `candidates/luaxml/{adapter,strictness,token_overlay}.lua` (+ vendored LuaXML) | Namespace-aware, byte-span-preserving XML with the Docstyle strictness overlay. Extended to multiple edits per document. |
| `writer.lua` | `archive/writer.lua` | Deterministic serialization and atomic publication, with the failure-injection seams the spike used for its safe-write tests. |
| `diagnostic.lua` | `lib/diagnostic.lua` | Typed result and error codes. |
| `binary.lua` | `lib/binary.lua` | Byte-level helpers. |

A single `init.lua` composes these modules into the public interface. Feature modules and the machine interface depend only on `init.lua`; they never reach into an internal module. New internal structure must not require edits spread across the core.

## Public interface

The interface extends the spike's real functions. Items marked new are added for production; the rest are promoted as-is.

**Open and inspect**

- `open(path, limits, options) -> package` — preflight the archive and parse OPC metadata, or raise a typed diagnostic. Promoted from `zip_preflight.open_path` composed with OPC parsing.
- `package:inventory()` — new. A read-only view of parts, content types, relationships and unknown parts, for feature modules to plan edits.
- `package:part(name)`, `package:content_type(name)` — promoted.
- `package:relationships(source)` — new. The relationships declared by a source part.
- `package:remaining_materialization_bytes()` — promoted.

**XML edit**

- `xml.parse(bytes, options) -> doc` — promoted; enforces the input-byte limit (see below) before parsing.
- `doc:find_all(ns, local_name)`, `node:get_attribute(ns, local_name)`, `node:set_attribute(ns, local_name, value)`, `node:replace_text(text)` — promoted.
- `xml.serialize(doc) -> bytes` — promoted, extended. Applies multiple non-overlapping byte-span edits collected against the original offsets in one pass, rebasing later offsets for earlier length deltas. Overlapping edits fail closed with a typed diagnostic. Only the exact requested ranges change; all other bytes are preserved verbatim.

**Write and finalize**

- `package:replace_part(name, bytes)` — promoted.
- `package:add_part(name, bytes, content_type)` — new. Adds a new part and registers its content type; fails closed on name collision or ASCII case collision.
- `package:add_relationship(source, type, target, mode) -> rId` — new. Adds a relationship and mints its relationship id (the next free `rIdN` within the source part's rels), returning the id. `mode` distinguishes internal from external targets; external targets are recorded, never fetched. General identifier allocation for other OOXML id spaces is out of scope (see Non-goals).
- `package:write_atomic(path, options)` — promoted. Validates the completed archive, then publishes through a single rename. Unknown parts, entry order and per-entry modification times are preserved; output bytes are deterministic.

**Diagnostics**

- `diagnostic.raise(code, message, context)` and `diagnostic.capture(fn)` — promoted. Codes are namespaced `zip.*`, `opc.*`, `xml.*` and `write.*`. The package core returns structured results and raises typed diagnostics; mapping to the programme's capability and validation result states happens at the feature-module boundary, not inside the core.

## Performance prerequisite

The conditional go is gated on this; it is a first-class deliverable, not documentation.

1. Measure WordprocessingML part sizes across the frozen WP0 characterization corpus. This is broader than the spike's six office fixtures, whose largest observed part was 654,301 bytes.
2. Set an explicit XML-part input-byte limit, reviewed against the measured corpus. The candidate value is 1,048,576 bytes (1 MiB); the review may lower it. The limit is visible configuration in the package core, never hidden.
3. Enforce the limit fail-closed before `xml.parse`: a part larger than the approved limit is rejected with a typed diagnostic and is never parsed. This realizes the `pre_parse_rejection_required` contract recorded in the decision provenance.
4. Record the expected worst-case reference latency at the approved limit (candidate: no more than 0.75 seconds) and re-run the reference benchmark. The retained-heap and both scaling gates remain hard and must still pass; the five-second absolute CPU target remains advisory and is reported, not asserted.

The archive-layer limits the spike tested (compressed-archive, entry-count, per-entry and total uncompressed, ratio and materialization budgets) are promoted unchanged as the starting envelope and may be tuned against a broader corpus independently of the XML-part limit.

## Finalization data flow

```
open(path)
   -> preflight + OPC parse
   -> inspect / read parts (bounded, budget-charged)
   -> edit existing parts:  xml.parse -> [set_attribute | replace_text]* -> xml.serialize
   -> add / replace parts, add relationships (minting relationship ids), register content types
   -> write_atomic:  validate completed archive -> single rename
      (unknown parts, entry order and modtimes preserved; deterministic bytes)
```

Multiple edits to one part are collected as non-overlapping byte-span operations against the original offsets and applied in a single serialize pass. This is the one genuinely new XML behaviour relative to the spike, which tested a single edit per document; the mechanism generalizes by sorting the edit list, rejecting overlaps and accumulating offset shifts.

## Result and error model

Writes are safe by construction: the archive is validated before publication and committed through a single atomic rename, so a partial or failed write never replaces a good destination. The failure-injection seams promoted from the spike writer keep this property under test at each stage (after archive assembly, after close, after verification and before rename). Typed diagnostics carry a stable code and structured context; a caller can distinguish a rejected input from an internal fault.

## Testing and verification

Promote the hermetic Lua harness (`tests/vnext/xml-spike/` to `tests/vnext/package-core/`), preserving every gate the spike already passes: archive, functional (XML), preservation, safety, determinism (fresh-process) and performance. The three real office fixtures and the WP0 corpus remain standing evidence and must not be regenerated to pass a test.

Add coverage for the new work:

- Finalization primitives: `add_part` (including collision and case-collision rejection), `add_relationship` (relationship-id minting, internal and external modes), and `write_atomic` preservation of the added parts alongside unknown parts.
- Multiple non-overlapping edits per part, with byte-exact preservation outside the edited ranges, verified by the independent oracle; overlapping-edit rejection.
- Performance-prerequisite enforcement: a part above the approved limit is rejected before parsing.

Wire the promoted suite into the vNext conformance run so continuous verification exercises it. No R is involved. The R suite remains unaffected.

## Acceptance criteria

1. The package-core modules live under `_extensions/docstyle/vnext/package-core/`, load with no R dependency, and are reachable only through `init.lua`. The legacy engine is unchanged.
2. Every gate the spike passed still passes after promotion.
3. The full finalization primitives (`add_part`, `add_relationship` including relationship-id minting, and multi-edit XML) are implemented, each with tests, and `write_atomic` preserves added parts, unknown parts, entry order and modtimes with deterministic output.
4. The performance prerequisite is satisfied: a reviewed XML-part input-byte limit is set, over-limit parts are rejected before parsing, worst-case latency at the limit is recorded, and the retained-heap and scaling gates still pass.
5. The promoted suite runs in the vNext conformance run with no failures; the WP0 fixtures are unchanged.

## References

- Programme specification: `docs/superpowers/specs/2026-07-12-docstyle-vnext-rebuild-design.md` (backend architecture, Lua-first runtime).
- WP2 feasibility design and amendment: `docs/superpowers/specs/2026-07-16-docstyle-vnext-wp2-ooxml-feasibility-design.md`.
- Decision report and provenance: `dev/vnext/xml-spike/decision-report.md`, `dev/vnext/xml-spike/provenance.json`.
- Work-package tracker: issue #27.
