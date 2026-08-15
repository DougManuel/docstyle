local diagnostic = require("lib.diagnostic")

local M = {}

local DEFAULT_LIMITS = {
  max_input_bytes = 64 * 1024 * 1024,
  max_depth = 1024,
  max_tokens = 10000000,
  max_attributes = 10000,
  max_namespaces = 1000,
}

function M.range(start_at, finish_at)
  if math.type(start_at) ~= "integer" or start_at < 0 or
      math.type(finish_at) ~= "integer" or finish_at < start_at then
    diagnostic.raise("xml.invalid-range", "invalid half-open byte range", {
      start = start_at,
      finish = finish_at,
    })
  end
  return { start = start_at, finish = finish_at }
end

function M.expanded_name(uri, local_name, prefix, qname)
  assert(type(uri) == "string", "namespace URI must be a string")
  assert(type(local_name) == "string" and local_name ~= "",
    "local name is required")
  return {
    uri = uri,
    local_name = local_name,
    prefix = prefix or "",
    qname = qname or (prefix and prefix ~= "" and
      (prefix .. ":" .. local_name) or local_name),
  }
end

function M.limits(options)
  options = options or {}
  assert(type(options) == "table", "parse options must be a table")
  local result = {}
  for name, default in pairs(DEFAULT_LIMITS) do
    local value = options[name]
    if value == nil then value = default end
    if math.type(value) ~= "integer" or value <= 0 then
      diagnostic.raise("xml.invalid-limit", "invalid XML parse limit", {
        option = name,
        value = value,
      })
    end
    result[name] = value
  end
  return result
end

function M.same_range(left, right)
  return type(left) == "table" and type(right) == "table" and
    left.start == right.start and left.finish == right.finish
end

return M
