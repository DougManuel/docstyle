-- tests/vnext/conformance/tests/test-state-id-uniqueness.lua
-- Wave 2 item 4: id uniqueness within state-metadata's `records[]` and
-- state-regions's `regions[]`. These stay arrays -- Doug's keyed-registry
-- decision applies only to document-model's registries.{metadata,
-- relationships,assets} (Wave 2 item 1; see schemas/document-model.v1.json)
-- because those are the model's registries. state-metadata.json and
-- state-regions.json are durable local state files, not registries, so
-- uniqueness is not free from JSON object-key semantics here. The
-- validator has no uniqueItems-by-field (see lib/jsonschema.lua's header),
-- so a duplicate id passes schema validation untouched -- this file
-- documents that gap and provides the actual targeted check
-- (find_duplicate_id) a caller runs alongside schema validation. Fixtures
-- stay inline rather than under schemas/examples/: that directory's
-- per-file check is pure schema validation (run.lua step 3), and a
-- duplicate-id "invalid" fixture placed there would be misjudged as
-- passing for the same reason a backwards source range would (see
-- test-state-regions-source.lua).
local js = require("lib.jsonschema")

local METADATA_SCHEMA_ID = "https://dougmanuel.github.io/docstyle/schemas/state-metadata.v1.json"
local REGIONS_SCHEMA_ID = "https://dougmanuel.github.io/docstyle/schemas/state-regions.v1.json"
local HASH = "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"

-- Returns the first duplicated `id`, or nil if every id in `list` is
-- distinct.
local function find_duplicate_id(list)
  local seen = {}
  for _, item in ipairs(list) do
    if seen[item.id] then return item.id end
    seen[item.id] = true
  end
  return nil
end

return {
  { name = "state-metadata: schema alone does not reject a duplicate records[].id", fn = function()
      local schema = assert(js.resolve(METADATA_SCHEMA_ID), "state-metadata.v1 not registered")
      local doc = {
        schemaVersion = 1,
        profiles = {},
        relationships = {},
        records = {
          { id = "rec-dup", recordType = "organization", schemaVersion = 1, name = "Org A" },
          { id = "rec-dup", recordType = "organization", schemaVersion = 1, name = "Org B" },
        },
      }
      assert(js.validate(schema, doc),
        "documents the known schema-level gap (no uniqueItems-by-field); " ..
        "if this now fails, the validator gained that support and this test/comment should be updated")
    end },

  { name = "targeted check: find_duplicate_id catches the duplicate records[].id", fn = function()
      local records = {
        { id = "rec-dup", recordType = "organization", schemaVersion = 1, name = "Org A" },
        { id = "rec-dup", recordType = "organization", schemaVersion = 1, name = "Org B" },
      }
      assert(find_duplicate_id(records) == "rec-dup")
    end },

  { name = "targeted check: find_duplicate_id passes distinct records[].id", fn = function()
      local records = {
        { id = "rec-a", recordType = "organization", schemaVersion = 1, name = "Org A" },
        { id = "rec-b", recordType = "organization", schemaVersion = 1, name = "Org B" },
      }
      assert(find_duplicate_id(records) == nil)
    end },

  { name = "state-regions: schema alone does not reject a duplicate regions[].id", fn = function()
      local schema = assert(js.resolve(REGIONS_SCHEMA_ID), "state-regions.v1 not registered")
      local doc = {
        schemaVersion = 1,
        regions = {
          { id = "dup-1", kind = "section", policy = "structural", hash = HASH },
          { id = "dup-1", kind = "paragraph", policy = "structural", hash = HASH },
        },
      }
      assert(js.validate(schema, doc),
        "documents the known schema-level gap (no uniqueItems-by-field); " ..
        "if this now fails, the validator gained that support and this test/comment should be updated")
    end },

  { name = "targeted check: find_duplicate_id catches the duplicate regions[].id", fn = function()
      local regions = {
        { id = "dup-1", kind = "section", policy = "structural", hash = HASH },
        { id = "dup-1", kind = "paragraph", policy = "structural", hash = HASH },
      }
      assert(find_duplicate_id(regions) == "dup-1")
    end },

  { name = "targeted check: find_duplicate_id passes distinct regions[].id", fn = function()
      local regions = {
        { id = "abstract", kind = "section", policy = "structural", hash = HASH },
        { id = "g-table-k3m7ap", kind = "table", policy = "structural", hash = HASH },
      }
      assert(find_duplicate_id(regions) == nil)
    end },
}
