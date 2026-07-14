local c, sha = require("lib.canonical"), require("lib.sha256")
local M = {}
local STRIP = { hash = true, source = true }
local function strip(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, val in pairs(v) do if not STRIP[k] then out[k] = strip(val) end end
  return out
end
function M.content_hash(node) return "sha256:" .. sha.hex(c.encode(strip(node))) end
return M
