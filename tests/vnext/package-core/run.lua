-- Hermetic runner for the Docstyle vNext WP2 package core.
-- Usage: quarto run tests/vnext/package-core/run.lua
local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local root = pandoc.path.normalize(pandoc.path.join({ here, "..", "..", ".." }))
local core = root .. "/_extensions/docstyle/vnext/package-core"

package.path = table.concat({
  here .. "/?.lua",
  here .. "/?/init.lua",
  core .. "/?.lua",
  core .. "/?/init.lua",
}, ";")

local harness = require("lib.harness")
local stage, options = harness.runner_options(os.getenv)
return harness.discover_and_run(here, stage, options)
