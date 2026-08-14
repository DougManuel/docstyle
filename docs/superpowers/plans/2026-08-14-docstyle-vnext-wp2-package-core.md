# WP2 package-core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Revised August 14, 2026 after external review. The blocking findings that shaped
this revision: added parts must be integrated through one effective-package
view (writer verification, relationship resolution, id minting and collision
checks all consult it); package metadata is edited through a safe XML insertion
primitive, never `gsub` on closing tags; the spike's publication and
determinism tests are ported, not left behind; `diagnostic.capture` returns
`ok, err` and every rejection test uses both values; the reference benchmark
overrides the new input-byte limit for its scaling cases.

**Goal:** Promote the WP2 feasibility spike's tested OOXML modules into a production Lua package-core library and extend it to the full package-finalization interface (add parts, add relationships, multi-edit XML) with the performance prerequisite satisfied.

**Architecture:** Move the selected spike modules by `git mv` into `_extensions/docstyle/vnext/package-core/`, rewrite require paths, and keep the promoted hermetic suite green — including the ported publication and determinism tests. Introduce an internal effective-package view (originals + replacements + additions) that every read, resolution, validation and the writer consult, then extend through TDD: `inventory()`, multi-edit XML with a zero-width insertion primitive, the fail-closed XML-part input-byte limit, `add_part`, `add_relationship`. `init.lua` is the only public surface.

**Tech Stack:** Pure Lua 5.4 on the Quarto-bundled Pandoc (`pandoc.zip`, `pandoc.path`, `pandoc.system`, `pandoc.json`, `pandoc.text`, `pandoc.pipe`); vendored LuaXML and libdeflate; the hermetic `run.lua` harness driven by `quarto run`. No R, no LuaRocks, no native modules, no external ZIP tool.

## Global Constraints

- Runtime: Quarto 1.9.26 / Pandoc 3.8.3 / Lua 5.4. No R dependency in any package-core module. No LuaRocks, no native shared library, no external ZIP executable.
- Production home: `_extensions/docstyle/vnext/package-core/`. Public entry point is `init.lua`; nothing outside the tree requires an internal module directly.
- XML-part input-byte limit: candidate 1,048,576 bytes (1 MiB), enforced fail-closed before `xml.parse`. Visible configuration, never hidden. `max_input_bytes` overrides must be validated as non-negative integers.
- One effective package view: every lookup, collision check, relationship resolution, size validation, writer entry assembly and post-publication verification goes through the `Package:_effective_*` helpers introduced in Task 3. No call site re-derives state from `pkg.entries` alone once additions exist.
- Package metadata (`[Content_Types].xml`, `_rels/*.rels`) is modified only through the XML module's insertion primitive with escaped attributes. String substitution on serialized XML is forbidden.
- Determinism: output bytes and entry order are reproducible across fresh `quarto run` processes; added entries use the fixed modtime constant and sorted-name order (never `pairs` order, never the wall clock).
- Diagnostics: typed codes via `diagnostic.raise(code, message, context)`, namespaced `zip.*`, `opc.*`, `xml.*`, `publication.*` (plus `internal.lua-error`). `diagnostic.capture(fn)` returns `ok, result_or_error` — rejection tests bind both and assert `not ok` before inspecting `err.code`. No `print`/`io.write` in library modules; benchmark advisory output goes to stderr so stdout stays valid JSON.
- WP0 characterization fixtures under `tests/vnext/fixtures/` are immutable migration evidence. Never regenerate a baseline to make a test pass.
- The feasibility record — `dev/vnext/xml-spike/decision-report.md`, `provenance.json`, `performance-results.json`, `determinism-results.json`, the rejected SLAXML candidate and the spike performance/selection tests — is immutable and stays in place.
- Commits: plain-text messages, no AI credit. `docs/` is gitignored; stage plan/spec files with `git add -f`.

---

## File structure

Production tree (under `_extensions/docstyle/vnext/package-core/`):

| File | Origin | Responsibility |
|---|---|---|
| `init.lua` | new | Public surface: `open`, `xml`, `diagnostic`. |
| `lib/binary.lua`, `lib/diagnostic.lua` | `dev/vnext/xml-spike/lib/` | Byte helpers; typed diagnostics. |
| `zip.lua` | `archive/zip_preflight.lua` | Central-directory preflight. |
| `inflate.lua` | `archive/inflate_limited.lua` | Bounded decompression. |
| `entry.lua` | `archive/entry_reader.lua` | CRC/size-checked reads + budget. |
| `opc.lua` | `archive/opc.lua` | Package object; extended: effective view, `inventory`, `add_part`, `add_relationship`. |
| `writer.lua` | `archive/writer.lua` | Deterministic atomic publication; extended: effective entries + verification. |
| `xml/init.lua` | new | Re-exports the adapter as module `xml`. |
| `xml/adapter.lua` | `candidates/luaxml/adapter.lua` | Parse/find/edit/serialize; extended: multi-edit, limit, `append_element`. |
| `xml/strictness.lua`, `xml/token_overlay.lua`, `xml/common.lua` | `candidates/luaxml/…`, `candidates/common.lua` | Strictness; byte-span overlay (extended: multi-edit serialize, exported escaping); shared helpers. |
| `xml/vendor/…`, `inflate/vendor/…` | spike vendor dirs | Vendored LuaXML / libdeflate (unchanged). |

Test tree (under `tests/vnext/package-core/`):

| File | Origin |
|---|---|
| `run.lua`, `lib/harness.lua`, `lib/fixture.lua`, `fixtures/…` | promoted from `tests/vnext/xml-spike/` |
| `lib/oracle.lua` | `dev/vnext/xml-spike/candidates/oracle.lua` (test-only judge) |
| `lib/child.lua` | `tests/vnext/xml-spike/lib/child.lua` (fresh-process determinism child) |
| `tests/test-archive-preflight.lua`, `tests/test-inflate-limit.lua`, `tests/test-opc.lua`, `tests/test-office-preservation.lua`, `tests/test-xml-adapter.lua`, `tests/test-oracle.lua`, `tests/test-publication.lua`, `tests/test-determinism.lua` | promoted (requires rewritten; feasibility-only cases removed) |
| `tests/test-inventory.lua` (Task 3), `tests/test-multi-edit.lua` (Task 4), `tests/test-xml-limit.lua` (Task 5), `tests/test-add-part.lua` (Task 6), `tests/test-add-relationship.lua` (Task 7) | new |

Stays behind in the spike tree (feasibility record): `candidates/slaxml/`, `tests/test-slaxml-adapter.lua`, `tests/test-performance.lua` (recorded reference evidence; its production replacement is Task 8's benchmark), `tests/test-runner.lua` (exercises spike-specific stage semantics; the promoted harness is unchanged and exercised by every promoted test). Gate mapping: archive/functional/preservation/safety gates ride the promoted tests; the determinism gate rides the ported `test-determinism.lua`; the performance gate is re-established in Task 8 against the production module.

---

## Task 1: Promote the module tree and the full guarantee set

**Files:**
- Move: library modules and vendor dirs as per the file-structure table (exact `git mv` commands below)
- Create: `_extensions/docstyle/vnext/package-core/init.lua`, `…/xml/init.lua`
- Move: harness, fixtures, oracle, child, and the eight promoted test files
- Modify: every moved file's `require` paths; `run.lua` `package.path`; `test-determinism.lua` (drop the spike-record cross-check); `test-xml-adapter.lua` (drop the selection-provenance case)

**Interfaces:**
- Produces: module names `zip`, `inflate`, `entry`, `opc`, `writer`, `xml` (via `xml/init.lua`), `xml.adapter`, `xml.strictness`, `xml.token_overlay`, `xml.common`, `lib.binary`, `lib.diagnostic`; public `init.lua` returning `{ open = opc.open_path, xml = require("xml"), diagnostic = require("lib.diagnostic") }`; test modules `lib.harness`, `lib.fixture`, `lib.oracle`, `lib.child`.

- [ ] **Step 1: Move the library modules**

```bash
cd $(git rev-parse --show-toplevel)
mkdir -p _extensions/docstyle/vnext/package-core/{lib,xml}
git mv dev/vnext/xml-spike/lib/binary.lua      _extensions/docstyle/vnext/package-core/lib/binary.lua
git mv dev/vnext/xml-spike/lib/diagnostic.lua  _extensions/docstyle/vnext/package-core/lib/diagnostic.lua
git mv dev/vnext/xml-spike/archive/zip_preflight.lua    _extensions/docstyle/vnext/package-core/zip.lua
git mv dev/vnext/xml-spike/archive/inflate_limited.lua  _extensions/docstyle/vnext/package-core/inflate.lua
git mv dev/vnext/xml-spike/archive/entry_reader.lua     _extensions/docstyle/vnext/package-core/entry.lua
git mv dev/vnext/xml-spike/archive/opc.lua              _extensions/docstyle/vnext/package-core/opc.lua
git mv dev/vnext/xml-spike/archive/writer.lua           _extensions/docstyle/vnext/package-core/writer.lua
git mv dev/vnext/xml-spike/candidates/luaxml/adapter.lua       _extensions/docstyle/vnext/package-core/xml/adapter.lua
git mv dev/vnext/xml-spike/candidates/luaxml/strictness.lua    _extensions/docstyle/vnext/package-core/xml/strictness.lua
git mv dev/vnext/xml-spike/candidates/luaxml/token_overlay.lua _extensions/docstyle/vnext/package-core/xml/token_overlay.lua
git mv dev/vnext/xml-spike/candidates/common.lua               _extensions/docstyle/vnext/package-core/xml/common.lua
```

Inspect the top of `xml/adapter.lua` and `inflate.lua` for their vendor requires and `git mv` the vendored LuaXML directory to `_extensions/docstyle/vnext/package-core/xml/vendor/` and the libdeflate directory to `_extensions/docstyle/vnext/package-core/inflate/vendor/` (or the exact sibling path each require expects after renaming — match the require, do not restructure the vendor trees).

- [ ] **Step 2: Rewrite the require paths in the moved modules**

Apply exactly, in every moved `.lua` file:

| Old | New |
|---|---|
| `require("archive.zip_preflight")` | `require("zip")` |
| `require("archive.inflate_limited")` | `require("inflate")` |
| `require("archive.entry_reader")` | `require("entry")` |
| `require("archive.opc")` | `require("opc")` |
| `require("archive.writer")` | `require("writer")` |
| `require("candidates.luaxml.adapter")` | `require("xml.adapter")` |
| `require("candidates.luaxml.strictness")` | `require("xml.strictness")` |
| `require("candidates.luaxml.token_overlay")` | `require("xml.token_overlay")` |
| `require("candidates.common")` | `require("xml.common")` |
| `require("candidates.oracle")` | `require("lib.oracle")` (tests only) |

`require("lib.binary")` / `require("lib.diagnostic")` are unchanged. Verify:

```bash
grep -rn 'require("archive\.\|require("candidates\.' _extensions/docstyle/vnext/package-core tests/vnext/package-core
# Expected: no output
```

- [ ] **Step 3: Write `xml/init.lua` and `init.lua`**

`_extensions/docstyle/vnext/package-core/xml/init.lua`:

```lua
-- Public XML module: the LuaXML adapter is the package-core XML surface.
return require("xml.adapter")
```

`_extensions/docstyle/vnext/package-core/init.lua`:

```lua
-- Docstyle vNext package core: the only public surface.
-- Feature modules and the machine interface require this file, never internals.
local opc = require("opc")
return {
  open = opc.open_path,
  xml = require("xml"),
  diagnostic = require("lib.diagnostic"),
}
```

- [ ] **Step 4: Move the harness, fixtures and the eight promoted test files**

```bash
mkdir -p tests/vnext/package-core/{lib,tests}
git mv tests/vnext/xml-spike/run.lua            tests/vnext/package-core/run.lua
git mv tests/vnext/xml-spike/lib/harness.lua    tests/vnext/package-core/lib/harness.lua
git mv tests/vnext/xml-spike/lib/fixture.lua    tests/vnext/package-core/lib/fixture.lua
git mv tests/vnext/xml-spike/lib/child.lua      tests/vnext/package-core/lib/child.lua
git mv tests/vnext/xml-spike/fixtures           tests/vnext/package-core/fixtures
git mv dev/vnext/xml-spike/candidates/oracle.lua tests/vnext/package-core/lib/oracle.lua
for t in archive-preflight inflate-limit opc office-preservation oracle publication determinism; do
  git mv tests/vnext/xml-spike/tests/test-$t.lua tests/vnext/package-core/tests/test-$t.lua
done
git mv tests/vnext/xml-spike/tests/test-luaxml-adapter.lua tests/vnext/package-core/tests/test-xml-adapter.lua
```

Left behind with the feasibility record: `test-slaxml-adapter.lua`, `test-performance.lua`, `test-runner.lua`, `candidates/slaxml/`. The spike's `run.lua` is gone, so add a one-line README note in `tests/vnext/xml-spike/` stating the remaining files are the frozen feasibility record, no longer an executable suite.

- [ ] **Step 5: Rewrite `run.lua` package.path and the tests' requires**

`tests/vnext/package-core/run.lua`:

```lua
-- Hermetic runner for the Docstyle vNext WP2 package core.
-- Usage: quarto run tests/vnext/package-core/run.lua
local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local root = pandoc.path.normalize(pandoc.path.join({ here, "..", "..", ".." }))
local core = root .. "/_extensions/docstyle/vnext/package-core"

package.path = table.concat({
  here .. "/?.lua",
  here .. "/?/init.lua",
  core .. "/?.lua",
  core .. "/?/init.lua",
}, ";")

local harness = require("lib.harness")
local stage, options = harness.runner_options(os.getenv)
return harness.discover_and_run(here, stage, options)
```

Apply the Step-2 require table to every moved test. Then two content adaptations:

1. `test-xml-adapter.lua`: delete the selection-provenance case (the one asserting `provenance.xml_candidate_selection.selected == "LuaXML"` / `status == "conditional-go"` against `dev/vnext/xml-spike/provenance.json`) — that is feasibility-record evidence, not production behaviour. Keep every functional, edit, preservation and rejection case.
2. `test-determinism.lua` + `lib/child.lua`: rename the child env vars `DOCSTYLE_SPIKE_CHILD_SOURCE`/`DOCSTYLE_SPIKE_CHILD_OUTPUT` to `DOCSTYLE_PACKAGE_CORE_CHILD_SOURCE`/`DOCSTYLE_PACKAGE_CORE_CHILD_OUTPUT` in both files; point the `run_child` spawn at `tests/vnext/package-core/lib/child.lua`; rewrite `child.lua`'s internal `package.path` to the production core tree (same pattern as `run.lua` above). Delete the case (or assertion block) that cross-checks `dev/vnext/xml-spike/determinism-results.json` — that JSON is the frozen spike record. Keep the live check: 10 fresh `quarto run` child processes, identical `edited_part_sha256`, `entry_names` and `archive_sha256` across all ten.
3. `test-publication.lua`: requires rewritten only — every case ports as-is (failure injection at `after_archive`/`after_close`/`after_verification`/`before_rename`, destination preservation, cleanup diagnostics `publication.cleanup` and `internal.lua-error`, output size/sequence validation, distinct-modtime preservation). Its fixtures moved with `fixtures/` in Step 4; fix any fixture paths that still say `xml-spike`.

- [ ] **Step 6: Run the promoted suite and confirm green**

Run: `quarto run tests/vnext/package-core/run.lua`
Expected: `FAIL 0`, `SKIP 0`, with pass counts per gate — archive, functional, preservation, safety and determinism all non-zero. The total is below the spike's 452 only by the feasibility-record cases left behind. Any `module 'X' not found` means a missed require rewrite; fix and re-run.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Promote WP2 package-core modules and guarantee tests to production

Move the selected spike modules, hermetic harness, publication and
determinism tests to _extensions/docstyle/vnext/package-core/ and
tests/vnext/package-core/, rewrite require paths, and add the init.lua
public surface. The feasibility record (selection, SLAXML, recorded
performance) stays frozen in the spike tree.

Relates to #27"
```

---

## Task 2: Aggregate the package-core suite into the conformance run

**Files:**
- Modify: `tests/vnext/conformance/run.lua`
- Test: the combined conformance run

**Interfaces:**
- Consumes: `tests/vnext/package-core/run.lua` (Task 1).
- Produces: `quarto run tests/vnext/conformance/run.lua` runs both suites; a failure in either makes the combined run fail (non-zero exit via the runner's existing `error(...)` path).

- [ ] **Step 1: Add the child-suite spawn to the conformance runner**

The WP1 conformance runner has no suite aggregation — it registers schemas, `dofile`s its own `tests/`, and validates schema examples. Aggregate by spawning the package-core suite as a child process (the same `pandoc.pipe`-spawns-`quarto run` pattern the determinism test uses). In `tests/vnext/conformance/run.lua`, immediately before the final `print(("PASS %d | FAIL %d"):format(pass, fail))`, insert:

```lua
-- 4. Aggregate the WP2 package-core suite. Combined semantics: both suites
-- must pass; a child failure is reported and fails this run.
local core_runner = pandoc.path.join({
  root, "tests", "vnext", "package-core", "run.lua",
})
local core_ok, core_output = pcall(function()
  return pandoc.pipe("quarto", { "run", core_runner }, "")
end)
if core_ok then
  local summary = tostring(core_output):match("(PASS %d+ | FAIL %d+ | SKIP %d+)")
  print("package-core: " .. (summary or "PASS (summary line not captured)"))
else
  fail_hard("runner/package-core", tostring(core_output))
end
```

(`root` and `fail_hard` already exist in this file. `pandoc.pipe` raises on a non-zero child exit, so a failing package-core suite lands in the `pcall` failure branch, increments `fail`, and the runner's existing `if fail > 0 then error(...)` makes the combined run exit non-zero.)

- [ ] **Step 2: Run the combined suite and confirm both report**

Run: `quarto run tests/vnext/conformance/run.lua`
Expected: the WP1 summary still `PASS 136 | FAIL 0`, plus a `package-core: PASS <n> | FAIL 0 | SKIP 0` line.

- [ ] **Step 3: Prove the failure path**

Temporarily add a failing case file `tests/vnext/package-core/tests/test-zz-sentinel.lua` containing `return { { name = "sentinel", gate = "functional", stage = "xml", fn = function() error("sentinel") end } }`, run the conformance suite, and confirm it reports `FAIL` and exits non-zero (`echo $?` is not `0`). Delete the sentinel file. Do not commit it.

- [ ] **Step 4: Confirm the R suite is unaffected**

Run: `env R_PROFILE_USER=/dev/null Rscript -e 'devtools::test(stop_on_failure = TRUE)'`
Expected: `FAIL 0 | WARN 30 | SKIP 4 | PASS 3400`.

- [ ] **Step 5: Commit**

```bash
git add tests/vnext/conformance/run.lua
git commit -m "Aggregate the package-core suite into the vNext conformance run

Relates to #27"
```

---

## Task 3: Effective package view and `inventory()`

**Files:**
- Modify: `_extensions/docstyle/vnext/package-core/opc.lua`
- Test: `tests/vnext/package-core/tests/test-inventory.lua`

**Interfaces:**
- Consumes: `open(path, limits, options) -> package`; existing `Package:part`, `Package:content_type`, `Package:relationships`.
- Produces (internal, consumed by Tasks 6–7 and the writer):
  - `Package:_effective_names() -> {zip_name, …}` — originals in central-directory order, then additions in sorted-name order.
  - `Package:_effective_bytes(zip_name) -> bytes` — additions, else replacements, else the bounded original read.
  - `Package:_effective_exists(zip_name) -> boolean` — normalized-name existence across originals and additions.
  - `Package:_effective_case_collision(zip_name) -> existing_name|nil` — ASCII-case-folded collision across originals and additions.
- Produces (public): `Package:inventory() -> { metadata = {part_name,…}, parts = {part_name,…}, content_types = {[part_name]=type|nil}, relationships = {[source]={record,…}} }` — records are copies; the package root `/` is included when it has relationships; malformed metadata raises (no `pcall` suppression).

- [ ] **Step 1: Write the failing test**

`tests/vnext/package-core/tests/test-inventory.lua` (confirm the exact office fixture filename with `ls tests/vnext/package-core/fixtures/office/`, and the part-name convention — leading slash — by reading `Package:part`):

```lua
local core = require("init")

local WORD = "tests/vnext/package-core/fixtures/office/word-native-comments.docx"

return {
  {
    name = "inventory separates metadata from parts and includes root relationships",
    gate = "functional",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD)
      local inv = pkg:inventory()
      local part_set, metadata_set = {}, {}
      for _, name in ipairs(inv.parts) do part_set[name] = true end
      for _, name in ipairs(inv.metadata) do metadata_set[name] = true end
      assert(part_set["/word/document.xml"], "document.xml is a part")
      assert(metadata_set["/[Content_Types].xml"], "content-types stream is metadata")
      assert(metadata_set["/_rels/.rels"], "root rels is metadata")
      assert(not part_set["/[Content_Types].xml"], "metadata is not listed as a part")
      assert(inv.content_types["/word/document.xml"] ~= nil,
        "document.xml resolves a content type")
      assert(inv.relationships["/"], "package-root relationships are reported")
    end,
  },
  {
    name = "inventory relationship records are copies, not package state",
    gate = "safety",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD)
      local inv = pkg:inventory()
      local source, record
      for src, records in pairs(inv.relationships) do
        source, record = src, records[1]
        break
      end
      assert(record, "expected at least one relationship record")
      local original_id = record.id
      record.id = "MUTATED"
      local again = pkg:inventory()
      assert(again.relationships[source][1].id == original_id,
        "mutating an inventory record must not change package state")
    end,
  },
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `quarto run tests/vnext/package-core/run.lua package`
Expected: FAIL — `attempt to call a nil value (method 'inventory')`.

- [ ] **Step 3: Implement the effective view**

In `opc.lua`: initialize `self._additions = {}` in the `Package` constructor (next to `_replacements`), then add (below the existing file-local helpers, so `normalize_percent_hex`, `ascii_lower`, `is_relationship_part` are in scope):

```lua
-- Effective package state: originals, replacements and additions as one
-- ordered, name-indexed view. Every lookup, collision check, relationship
-- resolution, size validation and the writer consult these helpers.
function Package:_effective_names()
  local names = {}
  for _, entry in ipairs(self.entries) do
    names[#names + 1] = entry.name
  end
  local added = {}
  for zip_name in pairs(self._additions) do added[#added + 1] = zip_name end
  table.sort(added)
  for _, zip_name in ipairs(added) do names[#names + 1] = zip_name end
  return names
end

function Package:_effective_bytes(zip_name)
  if self._additions[zip_name] ~= nil then return self._additions[zip_name] end
  if self._replacements[zip_name] ~= nil then return self._replacements[zip_name] end
  return self:_read_zip_entry(zip_name)
end

function Package:_effective_exists(zip_name)
  local normalized = normalize_percent_hex(zip_name)
  if self._entries_by_normalized_name[normalized] then return true end
  for added in pairs(self._additions) do
    if normalize_percent_hex(added) == normalized then return true end
  end
  return false
end

function Package:_effective_case_collision(zip_name)
  local folded = ascii_lower(normalize_percent_hex(zip_name))
  for _, entry in ipairs(self.entries) do
    if ascii_lower(normalize_percent_hex(entry.name)) == folded then
      return entry.name
    end
  end
  for added in pairs(self._additions) do
    if ascii_lower(normalize_percent_hex(added)) == folded then
      return added
    end
  end
  return nil
end
```

Route `Package:relationships` reads through the effective view: in its body, replace the entry lookup and read —

```lua
  local entry = self._entries_by_name[relationship_zip]
  local added = self._additions[relationship_zip]
  if not entry and not added then
    -- (existing missing-part handling unchanged: raise for "/", cache {} otherwise)
  end
  local document = xml_adapter.parse(self:_effective_bytes(relationship_zip))
```

(`_effective_bytes` must not call `_read_zip_entry` for an addition-only name; the addition branch returns first, so it does not.)

- [ ] **Step 4: Implement `Package:inventory`**

```lua
local function is_metadata_stream(zip_name)
  return zip_name == "[Content_Types].xml" or is_relationship_part(zip_name)
end

local function copy_relationship_records(records)
  local copies = {}
  for index, record in ipairs(records) do
    local copy = {}
    for key, value in pairs(record) do copy[key] = value end
    copies[index] = copy
  end
  return copies
end

function Package:inventory()
  local metadata, parts, content_types = {}, {}, {}
  for _, zip_name in ipairs(self:_effective_names()) do
    if is_metadata_stream(zip_name) then
      metadata[#metadata + 1] = "/" .. zip_name
    else
      local part_name = "/" .. zip_name
      parts[#parts + 1] = part_name
      content_types[part_name] = self:content_type(part_name)
    end
  end
  local relationships = {}
  local root_records = self:relationships("/")
  if #root_records > 0 then
    relationships["/"] = copy_relationship_records(root_records)
  end
  for _, part_name in ipairs(parts) do
    local records = self:relationships(part_name)  -- malformed metadata raises
    if #records > 0 then
      relationships[part_name] = copy_relationship_records(records)
    end
  end
  return {
    metadata = metadata,
    parts = parts,
    content_types = content_types,
    relationships = relationships,
  }
end
```

Note the two deliberate contrasts with the naive version: metadata streams are never passed to `content_type()` (whose part-name validator rejects `[Content_Types].xml` by design), and there is no `pcall` around `relationships()` — malformed relationship metadata fails closed.

- [ ] **Step 5: Run to verify it passes, then run the whole suite**

Run: `quarto run tests/vnext/package-core/run.lua`
Expected: new cases PASS; `FAIL 0` overall (the relationships read-path change is behaviour-preserving for packages with no additions or replacements).

- [ ] **Step 6: Commit**

```bash
git add _extensions/docstyle/vnext/package-core/opc.lua tests/vnext/package-core/tests/test-inventory.lua
git commit -m "Add the effective package view and inventory read method

Relates to #27"
```

---

## Task 4: Multi-edit XML with insertion support

**Files:**
- Modify: `_extensions/docstyle/vnext/package-core/xml/adapter.lua` (`register_edit`, new `append_element`)
- Modify: `_extensions/docstyle/vnext/package-core/xml/token_overlay.lua` (`M.serialize`, export escaping)
- Test: `tests/vnext/package-core/tests/test-multi-edit.lua`

**Interfaces:**
- Consumes: `xml.parse`, `xml.find_all`, `xml.set_attribute`, `xml.replace_text`, `xml.serialize`; `lib.oracle` for independent verification.
- Produces: `xml.serialize(document) -> bytes, ranges` applies every registered edit (attribute, text, insertion); intersecting ranges raise `xml.overlapping-edits`; editing the same token twice raises `xml.edit-target`; `xml.append_element(document, node, name, attributes) -> nil` registers a zero-width insertion of `<name attr="…"…/>` at `node`'s end-tag offset with escaped attribute values; `token_overlay.escape_attribute(value, quote)` is exported for the adapter.

- [ ] **Step 1: Write the failing tests**

`tests/vnext/package-core/tests/test-multi-edit.lua`:

```lua
local xml = require("xml")
local oracle = require("lib.oracle")
local diagnostic = require("lib.diagnostic")

local SOURCE =
  '<?xml version="1.0" encoding="UTF-8"?>' ..
  '<w:p xmlns:w="urn:w" w:one="A" w:two="B"><w:t>hello</w:t></w:p>'

return {
  {
    name = "two attribute edits and a text edit all apply, oracle-verified",
    gate = "functional",
    stage = "xml",
    fn = function()
      local doc = xml.parse(SOURCE)
      local p = xml.find_all(doc, "urn:w", "p")[1]
      local t = xml.find_all(doc, "urn:w", "t")[1]
      xml.set_attribute(doc, p, "urn:w", "one", "X")
      xml.set_attribute(doc, p, "urn:w", "two", "Y")
      xml.replace_text(doc, t, "world")
      local out, ranges = xml.serialize(doc)
      assert(#ranges == 3, "three edit ranges expected, got " .. #ranges)
      -- Independent verification: reparse through the oracle and confirm the
      -- expanded names and edited values, and that bytes outside the reported
      -- ranges are unchanged. Mirror the oracle call pattern used by the
      -- promoted adapter edit cases in test-xml-adapter.lua (read that file
      -- for the exact verify_edit signature) rather than substring checks.
      oracle.verify_edit(SOURCE, out, ranges)
      local reparsed = xml.parse(out)
      local p2 = xml.find_all(reparsed, "urn:w", "p")[1]
      assert(xml.get_attribute(p2, "urn:w", "one") == "X")
      assert(xml.get_attribute(p2, "urn:w", "two") == "Y")
    end,
  },
  {
    name = "editing the same token twice is rejected",
    gate = "safety",
    stage = "xml",
    fn = function()
      local doc = xml.parse(SOURCE)
      local p = xml.find_all(doc, "urn:w", "p")[1]
      xml.set_attribute(doc, p, "urn:w", "one", "X")
      local ok, err = diagnostic.capture(function()
        xml.set_attribute(doc, p, "urn:w", "one", "Z")
      end)
      assert(not ok, "second edit of one token must be rejected")
      assert(err.code == "xml.edit-target", tostring(err))
    end,
  },
  {
    name = "overlapping edit ranges are rejected at serialize",
    gate = "safety",
    stage = "xml",
    fn = function()
      local overlay = require("xml.token_overlay")
      local document = {
        source = "0123456789",
        edits = {
          { target = {}, seq = 1, range = { start = 2, finish = 6 }, replacement = "AA" },
          { target = {}, seq = 2, range = { start = 4, finish = 8 }, replacement = "BB" },
        },
      }
      local ok, err = diagnostic.capture(function()
        overlay.serialize(document)
      end)
      assert(not ok, "overlapping ranges must be rejected")
      assert(err.code == "xml.overlapping-edits", tostring(err))
    end,
  },
  {
    name = "append_element inserts an escaped empty element before the close tag",
    gate = "functional",
    stage = "xml",
    fn = function()
      local doc = xml.parse(SOURCE)
      local p = xml.find_all(doc, "urn:w", "p")[1]
      xml.append_element(doc, p, "w:extra", {
        { name = "w:val", value = 'a&b<c>"d' },
      })
      local out = xml.serialize(doc)
      assert(out:find('<w:extra w:val="a&amp;b&lt;c&gt;&quot;d"/></w:p>', 1, true),
        "escaped insertion before the parent close tag: " .. out)
      xml.parse(out)  -- the result must still be strict-valid
    end,
  },
}
```

(Adapter API note: the spike's `set_attribute(node, …)` reaches the document via `node.document`; if so, drop the `doc` first argument in these calls to match — confirm against `xml/adapter.lua` and keep the promoted signature, since the interface settlement is module functions with the tested shapes.)

- [ ] **Step 2: Run to verify failure**

Run: `quarto run tests/vnext/package-core/run.lua xml`
Expected: FAIL — the second `set_attribute` raises the spike's one-edit `xml.edit-target`, and `append_element` is nil.

- [ ] **Step 3: Collect edits as a sequenced list**

In `xml/adapter.lua`, replace `register_edit`:

```lua
local function register_edit(document, target, range, replacement, value)
  document.edits = document.edits or {}
  for _, existing in ipairs(document.edits) do
    if existing.target == target then
      raise("xml.edit-target", "a token may be edited at most once")
    end
  end
  document.edits[#document.edits + 1] = {
    target = target,
    seq = #document.edits + 1,
    range = range,
    replacement = replacement,
    value = value,
  }
end
```

- [ ] **Step 4: Apply every edit in one pass, right-to-left**

In `xml/token_overlay.lua`, replace `M.serialize` (and export the existing local `escape_attribute` as `M.escape_attribute = escape_attribute`):

```lua
function M.serialize(document)
  local edits = document.edits or {}
  if #edits == 0 then return document.source, {} end
  local ordered = {}
  for index, edit in ipairs(edits) do ordered[index] = edit end
  table.sort(ordered, function(a, b)
    if a.range.start ~= b.range.start then
      return a.range.start < b.range.start
    end
    return a.seq < b.seq
  end)
  -- Half-open interval intersection; zero-width insertions never intersect.
  for index = 2, #ordered do
    local previous, current = ordered[index - 1], ordered[index]
    if math.max(previous.range.start, current.range.start) <
        math.min(previous.range.finish, current.range.finish) then
      raise("xml.overlapping-edits", "XML edits overlap", {
        first = previous.range,
        second = current.range,
      })
    end
  end
  -- Apply from the highest offset down so earlier replacements do not shift
  -- offsets still to be applied. Same-offset insertions: the later list
  -- position is applied first, which leaves them in registration order.
  local result = document.source
  for index = #ordered, 1, -1 do
    result = replace_range(result, ordered[index].range,
      ordered[index].replacement)
  end
  local ranges = {}
  for _, edit in ipairs(ordered) do
    ranges[#ranges + 1] = common.range(edit.range.start, edit.range.finish)
  end
  return result, ranges
end
```

- [ ] **Step 5: Implement `append_element`**

In `xml/adapter.lua`. The insertion offset is the start of the parent's end-tag token. The strict document's event stream carries end-tag ranges; read `overlay.bind` and expose the element's end-tag range on the bound node as `node.end_tag_range` (a small `bind` extension mirroring how `range` is already attached), then:

```lua
function M.append_element(document, node, name, attributes)
  assert_document(document)
  assert_node(node)
  if type(name) ~= "string" or name == "" then
    raise("xml.invalid-input", "element name is required")
  end
  if not node.end_tag_range then
    raise("xml.edit-target",
      "append_element requires an element with a separate end tag", {})
  end
  local pieces = { "<", name }
  for _, attribute in ipairs(attributes or {}) do
    pieces[#pieces + 1] = (' %s="%s"'):format(
      attribute.name, overlay.escape_attribute(attribute.value, '"'))
  end
  pieces[#pieces + 1] = "/>"
  local offset = node.end_tag_range.start
  register_edit(document, { insertion = true, at = offset },
    { start = offset, finish = offset }, table.concat(pieces))
end
```

(Attribute *names* are caller-supplied qualified names; the package core passes only fixed literals — `PartName`, `ContentType`, `Id`, `Type`, `Target`, `TargetMode`. Values are always escaped. If `bind` does not currently record end-tag ranges, extend it: the strictness event list contains the end-tag event with its half-open range; attach it to the node when the end-tag event closes that element.)

- [ ] **Step 6: Run the suite**

Run: `quarto run tests/vnext/package-core/run.lua`
Expected: `FAIL 0` — the new cases pass and every promoted single-edit case still passes (a single edit is the one-element list).

- [ ] **Step 7: Commit**

```bash
git add _extensions/docstyle/vnext/package-core/xml tests/vnext/package-core/tests/test-multi-edit.lua
git commit -m "Support multiple non-overlapping XML edits and safe element insertion

Relates to #27"
```

---

## Task 5: Enforce the XML-part input-byte limit before parsing

**Files:**
- Modify: `_extensions/docstyle/vnext/package-core/xml/adapter.lua` (`M.parse`, `M.MAX_INPUT_BYTES`)
- Test: `tests/vnext/package-core/tests/test-xml-limit.lua`
- Measurement: `dev/vnext/package-core/part-size-survey.lua`

**Interfaces:**
- Consumes: `xml.parse(bytes, options)`.
- Produces: `xml.MAX_INPUT_BYTES = 1048576`; `xml.parse` raises `xml.input-too-large` (context: `actual`, `limit`) before tokenizing when `#bytes > limit`; a `max_input_bytes` override that is not a non-negative integer raises `xml.invalid-limit`.

- [ ] **Step 1: Survey WP0 part sizes**

Create `dev/vnext/package-core/part-size-survey.lua`: for each `.docx` under `tests/vnext/fixtures/*/baseline/legacy/` and `tests/vnext/package-core/fixtures/office/`, open it with `core.open` and print `part_name<TAB>byte_length` per part plus a final maximum line. Run:

```bash
quarto run dev/vnext/package-core/part-size-survey.lua
```

Record the largest WordprocessingML part in the Task commit message. If any real part exceeds 1 MiB, raise the candidate limit to the next power of two above the maximum and carry the change through this task and the spec.

- [ ] **Step 2: Write the failing test**

`tests/vnext/package-core/tests/test-xml-limit.lua`:

```lua
local xml = require("xml")
local diagnostic = require("lib.diagnostic")

return {
  {
    name = "the default XML-part input-byte limit is one MiB",
    gate = "safety",
    stage = "xml",
    fn = function()
      assert(xml.MAX_INPUT_BYTES == 1048576, tostring(xml.MAX_INPUT_BYTES))
    end,
  },
  {
    name = "an over-limit part is rejected before parsing",
    gate = "safety",
    stage = "xml",
    fn = function()
      local oversize = string.rep("x", 1048577)
      local ok, err = diagnostic.capture(function()
        xml.parse(oversize)
      end)
      assert(not ok, "over-limit input must be rejected")
      assert(err.code == "xml.input-too-large", tostring(err))
      assert(err.context.actual == 1048577, tostring(err.context.actual))
      assert(err.context.limit == 1048576, tostring(err.context.limit))
    end,
  },
  {
    name = "a malformed limit override is rejected",
    gate = "safety",
    stage = "xml",
    fn = function()
      for _, bad in ipairs({ -1, 1.5, "1048576", true }) do
        local ok, err = diagnostic.capture(function()
          xml.parse("<r/>", { max_input_bytes = bad })
        end)
        assert(not ok, "malformed limit must be rejected: " .. tostring(bad))
        assert(err.code == "xml.invalid-limit", tostring(err))
      end
    end,
  },
  {
    name = "an explicit override permits a larger input",
    gate = "functional",
    stage = "xml",
    fn = function()
      local big = '<?xml version="1.0"?><r a="' ..
        string.rep("x", 1100000) .. '"/>'
      local doc = xml.parse(big, { max_input_bytes = 2 * 1048576 })
      assert(doc, "override must permit parsing above the default limit")
    end,
  },
}
```

- [ ] **Step 3: Run to verify failure**

Run: `quarto run tests/vnext/package-core/run.lua xml`
Expected: FAIL — `xml.MAX_INPUT_BYTES` is nil; no `xml.input-too-large` raised.

- [ ] **Step 4: Implement the guard**

In `xml/adapter.lua`:

```lua
M.MAX_INPUT_BYTES = 1048576  -- XML-part input-byte limit (WP2 design; decision provenance)

function M.parse(xml_bytes, options)
  options = options or {}
  local limit = options.max_input_bytes
  if limit == nil then
    limit = M.MAX_INPUT_BYTES
  elseif math.type(limit) ~= "integer" or limit < 0 then
    raise("xml.invalid-limit",
      "max_input_bytes must be a non-negative integer", {
        max_input_bytes = tostring(limit),
      })
  end
  if #xml_bytes > limit then
    raise("xml.input-too-large",
      "XML part exceeds the input-byte limit; rejected before parsing", {
        actual = #xml_bytes,
        limit = limit,
      })
  end
  local strict_document = strictness.inspect(xml_bytes, options)
  local backend_events = overlay.luaxml_events(
    luaxml, strict_document.semantic_xml)
  return overlay.bind(
    xml_bytes, strict_document, backend_events, "dev@c919471")
end
```

- [ ] **Step 5: Run the whole suite**

Run: `quarto run tests/vnext/package-core/run.lua`
Expected: `FAIL 0` — real packages open unaffected (content-types and rels streams are far below the limit).

- [ ] **Step 6: Commit**

```bash
git add _extensions/docstyle/vnext/package-core tests/vnext/package-core/tests/test-xml-limit.lua
git add -f dev/vnext/package-core/part-size-survey.lua
git commit -m "Enforce the XML-part input-byte limit before parsing

Largest observed WP0 WordprocessingML part: <N> bytes; limit 1048576
bytes. Realizes the pre_parse_rejection_required contract from the
merged decision provenance.

Relates to #27"
```

---

## Task 6: `add_part()` integrated through the effective view

**Files:**
- Modify: `_extensions/docstyle/vnext/package-core/opc.lua` (`add_part`, content-type registration via `append_element`, `part`/`content_type` for additions)
- Modify: `_extensions/docstyle/vnext/package-core/writer.lua` (effective entries, size validation, post-publication verification)
- Test: `tests/vnext/package-core/tests/test-add-part.lua`

**Interfaces:**
- Consumes: the effective view (Task 3), `xml.append_element` (Task 4).
- Produces: `Package:add_part(part_name, bytes, content_type)`; added parts readable via `Package:part`, typed via `Package:content_type`, listed by `inventory()`; `write_atomic` publishes originals-then-sorted-additions with the fixed modtime and verifies the completed archive against the effective name sequence. Diagnostics: `opc.add-part-collision`, `opc.add-part-case-collision`, `opc.invalid-addition`, `opc.metadata-replacement`.

- [ ] **Step 1: Write the failing tests**

`tests/vnext/package-core/tests/test-add-part.lua`:

```lua
local fixture = require("lib.fixture")
local core = require("init")
local diagnostic = require("lib.diagnostic")

local WORD = "tests/vnext/package-core/fixtures/office/word-native-comments.docx"

return {
  {
    name = "an added part round-trips through write_atomic",
    gate = "functional",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("add-part", function(dir)
        local out = dir .. "/out.docx"
        local pkg = core.open(WORD)
        pkg:add_part("/word/custom.xml",
          '<?xml version="1.0"?><root/>', "application/xml")
        assert(pkg:part("/word/custom.xml") ==
          '<?xml version="1.0"?><root/>', "added part readable before publish")
        pkg:write_atomic(out)

        local reopened = core.open(out)
        assert(reopened:part("/word/custom.xml") ==
          '<?xml version="1.0"?><root/>', "added part bytes survive")
        assert(reopened:content_type("/word/custom.xml") == "application/xml",
          "added content type survives")
        assert(reopened:part("/word/document.xml") ~= nil,
          "original parts untouched")
      end)
    end,
  },
  {
    name = "adding an existing part name fails closed",
    gate = "safety",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD)
      local ok, err = diagnostic.capture(function()
        pkg:add_part("/word/document.xml", "x", "application/xml")
      end)
      assert(not ok)
      assert(err.code == "opc.add-part-collision", tostring(err))
    end,
  },
  {
    name = "a name differing only in ASCII case from an original fails closed",
    gate = "safety",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD)
      local ok, err = diagnostic.capture(function()
        pkg:add_part("/word/DOCUMENT.xml", "x", "application/xml")
      end)
      assert(not ok)
      assert(err.code == "opc.add-part-case-collision", tostring(err))
    end,
  },
  {
    name = "a name differing only in ASCII case from a prior addition fails closed",
    gate = "safety",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD)
      pkg:add_part("/word/custom.xml", "<root/>", "application/xml")
      local ok, err = diagnostic.capture(function()
        pkg:add_part("/word/CUSTOM.xml", "<root/>", "application/xml")
      end)
      assert(not ok)
      assert(err.code == "opc.add-part-case-collision", tostring(err))
    end,
  },
  {
    name = "two publishes of the same additions are byte-identical",
    gate = "determinism",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("add-part-det", function(dir)
        local outputs = {}
        for run = 1, 2 do
          local out = dir .. "/out-" .. run .. ".docx"
          local pkg = core.open(WORD)
          pkg:add_part("/word/b.xml", "<b/>", "application/xml")
          pkg:add_part("/word/a.xml", "<a/>", "application/xml")
          pkg:write_atomic(out)
          outputs[run] = fixture.read_bytes(out)
        end
        assert(outputs[1] == outputs[2], "publication must be deterministic")
      end)
    end,
  },
}
```

- [ ] **Step 2: Run to verify failure**

Run: `quarto run tests/vnext/package-core/run.lua package`
Expected: FAIL — `attempt to call a nil value (method 'add_part')`.

- [ ] **Step 3: Implement `add_part` and content-type registration**

In `opc.lua`:

```lua
function Package:add_part(part_name, bytes, content_type)
  local zip_name = zip_name_for_part(part_name)
  if is_relationship_part(zip_name) then
    raise("opc.metadata-replacement",
      "relationship metadata is not added through add_part", {
        part_name = part_name,
      })
  end
  if type(bytes) ~= "string" then
    raise("opc.invalid-addition", "added part must be a byte string", {
      part_name = part_name,
    })
  end
  if type(content_type) ~= "string" or content_type == "" then
    raise("opc.invalid-addition", "added part requires a content type", {
      part_name = part_name,
    })
  end
  if self:_effective_exists(zip_name) then
    raise("opc.add-part-collision", "a part with this name already exists", {
      part_name = part_name,
    })
  end
  local collision = self:_effective_case_collision(zip_name)
  if collision then
    raise("opc.add-part-case-collision",
      "a name differing only in ASCII case already exists", {
        part_name = part_name,
        existing = collision,
      })
  end
  self:_register_content_type_override(part_name, content_type)
  self._additions[zip_name] = bytes
  self._content_type_overrides[normalize_percent_hex(zip_name)] = content_type
end

function Package:_register_content_type_override(part_name, content_type)
  local current = self._replacements["[Content_Types].xml"]
    or self:_read_zip_entry("[Content_Types].xml", "opc.content-types-missing")
  local document = xml_adapter.parse(current)
  xml_adapter.append_element(document, document.root, "Override", {
    { name = "PartName", value = part_name },
    { name = "ContentType", value = content_type },
  })
  self._replacements["[Content_Types].xml"] = xml_adapter.serialize(document)
end
```

(No `gsub`: the Override is inserted by the escaped, strictness-validated `append_element` at the validated `Types` root's end-tag offset. `document.root` — confirm the bound document exposes the root node under that field; the spike's `assert_root` reads `document.root`, so it does.)

Extend the read paths for additions: in `require_entry` (or at the top of `Package:part` and `Package:content_type` before `require_entry` raises), consult the effective view —

```lua
function Package:part(part_name)
  local zip_name = zip_name_for_part(part_name)
  if self._additions[zip_name] ~= nil then
    return self._additions[zip_name]
  end
  local required = require_entry(self, part_name)
  -- (existing body unchanged from here, using `required`)
```

and in `Package:content_type`, resolve the zip name the same way before `require_entry` so an added part's override is returned.

- [ ] **Step 4: Integrate additions into the writer**

In `writer.lua`:

```lua
local ADDED_ENTRY_MODTIME = 315532800  -- 1980-01-01T00:00:00Z, the ZIP epoch

local function sorted_addition_names(pkg)
  local names = {}
  for zip_name in pairs(pkg._additions or {}) do
    names[#names + 1] = zip_name
  end
  table.sort(names)
  return names
end
```

In `archive_entries`, after the existing validated-originals loop, append:

```lua
  for _, zip_name in ipairs(sorted_addition_names(pkg)) do
    entries[#entries + 1] = pandoc.zip.Entry(
      zip_name, pkg._additions[zip_name], ADDED_ENTRY_MODTIME)
  end
```

In `validate_output_sizes`, after the originals loop, add the additions with the same entry and running-total checks (sorted iteration, same `publication.entry-limit` / `publication.total-limit` raises, `total = total + #bytes`).

Fix the post-publication verification in `publish` — replace the `#verified.entries ~= #pkg.entries` count check and the per-index originals loop with the effective sequence:

```lua
    local expected_names = pkg:_effective_names()
    if #verified.entries ~= #expected_names then
      raise("publication.verification",
        "completed package entry count changed", {
          expected = #expected_names,
          actual = #verified.entries,
        })
    end
    for index, expected in ipairs(expected_names) do
      if verified.entries[index].name ~= expected then
        raise("publication.verification",
          "completed package entry sequence changed", {
            index = index,
            expected = expected,
            actual = verified.entries[index].name,
          })
      end
    end
```

- [ ] **Step 5: Run the add-part tests, then the whole suite**

Run: `quarto run tests/vnext/package-core/run.lua`
Expected: all five new cases PASS (including the round-trip — the verification now expects the effective sequence — and the determinism double-publish); every promoted publication and preservation case still passes (no additions ⇒ `_effective_names()` equals the original sequence).

- [ ] **Step 6: Commit**

```bash
git add _extensions/docstyle/vnext/package-core tests/vnext/package-core/tests/test-add-part.lua
git commit -m "Add new parts through the effective view with verified publication

Relates to #27"
```

---

## Task 7: `add_relationship()` with minted ids

**Files:**
- Modify: `_extensions/docstyle/vnext/package-core/opc.lua`
- Test: `tests/vnext/package-core/tests/test-add-relationship.lua`

**Interfaces:**
- Consumes: effective view (Task 3), `xml.append_element` (Task 4), `Package:relationships` (effective-aware since Task 3).
- Produces: `Package:add_relationship(source_part, rel_type, target, mode) -> rId`. Minting scans the source's current (effective) relationship records for the highest `rIdN` and returns `rId(N+1)`; repeated calls mint distinct ids because `relationships()` re-reads effective bytes after cache invalidation. Internal targets must resolve to an existing or added part (`opc.relationship-target-missing` otherwise); external targets are stored with `TargetMode="External"` and never fetched. `source_part == "/"` is rejected (`opc.metadata-replacement`) — root-relationship addition is deferred until a consumer exists. `replace_part` on any rels part still raises `opc.metadata-replacement`; `add_relationship` is the only sanctioned rels mutation.

- [ ] **Step 1: Write the failing tests**

`tests/vnext/package-core/tests/test-add-relationship.lua`:

```lua
local fixture = require("lib.fixture")
local core = require("init")
local diagnostic = require("lib.diagnostic")

local WORD = "tests/vnext/package-core/fixtures/office/word-native-comments.docx"

return {
  {
    name = "an added internal relationship round-trips with a fresh id",
    gate = "functional",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("add-rel", function(dir)
        local out = dir .. "/out.docx"
        local pkg = core.open(WORD)
        pkg:add_part("/word/custom.xml", '<?xml version="1.0"?><root/>',
          "application/xml")
        local rid = pkg:add_relationship("/word/document.xml",
          "http://schemas.example.org/custom", "custom.xml", "Internal")
        assert(rid:match("^rId%d+$"), tostring(rid))
        pkg:write_atomic(out)

        local reopened = core.open(out)
        local found
        for _, record in ipairs(reopened:relationships("/word/document.xml")) do
          if record.id == rid then found = record end
        end
        assert(found, "added relationship survives")
        assert(found.resolved_part == "/word/custom.xml", tostring(found.resolved_part))
      end)
    end,
  },
  {
    name = "repeated additions mint distinct ids",
    gate = "safety",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD)
      pkg:add_part("/word/c1.xml", "<a/>", "application/xml")
      pkg:add_part("/word/c2.xml", "<b/>", "application/xml")
      local first = pkg:add_relationship("/word/document.xml",
        "http://schemas.example.org/custom", "c1.xml", "Internal")
      local second = pkg:add_relationship("/word/document.xml",
        "http://schemas.example.org/custom", "c2.xml", "Internal")
      assert(first ~= second, first .. " reused")
      local existing = {}
      for _, record in ipairs(pkg:relationships("/word/document.xml")) do
        assert(not existing[record.id], "duplicate id " .. record.id)
        existing[record.id] = true
      end
      assert(existing[first] and existing[second], "both additions present")
    end,
  },
  {
    name = "an external relationship stores TargetMode and is never resolved",
    gate = "functional",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("add-rel-ext", function(dir)
        local out = dir .. "/out.docx"
        local pkg = core.open(WORD)
        local rid = pkg:add_relationship("/word/document.xml",
          "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink",
          "https://example.org/page?a=1&b=2", "External")
        pkg:write_atomic(out)
        local reopened = core.open(out)
        local found
        for _, record in ipairs(reopened:relationships("/word/document.xml")) do
          if record.id == rid then found = record end
        end
        assert(found, "external relationship survives")
        assert(found.external == true and found.target_mode == "External")
        assert(found.target == "https://example.org/page?a=1&b=2",
          "raw target (with &) survives escaping and reparsing: " .. tostring(found.target))
        assert(found.resolved_part == nil, "external targets are never resolved")
      end)
    end,
  },
  {
    name = "an internal target that resolves to no part fails closed",
    gate = "safety",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD)
      local ok, err = diagnostic.capture(function()
        pkg:add_relationship("/word/document.xml",
          "http://schemas.example.org/custom", "missing.xml", "Internal")
      end)
      assert(not ok)
      assert(err.code == "opc.relationship-target-missing", tostring(err))
    end,
  },
  {
    name = "replace_part on a rels part is still rejected",
    gate = "safety",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD)
      local ok, err = diagnostic.capture(function()
        pkg:replace_part("/word/_rels/document.xml.rels", "x")
      end)
      assert(not ok)
      assert(err.code == "opc.metadata-replacement", tostring(err))
    end,
  },
  {
    name = "root-relationship addition is deferred and rejected",
    gate = "safety",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD)
      local ok, err = diagnostic.capture(function()
        pkg:add_relationship("/", "http://schemas.example.org/custom",
          "word/custom.xml", "Internal")
      end)
      assert(not ok)
      assert(err.code == "opc.metadata-replacement", tostring(err))
    end,
  },
}
```

- [ ] **Step 2: Run to verify failure**

Run: `quarto run tests/vnext/package-core/run.lua package`
Expected: FAIL — `attempt to call a nil value (method 'add_relationship')`.

- [ ] **Step 3: Implement `add_relationship`**

In `opc.lua` (below `resolve_literal_target`, `relationship_zip_name` and the effective helpers, all in scope). First make internal-target resolution effective-aware: in `resolve_literal_target`, replace the final entry lookup —

```lua
  local zip_name = zip_name_for_part(resolved)
  local entry = self._entries_by_normalized_name[
    normalize_percent_hex(zip_name)]
  if not entry and not self:_effective_exists(zip_name) then
    raise("opc.relationship-target-missing", …)  -- existing raise unchanged
  end
  if entry then
    return "/" .. entry.name, fragment,
      table.concat(normalized_segments, "/")
  end
  return resolved, fragment, table.concat(normalized_segments, "/")
```

Then the method and mint helper:

```lua
local function next_relationship_id(records)
  local max = 0
  for _, record in ipairs(records) do
    local n = tonumber(record.id:match("^rId(%d+)$"))
    if n and n > max then max = n end
  end
  return "rId" .. (max + 1)
end

function Package:add_relationship(source_part, rel_type, target, mode)
  mode = mode or "Internal"
  if source_part == "/" then
    raise("opc.metadata-replacement",
      "package-root relationship addition is not supported", {})
  end
  if mode ~= "Internal" and mode ~= "External" then
    raise("opc.invalid-target-mode", "mode must be Internal or External", {
      mode = mode,
    })
  end
  if type(rel_type) ~= "string" or rel_type == "" or
      type(target) ~= "string" or target == "" then
    raise("opc.invalid-relationship",
      "relationship requires a type and a target", {
        source_part = source_part,
      })
  end
  local records = self:relationships(source_part)
  local rid = next_relationship_id(records)
  if mode == "Internal" then
    -- Validates and resolves against the effective view; raises
    -- opc.relationship-target-missing when nothing matches.
    resolve_literal_target(self, source_part, target, {
      relationship_part = relationship_zip_name(source_part),
      relationship_id = rid,
    })
  end
  local relationship_zip = relationship_zip_name(source_part)
  local attributes = {
    { name = "Id", value = rid },
    { name = "Type", value = rel_type },
    { name = "Target", value = target },
  }
  if mode == "External" then
    attributes[#attributes + 1] = { name = "TargetMode", value = "External" }
  end
  local current = self._additions[relationship_zip]
    or self._replacements[relationship_zip]
    or (self._entries_by_name[relationship_zip]
        and self:_read_zip_entry(relationship_zip))
  if current then
    local document = xml_adapter.parse(current)
    assert_root(document, RELATIONSHIPS_NS, "Relationships",
      "opc.relationships-root", "relationships part")
    xml_adapter.append_element(document, document.root,
      "Relationship", attributes)
    local updated = xml_adapter.serialize(document)
    if self._additions[relationship_zip] then
      self._additions[relationship_zip] = updated
    else
      self._replacements[relationship_zip] = updated
    end
  else
    local pieces = {
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
      '<Relationships xmlns="', RELATIONSHIPS_NS, '">',
    }
    local document = xml_adapter.parse(table.concat(pieces) .. "</Relationships>")
    xml_adapter.append_element(document, document.root,
      "Relationship", attributes)
    self._additions[relationship_zip] = xml_adapter.serialize(document)
  end
  self._relationship_cache[relationship_zip] = nil
  return rid
end
```

(Both branches insert through `append_element` — escaped, structure-validated, no `gsub`. The `Relationships` root here is unprefixed with a default namespace, so the fixed child name `Relationship` inherits it; when an *existing* rels stream uses a namespace prefix on its root, the insertion offset still comes from the validated root node, but the unprefixed child would not be in the Relationships namespace — detect that case by checking the root's tag prefix (available on the bound node; confirm the field in `bind`) and reuse the root's prefix for the child name.)

- [ ] **Step 4: Run the add-relationship tests, then the whole suite**

Run: `quarto run tests/vnext/package-core/run.lua`
Expected: all six new cases PASS; `FAIL 0` overall. The rels streams produced here are re-validated on reopen by the existing relationships parser (duplicate-id, root-namespace and structure checks), so the round-trip cases prove the insertion is well-formed.

- [ ] **Step 5: Commit**

```bash
git add _extensions/docstyle/vnext/package-core/opc.lua tests/vnext/package-core/tests/test-add-relationship.lua
git commit -m "Add relationships with minted ids as the sanctioned rels mutation

Relates to #27"
```

---

## Task 8: Performance re-verification and acceptance sweep

**Files:**
- Create: `dev/vnext/package-core/performance.lua`
- Create: `dev/vnext/package-core/performance-results.json` (recorded output)

**Interfaces:**
- Consumes: the production `xml` module (Tasks 4–5).
- Produces: a recorded reference-performance result for the production module: hard retained-heap and scaling gates, the advisory 5-second CPU line on stderr, and the approved-limit latency check against the 0.75-second expectation. Stdout is exactly the JSON result.

- [ ] **Step 1: Port the reference benchmark to the production module**

Create `dev/vnext/package-core/performance.lua`, adapting the spike's protocol (1 warm-up + 5 repetitions, median, `pandoc.system.cputime`, retained heap = `max(0, collectgarbage("count") - init) * 1024` after collection at phase boundaries — copy the measurement mechanics from the spike's `test-performance.lua` `measure_reference`). Three obligations beyond the port:

1. **Override the limit for scaling cases.** Every `xml.parse` call in the benchmark passes `{ max_input_bytes = 16 * 1048576 }` — without this, the 5 and 10 MiB cases are rejected by the Task 5 default and the benchmark cannot run.
2. **Approved-limit latency.** Measure the 1 MiB case (exactly 1,048,576 bytes — the approved limit) and record `approved_limit_latency = { limit_bytes = 1048576, observed_median_seconds = …, observed_maximum_seconds = …, expectation_seconds = 0.75, met = <maximum <= 0.75> }` in the result.
3. **Stream separation.** The JSON result is the only stdout (`print(pandoc.json.encode(result))`); the advisory line goes to stderr:

```lua
io.stderr:write(("ADVISORY reference 10 MiB combined CPU: actual=%.6f s | target=5 s | met=%s\n")
  :format(ten_mib_median_cpu, tostring(ten_mib_median_cpu <= 5)))
```

Gates: retained heap at 10 MiB no more than 12× input (hard); 10 MiB:1 MiB CPU and retained-heap ratios no more than 15 (hard); the 5-second absolute CPU target advisory (reported, never asserted). `decision` in the JSON reflects the hard gates only.

- [ ] **Step 2: Run and record**

```bash
quarto run dev/vnext/package-core/performance.lua > dev/vnext/package-core/performance-results.json
python3 -c "import json; d=json.load(open('dev/vnext/package-core/performance-results.json')); print(d['decision'], d['approved_limit_latency'])"
```

Expected: stdout parses as JSON; `decision` is `pass` (hard gates); `approved_limit_latency.met` is recorded (either value is honest — if `false`, flag it to the reviewer rather than adjusting the expectation); the advisory line appeared on stderr.

- [ ] **Step 3: Full acceptance sweep**

```bash
quarto run tests/vnext/package-core/run.lua
quarto run tests/vnext/conformance/run.lua
env R_PROFILE_USER=/dev/null Rscript -e 'devtools::test(stop_on_failure = TRUE)'
git diff --exit-code origin/main -- tests/vnext/fixtures/
grep -rn 'require("archive\.\|require("candidates\.' _extensions/docstyle/vnext/package-core tests/vnext/package-core
grep -rn 'gsub("</' _extensions/docstyle/vnext/package-core
git diff --check
```

Expected: package-core `FAIL 0`; combined conformance green (WP1 `PASS 136 | FAIL 0` + package-core line); R `FAIL 0 | WARN 30 | SKIP 4 | PASS 3400`; WP0 fixtures unchanged; no stale requires; no closing-tag `gsub` anywhere in the core; whitespace clean.

- [ ] **Step 4: Verify the acceptance criteria against the spec**

Walk the spec's five acceptance criteria and record where each is proven: (1) production home + `init.lua`-only access + no R (Task 1 + the grep); (2) promoted gates green including publication and determinism (Tasks 1–2); (3) finalization primitives with tests and deterministic verified publication (Tasks 6–7); (4) limit set, enforced pre-parse, approved-limit latency recorded, hard gates pass (Tasks 5 + 8); (5) suite wired into conformance, WP0 fixtures unchanged (Task 2 + sweep).

- [ ] **Step 5: Commit**

```bash
git add dev/vnext/package-core
git add -f dev/vnext/package-core/performance.lua
git commit -m "Record WP2 package-core reference performance and acceptance sweep

Relates to #27"
```

---

## Self-review

**Spec coverage:** promote + isolate (Task 1), gate preservation incl. publication/determinism ports (Task 1), conformance aggregation with explicit combined-failure semantics (Task 2), effective view + inventory contract (Task 3), multi-edit + safe insertion primitive (Task 4), pre-parse limit with override validation (Task 5), `add_part` with case-collision against originals and additions plus writer verification (Task 6), `add_relationship` with distinct-id minting, external mode and rels immutability (Task 7), performance prerequisite incl. limit override, 0.75 s recording and stderr/stdout separation (Task 8). Non-goals have no tasks.

**Review-finding coverage:** effective view consulted by relationships/resolution/collisions/writer/verification (Tasks 3, 6, 7); no `gsub` insertion anywhere, enforced by the Task 8 grep; `[Content_Types].xml` never passed to `content_type()`; root relationships reported by inventory and copies returned; `pcall` suppression removed; `diagnostic.capture` two-value usage in every rejection test; publication + determinism tests ported with the spike-record cross-check removed; benchmark overrides the limit, records approved-limit latency, and keeps stdout valid JSON; conformance aggregation is explicit; interface settlements (module functions, `publication.*`, no `allocate_id`) are in the revised spec.

**Type consistency:** `document.edits` (list with `seq`) defined in Task 4 and consumed by its serialize; `Package:_effective_names/_effective_bytes/_effective_exists/_effective_case_collision` defined in Task 3, consumed in Tasks 6–7 and the writer; `xml.append_element` defined in Task 4, consumed in Tasks 6–7; `xml.MAX_INPUT_BYTES` defined and asserted in Task 5, overridden in Task 8; `sorted_addition_names` and `ADDED_ENTRY_MODTIME` defined and used in Task 6. Field names taken from the spike source (`self.entries`, `entry.name`, `_entries_by_name`, `_entries_by_normalized_name`, `_relationship_cache`, `RELATIONSHIPS_NS`, `document.root`) with confirm-notes where a field must be checked before editing.
