# Docstyle vNext WP2 OOXML feasibility spike implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Determine whether the Quarto-bundled Pandoc and Lua runtime can safely inspect, modify and republish a bounded subset of WordprocessingML without R, a system Lua installation or a native shared library, then publish a supported go, conditional-go or no-go decision.

**Architecture:** The spike is isolated from the production extension. A pure-Lua archive layer preflights ZIP metadata and bounds actual decompression before it exposes an OPC package handle. Only a passing archive gate unlocks three XML experiments behind one adapter: hardened SLAXML plus a lossless byte-span overlay, a LuaXML adapter and an independently implemented token oracle. Table-driven tests compare candidates on strictness, namespaces, exact edit ranges, preservation and scaling. The selected passing XML candidate is then exercised through a spike-only OPC reader/writer against Word, LibreOffice and adversarial packages.

**Tech stack:** Quarto 1.9.26, Pandoc 3.8.3, embedded Lua 5.4, `pandoc.zip`, pure-Lua candidate code vendored with provenance, XML 1.0 Fifth Edition, Namespaces in XML 1.0 Third Edition, OPC/ECMA-376 and RFC 3986.

**Approved specification:** `docs/superpowers/specs/2026-07-16-docstyle-vnext-wp2-ooxml-feasibility-design.md`

**Tracking:** issue #31; programme issue #27.

## Global constraints

- This plan implements the WP2 feasibility spike only. It does not authorize production OOXML integration, rendering, harvesting, CSS compilation or replacement of the legacy R engine.
- Stage 1 is a hard programme gate. Tasks 4 to 10 must not begin until Tasks 1 to 3 show both metadata preflight and capped actual decompression on the Quarto-only path. If the gate fails, execute the no-go branch in Task 3 and stop.
- The spike runtime is `quarto run`. It must work offline after checkout and must not load R, LuaRocks, a system Lua interpreter, a native shared library or an external ZIP executable.
- Treat OOXML, ZIP metadata, relationships and field instructions as untrusted data. Never execute package content, follow an external relationship target or extract entries to caller-selected paths.
- Namespace identity is `(namespace URI, local name)`. Prefixes are preserved lexical data, not identity.
- Use typed diagnostics with stable codes. Tests assert codes and structured context, not complete prose.
- WP0 fixtures under `tests/vnext/fixtures/` are read-only evidence. Copy them to temporary directories before any mutation.
- Keep all spike-only implementation under `dev/vnext/xml-spike/` and all runner code, fixtures and tests under `tests/vnext/xml-spike/`. Do not modify `_extensions/docstyle/` or production R code.
- Vendor only the files needed by the spike. Record upstream repository, immutable commit, version or tag, licence, source hashes, vendored hashes and local modifications in `dev/vnext/xml-spike/provenance.json`.
- Candidate source retrieval is a contributor-time operation. Runtime tests must verify vendored hashes and must not contact upstream services.
- Do not weaken a hard gate after observing candidate behaviour. Record failure and reject the candidate.
- Use Canadian Press spelling, sentence-case headings and the repository's ASCII ` -- ` convention in prose. Run the writing-style checker on new Markdown.
- Commit locally at each review boundary with plain-text messages and no AI credit. Do not push until Doug reviews the branch. Because `docs/` is ignored as generated pkgdown output, stage this plan and other `docs/superpowers/` files with `git add -f`.
- Baseline before implementation: `PASS 136 | FAIL 0` from the vNext conformance runner and `[ FAIL 0 | WARN 30 | SKIP 4 | PASS 3400 ]` from the full R suite.

---

## File structure

```text
tests/vnext/xml-spike/
  run.lua                         staged runner and summary reporter
  lib/harness.lua                 test registration, gates and typed failures
  lib/fixture.lua                 binary fixture and temporary-path helpers
  tests/test-archive-preflight.lua
  tests/test-inflate-limit.lua
  tests/test-oracle.lua
  tests/test-slaxml-adapter.lua
  tests/test-luaxml-adapter.lua
  tests/test-opc.lua
  tests/test-office-preservation.lua
  tests/test-publication.lua
  tests/test-performance.lua
  tests/test-determinism.lua
  fixtures/xml/cases.lua          authored XML, golden offsets and outcomes
  fixtures/archive/vectors.lua    compact hexadecimal ZIP/DEFLATE vectors
  fixtures/office/metadata.json
  fixtures/office/libreoffice-source.qmd
  fixtures/office/libreoffice-produced.docx
dev/vnext/xml-spike/
  lib/diagnostic.lua              stable codes and context
  lib/binary.lua                  checked unsigned ZIP reads
  archive/zip_preflight.lua       central-directory and physical-span parser
  archive/inflate_limited.lua     capped raw-DEFLATE adapter
  archive/opc.lua                 spike package handle and relationship logic
  archive/writer.lua              deterministic, atomic publication
  archive/vendor/libdeflate/      pinned source, licence and local patch record
  candidates/oracle.lua           independent strict token and semantic oracle
  candidates/common.lua           adapter result types only, no parsing logic
  candidates/slaxml/adapter.lua
  candidates/slaxml/vendor/       pinned SLAXML source and licence
  candidates/luaxml/adapter.lua
  candidates/luaxml/vendor/       minimum pinned LuaXML dependency closure
  provenance.json
  decision-report.md
```

The oracle and candidate adapters may share diagnostic shapes and fixture data. They must not share tokenizer, namespace-stack, entity-decoding or offset-calculation code.

---

### Task 1: Establish the hermetic staged runner and provenance contract

**Files:**
- Create: `tests/vnext/xml-spike/run.lua`
- Create: `tests/vnext/xml-spike/lib/harness.lua`
- Create: `tests/vnext/xml-spike/lib/fixture.lua`
- Create: `tests/vnext/xml-spike/tests/test-runner.lua`
- Create: `dev/vnext/xml-spike/lib/diagnostic.lua`
- Create: `dev/vnext/xml-spike/provenance.json`

**Interfaces:**
- `harness.case(group, name, fn, options)` registers a case. `options.gate` is one of `archive`, `functional`, `preservation`, `safety`, `determinism` or `performance`.
- `harness.run(stage)` returns per-gate pass/fail/skip counts and exits non-zero when any executed hard gate fails.
- `diagnostic.raise(code, message, context)` raises `{docstyle_diagnostic=true, code=..., message=..., context=...}`.
- `diagnostic.capture(fn)` returns `ok, value_or_diagnostic` and preserves stable codes.

- [x] **Step 1: Write the runner tests first**

Cover: non-zero discovery, stable alphabetical test order, all six summary groups, duplicate case-name rejection, structured diagnostic capture, a non-zero exit on failure and stage filtering. Stage values are `archive`, `xml`, `package` and `all`; later stages include earlier gates.

- [x] **Step 2: Implement the runner**

`run.lua` must set `package.path` explicitly from `PANDOC_SCRIPT_FILE`, without consulting environment paths:

```lua
local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local root = pandoc.path.normalize(pandoc.path.join({ here, "..", "..", ".." }))
package.path = table.concat({
  here .. "/?.lua",
  here .. "/?/init.lua",
  root .. "/dev/vnext/xml-spike/?.lua",
  root .. "/dev/vnext/xml-spike/?/init.lua",
}, ";")

local harness = require("lib.harness")
local stage, options = harness.runner_options(os.getenv)
harness.discover_and_run(here, stage, options)
```

Do not append the ambient `package.path`. The canonical command runs stage `all`. Developer-only stage values `archive`, `xml`, `package` and `all` are selected with `DOCSTYLE_SPIKE_STAGE`; reference performance is enabled with `DOCSTYLE_SPIKE_REFERENCE_PERFORMANCE=1`. Quarto 1.9.26 forwards extra Lua-script arguments to Pandoc as input filenames, so the runner does not use positional arguments. The runner prints one line per gate and a final `PASS n | FAIL n | SKIP n`; it fails if discovery count is zero.

- [x] **Step 3: Add a complete provenance schema instance**

Create a JSON object with `runtime`, `candidates`, `fixtures` and `local_modifications` arrays. Initial runtime fields are populated by `quarto --version`, `quarto pandoc --version`, `uname -srm` and Lua `_VERSION`. Candidate rows may be added only in the commit that vendors their source. No row may contain an unresolved marker, an empty commit or an unverified hash.

- [x] **Step 4: Verify the hermetic runner**

Run:

```bash
env -i PATH="$PATH" HOME="$(mktemp -d)" DOCSTYLE_SPIKE_STAGE=archive quarto run tests/vnext/xml-spike/run.lua
```

Expected: non-zero test count, runner self-tests pass, no network access and `PASS n | FAIL 0 | SKIP 0`.

- [x] **Step 5: Commit**

```bash
git add tests/vnext/xml-spike dev/vnext/xml-spike/lib dev/vnext/xml-spike/provenance.json
git commit -m "Add hermetic WP2 spike runner and provenance contract

Relates to #31"
```

---

### Task 2: Implement ZIP metadata preflight and physical-span validation

**Files:**
- Create: `dev/vnext/xml-spike/lib/binary.lua`
- Create: `dev/vnext/xml-spike/archive/zip_preflight.lua`
- Create: `tests/vnext/xml-spike/fixtures/archive/vectors.lua`
- Create: `tests/vnext/xml-spike/tests/test-archive-preflight.lua`

**Interfaces:**
- `binary.u16le(bytes, offset)`, `u32le` and `u64le` return exact non-negative Lua integers or raise `zip.integer-overflow`/`zip.truncated`.
- `zip_preflight.open_path(path, limits)` checks file size before reading and returns immutable metadata only after every entry and span validates.
- Metadata rows contain exact central and local names, flags, method, CRC-32, compressed and declared uncompressed sizes, local-header offset, compressed-data offset, descriptor length and complete half-open local-entry span.

- [x] **Step 1: Create deterministic binary-vector helpers and failing tests**

Build compact archives in Lua from explicit little-endian fields. Do not invoke `zip`, Python or R. Cases must cover:

- EOCD search bounded to the maximum comment length;
- empty, stored and deflated entries;
- data descriptors with and without the optional signature;
- ZIP64 sizes and offsets;
- multi-disk rejection;
- truncated and overflowing integer fields;
- compressed archive bytes, entry count, per-entry size, total declared size and compression-ratio limits, including exact inclusive boundaries;
- encrypted and symlink entries;
- duplicate exact names and ASCII case-colliding names;
- absolute, drive-letter, backslash, NUL, empty-segment, `.` and `..` names;
- the `[Content_Types].xml` metadata exception and valid ordinary OPC part names;
- central-directory/local-header name disagreement for requested and unrequested entries;
- duplicate local-header offsets, pairwise local-entry overlap and spans entering central-directory, ZIP64 or EOCD metadata.

Each failure asserts a stable code and, where available, entry name and byte offset. Include a quadratic-regression fixture with 2,000 empty entries; validation must sort spans once and compare adjacent ranges rather than compare every pair.

- [x] **Step 2: Implement checked ZIP parsing**

Parse EOCD and ZIP64 records before constructing any `pandoc.zip` object. Reject unsupported methods other than stored (`0`) and deflate (`8`). Use checked addition before every `offset + length`; never allow a floating-point approximation. Validate every central row against its local header before returning metadata.

Sort complete local-entry spans by start offset and reject a span when `current.start < previous.finish`. Independently require every span to end at or before `central_directory.start`. Central-directory, ZIP64 and EOCD metadata ranges must be non-overlapping and fully in bounds.

- [x] **Step 3: Show that preflight precedes the backend**

Instrument the archive constructor in the test harness. For every malformed vector, assert that the constructor call count remains zero. For a valid archive, assert exactly one constructor call after all-entry validation.

- [x] **Step 4: Run the archive metadata gate**

Run: `DOCSTYLE_SPIKE_STAGE=archive quarto run tests/vnext/xml-spike/run.lua`

Expected: all preflight tests pass; decompression tests from Task 3 are still absent, so the archive stage is not yet declared passed in the decision report.

- [x] **Step 5: Commit**

```bash
git add dev/vnext/xml-spike/lib/binary.lua dev/vnext/xml-spike/archive/zip_preflight.lua tests/vnext/xml-spike
git commit -m "Add bounded ZIP metadata preflight for the WP2 spike

Relates to #31"
```

---

### Task 3: Establish capped actual decompression and close the stage 1 gate

**Files:**
- Create: `dev/vnext/xml-spike/archive/inflate_limited.lua`
- Create: `dev/vnext/xml-spike/archive/vendor/libdeflate/LibDeflate.lua`
- Create: `dev/vnext/xml-spike/archive/vendor/libdeflate/LICENSE.txt`
- Create: `dev/vnext/xml-spike/archive/vendor/libdeflate/PROVENANCE.md`
- Create: `dev/vnext/xml-spike/archive/vendor/libdeflate/LOCAL-CHANGES.md`
- Create: `tests/vnext/xml-spike/tests/test-inflate-limit.lua`
- Modify: `dev/vnext/xml-spike/provenance.json`
- Create only on gate failure: `dev/vnext/xml-spike/decision-report.md`

**Interfaces:**
- `inflate_limited.inflate_raw(compressed, limit, emit)` decodes raw RFC 1951 stored, fixed-Huffman and dynamic-Huffman blocks.
- It checks `produced + next_chunk_bytes <= limit` before constructing or emitting the next chunk, retains no more than the 32 KiB DEFLATE history window plus bounded output chunks and returns the exact produced byte count.
- `emit(chunk)` is called only after the budget check. An omitted `emit` collects output for ordinary package reads.

- [ ] **Step 1: Vendor and verify the decompressor candidate**

Vendor only upstream LibDeflate 1.0.2 source and licence at an immutable commit. Record the upstream and vendored SHA-256 values. The upstream `DecompressDeflate` API materializes a complete string and therefore is not itself acceptable for untrusted package reads; `LOCAL-CHANGES.md` must explain the bounded sink adaptation and link each changed internal routine to its test.

- [ ] **Step 2: Write cap tests before adapting the code**

Use fixed checked-in hexadecimal vectors for stored, fixed and dynamic blocks, plus malformed Huffman trees, impossible distances, truncated streams and trailing data. Generate a high-ratio stream during the test from a small checked-in vector rather than committing a large expanded artifact.

For every block type, exercise limits `0`, `expected_length - 1`, `expected_length` and `expected_length + 1`. On limit failure, assert:

- code `zip.output-limit`;
- `emit` never observes bytes beyond the limit;
- no complete expanded result exists;
- retained Lua heap after collection stays below `limit + 2 MiB` for the deliberately small gate vector.

Also add a backend probe showing that `pandoc.zip.Entry:contents()` returns the full expanded bytes and cannot accept an enforceable output cap. Record that as evidence, not as the selected read path.

- [ ] **Step 3: Adapt the decoder to a bounded sink**

Keep a circular 32 KiB history window. Split back-references into chunks no larger than 8 KiB and check budget before copying. Reject a distance greater than produced history and reject output-length arithmetic that cannot remain an exact Lua integer. The wrapper must never call upstream `DecompressDeflate`.

- [ ] **Step 4: Integrate the read gate with preflight metadata**

For stored entries, compare the compressed length with the declared uncompressed length and budget before slicing bytes. For deflated entries, pass both the per-entry remaining limit and the package-handle remaining limit to `inflate_raw`; use the smaller limit. Verify produced length against the central-directory declaration and record CRC-32 agreement as evidence.

- [ ] **Step 5: Execute the formal gate decision**

Run:

```bash
DOCSTYLE_SPIKE_STAGE=archive quarto run tests/vnext/xml-spike/run.lua
```

Pass requires: safe metadata preflight, no backend call before validation, capped stored and deflated output, and no allocation or emit beyond the configured cap.

If any requirement cannot be supported on the Quarto-only path, stop. Write `dev/vnext/xml-spike/decision-report.md` with runtime evidence, failed gate, attempted bounded layer, residual risk and a `no-go` recommendation; run the style checker and regression commands from Task 10; then request review. Do not execute Tasks 4 to 10 except the no-go verification portions of Task 10.

- [ ] **Step 6: Commit the gate result**

```bash
git add dev/vnext/xml-spike tests/vnext/xml-spike
git commit -m "Complete the WP2 archive safety gate

Relates to #31"
```

---

### Task 4: Build the independent XML oracle and shared fixture table

**Precondition:** Task 3 passed.

**Files:**
- Create: `dev/vnext/xml-spike/candidates/common.lua`
- Create: `dev/vnext/xml-spike/candidates/oracle.lua`
- Create: `tests/vnext/xml-spike/fixtures/xml/cases.lua`
- Create: `tests/vnext/xml-spike/tests/test-oracle.lua`

**Interfaces:**
- `oracle.parse(bytes, options)` produces an independent semantic event stream, namespace bindings and raw token coordinates.
- `oracle.verify_edit(original, edited, golden_range, expected_change)` first checks exact range equality, then outside-range byte identity, then independently reparses both complete parts and compares all namespace bindings, expanded names and decoded values except the declared change.
- Golden ranges are literal half-open offsets stored in fixture rows or emitted by the fixture generator before candidate parsing.

- [ ] **Step 1: Author the fixture matrix and golden coordinates**

Table rows must identify encoding, expected diagnostic or semantic events, mutation operation, selected expanded name, replacement value and exact original byte range. Include UTF-8, UTF-16LE and UTF-16BE with and without BOM where legal; surrogate pairs; contradictory declarations; namespace shadowing; default namespaces; prefixed attributes; all predefined and numeric entities; both attribute quote styles; comments; processing instructions; CDATA; whitespace-only text; `xml:space="preserve"`; Microsoft compatibility markup; unknown elements and attributes.

Include every rejection class named in the approved specification: unsupported version, multiple roots, mismatched/unclosed elements, invalid names and characters, bad namespace bindings, duplicate expanded-name attributes, malformed declarations/comments/CDATA/PIs/references, PI target `xml` in mixed case, `DOCTYPE`, custom/external entities and every parse-limit boundary.

- [ ] **Step 2: Write oracle tests independent of candidate code**

Assert literal golden offsets before any outside-byte comparison. Test that CR in attribute and ordinary text replacements survives semantic reparse as the requested value. Test that a wider or narrower candidate-reported range fails even when outside bytes would otherwise compare equal.

- [ ] **Step 3: Implement the narrow oracle**

Implement a forward byte scanner, separate namespace stack and separate entity decoder. It may support only the spike operations, but it must strictly reject the complete accepted-language boundary in the fixture table. Do not import SLAXML, LuaXML or their adapter helpers.

For UTF-16, maintain a code-point-to-original-byte map that includes BOM and surrogate pairs; reported offsets always address original encoded bytes. Re-encode replacement text into the original encoding and preserve BOM and declaration.

- [ ] **Step 4: Run and commit**

```bash
DOCSTYLE_SPIKE_STAGE=xml quarto run tests/vnext/xml-spike/run.lua
git add dev/vnext/xml-spike/candidates tests/vnext/xml-spike
git commit -m "Add independent XML oracle and conformance fixtures

Relates to #31"
```

Expected at this boundary: oracle cases pass; the runner reports candidate gates as not yet executed, not silently passed.

---

### Task 5: Adapt and harden SLAXML as Approach A

**Files:**
- Create: `dev/vnext/xml-spike/candidates/slaxml/adapter.lua`
- Create: `dev/vnext/xml-spike/candidates/slaxml/token_overlay.lua`
- Create: `dev/vnext/xml-spike/candidates/slaxml/strictness.lua`
- Create: `dev/vnext/xml-spike/candidates/slaxml/vendor/slaxml.lua`
- Create: `dev/vnext/xml-spike/candidates/slaxml/vendor/LICENSE.txt`
- Create: `dev/vnext/xml-spike/candidates/slaxml/vendor/PROVENANCE.md`
- Create: `tests/vnext/xml-spike/tests/test-slaxml-adapter.lua`
- Modify: `dev/vnext/xml-spike/provenance.json`

**Interfaces:** Implement exactly:

```lua
document = adapter.parse(xml_bytes, options)
nodes = adapter.find_all(document, namespace_uri, local_name)
value = adapter.get_attribute(nodes[1], namespace_uri, local_name)
adapter.set_attribute(nodes[1], namespace_uri, local_name, new_value)
adapter.replace_text(nodes[1], new_text)
xml_bytes, edit_ranges = adapter.serialize(document)
```

- [ ] **Step 1: Vendor the minimum immutable SLAXML source**

Pin the reviewed v0.8-series commit, licence and hashes. Do not vendor its test directory or serializer. Record its documented well-formedness, declaration, Unicode-name, charset and namespace-serialization limitations in provenance.

- [ ] **Step 2: Run the shared fixture table as failing adapter tests**

The adapter test module iterates the same rows as Task 4. It must not copy expected values into candidate-specific tests. Every edit is verified by `oracle.verify_edit`; the adapter's own parser is never the sole semantic judge.

- [ ] **Step 3: Add the strictness and byte-span overlay**

SLAXML supplies semantic events only. The Docstyle overlay records exact original spans and enforces hierarchy, declarations, entity syntax, XML names, namespace bindings, duplicate expanded-name attributes and all parse limits before returning a document. Candidate serialization concatenates untouched source spans with one deterministically escaped replacement span; it never invokes SLAXML's DOM serializer.

Attribute replacement preserves quote delimiter and writes tab, line feed and carriage return as numeric references. Ordinary text replacement writes carriage return as `&#xD;` and escapes any `>` needed to avoid `]]>`.

- [ ] **Step 4: Measure candidate-specific maintenance evidence**

Record vendored lines, Docstyle-owned adapter/strictness/overlay lines, dependency count, unsupported constructs and all rejected fixture rows in a machine-readable result returned by the runner.

- [ ] **Step 5: Run and commit**

```bash
DOCSTYLE_SPIKE_STAGE=xml quarto run tests/vnext/xml-spike/run.lua
git add dev/vnext/xml-spike/candidates/slaxml dev/vnext/xml-spike/provenance.json tests/vnext/xml-spike
git commit -m "Evaluate hardened SLAXML for bounded OOXML edits

Relates to #31"
```

Continue to Task 6 even if Approach A fails; the comparison is required.

---

### Task 6: Adapt LuaXML as Approach B and select the leading XML candidate

**Files:**
- Create: `dev/vnext/xml-spike/candidates/luaxml/adapter.lua`
- Create: `dev/vnext/xml-spike/candidates/luaxml/vendor/` minimum dependency files
- Create: `dev/vnext/xml-spike/candidates/luaxml/vendor/LICENSE`
- Create: `dev/vnext/xml-spike/candidates/luaxml/vendor/PROVENANCE.md`
- Create: `tests/vnext/xml-spike/tests/test-luaxml-adapter.lua`
- Modify: `dev/vnext/xml-spike/provenance.json`

- [ ] **Step 1: Establish the exact dependency and licence closure before code**

Starting from the immutable LuaXML commit, trace every `require` used by the minimum XML parse path. Vendor only that closure. Record the Lua, MIT and modified-BSD licence boundaries file by file. If the minimum parse path requires LuaTeX globals, native modules or an unavailable dependency, keep the executable failure evidence, reject Approach B and do not shim the missing runtime silently.

- [ ] **Step 2: Run the same adapter table first**

Use the exact interface and Task 4 fixture rows. Candidate-specific code may translate LuaXML nodes into the adapter's node handles but may not relax expected outcomes. Every successful edit goes through the independent oracle.

- [ ] **Step 3: Implement only bounded compatibility code**

Do not import CSS, XPath, HTML or template modules. If LuaXML serializes the whole tree or loses lexical bytes, the adapter may add an independent byte-span overlay, but that Docstyle-owned code counts in the maintenance comparison and must not reuse the Task 4 oracle.

- [ ] **Step 4: Apply the selection rule**

Reject every candidate with an applicable hard-gate failure. If neither A nor B passes, update the decision report to `no-go`, run regression verification and stop. If one or both pass, select the candidate with the lower supported maintenance risk; record the reasons and omit a numeric score. Approach C remains an oracle unless it independently passes the entire adapter table.

- [ ] **Step 5: Run and commit**

```bash
DOCSTYLE_SPIKE_STAGE=xml quarto run tests/vnext/xml-spike/run.lua
git add dev/vnext/xml-spike/candidates/luaxml dev/vnext/xml-spike/provenance.json tests/vnext/xml-spike
git commit -m "Compare LuaXML through the WP2 adapter contract

Relates to #31"
```

---

### Task 7: Implement the spike-only OPC package seam

**Precondition:** A selected XML candidate passes Tasks 4 to 6.

**Files:**
- Create: `dev/vnext/xml-spike/archive/opc.lua`
- Create: `tests/vnext/xml-spike/tests/test-opc.lua`
- Extend: `tests/vnext/xml-spike/fixtures/archive/vectors.lua`

**Interfaces:**

```lua
pkg = opc.open_path(docx_path, limits)
bytes = pkg:part(part_name)
pkg:replace_part(part_name, bytes)
relationships = pkg:relationships(source_part)
pkg:write_atomic(output_path, options)
```

- [ ] **Step 1: Write package-handle and budget tests**

Assert invalid/non-integral/overflowing limits fail before archive processing. The handle tracks a cumulative materialization budget. Choose and document cache semantics: successful `part()` reads cache immutable bytes and charge once; repeated reads return the cached value without a second charge. Failed reads do not populate the cache. A request that would exceed the remaining budget fails before output exceeds it.

- [ ] **Step 2: Write path, content-type and root tests**

Validate slash-prefixed part names without URI decoding, map them to ZIP names by removing exactly one leading slash and use byte-exact lookup after rejecting ASCII case collisions. Parse `[Content_Types].xml`, `_rels/.rels` and part relationships with the selected XML adapter. Verify unique relationship IDs, one unambiguous office-document root, `word/document.xml` and `docProps/core.xml` traversal.

- [ ] **Step 3: Implement bounded RFC 3986 relationship handling**

Parse target segments before decoding. Reject malformed encodings, encoded separators, encoded dot segments, encoded NUL/control bytes, schemes, authorities and queries. Normalize retained hex to uppercase and decode only unreserved characters. Remove the fragment before lookup while recording it in the relationship result. Resolve literal `..` relative to the source and fail on package escape. Record but never fetch `TargetMode="External"`; missing mode means internal and other values fail closed.

Executable cases include `media/My%20Image.png`, `%7E`, `%2F`, `%2E%2E`, mixed-case hex, literal `../`, case-variant stored names and external relative targets.

- [ ] **Step 4: Bind validated metadata to bounded content retrieval**

The handle reads only compressed byte ranges identified by `zip_preflight`; it never asks `pandoc.zip` to decompress untrusted entry contents. Verify produced size and record CRC-32 agreement. Preserve unknown entries in the package inventory even when never requested.

- [ ] **Step 5: Run and commit**

```bash
DOCSTYLE_SPIKE_STAGE=package quarto run tests/vnext/xml-spike/run.lua
git add dev/vnext/xml-spike/archive/opc.lua tests/vnext/xml-spike
git commit -m "Add the spike-only bounded OPC package seam

Relates to #31"
```

---

### Task 8: Add office evidence and deterministic atomic publication

**Files:**
- Create: `dev/vnext/xml-spike/archive/writer.lua`
- Create: `tests/vnext/xml-spike/fixtures/office/libreoffice-source.qmd`
- Create: `tests/vnext/xml-spike/fixtures/office/libreoffice-produced.docx`
- Create: `tests/vnext/xml-spike/fixtures/office/metadata.json`
- Create: `tests/vnext/xml-spike/tests/test-office-preservation.lua`
- Create: `tests/vnext/xml-spike/tests/test-publication.lua`
- Modify: `dev/vnext/xml-spike/provenance.json`

- [ ] **Step 1: Produce and document the LibreOffice fixture**

The source contains a heading, body paragraph, list, table, internal and external hyperlinks, header or footer and section break. Render locally, open and save through LibreOffice, then record source licence, source hash, output hash, `soffice --version`, generation commands and expected constructs. Comment retention is descriptive evidence and does not determine the gate. Keep the DOCX small and free of personal data.

- [ ] **Step 2: Exercise Word and LibreOffice preservation**

Copy repository fixtures to temporary directories. Test native comments and relationships, section properties, headers/footers/page fields, revisions, DOCSTYLE/Zotero field instructions, compatibility namespaces and unknown attributes. Make one permitted existing-attribute or sole-ordinary-text edit per run. Assert untouched entries have identical uncompressed bytes and edited parts satisfy the independent full-part oracle.

- [ ] **Step 3: Implement deterministic writing**

Preserve existing entry order, uncompressed bytes and modification times. Changed existing entries retain original modification times. Append new entries in bytewise name order with ZIP epoch `1980-01-01T00:00:00`. Fix compression settings where `pandoc.zip` exposes them.

Reserve a collision-resistant temporary directory in the destination directory with an atomic `pandoc.system.make_directory(candidate, false)` call; the bundled runtime raises `File exists` on a collision. Derive only the random basename from `os.tmpname()`, remove the operating-system temporary entry, prefix the basename with `.docstyle-`, and retry directory reservation on collision. Build and close the archive inside the reserved directory. Reopen the completed temporary package through `opc.open_path`, run the same limits and relationship checks, then use `os.rename` as the single replacement point. Always remove the reserved directory. A simulated failure immediately before rename must leave an existing destination byte-identical and no temporary artifact behind.

- [ ] **Step 4: Test write failure and unknown-part preservation**

Inject failures after archive construction, after close, after verification and immediately before rename. Verify the destination and cleanup at every point. Verify initially unrequested unknown entries are republished and preserve uncompressed bytes.

- [ ] **Step 5: Run and commit**

```bash
DOCSTYLE_SPIKE_STAGE=package quarto run tests/vnext/xml-spike/run.lua
git add dev/vnext/xml-spike/archive/writer.lua dev/vnext/xml-spike/provenance.json tests/vnext/xml-spike
git commit -m "Add office preservation and atomic publication evidence

Relates to #31"
```

---

### Task 9: Measure fresh-process determinism and scaling

**Files:**
- Create: `tests/vnext/xml-spike/tests/test-performance.lua`
- Create: `tests/vnext/xml-spike/tests/test-determinism.lua`
- Create: `tests/vnext/xml-spike/lib/child.lua`
- Create: `dev/vnext/xml-spike/performance-results.json`
- Create: `dev/vnext/xml-spike/determinism-results.json`

- [ ] **Step 1: Generate independent scaling fixtures**

Generate one, five and 10 MiB XML parts with representative `w:p`, `w:r`, `w:t`, attributes and namespace declarations. The generator computes the planted edit coordinates as it emits source bytes; it must not call any candidate parser or search the completed XML for the target.

- [ ] **Step 2: Implement the measurement protocol exactly**

Run one unreported warm-up and five repetitions per size. Use `pandoc.system.cputime()` around parse, one edit and serialization separately and report median combined CPU time. Force collection before baseline and after each phase; report the maximum retained Lua heap delta as `max(0, observed_kib - initial_kib) * 1024`. Label it retained Lua heap, never peak memory.

Record Quarto, Pandoc, Lua, operating system, architecture, Mac model, processor and installed memory. Do not make performance thresholds ordinary CI assertions; enable them with `DOCSTYLE_SPIKE_REFERENCE_PERFORMANCE=1` on the recorded reference Mac.

- [ ] **Step 3: Run ten genuinely fresh publication processes**

`child.lua` performs the same XML edit and package write from identical source bytes, then prints JSON containing edited-part SHA-256, ordered entry names and whole-archive SHA-256. The parent invokes `quarto run` ten times with separate temporary output paths and compares all three fields. It must not call the child module ten times in one Lua VM.

- [ ] **Step 4: Apply the gates**

On the reference environment, the 10 MiB median combined CPU time is at most five seconds, maximum retained Lua heap delta is at most 12 times input bytes, and both 10 MiB measures are at most 15 times the one MiB results. Every edited range must still equal the generator's independent golden coordinates.

- [ ] **Step 5: Run and commit**

```bash
quarto run tests/vnext/xml-spike/run.lua
DOCSTYLE_SPIKE_REFERENCE_PERFORMANCE=1 quarto run tests/vnext/xml-spike/run.lua
git add tests/vnext/xml-spike dev/vnext/xml-spike/performance-results.json dev/vnext/xml-spike/determinism-results.json
git commit -m "Record WP2 determinism and scaling evidence

Relates to #31"
```

---

### Task 10: Publish the supported decision and complete regression verification

**Files:**
- Create or complete: `dev/vnext/xml-spike/decision-report.md`
- Modify only if results changed: `dev/vnext/xml-spike/provenance.json`

- [ ] **Step 1: Write the candidate comparison**

For archive layer, Approach A, Approach B and the oracle, report runtime/dependency closure, licence/provenance, strictness, namespace correctness, byte preservation, determinism, archive safety, office results, CPU/heap evidence, vendored and Docstyle-owned lines and residual limitations. Explain each rejection and the maintenance-risk judgement. Do not collapse the evidence into an arbitrary score.

- [ ] **Step 2: State exactly one decision**

Use `go`, `conditional go` or `no-go` for the bounded read, existing-attribute update and sole-ordinary-text replacement seam. A conditional prerequisite must be concrete and testable and cannot defer a security, preservation, namespace or determinism failure. Record the case-sensitive-lookup spike restriction and whether office fixtures actually contain URI-encoded relationship targets.

- [ ] **Step 3: Audit all 12 acceptance tests**

Add a table mapping every specification acceptance test to commands, test cases and evidence files. A stage-1 no-go maps only the executable archive evidence, supported report and regression checks, as authorized by the specification. Search for unresolved placeholders:

```bash
rg -n 'TB[D]|TO[D]|FIXM[E]|PLACEHOLDE[R]|X{2,}' dev/vnext/xml-spike tests/vnext/xml-spike
```

Expected: no matches.

- [ ] **Step 4: Run final verification**

```bash
quarto run tests/vnext/xml-spike/run.lua
quarto run tests/vnext/conformance/run.lua
env R_PROFILE_USER=/dev/null Rscript -e 'devtools::test(stop_on_failure = TRUE)'
git diff --exit-code main -- tests/vnext/fixtures/
python3 ~/github/ai-infrastructure/skills/writing-style/scripts/check_style.py dev/vnext/xml-spike/decision-report.md
git diff --check
```

Expected on the current baseline: spike runner `FAIL 0`; conformance `PASS 136 | FAIL 0`; R suite `[ FAIL 0 | WARN 30 | SKIP 4 | PASS 3400 ]`; no WP0 fixture changes; style and whitespace checks pass.

- [ ] **Step 5: Review the decision boundary before committing**

Verify no candidate code entered `_extensions/docstyle/` or production R. Verify the report does not authorize production integration. A go or conditional go leads to a separate production WP2 plan and review; a no-go returns to programme architecture.

- [ ] **Step 6: Commit**

```bash
git add dev/vnext/xml-spike tests/vnext/xml-spike
git commit -m "Publish the WP2 OOXML feasibility decision

Closes #31"
```

Do not push. Request independent review of the evidence, decision report and branch diff before issue closure or any production plan.

---

## Completion checklist

1. Stage 1 archive gate shows metadata preflight and capped actual decompression, or the reviewed no-go branch stops the spike -- Tasks 1 to 3.
2. At least two adapters run the same XML table -- Tasks 5 and 6.
3. An independent oracle verifies exact ranges and complete-part semantics -- Task 4.
4. All XML rejection, namespace, encoding and replacement cases are executable -- Tasks 4 to 6.
5. Unknown Word and LibreOffice constructs survive tested edits -- Task 8.
6. Archive names, physical spans, encryption, symlinks, limits and budgets fail closed before handle exposure or unsafe output -- Tasks 2, 3 and 7.
7. Internal and external relationship rules are executable -- Task 7.
8. Ten fresh processes produce identical edited XML, entry order and archive hash -- Task 9.
9. Simulated pre-rename failure preserves the prior destination -- Task 8.
10. Reference scaling and retained-heap gates are measured -- Task 9.
11. Offline spike, conformance and legacy regression suites pass -- Tasks 1 and 10.
12. The report contains one supported decision with no placeholders -- Task 10.

After the plan is reviewed, execute it in the isolated `codex/vnext-wp2-plan` worktree. Treat completion of Task 3 as the first mandatory human review checkpoint before broader XML work.
