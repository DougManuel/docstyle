-- tests/vnext/conformance/lib/migrate.lua
-- Legacy (writer v1-v3) ADDIN DOCSTYLE field-code payload and sidecar
-- migration into the vNext v4 field envelope / state-store model.
--
-- payload(legacy_table) -> { envelope, record, findings }
-- sidecars({ field_codes=?, comments=?, revisions=? }) -> { citations, annotations, report }
--
-- key-map.json (legacy/key-map.json, sibling of this lib/ directory) is the
-- disposition inventory: every key ever observed on a legacy payload is
-- listed there as mapped (writes to an envelope field), record (carried into
-- the migration record body, not the envelope) or dropped (discarded, with a
-- rationale). A legacy key with no entry is an unmapped-legacy-key error --
-- see key-map.json's "keys" table and its policyDefaultRule / idResolutionRule
-- notes for the reasoning behind each disposition.

local json = require("lib.json")
local sha = require("lib.sha256")
local canonical = require("lib.canonical")

local M = {}

-- ---------------------------------------------------------------------
-- key-map.json loading
-- ---------------------------------------------------------------------

-- This chunk's own file path, independent of PANDOC_SCRIPT_FILE (which stays
-- pinned to the top-level entry script even when this module is require()'d
-- from a dofile()'d test file several frames up -- see the note in
-- tests/test-migrate.lua). debug.getinfo(1, "S").source is "@<path>" for a
-- file chunk; the leading "@" is stripped.
local function this_module_path()
  local source = debug.getinfo(1, "S").source
  return source:match("^@(.*)$") or source
end

local LIB_DIR = pandoc.path.directory(this_module_path())
local CONFORMANCE_ROOT = pandoc.path.join({ LIB_DIR, ".." })
local KEY_MAP_PATH = pandoc.path.join({ CONFORMANCE_ROOT, "legacy", "key-map.json" })

local KEY_MAP -- loaded lazily, cached for the life of the process
local function key_map()
  if not KEY_MAP then
    KEY_MAP = json.read(KEY_MAP_PATH)
  end
  return KEY_MAP
end

-- ---------------------------------------------------------------------
-- small helpers
-- ---------------------------------------------------------------------

-- Deterministic key order: Lua's pairs() iteration order over string keys is
-- unspecified, and migration must be reproducible (same legacy payload in ->
-- same envelope/record/findings out, every run), so every walk over a legacy
-- payload's keys goes through this sort first.
local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

-- Legacy version defaults to 1 when absent, mirroring the real reader
-- (R/field_codes.R:520 `version <- payload$version %||% 1L`). docstyle_schemas
-- lists "version" as optional for every payload type, so pre-version-key
-- legacy payloads are expected to arrive without one.
local function version_of(legacy)
  return legacy.version or 1
end

-- ---------------------------------------------------------------------
-- payload migration
-- ---------------------------------------------------------------------

function M.payload(legacy)
  local findings = {}

  -- Malformed-input guards (Wave 4 item 3): a caller passing a non-table
  -- legacy value, or a payload whose "version" key isn't a number, must
  -- get a finding back, not a Lua runtime error from indexing a non-table
  -- or comparing a string/table with 1/3 below.
  if type(legacy) ~= "table" then
    findings[#findings + 1] = { level = "error", code = "invalid-legacy-payload",
      message = "legacy payload must be a table; got " .. type(legacy) }
    return { envelope = nil, record = nil, findings = findings, provisional = true }
  end

  local km = key_map()

  local version = version_of(legacy)
  if type(version) ~= "number" then
    findings[#findings + 1] = { level = "error", code = "non-numeric-version",
      message = "legacy payload 'version' must be a number; got "
        .. type(version) .. " (" .. tostring(version) .. ")" }
    return { envelope = nil, record = nil, findings = findings, provisional = true }
  end
  if version < 1 or version > 3 then
    findings[#findings + 1] = { level = "error", code = "unsupported-version",
      message = "legacy field code version " .. tostring(version)
        .. " is outside the supported range 1-3" }
    return { envelope = nil, record = nil, findings = findings, provisional = true }
  end

  local type_entry = km.payloadTypes[legacy.type]
  if not type_entry then
    findings[#findings + 1] = { level = "error", code = "unknown-payload-type",
      message = "legacy payload type '" .. tostring(legacy.type)
        .. "' is not a recognized docstyle field-code type" }
    return { envelope = nil, record = nil, findings = findings, provisional = true }
  end

  local envelope = { v = 4, kind = type_entry.kind, policy = type_entry.policy }
  local record = {}

  -- "type" and "version" are already consumed above (special-cased, per the
  -- brief: type drives the payloadTypes lookup, version drives the range
  -- check and is always replaced by the literal constant v=4, never copied).
  -- They still have entries in key-map.json's "keys" table for inventory
  -- completeness, but the generic walk below skips them so it never
  -- overwrites envelope.v/kind with a raw copy of the legacy value.
  for _, key in ipairs(sorted_keys(legacy)) do
    if key ~= "type" and key ~= "version" then
      local value = legacy[key]
      local key_entry = km.keys[key]
      if key_entry == nil then
        findings[#findings + 1] = { level = "error", code = "unmapped-legacy-key",
          message = "legacy key '" .. key .. "' has no disposition in key-map.json" }
      elseif key_entry.disposition == "mapped" then
        envelope[key_entry.target] = value
      elseif key_entry.disposition == "record" then
        -- Most "record" keys land under their own legacy name. A few --
        -- currently only the char payload's "source" key -- need a
        -- different record key: "source" is semantic content (the literal
        -- QMD shortcode text), but lib/hashes.lua's content_hash strips any
        -- key literally named "source" (or "hash") at every depth -- a
        -- convention meant for provenance pointers, not content. Stored
        -- under the legacy name, the shortcode text would silently drop out
        -- of the record's canonical encoding, were this record ever hashed
        -- downstream (WP1 itself no longer hashes the record into the
        -- envelope -- see the hash-unresolved finding below -- but the
        -- rename still protects whatever real semantic-hash pass a later
        -- work package runs over this same record shape). key-map.json's
        -- optional per-key "recordKey" says what to call it instead
        -- ("legacySource" for "source").
        -- Honouring it generically here (rather than hardcoding
        -- `if key == "source"`) means a future key-map.json entry can
        -- request the same rename for any other key with no code change.
        record[key_entry.recordKey or key] = value
      elseif key_entry.disposition == "dropped" then
        findings[#findings + 1] = { level = "info", code = "dropped-legacy-key",
          message = "legacy key '" .. key .. "' dropped: "
            .. (key_entry.rationale or "no rationale recorded") }
      else
        -- Defensive: key-map.json itself must stay a closed, valid
        -- disposition vocabulary (mapped/record/dropped). A typo or a new
        -- disposition string introduced there without a matching code path
        -- must not be silently ignored -- that would drop the key on the
        -- floor with no trace, exactly the failure mode this module exists
        -- to prevent for unmapped keys.
        findings[#findings + 1] = { level = "error", code = "invalid-key-map-disposition",
          message = "legacy key '" .. key .. "' has unrecognized key-map.json disposition '"
            .. tostring(key_entry.disposition) .. "'" }
      end
    end
  end

  -- id: from whichever mapped key targeted "id" (legacy "name" for div,
  -- legacy "id" for figure -- see key-map.json's idResolutionRule). When
  -- neither was present, fall back to a deterministic placeholder.
  -- Deterministic (not lib/ids.lua's random generate()) because migrate.payload
  -- is a single-input/single-output pure function: it has no cross-call
  -- "used ids" registry to thread a real collision-avoiding draw through, and
  -- migration output must be reproducible run to run. The ordinal is always
  -- the fixed literal "01" (not an incrementing counter) for the same reason
  -- -- there is nothing within one call to count. The "g-" prefix mirrors
  -- lib/ids.lua's reserved generated-id prefix so downstream code recognizes
  -- the id as tool-generated rather than authored.
  if envelope.id == nil then
    envelope.id = "g-" .. envelope.kind .. "-migr01"
  end

  -- Typed migration record (Wave 4 item 2): give the record a stable id,
  -- a recordType and a schemaVersion so it is a typed shape rather than an
  -- untyped bag of whatever key-map.json "record"-disposition keys
  -- happened to be present. Still provisional -- WP1 does not own the
  -- embedded-catalogue carrier this record shape will eventually feed
  -- (that is WP4's job); this only makes today's ad hoc record
  -- self-describing while it waits for that carrier to exist.
  record.id = envelope.id
  record.recordType = "migration-record"
  record.schemaVersion = 1

  -- Wave 4 item 1 (envelope hash honesty): WP1 has no OOXML parser, so the
  -- true semantic content hash of the recovered region cannot be computed
  -- here. The previous implementation hashed the migration record (legacy
  -- field-code metadata -- CSS classes, widths, anchor offsets, and so on)
  -- and put that value in the envelope's hash position as though it were
  -- the region's semantic content hash. That was misleading in a way that
  -- was easy to miss: two payloads with the same (often empty) record
  -- body but entirely different authored content -- for example the v1
  -- div "toc" and the v3 div "abstract" cases in legacy/cases/, whose
  -- record bodies are both {} because "name" maps to envelope.id, not the
  -- record -- would collide on an identical "content hash" despite being
  -- different regions with different content.
  --
  -- Mark the hash explicitly UNRESOLVED instead of silently omitting it:
  -- pandoc.json.null serializes as JSON `null`, present in the envelope
  -- but structurally impossible to mistake for a real
  -- `sha256:<64 hex>` value (field-envelope.v4's hash pattern requires
  -- that shape, and `null` fails it cleanly at /hash rather than via a
  -- fake-looking string). A finding makes the deferral explicit and
  -- greppable; WP5's real migration driver has the recovered semantic
  -- region and computes the real hash there.
  envelope.hash = pandoc.json.null
  findings[#findings + 1] = { level = "warning", code = "hash-unresolved",
    message = "content hash deferred to the WP5 migration driver, which has the recovered semantic region" }

  -- field-envelope.v4 REQUIRES hash to match ^sha256:[0-9a-f]{64}$, so an
  -- envelope whose hash is null is not -- and must never be presented as
  -- -- a final, schema-valid v4 envelope: it is a PROVISIONAL mapping.
  -- provisional=true is the explicit, stable marker callers and tests key
  -- on, rather than inferring provisionality from envelope shape (which
  -- would break silently if a future change gave hash a real-looking
  -- value without also resolving this flag).
  return { envelope = envelope, record = record, findings = findings, provisional = true }
end

-- ---------------------------------------------------------------------
-- sidecar migration
-- ---------------------------------------------------------------------

-- Every real legacy sidecar this module reads keys its entries by an id or
-- marker string rather than storing a plain 1..n array: comments.json
-- (`comments[[id]] <- ...`, R/comments.R:87), revisions.json
-- (`revisions[[rev_id]] <- ...`, R/revisions.R:61) and field-codes.json's
-- citationGroups (`citation_groups[[group_key]] <- ...`,
-- R/extract_citations.R:306). pandoc.json.decode reads a JSON object as
-- that same has-a-string-key shape (see lib/jsonschema.lua's own
-- object/array disambiguation), so detect that shape and normalize it to a
-- plain 1..n list. When object-keyed, the markers are sorted before
-- iterating so the normalized order is deterministic (Lua pairs() order
-- over string keys is not) and migration stays reproducible run to run.
-- Arrays (the synthetic shape some tests and the fixture-style callers use)
-- pass through unchanged.
--
-- Returns list, markers: `markers` is the sorted list of original object
-- keys aligned position-for-position with `list` (Wave 4 item 4 -- callers
-- that need to carry the original marker into a migrated id read it from
-- here), or nil when `raw` was already a plain array (there is no marker
-- to carry; plain-array inputs' synthesized ids are unchanged).
local function normalize_container(raw)
  if raw == nil then return {}, nil end
  local has_string_key = false
  for k in pairs(raw) do
    if type(k) == "string" then has_string_key = true break end
  end
  if not has_string_key then return raw, nil end

  local markers = {}
  for k in pairs(raw) do markers[#markers + 1] = k end
  table.sort(markers)
  local list = {}
  for _, marker in ipairs(markers) do list[#list + 1] = raw[marker] end
  return list, markers
end

-- Real legacy revisions.json uses the full words "insertion"/"deletion" (see
-- R/revisions.R: `type = "insertion"`, and its "deletion" counterpart); the
-- target schema's op enum is "insert"/"delete" (schemas/state-annotations.v1
-- .json). Normalize the legacy spelling to the schema's; already-normalized
-- or unrecognized values pass through unchanged so an genuinely invalid value
-- fails schema validation loudly instead of being silently coerced.
local function normalize_op(op_type)
  if op_type == "insertion" then return "insert" end
  if op_type == "deletion" then return "delete" end
  return op_type
end

-- Real anchor resolution (matching a comment/revision to its live position
-- in the document) is WP5. Until then, migrate.sidecars derives a stable
-- placeholder from whatever descriptive text is available (anchor_text when
-- present, else the annotation's own text) and flags it with a warning
-- finding so the placeholder is never mistaken for a resolved anchor.
local function anchor_placeholder(basis)
  return "legacy-anchor-" .. sha.hex(basis or ""):sub(1, 8)
end

function M.sidecars(inputs)
  inputs = inputs or {}
  local findings = {}

  -- citations (state-citations.v1). The real field-codes.json carries two
  -- different citation-shaped containers: "citations" is the per-citekey
  -- item catalog (itemData/uris -- a different shape, out of scope here,
  -- see key-map.json/audit notes) and "citationGroups" is the per-field-code
  -- group list this function actually migrates (citekeys/instrText, see
  -- R/extract_citations.R:306-312). Synthetic/test fixtures instead use a
  -- "citations" container whose items are already {keys, instruction}.
  -- Prefer the real "citationGroups" container when present; fall back to
  -- "citations" for the synthetic shape. Either way, normalize per-entry
  -- field names so both the real (citekeys/instrText) and synthetic
  -- (keys/instruction) spellings land the same way.
  local citations = { schemaVersion = 1, citations = {} }
  local field_codes = inputs.field_codes
  if field_codes then
    local list = normalize_container(field_codes.citationGroups or field_codes.citations)
    for _, c in ipairs(list) do
      local keys = c.keys or c.citekeys
      local instruction = c.instruction or c.instrText
      -- Malformed-input guard (Wave 4 item 3): a citation group with no
      -- keys/citekeys at all, or an empty keys array, would otherwise
      -- crash below (`keys[1]` on a nil `keys`, or concatenating a nil
      -- `keys[1]` into the id string). Skip the group with a blocking
      -- finding instead of guessing an id or letting the crash propagate.
      if keys == nil or keys[1] == nil then
        findings[#findings + 1] = { level = "error", code = "malformed-citation-group",
          message = "citation group has no usable keys/citekeys; skipped" }
      else
        citations.citations[#citations.citations + 1] = {
          id = "cite-" .. keys[1],
          keys = keys,
          instruction = instruction,
          privacy = "public",
        }
      end
    end
    if field_codes.zotero_pref ~= nil then
      citations.zoteroPref = field_codes.zotero_pref
    end
  end

  -- annotations (state-annotations.v1). Real comments.json/revisions.json
  -- are id-keyed JSON objects whose entries carry "content", not "text"
  -- (R/comments.R:87-92,169; R/revisions.R:61-66,144); synthetic/test
  -- fixtures use a plain array already spelled "text". normalize_container
  -- handles the array-vs-object-container difference; the `item.text or
  -- item.content` fallback handles the field-name difference.
  local annotations = { schemaVersion = 1 }
  if inputs.comments then
    local list, markers = normalize_container(inputs.comments)
    annotations.comments = {}
    for i, item in ipairs(list) do
      local text = item.text or item.content
      -- Marker-preserving ids (Wave 4 item 4): when the input was an
      -- object keyed by marker (comments.json's real shape,
      -- `comments[[id]] <- ...`), carry that original key into the
      -- migrated id instead of synthesizing "c1"/"c2" -- WP5 needs the
      -- original id for reply-threading reconstruction. Plain-array
      -- inputs have no marker to carry, so their synthesized ids are
      -- unchanged.
      local id = (markers and markers[i]) or ("c" .. i)
      annotations.comments[i] = {
        id = id,
        anchor = anchor_placeholder(item.anchor_text or text),
        author = item.author,
        date = item.date,
        text = text,
      }
      findings[#findings + 1] = { level = "warning", code = "anchor-unresolved",
        message = "comment " .. id .. " anchor is a placeholder pending WP5 anchor resolution" }
    end
  end
  if inputs.revisions then
    local list, markers = normalize_container(inputs.revisions)
    annotations.revisions = {}
    for i, item in ipairs(list) do
      local text = item.text or item.content
      -- See the comments loop above: carry the original marker into the
      -- id for object-keyed input; plain arrays keep "r1"/"r2".
      local id = (markers and markers[i]) or ("r" .. i)
      local entry = {
        id = id,
        anchor = anchor_placeholder(item.anchor_text or text),
        op = normalize_op(item.type),
        author = item.author,
        date = item.date,
      }
      if text ~= nil then entry.text = text end
      annotations.revisions[i] = entry
      findings[#findings + 1] = { level = "warning", code = "anchor-unresolved",
        message = "revision " .. id .. " anchor is a placeholder pending WP5 anchor resolution" }
    end
  end

  -- report (report-envelope.v1). Inputs are hashed as provided and never
  -- modified; only the three top-level inputs migrate.sidecars accepts are
  -- eligible, each recorded under its canonical sidecar filename (see
  -- legacy-contract.json's "sidecars" list).
  local report_inputs = {}
  local function add_input(name, value)
    if value ~= nil then
      report_inputs[#report_inputs + 1] = {
        name = name,
        hash = "sha256:" .. sha.hex(canonical.encode(value)),
      }
    end
  end
  add_input("field-codes.json", inputs.field_codes)
  add_input("comments.json", inputs.comments)
  add_input("revisions.json", inputs.revisions)

  local has_error, has_warning = false, false
  for _, f in ipairs(findings) do
    if f.level == "error" then has_error = true end
    if f.level == "warning" then has_warning = true end
  end
  local result = "PASS"
  if has_error then result = "FAIL"
  elseif has_warning then result = "PASS_WITH_WARNINGS" end

  local report = {
    schemaVersion = 1,
    operation = "migrate",
    toolVersion = "0.19.0",
    inputs = report_inputs,
    result = result,
    findings = findings,
  }

  return { citations = citations, annotations = annotations, report = report }
end

return M
