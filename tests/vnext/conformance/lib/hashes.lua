local c, sha = require("lib.canonical"), require("lib.sha256")
local M = {}
local STRIP = { hash = true, source = true }

-- Normalize line endings in every string VALUE before hashing (CRLF -> LF,
-- then any remaining lone CR -> LF), matching the spec's canonical hash
-- input rule ("text values normalized to Unicode NFC with LF line
-- endings"). Keys are never normalized: every key this module ever walks
-- is a schema-controlled field name (e.g. "type", "children"), not
-- authored text, so a key can never contain a line ending to begin with.
local function normalize_newlines(s)
  return (s:gsub("\r\n", "\n"):gsub("\r", "\n"))
end

local function strip(v)
  if type(v) == "string" then return normalize_newlines(v) end
  if type(v) ~= "table" then return v end
  local out = {}
  for k, val in pairs(v) do if not STRIP[k] then out[k] = strip(val) end end
  return out
end
function M.content_hash(node) return "sha256:" .. sha.hex(c.encode(strip(node))) end
return M
