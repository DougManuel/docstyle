# WP2 package-core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote the WP2 feasibility spike's tested OOXML modules into a production Lua package-core library and extend it to the full package-finalization interface (add parts, add relationships, multi-edit XML) with the performance prerequisite satisfied.

**Architecture:** Move the selected spike modules by `git mv` into `_extensions/docstyle/vnext/package-core/`, rewrite their require paths, and prove the promoted hermetic suite stays green. Then harden and extend through TDD: a read-only `inventory()`, multiple non-overlapping XML edits per document, an explicit fail-closed XML-part input-byte limit, `add_part`, and `add_relationship`. A single `init.lua` is the only public surface.

**Tech Stack:** Pure Lua 5.4 on the Quarto-bundled Pandoc (`pandoc.zip`, `pandoc.path`, `pandoc.system`, `pandoc.json`, `pandoc.text`); vendored LuaXML and libdeflate; the hermetic `run.lua` harness driven by `quarto run`. No R, no LuaRocks, no native modules, no external ZIP tool.

## Global Constraints

- Runtime: Quarto 1.9.26 / Pandoc 3.8.3 / Lua 5.4. No R dependency in any package-core module. No LuaRocks, no native shared library, no external ZIP executable.
- Production home: `_extensions/docstyle/vnext/package-core/`. Public entry point is `init.lua`; nothing outside the tree requires an internal module directly.
- XML-part input-byte limit: candidate 1,048,576 bytes (1 MiB), enforced fail-closed before `xml.parse`. Visible configuration, never hidden.
- Determinism: output bytes and entry order are reproducible across fresh `quarto run` processes; added entries use a fixed modtime (do not read the wall clock).
- WP0 characterization fixtures under `tests/vnext/fixtures/` are immutable migration evidence. Never regenerate a baseline to make a test pass.
- Messaging and diagnostics use typed codes via `diagnostic.raise(code, message, context)`; codes are namespaced `zip.*`, `opc.*`, `xml.*`, `write.*`. No `print`/`io.write` in library modules (the reference performance case is the sole existing exception and stays in tests).
- The feasibility record — `dev/vnext/xml-spike/decision-report.md`, `provenance.json`, `performance-results.json`, `determinism-results.json` — is immutable and stays in place. Do not move or edit it.
- Commits: plain-text messages, no AI credit. `docs/` is gitignored; stage plan/spec files with `git add -f`.

---

## File structure

Production tree created by this plan (under `_extensions/docstyle/vnext/package-core/`):

| File | Origin | Responsibility |
|---|---|---|
| `init.lua` | new | Public surface: `open`, `xml`, `diagnostic`. |
| `lib/binary.lua` | `dev/vnext/xml-spike/lib/binary.lua` | Byte helpers. |
| `lib/diagnostic.lua` | `dev/vnext/xml-spike/lib/diagnostic.lua` | Typed diagnostics. |
| `zip.lua` | `archive/zip_preflight.lua` | Central-directory preflight. |
| `inflate.lua` | `archive/inflate_limited.lua` | Bounded decompression. |
| `entry.lua` | `archive/entry_reader.lua` | CRC/size-checked reads + budget. |
| `opc.lua` | `archive/opc.lua` | Package object; extended with `inventory`, `add_part`, `add_relationship`. |
| `writer.lua` | `archive/writer.lua` | Deterministic atomic publication; extended for additions. |
| `xml/init.lua` | new | Re-exports the adapter as module `xml`. |
| `xml/adapter.lua` | `candidates/luaxml/adapter.lua` | XML parse/find/edit/serialize; extended to multiple edits. |
| `xml/strictness.lua` | `candidates/luaxml/strictness.lua` | XML 1.0 / namespace strictness. |
| `xml/token_overlay.lua` | `candidates/luaxml/token_overlay.lua` | Byte-span overlay + serialize; extended to multiple edits. |
| `xml/common.lua` | `candidates/common.lua` | Shared range/name helpers. |
| `xml/vendor/…` | `candidates/luaxml/vendor/…` | Vendored LuaXML (unchanged). |
| `inflate/vendor/…` | existing libdeflate vendor path | Vendored libdeflate (unchanged). |

Test tree created by this plan (under `tests/vnext/package-core/`):

| File | Origin |
|---|---|
| `run.lua` | `tests/vnext/xml-spike/run.lua` (package.path rewritten) |
| `lib/harness.lua`, `lib/fixture.lua` | `tests/vnext/xml-spike/lib/…` |
| `lib/oracle.lua` | `dev/vnext/xml-spike/candidates/oracle.lua` (test-only judge) |
| `fixtures/…` | `tests/vnext/xml-spike/fixtures/…` |
| `tests/test-archive-preflight.lua` … | promoted spike tests (requires rewritten) |
| `tests/test-inventory.lua` | new (Task 3) |
| `tests/test-multi-edit.lua` | new (Task 4) |
| `tests/test-xml-limit.lua` | new (Task 5) |
| `tests/test-add-part.lua` | new (Task 6) |
| `tests/test-add-relationship.lua` | new (Task 7) |

The rejected SLAXML candidate (`candidates/slaxml/`, `tests/test-slaxml-adapter.lua`) and the feasibility-only selection/performance/determinism spike tests are **not** promoted; they remain in the spike tree as the feasibility record. The promoted suite keeps the archive, functional, preservation, safety and (adapter-level) tests that guard the modules themselves.

---

## Task 1: Promote the module tree to the production home

**Files:**
- Move: `dev/vnext/xml-spike/lib/{binary,diagnostic}.lua` → `_extensions/docstyle/vnext/package-core/lib/`
- Move: `dev/vnext/xml-spike/archive/{zip_preflight→zip, inflate_limited→inflate, entry_reader→entry, opc, writer}.lua` → `_extensions/docstyle/vnext/package-core/`
- Move: `dev/vnext/xml-spike/candidates/luaxml/{adapter,strictness,token_overlay}.lua` + vendor → `_extensions/docstyle/vnext/package-core/xml/`
- Move: `dev/vnext/xml-spike/candidates/common.lua` → `_extensions/docstyle/vnext/package-core/xml/common.lua`
- Create: `_extensions/docstyle/vnext/package-core/xml/init.lua`, `_extensions/docstyle/vnext/package-core/init.lua`
- Move: `tests/vnext/xml-spike/{run.lua,lib,fixtures}` and the promoted `tests/*` → `tests/vnext/package-core/`
- Move: `dev/vnext/xml-spike/candidates/oracle.lua` → `tests/vnext/package-core/lib/oracle.lua`

**Interfaces:**
- Produces: module names `zip`, `inflate`, `entry`, `opc`, `writer`, `xml` (via `xml/init.lua`), `xml.adapter`, `xml.strictness`, `xml.token_overlay`, `xml.common`, `lib.binary`, `lib.diagnostic`; and public `init.lua` returning `{ open = <fn>, xml = <table>, diagnostic = <table> }`.

- [ ] **Step 1: Create the directories and move the library modules**

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
git mv dev/vnext/xml-spike/candidates/common.lua              _extensions/docstyle/vnext/package-core/xml/common.lua
```

Also move the vendored LuaXML directory that `xml/adapter.lua` loads (inspect the top of `adapter.lua` for the exact vendor require and path; `git mv` that directory under `_extensions/docstyle/vnext/package-core/xml/vendor/`). Move the libdeflate vendor directory that `inflate.lua` loads under `_extensions/docstyle/vnext/package-core/inflate/vendor/` (or keep the sibling path the module already uses — match whatever the require expects after the rename).

- [ ] **Step 2: Rewrite the require paths in the moved modules**

Apply this exact mapping to every `require("…")` in the moved `.lua` files:

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

`require("lib.binary")` and `require("lib.diagnostic")` are unchanged. Verify none remain:

```bash
grep -rn 'require("archive\.\|require("candidates\.' _extensions/docstyle/vnext/package-core
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

(Confirm `opc.open_path` is the package constructor by reading `opc.lua`; the spike writer calls `require("archive.opc").open_path(...)`, so it is exported.)

- [ ] **Step 4: Move the test harness and promoted tests**

```bash
mkdir -p tests/vnext/package-core/{lib,tests}
git mv tests/vnext/xml-spike/run.lua            tests/vnext/package-core/run.lua
git mv tests/vnext/xml-spike/lib/harness.lua    tests/vnext/package-core/lib/harness.lua
git mv tests/vnext/xml-spike/lib/fixture.lua    tests/vnext/package-core/lib/fixture.lua
git mv tests/vnext/xml-spike/fixtures           tests/vnext/package-core/fixtures
git mv dev/vnext/xml-spike/candidates/oracle.lua tests/vnext/package-core/lib/oracle.lua
git mv tests/vnext/xml-spike/tests/test-archive-preflight.lua   tests/vnext/package-core/tests/test-archive-preflight.lua
git mv tests/vnext/xml-spike/tests/test-inflate-limit.lua       tests/vnext/package-core/tests/test-inflate-limit.lua
git mv tests/vnext/xml-spike/tests/test-opc.lua                 tests/vnext/package-core/tests/test-opc.lua
git mv tests/vnext/xml-spike/tests/test-office-preservation.lua tests/vnext/package-core/tests/test-office-preservation.lua
git mv tests/vnext/xml-spike/tests/test-luaxml-adapter.lua      tests/vnext/package-core/tests/test-xml-adapter.lua
git mv tests/vnext/xml-spike/tests/test-oracle.lua              tests/vnext/package-core/tests/test-oracle.lua
```

The feasibility-only tests stay behind: `tests/vnext/xml-spike/tests/{test-slaxml-adapter,test-determinism,test-performance,test-publication,test-runner}.lua` and `candidates/slaxml/`. (Determinism and publication behaviour is re-covered by the promoted `test-office-preservation` and by Tasks 6–7; the spike's determinism/performance gate remains the recorded feasibility evidence.)

- [ ] **Step 5: Rewrite `run.lua` package.path and the tests' require paths**

`tests/vnext/package-core/run.lua` — set `package.path` to the production tree and the test lib:

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

In the moved test files, apply the Step-2 require mapping, plus:

| Old | New |
|---|---|
| `require("candidates.luaxml.adapter")` | `require("xml")` |
| `require("candidates.oracle")` | `require("lib.oracle")` |
| `require("candidates.common")` | `require("xml.common")` |
| `require("fixtures.xml.cases")` | `require("fixtures.xml.cases")` (unchanged) |

In `test-xml-adapter.lua`, delete the feasibility-only selection-provenance case (the one asserting `provenance.xml_candidate_selection.selected == "LuaXML"` and `status == "conditional-go"`) — that provenance belongs to the merged decision, not the production module. Keep every functional, edit, preservation and rejection case.

- [ ] **Step 6: Run the promoted suite and confirm green**

Run: `quarto run tests/vnext/package-core/run.lua`
Expected: every stage reports `FAIL 0`; the summary line is `PASS <n> | FAIL 0 | SKIP 0` with `<n>` equal to the promoted case count (the feasibility-only cases are gone, so `<n>` is lower than the spike's 452 — that is expected).

If any test fails with a `module 'X' not found` error, a require path was missed in Step 2 or Step 5. Fix the specific require and re-run.

- [ ] **Step 7: Commit**

```bash
git add -A
git add -f docs/superpowers/plans/2026-08-14-docstyle-vnext-wp2-package-core.md
git commit -m "Promote WP2 package-core modules to the production tree

Move the selected spike modules and hermetic harness to
_extensions/docstyle/vnext/package-core/ and tests/vnext/package-core/,
rewrite require paths, and add the init.lua public surface. Feasibility
record and rejected candidate stay in the spike tree.

Relates to #27"
```

---

## Task 2: Add the vNext conformance wiring for the promoted suite

**Files:**
- Modify: `tests/vnext/conformance/run.lua` (or the conformance aggregator that lists sub-suites — inspect it first)
- Test: the conformance run itself

**Interfaces:**
- Consumes: `tests/vnext/package-core/run.lua` from Task 1.
- Produces: the package-core suite runs as part of `quarto run tests/vnext/conformance/run.lua`.

- [ ] **Step 1: Inspect how the conformance runner aggregates suites**

Run: `sed -n '1,60p' tests/vnext/conformance/run.lua` and note how it discovers or lists sub-suites (a directory walk, or an explicit list).

- [ ] **Step 2: Add the package-core suite to the conformance run**

If the runner uses an explicit list, add an entry that invokes `tests/vnext/package-core/run.lua`. If it discovers by directory, confirm `tests/vnext/package-core/` is included; if not, extend the discovery root list. Follow the file's existing pattern exactly; do not restructure it.

- [ ] **Step 3: Run the conformance suite and confirm both suites report**

Run: `quarto run tests/vnext/conformance/run.lua`
Expected: the existing conformance total still passes (`136` cases, `FAIL 0`) **and** the package-core suite total is included or reported, `FAIL 0`.

- [ ] **Step 4: Confirm the R suite is unaffected**

Run: `env R_PROFILE_USER=/dev/null Rscript -e 'devtools::test(stop_on_failure = TRUE)'`
Expected: `FAIL 0 | WARN 30 | SKIP 4 | PASS 3400` (unchanged — no R touched).

- [ ] **Step 5: Commit**

```bash
git add tests/vnext/conformance
git commit -m "Wire the package-core suite into the vNext conformance run

Relates to #27"
```

---

## Task 3: `inventory()` read method

**Files:**
- Modify: `_extensions/docstyle/vnext/package-core/opc.lua`
- Test: `tests/vnext/package-core/tests/test-inventory.lua`

**Interfaces:**
- Consumes: `open(path, limits, options) -> package`; `package:part(name)`, `package:content_type(name)`, `package:relationships(source)` (existing).
- Produces: `package:inventory() -> { parts = {<part_name>, …}, content_types = {[part_name]=<type>|nil}, relationships = {[source]={<record>, …}}, unknown = {<part_name>, …} }`. `parts` is every part name in central-directory order; `unknown` is parts with no content-type override and no relationship referencing them (best-effort classification, read-only).

- [ ] **Step 1: Write the failing test**

`tests/vnext/package-core/tests/test-inventory.lua`:

```lua
local fixture = require("lib.fixture")
local core = require("init")

local WORD = "tests/vnext/package-core/fixtures/office/word-native-comments.docx"

return {
  {
    name = "inventory lists every part in archive order",
    gate = "functional",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD)
      local inv = pkg:inventory()
      assert(#inv.parts >= 1, "expected at least one part")
      -- [Content_Types].xml is the OPC content-type stream and is always present
      local seen = {}
      for _, name in ipairs(inv.parts) do seen[name] = true end
      assert(seen["/word/document.xml"], "document.xml must be listed")
      -- content_types maps document.xml to the WordprocessingML main type
      assert(inv.content_types["/word/document.xml"] ~= nil,
        "document.xml must resolve a content type")
    end,
  },
}
```

(Confirm the actual fixture filename with `ls tests/vnext/package-core/fixtures/office/`; use the real Word-native fixture. If part names are stored without the leading `/`, match the module's convention — read `Package:part` to see whether it expects `/word/document.xml` or `word/document.xml`.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `quarto run tests/vnext/package-core/run.lua package`
Expected: FAIL on `test-inventory` — `attempt to call a nil value (method 'inventory')`.

- [ ] **Step 3: Implement `Package:inventory`**

In `opc.lua`, add after `Package:content_type`:

```lua
function Package:inventory()
  local parts, content_types = {}, {}
  for _, entry in ipairs(self.entries) do
    local part_name = "/" .. entry.name
    parts[#parts + 1] = part_name
    content_types[part_name] = self:content_type(part_name)
  end
  local relationships, referenced = {}, {}
  for _, entry in ipairs(self.entries) do
    local part_name = "/" .. entry.name
    if is_relationship_part(zip_name_for_part(part_name)) then
      -- skip: relationships are keyed by their source part below
    else
      local ok, records = pcall(function()
        return self:relationships(part_name)
      end)
      if ok and next(records) then
        relationships[part_name] = records
        for _, record in ipairs(records) do
          if record.resolved_part then referenced[record.resolved_part] = true end
        end
      end
    end
  end
  local unknown = {}
  for _, part_name in ipairs(parts) do
    if content_types[part_name] == nil and not referenced[part_name] then
      unknown[#unknown + 1] = part_name
    end
  end
  return {
    parts = parts,
    content_types = content_types,
    relationships = relationships,
    unknown = unknown,
  }
end
```

(Match the real field names: confirm `self.entries` and `entry.name` by reading the `Package` constructor; the writer's `archive_entries` already iterates `pkg.entries` with `validated.name`, so `self.entries[i].name` is correct.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `quarto run tests/vnext/package-core/run.lua package`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add _extensions/docstyle/vnext/package-core/opc.lua tests/vnext/package-core/tests/test-inventory.lua
git commit -m "Add package inventory read method

Relates to #27"
```

---

## Task 4: Multiple non-overlapping XML edits per document

**Files:**
- Modify: `_extensions/docstyle/vnext/package-core/xml/adapter.lua` (`register_edit`)
- Modify: `_extensions/docstyle/vnext/package-core/xml/token_overlay.lua` (`M.serialize`)
- Test: `tests/vnext/package-core/tests/test-multi-edit.lua`

**Interfaces:**
- Consumes: `xml.parse`, `xml.find_all`, `xml.set_attribute`, `xml.replace_text`, `xml.serialize` (existing); `lib.oracle` for independent verification.
- Produces: `xml.serialize(document)` applies every registered edit; two edits whose byte ranges overlap raise `xml.overlapping-edits`; editing the same token twice raises `xml.edit-target`.

- [ ] **Step 1: Write the failing test**

`tests/vnext/package-core/tests/test-multi-edit.lua`:

```lua
local xml = require("xml")

local SOURCE =
  '<?xml version="1.0" encoding="UTF-8"?>' ..
  '<w:p xmlns:w="urn:w" w:one="A" w:two="B"><w:t>hello</w:t></w:p>'

return {
  {
    name = "two attribute edits on one element both apply",
    gate = "functional",
    stage = "xml",
    fn = function()
      local doc = xml.parse(SOURCE)
      local p = xml.find_all(doc, "urn:w", "p")[1]
      xml.set_attribute(p, "urn:w", "one", "X")
      xml.set_attribute(p, "urn:w", "two", "Y")
      local out = xml.serialize(doc)
      assert(out:find('w:one="X"', 1, true), "first edit missing: " .. out)
      assert(out:find('w:two="Y"', 1, true), "second edit missing: " .. out)
      -- every byte outside the two value ranges is preserved
      assert(out:find("<w:t>hello</w:t>", 1, true), "text must be untouched")
    end,
  },
  {
    name = "an attribute edit and a text edit both apply",
    gate = "functional",
    stage = "xml",
    fn = function()
      local doc = xml.parse(SOURCE)
      local p = xml.find_all(doc, "urn:w", "p")[1]
      local t = xml.find_all(doc, "urn:w", "t")[1]
      xml.set_attribute(p, "urn:w", "one", "X")
      xml.replace_text(t, "world")
      local out = xml.serialize(doc)
      assert(out:find('w:one="X"', 1, true), out)
      assert(out:find("<w:t>world</w:t>", 1, true), out)
    end,
  },
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `quarto run tests/vnext/package-core/run.lua xml`
Expected: FAIL on the first case — `register_edit` raises `xml.edit-target` "the spike adapter permits one owned edit" when the second `set_attribute` runs.

- [ ] **Step 3: Change `register_edit` to collect a list**

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
    range = range,
    replacement = replacement,
    value = value,
  }
end
```

- [ ] **Step 4: Change `M.serialize` to apply every edit, right-to-left**

In `xml/token_overlay.lua`, replace `M.serialize`:

```lua
function M.serialize(document)
  local edits = document.edits or {}
  if #edits == 0 then return document.source, {} end
  table.sort(edits, function(a, b) return a.range.start < b.range.start end)
  for index = 2, #edits do
    if edits[index].range.start < edits[index - 1].range.finish then
      raise("xml.overlapping-edits", "XML edits overlap", {
        first = edits[index - 1].range,
        second = edits[index].range,
      })
    end
  end
  -- Apply from the highest offset down so earlier replacements do not shift
  -- the byte offsets of edits still to be applied.
  local result = document.source
  for index = #edits, 1, -1 do
    result = replace_range(result, edits[index].range, edits[index].replacement)
  end
  local ranges = {}
  for _, edit in ipairs(edits) do
    ranges[#ranges + 1] = common.range(edit.range.start, edit.range.finish)
  end
  return result, ranges
end
```

- [ ] **Step 5: Run the multi-edit test to verify it passes**

Run: `quarto run tests/vnext/package-core/run.lua xml`
Expected: both new cases PASS.

- [ ] **Step 6: Run the whole suite to confirm no regression**

Run: `quarto run tests/vnext/package-core/run.lua`
Expected: `FAIL 0`. The promoted single-edit adapter and office-preservation cases still pass (one edit is the `#edits == 1` path).

- [ ] **Step 7: Add the overlap-rejection test**

Append to `test-multi-edit.lua` a case that constructs two edits whose ranges overlap and asserts `xml.overlapping-edits`. Because the public `set_attribute`/`replace_text` cannot easily produce overlapping ranges on distinct tokens, drive `M.serialize` directly:

```lua
  {
    name = "overlapping edit ranges are rejected",
    gate = "functional",
    stage = "xml",
    fn = function()
      local overlay = require("xml.token_overlay")
      local diagnostic = require("lib.diagnostic")
      local document = {
        source = "0123456789",
        edits = {
          { target = {}, range = { start = 2, finish = 6 }, replacement = "AA" },
          { target = {}, range = { start = 4, finish = 8 }, replacement = "BB" },
        },
      }
      local err = diagnostic.capture(function() overlay.serialize(document) end)
      assert(err and err.code == "xml.overlapping-edits", tostring(err))
    end,
  },
```

Run: `quarto run tests/vnext/package-core/run.lua xml`
Expected: PASS. (Confirm `diagnostic.capture` returns the raised diagnostic table; adjust the assertion to its real shape if it returns `ok, err`.)

- [ ] **Step 8: Commit**

```bash
git add _extensions/docstyle/vnext/package-core/xml tests/vnext/package-core/tests/test-multi-edit.lua
git commit -m "Support multiple non-overlapping XML edits per document

Relates to #27"
```

---

## Task 5: Enforce the XML-part input-byte limit before parsing

**Files:**
- Modify: `_extensions/docstyle/vnext/package-core/xml/adapter.lua` (`M.parse`)
- Modify: `_extensions/docstyle/vnext/package-core/init.lua` (expose the default limit constant)
- Test: `tests/vnext/package-core/tests/test-xml-limit.lua`
- Measurement: `dev/vnext/package-core/part-size-survey.lua` (new, records WP0 corpus part sizes)

**Interfaces:**
- Consumes: `xml.parse(bytes, options)`.
- Produces: `xml.parse` rejects input longer than `options.max_input_bytes` (default `xml.MAX_INPUT_BYTES = 1048576`) with `xml.input-too-large` **before** tokenizing; the diagnostic context records `actual` and `limit`.

- [ ] **Step 1: Survey WP0 part sizes (evidence for the limit)**

Create `dev/vnext/package-core/part-size-survey.lua` that opens each WP0 baseline `.docx` under `tests/vnext/fixtures/*/baseline/legacy/` (and the office fixtures), and for each part prints `part_name<TAB>byte_length`, plus the maximum. Run it:

```bash
quarto run dev/vnext/package-core/part-size-survey.lua | sort -t$'\t' -k2 -n | tail -20
```

Record the largest WordprocessingML part in the commit message. The candidate limit (1 MiB) must exceed it with headroom; if any real part exceeds 1 MiB, raise the limit to the next power of two above the observed maximum and note it.

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
      local err = diagnostic.capture(function()
        xml.parse(oversize, { max_input_bytes = 1048576 })
      end)
      assert(err and err.code == "xml.input-too-large", tostring(err))
      assert(err.context.actual == 1048577, tostring(err.context.actual))
      assert(err.context.limit == 1048576, tostring(err.context.limit))
    end,
  },
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `quarto run tests/vnext/package-core/run.lua xml`
Expected: FAIL — `xml.MAX_INPUT_BYTES` is nil and no rejection is raised (the oversize string parses or errors with a different code).

- [ ] **Step 4: Add the limit constant and pre-parse guard**

In `xml/adapter.lua`, before `M.parse`, add the constant, then guard at the top of `M.parse`:

```lua
M.MAX_INPUT_BYTES = 1048576  -- XML-part input-byte limit (see WP2 design + provenance)

function M.parse(xml_bytes, options)
  options = options or {}
  local limit = options.max_input_bytes or M.MAX_INPUT_BYTES
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

- [ ] **Step 5: Run the test to verify it passes**

Run: `quarto run tests/vnext/package-core/run.lua xml`
Expected: both cases PASS.

- [ ] **Step 6: Confirm OPC still parses real content-types and relationships**

The OPC layer calls `xml_adapter.parse` on `[Content_Types].xml` and rels parts, which are far below 1 MiB. Run the whole suite:

Run: `quarto run tests/vnext/package-core/run.lua`
Expected: `FAIL 0` — real packages open unaffected.

- [ ] **Step 7: Commit**

```bash
git add _extensions/docstyle/vnext/package-core dev/vnext/package-core tests/vnext/package-core/tests/test-xml-limit.lua
git add -f dev/vnext/package-core/part-size-survey.lua
git commit -m "Enforce the XML-part input-byte limit before parsing

Largest observed WP0 WordprocessingML part: <N> bytes; limit set to
1048576 bytes with headroom. Realizes the pre_parse_rejection_required
contract from the merged decision provenance.

Relates to #27"
```

---

## Task 6: `add_part()`

**Files:**
- Modify: `_extensions/docstyle/vnext/package-core/opc.lua` (`Package:add_part`, content-type registration)
- Modify: `_extensions/docstyle/vnext/package-core/writer.lua` (`archive_entries`, `validate_output_sizes` include additions)
- Test: `tests/vnext/package-core/tests/test-add-part.lua`

**Interfaces:**
- Consumes: `open`, `Package:part`, `Package:content_type`, `Package:write_atomic`, `Package:inventory` (Task 3).
- Produces: `Package:add_part(part_name, bytes, content_type)` records a new part with an added `[Content_Types].xml` Override; the published archive contains the new entry after the original entries with a fixed modtime; re-opening the output finds the new part with the given content type. Collisions (`opc.add-part-collision`) and ASCII case collisions (`opc.add-part-case-collision`) fail closed; a relationship-part name fails with `opc.metadata-replacement`.

- [ ] **Step 1: Write the failing test**

`tests/vnext/package-core/tests/test-add-part.lua`:

```lua
local fixture = require("lib.fixture")
local core = require("init")

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
          '<?xml version="1.0"?><root/>',
          "application/xml")
        pkg:write_atomic(out)

        local reopened = core.open(out)
        assert(reopened:part("/word/custom.xml") ==
          '<?xml version="1.0"?><root/>', "added part bytes must survive")
        assert(reopened:content_type("/word/custom.xml") == "application/xml",
          "added content type must survive")
        -- the original document part is untouched
        assert(reopened:part("/word/document.xml") ~= nil)
      end)
    end,
  },
  {
    name = "adding an existing part name fails closed",
    gate = "safety",
    stage = "package",
    fn = function()
      local diagnostic = require("lib.diagnostic")
      local pkg = core.open(WORD)
      local err = diagnostic.capture(function()
        pkg:add_part("/word/document.xml", "x", "application/xml")
      end)
      assert(err and err.code == "opc.add-part-collision", tostring(err))
    end,
  },
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `quarto run tests/vnext/package-core/run.lua package`
Expected: FAIL — `attempt to call a nil value (method 'add_part')`.

- [ ] **Step 3: Implement `Package:add_part`**

In `opc.lua`, add a `self._additions` table in the `Package` constructor (initialize to `{}` where `_replacements` is initialized), then:

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
  local normalized = normalize_percent_hex(zip_name)
  if self._entries_by_normalized_name[normalized] or self._additions[zip_name] then
    raise("opc.add-part-collision", "a part with this name already exists", {
      part_name = part_name,
    })
  end
  local folded = ascii_lower(normalized)
  for existing in pairs(self._additions) do
    if ascii_lower(normalize_percent_hex(existing)) == folded then
      raise("opc.add-part-case-collision",
        "a part name differing only in ASCII case already exists", {
          part_name = part_name,
        })
    end
  end
  -- (the preflight already rejects ASCII case collisions among original entries)
  self._additions[zip_name] = bytes
  self._content_type_overrides[normalized] = content_type
  self:_register_content_type_override(part_name, content_type)
end
```

Add `_register_content_type_override`, which rewrites `[Content_Types].xml` by appending an `<Override>` and storing it as a replacement so the writer emits it:

```lua
function Package:_register_content_type_override(part_name, content_type)
  local bytes = self._replacements["[Content_Types].xml"]
    or self:_read_zip_entry("[Content_Types].xml", "opc.content-types-missing")
  local override = ('<Override PartName="%s" ContentType="%s"/>')
    :format(part_name, content_type)
  local updated, count = bytes:gsub("</Types>", override .. "</Types>", 1)
  if count ~= 1 then
    raise("opc.content-types-structure",
      "content-types stream has no Types closing tag", {})
  end
  self._replacements["[Content_Types].xml"] = updated
end
```

(The `.gsub` on the closing tag is safe here because `[Content_Types].xml` is a small, well-formed OPC stream the package already validated on open; the added `Override` is XML-escaped by construction because `part_name` and `content_type` are ASCII part paths and media types. If a later requirement allows non-ASCII, replace this with an `xml`-module edit.)

- [ ] **Step 4: Make the writer include additions**

In `writer.lua`, extend `archive_entries` to append additions after the validated originals, and `validate_output_sizes` to count them. Use a fixed modtime for determinism:

```lua
local ADDED_ENTRY_MODTIME = 315532800  -- 1980-01-01T00:00:00Z, the ZIP epoch

local function archive_entries(pkg)
  -- (existing validated-entry loop unchanged) …
  for zip_name, bytes in pairs(pkg._additions or {}) do
    entries[#entries + 1] = pandoc.zip.Entry(zip_name, bytes, ADDED_ENTRY_MODTIME)
  end
  return entries
end
```

In `validate_output_sizes`, after the existing loop over `pkg.entries`, add:

```lua
  for _, bytes in pairs(pkg._additions or {}) do
    local size = #bytes
    if size > pkg._limits.max_entry_uncompressed_bytes then
      raise("publication.entry-limit",
        "output entry exceeds the uncompressed-size limit", {
          actual = size, limit = pkg._limits.max_entry_uncompressed_bytes,
        })
    end
    local remaining = pkg._limits.max_total_uncompressed_bytes - total
    if size > remaining then
      raise("publication.total-limit",
        "output package exceeds the total uncompressed-size limit", {
          actual = total + size, limit = pkg._limits.max_total_uncompressed_bytes,
        })
    end
    total = total + size
  end
```

(Iterating a hash with `pairs` is non-deterministic in order; ZIP entry order across additions must be stable. Before the append loop, collect `pkg._additions` keys into a table and `table.sort` them, then append in sorted order. Apply the same sorted iteration in `validate_output_sizes`.)

- [ ] **Step 5: Run the add-part tests to verify they pass**

Run: `quarto run tests/vnext/package-core/run.lua package`
Expected: both cases PASS.

- [ ] **Step 6: Run the whole suite and confirm determinism**

Run: `quarto run tests/vnext/package-core/run.lua`
Expected: `FAIL 0`. Then run twice and diff the produced bytes for the round-trip fixture to confirm identical output (the office-preservation and determinism expectations hold with the fixed modtime and sorted additions).

- [ ] **Step 7: Commit**

```bash
git add _extensions/docstyle/vnext/package-core tests/vnext/package-core/tests/test-add-part.lua
git commit -m "Add new parts with content-type registration and atomic publication

Relates to #27"
```

---

## Task 7: `add_relationship()`

**Files:**
- Modify: `_extensions/docstyle/vnext/package-core/opc.lua` (`Package:add_relationship`, rels build/mint)
- Test: `tests/vnext/package-core/tests/test-add-relationship.lua`

**Interfaces:**
- Consumes: `open`, `Package:relationships`, `Package:write_atomic`, `Package:add_part`.
- Produces: `Package:add_relationship(source_part, rel_type, target, mode) -> rId` builds or updates the source part's `_rels/*.rels` (as a replacement or addition), mints the next free `rIdN`, and returns it. `mode` is `"Internal"` (default) or `"External"`. Internal targets that do not resolve to a part fail with `opc.relationship-target-missing`; external targets are stored with `TargetMode="External"` and never fetched. Re-opening the output lists the new relationship.

- [ ] **Step 1: Write the failing test**

`tests/vnext/package-core/tests/test-add-relationship.lua`:

```lua
local fixture = require("lib.fixture")
local core = require("init")

local WORD = "tests/vnext/package-core/fixtures/office/word-native-comments.docx"

return {
  {
    name = "an added internal relationship round-trips and mints a fresh id",
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
        assert(rid:match("^rId%d+$"), "expected an rId, got " .. tostring(rid))
        pkg:write_atomic(out)

        local reopened = core.open(out)
        local rels = reopened:relationships("/word/document.xml")
        local found
        for _, record in ipairs(rels) do
          if record.id == rid then found = record end
        end
        assert(found, "added relationship must survive")
        assert(found.resolved_part == "/word/custom.xml", found.resolved_part)
      end)
    end,
  },
  {
    name = "a fresh id does not collide with existing relationship ids",
    gate = "functional",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD)
      local before = pkg:relationships("/word/document.xml")
      local existing = {}
      for _, record in ipairs(before) do existing[record.id] = true end
      pkg:add_part("/word/custom.xml", "<root/>", "application/xml")
      local rid = pkg:add_relationship("/word/document.xml",
        "http://schemas.example.org/custom", "custom.xml", "Internal")
      assert(not existing[rid], "minted id must be unused: " .. rid)
    end,
  },
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `quarto run tests/vnext/package-core/run.lua package`
Expected: FAIL — `attempt to call a nil value (method 'add_relationship')`.

- [ ] **Step 3: Implement `Package:add_relationship`**

In `opc.lua`, add a helper that mints the next id from a relationship record list, and the method. The rels part is built as an added or replaced part; because the spike marks rels parts immutable via `replace_part`, `add_relationship` bypasses that guard by writing the rels bytes directly into `self._replacements`/`self._additions` after validating the new relationship.

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
  if mode ~= "Internal" and mode ~= "External" then
    raise("opc.invalid-target-mode", "mode must be Internal or External", {
      mode = mode,
    })
  end
  if type(rel_type) ~= "string" or rel_type == "" or
      type(target) ~= "string" or target == "" then
    raise("opc.invalid-relationship", "relationship needs a type and target", {
      source_part = source_part,
    })
  end
  local records = self:relationships(source_part)   -- existing, validated
  local rid = next_relationship_id(records)
  if mode == "Internal" then
    -- validate the target resolves to a real part (added or original)
    local resolved = self:_resolve_relationship_target(source_part, target)
    if not (self._entries_by_normalized_name[
        normalize_percent_hex(zip_name_for_part(resolved))]
        or self._additions[zip_name_for_part(resolved)]) then
      raise("opc.relationship-target-missing",
        "internal relationship target was not found", {
          source_part = source_part, target = target,
        })
    end
  end
  local relationship_zip = relationship_zip_name(source_part)
  local mode_attr = mode == "External" and ' TargetMode="External"' or ""
  local element = ('<Relationship Id="%s" Type="%s" Target="%s"%s/>')
    :format(rid, rel_type, target, mode_attr)
  local existing_bytes = self._replacements[relationship_zip]
    or (self._entries_by_name[relationship_zip]
        and self:_read_zip_entry(relationship_zip))
  if existing_bytes then
    local updated, count = existing_bytes:gsub(
      "</Relationships>", element .. "</Relationships>", 1)
    if count ~= 1 then
      raise("opc.relationships-structure",
        "relationships stream has no closing tag", {
          relationship_part = relationship_zip,
        })
    end
    self._replacements[relationship_zip] = updated
  else
    self._additions[relationship_zip] =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' ..
      '<Relationships xmlns="' .. RELATIONSHIPS_NS .. '">' ..
      element .. '</Relationships>'
  end
  self._relationship_cache[relationship_zip] = nil  -- invalidate the read cache
  return rid
end
```

Add `Package:_resolve_relationship_target` by extracting the existing `resolve_literal_target` logic (it already resolves a target against a source part and the entry table); call it and return the resolved part name, or reuse `resolve_literal_target(self, source_part, target, {…})` directly if it is in scope.

(If `relationship_zip_name`, `resolve_literal_target`, `RELATIONSHIPS_NS`, `_entries_by_name`, `_entries_by_normalized_name`, `_relationship_cache` are file-locals/fields, they are already defined in `opc.lua` — this method sits below them. Confirm names against the file before writing.)

- [ ] **Step 4: Run the add-relationship tests to verify they pass**

Run: `quarto run tests/vnext/package-core/run.lua package`
Expected: both cases PASS.

- [ ] **Step 5: Add the immutability-preservation check**

Confirm the original guard still holds for `replace_part` on a rels part (the spike test asserts `opc.metadata-replacement`). Append a case asserting `pkg:replace_part("/word/_rels/document.xml.rels", "x")` still raises `opc.metadata-replacement` — `add_relationship` is the only sanctioned path to touch rels.

Run: `quarto run tests/vnext/package-core/run.lua package`
Expected: PASS.

- [ ] **Step 6: Run the whole suite**

Run: `quarto run tests/vnext/package-core/run.lua`
Expected: `FAIL 0`.

- [ ] **Step 7: Commit**

```bash
git add _extensions/docstyle/vnext/package-core tests/vnext/package-core/tests/test-add-relationship.lua
git commit -m "Add relationships with minted ids through the sanctioned path

Relates to #27"
```

---

## Task 8: Performance re-verification and acceptance sweep

**Files:**
- Create: `dev/vnext/package-core/performance.lua` (reference benchmark over the production `xml` module)
- Create: `dev/vnext/package-core/performance-results.json` (recorded result)
- Test: none new; this task runs the full acceptance sweep

**Interfaces:**
- Consumes: the production `xml` module and its limit; the promoted determinism expectations.
- Produces: a recorded reference-performance result for the production module (retained-heap and both scaling gates hard and passing; the five-second absolute CPU target reported, advisory) and the acceptance evidence.

- [ ] **Step 1: Port the reference benchmark to the production module**

Copy the spike's reference-performance measurement approach (1 warm-up + 5 reps, median, `pandoc.system.cputime`, retained-heap = `max(0, observed - init) * 1024`) into `dev/vnext/package-core/performance.lua`, calling the production `xml.parse`/`set_attribute`/`serialize` at 1, 5 and 10 MiB. Keep the binding gates hard (retained-heap ≤ 12× input; time and heap scaling ≤ 15× the 1 MiB baseline) and report the advisory 5-second CPU line via the same `ADVISORY reference 10 MiB combined CPU: actual=… | target=5 s | met=…` format used in the merged decision.

- [ ] **Step 2: Run the benchmark and record the result**

```bash
quarto run dev/vnext/package-core/performance.lua > dev/vnext/package-core/performance-results.json
```

Expected: `decision` reflects the binding gates only; retained-heap and both scaling gates `pass=true`; the advisory 10 MiB CPU line is emitted with `met=false` (or true — either is acceptable; it is advisory).

- [ ] **Step 3: Run the full acceptance sweep**

```bash
quarto run tests/vnext/package-core/run.lua
quarto run tests/vnext/conformance/run.lua
env R_PROFILE_USER=/dev/null Rscript -e 'devtools::test(stop_on_failure = TRUE)'
git diff --exit-code origin/main -- tests/vnext/fixtures/
grep -rn 'require("archive\.\|require("candidates\.' _extensions/docstyle/vnext/package-core tests/vnext/package-core
git diff --check
```

Expected: package-core `FAIL 0`; conformance `PASS 136 | FAIL 0` plus the package-core suite; R `FAIL 0 | WARN 30 | SKIP 4 | PASS 3400`; no WP0 fixture changes; no stale require paths; whitespace clean.

- [ ] **Step 4: Verify the acceptance criteria against the spec**

Confirm each spec acceptance criterion: (1) modules under the production home, no R, reachable only through `init.lua`; (2) promoted gates green; (3) `add_part`, `add_relationship` (with id minting) and multi-edit XML implemented and tested, `write_atomic` preserves added + unknown parts, order and modtimes deterministically; (4) the input-byte limit is set, enforced pre-parse, worst-case latency recorded, heap/scaling gates pass; (5) the promoted suite runs in the conformance run, WP0 fixtures unchanged.

- [ ] **Step 5: Commit**

```bash
git add dev/vnext/package-core
git add -f dev/vnext/package-core/performance.lua
git commit -m "Record WP2 package-core reference performance and acceptance sweep

Relates to #27"
```

---

## Self-review

**Spec coverage:** Goals map to Tasks — promote (1), no-R/isolated home + init.lua (1), full finalization interface (`add_part` 6, `add_relationship` 7, multi-edit 4), performance prerequisite (5 + 8), gate coverage carried over and extended (1, 2, and per-task tests). Non-goals (registry, feature modules, render, CSS, CLI, part removal, general id allocation) have no tasks — correct. Acceptance criteria are checked in Task 8 Step 4.

**Placeholder scan:** implementation steps carry real code; the two `.gsub`-on-closing-tag shortcuts are called out with their safety rationale and the condition under which to replace them. The survey `<N>` in Task 5's commit message is filled from Step 1 output, not a code placeholder.

**Type consistency:** `document.edits` (list) is introduced in Task 4 and consumed by the same task's `serialize`; `self._additions` is introduced in Task 6 and consumed by Task 6's writer changes and Task 7's `add_relationship`; `xml.MAX_INPUT_BYTES` is defined and asserted in Task 5. `next_relationship_id`, `_register_content_type_override` and `_resolve_relationship_target` are defined where first used. Field names (`self.entries`, `entry.name`, `_entries_by_normalized_name`, `_relationship_cache`, `RELATIONSHIPS_NS`) are the spike's real names, to be confirmed against each file before editing (noted inline).
