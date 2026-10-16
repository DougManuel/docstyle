-- tests/vnext/conformance/tests/test-catalogue.lua
-- Metadata-binding spec acceptance criteria 2-12: drives every binding
-- fixture under tests/vnext/conformance/fixtures/metadata-binding/ through
-- lib/catalogue.lua, plus a few structural cases (reference classification
-- mirrors the schema descriptions, carrier constants, criterion coverage).
--
-- Fixture shape: { description, criteria = {n, ...}, operation, <inputs>,
-- expect, schemas? } (`schemas`: test-only schemas registered for that
-- fixture's run alone; see with_schemas). `operation` is one of
--   embed               catalogue.embed(model, {document})
--   at-rest             catalogue.validate_at_rest(model)
--   validate-embedded   catalogue.validate_embedded(catalogue, {envelopes})
--   reconcile           catalogue.reconcile(catalogue, model)
--   cold-recover        catalogue.cold_recover(package)
--   embed-then-cold-recover  embed(model), then cold_recover of a package
--                       carrying exactly that catalogue (the DOCX round trip)
--   path                catalogue.resolve_path(record, path) per case
--   normalize-contract  the WP3 normalizer's stated output (not executed
--                       here -- see the fixture description) must embed
-- expect.errors is the EXACT set of distinct error codes (so a fixture
-- cannot pass by failing for an unintended reason); expect.warnings, when
-- given, is the exact set of warning codes. Inputs are written as a base
-- document from bases/ plus a patch (see the loader below); bases are not
-- themselves fixtures. bases/pre-embed-catalogue.json doubles as the
-- criterion-3 expected embedded output.
local cat = require("lib.catalogue")
local json = require("lib.json")
local jsonpatch = require("lib.jsonpatch")
local js = require("lib.jsonschema")

local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local root = pandoc.path.join({ here, "..", "..", ".." })
local FIXDIR = pandoc.path.join({ here, "fixtures", "metadata-binding" })

local function read_fixture_file(rel) return json.read(pandoc.path.join({ FIXDIR, rel })) end

-- Fixtures are stored as named base documents (bases/) plus short RFC 6902
-- patches: every {"$base": "bases/<name>.json", "$patch": [...]} object is
-- expanded by lib/jsonpatch.lua before the fixture is used.
local fixtures, names = {}, {}
for _, f in ipairs(pandoc.system.list_directory(FIXDIR)) do
  local name = f:match("^(.+)%.json$")
  if name then
    fixtures[name] = jsonpatch.expand(read_fixture_file(f), read_fixture_file)
    names[#names + 1] = name
  end
end
table.sort(names)

-- ---------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------

local function deep_equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not deep_equal(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local function code_set(findings, level)
  local set, list = {}, {}
  for _, f in ipairs(findings or {}) do
    if f.level == level and not set[f.code] then set[f.code] = true; list[#list + 1] = f.code end
  end
  table.sort(list)
  return list
end

local function describe(findings)
  local out = {}
  for _, f in ipairs(findings or {}) do
    out[#out + 1] = f.level .. ":" .. f.code .. "@" .. tostring(f.where) .. " (" .. tostring(f.message) .. ")"
  end
  return table.concat(out, "; ")
end

local function sorted_copy(list)
  local out = {}
  for i, v in ipairs(list or {}) do out[i] = v end
  table.sort(out)
  return out
end

local function assert_codes(res, expect)
  if expect.errors then
    local got, want = code_set(res.findings, "error"), sorted_copy(expect.errors)
    assert(deep_equal(got, want), "error codes: want {" .. table.concat(want, ",") .. "} got {"
      .. table.concat(got, ",") .. "}: " .. describe(res.findings))
  end
  if expect.warnings then
    local got, want = code_set(res.findings, "warning"), sorted_copy(expect.warnings)
    assert(deep_equal(got, want), "warning codes: want {" .. table.concat(want, ",") .. "} got {"
      .. table.concat(got, ",") .. "}")
  end
  for _, w in ipairs(expect.where or {}) do
    local hit = false
    for _, f in ipairs(res.findings or {}) do if f.where == w then hit = true end end
    assert(hit, "no finding at " .. w .. ": " .. describe(res.findings))
  end
  if expect.ok ~= nil then
    assert(res.ok == expect.ok, "ok: want " .. tostring(expect.ok) .. " got " .. tostring(res.ok)
      .. ": " .. describe(res.findings))
  end
  if expect.stage then
    assert(res.stage == expect.stage, "stage: want " .. expect.stage .. " got " .. tostring(res.stage))
  end
end

-- "records/contrib-1/contact" -> value or nil
local function at(tbl, path)
  local node = tbl
  for seg in path:gmatch("[^/]+") do
    if type(node) ~= "table" then return nil end
    node = node[seg]
  end
  return node
end

local function assert_paths(catalogue, expect)
  for _, p in ipairs(expect.absent or {}) do
    assert(at(catalogue, p) == nil, "expected " .. p .. " to be absent from the catalogue")
  end
  for _, p in ipairs(expect.present or {}) do
    assert(at(catalogue, p) ~= nil, "expected " .. p .. " to be present in the catalogue")
  end
  for view_id, want in pairs(expect.order or {}) do
    local v = catalogue.views[view_id]
    assert(v and v.sourceCollection, "no collection view " .. view_id)
    local got = cat.collection_order(catalogue.records, catalogue.document, v.sourceCollection)
    assert(deep_equal(got, want), view_id .. " order: want {" .. table.concat(want, ",")
      .. "} got {" .. table.concat(got, ",") .. "}")
  end
  if expect.sharedSource then
    local s = expect.sharedSource
    local a, b = catalogue.views[s.views[1]], catalogue.views[s.views[2]]
    assert(a and b and a.id ~= b.id, "expected two distinct view records")
    for _, v in ipairs({ a, b }) do
      assert(v.sourceRecord == s.sourceRecord and v.path == s.path,
        "view " .. v.id .. " does not share sourceRecord/path")
    end
  end
end

-- ---------------------------------------------------------------------
-- per-operation drivers
-- ---------------------------------------------------------------------

local drivers = {}

drivers["embed"] = function(f)
  local res = cat.embed(f.model, { document = f.document })
  assert_codes(res, f.expect)
  if res.ok then
    local v = js.validate(js.resolve("https://dougmanuel.github.io/docstyle/schemas/catalogue.v1.json"), res.catalogue)
    assert(v, "embedded output does not validate against catalogue.v1")
    assert_paths(res.catalogue, f.expect)
    if f.expect.catalogue then
      local want = jsonpatch.expand(read_fixture_file(f.expect.catalogue), read_fixture_file)
      assert(deep_equal(res.catalogue, want), "embedded output differs from " .. f.expect.catalogue)
    end
  else
    -- Fail closed: a failed embed never hands back a catalogue.
    assert(res.catalogue == nil, "failed embedding returned a catalogue")
  end
end

drivers["at-rest"] = function(f)
  -- At rest, the model must also still be schema-valid v1 data (the
  -- noncanonical values are warnings, not schema failures).
  local v = js.validate(js.resolve("https://dougmanuel.github.io/docstyle/schemas/document-model.v1.json"), f.model)
  assert(v, "at-rest fixture model is not document-model.v1 valid")
  assert_codes(cat.validate_at_rest(f.model), f.expect)
end

drivers["validate-embedded"] = function(f)
  local c = f.catalogue
  local envelopes = f.envelopesFrom and cat.envelopes_of(fixtures[f.envelopesFrom].model) or nil
  local local_ids = f.localIdsFrom and cat.local_ids_of(fixtures[f.localIdsFrom].model) or nil
  assert_codes(cat.validate_embedded(c, { envelopes = envelopes, local_ids = local_ids }), f.expect)
end

drivers["reconcile"] = function(f)
  local c = f.catalogue
  local res = cat.reconcile(c, f.model)
  assert(res.ok == f.expect.ok, "reconcile ok: want " .. tostring(f.expect.ok) .. " got " .. tostring(res.ok))
  for key, want in pairs(f.expect.outcomes or {}) do
    local e = res.entries[key]
    assert(e and e.outcome == want, key .. ": want " .. want .. " got " .. tostring(e and e.outcome))
  end
  -- Why the comparison must be against the projection: the raw local
  -- record (with its restricted contact) hashes differently from the
  -- embedded, pruned record, while the projected record matches it.
  for _, id in ipairs(f.expect.rawDiffers or {}) do
    local raw = cat.entry_hash(f.model.registries.metadata[id])
    local embedded = cat.entry_hash(c.records[id])
    assert(raw ~= embedded, "raw local " .. id .. " unexpectedly matches the embedded record")
    assert(res.entries["records/" .. id].outcome == "agree", "projected " .. id .. " must agree")
  end
end

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

-- The round trip a DOCX makes (#57 re-review): embed the model, carry the
-- embedded catalogue as the package would, then cold-recover it with
-- nothing else. Output that embedding accepts must recover.
drivers["embed-then-cold-recover"] = function(f)
  local emb = cat.embed(f.model)
  assert(emb.ok, "embedding must succeed first: " .. describe(emb.findings))
  local env, envelopes = cat.envelopes_of(f.model), {}
  for _, id in ipairs(sorted_keys(env)) do
    local e = env[id]
    envelopes[#envelopes + 1] = { v = 4, id = id, kind = e.kind, policy = e.policy,
      role = e.role, parent = e.parent, hash = "sha256:" .. ("0"):rep(64) }
  end
  local res = cat.cold_recover({
    envelopes = envelopes,
    relationships = { [cat.CARRIER.source] = {
      { type = cat.CARRIER.relationshipType, target = "../docstyle/catalogue.json" } } },
    parts = { [cat.CARRIER.part] = { contentType = cat.CARRIER.contentType, json = emb.catalogue } },
  })
  assert_codes(res, f.expect)
end

drivers["cold-recover"] = function(f)
  local res = cat.cold_recover(f.package)
  assert_codes(res, f.expect)
  if f.expect.degraded ~= nil then
    assert(res.degraded == f.expect.degraded, "degraded: want " .. tostring(f.expect.degraded))
    if res.degraded then
      -- WP1 behaviour: identity and policy known from the envelopes alone.
      for _, e in ipairs(f.package.envelopes) do
        local r = res.regions[e.id]
        assert(r and r.envelope.policy == e.policy and r.object == nil, "region " .. e.id .. " not degraded to identity/policy")
      end
    end
  end
  for id, want in pairs(f.expect.objects or {}) do
    assert(res.regions[id] and deep_equal(res.regions[id].object.semantics, want),
      "semantics of " .. id .. " not recovered through objects")
  end
  for id, want in pairs(f.expect.assets or {}) do
    local a = res.assets[id]
    assert(a and a.path == want.path and a.mediaType == want.mediaType and a.hash == want.hash,
      "asset identity of " .. id .. " not recovered")
  end
  for id, want in pairs(f.expect.views or {}) do
    local v = res.regions[id] and res.regions[id].view
    assert(v and v.sourceRecord == want.sourceRecord and v.path == want.path,
      "region " .. id .. " not bound to its view")
  end
end

drivers["path"] = function(f)
  for i, c in ipairs(f.cases) do
    local okpath, code = cat.resolve_path(c.record, c.path)
    assert(okpath == c.ok, "case " .. i .. " ('" .. c.path .. "'): want ok=" .. tostring(c.ok))
    if not c.ok then assert(code == c.code, "case " .. i .. ": want " .. c.code .. " got " .. tostring(code)) end
  end
end

drivers["normalize-contract"] = function(f)
  local m = f.normalized
  local res = cat.embed(m)
  assert_codes(res, f.expect)
  if f.expect.envelope then
    local e = f.expect.envelope
    local env = cat.envelopes_of(m)[e.id]
    assert(env and env.kind == e.kind and env.role == e.role and env.policy == e.policy,
      "normalized envelope is not " .. e.kind .. "/" .. e.role .. "/" .. e.policy)
    local doc = m.registries.metadata["rec-document"]
    assert(type(doc.abstract) == "table" and doc.abstract.region == e.id, "document record is not region form")
  end
  if f.expect.abstractText then
    local found
    for _, n in ipairs(m.content) do
      if n.id == "abstract" then found = n.children and n.children[1] and n.children[1].text end
    end
    assert(found == f.expect.abstractText, "abstract text does not live in the #abstract section")
    -- and nowhere in the embedded catalogue
    assert(not json.encode(res.catalogue):find(f.expect.abstractText, 1, true),
      "abstract text was duplicated into the catalogue")
  end
  for id, fields in pairs(f.expect.records or {}) do
    for k, v in pairs(fields) do
      assert(m.registries.metadata[id][k] == v, "normalized " .. id .. "." .. k .. " ~= " .. tostring(v))
    end
  end
  if res.catalogue then assert_paths(res.catalogue, f.expect) end
end

-- ---------------------------------------------------------------------
-- cases
-- ---------------------------------------------------------------------

local cases = {}

-- A fixture may register test-only schemas for its own run: `schemas` is an
-- array of schema documents, each under an $id no registered schema uses.
-- They are unregistered afterwards, so they never reach another case.
local function with_schemas(list, fn)
  for _, s in ipairs(list or {}) do
    assert(js.resolve(s["$id"]) == nil, "fixture schema " .. tostring(s["$id"]) .. " would shadow a registered schema")
  end
  for _, s in ipairs(list or {}) do js.register(s["$id"], s) end
  local okrun, err = pcall(fn)
  for _, s in ipairs(list or {}) do js.register(s["$id"], nil) end
  if not okrun then error(err, 0) end
end

for _, name in ipairs(names) do
  local f = fixtures[name]
  cases[#cases + 1] = { name = "fixture " .. name, fn = function()
      local drive = drivers[f.operation]
      assert(drive, "unknown fixture operation " .. tostring(f.operation))
      with_schemas(f.schemas, function() drive(f) end)
    end }
end

cases[#cases + 1] = { name = "every fixture declares its description, criteria and operation", fn = function()
    assert(#names > 0, "no metadata-binding fixtures found")
    for _, name in ipairs(names) do
      local f = fixtures[name]
      assert(type(f.description) == "string" and f.criteria ~= nil and f.expect ~= nil,
        name .. " lacks description/criteria/expect")
    end
  end }

cases[#cases + 1] = { name = "every executable acceptance criterion (2-8, 10-12) has fixture evidence", fn = function()
    -- Criterion 1 is test-schema-additivity.lua plus the example loop;
    -- criterion 9 is a review-time scope check with no executable form.
    local seen = {}
    for _, name in ipairs(names) do
      for _, c in ipairs(fixtures[name].criteria) do seen[math.tointeger(c)] = true end
    end
    for _, c in ipairs({ 2, 3, 4, 5, 6, 7, 8, 10, 11, 12 }) do
      assert(seen[c], "no fixture evidence for acceptance criterion " .. c)
    end
  end }

cases[#cases + 1] = { name = "reference classification matches the schema descriptions", fn = function()
    -- Spec section 6: "Reference fields are classified once, in the schema
    -- descriptions". lib/catalogue.lua's table must agree with that text.
    local mc = js.resolve("https://dougmanuel.github.io/docstyle/schemas/metadata-core.v1.json")
    for record_type, refs in pairs(cat.REFERENCES) do
      local props = mc["$defs"][record_type].properties
      for _, ref in ipairs(refs) do
        local d = props[ref.field] and props[ref.field].description or ""
        local want = ref.class == "prunable" and "^Prunable reference" or "^Closure%-required"
        assert(d:match(want), record_type .. "." .. ref.field .. " description does not classify it as " .. ref.class)
        assert(d:find(ref.target, 1, true), record_type .. "." .. ref.field .. " description does not name target " .. ref.target)
      end
    end
    local view = mc["$defs"]["metadata-view"].oneOf
    assert(view[1].properties.sourceRecord.description:match("^Closure%-required"), "sourceRecord unclassified")
    assert(view[2].properties.sourceCollection.description:match("^Closure%-required"), "sourceCollection unclassified")
    local dm = js.resolve("https://dougmanuel.github.io/docstyle/schemas/document-model.v1.json")
    assert(dm["$defs"]["figure-semantics"].properties.asset.description:match("^Closure%-required"), "asset unclassified")
    assert(dm["$defs"].credit.description:find("prunable", 1, true), "credit unclassified")
    assert(dm["$defs"].provenance.description:find("prunable", 1, true), "provenance unclassified")
  end }

cases[#cases + 1] = { name = "collection ties break by record id however many members tie", fn = function()
    -- table.sort is not stable, so a two-member tie can come out in id
    -- order by luck; many tied members (plus distinct keys around them)
    -- make the explicit tie-break the only thing that yields id order.
    local records, want = {}, {}
    local ids = { "c-09", "c-03", "c-11", "c-01", "c-07", "c-05", "c-12", "c-02", "c-10", "c-04", "c-08", "c-06" }
    for _, id in ipairs(ids) do
      records[id] = { id = id, recordType = "contribution", document = "d", group = "same" }
    end
    records["c-00"] = { id = "c-00", recordType = "contribution", document = "d", group = "aaa" }
    records["c-99"] = { id = "c-99", recordType = "contribution", document = "d", group = "zzz" }
    records["c-xx"] = { id = "c-xx", recordType = "contribution", document = "other", group = "aaa" }
    want[1] = "c-00"
    local sorted = {}
    for i, id in ipairs(ids) do sorted[i] = id end
    table.sort(sorted)
    for _, id in ipairs(sorted) do want[#want + 1] = id end
    want[#want + 1] = "c-99"
    local got = cat.collection_order(records, "d", { recordType = "contribution", orderBy = "group" })
    assert(deep_equal(got, want), "got {" .. table.concat(got, ",") .. "}")
  end }

cases[#cases + 1] = { name = "audit correction note for the table-policy row is in place, history unrewritten", fn = function()
    -- Criterion 6 / schema-change manifest: dev/vnext/wp1-legacy-coverage.md
    -- gains a correction note; the original inventory row stays as written.
    local fh = assert(io.open(pandoc.path.join({ root, "dev", "vnext", "wp1-legacy-coverage.md" }), "rb"))
    local text = fh:read("a"); fh:close()
    assert(text:find("| Field-code payload type `table` | `key-map.json` | mapped | field-envelope.v4 kind `table`, policy `authored-preserve` | |", 1, true),
      "the original table row was rewritten instead of annotated")
    local notes = text:match("## Correction notes(.-)\n## ")
    assert(notes, "no Correction notes section")
    assert(notes:find("Table-policy row", 1, true) and notes:find("`policy: \"structural\"`", 1, true)
      and notes:find("generated-replace", 1, true), "table-policy correction note incomplete")
  end }

cases[#cases + 1] = { name = "valid catalogue.v1 schema examples are also semantically closed", fn = function()
    -- Includes the specification's own section 6 example verbatim
    -- (valid-spec-example.json): the contracts must accept the spec's
    -- illustration. No envelopes are available for a bare example, so the
    -- node-reference checks are skipped with a warning, never passed silently.
    local dir = pandoc.path.join({ root, "schemas", "examples", "catalogue.v1" })
    local n = 0
    for _, f in ipairs(pandoc.system.list_directory(dir)) do
      if f:match("^valid.*%.json$") then
        n = n + 1
        local res = cat.validate_embedded(json.read(pandoc.path.join({ dir, f })))
        assert(res.ok, f .. ": " .. describe(res.findings))
        assert(deep_equal(code_set(res.findings, "warning"), { "envelopes-unavailable" }),
          f .. ": expected exactly the envelopes-unavailable warning")
      end
    end
    assert(n >= 3, "expected the valid catalogue examples to be present")
  end }

cases[#cases + 1] = { name = "DOCX carrier constants match the specification", fn = function()
    assert(cat.CARRIER.part == "/docstyle/catalogue.json")
    assert(cat.CARRIER.contentType == "application/vnd.docstyle.catalogue+json")
    assert(cat.CARRIER.relationshipType == "https://dougmanuel.github.io/docstyle/relationships/catalogue")
    assert(cat.CARRIER.source == "/word/document.xml")
  end }

cases[#cases + 1] = { name = "embedding order: a malformed value is rejected before projection, never pruned", fn = function()
    -- Criterion 12, stated directly: the malformed record-form credit has a
    -- restricted target, so a projection-first implementation would prune
    -- it and embed successfully. Step 1 must stop it.
    local f = fixtures["embed-order-malformed-credit"]
    local proj = cat.public_projection(f.model)
    assert(not proj.ok and proj.stage == "local" and proj.catalogue == nil,
      "malformed credit reached projection")
    local good = cat.embed(fixtures["embed-order-canonical-credit"].model)
    assert(good.ok and good.catalogue.assets["asset-flow"].credit == nil
      and good.catalogue.assets["asset-flow"].path == "media/flow.png",
      "canonical restricted credit was not pruned as a whole property")
  end }

cases[#cases + 1] = { name = "embedding does not mutate the local model", fn = function()
    -- Pruning acts on the projected copy only: records (contact), objects
    -- (semantics.provenance) and assets (credit) must all be deep copies.
    for _, name in ipairs({ "pre-embed-local", "prune-provenance", "embed-order-canonical-credit" }) do
      local f = fixtures[name]
      local before = json.encode(f.model)
      local res = cat.embed(f.model)
      assert(res.ok, name .. ": " .. describe(res.findings))
      assert(json.encode(f.model) == before, name .. ": embed() mutated local state while pruning")
    end
    assert(fixtures["pre-embed-local"].model.registries.metadata["contrib-1"].contact == "rec-contact-1")
    assert(fixtures["embed-order-canonical-credit"].model.registries.assets["asset-flow"].credit.record == "rec-org-internal")
    local tbl = fixtures["prune-provenance"].model.content
    local found
    for _, n in ipairs(tbl) do if n.id == "tbl-outcomes" then found = n.semantics.provenance end end
    assert(found and found.record == "rec-org-internal", "local table provenance was pruned")
  end }

cases[#cases + 1] = { name = "string sort keys use UTF-8 byte order whatever the collation locale", fn = function()
    -- Lua's string `<` uses strcoll(). Under a UTF-8 collation locale
    -- (where available) "a" sorts before "B" and U+00E9 before "f"; byte
    -- order is the reverse for both. The result must not change.
    local records = {
      ["c-1"] = { id = "c-1", recordType = "contribution", document = "d", k = "a" },
      ["c-2"] = { id = "c-2", recordType = "contribution", document = "d", k = "B" },
      ["c-3"] = { id = "c-3", recordType = "contribution", document = "d", k = "\195\169" },
      ["c-4"] = { id = "c-4", recordType = "contribution", document = "d", k = "f" },
    }
    local want = { "c-2", "c-1", "c-4", "c-3" } -- "B" < "a" < "f" < U+00E9 by bytes
    local coll = { recordType = "contribution", orderBy = "k" }
    local previous = os.setlocale(nil, "collate")
    local tried = {}
    for _, loc in ipairs({ "C", "en_US.UTF-8", "en_US.utf8", "C.UTF-8", "fr_FR.UTF-8" }) do
      if os.setlocale(loc, "collate") then
        tried[#tried + 1] = loc
        local okorder, got = pcall(cat.collection_order, records, "d", coll)
        os.setlocale(previous, "collate")
        assert(okorder, got)
        assert(deep_equal(got, want), "under collate locale " .. loc .. ": got {" .. table.concat(got, ",") .. "}")
      end
    end
    os.setlocale(previous, "collate")
    assert(#tried > 0, "no collation locale could be set")
  end }

cases[#cases + 1] = { name = "pre-existing document-model example stays valid at rest but is not silently embeddable", fn = function()
    -- Additivity from the other side: the WP1 full-coverage example keeps
    -- validating (criterion 1), and the canonical contracts neither break
    -- it at rest nor wave it through embedding (its figure has no alt).
    local m = json.read(pandoc.path.join({ root, "schemas", "examples", "document-model.v1", "valid-full-coverage.json" }))
    local rest = cat.validate_at_rest(m)
    assert(rest.ok, "full-coverage example fails at rest: " .. describe(rest.findings))
    local res = cat.embed(m)
    assert(not res.ok, "full-coverage example embedded despite missing canonical figure semantics")
  end }

-- ---------------------------------------------------------------------
-- Wrong-typed fields: every record and view field a semantic check reads,
-- set to each JSON type it may not take, comes back from embed() and
-- validate_at_rest() as findings -- never as a thrown Lua error. At embed
-- time the schema finding stands alone: a record that fails its schema is
-- skipped by the semantic checks, since its schema error already fails
-- embedding. Reference fields come from cat.REFERENCES, so a newly
-- classified reference is covered without editing this table.
-- ---------------------------------------------------------------------

-- Wrong values by the shape the field must have. Containers are nonempty,
-- so an object and an array are never ambiguous.
local WRONG = {
  string = { 7, true, { k = "v" }, { "x" } },
  integer = { 1.5, "1", true, { k = "v" }, { 1 } },
  ["string-array"] = { 7, "x", true, { k = "v" }, { 7 } },
  object = { 7, "x", true, { "x" } },
  abstract = { 7, true, { "x" }, { region = 7 }, { text = "x" } },
}

-- The local model plus a public funding record, so funding.funder is
-- exercised too.
local function wrong_type_base()
  local m = jsonpatch.deep_copy(fixtures["pre-embed-local"].model)
  m.registries.metadata["rec-funding-1"] = { id = "rec-funding-1", recordType = "funding",
    schemaVersion = 1, funder = "rec-org-uottawa" }
  return m
end

local function ids_where(model, pred)
  local out = {}
  for id, r in pairs(model.registries.metadata) do if pred(r) then out[#out + 1] = id end end
  table.sort(out)
  return out
end

local function wrong_type_targets(m)
  local function of_type(t) return ids_where(m, function(r) return r.recordType == t end) end
  local targets = {}
  local types = {}
  for t in pairs(cat.REFERENCES) do types[#types + 1] = t end
  table.sort(types)
  for _, t in ipairs(types) do
    for _, ref in ipairs(cat.REFERENCES[t]) do
      targets[#targets + 1] = { label = t .. "." .. ref.field, ids = of_type(t), field = ref.field,
        shape = ref.many and "string-array" or "string" }
    end
  end
  local record_views = ids_where(m, function(r) return r.sourceRecord ~= nil end)
  local collection_views = ids_where(m, function(r) return r.sourceCollection ~= nil end)
  local every_record = ids_where(m, function() return true end)
  for _, t in ipairs({
    { label = "contribution.position", ids = of_type("contribution"), field = "position", shape = "integer" },
    { label = "document.abstract", ids = of_type("document"), field = "abstract", shape = "abstract" },
    { label = "metadata-view.sourceRecord", ids = record_views, field = "sourceRecord", shape = "string" },
    { label = "metadata-view.path", ids = record_views, field = "path", shape = "string" },
    { label = "metadata-view.sourceCollection", ids = collection_views, field = "sourceCollection", shape = "object" },
    { label = "metadata-view.sourceCollection.recordType", ids = collection_views,
      field = "sourceCollection.recordType", shape = "string" },
    { label = "metadata-view.sourceCollection.orderBy", ids = collection_views,
      field = "sourceCollection.orderBy", shape = "string" },
    { label = "record.id", ids = every_record, field = "id", shape = "string" },
    { label = "record.recordType", ids = every_record, field = "recordType", shape = "string" },
    { label = "record.privacy", ids = every_record, field = "privacy", shape = "string" },
    { label = "record.profile", ids = every_record, field = "profile", shape = "string" },
  }) do targets[#targets + 1] = t end
  return targets
end

local function set_field(record, field, value)
  local segs = {}
  for seg in field:gmatch("[^.]+") do segs[#segs + 1] = seg end
  local node = record
  for i = 1, #segs - 1 do node = node[segs[i]] end
  node[segs[#segs]] = jsonpatch.deep_copy(value)
end

-- The schema layer's finding for the substituted records: record-schema at
-- one of their ids, or model-schema for a field document-model.v1 itself
-- constrains (id, recordType, privacy, profile).
local function schema_finding(res, ids)
  for _, f in ipairs(res.findings or {}) do
    if f.code == "model-schema" then return f end
    if f.code == "record-schema" then
      for _, id in ipairs(ids) do if f.where == id then return f end end
    end
  end
  return nil
end

cases[#cases + 1] = { name = "wrong-typed fields: the unmodified base embeds cleanly", fn = function()
    local res = cat.embed(wrong_type_base())
    assert(res.ok, describe(res.findings))
    for _, t in ipairs(wrong_type_targets(wrong_type_base())) do
      assert(#t.ids > 0, "no record in the base exercises " .. t.label)
    end
  end }

for _, t in ipairs(wrong_type_targets(wrong_type_base())) do
  cases[#cases + 1] = { name = "wrong-typed " .. t.label .. " returns findings, never throws", fn = function()
      local problems = {}
      local function problem(msg) problems[#problems + 1] = msg end
      for _, value in ipairs(WRONG[t.shape]) do
        -- "one": a single record carries the wrong value. "every": every
        -- record the target covers does, and the two contributions share a
        -- position, so position uniqueness reads the wrong values as well.
        for _, every in ipairs({ false, true }) do
          local m = wrong_type_base()
          local changed = every and t.ids or { t.ids[1] }
          for _, id in ipairs(changed) do set_field(m.registries.metadata[id], t.field, value) end
          if every and t.field ~= "position" then
            m.registries.metadata["contrib-2"].position = m.registries.metadata["contrib-1"].position
          end
          local label = t.label .. " = " .. json.encode(value) .. (every and " on every record" or "")

          local okcall, res = pcall(cat.embed, m)
          if not okcall then
            problem(label .. ": embed() threw: " .. tostring(res))
          elseif type(res) ~= "table" or type(res.findings) ~= "table" then
            problem(label .. ": embed() returned no findings")
          else
            if res.ok ~= false or res.catalogue ~= nil then problem(label .. ": embedded") end
            local f = schema_finding(res, changed)
            if not (f and f.level == "error") then
              problem(label .. ": embed() has no schema error: " .. describe(res.findings))
            end
            if not every and #code_set(res.findings, "error") ~= 1 then
              problem(label .. ": semantic checks ran on the schema-invalid record: " .. describe(res.findings))
            end
          end

          okcall, res = pcall(cat.validate_at_rest, m)
          if not okcall then
            problem(label .. ": validate_at_rest() threw: " .. tostring(res))
          elseif type(res) ~= "table" or type(res.findings) ~= "table" then
            problem(label .. ": validate_at_rest() returned no findings")
          else
            local f = schema_finding(res, changed)
            if not f then
              problem(label .. ": validate_at_rest() has no schema finding: " .. describe(res.findings))
            elseif not every and f.code == "record-schema" and #code_set(res.findings, "error") > 0 then
              problem(label .. ": unexpected error at rest: " .. describe(res.findings))
            end
          end
        end
      end
      assert(#problems == 0, #problems .. " problem(s): " .. table.concat(problems, " | "))
    end }
end

cases[#cases + 1] = { name = "cold import: profile-typed records with wrong-typed core-named fields return findings, never throw", fn = function()
    -- The catalogue's profile-record branch admits any shape, so the
    -- cold-import validator meets these values without a core schema
    -- check in front of them. Two such records share a position, so
    -- position uniqueness reads them too.
    local envelopes = cat.envelopes_of(fixtures["pre-embed-local"].model)
    for _, value in ipairs(WRONG.string) do
      local c = jsonpatch.expand(read_fixture_file("bases/pre-embed-catalogue.json"), read_fixture_file)
      for _, id in ipairs({ "rec-px-1", "rec-px-2" }) do
        c.records[id] = { id = id, recordType = "contribution", schemaVersion = 1, profile = "docstyle:absent",
          document = jsonpatch.deep_copy(value), person = jsonpatch.deep_copy(value),
          affiliations = jsonpatch.deep_copy(value), position = 1 }
      end
      local okcall, res = pcall(cat.validate_embedded, c, { envelopes = envelopes })
      assert(okcall, json.encode(value) .. ": validate_embedded() threw: " .. tostring(res))
      assert(res.ok == false, json.encode(value) .. ": validated")
      assert(deep_equal(code_set(res.findings, "error"), { "profile-record-unavailable" }),
        json.encode(value) .. ": " .. describe(res.findings))
    end
  end }

return cases
