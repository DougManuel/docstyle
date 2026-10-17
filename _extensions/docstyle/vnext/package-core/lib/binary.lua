local diagnostic = require("lib.diagnostic")

local M = {}
local U32_BASE = 0x100000000

local function with_context(context, fields)
  local result = {}
  for key, value in pairs(context or {}) do result[key] = value end
  for key, value in pairs(fields or {}) do result[key] = value end
  return result
end

local function require_bytes(bytes, offset, count, context)
  if type(bytes) ~= "string" or math.type(offset) ~= "integer" or
      offset < 0 or math.type(count) ~= "integer" or count < 0 then
    diagnostic.raise("zip.invalid-integer", "invalid binary read", with_context(context, {
      offset = offset,
      needed = count,
    }))
  end
  local available = #bytes - offset
  if available < count then
    diagnostic.raise("zip.truncated", "ZIP field extends beyond available bytes",
      with_context(context, {
        offset = offset,
        needed = count,
        available = math.max(0, available),
      }))
  end
end

function M.u16le(bytes, offset, context)
  require_bytes(bytes, offset, 2, context)
  local a, b = bytes:byte(offset + 1, offset + 2)
  return a | (b << 8)
end

function M.u32le(bytes, offset, context)
  require_bytes(bytes, offset, 4, context)
  local a, b, c, d = bytes:byte(offset + 1, offset + 4)
  return a | (b << 8) | (c << 16) | (d << 24)
end

function M.u64le(bytes, offset, context)
  require_bytes(bytes, offset, 8, context)
  local low = M.u32le(bytes, offset, context)
  local high = M.u32le(bytes, offset + 4, context)
  local max_high = math.maxinteger // U32_BASE
  local max_low = math.maxinteger % U32_BASE
  if high > max_high or (high == max_high and low > max_low) then
    diagnostic.raise("zip.integer-overflow", "ZIP integer exceeds Lua range",
      with_context(context, { offset = offset }))
  end
  return high * U32_BASE + low
end

function M.checked_add(left, right, context)
  if math.type(left) ~= "integer" or math.type(right) ~= "integer" or
      left < 0 or right < 0 or left > math.maxinteger - right then
    diagnostic.raise("zip.integer-overflow", "ZIP offset arithmetic overflow",
      with_context(context, { left = left, right = right }))
  end
  return left + right
end

function M.slice(bytes, offset, count, context)
  require_bytes(bytes, offset, count, context)
  return bytes:sub(offset + 1, offset + count)
end

return M
