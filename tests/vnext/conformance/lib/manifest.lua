-- tests/vnext/conformance/lib/manifest.lua
-- Atomic commit/read of the vNext state manifest and its typed sidecar
-- files, using generation-qualified immutable physical files.
--
-- Commit protocol:
--   1. Validate every logical file name in this commit's batch against the
--      path-containment allowlist (no absolute paths, no "..", no path
--      separators) before writing anything.
--   2. For each logical file (e.g. "regions.json"), compute this commit's
--      physical name "<base>.<generation>.json" (e.g. "regions.2.json") and
--      write it to "<physical>.tmp", then rename it to "<physical>".
--      Because the physical name always belongs to the generation being
--      committed -- never to a generation any existing manifest already
--      references -- this rename can never disturb a file the CURRENT
--      manifest (the previous generation) is relying on. There is no
--      "shared filename" window for a reader to observe half-written.
--   3. Write a complete new "manifest.json.tmp" for the new generation,
--      referencing the just-renamed physical files, their schema ids and
--      hashes.
--   4. Rename "manifest.json.tmp" over "manifest.json". This is the SOLE
--      commit point: every write and rename before this line is either
--      inert (a "<physical>.tmp" file nothing references) or invisible to
--      readers (a fresh "<physical>" file no manifest points at yet). A
--      crash at any point before this rename leaves manifest.json, and
--      therefore the reader-visible generation, exactly as it was; a crash
--      after this rename has fully committed the new generation. This is
--      what makes "a reader only ever sees either the previous complete
--      generation or the next complete generation, never a mix" genuinely
--      true: unlike a design that reuses a shared physical filename across
--      generations, no rename in this protocol other than this last one is
--      something a reader could observe mid-flight and misinterpret.
--   5. Best-effort GC: delete physical files belonging to generations older
--      than the one just superseded (i.e. keep this generation and the one
--      before it; remove anything older). GC runs after the commit point
--      and never raises -- a leftover orphaned file is harmless clutter,
--      never a correctness problem, and must never turn an already-durable
--      commit into a reported failure.
--
-- Path containment: both the caller-supplied logical `name` (at commit
-- time) and the manifest-recorded physical `file` (at read time) are
-- validated against a strict allowlist BEFORE being concatenated with the
-- state directory to build a path. This is enforced as an allowlist
-- (reject anything that does not match a known-safe shape) rather than a
-- blocklist of specific bad substrings, so there is no encoding trick or
-- missed special case that lets a hostile or corrupted name reach
-- `io.open`.
local json = require("lib.json")
local sha = require("lib.sha256")

local M = {}

-- Schema id for a typed file's manifest entry. Files whose logical base
-- name matches a known state schema (e.g. "regions.json" -> "regions") map
-- to the canonical published schema id ("state-<basename>.v1.json"); any
-- other name is not currently backed by a published state schema, so the
-- name is recorded unchanged rather than fabricating a URL.
local KNOWN_STATE_SCHEMAS = { regions = true, citations = true, annotations = true, metadata = true }
local function schema_id_for(name)
  local base = name:match("^(.*)%.json$")
  if base and KNOWN_STATE_SCHEMAS[base] then
    return "https://dougmanuel.github.io/docstyle/schemas/state-" .. base .. ".v1.json"
  end
  return name
end

-- Path-containment allowlists (see module docstring). A logical name is
-- what callers pass to commit() and what manifest entries are keyed by
-- ("regions.json"); a physical name is the generation-qualified file that
-- actually exists on disk ("regions.2.json"). Both are lowercase-letter-led,
-- hyphen/digit body, ".json"-suffixed -- physical names additionally
-- require the embedded ".<generation>" segment. Neither pattern can match
-- an absolute path, a "..", or anything containing "/".
local LOGICAL_NAME_PATTERN = "^[a-z][a-z0-9%-]*%.json$"
-- (Physical names need no separate pattern constant: validate_manifest
-- requires each entry's file to EQUAL physical_name(name, generation),
-- which is strictly stronger than a shape check and pins the generation.)

local function check_logical_name(name)
  if type(name) ~= "string" or not name:match(LOGICAL_NAME_PATTERN) then
    error("manifest: rejected logical file name outside the allowed pattern: " .. tostring(name))
  end
end

-- string.format("%d", ...) rather than plain concatenation: JSON has no
-- int/float distinction, so a `generation` value read back from a decoded
-- manifest (via read_raw) is a Lua float even when its value is exactly
-- integral (pandoc.json.decode always decodes JSON numbers to Lua floats).
-- Lua's default float-to-string conversion renders an integral float with a
-- trailing ".0" (e.g. 2.0 -> "2.0", precisely so int/float are visually
-- distinguishable) -- plain concatenation would silently produce
-- "regions.2.0.json", which fails PHYSICAL_FILE_PATTERN's `%d+` (no literal
-- "." allowed inside the generation segment). %d requires (and coerces) an
-- exact-integer numeric value, giving a clean digit string regardless of
-- the value's underlying Lua subtype.
local function physical_name(logical_name, generation)
  local base = logical_name:match("^(.*)%.json$")
  return base .. "." .. string.format("%d", generation) .. ".json"
end

-- Full state-manifest.v1 contract validation, applied to every manifest
-- read at BOTH boundaries (M.read, and the lineage read commit() performs
-- before writing the next generation). A manifest that fails any check is
-- structural corruption and RAISES -- the nil+errors channel that M.read
-- exposes is reserved for a well-formed manifest whose referenced typed
-- files are missing or stale ON DISK, which is a different failure class
-- (the manifest is trustworthy; the world drifted). Checks: schemaVersion
-- is exactly 1; stateId is 32 lowercase-hex characters; generation is an
-- integral number >= 1; files is present with at least one entry; every
-- entry's logical name passes containment, its physical file equals
-- physical_name(name, generation) exactly (binding each entry to THIS
-- manifest's generation -- a manifest edited to a different generation
-- while still pointing at another generation's files fails here), its
-- schema id agrees with its logical store, and its hash is a well-formed
-- sha256 value; logical names are unique.
local function validate_manifest(manifest, dir)
  local function bad(msg)
    error("manifest.json fails the state-manifest.v1 contract (" .. dir .. "): " .. msg)
  end
  if type(manifest) ~= "table" then bad("not a JSON object") end
  if math.tointeger(manifest.schemaVersion) ~= 1 then
    bad("schemaVersion must be 1, got " .. tostring(manifest.schemaVersion))
  end
  if type(manifest.stateId) ~= "string" or #manifest.stateId ~= 32
    or not manifest.stateId:match("^[0-9a-f]+$") then
    bad("stateId must be 32 lowercase hex characters")
  end
  local generation = math.tointeger(manifest.generation)
  if generation == nil or generation < 1 then
    bad("generation must be an integer >= 1, got " .. tostring(manifest.generation))
  end
  if type(manifest.files) ~= "table" then
    bad("files collection is missing")
  end
  local n = 0
  local seen = {}
  for _, entry in ipairs(manifest.files) do
    n = n + 1
    if type(entry) ~= "table" then bad("files[" .. n .. "] is not an object") end
    local name = entry.name
    if type(name) ~= "string" or not name:match(LOGICAL_NAME_PATTERN) then
      bad("files[" .. n .. "] logical name fails containment: " .. tostring(name))
    end
    if seen[name] then bad("duplicate logical name: " .. name) end
    seen[name] = true
    if entry.file ~= physical_name(name, generation) then
      bad(name .. ": physical file '" .. tostring(entry.file) ..
        "' does not belong to generation " .. generation ..
        " (expected '" .. physical_name(name, generation) .. "')")
    end
    if entry.schema ~= schema_id_for(name) then
      bad(name .. ": schema id '" .. tostring(entry.schema) ..
        "' does not correspond to this logical store")
    end
    if type(entry.hash) ~= "string" or #entry.hash ~= 71
      or not entry.hash:match("^sha256:[0-9a-f]+$") then
      bad(name .. ": hash is not a well-formed sha256 value")
    end
  end
  if n == 0 then bad("files collection is empty") end
end

-- Parse manifest.json with no hash verification of the referenced typed
-- files (used internally to recover stateId/generation before writing the
-- next generation, and by M.read before it hash-checks the files).
-- Distinguishes three states: the file does not exist at all (nil -- a
-- genuinely fresh store, fine for commit() to start a new lineage); the
-- file exists and satisfies the full state-manifest.v1 contract
-- (returned); or the file exists but is corrupt -- unparseable JSON or any
-- contract violation. The third case raises rather than being folded into
-- "absent", because treating a corrupt-but-present manifest as "no prior
-- generation" would let commit() start a brand-new random stateId at
-- generation 1 while the directory may still hold real typed files from a
-- real prior generation -- silently orphaning or shadowing them instead of
-- surfacing the corruption for a person to resolve.
local function read_raw(dir)
  local f = io.open(dir .. "/manifest.json", "rb")
  if not f then return nil end
  local bytes = f:read("a"); f:close()
  local okflag, manifest = pcall(json.decode, bytes)
  if not okflag then
    error("manifest.json exists but is not valid JSON (" .. dir .. "): " .. tostring(manifest))
  end
  validate_manifest(manifest, dir)
  return manifest
end

-- Best-effort, non-fatal GC: remove physical files whose embedded
-- generation number is older than the generation immediately preceding
-- `new_generation` (i.e. keep `new_generation` and `new_generation - 1`;
-- remove anything older). Scans the directory rather than tracking history
-- itself, so it also sweeps up any backlog left by a previous GC that
-- failed, or by a generation that was attempted but never committed (an
-- orphan from an interrupted commit, for example).
local function gc_old_generations(dir, new_generation)
  local keep_min = new_generation - 1
  for _, fname in ipairs(pandoc.system.list_directory(dir)) do
    local gen_str = fname:match("^[a-z][a-z0-9%-]*%.(%d+)%.json$")
    if gen_str and tonumber(gen_str) < keep_min then
      os.remove(dir .. "/" .. fname)
    end
  end
end

-- commit(dir, files, opts) -> generation
-- files: { ["<logical-name>.json"] = <lua table to encode>, ... }
-- opts.fail_before_rename: raise after the typed-file ".tmp" writes but
--   before ANY rename (typed files or manifest) -- nothing durable has
--   changed on disk yet at this point (only inert ".tmp" files exist).
-- opts.fail_before_manifest_rename: raise after the typed-file renames AND
--   after manifest.json.tmp is fully written, but before the manifest is
--   renamed into place. This is the interesting interruption window under
--   this generation-qualified design: the new generation's typed files
--   already exist on disk under their final physical names, but
--   manifest.json has not been repointed at them, so they are harmless
--   orphans and a reader must still see the previous generation.
function M.commit(dir, files, opts)
  opts = opts or {}
  local existing = read_raw(dir)
  local state_id = existing and existing.stateId
    or sha.hex(dir .. tostring(os.time()) .. tostring(math.random())):sub(1, 32)
  -- math.tointeger: normalize away the JSON-decode float subtype (see the
  -- physical_name comment above) so `generation` arithmetic and formatting
  -- stay in integers from here on, not just at the one call site that
  -- happens to format a string.
  local prev_generation = existing and existing.generation or 0
  prev_generation = math.tointeger(prev_generation) or prev_generation
  local generation = prev_generation + 1

  local names = {}
  for name in pairs(files) do
    check_logical_name(name)
    names[#names + 1] = name
  end
  table.sort(names)
  if #names == 0 then
    error("manifest: commit called with an empty files batch -- nothing to commit")
  end

  -- Phase 1: write every typed file under a FRESH, generation-qualified
  -- physical name that no existing manifest references.
  local entries = {}
  for _, name in ipairs(names) do
    local physical = physical_name(name, generation)
    local encoded = json.encode(files[name])
    local tmp_path = dir .. "/" .. physical .. ".tmp"
    local tmp = assert(io.open(tmp_path, "wb"))
    assert(tmp:write(encoded))
    assert(tmp:close())
    entries[#entries + 1] = {
      name = name,
      file = physical,
      schema = schema_id_for(name),
      hash = "sha256:" .. sha.hex(encoded),
    }
  end

  if opts.fail_before_rename then
    error("injected failure (before any rename)")
  end

  for _, name in ipairs(names) do
    local physical = physical_name(name, generation)
    assert(os.rename(dir .. "/" .. physical .. ".tmp", dir .. "/" .. physical),
      "rename failed: " .. dir .. "/" .. physical)
  end

  local manifest = {
    schemaVersion = 1,
    stateId = state_id,
    generation = generation,
    files = entries,
  }
  local manifest_tmp = dir .. "/manifest.json.tmp"
  local mtmp = assert(io.open(manifest_tmp, "wb"))
  assert(mtmp:write(json.encode(manifest)))
  assert(mtmp:close())

  if opts.fail_before_manifest_rename then
    error("injected failure (after typed-file renames, before manifest rename)")
  end

  -- The sole commit point.
  assert(os.rename(manifest_tmp, dir .. "/manifest.json"),
    "rename failed: " .. dir .. "/manifest.json")

  -- Best-effort GC, strictly after the sole commit point above. A GC
  -- failure is a warning, never a reason to report this already-durable
  -- commit as failed.
  local gc_ok, gc_err = pcall(gc_old_generations, dir, generation)
  if not gc_ok then
    io.stderr:write("[manifest] warning: GC of old generations failed in " ..
      dir .. ": " .. tostring(gc_err) .. "\n")
  end

  return generation
end

-- read(dir) -> manifest | nil, errors
-- read_raw has already enforced the full state-manifest.v1 contract
-- (raising on structural corruption, including containment and
-- generation/file binding), so every entry here is well-formed and its
-- physical name is safe to open. This function's own job is the ON-DISK
-- check: re-hash each entry's physical file against the manifest's
-- recorded hash; a missing or stale/tampered file is reported (labeled by
-- the entry's logical name) and the manifest is not returned.
function M.read(dir)
  local manifest = read_raw(dir)
  if not manifest then return nil, { "manifest.json not found" } end

  local errors = {}
  for _, entry in ipairs(manifest.files) do
    local f = io.open(dir .. "/" .. entry.file, "rb")
    if not f then
      errors[#errors + 1] = entry.name .. " (" .. entry.file .. "): file missing"
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
