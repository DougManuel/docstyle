local json = require("lib.json")
local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local ex = pandoc.path.join({ here, "..", "..", "..",
  "schemas", "examples", "field-envelope.v4" })
return {
  { name = "every valid envelope example serializes under 1024 bytes", fn = function()
      for _, f in ipairs(pandoc.system.list_directory(ex)) do
        if f:match("^valid") then
          local s = json.encode(json.read(pandoc.path.join({ ex, f })))
          assert(#s <= 1024, f .. " is " .. #s .. " bytes")
        end
      end
    end },
}
