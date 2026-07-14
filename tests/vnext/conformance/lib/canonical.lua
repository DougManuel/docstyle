-- tests/vnext/conformance/lib/canonical.lua
-- Canonical JSON encoder (RFC 8785-style): sorted object keys, no
-- whitespace, minimal string escaping. Integers only for numbers.
local M = {}

local ESCAPES = {
  ['"'] = '\\"', ['\\'] = '\\\\',
  ['\b'] = '\\b', ['\t'] = '\\t', ['\n'] = '\\n', ['\f'] = '\\f', ['\r'] = '\\r',
}

local function encode_string(s)
  local out = { '"' }
  for i = 1, #s do
    local byte = s:byte(i)
    local ch = s:sub(i, i)
    local esc = ESCAPES[ch]
    if esc then
      out[#out + 1] = esc
    elseif byte < 0x20 then
      out[#out + 1] = ("\\u%04x"):format(byte)
    else
      out[#out + 1] = ch
    end
  end
  out[#out + 1] = '"'
  return table.concat(out)
end

-- Determine whether a table is a JSON array: integer keys 1..n with no gaps.
local function is_array(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  if n == 0 then return false end -- empty table encodes as {} (see below)
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return true
end

local function encode_value(v)
  local t = type(v)
  if v == pandoc.json.null then
    return "null"
  elseif t == "boolean" then
    return v and "true" or "false"
  elseif t == "string" then
    return encode_string(v)
  elseif t == "number" then
    if math.type(v) == "integer" then
      return ("%d"):format(v)
    end
    error("non-integer number in canonical content")
  elseif t == "table" then
    -- An empty Lua table is ambiguous between object and array; treat it
    -- as an empty object.
    if is_array(v) then
      local parts = {}
      for i = 1, #v do parts[i] = encode_value(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = k end
      table.sort(keys)
      local parts = {}
      for i, k in ipairs(keys) do
        parts[i] = encode_string(k) .. ":" .. encode_value(v[k])
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  else
    error("cannot canonically encode value of type " .. t)
  end
end

function M.encode(value)
  return encode_value(value)
end

return M
