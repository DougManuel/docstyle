-- tests/vnext/conformance/run.lua
-- Conformance runner for Docstyle vNext WP1. Usage: quarto run tests/vnext/conformance/run.lua
local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
package.path = here .. "/?.lua;" .. package.path

local pass, fail = 0, 0
local function report(name, okflag, err)
  if okflag then pass = pass + 1
  else fail = fail + 1; io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n") end
end

local function fail_hard(name, msg)
  fail = fail + 1
  io.stderr:write("FAIL " .. name .. ": " .. msg .. "\n")
end

-- 1. Register schemas FIRST, before any module self-test runs. Self-test
-- cases (e.g. tests/test-migrate.lua) call js.resolve()/js.validate() and
-- need a populated registry to exercise real validation rather than
-- vacuously passing against an empty one -- see jsonschema.lua's M.validate
-- for why a nil schema is now a raised usage error rather than a silent
-- pass. `schemas/` and `schemas/examples/` must both exist: their absence
-- is a hard failure, not a silent skip, because a silently-empty registry
-- or example set would let every downstream check pass vacuously without
-- ever saying so. `schemas/profiles/` stays optional -- no profile schema
-- is required to exist yet.
local js = require("lib.jsonschema")
local json = require("lib.json")
local root = pandoc.path.join({ here, "..", "..", ".." })
local schemas_dir = pandoc.path.join({ root, "schemas" })
local exdir = pandoc.path.join({ schemas_dir, "examples" })

local loaded = {}
local okschemas = pcall(pandoc.system.list_directory, schemas_dir)
if not okschemas then
  fail_hard("runner/schemas-dir", "schemas/ directory not found at " .. schemas_dir)
else
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
end

-- 2. module self-tests (schemas are already registered above)
local self_test_count = 0
local list = pandoc.system.list_directory(here .. "/tests")
table.sort(list)
for _, f in ipairs(list) do
  local mod = f:match("^(test%-.+)%.lua$")
  if mod then
    local cases = dofile(here .. "/tests/" .. f)
    for _, c in ipairs(cases) do
      self_test_count = self_test_count + 1
      local okflag, err = pcall(c.fn)
      report(mod .. "/" .. c.name, okflag, err)
    end
  end
end

-- Floor check: a discovery bug (e.g. a typo'd directory, or every test file
-- silently returning an empty case list) must not look like a clean pass.
if self_test_count == 0 then
  fail_hard("runner/floor", "zero self-test cases ran -- test discovery is broken")
end

-- 3. schema examples. schemas/examples/ absence already reported above via
-- the schemas/ check when schemas/ itself is missing; when schemas/ exists
-- but examples/ does not, that is its own hard failure rather than a
-- silent skip.
if okschemas then
  local okexdir = pcall(pandoc.system.list_directory, exdir)
  if not okexdir then
    fail_hard("runner/examples-dir", "schemas/examples/ directory not found at " .. exdir)
  else
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
