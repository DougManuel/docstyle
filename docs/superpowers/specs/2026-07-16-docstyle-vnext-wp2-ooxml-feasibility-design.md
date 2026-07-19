# Docstyle vNext WP2: Lua OOXML Feasibility Spike Design

**Status:** Proposed for review
**Date:** July 16, 2026
**Work package:** WP2 of the vNext rebuild programme
**Programme specification:** `docs/superpowers/specs/2026-07-12-docstyle-vnext-rebuild-design.md`
**Tracking:** issue #31 (WP2 spike); programme issue #27
**Scope rule:** This document specifies a feasibility experiment. It does not authorize production OOXML integration, CSS compilation, rendering, harvesting or legacy-engine replacement.

## Executive summary

WP2 begins with a bounded experiment because safe XML processing is the critical gate for the vNext DOCX architecture. The spike will determine whether Docstyle can inspect and modify WordprocessingML through the Quarto-bundled Pandoc and Lua runtime without R, LuaRocks, a system Lua installation or a native shared library.

The leading hypothesis is a hybrid XML layer. A small namespace-aware pure-Lua parser provides semantic validation and expanded-name lookup. A Docstyle token index retains the original byte ranges so a bounded edit replaces only the intended attribute or text span. The package layer uses Pandoc's bundled `pandoc.zip` module but adds OPC path, relationship and archive-limit validation before any publication.

This hypothesis is not a preselected implementation. The spike compares it with a broader pure-Lua tree library and a purpose-built token layer. Any candidate that fails a security, namespace, preservation or determinism gate is rejected. If no candidate passes, the result is no-go and the production WP2 implementation does not begin.

## Context

The current runtime is Quarto 1.9.26 with Pandoc 3.8.3 and embedded Lua 5.4. Pandoc supplies a dependency-free Lua execution path, temporary-directory and atomic-rename helpers, CPU timing, binary strings and `pandoc.zip` archive objects. It does not supply an XML DOM.

The legacy engine uses R packages such as `xml2` and rewrites extracted DOCX parts. That implementation provides regression evidence only; vNext does not depend on it. WP1 established the document, field-envelope and durable-state contracts that the future OOXML layer will carry; WP2 must not revise those contracts merely to make XML implementation easier.

Existing Microsoft Word fixtures provide useful starting evidence:

- `tests/testthat/fixtures/word-native-comments.docx` is an 83-page Word document with native comments;
- `tests/testthat/fixtures/page-number-test.docx` contains Word-produced section and page-field structures;
- `inst/extdata/minimal-example/comments-revisions-test-roundtrip.docx` contains comment and revision structures;
- the frozen WP0 DOCX files provide small Docstyle-generated package baselines.

The repository has no explicit LibreOffice-produced fixture. The spike adds one from a small, openly licensed, repository-owned source and records the generating application and version.

## Goals

The spike will:

1. Compare viable XML strategies on the Quarto-bundled Lua 5.4 path.
2. Establish namespace-aware parsing and lookup by namespace URI and local name.
3. Define and test byte-preservation boundaries for unknown OOXML content.
4. Establish strict malformed-input and entity-handling behaviour.
5. Establish an enforceable OPC archive-limit mechanism, path normalization and relationship resolution.
6. Establish deterministic XML serialization and DOCX publication.
7. Measure time and Lua heap use on Word-produced and synthetic fixtures.
8. Produce a decision report with a go/no-go recommendation for the bounded production seam tested here.

## Non-goals

The spike will not:

- implement a general-purpose XML library or complete XPath engine;
- implement full DOCX rendering, harvesting or reconciliation;
- compile QMD, YAML or CSS into the semantic model;
- define the production feature-module ownership registry beyond the seam needed for the experiment;
- replace the legacy R engine;
- modify the frozen WP0 fixtures;
- select a candidate because of popularity, feature count or prior investment;
- permit a native XML library on the default local path.

## Constraints

The following constraints are hard gates:

- The production and end-user execution path is Quarto-only: QMD, Lua and Pandoc. It does not require R, Python, LuaRocks, a system Lua installation, a native shared library or an external ZIP executable.
- Development and CI may use R, Python, native libraries and system utilities for fixture generation, independent oracles, differential testing, provenance capture and regression tests. Any resulting fixture or runtime input must be checked in, and neither the executable spike nor a future production path may invoke those development tools.
- The spike runs offline after checkout. Candidate code is vendored with version, commit, licence and provenance records.
- OOXML and field-code content is untrusted data. The spike never executes payload content, follows external targets or expands custom entities.
- Namespace identity is the pair `(namespace URI, local name)`. Source prefixes are preserved where required but never trusted as identity.
- Unknown parts and unknown XML constructs are preserved unless a named operation owns them.
- The spike fails closed on malformed XML, unsafe archives, unexplained loss and ambiguous relationship resolution.
- WP0 fixtures remain read-only evidence.
- Production WP2 work requires a separate implementation plan after this specification and the spike decision are reviewed.

## Candidate approaches

### Approach A: vendored parser plus Docstyle token overlay

Vendor a small pure-Lua namespace-aware parser behind a Docstyle adapter. Use parser events to validate structure and expanded names, while a Docstyle tokenizer records the original byte spans for elements, attributes, text, comments, processing instructions and CDATA. Bounded mutations replace only the owned span; serialization concatenates untouched original spans with escaped replacement bytes.

SLAXML is the leading parser candidate for this approach. It is MIT-licensed, supports Lua 5.4, provides streaming and DOM interfaces, resolves namespaces, and exposes comments, processing instructions and CDATA. Its own documentation states that it does not enforce all XML well-formedness rules and that its serializer can emit invalid namespace combinations. The adapter must therefore supply strict hierarchy, namespace and entity guards; passing SLAXML's parser alone is not sufficient evidence.

Advantages:

- Small vendored dependency and no native runtime
- Direct access to namespace events and non-element tokens
- Narrow byte edits preserve unknown content
- Streaming path can limit memory use

Risks:

- Docstyle becomes responsible for the strictness layer and token offsets
- Complex future insertions may require a stronger serializer
- Parser limitations could be expensive to close safely

### Approach B: broader pure-Lua tree library

Adapt a maintained pure-Lua tree library, initially LuaXML, behind the same evaluation interface. LuaXML reads and serializes XML and has current maintenance activity, but it was designed mainly for LuaTeX workflows and has a larger API and mixed module licences. The spike must verify namespace behaviour, Lua 5.4 portability, dependency closure, token retention and deterministic output rather than assuming them.

Advantages:

- More tree, query and transformation machinery is already present
- May reduce the amount of Docstyle-owned XML code

Risks:

- Larger vendored code and audit burden
- General serialization may normalize or discard unknown lexical details
- Dependencies or LuaTeX assumptions may violate the Quarto-only path

### Approach C: purpose-built lossless OOXML token layer

Implement a narrow tokenizer, namespace stack, structural validator and mutation API for the XML subset used by OOXML. Preserve all source tokens and construct only the semantic indexes Docstyle needs.

Advantages:

- Exact control over preservation, limits and diagnostics
- Small public API designed around OOXML ownership

Risks:

- Highest correctness and security burden
- XML edge cases can expand the implementation beyond the work package
- Long-term maintenance rests entirely with Docstyle

### Screened-out defaults

`xml2lua` is useful prior art but its documented compatibility stops at Lua 5.3 and its XML-to-table model does not promise namespace or lexical preservation. Native libraries such as libxml2 may act as development oracles but cannot become the default runtime. Neither is a primary spike candidate unless new evidence changes these constraints.

## Recommended experiment

Prototype Approach A first because it tests the smallest credible route to the local-path and preservation requirements. Prototype Approach B through the same adapter tests whether a broader library reduces risk without losing bytes. Implement only enough of Approach C to establish the cost of strict tokenization and to provide an independent check on the leading candidate's token boundaries. For this decision, a candidate is a specific library version, its Docstyle adapter, and any strictness or token-preservation layer required to pass the gates. Approach C is an oracle unless it independently passes the complete adapter suite.

The spike selects among candidates that pass every applicable hard gate. The comparison reports vendored dependency count, vendored and Docstyle-owned lines of code, licence complexity, unresolved limitations and the amount of security-sensitive code Docstyle must maintain. It prefers the candidate with the lowest supported long-term maintenance risk; the report must explain the judgement rather than collapse these measures into an arbitrary score. A higher feature count does not compensate for failed preservation, malformed-input or archive-safety tests.

## Evaluation interface

Each XML candidate must implement the same spike-only interface:

```lua
document = adapter.parse(xml_bytes, options)
nodes = adapter.find_all(document, namespace_uri, local_name)
value = adapter.get_attribute(nodes[1], namespace_uri, local_name)
adapter.set_attribute(nodes[1], namespace_uri, local_name, new_value)
adapter.replace_text(nodes[1], new_text)
xml_bytes, edit_ranges = adapter.serialize(document)
```

`parse` raises a typed diagnostic on invalid input. A diagnostic contains a stable machine-readable code, a human-readable message and the available byte offset or package-entry context; tests assert the code rather than exact prose. `find_all` and attribute lookup use expanded names. `set_attribute` and `replace_text` are the only mutations required by the spike. `serialize` returns the final bytes and the source ranges it changed. Insert, remove, move, XPath and schema validation remain outside the experiment.

The package experiment exposes:

```lua
pkg = opc.open_path(docx_path, limits)
bytes = pkg:part(part_name)
pkg:replace_part(part_name, bytes)
relationships = pkg:relationships(source_part)
pkg:write_atomic(output_path, options)
```

The XML experiment performs one mutation per parsed document. Mutation values are Lua strings containing valid XML 1.0 characters. `set_attribute` updates the value bytes inside the existing quote delimiters of one attribute selected by expanded name and fails if it is absent; ambiguity cannot arise because parsing already rejects duplicate attributes with the same expanded name. It does not change the attribute name, prefix, namespace declaration or quote delimiter. `replace_text` updates the complete sole direct ordinary-text token of an element and fails on mixed content, nested elements, multiple text tokens or CDATA. These exact source spans are the only permitted edit ranges. Golden fixture coordinates, maintained independently of candidate code, prevent a candidate from reporting a larger range.

`edit_ranges` is a sorted, non-overlapping list of half-open byte offsets, `[start, end)`, into the original encoded input. Replacement lengths may differ from source lengths. The spike uses one range per mutation; multiple-edit coordinate rebasing belongs to production design. An independent oracle is an implementation that does not reuse the selected candidate's tokenizer or offset calculations.

The package interface accepts a path so it can check the compressed file size before loading archive bytes. `part_name` and `source_part` are slash-prefixed OPC part-name URIs; after validation, the adapter maps a part to its ZIP entry name by removing exactly one leading slash without URI decoding. `relationships("/")` addresses the package-root relationship part. This evaluation seam exists only for the spike. A production interface is specified after the spike.

## XML contract

### Encoding

The adapter detects an optional byte-order mark and the XML declaration before tokenization. The spike must accept UTF-8 and test UTF-16 little- and big-endian conversion through the Pandoc runtime; the verified facility on the recorded runtime is `pandoc.text.fromencoding` and `pandoc.text.toencoding`. `fromencoding` preserves a byte-order mark as U+FEFF in the decoded stream, which the offset mapping must account for, and encoding-name support is platform-dependent, so the report pins the two encoding names tested. It rejects declarations that contradict the byte stream and encodings it cannot convert safely. A bounded edit preserves the input encoding, byte-order mark and declaration; offsets refer to the original encoded bytes, and replacement text is encoded back into that source encoding. A candidate must either tokenize raw encoded bytes or maintain a tested reversible mapping from decoded code points to original byte offsets, including surrogate pairs and the byte-order mark. Encoding new XML parts belongs to production WP2 and is outside this spike.

### Well-formedness and entities

The accepted language is XML 1.0 Fifth Edition with Namespaces in XML 1.0 Third Edition. The adapter rejects unsupported XML versions and:

- mismatched, unclosed or multiply rooted elements;
- unbound namespace prefixes and illegal `xml` or `xmlns` rebinding;
- duplicate attributes with the same expanded name;
- malformed comments, CDATA, processing instructions, character references or declarations;
- invalid XML characters, names or qualified names, misplaced declarations and a processing-instruction target matching `xml` in any letter case;
- `DOCTYPE`, custom entity declarations and external entities.

Parse options include maximum input bytes, element depth, total tokens, attributes per element and namespace declarations per element. Zero, negative, non-integral or overflowing limits are invalid options. The runner uses small values to exercise each rejection path; selecting production defaults is deferred.

Only the five predefined XML entities and valid numeric character references are decoded. Untouched source spans retain their original entity spelling. Attribute replacement preserves the existing quote delimiter; it escapes `&`, `<` and that delimiter, and writes tab, line feed and carriage return as `&#x9;`, `&#xA;` and `&#xD;` so XML attribute-value normalization does not change the requested value. Ordinary text replacement escapes `&`, `<` and any `>` needed to avoid forming `]]>`, writes carriage return as `&#xD;` so XML line-end normalization cannot rewrite the requested value on reparse, and otherwise retains valid Unicode characters literally. Replacement bytes are therefore deterministic and escaped exactly once.

### Namespace handling

The parser maintains a namespace stack for every element. Queries and ownership rules use namespace URI plus local name. Prefix shadowing must resolve correctly. The serializer preserves original namespace declarations and prefixes outside the reported edit range. A newly serialized or replaced token must use an in-scope prefix bound to the requested namespace; it must not invent an unbound prefix.

### Preservation boundary

Preservation has two levels:

1. An untouched ZIP entry retains identical uncompressed bytes.
2. In an edited XML part, every byte outside the reported edit ranges remains identical to the input. Within the edited range, reparsing through an implementation independent of the candidate -- the acceptance-test-2 oracle or another candidate's adapter, never the edited candidate's own parser alone -- must produce the same expanded element and attribute names and decoded content, except for the requested value change. This is XML-level equivalence; the spike does not claim visual equivalence in Word.

Tests cover unknown elements and attributes, Microsoft compatibility markup, comments, processing instructions, CDATA, entity spellings, whitespace-only text, `xml:space="preserve"` and namespace declarations. The spike records any construct that a candidate normalizes even when it is not edited. Undeclared normalization is a failed preservation gate.

## OPC and ZIP contract

### Archive limits

`opc.open_path` receives an explicit limits object and checks the input file size before loading it. Limits are non-negative integers in bytes or counts and are inclusive; invalid or overflowing values fail before archive processing. Compression ratio is `declared_uncompressed_bytes / max(1, compressed_bytes)`. The spike uses deliberately small limits in adversarial tests so every branch is reachable. The interface must be able to enforce:

- compressed archive byte limit;
- entry-count limit;
- per-entry declared uncompressed byte limit;
- total declared uncompressed byte limit;
- compression-ratio limit;
- encrypted-entry and symlink rejection.

Pandoc's documented ZIP entry API exposes paths, contents, modification time and symlink status, but does not document declared compressed and uncompressed sizes or encryption state. The spike must determine whether those values are available safely before `Entry:contents()` decompresses data. If they are not, the candidate must add a bounded central-directory reader or return no-go for untrusted packages.

Central-directory preflight is necessary but does not by itself bound malicious decompression when declared sizes are false. Directory parsing uses checked integer arithmetic, validates ZIP64 records and rejects multi-disk archives. Before exposing the package handle, it computes the half-open physical span of every local entry from the start of its local header through its file name, extra field, compressed data and optional data descriptor. Every span must be fully contained in the archive data region before the central directory, pairwise disjoint from every other local-entry span, and disjoint from central-directory, ZIP64 and end-of-central-directory metadata; duplicate or overlapping local-header offsets fail closed. The spike must show that the backend enforces the output cap while decompressing, without allocating or materializing output beyond the configured per-entry or cumulative limit, or add a capped streaming decompression layer that does so. Tests forge inconsistent local-header, central-directory and actual-output sizes, overlapping local-entry spans, local-entry spans that enter archive metadata, and disagreements between central-directory and local-header entry names: because the spike necessarily runs two parsers over the same archive (the Docstyle preflight reader and the backend that decompresses), the package layer requires every central-directory record to agree with its referenced local header on the entry name before the package handle is exposed -- unknown and initially unrequested entries included, because the spike preserves and republishes unknown content -- and fails closed on any mismatch, so validation and content retrieval can never act on different names. Central-directory CRC-32 agreement for retrieved parts is recorded as evidence rather than enforced as a gate. Allocating or decompressing unbounded output and rejecting it afterwards does not satisfy the gate. The cumulative output limit is a per-package-handle budget: every `part()` call charges the bytes it newly materializes against the handle's remaining budget before returning them; a repeated read of the same entry either returns cached bytes without a second charge or re-charges the re-materialized output, and the candidate must document which; a call fails closed before output exceeds the remaining budget. The decision report recommends candidate production thresholds from measured Word and LibreOffice evidence; approving numeric production defaults remains production design work.

### Paths and duplicate entries

Archive entry names use `/` with non-empty segments. Two name classes are distinguished: the `[Content_Types].xml` content-types stream is a ZIP package item and package metadata rather than an OPC part, and is exempt only from the part-name grammar; every other entry's slash-prefixed form must be a valid OPC part name. The package layer rejects empty names, absolute paths, drive-letter paths, backslashes, `.` or `..` segments, NUL bytes, undecodable names and duplicate exact names. ZIP entry names are case-sensitive and are neither URI-decoded nor Unicode-normalized; because OPC compares part names by ASCII case-insensitive equivalence, two entries whose names differ only by ASCII letter case are distinct ZIP items but equivalent OPC part names, and the package layer rejects such case-colliding entries at validation. After that check, lookups match bytes exactly, and a reference whose case does not match the stored entry fails closed -- a declared spike restriction relative to OPC's ASCII case-insensitive comparison, recorded in the decision report. Both behaviours have executable tests: a case-colliding archive is rejected, and a case-variant reference to a stored entry fails closed. The spike never extracts an archive to caller-selected paths.

Relationship targets follow different rules. For the spike, an internal target must be a relative path reference with no scheme, authority or query. A fragment may be recorded but is removed before part lookup. URI-encoded octets in a target are handled per RFC 3986 section 2.4: the target is parsed into segments first, and valid encodings are preserved through resolution rather than decoded wholesale. Encoded separators, encoded dot segments, encoded NUL and other encoded control characters, and malformed encodings fail closed; hexadecimal digits in retained encodings are normalized to upper case; only encodings of unreserved characters are decoded, since only those decode without changing interpretation. The resolved reference, with its remaining encodings intact, is then validated as an OPC part name and matched against the package's part names under the same normalization. Whether any Word- or LibreOffice-produced fixture actually carries URI-encoded targets is recorded as evidence in the decision report. Literal `..` segments are resolved relative to the source part and the normalized result must remain inside the package. Missing `TargetMode` means internal; other values fail closed unless they equal `External`. Relationship IDs must be unique within their relationship part. Package-root relationships use `/` as their source base, and duplicate or ambiguous office-document roots fail closed. A relationship with `TargetMode="External"` is recorded but never resolved as an internal part or fetched. Broader URI-reference support is recorded as deferred work. This closes the failure mode tracked in #21.

### Content types and roots

The spike parses `[Content_Types].xml`, `_rels/.rels` and part-level relationship files through the selected XML adapter. It verifies package-root traversal to `word/document.xml` and `docProps/core.xml`, and does not report standards-defined roots as unreferenced merely because no part-local relationship points to them.

### Atomic and deterministic publication

The package writer creates a collision-resistant temporary file with exclusive creation in the destination directory, builds and closes the complete archive, verifies it through the same limits and relationship checks, then renames it over the destination as the single commit point. A simulated failure before the rename leaves the existing destination bytes unchanged and removes the temporary file. The spike claims atomic replacement on the tested filesystem, not crash durability after the rename.

Unchanged entries retain their uncompressed bytes and original modification times. A changed existing entry retains its original modification time; a new entry uses the ZIP epoch of January 1, 1980. Existing entry order is preserved, and any new entries are appended in bytewise name order. Compression settings are fixed when the archive API exposes them. Ten fresh processes given identical source bytes on the recorded runtime and platform must produce the same XML bytes, entry order and whole-archive SHA-256 hash; cross-version and cross-platform archive identity are not spike gates.

## Fixture matrix

### Existing Word evidence

The spike copies existing fixtures into temporary working directories and never rewrites the repository copies. At minimum it exercises:

- native comments and comment relationships;
- section properties, headers, footers and page fields;
- tracked revisions;
- DOCSTYLE and Zotero field instructions;
- Microsoft compatibility namespaces and unknown attributes present in the fixtures.

### LibreOffice evidence

A new small fixture begins from a repository-owned QMD or DOCX source containing every requested construct, is opened and saved by a recorded LibreOffice version, and is committed with provenance and licence metadata. The saved fixture must retain a heading, body paragraph, list, table, internal and external hyperlinks, a header or footer, and a section break. Comment retention is recorded as evidence; if LibreOffice drops it, the Word comment fixture remains authoritative for that construct.

### Adversarial XML and OPC evidence

Text fixtures cover valid namespace shadowing and every rejected XML class in this specification. Synthetic archives cover malicious paths, duplicate exact entry names, ASCII case-colliding entry names, duplicate and overlapping local-entry spans, local-entry spans that enter central-directory or end metadata, central-directory/local-header name disagreements, symlinks, encrypted entries, relationship escapes, URI-encoded target variants, external relative targets, excessive counts, high expansion ratios and repeated-read budget exhaustion. Fixture generation is deterministic; large or compressed adversarial artifacts are generated during tests rather than committed.

### Scaling evidence

The runner generates XML parts of one, five and 10 MiB with representative `w:p`, `w:r`, `w:t`, attributes and namespace declarations. The generator records the expected byte coordinates of each planted edit target as golden values, independent of any candidate, so scaling edits are range-checked with the same rigour as the authored fixtures. It measures parse, one attribute edit and serialization separately.

## Performance protocol

The runner performs one unreported warm-up and five measured repetitions for each size. It uses `pandoc.system.cputime()` for CPU measurements and reports the median combined parse, edit and serialization time. Instrumentation and forced collections are outside timed phases.

For retained Lua heap measurements, the runner calls `collectgarbage("collect")` before the initial baseline and after each phase, then reads `collectgarbage("count")`. Each phase-boundary delta is `max(0, observed_kib - initial_kib) * 1024`; the largest delta across phases and measured repetitions is reported in bytes. This metric does not observe allocations created and released inside a phase or native allocations, and the report must not describe it as peak memory. The decision report records Quarto, Pandoc, Lua, operating system, architecture, Mac model, processor and installed memory.

On the reference macOS environment:

- the 10 MiB case must complete parse, one bounded edit and serialization within five CPU seconds;
- the largest observed retained Lua heap delta must be no more than 12 times the input size;
- median combined time and maximum observed heap delta for the 10 MiB case must each be no more than 15 times the corresponding one MiB measurement.

These measurements are feasibility gates on the reference environment, not timing assertions in ordinary CI. CI tests retain functional limits and a generous timeout so routine hardware variation does not create false failures.

## Test and evaluation protocol

The spike runner is:

```bash
quarto run tests/vnext/xml-spike/run.lua
```

It must run offline and discover a non-zero test count. Candidate adapters run against the same table-driven cases. The runner prints separate functional, preservation, safety, determinism and performance summaries and exits non-zero on a failed hard gate.

Regression verification remains:

```bash
quarto run tests/vnext/conformance/run.lua
env R_PROFILE_USER=/dev/null Rscript -e 'devtools::test(stop_on_failure = TRUE)'
git diff --exit-code main -- tests/vnext/fixtures/
```

The R suite verifies that the spike did not disturb the legacy engine. It is not a dependency of the spike itself.

## Selection rule and report

The spike runs in stages and stops early when a programme gate fails:

1. Establish that archive metadata can be preflighted and actual decompression bounded on the Quarto-only path. If this requires a native runtime or cannot be made safe with a bounded Lua layer, record no-go and stop.
2. Run Approach A through the XML functional, strictness, preservation and scaling table. Continue even if it fails so the decision is comparative.
3. Run Approach B through the same table and use the independent Approach C oracle on the leading passing candidate. If neither adapter passes, record no-go.
4. Exercise the selected XML candidate with the package fixtures, deterministic writer and atomic-publication tests, then complete the report.

Every candidate receives a table with:

- runtime and dependency closure;
- licence and provenance;
- XML strictness;
- namespace correctness;
- byte preservation;
- deterministic output;
- OPC and archive safety;
- Word and LibreOffice fixture results;
- CPU and heap measurements;
- code size and Docstyle-owned maintenance burden;
- residual limitations.

Every constraint identified as a hard gate, every normative XML, archive, preservation, determinism and performance requirement, and acceptance tests 3 through 11 apply to a candidate where the candidate supplies that layer. Acceptance tests 1, 2 and 12 apply to the spike as a whole. Any applicable hard-gate failure rejects the candidate. The report must explain rejected approaches and may recommend:

- **go:** one candidate passes all gates and can support a production plan for the bounded read, existing-attribute update and ordinary-text replacement seam tested here;
- **conditional go:** a candidate passes the spike gates, but a named, bounded engineering prerequisite, licensing correction or upstream fix must land before production integration;
- **no-go:** no candidate supports the contract without changing the programme architecture.

A conditional-go prerequisite must be concrete and testable. It cannot change the runtime architecture or defer a failed security, preservation, namespace or determinism gate to production.

## Acceptance tests

If stage 1 establishes that safe archive handling is impossible on the programme runtime, the spike is complete when the executable evidence and supported no-go report are reviewed. Otherwise, the spike is complete when:

1. At least two candidate adapters run through the same XML fixture table.
2. A third tokenizer or oracle that shares no tokenizer or offset-calculation code with the selected candidate verifies the exact start and end coordinates of every reported edit range and the expanded names, across every edit case in the fixture table including the generated scaling fixtures, rejecting any range broader or narrower than the golden coordinates before the outside-bytes comparison runs.
3. Every XML rejection class, legal boundary case and namespace-shadowing case named in this specification has an executable test derived from the cited XML and Namespaces productions.
4. Every attribute edit and every text edit in the fixture table preserves all bytes outside its reported range, each reported range equals its golden coordinates exactly, and independent full-part reparsing of every edited part yields identical namespace bindings, expanded names and decoded values everywhere except the requested value change.
5. Unknown OOXML constructs survive the tested edits in Word and LibreOffice fixtures.
6. Archive path, duplicate-name, case-collision, overlapping-local-entry, archive-metadata-overlap, symlink, encryption and limit tests fail closed before the package handle is exposed and before any unsafe decompression or allocation occurs; the tests include cumulative-budget exhaustion across repeated reads under the candidate's documented cache-charging semantics, and central-directory/local-header name disagreement on entries the caller never requests.
7. Relationship tests distinguish `TargetMode="External"` and correctly normalize internal `..` targets without package escape.
8. Ten package writes from ten fresh processes, each given identical source bytes including at least one edited XML part, produce identical XML bytes, entry order and whole-archive SHA-256 hashes.
9. Simulated pre-rename failure leaves the prior destination unchanged.
10. The scaling fixtures meet the reference performance and heap gates.
11. The runner passes without network or R and the existing conformance and R suites remain green.
12. The decision report contains a supported go, conditional-go or no-go result with no unresolved placeholders.

## Outputs

The implementation plan for this specification may create:

- `tests/vnext/xml-spike/run.lua` and table-driven test modules;
- `tests/vnext/xml-spike/fixtures/` for small text and package fixtures;
- `dev/vnext/xml-spike/candidates/` for spike-only adapters and vendored candidates;
- `dev/vnext/xml-spike/provenance.json` for versions, commits and licences;
- `dev/vnext/xml-spike/decision-report.md` for results and recommendation.

None of the candidate code enters `_extensions/docstyle/` or production R code during the spike.

## Deferred work

- Final production XML and OPC APIs
- Complete feature-module interface and ownership registry
- General insertion, removal and move operations
- Full content-type and relationship graph validation
- Broader internal relationship URI-reference support beyond the bounded spike subset
- Render and return-path integration
- CSS, page and section property compilation
- Platform-wide performance baselines in hermetic CI
- Migration-driver and legacy-retirement work

## References

- Programme specification: `docs/superpowers/specs/2026-07-12-docstyle-vnext-rebuild-design.md`
- WP1 specification: `docs/superpowers/specs/2026-07-14-docstyle-vnext-wp1-schemas-state-design.md`
- WP2 tracking issue: <https://github.com/DougManuel/docstyle/issues/31>
- Pandoc Lua API, including `pandoc.system` and `pandoc.zip`: <https://pandoc.org/lua-filters.html>
- SLAXML repository and documented limitations: <https://github.com/Phrogz/SLAXML>
- LuaXML repository: <https://github.com/michal-h21/LuaXML>
- xml2lua repository: <https://github.com/manoelcampos/xml2lua>
- ECMA-376, Office Open XML File Formats: <https://ecma-international.org/publications-and-standards/standards/ecma-376/>
- W3C XML 1.0: <https://www.w3.org/TR/xml/>
- W3C Namespaces in XML 1.0: <https://www.w3.org/TR/xml-names/>
