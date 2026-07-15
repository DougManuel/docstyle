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
