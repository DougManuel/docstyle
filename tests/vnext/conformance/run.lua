-- tests/vnext/conformance/run.lua
-- Conformance runner for Docstyle vNext WP1. Usage: quarto run tests/vnext/conformance/run.lua
local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
package.path = here .. "/?.lua;" .. package.path

local pass, fail = 0, 0
local function report(name, okflag, err)
  if okflag then pass = pass + 1
  else fail = fail + 1; io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n") end
end

-- 1. module self-tests
local list = pandoc.system.list_directory(here .. "/tests")
table.sort(list)
for _, f in ipairs(list) do
  local mod = f:match("^(test%-.+)%.lua$")
  if mod then
    local cases = dofile(here .. "/tests/" .. f)
    for _, c in ipairs(cases) do
      local okflag, err = pcall(c.fn)
      report(mod .. "/" .. c.name, okflag, err)
    end
  end
end

-- 2. schema examples (skipped silently until schemas/ exists)
local js = require("lib.jsonschema")
local json = require("lib.json")
local root = pandoc.path.join({ here, "..", "..", ".." })
local schemas_dir = pandoc.path.join({ root, "schemas" })
local okdir, names = pcall(pandoc.system.list_directory, schemas_dir)
if okdir then
  local loaded = {}
  local function load_dir(dir, key_prefix)
    for _, f in ipairs(pandoc.system.list_directory(dir)) do
      if f:match("%.json$") then
        local s = json.read(pandoc.path.join({ dir, f }))
        js.register(s["$id"], s)
        loaded[key_prefix .. f:gsub("%.json$", "")] = s
      end
    end
  end
  load_dir(schemas_dir, "")
  local pd = pandoc.path.join({ schemas_dir, "profiles" })
  if pcall(pandoc.system.list_directory, pd) then load_dir(pd, "profiles/") end
  local exdir = pandoc.path.join({ schemas_dir, "examples" })
  if pcall(pandoc.system.list_directory, exdir) then
    for _, name in ipairs(pandoc.system.list_directory(exdir)) do
      local schema = loaded[name] or loaded["profiles/" .. name]
      for _, ex in ipairs(pandoc.system.list_directory(pandoc.path.join({ exdir, name }))) do
        if schema == nil then
          report("examples/" .. name .. "/" .. ex, false, "no schema registered for " .. name)
        else
          local inst = json.read(pandoc.path.join({ exdir, name, ex }))
          local v, errs = js.validate(schema, inst)
          local want_valid = ex:match("^valid") ~= nil
          local okflag = (v == want_valid)
          local msg = want_valid and (errs and errs[1] and (errs[1].path .. " " .. errs[1].message))
            or "invalid example validated"
          report("examples/" .. name .. "/" .. ex, okflag, msg)
        end
      end
    end
  end
end

print(("PASS %d | FAIL %d"):format(pass, fail))
if fail > 0 then error("conformance failures: " .. fail) end
