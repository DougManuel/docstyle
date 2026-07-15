-- lib/jsonschema.lua
-- Minimal JSON Schema (2020-12 subset) validator for the Docstyle vNext
-- conformance suite. Implements exactly the keyword subset the vNext
-- schemas and tests use: type, properties, required, additionalProperties
-- (boolean false only), enum, const, pattern, minLength/maxLength,
-- minimum/maximum, items, minItems/maxItems, oneOf, anyOf, $ref, $defs.
--
-- Object vs. array distinction: pandoc.json.decode(s, false) (see lib/json.lua)
-- decodes JSON without converting to pandoc AST types, so both `{}` and `[]`
-- become an empty Lua table -- there is no way to distinguish them from the
-- decoded value alone. Our rule lives entirely in `has_string_key(v)`,
-- below: it reports true only when `v` is a table with at least one string
-- key, which can only happen for a decoded JSON object (a JSON array always
-- decodes to a contiguous 1..n-integer-keyed table). An empty table is
-- genuinely ambiguous -- it could be `{}` or `[]` -- so `has_string_key`
-- reports false for it (there is no string key to find either way); callers
-- that need to treat an empty table as satisfying *either* interpretation
-- do that explicitly rather than asking `has_string_key` to decide:
-- `check_type`'s "object" branch accepts a value when `next(v) == nil`
-- (empty) OR `has_string_key(v)` (has at least one string key); its "array"
-- branch accepts a value when `next(v) == nil` (empty) OR
-- `not has_string_key(v)` (no string key, i.e. Lua's normal array
-- convention). Structural keywords (properties/required/additionalProperties
-- vs items/minItems) decide their own applicability from the *schema*, not
-- the instance, so the empty-table ambiguity never needs to be resolved
-- beyond "type is satisfied either way."

local M = {}

-- Registry of schemas keyed by $id, for absolute $ref resolution.
local registry = {}

function M.register(id, schema)
  registry[id] = schema
end

function M.resolve(id)
  return registry[id]
end

--- Returns true if `v` is a Lua table with at least one non-integer
--- (i.e. string) key -- meaning it must have come from a JSON object.
--- Empty tables are ambiguous (could be `{}` or `[]`) and are handled by
--- callers based on schema context, not here.
local function has_string_key(v)
  if type(v) ~= "table" then return false end
  for k in pairs(v) do
    if type(k) == "string" then return true end
  end
  return false
end

--- Array length using Lua's `#` (relies on JSON arrays decoding to a
--- contiguous integer-keyed table, which pandoc.json.decode guarantees).
local function array_len(v)
  return #v
end

local function is_lua_integer(v)
  if math.type(v) == "integer" then return true end
  if math.type(v) == "float" then
    return v == math.floor(v)
  end
  return false
end

-- ---------------------------------------------------------------------
-- Path helpers (JSON Pointer strings, e.g. "/a/0/b")
-- ---------------------------------------------------------------------

local function push(path, seg)
  return path .. "/" .. tostring(seg)
end

-- ---------------------------------------------------------------------
-- Pattern translation: expand `{n}` / `{n,m}` repetition into repeated
-- Lua character-class groups, since Lua patterns have no native brace
-- repetition. Character classes like [0-9a-f] and [a-z2-7] are already
-- valid Lua pattern syntax and pass through unchanged.
-- ---------------------------------------------------------------------

local function expand_braces(pat)
  -- Repeatedly expand the first `{n}` or `{n,m}` that follows either a
  -- `%`-escaped class, a `[...]` class, or a single literal character.
  local out = {}
  local i = 1
  local n = #pat
  while i <= n do
    local unit, after
    local c = pat:sub(i, i)
    if c == "%" then
      unit = pat:sub(i, i + 1)
      after = i + 2
    elseif c == "[" then
      local close = pat:find("]", i + 2, true) -- skip a leading ] or ^]
      if not close then
        unit = c
        after = i + 1
      else
        unit = pat:sub(i, close)
        after = close + 1
      end
    else
      unit = c
      after = i + 1
    end

    local brace_start, brace_end, nums = pat:find("^{(%d[%d,]*)}", after)
    if brace_start then
      local lo, hi = nums:match("^(%d+),(%d+)$")
      if not lo then
        lo = nums:match("^(%d+)$")
        hi = lo
      end
      lo = tonumber(lo)
      hi = tonumber(hi)
      for _ = 1, lo do out[#out + 1] = unit end
      for _ = lo + 1, hi do out[#out + 1] = unit .. "?" end
      i = brace_end + 1
    else
      out[#out + 1] = unit
      i = after
    end
  end
  return table.concat(out)
end

-- ---------------------------------------------------------------------
-- Core validation
-- ---------------------------------------------------------------------

local validate_node -- forward declaration

--- Resolves a $ref string against `root` (the top-level schema document,
--- for `#/$defs/...` fragments) and the module registry (for absolute
--- ids). On success returns the resolved schema plus the root to use when
--- resolving refs *inside* it: fragment refs keep the current root, while
--- an absolute id switches the root to the referenced schema document, so
--- that document's own `#/$defs/...` refs resolve against its `$defs`.
--- On failure returns nil plus an error message.
local function resolve_ref(ref, root)
  local frag = ref:match("^#(/.*)$")
  if frag then
    local node = root
    for seg in frag:gmatch("/([^/]+)") do
      seg = seg:gsub("~1", "/"):gsub("~0", "~")
      if type(node) ~= "table" then return nil, "cannot resolve $ref " .. ref end
      node = node[seg]
    end
    if node == nil then return nil, "unresolved $ref " .. ref end
    return node, root
  end

  local target = registry[ref]
  if target == nil then return nil, "unresolved $ref " .. ref end
  return target, target
end

local function check_type(t, v, errors, path)
  if t == "string" then
    if type(v) ~= "string" then
      errors[#errors + 1] = { path = path, message = "expected string" }
      return false
    end
  elseif t == "boolean" then
    if type(v) ~= "boolean" then
      errors[#errors + 1] = { path = path, message = "expected boolean" }
      return false
    end
  elseif t == "null" then
    if v ~= nil and v ~= pandoc.json.null then
      errors[#errors + 1] = { path = path, message = "expected null" }
      return false
    end
  elseif t == "integer" then
    if type(v) ~= "number" or not is_lua_integer(v) then
      errors[#errors + 1] = { path = path, message = "expected integer" }
      return false
    end
  elseif t == "number" then
    if type(v) ~= "number" then
      errors[#errors + 1] = { path = path, message = "expected number" }
      return false
    end
  elseif t == "object" then
    if type(v) ~= "table" then
      errors[#errors + 1] = { path = path, message = "expected object" }
      return false
    end
    -- empty table or a table with string keys both count as objects
    if not (next(v) == nil or has_string_key(v)) then
      errors[#errors + 1] = { path = path, message = "expected object" }
      return false
    end
  elseif t == "array" then
    if type(v) ~= "table" then
      errors[#errors + 1] = { path = path, message = "expected array" }
      return false
    end
    -- empty table or a table without string keys both count as arrays
    if not (next(v) == nil or not has_string_key(v)) then
      errors[#errors + 1] = { path = path, message = "expected array" }
      return false
    end
  else
    errors[#errors + 1] = { path = path, message = "unknown type " .. tostring(t) }
    return false
  end
  return true
end

local function check_pattern(pattern, v, errors, path)
  local lua_pat = expand_braces(pattern)
  if not v:match(lua_pat) then
    errors[#errors + 1] = { path = path, message = "does not match pattern " .. pattern }
    return false
  end
  return true
end

local function deep_equal(a, b)
  if type(a) ~= type(b) then
    -- allow integer/float number equivalence
    if type(a) == "number" and type(b) == "number" then return a == b end
    return false
  end
  if type(a) ~= "table" then return a == b end
  for k, av in pairs(a) do
    if not deep_equal(av, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil and b[k] ~= nil then return false end
  end
  return true
end

--- Validates `v` against `schema`, appending any errors (JSON Pointer
--- path + message) to `errors`. `root` is the top-level schema document
--- (for resolving `#/$defs/...` refs). Returns true/false.
validate_node = function(schema, v, errors, path, root)
  if schema == nil then return true end

  if schema["$ref"] then
    local resolved, root_or_err = resolve_ref(schema["$ref"], root)
    if not resolved then
      errors[#errors + 1] = { path = path, message = root_or_err }
      return false
    end
    return validate_node(resolved, v, errors, path, root_or_err)
  end

  local node_ok = true

  if schema.type then
    if not check_type(schema.type, v, errors, path) then
      node_ok = false
    end
  end

  if schema.enum then
    local found = false
    for _, ev in ipairs(schema.enum) do
      if deep_equal(ev, v) then found = true; break end
    end
    if not found then
      errors[#errors + 1] = { path = path, message = "not in enum" }
      node_ok = false
    end
  end

  if schema.const ~= nil then
    if not deep_equal(schema.const, v) then
      errors[#errors + 1] = { path = path, message = "does not match const" }
      node_ok = false
    end
  end

  if type(v) == "string" then
    if schema.pattern then
      if not check_pattern(schema.pattern, v, errors, path) then node_ok = false end
    end
    if schema.minLength and #v < schema.minLength then
      errors[#errors + 1] = { path = path, message = "shorter than minLength" }
      node_ok = false
    end
    if schema.maxLength and #v > schema.maxLength then
      errors[#errors + 1] = { path = path, message = "longer than maxLength" }
      node_ok = false
    end
  end

  if type(v) == "number" then
    if schema.minimum and v < schema.minimum then
      errors[#errors + 1] = { path = path, message = "less than minimum" }
      node_ok = false
    end
    if schema.maximum and v > schema.maximum then
      errors[#errors + 1] = { path = path, message = "greater than maximum" }
      node_ok = false
    end
  end

  -- object keywords: only meaningful when v is a table treated as object
  if type(v) == "table" and (schema.properties or schema.required or schema.additionalProperties ~= nil) then
    if schema.required then
      for _, key in ipairs(schema.required) do
        if v[key] == nil then
          errors[#errors + 1] = { path = path, message = "missing required property " .. key }
          node_ok = false
        end
      end
    end

    if schema.properties then
      for key, subschema in pairs(schema.properties) do
        if v[key] ~= nil then
          if not validate_node(subschema, v[key], errors, push(path, key), root) then
            node_ok = false
          end
        end
      end
    end

    if schema.additionalProperties == false then
      local allowed = schema.properties or {}
      for key in pairs(v) do
        if allowed[key] == nil then
          errors[#errors + 1] = { path = push(path, key), message = "additional property not allowed" }
          node_ok = false
        end
      end
    end
  end

  -- array keywords: only meaningful when v is a table treated as array
  if type(v) == "table" and (schema.items or schema.minItems or schema.maxItems) then
    local len = array_len(v)
    if schema.minItems and len < schema.minItems then
      errors[#errors + 1] = { path = path, message = "fewer than minItems" }
      node_ok = false
    end
    if schema.maxItems and len > schema.maxItems then
      errors[#errors + 1] = { path = path, message = "more than maxItems" }
      node_ok = false
    end
    if schema.items then
      for idx = 1, len do
        if not validate_node(schema.items, v[idx], errors, push(path, idx - 1), root) then
          node_ok = false
        end
      end
    end
  end

  if schema.anyOf then
    local matched = false
    for _, sub in ipairs(schema.anyOf) do
      local sub_errors = {}
      if validate_node(sub, v, sub_errors, path, root) then
        matched = true
        break
      end
    end
    if not matched then
      errors[#errors + 1] = { path = path, message = "does not match any schema in anyOf" }
      node_ok = false
    end
  end

  if schema.oneOf then
    local match_count = 0
    for _, sub in ipairs(schema.oneOf) do
      local sub_errors = {}
      if validate_node(sub, v, sub_errors, path, root) then
        match_count = match_count + 1
      end
    end
    if match_count ~= 1 then
      errors[#errors + 1] = { path = path, message = "matched " .. match_count .. " schemas in oneOf, expected exactly 1" }
      node_ok = false
    end
  end

  return node_ok
end

--- Validates `instance` against `schema`. Returns ok:boolean,
--- errors:{ {path, message}, ... }.
---
--- `schema` must not be nil. A nil schema almost always means a caller took
--- `M.resolve()`'s return value straight into `M.validate()` without
--- checking it -- and an unregistered schema id is a usage error, not the
--- same thing as a legitimately unconstrained `{}` schema (which still
--- validates everything and is not an error). Raising here, at this entry
--- boundary, distinguishes "unregistered" (nil, raises) from "unconstrained"
--- (an actual empty schema object, still passes) without changing
--- `validate_node`'s own recursive nil-tolerance, which exists for
--- subschemas legitimately reached with no constraints during traversal.
function M.validate(schema, instance)
  if schema == nil then
    error("jsonschema.validate: schema is nil -- did M.resolve() return nil for an unregistered $id?")
  end
  local errors = {}
  local okflag = validate_node(schema, instance, errors, "", schema)
  return okflag and #errors == 0, errors
end

return M
