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
