-- tests/vnext/conformance/lib/jsonpatch.lua
-- The RFC 6902 subset the metadata-binding fixtures need: `add`, `replace`
-- and `remove`, addressed by JSON Pointer (lib/jsonschema.lua's
-- pointer_segments / is_array_index, so decoding matches $ref resolution).
-- Each fixture is a named base document plus a short patch; see
-- tests/test-catalogue.lua's loader.
--
-- apply(doc, ops) mutates and returns `doc` (callers pass a copy of the
-- base). Every value added is deep-copied, so a patch never aliases into
-- the document. Anything outside the subset -- another op, a missing
-- parent, a missing replace/remove target, a noncanonical array index --
-- raises: a fixture patch that does not apply cleanly must fail loudly.
--
-- Arrays vs objects: pandoc.json.decode(s, false) gives both as Lua tables;
-- a non-empty table with a string key is an object, otherwise an array.
-- An empty table is an array when the last segment is "-" or an index,
-- else an object (the same ambiguity rule as lib/jsonschema.lua).
local js = require("lib.jsonschema")

local M = {}

local function has_string_key(v)
  for k in pairs(v) do if type(k) == "string" then return true end end
  return false
end

local function deep_copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = deep_copy(x) end
  return setmetatable(out, getmetatable(v))
end
M.deep_copy = deep_copy

local function is_array_for(t, seg)
  if next(t) == nil then return seg == "-" or js.is_array_index(seg) end
  return not has_string_key(t)
end

local function fail(i, op, why) error(("jsonpatch op %d (%s %s): %s"):format(i, tostring(op.op), tostring(op.path), why), 0) end

function M.apply(doc, ops)
  for i, op in ipairs(ops or {}) do
    if op.op ~= "add" and op.op ~= "replace" and op.op ~= "remove" then fail(i, op, "unsupported op") end
    local segs = js.pointer_segments(op.path)
    if #segs == 0 then
      if op.op == "remove" then fail(i, op, "cannot remove the document root") end
      doc = deep_copy(op.value)
    else
      local parent = doc
      for j = 1, #segs - 1 do
        local seg = segs[j]
        if type(parent) ~= "table" then fail(i, op, "path crosses a non-container") end
        if is_array_for(parent, seg) then
          if not js.is_array_index(seg) then fail(i, op, "bad array index '" .. seg .. "'") end
          parent = parent[tonumber(seg) + 1]
        else
          parent = parent[seg]
        end
        if parent == nil then fail(i, op, "missing parent at segment '" .. seg .. "'") end
      end
      if type(parent) ~= "table" then fail(i, op, "parent is not a container") end
      local last = segs[#segs]
      if is_array_for(parent, last) then
        local n = #parent
        local idx
        if last == "-" then
          if op.op ~= "add" then fail(i, op, "'-' is only valid for add") end
          idx = n + 1
        elseif js.is_array_index(last) then
          idx = tonumber(last) + 1
        else
          fail(i, op, "bad array index '" .. last .. "'")
        end
        if op.op == "add" then
          if idx > n + 1 then fail(i, op, "index past the array end") end
          table.insert(parent, idx, deep_copy(op.value))
        elseif idx > n then
          fail(i, op, "no array element to " .. op.op)
        elseif op.op == "replace" then
          parent[idx] = deep_copy(op.value)
        else
          table.remove(parent, idx)
        end
      else
        if op.op ~= "add" and parent[last] == nil then fail(i, op, "no member to " .. op.op) end
        if op.op == "remove" then parent[last] = nil else parent[last] = deep_copy(op.value) end
      end
    end
  end
  return doc
end

--- Expands every `{"$base": <path>, "$patch": [ops]}` object inside `v`
--- (at any depth, including inside base documents themselves) into a copy
--- of the base document with the patch applied. `load(path)` returns the
--- decoded base; it is never mutated. An object carrying `$base` must have
--- exactly those two keys, so a typo cannot silently drop data.
function M.expand(v, load)
  if type(v) ~= "table" then return v end
  if v["$base"] ~= nil then
    for k in pairs(v) do
      if k ~= "$base" and k ~= "$patch" then error("stray key '" .. tostring(k) .. "' beside $base", 0) end
    end
    local base = M.expand(deep_copy(load(v["$base"])), load)
    return M.apply(base, v["$patch"] or {})
  end
  local out = {}
  for k, x in pairs(v) do out[k] = M.expand(x, load) end
  return setmetatable(out, getmetatable(v))
end

return M
