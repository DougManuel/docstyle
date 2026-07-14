local mg = require("lib.migrate")
local json = require("lib.json")

-- NOTE on path resolution (deviation from the task-8 brief's literal
-- `local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)`):
--
-- PANDOC_SCRIPT_FILE stays pinned to the *top-level* entry script
-- (tests/vnext/conformance/run.lua) for the lifetime of the process --
-- run.lua's `dofile(here .. "/tests/" .. f)` does not update it to the
-- dofile()'d file. Verified empirically with a standalone run.lua + dofile()
-- harness (see task-8-report.md): a nested script's
-- `pandoc.path.directory(PANDOC_SCRIPT_FILE)` prints run.lua's own
-- directory, not the nested script's directory, both under `quarto run
-- <absolute path>` and `quarto run <relative path>`.
--
-- Using PANDOC_SCRIPT_FILE here would make `here` resolve to
-- tests/vnext/conformance (run.lua's directory) rather than
-- tests/vnext/conformance/tests (this file's own directory), so
-- `join(here, "..", "legacy", "cases")` would land one level too high, on a
-- "legacy" sibling of conformance/ itself, instead of tests/vnext/conformance
-- /legacy/cases as required by the task-8 brief's Files list. Resolving
-- `here` from this chunk's own debug info (which does reflect wherever it
-- was loaded from) makes the `..`-relative join land correctly regardless of
-- how this file is invoked (dofile()'d from run.lua, or run directly).
--
-- The four test cases below are otherwise verbatim from the task-8 brief.
local this_file = debug.getinfo(1, "S").source:match("^@(.*)$")
local here = pandoc.path.directory(this_file)
local cases_dir = pandoc.path.join({ here, "..", "legacy", "cases" })
local cases = {
  { name = "every mapping case produces its expected envelope", fn = function()
      for _, f in ipairs(pandoc.system.list_directory(cases_dir)) do
        local case = json.read(pandoc.path.join({ cases_dir, f }))
        local out = mg.payload(case.legacy)
        local got, want = json.encode(out.envelope), json.encode(case.expected_envelope)
        assert(got == want, f .. ": " .. got)
      end
    end },
  { name = "unknown legacy key is a blocking finding, not a guess", fn = function()
      local out = mg.payload({ version = 2, type = "div", name = "x",
        mystery = "value" })
      local found = false
      for _, fd in ipairs(out.findings) do
        if fd.code == "unmapped-legacy-key" and fd.level == "error" then found = true end
      end
      assert(found, "expected unmapped-legacy-key error finding")
    end },
  { name = "future version is rejected", fn = function()
      local out = mg.payload({ version = 9, type = "div", name = "x" })
      assert(out.envelope == nil and out.findings[1].code == "unsupported-version")
    end },
  { name = "sidecar migration emits schema-valid outputs and a report", fn = function()
      local js = require("lib.jsonschema")
      local res = mg.sidecars({
        field_codes = { citations = { { keys = { "smith2024" },
          instruction = "ADDIN ZOTERO_ITEM CSL_CITATION {}" } },
          zotero_pref = "<data/>" },
        comments = { { author = "A", date = "2026-07-01",
          text = "note", anchor_text = "the abstract" } },
        revisions = { { author = "A", date = "2026-07-01",
          type = "insert", text = "added" } } })
      local base = "https://dougmanuel.github.io/docstyle/schemas/"
      assert(js.validate(js.resolve(base .. "state-citations.v1.json"), res.citations))
      assert(js.validate(js.resolve(base .. "state-annotations.v1.json"), res.annotations))
      assert(js.validate(js.resolve(base .. "report-envelope.v1.json"), res.report))
      assert(res.report.result ~= "FAIL")
    end },
}
return cases
