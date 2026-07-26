local fixture = require("lib.fixture")

local runner_here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local root = pandoc.path.normalize(pandoc.path.join({
  runner_here, "..", "..", "..",
}))

local SOURCE = pandoc.path.join({
  root, "tests", "vnext", "xml-spike", "fixtures", "office",
  "libreoffice-produced.docx",
})
local CHILD = pandoc.path.join({
  root, "tests", "vnext", "xml-spike", "lib", "child.lua",
})
local RESULTS = pandoc.path.join({
  root, "dev", "vnext", "xml-spike", "determinism-results.json",
})

local function trim(value)
  return value:match("^%s*(.-)%s*$")
end

local function run_child(output_path)
  local environment = pandoc.system.environment()
  environment.DOCSTYLE_SPIKE_CHILD_SOURCE = SOURCE
  environment.DOCSTYLE_SPIKE_CHILD_OUTPUT = output_path
  local stdout = pandoc.system.with_environment(environment, function()
    return pandoc.pipe("quarto", { "run", CHILD }, "")
  end)
  return pandoc.json.decode(trim(stdout), false)
end

local function joined_names(names)
  assert(type(names) == "table" and #names > 0,
    "child result must contain ordered entry names")
  return table.concat(names, "\0")
end

return {
  {
    name = "ten fresh processes produce identical publication evidence",
    gate = "determinism",
    stage = "performance",
    fn = function()
      fixture.with_temp_dir("fresh-process", function(dir)
        local baseline
        for index = 1, 10 do
          local result = run_child(pandoc.path.join({
            dir, ("published-%02d.docx"):format(index),
          }))
          assert(type(result.edited_part_sha256) == "string" and
            result.edited_part_sha256:match("^[0-9a-f]+$") and
            #result.edited_part_sha256 == 64)
          assert(type(result.archive_sha256) == "string" and
            result.archive_sha256:match("^[0-9a-f]+$") and
            #result.archive_sha256 == 64)
          local names = joined_names(result.entry_names)
          if not baseline then
            baseline = {
              edited_part_sha256 = result.edited_part_sha256,
              archive_sha256 = result.archive_sha256,
              entry_names = names,
            }
          else
            assert(result.edited_part_sha256 ==
              baseline.edited_part_sha256,
              "edited-part hash differs in process " .. index)
            assert(names == baseline.entry_names,
              "entry order differs in process " .. index)
            assert(result.archive_sha256 == baseline.archive_sha256,
              "archive hash differs in process " .. index)
          end
        end

        local evidence = pandoc.json.decode(
          fixture.read_bytes(RESULTS), false)
        assert(evidence.decision == "pass")
        assert(evidence.process_count == 10)
        assert(evidence.runtime.quarto == "1.9.26")
        assert(evidence.runtime.pandoc == tostring(PANDOC_VERSION))
        assert(evidence.runtime.lua == _VERSION)
        assert(evidence.runtime.os == pandoc.system.os)
        assert(evidence.runtime.arch == pandoc.system.arch)
        assert(evidence.source_sha256 ==
          "3fb9ec751404c2e66e8e81a066fe2c0ab87dfb367756a2987bd99fecb909cec4")
        assert(evidence.edited_part_sha256 ==
          baseline.edited_part_sha256)
        assert(joined_names(evidence.entry_names) ==
          baseline.entry_names)
        assert(evidence.archive_sha256 == baseline.archive_sha256)
      end)
    end,
  },
}
