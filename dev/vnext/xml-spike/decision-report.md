# Docstyle vNext WP2 OOXML feasibility decision

Date: July 29, 2026

Decision: **conditional go**

## Bottom line

The Quarto-bundled Pandoc and Lua runtime can support the bounded seam tested
by this spike without R, Python, a system Lua interpreter, LuaRocks, a native
shared library or an external ZIP executable in production. The selected XML
path is the pinned LuaXML structural tokenizer combined with Docstyle-owned
XML strictness, namespace and byte-span layers. The package path combines a
Docstyle central-directory and OPC preflight reader, bounded LibDeflate
decompression and the Pandoc ZIP writer.

The supported seam is deliberately narrow:

- inspect a preflighted DOCX package;
- read validated OPC metadata and bounded parts;
- update one existing XML attribute or replace the sole ordinary-text content
  of one element;
- preserve all bytes outside the exact independently verified edit range;
- preserve unknown entries, entry order and per-entry modification times; and
- publish through a completed-output revalidation and a single atomic rename.

This is not approval to integrate the spike code into production. Production
integration requires a separate plan and review. It is also conditional on the
performance prerequisite in this report.

## Decision boundary

LuaXML passes every applicable security, XML strictness, namespace,
preservation, determinism, retained-heap and scaling gate. SLAXML does not:
its backend rejects legal Unicode element, attribute and processing-instruction
names. The independent oracle is a judge rather than a production candidate.
The archive and publication layers pass their gates.

The decision is therefore a conditional go for LuaXML and the bounded archive
seam. It is not a general-purpose XML editor, a general OPC implementation or
an approval to replace Docstyle's existing production engine.

## Transparent performance amendment

Task 9 ran under the original specification, which treated four reference
performance thresholds as hard gates. The 10 MiB median combined CPU time was
5.274299 seconds against a five-second threshold. Task 9 therefore remains
recorded as `fail` in `performance-results.json` and `provenance.json`. The
five-second target was not met.

On July 27, 2026, the project owner approved a post-result amendment that
reclassified only the five-second absolute CPU threshold as advisory. This
report does not reinterpret the measured value as a pass. The rationale is
that absolute time on one reference Mac is less generalizable than resource
growth. The following three performance requirements remain binding and pass:

| Requirement | Result | Limit | Status |
|---|---:|---:|---|
| 10 MiB retained Lua heap delta | 35,144,865 bytes, or 3.352 times input | No more than 12 times input | Pass |
| 10 MiB to one MiB CPU ratio | 10.128 | No more than 15 | Pass |
| 10 MiB to one MiB retained-heap ratio | 9.987 | No more than 15 | Pass |
| 10 MiB combined CPU time | 5.274299 seconds | Advisory target of five seconds | Not met |

The 10 MiB measurement is parse-dominated. In the median-defining repetition,
parsing used 5.270297 of 5.274299 CPU seconds, or 99.92 per cent. Editing and
serialization together used about four milliseconds.

The Task 10 verification repeated the full reference protocol. Its 10 MiB
median was 5.117641 seconds: the advisory target was again not met, while all
three binding performance gates passed and the reference suite reported
`PASS 452 | FAIL 0 | SKIP 0`.

The reference environment for the recorded July 29 measurements was Quarto
1.9.26, Pandoc 3.8.3 and Lua 5.4 on macOS 26.5.2, arm64, on a 10-core Apple
M1 Max MacBook Pro with 64 GiB of installed memory. The reported memory
measure is retained Lua heap observed after collection at phase boundaries,
not peak process memory.

## Production performance prerequisite

Before production integration, the production implementation branch must:

1. repeat the reference benchmark without weakening the retained-heap or
   scaling gates;
2. measure the parse-dominated cost on representative WordprocessingML parts;
3. review and approve a production XML-part size limit;
4. record the expected worst-case latency at that approved limit; and
5. make the limit explicit and fail closed before calling the XML adapter.

Six Word, Docstyle and LibreOffice fixtures were inspected for this decision:

| Fixture | Archive bytes | Entries | Largest Word XML part |
|---|---:|---:|---:|
| Word native comments | 180,739 | 31 | 654,301 bytes |
| Word page fields | 24,139 | 18 | 52,982 bytes |
| Docstyle POPCORN baseline | 10,564 | 17 | 21,784 bytes |
| Docstyle DemPoRT baseline | 10,631 | 17 | 22,241 bytes |
| Docstyle independent manuscript | 15,580 | 19 | 23,278 bytes |
| LibreOffice output | 10,311 | 15 | 11,474 bytes |

The largest observed WordprocessingML part is 654,301 bytes. The one MiB
synthetic case measured a 0.520740-second median and a 0.524631-second maximum
across five repetitions. The production plan should begin with a candidate
XML-part input-byte limit of 1,048,576 bytes and a candidate reference-CPU
expectation
of no more than 0.75 seconds at that limit. These are proposed review values,
not approved production defaults. The prerequisite remains open until a fresh
benchmark supports them on the production branch.

The archive layer has separately shown enforceable inclusive limits.
For production planning, the spike's tested envelope is a conservative
starting ceiling: 128 MiB compressed archive, 10,000 entries, 128 MiB per
declared uncompressed entry, 512 MiB total declared uncompressed bytes, a
1,000:1 declared compression ratio and a 256 MiB materialization budget.
These values are not production defaults. The production plan should validate
them against a broader document corpus and may lower them independently of the
stricter XML-part input-byte limit.

## Candidate comparison

| Component | Runtime and provenance | Correctness and preservation | Maintenance evidence | Decision |
|---|---|---|---|---|
| Archive and OPC layer | Quarto/Pandoc embedded Lua; pinned LibDeflate 1.0.2-release under the zlib licence; Pandoc ZIP writer from the bundled GPL-2.0-or-later runtime | Passes bounded preflight and decompression, CRC and size checks, cumulative budgets, path and collision checks, relationship rules, unknown-part preservation, completed-output validation and atomic publication | 1,803 Docstyle-owned archive lines plus 3,853 vendored LibDeflate lines; the bounded decoder is a documented local modification | Select for a production plan |
| Approach A: SLAXML | One pinned 259-line MIT dependency at commit `8a3e0c9`; no runtime dependency outside embedded Lua | Docstyle's wrapper supplies strictness, namespaces and exact byte ranges, but the backend rejects legal Unicode names | 1,330 Docstyle-owned lines; four measured Unicode-name capability rows fail | Reject |
| Approach B: LuaXML | One pinned 570-line file at commit `c919471` under the Lua License; CSS, HTML, XPath, LuaRocks and native paths excluded | Passes the complete shared XML table, independent semantic and range verification, Unicode names, office edits, deterministic publication and binding performance gates | 1,305 Docstyle-owned lines; one vendored dependency | Select, conditionally |
| Approach C: independent oracle | Repository-owned Lua implementation with no candidate tokenizer or offset code shared with LuaXML | Independently reparses whole parts, checks namespace-expanded semantics, verifies exact half-open ranges and rejects outside-range changes | 1,137 Docstyle-owned lines; used only as a test judge | Retain as development evidence, not production |

### Why SLAXML is rejected

SLAXML's small vendored source does not yield a smaller maintained solution.
Its ASCII-oriented backend requires 1,330 Docstyle-owned lines and still cannot
accept legal Unicode names without forking the dependency. The capability is a
hard XML gate, so recording the limitation is not sufficient for selection.

Two rejected-SLAXML diagnostics also changed from `xml.backend-rejected` to
`xml.backend-mismatch` in an additional `env -i` run without locale variables.
The selected LuaXML path was unaffected. This diagnostic-portability
observation does not change the selection, but it further weakens SLAXML as a
maintainable production base.

### Why LuaXML is selected

LuaXML passes the same shared cases that reject SLAXML, including Greek, CJK
and astral-plane names. The Docstyle layer independently enforces XML 1.0,
encoding and namespace requirements before comparing LuaXML structural events
with byte-span events. Only the exact requested range is serialized; no
whole-tree serializer is trusted to preserve lexical bytes.

The upstream tokenizer is not accepted as a standalone XML implementation.
Selection is for the combined LuaXML and Docstyle strictness/overlay path that
the spike tested.

### Why the oracle is not selected

The oracle is intentionally independent and from scratch. Using it as both
implementation and judge would reduce the value of differential verification.
Its 1,137 lines also do not provide a smaller maintenance burden than
the selected 570-line LuaXML dependency and 1,305-line Docstyle layer. It
should remain a development oracle.

## Archive, OPC and publication evidence

Before exposing a package handle, the archive layer validates central and
local headers, ZIP64 structure, integer bounds, entry names, duplicate and
ASCII case-colliding names, physical-span overlap, metadata intrusion,
encryption, symlink mode bits, compression methods, declared sizes, ratios and
package limits. Central and local entry names must agree for every entry,
including unknown entries that the caller never requests.

Stored and deflated reads are bounded before unsafe output is allocated or
emitted. Actual output length and CRC-32 must agree with the validated central
record. A package-wide materialization budget charges each distinct cached
entry once.

Publication preserves unmodified entry bytes, entry order and each entry's
modification time. It validates the completed archive before publication and
uses one rename as the commit point. Injected write, close, cleanup and
pre-rename failures preserve the prior destination and expose cleanup paths
when recovery is required.

Ten separate `quarto run` processes produced identical edited-part SHA-256,
entry order and whole-archive SHA-256. This shows determinism on the recorded
runtime and platform, not across Pandoc versions or operating systems.

## Office evidence

The edit-and-publish matrix includes native Word comments and revisions, Word
page fields and section footers, a Docstyle POPCORN baseline and a
LibreOffice-saved document. Comments, tracked changes, Zotero and Docstyle
field instructions, custom properties, relationships, section properties and
unknown entries survive the tested edit. Every output is reopened through the
same bounded seam.

No URI-encoded relationship target was observed in the six inspected Word,
Docstyle and LibreOffice packages. URI-encoded target handling is therefore
supported by synthetic RFC 3986 cases, not by office-produced evidence.

## Residual limitations

- Part lookup is byte-exact after rejecting ASCII case-colliding archive
  entries. A case-variant relationship to a stored entry fails closed. This is
  a deliberate spike restriction relative to OPC's ASCII case-insensitive part
  comparison.
- Internal relationship targets support the bounded RFC 3986 subset tested by
  the spike. Broader URI-reference forms are deferred. External targets are
  recorded but never fetched.
- DTDs, custom entity expansion and XInclude are rejected. Supported character
  encodings are UTF-8 and UTF-16 forms covered by the fixture table.
- The package structure is fixed at open. Relationship metadata cannot be
  replaced through the spike seam, and every published result is reopened and
  revalidated.
- ZIP compression method, compression level, extra fields, external
  attributes and archive comments are not preserved through the exposed
  Pandoc writer. Whole-archive bytes are therefore not expected to match the
  source.
- Atomic replacement is established on the tested filesystem. Crash
  durability after rename is not claimed.
- Cross-version and cross-platform archive identity are not claimed.
- The spike supports one existing-attribute edit or one sole-ordinary-text
  replacement. Mixed-content text replacement, new elements, new attributes,
  part creation and general XML transformation are outside the decision.

## Acceptance-test audit

| No. | Acceptance requirement | Executable evidence | Result |
|---:|---|---|---|
| 1 | At least two adapters run the shared XML table | `test-slaxml-adapter.lua`, `test-luaxml-adapter.lua`, `fixtures/xml/cases.lua` | Pass; SLAXML capability failures are measured and LuaXML passes |
| 2 | Independent exact-range and semantic oracle | `test-oracle.lua`; adapter edit cases; generated performance ranges | Pass |
| 3 | XML rejection, boundary and namespace cases | Shared fixture table plus oracle and both adapter suites | Pass |
| 4 | Exact outside-byte preservation and independent full-part semantics | Oracle `verify_edit`; adapter edit cases; office and scaling edits | Pass |
| 5 | Unknown Word and LibreOffice constructs survive | `test-office-preservation.lua`, `test-publication.lua`, office metadata | Pass |
| 6 | Archive hazards and budgets fail closed | `test-archive-preflight.lua`, `test-inflate-limit.lua`, `test-opc.lua` | Pass |
| 7 | Relationship mode and path normalization | `test-opc.lua` relationship-target, unsafe-target and `TargetMode` cases | Pass |
| 8 | Ten fresh processes are deterministic | `test-determinism.lua`, `determinism-results.json` | Pass |
| 9 | Pre-rename failure preserves destination | `test-publication.lua` failure-injection cases | Pass |
| 10 | Binding heap and scaling gates pass; advisory CPU is reported | `test-performance.lua`, `performance-results.json`, Task 10 provenance | Pass; five-second advisory target not met |
| 11 | Offline spike and regression suites remain green | Commands and results below | Pass |
| 12 | One supported decision with no placeholders | This report, provenance and placeholder/style checks | Pass |

## Verification record

The branch is verified with:

```bash
quarto run tests/vnext/xml-spike/run.lua
DOCSTYLE_SPIKE_REFERENCE_PERFORMANCE=1 quarto run tests/vnext/xml-spike/run.lua
quarto run tests/vnext/conformance/run.lua
env R_PROFILE_USER=/dev/null Rscript -e \
  'devtools::test(stop_on_failure = TRUE)'
git diff --exit-code origin/main -- tests/vnext/fixtures/
python3 ~/github/ai-infrastructure/skills/writing-style/scripts/check_style.py \
  dev/vnext/xml-spike/decision-report.md
rg -n 'TB[D]|TO[D]|FIXM[E]|PLACEHOLDE[R]|X{2,}' \
  dev/vnext/xml-spike tests/vnext/xml-spike -g '!**/vendor/**'
git diff --check
```

The ordinary spike run passes all executed gates and skips only the opt-in
reference measurement. The reference run passes all binding gates and reports
the unmet advisory target. The vNext conformance suite reports
`PASS 136 | FAIL 0`. The R suite reports
`FAIL 0 | WARN 30 | SKIP 4 | PASS 3400`. WP0 fixture bytes are unchanged, and
the placeholder, style and whitespace checks pass.

The placeholder search excludes immutable vendored sources because their
upstream comments contain development markers that are not Docstyle decision
placeholders. Vendored hashes are verified separately; all Docstyle-owned
spike and report files are included.

## Decision

**Conditional go.** The selected LuaXML, archive and publication path is
feasible for a separate production plan implementing only the bounded seam
described in this report. Production code must not be copied from the spike
until the performance prerequisite is completed and independently reviewed.
No failed security, preservation, namespace, determinism, retained-heap or
scaling gate is deferred.
