-- tests/vnext/conformance/tests/test-schema-additivity.lua
-- Metadata-binding spec, acceptance criterion 1: "every pre-existing valid
-- example still validates (additivity is executable, not asserted)".
--
-- run.lua's example loop already validates every valid-* file, but on its
-- own it cannot tell a pre-existing example from a new one, nor notice a
-- pre-existing example being deleted or quietly edited until it fits a
-- narrowed schema. This file pins the valid examples that existed before
-- the metadata-binding v1 revision (the PR #49 base, 3d78e19): each must
-- still exist, still validate against its schema, and still carry the same
-- content, compared by the SHA-256 of its canonical JSON encoding
-- (lib/canonical.lua) rather than raw bytes, so a line-ending or
-- whitespace-only checkout difference is not mistaken for an edit.
--
-- The list is closed on purpose: a later additive revision appends its own
-- baseline rather than editing these rows.
local js = require("lib.jsonschema")
local json = require("lib.json")
local canonical = require("lib.canonical")
local sha = require("lib.sha256")

local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local root = pandoc.path.join({ here, "..", "..", ".." })
local BASE = "https://dougmanuel.github.io/docstyle/schemas/"

-- { example dir (= schema name), file, canonical sha256 }
local BASELINE = {
  { "document-model.v1", "valid-full-coverage.json",
    "sha256:e1b2f3f0d6c50b341237a72c9127e62265a2ffa286be3991774b30d60649b816" },
  { "field-envelope.v4", "valid-full.json",
    "sha256:b28759ffa9b437b925f5c8640d873611a989afbee8d5a7585f2f9030dbdd134a" },
  { "field-envelope.v4", "valid-minimal.json",
    "sha256:cc40b71ff39131ef80cfb93ca7a4916fd123f38c3a33f1aa31275b85975563a4" },
  { "fixture.v1", "valid-record.json",
    "sha256:4d717e4db2e3df96f37036b8edddc8a341ee879fe885414a858610e4409dcb7f" },
  { "metadata-core.v1", "valid-document.json",
    "sha256:b5928884b3444d050a8d1388da89d1e1993aae8c6fd2903eee4118cd604fc8fc" },
  { "metadata-core.v1", "valid-funding.json",
    "sha256:c7041ed4af766124d3d9c0d7e2a9510b8cad967752914d3e15915a5a69eaac07" },
  { "metadata-core.v1", "valid-organization.json",
    "sha256:22a6f0856a49456bc6424bda92a5692b6c434668b44fefabe9dbd8604402a8ef" },
  { "metadata-core.v1", "valid-person.json",
    "sha256:d3e092d3dc5b6e322e4bea4a972bbaf13af7898a4def6c4a8038f7da8b8b8dbb" },
  { "profile-manifest.v1", "valid-fixture.json",
    "sha256:80aa5a1dd8783764e4cf3430a132f26a70c65c97179d701418ddd6d53fbbfc63" },
  { "report-envelope.v1", "valid-migration-report.json",
    "sha256:bfebba9b908e288534a00e402951db2809bc5f96a4050a71aaa9bbdb4561c4aa" },
  { "state-annotations.v1", "valid-comment-thread.json",
    "sha256:2cd60e5f8ae7ddb3d7b73f688f15d9a257da5c6a0b3921f498ad77dc8d078b55" },
  { "state-citations.v1", "valid-zotero.json",
    "sha256:a88ccbe3f66550784ec3d6f8a4c63bdca565ec4c426cb719ab1efe4da9e94459" },
  { "state-manifest.v1", "valid-minimal.json",
    "sha256:0ba2b9307100776f9741c2423313d6a6d728e7ed630f510a51047ee33c01aa3a" },
  { "state-metadata.v1", "valid-records-and-profiles.json",
    "sha256:1878edae2b0769a4b16b727d6b296a7c7674c4e78d43e952dc0f707f5642e7e7" },
  { "state-regions.v1", "valid-two-regions.json",
    "sha256:4f2b2b60b6dfd83e50b2c8fb5184425b12dafecd1addbee63a94c5623a770e1f" },
}

local function schema_id(name)
  if name == "fixture.v1" then return BASE .. "profiles/fixture.v1.json" end
  return BASE .. name .. ".json"
end

local cases = {}
for _, row in ipairs(BASELINE) do
  local name, file, want = row[1], row[2], row[3]
  cases[#cases + 1] = { name = "pre-existing " .. name .. "/" .. file .. " still validates unchanged", fn = function()
      local path = pandoc.path.join({ root, "schemas", "examples", name, file })
      local okread, inst = pcall(json.read, path)
      assert(okread, "pre-existing valid example is missing: " .. path)
      local got = "sha256:" .. sha.hex(canonical.encode(inst))
      assert(got == want, "pre-existing valid example content changed (" .. got .. ")")
      local schema = js.resolve(schema_id(name))
      assert(schema, "schema not registered: " .. schema_id(name))
      local v, errs = js.validate(schema, inst)
      assert(v, "pre-existing valid example no longer validates: "
        .. tostring(errs[1] and (errs[1].path .. " " .. errs[1].message)))
    end }
end
return cases
