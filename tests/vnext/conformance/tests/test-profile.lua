-- tests/vnext/conformance/tests/test-profile.lua
-- Wave 3 item 1: adversarial coverage for lib/profile.lua's
-- validate_metadata(), the semantic gate that composes an active profile's
-- own schema against its records -- closing the "anyOf branch-2 bypass"
-- that schemas/state-metadata.v1.json's deliberately permissive
-- records[] anyOf leaves open (see lib/profile.lua's header comment for
-- the full two-layer design). Case (b) below is the key case: a fixture
-- record missing its profile-required `label` passes state-metadata.v1's
-- own anyOf (branch 2 asks only for id/recordType/schemaVersion/profile)
-- but must fail here.
local js = require("lib.jsonschema")
local json = require("lib.json")
local profile = require("lib.profile")

local FIXTURE_SCHEMA_ID = "https://dougmanuel.github.io/docstyle/schemas/profiles/fixture.v1.json"

-- The runner registers every schemas/ and schemas/profiles/ file before any
-- test file's cases run (run.lua step 1, Wave 1), so js.resolve() should
-- already return the fixture profile schema here. Register it defensively
-- if some other invocation path hasn't already done so, rather than
-- silently letting every profile-active case below vacuously fail to
-- resolve a schema that really does exist on disk.
if js.resolve(FIXTURE_SCHEMA_ID) == nil then
  local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
  local root = pandoc.path.join({ here, "..", "..", ".." })
  local schema = json.read(pandoc.path.join({ root, "schemas", "profiles", "fixture.v1.json" }))
  js.register(schema["$id"], schema)
end
assert(js.resolve(FIXTURE_SCHEMA_ID) ~= nil,
  "fixture.v1 profile schema is not registered even after a defensive load")

-- Mirrors schemas/examples/fixture.v1/valid-record.json's shape (built
-- inline per Wave 3 scope -- this file does not read the example at test
-- time, only takes it as the reference shape).
local function valid_fixture_record(id)
  return {
    id = id or "rec-fx1",
    recordType = "fixture-record",
    schemaVersion = 1,
    profile = "docstyle:fixture",
    label = "Example fixture record",
    notes = { "first note", "second note" },
    category = "beta",
    region = "abstract",
  }
end

local function fixture_record_missing_label(id)
  local r = valid_fixture_record(id)
  r.label = nil
  return r
end

local function absent_profile_record(id)
  return {
    id = id or "rec-absent",
    recordType = "absent-record",
    schemaVersion = 1,
    profile = "docstyle:absent",
  }
end

local function core_record(id)
  return {
    id = id or "rec-core",
    recordType = "organization",
    schemaVersion = 1,
    name = "Example Org",
  }
end

local function has_finding(findings, level, code)
  for _, f in ipairs(findings) do
    if f.level == level and (code == nil or f.code == code) then return true end
  end
  return false
end

return {
  { name = "(a) fixture record with label, profile active+available -> ok, no error findings", fn = function()
      local doc = {
        records = { valid_fixture_record() },
        profiles = { ["docstyle:fixture"] = "1.0.0" },
      }
      local result = profile.validate_metadata(doc, { "docstyle:fixture" })
      assert(result.ok == true, "expected ok=true for a complete fixture record")
      assert(not has_finding(result.findings, "error"),
        "expected no error finding for a complete fixture record")
    end },

  { name = "(b) fixture record missing label, profile active+available -> ok=false with an error finding (the anyOf branch-2 bypass case)", fn = function()
      local doc = {
        records = { fixture_record_missing_label() },
        profiles = { ["docstyle:fixture"] = "1.0.0" },
      }
      -- Sanity check on the premise: branch 2 of state-metadata.v1's
      -- records[] anyOf (id/recordType/schemaVersion/profile only) would
      -- accept this record even without `label` -- that is exactly the
      -- structural-layer permissiveness this module's semantic layer must
      -- catch instead.
      local result = profile.validate_metadata(doc, { "docstyle:fixture" })
      assert(result.ok == false,
        "expected ok=false when a fixture record is missing its profile-required label")
      assert(has_finding(result.findings, "error", "profile-record-invalid"),
        "expected a profile-record-invalid error finding for the missing-label record")
    end },

  { name = "(c) record referencing an inactive/unavailable profile is preserved with a warning, not blocking", fn = function()
      local doc = {
        records = { absent_profile_record() },
        profiles = {}, -- "docstyle:absent" is not activated
      }
      -- "docstyle:fixture" being available doesn't make "docstyle:absent"
      -- available too -- availability is checked per profile id.
      local result = profile.validate_metadata(doc, { "docstyle:fixture" })
      assert(result.ok == true,
        "an inactive/unavailable profile reference must not block validation")
      assert(has_finding(result.findings, "warning", "profile-unavailable-preserved"),
        "expected a profile-unavailable-preserved warning finding")
    end },

  { name = "(d) activating an unavailable profile is a blocking failure even with no referencing record", fn = function()
      local doc = {
        records = {},
        profiles = { ["docstyle:absent"] = "1.0.0" }, -- activated but never available
      }
      local result = profile.validate_metadata(doc, { "docstyle:fixture" })
      assert(result.ok == false,
        "expected activation of an unavailable profile to block, independent of any record")
      assert(has_finding(result.findings, "error", "profile-activation-unavailable"),
        "expected a profile-activation-unavailable error finding")
    end },

  { name = "(e) core record with no profile field is untouched by the profile gate", fn = function()
      local doc = {
        records = { core_record() },
        profiles = {},
      }
      local result = profile.validate_metadata(doc, {})
      assert(result.ok == true, "a profile-less record must never block")
      assert(#result.findings == 0, "a profile-less record must produce no profile findings at all")
    end },
}
