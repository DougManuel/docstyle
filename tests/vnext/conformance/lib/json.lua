local M = {}
function M.decode(s) return pandoc.json.decode(s, false) end
function M.encode(v) return pandoc.json.encode(v) end
function M.read(path)
  local f = assert(io.open(path, "rb")); local s = f:read("a"); f:close()
  return M.decode(s)
end
return M
