-- tests/vnext/conformance/lib/catalogue.lua
-- Semantic validator for the metadata-binding contracts (docs/superpowers/
-- specs/2026-08-14-docstyle-vnext-metadata-binding-design.md): canonical
-- semantics and credit, typed reference closure, terminal view authority,
-- projected path resolution, collection scope and ordering, whole-property
-- pruning, contribution-position uniqueness, and catalogue-vs-
-- public_projection(local state) reconciliation. It runs BESIDE the JSON
-- Schema check (schemas/catalogue.v1.json), which cannot express any of
-- these.
--
-- Entry points (all return plain tables; none raise on bad input):
--
--   validate_at_rest(model)            -> { ok, findings }
--   public_projection(model, opts)     -> { ok, stage, findings, catalogue }
--   validate_embedded(catalogue, opts) -> { ok, stage, findings }
--   embed(model, opts)                 -> { ok, stage, findings, catalogue }
--   reconcile(catalogue, model, opts)  -> { ok, findings, entries }
--   cold_recover(package)              -> { ok, degraded, findings, regions, objects, assets, views }
--   resolve_path(record, path)         -> ok, code
--   collection_order(records, document, sourceCollection) -> { id, ... }
--   envelopes_of(model)                -> { [id] = { kind, role, policy } }
--
-- `model` is a document-model.v1 instance: local state's content tree plus
-- registries. Metadata-view records live in registries.metadata beside the
-- authority records; the catalogue separates them into `views`.
-- opts.document names the catalogue document record (default: the single
-- document record in the model); opts.generator fills catalogue.generator.
--
-- Embedding is the spec's three ordered steps (section 6), and the order is
-- load-bearing -- projection removes the evidence some checks need, since a
-- pruned restricted target is indistinguishable from an absent one:
--   1. local validation, before projection (local_validate, mode "embed"):
--      schemas, canonical semantics/credit/provenance (including values
--      projection will prune), reference target types, prunable-target
--      classification (public / known restricted / absent -- absent
--      fails), collection selection (a restricted member fails);
--   2. projection (project): drop restricted records, remove the WHOLE
--      property of each prunable reference step 1 classified as known
--      restricted -- acting only on that classification, never on a value;
--   3. embedded validation (validate_embedded): catalogue.v1 schema, then
--      closure, view paths and collections against the PROJECTED records.
-- A step-1 error stops embedding: nothing is projected, so a malformed value
-- can never be pruned away unvalidated.
--
-- Findings: { level = "error" | "warning", code, stage, where, message }.
-- ok = no error-level finding. `stage` is "at-rest", "local", "embedded" or
-- "carrier". Codes are stable identifiers the conformance fixtures assert
-- on (tests/vnext/conformance/fixtures/metadata-binding/).
--
-- At rest (validate_at_rest) the canonical-form checks are WARNINGS: a
-- noncanonical abstract string, legacy semantics or credit value, or legacy
-- whole-table policy is valid v1 data awaiting explicit normalization, never
-- silently discarded or reinterpreted. The same checks are ERRORS at embed
-- time, as is a registry record that is not a full metadata-core.v1
-- record. Contribution-position uniqueness is a contract, not a
-- normalization, so it is an error in both modes.

local js = require("lib.jsonschema")
local canonical = require("lib.canonical")
local sha = require("lib.sha256")
local reconcile_rules = require("lib.reconcile")
local profile = require("lib.profile")

local M = {}

local BASE = "https://dougmanuel.github.io/docstyle/schemas/"
local MC = BASE .. "metadata-core.v1.json"
local DM = BASE .. "document-model.v1.json"
local CATALOGUE = BASE .. "catalogue.v1.json"
local ENVELOPE = BASE .. "field-envelope.v4.json"
local MANIFEST = BASE .. "profile-manifest.v1.json"

-- DOCX carrier (spec section 6). The OPC reading/writing itself is WP2/WP4;
-- cold_recover() below consumes an already-read package description.
M.CARRIER = {
  part = "/docstyle/catalogue.json",
  contentType = "application/vnd.docstyle.catalogue+json",
  relationshipType = "https://dougmanuel.github.io/docstyle/relationships/catalogue",
  source = "/word/document.xml",
}

-- Record types the catalogue may carry (catalogue.v1 $defs/public-record),
-- plus metadata-view, which it carries separately in `views`.
local CORE_TYPES = {
  document = true, person = true, organization = true, funding = true,
  contribution = true, contact = true, ["metadata-view"] = true,
}

-- Collection member types must be registered AND document-scoped (carry a
-- `document` field naming their document). In core v1 only contribution is.
local DOCUMENT_SCOPED = { contribution = true }

-- Reference classification, stated once (spec section 6) and mirrored in
-- the schema descriptions; tests/test-catalogue.lua checks that each row
-- here matches the wording of the corresponding schema description.
-- View sources (sourceRecord, sourceCollection) and the semantics/asset
-- references (asset, provenance, credit, caption, notes) have their own
-- resolution scopes and are handled by check_view / check_semantics /
-- check_asset below.
-- person.affiliations and funding.funder are not in the spec's section 6
-- list; they are classified closure-required here under its governing
-- rule ("Embedding must fail closed, never ship a dangling id"), pending
-- spec review.
M.REFERENCES = {
  person = {
    { field = "affiliations", class = "closure-required", target = "organization", many = true },
  },
  funding = {
    { field = "funder", class = "closure-required", target = "organization" },
  },
  contribution = {
    { field = "document", class = "closure-required", target = "document" },
    { field = "person", class = "closure-required", target = "person" },
    { field = "affiliations", class = "closure-required", target = "organization", many = true },
    { field = "contact", class = "prunable", target = "contact" },
  },
}

local NODE_CONTENT_TYPES = { caption = true, paragraph = true, span = true, heading = true }

-- ---------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------

local function has_string_key(v)
  if type(v) ~= "table" then return false end
  for k in pairs(v) do if type(k) == "string" then return true end end
  return false
end

local function is_object(v)
  return type(v) == "table" and (next(v) == nil or has_string_key(v))
end

local function is_public(r)
  -- WP1 privacy rule: a missing privacy field means public for metadata
  -- records. contact.privacy is schema-required, so this default can never
  -- publish an email.
  return r.privacy ~= "restricted"
end

local function deep_copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = deep_copy(x) end
  return setmetatable(out, getmetatable(v))
end

local function sorted_keys(t)
  local ks = {}
  for k in pairs(t or {}) do ks[#ks + 1] = k end
  table.sort(ks)
  return ks
end

-- Byte-wise string order. Lua's `<` on strings uses strcoll(), which is
-- locale-dependent; the spec fixes UTF-8 byte order (= code point order).
local function bytes_lt(a, b)
  local n = math.min(#a, #b)
  for i = 1, n do
    local x, y = a:byte(i), b:byte(i)
    if x ~= y then return x < y end
  end
  return #a < #b
end

local function first_error(errs)
  local e = errs and errs[1]
  return e and ((e.path ~= "" and e.path or "/") .. " " .. e.message) or "validation failed"
end

local function schema_check(ref, value)
  local okflag, errs = js.validate({ ["$ref"] = ref }, value)
  return okflag, first_error(errs)
end

local function new_findings()
  local F = { list = {} }
  function F.add(level, code, stage, where, message)
    F.list[#F.list + 1] = { level = level, code = code, stage = stage,
      where = where, message = message }
  end
  function F.ok()
    for _, f in ipairs(F.list) do if f.level == "error" then return false end end
    return true
  end
  return F
end

local function preorder(content, fn, parent)
  for _, n in ipairs(content or {}) do
    fn(n, parent)
    preorder(n.children, fn, n)
  end
end

--- Envelope map derived from a model's content tree: every node's id is its
--- field-envelope id (WP1: envelope id = node id), with the envelope's kind,
--- role, policy and parent. Used as the resolution scope for node-id
--- references and for the view/region identity checks.
function M.envelopes_of(model)
  local env = {}
  preorder(model and model.content, function(n, parent)
    env[n.id] = { kind = n.type, role = n.role, policy = n.policy, parent = parent and parent.id }
  end)
  return env
end

-- ---------------------------------------------------------------------
-- Path resolution (spec section 6, "For sourceRecord ...")
-- ---------------------------------------------------------------------

--- Resolves a dotted `path` against `record`. Empty path = whole record.
--- Segments must be nonempty object properties that exist -- existence is
--- independent of value truthiness (false, null, 0 and "" all exist). Array
--- indexing and wildcards are unsupported. Returns ok, code.
function M.resolve_path(record, path)
  if path == "" then return true end
  if path:sub(1, 1) == "." or path:sub(-1) == "." or path:find("..", 1, true) then
    return false, "view-path-malformed"
  end
  local node = record
  for seg in path:gmatch("[^.]+") do
    if seg == "*" or seg:find("[%*%[%]]") then return false, "view-path-unsupported" end
    if type(node) == "table" and next(node) ~= nil and not has_string_key(node) then
      return false, "view-path-unsupported" -- an array: indexing is not a path step
    end
    if not is_object(node) or node[seg] == nil then return false, "view-path-unresolved" end
    node = node[seg]
  end
  return true
end

-- ---------------------------------------------------------------------
-- Collections (spec section 6, "Collections select records ...")
-- ---------------------------------------------------------------------

local function select_members(records, document, coll)
  local members = {}
  for _, id in ipairs(sorted_keys(records)) do
    local r = records[id]
    if r.recordType == coll.recordType and r.document == document then
      members[#members + 1] = r
    end
  end
  return members
end

-- Returns nil on success, or an error code for the sort-key contract.
local function sort_key_problem(members, key)
  local kind
  for _, r in ipairs(members) do
    local v = r[key]
    if v == nil then return "collection-sort-key-missing" end
    local t
    if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then t = "number"
    elseif type(v) == "string" then t = "string"
    else return "collection-sort-key-type" end
    if kind and kind ~= t then return "collection-sort-key-mixed" end
    kind = t
  end
  return nil
end

--- Ordered member ids of a collection: ascending by orderBy (numbers
--- numerically, strings by UTF-8 byte order), ties broken by record id.
--- Assumes the sort-key contract already holds (validated beforehand).
function M.collection_order(records, document, coll)
  local members = select_members(records, document, coll)
  local key = coll.orderBy
  table.sort(members, function(a, b)
    local x, y = a[key], b[key]
    if x ~= y then
      if type(x) == "string" then return bytes_lt(x, y) end
      return x < y
    end
    return bytes_lt(a.id, b.id)
  end)
  local ids = {}
  for i, r in ipairs(members) do ids[i] = r.id end
  return ids
end

-- Core types plus every recordType an ACTIVE profile's manifest registers.
-- `manifests` holds only manifests that validated (active_manifests below).
local function registered_types(manifests)
  local set = {}
  for k in pairs(CORE_TYPES) do set[k] = true end
  for _, manifest in pairs(manifests or {}) do
    -- A manifest reaching here has validated, but a nil recordTypes (a
    -- bypassed check) must mean "registers nothing", never a crash.
    for _, t in ipairs(manifest.recordTypes or {}) do set[t] = true end
  end
  return set
end

-- registries.profiles holds the profile manifests active in the document
-- (WP1 spec, "Registries"), keyed by profile id. Only an entry that is a
-- valid profile-manifest.v1 manifest keyed by its own id registers
-- anything; any other entry is an error, never a silent registration.
local function active_manifests(F, stage, profiles)
  local active = {}
  for _, id in ipairs(sorted_keys(profiles)) do
    local manifest = profiles[id]
    local okm, why = schema_check(MANIFEST, manifest)
    if not okm then
      F.add("error", "profile-manifest-invalid", stage, "profiles/" .. id,
        "active profile entry is not a profile-manifest.v1 manifest: " .. why)
    elseif manifest.id ~= id then
      F.add("error", "container-key-mismatch", stage, "profiles/" .. id,
        "key does not match the manifest id '" .. tostring(manifest.id) .. "'")
    else
      active[id] = manifest
    end
  end
  return active
end

-- A profile-typed record: validated against its profile's own schema
-- (lib/profile.lua's derived schema id). `manifests` is the active set at
-- the local stage; nil at the embedded stage, where the catalogue carries
-- no manifests and only availability of the profile schema can be checked.
local function check_profile_record(F, stage, r, manifests)
  local p = r.profile
  if manifests then
    local manifest = manifests[p]
    if manifest == nil then
      F.add("error", "profile-record-unavailable", stage, r.id,
        "profile '" .. p .. "' is not active in this document")
      return
    end
    local registers = false
    for _, t in ipairs(manifest.recordTypes or {}) do if t == r.recordType then registers = true end end
    if not registers then
      F.add("error", "record-type-unregistered", stage, r.id,
        "profile '" .. p .. "' does not register record type '" .. tostring(r.recordType) .. "'")
      return
    end
  end
  local schema_id = profile.schema_id(p)
  local schema = schema_id and js.resolve(schema_id)
  if schema == nil then
    F.add("error", "profile-record-unavailable", stage, r.id, "profile '" .. p .. "' schema is not available")
    return
  end
  local okrec, errs = js.validate(schema, r)
  if not okrec then
    F.add("error", "profile-record-invalid", stage, r.id,
      "fails its profile '" .. p .. "' schema: " .. first_error(errs))
  end
end

-- ---------------------------------------------------------------------
-- Shared binding checks. `ctx` fields:
--   stage      "local" | "embedded"
--   records    authority records by id (never views)
--   views      metadata-view records by id
--   assets     asset records by id
--   document   the catalogue document id
--   envelopes  { [id] = { kind, role, policy } } or nil (skip node refs)
--   profiles   active profile manifests by id (local) or nil
--   prunes     list of { container, id, property } (local stage only)
--   canon      "error" | "warning" -- level for canonical-form failures
-- ---------------------------------------------------------------------

-- Classifies a record reference. Returns "public" | "restricted" | nil,
-- after recording any absent/view/type error. `referrer_public` gates the
-- closure-required restricted-target error (only an embedded referrer
-- can leak a dangling id).
local function check_ref(ctx, F, where, target_id, expected_type, class, referrer_public)
  local target = ctx.records[target_id]
  if target == nil then
    if ctx.views[target_id] ~= nil then
      F.add("error", "reference-target-type", ctx.stage, where,
        "'" .. target_id .. "' is a metadata-view; references resolve to authority records, never views")
    else
      F.add("error", "reference-target-absent", ctx.stage, where,
        "reference target '" .. tostring(target_id) .. "' is absent")
    end
    return nil
  end
  if expected_type and target.recordType ~= expected_type then
    F.add("error", "reference-target-type", ctx.stage, where,
      "'" .. target_id .. "' is a " .. tostring(target.recordType) .. ", expected " .. expected_type)
    return nil
  end
  if is_public(target) then return "public" end
  if class == "closure-required" and referrer_public then
    F.add("error", "closure-target-restricted", ctx.stage, where,
      "public closure reaches restricted '" .. target_id .. "'; make the target public or remove the reference")
  end
  return "restricted"
end

-- catalogue.document: absent is its own code (a catalogue with no document
-- binds nothing); present but not a document is a type error.
local function check_catalogue_document(ctx, F, doc_id)
  if ctx.records[doc_id] == nil and ctx.views[doc_id] == nil then
    F.add("error", "catalogue-document-unresolved", ctx.stage, "catalogue.document",
      "catalogue document '" .. tostring(doc_id) .. "' is not a record")
    return
  end
  check_ref(ctx, F, "catalogue.document", doc_id, "document", "closure-required", true)
end

local function check_record_refs(ctx, F, r)
  for _, ref in ipairs(M.REFERENCES[r.recordType] or {}) do
    local v = r[ref.field]
    if v ~= nil then
      local targets = ref.many and v or { v }
      for _, target_id in ipairs(targets) do
        local where = r.id .. "." .. ref.field
        local cls = check_ref(ctx, F, where, target_id, ref.target, ref.class, is_public(r))
        if cls == "restricted" and ref.class == "prunable" and ctx.prunes and is_public(r) then
          ctx.prunes[#ctx.prunes + 1] = { container = "records", id = r.id, property = ref.field }
        end
      end
    end
  end
end

local function check_view(ctx, F, v, registered)
  local where = v.id
  if v.sourceRecord ~= nil then
    local src = v.sourceRecord
    if src == v.id then
      F.add("error", "view-self-reference", ctx.stage, where, "view names itself as its source")
    elseif ctx.views[src] ~= nil then
      F.add("error", "view-source-is-view", ctx.stage, where,
        "source '" .. src .. "' is a metadata-view; views are terminal and never sources of views")
    else
      local cls = check_ref(ctx, F, where .. ".sourceRecord", src, nil, "closure-required", is_public(v))
      -- Path validation runs against the PROJECTED record (embedded stage
      -- only), so a path removed by privacy pruning fails embedding.
      if cls and ctx.stage == "embedded" then
        local okpath, code = M.resolve_path(ctx.records[src], v.path or "")
        if not okpath then
          F.add("error", code, ctx.stage, where,
            "path '" .. tostring(v.path) .. "' does not resolve on '" .. src .. "'")
        end
      end
    end
  elseif v.sourceCollection ~= nil then
    local coll = v.sourceCollection
    if not registered[coll.recordType] then
      F.add("error", "collection-type-unregistered", ctx.stage, where,
        "collection record type '" .. tostring(coll.recordType) .. "' is not registered")
      return
    end
    if not DOCUMENT_SCOPED[coll.recordType] then
      F.add("error", "collection-type-not-document-scoped", ctx.stage, where,
        "collection record type '" .. coll.recordType .. "' is not document-scoped")
      return
    end
    -- Selection happens before privacy projection: a restricted member
    -- fails closure instead of silently disappearing.
    local members = select_members(ctx.records, ctx.document, coll)
    for _, m in ipairs(members) do
      if not is_public(m) and is_public(v) then
        F.add("error", "collection-member-restricted", ctx.stage, where,
          "selected member '" .. m.id .. "' is restricted")
      end
    end
    local problem = sort_key_problem(members, coll.orderBy)
    if problem then
      F.add("error", problem, ctx.stage, where,
        "orderBy '" .. coll.orderBy .. "' violates the sort-key contract")
    end
  end
end

-- The identity equation (spec section 2): a view's id IS its rendered
-- region's envelope id, and no generated region is left unbound. Read
-- conservatively ("WP4 ... must not invent unbound generated regions"): a
-- region needs a view when it has role metadata-value OR it is an
-- OUTERMOST generated-replace region (no generated-replace ancestor). The
-- descendants of a bound generated region (rows and cells of a generated
-- table) are covered by that region's view.
-- A restricted view bound to a rendered region is an error: the region
-- ships in the DOCX, so its binding cannot be withheld. A restricted view
-- with no rendered region is local-only state and never embeds.
local function outermost_generated(envelopes, e)
  if e.policy ~= "generated-replace" then return false end
  local seen, p = {}, e.parent
  while p and envelopes[p] and not seen[p] do
    seen[p] = true
    if envelopes[p].policy == "generated-replace" then return false end
    p = envelopes[p].parent
  end
  return true
end

local function check_view_regions(ctx, F)
  if not ctx.envelopes then return end
  for _, id in ipairs(sorted_keys(ctx.views)) do
    local e = ctx.envelopes[id]
    if not is_public(ctx.views[id]) then
      if e ~= nil then
        F.add("error", "view-restricted", ctx.stage, id,
          "a restricted view is bound to a rendered region; the region's binding must be public")
      end
    elseif e == nil then
      F.add("error", "view-region-missing", ctx.stage, id, "no rendered region carries this view's id")
    elseif e.role ~= "metadata-value" or e.policy ~= "generated-replace" then
      F.add("error", "view-region-mismatch", ctx.stage, id,
        "bound region must be role metadata-value, policy generated-replace")
    end
  end
  for _, id in ipairs(sorted_keys(ctx.envelopes)) do
    local e = ctx.envelopes[id]
    if ctx.views[id] == nil and (e.role == "metadata-value" or outermost_generated(ctx.envelopes, e)) then
      F.add("error", "unbound-generated-region", ctx.stage, id,
        e.role == "metadata-value" and "generated metadata-value region has no view record"
          or "outermost generated-replace region has no view record")
    end
  end
end

local function check_positions(ctx, F)
  local seen = {}
  for _, id in ipairs(sorted_keys(ctx.records)) do
    local r = ctx.records[id]
    if r.recordType == "contribution" and r.document ~= nil and r.position ~= nil then
      seen[r.document] = seen[r.document] or {}
      local prior = seen[r.document][r.position]
      if prior then
        F.add("error", "contribution-position-duplicate", ctx.stage, id,
          "position " .. tostring(math.tointeger(r.position) or r.position) .. " already used by '"
            .. prior .. "' for document '" .. r.document .. "'")
      else
        seen[r.document][r.position] = id
      end
    end
  end
end

local function check_abstract(ctx, F, doc)
  local a = doc.abstract
  if a == nil then return end
  if type(a) == "string" then
    F.add(ctx.canon, "abstract-noncanonical", ctx.stage, doc.id,
      "string abstract is authoring input, not canonical; normalize to {region: \"abstract\"}")
    return
  end
  if not ctx.envelopes or type(a) ~= "table" or a.region == nil then return end
  local e = ctx.envelopes[a.region]
  if e == nil then
    F.add("error", "abstract-region-unresolved", ctx.stage, doc.id,
      "abstract region '" .. tostring(a.region) .. "' names no envelope")
  elseif e.kind ~= "section" or e.role ~= "abstract" or e.policy ~= "authored-preserve" then
    F.add("error", "abstract-region-mismatch", ctx.stage, doc.id,
      "abstract region must be kind section, role abstract, policy authored-preserve")
  end
end

-- Record-reference form of credit/provenance: classify its target; a known
-- restricted target schedules removal of the whole property.
local function check_prunable_value(ctx, F, where, value, container, id, property, sub)
  if type(value) ~= "table" or value.record == nil then return end
  local cls = check_ref(ctx, F, where, value.record, nil, "prunable", true)
  if cls == "restricted" and ctx.prunes then
    ctx.prunes[#ctx.prunes + 1] = { container = container, id = id, property = property, sub = sub }
  end
end

-- Fail-closed guard for profile data. profile-manifest.v1 cannot yet
-- declare which profile fields are references, so every string value of a
-- public profile record and of every semantics.profiles extension value is
-- treated as a potential record id:
--   local stage (ctx.restricted_ids): a string equal to the id of a record
--     restricted in local state fails -- embedding it would ship a dangling
--     restricted id. A string naming a public record is fine (it ships).
--     Absent ids are NOT inferred from arbitrary strings.
--   embedded stage with the local model known (ctx.local_ids, as embed()
--     passes): a string equal to a local id that is missing from the
--     catalogue's records/views/assets fails -- defence in depth, since
--     step 1 already rejects restricted ids.
--   cold import (neither set): no local model exists, so there is nothing
--     to compare against and the check is skipped; the strings are opaque
--     profile data there.
local function walk_strings(v, path, fn)
  if type(v) == "string" then
    fn(v, path)
  elseif type(v) == "table" then
    if next(v) ~= nil and not has_string_key(v) then
      for i, x in ipairs(v) do walk_strings(x, path .. "/" .. (i - 1), fn) end
    else
      for _, k in ipairs(sorted_keys(v)) do walk_strings(v[k], path .. "/" .. k, fn) end
    end
  end
end

local function check_profile_values(ctx, F, where, value)
  if not (ctx.restricted_ids or ctx.local_ids) then return end
  walk_strings(value, where, function(str, path)
    if ctx.restricted_ids then
      if ctx.restricted_ids[str] then
        F.add("error", "profile-value-restricted-id", ctx.stage, path,
          "profile value names restricted record '" .. str .. "'; it would ship as a dangling id")
      end
    elseif ctx.local_ids[str] and ctx.records[str] == nil and ctx.views[str] == nil
        and ctx.assets[str] == nil then
      F.add("error", "profile-value-unresolved-id", ctx.stage, path,
        "profile value names local id '" .. str .. "', which the catalogue does not carry")
    end
  end)
end

--- Ids of every metadata record (including views) and asset in a model:
--- the local-id scope for the step-3 profile-value check.
function M.local_ids_of(model)
  local set = {}
  local reg = model and model.registries or {}
  for id in pairs(reg.metadata or {}) do set[id] = true end
  for id in pairs(reg.assets or {}) do set[id] = true end
  return set
end

local function check_profiles_ext(ctx, F, where, profiles_ext)
  for _, key in ipairs(sorted_keys(profiles_ext)) do
    local schema_id = profile.schema_id(key)
    local schema = schema_id and js.resolve(schema_id)
    local active = ctx.profiles == nil or ctx.profiles[key] ~= nil
    if not (schema and active) then
      F.add(ctx.canon, "semantics-profile-unavailable", ctx.stage, where,
        "profile extension '" .. key .. "' names no active, available profile")
    else
      local value = profiles_ext[key]
      check_profile_values(ctx, F, where .. "/" .. key, value)
      local items = (type(value) == "table" and next(value) ~= nil and not has_string_key(value)) and value or { value }
      for _, item in ipairs(items) do
        local okflag, errs = js.validate(schema, item)
        if not okflag then
          F.add(ctx.canon, "semantics-profile-invalid", ctx.stage, where,
            "profile extension '" .. key .. "' fails its profile schema: " .. first_error(errs))
        end
      end
    end
  end
end

-- Canonical semantics for one table or figure (node or embedded object).
local function check_semantics(ctx, F, id, node_type, sem)
  local where = id .. ".semantics"
  if sem == nil then
    if node_type == "figure" and ctx.canon == "error" then
      F.add("error", "figure-alt-missing", ctx.stage, where, "public figure has no semantics, hence no alt text")
    end
    return
  end
  local okflag, detail = schema_check(DM .. "#/$defs/" .. node_type .. "-semantics", sem)
  if not okflag then
    F.add(ctx.canon, "semantics-noncanonical", ctx.stage, where,
      "semantics is not canonical " .. node_type .. "-semantics (" .. detail .. "); normalize explicitly")
    return
  end
  if node_type == "figure" and sem.alt == nil and ctx.canon == "error" then
    F.add("error", "figure-alt-missing", ctx.stage, where, "public figure has no alt text")
  end
  if sem.profiles ~= nil then check_profiles_ext(ctx, F, where .. ".profiles", sem.profiles) end
  if ctx.canon ~= "error" then return end -- reference closure is an embed-time contract
  if ctx.envelopes then
    local refs = {}
    if sem.caption then refs[#refs + 1] = { "caption", sem.caption } end
    for _, n in ipairs(sem.notes or {}) do refs[#refs + 1] = { "notes", n } end
    for _, ref in ipairs(refs) do
      if ctx.envelopes[ref[2]] == nil then
        F.add("error", "semantics-node-ref-unresolved", ctx.stage, where .. "." .. ref[1],
          "node id '" .. ref[2] .. "' is not a field-envelope id in this document")
      end
    end
  end
  if node_type == "figure" and sem.asset ~= nil and ctx.assets[sem.asset] == nil then
    F.add("error", "reference-target-absent", ctx.stage, where .. ".asset",
      "asset '" .. sem.asset .. "' is not in the asset registry")
  end
  local key = node_type == "table" and "provenance" or "credit"
  check_prunable_value(ctx, F, where .. "." .. key, sem[key], "objects", id, "semantics", key)
end

local function check_asset(ctx, F, a)
  if a.credit == nil then return end
  local okflag, detail = schema_check(DM .. "#/$defs/credit", a.credit)
  if not okflag then
    F.add(ctx.canon, "credit-noncanonical", ctx.stage, a.id .. ".credit",
      "asset credit is not canonical (" .. detail .. "); normalize explicitly")
    return
  end
  if ctx.canon == "error" then
    check_prunable_value(ctx, F, a.id .. ".credit", a.credit, "assets", a.id, "credit")
  end
end

-- Table preservation policy (spec section 5). Authored table: table, rows
-- and cells structural; caption and cell content authored-preserve.
-- Generated table: generated-replace throughout. Never mixed.
local function check_table_policy(ctx, F, t)
  if t.policy == "generated-replace" then
    preorder(t.children, function(d)
      if d.policy ~= "generated-replace" then
        F.add(ctx.canon, "table-policy-mixed", ctx.stage, d.id,
          "a generated table is generated-replace throughout; found " .. d.policy)
      end
    end)
  elseif t.policy == "structural" then
    preorder(t.children, function(d)
      if d.policy == "generated-replace" then
        F.add(ctx.canon, "table-policy-mixed", ctx.stage, d.id,
          "an authored table never contains generated-replace descendants")
      elseif (d.type == "table-row" or d.type == "table-cell") and d.policy ~= "structural" then
        F.add(ctx.canon, "table-policy-structure", ctx.stage, d.id, d.type .. " must be structural")
      elseif NODE_CONTENT_TYPES[d.type] and d.policy ~= "authored-preserve" then
        F.add(ctx.canon, "table-policy-structure", ctx.stage, d.id,
          d.type .. " inside an authored table must be authored-preserve")
      end
    end)
  elseif t.policy == "authored-preserve" then
    F.add(ctx.canon, "table-policy-legacy", ctx.stage, t.id,
      "legacy whole-table authored-preserve envelope; the vNext table envelope is structural with authored descendants")
  else
    F.add(ctx.canon, "table-policy-structure", ctx.stage, t.id,
      "table envelope policy must be structural (authored) or generated-replace (generated view)")
  end
end

-- ---------------------------------------------------------------------
-- Step 1: local validation (also the at-rest validator)
-- ---------------------------------------------------------------------

local function check_keys(F, stage, container_name, container)
  for _, k in ipairs(sorted_keys(container)) do
    if type(container[k]) == "table" and container[k].id ~= k then
      F.add("error", "container-key-mismatch", stage, container_name .. "/" .. k,
        "key does not match the contained id '" .. tostring(container[k].id) .. "'")
    end
  end
end

local function choose_document(records, wanted)
  if wanted then return wanted end
  local found
  for _, id in ipairs(sorted_keys(records)) do
    if records[id].recordType == "document" then
      if found then return nil, "ambiguous" end
      found = id
    end
  end
  return found
end

local function local_validate(model, opts, mode)
  opts = opts or {}
  local embed = (mode == "embed")
  local stage = embed and "local" or "at-rest"
  local F = new_findings()

  local okmodel, detail = schema_check(DM, model)
  if not okmodel then
    F.add("error", "model-schema", stage, "", "not a document-model.v1 instance: " .. detail)
    return F
  end

  local reg = model.registries
  check_keys(F, stage, "metadata", reg.metadata)
  check_keys(F, stage, "assets", reg.assets)
  -- Profile activation is lib/profile.lua's layer at rest; at embed time
  -- only valid, active manifests register record types.
  local manifests = embed and active_manifests(F, stage, reg.profiles) or nil

  local records, views = {}, {}
  for _, id in ipairs(sorted_keys(reg.metadata)) do
    local r = reg.metadata[id]
    if r.recordType == "metadata-view" then views[id] = r else records[id] = r end
    if r.profile ~= nil then
      -- A restricted profile record never embeds, so it cannot block
      -- embedding; a public one embeds only once validated by its profile.
      if embed and is_public(r) then check_profile_record(F, stage, r, manifests) end
    elseif not CORE_TYPES[r.recordType] then
      if embed then
        F.add("error", "record-type-unregistered", stage, id,
          "record type '" .. tostring(r.recordType) .. "' is not a registered core type")
      end
    else
      -- document-model.v1's registry record definition is deliberately
      -- generic, so a registry record that is not a full metadata-core.v1
      -- record (e.g. the WP1 full-coverage example's bare document record)
      -- is valid v1 data at rest: a warning there, an error at embed time,
      -- where catalogue.v1 requires the full core definition.
      local okrec, why = schema_check(MC .. "#/$defs/" .. r.recordType, r)
      if not okrec then
        F.add(embed and "error" or "warning", "record-schema", stage, id,
          "fails metadata-core.v1 " .. r.recordType .. ": " .. why)
      end
      if r.recordType == "person" and (r.roles ~= nil or r.corresponding ~= nil) then
        F.add("warning", "person-authorship-deprecated", stage, id,
          "person.roles/person.corresponding are deprecated; the normalizer migrates them to contribution records")
      end
    end
  end

  local ctx = {
    stage = stage, records = records, views = views, assets = reg.assets or {},
    envelopes = embed and M.envelopes_of(model) or nil, profiles = manifests or reg.profiles or {},
    prunes = embed and {} or nil, canon = embed and "error" or "warning",
  }

  if embed then
    ctx.restricted_ids = {}
    for id, r in pairs(reg.metadata) do
      if not is_public(r) then ctx.restricted_ids[id] = true end
    end
    for _, id in ipairs(sorted_keys(records)) do
      local r = records[id]
      if r.profile ~= nil and is_public(r) then check_profile_values(ctx, F, id, r) end
    end
  end

  local doc_id, why = choose_document(records, opts.document)
  ctx.document = doc_id
  if embed then
    if doc_id == nil then
      F.add("error", "catalogue-document-unresolved", stage, "",
        why == "ambiguous" and "several document records; pass opts.document" or "no document record")
    else
      check_catalogue_document(ctx, F, doc_id)
    end
  end

  for _, id in ipairs(sorted_keys(records)) do
    local r = records[id]
    if r.recordType == "document" and is_public(r) then check_abstract(ctx, F, r) end
    if embed then check_record_refs(ctx, F, r) end
  end
  check_positions(ctx, F)

  if embed then
    local registered = registered_types(manifests)
    for _, id in ipairs(sorted_keys(views)) do check_view(ctx, F, views[id], registered) end
    check_view_regions(ctx, F)
  end

  preorder(model.content, function(n)
    if n.type == "table" or n.type == "figure" then
      check_semantics(ctx, F, n.id, n.type, n.semantics)
    end
    if n.type == "table" then check_table_policy(ctx, F, n) end
  end)
  for _, id in ipairs(sorted_keys(ctx.assets)) do check_asset(ctx, F, ctx.assets[id]) end

  return F, ctx
end

function M.validate_at_rest(model)
  local F = local_validate(model, nil, "at-rest")
  return { ok = F.ok(), findings = F.list }
end

-- ---------------------------------------------------------------------
-- Step 2: projection
-- ---------------------------------------------------------------------

local function project(model, ctx, generator)
  local cat = { schemaVersion = 1, generator = generator or "docstyle conformance",
    document = ctx.document, records = {}, views = {}, objects = {}, assets = {} }
  for id, r in pairs(ctx.records) do
    if is_public(r) then cat.records[id] = deep_copy(r) end
  end
  for id, v in pairs(ctx.views) do
    if is_public(v) then cat.views[id] = deep_copy(v) end
  end
  preorder(model.content, function(n)
    if (n.type == "table" or n.type == "figure") and n.semantics ~= nil then
      cat.objects[n.id] = { id = n.id, type = n.type, semantics = deep_copy(n.semantics) }
    end
  end)
  for id, a in pairs(ctx.assets) do cat.assets[id] = deep_copy(a) end
  -- Remove the ENTIRE property of each prunable reference step 1 classified
  -- as known restricted -- never just the nested `record` key.
  for _, p in ipairs(ctx.prunes) do
    local holder = cat[p.container][p.id]
    if holder then
      if p.sub then
        if holder[p.property] then holder[p.property][p.sub] = nil end
      else
        holder[p.property] = nil
      end
    end
  end
  return cat
end

function M.public_projection(model, opts)
  opts = opts or {}
  local F, ctx = local_validate(model, opts, "embed")
  if not F.ok() then return { ok = false, stage = "local", findings = F.list } end
  return { ok = true, stage = "projection", findings = F.list,
    catalogue = project(model, ctx, opts.generator) }
end

-- ---------------------------------------------------------------------
-- Step 3: embedded validation (also the cold-import validator)
-- ---------------------------------------------------------------------

--- opts.local_ids: ids of the local model (local_ids_of), when known --
--- embed() passes them; a cold import cannot. opts.envelopes: the
--- document's field-envelope map (id -> {kind, role, policy, parent}); node-id references and view/region identity are checked only
--- when it is given (a warning records that they were not).
function M.validate_embedded(cat, opts)
  opts = opts or {}
  local stage = "embedded"
  local F = new_findings()
  local schema = js.resolve(CATALOGUE)
  if schema == nil then
    F.add("error", "catalogue-schema", stage, "", "catalogue.v1 schema is not registered")
    return { ok = false, stage = stage, findings = F.list }
  end
  local okcat, errs = js.validate(schema, cat)
  if not okcat then
    F.add("error", "catalogue-schema", stage, "", "fails catalogue.v1: " .. first_error(errs))
    return { ok = false, stage = stage, findings = F.list }
  end
  for _, name in ipairs({ "records", "views", "objects", "assets" }) do check_keys(F, stage, name, cat[name]) end

  local ctx = { stage = stage, records = cat.records, views = cat.views, assets = cat.assets,
    document = cat.document, envelopes = opts.envelopes, profiles = nil, canon = "error",
    local_ids = opts.local_ids }
  if not opts.envelopes then
    F.add("warning", "envelopes-unavailable", stage, "",
      "no field envelopes supplied; node-id references and view/region identity not checked")
  end

  check_catalogue_document(ctx, F, cat.document)
  for _, id in ipairs(sorted_keys(cat.records)) do
    local r = cat.records[id]
    if r.profile ~= nil then
      check_profile_record(F, stage, r, nil)
      check_profile_values(ctx, F, id, r)
    else
      if r.recordType == "document" then check_abstract(ctx, F, r) end
      check_record_refs(ctx, F, r)
    end
  end
  check_positions(ctx, F)
  local registered = registered_types(nil)
  for _, id in ipairs(sorted_keys(cat.views)) do check_view(ctx, F, cat.views[id], registered) end
  check_view_regions(ctx, F)
  for _, id in ipairs(sorted_keys(cat.objects)) do
    local o = cat.objects[id]
    check_semantics(ctx, F, id, o.type, o.semantics)
  end
  for _, id in ipairs(sorted_keys(cat.assets)) do check_asset(ctx, F, cat.assets[id]) end

  return { ok = F.ok(), stage = stage, findings = F.list }
end

function M.embed(model, opts)
  local proj = M.public_projection(model, opts)
  if not proj.ok then return proj end
  local res = M.validate_embedded(proj.catalogue,
    { envelopes = M.envelopes_of(model), local_ids = M.local_ids_of(model) })
  local findings = {}
  for _, f in ipairs(proj.findings) do findings[#findings + 1] = f end
  for _, f in ipairs(res.findings) do findings[#findings + 1] = f end
  if not res.ok then return { ok = false, stage = "embedded", findings = findings } end
  return { ok = true, stage = "embedded", findings = findings, catalogue = proj.catalogue }
end

-- ---------------------------------------------------------------------
-- Reconciliation against public_projection(local state)
-- ---------------------------------------------------------------------

--- Canonical-JSON SHA-256 of one embedded or projected entry.
function M.entry_hash(v)
  local okflag, enc = pcall(canonical.encode, v)
  if not okflag then return nil end
  return "sha256:" .. sha.hex(enc)
end

--- Compares an embedded catalogue with public_projection(model) -- never
--- with raw local records -- entry by entry, routing each through
--- lib/reconcile.lua's metadata row (contradiction is a blocking conflict).
function M.reconcile(cat, model, opts)
  local proj = M.public_projection(model, opts)
  if not proj.ok then return { ok = false, findings = proj.findings, entries = {} } end
  local entries, ok = {}, true
  local function compare(key, a, b)
    local ha, hb = a ~= nil and M.entry_hash(a) or nil, b ~= nil and M.entry_hash(b) or nil
    local agree = nil
    if a ~= nil and b ~= nil then agree = (ha ~= nil and ha == hb) end
    local d = reconcile_rules.decide({ authority = "metadata",
      present = { catalogue = a ~= nil, state = b ~= nil }, hashes_agree = agree })
    entries[key] = { outcome = d.outcome, blocking = d.blocking, embedded = ha, projected = hb }
    if d.blocking then ok = false end
  end
  compare("document", cat.document, proj.catalogue.document)
  for _, name in ipairs({ "records", "views", "objects", "assets" }) do
    local seen = {}
    for id in pairs(cat[name] or {}) do seen[id] = true end
    for id in pairs(proj.catalogue[name]) do seen[id] = true end
    for _, id in ipairs(sorted_keys(seen)) do
      compare(name .. "/" .. id, (cat[name] or {})[id], proj.catalogue[name][id])
    end
  end
  return { ok = ok, findings = proj.findings, entries = entries }
end

-- ---------------------------------------------------------------------
-- Cold recovery from the DOCX's own contents (no QMD, no local state)
-- ---------------------------------------------------------------------

-- Resolves an OPC relationship target relative to its source part's folder.
local function resolve_target(source, target)
  if target:sub(1, 1) == "/" then return target end
  local segs = {}
  for s in source:gmatch("[^/]+") do segs[#segs + 1] = s end
  segs[#segs] = nil -- drop the source part's own file name
  for s in target:gmatch("[^/]+") do
    if s == ".." then segs[#segs] = nil elseif s ~= "." then segs[#segs + 1] = s end
  end
  return "/" .. table.concat(segs, "/")
end

--- `package` is an already-read DOCX description: { parts = { [name] =
--- { contentType, json? } }, relationships = { [source part] = { {id, type,
--- target}, ... } }, envelopes = { field-envelope.v4, ... } }. Reading the
--- ZIP/OPC container itself is WP2/WP4. Cold import order (spec section 6):
--- read the catalogue part if present, then bind envelopes to records by id;
--- without a catalogue, degrade to WP1 behaviour (identity and policy only).
function M.cold_recover(pkg)
  local F = new_findings()
  local stage = "carrier"
  local envelopes, regions = {}, {}
  for i, e in ipairs(pkg.envelopes or {}) do
    local okenv, why = schema_check(ENVELOPE, e)
    if not okenv then
      F.add("error", "envelope-schema", stage, "envelopes/" .. (i - 1), "fails field-envelope.v4: " .. why)
    else
      envelopes[e.id] = { kind = e.kind, role = e.role, policy = e.policy, parent = e.parent }
      regions[e.id] = { envelope = e }
    end
  end

  local rels = {}
  for _, rel in ipairs((pkg.relationships or {})[M.CARRIER.source] or {}) do
    if rel.type == M.CARRIER.relationshipType then rels[#rels + 1] = rel end
  end
  if #rels == 0 then
    F.add("warning", "catalogue-absent", stage, "",
      "no catalogue relationship from " .. M.CARRIER.source .. "; identity and policy only")
    return { ok = F.ok(), degraded = true, findings = F.list, regions = regions }
  end
  if #rels > 1 then
    F.add("error", "carrier-ambiguous", stage, "", "more than one catalogue relationship")
    return { ok = false, findings = F.list }
  end
  local name = resolve_target(M.CARRIER.source, rels[1].target)
  local part = (pkg.parts or {})[name]
  if part == nil then
    F.add("error", "carrier-part-missing", stage, name, "catalogue relationship target is not a part")
    return { ok = false, findings = F.list }
  end
  if part.contentType ~= M.CARRIER.contentType then
    F.add("error", "carrier-content-type", stage, name,
      "catalogue part content type is '" .. tostring(part.contentType) .. "'")
    return { ok = false, findings = F.list }
  end
  if not F.ok() then return { ok = false, findings = F.list } end

  local cat = part.json
  local res = M.validate_embedded(cat, { envelopes = envelopes })
  for _, f in ipairs(res.findings) do F.list[#F.list + 1] = f end
  if not res.ok then return { ok = false, findings = F.list } end

  for id, r in pairs(regions) do
    r.object = cat.objects[id]
    r.view = cat.views[id]
  end
  return { ok = true, degraded = false, findings = F.list, regions = regions,
    objects = cat.objects, assets = cat.assets, views = cat.views, records = cat.records }
end

return M
