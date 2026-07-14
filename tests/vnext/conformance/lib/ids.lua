-- tests/vnext/conformance/lib/ids.lua
-- Generated-region identifier allocation and explicit-id validation.
local M = {}

M.ALPHABET = "abcdefghijklmnopqrstuvwxyz234567"

local function default_next_char()
  local i = math.random(1, #M.ALPHABET)
  return M.ALPHABET:sub(i, i)
end

-- generate(kind, used, next_char) -> id
-- Draws six characters from next_char (default: math.random over ALPHABET)
-- to form "g-<kind>-<suffix>", redrawing while used[id] is already taken.
function M.generate(kind, used, next_char)
  next_char = next_char or default_next_char
  local id
  repeat
    local chars = {}
    for i = 1, 6 do chars[i] = next_char() end
    id = "g-" .. kind .. "-" .. table.concat(chars)
  until not used[id]
  return id
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
