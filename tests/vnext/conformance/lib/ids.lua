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

return M
