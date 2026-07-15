-- tests/vnext/conformance/tests/test-state-regions-source.lua
-- Wave 2 item 3: schemas/state-regions.v1.json's "source" member now
-- requires file/start/end together (schema-expressible, checked here
-- directly against the registered schema) and file must be non-empty.
-- "end >= start" is a cross-field comparison the validator cannot express
-- (see lib/jsonschema.lua's header: no if/then/else, no cross-field
-- compare) -- source_order_ok() below is the targeted, test-level check
-- that covers it instead. This file intentionally keeps its fixtures
-- inline rather than under schemas/examples/state-regions.v1/: that
-- directory is auto-validated purely by schema (see run.lua step 3), and
-- an "end < start" fixture placed there would be misjudged as passing
-- (a false "invalid example validated" runner failure) precisely because
-- the schema cannot see the violation -- exactly the gap this file exists
-- to document and cover by other means.
local js = require("lib.jsonschema")

local SCHEMA_ID = "https://dougmanuel.github.io/docstyle/schemas/state-regions.v1.json"
local HASH = "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"

local function mksource(file, start_, end_)
  return { file = file, start = start_, ["end"] = end_ }
end

local function region(source)
  local r = { id = "r1", kind = "section", policy = "authored-preserve", hash = HASH }
  if source then r.source = source end
  return r
end

-- The validator has no cross-field comparison, so "source.end >=
-- source.start" cannot live in the schema itself. This is the actual
-- conformance check for that invariant; it never touches run.lua or the
-- schema.
local function source_order_ok(r)
  if not r.source then return true end
  local s = r.source
  if s.start == nil or s["end"] == nil then return true end -- schema's own "required" already covers incompleteness
  return s["end"] >= s.start
end

return {
  { name = "schema: complete source (file+start+end) validates", fn = function()
      local schema = assert(js.resolve(SCHEMA_ID), "state-regions.v1 not registered")
      local doc = { schemaVersion = 1, regions = { region(mksource("protocol.qmd", 12, 18)) } }
      assert(js.validate(schema, doc))
    end },

  { name = "schema: source missing a required member (end) is rejected", fn = function()
      local schema = assert(js.resolve(SCHEMA_ID))
      local doc = { schemaVersion = 1, regions = { region({ file = "protocol.qmd", start = 12 }) } }
      assert(not js.validate(schema, doc), "expected source missing 'end' to be rejected")
    end },

  { name = "schema: empty source file is rejected", fn = function()
      local schema = assert(js.resolve(SCHEMA_ID))
      local doc = { schemaVersion = 1, regions = { region(mksource("", 12, 18)) } }
      assert(not js.validate(schema, doc), "expected an empty source.file to be rejected")
    end },

  { name = "documented gap: schema alone cannot reject end < start", fn = function()
      local schema = assert(js.resolve(SCHEMA_ID))
      local doc = { schemaVersion = 1, regions = { region(mksource("protocol.qmd", 18, 12)) } }
      assert(js.validate(schema, doc),
        "documents the known schema-level gap (no cross-field compare); " ..
        "if this now fails, the validator gained end>=start support and this test/comment should be updated")
    end },

  { name = "targeted check: source_order_ok rejects end < start and accepts end >= start", fn = function()
      assert(not source_order_ok(region(mksource("protocol.qmd", 18, 12))), "expected end < start to be rejected")
      assert(source_order_ok(region(mksource("protocol.qmd", 12, 18))), "expected end > start to pass")
      assert(source_order_ok(region(mksource("protocol.qmd", 12, 12))), "expected end == start to pass")
      assert(source_order_ok(region(nil)), "a region without a source has nothing to compare")
    end },
}
