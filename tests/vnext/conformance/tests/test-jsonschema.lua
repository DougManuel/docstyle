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
  { name = "additionalProperties as a schema validates every extra property value", fn = function()
      -- The id-keyed registry shape (document-model.v1): no `properties`
      -- declared, so EVERY property is an "additional" property and must
      -- match the value schema. A value missing a required field, or
      -- violating one of its constraints, must fail -- this is exactly the
      -- per-entry validation the array+items shape used to provide and the
      -- keyed reshape lost when additionalProperties-as-schema went
      -- unenforced.
      local s = { type = "object", additionalProperties = {
        type = "object", required = { "id" },
        properties = { id = { type = "string", minLength = 1 } } } }
      ok(s, { k1 = { id = "a" }, k2 = { id = "b" } })
      bad(s, { k1 = { id = "a" }, k2 = {} })      -- k2 missing required id
      bad(s, { k1 = { id = "" } })                -- k1 violates minLength
    end },
  { name = "additionalProperties schema reports the offending property path", fn = function()
      local s = { type = "object", additionalProperties = {
        type = "object", required = { "id" },
        properties = { id = { type = "string", minLength = 1 } } } }
      local v, errs = js.validate(s, { k2 = { id = "" } })
      assert(not v, "expected invalid")
      local found = false
      for _, e in ipairs(errs) do if e.path:match("^/k2") then found = true end end
      assert(found, "expected an error at path /k2, got " .. tostring(errs[1] and errs[1].path))
    end },
  { name = "additionalProperties schema does not apply to declared properties", fn = function()
      -- Only keys NOT in `properties` are "additional"; declared ones use
      -- their own subschema, mirroring the == false branch's allowlist.
      local s = { type = "object",
        properties = { name = { type = "string" } },
        additionalProperties = { type = "integer" } }
      ok(s, { name = "x", count = 3 })      -- name declared (string); count additional (integer)
      bad(s, { name = "x", count = "no" })  -- count additional must be integer
      ok(s, { name = "x" })                 -- only the declared property
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
  { name = "absolute ref switches resolution root to target document", fn = function()
      js.register("https://example.org/record.v1.json", {
        ["$id"] = "https://example.org/record.v1.json",
        oneOf = { { ["$ref"] = "#/$defs/rec" } },
        ["$defs"] = { rec = { type = "object", required = { "id" },
          properties = { id = { type = "string" },
            privacy = { enum = { "public", "restricted" } } } } } })
      local outer = { type = "object", properties = {
        records = { type = "array",
          items = { ["$ref"] = "https://example.org/record.v1.json" } } } }
      ok(outer, { records = { { id = "a", privacy = "public" } } })
      bad(outer, { records = { { id = "a", privacy = "secret" } } })
    end },
  { name = "absolute ref with a JSON Pointer fragment resolves inside the registered document", fn = function()
      -- Metadata-binding spec, schema-change manifest ("conformance runner"
      -- row): `$ref` of the form `<registered $id>#/<pointer>` walks the
      -- pointer inside the registered document, and switches the resolution
      -- root to that document so its own `#/$defs/...` refs keep resolving
      -- against its own `$defs` (catalogue.v1 reuses document-model.v1 and
      -- metadata-core.v1 definitions this way).
      js.register("https://example.org/defs.v1.json", {
        ["$id"] = "https://example.org/defs.v1.json",
        ["$defs"] = {
          leaf = { type = "string", minLength = 1 },
          wrap = { type = "object", required = { "v" },
            properties = { v = { ["$ref"] = "#/$defs/leaf" } } },
          ["a/b"] = { type = "integer" } } })
      local s = { type = "object", properties = {
        w = { ["$ref"] = "https://example.org/defs.v1.json#/$defs/wrap" },
        e = { ["$ref"] = "https://example.org/defs.v1.json#/$defs/a~1b" } } }
      ok(s, { w = { v = "x" }, e = 3 })
      bad(s, { w = { v = "" } })          -- nested fragment ref resolved in the target doc
      bad(s, { e = "not an integer" })    -- ~1 unescapes to "/"
    end },
  { name = "absolute ref with an empty fragment resolves to the whole registered document", fn = function()
      js.register("https://example.org/whole.v1.json", { type = "integer" })
      ok({ ["$ref"] = "https://example.org/whole.v1.json#" }, 1)
      bad({ ["$ref"] = "https://example.org/whole.v1.json#" }, "x")
    end },
  { name = "absolute ref with a pointer into a missing definition fails loudly", fn = function()
      js.register("https://example.org/sparse.v1.json", { ["$defs"] = {} })
      local v, errs = js.validate({ ["$ref"] = "https://example.org/sparse.v1.json#/$defs/absent" }, "x")
      assert(not v, "a dangling pointer must not validate")
      assert(errs[1].message:match("unresolved"), "expected an unresolved-$ref error, got " .. tostring(errs[1].message))
      local v2 = js.validate({ ["$ref"] = "https://example.org/unregistered.v1.json#/$defs/x" }, "x")
      assert(not v2, "a pointer into an unregistered document must not validate")
    end },
  { name = "JSON Pointer array-index segments are zero-based", fn = function()
      -- RFC 6901: "/oneOf/0" is the FIRST element; Lua arrays are 1-based.
      -- metadata-core.v1's oneOf[0] is {"$ref": "#/$defs/document"}, whose
      -- own fragment ref must then resolve against metadata-core's $defs.
      local base = "https://dougmanuel.github.io/docstyle/schemas/metadata-core.v1.json"
      local s = { ["$ref"] = base .. "#/oneOf/0" }
      ok(s, { id = "d", recordType = "document", schemaVersion = 1, type = "other", title = "T" })
      bad(s, { id = "p", recordType = "person", schemaVersion = 1, name = { family = "F" } })
      js.register("https://example.org/arr.v1.json", { items = { { type = "string" }, { type = "integer" } } })
      ok({ ["$ref"] = "https://example.org/arr.v1.json#/items/1" }, 5)
      bad({ ["$ref"] = "https://example.org/arr.v1.json#/items/1" }, "x")
      bad({ ["$ref"] = "https://example.org/arr.v1.json#/items/2" }, 5)   -- out of range: unresolved
      bad({ ["$ref"] = "https://example.org/arr.v1.json#/items/01" }, 5)  -- leading zero is not an index
      bad({ ["$ref"] = "https://example.org/arr.v1.json#/items/-" }, 5)   -- "-" names no element
    end },
  { name = "JSON Pointer segments are percent-decoded, then tilde-decoded, and may be empty", fn = function()
      -- RFC 6901 section 6 (URI fragment form) then section 4: percent-
      -- decode first, then ~1 -> "/" before ~0 -> "~", so "~01" is "~1".
      js.register("https://example.org/esc.v1.json", { ["$defs"] = {
        ["a b"] = { type = "integer" }, ["~1"] = { type = "boolean" },
        ["c%d"] = { type = "string" }, [""] = { type = "null" } } })
      ok({ ["$ref"] = "https://example.org/esc.v1.json#/$defs/a%20b" }, 1)
      bad({ ["$ref"] = "https://example.org/esc.v1.json#/$defs/a%20b" }, "x")
      ok({ ["$ref"] = "https://example.org/esc.v1.json#/$defs/~01" }, true)
      bad({ ["$ref"] = "https://example.org/esc.v1.json#/$defs/~01" }, 1)
      ok({ ["$ref"] = "https://example.org/esc.v1.json#/$defs/c%25d" }, "x")
      bad({ ["$ref"] = "https://example.org/esc.v1.json#/$defs/c%25d" }, 1)
      ok({ ["$ref"] = "https://example.org/esc.v1.json#/$defs/" }, pandoc.json.null)
      bad({ ["$ref"] = "https://example.org/esc.v1.json#/$defs/" }, 1)
    end },
  { name = "cross-file ref into document-model.v1 resolves in the conformance run", fn = function()
      -- Acceptance criterion 12 (second half): the real registered schema,
      -- not a synthetic stand-in. run.lua registers schemas/ before tests.
      local base = "https://dougmanuel.github.io/docstyle/schemas/document-model.v1.json"
      assert(js.resolve(base), "document-model.v1 is not registered")
      local s = { ["$ref"] = base .. "#/$defs/table-semantics" }
      ok(s, { label = "Table 1", caption = "g-caption-x2r9qa" })
      bad(s, { label = "Table 1", lable = "typo" })
    end },
  { name = "errors carry instance paths", fn = function()
      local s = { type = "object", properties = { a = { type = "string" } } }
      local v, errs = js.validate(s, { a = 5 })
      assert(not v and errs[1].path == "/a", "path was " .. tostring(errs and errs[1] and errs[1].path))
    end },
  { name = "validate raises on a nil schema instead of vacuously passing", fn = function()
      -- A nil schema means a caller took resolve()'s nil (unregistered id)
      -- straight into validate() without checking it. That must be a loud
      -- usage error, not a silent pass -- otherwise an unregistered schema
      -- id and a legitimately unconstrained `{}` schema are indistinguishable
      -- from the caller's side (both currently would "validate" everything).
      local okflag, err = pcall(js.validate, nil, "x")
      assert(not okflag, "expected js.validate(nil, ...) to raise")
      assert(tostring(err):match("nil"), "expected the error to mention the nil schema, got " .. tostring(err))
    end },
  { name = "validate still passes an unconstrained (empty) schema", fn = function()
      -- Distinguishes "unregistered" (nil, above) from "unconstrained"
      -- (an actual empty schema object, which legitimately matches anything).
      ok({}, "anything at all")
      ok({}, 42)
      ok({}, { nested = { 1, 2, 3 } })
    end },
}
