local M = {}

local GATES = {
  "archive",
  "functional",
  "preservation",
  "safety",
  "determinism",
  "performance",
}

local VALID_GATE = {}
for _, gate in ipairs(GATES) do VALID_GATE[gate] = true end

local STAGE_RANK = {
  archive = 1,
  xml = 2,
  package = 3,
  performance = 4,
  all = 4,
}

local Registry = {}
Registry.__index = Registry

local function empty_gate_rows()
  local rows = {}
  for _, gate in ipairs(GATES) do
    rows[gate] = { pass = 0, fail = 0, skip = 0 }
  end
  return rows
end

local function validate_stage(stage)
  assert(STAGE_RANK[stage], "unknown spike stage: " .. tostring(stage))
end

local function format_error(err)
  if type(err) == "table" and err.docstyle_diagnostic == true then
    return err.code .. ": " .. err.message
  end
  return tostring(err)
end

function M.new()
  return setmetatable({ cases = {}, names = {} }, Registry)
end

function Registry:case(group, name, fn, options)
  options = options or {}
  assert(type(group) == "string" and group ~= "", "test group is required")
  assert(type(name) == "string" and name ~= "", "test name is required")
  assert(type(fn) == "function", "test function is required")
  assert(VALID_GATE[options.gate], "unknown test gate: " .. tostring(options.gate))
  validate_stage(options.stage)

  local full_name = group .. "/" .. name
  assert(not self.names[full_name], "duplicate test case: " .. full_name)
  self.names[full_name] = true
  self.cases[#self.cases + 1] = {
    full_name = full_name,
    fn = fn,
    gate = options.gate,
    stage = options.stage,
    reference_only = options.reference_only == true,
  }
end

local function should_run(case, stage, options)
  if STAGE_RANK[case.stage] > STAGE_RANK[stage] then return false end
  if case.reference_only and not options.reference_performance then return false end
  return true
end

function Registry:run(stage, options)
  validate_stage(stage)
  options = options or {}
  local cases = {}
  for index, case in ipairs(self.cases) do cases[index] = case end
  table.sort(cases, function(a, b) return a.full_name < b.full_name end)

  local summary = {
    pass = 0,
    fail = 0,
    skip = 0,
    discovered = #cases,
    gates = empty_gate_rows(),
  }

  for _, case in ipairs(cases) do
    local row = summary.gates[case.gate]
    if not should_run(case, stage, options) then
      summary.skip = summary.skip + 1
      row.skip = row.skip + 1
    else
      local ok, err = pcall(case.fn)
      if ok then
        summary.pass = summary.pass + 1
        row.pass = row.pass + 1
      else
        summary.fail = summary.fail + 1
        row.fail = row.fail + 1
        if not options.quiet then
          io.stderr:write("FAIL " .. case.full_name .. ": " .. format_error(err) .. "\n")
        end
      end
    end
  end
  return summary
end

function M.assert_discovery(count)
  assert(type(count) == "number" and count > 0,
    "zero test cases discovered -- spike test discovery is broken")
end

function M.assert_success(summary)
  assert(summary.fail == 0, "spike failures: " .. tostring(summary.fail))
end

function M.runner_options(getenv)
  getenv = getenv or os.getenv
  local stage = getenv("DOCSTYLE_SPIKE_STAGE") or "all"
  validate_stage(stage)
  return stage, {
    reference_performance =
      getenv("DOCSTYLE_SPIKE_REFERENCE_PERFORMANCE") == "1",
  }
end

local function load_test_files(here, registry)
  local tests_dir = pandoc.path.join({ here, "tests" })
  local files = pandoc.system.list_directory(tests_dir)
  table.sort(files)
  for _, filename in ipairs(files) do
    local group = filename:match("^(test%-.+)%.lua$")
    if group then
      local cases = dofile(pandoc.path.join({ tests_dir, filename }))
      assert(type(cases) == "table", filename .. " must return a case table")
      for _, case in ipairs(cases) do
        registry:case(group, case.name, case.fn, {
          gate = case.gate,
          stage = case.stage,
          reference_only = case.reference_only,
        })
      end
    end
  end
end

function M.discover_and_run(here, stage, options)
  local registry = M.new()
  load_test_files(here, registry)
  M.assert_discovery(#registry.cases)
  local summary = registry:run(stage, options)
  for _, gate in ipairs(GATES) do
    local row = summary.gates[gate]
    print(("%s: PASS %d | FAIL %d | SKIP %d"):format(
      gate, row.pass, row.fail, row.skip))
  end
  print(("PASS %d | FAIL %d | SKIP %d"):format(
    summary.pass, summary.fail, summary.skip))
  M.assert_success(summary)
  return summary
end

M.gates = GATES

return M
