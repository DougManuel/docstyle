-- tests/vnext/conformance/lib/ids.lua
-- Generated-region identifier allocation and explicit-id validation.
local M = {}

M.ALPHABET = "abcdefghijklmnopqrstuvwxyz234567"

-- Redraw cap: a pathological character source or a saturated id space must
-- raise, not spin the collision-redraw loop forever.
local MAX_ATTEMPTS = 64

local function default_next_char()
  local i = math.random(1, #M.ALPHABET)
  return M.ALPHABET:sub(i, i)
end

-- generate(kind, used, next_char) -> id
-- Draws six characters from next_char (default: math.random over ALPHABET)
-- to form "g-<kind>-<suffix>", redrawing while used[id] is already taken.
-- Raises when next_char yields anything other than a single alphabet
-- character (e.g. a finite injected source read past its end returns ""),
-- and when MAX_ATTEMPTS successive draws all collide.
function M.generate(kind, used, next_char)
  next_char = next_char or default_next_char
  for _ = 1, MAX_ATTEMPTS do
    local chars = {}
    for i = 1, 6 do
      local ch = next_char()
      if type(ch) ~= "string" or #ch ~= 1 or not M.ALPHABET:find(ch, 1, true) then
        error("identifier char source exhausted")
      end
      chars[i] = ch
    end
    local id = "g-" .. kind .. "-" .. table.concat(chars)
    if not used[id] then return id end
  end
  error("identifier generation exhausted after " .. MAX_ATTEMPTS .. " attempts")
end

-- check_explicit(id, used) -> ok, err
-- Explicit (author-supplied) ids may not use the reserved generated-id
-- prefix "g-" or the reserved "docstyle-" prefix, and may not collide with
-- an already-used id.
function M.check_explicit(id, used)
  if id:match("^g%-") or id:match("^docstyle%-") then
    return false, "reserved prefix"
  end
  if used[id] then
    return false, "duplicate"
  end
  return true
end

-- Compares two {file, start, end} source-location tables. Not a generic
-- deep_equal: source is a fixed three-member shape (matching
-- schemas/state-regions.v1.json's "source"), so a direct field compare is
-- both sufficient and self-documenting. Either side missing or non-table
-- means "no match" rather than an error -- a region with no source (or a
-- durable entry with none recorded) simply never matches by location.
local function source_equal(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  return a.file == b.file and a.start == b.start and a["end"] == b["end"]
end

-- reuse(region, durable_regions, kind) -> id, origin
-- Implements the WP1 spec's "Decision (stability)" (Identifiers section):
-- a generated identifier is assigned once and persisted in durable state
-- (regions.json); later renders reuse the persisted identifier by matching
-- explicit identifiers first, then source location, then content hash --
-- never because a coincidental fresh match is easier to compute. A
-- generated identifier never changes just because content changed; content
-- hash is used only to RECOGNIZE a region that moved (rule 3 below), not
-- to decide whether to mint a new id for changed content.
--
-- region: this render's candidate region --
--   { explicit_id?, type?, source={file,start,end}, hash }
--   explicit_id is present only when the region already carries an
--   author-supplied QMD id; type is the content-node type, used as the
--   generate() "kind" when a fresh id must be minted; source/hash are this
--   render's own location and content hash for the region.
-- durable_regions: the previous commit's regions.json entries -- an array
--   of { id, source={file,start,end}, hash }.
-- kind: fallback generate() "kind", used only when region.type is absent
--   (defaults to "region" when neither is given).
--
-- Match order (first hit wins; each branch returns id, origin):
--   1. region.explicit_id present -> (explicit_id, "explicit"). An
--      explicit id is authoritative regardless of source or hash.
--   2. some durable region's source deep-equals region.source ->
--      (that durable region's id, "source"). The region stayed in the
--      same place; its content may have changed underneath it (an edit),
--      but it is still the same region.
--   3. some durable region's hash == region.hash -> (that durable
--      region's id, "hash"). The region's content is identical to a
--      previously-seen region, but it moved to a new source location --
--      still the same region.
--   4. no match -> mint a fresh id via generate(), origin "minted". `used`
--      is derived from durable_regions' own ids, so a freshly-minted id
--      cannot collide with any id already on record.
--
-- Source is checked before hash (matching the spec's own stated order:
-- "explicit identifiers first, then source location, then content hash")
-- because a moved-but-edited region has no matching source anywhere and
-- must fall through to the hash check, while a region that stayed put but
-- changed content should resolve via its unchanged source without its
-- now-stale old hash ever being consulted.
-- allocator(durable_regions, opts) -> alloc; alloc:claim(region, kind) -> id, origin
-- Document-scoped allocation, per the spec's collision decision: an id must
-- be unused within the DOCUMENT and its durable state, so all claims in one
-- render share state. `claimed` marks durable ids already selected this
-- render (a durable id can be reused by at most ONE current region);
-- `assigned` marks every id handed out this render (explicit, reused or
-- minted), so mints reserve against one another and duplicate explicit ids
-- fail closed. opts.next_char threads a deterministic character source to
-- generate() for tests.
--
-- Tier rules (explicit -> source -> hash -> mint, as reuse() documents),
-- with the document-scoped refinements:
--   * explicit: validated via check_explicit against `assigned` -- a
--     duplicate explicit id (or one colliding with an id already reused
--     this render) raises rather than silently duplicating.
--   * source/hash: only UNCLAIMED durable entries are eligible.
--   * hash additionally requires the match to be UNIQUE among unclaimed
--     durable entries: hashes recognize a moved region, they do not define
--     identity, so an ambiguous match (two identical-content durable
--     regions) mints instead of pairing arbitrarily.
function M.allocator(durable_regions, opts)
  durable_regions = durable_regions or {}
  opts = opts or {}
  local alloc = {
    durable = durable_regions,
    claimed = {},   -- durable ids selected this render
    assigned = {},  -- every id handed out this render
    next_char = opts.next_char,
  }

  function alloc:claim(region, kind)
    region = region or {}

    if region.explicit_id ~= nil then
      local ok, err = M.check_explicit(region.explicit_id, self.assigned)
      if not ok then
        error("explicit id '" .. tostring(region.explicit_id) .. "' rejected: " .. err)
      end
      self.assigned[region.explicit_id] = true
      return region.explicit_id, "explicit"
    end

    if region.source ~= nil then
      for _, durable in ipairs(self.durable) do
        if not self.claimed[durable.id] and source_equal(durable.source, region.source) then
          self.claimed[durable.id] = true
          self.assigned[durable.id] = true
          return durable.id, "source"
        end
      end
    end

    if region.hash ~= nil then
      local match = nil
      local ambiguous = false
      for _, durable in ipairs(self.durable) do
        if not self.claimed[durable.id] and durable.hash ~= nil and durable.hash == region.hash then
          if match ~= nil then ambiguous = true break end
          match = durable
        end
      end
      if match ~= nil and not ambiguous then
        self.claimed[match.id] = true
        self.assigned[match.id] = true
        return match.id, "hash"
      end
    end

    local used = {}
    for _, durable in ipairs(self.durable) do
      used[durable.id] = true
    end
    for id in pairs(self.assigned) do
      used[id] = true
    end
    local id = M.generate(region.type or kind or "region", used, self.next_char)
    self.assigned[id] = true
    return id, "minted"
  end

  return alloc
end

-- One-shot convenience over a fresh allocator. Correct only for a SINGLE
-- claim: it cannot see ids handed to other regions, so multi-region renders
-- must create one allocator for the whole document and claim() through it.
function M.reuse(region, durable_regions, kind)
  return M.allocator(durable_regions):claim(region, kind)
end

return M
