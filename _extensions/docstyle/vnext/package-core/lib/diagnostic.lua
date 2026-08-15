local M = {}

local diagnostic_mt = {
  __tostring = function(value)
    return value.code .. ": " .. value.message
  end,
}

local function make(code, message, context)
  assert(type(code) == "string" and code ~= "", "diagnostic code is required")
  assert(type(message) == "string" and message ~= "", "diagnostic message is required")
  assert(context == nil or type(context) == "table", "diagnostic context must be a table")
  return setmetatable({
    docstyle_diagnostic = true,
    code = code,
    message = message,
    context = context or {},
  }, diagnostic_mt)
end

function M.raise(code, message, context)
  error(make(code, message, context), 0)
end

function M.capture(fn)
  assert(type(fn) == "function", "capture requires a function")
  local values = table.pack(pcall(fn))
  if values[1] then
    return true, table.unpack(values, 2, values.n)
  end

  local err = values[2]
  if type(err) == "table" and err.docstyle_diagnostic == true then
    return false, err
  end
  return false, make("internal.lua-error", tostring(err), {})
end

return M
