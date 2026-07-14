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
local hashes = require("lib.hashes")
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
  local km = key_map()
  local findings = {}

  local version = version_of(legacy)
  if version < 1 or version > 3 then
    findings[#findings + 1] = { level = "error", code = "unsupported-version",
      message = "legacy field code version " .. tostring(version)
        .. " is outside the supported range 1-3" }
    return { envelope = nil, record = nil, findings = findings }
  end

  local type_entry = km.payloadTypes[legacy.type]
  if not type_entry then
    findings[#findings + 1] = { level = "error", code = "unknown-payload-type",
      message = "legacy payload type '" .. tostring(legacy.type)
        .. "' is not a recognized docstyle field-code type" }
    return { envelope = nil, record = nil, findings = findings }
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
        -- The char payload's "source" key is semantic content (the literal
        -- QMD shortcode text), but lib/hashes.lua's content_hash strips any
        -- key literally named "source" (or "hash") at every depth -- a
        -- convention meant for provenance pointers, not content. Stored
        -- under the legacy name, the shortcode text would silently drop out
        -- of the envelope hash. Renaming it to "legacySource" in the record
        -- keeps it inside the hash without touching lib/hashes.lua. See
        -- key-map.json's "source" entry (recordKey: legacySource).
        if key == "source" then
          record.legacySource = value
        else
          record[key] = value
        end
      elseif key_entry.disposition == "dropped" then
        findings[#findings + 1] = { level = "info", code = "dropped-legacy-key",
          message = "legacy key '" .. key .. "' dropped: "
            .. (key_entry.rationale or "no rationale recorded") }
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

  envelope.hash = hashes.content_hash(record)

  return { envelope = envelope, record = record, findings = findings }
end

-- ---------------------------------------------------------------------
-- sidecar migration
-- ---------------------------------------------------------------------

-- Legacy field-codes.json represents "a citation with keys and an
-- instruction field code" as either a plain list of { keys, instruction }
-- tables (one per Zotero field-code occurrence), or as a table keyed by an
-- arbitrary marker string whose values have that same per-item shape --
-- mirroring the real docstyle field-codes.json "citationGroups" map (each
-- entry keyed by a group id, e.g. fc$citations[[ck]] / fc$citationGroups in
-- R/add_citations.R and R/extract_citations.R). Detect which container shape
-- we were handed with the same has-a-string-key heuristic lib/jsonschema.lua
-- uses to tell JSON objects from arrays after pandoc.json.decode's
-- object/array ambiguity, then normalize to a plain 1..n list. When
-- object-keyed, the markers are sorted before iterating so the normalized
-- order is deterministic (Lua pairs() order over string keys is not).
local function normalize_citations(raw)
  if raw == nil then return {} end
  local has_string_key = false
  for k in pairs(raw) do
    if type(k) == "string" then has_string_key = true break end
  end
  if not has_string_key then return raw end

  local markers = {}
  for k in pairs(raw) do markers[#markers + 1] = k end
  table.sort(markers)
  local list = {}
  for _, marker in ipairs(markers) do list[#list + 1] = raw[marker] end
  return list
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

  -- citations (state-citations.v1)
  local citations = { schemaVersion = 1, citations = {} }
  local field_codes = inputs.field_codes
  if field_codes then
    local list = normalize_citations(field_codes.citations)
    for _, c in ipairs(list) do
      citations.citations[#citations.citations + 1] = {
        id = "cite-" .. c.keys[1],
        keys = c.keys,
        instruction = c.instruction,
        privacy = "public",
      }
    end
    if field_codes.zotero_pref ~= nil then
      citations.zoteroPref = field_codes.zotero_pref
    end
  end

  -- annotations (state-annotations.v1)
  local annotations = { schemaVersion = 1 }
  if inputs.comments then
    annotations.comments = {}
    for i, item in ipairs(inputs.comments) do
      annotations.comments[i] = {
        id = "c" .. i,
        anchor = anchor_placeholder(item.anchor_text or item.text),
        author = item.author,
        date = item.date,
        text = item.text,
      }
      findings[#findings + 1] = { level = "warning", code = "anchor-unresolved",
        message = "comment c" .. i .. " anchor is a placeholder pending WP5 anchor resolution" }
    end
  end
  if inputs.revisions then
    annotations.revisions = {}
    for i, item in ipairs(inputs.revisions) do
      local entry = {
        id = "r" .. i,
        anchor = anchor_placeholder(item.anchor_text or item.text),
        op = normalize_op(item.type),
        author = item.author,
        date = item.date,
      }
      if item.text ~= nil then entry.text = item.text end
      annotations.revisions[i] = entry
      findings[#findings + 1] = { level = "warning", code = "anchor-unresolved",
        message = "revision r" .. i .. " anchor is a placeholder pending WP5 anchor resolution" }
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
