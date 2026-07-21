-- Hermetic runner for the Docstyle vNext WP2 feasibility spike.
-- Usage: quarto run tests/vnext/xml-spike/run.lua
local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local root = pandoc.path.normalize(pandoc.path.join({ here, "..", "..", ".." }))

package.path = table.concat({
  here .. "/?.lua",
  here .. "/?/init.lua",
  root .. "/dev/vnext/xml-spike/?.lua",
  root .. "/dev/vnext/xml-spike/?/init.lua",
}, ";")

local harness = require("lib.harness")
local stage, options = harness.runner_options(os.getenv)
return harness.discover_and_run(here, stage, options)
