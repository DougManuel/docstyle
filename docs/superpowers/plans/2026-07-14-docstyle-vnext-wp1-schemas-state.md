# Docstyle vNext WP1 Schemas and State Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the WP1 JSON Schemas with valid and invalid examples, a Quarto/Lua conformance runner that proves them, legacy mapping fixtures, and the legacy element coverage audit.

**Architecture:** Schemas live in `schemas/` at the repository root. A pure-Lua conformance runner under `tests/vnext/conformance/` executes via `quarto run`, so the contributor path needs only Quarto. Support modules (JSON Schema subset validator, canonical JSON, SHA-256, identifier rules, manifest commit, legacy migration) are small Lua files with their own test files discovered by the runner.

**Tech Stack:** JSON Schema draft 2020-12, Pandoc Lua (Lua 5.4) via `quarto run`, testthat only as a thin optional bridge.

## Global constraints

- Approved specification: `docs/superpowers/specs/2026-07-14-docstyle-vnext-wp1-schemas-state-design.md`. Field names, enums and requirements below are copied from it; the spec wins on any drift.
- The conformance path must require only Quarto. No R, no network, no external ZIP tools.
- WP0 baselines under `tests/vnext/fixtures/` are read-only evidence. Never modify them.
- Schema `$id` form: `https://dougmanuel.github.io/docstyle/schemas/<name>.v<major>.json`. Identifiers are names; the runner resolves them from a bundled registry, never the network.
- Content hash: `sha256:` + 64 lowercase hex over RFC 8785 canonical JSON; integers only (non-integer numbers are an error in WP1 contracts); text assumed NFC (see Task 2 bound).
- Generated identifiers: `g-<type>-<6 chars of a-z2-7>`. Reserved prefixes `g-` and `docstyle-`.
- Envelope: exactly eight defined keys (`v`, `id`, `kind`, `policy`, `hash`, `role`, `parent`, `profile`); serialized size <= 1,024 bytes; unknown keys preserved, never interpreted.
- Prose documents follow the house style (Canadian Press spelling, sentence case for level-2+ headings). Run `python3 ~/github/ai-infrastructure/skills/writing-style/scripts/check_style.py <file>` on new Markdown.
- Commit locally per task with plain-text messages, no AI credit, never push. `docs/` is gitignored (pkgdown output): stage anything under `docs/superpowers/` with `git add -f`.
- Run the full legacy suite once at the end (`env R_PROFILE_USER=/dev/null Rscript -e 'devtools::test()'`); expected baseline is FAIL 0, WARN 30, SKIP 4.

## File structure

```text
schemas/
  document-model.v1.json     metadata-core.v1.json      profile-manifest.v1.json
  field-envelope.v4.json     state-manifest.v1.json     state-regions.v1.json
  state-metadata.v1.json     state-citations.v1.json    state-annotations.v1.json
  report-envelope.v1.json    profiles/fixture.v1.json
  examples/<schema-name>/valid-*.json | invalid-*.json
tests/vnext/conformance/
  run.lua              entry point: self-tests, then schema/example validation
  lib/jsonschema.lua   draft 2020-12 subset validator + registry
  lib/canonical.lua    RFC 8785 canonical JSON (integer-bounded)
  lib/sha256.lua       FIPS 180-4 SHA-256
  lib/hashes.lua       content_hash over semantic nodes
  lib/ids.lua          identifier generation, reservation, collision
  lib/manifest.lua     atomic state-manifest commit and verified read
  lib/migrate.lua      legacy payload and sidecar migration
  lib/json.lua         thin wrapper over pandoc.json encode/decode
  tests/test-*.lua     one test file per module
  legacy/key-map.json  legacy payload key dispositions (Task 8)
  legacy/cases/*.json  legacy-to-v4 mapping fixtures (Task 8)
  README.md            how to run; contract summary
dev/vnext/wp1-legacy-coverage.md   coverage audit (Task 9)
tests/testthat/test-vnext-conformance.R   optional R bridge (Task 9)
```

Node-type note: the schemas below include `anchor` in the node-type and `kind` enums. The approved spec's illustrative type list omits it, but legacy `float` and `anchor` payload types (Task 8) need a positioned-content kind. Record this as a spec revision in the coverage audit and flag it in the completion summary for review.

---

### Task 1: Conformance runner and JSON Schema subset validator

**Files:**
- Create: `tests/vnext/conformance/run.lua`
- Create: `tests/vnext/conformance/lib/json.lua`
- Create: `tests/vnext/conformance/lib/jsonschema.lua`
- Test: `tests/vnext/conformance/tests/test-jsonschema.lua`

**Interfaces:**
- Consumes: `pandoc.json.decode/encode`, `pandoc.system`, `pandoc.path` (available under `quarto run`).
- Produces: `jsonschema.validate(schema, instance) -> ok:boolean, errors:{{path,message},...}`; `jsonschema.register(id, schema)`; `jsonschema.resolve(id) -> schema`. `json.decode(str)`, `json.encode(value)`, `json.read(path)`. Runner conventions every later task relies on: test files `tests/test-*.lua` return `{ {name=..., fn=...}, ... }`; `fn` raises on failure via `assert`/`error`; run.lua prints `PASS n | FAIL n` and exits non-zero on any failure; schema examples under `schemas/examples/<name>/valid-*.json` must validate and `invalid-*.json` must fail validation.

- [ ] **Step 1: Write the failing test file**

`tests/vnext/conformance/tests/test-jsonschema.lua`:

```lua
local js = require("lib.jsonschema")

local function ok(schema, inst) local v = js.validate(schema, inst); assert(v, "expected valid") end
local function bad(schema, inst) local v = js.validate(schema, inst); assert(not v, "expected invalid") end

return {
  { name = "type string", fn = function()
      ok({ type = "string" }, "x"); bad({ type = "string" }, 5)
    end },
  { name = "required and properties", fn = function()
      local s = { type = "object", required = { "id" },
        properties = { id = { type = "string" } } }
      ok(s, { id = "a" }); bad(s, {}); bad(s, { id = 7 })
    end },
  { name = "additionalProperties false rejects unknowns", fn = function()
      local s = { type = "object", properties = { a = { type = "string" } },
        additionalProperties = false }
      ok(s, { a = "x" }); bad(s, { a = "x", b = 1 })
    end },
  { name = "enum, const, pattern", fn = function()
      ok({ enum = { "a", "b" } }, "b"); bad({ enum = { "a" } }, "c")
      ok({ const = 4 }, 4); bad({ const = 4 }, 5)
      ok({ type = "string", pattern = "^g%-[a-z]+%-[a-z2-7]{6}$" }, "g-table-k3m7ap")
      bad({ type = "string", pattern = "^sha256:[0-9a-f]{64}$" }, "sha256:short")
    end },
  { name = "arrays: items, minItems", fn = function()
      local s = { type = "array", items = { type = "integer" }, minItems = 1 }
      ok(s, { 1, 2 }); bad(s, {}); bad(s, { "x" })
    end },
  { name = "integer vs number, minimum", fn = function()
      ok({ type = "integer", minimum = 1 }, 4)
      bad({ type = "integer" }, 4.5); bad({ type = "integer", minimum = 1 }, 0)
    end },
  { name = "oneOf and anyOf", fn = function()
      ok({ anyOf = { { type = "string" }, { type = "integer" } } }, 3)
      bad({ oneOf = { { type = "integer" }, { minimum = 0 } } }, 3) -- matches both
    end },
  { name = "ref resolves through registry and $defs", fn = function()
      js.register("https://example.org/leaf.v1.json", { type = "string" })
      local s = { ["$defs"] = { p = { type = "integer" } },
        type = "object", properties = {
          a = { ["$ref"] = "#/$defs/p" },
          b = { ["$ref"] = "https://example.org/leaf.v1.json" } } }
      ok(s, { a = 1, b = "x" }); bad(s, { a = "no", b = "x" })
    end },
  { name = "errors carry instance paths", fn = function()
      local s = { type = "object", properties = { a = { type = "string" } } }
      local v, errs = js.validate(s, { a = 5 })
      assert(not v and errs[1].path == "/a", "path was " .. tostring(errs and errs[1] and errs[1].path))
    end },
}
```

Note on `pattern`: implement with Lua patterns and translate the two regex classes the schemas use (`{n}` repetition and `[0-9a-f]`/`[a-z2-7]` classes) — write schema patterns in the Lua-compatible dialect shown above and document that bound in the README (Task 9). Do not attempt full ECMA regex.

- [ ] **Step 2: Write run.lua so the failure is observable**

```lua
-- tests/vnext/conformance/run.lua
-- Conformance runner for Docstyle vNext WP1. Usage: quarto run tests/vnext/conformance/run.lua
local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
package.path = here .. "/?.lua;" .. package.path

local pass, fail = 0, 0
local function report(name, okflag, err)
  if okflag then pass = pass + 1
  else fail = fail + 1; io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n") end
end

-- 1. module self-tests
local list = pandoc.system.list_directory(here .. "/tests")
table.sort(list)
for _, f in ipairs(list) do
  local mod = f:match("^(test%-.+)%.lua$")
  if mod then
    local cases = dofile(here .. "/tests/" .. f)
    for _, c in ipairs(cases) do
      local okflag, err = pcall(c.fn)
      report(mod .. "/" .. c.name, okflag, err)
    end
  end
end

-- 2. schema examples (skipped silently until schemas/ exists)
local js = require("lib.jsonschema")
local json = require("lib.json")
local root = pandoc.path.join({ here, "..", "..", ".." })
local schemas_dir = pandoc.path.join({ root, "schemas" })
local okdir, names = pcall(pandoc.system.list_directory, schemas_dir)
if okdir then
  local loaded = {}
  local function load_dir(dir)
    for _, f in ipairs(pandoc.system.list_directory(dir)) do
      if f:match("%.json$") then
        local s = json.read(pandoc.path.join({ dir, f }))
        js.register(s["$id"], s)
        loaded[f:gsub("%.json$", "")] = s
      end
    end
  end
  load_dir(schemas_dir)
  local pd = pandoc.path.join({ schemas_dir, "profiles" })
  if pcall(pandoc.system.list_directory, pd) then load_dir(pd) end
  local exdir = pandoc.path.join({ schemas_dir, "examples" })
  if pcall(pandoc.system.list_directory, exdir) then
    for _, name in ipairs(pandoc.system.list_directory(exdir)) do
      local schema = loaded[name] or loaded["profiles/" .. name]
      for _, ex in ipairs(pandoc.system.list_directory(pandoc.path.join({ exdir, name }))) do
        local inst = json.read(pandoc.path.join({ exdir, name, ex }))
        local v, errs = js.validate(schema, inst)
        local want_valid = ex:match("^valid") ~= nil
        local okflag = (v == want_valid)
        local msg = want_valid and (errs and errs[1] and (errs[1].path .. " " .. errs[1].message))
          or "invalid example validated"
        report("examples/" .. name .. "/" .. ex, okflag, msg)
      end
    end
  end
end

print(("PASS %d | FAIL %d"):format(pass, fail))
if fail > 0 then error("conformance failures: " .. fail) end
```

`tests/vnext/conformance/lib/json.lua`:

```lua
local M = {}
function M.decode(s) return pandoc.json.decode(s, false) end
function M.encode(v) return pandoc.json.encode(v) end
function M.read(path)
  local f = assert(io.open(path, "rb")); local s = f:read("a"); f:close()
  return M.decode(s)
end
return M
```

- [ ] **Step 3: Run to verify failure**

Run: `quarto run tests/vnext/conformance/run.lua`
Expected: FAIL lines for every test-jsonschema case (module `lib.jsonschema` not found), non-zero exit.

- [ ] **Step 4: Implement the validator**

`tests/vnext/conformance/lib/jsonschema.lua` — implement exactly the keyword subset the tests and schemas use: `type` (string/integer/number/boolean/object/array/null; integer means `math.type(v) == "integer"` or a float with zero fraction), `properties`, `required`, `additionalProperties` (boolean false only), `enum`, `const`, `pattern` (Lua patterns; expand `{n}`/`{n,m}` repetitions before matching), `minLength`/`maxLength` (bytes), `minimum`/`maximum`, `items`, `minItems`/`maxItems`, `oneOf`, `anyOf`, `$ref` (fragment `#/$defs/<name>` in the current root, or absolute id via the registry), `$defs`. Objects decoded by `pandoc.json` distinguish empty object from empty array; treat a value as an object when it is a table whose keys are strings. Collect errors as `{ path = "/a/0/b", message = "..." }`, descending paths as JSON Pointers. `validate` returns `ok, errors`. Registry: module-level table keyed by `$id`; `register` and `resolve` read and write it; unknown `$ref` is itself a validation error.

- [ ] **Step 5: Run to verify pass**

Run: `quarto run tests/vnext/conformance/run.lua`
Expected: `PASS 9 | FAIL 0`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add tests/vnext/conformance
git commit -m "Add vNext conformance runner and JSON Schema subset validator

Relates to #28"
```

---

### Task 2: Canonical JSON and SHA-256

**Files:**
- Create: `tests/vnext/conformance/lib/canonical.lua`
- Create: `tests/vnext/conformance/lib/sha256.lua`
- Create: `tests/vnext/conformance/lib/hashes.lua`
- Test: `tests/vnext/conformance/tests/test-canonical.lua`
- Test: `tests/vnext/conformance/tests/test-sha256.lua`
- Test: `tests/vnext/conformance/tests/test-hashes.lua`

**Interfaces:**
- Consumes: runner conventions from Task 1.
- Produces: `canonical.encode(value) -> string` (raises on non-integer numbers); `sha256.hex(bytes) -> 64-char lowercase hex`; `hashes.content_hash(node) -> "sha256:<hex>"` stripping `hash` and `source` keys at every depth before canonical encoding.

**Bound (record in README and coverage audit):** WP1 canonicalization assumes input text is already Unicode NFC; Pandoc Lua exposes no normalizer. The contract in the spec stands; NFD-input normalization lands with the production model builder (WP3) or the WP2 text layer. Acceptance test 4 runs on NFC fixtures.

- [ ] **Step 1: Write the failing tests**

`tests/vnext/conformance/tests/test-sha256.lua` (NIST FIPS 180-4 vectors):

```lua
local sha = require("lib.sha256")
return {
  { name = "empty string", fn = function()
      assert(sha.hex("") ==
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    end },
  { name = "abc", fn = function()
      assert(sha.hex("abc") ==
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    end },
  { name = "448-bit vector", fn = function()
      assert(sha.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    end },
  { name = "million a (padding across blocks)", fn = function()
      assert(sha.hex(string.rep("a", 1000000)) ==
        "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    end },
}
```

`tests/vnext/conformance/tests/test-canonical.lua`:

```lua
local c = require("lib.canonical")
return {
  { name = "keys sorted, no whitespace", fn = function()
      assert(c.encode({ b = 1, a = "x" }) == '{"a":"x","b":1}')
    end },
  { name = "nested arrays and objects", fn = function()
      assert(c.encode({ l = { 1, { z = true, a = pandoc.json.null } } })
        == '{"l":[1,{"a":null,"z":true}]}')
    end },
  { name = "string escapes per RFC 8785", fn = function()
      assert(c.encode({ s = 'q"\\\n\t\27' }) == '{"s":"q\\"\\\\\\n\\t\\u001b"}')
    end },
  { name = "utf-8 passes through unescaped", fn = function()
      assert(c.encode({ s = "protocole étendu" }) == '{"s":"protocole étendu"}')
    end },
  { name = "non-integer number raises", fn = function()
      assert(not pcall(c.encode, { x = 1.5 }))
    end },
}
```

`tests/vnext/conformance/tests/test-hashes.lua`:

```lua
local h = require("lib.hashes")
return {
  { name = "format and determinism", fn = function()
      local node = { id = "abstract", type = "section", hash = "sha256:stale",
        children = { { id = "g-paragraph-aaaaaa", type = "paragraph",
          source = { file = "x.qmd", start = 3 }, text = "Résumé ✓" } } }
      local a = h.content_hash(node)
      assert(a:match("^sha256:[0-9a-f]+$") and #a == 71, a)
      assert(a == h.content_hash(node))
    end },
  { name = "hash and source excluded; text changes hash", fn = function()
      local base = { id = "r", type = "paragraph", text = "t" }
      local with_meta = { id = "r", type = "paragraph", text = "t",
        hash = "sha256:x", source = { file = "a.qmd" } }
      assert(h.content_hash(base) == h.content_hash(with_meta))
      local edited = { id = "r", type = "paragraph", text = "u" }
      assert(h.content_hash(base) ~= h.content_hash(edited))
    end },
}
```

- [ ] **Step 2: Run to verify failure**

Run: `quarto run tests/vnext/conformance/run.lua`
Expected: new cases FAIL (modules missing); Task 1 cases still PASS.

- [ ] **Step 3: Implement the three modules**

`sha256.lua`: FIPS 180-4 with Lua 5.4 native integer operators (`~`, `&`, `|`, `>>`, `<<`, masked to 32 bits with `& 0xffffffff`). Standard 64-entry K table and 8-entry H init, 512-bit blocks, length padding. About 100 lines; the four vectors gate correctness — do not hand-verify, let the tests decide.

`canonical.lua`: recursive encoder. Objects: collect string keys, `table.sort`, emit `"k":v` comma-joined in `{}`. Arrays (integer keys 1..n): `[]`. Strings: escape `"` `\` and control bytes < 0x20 (`\b \t \n \f \r` shorthands, otherwise `\u00XX`); all other bytes pass through. Booleans, `pandoc.json.null` -> `null`. Numbers: `math.type(v) == "integer"` emits `%d`; anything else raises `"non-integer number in canonical content"`.

`hashes.lua`:

```lua
local c, sha = require("lib.canonical"), require("lib.sha256")
local M = {}
local STRIP = { hash = true, source = true }
local function strip(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, val in pairs(v) do if not STRIP[k] then out[k] = strip(val) end end
  return out
end
function M.content_hash(node) return "sha256:" .. sha.hex(c.encode(strip(node))) end
return M
```

- [ ] **Step 4: Run to verify pass**

Run: `quarto run tests/vnext/conformance/run.lua`
Expected: `PASS 20 | FAIL 0`.

- [ ] **Step 5: Commit**

```bash
git add tests/vnext/conformance
git commit -m "Add canonical JSON, SHA-256 and content-hash modules

Relates to #28"
```

---

### Task 3: Field-envelope schema (exemplar) and .Rbuildignore

**Files:**
- Create: `schemas/field-envelope.v4.json`
- Create: `schemas/examples/field-envelope.v4/valid-minimal.json`
- Create: `schemas/examples/field-envelope.v4/valid-full.json`
- Create: `schemas/examples/field-envelope.v4/invalid-missing-policy.json`
- Create: `schemas/examples/field-envelope.v4/invalid-bad-hash.json`
- Modify: `.Rbuildignore` (append `^schemas$`)
- Test: `tests/vnext/conformance/tests/test-envelope-size.lua`

**Interfaces:**
- Consumes: runner example discovery (Task 1), `canonical.encode` (Task 2).
- Produces: registered schema id `https://dougmanuel.github.io/docstyle/schemas/field-envelope.v4.json`; the `KINDS` and `POLICIES` enums reused verbatim by Tasks 4, 6 and 8.

- [ ] **Step 1: Write the examples and the size test (failing)**

`valid-minimal.json`:

```json
{ "v": 4, "id": "abstract", "kind": "section", "policy": "authored-preserve",
  "hash": "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08" }
```

`valid-full.json`:

```json
{ "v": 4, "id": "g-table-k3m7ap", "kind": "table", "policy": "authored-preserve",
  "hash": "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
  "role": "predictor-definition", "parent": "methods", "profile": "docstyle:fixture" }
```

`invalid-missing-policy.json` (most likely real mistake: writer forgets policy, expecting inference):

```json
{ "v": 4, "id": "abstract", "kind": "section",
  "hash": "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08" }
```

`invalid-bad-hash.json` (truncated hash):

```json
{ "v": 4, "id": "abstract", "kind": "section", "policy": "authored-preserve",
  "hash": "sha256:9f86d0" }
```

`tests/vnext/conformance/tests/test-envelope-size.lua`:

```lua
local json = require("lib.json")
local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local ex = pandoc.path.join({ here, "..", "..", "..", "..",
  "schemas", "examples", "field-envelope.v4" })
return {
  { name = "every valid envelope example serializes under 1024 bytes", fn = function()
      for _, f in ipairs(pandoc.system.list_directory(ex)) do
        if f:match("^valid") then
          local s = json.encode(json.read(pandoc.path.join({ ex, f })))
          assert(#s <= 1024, f .. " is " .. #s .. " bytes")
        end
      end
    end },
}
```

- [ ] **Step 2: Run to verify failure**

Run: `quarto run tests/vnext/conformance/run.lua`
Expected: example cases FAIL (`schemas/field-envelope.v4.json` missing, valid examples cannot validate; invalid examples fail correctly only once the schema exists — the runner reports missing-schema errors for all four).

- [ ] **Step 3: Write the schema**

`schemas/field-envelope.v4.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://dougmanuel.github.io/docstyle/schemas/field-envelope.v4.json",
  "title": "DOCSTYLE field envelope, version 4",
  "type": "object",
  "required": ["v", "id", "kind", "policy", "hash"],
  "properties": {
    "v": { "const": 4 },
    "id": { "type": "string", "minLength": 1, "maxLength": 128 },
    "kind": { "enum": ["section", "heading", "paragraph", "list", "list-item",
      "table", "table-row", "table-cell", "figure", "caption", "equation",
      "code-block", "footnote", "citation", "span", "raw", "anchor"] },
    "policy": { "enum": ["authored-preserve", "generated-replace",
      "structural", "external-managed"] },
    "hash": { "type": "string", "pattern": "^sha256:[0-9a-f]{64}$" },
    "role": { "type": "string", "minLength": 1, "maxLength": 64 },
    "parent": { "type": "string", "minLength": 1, "maxLength": 128 },
    "profile": { "type": "string", "pattern": "^[a-z][a-z0-9-]*:[a-z][a-z0-9-]*$" }
  }
}
```

No `additionalProperties: false`: unknown keys are preserved data by contract. The 1,024-byte bound is a writer rule enforced by the size test, not by schema.

Append to `.Rbuildignore`:

```text
^schemas$
```

- [ ] **Step 4: Run to verify pass**

Run: `quarto run tests/vnext/conformance/run.lua`
Expected: two valid examples PASS as valid, two invalid examples PASS as rejected, size test PASS. `PASS 25 | FAIL 0`.

- [ ] **Step 5: Commit**

```bash
git add schemas .Rbuildignore tests/vnext/conformance
git commit -m "Add field-envelope v4 schema with examples and size gate

Relates to #28"
```

---

### Task 4: Document-model schema and full-coverage example

**Files:**
- Create: `schemas/document-model.v1.json`
- Create: `schemas/examples/document-model.v1/valid-full-coverage.json`
- Create: `schemas/examples/document-model.v1/invalid-node-missing-classification.json`
- Test: `tests/vnext/conformance/tests/test-model-coverage.lua`

**Interfaces:**
- Consumes: `KINDS`/`POLICIES` enums exactly as written in Task 3; `hashes.content_hash` (Task 2).
- Produces: schema id `.../document-model.v1.json`; node object shape (`id`, `type`, `classification`, `policy`, `hash`, optional `role`, `children`, `attrs`, `source`) consumed by Tasks 6, 7 and 8; the full-coverage example reused by Task 7's round-trip test.

- [ ] **Step 1: Write the failing coverage test**

`tests/vnext/conformance/tests/test-model-coverage.lua`:

```lua
local json = require("lib.json")
local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local p = pandoc.path.join({ here, "..", "..", "..", "..",
  "schemas", "examples", "document-model.v1", "valid-full-coverage.json" })
local ALL_TYPES = { "section", "heading", "paragraph", "list", "list-item",
  "table", "table-row", "table-cell", "figure", "caption", "equation",
  "code-block", "footnote", "citation", "span", "raw", "anchor" }
local ALL_POLICIES = { "authored-preserve", "generated-replace",
  "structural", "external-managed" }
local function walk(node, seen_t, seen_p, seen_g, seen_e)
  seen_t[node.type] = true; seen_p[node.policy] = true
  if node.id:match("^g%-") then seen_g.yes = true else seen_e.yes = true end
  for _, c in ipairs(node.children or {}) do walk(c, seen_t, seen_p, seen_g, seen_e) end
end
return {
  { name = "example exercises every node type, policy and both id forms", fn = function()
      local m = json.read(p)
      local t, pol, g, e = {}, {}, {}, {}
      for _, n in ipairs(m.content) do walk(n, t, pol, g, e) end
      for _, ty in ipairs(ALL_TYPES) do assert(t[ty], "missing node type " .. ty) end
      for _, po in ipairs(ALL_POLICIES) do assert(pol[po], "missing policy " .. po) end
      assert(g.yes and e.yes, "need both generated and explicit identifiers")
      assert(m.registries.metadata and m.registries.profiles
        and m.registries.relationships and m.registries.assets, "missing registry")
    end },
}
```

- [ ] **Step 2: Run to verify failure**

Run: `quarto run tests/vnext/conformance/run.lua`
Expected: FAIL (example file missing).

- [ ] **Step 3: Write the schema and the example**

`schemas/document-model.v1.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://dougmanuel.github.io/docstyle/schemas/document-model.v1.json",
  "title": "Docstyle serialized semantic document model, version 1",
  "type": "object",
  "required": ["schemaVersion", "content", "registries"],
  "properties": {
    "schemaVersion": { "const": 1 },
    "content": { "type": "array", "items": { "$ref": "#/$defs/node" } },
    "registries": {
      "type": "object",
      "required": ["metadata", "profiles", "relationships", "assets"],
      "properties": {
        "metadata": { "type": "array", "items": { "$ref": "#/$defs/record" } },
        "profiles": { "type": "object" },
        "relationships": { "type": "array", "items": { "$ref": "#/$defs/relationship" } },
        "assets": { "type": "array", "items": { "$ref": "#/$defs/asset" } }
      }
    }
  },
  "$defs": {
    "node": {
      "type": "object",
      "required": ["id", "type", "classification", "policy", "hash"],
      "properties": {
        "id": { "type": "string", "minLength": 1, "maxLength": 128 },
        "type": { "enum": ["section", "heading", "paragraph", "list", "list-item",
          "table", "table-row", "table-cell", "figure", "caption", "equation",
          "code-block", "footnote", "citation", "span", "raw", "anchor"] },
        "role": { "type": "string" },
        "classification": { "enum": ["authored", "generated", "structural", "external-managed"] },
        "policy": { "enum": ["authored-preserve", "generated-replace",
          "structural", "external-managed"] },
        "hash": { "type": "string", "pattern": "^sha256:[0-9a-f]{64}$" },
        "children": { "type": "array", "items": { "$ref": "#/$defs/node" } },
        "attrs": { "type": "object" },
        "text": { "type": "string" },
        "source": { "type": "object", "properties": {
          "file": { "type": "string" }, "start": { "type": "integer", "minimum": 1 },
          "end": { "type": "integer", "minimum": 1 } } }
      }
    },
    "record": {
      "type": "object",
      "required": ["id", "recordType", "schemaVersion"],
      "properties": {
        "id": { "type": "string", "minLength": 1 },
        "recordType": { "type": "string", "minLength": 1 },
        "schemaVersion": { "type": "integer", "minimum": 1 },
        "profile": { "type": "string" },
        "privacy": { "enum": ["public", "restricted"] }
      }
    },
    "relationship": {
      "type": "object",
      "required": ["id", "subject", "predicate", "object"],
      "properties": {
        "id": { "type": "string" }, "subject": { "type": "string" },
        "predicate": { "type": "string" }, "object": { "type": "string" }
      }
    },
    "asset": {
      "type": "object",
      "required": ["id", "path", "mediaType", "hash"],
      "properties": {
        "id": { "type": "string" }, "path": { "type": "string" },
        "mediaType": { "type": "string" },
        "hash": { "type": "string", "pattern": "^sha256:[0-9a-f]{64}$" }
      }
    }
  }
}
```

`valid-full-coverage.json`: a synthetic document exercising all 17 node types, all four policies, one explicit id (`abstract`) and generated ids elsewhere. Structure: one `section` (id `abstract`, role `abstract`, policy `authored-preserve`, classification `authored`) containing a `paragraph` with a `span` and a `citation`; one generated `section` containing `heading`, `list` with two `list-item`s, `table` with `table-row` and `table-cell`, `figure` with `caption`, `equation`, `code-block`, `footnote`, `raw` (attrs `{"format":"openxml"}`, classification `authored`), and an `anchor` (policy `structural`, classification `structural`); one `paragraph` with policy `generated-replace` and classification `generated`; the `citation` node carries policy `external-managed` and classification `external-managed`. Every `hash` is any well-formed value (recompute is Task 7's job; schema requires shape only). Registries: one metadata record (`recordType`: `document`), `profiles` `{}`, one relationship (`{"id":"g-relationship-aaaaaa","subject":"rec-doc","predicate":"describes","object":"abstract"}`), one asset. Write the JSON by hand to satisfy `test-model-coverage`; the test is the completeness check, so iterate until it passes.

`invalid-node-missing-classification.json` (most likely mistake: emitting a node without its authored/generated classification):

```json
{ "schemaVersion": 1,
  "content": [ { "id": "abstract", "type": "section", "policy": "authored-preserve",
    "hash": "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08" } ],
  "registries": { "metadata": [], "profiles": {}, "relationships": [], "assets": [] } }
```

- [ ] **Step 4: Run to verify pass**

Run: `quarto run tests/vnext/conformance/run.lua`
Expected: all example and coverage cases PASS.

- [ ] **Step 5: Commit**

```bash
git add schemas tests/vnext/conformance
git commit -m "Add document-model v1 schema with full-coverage example

Relates to #28"
```

---

### Task 5: Core metadata, profile manifest and fixture profile

**Files:**
- Create: `schemas/metadata-core.v1.json`
- Create: `schemas/profile-manifest.v1.json`
- Create: `schemas/profiles/fixture.v1.json`
- Create: `schemas/examples/metadata-core.v1/valid-document.json`, `valid-person.json`, `valid-funding.json`, `invalid-bad-type.json`, `invalid-licence-empty.json`
- Create: `schemas/examples/profile-manifest.v1/valid-fixture.json`, `invalid-bad-namespace.json`
- Create: `schemas/examples/fixture.v1/valid-record.json`, `invalid-missing-required.json`

**Interfaces:**
- Consumes: record base shape from Task 4 (`id`, `recordType`, `schemaVersion`, `privacy`).
- Produces: schema ids `.../metadata-core.v1.json`, `.../profile-manifest.v1.json`, `.../profiles/fixture.v1.json`; the document record shape Task 6 embeds in `state-metadata` and Task 8 emits from migration.

- [ ] **Step 1: Write the examples first (failing)**

`valid-document.json`:

```json
{ "id": "rec-doc", "recordType": "document", "schemaVersion": 1,
  "type": "protocol",
  "title": "Reporting practices scoping review protocol",
  "shortTitle": "POPCORN protocol",
  "licence": { "spdx": "CC-BY-4.0" },
  "keywords": ["scoping review", "reporting"],
  "version": "0.2.11",
  "versionHistory": [
    { "version": "0.2.11", "date": "2026-06-16", "description": "Criterion 1 synthetic-population nuance." } ],
  "status": "draft",
  "dates": { "modified": "2026-06-16" },
  "language": "en-CA",
  "identifiers": [ { "scheme": "doi", "value": "10.0000/example" } ] }
```

`valid-person.json`:

```json
{ "id": "rec-p1", "recordType": "person", "schemaVersion": 1,
  "name": { "given": "Doug", "family": "Manuel" },
  "orcid": "0000-0003-0000-0000",
  "roles": ["conceptualization", "methodology"],
  "corresponding": true,
  "affiliations": ["rec-org1"] }
```

`valid-funding.json`:

```json
{ "id": "rec-f1", "recordType": "funding", "schemaVersion": 1,
  "funder": "rec-org1", "grant": "PJT-000000" }
```

`invalid-bad-type.json` (most likely mistake: free-text document type):

```json
{ "id": "rec-doc", "recordType": "document", "schemaVersion": 1,
  "type": "scoping review protocol", "title": "T" }
```

`invalid-licence-empty.json` (licence object with no member):

```json
{ "id": "rec-doc", "recordType": "document", "schemaVersion": 1,
  "type": "protocol", "title": "T", "licence": {} }
```

`profile-manifest.v1/valid-fixture.json`:

```json
{ "id": "docstyle:fixture", "version": "1.0.0",
  "schema": "profiles/fixture.v1.json",
  "recordTypes": ["fixture-record"],
  "classes": ["fixture-region"],
  "regionRoles": ["fixture-role"],
  "predicates": ["fixture-supports"],
  "migratesFrom": [] }
```

`profile-manifest.v1/invalid-bad-namespace.json` (uppercase namespace):

```json
{ "id": "Docstyle:Fixture", "version": "1.0.0",
  "schema": "profiles/fixture.v1.json", "recordTypes": ["fixture-record"] }
```

`fixture.v1/valid-record.json` (exercises required scalar, repeatable field, controlled term, region link):

```json
{ "id": "rec-fx1", "recordType": "fixture-record", "schemaVersion": 1,
  "profile": "docstyle:fixture",
  "label": "Example fixture record",
  "notes": ["first note", "second note"],
  "category": "beta",
  "region": "abstract" }
```

`fixture.v1/invalid-missing-required.json` (omits `label`):

```json
{ "id": "rec-fx1", "recordType": "fixture-record", "schemaVersion": 1,
  "profile": "docstyle:fixture", "category": "beta" }
```

- [ ] **Step 2: Run to verify failure**

Run: `quarto run tests/vnext/conformance/run.lua`
Expected: FAIL for all new example files (schemas missing).

- [ ] **Step 3: Write the three schemas**

`metadata-core.v1.json`: `oneOf` over `$defs` for `document`, `person`, `organization`, `funding`, discriminated by `recordType` `const` in each branch. Shared required base: `id`, `recordType`, `schemaVersion`; optional `privacy` enum `["public","restricted"]`. Document branch: required `type` and `title`; `type` enum `["research-article","review-article","protocol","brief-report","case-report","editorial","letter","other"]`; `licence` object `{spdx,url,statement}` with `"minProperties": 1` — the subset validator does not implement `minProperties`, so express it as `"anyOf": [{"required":["spdx"]},{"required":["url"]},{"required":["statement"]}]`; `status` enum `["draft","submitted","preprint","accepted","published"]`; `versionHistory` array of `{version,date,description}` (all three required); `dates` object with optional `created`/`modified`/`published` strings matching `^%d{4}-%d{2}-%d{2}$` (write as the Lua-dialect pattern `^%d%d%d%d%-%d%d%-%d%d$`); `identifiers` array of `{scheme,value}`; `language`, `abstract`, `shortTitle`, `keywords` as plain optional fields. Person branch: required `name` (`{given,family}`, family required); optional `orcid` (pattern `^%d%d%d%d%-%d%d%d%d%-%d%d%d%d%-%d%d%d[%dX]$`), `roles` (enum of the 14 CRediT terms: `conceptualization`, `data-curation`, `formal-analysis`, `funding-acquisition`, `investigation`, `methodology`, `project-administration`, `resources`, `software`, `supervision`, `validation`, `visualization`, `writing-original-draft`, `writing-review-editing`), `corresponding` boolean, `affiliations` array of record ids. Organization branch: required `name`; optional `ror`. Funding branch: required `funder` (record id); optional `grant`.

`profile-manifest.v1.json`: required `id` (pattern `^[a-z][a-z0-9-]*:[a-z][a-z0-9-]*$`), `version` (pattern `^%d+%.%d+%.%d+$`), `schema`, `recordTypes` (array, minItems 1); optional `classes`, `regionRoles`, `predicates`, `mappings`, `migratesFrom`.

`profiles/fixture.v1.json`: object requiring the record base plus `label` (string); optional `notes` (array of strings), `category` (enum `["alpha","beta"]`), `region` (string, a content-node id).

- [ ] **Step 4: Run to verify pass**

Run: `quarto run tests/vnext/conformance/run.lua`
Expected: all metadata, manifest and fixture examples PASS (valid accepted, invalid rejected).

- [ ] **Step 5: Commit**

```bash
git add schemas
git commit -m "Add core metadata, profile manifest and fixture profile schemas

Relates to #28"
```

---

### Task 6: State store and report schemas

**Files:**
- Create: `schemas/state-manifest.v1.json`, `schemas/state-regions.v1.json`, `schemas/state-metadata.v1.json`, `schemas/state-citations.v1.json`, `schemas/state-annotations.v1.json`, `schemas/report-envelope.v1.json`
- Create: two examples each (`valid-*.json`, `invalid-*.json`) under the matching `schemas/examples/<name>/` directories

**Interfaces:**
- Consumes: record shapes (Task 5), node/region fields (Task 4), hash pattern (Task 3).
- Produces: schema ids for the five state files and the report envelope; `state-manifest` shape (`stateId`, `generation`, `files`) consumed by Task 7's `manifest.lua`; `report-envelope` shape consumed by Task 8's migration report.

- [ ] **Step 1: Write examples (failing)**

`state-manifest.v1/valid-minimal.json`:

```json
{ "schemaVersion": 1,
  "stateId": "3f7a1c9e0b2d4f6a8c1e3a5b7d9f0e2c",
  "generation": 7,
  "files": [
    { "name": "regions.json", "schema": "https://dougmanuel.github.io/docstyle/schemas/state-regions.v1.json",
      "hash": "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08" } ] }
```

`state-manifest.v1/invalid-bad-state-id.json`: same but `"stateId": "short"` (most likely mistake: wrong identifier length).

`state-regions.v1/valid-two-regions.json`:

```json
{ "schemaVersion": 1, "regions": [
  { "id": "abstract", "kind": "section", "role": "abstract",
    "policy": "authored-preserve",
    "hash": "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
    "source": { "file": "protocol.qmd", "start": 12, "end": 18 } },
  { "id": "g-table-k3m7ap", "kind": "table", "policy": "authored-preserve",
    "hash": "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
    "parent": "methods" } ] }
```

`state-regions.v1/invalid-reserved-explicit-id.json`: a region with `"id": "g-abstract"` and `"generated": false` — schema cannot see reservation, so instead make the invalid case a region missing `policy` (the same likely mistake as the envelope). Reservation is tested behaviourally in Task 7.

`state-metadata.v1/valid-records-and-profiles.json`: `{ "schemaVersion": 1, "profiles": { "docstyle:fixture": "1.0.0" }, "records": [ <the Task 5 valid-document record> ], "relationships": [ { "id": "g-relationship-aaaaaa", "subject": "rec-fx1", "predicate": "fixture-supports", "object": "abstract" } ] }`. Invalid: a record whose `privacy` is `"secret"` (not in the enum).

`state-citations.v1/valid-zotero.json`:

```json
{ "schemaVersion": 1,
  "zoteroPref": "<data data-version=\"3\"/>",
  "citations": [
    { "id": "cite-smith2024", "keys": ["smith2024"],
      "instruction": "ADDIN ZOTERO_ITEM CSL_CITATION {...}",
      "privacy": "public" } ] }
```

Invalid: citation missing `instruction` (the exact-instruction preservation rule is the point of the file).

`state-annotations.v1/valid-comment-thread.json`:

```json
{ "schemaVersion": 1,
  "comments": [
    { "id": "c1", "anchor": "abstract", "author": "Reviewer A",
      "date": "2026-07-01", "text": "Consider shortening.", "privacy": "restricted",
      "replies": [ { "id": "c1r1", "author": "Doug Manuel",
        "date": "2026-07-02", "text": "Agreed." } ] } ],
  "revisions": [
    { "id": "r1", "anchor": "g-paragraph-aaaaaa", "op": "insert",
      "author": "Reviewer A", "date": "2026-07-01", "text": "newly inserted words" } ] }
```

Invalid: a revision with `"op": "moved"` (not in enum `["insert","delete"]`).

`report-envelope.v1/valid-migration-report.json`:

```json
{ "schemaVersion": 1, "operation": "migrate",
  "toolVersion": "0.20.0", "generation": 1,
  "inputs": [ { "name": "field-codes.json",
    "hash": "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08" } ],
  "result": "PASS_WITH_WARNINGS",
  "findings": [ { "level": "warning", "code": "unversioned-sidecar",
    "message": "comments.json identified by shape check" } ] }
```

Invalid: `"result": "OK"` (not one of `PASS`, `PASS_WITH_WARNINGS`, `FAIL` — the most likely drive-by mistake).

- [ ] **Step 2: Run to verify failure**

Run: `quarto run tests/vnext/conformance/run.lua`
Expected: FAIL for every new example (schemas missing).

- [ ] **Step 3: Write the six schemas**

Each `$id` follows the global pattern; each root requires `schemaVersion` with `const: 1`. Shapes exactly as the examples imply: `state-manifest` requires `stateId` (pattern `^[0-9a-f]{32}$` written as `^%x+$` plus `minLength`/`maxLength` 32), `generation` (integer, minimum 1) and `files` (array, items requiring `name`, `schema`, `hash`); `state-regions` items require `id`, `kind` (Task 3 enum), `policy`, `hash`, with optional `role`, `parent`, `source`; `state-metadata` requires `records` (items: the record base — full typed validation happens against `metadata-core` in the runner via `$ref` to its id), `profiles` object, `relationships` (Task 4 relationship shape); `state-citations` items require `id`, `keys` (array of strings, minItems 1), `instruction`; `state-annotations` comments require `id`, `anchor`, `author`, `date`, `text`, with optional `replies` (same shape minus anchor) and revisions require `id`, `anchor`, `op` enum `["insert","delete"]`, `author`, `date`; `report-envelope` requires `operation`, `toolVersion`, `result` enum `["PASS","PASS_WITH_WARNINGS","FAIL"]`, `inputs`, `findings` (items require `level` enum `["info","warning","error"]`, `code`, `message`). All annotation `privacy` fields default-restricted per spec: schema marks them optional; the default is documented prose, not schema.

- [ ] **Step 4: Run to verify pass, then commit**

Run: `quarto run tests/vnext/conformance/run.lua` — expect all example cases PASS.

```bash
git add schemas
git commit -m "Add state store and report envelope schemas with examples

Relates to #28"
```

---

### Task 7: Identifier and manifest behaviour modules

**Files:**
- Create: `tests/vnext/conformance/lib/ids.lua`
- Create: `tests/vnext/conformance/lib/manifest.lua`
- Test: `tests/vnext/conformance/tests/test-ids.lua`
- Test: `tests/vnext/conformance/tests/test-manifest.lua`
- Test: `tests/vnext/conformance/tests/test-model-roundtrip.lua`

**Interfaces:**
- Consumes: `canonical`, `sha256`, `hashes`, `json` (Task 2), state-manifest schema (Task 6), full-coverage model example (Task 4).
- Produces: `ids.generate(kind, used, next_char) -> id` (`used`: set of taken ids; `next_char()`: injected character source so tests are deterministic); `ids.check_explicit(id, used) -> ok, err` (rejects reserved prefixes `g-` and `docstyle-`, rejects duplicates); `manifest.commit(dir, files, opts) -> generation` and `manifest.read(dir) -> manifest | nil, errors` with `opts.fail_before_rename` for interruption injection.

- [ ] **Step 1: Write the failing tests**

`tests/vnext/conformance/tests/test-ids.lua`:

```lua
local ids = require("lib.ids")
local function charsource(s)
  local i = 0
  return function() i = i + 1; return s:sub(i, i) end
end
return {
  { name = "format g-<kind>-<6 base32>", fn = function()
      local id = ids.generate("table", {}, charsource("k3m7ap"))
      assert(id == "g-table-k3m7ap", id)
    end },
  { name = "collision redraws until unused", fn = function()
      local used = { ["g-table-aaaaaa"] = true }
      local id = ids.generate("table", used, charsource("aaaaaabbbbbb"))
      assert(id == "g-table-bbbbbb", id)
    end },
  { name = "explicit ids may not use reserved prefixes or collide", fn = function()
      assert(ids.check_explicit("abstract", {}))
      local ok1 = ids.check_explicit("g-abstract", {})
      local ok2 = ids.check_explicit("docstyle-x", {})
      local ok3 = ids.check_explicit("abstract", { abstract = true })
      assert(not ok1 and not ok2 and not ok3)
    end },
  { name = "persisted id survives a simulated re-render", fn = function()
      -- first render assigns; durable state carries it; second render must reuse
      local state = {}
      local id = ids.generate("figure", state, charsource("qqqqqq"))
      state[id] = true
      local reused = state["g-figure-qqqqqq"] and "g-figure-qqqqqq"
      assert(reused == id)
    end },
}
```

`tests/vnext/conformance/tests/test-manifest.lua`:

```lua
local m = require("lib.manifest")
local json = require("lib.json")
return {
  { name = "commit writes manifest and typed files atomically", fn = function()
      pandoc.system.with_temporary_directory("wp1state", function(dir)
        local g1 = m.commit(dir, { ["regions.json"] = { schemaVersion = 1, regions = {} } })
        assert(g1 == 1)
        local man = assert(m.read(dir))
        assert(man.generation == 1 and #man.stateId == 32 and man.files[1].name == "regions.json")
        local g2 = m.commit(dir, { ["regions.json"] = { schemaVersion = 1, regions = {} } })
        assert(g2 == 2 and m.read(dir).stateId == man.stateId, "stateId must persist")
      end)
    end },
  { name = "interrupted commit leaves previous generation readable", fn = function()
      pandoc.system.with_temporary_directory("wp1state", function(dir)
        m.commit(dir, { ["regions.json"] = { schemaVersion = 1, regions = {} } })
        local okflag = pcall(m.commit, dir,
          { ["regions.json"] = { schemaVersion = 1, regions = { { id = "x" } } } },
          { fail_before_rename = true })
        assert(not okflag, "injected failure must raise")
        local man = assert(m.read(dir))
        assert(man.generation == 1, "old generation must survive")
      end)
    end },
  { name = "hash mismatch is reported on read", fn = function()
      pandoc.system.with_temporary_directory("wp1state", function(dir)
        m.commit(dir, { ["regions.json"] = { schemaVersion = 1, regions = {} } })
        local f = assert(io.open(dir .. "/regions.json", "wb"))
        f:write('{"schemaVersion":1,"regions":[{"tampered":true}]}'); f:close()
        local man, errs = m.read(dir)
        assert(man == nil and errs[1]:match("regions.json"), "expected stale-file error")
      end)
    end },
}
```

`tests/vnext/conformance/tests/test-model-roundtrip.lua`:

```lua
local json = require("lib.json")
local c = require("lib.canonical")
local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local p = pandoc.path.join({ here, "..", "..", "..", "..",
  "schemas", "examples", "document-model.v1", "valid-full-coverage.json" })
return {
  { name = "model round-trips decode-encode-decode without loss", fn = function()
      local m1 = json.read(p)
      local m2 = json.decode(json.encode(m1))
      assert(c.encode(m1) == c.encode(m2), "canonical forms differ after round trip")
    end },
}
```

- [ ] **Step 2: Run to verify failure**

Run: `quarto run tests/vnext/conformance/run.lua`
Expected: new cases FAIL (`lib.ids`, `lib.manifest` missing); round-trip may PASS already (it needs no new module) — that is fine.

- [ ] **Step 3: Implement ids.lua and manifest.lua**

`ids.lua`: `ALPHABET = "abcdefghijklmnopqrstuvwxyz234567"`. `generate` draws six characters from `next_char` (default: `math.random` over the alphabet when not injected), forms `g-<kind>-<suffix>`, redraws while `used[id]`. `check_explicit` returns `false, "reserved prefix"` for `^g%-` or `^docstyle%-`, `false, "duplicate"` when `used[id]`, else `true`.

`manifest.lua`: `commit(dir, files, opts)`: read existing manifest for `stateId` and `generation` (create `stateId` from `sha256.hex` of `dir .. tostring(os.time()) .. tostring(math.random())` truncated to 32 chars when absent); for each typed file, encode with `json.encode`, write to `<name>.tmp`, compute `sha256` of the bytes; build the new manifest table (`schemaVersion = 1`, `stateId`, `generation + 1`, `files` with name, schema id, hash); write it to `manifest.json.tmp`; if `opts and opts.fail_before_rename` then `error("injected failure")`; rename every `<name>.tmp` to `<name>`, then rename `manifest.json.tmp` last (`os.rename` — the manifest rename is the commit point). `read(dir)`: decode `manifest.json`; re-hash each listed file; on any mismatch return `nil, errors`; else return the manifest.

- [ ] **Step 4: Run to verify pass, then commit**

Run: `quarto run tests/vnext/conformance/run.lua` — all cases PASS.

```bash
git add tests/vnext/conformance
git commit -m "Add identifier and atomic manifest behaviour modules

Relates to #28"
```

---

### Task 8: Legacy migration module and mapping fixtures

**Files:**
- Create: `tests/vnext/conformance/legacy/key-map.json`
- Create: `tests/vnext/conformance/lib/migrate.lua`
- Create: `tests/vnext/conformance/legacy/cases/` (one JSON file per case, at least six)
- Test: `tests/vnext/conformance/tests/test-migrate.lua`

**Interfaces:**
- Consumes: envelope schema and enums (Task 3), report envelope (Task 6), `ids`/`hashes` (Tasks 2, 7). Read-only inputs: `inst/schema/docstyle-field-codes.json`, the WP0 field inventories under `tests/vnext/fixtures/*/`, and `tests/vnext/fixtures/legacy-contract.json`.
- Produces: `migrate.payload(legacy_table) -> { envelope, record, findings }`; `migrate.sidecars({ field_codes=?, comments=?, revisions=? }) -> { citations, annotations, report }`. `key-map.json` is the disposition inventory the Task 9 audit cites.

- [ ] **Step 1: Build the legacy key inventory (no test yet — this is evidence gathering)**

Read `inst/schema/docstyle-field-codes.json` and grep the WP0 inventories:

```bash
jq . inst/schema/docstyle-field-codes.json | head -80
rg -o '"type"\s*:\s*"[a-z]+"' tests/vnext/fixtures/*/inventories/*field* | sort -u
```

Write `tests/vnext/conformance/legacy/key-map.json`: one entry per legacy payload key observed, shaped as

```json
{ "schemaVersion": 1,
  "payloadTypes": {
    "char":    { "kind": "span" },
    "div":     { "kind": "section" },
    "list":    { "kind": "list" },
    "section": { "kind": "section" },
    "table":   { "kind": "table" },
    "figure":  { "kind": "figure" },
    "float":   { "kind": "anchor" },
    "anchor":  { "kind": "anchor" }
  },
  "keys": {
    "version": { "disposition": "mapped", "target": "v" },
    "type":    { "disposition": "mapped", "target": "kind" },
    "name":    { "disposition": "mapped", "target": "id" }
  }
}
```

Extend `keys` with every key actually found in the schema file and inventories. Legal dispositions: `mapped` (with `target`), `record` (carried into the migration record body, not the envelope), `dropped` (with `"rationale"`). The migrate test asserts completeness, so an unlisted key fails loudly.

- [ ] **Step 2: Write the failing tests**

`tests/vnext/conformance/tests/test-migrate.lua`:

```lua
local mg = require("lib.migrate")
local json = require("lib.json")
local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local cases_dir = pandoc.path.join({ here, "..", "legacy", "cases" })
local cases = {
  { name = "every mapping case produces its expected envelope", fn = function()
      for _, f in ipairs(pandoc.system.list_directory(cases_dir)) do
        local case = json.read(pandoc.path.join({ cases_dir, f }))
        local out = mg.payload(case.legacy)
        local got, want = json.encode(out.envelope), json.encode(case.expected_envelope)
        assert(got == want, f .. ": " .. got)
      end
    end },
  { name = "unknown legacy key is a blocking finding, not a guess", fn = function()
      local out = mg.payload({ version = 2, type = "div", name = "x",
        mystery = "value" })
      local found = false
      for _, fd in ipairs(out.findings) do
        if fd.code == "unmapped-legacy-key" and fd.level == "error" then found = true end
      end
      assert(found, "expected unmapped-legacy-key error finding")
    end },
  { name = "future version is rejected", fn = function()
      local out = mg.payload({ version = 9, type = "div", name = "x" })
      assert(out.envelope == nil and out.findings[1].code == "unsupported-version")
    end },
  { name = "sidecar migration emits schema-valid outputs and a report", fn = function()
      local js = require("lib.jsonschema")
      local res = mg.sidecars({
        field_codes = { citations = { { keys = { "smith2024" },
          instruction = "ADDIN ZOTERO_ITEM CSL_CITATION {}" } },
          zotero_pref = "<data/>" },
        comments = { { author = "A", date = "2026-07-01",
          text = "note", anchor_text = "the abstract" } },
        revisions = { { author = "A", date = "2026-07-01",
          type = "insert", text = "added" } } })
      local base = "https://dougmanuel.github.io/docstyle/schemas/"
      assert(js.validate(js.resolve(base .. "state-citations.v1.json"), res.citations))
      assert(js.validate(js.resolve(base .. "state-annotations.v1.json"), res.annotations))
      assert(js.validate(js.resolve(base .. "report-envelope.v1.json"), res.report))
      assert(res.report.result ~= "FAIL")
    end },
}
return cases
```

Then author at least six case files in `legacy/cases/`, each `{ "legacy": {...}, "expected_envelope": {...} }`: one per legacy writer generation (a v1, a v2 and a v3 payload copied verbatim from the WP0 field inventories — copy, never edit, the originals), plus a `table` payload with widths (widths land in `out.record`, not the envelope), a `float` payload (kind `anchor`), and a `section` payload. Expected envelopes: `v = 4`; `id` from the legacy `name` when present, else `g-<kind>-migr01` style placeholder documented in the case file; `kind` from `payloadTypes`; `policy`: `structural` for section/float/anchor payloads, `authored-preserve` for the rest — record this policy default in key-map.json as the disposition of the implicit legacy policy; `hash` computed by `hashes.content_hash` over the migration record (the case file stores the resulting literal).

- [ ] **Step 3: Run to verify failure**

Run: `quarto run tests/vnext/conformance/run.lua`
Expected: migrate cases FAIL (`lib.migrate` missing).

- [ ] **Step 4: Implement migrate.lua**

`payload(legacy)`: reject `version` > 3 or < 1 with `unsupported-version` (envelope nil). Look up `type` in `payloadTypes` (unknown type: `error` finding `unknown-payload-type`, envelope nil). Walk every key of the legacy table against `keys` from `key-map.json`: `mapped` writes to the envelope target; `record` copies into the record body; `dropped` adds an `info` finding with the rationale; unlisted adds `error` finding `unmapped-legacy-key` (envelope still produced so the caller can inspect, result blocking). Fill defaults (`v = 4`, policy rule from Step 2), compute `hash` via `hashes.content_hash(record)`.

`sidecars(inputs)`: map `field_codes.citations[]` to `state-citations` entries (`id`: `cite-` plus first key; `keys`, `instruction` verbatim; `privacy = "public"`), `zotero_pref` -> `zoteroPref`; map `comments[]`/`revisions[]` to `state-annotations` (`anchor`: legacy `anchor_text` hashed to a stable placeholder `legacy-anchor-<first 8 hash chars>` — real anchor resolution is WP5, record a `warning` finding `anchor-unresolved`); build a `report-envelope` with `operation = "migrate"`, inputs listed with hashes of their canonical encoding, `result = "PASS_WITH_WARNINGS"` when warnings exist and no errors, `PASS` when clean, `FAIL` when any `error` finding. Inputs are never modified.

- [ ] **Step 5: Run to verify pass, then commit**

Run: `quarto run tests/vnext/conformance/run.lua` — all cases PASS.

```bash
git add tests/vnext/conformance
git commit -m "Add legacy payload and sidecar migration with mapping fixtures

Relates to #28"
```

---

### Task 9: Coverage audit, R bridge and README

**Files:**
- Create: `dev/vnext/wp1-legacy-coverage.md`
- Create: `tests/vnext/conformance/README.md`
- Test: `tests/testthat/test-vnext-conformance.R`

**Interfaces:**
- Consumes: everything above; `key-map.json` dispositions (Task 8).
- Produces: the acceptance-test-9 audit document; a `devtools::test()` bridge so the legacy suite exercises the conformance runner during the migration period.

- [ ] **Step 1: Write the R bridge (failing only if the runner fails)**

`tests/testthat/test-vnext-conformance.R`:

```r
test_that("vNext conformance runner passes", {
  skip_if(Sys.which("quarto") == "", "quarto not on PATH")
  root <- normalizePath(file.path(testthat::test_path(), "..", ".."))
  res <- suppressWarnings(system2(
    "quarto",
    c("run", file.path(root, "tests", "vnext", "conformance", "run.lua")),
    stdout = TRUE, stderr = TRUE
  ))
  status <- attr(res, "status") %||% 0L
  expect_identical(status, 0L, info = paste(res, collapse = "\n"))
})
```

Run: `env R_PROFILE_USER=/dev/null Rscript -e 'devtools::load_all(quiet=TRUE); testthat::test_file("tests/testthat/test-vnext-conformance.R")'`
Expected: PASS (the runner already passes).

- [ ] **Step 2: Build the legacy element inventory**

Enumerate WP1-scope data elements from the legacy implementation. Sources and commands:

```bash
jq -r '.. | objects | keys[]' inst/schema/docstyle-field-codes.json | sort -u   # payload keys
rg -o 'DOCSTYLE_[A-Z_]+' _extensions/docstyle/*.lua R/*.R | sort -u             # marker vocabulary
rg -l 'write_json|toJSON' R/*.R                                                  # sidecar writers
rg -o '"[a-z-]+"\s*=' R/field_codes.R R/generated_content.R | sort -u           # handler payload keys
rg -o 'docstyle[.-][a-z-]+' R/*.R _extensions/docstyle/*.lua | sort -u          # YAML and class conventions
```

Cross-check the ten sidecar files against `tests/vnext/fixtures/legacy-contract.json` (names, lifecycles) and the QMD conventions against `CLAUDE.md` (divs `bibliography`, `docstyle-abstract`, section classes, anchor classes; attributes `page-break`, `line-numbers`, `suppress-top-spacing`, `content-mode`, `widths`; YAML keys `version-history`, `version-summary`, `medrxiv`, `base-doc`, `docstyle.validators`, `docstyle.silence-version-warning`).

- [ ] **Step 3: Write the audit document**

`dev/vnext/wp1-legacy-coverage.md` — sentence-case headings, one table:

| Element | Source | Classification | Target |
|---|---|---|---|
| payload type `table` | `inst/schema/docstyle-field-codes.json` | mapped | `field-envelope.v4` kind `table` |
| sidecar `page-config.json` | `R/page_layout.R` | assigned | WP3 property model |
| ... | ... | ... | ... |

Every element gets exactly one classification: `mapped` (name the schema and field), `assigned` (name the work package), or `dropped` (record the rationale). Close with three declared bounds carried from this plan: the NFC assumption (Task 2), the Lua-dialect `pattern` bound (Task 1), and the `anchor` node-type addition (file-structure note) flagged as a spec revision for review. End with the completion statement: "No element remains unclassified." — the document is not complete while any row is missing.

Run the style checker: `python3 ~/github/ai-infrastructure/skills/writing-style/scripts/check_style.py dev/vnext/wp1-legacy-coverage.md` — fix findings.

- [ ] **Step 4: Write the runner README**

`tests/vnext/conformance/README.md`: how to run (`quarto run tests/vnext/conformance/run.lua`), what PASS/FAIL means, the test-file convention, the three declared bounds from Step 3, and the rule that `schemas/` changes require matching example changes in the same commit.

- [ ] **Step 5: Full verification**

```bash
quarto run tests/vnext/conformance/run.lua                       # expect PASS n | FAIL 0
env R_PROFILE_USER=/dev/null Rscript -e 'devtools::test()'       # expect FAIL 0 | WARN 30 | SKIP 4
git status --short                                                # nothing unexpected; WP0 fixtures untouched
git diff --stat main -- tests/vnext/fixtures/                     # must be empty
```

- [ ] **Step 6: Commit**

```bash
git add dev/vnext/wp1-legacy-coverage.md tests/vnext/conformance/README.md tests/testthat/test-vnext-conformance.R
git commit -m "Add legacy coverage audit, conformance README and R bridge

Closes the WP1 acceptance tests. Relates to #28"
```

---

## Completion checklist (maps to the spec's acceptance tests)

1. Schemas validate valid and reject invalid examples — Tasks 3–6 (runner example discovery).
2. Full-coverage synthetic model round-trips — Tasks 4 and 7 (`test-model-coverage`, `test-model-roundtrip`).
3. Identifier generation, collision and persistence — Task 7 (`test-ids`).
4. Reproducible hashing with non-ASCII NFC text — Task 2 (`test-hashes`; NFC bound declared).
5. Fixture profile registration, validation, region link, relationship — Tasks 5 and 6 (`fixture.v1` examples; `state-metadata` example carries the profile and relationship).
6. Atomic manifest under interruption — Task 7 (`test-manifest`).
7. Legacy fixtures translate v1–v3 payloads and three durable sidecars with a report, inputs untouched — Task 8.
8. Reconciliation outcomes — the reconciliation *rules* are spec contracts consumed by WP5; WP1 verifies their data preconditions (ids, hashes, policies present in every schema). Record this reading in the audit; if review wants executable reconciliation cases in WP1, add a table-driven `test-reconcile.lua` exercising the six rules over synthetic pairs.
9. Legacy element coverage — Task 9; blocking until no row is unclassified.

After the final commit, flag for review: the `anchor` node-type addition, the NFC bound, the Lua pattern dialect, and the acceptance-test-8 reading above. Do not push; Doug reviews the branch first.
