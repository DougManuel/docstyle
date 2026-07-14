-- tests/vnext/conformance/lib/manifest.lua
-- Atomic commit/read of the vNext state manifest and its typed sidecar
-- files. Commit protocol: write every typed file to "<name>.tmp" and the
-- manifest to "manifest.json.tmp", THEN rename the typed files, THEN rename
-- the manifest last. The manifest rename is the durable commit point --
-- a reader only ever sees either the previous complete generation or the
-- next complete generation, never a mix.
local json = require("lib.json")
local sha = require("lib.sha256")

local M = {}

-- Schema id for a typed file's manifest entry. Files whose basename matches
-- a known state schema (e.g. "regions.json" -> "regions") map to the
-- canonical published schema id ("state-<basename>.v1.json"); any other
-- name is not currently backed by a published state schema, so the name is
-- recorded unchanged rather than fabricating a URL.
local KNOWN_STATE_SCHEMAS = { regions = true, citations = true, annotations = true, metadata = true }
local function schema_id_for(name)
  local base = name:match("^(.*)%.json$")
  if base and KNOWN_STATE_SCHEMAS[base] then
    return "https://dougmanuel.github.io/docstyle/schemas/state-" .. base .. ".v1.json"
  end
  return name
end

-- Parse manifest.json with no hash verification (used internally to recover
-- stateId/generation before writing the next one). Callers wanting a
-- verified read must use M.read().
local function read_raw(dir)
  local f = io.open(dir .. "/manifest.json", "rb")
  if not f then return nil end
  local bytes = f:read("a"); f:close()
  local okflag, manifest = pcall(json.decode, bytes)
  if not okflag then return nil end
  return manifest
end

-- commit(dir, files, opts) -> generation
-- files: { ["<name>.json"] = <lua table to encode> , ... }
-- opts.fail_before_rename: raise after the .tmp writes but before any
-- rename, for interruption testing.
function M.commit(dir, files, opts)
  local existing = read_raw(dir)
  local state_id = existing and existing.stateId
    or sha.hex(dir .. tostring(os.time()) .. tostring(math.random())):sub(1, 32)
  local generation = (existing and existing.generation or 0) + 1

  local names = {}
  for name in pairs(files) do names[#names + 1] = name end
  table.sort(names)

  local entries = {}
  for _, name in ipairs(names) do
    local encoded = json.encode(files[name])
    local tmp = assert(io.open(dir .. "/" .. name .. ".tmp", "wb"))
    tmp:write(encoded); tmp:close()
    entries[#entries + 1] = {
      name = name,
      schema = schema_id_for(name),
      hash = "sha256:" .. sha.hex(encoded),
    }
  end

  local manifest = {
    schemaVersion = 1,
    stateId = state_id,
    generation = generation,
    files = entries,
  }
  local mtmp = assert(io.open(dir .. "/manifest.json.tmp", "wb"))
  mtmp:write(json.encode(manifest)); mtmp:close()

  if opts and opts.fail_before_rename then
    error("injected failure")
  end

  for _, name in ipairs(names) do
    os.rename(dir .. "/" .. name .. ".tmp", dir .. "/" .. name)
  end
  os.rename(dir .. "/manifest.json.tmp", dir .. "/manifest.json")

  return generation
end

-- read(dir) -> manifest | nil, errors
-- Re-hashes every listed file against the manifest's recorded hash; any
-- mismatch (stale or tampered file, or a file missing entirely) is reported
-- and the manifest is not returned.
function M.read(dir)
  local manifest = read_raw(dir)
  if not manifest then return nil, { "manifest.json not found or invalid" } end

  local errors = {}
  for _, entry in ipairs(manifest.files or {}) do
    local f = io.open(dir .. "/" .. entry.name, "rb")
    if not f then
      errors[#errors + 1] = entry.name .. ": file missing"
    else
      local bytes = f:read("a"); f:close()
      local hash = "sha256:" .. sha.hex(bytes)
      if hash ~= entry.hash then
        errors[#errors + 1] = entry.name .. ": hash mismatch (stale or tampered file)"
      end
    end
  end

  if #errors > 0 then return nil, errors end
  return manifest
end

return M
