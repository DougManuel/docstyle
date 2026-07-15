-- tests/vnext/conformance/lib/profile.lua
-- Semantic gate for the metadata-profile mechanism (WP1 spec, "Metadata-
-- profile mechanism"; acceptance test 5). Profile validation is two
-- layers that compose rather than duplicate each other:
--
-- - STRUCTURAL gate: schemas/state-metadata.v1.json's `records[]` `anyOf`.
--   Branch 1 validates a core metadata-core.v1 record; branch 2 accepts
--   any object that merely carries id/recordType/schemaVersion/profile,
--   because state-metadata.v1 itself has no way to know what any given
--   profile's actual record shape requires. That permissiveness means a
--   record can satisfy branch 2 while still violating its own profile's
--   real schema (e.g. a docstyle:fixture record missing the profile's
--   required `label`) -- the "anyOf branch-2 bypass".
-- - SEMANTIC gate: this module. validate_metadata() below composes the
--   ACTIVE profile's own schema for every profile-typed record and
--   validates against it, closing the gap branch 2 leaves open.
--
-- validate_metadata(state_metadata_doc, available_profile_ids) -> { ok, findings }
--
-- state_metadata_doc: a state-metadata.v1-shaped document -- `.records`
-- (array) and `.profiles` (object mapping activated profile id -> version
-- string, i.e. what `docstyle.profiles` in YAML resolves to).
-- available_profile_ids: the profile ids whose schema is registered
-- (js.resolve() would return non-nil) and safe to compose against, as
-- either a plain array ({"docstyle:fixture"}) or an already-built set
-- (string key -> truthy). The CALLER decides availability -- e.g. which
-- profiles are actually bundled/installed in this project -- rather than
-- this module inferring it from the schema registry alone, mirroring the
-- spec's own separation between "active" (declared in YAML/doc.profiles)
-- and "available" (schema resolvable in this installation).
--
-- Per-record dispatch (spec, "Decision (namespace and registration)":
-- "activation of an unavailable profile is a validation failure, while
-- profile-typed data for an inactive profile is preserved as opaque data
-- with a warning"):
--   - record.profile absent -> no profile check. Structural/core
--     validation is state-metadata.v1's job (already covered by its
--     anyOf), not this module's layer. Skipped entirely -- untouched.
--   - record.profile == P, P listed as ACTIVE in doc.profiles AND P in
--     available_profile_ids -> resolve P's profile schema (see the
--     mapping convention below) and validate the record against it; a
--     failure is a blocking `error` finding (profile-record-invalid).
--   - record.profile == P but P is NOT active, or NOT available -> a
--     `warning` finding (profile-unavailable-preserved); NOT blocking.
--     The record itself is untouched -- preserved as opaque data, per the
--     spec's own wording.
-- Independently of any record: every profile id doc.profiles lists as
-- ACTIVE whose schema is NOT available is its own blocking `error` finding
-- (profile-activation-unavailable), even when no record currently
-- references it -- activating an unavailable profile is a failure in its
-- own right.
--
-- ok = (no finding has level == "error").
--
-- Profile id -> schema mapping convention: WP1 ships exactly one real
-- profile, docstyle:fixture, whose schema is schemas/profiles/fixture.v1
-- .json (see the WP1 spec's JSON Schema inventory table). The rule this
-- module implements is a direct derivation, not a lookup table: strip the
-- "<namespace>:" prefix from the profile id, keep "<name>", and resolve
-- "<schema-base>/profiles/<name>.v1.json" (docstyle:fixture ->
-- profiles/fixture.v1.json). A hardcoded id->file table would need a new
-- entry per profile; this derivation generalizes to any future profile as
-- long as its manifest's namespace:name maps onto a profiles/<name>.v1
-- .json file one-for-one, matching the fixture profile's own pairing. If a
-- later profile's naming ever needs to diverge from this rule, the
-- profile's own manifest `schema` field (profile-manifest.v1, WP1 spec's
-- "Profile manifest" table) is the authoritative source a real
-- implementation should read instead of re-deriving it here -- this
-- derivation is a WP1 conformance-test convenience, not the shipped
-- resolution mechanism (that carrier is WP4's).

local js = require("lib.jsonschema")

local M = {}

local SCHEMA_BASE = "https://dougmanuel.github.io/docstyle/schemas"

-- "docstyle:fixture" -> ".../schemas/profiles/fixture.v1.json". Returns nil
-- when `profile_id` doesn't match the "<namespace>:<name>" shape the WP1
-- spec's profile-manifest.v1 `id` field requires.
local function profile_schema_id(profile_id)
  local name = profile_id:match("^[a-z][a-z0-9-]*:([a-z][a-z0-9-]*)$")
  if not name then return nil end
  return SCHEMA_BASE .. "/profiles/" .. name .. ".v1.json"
end

-- Accepts either a plain array of ids (integer-keyed, e.g.
-- {"docstyle:fixture"}) or an already-built set (string key -> truthy).
-- ipairs() alone would silently see zero entries in a set-shaped table
-- (all its keys are strings, none integer), so detect the shape first
-- rather than risk quietly treating every id as unavailable -- the same
-- has_string_key-style shape check lib/jsonschema.lua and lib/migrate.lua
-- both use for the same pandoc.json.decode object/array ambiguity.
local function to_set(list_or_set)
  local set = {}
  if list_or_set == nil then return set end
  local is_set = false
  for k in pairs(list_or_set) do
    if type(k) == "string" then is_set = true break end
  end
  if is_set then
    for k, v in pairs(list_or_set) do if v then set[k] = true end end
  else
    for _, id in ipairs(list_or_set) do set[id] = true end
  end
  return set
end

function M.validate_metadata(state_metadata_doc, available_profile_ids)
  state_metadata_doc = state_metadata_doc or {}
  local records = state_metadata_doc.records or {}
  local active = state_metadata_doc.profiles or {}
  local available = to_set(available_profile_ids)

  local findings = {}

  for _, record in ipairs(records) do
    local p = record.profile
    if p ~= nil then
      local is_active = active[p] ~= nil
      local is_available = available[p] == true
      if is_active and is_available then
        local schema_id = profile_schema_id(p)
        local schema = schema_id and js.resolve(schema_id)
        if schema == nil then
          -- available_profile_ids claimed this profile was available but
          -- the derived schema id isn't actually registered -- a caller/
          -- config error, not silently skipped validation.
          findings[#findings + 1] = { level = "error", code = "profile-schema-unresolved",
            message = "profile '" .. p .. "' was reported available but its schema id ("
              .. tostring(schema_id) .. ") is not registered" }
        else
          local ok, errs = js.validate(schema, record)
          if not ok then
            local detail = errs and errs[1] and (errs[1].path .. " " .. errs[1].message) or "validation failed"
            findings[#findings + 1] = { level = "error", code = "profile-record-invalid",
              message = "record '" .. tostring(record.id) .. "' fails its profile '" .. p
                .. "' schema: " .. detail }
          end
        end
      else
        findings[#findings + 1] = { level = "warning", code = "profile-unavailable-preserved",
          message = "record '" .. tostring(record.id) .. "' references profile '" .. p
            .. "', which is not active/available; preserved as opaque data" }
      end
    end
  end

  -- Independent of any record: activating a profile whose schema is not
  -- available is a validation failure in its own right (spec: "activation
  -- of an unavailable profile is a validation failure").
  for profile_id in pairs(active) do
    if not available[profile_id] then
      findings[#findings + 1] = { level = "error", code = "profile-activation-unavailable",
        message = "profile '" .. profile_id .. "' is activated but its schema is not available" }
    end
  end

  local ok = true
  for _, f in ipairs(findings) do
    if f.level == "error" then ok = false end
  end

  return { ok = ok, findings = findings }
end

return M
